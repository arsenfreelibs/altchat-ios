import UIKit

/// A view that draws a waveform as vertical rounded bars.
/// Bars before `progress` are drawn with `tintColor`; the rest with `tintColor.withAlphaComponent(0.25)`.
/// An empty `samples` array displays flat equal-height placeholder bars (loading state).
/// Tap or pan triggers `seekAction` with a normalized position in [0, 1].
public class WaveformView: UIView {

    // MARK: - Public properties

    /// Normalised amplitude samples, each in [0, 1]. Setting this triggers a redraw.
    public var samples: [Float] = [] {
        didSet { setNeedsDisplay() }
    }

    /// Playback progress in [0, 1]. Setting this triggers a redraw.
    public var progress: Float = 0 {
        didSet { setNeedsDisplay() }
    }

    /// Called when the user taps or drags on the view. Parameter is the seek position in [0, 1].
    public var seekAction: ((Float) -> Void)?

    // MARK: - Layout constants

    private let barCount: Int = 40
    private let barSpacingRatio: CGFloat = 0.4   // fraction of (barWidth + spacing) used as gap
    private let minBarHeightRatio: CGFloat = 0.15 // minimum bar height as fraction of available height

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSeekGesture(_:)))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSeekGesture(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    // MARK: - Drawing

    public override func draw(_ rect: CGRect) {
        let totalWidth = rect.width
        let totalHeight = rect.height
        let count = barCount

        // Bar + gap width
        let slotWidth = totalWidth / CGFloat(count)
        let barWidth = slotWidth * (1 - barSpacingRatio)
        let cornerRadius = barWidth / 2

        let playedColor = tintColor ?? UIColor.systemGreen
        let unplayedColor = playedColor.withAlphaComponent(0.25)
        let progressX = totalWidth * CGFloat(progress)

        for i in 0 ..< count {
            let normalizedAmplitude: CGFloat
            if samples.isEmpty {
                normalizedAmplitude = 0.25   // flat placeholder bars
            } else {
                let sampleIndex = Int(Float(i) / Float(count) * Float(samples.count))
                let clamped = min(max(samples[sampleIndex], 0), 1)
                normalizedAmplitude = CGFloat(clamped)
            }

            let barHeight = max(totalHeight * minBarHeightRatio,
                                totalHeight * normalizedAmplitude)
            let x = CGFloat(i) * slotWidth + (slotWidth - barWidth) / 2
            let y = (totalHeight - barHeight) / 2
            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)

            let barMidX = x + barWidth / 2
            let color = barMidX <= progressX ? playedColor : unplayedColor
            color.setFill()

            let path = UIBezierPath(roundedRect: barRect, cornerRadius: cornerRadius)
            path.fill()
        }
    }

    // MARK: - Seek gesture

    @objc private func handleSeekGesture(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended else { return }
        let x = gesture.location(in: self).x
        let seekProgress = Float(min(max(x / bounds.width, 0), 1))
        seekAction?(seekProgress)
    }
}
