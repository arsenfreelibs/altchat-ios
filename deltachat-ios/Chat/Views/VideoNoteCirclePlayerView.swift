import UIKit
import AVFoundation
import DcCore

/// 220-pt circular looping video player shown above the input bar during video note preview.
/// Auto-plays muted on `configure(url:)`. Mute is toggled by the built-in speaker button.
/// Call `setPlaying(_:)` from ChatViewController when the filmstrip bar's play/pause is tapped.
final class VideoNoteCirclePlayerView: UIView {

    // MARK: - Public

    /// Current playing state, mirrored from the AVPlayer.
    private(set) var isPlaying = false

    /// Current playback position in seconds.
    var currentTimeSeconds: Double { player?.currentTime().seconds ?? 0 }

    // MARK: - Private

    private let circleSize: CGFloat = 220
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var bgLayer: CALayer?          // black circle; kept as property so layoutSubviews can resize it
    private var itemEndObserver: NSObjectProtocol?
    private var isMuted = true

    // Progress ring drawn outside the clipped circle (same style as VideoNoteCell).
    private let progressTrackLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        l.fillColor = UIColor.clear.cgColor
        l.lineWidth = 4
        return l
    }()

    private let progressFillLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = UIColor.white.cgColor
        l.fillColor = UIColor.clear.cgColor
        l.lineWidth = 4
        l.strokeEnd = 0
        l.lineCap = .round
        return l
    }()

    private lazy var muteButton: UIButton = {
        let btn = UIButton(type: .system)
        let conf = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        btn.setImage(UIImage(systemName: "speaker.slash.fill", withConfiguration: conf), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        btn.layer.cornerRadius = 16
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        btn.accessibilityLabel = "Mute"
        return btn
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        player?.pause()
        playerLayer?.removeFromSuperlayer()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep bgLayer and playerLayer sized to bounds so they're correct
        // whether laid out before or after configure(url:) is called.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer?.frame = bounds
        bgLayer?.cornerRadius = bounds.width / 2
        playerLayer?.frame = bounds
        if let playerLayer {
            let mask = CAShapeLayer()
            mask.path = UIBezierPath(ovalIn: bounds).cgPath
            playerLayer.mask = mask
        }
        CATransaction.commit()
        updateProgressRingPath()
    }

    private func updateProgressRingPath() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = circleSize / 2 + 7
        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: 1.5 * .pi,
            clockwise: true
        ).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressTrackLayer.path = path
        progressFillLayer.path = path
        CATransaction.commit()
    }

    // MARK: - Setup

    private func setupUI() {
        clipsToBounds = false   // ring extends ~9pt outside; circle shape enforced by bgLayer mask + playerLayer mask
        backgroundColor = .clear

        // Black background circle — created once here so it exists even before configure(url:).
        let bg = CALayer()
        bg.backgroundColor = UIColor.black.cgColor
        bg.masksToBounds = true
        // frame and cornerRadius are set in layoutSubviews once bounds are known
        layer.addSublayer(bg)
        bgLayer = bg

        layer.addSublayer(progressTrackLayer)
        layer.addSublayer(progressFillLayer)

        addSubview(muteButton)
        NSLayoutConstraint.activate([
            muteButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            muteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            muteButton.widthAnchor.constraint(equalToConstant: 32),
            muteButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    // MARK: - Public API

    /// Load the video URL and start looping playback immediately (muted by default).
    func configure(url: URL) {
        // Clean up any previous player.
        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndObserver = nil
        }
        player?.pause()
        playerLayer?.removeFromSuperlayer()

        // bgLayer is already in the hierarchy (created in setupUI); no need to re-add it.
        // playerLayer goes above bgLayer (index 1).
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = 0  // muted by default
        isMuted = true
        updateMuteIcon()

        let newPlayerLayer = AVPlayerLayer(player: newPlayer)
        newPlayerLayer.videoGravity = .resizeAspectFill
        newPlayerLayer.frame = bounds
        // Apply circle mask immediately — layoutSubviews may not fire again after we insert
        // this layer, so the video would appear square without the mask being set here.
        if bounds != .zero {
            let circleMask = CAShapeLayer()
            circleMask.path = UIBezierPath(ovalIn: bounds).cgPath
            newPlayerLayer.mask = circleMask
        }
        if let bg = bgLayer {
            layer.insertSublayer(newPlayerLayer, above: bg)
        } else {
            layer.insertSublayer(newPlayerLayer, at: 0)
        }
        playerLayer = newPlayerLayer
        player = newPlayer

        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }

        newPlayer.play()
        isPlaying = true
        bringSubviewToFront(muteButton)
    }

    /// Toggle play / pause from outside (called by VideoNotePreviewBar's play button).
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if playing {
            player?.play()
        } else {
            player?.pause()
        }
    }

    /// Update the circular progress ring (0.0 … 1.0).
    func setProgress(_ progress: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressFillLayer.strokeEnd = CGFloat(max(0, min(1, progress)))
        CATransaction.commit()
    }

    // MARK: - Mute toggle

    @objc private func muteTapped() {
        isMuted.toggle()
        player?.volume = isMuted ? 0 : 1
        updateMuteIcon()
        muteButton.accessibilityLabel = isMuted ? "Unmute" : "Mute"
    }

    private func updateMuteIcon() {
        let name = isMuted ? "speaker.slash.fill" : "speaker.fill"
        let conf = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        muteButton.setImage(UIImage(systemName: name, withConfiguration: conf), for: .normal)
    }
}
