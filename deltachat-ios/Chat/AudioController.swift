import UIKit
import AVFoundation
import MediaPlayer
import DcCore

/// The `PlayerState` indicates the current audio controller state
public enum PlayerState {

    /// The audio controller is currently playing a sound
    case playing

    /// The audio controller is currently in pause state
    case pause

    /// The audio controller is not playing any sound and audioPlayer is nil
    case stopped
}

public protocol AudioControllerDelegate: AnyObject {
    func onAudioPlayFailed()
    /// Called during headless autoplay so the controller can bind a visible cell immediately.
    /// Return the `AudioMessageCell` currently displayed for `messageId`, or `nil` if not visible.
    func audioController(_ controller: AudioController, visibleCellForMessageId messageId: Int) -> AudioMessageCell?
}

/// Observed by a persistent global observer (e.g. AppCoordinator) that needs to show / update
/// a mini-player bar. Unlike `AudioControllerDelegate` this reference is never released while
/// the app is running.
public protocol AudioControllerMiniPlayerDelegate: AnyObject {
    /// Called when playback starts for a message.
    func audioController(_ controller: AudioController, didStartPlaying message: DcMsg)
    /// Called on each progress timer tick with the current progress (0.0–1.0).
    func audioController(_ controller: AudioController, didUpdateProgress progress: Float)
    /// Called when playback stops for any reason.
    func audioControllerDidStop(_ controller: AudioController)
}

/// The `AudioController` update UI for current audio cell that is playing a sound
/// and also creates and manage an `AVAudioPlayer` states, play, pause and stop.
open class AudioController: NSObject, AVAudioPlayerDelegate, AudioMessageCellDelegate {

    open weak var delegate: AudioControllerDelegate?
    /// Persistent observer for mini-player UI. Set once by AppCoordinator and never cleared.
    open weak var miniPlayerDelegate: AudioControllerMiniPlayerDelegate?

    lazy var audioSession: AVAudioSession = {
        let audioSession = AVAudioSession.sharedInstance()
        _ = try? audioSession.setCategory(AVAudioSession.Category.playback, options: [.defaultToSpeaker])
        return audioSession
    }()

    /// The `AVAudioPlayer` that is playing the sound
    open var audioPlayer: AVAudioPlayer?

    /// The `AudioMessageCell` that is currently playing sound
    open weak var playingCell: AudioMessageCell?

    /// The `MessageType` that is currently playing sound
    open var playingMessage: DcMsg?

    /// Specify if current audio controller state: playing, in pause or none
    open private(set) var state: PlayerState = .stopped

    private(set) var dcContext: DcContext
    private(set) var chatId: Int

    /// Current playback rate. Applied to new and resumed playback.
    private(set) var playbackRate: Float = {
        let saved = UserDefaults.standard.float(forKey: "audioPlaybackRate")
        return saved > 0 ? saved : 1.0
    }()

    /// The `Timer` that update playing progress
    internal var progressTimer: Timer?

    /// Cache of extracted waveform samples keyed by message id
    private var waveformCache: [Int: [Float]] = [:]

    // MARK: - Now Playing / lock-screen integration (#3090)
    /// Controller that currently owns the lock-screen "Now Playing" item and remote commands.
    /// We run one shared AudioController (AppCoordinator), so a single weak ref is enough to
    /// route remote-control events to whoever is actually playing.
    private static weak var nowPlayingController: AudioController?
    private static var remoteCommandsConfigured = false
    private var playingArtwork: MPMediaItemArtwork?
    private var shouldResumeAfterInterruption = false
    private var lastNowPlayingInfoUpdate = Date.distantPast

    // MARK: - Init Methods

    public init(dcContext: DcContext, chatId: Int, delegate: AudioControllerDelegate? = nil) {
        self.dcContext = dcContext
        self.chatId = chatId
        self.delegate = delegate
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(audioRouteChanged),
                                               name: AVAudioSession.routeChangeNotification,
                                               object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(audioSessionInterrupted),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
    }

