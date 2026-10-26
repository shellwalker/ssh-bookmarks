import Foundation

/// Localized format strings.
///
/// `String(localized:)` / `Text` interpolation is rejected by the Xcode 16 Swift
/// overlay for several of these call sites (the interpolated value is not a
/// `LocalizationValue` argument), and it also builds a key that may not match
/// `Localizable.strings`. Keys here are the printf strings already in that file
/// (`%@`, `%lld`).
enum L10n {
    static func format(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        String(format: String(localized: key), locale: .current, arguments: args)
    }
}
