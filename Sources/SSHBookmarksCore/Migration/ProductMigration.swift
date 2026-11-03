import Foundation

/// 显示名是 “SSH Bookmarks”（中英文相同）。没有空格的标识用 SSHBookmarks。
public enum ProductIdentity {
    public static let displayName = "SSH Bookmarks"
    public static let bundleIdentifier = "com.shellwalker.SSHBookmarks"
    public static let legacyBundleIdentifier = "com.shellwalker.MenuSSH"
    public static let supportDirectoryName = "SSH Bookmarks"
    public static let legacySupportDirectoryName = "MenuSSH"
    /// 日志放在 Application Support 里面，搬文件夹时一起搬走。
    public static let logsDirectoryName = "Logs"
    public static let iCloudDirectoryName = "SSH Bookmarks"
    public static let legacyICloudDirectoryName = "MenuSSH"
    public static let keychainService = "com.shellwalker.SSHBookmarks"
    public static let legacyKeychainService = "com.shellwalker.MenuSSH"
    public static let keychainLabel = "SSH Bookmarks"
}

public enum ProductPaths {
    public static func supportDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(ProductIdentity.supportDirectoryName, isDirectory: true)
    }

    public static func legacySupportDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(ProductIdentity.legacySupportDirectoryName, isDirectory: true)
    }

    public static func logsDirectory(applicationSupport: URL) -> URL {
        supportDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent(ProductIdentity.logsDirectoryName, isDirectory: true)
    }

    public static func legacyLogsDirectory(applicationSupport: URL) -> URL {
        legacySupportDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent(ProductIdentity.logsDirectoryName, isDirectory: true)
    }
}

public enum SupportDirectoryMigration {
    public enum Result: Equatable {
        /// 旧目录已改名为新目录。
        case moved
        /// 完成标记已存在，或旧目录已搬完。
        case alreadyPresent
        /// 没有旧目录。
        case nothingToMove
    }

    /// Merge an interrupted migration without overwriting newer data.
    public static func migrate(
        applicationSupport: URL, fileManager: FileManager = .default,
        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws -> Result {
        let legacy = ProductPaths.legacySupportDirectory(applicationSupport: applicationSupport)
        let current = ProductPaths.supportDirectory(applicationSupport: applicationSupport)
        return try DirectoryMigration.migrate(
            legacy: legacy, current: current, fileManager: fileManager,
            move: { try fileManager.moveItem(at: $0, to: $1) }, copy: copy)
    }

}

public enum DefaultsMigration {
    public static let markerKey = "SSHBookmarks.didCopyLegacyDefaults"
    /// 只复制这些键。新域里已经有的键不覆盖。
    public static let keys = [
        "appearance",
        "language",
        "dockIconMode",
        "terminal",
        "terminalOpenMode",
        "sshPath",
        "closePanelAfterConnect",
        "syncEnabled",
        "syncFolderPath",
        "syncDeviceId",
        "AppleLanguages",
    ]

    /// 从旧域抄一次。写好标记后，以后启动不再覆盖。返回这次抄到的键。
    @discardableResult
    public static func migrate(from legacy: UserDefaults, into current: UserDefaults) -> [String] {
        if current.object(forKey: markerKey) != nil { return [] }
        var copied: [String] = []
        for key in keys {
            if current.object(forKey: key) != nil { continue }
            guard let value = legacy.object(forKey: key) else { continue }
            current.set(value, forKey: key)
            copied.append(key)
        }
        current.set(true, forKey: markerKey)
        return copied
    }

    /// 旧应用的 UserDefaults.standard 落在 `com.shellwalker.MenuSSH.plist`，同名 suite 读的就是那份。
    /// 界面测试不要调用：测试进程用独立 suite，不应碰用户的偏好。
    @discardableResult
    public static func migrateLegacyDomain(into current: UserDefaults) -> [String] {
        guard let legacy = UserDefaults(suiteName: ProductIdentity.legacyBundleIdentifier) else { return [] }
        return migrate(from: legacy, into: current)
    }
}

public enum KeychainMigration {
    public enum Read: Equatable {
        /// 新 service 已有条目。
        case current
        /// 新 service 没有、旧 service 有。读到后写回新 service，并删掉旧条目。
        case copyFromLegacy
        case missing
    }

    public static func read(foundInCurrent: Bool, foundInLegacy: Bool) -> Read {
        if foundInCurrent { return .current }
        if foundInLegacy { return .copyFromLegacy }
        return .missing
    }
}

public enum EnvironmentAlias {
    /// 优先规范名。空字符串不算，避免空白的新变量挡住仍在使用的旧变量。
    public static func string(primary: String, legacy: String, environment: [String: String]) -> String? {
        if let value = environment[primary], !value.isEmpty { return value }
        if let value = environment[legacy], !value.isEmpty { return value }
        return nil
    }

