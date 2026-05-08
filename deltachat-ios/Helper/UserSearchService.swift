import Foundation
import DcCore

final class UserSearchService {

    private static let baseURLString = "https://api.alt-to.online/v1/users/search"
    private static let debounceInterval: TimeInterval = 0.4
    private static let timeoutInterval: TimeInterval = 15
    /// Minimum interval between consecutive re-registration attempts triggered by 401.
    private static let reRegisterCooldown: TimeInterval = 60

    private let dcContext: DcContext
    private var accountId: Int { dcContext.id }
    private var debounceTimer: Timer?
    private var currentRequestId = 0
    private var lastReRegisterAttempt: Date?

    init(dcContext: DcContext) {
        self.dcContext = dcContext
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
            self.fireRequest(query: query, isRetry: false) { result in
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

    private func fireRequest(query: String, isRetry: Bool, completion: @escaping (Result<[RemoteUser], Error>) -> Void) {
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
            logger.info("UserSearchService: no JWT token for account \(accountId), sending unauthenticated request")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        logger.info("UserSearchService: searching for \"\(query)\" (authenticated=\(hasToken))")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    logger.info("UserSearchService: network error for \"\(query)\": \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.success([]))
                    return
                }
                guard httpResponse.statusCode == 200 else {
                    logger.info("UserSearchService: HTTP \(httpResponse.statusCode) for \"\(query)\"")
                    if httpResponse.statusCode == 401 && !isRetry {
                        self.recoverAuthAndRetry(query: query, completion: completion)
                        return
                    }
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
                    logger.info("UserSearchService: found \(users.count) user(s) for \"\(query)\"")
                    completion(.success(users))
                } catch {
                    logger.info("UserSearchService: decode error for \"\(query)\": \(error)")
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    /// Called when a search request receives HTTP 401. Re-registers on a background
    /// thread (rate-limited to once per 60 s), then retries the search exactly once.
    private func recoverAuthAndRetry(query: String, completion: @escaping (Result<[RemoteUser], Error>) -> Void) {
        let fail401: () -> Void = {
            DispatchQueue.main.async {
                let err = NSError(domain: "UserSearchService", code: 401,
                                 userInfo: [NSLocalizedDescriptionKey: "Unauthorized"])
                completion(.failure(err))
            }
        }

        if let last = lastReRegisterAttempt,
           Date().timeIntervalSince(last) < Self.reRegisterCooldown {
            logger.info("UserSearchService: re-registration skipped (cooldown)")
            fail401()
            return
        }
        lastReRegisterAttempt = Date()

        logger.info("UserSearchService: 401 received — attempting re-registration before retry")
        let ctx = dcContext
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            guard let displayName = ctx.displayname, !displayName.isEmpty else {
                logger.info("UserSearchService: re-registration skipped — no display name")
                fail401()
                return
            }
            AltPlatformService(dcContext: ctx).quickRegister(displayName: displayName)
            guard KeychainManager.loadJwtToken(accountId: ctx.id) != nil else {
                logger.info("UserSearchService: re-registration did not produce a token")
                fail401()
                return
            }
            logger.info("UserSearchService: re-registration succeeded — retrying search")
            self.fireRequest(query: query, isRetry: true, completion: completion)
        }
    }
}
