import UIKit
import DcCore

public class InitialsBadge: UIView {

    private let size: CGFloat

    private let gradientLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0, y: 0)
        layer.endPoint = CGPoint(x: 1, y: 1)
        return layer
    }()

    var leadingImageAnchorConstraint: NSLayoutConstraint?
    var trailingImageAnchorConstraint: NSLayoutConstraint?
    var topImageAnchorConstraint: NSLayoutConstraint?
    var bottomImageAnchorConstraint: NSLayoutConstraint?

    public var imagePadding: CGFloat = 0 {
        didSet {
            leadingImageAnchorConstraint?.constant = imagePadding
            topImageAnchorConstraint?.constant = imagePadding
            trailingImageAnchorConstraint?.constant = -imagePadding
            bottomImageAnchorConstraint?.constant = -imagePadding
        }
    }

    private var label: UILabel = {
        let label = UILabel()
        label.textAlignment = NSTextAlignment.center
        label.textColor = UIColor.white
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isAccessibilityElement = false
        return label
    }()

    private var recentlySeenView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = DcColors.recentlySeenDot
        view.clipsToBounds = true
        view.isHidden = true
        return view
    }()

    private var imageView: UIImageView = {
        let imageViewContainer = UIImageView()
        imageViewContainer.clipsToBounds = true
        imageViewContainer.translatesAutoresizingMaskIntoConstraints = false
        return imageViewContainer
    }()
    
    private lazy var unreadMessageCounter: MessageCounter = {
        let view = MessageCounter(count: 0, size: 20)
        view.isHidden = true
        view.isAccessibilityElement = false
        return view
    }()

    public convenience init(name: String, color: UIColor, size: CGFloat, accessibilityLabel: String? = nil) {
        self.init(size: size, accessibilityLabel: accessibilityLabel)
        setName(name)
        setColor(color)
    }

    public convenience init(image: UIImage, size: CGFloat, accessibilityLabel: String? = nil) {
        self.init(size: size, accessibilityLabel: accessibilityLabel)
        setImage(image)
    }

    public init(size: CGFloat, accessibilityLabel: String? = nil) {
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        self.accessibilityLabel = accessibilityLabel
        let radius = size / 2
        layer.cornerRadius = radius
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: size).isActive = true
        widthAnchor.constraint(equalToConstant: size).isActive = true
        label.font = UIFont.systemFont(ofSize: size * 0.40, weight: .semibold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        gradientLayer.cornerRadius = radius
        gradientLayer.masksToBounds = true
        layer.insertSublayer(gradientLayer, at: 0)
        setupSubviews(with: radius)
        isAccessibilityElement = true
    }

    private func setupSubviews(with radius: CGFloat) {
        addSubview(imageView)
        imageView.layer.cornerRadius = radius
        leadingImageAnchorConstraint = imageView.constraintAlignLeadingToAnchor(leadingAnchor)
        trailingImageAnchorConstraint = imageView.constraintAlignTrailingToAnchor(trailingAnchor)
        topImageAnchorConstraint = imageView.constraintAlignTopToAnchor(topAnchor)
        bottomImageAnchorConstraint = imageView.constraintAlignBottomToAnchor(bottomAnchor)

        addSubview(label)
        label.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        label.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true

        let recentlySeenViewWh = min(35, radius * 0.6)

        addSubview(recentlySeenView)
        addSubview(unreadMessageCounter)
        let imgViewConstraints = [recentlySeenView.constraintAlignBottomTo(self),
                                  recentlySeenView.constraintAlignTrailingTo(self),
                                  recentlySeenView.constraintHeightTo(recentlySeenViewWh),
                                  recentlySeenView.constraintWidthTo(recentlySeenViewWh),
                                  unreadMessageCounter.constraintAlignTopTo(self),
                                  unreadMessageCounter.constraintAlignTrailingTo(self, paddingTrailing: -8)
        ]
        recentlySeenView.layer.cornerRadius = recentlySeenViewWh / 2
        addConstraints(imgViewConstraints)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    private static func twoInitials(from name: String) -> String {
        let words = name.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let first = words.first, let firstChar = first.unicodeScalars.first.map({ String($0) }) else { return "" }
        guard words.count > 1, let last = words.last, last != first,
              let lastChar = last.unicodeScalars.first.map({ String($0) }) else {
            return firstChar.uppercased()
        }
        return (firstChar + lastChar).uppercased()
    }

    public func setName(_ name: String) {
        label.text = InitialsBadge.twoInitials(from: name)
        label.isHidden = name.isEmpty
        imageView.isHidden = !name.isEmpty
    }

    public func setImage(_ image: UIImage?) {
        guard let image else { return }
        self.imageView.image = image
        self.imageView.contentMode = UIView.ContentMode.scaleAspectFill
        self.imageView.isHidden = false
        self.label.isHidden = true
    }

    public func showsInitials() -> Bool {
        return !label.isHidden
    }

    public func setColor(_ color: UIColor) {
        gradientLayer.colors = [color.lightened(by: 0.25).cgColor, color.darkened(by: 0.2).cgColor]
    }

    public func setRecentlySeen(_ seen: Bool) {
        recentlySeenView.isHidden = !seen
    }
    
    public func setUnreadMessageCount(_ messageCount: Int, isMuted: Bool = false) {
        unreadMessageCounter.setCount(messageCount)
        unreadMessageCounter.backgroundColor = isMuted ? DcColors.unreadBadgeMuted : DcColors.unreadBadge
        unreadMessageCounter.isHidden = messageCount == 0
    }

    public func reset() {
        imageView.image = nil
        label.text = nil
        accessibilityLabel = nil
    }

    // render including shape etc.
    public func asImage() -> UIImage {
        UIGraphicsImageRenderer(size: bounds.size).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    // return the raw, rectange image
    public func getImage() -> UIImage? {
        return imageView.image
    }
}
