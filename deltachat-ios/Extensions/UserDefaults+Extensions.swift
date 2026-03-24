import Foundation

extension UserDefaults {
    static let onlineStatusEnabledKey = "pref_online_status_enabled"

    func populateDefaultEmojis() {
        let keys = DefaultReactions.allCases
            .reversed()
            .map { return "\($0.emoji)-usage-timestamps" }

        for key in keys {
            if array(forKey: key) == nil {
                setValue([Date().timeIntervalSince1970], forKey: key)
            } else if let timestamps = array(forKey: key), timestamps.isEmpty {
                setValue([Date().timeIntervalSince1970], forKey: key)
            }
        }
    }
}
