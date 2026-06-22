import UIKit
import DcCore

/// "Privacy and Security" screen. For now it hosts the Passcode Lock entry; it is the natural
/// place for future privacy options (e.g. a screenshot/blur toggle).
class PrivacySettingsViewController: UITableViewController {

    private let manager: PasscodeManager

    private lazy var passcodeCell: UITableViewCell = {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = String.localized("passcode_title")
        cell.imageView?.image = UIImage(systemName: "lock")
        cell.accessoryType = .disclosureIndicator
        return cell
    }()

    init(manager: PasscodeManager = .shared) {
        self.manager = manager
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String.localized("privacy_security_title")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updatePasscodeCell()
    }

    private func updatePasscodeCell() {
        passcodeCell.detailTextLabel?.text = String.localized(manager.isEnabled ? "passcode_summary_on" : "passcode_summary_off")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return passcodeCell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if manager.isEnabled {
            showPasscodeSettings()
        } else {
            startPasscodeCreation()
        }
    }

    private func showPasscodeSettings() {
        navigationController?.pushViewController(PasscodeSettingsViewController(manager: manager), animated: true)
    }

    /// Launch passcode creation; on success, replace this row's flow with the passcode settings.
    private func startPasscodeCreation() {
        let setup = PasscodeSetupViewController(mode: .create, manager: manager)
        let nav = PasscodePortraitNavigationController(rootViewController: setup)
        nav.modalPresentationStyle = .fullScreen
        setup.onFinished = { [weak self, weak nav] created in
            nav?.dismiss(animated: true)
            guard let self else { return }
            self.updatePasscodeCell()
            if created {
                self.navigationController?.pushViewController(PasscodeSettingsViewController(manager: self.manager), animated: true)
            }
        }
        present(nav, animated: true)
    }
}
