import UIKit

final class AppUpdateChecker {

    static let shared = AppUpdateChecker()

    static let updateCheckCompletedNotification = Notification.Name("AppUpdateCheckCompleted")

    let appStoreURL = URL(string: "https://apps.apple.com/ua/app/alt-chat/id6763624908")!

    var isUpdateAvailable = false

    func checkForUpdate(completion: ((Bool) -> Void)? = nil) {
        let url = URL(string: "https://itunes.apple.com/lookup?id=6763624908")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data else { return }
            let updateAvailable = self.parseResponse(data: data)
            DispatchQueue.main.async {
                self.isUpdateAvailable = updateAvailable
                NotificationCenter.default.post(name: AppUpdateChecker.updateCheckCompletedNotification, object: nil)
                completion?(updateAvailable)
            }
        }.resume()
    }

    // MARK: - Private

    private init() {}

    private func parseResponse(data: Data) -> Bool {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]],
            let first = results.first,
            let storeVersionString = first["version"] as? String,
            let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else {
            return false
        }
        return isNewerVersion(storeVersionString, than: currentVersionString)
    }

    private func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let toComponents = { (v: String) in v.split(separator: ".").compactMap { Int($0) } }
        let c = toComponents(candidate)
        let cur = toComponents(current)
        let maxLen = max(c.count, cur.count)
        for i in 0..<maxLen {
            let a = i < c.count ? c[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
