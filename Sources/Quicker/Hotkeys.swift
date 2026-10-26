import CoreGraphics

/// Key codes and modifier matching for the space hotkeys.
enum Hotkeys {
    /// Virtual key codes of the 1…9 keys on the main keyboard (ANSI positions; layout independent).
    static let digits: [Int32: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    static let leftArrow: Int32 = 123
    static let rightArrow: Int32 = 124

    /// Modifiers that must match exactly. Caps Lock, Fn and the numeric-pad flag (set on arrow
    /// keys) are ignored.
    private static let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    static func modifiersMatch(_ rawFlags: UInt64, _ modifier: HotkeyModifier) -> Bool {
        CGEventFlags(rawValue: rawFlags).intersection(relevant) == modifier.flags
    }
}
