import Foundation

/// 只保存删除操作的逆操作，撤销时不覆盖后来新增或修改的对象。
public struct HostDeletionUndo: Sendable {
    private var hosts: [SSHHost]
    private var groups: [HostGroup]
    private var hostMoves: [(SSHHost, SSHHost)]
    private var groupMoves: [(HostGroup, HostGroup)]

    public init(before: HostLibrary, after: HostLibrary) {
        hosts = before.hosts.filter { old in !after.hosts.contains { $0.id == old.id } }
        groups = before.groups.filter { old in !after.groups.contains { $0.id == old.id } }
        hostMoves = before.hosts.compactMap { old in
            guard let new = after.hosts.first(where: { $0.id == old.id }), old.groupID != new.groupID else { return nil }
            return (old, new)
        }
        groupMoves = before.groups.compactMap { old in
            guard let new = after.groups.first(where: { $0.id == old.id }), old.parentID != new.parentID else { return nil }
            return (old, new)
        }
    }

    public func restore(in library: inout HostLibrary, now: Date = Date(), deviceId: String) {
        // 同步来的墓碑可能比本机时钟更新；恢复必须严格胜过对应墓碑。
        func restoredDate(_ id: UUID, kind: SyncTombstone.Kind) -> Date {
            library.tombstones.filter { $0.id == id && $0.kind == kind }
                .reduce(now) { max($0, $1.deletedAt.addingTimeInterval(1)) }
        }
        for var host in hosts where !library.hosts.contains(where: { $0.id == host.id }) {
            host.updatedAt = restoredDate(host.id, kind: .host)
            host.updatedByDeviceId = deviceId
            library.tombstones.removeAll { $0.kind == .host && $0.id == host.id }
            library.upsert(host)
        }
        for var group in groups where !library.groups.contains(where: { $0.id == group.id }) {
            group.updatedAt = restoredDate(group.id, kind: .group)
            group.updatedByDeviceId = deviceId
            library.tombstones.removeAll { $0.kind == .group && $0.id == group.id }
            library.upsert(group)
        }
        // 删除后又被编辑的对象保留当前关系，避免撤销覆盖后来主动移动的结果。
        for (old, deletedState) in hostMoves {
            guard let i = library.hosts.firstIndex(where: { $0.id == old.id }), library.hosts[i] == deletedState else { continue }
            library.hosts[i].groupID = old.groupID
            library.hosts[i].updatedAt = now
            library.hosts[i].updatedByDeviceId = deviceId
        }
        for (old, deletedState) in groupMoves {
            guard let i = library.groups.firstIndex(where: { $0.id == old.id }), library.groups[i] == deletedState else { continue }
            library.groups[i].parentID = old.parentID
            library.groups[i].updatedAt = now
            library.groups[i].updatedByDeviceId = deviceId
        }
    }
}
