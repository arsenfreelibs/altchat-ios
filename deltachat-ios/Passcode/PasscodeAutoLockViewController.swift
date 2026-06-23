import UIKit
import DcCore
import LocalAuthentication

/// Checklist of auto-lock delays. Writes the chosen value back to `PasscodeManager`.
class PasscodeAutoLockViewController: UITableViewController {

    private let manager: PasscodeManager
    private let options = PasscodeManager.AutoLock.allCases

    /// Called after a selection so the caller can refresh its subtitle.
    var onChange: (() -> Void)?

    init(manager: PasscodeManager = .shared) {
        self.manager = manager
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String.localized("passcode_autolock")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return options.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return String.localized("passcode_autolock_summary")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let option = options[indexPath.row]
        cell.textLabel?.text = PasscodeFormat.title(for: option)
        cell.accessoryType = (option == manager.autoLock) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        manager.autoLock = options[indexPath.row]
        tableView.reloadData()
        onChange?()
    }
}

/// Presentation helpers for passcode values, kept out of the (UI-free) PasscodeManager.
enum PasscodeFormat {
    static func title(for option: PasscodeManager.AutoLock) -> String {
        switch option {
        case .disabled: return String.localized("passcode_autolock_disabled")
        case .oneMinute: return String.localized("passcode_autolock_1min")
        case .fiveMinutes: return String.localized("passcode_autolock_5min")
        case .oneHour: return String.localized("passcode_autolock_1hour")
        case .fiveHours: return String.localized("passcode_autolock_5hours")
        }
    }

    static func biometricTitle(for type: LABiometryType) -> String {
        switch type {
        case .faceID: return String.localized("passcode_unlock_faceid")
        case .touchID: return String.localized("passcode_unlock_touchid")
        default: return String.localized("passcode_fingerprint")
        }
    }
}
