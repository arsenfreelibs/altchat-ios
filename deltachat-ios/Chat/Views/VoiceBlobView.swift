import UIKit
import DcCore

/// Animated concentric circles rendered behind the mic button during voice note recording.
/// Three UIView rings scale outward in proportion to the microphone level,
/// matching the Telegram audio-note blob animation style.
///
/// Uses UIView subviews (not CAShapeLayer sublayers) so that `view.transform` always
/// pivots around `view.center` — set correctly by `layoutSubviews` independently of
/// when `startAnimating()` is called.
final class VoiceBlobView: UIView {

    // MARK: - Ring views

    private let smallRing  = UIView()
    private let mediumRing = UIView()
    private let largeRing  = UIView()

    // Scale ranges [min, max] per ring.
    private let smallScaleRange:  ClosedRange<CGFloat> = 0.45...0.55
    private let mediumScaleRange: ClosedRange<CGFloat> = 0.52...0.87
    private let largeScaleRange:  ClosedRange<CGFloat> = 0.57...1.00

    // Alpha per ring (outer ring is most transparent).
    private let smallAlpha:  CGFloat = 0.20
    private let mediumAlpha: CGFloat = 0.13
    private let largeAlpha:  CGFloat = 0.08

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setupRings()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func setupRings() {
        // Add largest first so it renders behind smaller rings.
        for (ring, alpha) in [(largeRing, largeAlpha), (mediumRing, mediumAlpha), (smallRing, smallAlpha)] {
            ring.backgroundColor = DcColors.primary.withAlphaComponent(alpha)
            ring.isUserInteractionEnabled = false
            addSubview(ring)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for ring in [smallRing, mediumRing, largeRing] {
            // Reset transform first so bounds/center assignment is in identity space.
            ring.transform = .identity
            ring.bounds = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            ring.center = center
            ring.layer.cornerRadius = size / 2
        }
        applyScales(level: 0, animated: false)
    }

    // MARK: - Public API

    /// Feed this with the normalised mic level (0 = silence, 1 = maximum) on each metering tick.
    func setLevel(_ level: Float) {
        let clamped = CGFloat(min(max(level, 0), 1))
        applyScales(level: clamped, animated: true)
    }

    /// Start a gentle idle breath animation. Call once after the view is placed on screen.
    func startAnimating() {
        applyScales(level: 0, animated: false)
        startIdleAnimation()
    }

    /// Stop all animations and collapse rings back to their minimum scale.
    func stopAnimating() {
        stopIdleAnimation()
        applyScales(level: 0, animated: true)
    }

    // MARK: - Scale helpers

    private func applyScales(level: CGFloat, animated: Bool) {
        let ss = lerp(smallScaleRange,  t: level)
        let ms = lerp(mediumScaleRange, t: level)
        let ls = lerp(largeScaleRange,  t: level)

        let apply = { [weak self] in
            guard let self else { return }
            self.smallRing.transform  = CGAffineTransform(scaleX: ss, y: ss)
            self.mediumRing.transform = CGAffineTransform(scaleX: ms, y: ms)
            self.largeRing.transform  = CGAffineTransform(scaleX: ls, y: ls)
        }

        if animated {
            UIView.animate(withDuration: 0.1, delay: 0,
                           options: [.curveEaseOut, .beginFromCurrentState],
                           animations: apply)
        } else {
            apply()
        }
    }

    // MARK: - Idle animation

    private func startIdleAnimation() {
        // One continuous repeating animation — no timer, no overlapping starts, no flicker.
        UIView.animate(withDuration: 0.9, delay: 0,
                       options: [.repeat, .autoreverse, .curveEaseInOut, .allowUserInteraction]) { [weak self] in
            guard let self else { return }
            let s = self.lerp(self.smallScaleRange,  t: 0.12)
            let m = self.lerp(self.mediumScaleRange, t: 0.12)
            let l = self.lerp(self.largeScaleRange,  t: 0.12)
            self.smallRing.transform  = CGAffineTransform(scaleX: s, y: s)
            self.mediumRing.transform = CGAffineTransform(scaleX: m, y: m)
            self.largeRing.transform  = CGAffineTransform(scaleX: l, y: l)
        }
    }

    private func stopIdleAnimation() {
        smallRing.layer.removeAllAnimations()
        mediumRing.layer.removeAllAnimations()
        largeRing.layer.removeAllAnimations()
    }

    private func lerp(_ range: ClosedRange<CGFloat>, t: CGFloat) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * t
    }
}
