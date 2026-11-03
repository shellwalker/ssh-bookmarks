import Foundation
import XCTest

@testable import SSHBookmarksCore

final class Review2MigrationTests: XCTestCase {
    func testPartialSupportMigrationRetriesAfterMainFileWasCopied() throws {
        try verifyRetry(iCloud: false)
    }

    func testPartialICloudMigrationRetriesAfterMainFileWasCopied() throws {
        try verifyRetry(iCloud: true)
    }

    func testICloudTrailingClosureStillCoordinatesMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = ICloudDirectoryMigration.directory(home: root.path, folderName: "MenuSSH")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        var coordinated = false
        XCTAssertEqual(
            try ICloudDirectoryMigration.migrate(home: root.path) { source, destination in
                coordinated = true
                try FileManager.default.moveItem(at: source, to: destination)
            }, .moved)
        XCTAssertTrue(coordinated)
    }

    func testRetryAfterMoveSucceededButCoordinationReportedFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = ICloudDirectoryMigration.directory(home: root.path, folderName: "MenuSSH")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("sync".utf8).write(to: legacy.appendingPathComponent(SyncDocument.fileName))
        XCTAssertThrowsError(
            try ICloudDirectoryMigration.migrate(home: root.path) { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
                throw CocoaError(.fileWriteUnknown)
            })
        XCTAssertEqual(try ICloudDirectoryMigration.migrate(home: root.path), .alreadyPresent)
        let current = ICloudDirectoryMigration.directory(home: root.path, folderName: "SSH Bookmarks")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent(".migration-complete").path))
    }

    private func verifyRetry(iCloud: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let legacy =
            iCloud
            ? ICloudDirectoryMigration.directory(home: root.path, folderName: "MenuSSH")
            : ProductPaths.legacySupportDirectory(applicationSupport: root)
        let current =
            iCloud
            ? ICloudDirectoryMigration.directory(home: root.path, folderName: "SSH Bookmarks")
            : ProductPaths.supportDirectory(applicationSupport: root)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        let main = iCloud ? SyncDocument.fileName : "hosts.json"
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent(main))
        try Data("remaining".utf8).write(to: legacy.appendingPathComponent("zz-conflict.json"))
        let interrupted: (URL, URL) throws -> Void = { source, destination in
            if source.lastPathComponent == "zz-conflict.json" { throw CocoaError(.fileWriteUnknown) }
            try fm.copyItem(at: source, to: destination)
        }
        if iCloud {
            XCTAssertThrowsError(try ICloudDirectoryMigration.migrate(home: root.path, copy: interrupted))
        } else {
            XCTAssertThrowsError(try SupportDirectoryMigration.migrate(applicationSupport: root, copy: interrupted))
        }
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent(main).path))
        XCTAssertFalse(fm.fileExists(atPath: current.appendingPathComponent(".migration-complete").path))
        // A file changed in the new directory must survive; preserve the legacy content separately.
        try Data("current".utf8).write(to: current.appendingPathComponent(main))
        if iCloud {
            XCTAssertEqual(try ICloudDirectoryMigration.migrate(home: root.path), .moved)
        } else {
            XCTAssertEqual(try SupportDirectoryMigration.migrate(applicationSupport: root), .moved)
        }
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent(main)), "current")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("zz-conflict.json")), "remaining")
        let copies = try fm.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)
        XCTAssertTrue(try copies.contains { try Data(contentsOf: $0) == Data("legacy".utf8) })
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent(".migration-complete").path))
    }
}
