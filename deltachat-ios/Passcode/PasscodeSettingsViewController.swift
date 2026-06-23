import UIKit
import DcCore

/// "Passcode Lock" settings, shown only while a passcode is enabled.
/// Lets the user change the passcode, toggle biometric unlock, pick the auto-lock delay, or turn
/// the passcode off.
class PasscodeSettingsViewController: UITableViewController {

    private let manager: PasscodeManager

    private enum Row {
        case change
        case biometric
        case autoLock
        case turnOff
    }

    /// The biometric row is only present when the device has usable, enrolled biometrics.
    private var rows: [Row] {
        var result: [Row] = [.change]
        if manager.isBiometryAvailable { result.append(.biometric) }
        result.append(contentsOf: [.autoLock, .turnOff])
        return result
    }

    init(manager: PasscodeManager = .shared) {
        self.manager = manager
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String.localized("passcode_title")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // If the passcode was turned off elsewhere, leave this screen.
        if !manager.isEnabled {
            navigationController?.popViewController(animated: animated)
            return
        }
        // Drop biometric opt-in if the enrolled biometrics changed since.
        manager.invalidateBiometricIfEnrolmentChanged()
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .change:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = String.localized("passcode_change")
            cell.accessoryType = .disclosureIndicator
            return cell
        case .biometric:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = PasscodeFormat.biometricTitle(for: manager.biometryType)
            cell.selectionStyle = .none
            let toggle = UISwitch()
            toggle.isOn = manager.isBiometricEnabled
            toggle.addTarget(self, action: #selector(biometricToggled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        case .autoLock:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = String.localized("passcode_autolock")
            cell.detailTextLabel?.text = PasscodeFormat.title(for: manager.autoLock)
            cell.accessoryType = .disclosureIndicator
            return cell
        case .turnOff:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = String.localized("passcode_turn_off")
            cell.textLabel?.textColor = .systemRed
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
        case .change: changePasscode()
        case .biometric: break // handled by the switch
        case .autoLock: showAutoLock()
        case .turnOff: confirmTurnOff()
        }
    }

    @objc private func biometricToggled(_ sender: UISwitch) {
        manager.setBiometricEnabled(sender.isOn)
    }

    private func changePasscode() {
        let setup = PasscodeSetupViewController(mode: .change)
        let nav = PasscodePortraitNavigationController(rootViewController: setup)
        nav.modalPresentationStyle = .fullScreen
        setup.onFinished = { [weak self, weak nav] _ in
            nav?.dismiss(animated: true)
            self?.tableView.reloadData()
        }
        present(nav, animated: true)
    }

    private func showAutoLock() {
        let controller = PasscodeAutoLockViewController(manager: manager)
        controller.onChange = { [weak self] in
            self?.tableView.reloadData()
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func confirmTurnOff() {
        let alert = UIAlertController(
            title: String.localized("passcode_turn_off"),
            message: String.localized("passcode_turn_off_confirm"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String.localized("cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String.localized("passcode_turn_off"), style: .destructive) { [weak self] _ in
            self?.manager.disable()
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
}
