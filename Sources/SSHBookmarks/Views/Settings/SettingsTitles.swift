import Foundation
import SSHBookmarksCore
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
    /// 下拉菜单中的名称（需要和版本号等拼接，所以是 String）。
    var localizedName: String {
        switch self {
        case .terminal: return NSLocalizedString("System Default (Terminal)", comment: "terminal picker")
        case .iTerm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }
}

extension SettingsPaneID {
    var title: LocalizedStringKey { LocalizedStringKey(titleKey) }

    var titleKey: String {
        switch self {
        case .general: return "General"
        case .terminal: return "Terminal"
        case .hosts: return "Hosts"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .hosts: return "server.rack"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

extension SettingsItemID {
    /// Localizable.strings 中的标题 key。
    var titleKey: String {
        switch self {
        case .appearance: return "Appearance"
        case .language: return "Language"
        case .launchAtLogin: return "Launch at Login"
        case .dockIcon: return "Show in Dock"
        case .closePanelAfterConnect: return "Close Panel After Connecting"
        case .showTunnelCount: return "Show Tunnel Count in the Menu Bar"
        case .sessionTerminal: return "Session Terminal"
        case .openMode: return "Open In"
        case .sshPath: return "SSH Executable"
        case .automationPermission: return "Automation Permission"
        case .importSSHConfig: return "Import ~/.ssh/config"
        case .dataFile: return "Data File"
        case .sync: return "Sync"
        case .syncFolder: return "Sync Folder"
        case .diagnosticFile: return "Write Diagnostic Log"
        case .diagnosticRedactNames: return "Redact Hostnames and Usernames"
        case .diagnosticExport: return "Export Diagnostic Log…"
        case .diagnosticCopy: return "Copy Diagnostic Info"
        case .version: return "Version"
        case .sourceCode: return "Source Code"
        }
    }

    /// 默认说明文字的 key（行内可能根据状态替换成别的说明）。
    var subtitleKey: String? {
        switch self {
        case .appearance: return "Light, dark, or follow the system"
        case .language: return "Interface language"
        case .launchAtLogin: return "Start SSH Bookmarks automatically when you log in"
        case .dockIcon: return "\"Follow Window\" shows the Dock icon only while a window is open"
        case .closePanelAfterConnect: return "Hide the menu bar panel once a session opens"
        case .showTunnelCount: return "Show the number of running tunnels on the menu bar icon"
        case .sessionTerminal: return "Terminal used to open SSH sessions"
        case .openMode: return "Open each session in a new window or a new tab"
        case .sshPath: return "Default: /usr/bin/ssh"
        case .automationPermission:
            return "Terminal, iTerm2 and Ghostty are controlled via AppleScript. "
                + "If launching fails, allow SSH Bookmarks under Privacy & Security › Automation."
        case .importSSHConfig: return "Adds Host entries that are not in SSH Bookmarks yet"
        case .dataFile: return "Hosts are stored as JSON; passwords live in the Keychain"
        case .sync: return "Sync is off. Hosts stay on this Mac."
        case .syncFolder: return "iCloud Drive/SSH Bookmarks"
        case .diagnosticFile: return "The log stays on this Mac and is off until you turn it on"
        case .diagnosticRedactNames: return "On by default. Passwords and tokens are always removed"
        case .diagnosticExport: return "Save a ZIP that never includes passwords, tokens, or private keys"
        case .diagnosticCopy: return "Copy a short redacted summary to the clipboard"
        case .version, .sourceCode: return nil
        }
    }

    /// 当前语言下的标题和说明，供“查找设置”匹配。
    var localizedSearchText: [String] {
        [titleKey, subtitleKey].compactMap { $0 }.map { NSLocalizedString($0, comment: "") }
    }
}
