import Foundation
import Security
import CommonCrypto
import LocalAuthentication

/// Global, account-independent passcode lock.
///
/// Stores only a PBKDF2 hash + random salt in the Keychain (no plaintext). Holds the
/// runtime lock state for the process and the auto-lock / lockout bookkeeping.
///
/// UI (lock screen, setup, settings) and app-lifecycle wiring live in separate types;
/// this class is pure logic so it can be unit-tested in isolation.
///
/// See `docs/DESIGN.ios.md` for the rationale behind the storage and timing choices.
public final class PasscodeManager {

    public static let shared = PasscodeManager()

    private init() {}

    // MARK: - Constants

    /// Fixed passcode length (digits).
    public static let passcodeLength = 4

    private static let pbkdf2Iterations = 120_000
    private static let pbkdf2KeyLength = 32 // 256 bit
    private static let saltLength = 16

    /// After this many consecutive failures the progressive lockout kicks in.
    public static let lockoutAfterAttempts = 5
    private static let lockoutStepSeconds: TimeInterval = 30
    private static let lockoutMaxSeconds: TimeInterval = 30 * 60

    // MARK: - Auto-lock options

    /// Auto-lock delay in seconds. `disabled` means lock only on cold start / lock button.
    public enum AutoLock: Int, CaseIterable {
        case disabled = -1
        case oneMinute = 60
        case fiveMinutes = 300
        case oneHour = 3600
        case fiveHours = 18000

        public static let defaultValue: AutoLock = .oneHour
    }

    // MARK: - UserDefaults keys (non-secret settings)

    private enum Key {
        static let autoLock = "passcode_autolock_seconds"
        static let biometricEnabled = "passcode_biometric_enabled"
        static let biometricDomainState = "passcode_biometric_domain_state"
        static let failedAttempts = "passcode_failed_attempts"
        static let lockoutDeadlineUptime = "passcode_lockout_deadline_uptime"
        static let lockoutBootRef = "passcode_lockout_boot_ref"
    }

    /// App-level defaults — the passcode and its settings are not needed by app extensions.
    private var defaults: UserDefaults { UserDefaults.standard }

    // MARK: - Keychain item

    private let keychainService = "alt_passcode"
    private let keychainAccount = "alt_passcode_v1"
    // The app's application-identifier keychain group (always implicitly accessible). Must be set
    // EXPLICITLY: with no access group, items default into the first `keychain-access-groups`
    // entry (the shared `group.me.alt.chat`), where KeychainManager.deleteDBSecrets() would wipe
    // them on reinstall. This app-private group isolates the passcode from extensions and that wipe.
    private let keychainAccessGroup = "U97T6JQUY7.me.alt.chat"

    // MARK: - Runtime lock state (process-level)

    private var locked = false
    private var didFirstForegroundCheck = false
    private var backgroundedAtUptime: TimeInterval?

    // MARK: - Public state

    /// Whether a passcode is set up.
    public var isEnabled: Bool {
        return loadStoredHash() != nil
    }

    /// Whether the app is currently locked and must show the lock screen.
    public var isLocked: Bool {
        return locked
    }

    public var autoLock: AutoLock {
        get {
            if let raw = defaults.object(forKey: Key.autoLock) as? Int,
               let value = AutoLock(rawValue: raw) {
                return value
            }
            return .defaultValue
        }
        set { defaults.set(newValue.rawValue, forKey: Key.autoLock) }
    }

    // MARK: - Biometric unlock

    /// User preference (raw). Use `canUseBiometricUnlock` to decide whether to actually offer it.
    public var isBiometricEnabled: Bool {
        defaults.bool(forKey: Key.biometricEnabled)
    }

    /// Whether the device has usable, enrolled biometrics. Controls the settings toggle visibility.
    public var isBiometryAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Face ID / Touch ID / none — for labelling the settings toggle and lock-screen key.
    public var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    /// Whether biometric unlock should be offered now: enabled by the user, available, and the
    /// enrolled biometrics have not changed since the user opted in.
    public var canUseBiometricUnlock: Bool {
        guard isEnabled, isBiometricEnabled else { return false }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        return domainStateMatches(context)
    }

