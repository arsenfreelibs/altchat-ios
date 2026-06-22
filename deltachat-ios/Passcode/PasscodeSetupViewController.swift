import UIKit
import DcCore

/// Create or change the passcode. Drives `PasscodeEntryViewController` through the step machine:
/// - Create: ENTER_NEW → CONFIRM_NEW
/// - Change: ENTER_OLD → ENTER_NEW → CONFIRM_NEW
///
/// On success it stores the new passcode and calls `onFinished(true)`; cancel calls `onFinished(false)`.
class PasscodeSetupViewController: PasscodeEntryViewController {

    enum Mode {
        case create
        case change
    }

    private enum Step {
        case enterOld
        case enterNew
        case confirmNew
    }

    private let mode: Mode
    private let manager: PasscodeManager
    private var step: Step
    private var firstEntry: String?

    /// Called when the flow ends. `true` if a new passcode was set, `false` if cancelled.
    var onFinished: ((Bool) -> Void)?

    init(mode: Mode, manager: PasscodeManager = .shared) {
        self.mode = mode
        self.manager = manager
        self.step = (mode == .change) ? .enterOld : .enterNew
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        onCodeEntered = { [weak self] code in
            self?.handle(code: code)
        }
        applyStep()
    }

    private func applyStep() {
        reset()
        switch step {
        case .enterOld:
            setTitleText(String.localized("passcode_enter_old_title"))
            setSubtitle(nil)
        case .enterNew:
            setTitleText(String.localized("passcode_create_title"))
            setSubtitle(String.localized("passcode_create_subtitle"))
        case .confirmNew:
            setTitleText(String.localized("passcode_confirm_title"))
            setSubtitle(String.localized("passcode_confirm_subtitle"))
        }
    }

    private func handle(code: String) {
        switch step {
        case .enterOld:
            if manager.verify(code) {
                step = .enterNew
                applyStep()
            } else {
                showError(String.localized("passcode_wrong"))
            }
        case .enterNew:
            firstEntry = code
            step = .confirmNew
            applyStep()
        case .confirmNew:
            if code == firstEntry {
                if manager.setPasscode(code) {
                    onFinished?(true)
                } else {
                    // Storage failure: restart from a clean new entry.
                    firstEntry = nil
                    step = .enterNew
                    applyStep()
                    showError(String.localized("error"))
                }
            } else {
                firstEntry = nil
                step = .enterNew
                applyStep()
                showError(String.localized("passcode_mismatch"))
            }
        }
    }

    @objc private func cancelTapped() {
        onFinished?(false)
    }
}
