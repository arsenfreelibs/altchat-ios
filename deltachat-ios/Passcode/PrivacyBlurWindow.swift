import UIKit

/// Covers the app content with a blur while the app is inactive/backgrounded, so chat content does
/// not appear in the multitasking (task switcher) snapshot.
///
/// This is the iOS substitute for Android's FLAG_SECURE task-switcher hiding: iOS cannot prevent
/// screenshots, but the system snapshot is taken right after `applicationWillResignActive` returns,
/// so showing the cover there hides the content in the preview.
///
/// Only active while a passcode is enabled. It sits above the normal UI but below the lock window.
final class PrivacyBlurWindow {

    static let shared = PrivacyBlurWindow()

    private var window: UIWindow?

    private init() {}

    /// Show the blur cover. No-op if already shown.
    func show() {
        guard window == nil else { return }

        let blurController = UIViewController()
        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blurView.frame = blurController.view.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurController.view.addSubview(blurView)

        let window: UIWindow
        if let scene = Self.activeWindowScene() {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        // Above the normal UI, but below the lock window (.alert + 1).
        window.windowLevel = UIWindow.Level.alert
        window.rootViewController = blurController
        window.isUserInteractionEnabled = false
        window.makeKeyAndVisible()
        self.window = window
    }

    /// Remove the blur cover.
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
