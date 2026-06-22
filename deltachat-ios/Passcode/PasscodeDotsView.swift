import UIKit
import DcCore

/// Row of PIN dots; the first `filledCount` are filled, the rest are outlined.
class PasscodeDotsView: UIView {

    private let dotSize: CGFloat = 14
    private let spacing: CGFloat = 22

    private var dots: [UIView] = []

    var filledCount: Int = 0 {
        didSet { updateDots() }
    }

    init(totalCount: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        for _ in 0..<totalCount {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = dotSize / 2
            dot.layer.borderWidth = 1.5
            dot.layer.borderColor = DcColors.defaultTextColor.cgColor
            dot.widthAnchor.constraint(equalToConstant: dotSize).isActive = true
            dot.heightAnchor.constraint(equalToConstant: dotSize).isActive = true
            stack.addArrangedSubview(dot)
            dots.append(dot)
        }
        updateDots()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // cgColor does not follow light/dark automatically.
        for (index, dot) in dots.enumerated() {
            dot.layer.borderColor = DcColors.defaultTextColor.cgColor
            dot.backgroundColor = index < filledCount ? DcColors.defaultTextColor : .clear
        }
    }

    private func updateDots() {
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = index < filledCount ? DcColors.defaultTextColor : .clear
        }
    }
}
