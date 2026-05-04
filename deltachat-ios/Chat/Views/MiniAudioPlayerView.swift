import UIKit
import DcCore

/// A Telegram-style mini audio player bar shown under the navigation bar while a voice/audio
/// message is playing. Attach it to a navigation controller's view and adjust
/// `additionalSafeAreaInsets.top` to push child content below it.
final class MiniAudioPlayerView: UIView {

    // MARK: - Constants

    static let height: CGFloat = 52

    // MARK: - Callbacks

    var onPlayPause: (() -> Void)?
    var onSpeedToggle: (() -> Void)?
    var onClose: (() -> Void)?

    // MARK: - Subviews

    private let blurView: UIVisualEffectView = {
        let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let separator: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.separator
        return v
    }()

    private let playPauseButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setImage(UIImage(systemName: "play.fill"), for: .normal)
        b.tintColor = DcColors.primary
        b.accessibilityLabel = String.localized("play")
        return b
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .label
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabel
        l.text = String.localized("voice_message")
        return l
    }()

    let speedButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setTitle("1×", for: .normal)
        b.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        b.tintColor = DcColors.primary
        b.accessibilityLabel = "Playback speed"
        return b
    }()

    private let closeButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setImage(UIImage(systemName: "xmark"), for: .normal)
        b.tintColor = DcColors.primary
        b.accessibilityLabel = String.localized("close")
        return b
    }()

    // MARK: - Progress bar (pinned to bottom edge)

    private let progressTrack: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.separator
        return v
    }()

    private let progressFill: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = DcColors.primary
        return v
    }()

    private var progressWidthConstraint: NSLayoutConstraint!

    // MARK: - Labels stack

    private lazy var labelsStack: UIStackView = {
        let sv = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.axis = .vertical
        sv.spacing = 1
        sv.alignment = .leading
        return sv
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupActions()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        setupActions()
    }

    // MARK: - Layout

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Blur background
        addSubview(blurView)
        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Bottom separator line
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2), // above progress bar
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        // Controls
        addSubview(playPauseButton)
        addSubview(labelsStack)
        addSubview(speedButton)
        addSubview(closeButton)

        let minTapSize: CGFloat = 44
        NSLayoutConstraint.activate([
            // Play/Pause — left edge
            playPauseButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            playPauseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playPauseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: minTapSize),
            playPauseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: minTapSize),

            // Close — right edge
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: minTapSize),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: minTapSize),

            // Speed — left of close
            speedButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            speedButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            speedButton.widthAnchor.constraint(greaterThanOrEqualToConstant: minTapSize),
            speedButton.heightAnchor.constraint(greaterThanOrEqualToConstant: minTapSize),

            // Labels — fills remaining space between play and speed buttons
            labelsStack.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 4),
            labelsStack.trailingAnchor.constraint(lessThanOrEqualTo: speedButton.leadingAnchor, constant: -8),
            labelsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Progress bar — 2pt strip at very bottom
        addSubview(progressTrack)
        progressTrack.addSubview(progressFill)

        progressWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            progressTrack.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 2),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressWidthConstraint,
        ])
    }

    private func setupActions() {
        playPauseButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)
        speedButton.addTarget(self, action: #selector(didTapSpeed), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
    }

    // MARK: - Public API

    func configure(title: String, subtitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }

    func setPlaying(_ isPlaying: Bool) {
        let imageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: imageName), for: .normal)
        playPauseButton.accessibilityLabel = String.localized(isPlaying ? "pause" : "play")
    }

    /// Progress is 0.0–1.0. Updates the fill width relative to the track width.
    func setProgress(_ progress: Float) {
        guard progressTrack.bounds.width > 0 else {
            // Layout not yet performed — update constraint constant directly.
            progressWidthConstraint.constant = 0
            return
        }
        let clamped = CGFloat(max(0, min(1, progress)))
        progressWidthConstraint.constant = progressTrack.bounds.width * clamped
    }

    func setSpeed(_ speed: Float) {
        let formatted: String
        switch speed {
        case 1.5: formatted = "1.5×"
        case 2.0: formatted = "2×"
        default:  formatted = "1×"
        }
        speedButton.setTitle(formatted, for: .normal)
    }

    // MARK: - Show / Hide

    func show(in parentView: UIView, below topAnchorRef: NSLayoutYAxisAnchor) {
        guard superview == nil else { return }
        parentView.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
            topAnchor.constraint(equalTo: topAnchorRef),
            heightAnchor.constraint(equalToConstant: MiniAudioPlayerView.height),
        ])
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: -MiniAudioPlayerView.height)
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func hide(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: -MiniAudioPlayerView.height)
        }, completion: { _ in
            self.removeFromSuperview()
            self.alpha = 1
            self.transform = .identity
            completion?()
        })
    }

    // MARK: - Actions

    @objc private func didTapPlayPause() { onPlayPause?() }
    @objc private func didTapSpeed() { onSpeedToggle?() }
    @objc private func didTapClose() { onClose?() }
}
