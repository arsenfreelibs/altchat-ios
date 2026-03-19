import UIKit
import DcCore

// a cell with a centered label in system blue

class ActionCell: UITableViewCell {

    static let reuseIdentifier = "action_cell_reuse_identifier"

    var actionTitle: String? {
        didSet {
            textLabel?.text = actionTitle
        }
    }

    var actionColor: UIColor? {
        didSet {
            textLabel?.textColor = actionColor ?? DcColors.primary
            if let imageView {
                imageView.tintColor = actionColor ?? DcColors.primary
            }
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        textLabel?.textColor = DcColors.primary
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
