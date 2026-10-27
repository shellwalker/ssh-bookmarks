import Foundation

public struct SyncMergeOutcome: Equatable, Sendable {
    public var document: SyncDocument
    public var conflictCount: Int
    /// 时间戳不同、较新的一边胜出。不算冲突。
    public var newerUpdatedAtKept: Int
    /// 时间戳相同才计冲突，并按 deviceId 字典序取舍。与 `conflictCount` 一致。
    public var deviceIdOrderKept: Int

    public init(
        document: SyncDocument, conflictCount: Int, newerUpdatedAtKept: Int = 0, deviceIdOrderKept: Int = 0
    ) {
        self.document = document
        self.conflictCount = conflictCount
        self.newerUpdatedAtKept = newerUpdatedAtKept
        self.deviceIdOrderKept = deviceIdOrderKept
    }
}

/// 两条记录谁留下。`left` 是调用方传入的第一份（通常是本机）。
public struct SyncKeepDecision: Equatable, Sendable {
    public enum Side: String, Equatable, Sendable {
        case left
        case right
    }

    public enum Reason: String, Equatable, Sendable {
        case newerUpdatedAt
        case deviceIdOrder
    }

    public var kept: Side
    public var reason: Reason
    /// 只有时间戳相同且内容不同才算冲突。较新的 `updatedAt` 静默胜出。
    public var countsAsConflict: Bool

    public init(kept: Side, reason: Reason, countsAsConflict: Bool) {
        self.kept = kept
        self.reason = reason
        self.countsAsConflict = countsAsConflict
    }

    public var keptSideName: String { kept.rawValue }

    /// 稳定的英文规则名，供测试和提示文案对齐。
    public var ruleName: String {
        switch reason {
        case .newerUpdatedAt: return "newer updatedAt"
        case .deviceIdOrder: return "deviceId order"
        }
    }
}

/// 按 id 合并两份同步文件。
///
/// 时间戳不同：较新的一边直接胜出，不算冲突（静默快进）。
/// 时间戳相同且内容不同，或“还在”和“已删”时间戳相同：算一次冲突，字典序更大的 deviceId 胜出。
/// 墓碑保留 90 天，过期后不再压制站点。
public enum SyncMerger {
    public static let tombstoneRetention: TimeInterval = 90 * 24 * 60 * 60

    public static func prune(_ tombstones: [SyncTombstone], now: Date) -> [SyncTombstone] {
        tombstones.filter { now.timeIntervalSince($0.deletedAt) <= tombstoneRetention }
    }

    /// 墓碑是否压过这条记录。时间相同则 deviceId 字典序更大者胜；再相同则墓碑胜。
    public static func tombstoneBeats(_ tombstone: SyncTombstone, updatedAt: Date, deviceId: String?) -> Bool {
        if tombstone.deletedAt != updatedAt { return tombstone.deletedAt > updatedAt }
        return (tombstone.deviceId ?? "") >= (deviceId ?? "")
    }

    /// 冲突提示用的英文句子：平局留 deviceId 较大的一边；时间不同则留较新的 updatedAt。
    public static func conflictNotice(tiedItems: Int) -> String {
        "Kept the greater device id for \(tiedItems) tied items. When updatedAt differs, the newer side is kept."
    }

    public static func decide(
        leftUpdatedAt: Date,
        leftDeviceId: String?,
        rightUpdatedAt: Date,
        rightDeviceId: String?,
        sameContent: Bool
    ) -> SyncKeepDecision {
        if leftUpdatedAt != rightUpdatedAt {
            let leftWins = leftUpdatedAt > rightUpdatedAt
            return SyncKeepDecision(kept: leftWins ? .left : .right, reason: .newerUpdatedAt, countsAsConflict: false)
        }
        let left = leftDeviceId ?? ""
        let right = rightDeviceId ?? ""
        let leftWins = left >= right
        return SyncKeepDecision(kept: leftWins ? .left : .right, reason: .deviceIdOrder, countsAsConflict: !sameContent)
    }

