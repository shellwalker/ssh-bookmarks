import Foundation

/// ~/.ssh/config 中的一个 Host 条目（只保留导入需要的字段）。
public struct SSHConfigEntry: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?

    public init(
        alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil,
        identityFile: String? = nil, proxyJump: String? = nil
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }
}

/// 极简 ssh_config 解析器，用于“导入站点”。
///
/// - 只处理 `Host` 块；`Match` 块整体跳过。
/// - 带通配符（`*`、`?`、`!`）的模式不导入。
/// - 一行多个别名（`Host a b`）会生成多个条目。
/// - `Include` 暂不展开（M3 再做）。
/// - 同一关键字以第一次出现为准（与 ssh 语义一致）。
public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var current: [SSHConfigEntry] = []
        var inMatch = false

        func flush() {
            entries.append(contentsOf: current)
            current = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let (keyword, value) = splitKeyword(line)
            guard !keyword.isEmpty else { continue }

            switch keyword {
            case "host":
                flush()
                inMatch = false
                let patterns = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                current =
                    patterns
                    .filter { p in !p.contains("*") && !p.contains("?") && !p.hasPrefix("!") }
                    .map { SSHConfigEntry(alias: unquote($0)) }
            case "match":
                flush()
                inMatch = true
            default:
                guard !inMatch, !current.isEmpty else { continue }
                let v = unquote(value)
                for i in current.indices {
                    switch keyword {
                    case "hostname": if current[i].hostName == nil { current[i].hostName = v }
                    case "user": if current[i].user == nil { current[i].user = v }
                    case "port": if current[i].port == nil { current[i].port = Int(v) }
                    case "identityfile": if current[i].identityFile == nil { current[i].identityFile = v }
                    case "proxyjump": if current[i].proxyJump == nil { current[i].proxyJump = v }
                    default: break
                    }
                }
            }
        }
        flush()
        return entries
    }

    /// 转为 SSHHost。hostname 使用别名，这样连接时仍会应用 ~/.ssh/config 中的其他选项；
    /// 其余字段只作展示用途，保持 nil/空，交给 ssh_config 决定。
    public static func makeHosts(from entries: [SSHConfigEntry], groupID: UUID? = nil) -> [SSHHost] {
        entries.map { e in
            SSHHost(
                label: e.alias,
                hostname: e.alias,
                groupID: groupID,
                tags: ["ssh-config"],
                notes: [e.user.map { "User \($0)" }, e.hostName.map { "HostName \($0)" }, e.port.map { "Port \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
        }
    }

    /// 支持 `Key Value` 和 `Key=Value` 两种写法。
    private static func splitKeyword(_ line: String) -> (String, String) {
        guard let sepIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line.lowercased(), "")
        }
        let key = String(line[..<sepIndex]).lowercased()
        var rest = line[sepIndex...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        return (key, String(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
