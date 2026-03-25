import AVFoundation
import DcCore
import UIKit
import WebRTC

// TODO: Minimize call to PiP when app is opened from a deeplink (or from a notification)
// TODO: Fix missed call logic: if the missed call was from me dont send notification
// TODO: Actually stop capturing mic when muted
// FIXME: Still doesn't always work when in background

class CallViewController: UIViewController {
    var call: DcCall
    private lazy var dcChat: DcChat = DcAccounts.shared.get(id: call.contextId).getChat(chatId: call.chatId)
    private lazy var factory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    private var mutedStateDataChannel: RTCDataChannel?
    private var iceTricklingDataChannel: RTCDataChannel?
    /// Stores local ICE candidates to be sent to the remote peer when the data channel opens.
    private var iceTricklingBuffer: [RTCIceCandidate] = []
    private let iceTricklingBufferLock = NSLock()
    @Published private var gatheredEnoughIce = false
    private let rtcAudioSession = RTCAudioSession.sharedInstance()
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoCapturer: RTCCameraVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?

    // MARK: - Ringback tone

    /// Plays a synthetic 440+480 Hz ringback tone (2 s on / 4 s off) during outgoing ringing.
    private final class RingbackPlayer {
        private let engine = AVAudioEngine()
        // node must be retained; engine keeps a weak reference internally on some OS versions.
        private var node: AVAudioSourceNode?
        // Match the hardware sample rate to avoid Core Audio sample-rate conversion.
        private let sampleRate: Double = AVAudioSession.sharedInstance().sampleRate

