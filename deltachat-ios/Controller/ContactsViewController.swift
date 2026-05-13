import UIKit
import DcCore

class ContactsViewController: UITableViewController {

    private let dcContext: DcContext

    private enum Reuse {
        static let remoteContact = "RemoteContactCell"
    }

    private static let remoteAvatarColors: [UIColor] = [
        .systemBlue, .systemPurple, .systemOrange, .systemPink, .systemTeal, DcColors.primary
    ]

    private var contactGroups: [(letter: String, ids: [Int])] = []
    private var filteredContactIds: [Int] = []
    private var remoteResults: [RemoteUser] = []
    private var isRemoteSearchPending = false

    private var firstContactSection: Int { isFiltering ? 0 : 1 }
    private var numberOfContactSections: Int {
        isFiltering ? (filteredContactIds.isEmpty ? 0 : 1) : contactGroups.count
    }
    private var showRemote: Bool { isFiltering && (searchText?.count ?? 0) >= 2 }
    private var remoteSection: Int { firstContactSection + numberOfContactSections }
    private func isContactSection(_ section: Int) -> Bool {
        section >= firstContactSection && section < remoteSection
    }

    private lazy var searchService = UserSearchService(dcContext: dcContext)

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

    private var emptySearchStateLabelWidthConstraint: NSLayoutConstraint?

    // MARK: - init

