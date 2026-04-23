import UIKit
import AVFoundation
import DcCore

class VideoNoteCell: BaseMessageCell, ReusableCell {

    static let reuseIdentifier = "VideoNoteCell"

    private static let noteSize: CGFloat = 200

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: Any?
    private var progressTimer: Timer?
    private var isPlaying = false
    /// Guards against stale async duration callbacks after cell reuse.
    private var currentMsgId: Int = -1

    // Progress ring drawn on contentView.layer, around the circle
    private let progressTrackLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        l.fillColor = UIColor.clear.cgColor
        l.lineWidth = 4
        l.isHidden = true
        return l
    }()

    private let progressFillLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = UIColor.white.cgColor
        l.fillColor = UIColor.clear.cgColor
        l.lineWidth = 4
        l.strokeEnd = 0
        l.lineCap = .round
        l.isHidden = true
        return l
    }()

    private lazy var videoContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = true
        v.layer.cornerRadius = VideoNoteCell.noteSize / 2
        v.backgroundColor = .black
        return v
    }()

    private lazy var playIconView: UIImageView = {
        let iv = UIImageView(
            image: UIImage(systemName: "play.fill")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 36, weight: .medium))
        )
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.tintColor = .white
        iv.contentMode = .center
        return iv
    }()

    /// Semi-transparent pill shown at the bottom-left of the circle, mirroring the
    /// send-time status view at the bottom-right.
    private lazy var durationPillView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = DcColors.systemMessageBackgroundColor
        v.layer.cornerRadius = 5
        v.layer.masksToBounds = true
        v.isHidden = true
        return v
    }()

    private lazy var durationLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = UIFont.preferredFont(for: .caption1, weight: .regular)
        l.textColor = .white
        l.textAlignment = .left
        l.isAccessibilityElement = false
        return l
    }()

    // MARK: - Setup

    override func setupSubviews() {
        super.setupSubviews()

        // CRITICAL: UIStackView default alignment (.fill) adds required implicit constraints
        // that force every arranged subview to fill the stack's full width. This conflicts with
        // the fixed 200pt width constraint → videoContainer stretches to cell width →
        // cornerRadius=100 on a ~340pt-wide view draws a rounded rect, not a circle.
        // .center lets videoContainer keep its exact 200×200 size.
        mainContentView.alignment = .center

        // The progress ring (radius = noteSize/2 + 7 = 107pt) extends ~9pt beyond the circle.
        // Without padding the ring draws outside the cell bounds and overlaps neighboring cells.
        // 10pt top+bottom gives the ring just enough room to stay within contentView.
        mainContentView.isLayoutMarginsRelativeArrangement = true
        mainContentView.insetsLayoutMarginsFromSafeArea = false   // prevent iOS safe-area from inflating the bottom margin for cells near the screen edge
        mainContentView.layoutMargins = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

        videoContainer.addSubview(playIconView)
        mainContentView.addArrangedSubview(videoContainer)

        durationPillView.addSubview(durationLabel)
        messageBackgroundContainer.addSubview(durationPillView)

        NSLayoutConstraint.activate([
            videoContainer.widthAnchor.constraint(equalToConstant: VideoNoteCell.noteSize),
            videoContainer.heightAnchor.constraint(equalToConstant: VideoNoteCell.noteSize),
            playIconView.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            playIconView.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor),

            // Duration pill: mirror statusView position (trailing - 8, bottom - 6) to leading + 8, bottom - 6
            durationLabel.topAnchor.constraint(equalTo: durationPillView.topAnchor),
            durationLabel.bottomAnchor.constraint(equalTo: durationPillView.bottomAnchor),
            durationLabel.leadingAnchor.constraint(equalTo: durationPillView.leadingAnchor, constant: 5),
            durationPillView.trailingAnchor.constraint(equalTo: durationLabel.trailingAnchor, constant: 5),
            durationPillView.leadingAnchor.constraint(equalTo: messageBackgroundContainer.leadingAnchor, constant: 8),
            durationPillView.bottomAnchor.constraint(equalTo: messageBackgroundContainer.bottomAnchor, constant: -6),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(onVideoTapped))
        videoContainer.isUserInteractionEnabled = true
        videoContainer.addGestureRecognizer(tap)

        // Progress ring sits above all subviews in contentView
        contentView.layer.addSublayer(progressTrackLayer)
        contentView.layer.addSublayer(progressFillLayer)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = videoContainer.bounds
        updateProgressRingPath()
    }

    private func updateProgressRingPath() {
        guard videoContainer.frame != .zero else { return }
        let center = contentView.convert(
            CGPoint(x: videoContainer.bounds.midX, y: videoContainer.bounds.midY),
            from: videoContainer
        )
        let radius = VideoNoteCell.noteSize / 2 + 7
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

    // MARK: - Update

    override func update(
        dcContext: DcContext,
        msg: DcMsg,
        messageStyle: UIRectCorner,
        showAvatar: Bool,
        showName: Bool,
        showViewCount: Bool,
        searchText: String? = nil,
        highlight: Bool
    ) {
        cleanupPlayer()

        if let url = msg.fileURL {
            let newPlayer = AVPlayer(url: url)
            let newLayer = AVPlayerLayer(player: newPlayer)
            newLayer.videoGravity = .resizeAspectFill
            newLayer.frame = videoContainer.bounds
            videoContainer.layer.insertSublayer(newLayer, at: 0)
            player = newPlayer
            playerLayer = newLayer
        }

        playIconView.isHidden = false
        progressTrackLayer.isHidden = true
        progressFillLayer.isHidden = true
        progressFillLayer.strokeEnd = 0
        messageBackgroundContainer.skipApplyMask = true
        isTransparent = true
        bottomCompactView = true
        showBottomLabelBackground = true
        topCompactView = msg.quoteText == nil
        mainContentView.spacing = 0
        messageLabel.text = nil
        a11yDcType = String.localized("video")

        // Duration pill
        currentMsgId = msg.id
        let durationMs = msg.duration
        if durationMs > 0 {
            showDuration(seconds: Double(durationMs) / 1000.0)
        } else {
            durationPillView.isHidden = true
            // Fallback: read duration from the local file (covers old messages
            // and incoming messages where the sender didn't store duration metadata).
            if let url = msg.fileURL {
                let msgId = msg.id
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let asset = AVURLAsset(url: url)
                    let seconds = CMTimeGetSeconds(asset.duration)
                    guard seconds > 0 else { return }
                    // Cache it so subsequent opens don't need to re-read.
                    msg.setLateFilingMediaSize(width: 0, height: 0, duration: Int(seconds * 1000))
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.currentMsgId == msgId else { return }
                        self.showDuration(seconds: seconds)
                    }
                }
            }
        }

        super.update(
            dcContext: dcContext,
            msg: msg,
            messageStyle: messageStyle,
            showAvatar: showAvatar,
            showName: showName,
            showViewCount: showViewCount,
            searchText: searchText,
            highlight: highlight
        )
    }

    private func showDuration(seconds: Double) {
        let text: String
        if seconds < 60 {
            text = String(format: "0:%02d", Int(seconds.rounded(.up)))
        } else {
            text = String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
        }
        durationLabel.text = text
        durationPillView.isHidden = false
    }

    // MARK: - Inline Playback

    @objc private func onVideoTapped() {
        if isPlaying {
            player?.pause()
            stopProgressTimer()
            playIconView.isHidden = false
            progressTrackLayer.isHidden = true
            progressFillLayer.isHidden = true
            isPlaying = false
        } else {
            guard let player else { return }

            // Spring pop: briefly grows then snaps back to indicate playback start
            UIView.animate(withDuration: 0.10, delay: 0, options: .curveEaseOut) {
                self.videoContainer.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            } completion: { _ in
                UIView.animate(withDuration: 0.14, delay: 0,
                               usingSpringWithDamping: 0.5, initialSpringVelocity: 6) {
                    self.videoContainer.transform = .identity
                }
            }

            if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.stopProgressTimer()
                self.player?.seek(to: .zero)
                self.isPlaying = false
                self.playIconView.isHidden = false
                self.progressTrackLayer.isHidden = true
                self.progressFillLayer.isHidden = true
                self.progressFillLayer.strokeEnd = 0
            }

            player.seek(to: .zero)
            // Activate .playback audio session so sound plays through the speaker
            // even when the silent/ringer switch is off, matching AudioController behaviour.
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.defaultToSpeaker])
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            playIconView.isHidden = true
            // Recalculate ring path to match current videoContainer position (accounts
            // for table view scrolling, cell reuse, or any pending layout change).
            updateProgressRingPath()
            progressTrackLayer.isHidden = false
            progressFillLayer.isHidden = false
            isPlaying = true
            startProgressTimer()
        }
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self,
                  let item = self.player?.currentItem,
                  item.duration.isNumeric,
                  item.duration.seconds > 0 else { return }
            let progress = (self.player?.currentTime().seconds ?? 0) / item.duration.seconds
            self.progressFillLayer.strokeEnd = CGFloat(min(max(progress, 0), 1))
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func cleanupPlayer() {
        player?.pause()
        stopProgressTimer()
        isPlaying = false
        if let obs = loopObserver {
            NotificationCenter.default.removeObserver(obs)
            loopObserver = nil
        }
        playerLayer?.removeFromSuperlayer()
        player = nil
        playerLayer = nil
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        cleanupPlayer()
        videoContainer.transform = .identity
        playIconView.isHidden = false
        progressTrackLayer.isHidden = true
        progressFillLayer.isHidden = true
        progressFillLayer.strokeEnd = 0
        durationPillView.isHidden = true
        durationLabel.text = nil
        currentMsgId = -1
    }
}
