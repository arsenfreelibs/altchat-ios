import Foundation
import Network
import DcCore

/// Automatically engages a bundled HTTP proxy when our relay is blocked but the
/// internet still works, and reverts to a direct connection once the relay is
/// reachable again.
///
/// State machine (all transitions happen on `queue`):
/// - `.direct`:   proxy off, watching the selected account's relay. If it stays
///                disconnected for `graceSeconds` while the internet is reachable
///                AND a direct TCP probe of the relay also fails -> engage proxy.
/// - `.engaging`: we turned a proxy on for `managedAccountId` and are waiting for
///                it to connect. Each candidate gets `proxyTrySeconds`; on timeout
///                we rotate. Candidates that aren't even TCP-reachable are skipped
///                without ever touching the account config.
/// - `.engaged`:  proxy connected. We re-probe every engaged account's relay
///                directly every `directRecheckSeconds`; whichever answers reverts
///                to direct — independently of which account is currently selected.
///
/// Engagement is tracked per-account (`engagedKey(id)`), so a proxy we turned on
/// for a background account is still reverted once its relay recovers. A proxy the
/// user enabled manually is left untouched.
final class AutoProxyManager: NSObject {

    private let dcAccounts: DcAccounts
    private let queue = DispatchQueue(label: "chat.alt.autoproxy")

    private enum Mode {
        case direct
        case engaging
        case engaged
    }
    private var mode: Mode = .direct
    private var started = false

    /// Single in-flight scheduled task (grace check / rotate / direct re-check).
    private var pendingWork: DispatchWorkItem?
    /// Index into `AutoProxy.proxyURLs` of the candidate currently being tried.
    private var currentProxyIndex = 0
    /// Number of consecutive candidates tried without success in the current round.
    private var triesInRound = 0
    /// True while we're waiting out a grace period after the proxy dropped, before
    /// tearing IO down. Cleared by `cancelPending()` so it stays in sync with the timer.
    private var engagedDropPending = false
    /// Account whose proxy this state machine is currently engaging/managing.
    private var managedAccountId: Int?

    /// Legacy single-account flag, kept only to clear it on first launch after upgrade.
    private static let legacyEngagedKey = "autoProxyEngaged"
    private static func engagedKey(_ accountId: Int) -> String { "autoProxyEngaged.\(accountId)" }

