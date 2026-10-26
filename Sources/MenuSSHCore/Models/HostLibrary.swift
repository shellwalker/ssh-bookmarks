import Foundation

/// 持久化到 hosts.json 的完整数据。
public struct HostLibrary: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var groups: [HostGroup]
    public var hosts: [SSHHost]

    public init(schemaVersion: Int = HostLibrary.currentSchemaVersion, groups: [HostGroup] = [], hosts: [SSHHost] = []) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.hosts = hosts
    }

    public static let empty = HostLibrary()
}

/// 菜单栏面板 / 站点列表中的一个分区。
public struct HostSection: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case favorites
        case group(HostGroup)
        case ungrouped
    }

    public var kind: Kind
    public var hosts: [SSHHost]

    public var id: String {
        switch kind {
        case .favorites: return "favorites"
        case .group(let g): return g.id.uuidString
        case .ungrouped: return "ungrouped"
        }
    }
}

public extension HostLibrary {
    /// 搜索：按空白拆分关键词，每个关键词都要命中 label / hostname / username / tags / 分组名之一（不区分大小写）。
    func hosts(matching query: String) -> [SSHHost] {
        let tokens =
            query
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
        guard !tokens.isEmpty else { return hosts }

        let groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name.lowercased()) })
        return hosts.filter { host in
            var haystack = [host.label.lowercased(), host.hostname.lowercased(), host.username.lowercased()]
            haystack.append(contentsOf: host.tags.map { $0.lowercased() })
            if let gid = host.groupID, let name = groupNames[gid] { haystack.append(name) }
            return tokens.allSatisfy { token in haystack.contains { $0.contains(token) } }
        }
    }

    /// 生成分区：收藏（仅在无搜索词时单独显示）→ 各分组（按 sortOrder、名称）→ 未分组。
    func sections(matching query: String) -> [HostSection] {
        let matched = hosts(matching: query)
        let byLabel: (SSHHost, SSHHost) -> Bool = {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        var result: [HostSection] = []

        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isSearching {
            let favorites = matched.filter(\.isFavorite).sorted(by: byLabel)
            if !favorites.isEmpty { result.append(HostSection(kind: .favorites, hosts: favorites)) }
        }

        let knownGroupIDs = Set(groups.map(\.id))
        let sortedGroups = groups.sorted {
            ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased())
        }
        for group in sortedGroups {
            let members = matched.filter { $0.groupID == group.id }.sorted(by: byLabel)
            if !members.isEmpty { result.append(HostSection(kind: .group(group), hosts: members)) }
        }

        let ungrouped =
            matched
            .filter { $0.groupID == nil || !knownGroupIDs.contains($0.groupID!) }
            .sorted(by: byLabel)
        if !ungrouped.isEmpty { result.append(HostSection(kind: .ungrouped, hosts: ungrouped)) }
        return result
    }

    /// 最近连接（菜单栏面板顶部可用）。
    func recentHosts(limit: Int = 5) -> [SSHHost] {
        hosts
            .filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    mutating func upsert(_ host: SSHHost) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
    }

    mutating func removeHost(id: UUID) {
        hosts.removeAll { $0.id == id }
    }

    mutating func upsert(_ group: HostGroup) {
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx] = group
        } else {
            groups.append(group)
        }
    }

    /// 删除分组时，其中的站点移动到“未分组”，子分组提升一级。
    mutating func removeGroup(id: UUID) {
        let parent = groups.first(where: { $0.id == id })?.parentID
        groups.removeAll { $0.id == id }
        for i in groups.indices where groups[i].parentID == id {
            groups[i].parentID = parent
        }
        for i in hosts.indices where hosts[i].groupID == id {
            hosts[i].groupID = nil
        }
    }
}
