import Foundation

/// 认证方式。密码 / 私钥口令本身不进 JSON，只存在钥匙串（Keychain）中。
public enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 交给 ssh 自己处理（ssh-agent、~/.ssh/config、默认密钥）。
    case automatic
    /// 指定私钥文件（IdentityFile）。
    case publicKey
    /// 密码登录（M3：通过 SSH_ASKPASS 从钥匙串读取）。
    case password

    public var id: String { rawValue }
}

/// 端口转发规则（对应 ssh -L / -R / -D）。
public struct PortForward: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case local
        case remote
        case dynamic
    }

    public var id: UUID
    public var kind: Kind
    /// 可选的绑定地址，例如 127.0.0.1。
    public var bindAddress: String?
    public var listenPort: Int
    /// dynamic 类型不需要目标地址。
    public var destinationHost: String?
    public var destinationPort: Int?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        bindAddress: String? = nil,
        listenPort: Int,
        destinationHost: String? = nil,
        destinationPort: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }
}

/// 一个 SSH 站点。命名为 SSHHost 以避免与 Foundation.Host 冲突。
public struct SSHHost: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// 显示名称，例如 “生产 API”。
    public var label: String
    /// 主机名 / IP，或 ~/.ssh/config 里的 Host 别名。
    public var hostname: String
    /// nil 表示不传 -p，交给 ssh_config / 默认 22。
    public var port: Int?
    /// 空字符串表示不传 -l，交给 ssh_config / 当前用户。
    public var username: String
    public var groupID: UUID?
    public var tags: [String]
    public var authMethod: AuthMethod
    /// 私钥路径，支持 ~ 开头。
    public var identityFile: String?
    /// ProxyJump，格式 [user@]host[:port][,...]
    public var jumpHost: String?
    public var portForwards: [PortForward]
    /// 额外的 `-o Key=Value` 选项。
    public var extraOptions: [SSHOption]
    /// 显式打开时追加 `-o ForwardAgent=yes`。
    public var forwardAgent: Bool
    /// 连接后在终端里换行再输入的一行命令。空字符串表示不追加。
    public var startupCommand: String
    public var isFavorite: Bool
    public var notes: String
    public var lastConnectedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// 最后改这条站点的设备。不参与认证，时间戳相同时用于打破平局。
    public var updatedByDeviceId: String?

    public init(
        id: UUID = UUID(),
        label: String,
        hostname: String,
        port: Int? = nil,
        username: String = "",
        groupID: UUID? = nil,
        tags: [String] = [],
        authMethod: AuthMethod = .automatic,
        identityFile: String? = nil,
        jumpHost: String? = nil,
        portForwards: [PortForward] = [],
        extraOptions: [SSHOption] = [],
        forwardAgent: Bool = false,
        startupCommand: String = "",
        isFavorite: Bool = false,
        notes: String = "",
        lastConnectedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedByDeviceId: String? = nil
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.groupID = groupID
        self.tags = tags
        self.authMethod = authMethod
        self.identityFile = identityFile
        self.jumpHost = jumpHost
        self.portForwards = portForwards
        self.extraOptions = extraOptions
        self.forwardAgent = forwardAgent
        self.startupCommand = startupCommand
        self.isFavorite = isFavorite
        self.notes = notes
        self.lastConnectedAt = lastConnectedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedByDeviceId = updatedByDeviceId
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, hostname, port, username, groupID, tags, authMethod, identityFile
        case jumpHost, portForwards, extraOptions, forwardAgent, startupCommand, isFavorite, notes
        case lastConnectedAt, createdAt, updatedAt, updatedByDeviceId
    }

    /// 宽松解码：新增字段缺失时使用默认值，保证旧版本 JSON 可读。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        hostname = try c.decode(String.self, forKey: .hostname)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? hostname
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .automatic
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost)
        portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
        extraOptions = try c.decodeIfPresent([SSHOption].self, forKey: .extraOptions) ?? []
        forwardAgent = try c.decodeIfPresent(Bool.self, forKey: .forwardAgent) ?? false
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand) ?? ""
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        updatedByDeviceId = try c.decodeIfPresent(String.self, forKey: .updatedByDeviceId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(hostname, forKey: .hostname)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encode(tags, forKey: .tags)
        try c.encode(authMethod, forKey: .authMethod)
        try c.encodeIfPresent(identityFile, forKey: .identityFile)
        try c.encodeIfPresent(jumpHost, forKey: .jumpHost)
        try c.encode(portForwards, forKey: .portForwards)
        try c.encode(extraOptions, forKey: .extraOptions)
        try c.encode(forwardAgent, forKey: .forwardAgent)
        try c.encode(startupCommand, forKey: .startupCommand)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(updatedByDeviceId, forKey: .updatedByDeviceId)
    }

    /// 同步时算“内容变了”的字段。连接时间、创建时间、设备 id 不算。
    public func hasSameSyncContent(as other: SSHHost) -> Bool {
        var a = self
        var b = other
        a.lastConnectedAt = nil
        b.lastConnectedAt = nil
        a.createdAt = .distantPast
        b.createdAt = .distantPast
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        a.updatedByDeviceId = nil
        b.updatedByDeviceId = nil
        return a == b
    }

    /// 列表中显示的副标题（Termius 风格 `user@host:port`），例如 `deploy@10.0.0.15:2201`。
    /// 未填写的部分省略（由 ~/.ssh/config 决定）；IPv6 地址带端口时加方括号。
    public var subtitle: String {
        var s = ""
        if !username.isEmpty { s += "\(username)@" }
        if let port {
            s += hostname.contains(":") ? "[\(hostname)]:\(port)" : "\(hostname):\(port)"
        } else {
            s += hostname
        }
        return s
    }
}

/// `-o Key=Value` 形式的 ssh 选项。
public struct SSHOption: Codable, Hashable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
