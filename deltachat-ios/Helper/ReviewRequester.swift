import StoreKit

final class ReviewRequester {

    static let shared = ReviewRequester()
    private let requiredDays = 7

    /// Call on every app launch. Records first launch date on first call,
    /// then requests a review once the app has been installed for 7+ days.
    /// iOS limits the actual prompt to 3 times per 365 days.
    func requestReviewIfEligible() {
        recordFirstLaunchDateIfNeeded()

        guard let firstLaunch = firstLaunchDate,
              daysSince(firstLaunch) >= requiredDays else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else { return }
            SKStoreReviewController.requestReview(in: scene)
        }
    }

    // MARK: - Private

    private init() {}

    private var firstLaunchDate: Date? {
        let ts = UserDefaults.standard.double(forKey: UserDefaults.firstLaunchDateKey)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private func recordFirstLaunchDateIfNeeded() {
        let ts = UserDefaults.standard.double(forKey: UserDefaults.firstLaunchDateKey)
        guard ts == 0 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UserDefaults.firstLaunchDateKey)
    }

    private func daysSince(_ date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
    }
}