    /// Updates the controller's context to the given chat so that autoplay targets the correct
    /// message list. Does NOT stop ongoing playback — audio continues across chat navigation.
    public func configure(dcContext: DcContext, chatId: Int) {
        self.dcContext = dcContext
        self.chatId = chatId
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Methods

    /// - Parameters:
    ///   - cell: The `NewAudioMessageCell` that needs to be configure.
    ///   - message: The `DcMsg` that configures the cell.
    ///
    /// - Note:
    ///   This protocol method is called by MessageKit every time an audio cell needs to be configure
    func update(_ cell: AudioMessageCell, with messageId: Int) {
        cell.delegate = self
        if playingMessage?.id == messageId, let player = audioPlayer {
            playingCell = cell
            cell.audioPlayerView.setProgress((player.duration == 0) ? 0 : Float(player.currentTime/player.duration))
            cell.audioPlayerView.showPlayLayout((player.isPlaying == true) ? true : false)
            cell.audioPlayerView.setDuration(duration: player.currentTime)
        }
        if let samples = waveformCache[messageId] {
            cell.audioPlayerView.setWaveform(samples)
        }
    }
    
    public func getAudioWaveform(messageId: Int, successHandler: @escaping (Int, [Float]) -> Void) {
        if let cached = waveformCache[messageId] {
            successHandler(messageId, cached)
            return
        }
        let message = dcContext.getMessage(id: messageId)
        guard let fileURL = message.fileURL else { return }
        AudioWaveformHelper.extractSamples(from: fileURL) { [weak self] samples in
            guard let self else { return }
            self.waveformCache[messageId] = samples
            successHandler(messageId, samples)
        }
    }

    public func seekAudio(messageId: Int, progress: Float) {
        guard let player = audioPlayer,
              playingMessage?.id == messageId else { return }
        player.currentTime = Double(progress) * player.duration
        playingCell?.audioPlayerView.setProgress(progress)
        playingCell?.audioPlayerView.setDuration(duration: player.currentTime)
    }

    public func getAudioDuration(messageId: Int, successHandler: @escaping (Int, Double) -> Void) {
        let message = dcContext.getMessage(id: messageId)
        if playingMessage?.id == messageId {
            // irgnore messages that are currently playing or recently paused
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let duration = message.duration
            if duration > 0 {
                DispatchQueue.main.async {
                    successHandler(messageId, Double(duration) / 1000)
                }
            } else if let fileURL = message.fileURL {
                let audioAsset = AVURLAsset.init(url: fileURL, options: nil)
                audioAsset.loadValuesAsynchronously(forKeys: ["duration"]) {
                    var error: NSError?
                    let status = audioAsset.statusOfValue(forKey: "duration", error: &error)
                    switch status {
                    case .loaded:
                        let duration = audioAsset.duration
                        let durationInSeconds = CMTimeGetSeconds(duration)
                        message.setLateFilingMediaSize(width: 0, height: 0, duration: Int(1000 * durationInSeconds))
                        DispatchQueue.main.async {
                            successHandler(messageId, Double(durationInSeconds))
                        }
                    case .failed:
                        logger.warning("loading audio message \(messageId) failed: \(String(describing: error?.localizedDescription))")
                    default: break
                    }
                }
            }
        }
    }

    public func playButtonTapped(cell: AudioMessageCell, messageId: Int) {
            let message = dcContext.getMessage(id: messageId)
            guard state != .stopped else {
                // There is no audio sound playing - prepare to start playing for given audio message
                playSound(for: message, in: cell)
                return
            }
            if playingMessage?.messageId == message.messageId {
                // tap occur in the current cell that is playing audio sound
                if state == .playing {
                    pauseSound(in: cell)
                } else {
                    resumeSound()
                }
            } else {
                // tap occur in a difference cell that the one is currently playing sound. First stop currently playing and start the sound for given message
                stopAnyOngoingPlaying()
                playSound(for: message, in: cell)
            }
    }

    /// Used to start play audio sound
    ///
    /// - Parameters:
    ///   - message: The `DcMsg` that contain the audio item to be played.
    ///   - audioCell: The `NewAudioMessageCell` that needs to be updated while audio is playing.
    open func playSound(for message: DcMsg, in audioCell: AudioMessageCell) {
        if message.type == DC_MSG_AUDIO || message.type == DC_MSG_VOICE {
            _ = try? audioSession.setActive(true)
            playingCell = audioCell
            playingMessage = message
            if let fileUrl = message.fileURL, let player = try? AVAudioPlayer(contentsOf: fileUrl) {
                audioPlayer = player
                audioPlayer?.enableRate = true
                audioPlayer?.prepareToPlay()
                audioPlayer?.rate = playbackRate
                audioPlayer?.delegate = self
                audioPlayer?.play()
                state = .playing
                audioCell.audioPlayerView.showPlayLayout(true)  // show pause button on audio cell
                startProgressTimer()
                beginNowPlaying(for: message)
                miniPlayerDelegate?.audioController(self, didStartPlaying: message)
            } else {
                delegate?.onAudioPlayFailed()
            }
        }
    }

    /// Used to pause the audio sound
    ///
    /// - Parameters:
    ///   - message: The `MessageType` that contain the audio item to be pause.
    ///   - audioCell: The `AudioMessageCell` that needs to be updated by the pause action.
    open func pauseSound(in audioCell: AudioMessageCell) {
        audioPlayer?.pause()
        state = .pause
        audioCell.audioPlayerView.showPlayLayout(false) // show play button on audio cell
        progressTimer?.invalidate()
    }

    /// Stops any ongoing audio playing if exists
    open func stopAnyOngoingPlaying() {
        // If the audio player is nil then we don't need to go through the stopping logic
        guard audioPlayer != nil else { return }
        stopInternally()
        miniPlayerDelegate?.audioControllerDidStop(self)
    }

    /// Internal stop: tears down the player but does NOT notify miniPlayerDelegate.
    /// Use when autoplay will immediately start the next message so the mini-player stays visible.
    private func stopInternally() {
        guard let player = audioPlayer else { return }
        player.stop()
        state = .stopped
        if let cell = playingCell {
            cell.audioPlayerView.setProgress(0.0)
            cell.audioPlayerView.showPlayLayout(false)
            cell.audioPlayerView.setDuration(duration: player.duration)
        }
        progressTimer?.invalidate()
        progressTimer = nil
        audioPlayer = nil
        playingMessage = nil
        playingCell = nil
        // playbackRate is intentionally NOT reset — it persists across messages.
        playingArtwork = nil
        shouldResumeAfterInterruption = false
        lastNowPlayingInfoUpdate = .distantPast
        if AudioController.nowPlayingController === self {
            AudioController.nowPlayingController = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        try? audioSession.setActive(false)
    }

    /// Resume a currently pause audio sound
    open func resumeSound() {
        guard let player = audioPlayer, let cell = playingCell else {
            stopAnyOngoingPlaying()
            return
        }
        player.prepareToPlay()
        player.rate = playbackRate
        player.play()
        state = .playing
        startProgressTimer()
        cell.audioPlayerView.showPlayLayout(true) // show pause button on audio cell
    }

    /// Set the playback rate (1.0 = normal, 1.5, 2.0 etc.).
    /// Persists the value to UserDefaults so it survives app restarts.
    open func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: "audioPlaybackRate")
        audioPlayer?.rate = rate
    }

