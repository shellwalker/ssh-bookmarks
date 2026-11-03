import Foundation

/// 同步文件里的一条删除记录。过期前，另一台机器上的旧副本不能把站点复活。
public struct SyncTombstone: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case host
        case group
    }

    public var id: UUID
    public var kind: Kind
    public var deletedAt: Date
    public var deviceId: String?

    public init(id: UUID, kind: Kind, deletedAt: Date, deviceId: String? = nil) {
        self.id = id
        self.kind = kind
        self.deletedAt = deletedAt
        self.deviceId = deviceId
    }
}

public enum SyncFormatError: Error, Equatable, Sendable {
    case newerSchema(Int)
    case unreadablePrimary
    case secretKey(String)
}

/// 便携同步文件。只有站点、分组、端口转发和墓碑，没有任何秘密字段。
public struct SyncDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3
    public static let fileName = "menu-ssh-sync.json"

    public var schemaVersion: Int
    public var deviceId: String
    public var groups: [HostGroup]
    public var hosts: [SSHHost]
    public var tombstones: [SyncTombstone]

    public init(
        schemaVersion: Int = SyncDocument.currentSchemaVersion,
        deviceId: String,
        groups: [HostGroup] = [],
        hosts: [SSHHost] = [],
        tombstones: [SyncTombstone] = []
    ) {
        self.schemaVersion = schemaVersion
        self.deviceId = deviceId
        self.groups = groups
        self.hosts = hosts
        self.tombstones = tombstones
    }

    public init(library: HostLibrary, deviceId: String) {
        self.init(deviceId: deviceId, groups: library.groups, hosts: library.hosts, tombstones: library.tombstones)
    }

    public func makeLibrary() -> HostLibrary {
        HostLibrary(
            schemaVersion: HostLibrary.currentSchemaVersion,
            groups: groups,
            hosts: hosts,
            tombstones: tombstones
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, deviceId, groups, hosts, tombstones
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if version > Self.currentSchemaVersion {
            throw SyncFormatError.newerSchema(version)
        }
        schemaVersion = version
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        groups = try c.decodeIfPresent([HostGroup].self, forKey: .groups) ?? []
        hosts = try c.decodeIfPresent([SSHHost].self, forKey: .hosts) ?? []
        tombstones = try c.decodeIfPresent([SyncTombstone].self, forKey: .tombstones) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // 写出时升到当前版本，旧客户端会因 newerSchema 拒绝覆盖，避免丢掉新字段。
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(groups, forKey: .groups)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(tombstones, forKey: .tombstones)
    }
}

public enum SyncPaths {
    /// `…/CloudDocs/SSH Bookmarks/menu-ssh-sync.json`。旧的 `MenuSSH` 目录在首次启动时迁过来。
    public static func iCloudDirectory(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/\(ProductIdentity.iCloudDirectoryName)",
                isDirectory: true
            )
    }
}

/// 编码结果里不允许出现的键。值里偶然出现“password”这个词不算（例如备注），键才算。
public enum SyncSecretScan {
    public static let forbiddenKeys: Set<String> = [
        "password", "passphrase", "secret", "privatekey", "token", "askpasstoken", "ksecvaluedata",
    ]

    public static func keys(in value: Any) -> Set<String> {
        var found = Set<String>()
        func walk(_ item: Any) {
            if let dict = item as? [String: Any] {
                for (key, child) in dict {
                    found.insert(key.lowercased())
                    walk(child)
                }
            } else if let list = item as? [Any] {
                list.forEach(walk)
            }
        }
        walk(value)
        return found
    }
}
