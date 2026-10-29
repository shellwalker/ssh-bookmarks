import Foundation

/// 持久化到 hosts.json 的完整数据。
public struct HostLibrary: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var groups: [HostGroup]
    public var hosts: [SSHHost]
    /// 删除记录。同步关闭时也留在本机，避免以后打开同步时把已删站点从另一台机器拉回来。
    public var tombstones: [SyncTombstone]

    public init(
        schemaVersion: Int = HostLibrary.currentSchemaVersion,
        groups: [HostGroup] = [],
        hosts: [SSHHost] = [],
        tombstones: [SyncTombstone] = []
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.hosts = hosts
        self.tombstones = tombstones
    }

    public static let empty = HostLibrary()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, groups, hosts, tombstones
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? HostLibrary.currentSchemaVersion
        groups = try c.decodeIfPresent([HostGroup].self, forKey: .groups) ?? []
        hosts = try c.decodeIfPresent([SSHHost].self, forKey: .hosts) ?? []
        tombstones = try c.decodeIfPresent([SyncTombstone].self, forKey: .tombstones) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // 保存时写成当前版本。本地文件仍可读更新的版本，避免一次解码失败就把用户的库改名备份。
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(groups, forKey: .groups)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(tombstones, forKey: .tombstones)
    }
}

/// 菜单栏面板 / 站点列表中的一个分区。
public struct HostSection: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case recent
        case favorites
        case group(HostGroup)
        case ungrouped
    }

    public var kind: Kind
    public var hosts: [SSHHost]

    public var id: String {
        switch kind {
        case .recent: return "recent"
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

    /// 生成分区：最近 → 各分组（按 sortOrder、名称）→ 未分组。收藏不单独成区。
    func sections(matching query: String) -> [HostSection] {
        let matched = hosts(matching: query)
        let byLabel: (SSHHost, SSHHost) -> Bool = {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        var result: [HostSection] = []

        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let recent = isSearching ? [] : recentHosts(limit: HostLibrary.recentSectionLimit)
        if !recent.isEmpty { result.append(HostSection(kind: .recent, hosts: recent)) }
        // 收藏只在所在行上显示星号。已经出现在「最近」里的收藏不再进分组，避免同一条站点画两次。
        let favoriteAlreadyShown = Set(recent.filter(\.isFavorite).map(\.id))

        let knownGroupIDs = Set(groups.map(\.id))
        let sortedGroups = groups.sorted {
            ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased())
        }
        for group in sortedGroups {
            let members = matched.filter { $0.groupID == group.id && !favoriteAlreadyShown.contains($0.id) }.sorted(by: byLabel)
            if !members.isEmpty { result.append(HostSection(kind: .group(group), hosts: members)) }
        }

        let ungrouped =
            matched
            .filter { ($0.groupID == nil || !knownGroupIDs.contains($0.groupID!)) && !favoriteAlreadyShown.contains($0.id) }
            .sorted(by: byLabel)
        if !ungrouped.isEmpty { result.append(HostSection(kind: .ungrouped, hosts: ungrouped)) }
        return result
    }

    public static let recentSectionLimit = 8

    /// 面板分区标题。顶层分组只有自己的名字；子分组是「父 / 子」。
    func groupPath(id: UUID) -> String {
        var names: [String] = []
        var current: UUID? = id
        var seen = Set<UUID>()
        var steps = 0
        while let cid = current, steps < 32, seen.insert(cid).inserted, let group = groups.first(where: { $0.id == cid }) {
            names.append(group.name)
            current = group.parentID
            steps += 1
        }
        return names.reversed().joined(separator: " / ")
    }

    /// 最近连接（菜单栏面板顶部）。最多 8 条。
    func recentHosts(limit: Int = HostLibrary.recentSectionLimit) -> [SSHHost] {
        hosts
            .filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    mutating func upsert(_ host: SSHHost) {
        tombstones.removeAll { tomb in
            tomb.kind == .host && tomb.id == host.id
                && !SyncMerger.tombstoneBeats(tomb, updatedAt: host.updatedAt, deviceId: host.updatedByDeviceId)
        }
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
    }

    mutating func removeHost(id: UUID, now: Date = Date(), deviceId: String? = nil) {
        hosts.removeAll { $0.id == id }
        recordTombstone(id: id, kind: .host, now: now, deviceId: deviceId)
    }

    mutating func upsert(_ group: HostGroup) {
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx] = group
        } else {
            groups.append(group)
        }
    }

    /// 删除分组时，其中的站点移动到“未分组”，子分组提升一级。
    mutating func removeGroup(id: UUID, now: Date = Date(), deviceId: String? = nil) {
        let parent = groups.first(where: { $0.id == id })?.parentID
        groups.removeAll { $0.id == id }
        for i in groups.indices where groups[i].parentID == id {
            groups[i].parentID = parent
            groups[i].updatedAt = now
            groups[i].updatedByDeviceId = deviceId ?? groups[i].updatedByDeviceId
        }
        for i in hosts.indices where hosts[i].groupID == id {
            hosts[i].groupID = nil
            hosts[i].updatedAt = now
            hosts[i].updatedByDeviceId = deviceId ?? hosts[i].updatedByDeviceId
        }
        recordTombstone(id: id, kind: .group, now: now, deviceId: deviceId)
    }

    mutating func recordTombstone(id: UUID, kind: SyncTombstone.Kind, now: Date, deviceId: String?) {
        if let existing = tombstones.first(where: { $0.id == id && $0.kind == kind }),
            SyncMerger.tombstoneBeats(existing, updatedAt: now, deviceId: deviceId)
        {
            return
        }
        tombstones.removeAll { $0.id == id && $0.kind == kind }
        tombstones.append(SyncTombstone(id: id, kind: kind, deletedAt: now, deviceId: deviceId))
    }

    /// 丢掉超过保留期的墓碑。
    public func pruningTombstones(now: Date) -> HostLibrary {
        var copy = self
        copy.tombstones = SyncMerger.prune(tombstones, now: now)
        return copy
    }
}
