import UIKit
import AVFoundation
import DcCore

/// Full-width bar shown in the input area after a locked video note recording stops.
/// Layout: [🗑️] [pill: ▶/⏸ | filmstrip with read-only position line] [↑]
/// The pill's filmstrip shows evenly-spaced thumbnail frames; a thin vertical line
/// tracks playback position (read-only). Playback itself is in VideoNoteCirclePlayerView.
final class VideoNotePreviewBar: UIView {

    // MARK: - Callbacks

    var deleteAction: (() -> Void)?
    var sendAction: (() -> Void)?
    var resumeAction: (() -> Void)?
    /// Called with the new `isPlaying` state when user taps play/pause.
    var playToggleAction: ((Bool) -> Void)?

    // MARK: - State

    private var isPlaying = true  // auto-play on open
    private var totalDuration: Double = 0
    private var filmstripWidth: CGFloat = 0

    // MARK: - Subviews

    private lazy var deleteButton: UIButton = {
        let btn = UIButton(type: .system)
        let conf = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        btn.setImage(UIImage(systemName: "trash", withConfiguration: conf), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = DcColors.primary
        btn.layer.cornerRadius = 20
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        btn.accessibilityLabel = String.localized("delete")
        return btn
    }()

    var sendButtonWindowFrame: CGRect? {
        sendButton.superview?.convert(sendButton.frame, to: nil)
    }

    private lazy var sendButton: UIButton = {
        let btn = UIButton(type: .system)
        let conf = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        btn.setImage(UIImage(systemName: "arrow.up", withConfiguration: conf), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = DcColors.primary
        btn.layer.cornerRadius = 20
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        btn.accessibilityLabel = String.localized("send")
        return btn
    }()

    private lazy var pillView: UIView = {
        let v = UIView()
        v.backgroundColor = DcColors.systemMessageBackgroundColor
        v.layer.cornerRadius = 18
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var playButton: UIButton = {
        let btn = UIButton(type: .system)
        let conf = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        btn.setImage(UIImage(systemName: "pause.fill", withConfiguration: conf), for: .normal)
        btn.tintColor = DcColors.primary
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        btn.accessibilityLabel = String.localized("menu_play")
        return btn
    }()

    /// Clip-bounds container for the filmstrip image views + position indicator.
    private lazy var filmstripContainer: UIView = {
        let v = UIView()
        v.clipsToBounds = true
        v.layer.cornerRadius = 6
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        return v
    }()

    /// Stack that holds the thumbnail UIImageViews side-by-side.
    private lazy var filmstripStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.distribution = .fillEqually
        sv.alignment = .fill
        sv.spacing = 0
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    /// Thin white vertical line that moves with playback progress (read-only).
    private lazy var positionIndicator: UIView = {
        let v = UIView()
        v.backgroundColor = .white
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private var positionIndicatorLeading: NSLayoutConstraint?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    func configure(url: URL, duration: Double) {
        totalDuration = duration
        // Extract thumbnails asynchronously after layout completes so we know the filmstrip width.
        DispatchQueue.main.async { [weak self] in
            self?.extractFilmstrip(url: url)
        }
    }

    /// Move the position indicator. `progress` in [0, 1].
    func setProgress(_ progress: Float) {
        guard filmstripWidth > 0 else { return }
        let x = CGFloat(progress) * filmstripWidth
        positionIndicatorLeading?.constant = x
        // No animation — called at 20 Hz for smooth scrubbing feel.
    }

    // MARK: - Layout

    private func setupView() {
        backgroundColor = .clear

        addSubview(deleteButton)
        addSubview(sendButton)
        addSubview(pillView)

        pillView.addSubview(playButton)
        pillView.addSubview(filmstripContainer)
        filmstripContainer.addSubview(filmstripStack)
        filmstripContainer.addSubview(positionIndicator)

        let leading = positionIndicator.leadingAnchor.constraint(equalTo: filmstripContainer.leadingAnchor)
        positionIndicatorLeading = leading

        NSLayoutConstraint.activate([
            // Delete — left edge
            deleteButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 40),
            deleteButton.heightAnchor.constraint(equalToConstant: 40),

            // Send — right edge
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sendButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 40),
            sendButton.heightAnchor.constraint(equalToConstant: 40),

            // Pill — fills the space between delete and send buttons
            pillView.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 8),
            pillView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            pillView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillView.heightAnchor.constraint(equalToConstant: 36),

            // Play button — left inside pill
            playButton.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 10),
            playButton.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 24),
            playButton.heightAnchor.constraint(equalToConstant: 24),

            // Filmstrip container — fills remaining pill width
            filmstripContainer.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 8),
            filmstripContainer.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -8),
            filmstripContainer.topAnchor.constraint(equalTo: pillView.topAnchor, constant: 4),
            filmstripContainer.bottomAnchor.constraint(equalTo: pillView.bottomAnchor, constant: -4),

            // Filmstrip stack — fills container
            filmstripStack.leadingAnchor.constraint(equalTo: filmstripContainer.leadingAnchor),
            filmstripStack.trailingAnchor.constraint(equalTo: filmstripContainer.trailingAnchor),
            filmstripStack.topAnchor.constraint(equalTo: filmstripContainer.topAnchor),
            filmstripStack.bottomAnchor.constraint(equalTo: filmstripContainer.bottomAnchor),

            // Position indicator — full height, 2 pt wide
            leading,
            positionIndicator.topAnchor.constraint(equalTo: filmstripContainer.topAnchor),
            positionIndicator.bottomAnchor.constraint(equalTo: filmstripContainer.bottomAnchor),
            positionIndicator.widthAnchor.constraint(equalToConstant: 2),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        filmstripWidth = filmstripContainer.bounds.width
    }

    // MARK: - Filmstrip extraction

    private static let frameCount = 10

    private func extractFilmstrip(url: URL) {
        let asset = AVURLAsset(url: url)
        let count = Self.frameCount
        guard totalDuration > 0 else { return }

        // Add placeholder views immediately.
        for _ in 0..<count {
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            filmstripStack.addArrangedSubview(iv)
        }

        // Pulse the filmstrip container so the user sees it's loading.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.35
        pulse.toValue = 0.85
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        filmstripContainer.layer.add(pulse, forKey: "filmstripPulse")

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 80, height: 80)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        let times: [NSValue] = (0..<count).map { i in
            let t = totalDuration * Double(i) / Double(count)
            return NSValue(time: CMTime(seconds: t, preferredTimescale: 600))
        }

        var index = 0
        var completedCount = 0
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] _, cgImage, _, result, _ in
            guard let self else { return }
            let i = index
            index += 1
            completedCount += 1
            if result == .succeeded, let cgImage {
                let image = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    guard i < self.filmstripStack.arrangedSubviews.count,
                          let iv = self.filmstripStack.arrangedSubviews[i] as? UIImageView else { return }
                    iv.image = image
                }
            }
            if completedCount >= count {
                DispatchQueue.main.async {
                    self.filmstripContainer.layer.removeAnimation(forKey: "filmstripPulse")
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func deleteTapped() { deleteAction?() }
    @objc private func sendTapped() { sendAction?() }

    @objc private func playTapped() {
        isPlaying.toggle()
        let conf = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let name = isPlaying ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: name, withConfiguration: conf), for: .normal)
        playToggleAction?(isPlaying)
    }
}
