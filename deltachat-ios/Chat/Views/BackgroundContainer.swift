import Foundation
import UIKit
import DcCore

class BackgroundContainer: UIImageView {

    var rectCorners: UIRectCorner?
    var color: UIColor?

    /// When true, applyPath() is skipped and the mask is cleared.
    /// Used by VideoNoteCell so the cell's own circular subview handles clipping.
    var skipApplyMask: Bool = false

    func update(rectCorners: UIRectCorner, color: UIColor) {
        self.rectCorners = rectCorners
        self.color = color
        image = UIImage(color: color)
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyPath()
    }

    func applyPath() {
        guard !skipApplyMask else {
            layer.mask = nil
            return
        }
        let radius: CGFloat = 16
        let path = UIBezierPath(roundedRect: bounds,
                                byRoundingCorners: rectCorners ?? UIRectCorner(),
                                cornerRadii: CGSize(width: radius, height: radius))
        let mask = CAShapeLayer()
        mask.path = path.cgPath
        layer.mask = mask
    }

    func prepareForReuse() {
        layer.mask = nil
        image = nil
        rectCorners = nil
        color = nil
        isHidden = false
        skipApplyMask = false
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if let rectCorners = self.rectCorners, let color = self.color {
            update(rectCorners: rectCorners, color: color)
        }
    }

}
