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
        guard let scene = Self.activeWindowScene() else { return }

        let lockController = PasscodeLockViewController()
        lockController.onUnlocked = { [weak self] in
            self?.dismiss()
        }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.rootViewController = lockController
        window.makeKeyAndVisible()
        self.window = window
    }

    private func dismiss() {
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
