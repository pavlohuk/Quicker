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

    var indicatorCorner: IndicatorCorner {
        get { IndicatorCorner(rawValue: defaults.string(forKey: Key.indicatorCorner) ?? "") ?? .topCenter }
        set { defaults.set(newValue.rawValue, forKey: Key.indicatorCorner) }
    }
}
