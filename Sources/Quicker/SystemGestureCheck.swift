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

    /// System Settings → Desktop & Dock → "When switching to an application, switch to a Space
    /// with open windows for the application". On by default; the Dock then slides (animated).
    static func systemSwitchOnActivateEnabled() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        var valid: DarwinBoolean = false
        let value = CFPreferencesGetAppBooleanValue("AppleSpacesSwitchOnActivate" as CFString,
                                                    kCFPreferencesAnyApplication, &valid)
        return valid.boolValue ? value : true
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
