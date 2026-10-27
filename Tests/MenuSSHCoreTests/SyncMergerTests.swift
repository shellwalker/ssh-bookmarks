import XCTest

@testable import MenuSSHCore

final class SyncMergerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let deviceA = "device-a"
    let deviceB = "device-b"

    func host(_ label: String, id: UUID = UUID(), at time: Date, device: String, portForwards: [PortForward] = []) -> SSHHost {
        SSHHost(
            id: id, label: label, hostname: "example.com", username: "alice", portForwards: portForwards, updatedAt: time,
            updatedByDeviceId: device)
    }

    func group(_ name: String, id: UUID = UUID(), at time: Date, device: String, parent: UUID? = nil, order: Int = 0) -> HostGroup {
        HostGroup(id: id, name: name, parentID: parent, sortOrder: order, updatedAt: time, updatedByDeviceId: device)
    }

    func doc(
        _ hosts: [SSHHost] = [], groups: [HostGroup] = [], tombstones: [SyncTombstone] = [], device: String = "writer"
    ) -> SyncDocument {
        SyncDocument(deviceId: device, groups: groups, hosts: hosts, tombstones: tombstones)
    }

    func testNewerRemoteWinsSilently() {
        let id = UUID()
        let local = doc([host("old", id: id, at: t0, device: deviceA)])
        let remote = doc([host("new", id: id, at: t0.addingTimeInterval(10), device: deviceB)])
        let outcome = SyncMerger.merge(local: local, remote: remote, now: t0.addingTimeInterval(20), writingDeviceId: deviceA)
        XCTAssertEqual(outcome.conflictCount, 0)
        XCTAssertEqual(outcome.newerUpdatedAtKept, 1)
        XCTAssertEqual(outcome.deviceIdOrderKept, 0)
        XCTAssertEqual(outcome.document.hosts.first?.label, "new")
        XCTAssertEqual(outcome.document.deviceId, deviceA)
    }

    func testNewerLocalWinsSilently() {
        let id = UUID()
        let local = doc([host("local", id: id, at: t0.addingTimeInterval(5), device: deviceA)])
        let remote = doc([host("remote", id: id, at: t0, device: deviceB)])
        let outcome = SyncMerger.merge(local: local, remote: remote, now: t0.addingTimeInterval(9), writingDeviceId: deviceA)
        XCTAssertEqual(outcome.conflictCount, 0)
        XCTAssertEqual(outcome.document.hosts.first?.label, "local")
    }

    func testEqualUpdatedAtUsesLargerDeviceIdAndCountsConflict() {
        let id = UUID()
        let local = doc([host("from-a", id: id, at: t0, device: deviceA)])
        let remote = doc([host("from-b", id: id, at: t0, device: deviceB)])
        let outcome = SyncMerger.merge(local: local, remote: remote, now: t0.addingTimeInterval(1), writingDeviceId: deviceA)
        XCTAssertEqual(outcome.conflictCount, 1)
        XCTAssertEqual(outcome.deviceIdOrderKept, 1)
        XCTAssertEqual(outcome.newerUpdatedAtKept, 0)
        XCTAssertEqual(outcome.document.hosts.first?.label, "from-b")
        XCTAssertEqual(outcome.document.hosts.first?.updatedByDeviceId, deviceB)
    }

    func testEqualContentIsNotAConflictAndKeepsLaterLastConnected() {
        let id = UUID()
        var localHost = host("same", id: id, at: t0, device: deviceA)
        var remoteHost = host("same", id: id, at: t0, device: deviceB)
        localHost.lastConnectedAt = t0.addingTimeInterval(50)
        remoteHost.lastConnectedAt = t0.addingTimeInterval(10)
        let outcome = SyncMerger.merge(
            local: doc([localHost]), remote: doc([remoteHost]), now: t0.addingTimeInterval(80), writingDeviceId: deviceA)
        XCTAssertEqual(outcome.conflictCount, 0)
        XCTAssertEqual(outcome.document.hosts.first?.lastConnectedAt, t0.addingTimeInterval(50))
    }

    func testDisjointHostsAndGroupsStay() {
        let outcome = SyncMerger.merge(
            local: doc([host("L", at: t0, device: deviceA)], groups: [group("G1", at: t0, device: deviceA)]),
            remote: doc([host("R", at: t0, device: deviceB)], groups: [group("G2", at: t0, device: deviceB)]),
            now: t0.addingTimeInterval(1),
            writingDeviceId: deviceA
        )
        XCTAssertEqual(outcome.conflictCount, 0)
        XCTAssertEqual(Set(outcome.document.hosts.map(\.label)), ["L", "R"])
        XCTAssertEqual(Set(outcome.document.groups.map(\.name)), ["G1", "G2"])
    }

    func testPortForwardTieIsAConflict() {
        let id = UUID()
        let forward = PortForward(kind: .local, listenPort: 8080, destinationHost: "db", destinationPort: 5432)
        let local = doc([host("h", id: id, at: t0, device: deviceA, portForwards: [forward])])
        let remote = doc([host("h", id: id, at: t0, device: deviceB)])
        let outcome = SyncMerger.merge(local: local, remote: remote, now: t0.addingTimeInterval(1), writingDeviceId: deviceA)
        XCTAssertEqual(outcome.conflictCount, 1)
        XCTAssertEqual(outcome.document.hosts.first?.portForwards.count, 0)
    }

    func testGroupTieBreakKeepsParentAndSortOrderFromLargerDevice() {
        let id = UUID()
        let parent = UUID()
        let local = doc(groups: [group("A", id: id, at: t0, device: deviceA, order: 1)])
        let remote = doc(groups: [group("B", id: id, at: t0, device: deviceB, parent: parent, order: 4)])
        let outcome = SyncMerger.merge(local: local, remote: remote, now: t0.addingTimeInterval(1), writingDeviceId: deviceA)
        XCTAssertEqual(outcome.conflictCount, 1)
        XCTAssertEqual(outcome.document.groups.first?.name, "B")
        XCTAssertEqual(outcome.document.groups.first?.parentID, parent)
        XCTAssertEqual(outcome.document.groups.first?.sortOrder, 4)
    }

    func testNewerTombstoneDeletesSilently() {
        let id = UUID()
        let local = doc([host("live", id: id, at: t0, device: deviceA)])
        let remote = doc(
            tombstones: [SyncTombstone(id: id, kind: .host, deletedAt: t0.addingTimeInterval(30), deviceId: deviceB)])
        let outcome = SyncMerger.merge(local: local, remote: remote, now: t0.addingTimeInterval(40), writingDeviceId: deviceA)
        XCTAssertEqual(outcome.conflictCount, 0)
        XCTAssertTrue(outcome.document.hosts.isEmpty)
        XCTAssertEqual(outcome.document.tombstones.count, 1)
    }

    func testEditAfterDeleteComesBackSilently() {
        let id = UUID()
        let local = doc([host("revived", id: id, at: t0.addingTimeInterval(20), device: deviceA)])
        let remote = doc(tombstones: [SyncTombstone(id: id, kind: .host, deletedAt: t0, deviceId: deviceB)])
        let outcome = SyncMerger.merge(local: local, remote: remote, now: t0.addingTimeInterval(30), writingDeviceId: deviceA)
        XCTAssertEqual(outcome.conflictCount, 0)
        XCTAssertEqual(outcome.document.hosts.first?.label, "revived")
        XCTAssertTrue(outcome.document.tombstones.isEmpty)
    }

    func testEqualTimeDeleteUsesLargerDeviceId() {
        let id = UUID()
        let local = doc([host("live", id: id, at: t0, device: deviceA)])
        let remote = doc(tombstones: [SyncTombstone(id: id, kind: .host, deletedAt: t0, deviceId: deviceB)])
        let deleted = SyncMerger.merge(local: local, remote: remote, now: t0.addingTimeInterval(5), writingDeviceId: deviceA)
        XCTAssertEqual(deleted.conflictCount, 1)
        XCTAssertTrue(deleted.document.hosts.isEmpty)

        let live = doc([host("live", id: id, at: t0, device: deviceB)])
        let olderDelete = doc(tombstones: [SyncTombstone(id: id, kind: .host, deletedAt: t0, deviceId: deviceA)])
        let kept = SyncMerger.merge(local: live, remote: olderDelete, now: t0.addingTimeInterval(5), writingDeviceId: deviceB)
        XCTAssertEqual(kept.conflictCount, 1)
        XCTAssertEqual(kept.document.hosts.first?.label, "live")
    }

    func testTombstoneExpiresAfterNinetyDays() {
        let id = UUID()
        let deletedAt = t0
        let now = deletedAt.addingTimeInterval(SyncMerger.tombstoneRetention + 1)
        let local = doc([host("still", id: id, at: deletedAt.addingTimeInterval(-10), device: deviceA)])
        let remote = doc(tombstones: [SyncTombstone(id: id, kind: .host, deletedAt: deletedAt, deviceId: deviceB)])
        let outcome = SyncMerger.merge(local: local, remote: remote, now: now, writingDeviceId: deviceA)
        XCTAssertEqual(outcome.conflictCount, 0)
        XCTAssertEqual(outcome.document.hosts.first?.label, "still")
        XCTAssertTrue(outcome.document.tombstones.isEmpty)
    }

    func testTombstoneWithinNinetyDaysStillDeletes() {
        let id = UUID()
        let deletedAt = t0
        let now = deletedAt.addingTimeInterval(SyncMerger.tombstoneRetention)
        let local = doc([host("old", id: id, at: deletedAt.addingTimeInterval(-10), device: deviceA)])
        let remote = doc(tombstones: [SyncTombstone(id: id, kind: .host, deletedAt: deletedAt, deviceId: deviceB)])
        let outcome = SyncMerger.merge(local: local, remote: remote, now: now, writingDeviceId: deviceA)
        XCTAssertTrue(outcome.document.hosts.isEmpty)
        XCTAssertEqual(outcome.document.tombstones.count, 1)
    }

    func testExpiredGroupTombstoneDoesNotUngroup() {
        let groupID = UUID()
        let hostID = UUID()
        var live = host("h", id: hostID, at: t0, device: deviceA)
        live.groupID = groupID
        let now = t0.addingTimeInterval(SyncMerger.tombstoneRetention + 5)
        let outcome = SyncMerger.merge(
            local: doc([live], groups: [group("G", id: groupID, at: t0, device: deviceA)]),
            remote: doc(tombstones: [SyncTombstone(id: groupID, kind: .group, deletedAt: t0, deviceId: deviceB)]),
            now: now,
            writingDeviceId: deviceA
        )
        XCTAssertEqual(outcome.document.hosts.first?.groupID, groupID)
        XCTAssertEqual(outcome.document.groups.count, 1)
    }

    func testEmptyRemoteKeepsLocalHosts() {
        let localHost = host("keep-me", at: t0, device: deviceA)
        let outcome = SyncMerger.merge(
            local: doc([localHost], groups: [group("Ops", at: t0, device: deviceA)]),
            remote: doc(),
            now: t0.addingTimeInterval(5),
            writingDeviceId: deviceB
        )
        XCTAssertEqual(outcome.document.hosts.map(\.label), ["keep-me"])
        XCTAssertEqual(outcome.document.groups.map(\.name), ["Ops"])
        XCTAssertEqual(outcome.conflictCount, 0)
    }

    func testConflictWordingNamesTheKeptSide() {
        let newer = SyncMerger.decide(
            leftUpdatedAt: t0.addingTimeInterval(5),
            leftDeviceId: "aaa",
            rightUpdatedAt: t0,
            rightDeviceId: "zzz",
            sameContent: false
        )
        XCTAssertEqual(newer.kept, .left)
        XCTAssertEqual(newer.keptSideName, "left")
        XCTAssertEqual(newer.ruleName, "newer updatedAt")
        XCTAssertFalse(newer.countsAsConflict)

        let tie = SyncMerger.decide(
            leftUpdatedAt: t0, leftDeviceId: "device-a", rightUpdatedAt: t0, rightDeviceId: "device-b", sameContent: false)
        XCTAssertEqual(tie.kept, .right)
        XCTAssertEqual(tie.ruleName, "deviceId order")
        XCTAssertTrue(tie.countsAsConflict)
        XCTAssertEqual(
            SyncMerger.conflictNotice(tiedItems: 2),
            "Kept the greater device id for 2 tied items. When updatedAt differs, the newer side is kept."
        )

        let same = SyncMerger.decide(
            leftUpdatedAt: t0, leftDeviceId: "b", rightUpdatedAt: t0, rightDeviceId: "a", sameContent: true)
        XCTAssertEqual(same.kept, .left)
        XCTAssertFalse(same.countsAsConflict)
    }

    func testLibraryRemoveRecordsTombstone() {
        var library = HostLibrary(hosts: [host("h", at: t0, device: deviceA)])
        let id = library.hosts[0].id
        library.removeHost(id: id, now: t0.addingTimeInterval(3), deviceId: deviceA)
        XCTAssertTrue(library.hosts.isEmpty)
        XCTAssertEqual(library.tombstones.first?.id, id)
        XCTAssertEqual(library.tombstones.first?.kind, .host)
        let pruned = library.pruningTombstones(now: t0.addingTimeInterval(SyncMerger.tombstoneRetention + 10))
        XCTAssertTrue(pruned.tombstones.isEmpty)
    }
}
