import UIKit
import DcCore

/// Reusable full-screen passcode entry UI: title, subtitle, the PIN dots, an error label and a
/// custom numeric keypad. It owns the digit buffer and the shake/error feedback; concrete screens
/// (setup, lock) drive it through `onCodeEntered` and the `show*` / `set*` helpers.
///
/// A custom keypad (instead of the system keyboard) keeps the lock screen self-contained and always
/// visible, and leaves room for the biometric key.
class PasscodeEntryViewController: UIViewController {

    private let codeLength = PasscodeManager.passcodeLength

    /// Called once `codeLength` digits have been entered.
    var onCodeEntered: ((String) -> Void)?

    /// Shown as the bottom-left keypad key when `true` (stage 2: biometric unlock).
    var showsBiometricButton = false { didSet { biometricButton.isHidden = !showsBiometricButton } }
    var onBiometricTapped: (() -> Void)?

    private var enteredDigits = "" {
        didSet { dotsView.filledCount = enteredDigits.count }
    }

    // MARK: - Subviews

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = DcColors.defaultTextColor
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = DcColors.secondaryTextColor
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .systemRed
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var dotsView = PasscodeDotsView(totalCount: codeLength)

    private lazy var biometricButton: UIButton = makeKeyButton(systemImage: "faceid", action: #selector(biometricTapped))
    private lazy var backspaceButton: UIButton = makeKeyButton(systemImage: "delete.left", action: #selector(backspaceTapped))

    private lazy var keypadStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DcColors.defaultBackgroundColor
        biometricButton.isHidden = !showsBiometricButton
        setupLayout()
    }

    // The vertical passcode layout (header on top, keypad pinned to the bottom) does not fit
    // landscape; lock these screens to portrait.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var shouldAutorotate: Bool { true }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }

    private func setupLayout() {
        let headerStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        headerStack.axis = .vertical
        headerStack.spacing = 12
        headerStack.alignment = .fill
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerStack)
        view.addSubview(dotsView)
        view.addSubview(errorLabel)
        view.addSubview(keypadStack)
        buildKeypad()

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            headerStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
            headerStack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 48),

            dotsView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dotsView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 40),

            errorLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
            errorLabel.topAnchor.constraint(equalTo: dotsView.bottomAnchor, constant: 20),

            keypadStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            keypadStack.widthAnchor.constraint(equalToConstant: 280),
            keypadStack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
            keypadStack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -24),
            keypadStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
        ])
    }

    private func buildKeypad() {
        let rows: [[KeypadKey]] = [
            [.digit(1), .digit(2), .digit(3)],
            [.digit(4), .digit(5), .digit(6)],
            [.digit(7), .digit(8), .digit(9)],
            [.biometric, .digit(0), .backspace],
        ]
        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.spacing = 12
            for key in row {
                switch key {
                case .digit(let value):
                    rowStack.addArrangedSubview(wrapKey(makeDigitButton(value)))
                case .biometric:
                    rowStack.addArrangedSubview(wrapKey(biometricButton))
                case .backspace:
                    rowStack.addArrangedSubview(wrapKey(backspaceButton))
                }
            }
            keypadStack.addArrangedSubview(rowStack)
        }
    }

    private enum KeypadKey {
        case digit(Int)
        case biometric
        case backspace
    }

    // MARK: - Public API

    func setTitleText(_ text: String) { titleLabel.text = text }
    func setSubtitle(_ text: String?) {
        subtitleLabel.text = text
        subtitleLabel.isHidden = (text == nil)
    }

    /// Clear the entered digits (and optionally the error message).
    func reset(clearError: Bool = true) {
        enteredDigits = ""
        if clearError { errorLabel.text = nil }
    }

    /// Show an error, shake the dots and clear the buffer.
    func showError(_ message: String) {
        errorLabel.text = message
        enteredDigits = ""
        shakeDots()
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Enable/disable digit entry (used while locked out).
    func setKeypadEnabled(_ enabled: Bool) {
        keypadStack.isUserInteractionEnabled = enabled
        keypadStack.alpha = enabled ? 1 : 0.4
    }

    func setErrorText(_ text: String?) { errorLabel.text = text }

    // MARK: - Input handling

    private func appendDigit(_ digit: Int) {
        guard enteredDigits.count < codeLength else { return }
        errorLabel.text = nil
        enteredDigits.append(String(digit))
        if enteredDigits.count == codeLength {
            let code = enteredDigits
            // Let the dot fill render before handing off.
            DispatchQueue.main.async { [weak self] in
                self?.onCodeEntered?(code)
            }
        }
    }

    @objc private func digitTapped(_ sender: UIButton) {
        appendDigit(sender.tag)
    }

    @objc private func backspaceTapped() {
        guard !enteredDigits.isEmpty else { return }
        enteredDigits.removeLast()
    }

    @objc private func biometricTapped() {
        onBiometricTapped?()
    }

    // MARK: - Button factories

    private static let keyDiameter: CGFloat = 72

    /// Center a fixed-size key inside a flexible grid cell so keys stay round and evenly spaced.
    /// The key is pinned top/bottom so the container derives its height from the key (otherwise the
    /// rows would collapse to zero height and overlap).
    private func wrapKey(_ key: UIView) -> UIView {
        let container = UIView()
        key.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(key)
        NSLayoutConstraint.activate([
            key.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            key.topAnchor.constraint(equalTo: container.topAnchor),
            key.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            key.widthAnchor.constraint(equalToConstant: Self.keyDiameter),
            key.heightAnchor.constraint(equalToConstant: Self.keyDiameter),
        ])
        return container
    }

    private func makeDigitButton(_ value: Int) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(String(value), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 32, weight: .regular)
        button.setTitleColor(DcColors.defaultTextColor, for: .normal)
        button.backgroundColor = .secondarySystemFill
        button.layer.cornerRadius = Self.keyDiameter / 2
        button.tag = value
        button.addTarget(self, action: #selector(digitTapped(_:)), for: .touchUpInside)
        return button
    }

    private func makeKeyButton(systemImage: String, action: Selector) -> UIButton {
        // Backspace/biometric keys read as secondary: no filled circle.
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemImage), for: .normal)
        button.tintColor = DcColors.defaultTextColor
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - Animation

    private func shakeDots() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [-12, 12, -10, 10, -6, 6, 0]
        animation.duration = 0.4
        dotsView.layer.add(animation, forKey: "shake")
    }
}

/// Navigation controller that forwards orientation to its top view controller, so a wrapped
/// passcode screen can keep the flow in portrait (UINavigationController otherwise reports all
/// orientations regardless of its content).
final class PasscodePortraitNavigationController: UINavigationController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return topViewController?.supportedInterfaceOrientations ?? .portrait
    }
    override var shouldAutorotate: Bool {
        return topViewController?.shouldAutorotate ?? true
    }
}
