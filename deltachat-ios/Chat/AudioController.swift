import UIKit
import AVFoundation
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
    private(set) var chat: DcChat

    /// Current playback rate. Applied to new and resumed playback.
    private(set) var playbackRate: Float = {
        let saved = UserDefaults.standard.float(forKey: "audioPlaybackRate")
        return saved > 0 ? saved : 1.0
    }()

    /// The `Timer` that update playing progress
    internal var progressTimer: Timer?

    /// Cache of extracted waveform samples keyed by message id
    private var waveformCache: [Int: [Float]] = [:]

    // MARK: - Init Methods

    public init(dcContext: DcContext, chatId: Int, delegate: AudioControllerDelegate? = nil) {
        self.dcContext = dcContext
        self.chatId = chatId
        self.chat = dcContext.getChat(chatId: chatId)
        self.delegate = delegate
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(audioRouteChanged),
                                               name: AVAudioSession.routeChangeNotification,
                                               object: AVAudioSession.sharedInstance())
    }

    /// Updates the controller's context to the given chat so that autoplay targets the correct
    /// message list. Does NOT stop ongoing playback — audio continues across chat navigation.
    public func configure(dcContext: DcContext, chatId: Int) {
        self.dcContext = dcContext
        self.chatId = chatId
        self.chat = dcContext.getChat(chatId: chatId)
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
        } else {
            player.rate = playbackRate
            player.play()
            state = .playing
            startProgressTimer()
        }
    }

    // MARK: - Fire Methods
    @objc private func didFireProgressTimer(_ timer: Timer) {
        guard let player = audioPlayer else { return }
        let progress = player.duration == 0 ? Float(0) : Float(player.currentTime / player.duration)
        if let cell = playingCell {
            cell.audioPlayerView.setProgress(progress)
            cell.audioPlayerView.setDuration(duration: player.currentTime)
        }
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
        miniPlayerDelegate?.audioController(self, didStartPlaying: message)
    }

    open func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stopAnyOngoingPlaying()
    }

    // MARK: - AVAudioSession.routeChangeNotification handler
    @objc func audioRouteChanged(note: Notification) {
      if let userInfo = note.userInfo {
        if let reason = userInfo[AVAudioSessionRouteChangeReasonKey] as? Int {
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            // headphones plugged out
            resumeSound()
          }
        }
      }
    }
}