    public static func merge(local: SyncDocument, remote: SyncDocument, now: Date, writingDeviceId: String) -> SyncMergeOutcome {
        var conflicts = Set<String>()
        var newerWins = 0
        var hosts = mergeHosts(local.hosts, remote.hosts, conflicts: &conflicts, newerWins: &newerWins)
        var groups = mergeGroups(local.groups, remote.groups, conflicts: &conflicts, newerWins: &newerWins)
        var tombstones = mergeTombstones(
            prune(local.tombstones, now: now),
            prune(remote.tombstones, now: now)
        )
        applyHostTombstones(&tombstones, hosts: &hosts, conflicts: &conflicts)
        applyGroupTombstones(&tombstones, groups: &groups, conflicts: &conflicts)
        clearGroupedHosts(tombstones, hosts: &hosts)

        let document = SyncDocument(
            deviceId: writingDeviceId,
            groups: groups.sorted { $0.id.uuidString < $1.id.uuidString },
            hosts: hosts.sorted { $0.id.uuidString < $1.id.uuidString },
            tombstones: tombstones.sorted {
                ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString)
            }
        )
        return SyncMergeOutcome(
            document: document,
            conflictCount: conflicts.count,
            newerUpdatedAtKept: newerWins,
            deviceIdOrderKept: conflicts.count
        )
    }

    /// 把冲突副本依次并进主文件。副本之间、以及和主文件时间戳打平时才计入冲突。
    public static func mergeCopies(
        primary: SyncDocument,
        copies: [SyncDocument],
        now: Date,
        writingDeviceId: String
    ) -> SyncMergeOutcome {
        var current = primary
        var conflicts = 0
        var newerWins = 0
        for copy in copies {
            let step = merge(local: current, remote: copy, now: now, writingDeviceId: writingDeviceId)
            current = step.document
            conflicts += step.conflictCount
            newerWins += step.newerUpdatedAtKept
        }
        current.deviceId = writingDeviceId
        return SyncMergeOutcome(
            document: current, conflictCount: conflicts, newerUpdatedAtKept: newerWins, deviceIdOrderKept: conflicts)
    }

    private enum Side {
        case left, right
    }

    private static func choose(leftDate: Date, leftDevice: String?, rightDate: Date, rightDevice: String?) -> Side {
        let decision = decide(
            leftUpdatedAt: leftDate, leftDeviceId: leftDevice, rightUpdatedAt: rightDate, rightDeviceId: rightDevice, sameContent: true)
        return decision.kept == .left ? .left : .right
    }

    private static func mergeHosts(
        _ local: [SSHHost], _ remote: [SSHHost], conflicts: inout Set<String>, newerWins: inout Int
    ) -> [SSHHost] {
        let remoteByID = indexed(remote)
        var seen = Set<UUID>()
        var result: [SSHHost] = []
        for host in indexed(local).values {
            seen.insert(host.id)
            guard let other = remoteByID[host.id] else {
                result.append(host)
                continue
            }
            let (winner, decision) = combine(host, other)
            if decision.countsAsConflict { conflicts.insert("host-\(host.id.uuidString)") }
            if decision.reason == .newerUpdatedAt { newerWins += 1 }
            result.append(winner)
        }
        for host in remoteByID.values where !seen.contains(host.id) {
            result.append(host)
        }
        return result
    }

    private static func indexed(_ hosts: [SSHHost]) -> [UUID: SSHHost] {
        var byID: [UUID: SSHHost] = [:]
        for host in hosts {
            if let existing = byID[host.id] {
                byID[host.id] = combine(existing, host).host
            } else {
                byID[host.id] = host
            }
        }
        return byID
    }

    private static func combine(_ local: SSHHost, _ remote: SSHHost) -> (host: SSHHost, decision: SyncKeepDecision) {
        let decision = decide(
            leftUpdatedAt: local.updatedAt,
            leftDeviceId: local.updatedByDeviceId,
            rightUpdatedAt: remote.updatedAt,
            rightDeviceId: remote.updatedByDeviceId,
            sameContent: local.hasSameSyncContent(as: remote)
        )
        var winner = decision.kept == .left ? local : remote
        winner.lastConnectedAt = latest(local.lastConnectedAt, remote.lastConnectedAt)
        return (winner, decision)
    }

    private static func mergeGroups(
        _ local: [HostGroup], _ remote: [HostGroup], conflicts: inout Set<String>, newerWins: inout Int
    ) -> [HostGroup] {
        let remoteByID = indexed(remote)
        var seen = Set<UUID>()
        var result: [HostGroup] = []
        for group in indexed(local).values {
            seen.insert(group.id)
            guard let other = remoteByID[group.id] else {
                result.append(group)
                continue
            }
            let decision = decide(
                leftUpdatedAt: group.updatedAt,
                leftDeviceId: group.updatedByDeviceId,
                rightUpdatedAt: other.updatedAt,
                rightDeviceId: other.updatedByDeviceId,
                sameContent: group.hasSameSyncContent(as: other)
            )
            let winner = decision.kept == .left ? group : other
            if decision.countsAsConflict { conflicts.insert("group-\(group.id.uuidString)") }
            if decision.reason == .newerUpdatedAt { newerWins += 1 }
            result.append(winner)
        }
        for group in remoteByID.values where !seen.contains(group.id) {
            result.append(group)
        }
        return result
    }

    private static func indexed(_ groups: [HostGroup]) -> [UUID: HostGroup] {
        var byID: [UUID: HostGroup] = [:]
        for group in groups {
            if let existing = byID[group.id] {
                let side = choose(
                    leftDate: existing.updatedAt, leftDevice: existing.updatedByDeviceId,
                    rightDate: group.updatedAt, rightDevice: group.updatedByDeviceId)
                byID[group.id] = side == .left ? existing : group
            } else {
                byID[group.id] = group
            }
        }
        return byID
    }

    private static func mergeTombstones(_ local: [SyncTombstone], _ remote: [SyncTombstone]) -> [SyncTombstone] {
        var byKey: [String: SyncTombstone] = [:]
        for tomb in local + remote {
            let key = tomb.kind.rawValue + ":" + tomb.id.uuidString
            if let existing = byKey[key] {
                if tombstoneBeats(tomb, updatedAt: existing.deletedAt, deviceId: existing.deviceId) {
                    byKey[key] = tomb
                }
            } else {
                byKey[key] = tomb
            }
        }
        return Array(byKey.values)
    }

    private static func applyHostTombstones(
        _ tombstones: inout [SyncTombstone], hosts: inout [SSHHost], conflicts: inout Set<String>
    ) {
        var kept: [SSHHost] = []
        var drop = Set<UUID>()
        for host in hosts {
            guard let tomb = tombstones.first(where: { $0.kind == .host && $0.id == host.id }) else {
                kept.append(host)
                continue
            }
            if tomb.deletedAt == host.updatedAt {
                conflicts.insert("host-\(host.id.uuidString)")
            }
            if tombstoneBeats(tomb, updatedAt: host.updatedAt, deviceId: host.updatedByDeviceId) {
                continue
            }
            drop.insert(host.id)
            kept.append(host)
        }
        hosts = kept
        tombstones.removeAll { $0.kind == .host && drop.contains($0.id) }
    }

    private static func applyGroupTombstones(
        _ tombstones: inout [SyncTombstone], groups: inout [HostGroup], conflicts: inout Set<String>
    ) {
        var kept: [HostGroup] = []
        var drop = Set<UUID>()
        for group in groups {
            guard let tomb = tombstones.first(where: { $0.kind == .group && $0.id == group.id }) else {
                kept.append(group)
                continue
            }
            if tomb.deletedAt == group.updatedAt {
                conflicts.insert("group-\(group.id.uuidString)")
            }
            if tombstoneBeats(tomb, updatedAt: group.updatedAt, deviceId: group.updatedByDeviceId) {
                continue
            }
            drop.insert(group.id)
            kept.append(group)
        }
        groups = kept
        tombstones.removeAll { $0.kind == .group && drop.contains($0.id) }
    }

    /// 分组已被墓碑压过时，仍指向它、且不比删除更新的站点改为未分组。
    private static func clearGroupedHosts(_ tombstones: [SyncTombstone], hosts: inout [SSHHost]) {
        for tomb in tombstones where tomb.kind == .group {
            for index in hosts.indices where hosts[index].groupID == tomb.id {
                if tombstoneBeats(tomb, updatedAt: hosts[index].updatedAt, deviceId: hosts[index].updatedByDeviceId) {
                    hosts[index].groupID = nil
                }
            }
        }
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (let date?, nil), (nil, let date?): return date
        case (let left?, let right?): return max(left, right)
        }
    }
}

extension HostGroup {
    public func hasSameSyncContent(as other: HostGroup) -> Bool {
        name == other.name && parentID == other.parentID && sortOrder == other.sortOrder
    }
}
