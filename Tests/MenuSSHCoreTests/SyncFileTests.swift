import XCTest

@testable import MenuSSHCore

final class SyncFileTests: XCTestCase {
    func testConflictCopyNames() {
        XCTAssertTrue(SyncConflictNames.isCopy("menu-ssh-sync 2.json", of: SyncDocument.fileName))
        XCTAssertTrue(SyncConflictNames.isCopy("hosts 2.json", of: "hosts.json"))
        XCTAssertTrue(SyncConflictNames.isCopy("hosts 10.json", of: "hosts.json"))
        XCTAssertFalse(SyncConflictNames.isCopy("menu-ssh-sync.json", of: SyncDocument.fileName))
        XCTAssertFalse(SyncConflictNames.isCopy("menu-ssh-sync2.json", of: SyncDocument.fileName))
        XCTAssertFalse(SyncConflictNames.isCopy("menu-ssh-sync 1.json", of: SyncDocument.fileName))
        XCTAssertFalse(SyncConflictNames.isCopy("other 2.json", of: SyncDocument.fileName))
        XCTAssertFalse(SyncConflictNames.isCopy("hosts 02.json", of: "hosts.json"))
        XCTAssertEqual(
            SyncConflictNames.copies(
                in: ["menu-ssh-sync.json", "menu-ssh-sync 3.json", "notes.txt", "menu-ssh-sync 2.json"],
                of: SyncDocument.fileName),
            ["menu-ssh-sync 2.json", "menu-ssh-sync 3.json"]
        )
    }

    func testRoundTripKeepsPortForwardsAndOmitsSecretKeys() throws {
        let forward = PortForward(
            kind: .local, bindAddress: "127.0.0.1", listenPort: 2200, destinationHost: "db.internal", destinationPort: 5432)
        let parent = UUID()
        let group = HostGroup(
            id: parent, name: "Prod", sortOrder: 2, updatedAt: Date(timeIntervalSince1970: 10), updatedByDeviceId: "device-a")
        var host = SSHHost(
            label: "DB", hostname: "db.example", username: "alice", groupID: parent, portForwards: [forward], notes: "no secrets here",
            updatedAt: Date(timeIntervalSince1970: 20), updatedByDeviceId: "device-a")
        host.identityFile = "~/.ssh/id_ed25519"
        let document = SyncDocument(deviceId: "device-a", groups: [group], hosts: [host])
        let data = try SyncCodec.encode(document)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("s3cr3t-password"))
        let object = try JSONSerialization.jsonObject(with: data)
        let keys = SyncSecretScan.keys(in: object)
        XCTAssertTrue(keys.isDisjoint(with: SyncSecretScan.forbiddenKeys))
        XCTAssertTrue(keys.contains("portforwards"))
        XCTAssertTrue(keys.contains("username"))
        XCTAssertTrue(keys.contains("hostname"))

