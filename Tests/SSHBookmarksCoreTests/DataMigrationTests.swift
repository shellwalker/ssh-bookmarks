import XCTest

@testable import SSHBookmarksCore

final class DataMigrationTests: XCTestCase {
    func testSupportFolderMovesOnlyWhenTheNewOneIsAbsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = ProductPaths.legacySupportDirectory(applicationSupport: root)
        let logs = legacy.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let hosts = legacy.appendingPathComponent("hosts.json")
        try Data("{\"ok\":true}".utf8).write(to: hosts)
        try Data("log".utf8).write(to: logs.appendingPathComponent("app.log"))

        XCTAssertEqual(try SupportDirectoryMigration.migrate(applicationSupport: root), .moved)
        let current = ProductPaths.supportDirectory(applicationSupport: root)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("hosts.json")), "{\"ok\":true}")
        let migratedLog = ProductPaths.logsDirectory(applicationSupport: root).appendingPathComponent("app.log")
        XCTAssertEqual(try String(contentsOf: migratedLog), "log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: hosts)
        XCTAssertEqual(try SupportDirectoryMigration.migrate(applicationSupport: root), .alreadyPresent)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("hosts.json")), "{\"ok\":true}")
        XCTAssertEqual(try String(contentsOf: hosts), "stale")
    }

    func testMissingLegacySupportFolderIsLeftAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try SupportDirectoryMigration.migrate(applicationSupport: root), .nothingToMove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProductPaths.supportDirectory(applicationSupport: root).path))
    }

    func testDefaultsCopyMissingKeysOnceAndDoNotOverwrite() {
        let legacyName = "test.legacy.\(UUID().uuidString)"
        let currentName = "test.current.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: legacyName)!
        let current = UserDefaults(suiteName: currentName)!
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            current.removePersistentDomain(forName: currentName)
        }
        legacy.set("dark", forKey: "appearance")
        legacy.set(false, forKey: "syncEnabled")
        legacy.set(["zh-Hans"], forKey: "AppleLanguages")
        legacy.set("/tmp/old-ssh", forKey: "sshPath")
        current.set("/usr/bin/ssh", forKey: "sshPath")
        // 全局域里通常已经有 AppleLanguages，缺省键才复制，不能盖掉进程已有的语言。
        current.set(["en"], forKey: "AppleLanguages")

        let copied = DefaultsMigration.migrate(from: legacy, into: current)
        XCTAssertEqual(copied, ["appearance", "syncEnabled"])
        XCTAssertEqual(current.string(forKey: "appearance"), "dark")
        XCTAssertEqual(current.bool(forKey: "syncEnabled"), false)
        XCTAssertEqual(current.stringArray(forKey: "AppleLanguages"), ["en"])
        XCTAssertEqual(current.string(forKey: "sshPath"), "/usr/bin/ssh")
        XCTAssertEqual(current.bool(forKey: DefaultsMigration.markerKey), true)

        legacy.set("light", forKey: "appearance")
        legacy.set("/tmp/later", forKey: "syncFolderPath")
        XCTAssertEqual(DefaultsMigration.migrate(from: legacy, into: current), [])
        XCTAssertEqual(current.string(forKey: "appearance"), "dark")
        XCTAssertNil(current.string(forKey: "syncFolderPath"))
    }

    func testKeychainReadPlan() {
        XCTAssertEqual(KeychainMigration.read(foundInCurrent: true, foundInLegacy: true), .current)
        XCTAssertEqual(KeychainMigration.read(foundInCurrent: true, foundInLegacy: false), .current)
        XCTAssertEqual(KeychainMigration.read(foundInCurrent: false, foundInLegacy: true), .copyFromLegacy)
        XCTAssertEqual(KeychainMigration.read(foundInCurrent: false, foundInLegacy: false), .missing)
        XCTAssertEqual(ProductIdentity.keychainService, "com.shellwalker.SSHBookmarks")
        XCTAssertEqual(ProductIdentity.legacyKeychainService, "com.shellwalker.MenuSSH")
    }

    func testICloudFolderUsesTheNewNameAndMovesTheLegacyFolderOnce() throws {
        let url = SyncPaths.iCloudDirectory(home: "/Users/a")
        XCTAssertTrue(url.path.hasSuffix("/SSH Bookmarks"))
        XCTAssertFalse(url.path.hasSuffix("/MenuSSH"))
        XCTAssertEqual(ProductIdentity.iCloudDirectoryName, "SSH Bookmarks")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let legacy = ICloudDirectoryMigration.directory(home: home.path, folderName: "MenuSSH")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("sync".utf8).write(to: legacy.appendingPathComponent("menu-ssh-sync.json"))
        XCTAssertEqual(try ICloudDirectoryMigration.migrate(home: home.path), .moved)
        let current = ICloudDirectoryMigration.directory(home: home.path, folderName: "SSH Bookmarks")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("menu-ssh-sync.json")), "sync")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(try ICloudDirectoryMigration.migrate(home: home.path), .alreadyPresent)
        XCTAssertEqual(
            ProductPaths.legacyLogsDirectory(applicationSupport: URL(fileURLWithPath: "/tmp")).lastPathComponent,
            "Logs"
        )
    }

    func testEnvironmentAliasPrefersTheNewName() {
        XCTAssertEqual(
            EnvironmentAlias.string(primary: "SSHBOOKMARKS_UI_TEST", legacy: "MENUSH_UI_TEST", environment: ["MENUSH_UI_TEST": "1"]),
            "1"
        )
        XCTAssertEqual(
            EnvironmentAlias.string(
                primary: "SSHBOOKMARKS_DATA_DIR",
                legacy: "MENUSH_DATA_DIR",
                environment: ["SSHBOOKMARKS_DATA_DIR": "/new", "MENUSH_DATA_DIR": "/old"]
            ),
            "/new"
        )
        XCTAssertEqual(
            EnvironmentAlias.string(
                primary: "SSHBOOKMARKS_DATA_DIR",
                legacy: "MENUSH_DATA_DIR",
                environment: ["SSHBOOKMARKS_DATA_DIR": "", "MENUSH_DATA_DIR": "/old"]
            ),
            "/old"
        )
        XCTAssertFalse(
            EnvironmentAlias.flag(primary: "SSHBOOKMARKS_UI_TEST", legacy: "MENUSH_UI_TEST", environment: [:])
        )
        XCTAssertEqual(AskpassTokenStore.token(in: ["MENUSH_ASKPASS_TOKEN": "abc"]), "abc")
        XCTAssertEqual(
            AskpassTokenStore.token(in: ["SSHBOOKMARKS_ASKPASS_TOKEN": "new", "MENUSH_ASKPASS_TOKEN": "old"]),
            "new"
        )
    }
}
