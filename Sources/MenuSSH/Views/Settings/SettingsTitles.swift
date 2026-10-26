import MenuSSHCore
import SwiftUI

// Core 是纯 Foundation，界面文案集中在这里，交给 Localizable.strings 翻译。

extension AppearanceMode {
    var title: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

extension AppLanguage {
    /// 语言名用各自语言原文显示，方便切换。
    var title: LocalizedStringKey {
        switch self {
        case .system: return "Follow System"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

extension DockIconMode {
    var title: LocalizedStringKey {
        switch self {
        case .hidden: return "Hide"
        case .followWindow: return "Follow Window"
        case .visible: return "Show"
        }
    }
}

extension TerminalOpenMode {
    var title: LocalizedStringKey {
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        }
    }
}

extension TerminalApp {
    var pickerTitle: LocalizedStringKey {
        switch self {
        case .terminal: return "System Default (Terminal)"
        case .iTerm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }
}