        func start() {
            guard node == nil else { return }
            let sr = sampleRate
            guard sr > 0 else { return }
            // Copy mutable state into locals so the render callback avoids retaining self.
            // The callback runs on a real-time thread; capturing self (even weakly) is unsafe.
            var p1: Double = 0, p2: Double = 0, ct: Double = 0
            let sourceNode = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!) {
                _, _, frameCount, audioBufferList in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for frame in 0..<Int(frameCount) {
                    ct += 1.0 / sr
                    if ct >= 6.0 { ct -= 6.0 }
                    var sample: Float = 0
                    if ct < 2.0 {
                        p1 += 2.0 * .pi * 440.0 / sr
                        p2 += 2.0 * .pi * 480.0 / sr
                        sample = Float(0.15 * (sin(p1) + sin(p2)))
                    }
                    for buffer in abl {
                        UnsafeMutableBufferPointer<Float>(buffer)[frame] = sample
                    }
                }
                return noErr
            }
            node = sourceNode
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: engine.mainMixerNode, format: sourceNode.outputFormat(forBus: 0))
            try? engine.start()
        }

        func stop() {
            engine.stop()
            if let n = node { engine.detach(n) }
            node = nil
        }
    }

    private var ringbackPlayer: RingbackPlayer?

    // MARK: - Call state
    private enum CallState { case ringing, connecting, connected }
    private var callState: CallState = .ringing
    private var ringingDotsTimer: Timer?
    private var callDurationTimer: Timer?
    private var callStartDate: Date?
    private var dotCount = 0

    // MARK: - Appearance
    private let backgroundGradientLayer = CAGradientLayer()
    private var ringingAnimationLayers: [CAShapeLayer] = []

    private static let gradientColors: [CGColor] = [
        UIColor(hexString: "064E3B").cgColor,
        UIColor(hexString: "065F46").cgColor,
        UIColor(hexString: "047857").cgColor,
    ]
    private static let ringStrokeColor = UIColor(hexString: "34d399").withAlphaComponent(0.9).cgColor

    // MARK: - Local video
    private lazy var localVideoView: RTCMTLVideoView = {
        let videoView = RTCMTLVideoView(frame: .zero)
        videoView.videoContentMode = .scaleAspectFill
        videoView.layer.cornerRadius = 20
        videoView.layer.cornerCurve = .continuous
        videoView.layer.masksToBounds = true
        return videoView
    }()

    private lazy var localVideoContainerView: UIView = {
        let shadowView = UIView()
        shadowView.layer.cornerRadius = 20
        shadowView.layer.cornerCurve = .continuous
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOffset = CGSize(width: 4, height: 4)
        shadowView.layer.shadowOpacity = 0.2
        shadowView.layer.shadowRadius = 5.0
        shadowView.isHidden = !call.hasVideoInitially
        return shadowView
    }()

    private var remoteVideoTrack: RTCVideoTrack?
    private lazy var remoteVideoView: PiPVideoView = PiPVideoView(fromChat: dcChat, frame: view.frame)
    private var setupTask: Task<Void, Never>?

    private lazy var glowBlob1: UIView = makeGlowBlob(size: 280)
    private lazy var glowBlob2: UIView = makeGlowBlob(size: 300)

    // MARK: - Call info overlay
    private let callInfoView = UIView()
    private let avatarRingContainerView: UIView = {
        let v = UIView()
        v.isUserInteractionEnabled = false
        return v
    }()

    private lazy var avatarImageView: UIImageView = {
        let badge = InitialsBadge(size: 125)
        badge.setName(dcChat.name)
        badge.setColor(dcChat.color)
        badge.setImage(dcChat.profileImage)
        let iv = UIImageView(image: badge.asImage())
        iv.contentMode = .scaleAspectFit
        iv.layer.cornerRadius = 62.5
        iv.layer.masksToBounds = true
        return iv
    }()

    private lazy var contactNameLabel: UILabel = {
        let label = UILabel()
        label.text = dcChat.name
        label.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        return label
    }()

    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.textAlignment = .center
        return label
    }()

    // MARK: - Control buttons

    private lazy var hangupButton: UIButton = {
        let btn = CallUIToggleButton(
            imageSystemName: "phone.down.fill",
            state: false,
            fixedOverlayColor: UIColor.systemRed.withAlphaComponent(0.80)
        )
        btn.addAction(UIAction { [weak self] _ in self?.hangup() }, for: .touchUpInside)
        return btn
    }()

    private lazy var toggleMicrophoneButton: CallUIToggleButton = {
        let btn = CallUIToggleButton(imageSystemName: "mic.fill", offImageSystemName: "mic.slash.fill", state: true)
        btn.addAction(UIAction { [weak self, weak btn] _ in
            guard let self, let btn else { return }
            btn.toggleState.toggle()
            localAudioTrack?.isEnabled.toggle()
            shareMutedState()
        }, for: .touchUpInside)
        return btn
    }()

    private lazy var toggleVideoButton: CallUIToggleButton = {
        let btn = CallUIToggleButton(imageSystemName: "video.fill", offImageSystemName: "video.slash.fill", state: localVideoTrack?.isEnabled == true)
        btn.addAction(UIAction { [weak self, weak btn] _ in
            guard let self, let btn else { return }
            btn.toggleState.toggle()
            localVideoTrack?.isEnabled.toggle()
            localVideoContainerView.isHidden.toggle()
            flipCameraButton.isHidden = !btn.toggleState
            let transceiver = peerConnection?.transceivers.first { $0.mediaType == .video }
            transceiver?.sender.track = btn.toggleState ? localVideoTrack : nil
            if btn.toggleState {
                localVideoCapturer?.startCapture(facing: .front)
            } else {
                localVideoCapturer?.stopCapture()
            }
            rtcAudioSession.lockForConfiguration()
            try? rtcAudioSession.setMode(btn.toggleState ? .videoChat : .voiceChat)
            rtcAudioSession.unlockForConfiguration()
            shareMutedState()
        }, for: .touchUpInside)
        return btn
    }()

    private lazy var toggleSpeakerButton: CallUIToggleButton = {
        let btn = CallUIToggleButton(imageSystemName: "speaker.wave.3.fill", offImageSystemName: "speaker.slash.fill", state: false)
        btn.addAction(UIAction { [weak self, weak btn] _ in
            guard let self, let btn else { return }
            btn.toggleState.toggle()
            setSpeaker(enabled: btn.toggleState)
        }, for: .touchUpInside)
        return btn
    }()

    private lazy var startPiPButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "arrow.up.right.and.arrow.down.left"), for: .normal)
        btn.tintColor = .white
        btn.setPreferredSymbolConfiguration(.init(pointSize: 18, weight: .medium), forImageIn: .normal)
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOffset = .zero
        btn.layer.shadowRadius = 4
        btn.layer.shadowOpacity = 0.55
        btn.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let pc = remoteVideoView.pipController
            guard let pc, !pc.isPictureInPictureActive, pc.isPictureInPicturePossible else { return }
            pc.startPictureInPicture()
            CallWindow.shared?.hideCallUI()
        }, for: .touchUpInside)
        btn.isHidden = remoteVideoView.pipController == nil
        return btn
    }()

    private lazy var callButtonStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            toggleSpeakerButton,
            toggleVideoButton,
            toggleMicrophoneButton,
            hangupButton,
        ])
        stack.axis = .horizontal
        stack.spacing = 16
        stack.distribution = .fill
        stack.alignment = .center
        return stack
    }()

    private lazy var unreadMessageCounter: MessageCounter = {
        let counter = MessageCounter(count: 0, size: 20)
        counter.backgroundColor = DcColors.unreadBadge
        counter.isHidden = true
        counter.isAccessibilityElement = false
        counter.isUserInteractionEnabled = false
        return counter
    }()

    private lazy var flipCameraButton: UIButton = {
        let btn = CallUIToggleButton(imageSystemName: "camera.rotate.fill", size: 40, state: false)
        btn.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if let currentlyFacing = localVideoCapturer?.captureSession.inputs
                .compactMap({ $0 as? AVCaptureDeviceInput }).first?.device.position {
                localVideoCapturer?.startCapture(facing: currentlyFacing == .front ? .back : .front)
            }
        }, for: .touchUpInside)
        btn.isHidden = !call.hasVideoInitially
        return btn
    }()

    init(call: DcCall) {
        self.call = call
        super.init(nibName: nil, bundle: nil)

        #if DEBUG
        RTCSetMinDebugLogLevel(.warning)
        #endif
        RTCInitializeSSL()

        let config = RTCConfiguration()
        config.iceTransportPolicy = .all
        config.bundlePolicy = .maxBundle
        config.iceCandidatePoolSize = 1

        // If we set ice servers before creating peerconnection the factory can return nil
        config.iceServers = DcAccounts.shared.get(id: call.contextId).iceServers().map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }

        peerConnection = factory.peerConnection(with: config, constraints: .default, delegate: self)
        assert(peerConnection != nil)

        let iceTricklingConfig = RTCDataChannelConfiguration()
        iceTricklingConfig.isNegotiated = true
        iceTricklingConfig.channelId = 1
        iceTricklingDataChannel = peerConnection?.dataChannel(forLabel: "iceTrickling", configuration: iceTricklingConfig)
        iceTricklingDataChannel?.delegate = self
        assert(iceTricklingDataChannel != nil)

        let mutedStateConfig = RTCDataChannelConfiguration()
        mutedStateConfig.isNegotiated = true
        mutedStateConfig.channelId = 3
        mutedStateDataChannel = peerConnection?.dataChannel(forLabel: "mutedState", configuration: mutedStateConfig)
        mutedStateDataChannel?.delegate = self
        assert(mutedStateDataChannel != nil)

        NotificationCenter.default.addObserver(self, selector: #selector(handleOutgoingCallAcceptedEvent), name: Event.outgoingCallAccepted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        callState = call.direction == .outgoing ? .ringing : .connecting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        setupTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        ringingDotsTimer?.invalidate()
        callDurationTimer?.invalidate()
        ringbackPlayer?.stop()
        localVideoCapturer?.stopCapture()
        peerConnection?.close()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupStreams()
        configureAudioSession()
        if call.direction == .outgoing {
            ringbackPlayer = RingbackPlayer()
            ringbackPlayer?.start()
            // AVAudioEngine.start() may shift routing; re-pin to earpiece.
            rtcAudioSession.lockForConfiguration()
            try? rtcAudioSession.overrideOutputAudioPort(.none)
            rtcAudioSession.unlockForConfiguration()
        }

        backgroundGradientLayer.colors = Self.gradientColors
        backgroundGradientLayer.startPoint = CGPoint(x: 0, y: 0)
        backgroundGradientLayer.endPoint = CGPoint(x: 1, y: 1)
        view.layer.insertSublayer(backgroundGradientLayer, at: 0)

        view.addSubview(glowBlob1)
        glowBlob1.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glowBlob1.widthAnchor.constraint(equalToConstant: 280),
            glowBlob1.heightAnchor.constraint(equalToConstant: 280),
            glowBlob1.topAnchor.constraint(equalTo: view.topAnchor, constant: -60),
            glowBlob1.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -80),
        ])
        view.addSubview(glowBlob2)
        glowBlob2.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glowBlob2.widthAnchor.constraint(equalToConstant: 300),
            glowBlob2.heightAnchor.constraint(equalToConstant: 300),
            glowBlob2.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 80),
            glowBlob2.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 80),
        ])
        animateGlowBlobs()

        remoteVideoView.backgroundColor = .clear
        remoteVideoView.hideAvatarFallback()
        remoteVideoView.onVideoEnabled = { [weak self] videoEnabled in
            guard let self else { return }
            UIView.animate(withDuration: 0.3) {
                self.callInfoView.alpha = videoEnabled ? 0 : 1
            }
        }
        view.addSubview(remoteVideoView)
        remoteVideoView.fillSuperview()

        localVideoContainerView.addSubview(localVideoView)
        localVideoView.fillSuperview()
        view.addSubview(localVideoContainerView)
        localVideoContainerView.constraint(equalTo: CGSize(width: 150, height: 150))
        localVideoContainerView.alignTopToAnchor(view.safeAreaLayoutGuide.topAnchor, paddingTop: 10)
        localVideoContainerView.alignTrailingToAnchor(view.safeAreaLayoutGuide.trailingAnchor, paddingTrailing: 10)
        view.addSubview(flipCameraButton)
        flipCameraButton.alignBottomToAnchor(localVideoView.bottomAnchor, paddingBottom: 4)
        flipCameraButton.alignTrailingToAnchor(localVideoView.trailingAnchor, paddingTrailing: 4)

        setupCallInfoView()

        view.addSubview(startPiPButton)
        startPiPButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            startPiPButton.widthAnchor.constraint(equalToConstant: 36),
            startPiPButton.heightAnchor.constraint(equalToConstant: 36),
            startPiPButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            startPiPButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
        ])

        view.addSubview(unreadMessageCounter)
        unreadMessageCounter.alignTrailingToAnchor(startPiPButton.trailingAnchor)
        unreadMessageCounter.alignTopToAnchor(startPiPButton.topAnchor)
        setUnreadMessageCount(DcAccounts.shared.getFreshMessagesCount())

        view.addSubview(callButtonStackView)
        callButtonStackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            callButtonStackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            callButtonStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        setupTask = Task {
            guard let peerConnection else { return }
            switch call.direction {
            case .outgoing:
                do {
                    let offer = try await peerConnection.offer(for: RTCMediaConstraints.default)
                    try await peerConnection.setLocalDescription(offer)
                    if #available(iOS 15.0, *) {
                        _ = await $gatheredEnoughIce.values.first(where: \.self)
                    }
                    if call.messageId == nil {
                        let sdp = peerConnection.localDescription?.sdp ?? offer.sdp
                        let dcContext = DcAccounts.shared.get(id: call.contextId)
                        call.messageId = dcContext.placeOutgoingCall(chatId: call.chatId, placeCallInfo: sdp, hasVideoInitially: call.hasVideoInitially)
                    }
                } catch {
                    logger.error(error.localizedDescription)
                }
            case .incoming:
                do {
                    guard let placeCallInfo = call.placeCallInfo else {
                        logger.error("placeCallInfo missing for acceptCall")
                        // TODO: alert user?
                        CallManager.shared.endCallControllerAndHideUI()
                        return
                    }
                    try await peerConnection.setRemoteDescription(.init(type: .offer, sdp: placeCallInfo))
                    let answer = try await peerConnection.answer(for: RTCMediaConstraints.default)
                    try await peerConnection.setLocalDescription(answer)
                    if #available(iOS 15.0, *) {
                        _ = await $gatheredEnoughIce.values.first(where: \.self)
                    }
                    guard let messageId = call.messageId else { return logger.error("errAcceptCall: messageId not set") }
                    let sdp = peerConnection.localDescription?.sdp ?? answer.sdp
                    logger.info("acceptCall: " + sdp)
                    let dcContext = DcAccounts.shared.get(id: call.contextId)
                    call.callAcceptedHere = true
                    dcContext.acceptIncomingCall(msgId: messageId, acceptCallInfo: sdp)
                } catch {
                    logger.error(error.localizedDescription)
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backgroundGradientLayer.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if callState != .connected {
            startStatusAnimation()
        }
    }

    // MARK: - Call info overlay setup

    private func setupCallInfoView() {
        view.addSubview(callInfoView)
        callInfoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            callInfoView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            callInfoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            callInfoView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            callInfoView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])

        callInfoView.addSubview(avatarRingContainerView)
        avatarRingContainerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarRingContainerView.topAnchor.constraint(equalTo: callInfoView.topAnchor),
            avatarRingContainerView.centerXAnchor.constraint(equalTo: callInfoView.centerXAnchor),
            avatarRingContainerView.widthAnchor.constraint(equalToConstant: 200),
            avatarRingContainerView.heightAnchor.constraint(equalToConstant: 200),
        ])

        avatarRingContainerView.addSubview(avatarImageView)
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarImageView.centerXAnchor.constraint(equalTo: avatarRingContainerView.centerXAnchor),
            avatarImageView.centerYAnchor.constraint(equalTo: avatarRingContainerView.centerYAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 125),
            avatarImageView.heightAnchor.constraint(equalToConstant: 125),
        ])

        callInfoView.addSubview(contactNameLabel)
        contactNameLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contactNameLabel.topAnchor.constraint(equalTo: avatarRingContainerView.bottomAnchor, constant: 16),
            contactNameLabel.centerXAnchor.constraint(equalTo: callInfoView.centerXAnchor),
            contactNameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: callInfoView.leadingAnchor),
            contactNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: callInfoView.trailingAnchor),
        ])

        callInfoView.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: contactNameLabel.bottomAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: callInfoView.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: callInfoView.bottomAnchor),
        ])

        addRingingAnimationLayers()
    }

    // MARK: - Ring animation

    private func addRingingAnimationLayers() {
        let center = CGPoint(x: 100, y: 100)
        let radii: [CGFloat] = [72, 86, 100]
        let delays: [Double] = [0.0, 0.6, 1.2]

        for (radius, delay) in zip(radii, delays) {
            let shapeLayer = CAShapeLayer()
            let path = UIBezierPath(arcCenter: center, radius: radius,
                                    startAngle: 0, endAngle: .pi * 2, clockwise: true)
            shapeLayer.path = path.cgPath
            shapeLayer.fillColor = UIColor.clear.cgColor
            shapeLayer.strokeColor = Self.ringStrokeColor
            shapeLayer.lineWidth = 2
            shapeLayer.opacity = 0

            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 1.0
            scaleAnim.toValue = 1.5

            let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
            opacityAnim.values = [0.0, 0.65, 0.0]
            opacityAnim.keyTimes = [0, 0.3, 1.0]

            let group = CAAnimationGroup()
            group.animations = [scaleAnim, opacityAnim]
            group.duration = 1.8
            group.beginTime = CACurrentMediaTime() + delay
            group.repeatCount = .infinity
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)

            shapeLayer.add(group, forKey: "ring")
            avatarRingContainerView.layer.addSublayer(shapeLayer)
            ringingAnimationLayers.append(shapeLayer)
        }
    }

    private func stopRingingAnimation() {
        ringingAnimationLayers.forEach {
            $0.removeAllAnimations()
            $0.opacity = 0
            $0.isHidden = true
        }
    }

    // MARK: - Status text animation

    private func startStatusAnimation() {
        guard callState != .connected else { return }
        dotCount = 0
        let baseKey = callState == .ringing ? "call_status_ringing" : "call_status_connecting"
        let baseText = String.localized(baseKey)
        statusLabel.text = baseText
        remoteVideoView.updatePiPStatus(baseText)

        ringingDotsTimer?.invalidate()
        ringingDotsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, callState != .connected else { return }
            dotCount = (dotCount + 1) % 4
            let text = baseText + String(repeating: ".", count: dotCount)
            statusLabel.text = text
            remoteVideoView.updatePiPStatus(text)
        }
    }

    private func transitionToConnected() {
        assert(Thread.isMainThread)
        guard callState != .connected else { return }
        callState = .connected
        ringbackPlayer?.stop()
        ringbackPlayer = nil
        ringingDotsTimer?.invalidate()
        ringingDotsTimer = nil
        stopRingingAnimation()
        callStartDate = Date()
        updateDurationLabel()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateDurationLabel()
        }
        RunLoop.main.add(timer, forMode: .common)
        callDurationTimer = timer
    }

    private func updateDurationLabel() {
        guard let start = callStartDate else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let text = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        statusLabel.text = text
        remoteVideoView.updatePiPStatus(text)
    }

    // MARK: - Speaker

    private func setSpeaker(enabled: Bool) {
        rtcAudioSession.lockForConfiguration()
        do {
            try rtcAudioSession.overrideOutputAudioPort(enabled ? .speaker : .none)
        } catch {
            logger.error("Error toggling speaker: \(error)")
        }
        rtcAudioSession.unlockForConfiguration()
    }

    // MARK: - Background appearance

    private func makeGlowBlob(size: CGFloat) -> UIView {
        let v = UIView()
        v.backgroundColor = DcColors.primary.withAlphaComponent(0.38)
        v.layer.cornerRadius = size / 2
        v.isUserInteractionEnabled = false
        return v
    }

    private func animateGlowBlobs() {
        [glowBlob1, glowBlob2].enumerated().forEach { index, blob in
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 1.25
            pulse.duration = 3.0 + Double(index) * 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blob.layer.add(pulse, forKey: "pulse")
        }
    }

    // MARK: - Streams

    private func setupStreams() {
        let audioSource = factory.audioSource(with: RTCMediaConstraints.default)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "localAudioTrack")
        localAudioTrack = audioTrack
        peerConnection?.add(audioTrack, streamIds: ["localStream"])

        let videoSource = factory.videoSource()
        localVideoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        if call.hasVideoInitially {
            localVideoCapturer?.startCapture(facing: .front)
        }
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "localVideoTrack")
        peerConnection?.add(videoTrack, streamIds: ["localStream"])
        localVideoTrack = videoTrack
        localVideoTrack?.isEnabled = call.hasVideoInitially
        localVideoTrack?.add(localVideoView)
    }

    private func hangup() {
        ringingDotsTimer?.invalidate()
        ringingDotsTimer = nil
        callDurationTimer?.invalidate()
        callDurationTimer = nil
        CallManager.shared.endCallControllerAndHideUI()
    }

    private func configureAudioSession() {
        rtcAudioSession.lockForConfiguration()
        do {
            try rtcAudioSession.setCategory(.playAndRecord)
            try rtcAudioSession.setMode(call.hasVideoInitially ? .videoChat : .voiceChat)
            // Explicitly pin to earpiece so the call starts in earpiece by default.
            try rtcAudioSession.overrideOutputAudioPort(.none)
        } catch {
            logger.error("Error updating AVAudioSession category: \(error)")
        }
        rtcAudioSession.unlockForConfiguration()
    }

    func setUnreadMessageCount(_ messageCount: Int) {
        unreadMessageCounter.setCount(messageCount)
        unreadMessageCounter.isHidden = messageCount == 0
    }

    func shareMutedState() {
        guard mutedStateDataChannel?.readyState == .open else { return }
        _ = try? mutedStateDataChannel?.sendData(.init(data: JSONEncoder().encode(MutedState(
            audioEnabled: toggleMicrophoneButton.toggleState,
            videoEnabled: toggleVideoButton.toggleState
        )), isBinary: false))
    }

    // MARK: - Notifications

    @objc private func handleOutgoingCallAcceptedEvent(_ notification: Notification) {
        guard let ui = notification.userInfo,
              let accountId = ui["account_id"] as? Int,
              let msgId = ui["message_id"] as? Int,
              accountId == call.contextId && msgId == call.messageId,
              let acceptCallInfo = ui["accept_call_info"] as? String else { return }

        peerConnection?.setRemoteDescription(.init(type: .answer, sdp: acceptCallInfo)) { error in
            if let error { logger.error("setRemoteDescription failed: \(error)") }
        }
        DispatchQueue.main.async { [weak self] in self?.transitionToConnected() }
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        // show call and end pip when returning to foreground
        CallWindow.shared?.showCallUI()
        if remoteVideoView.pipController?.isPictureInPictureActive == true {
            remoteVideoView.pipController?.stopPictureInPicture()
        }
    }
}

