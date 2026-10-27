import Foundation

/// 主窗口侧边栏的筛选项。
public enum HostFilter: Hashable, Sendable {
    case all
    case favorites
    case group(UUID)
    case ungrouped
    case tag(String)
}

/// 侧栏里的一层分组。depth 从 0 开始，只用于缩进，不继承属性。
public struct GroupOutlineEntry: Equatable, Sendable, Identifiable {
    public var group: HostGroup
    public var depth: Int
    public var id: UUID { group.id }

    public init(group: HostGroup, depth: Int) {
        self.group = group
        self.depth = depth
    }
}

/// 标签及其使用次数。
public struct TagCount: Hashable, Sendable, Identifiable {
    public var tag: String
    public var count: Int
    public var id: String { tag.lowercased() }

    public init(tag: String, count: Int) {
        self.tag = tag
        self.count = count
    }
}

public extension HostLibrary {
    /// 所有标签（不区分大小写去重，保留首次出现的写法），按名称排序。
    var allTags: [TagCount] {
        var order: [String] = []
        var display: [String: String] = [:]
        var counts: [String: Int] = [:]
        for host in hosts {
            for tag in Set(host.tags.map { $0.lowercased() }) {
                if display[tag] == nil {
                    order.append(tag)
                    display[tag] = host.tags.first { $0.lowercased() == tag } ?? tag
                }
                counts[tag, default: 0] += 1
            }
        }
        return
            order
            .map { TagCount(tag: display[$0] ?? $0, count: counts[$0] ?? 0) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    /// 分组按 sortOrder、名称排序。
    var sortedGroups: [HostGroup] {
        groups.sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
    }

    /// 主窗口右侧列表：先按筛选项过滤，再按搜索词过滤，按名称排序。
    func hosts(filter: HostFilter, query: String) -> [SSHHost] {
        let knownGroupIDs = Set(groups.map(\.id))
        return hosts(matching: query)
            .filter { host in
                switch filter {
                case .all: return true
                case .favorites: return host.isFavorite
                case .group(let id):
                    guard let groupID = host.groupID else { return false }
                    return groupIDs(inTreeOf: id).contains(groupID)
                case .ungrouped: return host.groupID.map { !knownGroupIDs.contains($0) } ?? true
                case .tag(let tag): return host.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                }
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func count(for filter: HostFilter) -> Int {
        hosts(filter: filter, query: "").count
    }

    /// 复制站点：新 id、名称加后缀、清空最近连接时间。返回新站点（已插入）。
    @discardableResult
    mutating func duplicateHost(id: UUID, labelSuffix: String = " copy", now: Date = Date()) -> SSHHost? {
        guard let original = hosts.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.label = original.label + labelSuffix
        copy.lastConnectedAt = nil
        copy.createdAt = now
        copy.updatedAt = now
        hosts.append(copy)
        return copy
    }

    /// 把站点移动到分组（nil = 未分组）。分组不存在时不做任何事并返回 false。
    @discardableResult
    mutating func moveHost(id: UUID, toGroup groupID: UUID?, now: Date = Date()) -> Bool {
        if let groupID, !groups.contains(where: { $0.id == groupID }) { return false }
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return false }
        hosts[idx].groupID = groupID
        hosts[idx].updatedAt = now
        return true
    }

    /// 是否已有同名分组（忽略大小写和首尾空白）。
    func hasGroup(named name: String, excluding id: UUID? = nil) -> Bool {
        let key = HostInputParser.normalizedName(name).lowercased()
        return groups.contains { $0.id != id && $0.name.lowercased() == key }
    }

    /// `root` 自身以及所有子孙分组。数据里的环会被跳过。
    public func groupIDs(inTreeOf root: UUID) -> Set<UUID> {
        var result: Set<UUID> = [root]
        var frontier: [UUID] = [root]
        while !frontier.isEmpty {
            let parents = frontier
            frontier = []
            for group in groups {
                guard let parent = group.parentID, parents.contains(parent), result.insert(group.id).inserted else { continue }
                frontier.append(group.id)
            }
        }
        return result
    }

    /// 先根后子。父分组缺失的项视为顶层。环里没有根的分组追加在最后，避免从界面消失。
    public func groupOutline() -> [GroupOutlineEntry] {
        let known = Set(groups.map(\.id))
        func children(of parent: UUID) -> [HostGroup] {
            groups
                .filter { $0.parentID == parent }
                .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
        }
        var result: [GroupOutlineEntry] = []
        var seen = Set<UUID>()
        func walk(_ group: HostGroup, depth: Int) {
            guard seen.insert(group.id).inserted else { return }
            result.append(GroupOutlineEntry(group: group, depth: depth))
            for child in children(of: group.id) {
                walk(child, depth: depth + 1)
            }
        }
        let roots =
            groups
            .filter { group in
                guard let parent = group.parentID else { return true }
                return !known.contains(parent)
            }
            .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
        for root in roots { walk(root, depth: 0) }
        let leftover = groups.filter { !seen.contains($0.id) }.sorted {
            ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased())
        }
        for group in leftover { walk(group, depth: 0) }
        return result
    }

    /// 拒绝自己、不存在的父分组，以及会形成环的子孙。`parentID == nil` 表示移到顶层。
    @discardableResult
    public mutating func reparentGroup(id: UUID, parentID: UUID?, now: Date = Date(), deviceId: String? = nil) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        if let parentID {
            guard parentID != id, groups.contains(where: { $0.id == parentID }) else { return false }
            if groupIDs(inTreeOf: id).contains(parentID) { return false }
        }
        groups[index].parentID = parentID
        groups[index].updatedAt = now
        if let deviceId { groups[index].updatedByDeviceId = deviceId }
        return true
    }
}
