import Foundation

final class UserSearchService {

    // TODO: Replace with real JWT token from auth service once authentication is implemented
    private static let accessToken = "fake_access_token"
    private static let baseURLString = "https://api.alt-to.online/v1/users/search"
    private static let debounceInterval: TimeInterval = 0.4
    private static let timeoutInterval: TimeInterval = 15

    private var debounceTimer: Timer?
    private var currentRequestId = 0

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
        request.setValue("Bearer \(Self.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.success([]))
                    return
                }
                guard httpResponse.statusCode == 200 else {
                    completion(.success([]))
                    return
                }
                guard let data else {
                    completion(.success([]))
                    return
                }
                do {
                    let users = try JSONDecoder().decode([RemoteUser].self, from: data)
                    completion(.success(users))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
}
