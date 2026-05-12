import UIKit
import DcCore

/// Telegram-style audio-note recording overlay shown during the pre-lock recording phase.
///
/// Positioned over the input bar area + a lock-target zone above it.
/// The overlay is added to the window but sized to cover only `lockAreaHeight` above the
/// input bar plus the input bar itself — NOT the whole screen.
///
/// Layout inside the overlay (y = 0 at top of overlay):
///   [0 … lockAreaHeight)          — lock-target zone (transparent except for lock circle)
///   [lockAreaHeight … height)     — input-bar zone (blurred background, recording controls)
final class AudioNoteRecordingOverlay: UIView {

    // MARK: - Public constants

    /// Height of the zone above the input bar reserved for the lock target.
    static let lockAreaHeight: CGFloat = 120

    // MARK: - Private constants

    private let lockSize: CGFloat = 44
    private let dotSize: CGFloat = 10
    private let sidePad: CGFloat = 18

    // MARK: - Subviews

    /// Blurred background covering the input-bar portion (visually replaces the input bar).
    private let blurBg = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    /// Pulsing red recording dot.
    private let redDot = UIView()
    /// Monospaced elapsed-time label ("0:12").
    private let timerLabel = UILabel()
    /// Pulsing left-arrow ("←") — animates separately from hint text.
    private let arrowLabel = UILabel()
    /// "Slide to cancel" hint text — fades as the finger moves toward cancel threshold.
    private let hintLabel = UILabel()
    /// Circular container for the lock icon; appears above the mic button after a delay.
    private let lockContainer = UIView()
    private let lockOpenIcon = UIImageView()    // shown initially
    private let lockClosedIcon = UIImageView()  // crossfades in on lock
    private let lockPauseIcon = UIImageView()   // shown in locked mode instead of padlock

    /// Called when the user taps the pause icon in locked recording mode.
    var onPauseTapped: (() -> Void)?

    // MARK: - Geometry (populated by show())

    /// X coordinate of the mic button in **window** coords (= overlay coords since x == 0).
    private var micWindowX: CGFloat = 0
    /// Y coordinate of the lock target centre in **window** coords (for proximity check).
    private var lockTargetWindowY: CGFloat = 0
    /// Window-X at or below which cancel fires (set inside show()).
    private(set) var cancelThresholdX: CGFloat = 0

    private var lockShowTask: DispatchWorkItem?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        blurBg.layer.masksToBounds = true

        redDot.backgroundColor = .systemRed
        redDot.layer.cornerRadius = dotSize / 2

        timerLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .regular)
        timerLabel.textColor = DcColors.defaultTextColor

        arrowLabel.font = .preferredFont(forTextStyle: .subheadline)
        arrowLabel.textColor = DcColors.defaultTextColor.withAlphaComponent(0.6)
        arrowLabel.text = "←"

        hintLabel.font = .preferredFont(forTextStyle: .subheadline)
        hintLabel.textColor = DcColors.defaultTextColor.withAlphaComponent(0.6)
        hintLabel.text = String.localized("chat_record_slide_to_cancel")

        lockContainer.backgroundColor = DcColors.systemMessageBackgroundColor
        lockContainer.layer.cornerRadius = lockSize / 2
        lockContainer.alpha = 0

        let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        lockOpenIcon.image = UIImage(systemName: "lock.open.fill", withConfiguration: cfg)
        lockOpenIcon.tintColor = .white
        lockOpenIcon.contentMode = .center
        lockClosedIcon.image = UIImage(systemName: "lock.fill", withConfiguration: cfg)
        lockClosedIcon.tintColor = .white
        lockClosedIcon.contentMode = .center
        lockClosedIcon.alpha = 0

        lockContainer.addSubview(lockOpenIcon)
        lockContainer.addSubview(lockClosedIcon)

        lockPauseIcon.image = UIImage(systemName: "pause.fill", withConfiguration: cfg)
        lockPauseIcon.tintColor = .white
        lockPauseIcon.contentMode = .center
        lockPauseIcon.alpha = 0
        lockContainer.addSubview(lockPauseIcon)

        addSubview(blurBg)
        addSubview(redDot)
        addSubview(timerLabel)
        addSubview(arrowLabel)
        addSubview(hintLabel)
        addSubview(lockContainer)
    }

    // MARK: - Show

    /// Call after setting the overlay's `frame` (= input-bar rect extended upward by `lockAreaHeight`).
    /// Both `micButtonCenter` and `inputBarFrame` are in **window** coordinates.
    func show(micButtonCenter: CGPoint, inputBarFrame: CGRect) {
        let lockH = AudioNoteRecordingOverlay.lockAreaHeight
        let ibarH = inputBarFrame.height
        let midY = lockH + ibarH / 2  // vertical centre of input-bar area in overlay-local coords
        micWindowX = micButtonCenter.x  // overlay x == 0, so window x == overlay-local x

        // Blurred background over the input-bar portion — stops before the mic button
        // so the button (still in the right stack view) shows through the transparent overlay.
        // micWindowX is the button centre; 22pt = half button width, 6pt = visual gap.
        blurBg.frame = CGRect(x: 0, y: lockH, width: micWindowX - 28, height: ibarH)

        // Red dot — left edge, vertically centred
        redDot.frame = CGRect(x: sidePad, y: midY - dotSize / 2, width: dotSize, height: dotSize)

        // Timer — immediately right of dot
        timerLabel.text = "0:00"
        timerLabel.sizeToFit()
        let timerW = max(timerLabel.bounds.width + 4, 44)
        let timerH = timerLabel.bounds.height
        let timerX = sidePad + dotSize + 8
        timerLabel.frame = CGRect(x: timerX, y: midY - timerH / 2, width: timerW, height: timerH)

        // Arrow + hint — centred between timer-right and mic-button-left
        arrowLabel.sizeToFit()
        hintLabel.sizeToFit()
        let arrowW = arrowLabel.bounds.width
        let hintW = hintLabel.bounds.width
        let hintH = hintLabel.bounds.height
        let contentLeft = timerX + timerW + 8
        let contentRight = micWindowX - 52  // leave room before the mic button area
        let cx = (contentLeft + contentRight) / 2
        let groupW = arrowW + 5 + hintW
        arrowLabel.frame = CGRect(x: cx - groupW / 2,
                                  y: midY - hintH / 2,
                                  width: arrowW, height: hintH)
        hintLabel.frame = CGRect(x: cx - groupW / 2 + arrowW + 5,
                                 y: midY - hintH / 2,
                                 width: hintW, height: hintH)

        // Cancel fires when finger passes ~42% of screen width to the left of mic button
        cancelThresholdX = micWindowX - bounds.width * 0.42

        // Lock container — positioned higher above the input bar so the finger doesn't cover it.
        // Frame is set to the final resting position; the initial downward offset is encoded into
        // the transform so frame and transform are never mutated together in one animation block.
        let lockLocalY = lockH - lockSize - 64
        lockContainer.frame = CGRect(x: micWindowX - lockSize / 2,
                                     y: lockLocalY,
                                     width: lockSize, height: lockSize)
        lockOpenIcon.frame = lockContainer.bounds
        lockClosedIcon.frame = lockContainer.bounds
        lockPauseIcon.frame = lockContainer.bounds
        lockContainer.alpha = 0
        // Encode +16pt downward start offset into the transform (divide by scale factor 0.7).
        lockContainer.transform = CGAffineTransform(scaleX: 0.7, y: 0.7).translatedBy(x: 0, y: 16 / 0.7)

        // Lock target centre in window coords (for proximity detection in updateDrag)
        lockTargetWindowY = frame.minY + CGFloat(lockLocalY) + lockSize / 2

        // Animate recording strip in
        alpha = 0
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }

        startRedDotPulse()
        startArrowPulse()

        // Lock icon appears above mic button after a short delay
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.25, delay: 0,
                           usingSpringWithDamping: 0.65, initialSpringVelocity: 5) {
                self.lockContainer.alpha = 1
                self.lockContainer.transform = .identity
            }
        }
        lockShowTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: task)
    }

    // MARK: - Pulse animations

    private func startRedDotPulse() {
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 1.0
        anim.toValue = 1.5
        anim.duration = 0.55
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        redDot.layer.add(anim, forKey: "dotPulse")
    }

    private func startArrowPulse() {
        UIView.animate(withDuration: 0.55, delay: 0.2,
                       options: [.repeat, .autoreverse, .allowUserInteraction, .curveEaseInOut]) {
            self.arrowLabel.transform = CGAffineTransform(translationX: -6, y: 0)
        }
    }

    // MARK: - Drag tracking

    /// Call on every `.changed` gesture event. `location` is in **window** coordinates.
    /// Returns `(shouldCancel, shouldLock, hintFade)` — the caller acts on these flags.
    /// `hintFade` is 1.0 normally and fades to 0.0 as the finger nears the cancel threshold.
    func updateDrag(location: CGPoint) -> (shouldCancel: Bool, shouldLock: Bool, hintFade: CGFloat) {
        let movedLeft = micWindowX - location.x        // positive = moved left
        let movedUp   = lockTargetWindowY - location.y // positive = moved toward lock

        let horizontal = abs(movedLeft) >= abs(movedUp)

        var hintFade: CGFloat = 1.0
        // Fade the hint as the finger approaches the cancel threshold
        if horizontal && movedLeft > 0 {
            let maxDx = max(micWindowX - cancelThresholdX, 1)
            let t = min(movedLeft / maxDx, 1.0)
            hintFade = max(0, 1 - t)
            hintLabel.alpha = hintFade
            arrowLabel.alpha = hintFade
        }

        // Lock: predominantly upward drag that reaches the lock target zone
        if !horizontal && location.y <= lockTargetWindowY + 20 {
            return (false, true, hintFade)
        }

        // Cancel: finger passed the cancel threshold while moving left
        if horizontal && location.x <= cancelThresholdX {
            return (true, false, hintFade)
        }

        return (false, false, hintFade)
    }

    // MARK: - Lock-close animation

    /// Animates the padlock from open → closed (open icon fades out, closed icon bounces in).
    /// The `completion` block is called when the bounce settles — use it to dismiss the overlay.
    func animateLockClosing(completion: @escaping () -> Void) {
        lockShowTask?.cancel()
        lockShowTask = nil

        // Make sure the lock container is visible before animating
        UIView.animate(withDuration: 0.08) {
            self.lockContainer.alpha = 1
            self.lockContainer.transform = .identity
        }

        // Open icon shrinks out
        UIView.animate(withDuration: 0.12, delay: 0.06) {
            self.lockOpenIcon.alpha = 0
            self.lockOpenIcon.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        }

        // Closed icon bounces in
        UIView.animate(withDuration: 0.22, delay: 0.12,
                       usingSpringWithDamping: 0.45, initialSpringVelocity: 10) {
            self.lockClosedIcon.alpha = 1
            self.lockContainer.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        } completion: { _ in
            UIView.animate(withDuration: 0.12) {
                self.lockContainer.transform = .identity
            } completion: { _ in
                completion()
            }
        }
    }

    // MARK: - Timer

    func updateTimerText(_ text: String) {
        timerLabel.text = text
    }

    /// Hides the input-bar recording strip (blur, dot, timer, hint), leaving only the padlock.
    /// Called for audio note mode — the input bar itself shows the timer/hint in Telegram style.
    func hideRecordingControls() {
        blurBg.isHidden = true
        redDot.isHidden = true
        timerLabel.isHidden = true
        arrowLabel.isHidden = true
        hintLabel.isHidden = true
    }

    /// Shows the overlay directly in pause-button state — used when resuming after preview.
    /// Skips the padlock animation; the lockContainer appears immediately as a pause icon
    /// positioned above `sendButtonCenter` (window coordinates), matching the lock-icon position.
    func showAsPause(sendButtonCenter: CGPoint, inputBarFrame: CGRect, onTap: @escaping () -> Void) {
        show(micButtonCenter: sendButtonCenter, inputBarFrame: inputBarFrame)
        hideRecordingControls()

        lockShowTask?.cancel()
        lockShowTask = nil
        lockContainer.transform = .identity
        lockContainer.alpha = 1
        // Hide all other icons; show only the pause icon.
        lockOpenIcon.alpha = 0
        lockClosedIcon.alpha = 0
        lockPauseIcon.alpha = 1

        onPauseTapped = onTap
        isUserInteractionEnabled = true
        lockContainer.isUserInteractionEnabled = true
        lockContainer.gestureRecognizers?.forEach { lockContainer.removeGestureRecognizer($0) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handlePauseTap))
        lockContainer.addGestureRecognizer(tap)
    }

    /// Transitions the floating icon from closed padlock → pause button.
    /// After calling this the overlay intercepts touches only within the lock container.
    func transitionToPause(onTap: @escaping () -> Void) {
        onPauseTapped = onTap
        isUserInteractionEnabled = true
        lockContainer.isUserInteractionEnabled = true
        lockContainer.gestureRecognizers?.forEach { lockContainer.removeGestureRecognizer($0) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handlePauseTap))
        lockContainer.addGestureRecognizer(tap)

        // Crossfade: closed padlock → pause icon
        UIView.animate(withDuration: 0.15) { self.lockClosedIcon.alpha = 0 }
        UIView.animate(withDuration: 0.2, delay: 0.1) { self.lockPauseIcon.alpha = 1 }
    }

    @objc private func handlePauseTap() { onPauseTapped?() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled else { return nil }
        // Only the lock container intercepts touches; everything else passes through.
        let lockPoint = lockContainer.convert(point, from: self)
        if lockContainer.bounds.contains(lockPoint) { return lockContainer }
        return nil
    }

    // MARK: - Dismiss

    func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        lockShowTask?.cancel()
        lockShowTask = nil
        redDot.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.1) { self.arrowLabel.transform = .identity }

        guard animated else {
            removeFromSuperview()
            completion?()
            return
        }

        UIView.animate(withDuration: 0.18) {
            self.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
            completion?()
        }
    }
}
