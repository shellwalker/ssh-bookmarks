import Foundation

/// 为现有 Localizable.strings 选择计数格式，翻译仍由应用负责。
public enum LocalizedCount {
    public static func diagnosticSummaryKey(count: Int) -> String {
        count == 1 ? "%lld file · %@" : "%lld files · %@"
    }

    public static func importSummaryKey(imported: Int, skipped: Int) -> String {
        switch (imported == 1, skipped == 1) {
        case (true, true): return "Imported %lld host. Skipped %lld duplicate."
        case (true, false): return "Imported %lld host. Skipped %lld duplicates."
        case (false, true): return "Imported %lld hosts. Skipped %lld duplicate."
        case (false, false): return "Imported %lld hosts. Skipped %lld duplicates."
        }
    }
}
