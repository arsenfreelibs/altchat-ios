import Foundation
import CryptoKit
import DcCore

final class AltPlatformService {

    private static let quickRegisterURL = "https://api.alt-to.online/v1/users/quick-register"
    private static let registrationQueue = DispatchQueue(label: "alt.platform.register")
    private static var isRegistering = false

    private let dcContext: DcContext

    init(dcContext: DcContext) {
        self.dcContext = dcContext
    }

    /// Registers the account on the Alt Platform backend.
    /// Must be called from a background thread. Blocks until the network request completes.
    /// All errors are handled silently — no UI feedback is produced.
    func quickRegister(displayName: String) {
        // Prevent concurrent calls
        var shouldRun = false
        AltPlatformService.registrationQueue.sync {
            if !AltPlatformService.isRegistering {
                AltPlatformService.isRegistering = true
                shouldRun = true
            }
        }
        guard shouldRun else { return }
        defer {
            AltPlatformService.registrationQueue.sync {
                AltPlatformService.isRegistering = false
            }
        }

        // 1. Collect transport addresses
        let transports = dcContext.listTransportsEx()
        var addrs = transports.map { $0.param.addr }
        if addrs.isEmpty, let addr = dcContext.addr { addrs = [addr] }
        guard !addrs.isEmpty else { return }

        // 2. Derive username from first address
        let email = addrs[0]
        let username = deriveUsername(from: email)

        // 3. Obtain OpenPGP keys and fingerprint via RPC
        guard let publicKey = dcContext.getSelfPublicKeyArmored(),
              let privateKeyArmored = dcContext.getSelfPrivateKeyArmored(),
              let fingerprint = dcContext.getSelfFingerprintHex() else { return }

        // 4. Generate recovery password
        let recoveryPassword = generateRecoveryPassword()

        // 5. Save recovery password to Keychain BEFORE the network call
        KeychainManager.saveRecoveryPassword(recoveryPassword)

        // 6. Encrypt private key — do NOT send it in plain text
        guard let encryptedPrivKey = encryptPrivateKey(privateKeyArmored, password: recoveryPassword) else { return }

        // 7. Build and send the POST request
        let body = RegisterRequest(
            username: username,
            email: email,
            addr: addrs,
            displayName: displayName,
            publicKey: publicKey,
            fingerprint: fingerprint,
            encryptedPrivateKey: encryptedPrivKey
        )

        guard let url = URL(string: AltPlatformService.quickRegisterURL),
              let bodyData = try? JSONEncoder().encode(body) else { return }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        // Synchronous wait — we are already on a background thread
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var httpResponse: HTTPURLResponse?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            httpResponse = response as? HTTPURLResponse
            semaphore.signal()
        }.resume()
        semaphore.wait()

        // 8. Handle result
        guard let statusCode = httpResponse?.statusCode else { return }

        if statusCode == 200,
           let data = responseData,
           let decoded = try? JSONDecoder().decode(RegisterResponse.self, from: data),
           !decoded.token.isEmpty {
            KeychainManager.saveJwtToken(decoded.token, accountId: dcContext.id)
            UserDefaults.shared?.set(username, forKey: "alt_username")
            UserDefaults.shared?.set(email, forKey: "alt_email")
        }
        // 409 or other errors: silent — retryQuickRegisterIfNeeded() will retry on next foreground
    }

    // MARK: - Private helpers

    private func deriveUsername(from addr: String) -> String {
        let local = addr.components(separatedBy: "@").first ?? addr
        var result = local.lowercased()

        // Replace any non-[a-z0-9_] character with underscore
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        result = result.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()

        // Collapse consecutive underscores
        while result.contains("__") {
            result = result.replacingOccurrences(of: "__", with: "_")
        }

        // Strip leading and trailing underscores
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if result.count < 3 {
            let suffix = String(format: "%05x", Int.random(in: 0..<0xfffff))
            result += suffix
        }
        if result.count > 30 {
            result = String(result.prefix(30))
        }
        return result
    }

    private func generateRecoveryPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, 24, &bytes)
        let b64 = Data(bytes).base64EncodedString()
        let alnum = b64.filter { $0.isLetter || $0.isNumber }
        return String(alnum.prefix(20))
    }

    /// Encrypts the armored private key using AES-GCM with a SHA-256-derived key.
    /// Output: Base64(nonce + ciphertext + tag)
    private func encryptPrivateKey(_ plaintext: String, password: String) -> String? {
        guard let plaintextData = plaintext.data(using: .utf8),
              let passwordData = password.data(using: .utf8) else { return nil }
        let symmetricKey = SymmetricKey(data: SHA256.hash(data: passwordData))
        guard let sealedBox = try? AES.GCM.seal(plaintextData, using: symmetricKey),
              let combined = sealedBox.combined else { return nil }
        return combined.base64EncodedString()
    }
}

// MARK: - Codable models

private struct RegisterRequest: Encodable {
    let username: String
    let email: String
    let addr: [String]
    let displayName: String
    let publicKey: String
    let fingerprint: String
    let encryptedPrivateKey: String
}

private struct RegisterResponse: Decodable {
    let token: String
}