        let decoded = try SyncCodec.decode(data)
        XCTAssertEqual(decoded.hosts.first?.portForwards, [forward])
        XCTAssertEqual(decoded.groups.first?.parentID, nil)
        XCTAssertEqual(decoded.groups.first?.sortOrder, 2)
        XCTAssertEqual(decoded.hosts.first?.groupID, parent)
        XCTAssertNil(decoded.hosts.first?.identityFile?.contains("password") == true ? "x" : nil)
    }

    func testSchemaOneDefaultsNewFieldsAndEncodeWritesCurrentSchema() throws {
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let json = """
            {"schemaVersion":1,"deviceId":"d","groups":[],"hosts":[{"id":"\(id)","hostname":"h","label":"h"}],"tombstones":[]}
            """
        let decoded = try SyncCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.hosts.first?.forwardAgent, false)
        XCTAssertEqual(decoded.hosts.first?.startupCommand, "")
        let encoded = try SyncCodec.encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, SyncDocument.currentSchemaVersion)
        let keys = SyncSecretScan.keys(in: try JSONSerialization.jsonObject(with: encoded))
        XCTAssertTrue(keys.contains("forwardagent"))
        XCTAssertTrue(keys.contains("startupcommand"))
        XCTAssertTrue(keys.isDisjoint(with: SyncSecretScan.forbiddenKeys))
    }

    func testNewerSchemaIsRefused() {
        let json = #"{"schemaVersion":9,"deviceId":"x","groups":[],"hosts":[],"tombstones":[]}"#
        XCTAssertThrowsError(try SyncCodec.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? SyncFormatError, .newerSchema(9))
        }
    }

    func testReconcileMergesConflictCopyThenDeletesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let primary = SyncDocument(
            deviceId: "device-a",
            hosts: [SSHHost(id: id, label: "old", hostname: "h", updatedAt: t0, updatedByDeviceId: "device-a")]
        )
        let copy = SyncDocument(
            deviceId: "device-b",
            hosts: [SSHHost(id: id, label: "from-copy", hostname: "h", updatedAt: t0.addingTimeInterval(15), updatedByDeviceId: "device-b")]
        )
        try SyncCodec.write(primary, to: dir.appendingPathComponent(SyncDocument.fileName))
        try SyncCodec.write(copy, to: dir.appendingPathComponent("menu-ssh-sync 2.json"))
        let local = HostLibrary(hosts: [SSHHost(id: id, label: "old", hostname: "h", updatedAt: t0, updatedByDeviceId: "device-a")])
        let result = try SyncReconciler.reconcile(local: local, directory: dir, deviceId: "device-a", now: t0.addingTimeInterval(20))
        XCTAssertEqual(result.conflictCount, 0)
        XCTAssertEqual(result.library.hosts.first?.label, "from-copy")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.filter { !$0.hasPrefix(".") }, [SyncDocument.fileName])
        let written = try Data(contentsOf: dir.appendingPathComponent(SyncDocument.fileName))
        let keys = SyncSecretScan.keys(in: try JSONSerialization.jsonObject(with: written))
        XCTAssertTrue(keys.isDisjoint(with: SyncSecretScan.forbiddenKeys))
    }

    func testReconcileCountsTieInsideConflictCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = SyncDocument(
            deviceId: "device-a",
            hosts: [SSHHost(id: id, label: "aaa", hostname: "h", updatedAt: t0, updatedByDeviceId: "device-a")]
        )
        let copy = SyncDocument(
            deviceId: "device-z",
            hosts: [SSHHost(id: id, label: "zzz", hostname: "h", updatedAt: t0, updatedByDeviceId: "device-z")]
        )
        try SyncCodec.write(primary, to: dir.appendingPathComponent(SyncDocument.fileName))
        try SyncCodec.write(copy, to: dir.appendingPathComponent("menu-ssh-sync 2.json"))
        let local = primary.makeLibrary()
        let result = try SyncReconciler.reconcile(local: local, directory: dir, deviceId: "device-a", now: t0.addingTimeInterval(5))
        XCTAssertEqual(result.library.hosts.first?.label, "zzz")
        XCTAssertGreaterThanOrEqual(result.conflictCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("menu-ssh-sync 2.json").path))
    }

    func testAtomicWriteLeavesNoTempFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("menu-ssh-sync.json")
        try AtomicFileWrite.write(Data("one".utf8), to: url)
        try AtomicFileWrite.write(Data("two".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url), "two")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["menu-ssh-sync.json"])
    }

    func testUnreadablePrimaryIsNotReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SyncDocument.fileName)
        try Data("{".utf8).write(to: url)
        let local = HostLibrary(hosts: [SSHHost(label: "L", hostname: "h")])
        XCTAssertThrowsError(try SyncReconciler.reconcile(local: local, directory: dir, deviceId: "device-a")) { error in
            XCTAssertEqual(error as? SyncFormatError, .unreadablePrimary)
        }
        XCTAssertEqual(try String(contentsOf: url), "{")
    }
}
