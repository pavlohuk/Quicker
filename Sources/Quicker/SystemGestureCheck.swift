import AppKit

/// The system's own "swipe between full-screen apps" gesture must stay ON: Quicker
/// intercepts exactly the events that gesture produces and replaces them with instant switches.
enum SystemGestureCheck {
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]

    /// Finger count (3 or 4) the system swipe between spaces is set to, or nil when it is off.
    static func systemSwipeFingers() -> Int? {
        for (fingers, key) in [(3, "TrackpadThreeFingerHorizSwipeGesture"), (4, "TrackpadFourFingerHorizSwipeGesture")] {
            for domain in domains {
                CFPreferencesAppSynchronize(domain as CFString)
                if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int, value == 2 {
                    return fingers
                }
            }
        }
        return nil
    }

    private static var switchOnActivate: (value: Bool, at: Date)?

    /// System Settings → Desktop & Dock → "When switching to an application, switch to a Space
    /// with open windows for the application". On by default; the Dock then slides (animated).
    ///
    /// Asked on every click near the Dock, from inside the event tap, so the answer is cached
    /// for a moment: synchronizing preferences is a round trip to cfprefsd, and the whole
    /// system's input waits while the tap is busy.
    static func systemSwitchOnActivateEnabled() -> Bool {
        if let cached = switchOnActivate, Date().timeIntervalSince(cached.at) < 2 { return cached.value }
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        var valid: DarwinBoolean = false
        let raw = CFPreferencesGetAppBooleanValue("AppleSpacesSwitchOnActivate" as CFString,
                                                  kCFPreferencesAnyApplication, &valid)
        let value = valid.boolValue ? raw : true
        switchOnActivate = (value, Date())
        return value
    }

    static func openDesktopAndDockSettings() {
        open([
            "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.dock",
        ])
    }

    static func openTrackpadSettings() {
        open([
            "x-apple.systempreferences:com.apple.Trackpad-Settings.extension?MoreGestures",
            "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
        ])
    }

    static func openAccessibilitySettings() {
        open([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ])
    }

    private static func open(_ candidates: [String]) {
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }
}