extension CallViewController: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .connected || newState == .completed {
            DispatchQueue.main.async { [weak self] in self?.transitionToConnected() }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            DispatchQueue.main.async { [weak self] in
                self?.gatheredEnoughIce = true
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // gatheredEnoughIce logic explained: https://github.com/deltachat/calls-webapp/blob/8b0069202db64c6d66a7fb56be70b457c61bf5a6/src/lib/calls.ts#L333
        DispatchQueue.main.async { [weak self] in
            guard let self, !gatheredEnoughIce else { return }
            if candidate.sdp.contains("typ relay") {
                gatheredEnoughIce = true
            } else if candidate.sdp.contains("typ srflx") {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
                    self?.gatheredEnoughIce = true
                }
            }
        }
        if iceTricklingDataChannel?.readyState == .open {
            _ = try? iceTricklingDataChannel?.sendData(.init(data: candidate.toJSON(), isBinary: false))
        } else {
            iceTricklingBufferLock.lock()
            iceTricklingBuffer.append(candidate)
            iceTricklingBufferLock.unlock()
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if transceiver.mediaType == .video, let newTrack = transceiver.receiver.track as? RTCVideoTrack {
            remoteVideoTrack?.remove(remoteVideoView)
            remoteVideoTrack = newTrack
            remoteVideoTrack?.add(remoteVideoView)
            DispatchQueue.main.async { [weak self] in
                self?.remoteVideoView.updateVideoEnabled(true)
            }
        }
    }
}

extension CallViewController: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch (dataChannel.label, dataChannel.readyState) {
        case (iceTricklingDataChannel?.label, .open):
            iceTricklingBufferLock.lock()
            let pending = iceTricklingBuffer
            iceTricklingBuffer.removeAll()
            iceTricklingBufferLock.unlock()
            for candidate in pending {
                _ = try? dataChannel.sendData(.init(data: candidate.toJSON(), isBinary: false))
            }
        case (mutedStateDataChannel?.label, .open):
            DispatchQueue.main.async { [weak self] in self?.shareMutedState() }
        default: break
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        switch dataChannel.label {
        case iceTricklingDataChannel?.label:
            if let candidate = try? RTCIceCandidate.fromJSON(buffer.data) {
                peerConnection?.add(candidate, completionHandler: { _ in })
            }
        case mutedStateDataChannel?.label:
            if let remoteMutedState = try? JSONDecoder().decode(MutedState.self, from: buffer.data) {
                DispatchQueue.main.async { [weak self] in
                    self?.remoteVideoView.updateVideoEnabled(remoteMutedState.videoEnabled)
                }
            }
        default: break
        }
    }
}

private struct MutedState: Codable {
    let audioEnabled: Bool
    let videoEnabled: Bool
}
