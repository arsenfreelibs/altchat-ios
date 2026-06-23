import UIKit
import DcCore

class EmptyStateLabel: PaddingTextView {

    init(text: String? = nil) {
        super.init()
        backgroundColor = DcColors.systemMessageBackgroundColor
        label.textColor = DcColors.systemMessageFontColor
        layer.cornerRadius = 16
        label.clipsToBounds = true
        label.textAlignment = .center
        label.text = text
        paddingTop = 15
        paddingBottom = 15
        paddingLeading = 15
        paddingTrailing = 15
        translatesAutoresizingMaskIntoConstraints = false
    }

    func addCenteredTo(parentView: UIView, evadeKeyboard: Bool = false) {
        parentView.addSubview(self)
        // The parent may be a table's `backgroundView`, whose width is transiently 0
        // under its autoresizing mask before the table sizes it. Keep these margin
        // pins below `required` so that transient doesn't trigger a required-constraint
        // conflict in the log; the final layout is identical once the parent has width.
        let leading = leadingAnchor.constraint(equalTo: parentView.leadingAnchor, constant: 40)
        let trailing = trailingAnchor.constraint(equalTo: parentView.trailingAnchor, constant: -40)
        leading.priority = .required - 1
        trailing.priority = .required - 1
        leading.isActive = true
        trailing.isActive = true
        let safeArea = parentView.safeAreaLayoutGuide
        centerXAnchor.constraint(equalTo: safeArea.centerXAnchor).isActive = true
        let centerYConstraint = centerYAnchor.constraint(equalTo: safeArea.centerYAnchor)
        centerYConstraint.isActive = true
        if #available(iOS 15.0, *), evadeKeyboard {
            centerYConstraint.priority = .defaultHigh
            bottomAnchor.constraint(lessThanOrEqualTo: parentView.keyboardLayoutGuide.topAnchor, constant: -40).isActive = true
        }

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
