import UIKit
import AVFoundation
import DcCore

/// Full-width bar shown in the input area after a locked audio note recording stops.
/// Replicates Telegram's pre-send voice note preview: delete | [▶ waveform duration] | send.
final class AudioNotePreviewBar: UIView {

    // MARK: - Callbacks

    var deleteAction: (() -> Void)?
    var sendAction: (() -> Void)?
    var resumeAction: (() -> Void)?

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

    /// Returns the send button's frame in window coordinates — used by ChatViewController to
    /// position the window-level mic-resume button above it (same pattern as lockContainer).
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

    /// Pill-shaped container that holds play button + waveform + duration label.
    private lazy var pillView: UIView = {
        let v = UIView()
        v.backgroundColor = DcColors.systemMessageBackgroundColor
        v.layer.cornerRadius = 18
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var playButton: UIButton = {
        let btn = UIButton(type: .system)
        let conf = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        btn.setImage(UIImage(systemName: "play.fill", withConfiguration: conf), for: .normal)
        btn.setImage(UIImage(systemName: "stop.fill", withConfiguration: conf), for: .selected)
        btn.tintColor = DcColors.primary
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        btn.accessibilityLabel = String.localized("menu_play")
        return btn
    }()

    private lazy var waveformView: WaveformView = {
        let v = WaveformView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.tintColor = DcColors.primary
        v.seekAction = { [weak self] progress in self?.seek(to: progress) }
        return v
    }()

    private lazy var durationLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = DcColors.primary
        label.text = "0:00"
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    // MARK: - Playback state

    private var player: AVAudioPlayer?
    private var audioFileURL: URL?
    private var progressTimer: Timer?
    private var totalDuration: Double = 0

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        progressTimer?.invalidate()
        player?.stop()
    }

    // MARK: - Public

    /// Call once after init. Stores the URL and triggers async waveform extraction.
    /// Player is created lazily on first play tap to avoid audio-session race with the recorder.
    func configure(url: URL, duration: Double) {
        audioFileURL = url
        totalDuration = duration
        durationLabel.text = formatted(duration)

        AudioWaveformHelper.extractSamples(from: url) { [weak self] samples in
            self?.waveformView.samples = samples
        }
    }

    // MARK: - Layout

    private func setupView() {
        backgroundColor = .clear  // transparent — input bar's blur/background shows through

        addSubview(deleteButton)
        addSubview(sendButton)
        addSubview(pillView)
        pillView.addSubview(playButton)
        pillView.addSubview(waveformView)
        pillView.addSubview(durationLabel)

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

            // Duration — right inside pill
            durationLabel.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -10),
            durationLabel.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),

            // Waveform — between play and duration
            waveformView.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 6),
            waveformView.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -6),
            waveformView.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
            waveformView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Actions

    @objc private func deleteTapped() {
        stopPlayback()
        deleteAction?()
    }

    @objc private func sendTapped() {
        stopPlayback()
        sendAction?()
    }

    @objc private func playTapped() {

        if let player, player.isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    // MARK: - Playback control

    private func startPlayback() {
        // Lazily create the player the first time play is tapped.
        // Session must be activated BEFORE AVAudioPlayer(contentsOf:) — the player
        // initialises hardware resources that require an active session.
        if player == nil, let url = audioFileURL {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                player = p
            } catch {
                logger.warning("[Preview] cannot create player — \(error)")
                return
            }
        }
        guard let player else { return }
        if player.play() {
            playButton.isSelected = true
            startProgressTimer()
        } else {
            logger.warning("[Preview] play() returned false")
        }
    }

    private func stopPlayback() {
        player?.stop()
        player?.currentTime = 0
        playButton.isSelected = false
        stopProgressTimer()
        waveformView.progress = 0
        durationLabel.text = formatted(totalDuration)
    }

    private func seek(to progress: Float) {
        guard let player else { return }
        player.currentTime = Double(progress) * player.duration
        waveformView.progress = progress
        durationLabel.text = formatted(player.currentTime)
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tickProgress()
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tickProgress() {
        guard let player, player.duration > 0 else { return }
        waveformView.progress = Float(player.currentTime / player.duration)
        durationLabel.text = formatted(player.currentTime)
    }

    // MARK: - Helpers

    private func formatted(_ t: Double) -> String {
        let t = max(0, t)
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        return String(format: "%d:%02d", mm, ss)
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioNotePreviewBar: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        playButton.isSelected = false
        stopProgressTimer()
        waveformView.progress = 0
        durationLabel.text = formatted(totalDuration)
    }
}
