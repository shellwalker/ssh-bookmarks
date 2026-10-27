import Foundation

/// 设置窗口左侧的分类。
public enum SettingsPaneID: String, CaseIterable, Identifiable, Sendable {
    case general
    case terminal
    case hosts
    case about
    public var id: String { rawValue }
}

/// 设置窗口中的每一行。界面按 id 渲染，搜索也按 id 返回。
public enum SettingsItemID: String, CaseIterable, Identifiable, Sendable {
    // 通用
    case appearance
    case language
    case launchAtLogin
    case dockIcon
    case closePanelAfterConnect
    // 终端
    case sessionTerminal
    case openMode
    case sshPath
    case automationPermission
    // 站点
    case importSSHConfig
    case dataFile
    case sync
    case syncFolder
    // 关于
    case version
    case sourceCode

    public var id: String { rawValue }
}

/// 设置项元数据：所属分类、卡片分组以及中英文搜索关键词。
public struct SettingsItem: Hashable, Sendable, Identifiable {
    public var id: SettingsItemID
    public var pane: SettingsPaneID
    /// 同一分类中 group 相同的行放在同一张卡片里。
    public var group: Int
    public var keywords: [String]
}

public enum SettingsCatalog {
    public static let items: [SettingsItem] = [
        SettingsItem(
            id: .appearance, pane: .general, group: 0, keywords: ["appearance", "theme", "dark", "light", "外观", "主题", "深色", "浅色", "暗色"]),
        SettingsItem(id: .language, pane: .general, group: 0, keywords: ["language", "chinese", "english", "语言", "中文", "英文", "简体"]),
        SettingsItem(
            id: .launchAtLogin, pane: .general, group: 1, keywords: ["launch", "login", "startup", "boot", "开机", "启动", "登录", "自启"]),
        SettingsItem(id: .dockIcon, pane: .general, group: 1, keywords: ["dock", "icon", "menu bar", "程序坞", "图标", "菜单栏"]),
        SettingsItem(
            id: .closePanelAfterConnect, pane: .general, group: 1,
            keywords: ["close", "panel", "connect", "dismiss", "关闭", "面板", "连接后"]),
        SettingsItem(
            id: .sessionTerminal, pane: .terminal, group: 0,
            keywords: ["terminal", "iterm", "iterm2", "ghostty", "session", "终端", "会话"]),
        SettingsItem(id: .openMode, pane: .terminal, group: 0, keywords: ["window", "tab", "open", "窗口", "标签页", "打开方式"]),
        SettingsItem(id: .sshPath, pane: .terminal, group: 0, keywords: ["ssh", "path", "executable", "binary", "路径", "可执行"]),
        SettingsItem(
            id: .automationPermission, pane: .terminal, group: 1,
            keywords: ["automation", "permission", "privacy", "applescript", "自动化", "权限", "隐私"]),
        SettingsItem(
            id: .importSSHConfig, pane: .hosts, group: 0,
            keywords: ["import", "ssh config", "~/.ssh/config", "导入", "配置"]),
        SettingsItem(
            id: .dataFile, pane: .hosts, group: 0,
            keywords: ["data", "file", "json", "finder", "backup", "keychain", "数据", "文件", "备份", "钥匙串"]),
        SettingsItem(
            id: .sync, pane: .hosts, group: 1,
            keywords: ["sync", "icloud", "cloud", "同步", "云盘", "明文", "主机名"]),
        SettingsItem(
            id: .syncFolder, pane: .hosts, group: 1,
            keywords: ["sync", "folder", "icloud", "dropbox", "同步", "文件夹", "目录"]),
        SettingsItem(id: .version, pane: .about, group: 0, keywords: ["version", "about", "update", "版本", "关于"]),
        SettingsItem(id: .sourceCode, pane: .about, group: 0, keywords: ["source", "github", "code", "源码", "源代码"]),
    ]

    public static func item(_ id: SettingsItemID) -> SettingsItem {
        items.first { $0.id == id }!
    }

    public static func items(in pane: SettingsPaneID) -> [SettingsItem] {
        items.filter { $0.pane == pane }
    }

    /// 按卡片分组：[[item]]，保持声明顺序。
    public static func groups(in pane: SettingsPaneID) -> [[SettingsItem]] {
        groups(of: items(in: pane))
    }

    public static func groups(of list: [SettingsItem]) -> [[SettingsItem]] {
        var result: [[SettingsItem]] = []
        for item in list {
            if let last = result.last?.last, last.pane == item.pane, last.group == item.group {
                result[result.count - 1].append(item)
            } else {
                result.append([item])
            }
        }
        return result
    }

    /// “查找设置”：按空白拆词，每个词都要命中关键词、id 或界面上显示的（已本地化）标题 / 说明之一。
    /// - Parameter localizedText: 界面当前语言下每一项的标题和说明，由 App 层提供。
    public static func search(_ query: String, localizedText: [SettingsItemID: [String]] = [:]) -> [SettingsItem] {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return items }
        return items.filter { item in
            let haystack = ([item.id.rawValue.lowercased()] + item.keywords + (localizedText[item.id] ?? [])).map { $0.lowercased() }
            return tokens.allSatisfy { token in haystack.contains { $0.contains(token) } }
        }
    }
}
