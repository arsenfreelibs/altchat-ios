import UIKit
import AVFoundation

protocol VideoNoteRecorderDelegate: AnyObject {
    func videoNoteRecorder(_ recorder: VideoNoteRecorderView, didFinishRecordingAt url: URL?)
}

final class VideoNoteRecorderView: UIView, AVCaptureFileOutputRecordingDelegate {

    weak var delegate: VideoNoteRecorderDelegate?

    static let maxDuration: TimeInterval = 30

    private let circleSize: CGFloat = 220
    private let captureSession = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    /// Serial queue — all capture session work runs here exclusively.
    private let sessionQueue = DispatchQueue(label: "VideoNoteRecorderView.sessionQueue")

    private var progressTimer: Timer?
    private var elapsedTime: TimeInterval = 0
    private var cancelled = false

    // MARK: - Subviews

    private lazy var circleContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = true
        v.layer.cornerRadius = circleSize / 2
        v.backgroundColor = .black
        return v
    }()

    private let progressTrackLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        l.fillColor = UIColor.clear.cgColor
        l.lineWidth = 5
        return l
    }()

    private let progressFillLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = UIColor.systemRed.cgColor
        l.fillColor = UIColor.clear.cgColor
        l.lineWidth = 5
        l.strokeEnd = 0
        l.lineCap = .round
        return l
    }()

    private let durationLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = "0:00"
        l.textColor = .white
        l.font = .systemFont(ofSize: 16, weight: .medium)
        l.textAlignment = .center
        return l
    }()

    private let hintLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = "Release to send"
        l.textColor = UIColor.white.withAlphaComponent(0.75)
        l.font = .preferredFont(forTextStyle: .footnote)
        l.textAlignment = .center
        return l
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = circleContainer.bounds
        updateProgressRingPath()
    }

    // MARK: - UI Setup

    private func setupUI() {
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        addSubview(circleContainer)
        addSubview(durationLabel)
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            circleContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            circleContainer.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            circleContainer.widthAnchor.constraint(equalToConstant: circleSize),
            circleContainer.heightAnchor.constraint(equalToConstant: circleSize),

            durationLabel.topAnchor.constraint(equalTo: circleContainer.bottomAnchor, constant: 20),
            durationLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            hintLabel.topAnchor.constraint(equalTo: durationLabel.bottomAnchor, constant: 8),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])

        layer.addSublayer(progressTrackLayer)
        layer.addSublayer(progressFillLayer)
    }

    private func updateProgressRingPath() {
        guard circleContainer.frame != .zero else { return }
        let center = CGPoint(x: circleContainer.frame.midX, y: circleContainer.frame.midY)
        let radius = (circleSize / 2) + 9
        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: 1.5 * .pi,
            clockwise: true
        ).cgPath
        progressTrackLayer.path = path
        progressFillLayer.path = path
    }

    // MARK: - Capture Session Setup

    private func configureCaptureSession() {
        // Must be called on sessionQueue
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        guard
            let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
            captureSession.canAddInput(videoInput)
        else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(videoInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
            movieOutput.maxRecordedDuration = CMTime(
                seconds: VideoNoteRecorderView.maxDuration,
                preferredTimescale: 600
            )
        }

        if let connection = movieOutput.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }

        captureSession.commitConfiguration()
    }

    // MARK: - Recording

    func startRecording() {
        cancelled = false
        elapsedTime = 0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        // Run everything on the serial sessionQueue to avoid racing
        // beginConfiguration/commitConfiguration with startRunning.
        sessionQueue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.configureCaptureSession()
            self.captureSession.startRunning()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.cancelled {
                    self.cleanup()
                    self.delegate?.videoNoteRecorder(self, didFinishRecordingAt: nil)
                    return
                }
                self.addPreviewLayer()
                self.beginActualRecording()
            }
        }
    }

    private func addPreviewLayer() {
        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        preview.frame = circleContainer.bounds
        circleContainer.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    private func beginActualRecording() {
        guard !cancelled else { return }
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videonote_tmp_\(Int(Date().timeIntervalSince1970)).mp4")
        movieOutput.startRecording(to: tempURL, recordingDelegate: self)
        startProgressTimer()
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedTime += 0.05
            let progress = self.elapsedTime / VideoNoteRecorderView.maxDuration
            self.progressFillLayer.strokeEnd = CGFloat(min(progress, 1.0))
            let totalSeconds = Int(self.elapsedTime)
            self.durationLabel.text = String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        }
    }

    func stopRecording(cancel: Bool = false) {
        cancelled = cancel
        progressTimer?.invalidate()
        progressTimer = nil
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                // Session may still be starting up; stop it and report nil.
                self.captureSession.stopRunning()
                DispatchQueue.main.async {
                    self.previewLayer?.removeFromSuperlayer()
                    self.previewLayer = nil
                    self.delegate?.videoNoteRecorder(self, didFinishRecordingAt: nil)
                }
            }
        }
    }

    @objc private func handleAppWillResignActive() {
        stopRecording(cancel: true)
    }

    private func cleanup() {
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        cleanup()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let tooShort = self.elapsedTime < 1.0
            let isMaxDuration = (error as? NSError).map {
                $0.domain == AVFoundationErrorDomain &&
                $0.code == AVError.maximumDurationReached.rawValue
            } ?? false
            if self.cancelled || tooShort || (error != nil && !isMaxDuration) {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.delegate?.videoNoteRecorder(self, didFinishRecordingAt: nil)
            } else {
                self.delegate?.videoNoteRecorder(self, didFinishRecordingAt: outputFileURL)
            }
        }
    }
}
