import Foundation

/// hosts.json 的读写。只负责文件 I/O，不含 UI 状态。
public struct HostFileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 默认位置：~/Library/Application Support/SSH Bookmarks/hosts.json
    /// 升级时先把旧的 MenuSSH 目录搬过来，再创建这一层。见 SupportDirectoryMigration。
    public static func defaultFileURL(appSupportDirectory: URL) -> URL {
        ProductPaths.supportDirectory(applicationSupport: appSupportDirectory)
            .appendingPathComponent("hosts.json", isDirectory: false)
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 文件不存在时返回空库；解析失败时把坏文件改名备份后抛错，避免覆盖用户数据。
    public func load() throws -> HostLibrary {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        do {
            return try Self.makeDecoder().decode(HostLibrary.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
            try? fm.copyItem(at: fileURL, to: backup)
            throw error
        }
    }

    /// 原子写入，并把文件权限设为 0600（站点信息也算敏感数据）。
    public func save(_ library: HostLibrary) throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try Self.makeEncoder().encode(library)
        try data.write(to: fileURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
