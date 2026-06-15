import Foundation

/// Configuration for the automatic proxy fallback feature.
///
/// When the app cannot reach our relay (IMAP/SMTP server) but the internet is
/// otherwise reachable, it automatically routes traffic through one of these
/// pre-bundled HTTP proxies. See `AutoProxyManager` for the state machine.
enum AutoProxy {

    /// Pre-bundled HTTP proxies, tried in order until one connects.
    /// Format matches deltachat-core `proxy_url`: `http://user:password@host:port`.
    static let proxyURLs = [
    ]

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
