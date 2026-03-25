import Foundation
import CryptoKit
import DcCore

/// Manages typing indicators and online presence over the Webxdc Realtime API.
///
/// **Protocol** — 7-byte binary packets:
/// - bytes[0..1]: magic `0xDC 0x54` — distinguishes our packets from Maps XDC data
/// - byte[2]: type — `0` = stopped, `1` = typing, `2` = online heartbeat, `3` = going offline
/// - bytes[3..6]: first 4 bytes of SHA-256(email UTF-8), little-endian UInt32
///
/// This reuses the per-chat Maps integration message as the realtime channel.
/// Maps persist their state via status updates, while our typing/presence data
/// travels as ephemeral realtime bytes — the two systems are fully independent.
///
/// The channel is obtained via `initWebxdcIntegration(for: chatId)`. This call is
/// per-chat and idempotent: it creates a Maps message in the chat on first call,
/// and returns the same msgId on subsequent calls. The side-effect (creating a
/// Maps message) only occurs once per chat and only if a global integration XDC
/// has been set (i.e. the user has ever opened Maps in any chat). Chats where Maps
/// was never used will not have an integration message created until the user
/// opens Maps in that chat or TypingManager joins it first.
final class TypingManager {
    static let shared = TypingManager()

    private init() {
        // Schedule on main run loop explicitly: the singleton may be first accessed
        // from a background thread, but Timer requires a run loop to fire.
        DispatchQueue.main.async { [self] in
            startStalePresenceTimer()
        }
        // Subscribe permanently so typing packets are processed even when no chat screen
        // is open (e.g. the user is on the chat list). ChatViewController no longer needs
        // to forward this event.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRealtimeDataNotification(_:)),
            name: Event.webxdcRealtimeDataReceived,
            object: nil
        )
    }

    @objc private func handleRealtimeDataNotification(_ notification: Notification) {
        guard let ui = notification.userInfo,
              let msgId = ui["message_id"] as? Int,
              let data = ui["data"] as? Data else { return }
        // The C event handler posts on a background thread; TypingManager requires main thread.
        DispatchQueue.main.async { [weak self] in
            self?.handleRealtimeData(msgId: msgId, data: data)
        }
    }

    // MARK: - Protocol constants

    private static let magic0: UInt8 = 0xDC
    private static let magic1: UInt8 = 0x54  // 'T'

    private static let typeStopped:    UInt8 = 0
    private static let typeTyping:     UInt8 = 1
    private static let typeHeartbeat:  UInt8 = 2
    private static let typeOffline:    UInt8 = 3

    private static let heartbeatInterval: TimeInterval = 30
    private static let presenceTTL:       TimeInterval = 90  // 3 missed heartbeats
    private static let typingThrottle:    TimeInterval = 2
    private static let typingStopDelay:   TimeInterval = 3

    // MARK: - Notifications

    /// Posted on main thread whenever typing state changes in a chat.
    /// userInfo: ["chatId": Int]
    static let typingChangedNotification = Notification.Name("typingManagerTypingChanged")

    /// Posted on main thread when any contact's online status changes.
    static let onlineStatusChangedNotification = Notification.Name("typingManagerOnlineStatusChanged")

    // MARK: - State (main thread only)

    /// chatId → integration msgId (cached after first lookup)
    private var chatIntegrationMsgId: [Int: Int] = [:]

    /// chatId → set of contactIds currently typing
    private var typingContactIds: [Int: Set<Int>] = [:]

    /// chatId → contactId → Date of the most-recent typeTyping packet; used to guard the auto-clear asyncAfter.
    private var typingLastSeen: [Int: [Int: Date]] = [:]

    /// contactId → date of last heartbeat received
    private var heartbeatDates: [Int: Date] = [:]

    /// contactIds that are considered online right now
    private(set) var onlineContactIds: Set<Int> = []

    /// chatId → [SHA-256-fingerprint → contactId]; rebuilt asynchronously on joinChat
    private var fingerprintCache: [Int: [UInt32: Int]] = [:]

    private var currentChatId: Int?
    private weak var currentDcContext: DcContext?
    /// Account ID of the last context passed to joinChat; used to detect account switches.
    private var currentAccountId: Int?

    /// Cached SHA-256 fingerprint of own email, refreshed on joinChat.
    private var selfFingerprint: UInt32?

    private var typingStopTimer: Timer?
    private var heartbeatTimer: Timer?
    private var stalePresenceTimer: Timer?

    private var lastTypingSentTime: Date?
    /// Set to `true` when `textDidChange` is called before the async msgId lookup completes.
    /// Flushed as a single typing packet once `setupRealtime` stores the msgId.
    private var pendingTypingSend: Bool = false
    /// Typing packets received before `fingerprintCache` was ready; flushed once the cache is built.
    private var pendingIncomingPackets: [(msgId: Int, data: Data)] = []

    // MARK: - Public API

    /// Call from `viewDidAppear` when user opens a chat.
    func joinChat(chatId: Int, dcContext: DcContext) {
        assert(Thread.isMainThread)

        // Flush all per-account caches when the user has switched accounts so that
        // contact IDs from one account are never confused with another account's.
        let accountId = dcContext.id
        if currentAccountId != accountId {
            currentAccountId = accountId
            chatIntegrationMsgId.removeAll()
            fingerprintCache.removeAll()
            typingContactIds.removeAll()
            heartbeatDates.removeAll()
            onlineContactIds.removeAll()
            pendingTypingSend = false
            pendingIncomingPackets.removeAll()
        }

        // Reset presence state when switching to a different chat: the new chat has its own
        // realtime channel and we won't receive typeOffline packets from the previous chat's peers.
        if currentChatId != chatId {
            onlineContactIds.removeAll()
            heartbeatDates.removeAll()
            pendingIncomingPackets.removeAll()
        }

        currentChatId = chatId
        currentDcContext = dcContext
        // Always refresh: email changes in the new account session.
        selfFingerprint = Self.fingerprint(of: dcContext.getContact(id: Int(DC_CONTACT_ID_SELF)).email)

        // Always reset typing state on join: when returning from a sub-screen we may have
        // missed typeStopped packets (the observer was removed while the sub-screen was open).
        // Typing is ephemeral — if a peer is still typing they will resend within 2 seconds.
        typingContactIds[chatId] = []

        // Build fingerprint→contactId lookup cache asynchronously to avoid FFI on main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let contactIds = dcContext.getChat(chatId: chatId).getContactIds(dcContext)
            var map: [UInt32: Int] = [:]
            for contactId in contactIds where contactId != Int(DC_CONTACT_ID_SELF) {
                let email = dcContext.getContact(id: contactId).email
                // Known limitation: 32-bit truncated SHA-256 has a negligible but non-zero
                // collision probability (~0.0005% for 200-member groups). On collision the
                // last contactId iterated wins and typing may be attributed to the wrong person.
                map[Self.fingerprint(of: email)] = contactId
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentChatId == chatId else { return }
                self.fingerprintCache[chatId] = map
                // Flush packets that arrived while the cache was being built.
                let buffered = self.pendingIncomingPackets
                self.pendingIncomingPackets.removeAll()
                for packet in buffered {
                    self.handleRealtimeData(msgId: packet.msgId, data: packet.data)
                }
            }
        }

        setupRealtime(chatId: chatId, dcContext: dcContext)

        if UserDefaults.standard.bool(forKey: UserDefaults.onlineStatusEnabledKey) {
            startHeartbeat(chatId: chatId, dcContext: dcContext)
        }
    }

    /// Call when user leaves a chat (navigating back or app resigning active).
    func leaveChat(chatId: Int, dcContext: DcContext) {
        assert(Thread.isMainThread)
        // Send stop-typing immediately if we were actively typing (don't wait for the debounce timer).
        if lastTypingSentTime != nil {
            sendStopTyping(chatId: chatId, dcContext: dcContext)
        }
        // Notify peers that we're going offline immediately, rather than making them wait
        // up to presenceTTL (90 s) for our heartbeat to expire.
        if UserDefaults.standard.bool(forKey: UserDefaults.onlineStatusEnabledKey) {
            sendOfflinePacket(chatId: chatId, dcContext: dcContext)
        }
        stopTypingTimers()
        pendingTypingSend = false
        pendingIncomingPackets.removeAll()
        typingContactIds.removeValue(forKey: chatId)
        typingLastSeen.removeValue(forKey: chatId)
        fingerprintCache.removeValue(forKey: chatId)
        currentChatId = nil
        currentDcContext = nil
        selfFingerprint = nil
        // chatIntegrationMsgId is intentionally kept: avoid redundant FFI on re-join and,
        // more importantly, avoid disrupting Maps if it is reusing the same realtime channel.
        // The core stops routing data to us once we stop advertising; no explicit leave needed.
    }

    /// Call from `viewDidDisappear` when a sub-screen (ChatInfo, SharedMedia, …) is pushed
    /// onto the navigation stack — i.e. when the chat view disappears but the user has NOT
    /// left the chat. Stops typing/heartbeat timers and discards any pending unsent typing
    /// packet so stale data is never sent while the view is invisible.
    /// `joinChat` re-establishes everything when the user returns (`viewDidAppear`).
    func suspendTimers() {
        assert(Thread.isMainThread)
        stopTypingTimers()
        pendingTypingSend = false
    }

    /// Call from `inputBar(_:textViewTextDidChangeTo:)` after each keystroke.
    func textDidChange(chatId: Int, dcContext: DcContext) {
        assert(Thread.isMainThread)

        // Reschedule the stop-typing timer
        typingStopTimer?.invalidate()
        typingStopTimer = Timer.scheduledTimer(
            withTimeInterval: Self.typingStopDelay, repeats: false
        ) { [weak self] _ in
            // Cancel any pending unsent typing packet: the user has stopped typing.
            self?.pendingTypingSend = false
            self?.sendStopTyping(chatId: chatId, dcContext: dcContext)
        }

        // Throttle actual [1,...] sends to once per 2 seconds
        let now = Date()
        if let last = lastTypingSentTime, now.timeIntervalSince(last) < Self.typingThrottle {
            return
        }
        lastTypingSentTime = now

        guard let msgId = chatIntegrationMsgId[chatId] else {
            // msgId not yet known (async setup in flight). Record intent; setupRealtime will flush it.
            pendingTypingSend = true
            return
        }
        let packet = makePacket(type: Self.typeTyping)
        DispatchQueue.global(qos: .utility).async {
            dcContext.sendWebxdcRealtimeData(messageId: msgId, uint8Array: packet)
        }
    }

    /// Call from `ChatsAndMediaViewController` when the online status toggle changes.
    func onlineStatusSettingChanged() {
        assert(Thread.isMainThread)
        let enabled = UserDefaults.standard.bool(forKey: UserDefaults.onlineStatusEnabledKey)
        if enabled, let chatId = currentChatId, let dcContext = currentDcContext {
            startHeartbeat(chatId: chatId, dcContext: dcContext)
            // Send immediately — without this the first heartbeat would only arrive 30 s later.
            if let msgId = chatIntegrationMsgId[chatId], let fp = selfFingerprint {
                DispatchQueue.global(qos: .utility).async {
                    Self.sendHeartbeatPacket(dcContext: dcContext, msgId: msgId, fp: fp)
                }
            }
        } else if !enabled {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            // Tell peers we're offline now — don't make them wait for the TTL to expire.
            if let chatId = currentChatId, let dcContext = currentDcContext {
                sendOfflinePacket(chatId: chatId, dcContext: dcContext)
            }
            // Clear our view of others' online state: with mutual opt-in, we should not
            // display contacts as online when we are not broadcasting our own presence.
            onlineContactIds.removeAll()
            heartbeatDates.removeAll()
            // Notify observers (ContactsViewController, ChatViewController) to clear badges.
            NotificationCenter.default.post(name: Self.onlineStatusChangedNotification, object: nil)
        }
    }

    /// Call from the `Event.webxdcRealtimeDataReceived` observer. Must be called on the main thread.
    func handleRealtimeData(msgId: Int, data: Data) {
        assert(Thread.isMainThread)
        // Validate magic prefix — rejects Maps XDC and any other unknown payloads.
        guard data.count >= 7,
              data[0] == Self.magic0,
              data[1] == Self.magic1 else { return }
        // Each chat has its own integration msgId; match against the
        // current chat's cached entry rather than doing a dict reverse-lookup (which
        // could return a stale chatId from a previously visited chat).
        guard let chatId = currentChatId,
              chatIntegrationMsgId[chatId] == msgId else { return }
        guard currentDcContext != nil else { return }
        guard let selfFp = selfFingerprint else { return }

        let type = data[2]
        let fp = UInt32(data[3])
            | (UInt32(data[4]) << 8)
            | (UInt32(data[5]) << 16)
            | (UInt32(data[6]) << 24)

        // Ignore packets from ourselves
        if fp == selfFp { return }

        // Buffer if the fingerprint→contactId cache is not yet ready (async build in flight).
        // The packet will be replayed once joinChat's background task completes.
        guard fingerprintCache[chatId] != nil else {
            pendingIncomingPackets.append((msgId: msgId, data: data))
            return
        }

        guard let contactId = resolveFingerprint(fp, chatId: chatId) else { return }

        switch type {
        case Self.typeTyping:
            let now = Date()
            typingLastSeen[chatId, default: [:]][contactId] = now
            var set = typingContactIds[chatId] ?? []
            let inserted = set.insert(contactId).inserted
            typingContactIds[chatId] = set
            if inserted { NotificationCenter.default.post(name: Self.typingChangedNotification, object: nil, userInfo: ["chatId": chatId]) }
            // Auto-clear after 6 s only if no newer typing packet has arrived since this one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self,
                      self.typingLastSeen[chatId]?[contactId] == now else { return }
                self.typingLastSeen[chatId]?.removeValue(forKey: contactId)
                var s = self.typingContactIds[chatId] ?? []
                if s.remove(contactId) != nil {
                    self.typingContactIds[chatId] = s
                    NotificationCenter.default.post(name: Self.typingChangedNotification, object: nil, userInfo: ["chatId": chatId])
                }
            }

        case Self.typeStopped:
            var set = typingContactIds[chatId] ?? []
            if set.remove(contactId) != nil {
                typingContactIds[chatId] = set
                NotificationCenter.default.post(name: Self.typingChangedNotification, object: nil, userInfo: ["chatId": chatId])
            }

        case Self.typeHeartbeat:
            // Mutual opt-in: only show contacts as online when we're also broadcasting our own status.
            guard UserDefaults.standard.bool(forKey: UserDefaults.onlineStatusEnabledKey) else { break }
            let wasOnline = onlineContactIds.contains(contactId)
            heartbeatDates[contactId] = Date()
            onlineContactIds.insert(contactId)
            if !wasOnline {
                NotificationCenter.default.post(name: Self.onlineStatusChangedNotification, object: nil)
            }

        case Self.typeOffline:
            heartbeatDates.removeValue(forKey: contactId)
            if onlineContactIds.remove(contactId) != nil {
                NotificationCenter.default.post(name: Self.onlineStatusChangedNotification, object: nil)
            }

        default:
            break
        }
    }

    /// Returns `true` if a heartbeat from this contact was received within `presenceTTL`.
    func isOnline(contactId: Int) -> Bool {
        return onlineContactIds.contains(contactId)
    }

    /// Returns the current set of contact IDs typing in the given chat.
    /// Used by `ChatViewController.viewDidAppear` to seed local state after returning from a sub-screen.
    func typingContacts(for chatId: Int) -> Set<Int> {
        return typingContactIds[chatId] ?? []
    }

    // MARK: - Private helpers

    private func setupRealtime(chatId: Int, dcContext: DcContext) {
        // If already cached, just advertise
        if let msgId = chatIntegrationMsgId[chatId], msgId != 0 {
            let sendHeartbeat = UserDefaults.standard.bool(forKey: UserDefaults.onlineStatusEnabledKey)
            let fp = selfFingerprint  // capture on main thread before background dispatch
            DispatchQueue.global(qos: .utility).async {
                dcContext.sendWebxdcRealtimeAdvertisement(messageId: msgId)
                if sendHeartbeat, let fp {
                    Self.sendHeartbeatPacket(dcContext: dcContext, msgId: msgId, fp: fp)
                }
            }
            return
        }

        let sendHeartbeat = UserDefaults.standard.bool(forKey: UserDefaults.onlineStatusEnabledKey)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // initWebxdcIntegration is idempotent per chat: returns the same msgId on
            // repeated calls. Returns 0 if no global integration XDC has been set yet
            // (i.e. Maps was never opened). Register the bundled maps XDC if needed so
            // that typing works even on a fresh install before the user opens Maps.
            var msgId = dcContext.initWebxdcIntegration(for: chatId)
            if msgId == 0,
               let mapsXdc = Bundle.main.url(forResource: "maps", withExtension: "xdc", subdirectory: "Assets") {
                dcContext.setWebxdcIntegration(filepath: mapsXdc.path)
                msgId = dcContext.initWebxdcIntegration(for: chatId)
            }
            guard msgId != 0 else { return }

            DispatchQueue.main.async { [weak self] in
                // Guard against the user having already left before we finished the async lookup.
                guard let self, self.currentChatId == chatId else { return }
                self.chatIntegrationMsgId[chatId] = msgId

                // Flush any typing packet that arrived while the msgId was unknown,
                // but only if the user is still actively typing (stop timer hasn't fired yet).
                let flushTyping = self.pendingTypingSend
                if flushTyping { self.pendingTypingSend = false }

                let fp = self.selfFingerprint  // capture on main thread before background dispatch
                DispatchQueue.global(qos: .utility).async {
                    dcContext.sendWebxdcRealtimeAdvertisement(messageId: msgId)
                    if flushTyping {
                        let packet = Self.makePacketBackground(type: Self.typeTyping, fp: fp)
                        dcContext.sendWebxdcRealtimeData(messageId: msgId, uint8Array: packet)
                    }
                    if sendHeartbeat, let fp {
                        Self.sendHeartbeatPacket(dcContext: dcContext, msgId: msgId, fp: fp)
                    }
                }
            }
        }
    }

    private func startHeartbeat(chatId: Int, dcContext: DcContext) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.heartbeatInterval, repeats: true
        ) { [weak self] _ in
            // Timer fires on main thread — use currentChatId (not the captured chatId)
            // so we don't send heartbeats for a chat we've already left.
            guard let self,
                  self.currentChatId == chatId,
                  let msgId = self.chatIntegrationMsgId[chatId],
                  msgId != 0,
                  let fp = self.selfFingerprint else { return }
            DispatchQueue.global(qos: .utility).async {
                Self.sendHeartbeatPacket(dcContext: dcContext, msgId: msgId, fp: fp)
            }
        }
    }

    /// Called from a background thread — `fp` must be captured on the main thread by the caller.
    private static func sendHeartbeatPacket(dcContext: DcContext, msgId: Int, fp: UInt32) {
        let packet: [UInt8] = [
            Self.magic0, Self.magic1, Self.typeHeartbeat,
            UInt8(fp & 0xFF), UInt8((fp >> 8) & 0xFF),
            UInt8((fp >> 16) & 0xFF), UInt8((fp >> 24) & 0xFF)
        ]
        dcContext.sendWebxdcRealtimeData(messageId: msgId, uint8Array: packet)
    }

    private func sendStopTyping(chatId: Int, dcContext: DcContext) {
        lastTypingSentTime = nil
        guard let msgId = chatIntegrationMsgId[chatId], msgId != 0 else { return }
        let packet = makePacket(type: Self.typeStopped)
        DispatchQueue.global(qos: .utility).async {
            dcContext.sendWebxdcRealtimeData(messageId: msgId, uint8Array: packet)
        }
    }

    private func sendOfflinePacket(chatId: Int, dcContext: DcContext) {
        guard let msgId = chatIntegrationMsgId[chatId], msgId != 0 else { return }
        let packet = makePacket(type: Self.typeOffline)
        DispatchQueue.global(qos: .utility).async {
            dcContext.sendWebxdcRealtimeData(messageId: msgId, uint8Array: packet)
        }
    }

    /// Builds a 7-byte packet. Safe to call from any thread — `fp` is passed explicitly.
    private static func makePacketBackground(type: UInt8, fp: UInt32?) -> [UInt8] {
        let f = fp ?? 0
        return [
            Self.magic0, Self.magic1, type,
            UInt8(f & 0xFF), UInt8((f >> 8) & 0xFF),
            UInt8((f >> 16) & 0xFF), UInt8((f >> 24) & 0xFF)
        ]
    }

    /// Convenience wrapper around `makePacketBackground` that injects the cached
    /// `selfFingerprint`. Must be called on the main thread (accesses `selfFingerprint`).
    private func makePacket(type: UInt8) -> [UInt8] {
        TypingManager.makePacketBackground(type: type, fp: selfFingerprint)
    }

    private func resolveFingerprint(_ fp: UInt32, chatId: Int) -> Int? {
        // Use the pre-built cache populated on joinChat.
        // If the cache is not yet ready, drop the packet — it only affects the brief async
        // build window on joinChat and avoids calling FFI synchronously on the main thread.
        return fingerprintCache[chatId]?[fp]
    }

    private func stopTypingTimers() {
        typingStopTimer?.invalidate()
        typingStopTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        lastTypingSentTime = nil
    }

    private func startStalePresenceTimer() {
        // Interval of 30 s gives a worst-case stale-display window of TTL (90 s) + 30 s = 120 s.
        stalePresenceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.purgeStalePresence()
        }
    }

    private func purgeStalePresence() {
        assert(Thread.isMainThread)
        let cutoff = Date().addingTimeInterval(-Self.presenceTTL)
        let staleIds = heartbeatDates.compactMap { contactId, date in
            date < cutoff ? contactId : nil
        }
        for contactId in staleIds {
            heartbeatDates.removeValue(forKey: contactId)
            onlineContactIds.remove(contactId)
        }
        if !staleIds.isEmpty {
            NotificationCenter.default.post(name: Self.onlineStatusChangedNotification, object: nil)
        }
    }

    // SHA-256 fingerprint — first 4 bytes of SHA-256(email UTF-8), little-endian.
    // Much more collision-resistant than DJB2 for group chats with many members.
    private static func fingerprint(of email: String) -> UInt32 {
        let digest = SHA256.hash(data: Data(email.utf8))
        var iter = digest.makeIterator()
        let b0 = UInt32(iter.next() ?? 0)
        let b1 = UInt32(iter.next() ?? 0)
        let b2 = UInt32(iter.next() ?? 0)
        let b3 = UInt32(iter.next() ?? 0)
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
