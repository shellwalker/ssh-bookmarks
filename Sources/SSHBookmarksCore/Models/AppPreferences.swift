import Foundation

/// 外观：跟随系统 / 浅色 / 深色。
public enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark
    public var id: String { rawValue }
}

/// 界面语言。切换后写入 AppleLanguages，重启应用生效。
public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    public var id: String { rawValue }

    /// 写入 UserDefaults `AppleLanguages` 的值；nil 表示移除覆盖、跟随系统。
    public var appleLanguagesOverride: [String]? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return ["zh-Hans"]
        case .english: return ["en"]
        }
    }
}

/// 程序坞图标：隐藏 / 跟随窗口（有窗口打开时显示）/ 显示。与 magpie 截图一致。
public enum DockIconMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case hidden
    case followWindow
    case visible
    public var id: String { rawValue }

    /// 是否应显示 Dock 图标。
    public func showsDockIcon(hasVisibleWindow: Bool) -> Bool {
        switch self {
        case .hidden: return false
        case .visible: return true
        case .followWindow: return hasVisibleWindow
        }
    }
}

/// 打开会话的方式。
public enum TerminalOpenMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case newWindow
    case newTab
    public var id: String { rawValue }
}
