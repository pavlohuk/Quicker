import Foundation

/// Localized UI text from `Resources/<language>.lproj/Localizable.strings` in the app bundle.
///
/// macOS picks the language from the user's preferred languages (System Settings → General →
/// Language & Region, or a per-app override there). Languages without a translation fall back to
/// English, the development language.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}
