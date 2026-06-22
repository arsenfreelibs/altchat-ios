import Foundation
import Network
import DcCore

/// Automatically engages a bundled HTTP proxy when our relay is blocked but the
/// internet still works, and reverts to a direct connection once the relay is
/// reachable again.
///
/// State machine (all transitions happen on `queue`):
/// - `.direct`:   proxy off, watching the relay. If it stays disconnected for
///                `graceSeconds` while the internet is reachable -> engage proxy.
/// - `.engaging`: we turned a proxy on and are waiting for it to connect. Each
///                candidate gets `proxyTrySeconds`; on timeout we rotate.
/// - `.engaged`:  proxy connected. We re-probe the relay directly every
///                `directRecheckSeconds`; once it answers we revert to direct.
///
/// We only ever touch the proxy configuration that we set ourselves (tracked via
/// `engagedKey`). A proxy enabled manually by the user is left untouched.
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

    private static let engagedKey = "autoProxyEngaged"

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

            // Resume monitoring for relay recovery if we engaged a proxy in a previous run.
            if UserDefaults.standard.bool(forKey: Self.engagedKey) {
                self.mode = .engaged
                self.scheduleDirectRecheck()
            }
            self.onConnectivity()
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
        let dcContext = dcAccounts.getSelected()
        guard dcContext.isConfigured() else {
            cancelPending()
            mode = .direct
            return
        }

        // Respect a proxy the user enabled manually: only act when proxy is off
        // or when the active proxy is the one we engaged.
        let weEngaged = UserDefaults.standard.bool(forKey: Self.engagedKey)
        if dcContext.isProxyEnabled && !weEngaged {
            cancelPending()
            mode = .direct
            return
        }

        let connected = relayIsUp(dcContext)

        switch mode {
        case .direct:
            if connected {
                cancelPending()
            } else if pendingWork == nil {
                // Relay just went away — wait out the grace period before reacting.
                scheduleGraceCheck()
            }

        case .engaging:
            if connected {
                // Current candidate works.
                mode = .engaged
                UserDefaults.standard.set(true, forKey: Self.engagedKey)
                triesInRound = 0
                scheduleDirectRecheck()
            }
            // else: the rotate timer will move on to the next candidate.

        case .engaged:
            if !connected {
                // Proxy stopped working — start trying candidates again.
                triesInRound = 0
                rotateToNextProxy()
            }
        }
    }

    // MARK: - Scheduling

    private func cancelPending() {
        pendingWork?.cancel()
        pendingWork = nil
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

    // MARK: - Direct -> Proxy

    private func graceExpired() {
        let dcContext = dcAccounts.getSelected()
        guard dcContext.isConfigured() else { mode = .direct; return }
        guard !relayIsUp(dcContext) else { return }

        // Relay still unreachable. Only engage a proxy if the internet itself works,
        // otherwise it's a general outage and proxies won't help.
        probeInternet { [weak self] internetReachable in
            guard let self else { return }
            if internetReachable {
                self.triesInRound = 0
                self.currentProxyIndex = Int.random(in: 0..<max(AutoProxy.proxyURLs.count, 1))
                self.engageCurrentProxy()
            } else {
                // No internet yet; re-check after the grace period.
                self.scheduleGraceCheck()
            }
        }
    }

    /// Merge the bundled proxies into the account's proxy list (preserving the
    /// user's own entries), put the current candidate first, enable the proxy and
    /// restart IO. deltachat-core only uses the first line of `proxy_url`.
    private func engageCurrentProxy() {
        guard !AutoProxy.proxyURLs.isEmpty else { return }
        let dcContext = dcAccounts.getSelected()
        let candidate = AutoProxy.proxyURLs[currentProxyIndex % AutoProxy.proxyURLs.count]

        var list = dcContext.getProxies().filter { !$0.isEmpty }
        // Ensure all bundled proxies are present.
        for url in AutoProxy.proxyURLs where !list.contains(url) {
            list.append(url)
        }
        // Move the candidate to the front so the core actually uses it.
        list.removeAll { $0 == candidate }
        list.insert(candidate, at: 0)

        dcContext.setProxies(proxyURLs: list)
        dcContext.isProxyEnabled = true
        UserDefaults.standard.set(true, forKey: Self.engagedKey)
        dcAccounts.restartIO()

        mode = .engaging
        logger.info("autoproxy: engaging proxy #\(currentProxyIndex)")

        // Give this candidate a chance; rotate on timeout.
        schedule(after: AutoProxy.proxyTrySeconds) { [weak self] in
            guard let self else { return }
            self.pendingWork = nil
            self.proxyTryTimedOut()
        }
    }

    private func proxyTryTimedOut() {
        let dcContext = dcAccounts.getSelected()
        if relayIsUp(dcContext) {
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
            // Tried every proxy without success — back off, then start a fresh round.
            triesInRound = 0
            logger.info("autoproxy: all proxies failed, backing off")
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

    private func directRecheck() {
        let dcContext = dcAccounts.getSelected()
        guard mode == .engaged else { return }
        guard dcContext.isConfigured(),
              let host = dcContext.getConfig("configured_mail_server"),
              case let port = dcContext.getConfigInt("configured_mail_port"),
              port > 0
        else {
            scheduleDirectRecheck()
            return
        }

        // Probe the relay directly (NWConnection does not go through the HTTP proxy).
        probeRelayDirect(host: host, port: UInt16(port)) { [weak self] reachable in
            guard let self else { return }
            if reachable {
                self.disengageProxy()
            } else {
                self.scheduleDirectRecheck()
            }
        }
    }

    private func disengageProxy() {
        let dcContext = dcAccounts.getSelected()
        dcContext.isProxyEnabled = false
        UserDefaults.standard.set(false, forKey: Self.engagedKey)
        dcAccounts.restartIO()
        mode = .direct
        cancelPending()
        logger.info("autoproxy: relay reachable again, reverting to direct")
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

    /// Raw TCP connect to the relay, bypassing any proxy, to detect recovery.
    private func probeRelayDirect(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
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
}
