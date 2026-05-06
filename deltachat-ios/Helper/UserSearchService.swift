import Foundation

final class UserSearchService {

    private static let baseURLString = "https://api.alt-to.online/v1/users/search"
    private static let debounceInterval: TimeInterval = 0.4
    private static let timeoutInterval: TimeInterval = 15

    private let accountId: Int
    private var debounceTimer: Timer?
    private var currentRequestId = 0

    init(accountId: Int) {
        self.accountId = accountId
    }

    /// Searches for users by name or username. Results are debounced (400 ms).
    /// - If `query` is shorter than 2 characters the timer is cancelled and
    ///   `completion` is called immediately with an empty array.
    /// - Stale responses (from requests that were superseded by a newer one)
    ///   are silently discarded.
    func search(query: String, completion: @escaping (Result<[RemoteUser], Error>) -> Void) {
        debounceTimer?.invalidate()

        guard query.count >= 2 else {
            currentRequestId += 1
            completion(.success([]))
            return
        }

        debounceTimer = Timer.scheduledTimer(withTimeInterval: Self.debounceInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.currentRequestId += 1
            let requestId = self.currentRequestId
            self.fireRequest(query: query) { result in
                guard self.currentRequestId == requestId else { return }
                completion(result)
            }
        }
    }

    func cancel() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        currentRequestId += 1
    }

    // MARK: - Private

    private func fireRequest(query: String, completion: @escaping (Result<[RemoteUser], Error>) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
              let url = URL(string: "\(Self.baseURLString)?q=\(encoded)") else {
            completion(.success([]))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: Self.timeoutInterval)
        let hasToken = KeychainManager.loadJwtToken(accountId: accountId) != nil
        if let token = KeychainManager.loadJwtToken(accountId: accountId) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            logger.debug("UserSearchService: no JWT token for account \(accountId), sending unauthenticated request")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        logger.debug("UserSearchService: searching for \"\(query)\" (authenticated=\(hasToken))")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    logger.debug("UserSearchService: network error for \"\(query)\": \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.success([]))
                    return
                }
                guard httpResponse.statusCode == 200 else {
                    logger.debug("UserSearchService: HTTP \(httpResponse.statusCode) for \"\(query)\"")
                    let err = NSError(domain: "UserSearchService", code: httpResponse.statusCode,
                                     userInfo: [NSLocalizedDescriptionKey: "Server error \(httpResponse.statusCode)"])
                    completion(.failure(err))
                    return
                }
                guard let data else {
                    completion(.success([]))
                    return
                }
                do {
                    let users = try JSONDecoder().decode([RemoteUser].self, from: data)
                    logger.debug("UserSearchService: found \(users.count) user(s) for \"\(query)\"")
                    completion(.success(users))
                } catch {
                    logger.debug("UserSearchService: decode error for \"\(query)\": \(error)")
                    completion(.failure(error))
                }
            }
        }.resume()
    }
}