    private func isEngaged(_ accountId: Int) -> Bool {
        UserDefaults.standard.bool(forKey: Self.engagedKey(accountId))
    }
    private func setEngaged(_ engaged: Bool, _ accountId: Int) {
        let key = Self.engagedKey(accountId)
        if engaged {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// A connection counts as "up" once the core reports `WORKING`, not only the
    /// fully-idle `CONNECTED`. During a message send the core drops from
    /// `CONNECTED` (4000) to `WORKING` (3000) and fires `connectivityChanged`;
    /// treating that transient as "disconnected" would make us rotate proxies and
    /// `restartIO()` mid-send, stalling the very message being sent.
    private func relayIsUp(_ dcContext: DcContext) -> Bool {
        dcContext.getConnectivity() >= DC_CONNECTIVITY_WORKING
    }

    init(dcAccounts: DcAccounts) {
        self.dcAccounts = dcAccounts
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.connectivityChanged(_:)),
                name: Event.connectivityChanged,
                object: nil)

            self.recoverEngagedAccounts()
            self.onConnectivity()
        }
    }

    /// On launch, mark every account that is currently sitting on one of our bundled
    /// proxies as engaged (covers app restarts and migrates the old single-flag
    /// scheme), then resume relay monitoring so they get reverted once reachable.
    private func recoverEngagedAccounts() {
        for id in dcAccounts.getAll() {
            let ctx = dcAccounts.get(id: id)
            if ctx.isProxyEnabled,
               let front = ctx.getProxies().first(where: { !$0.isEmpty }),
               AutoProxy.proxyURLs.contains(front) {
                setEngaged(true, id)
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyEngagedKey)

        let engaged = dcAccounts.getAll().filter { isEngaged($0) }
        if !engaged.isEmpty {
            managedAccountId = engaged.first
            mode = .engaged
            scheduleDirectRecheck()
        }
    }

    /// Nudge the state machine, e.g. when the app returns to foreground.
    func reevaluate() {
        queue.async { [weak self] in self?.onConnectivity() }
    }

    // MARK: - Events

    @objc private func connectivityChanged(_ notification: Notification) {
        queue.async { [weak self] in self?.onConnectivity() }
    }

    private func onConnectivity() {
        guard started else { return }
        let selected = dcAccounts.getSelected()
        guard selected.isConfigured() else {
            cancelPending()
            mode = .direct
            return
        }

        switch mode {
        case .direct:
            // Respect a proxy the user enabled manually on the selected account.
            if selected.isProxyEnabled && !isEngaged(selected.id) {
                cancelPending()
                return
            }
            if relayIsUp(selected) {
                cancelPending()
            } else if pendingWork == nil {
                // Relay just went away — wait out the grace period before reacting.
                scheduleGraceCheck()
            }

        case .engaging:
            // Evaluate the account we actually put the proxy on, not the selected one.
            guard let ctx = managedContext() else { mode = .direct; cancelPending(); return }
            if relayIsUp(ctx) {
                mode = .engaged
                if let id = managedAccountId { setEngaged(true, id) }
                triesInRound = 0
                scheduleDirectRecheck()
            }
            // else: the rotate timer will move on to the next candidate.

        case .engaged:
            guard let ctx = managedContext() else { mode = .direct; cancelPending(); return }
            if relayIsUp(ctx) {
                // If we were waiting out a transient drop and it recovered on its
                // own, resume normal direct-recheck monitoring.
                if engagedDropPending {
                    scheduleDirectRecheck()
                }
            } else if !engagedDropPending {
                // Don't tear IO down immediately: brief blips (Wi-Fi<->cellular
                // handover, short reconnect) recover by themselves within the grace
                // period, and an immediate restartIO would needlessly interrupt
                // traffic. Only rotate if still down after the grace period.
                scheduleEngagedDropCheck()
            }
        }
    }

    private func managedContext() -> DcContext? {
        guard let id = managedAccountId else { return nil }
        return dcAccounts.get(id: id)
    }

    // MARK: - Scheduling

    private func cancelPending() {
        pendingWork?.cancel()
        pendingWork = nil
        engagedDropPending = false
    }

    private func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        cancelPending()
        let work = DispatchWorkItem(block: block)
        pendingWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func scheduleGraceCheck() {
        schedule(after: AutoProxy.graceSeconds) { [weak self] in
            guard let self else { return }
            self.pendingWork = nil
            self.graceExpired()
        }
    }

    private func scheduleDirectRecheck() {
        schedule(after: AutoProxy.directRecheckSeconds) { [weak self] in
            guard let self else { return }
            self.pendingWork = nil
            self.directRecheck()
        }
    }

    /// Debounce a drop while engaged: wait out the grace period, then decide whether
    /// the proxy is really dead (rotate) or the blip recovered (keep the proxy).
    private func scheduleEngagedDropCheck() {
        schedule(after: AutoProxy.graceSeconds) { [weak self] in
            guard let self else { return }
            self.pendingWork = nil
            self.engagedDropPending = false
            self.engagedDropExpired()
        }
        engagedDropPending = true
    }

    private func engagedDropExpired() {
        guard mode == .engaged, let ctx = managedContext() else { return }
        if relayIsUp(ctx) {
            // Recovered during the grace period — back to normal monitoring.
            scheduleDirectRecheck()
        } else {
            // Still down: the proxy is likely dead, move on to the next candidate.
            triesInRound = 0
            rotateToNextProxy()
        }
    }

    // MARK: - Direct -> Proxy

    private func graceExpired() {
        let selected = dcAccounts.getSelected()
        guard selected.isConfigured() else { mode = .direct; return }
        guard !relayIsUp(selected) else { return }

        // A: the core may report disconnected during transient/auth hiccups even
        // though the relay is reachable. Confirm with a direct TCP probe before
        // engaging a proxy — if the relay answers, there is nothing to route around.
        probeRelay(selected) { [weak self] relayReachable in
            guard let self else { return }
            if relayReachable {
                self.mode = .direct
                self.cancelPending()
                return
            }
            // Relay genuinely unreachable. Only engage if the internet itself works,
            // otherwise it's a general outage and proxies won't help.
            self.probeInternet { [weak self] internetReachable in
                guard let self else { return }
                guard internetReachable else { self.scheduleGraceCheck(); return }
                self.managedAccountId = selected.id
                self.triesInRound = 0
                self.currentProxyIndex = Int.random(in: 0..<max(AutoProxy.proxyURLs.count, 1))
                self.engageCurrentProxy()
            }
        }
    }

    /// B: TCP-probe the candidate proxy before committing the account to it, so we
    /// never set `isProxyEnabled = true` + `restartIO()` on a dead proxy.
    private func engageCurrentProxy() {
        guard !AutoProxy.proxyURLs.isEmpty, let id = managedAccountId else { return }
        let candidate = AutoProxy.proxyURLs[currentProxyIndex % AutoProxy.proxyURLs.count]

        guard let (host, port) = Self.proxyHostPort(candidate) else {
            rotateToNextProxy()
            return
        }
        probeTCP(host: host, port: port) { [weak self] alive in
            guard let self else { return }
            guard alive else {
                logger.info("autoproxy: candidate #\(self.currentProxyIndex) unreachable, skipping")
                self.rotateToNextProxy()
                return
            }
            self.commitProxy(candidate, accountId: id)
        }
    }

    /// Merge the bundled proxies into the account's proxy list (preserving the
    /// user's own entries), put the current candidate first, enable the proxy and
    /// restart IO. deltachat-core only uses the first line of `proxy_url`.
    private func commitProxy(_ candidate: String, accountId id: Int) {
        let ctx = dcAccounts.get(id: id)
        var list = ctx.getProxies().filter { !$0.isEmpty }
        // Ensure all bundled proxies are present.
        for url in AutoProxy.proxyURLs where !list.contains(url) {
            list.append(url)
        }
        // Move the candidate to the front so the core actually uses it.
        list.removeAll { $0 == candidate }
        list.insert(candidate, at: 0)

        ctx.setProxies(proxyURLs: list)
        ctx.isProxyEnabled = true
        setEngaged(true, id)
        dcAccounts.restartIO()

        mode = .engaging
        logger.info("autoproxy: engaging proxy #\(currentProxyIndex) on account \(id)")

        // Give this candidate a chance; rotate on timeout.
        schedule(after: AutoProxy.proxyTrySeconds) { [weak self] in
            guard let self else { return }
            self.pendingWork = nil
            self.proxyTryTimedOut()
        }
    }

    private func proxyTryTimedOut() {
        guard let ctx = managedContext() else { mode = .direct; return }
        if relayIsUp(ctx) {
            // Connected in the meantime.
            mode = .engaged
            triesInRound = 0
            scheduleDirectRecheck()
            return
        }
        rotateToNextProxy()
    }

    private func rotateToNextProxy() {
        triesInRound += 1
        if triesInRound >= AutoProxy.proxyURLs.count {
            // Tried every proxy without success. B: don't sit on a dead proxy —
            // revert to direct, then back off before starting a fresh round.
            triesInRound = 0
            logger.info("autoproxy: all proxies failed, reverting to direct and backing off")
            if let id = managedAccountId { disengageAccount(id) }
            managedAccountId = nil
            mode = .direct
            schedule(after: AutoProxy.backoffSeconds) { [weak self] in
                guard let self else { return }
                self.pendingWork = nil
                self.graceExpired()
            }
            return
        }
        currentProxyIndex = (currentProxyIndex + 1) % AutoProxy.proxyURLs.count
        engageCurrentProxy()
    }

    // MARK: - Proxy -> Direct

    /// C: re-probe the relay of *every* engaged account (not just the selected one)
    /// so a proxy we turned on for a background account is still reverted once its
    /// relay is reachable again.
    private func directRecheck() {
        guard mode == .engaged else { return }
        let engaged = dcAccounts.getAll().filter { isEngaged($0) }
        guard !engaged.isEmpty else { mode = .direct; cancelPending(); return }

        recheckAccounts(engaged) { [weak self] in
            guard let self else { return }
            if self.dcAccounts.getAll().contains(where: { self.isEngaged($0) }) {
                self.scheduleDirectRecheck()
            } else {
                self.mode = .direct
                self.cancelPending()
            }
        }
    }

    /// Sequentially probe each account's relay directly; disengage the ones that answer.
    private func recheckAccounts(_ ids: [Int], completion: @escaping () -> Void) {
        var remaining = ids
        func step() {
            guard let id = remaining.popLast() else { completion(); return }
            probeRelay(dcAccounts.get(id: id)) { [weak self] reachable in
                guard let self else { return }
                if reachable { self.disengageAccount(id) }
                step()
            }
        }
        step()
    }

    private func disengageAccount(_ id: Int) {
        let ctx = dcAccounts.get(id: id)
        ctx.isProxyEnabled = false
        setEngaged(false, id)
        if managedAccountId == id { managedAccountId = nil }
        dcAccounts.restartIO()
        logger.info("autoproxy: relay reachable for account \(id), reverting to direct")
    }

    // MARK: - Probes

    /// HTTP 204 probe to confirm the internet works (not just the local interface).
    private func probeInternet(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: AutoProxy.internetProbeURL) else {
            queue.async { completion(false) }
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = AutoProxy.probeTimeoutSeconds
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: url) { [weak self] _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse) != nil
            session.invalidateAndCancel()
            self?.queue.async { completion(ok) }
        }
        task.resume()
    }

    /// Direct TCP connect to an account's relay (bypassing any proxy) to detect
    /// reachability. Completes `false` if the account isn't configured.
    private func probeRelay(_ ctx: DcContext, completion: @escaping (Bool) -> Void) {
        guard ctx.isConfigured(),
              let host = ctx.getConfig("configured_mail_server"),
              case let port = ctx.getConfigInt("configured_mail_port"),
              port > 0
        else {
            queue.async { completion(false) }
            return
        }
        probeTCP(host: host, port: UInt16(port), completion: completion)
    }

    /// Raw TCP connect, bypassing any HTTP proxy. Used both to probe relays and to
    /// health-check proxy candidates.
    private func probeTCP(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            queue.async { completion(false) }
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        var finished = false
        let finish: (Bool) -> Void = { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !finished else { return }
                finished = true
                connection.cancel()
                completion(result)
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + AutoProxy.probeTimeoutSeconds) { finish(false) }
    }

    /// Extract host/port from a `http://user:password@host:port` proxy URL.
    private static func proxyHostPort(_ urlString: String) -> (String, UInt16)? {
        guard let comps = URLComponents(string: urlString),
              let host = comps.host,
              let port = comps.port,
              port > 0, port <= 65535
        else { return nil }
        return (host, UInt16(port))
    }
}
