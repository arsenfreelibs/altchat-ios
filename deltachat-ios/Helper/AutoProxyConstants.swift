import Foundation

/// Configuration for the automatic proxy fallback feature.
///
/// When the app cannot reach our relay (IMAP/SMTP server) but the internet is
/// otherwise reachable, it automatically routes traffic through one of these
/// pre-bundled HTTP proxies. See `AutoProxyManager` for the state machine.
enum AutoProxy {

    /// Pre-bundled HTTP proxies, tried in order until one connects.
    /// Format matches deltachat-core `proxy_url`: `http://user:password@host:port`.
    ///
    /// The list is NOT hardcoded here. Credentials live in the gitignored
    /// `Config/auto_proxy.local` (plaintext, one URL per line) and are obfuscated
    /// into the bundled `autoproxy.dat` at build time by `scripts/gen_autoproxy_obf.py`
    /// (see the "Obfuscate auto-proxy creds" build phase). We decode that blob here
    /// in memory; nothing is written back to disk. Empty/missing -> feature inactive.
    static let proxyURLs: [String] = loadObfuscatedProxyURLs()

    /// XOR key used to deobfuscate `autoproxy.dat`.
    /// MUST match `KEY` in `scripts/gen_autoproxy_obf.py`.
    private static let obfuscationKey = Array("altchat-autoproxy-obfuscation-key-v1".utf8)

    private static func loadObfuscatedProxyURLs() -> [String] {
        guard let url = Bundle.main.url(forResource: "autoproxy", withExtension: "dat"),
              let blob = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = Data(base64Encoded: trimmed),
              !obfuscationKey.isEmpty
        else { return [] }

        var bytes = [UInt8](data)
        for i in 0..<bytes.count {
            bytes[i] ^= obfuscationKey[i % obfuscationKey.count]
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// How long the relay must stay disconnected (while internet works) before we engage a proxy.
    static let graceSeconds: TimeInterval = 20

    /// How long a single proxy gets to reach a connected state before we rotate to the next one.
    static let proxyTrySeconds: TimeInterval = 30

    /// How often, while on a proxy, we re-probe the relay directly to see if we can go back to direct.
    static let directRecheckSeconds: TimeInterval = 240

    /// Pause after all proxies failed before starting a fresh round.
    static let backoffSeconds: TimeInterval = 120

    /// URL used to confirm general internet connectivity (returns HTTP 204).
    static let internetProbeURL = "https://www.google.com/generate_204"

    /// Timeout for the internet/relay probes.
    static let probeTimeoutSeconds: TimeInterval = 8
}