    init(dcContext: DcContext, dcAccounts: DcAccounts) {
        self.dcContext = dcContext
        super.init(style: .plain)
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

        tableView.separatorStyle = .none
        tableView.register(ActionCell.self, forCellReuseIdentifier: ActionCell.reuseIdentifier)
        tableView.register(ContactCell.self, forCellReuseIdentifier: ContactCell.reuseIdentifier)
        tableView.register(ContactCell.self, forCellReuseIdentifier: Reuse.remoteContact)
        emptySearchStateLabelWidthConstraint = emptySearchStateLabel.widthAnchor.constraint(equalTo: tableView.widthAnchor)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addButtonPressed)
        )

        navigationController?.navigationBar.scrollEdgeAppearance = navigationController?.navigationBar.standardAppearance
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        buildGroups(from: dcContext.getContacts(flags: DC_GCL_ADD_SELF))
        tableView.reloadData()
        NotificationCenter.default.addObserver(self, selector: #selector(handleOnlineStatusChanged),
                                               name: TypingManager.onlineStatusChangedNotification, object: nil)
        retryRegistrationIfNeeded()
    }

    private func retryRegistrationIfNeeded() {
        guard KeychainManager.loadJwtToken(accountId: dcContext.id) == nil else { return }
        guard let displayName = dcContext.displayname, !displayName.isEmpty else { return }
        let dcCtx = dcContext
        DispatchQueue.global().async {
            AltPlatformService(dcContext: dcCtx).quickRegister(displayName: displayName)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if searchController.isActive && filteredContactIds.isEmpty && remoteResults.isEmpty {
            tableView.scrollRectToVisible(emptySearchStateLabel.frame, animated: false)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: TypingManager.onlineStatusChangedNotification, object: nil)
    }

    // MARK: - actions

    @objc private func handleOnlineStatusChanged() {
        let showOnline = UserDefaults.standard.bool(forKey: UserDefaults.onlineStatusEnabledKey)
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard isContactSection(indexPath.section),
                  let cell = tableView.cellForRow(at: indexPath) as? ContactCell else { continue }
            let contactId = contactIdAt(indexPath)
            // When showOnline is false the badge is explicitly cleared, not just skipped.
            let isOnline = showOnline && TypingManager.shared.isOnline(contactId: contactId)
            cell.avatar.setRecentlySeen(isOnline)
        }
    }

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
        return isFiltering ? numberOfContactSections + (showRemote ? 1 : 0)
                           : 1 + numberOfContactSections
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if !isFiltering && section == 0 { return 1 }
        if showRemote && section == remoteSection { return remoteResults.count }
        if isFiltering { return filteredContactIds.count }
        let groupIndex = section - firstContactSection
        guard groupIndex >= 0 && groupIndex < contactGroups.count else { return 0 }
        return contactGroups[groupIndex].ids.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if !isFiltering && section == 0 { return nil }
        if showRemote && section == remoteSection { return String.localized("search_results_on_server") }
        if isFiltering { return filteredContactIds.isEmpty ? nil : String.localized("search_results_local") }
        let groupIndex = section - firstContactSection
        guard groupIndex >= 0 && groupIndex < contactGroups.count else { return nil }
        return contactGroups[groupIndex].letter
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if !isFiltering && indexPath.section == 0 { return UITableView.automaticDimension }
        return ContactCell.cellHeight
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if !isFiltering && indexPath.section == 0 {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ActionCell.reuseIdentifier, for: indexPath) as? ActionCell else {
                fatalError("ActionCell expected")
            }
            cell.imageView?.image = UIImage(systemName: "heart")
            cell.actionTitle = String.localized("invite_friends")
            return cell
        }
        if showRemote && indexPath.section == remoteSection {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: Reuse.remoteContact) as? ContactCell else {
                fatalError("ContactCell expected")
            }
            let user = remoteResults[indexPath.row]
            let displayName = user.name.isEmpty ? user.username : user.name
            cell.titleLabel.text = displayName
            cell.titleLabel.font = UIFont.preferredFont(for: .body, weight: .regular)
            cell.subtitleLabel.text = "@\(user.username)"
            cell.subtitleLabel.textColor = DcColors.middleGray
            let colorIndex = abs(displayName.hashValue) % Self.remoteAvatarColors.count
            cell.setBackupImage(name: displayName, color: Self.remoteAvatarColors[colorIndex])
            cell.avatar.setRecentlySeen(false)
            cell.setTimeLabel(nil)
            return cell
        }
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ContactCell.reuseIdentifier, for: indexPath) as? ContactCell else {
            fatalError("ContactCell expected")
        }
        let contactId = contactIdAt(indexPath)
        let viewModel = ContactCellViewModel.make(contactId: contactId, searchText: searchText, dcContext: dcContext)
        cell.updateCell(cellViewModel: viewModel)
        // Show @username derived from email instead of raw email address
        let contact = dcContext.getContact(id: contactId)
        cell.subtitleLabel.text = "@" + usernameFromEmail(contact.email)
        cell.subtitleLabel.isHidden = false
        // Overlay online status from TypingManager (mutual opt-in: only visible if we also have it enabled)
        if UserDefaults.standard.bool(forKey: UserDefaults.onlineStatusEnabledKey) {
            cell.avatar.setRecentlySeen(TypingManager.shared.isOnline(contactId: contactId))
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        if !isFiltering && indexPath.section == 0 {
            if let cell = tableView.cellForRow(at: indexPath) {
                inviteFriends(sourceView: cell)
            }
            return
        }
        if showRemote && indexPath.section == remoteSection {
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
        showChatAt(indexPath: indexPath)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard isContactSection(indexPath.section) else { return nil }
        let contactId = contactIdAt(indexPath)

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
        profileAction.backgroundColor = DcColors.primary
        profileAction.image = UIImage(systemName: "person.crop.circle")

        let deleteAction = UIContextualAction(style: .destructive, title: String.localized("delete")) { [weak self] _, _, done in
            guard let self else { return }
            self.askToDeleteContact(contactId: contactId, indexPath: indexPath) { done(true) }
        }
        deleteAction.image = UIImage(systemName: "trash")

        return UISwipeActionsConfiguration(actions: [profileAction, deleteAction])
    }

    // MARK: - helpers

    private func contactIdAt(_ indexPath: IndexPath) -> Int {
        if isFiltering {
            guard filteredContactIds.indices.contains(indexPath.row) else {
                assertionFailure("contactIdAt: filteredContactIds index out of bounds \(indexPath)")
                return 0
            }
            return filteredContactIds[indexPath.row]
        }
        let groupIndex = indexPath.section - firstContactSection
        guard contactGroups.indices.contains(groupIndex),
              contactGroups[groupIndex].ids.indices.contains(indexPath.row) else {
            assertionFailure("contactIdAt: index out of bounds \(indexPath)")
            return 0
        }
        return contactGroups[groupIndex].ids[indexPath.row]
    }

    private func buildGroups(from ids: [Int]) {
        // Fetch all names in one pass to avoid repeated DB calls in the sort comparator.
        let pairs: [(id: Int, name: String)] = ids.map {
            (id: $0, name: dcContext.getContact(id: $0).displayName)
        }
        let sorted = pairs.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var groups: [(String, [Int])] = []
        var currentLetter = ""
        var currentIds: [Int] = []
        for pair in sorted {
            let letter = pair.name.first.flatMap { $0.isLetter ? String($0).uppercased() : nil } ?? "#"
            if letter == currentLetter {
                currentIds.append(pair.id)
            } else {
                if !currentIds.isEmpty { groups.append((currentLetter, currentIds)) }
                currentLetter = letter
                currentIds = [pair.id]
            }
        }
        if !currentIds.isEmpty { groups.append((currentLetter, currentIds)) }
        contactGroups = groups
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        guard !isFiltering else { return nil }
        return [UITableView.indexSearch] + contactGroups.map { $0.letter }
    }

    override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        if index == 0 {
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
            return NSNotFound
        }
        return firstContactSection + index - 1
    }

    private static let usernameAllowedChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")

    private func usernameFromEmail(_ email: String) -> String {
        let local = email.components(separatedBy: "@").first ?? email
        let allowed = Self.usernameAllowedChars
        let result = local.lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
        // Collapse consecutive underscores in a single pass using regex
        let collapsed = result.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }


    private func showChatAt(indexPath: IndexPath) {
        let contactId = contactIdAt(indexPath)
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
        let keyContactIds = dcContext.getContacts(flags: DC_GCL_ADD_SELF, queryString: searchText)
        let addrContactIds = dcContext.getContacts(flags: DC_GCL_ADDRESS, queryString: searchText)
        let keyContactSet = Set(keyContactIds)
        filteredContactIds = keyContactIds + addrContactIds.filter { !keyContactSet.contains($0) }

        if searchText.count >= 2 {
            isRemoteSearchPending = true
            searchService.search(query: searchText) { [weak self] result in
                guard let self else { return }
                self.isRemoteSearchPending = false
                switch result {
                case .success(let users):
                    let localEmails = Set(self.filteredContactIds.map { self.dcContext.getContact(id: $0).email.lowercased() })
                    self.remoteResults = users.filter { user in
                        !user.addr.contains { localEmails.contains($0.lowercased()) }
                    }
                case .failure:
                    self.remoteResults = []
                }
                self.tableView.reloadData()
                self.updateEmptyState(for: searchText)
            }
        } else {
            searchService.cancel()
            isRemoteSearchPending = false
            remoteResults = []
        }

        tableView.reloadData()
        tableView.scrollToTop()
        updateEmptyState(for: searchText)
    }

    private func updateEmptyState(for searchText: String) {
        if searchController.isActive && filteredContactIds.isEmpty && remoteResults.isEmpty && !isRemoteSearchPending {
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
                self.buildGroups(from: self.dcContext.getContacts(flags: DC_GCL_ADD_SELF))
                if self.isFiltering {
                    self.filteredContactIds = self.dcContext.getContacts(flags: DC_GCL_ADD_SELF, queryString: self.searchText)
                }
                self.tableView.reloadData()
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
