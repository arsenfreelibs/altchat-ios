import UIKit
import DcCore

class CallUIToggleButton: UIButton {
    private let size: CGFloat
    private let onImageName: String
    private let offImageName: String?
    /// When set, this color is always used as the tint overlay (e.g. red for hangup).
    private let fixedOverlayColor: UIColor?

    var toggleState: Bool {
        didSet { updateAppearance() }
    }

    private lazy var blurView: UIVisualEffectView = {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = size / 2
        blur.layer.masksToBounds = true
        return blur
    }()

    private lazy var tintOverlayView: UIView = {
        let v = UIView()
        v.layer.cornerRadius = size / 2
        v.layer.masksToBounds = true
        v.isUserInteractionEnabled = false
        return v
    }()

    init(imageSystemName: String, offImageSystemName: String? = nil, size: CGFloat = 70, state: Bool, fixedOverlayColor: UIColor? = nil) {
        self.size = size
        self.onImageName = imageSystemName
        self.offImageName = offImageSystemName
        self.toggleState = state
        self.fixedOverlayColor = fixedOverlayColor
        super.init(frame: .zero)
        let initialIcon = (!state ? offImageSystemName : nil) ?? imageSystemName
        self.setImage(UIImage(systemName: initialIcon), for: .normal)
        self.setPreferredSymbolConfiguration(.init(pointSize: size * 0.35), forImageIn: .normal)
        self.layer.cornerRadius = size / 2
        tintColor = .white
        insertSubview(blurView, at: 0)
        insertSubview(tintOverlayView, at: 1)
        updateAppearance()
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAppearance() {
        if let offName = offImageName {
            setImage(UIImage(systemName: toggleState ? onImageName : offName), for: .normal)
        }
        if let fixed = fixedOverlayColor {
            tintOverlayView.backgroundColor = fixed
        } else {
            tintOverlayView.backgroundColor = toggleState
                ? DcColors.primary.withAlphaComponent(0.55)
                : UIColor.white.withAlphaComponent(0.15)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        tintOverlayView.frame = bounds
        if let iv = imageView { bringSubviewToFront(iv) }
    }

}
