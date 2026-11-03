import Foundation
import XCTest

@testable import SSHBookmarksCore

final class ReviewPersistenceTests: XCTestCase {
    func testSyncTransactionSerializesReadModifyWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("counter")
        try Data("0".utf8).write(to: url)
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            do {
                try SyncFileCoordination.transaction(url: url) { coordinatedURL in
                    let value = Int(try String(contentsOf: coordinatedURL))!
                    try Data(String(value + 1).utf8).write(to: coordinatedURL)
                }
            } catch {
                XCTFail("Transaction failed: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: url), "40")
    }

    func testUnreadablePrimaryLeavesConflictCopyUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let primary = root.appendingPathComponent(SyncDocument.fileName)
        let copy = root.appendingPathComponent(
            URL(fileURLWithPath: SyncDocument.fileName).deletingPathExtension().lastPathComponent + " 2.json")
        let original = Data("invalid primary".utf8)
        let copyData = try SyncCodec.encode(SyncDocument(deviceId: "other"))
        try original.write(to: primary)
        try copyData.write(to: copy)
        XCTAssertThrowsError(try SyncReconciler.reconcile(local: .empty, directory: root, deviceId: "local"))
        XCTAssertEqual(try Data(contentsOf: primary), original)
        XCTAssertEqual(try Data(contentsOf: copy), copyData)
    }

