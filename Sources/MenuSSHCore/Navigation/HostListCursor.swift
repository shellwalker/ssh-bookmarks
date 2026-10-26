import Foundation

/// 菜单栏面板中可选中的一行。收藏的站点会同时出现在“收藏”和所属分组中，所以 id 由分区 + 站点组成。
public struct HostListEntry: Hashable, Identifiable, Sendable {
    public var sectionID: String
    public var host: SSHHost
    public var id: String { "\(sectionID)/\(host.id.uuidString)" }

    public init(sectionID: String, host: SSHHost) {
        self.sectionID = sectionID
        self.host = host
    }
}

/// 面板支持的按键。
public enum PanelKey: Equatable, Sendable {
    case up
    case down
    case pageUp
    case pageDown
    case home
    case end
    case enter
    case escape

    /// macOS 虚拟键码（kVK_*）→ 按键。Control-N / Control-P 也可上下移动（emacs 习惯）。
    public init?(keyCode: UInt16, control: Bool = false) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 116: self = .pageUp
        case 121: self = .pageDown
        case 115: self = .home
        case 119: self = .end
        case 36, 76: self = .enter  // Return, keypad Enter
        case 53: self = .escape
        case 35 where control: self = .up  // P
        case 45 where control: self = .down  // N
        default: return nil
        }
    }
}

/// 面板对按键的反应。
public enum PanelAction: Equatable, Sendable {
    case none
    case select(String)
    case connect(SSHHost)
    case close
}

/// 键盘导航游标：上下移动选中项（到边界停住），回车连接，Esc 关闭。
public struct HostListCursor: Equatable, Sendable {
    public private(set) var entries: [HostListEntry]
    public private(set) var selectedIndex: Int?
    public var pageSize: Int

    public init(sections: [HostSection] = [], pageSize: Int = 8) {
        self.entries = sections.flatMap { section in section.hosts.map { HostListEntry(sectionID: section.id, host: $0) } }
        self.selectedIndex = entries.isEmpty ? nil : 0
        self.pageSize = max(1, pageSize)
    }

    public var selectedEntry: HostListEntry? {
        selectedIndex.map { entries[$0] }
    }

    public var selectedID: String? { selectedEntry?.id }

    /// 列表内容变化（搜索词改变）时调用：重置到第一项。
    public mutating func reset(sections: [HostSection]) {
        self = HostListCursor(sections: sections, pageSize: pageSize)
    }

    /// 列表内容变化但希望保留当前选中（例如收藏状态改变）时调用；找不到原选中项则回到第一项。
    public mutating func update(sections: [HostSection]) {
        let previous = selectedID
        reset(sections: sections)
        if let previous, let idx = entries.firstIndex(where: { $0.id == previous }) {
            selectedIndex = idx
        }
    }

    public mutating func select(id: String) {
        if let idx = entries.firstIndex(where: { $0.id == id }) { selectedIndex = idx }
    }

    /// 移动 delta 行，夹在 [0, count-1]。
    public mutating func move(by delta: Int) {
        guard !entries.isEmpty else {
            selectedIndex = nil
            return
        }
        let current = selectedIndex ?? (delta >= 0 ? -1 : entries.count)
        selectedIndex = min(max(current + delta, 0), entries.count - 1)
    }

    /// 处理按键，返回面板应执行的动作。
    public mutating func handle(_ key: PanelKey) -> PanelAction {
        switch key {
        case .escape:
            return .close
        case .enter:
            guard let entry = selectedEntry else { return .none }
            return .connect(entry.host)
        case .up: move(by: -1)
        case .down: move(by: 1)
        case .pageUp: move(by: -pageSize)
        case .pageDown: move(by: pageSize)
        case .home: move(by: -entries.count)
        case .end: move(by: entries.count)
        }
        return selectedID.map(PanelAction.select) ?? .none
    }
}
