import UIKit
import DcCore

/// The lock screen shown inside the dedicated lock `UIWindow`. Verifies the passcode, applies the
/// progressive lockout (disabling the keypad and counting down) and reports a successful unlock.
///
/// Biometric unlock is wired in stage 2; for now the biometric key stays hidden.
class PasscodeLockViewController: PasscodeEntryViewController {

    private let manager: PasscodeManager
    private var lockoutTimer: Timer?
    private var didAutoPromptBiometric = false

    /// Called once the correct passcode or biometric unlocks the app.
    var onUnlocked: (() -> Void)?

    init(manager: PasscodeManager = .shared) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let appName = String.localized("app_name")
        setTitleText(String(format: String.localized("passcode_locked_title"), appName))
        setSubtitle(String.localized("passcode_enter_hint"))
        onCodeEntered = { [weak self] code in
            self?.handle(code: code)
        }
        manager.invalidateBiometricIfEnrolmentChanged()
        setupBiometric()
        refreshLockoutState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Auto-present the biometric prompt once when the lock screen first appears.
        if !didAutoPromptBiometric {
            didAutoPromptBiometric = true
            promptBiometric()
        }
    }

    deinit {
        lockoutTimer?.invalidate()
    }

    private func setupBiometric() {
        guard manager.canUseBiometricUnlock else {
            showsBiometricButton = false
            return
        }
        setBiometricImage(systemName: manager.biometryType == .faceID ? "faceid" : "touchid")
        showsBiometricButton = true
        onBiometricTapped = { [weak self] in self?.promptBiometric() }
    }

    private func promptBiometric() {
        guard manager.canUseBiometricUnlock, !manager.isLockedOut else { return }
        manager.authenticateWithBiometrics(reason: biometricReason) { [weak self] success in
            guard let self, success else { return }
            self.manager.didUnlock()
            self.onUnlocked?()
        }
    }

    private var biometricReason: String {
        return String(format: String.localized("passcode_unlock_biometric_reason"), String.localized("app_name"))
    }

    private func handle(code: String) {
        guard !manager.isLockedOut else {
            refreshLockoutState()
            return
        }
        if manager.verify(code) {
            manager.didUnlock()
            onUnlocked?()
        } else {
            manager.registerFailedAttempt()
            if manager.isLockedOut {
                refreshLockoutState()
            } else {
                showError(String.localized("passcode_wrong"))
            }
        }
    }

    private func refreshLockoutState() {
        lockoutTimer?.invalidate()
        guard manager.isLockedOut else {
            setKeypadEnabled(true)
            setErrorText(nil)
            return
        }
        setKeypadEnabled(false)
        updateLockoutCountdown()
        lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateLockoutCountdown()
        }
    }

    private func updateLockoutCountdown() {
        let remaining = manager.remainingLockoutSeconds()
        if remaining <= 0 {
            lockoutTimer?.invalidate()
            lockoutTimer = nil
            setKeypadEnabled(true)
            setErrorText(nil)
            reset()
            return
        }
        let formatted = Self.formatRemaining(remaining)
        setErrorText(String(format: String.localized("passcode_locked_out"), formatted))
    }

    private static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(ceil(seconds))
        let minutes = total / 60
        let secs = total % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, secs)
        }
        return String(format: "0:%02d", secs)
    }
}