    func testFirstSyncMergesReadableCopyAndRetainsUnreadableCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: SyncDocument.fileName).deletingPathExtension().lastPathComponent
        let readable = root.appendingPathComponent(stem + " 2.json")
        let unreadable = root.appendingPathComponent(stem + " 3.json")
        let host = SSHHost(label: "remote", hostname: "remote.example")
        try SyncCodec.encode(SyncDocument(deviceId: "remote", hosts: [host])).write(to: readable)
        let invalid = Data("not JSON".utf8)
        try invalid.write(to: unreadable)
        let result = try SyncReconciler.reconcile(local: .empty, directory: root, deviceId: "local")
        XCTAssertEqual(result.library.hosts.map(\.id), [host.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: readable.path))
        XCTAssertEqual(try Data(contentsOf: unreadable), invalid)
        let written = try SyncCodec.decode(Data(contentsOf: root.appendingPathComponent(SyncDocument.fileName)))
        XCTAssertEqual(written.hosts.map(\.id), [host.id])
    }

    #if os(macOS)
        // Linux 的 replaceItemAt 已知失败；真实协调事务与替换路径在 macOS 执行。
        func testConcurrentReconciliationKeepsBothWriters() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let hosts = [SSHHost(label: "A", hostname: "a.example"), SSHHost(label: "B", hostname: "b.example")]
            DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
                do {
                    _ = try SyncReconciler.reconcile(
                        local: HostLibrary(hosts: [hosts[index]]), directory: root, deviceId: "device-\(index)")
                } catch {
                    XCTFail("Reconciliation failed: \(error)")
                }
            }
            let result = try SyncCodec.decode(Data(contentsOf: root.appendingPathComponent(SyncDocument.fileName)))
            XCTAssertEqual(Set(result.makeLibrary().hosts.map(\.id)), Set(hosts.map(\.id)))
        }
    #endif

    func testConflictSnapshotPreservesChangedContentsAndDate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first".utf8).write(to: url)
        let snapshot = try SyncCopySnapshot(url: url)
        XCTAssertTrue(snapshot.isUnchanged())
        try Data("other".utf8).write(to: url)
        XCTAssertFalse(snapshot.isUnchanged())
        try snapshot.data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        XCTAssertFalse(snapshot.isUnchanged())
    }

    func testLocalNewerSchemaCannotBeSavedOrOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("{\"schemaVersion\":999,\"futureField\":true}".utf8)
        try original.write(to: url)
        let store = HostFileStore(fileURL: url)
        let library = try store.load()
        XCTAssertEqual(library.schemaVersion, 999)
        XCTAssertThrowsError(try HostFileStore.makeEncoder().encode(library))
        XCTAssertThrowsError(try store.save(library))
        XCTAssertThrowsError(try store.save(.empty))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSupportMigrationIgnoresLogsInNewDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ProductPaths.legacySupportDirectory(applicationSupport: root)
        let new = ProductPaths.supportDirectory(applicationSupport: root)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new.appendingPathComponent("Logs"), withIntermediateDirectories: true)
        try Data("old hosts".utf8).write(to: old.appendingPathComponent("hosts.json"))
        XCTAssertEqual(try SupportDirectoryMigration.migrate(applicationSupport: root), .moved)
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("hosts.json")), "old hosts")
    }

    func testICloudMigrationIgnoresLogsAndUpdatesOnlyExactOldPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ICloudDirectoryMigration.directory(home: root.path, folderName: "MenuSSH")
        let new = ICloudDirectoryMigration.directory(home: root.path, folderName: "SSH Bookmarks")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new.appendingPathComponent("Logs"), withIntermediateDirectories: true)
        try Data("sync data".utf8).write(to: old.appendingPathComponent(SyncDocument.fileName))
        XCTAssertEqual(try ICloudDirectoryMigration.migrate(home: root.path), .moved)
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent(SyncDocument.fileName)), "sync data")
        XCTAssertEqual(ICloudDirectoryMigration.migratedSyncFolderPath(old.path, home: root.path), new.path)
        for path in [nil, "/custom/MenuSSH", old.path + "/nested", new.path] {
            XCTAssertEqual(ICloudDirectoryMigration.migratedSyncFolderPath(path, home: root.path), path)
        }
    }

    func testFailedMigrationKeepsLegacyDataForRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ICloudDirectoryMigration.directory(home: root.path, folderName: "MenuSSH")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let source = old.appendingPathComponent(SyncDocument.fileName)
        try Data("sync data".utf8).write(to: source)
        XCTAssertThrowsError(
            try ICloudDirectoryMigration.migrate(
                home: root.path,
                move: { _, _ in
                    throw CocoaError(.fileWriteNoPermission)
                }))
        XCTAssertEqual(try String(contentsOf: source), "sync data")
        XCTAssertEqual(try ICloudDirectoryMigration.migrate(home: root.path), .moved)
    }

    func testUnchangedSyncDoesNotRewriteRemoteDeviceOrModificationDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(SyncDocument.fileName)
        let original = try SyncCodec.encode(SyncDocument(deviceId: "remote"))
        try original.write(to: url)
        let before = try SyncCopySnapshot(url: url)
        _ = try SyncReconciler.reconcile(local: .empty, directory: root, deviceId: "local")
        XCTAssertTrue(before.isUnchanged())
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFailedHostSaveDoesNotOverwriteBlockingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep".utf8).write(to: root)
        let store = HostFileStore(fileURL: root.appendingPathComponent("hosts.json"))
        XCTAssertThrowsError(try store.save(.empty))
        XCTAssertEqual(try String(contentsOf: root), "keep")
    }

    func testQuotedSecretsTruncatedKeysAndCaseInsensitiveNames() {
        let redactor = DiagnosticRedactor(hostnames: ["server.example"], usernames: ["Alice"])
        let value = redactor.redact("password='alpha beta' --password \"gamma delta\" SERVER.EXAMPLE ALICE")
        for secret in ["alpha", "beta", "gamma", "delta", "SERVER.EXAMPLE", "ALICE"] {
            XCTAssertFalse(value.contains(secret), value)
        }
        XCTAssertFalse(redactor.redact("-----BEGIN OPENSSH PRIVATE KEY-----\nsecret-body").contains("secret-body"))
        XCTAssertFalse(redactor.redact("secret-body\n-----END OPENSSH PRIVATE KEY-----").contains("secret-body"))
    }
}