    /// Toggle between playing and paused without requiring a cell reference.
    /// Use this from contexts where the AudioMessageCell is not available (e.g. mini-player).
    open func togglePlayPause() {
        guard let player = audioPlayer else { return }
        if state == .playing {
            player.pause()
            state = .pause
            progressTimer?.invalidate()
            playingCell?.audioPlayerView.showPlayLayout(false)
        } else {
            player.rate = playbackRate
            player.play()
            state = .playing
            startProgressTimer()
            playingCell?.audioPlayerView.showPlayLayout(true)
        }
        updateNowPlayingInfo()
    }

    // MARK: - Fire Methods
    @objc private func didFireProgressTimer(_ timer: Timer) {
        guard let player = audioPlayer else { return }
        let progress = player.duration == 0 ? Float(0) : Float(player.currentTime / player.duration)
        if let cell = playingCell {
            cell.audioPlayerView.setProgress(progress)
            cell.audioPlayerView.setDuration(duration: player.currentTime)
        }
        updateNowPlayingInfoIfNeeded()
        miniPlayerDelegate?.audioController(self, didUpdateProgress: progress)
    }

    // MARK: - Private Methods
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        progressTimer = Timer.scheduledTimer(timeInterval: 0.1,
                                             target: self,
                                             selector: #selector(AudioController.didFireProgressTimer(_:)),
                                             userInfo: nil,
                                             repeats: true)
    }

    // MARK: - AVAudioPlayerDelegate
    open func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedId = playingMessage?.id
        // Use stopInternally so the mini-player stays visible while we search for the next message.
        // startAutoplayAfter will notify audioControllerDidStop if the chain has ended.
        stopInternally()
        if let finishedId, flag {
            startAutoplayAfter(messageId: finishedId)
        } else {
            miniPlayerDelegate?.audioControllerDidStop(self)
        }
    }

    // MARK: - Autoplay

    /// Searches forward in the chat for the next audio/voice message after `messageId`
    /// and starts playing it headlessly (without requiring a visible cell).
    private func startAutoplayAfter(messageId: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let allMsgIds = self.dcContext.getChatMsgs(chatId: self.chatId, flags: 0)
            guard let currentIndex = allMsgIds.firstIndex(of: messageId) else {
                DispatchQueue.main.async { self.miniPlayerDelegate?.audioControllerDidStop(self) }
                return
            }
            for nextId in allMsgIds[(currentIndex + 1)...] {
                let msg = self.dcContext.getMessage(id: nextId)
                if msg.type == DC_MSG_AUDIO || msg.type == DC_MSG_VOICE {
                    DispatchQueue.main.async { self.startPlayingHeadless(message: msg) }
                    return
                }
            }
            // No next message found — the chain has ended.
            DispatchQueue.main.async { self.miniPlayerDelegate?.audioControllerDidStop(self) }
        }
    }

    /// Starts playback of `message` without a pre-existing cell reference.
    /// Immediately tries to bind the visible cell via the delegate so animations start right away;
    /// if the cell is off-screen, `update(_:with:)` will bind it when it scrolls into view.
    private func startPlayingHeadless(message: DcMsg) {
        guard let fileUrl = message.fileURL,
              let player = try? AVAudioPlayer(contentsOf: fileUrl) else {
            delegate?.onAudioPlayFailed()
            return
        }
        _ = try? audioSession.setActive(true)
        playingMessage = message
        audioPlayer = player
        audioPlayer?.enableRate = true
        audioPlayer?.prepareToPlay()
        audioPlayer?.rate = playbackRate
        audioPlayer?.delegate = self
        audioPlayer?.play()
        state = .playing
        // Bind the visible cell immediately so its animation starts without waiting for cellForRowAt.
        if let cell = delegate?.audioController(self, visibleCellForMessageId: message.id) {
            playingCell = cell
            cell.audioPlayerView.showPlayLayout(true)
        } else {
            playingCell = nil
        }
        startProgressTimer()
        beginNowPlaying(for: message)
        miniPlayerDelegate?.audioController(self, didStartPlaying: message)
    }

    open func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stopAnyOngoingPlaying()
    }

    // MARK: - AVAudioSession.routeChangeNotification handler
    @objc func audioRouteChanged(note: Notification) {
        guard let userInfo = note.userInfo,
              let reason = userInfo[AVAudioSessionRouteChangeReasonKey] as? Int,
              reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        // Headphones (or other output) unplugged: pause so audio doesn't suddenly blast out of
        // the built-in speaker. Self-contained pause — playingCell may be nil (e.g. off-screen).
        guard state == .playing, let player = audioPlayer else { return }
        player.pause()
        state = .pause
        progressTimer?.invalidate()
        playingCell?.audioPlayerView.showPlayLayout(false)
        updateNowPlayingInfo()
    }

    // MARK: - Now Playing / remote commands / interruptions (#3090)

    private func beginNowPlaying(for message: DcMsg) {
        AudioController.nowPlayingController = self
        AudioController.configureRemoteCommands()
        loadArtwork(for: message)
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfoIfNeeded() {
        guard Date().timeIntervalSince(lastNowPlayingInfoUpdate) >= 1 else { return }
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        guard let player = audioPlayer, let message = playingMessage else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let text = message.text, !text.isEmpty {
            info[MPMediaItemPropertyTitle] = text
        } else {
            info[MPMediaItemPropertyTitle] = String.localized(message.type == DC_MSG_VOICE ? "voice_message" : "audio")
        }
        info[MPMediaItemPropertyArtist] = dcContext.getChat(chatId: message.chatId).name
        if let playingArtwork {
            info[MPMediaItemPropertyArtwork] = playingArtwork
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = (state == .playing) ? Double(player.rate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlayingInfoUpdate = Date()
    }

    /// Loads the sender's avatar asynchronously and sets it as the lock-screen artwork.
    private func loadArtwork(for message: DcMsg) {
        playingArtwork = nil
        let contact = dcContext.getContact(id: message.fromContactId)
        guard let imageURL = contact.profileImageURL else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, messageId = message.id] in
            guard let data = try? Data(contentsOf: imageURL), let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                guard let self, self.playingMessage?.id == messageId else { return }
                self.playingArtwork = artwork
                self.updateNowPlayingInfo()
            }
        }
    }

    private static func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in routeRemoteCommand { $0.remotePlay() } }
        center.pauseCommand.addTarget { _ in routeRemoteCommand { $0.remotePause() } }
        center.togglePlayPauseCommand.addTarget { _ in routeRemoteCommand { $0.togglePlayPause() } }
        center.stopCommand.addTarget { _ in routeRemoteCommand { $0.stopAnyOngoingPlaying() } }
        // Lock-screen seek buttons: use ±15s skip (the default next/previous-track buttons would
        // otherwise show greyed-out, as there is no track list to navigate).
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .noActionableNowPlayingItem }
            return routeRemoteCommand { $0.remoteSkip(by: event.interval) }
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .noActionableNowPlayingItem }
            return routeRemoteCommand { $0.remoteSkip(by: -event.interval) }
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .noActionableNowPlayingItem }
            return routeRemoteCommand { controller in
                guard let player = controller.audioPlayer else { return }
                player.currentTime = event.positionTime
                controller.playingCell?.audioPlayerView.setProgress(player.duration == 0 ? 0 : Float(player.currentTime / player.duration))
                controller.updateNowPlayingInfo()
            }
        }
    }

    /// Routes a remote-control event to the currently playing controller, on the main thread.
    private static func routeRemoteCommand(_ action: @escaping (AudioController) -> Void) -> MPRemoteCommandHandlerStatus {
        let run = { () -> MPRemoteCommandHandlerStatus in
            guard let controller = nowPlayingController else { return .noActionableNowPlayingItem }
            action(controller)
            return .success
        }
        return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
    }

    /// Seek the current player by `seconds` (negative = backward), clamped to the message bounds.
    private func remoteSkip(by seconds: TimeInterval) {
        guard let player = audioPlayer else { return }
        let newTime = max(0, min(player.duration, player.currentTime + seconds))
        player.currentTime = newTime
        if let cell = playingCell {
            cell.audioPlayerView.setProgress(player.duration == 0 ? 0 : Float(newTime / player.duration))
            cell.audioPlayerView.setDuration(duration: newTime)
        }
        updateNowPlayingInfo()
    }

    private func remotePlay() {
        guard state == .pause else { return }
        togglePlayPause()
    }

    private func remotePause() {
        guard state == .playing else { return }
        togglePlayPause()
    }

    // MARK: - AVAudioSession.interruptionNotification handler
    @objc private func audioSessionInterrupted(note: Notification) {
        guard AudioController.nowPlayingController === self,
              let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        let handle = { [weak self] in
            guard let self, AudioController.nowPlayingController === self else { return }
            switch type {
            case .began:
                self.shouldResumeAfterInterruption = self.state == .playing
                if self.state == .playing { self.togglePlayPause() }
            case .ended:
                let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = self.shouldResumeAfterInterruption
                    && AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
                self.shouldResumeAfterInterruption = false
                if shouldResume, self.state == .pause {
                    _ = try? self.audioSession.setActive(true)
                    self.togglePlayPause()
                }
            @unknown default:
                break
            }
        }
        if Thread.isMainThread { handle() } else { DispatchQueue.main.async(execute: handle) }
    }
}
