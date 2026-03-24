import UIKit
import DcCore

class ContactsViewController: UITableViewController {

    private let dcContext: DcContext
    private let dcAccounts: DcAccounts

    private let sectionInviteFriends = 0
    private let sectionContacts = 1
    private let sectionRemoteResults = 2

    private var contactIds: [Int] = []
    private var filteredContactIds: [Int] = []
    private var remoteResults: [RemoteUser] = []

    private lazy var searchService = UserSearchService(accountId: dcContext.id)

    private var searchText: String? {
        return searchController.searchBar.text
    }

    private var isFiltering: Bool {
        return !(searchController.searchBar.text?.isEmpty ?? true)
    }

    private lazy var searchController: UISearchController = {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String.localized("search")
        return searchController
    }()

    private lazy var emptySearchStateLabel: EmptyStateLabel = {
        let label = EmptyStateLabel()
        label.isHidden = true
        label.backgroundColor = nil
        label.textColor = DcColors.defaultTextColor
        label.paddingBottom = 64
        return label
    }()

    private lazy var emptySearchStateLabelWidthConstraint: NSLayoutConstraint? = {
        return emptySearchStateLabel.widthAnchor.constraint(equalTo: tableView.widthAnchor)
    }()

    // MARK: - init

    init(dcContext: DcContext, dcAccounts: DcAccounts) {
        self.dcContext = dcContext
        self.dcAccounts = dcAccounts
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String.localized("contacts_title")

        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        tableView.register(ActionCell.self, forCellReuseIdentifier: ActionCell.reuseIdentifier)
        tableView.register(ContactCell.self, forCellReuseIdentifier: ContactCell.reuseIdentifier)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addButtonPressed)
        )

        navigationController?.navigationBar.scrollEdgeAppearance = navigationController?.navigationBar.standardAppearance
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        contactIds = dcContext.getContacts(flags: DC_GCL_ADD_SELF)
        tableView.reloadData()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if searchController.isActive && filteredContactIds.isEmpty && remoteResults.isEmpty {
            tableView.scrollRectToVisible(emptySearchStateLabel.frame, animated: false)
        }
    }

    // MARK: - actions

    @objc private func addButtonPressed() {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .safeActionSheet)
        alert.addAction(UIAlertAction(title: String.localized("search_by_name_or_nick"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.searchController.isActive = true
            self.searchController.searchBar.becomeFirstResponder()
        })
        alert.addAction(UIAlertAction(title: String.localized("paste_from_clipboard"), style: .default) { [weak self] _ in
            guard let self else { return }
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.appCoordinator.coordinate(qrCode: UIPasteboard.general.string ?? "", from: self)
        })
        alert.addAction(UIAlertAction(title: String.localized("qrscan_title"), style: .default) { _ in
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.appCoordinator.presentQrCodeController()
        })
        alert.addAction(UIAlertAction(title: String.localized("cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func inviteFriends(sourceView: UIView) {
        guard let inviteLink = Utils.getInviteLink(context: dcContext, chatId: 0) else { return }
        let invitationText = String.localizedStringWithFormat(String.localized("invite_friends_text"), inviteLink)
        Utils.share(text: invitationText, parentViewController: self, sourceView: sourceView)
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        let showRemote = isFiltering && (searchText?.count ?? 0) >= 2
        return showRemote ? 3 : 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == sectionInviteFriends {
            return 1
        } else if section == sectionRemoteResults {
            return remoteResults.count
        }
        return isFiltering ? filteredContactIds.count : contactIds.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == sectionRemoteResults && !remoteResults.isEmpty {
            return String.localized("search_results_on_server")
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == sectionInviteFriends {
            return UITableView.automaticDimension
        }
        return ContactCell.cellHeight
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == sectionInviteFriends {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ActionCell.reuseIdentifier, for: indexPath) as? ActionCell else {
                fatalError("ActionCell expected")
            }
            cell.imageView?.image = UIImage(systemName: "heart")
            cell.actionTitle = String.localized("invite_friends")
            return cell
        }
        if indexPath.section == sectionRemoteResults {
            let cell = tableView.dequeueReusableCell(withIdentifier: "RemoteUserCell")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "RemoteUserCell")
            let user = remoteResults[indexPath.row]
            cell.textLabel?.text = user.name.isEmpty ? user.username : user.name
            cell.detailTextLabel?.text = "@\(user.username) · \(user.addr.first ?? "")"
            cell.detailTextLabel?.textColor = DcColors.middleGray
            return cell
        }
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ContactCell.reuseIdentifier, for: indexPath) as? ContactCell else {
            fatalError("ContactCell expected")
        }
        let viewModel = ContactCellViewModel.make(contactId: contactIdByRow(indexPath.row), searchText: searchText, dcContext: dcContext)
        cell.updateCell(cellViewModel: viewModel)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        if indexPath.section == sectionInviteFriends {
            if let cell = tableView.cellForRow(at: indexPath) {
                inviteFriends(sourceView: cell)
            }
            return
        }
        if indexPath.section == sectionRemoteResults {
            let user = remoteResults[indexPath.row]
            guard let email = user.addr.first else { return }
            let contactId = dcContext.importContactWithKey(name: user.name, email: email, publicKey: user.publicKey)
            if searchController.isActive {
                searchController.dismiss(animated: false) { [weak self] in
                    self?.openChat(contactId: contactId)
                }
            } else {
                openChat(contactId: contactId)
            }
            return
        }
        showChatAt(row: indexPath.row)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == sectionContacts else { return nil }
        let contactId = contactIdByRow(indexPath.row)

        let profileAction = UIContextualAction(style: .normal, title: String.localized("profile")) { [weak self] _, _, done in
            guard let self else { return }
            if self.searchController.isActive {
                self.searchController.dismiss(animated: false) {
                    self.showContactDetail(contactId: contactId)
                }
            } else {
                self.showContactDetail(contactId: contactId)
            }
            done(true)
        }
        profileAction.backgroundColor = .systemBlue
        profileAction.image = UIImage(systemName: "person.crop.circle")

        let deleteAction = UIContextualAction(style: .destructive, title: String.localized("delete")) { [weak self] _, _, done in
            guard let self else { return }
            self.askToDeleteContact(contactId: contactId, indexPath: indexPath) { done(true) }
        }
        deleteAction.image = UIImage(systemName: "trash")

        return UISwipeActionsConfiguration(actions: [profileAction, deleteAction])
    }

    // MARK: - helpers

    private func contactIdByRow(_ row: Int) -> Int {
        return isFiltering ? filteredContactIds[row] : contactIds[row]
    }

    private func showChatAt(row: Int) {
        let contactId = contactIdByRow(row)
        if searchController.isActive {
            searchController.dismiss(animated: false) { [weak self] in
                self?.openChat(contactId: contactId)
            }
        } else {
            openChat(contactId: contactId)
        }
    }

    private func openChat(contactId: Int) {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let chatId = dcContext.createChatByContactId(contactId: contactId)
        appDelegate.appCoordinator.showChat(chatId: chatId, animated: true, clearViewControllerStack: true)
    }

    private func showContactDetail(contactId: Int) {
        navigationController?.pushViewController(ProfileViewController(dcContext, contactId: contactId), animated: true)
    }

    private func filterContentForSearchText(_ searchText: String) {
        filteredContactIds = dcContext.getContacts(flags: DC_GCL_ADD_SELF, queryString: searchText)

        if searchText.count >= 2 {
            searchService.search(query: searchText) { [weak self] result in
                guard let self else { return }
                if case .success(let users) = result {
                    let localEmails = Set(self.filteredContactIds.map { self.dcContext.getContact(id: $0).email.lowercased() })
                    self.remoteResults = users.filter { user in
                        !user.addr.contains { localEmails.contains($0.lowercased()) }
                    }
                } else {
                    self.remoteResults = []
                }
                self.tableView.reloadData()
                self.updateEmptyState(for: searchText)
            }
        } else {
            searchService.cancel()
            remoteResults = []
        }

        tableView.reloadData()
        tableView.scrollToTop()
        updateEmptyState(for: searchText)
    }

    private func updateEmptyState(for searchText: String) {
        if searchController.isActive && filteredContactIds.isEmpty && remoteResults.isEmpty {
            let text = String.localizedStringWithFormat(String.localized("search_no_result_for_x"), searchText)
            emptySearchStateLabel.text = text
            emptySearchStateLabel.isHidden = false
            tableView.tableHeaderView = emptySearchStateLabel
            emptySearchStateLabelWidthConstraint?.isActive = true
        } else {
            emptySearchStateLabel.text = nil
            emptySearchStateLabel.isHidden = true
            emptySearchStateLabelWidthConstraint?.isActive = false
            tableView.tableHeaderView = nil
        }
    }
}

// MARK: - alerts

extension ContactsViewController {
    private func askToDeleteContact(contactId: Int, indexPath: IndexPath, didDelete: (() -> Void)? = nil) {
        let contact = dcContext.getContact(id: contactId)
        let alert = UIAlertController(
            title: String.localizedStringWithFormat(String.localized("ask_delete_contact"), contact.displayName),
            message: nil,
            preferredStyle: .safeActionSheet
        )
        alert.addAction(UIAlertAction(title: String.localized("delete"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            if self.dcContext.deleteContact(contactId: contactId) {
                self.contactIds = self.dcContext.getContacts(flags: DC_GCL_ADD_SELF)
                if self.isFiltering {
                    self.filteredContactIds = self.dcContext.getContacts(flags: DC_GCL_ADD_SELF, queryString: self.searchText)
                }
                self.tableView.deleteRows(at: [indexPath], with: .automatic)
            }
            didDelete?()
        })
        alert.addAction(UIAlertAction(title: String.localized("cancel"), style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - UISearchResultsUpdating

extension ContactsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        if let text = searchController.searchBar.text {
            filterContentForSearchText(text)
        }
    }
}