    /// Enable/disable biometric unlock. Enabling pins the current biometry enrolment so a later
    /// change (added face/finger) invalidates it and forces the passcode again.
    public func setBiometricEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.biometricEnabled)
        if enabled {
            let context = LAContext()
            _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            defaults.set(context.evaluatedPolicyDomainState, forKey: Key.biometricDomainState)
        } else {
            defaults.removeObject(forKey: Key.biometricDomainState)
        }
    }

    /// If the enrolled biometrics changed since opt-in, turn biometric unlock off so the user must
    /// re-enable it deliberately (and re-pin the new enrolment).
    public func invalidateBiometricIfEnrolmentChanged() {
        guard isBiometricEnabled else { return }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return }
        if !domainStateMatches(context) {
            setBiometricEnabled(false)
        }
    }

    /// Prompt for biometric authentication. `completion(true)` means the user is verified.
    public func authenticateWithBiometrics(reason: String, completion: @escaping (Bool) -> Void) {
        guard canUseBiometricUnlock else { completion(false); return }
        let context = LAContext()
        context.localizedCancelTitle = String.localized("passcode_use_pin")
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    private func domainStateMatches(_ context: LAContext) -> Bool {
        let stored = defaults.data(forKey: Key.biometricDomainState)
        return stored == context.evaluatedPolicyDomainState
    }

    // MARK: - Setup / change / disable

    /// Sets (or replaces) the passcode. Clears any lockout/attempt state.
    /// - Returns: `true` on success.
    @discardableResult
    public func setPasscode(_ passcode: String) -> Bool {
        guard let salt = Self.randomBytes(count: Self.saltLength),
              let hash = Self.pbkdf2(passcode: passcode, salt: salt) else {
            return false
        }
        var blob = Data()
        blob.append(salt)
        blob.append(hash)
        let stored = storeBlob(blob)
        if stored {
            resetAttempts()
        }
        return stored
    }

    /// Constant-time check of `passcode` against the stored hash.
    public func verify(_ passcode: String) -> Bool {
        guard let blob = loadStoredHash(), blob.count == Self.saltLength + Self.pbkdf2KeyLength else {
            return false
        }
        let salt = blob.prefix(Self.saltLength)
        let storedHash = blob.suffix(Self.pbkdf2KeyLength)
        guard let candidate = Self.pbkdf2(passcode: passcode, salt: Data(salt)) else { return false }
        return Self.constantTimeEquals(Data(storedHash), candidate)
    }

    /// Disables the passcode and clears all related state.
    public func disable() {
        deleteBlob()
        resetAttempts()
        locked = false
        defaults.removeObject(forKey: Key.biometricEnabled)
        defaults.removeObject(forKey: Key.biometricDomainState)
        defaults.removeObject(forKey: Key.autoLock)
    }

    // MARK: - Lock state transitions

    /// Immediately locks the app (used by the toolbar lock button).
    public func lock() {
        guard isEnabled else { return }
        locked = true
    }

    /// Called after a successful unlock (correct passcode or biometric).
    public func didUnlock() {
        locked = false
        backgroundedAtUptime = nil
        resetAttempts()
    }

    /// Record the moment the app went to background, using monotonic uptime so it is
    /// immune to the user changing the system clock.
    public func onAppBackgrounded() {
        backgroundedAtUptime = ProcessInfo.processInfo.systemUptime
    }

    /// Decide whether the app should be locked when coming to the foreground.
    /// Mirrors the Android `shouldLockOnForeground()` logic.
    public func shouldLockOnForeground() -> Bool {
        let isColdStart = !didFirstForegroundCheck
        didFirstForegroundCheck = true

        // 2. passcode disabled -> never lock
        guard isEnabled else {
            locked = false
            return false
        }
        // 3. cold start with passcode enabled -> lock
        if isColdStart {
            locked = true
            return true
        }
        // 4. already locked -> stay locked
        if locked {
            return true
        }
        // 5. auto-lock disabled -> only lock via button / cold start
        guard autoLock != .disabled else {
            return false
        }
        // 6. lock if backgrounded for at least the timeout
        guard let backgroundedAt = backgroundedAtUptime else { return false }
        let elapsed = ProcessInfo.processInfo.systemUptime - backgroundedAt
        if elapsed >= TimeInterval(autoLock.rawValue) {
            locked = true
            return true
        }
        return false
    }

    // MARK: - Lockout (rate limiting)

    /// Registers a failed unlock attempt and arms the progressive lockout once the
    /// threshold is exceeded.
    public func registerFailedAttempt() {
        let attempts = defaults.integer(forKey: Key.failedAttempts) + 1
        defaults.set(attempts, forKey: Key.failedAttempts)

        guard attempts >= Self.lockoutAfterAttempts else { return }
        let overflow = attempts - Self.lockoutAfterAttempts // 0 on the first lockout
        let delay = min(Self.lockoutStepSeconds * TimeInterval(overflow + 1), Self.lockoutMaxSeconds)
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        defaults.set(deadline, forKey: Key.lockoutDeadlineUptime)
        defaults.set(Self.currentBootReference(), forKey: Key.lockoutBootRef)
    }

    /// Seconds the user still has to wait before another attempt is allowed, or `0`.
    ///
    /// The deadline is stored in monotonic uptime; after a device reboot uptime resets, so we
    /// pin the deadline to a boot reference and treat a mismatch as "no active lockout"
    /// (the failed-attempt counter itself survives — only the waiting window is cleared).
    public func remainingLockoutSeconds() -> TimeInterval {
        guard defaults.object(forKey: Key.lockoutDeadlineUptime) != nil else { return 0 }

        let storedBootRef = defaults.double(forKey: Key.lockoutBootRef)
        if abs(storedBootRef - Self.currentBootReference()) > Self.bootReferenceTolerance {
            // Device rebooted: the uptime-based deadline is meaningless now.
            defaults.removeObject(forKey: Key.lockoutDeadlineUptime)
            defaults.removeObject(forKey: Key.lockoutBootRef)
            return 0
        }
        let deadline = defaults.double(forKey: Key.lockoutDeadlineUptime)
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        return remaining > 0 ? remaining : 0
    }

    public var isLockedOut: Bool {
        return remainingLockoutSeconds() > 0
    }

    /// Clears the failed-attempt counter and any active lockout window.
    public func resetAttempts() {
        defaults.removeObject(forKey: Key.failedAttempts)
        defaults.removeObject(forKey: Key.lockoutDeadlineUptime)
        defaults.removeObject(forKey: Key.lockoutBootRef)
    }

    // MARK: - Boot reference

    /// Approximate wall-clock time of the last boot (now - uptime). Changes across reboots,
    /// stays roughly constant within one boot session.
    private static func currentBootReference() -> Double {
        return Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    }

    /// Clock drift tolerance (seconds) when comparing boot references.
    private static let bootReferenceTolerance: Double = 5

    // MARK: - Crypto

    private static func randomBytes(count: Int) -> Data? {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return status == errSecSuccess ? bytes : nil
    }

    private static func pbkdf2(passcode: String, salt: Data) -> Data? {
        let passwordData = Data(passcode.utf8)
        var derived = Data(count: pbkdf2KeyLength)

        let status: Int32 = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                passwordData.withUnsafeBytes { passwordPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.bindMemory(to: Int8.self).baseAddress, passwordData.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(pbkdf2Iterations),
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress, pbkdf2KeyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    /// Constant-time equality to avoid leaking timing information.
    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[lhs.startIndex + i] ^ rhs[rhs.startIndex + i]
        }
        return diff == 0
    }

    // MARK: - Keychain storage

    private func baseQuery() -> [String: Any] {
        // Pinned to an explicit app-private access group (see keychainAccessGroup) and, on write,
        // to this device only (WhenUnlockedThisDeviceOnly) so it never leaves via iCloud Keychain.
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: keychainAccessGroup,
        ]
    }

    private func storeBlob(_ blob: Data) -> Bool {
        SecItemDelete(baseQuery() as CFDictionary)
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = blob
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private func loadStoredHash() -> Data? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private func deleteBlob() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
