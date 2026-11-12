import CoreGraphics
import Foundation

/// Modifier used by the space hotkeys (modifier+1…9 and modifier+←/→).
enum HotkeyModifier: String, CaseIterable {
    case command
    case control
    case option
    case controlOption

    var flags: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .controlOption: return [.maskControl, .maskAlternate]
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .controlOption: return "⌃⌥"
        }
    }

    var title: String {
        switch self {
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .controlOption: return "⌃⌥ Control + Option"
        }
    }
}

/// User preferences, backed by UserDefaults (domain com.pavlohuk.Quicker).
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let enabled = "enabled"
        static let invert = "invertDirection"
        static let hotkeyDigits = "hotkeyDigits"
        static let hotkeyArrows = "hotkeyArrows"
        static let hotkeyModifier = "hotkeyModifier"
        static let indicatorEnabled = "indicatorEnabled"
        static let indicatorCorner = "indicatorCorner"
        static let followActivatedApp = "followActivatedApp"
        static let hideMenuBarForVideo = "hideMenuBarForVideo"
        static let longSwipeSkipsMore = "longSwipeSkipsMore"
        static let brightnessKeys = "brightnessKeys"
        static let dockShownOnExternalDisplay = "dockShownOnExternalDisplay"
        static let smoothScroll = "smoothScroll"
        static let scrollSmoothness = "scrollSmoothness"
        static let scrollBounce = "scrollBounce"
        static let scrollSpeed = "scrollSpeed"
        static let scrollBounceApps = "scrollBounceApps"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.invert: false,
            Key.hotkeyDigits: true,
            Key.hotkeyArrows: true,
            Key.hotkeyModifier: HotkeyModifier.command.rawValue,
            Key.indicatorEnabled: true,
            Key.indicatorCorner: IndicatorCorner.topCenter.rawValue,
            Key.followActivatedApp: true,
            Key.hideMenuBarForVideo: true,
            Key.longSwipeSkipsMore: true,
            Key.brightnessKeys: true,
            Key.dockShownOnExternalDisplay: true,
            Key.smoothScroll: true,
            Key.scrollSmoothness: ScrollSmoothness.medium.rawValue,
            Key.scrollBounce: false,
            Key.scrollSpeed: 1.5,
            Key.scrollBounceApps: [
                "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "app.zen-browser.zen",
                "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
            ],
        ])
    }

    /// Master switch. When off, swipes pass through untouched (normal animated switching) and
    /// the hotkeys do nothing.
    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Reverses the direction of the trackpad swipe only.
    var invertDirection: Bool {
        get { defaults.bool(forKey: Key.invert) }
        set { defaults.set(newValue, forKey: Key.invert) }
    }

    /// A longer trackpad swipe moves more than one Space.
    var longSwipeSkipsMore: Bool {
        get { defaults.bool(forKey: Key.longSwipeSkipsMore) }
        set { defaults.set(newValue, forKey: Key.longSwipeSkipsMore) }
    }

    /// modifier+1…9 jumps straight to desktop N.
    var hotkeyDigits: Bool {
        get { defaults.bool(forKey: Key.hotkeyDigits) }
        set { defaults.set(newValue, forKey: Key.hotkeyDigits) }
    }

    /// modifier+←/→ switches to the neighbouring space.
    var hotkeyArrows: Bool {
        get { defaults.bool(forKey: Key.hotkeyArrows) }
        set { defaults.set(newValue, forKey: Key.hotkeyArrows) }
    }

    var hotkeyModifier: HotkeyModifier {
        get { HotkeyModifier(rawValue: defaults.string(forKey: Key.hotkeyModifier) ?? "") ?? .command }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyModifier) }
    }

    /// Shows the corner indicator with the current space after every switch.
    var indicatorEnabled: Bool {
        get { defaults.bool(forKey: Key.indicatorEnabled) }
        set { defaults.set(newValue, forKey: Key.indicatorEnabled) }
    }

    /// When an app is activated (⌘Tab, Dock click…) and none of its windows is on the current
    /// space, jump instantly to the space with its most recent window. Only acts while the
    /// system's own animated "switch to a Space with open windows" option is off.
    var followActivatedApp: Bool {
        get { defaults.bool(forKey: Key.followActivatedApp) }
        set { defaults.set(newValue, forKey: Key.followActivatedApp) }
    }

    /// Hides the menu bar on a full-screen Space while a video plays there, when the system
    /// option keeps it visible in full screen otherwise.
    var hideMenuBarForVideo: Bool {
        get { defaults.bool(forKey: Key.hideMenuBarForVideo) }
        set { defaults.set(newValue, forKey: Key.hideMenuBarForVideo) }
    }

    /// The brightness keys change the display under the cursor, external ones too, and show
    /// Quicker's own brightness HUD.
    var brightnessKeys: Bool {
        get { defaults.bool(forKey: Key.brightnessKeys) }
        set { defaults.set(newValue, forKey: Key.brightnessKeys) }
    }

    /// Smooth, trackpad-like scrolling for mouse wheels.
    var smoothScroll: Bool {
        get { defaults.bool(forKey: Key.smoothScroll) }
        set { defaults.set(newValue, forKey: Key.smoothScroll) }
    }

    var scrollSmoothness: ScrollSmoothness {
        get { ScrollSmoothness(rawValue: defaults.string(forKey: Key.scrollSmoothness) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.scrollSmoothness) }
    }

    /// How far a smoothed scroll goes, as a multiple of what the wheel reports.
    var scrollSpeed: Double {
        get { min(max(defaults.double(forKey: Key.scrollSpeed), 0.5), 4) }
        set { defaults.set(newValue, forKey: Key.scrollSpeed) }
    }

    /// Bundle identifiers of the apps that get the bounce when `scrollBounce` is on. It is a
    /// list of apps known to handle it (browsers): many others scroll slowly, unevenly or not at
    /// all when sent trackpad momentum.
    var scrollBounceApps: [String] {
        get { defaults.stringArray(forKey: Key.scrollBounceApps) ?? [] }
        set { defaults.set(newValue, forKey: Key.scrollBounceApps) }
    }

    /// Smoothed scrolling carries trackpad phases in the apps of `scrollBounceApps`, so they
    /// bounce at the edges.
    var scrollBounce: Bool {
        get { defaults.bool(forKey: Key.scrollBounce) }
        set { defaults.set(newValue, forKey: Key.scrollBounce) }
    }

    /// Keep an auto-hiding Dock shown while an external display is connected.
    var dockShownOnExternalDisplay: Bool {
        get { defaults.bool(forKey: Key.dockShownOnExternalDisplay) }
        set { defaults.set(newValue, forKey: Key.dockShownOnExternalDisplay) }
    }

    var indicatorCorner: IndicatorCorner {
        get { IndicatorCorner(rawValue: defaults.string(forKey: Key.indicatorCorner) ?? "") ?? .topCenter }
        set { defaults.set(newValue.rawValue, forKey: Key.indicatorCorner) }
    }
}
