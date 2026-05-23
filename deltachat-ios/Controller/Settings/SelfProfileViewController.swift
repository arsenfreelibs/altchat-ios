import UIKit
import DcCore
import Intents

class SelfProfileViewController: UITableViewController, MediaPickerDelegate {

    private struct SectionConfigs {
        let headerTitle: String?
        let footerTitle: String?
        let cells: [UITableViewCell]
    }

    private let dcAccounts: DcAccounts
    private let dcContext: DcContext

    private lazy var doneButton: UIBarButtonItem = {
        return UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneButtonPressed))
    }()

    private lazy var cancelButton: UIBarButtonItem = {
        return UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonPressed))
    }()

    private lazy var mediaPicker: MediaPicker? = {
        let mediaPicker = MediaPicker(dcContext: dcContext, navigationController: navigationController)
        mediaPicker.delegate = self
        return mediaPicker
    }()

    private lazy var statusCell: MultilineTextFieldCell = {
        let cell = MultilineTextFieldCell(description: String.localized("pref_default_status_label"),
                                          multilineText: dcContext.selfstatus,
                                          placeholder: String.localized("pref_default_status_label"))
        return cell
    }()

    private var changeAvatar: UIImage?
    private var deleteAvatar: Bool = false
    private var cachedSelfAvatar: UIImage?

    // MARK: - Avatar header

    private lazy var avatarBadge: InitialsBadge = {
        let badge = InitialsBadge(size: 100)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isUserInteractionEnabled = true
        return badge
    }()

    private lazy var avatarPhotoLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .callout)
        label.textAlignment = .center
        return label
    }()

    private lazy var avatarHeaderView: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(avatarBadge)
        container.addSubview(avatarPhotoLabel)

        NSLayoutConstraint.activate([
            avatarBadge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            avatarBadge.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            avatarBadge.widthAnchor.constraint(equalToConstant: 100),
            avatarBadge.heightAnchor.constraint(equalToConstant: 100),

            avatarPhotoLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            avatarPhotoLabel.topAnchor.constraint(equalTo: avatarBadge.bottomAnchor, constant: 8),
            avatarPhotoLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        // Gesture recognizer added in viewDidLoad to avoid capturing self inside the lazy closure
        return container
    }()

    private func setupAvatarHeader() {
        cachedSelfAvatar = dcContext.getSelfAvatarImage()  // read from disk once, reuse the cache
        if let image = cachedSelfAvatar {
            avatarBadge.setImage(image)
        } else {
            avatarBadge.setName(dcContext.displayname ?? "")
            avatarBadge.setColor(dcContext.getContact(id: Int(DC_CONTACT_ID_SELF)).color)
        }
        updateAvatarPhotoLabel(hasAvatar: cachedSelfAvatar != nil)
    }

    private func updateAvatarHeader(image: UIImage?) {
        if let image {
            avatarBadge.setImage(image)
        } else {
            avatarBadge.setImage(UIImage(named: "camera") ?? UIImage())
            avatarBadge.setColor(UIColor.lightGray)
        }
        updateAvatarPhotoLabel(hasAvatar: image != nil)
    }

    private func updateAvatarPhotoLabel(hasAvatar: Bool) {
        avatarPhotoLabel.text = hasAvatar ? "Change Photo" : "Set Photo"
        avatarPhotoLabel.textColor = .systemBlue
    }

    private func isAvatarCurrentlySet() -> Bool {
        if deleteAvatar { return false }
        if changeAvatar != nil { return true }
        return cachedSelfAvatar != nil
    }

    private lazy var usernameCell: UITableViewCell = {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = "Username"
        cell.detailTextLabel?.text = "@\(currentUsername())"
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }()

    private func currentUsername() -> String {
        if let stored = UserDefaults.shared?.string(forKey: "alt_username"), !stored.isEmpty {
            return stored
        }
        return AltPlatformService.deriveUsername(from: dcContext.addr ?? "")
    }

    private lazy var nameCell: TextFieldCell = {
        let cell = TextFieldCell(description: "Display Name", placeholder: String.localized("please_enter_name"))
        cell.setText(text: dcContext.displayname)
        cell.textFieldDelegate = self
        cell.textField.returnKeyType = .default
        return cell
    }()

    private lazy var deleteAccountCell: ActionCell = {
        let cell = ActionCell()
        cell.actionTitle = String.localized("delete_account")
        cell.actionColor = .systemRed
        return cell
    }()

    private lazy var sections: [SectionConfigs] = {
        let nameSection = SectionConfigs(
            headerTitle: nil,
            footerTitle: String.localized("pref_who_can_see_profile_explain"),
            cells: [nameCell, usernameCell, statusCell]
        )
        let deleteSection = SectionConfigs(
            headerTitle: nil,
            footerTitle: nil,
            cells: [deleteAccountCell]
        )
        return [nameSection, deleteSection]
    }()

    init(dcAccounts: DcAccounts) {
        self.dcAccounts = dcAccounts
        self.dcContext = dcAccounts.getSelected()
        super.init(style: .insetGrouped)
        hidesBottomBarWhenPushed = true

        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange), name: UITextField.textDidChangeNotification, object: nameCell.textField)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String.localized("pref_profile_info_headline")
        setupAvatarHeader()

        // Add tap here — keeps the lazy var closure free of strong self capture
        let tap = UITapGestureRecognizer(target: self, action: #selector(avatarHeaderTapped))
        avatarHeaderView.addGestureRecognizer(tap)

        // Must add to tableView first so header and tableView share a common ancestor,
        // then activate the width constraint, then measure and re-assign to commit the height.
        let header = avatarHeaderView
        tableView.tableHeaderView = header
        header.widthAnchor.constraint(equalTo: tableView.widthAnchor).isActive = true
        header.setNeedsLayout()
        header.layoutIfNeeded()
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        tableView.tableHeaderView = header

        tableView.rowHeight = UITableView.automaticDimension
        navigationItem.rightBarButtonItem = doneButton
        navigationItem.leftBarButtonItem = cancelButton
        validateFields()
    }

    private func validateFields() {
        doneButton.isEnabled = !(nameCell.textField.text?.isEmpty ?? true)
    }

    // MARK: - Table view data source
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].cells.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return sections[indexPath.section].cells[indexPath.row]
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].headerTitle
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        return sections[section].footerTitle
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = sections[indexPath.section].cells[indexPath.row]
        if cell === usernameCell {
            let alert = UIAlertController(title: "Coming Soon", message: "Username editing will be available in a future update.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String.localized("ok"), style: .default))
            present(alert, animated: true)
        } else if indexPath.section == 1 {
            deleteCurrentAccount()
        }
    }

    // MARK: - Notifications
    @objc private func textDidChange(notification: Notification) {
        validateFields()
    }

    // MARK: - actions
    @objc private func cancelButtonPressed() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func doneButtonPressed() {
        dcContext.selfstatus = statusCell.getText()
        dcContext.displayname = nameCell.getText()
        if let changeAvatar {
            AvatarHelper.saveSelfAvatarImage(dcContext: dcContext, image: changeAvatar)
        } else if deleteAvatar {
            dcContext.selfavatar = nil
        }
        navigationController?.popViewController(animated: true)
    }

    private func deleteCurrentAccount() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        Utils.authenticateDeviceOwner(reason: String.localized("delete_account")) { [weak self] in
            guard let self else { return }
            let accountId = dcContext.id
            let message = "⚠️ " + String.localized(stringID: "delete_account_explain_with_name",
                                                    parameter: dcContext.displayname ?? dcContext.addr ?? "")
            let alert = UIAlertController(title: String.localized("delete_account_ask"),
                                          message: message,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String.localized("delete_account"), style: .destructive) { [weak self] _ in
                guard let self else { return }
                appDelegate.locationManager.disableLocationStreamingInAllChats()
                _ = dcAccounts.remove(id: accountId)
                KeychainManager.deleteAccountSecret(id: accountId)
                INInteraction.delete(with: "\(accountId)", completion: nil)
                if dcAccounts.getAll().isEmpty {
                    _ = dcAccounts.add()
                }
                appDelegate.reloadDcContext()
            })
            alert.addAction(UIAlertAction(title: String.localized("cancel"), style: .cancel))
            present(alert, animated: true)
        }
    }

    @objc private func avatarHeaderTapped() {
        onAvatarTapped()
    }

    private func enlargeAvatarPressed(_ action: UIAlertAction) {
        // temporarily save to file as PreviewController uses QLPreviewItem which does not accept UIImage
        guard let image = avatarBadge.getImage() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview.png")
        guard let imageData = image.pngData() else { return }
        guard (try? imageData.write(to: url)) != nil else { return }

        let previewController = PreviewController(dcContext: dcContext, type: .single(url))
        previewController.customTitle = String.localized("pref_profile_photo")
        navigationController?.pushViewController(previewController, animated: true)
    }

    private func galleryButtonPressed(_ action: UIAlertAction) {
        mediaPicker?.showGallery(allowCropping: true)
    }

    private func cameraButtonPressed(_ action: UIAlertAction) {
        mediaPicker?.showCamera(allowCropping: true, supportedMediaTypes: .photo)
    }

    private func deleteProfileIconPressed(_ action: UIAlertAction) {
        changeAvatar = nil
        deleteAvatar = true
        updateAvatarHeader(image: nil)
    }

    private func onAvatarTapped() {
        let alert = UIAlertController(title: String.localized("pref_profile_photo"), message: nil, preferredStyle: .safeActionSheet)
        if isAvatarCurrentlySet() {
            alert.addAction(UIAlertAction(title: String.localized("global_menu_view_desktop"), style: .default, handler: enlargeAvatarPressed(_:)))
        }
        alert.addAction(PhotoPickerAlertAction(title: String.localized("camera"), style: .default, handler: cameraButtonPressed(_:)))
        alert.addAction(PhotoPickerAlertAction(title: String.localized("gallery"), style: .default, handler: galleryButtonPressed(_:)))
        if isAvatarCurrentlySet() {
            alert.addAction(UIAlertAction(title: String.localized("delete"), style: .destructive, handler: deleteProfileIconPressed(_:)))
        }
        alert.addAction(UIAlertAction(title: String.localized("cancel"), style: .cancel, handler: nil))

        self.present(alert, animated: true, completion: nil)
    }

    func onImageSelected(image: UIImage) {
        changeAvatar = image
        deleteAvatar = false
        updateAvatarHeader(image: image)
    }
}


extension SelfProfileViewController: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
