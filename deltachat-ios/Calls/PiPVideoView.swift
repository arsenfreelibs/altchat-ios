import UIKit
import DcCore
import AVKit
import WebRTC

class PiPVideoView: UIView {
    private var fromChat: DcChat

    /// Called when the remote peer enables or disables their video.
    var onVideoEnabled: ((Bool) -> Void)?
    private var avatarFallbackHidden = false
    private var isPiPActive = false
    private var isVideoEnabled = false

    private let pipInfoStatusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 11)
        l.textColor = UIColor.white.withAlphaComponent(0.75)
        l.textAlignment = .center
        return l
    }()

    /// Container view in which the video renderer view is placed when not in PiP
    private lazy var videoCallSourceView = UIView()
    /// We need to change the source view's height to have a good looking transition to and from PiP
    private lazy var videoCallSourceViewHeightConstraint: NSLayoutConstraint = {
        videoCallSourceView.heightAnchor.constraint(equalToConstant: frame.height)
    }()

    /// The view that is shown in the picture in picture window
    private lazy var pipView = UIView()

    /// The view that renders the video
    /// Note: Do not add subviews as this view may be rotated if the video source was rotated
    private lazy var renderView = {
        let renderView = PiPVideoRendererView(frame: frame)
        return renderView
    }()

    private lazy var avatarView: UIView = {
        let badge = InitialsBadge(size: 200)
        badge.setName(fromChat.name)
        badge.setColor(fromChat.color)
        badge.setImage(fromChat.profileImage)
        // Original InitialsBadge does not scale so convert to image
        let imageView = UIImageView(image: badge.asImage())
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private lazy var pipInfoOverlay: UIView = {
        let overlay = UIView()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        overlay.isHidden = true

        let badge = InitialsBadge(size: 64)
        badge.setName(fromChat.name)
        badge.setColor(fromChat.color)
        badge.setImage(fromChat.profileImage)
        let avatarIV = UIImageView(image: badge.asImage())
        avatarIV.contentMode = .scaleAspectFit
        avatarIV.layer.cornerRadius = 32
        avatarIV.layer.masksToBounds = true
        avatarIV.translatesAutoresizingMaskIntoConstraints = false
        avatarIV.widthAnchor.constraint(equalToConstant: 64).isActive = true
        avatarIV.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let nameLabel = UILabel()
        nameLabel.text = fromChat.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.adjustsFontSizeToFitWidth = true

        let stack = UIStackView(arrangedSubviews: [avatarIV, nameLabel, pipInfoStatusLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -8),
        ])
        return overlay
    }()

    /// - Note: Returns nil on iOS 14
    lazy var pipController: AVPictureInPictureController? = {
        guard #available(iOS 15.0, *) else { return nil }
        let pipController = AVPictureInPictureController(contentSource: .init(
            activeVideoCallSourceView: videoCallSourceView,
            contentViewController: AVPictureInPictureVideoCallViewController()
        ))
        pipController.canStartPictureInPictureAutomaticallyFromInline = true
        return pipController
    }()

    init(fromChat: DcChat, frame: CGRect) {
        self.fromChat = fromChat
        super.init(frame: frame)

        backgroundColor = .clear
        videoCallSourceView.backgroundColor = .clear

        addSubview(videoCallSourceView)
        videoCallSourceView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            videoCallSourceView.centerXAnchor.constraint(equalTo: centerXAnchor),
            videoCallSourceView.centerYAnchor.constraint(equalTo: centerYAnchor),
            videoCallSourceView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 1.0),
            videoCallSourceViewHeightConstraint,
        ])

        pipView.addSubview(renderView)
        renderView.fillSuperview()
        renderView.isHidden = true
        pipView.addSubview(avatarView)
        avatarView.centerInSuperview()
        avatarView.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true

        pipView.addSubview(pipInfoOverlay)
        pipInfoOverlay.fillSuperview()

        videoCallSourceView.addSubview(pipView)
        pipView.fillSuperview()

        pipController?.delegate = self
        resetSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension PiPVideoView: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
        updatePiPFallback()
        if #available(iOS 15.0, *) {
            let pipVC = pictureInPictureController.contentSource?.activeVideoCallContentViewController
            pipView.removeFromSuperview()
            pipVC?.view.addSubview(pipView)
            pipView.fillSuperview()
        }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        CallWindow.shared?.showCallUI()
        completionHandler(true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
        updatePiPFallback()
        pipView.removeFromSuperview()
        videoCallSourceView.addSubview(pipView)
        pipView.fillSuperview()
        videoCallSourceView.setNeedsLayout()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        CallWindow.shared?.showCallUI()
    }
}

extension PiPVideoView: RTCVideoRenderer {
    /// Reset to a square
    func resetSize() {
        setSize(CGSize(width: frame.size.width, height: frame.size.width))
    }

    func setSize(_ size: CGSize) {
        renderView.frameProcessor?.setSize(size)
        DispatchQueue.main.async { [self] in
            guard size.width > 0 else { return }
            setPiPPreferredContentSize(size)
            videoCallSourceViewHeightConstraint.constant = frame.width / size.width * size.height
            videoCallSourceView.setNeedsLayout()
        }
    }
    
    func renderFrame(_ frame: RTCVideoFrame?) {
        renderView.frameProcessor?.renderFrame(frame)
    }

    private func setPiPPreferredContentSize(_ size: CGSize) {
        guard #available(iOS 15.0, *) else { return }
        pipController?.contentSource?.activeVideoCallContentViewController.preferredContentSize = size
    }

    /// Hides the built-in avatar fallback. Use when the call screen provides its own avatar overlay.
    func hideAvatarFallback() {
        avatarFallbackHidden = true
        avatarView.isHidden = true
    }

    func updateVideoEnabled(_ videoEnabled: Bool) {
        isVideoEnabled = videoEnabled
        renderView.isHidden = !videoEnabled
        updatePiPFallback()
        if !avatarFallbackHidden {
            avatarView.isHidden = videoEnabled
        }
        if !videoEnabled {
            renderView.displayLayer?.flushAndRemoveImage()
            resetSize()
        }
        onVideoEnabled?(videoEnabled)
    }

    func updatePiPStatus(_ text: String) {
        pipInfoStatusLabel.text = text
    }

    private func updatePiPFallback() {
        assert(Thread.isMainThread)
        pipInfoOverlay.isHidden = !(isPiPActive && !isVideoEnabled)
    }
}

/// A view that can render an RTCVideoTrack in PiP using AVSampleBufferDisplayLayer.
/// This is required because MTKViews are not supported in PiP before iOS 18.
private class PiPVideoRendererView: UIView {
    fileprivate var frameProcessor: PiPFrameProcessor?
    fileprivate var displayLayer: AVSampleBufferDisplayLayer?

    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        displayLayer = layer as? AVSampleBufferDisplayLayer
        guard let displayLayer else { return }
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = UIColor.clear.cgColor
        displayLayer.flushAndRemoveImage()
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true

        frameProcessor = PiPFrameProcessor(displayLayer: displayLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
