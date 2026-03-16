import UIKit
import DcCore

protocol FilterBarDelegate: AnyObject {
    func filterBar(_ filterBar: FilterBarView, didSelectFilter filter: ActiveFilter)
    func filterBarDidTapAdd(_ filterBar: FilterBarView)
    func filterBar(_ filterBar: FilterBarView, didLongPressFilter filter: ChatFilter, sourceView: UIView)
}

// MARK: - FilterBarView

class FilterBarView: UIView {

    static let height: CGFloat = 44

    weak var delegate: FilterBarDelegate?

    private var customFilters: [ChatFilter] = []
    private var badgeCounts: [UUID: Int] = [:]
    private var activeFilter: ActiveFilter = .system(.all)
    private var allUnreadCount: Int = 0
    private var unreadChatsCount: Int = 0

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
        layout.minimumInteritemSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.showsHorizontalScrollIndicator = false
        cv.backgroundColor = .systemBackground
        cv.register(FilterChipCell.self, forCellWithReuseIdentifier: FilterChipCell.reuseIdentifier)
        cv.translatesAutoresizingMaskIntoConstraints = false
        return cv
    }()

    private let separator: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .systemBackground
        addSubview(collectionView)
        addSubview(separator)
        collectionView.dataSource = self
        collectionView.delegate = self
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    private func setupGestures() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        collectionView.addGestureRecognizer(longPress)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let cell = collectionView.cellForItem(at: indexPath) else { return }
        let item = items[indexPath.item]
        if case .custom(let filter) = item {
            delegate?.filterBar(self, didLongPressFilter: filter, sourceView: cell)
        }
    }

    // MARK: - Items

    private enum Item {
        case system(SystemFilter)
        case custom(ChatFilter)
        case add
    }

    private var items: [Item] {
        var result: [Item] = [.system(.all), .system(.unread)]
        result += customFilters.map { .custom($0) }
        result.append(.add)
        return result
    }

    // MARK: - Public API

    func configure(filters: [ChatFilter], activeFilter: ActiveFilter, badgeCounts: [UUID: Int],
                   allUnreadCount: Int = 0, unreadChatsCount: Int = 0) {
        self.customFilters = filters
        self.activeFilter = activeFilter
        self.badgeCounts = badgeCounts
        self.allUnreadCount = allUnreadCount
        self.unreadChatsCount = unreadChatsCount
        collectionView.reloadData()
    }

    func updateBadgeCounts(_ counts: [UUID: Int]) {
        self.badgeCounts = counts
        collectionView.reloadData()
    }
}

// MARK: - UICollectionViewDataSource

extension FilterBarView: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilterChipCell.reuseIdentifier, for: indexPath) as! FilterChipCell
        let item = items[indexPath.item]
        switch item {
        case .system(.all):
            let isActive = activeFilter == .system(.all)
            let badge = allUnreadCount > 0 ? allUnreadCount : nil
            cell.configure(title: String.localized("pref_show_emails_all"), badge: badge, isActive: isActive, isAddButton: false)
        case .system(.unread):
            let isActive = activeFilter == .system(.unread)
            let badge = unreadChatsCount > 0 ? unreadChatsCount : nil
            cell.configure(title: String.localized("search_unread"), badge: badge, isActive: isActive, isAddButton: false)
        case .custom(let filter):
            let isActive = activeFilter == .custom(filter.id)
            let badge = badgeCounts[filter.id]
            cell.configure(title: filter.name, badge: badge, isActive: isActive, isAddButton: false)
        case .add:
            cell.configure(title: "+", badge: nil, isActive: false, isAddButton: true)
        }
        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension FilterBarView: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = items[indexPath.item]
        switch item {
        case .system(let sys):
            delegate?.filterBar(self, didSelectFilter: .system(sys))
        case .custom(let filter):
            delegate?.filterBar(self, didSelectFilter: .custom(filter.id))
        case .add:
            delegate?.filterBarDidTapAdd(self)
        }
    }
}

// MARK: - FilterChipCell

private class FilterChipCell: UICollectionViewCell {

    static let reuseIdentifier = "FilterChipCell"

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let badgeView: UIView = {
        let v = UIView()
        v.backgroundColor = .systemRed
        v.layer.cornerRadius = 9
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let badgeLabel: UILabel = {
        let l = UILabel()
        l.textColor = .white
        l.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private var badgeMinWidthConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        contentView.layer.cornerRadius = 14
        contentView.clipsToBounds = true

        badgeView.addSubview(badgeLabel)
        contentView.addSubview(titleLabel)
        contentView.addSubview(badgeView)

        let badgeMinWidth = badgeView.widthAnchor.constraint(equalToConstant: 18)
        badgeMinWidth.priority = .defaultHigh
        badgeMinWidthConstraint = badgeMinWidth

        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(equalToConstant: 30),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            badgeView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            badgeView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            badgeView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badgeView.heightAnchor.constraint(equalToConstant: 18),
            badgeMinWidth,

            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 3),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -3),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
        ])
    }

    func configure(title: String, badge: Int?, isActive: Bool, isAddButton: Bool) {
        titleLabel.text = title

        if let badge, badge > 0 {
            badgeView.isHidden = false
            badgeLabel.text = badge > 999 ? "∞" : "\(badge)"
        } else {
            badgeView.isHidden = true
        }

        if isAddButton {
            contentView.backgroundColor = UIColor.secondarySystemBackground
            titleLabel.textColor = DcColors.primary
            titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .regular)
        } else if isActive {
            contentView.backgroundColor = DcColors.primary
            titleLabel.textColor = .white
            titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        } else {
            contentView.backgroundColor = UIColor.secondarySystemBackground
            titleLabel.textColor = UIColor.label
            titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        }
    }

    // Width = leading padding + label + gap + badge(if shown) + trailing padding
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let targetSize = CGSize(width: UIView.layoutFittingCompressedSize.width, height: 30)
        let size = contentView.systemLayoutSizeFitting(targetSize,
                                                        withHorizontalFittingPriority: .fittingSizeLevel,
                                                        verticalFittingPriority: .required)
        var newAttributes = layoutAttributes
        newAttributes.frame.size = CGSize(width: max(size.width, 44), height: 30)
        return newAttributes
    }
}