    public static func flag(primary: String, legacy: String, environment: [String: String]) -> Bool {
        string(primary: primary, legacy: legacy, environment: environment) == "1"
    }
}

public enum ProductEnvironment {
    public static let uiTest = "SSHBOOKMARKS_UI_TEST"
    public static let uiTestLegacy = "MENUSH_UI_TEST"
    public static let dataDirectory = "SSHBOOKMARKS_DATA_DIR"
    public static let dataDirectoryLegacy = "MENUSH_DATA_DIR"
    public static let appearance = "SSHBOOKMARKS_APPEARANCE"
    public static let appearanceLegacy = "MENUSH_APPEARANCE"
    public static let fakeTerminalLog = "SSHBOOKMARKS_FAKE_TERMINAL_LOG"
    public static let fakeTerminalLogLegacy = "MENUSH_FAKE_TERMINAL_LOG"
    public static let sshDirectory = "SSHBOOKMARKS_SSH_DIR"
    public static let sshDirectoryLegacy = "MENUSH_SSH_DIR"
    public static let screenshotDirectory = "SSHBOOKMARKS_SCREENSHOT_DIR"
    public static let screenshotDirectoryLegacy = "MENUSH_SCREENSHOT_DIR"
    public static let integration = "SSHBOOKMARKS_INTEGRATION"
    public static let integrationLegacy = "MENUSH_INTEGRATION"
    public static let fakeTunnelFailure = "SSHBOOKMARKS_FAKE_TUNNEL_FAILURE"
    public static let fakeTunnelFailureLegacy = "MENUSH_FAKE_TUNNEL_FAILURE"

    public static func sshValue(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        EnvironmentAlias.string(primary: "SSHBOOKMARKS_SSH_\(name)", legacy: "MENUSH_SSH_\(name)", environment: environment)
    }
}

/// iCloud 同步目录从 `MenuSSH` 改到 `SSH Bookmarks`；已有目录时补齐未迁入内容。
public enum ICloudDirectoryMigration {
    public enum Result: Equatable {
        case moved
        case alreadyPresent
        case nothingToMove
    }

    public static func directory(home: String, folderName: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/\(folderName)", isDirectory: true)
    }

    public static func migratedSyncFolderPath(_ path: String?, home: String) -> String? {
        let legacy = directory(home: home, folderName: ProductIdentity.legacyICloudDirectoryName).path
        guard path == legacy else { return path }
        return directory(home: home, folderName: ProductIdentity.iCloudDirectoryName).path
    }

    public static func migrate(
        home: String,
        fileManager: FileManager = .default,
        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws -> Result {
        let legacy = directory(home: home, folderName: ProductIdentity.legacyICloudDirectoryName)
        let current = directory(home: home, folderName: ProductIdentity.iCloudDirectoryName)
        switch try DirectoryMigration.migrate(legacy: legacy, current: current, fileManager: fileManager, move: move, copy: copy) {
        case .moved: return .moved
        case .alreadyPresent: return .alreadyPresent
        case .nothingToMove: return .nothingToMove
        }
    }
}

/// Completion is recorded only after every legacy entry has been accounted for.
private enum DirectoryMigration {
    static func migrate(
        legacy: URL, current: URL, fileManager: FileManager,
        move: (URL, URL) throws -> Void, copy: (URL, URL) throws -> Void
    ) throws -> SupportDirectoryMigration.Result {
        let marker = current.appendingPathComponent(".migration-complete")
        if fileManager.fileExists(atPath: marker.path) { return .alreadyPresent }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            // A coordinated move can succeed before its completion/error is reported.
            // With no source left, an existing destination has nothing further to merge.
            if fileManager.fileExists(atPath: current.path) {
                try Data().write(to: marker, options: .atomic)
                return .alreadyPresent
            }
            return .nothingToMove
        }
        try fileManager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: current.path) {
            try merge(legacy, into: current, fileManager: fileManager, copy: copy)
        } else {
            try move(legacy, current)
        }
        try Data().write(to: marker, options: .atomic)
        return .moved
    }

    private static func merge(
        _ source: URL, into destination: URL, fileManager: FileManager, copy: (URL, URL) throws -> Void
    ) throws {
        for name in try fileManager.contentsOfDirectory(atPath: source.path).sorted() where name != ".migration-complete" {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: to.path) {
                try copy(from, to)
                continue
            }
            if fileManager.contentsEqual(atPath: from.path, andPath: to.path) { continue }
            let sourceValues = try from.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let targetValues = try to.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if sourceValues.isDirectory == true, targetValues.isDirectory == true,
                sourceValues.isSymbolicLink != true, targetValues.isSymbolicLink != true
            {
                try merge(from, into: to, fileManager: fileManager, copy: copy)
                continue
            }
            // Stable names let retries recognize a conflict already copied before a later failure.
            var index = 1
            while true {
                let conflict = destination.appendingPathComponent(name + ".migration-conflict-\(index)")
                if !fileManager.fileExists(atPath: conflict.path) {
                    try copy(from, conflict)
                    break
                }
                if fileManager.contentsEqual(atPath: from.path, andPath: conflict.path) { break }
                index += 1
            }
        }
    }
}
