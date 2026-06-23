import UIKit

/// Presents the lock screen in its own `UIWindow` overlay, above the normal UI.
///
/// A dedicated window (rather than swapping the app's `rootViewController` or presenting modally)
/// keeps the main UI, navigation and keyboard state intact underneath. The window is pinned to the
/// active `windowScene` and sits just above `.alert` so it covers the normal UI; the call window
/// (`CallWindow`, also `.alert`) is handled separately in stage 3.
final class PasscodeLockWindow {

    static let shared = PasscodeLockWindow()

    private var window: UIWindow?

    private init() {}

    var isShowing: Bool { window != nil }

    /// Show the lock screen. No-op if already shown.
    func show() {
        guard window == nil else { return }

        let lockController = PasscodeLockViewController()
        lockController.onUnlocked = { [weak self] in
            self?.hide()
        }

        // Prefer attaching to the active scene; fall back to a frame-based window when no scene is
        // connected yet (can happen during a cold-start lock).
        let window: UIWindow
        if let scene = Self.activeWindowScene() {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.rootViewController = lockController
        window.makeKeyAndVisible()
        self.window = window
    }

    /// Tear down the lock window. Does not change the lock state — used both after a successful
    /// unlock and to temporarily get out of the way of the call UI (the app stays locked, so the
    /// lock is re-shown when the call ends).
    func hide() {
        window?.isHidden = true
        window = nil
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
