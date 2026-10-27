import Foundation

/// ~/.ssh/config 中的一个 Host 条目（只保留导入需要的字段）。
public struct SSHConfigImportPlan: Equatable, Sendable {
    public var hosts: [SSHHost]
    public var skippedDuplicates: Int

    public init(hosts: [SSHHost], skippedDuplicates: Int) {
        self.hosts = hosts
        self.skippedDuplicates = skippedDuplicates
    }
}

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
/// - `Include` 按 OpenSSH：相对路径相对 `~/.ssh`，支持 `~` 和最后一段的 `*` / `?`。
/// - 同一关键字以第一次出现为准（与 ssh 语义一致）。
public enum SSHConfigParser {
    public static let maxIncludeDepth = 8

    public static func parse(_ text: String) -> [SSHConfigEntry] {
        parse(text, homeDirectory: "", readFile: nil, listDirectory: nil)
    }

    /// `readFile` 收到绝对路径。`listDirectory` 用于展开通配。两者缺一则跳过 Include，不报错。
    public static func parse(
        _ text: String,
        homeDirectory: String,
        readFile: ((String) -> String?)?,
        listDirectory: ((String) -> [String])?
    ) -> [SSHConfigEntry] {
        let state = ParseState()
        state.consume(
            text: text,
            origin: nil,
            homeDirectory: homeDirectory,
            readFile: readFile,
            listDirectory: listDirectory
        )
        state.flush()
        return state.entries
    }

    /// 已有 hostname（不区分大小写）整条跳过，不覆盖。同一文件里的重复别名也只保留第一条。
    public static func planImport(
        entries: [SSHConfigEntry], existingHostnames: Set<String>, groupID: UUID? = nil
    ) -> SSHConfigImportPlan {
        var seen = Set(existingHostnames.map { $0.lowercased() })
        var hosts: [SSHHost] = []
        var skipped = 0
        for host in makeHosts(from: entries, groupID: groupID) {
            let key = host.hostname.lowercased()
            if seen.contains(key) {
                skipped += 1
            } else {
                seen.insert(key)
                hosts.append(host)
            }
        }
        return SSHConfigImportPlan(hosts: hosts, skippedDuplicates: skipped)
    }

    /// hostname 仍用别名，这样未导入的 config 选项继续由 ssh 自己应用。
    /// User / Port / IdentityFile / ProxyJump 写入对应字段；HostName 只留在备注里。
    public static func makeHosts(from entries: [SSHConfigEntry], groupID: UUID? = nil) -> [SSHHost] {
        entries.map { entry in
            let user = entry.user.flatMap { SSHCommandBuilder.isValidUsername($0) ? $0 : nil } ?? ""
            let port = entry.port.flatMap { (1...65535).contains($0) ? $0 : nil }
            let identity = entry.identityFile.flatMap { SSHCommandBuilder.isValidPath($0) ? $0 : nil }
            let jump = entry.proxyJump.flatMap { SSHCommandBuilder.isValidJumpSpec($0) ? $0 : nil }
            let notes = entry.hostName.map { "HostName \($0)" } ?? ""
            return SSHHost(
                label: entry.alias,
                hostname: entry.alias,
                port: port,
                username: user,
                groupID: groupID,
                tags: ["ssh-config"],
                authMethod: identity == nil ? .automatic : .publicKey,
                identityFile: identity,
                jumpHost: jump,
                notes: notes
            )
        }
    }

    /// 把一条 Include token 解析成绝对路径。通配只作用在最后一段。
    public static func resolveInclude(token: String, homeDirectory: String, listDirectory: (String) -> [String]) -> [String] {
        let raw = SSHConfigParserSplit.unquote(token)
        guard !raw.isEmpty else { return [] }
        var path = raw
        if path == "~" {
            path = homeDirectory
        } else if path.hasPrefix("~/") {
            path = homeDirectory + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            guard !homeDirectory.isEmpty else { return [] }
            path = homeDirectory + "/.ssh/" + path
        }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard name.contains("*") || name.contains("?") else { return [path] }
        let directory = url.deletingLastPathComponent().path
        return
            listDirectory(directory)
            .filter { globMatch(pattern: name, name: $0) }
            .sorted()
            .map { directory + "/" + $0 }
    }

    /// `*` / `?`。星号不匹配开头的点，除非模式自己以点开头。
    static func globMatch(pattern: String, name: String) -> Bool {
        if name.hasPrefix("."), !pattern.hasPrefix(".") { return false }
        return glob(pattern: Array(pattern), name: Array(name))
    }

    private static func glob(pattern: [Character], name: [Character]) -> Bool {
        var pi = 0
        var ni = 0
        var star = -1
        var mark = -1
        while ni < name.count {
            if pi < pattern.count, (pattern[pi] == name[ni] || pattern[pi] == "?") {
                pi += 1
                ni += 1
            } else if pi < pattern.count, pattern[pi] == "*" {
                star = pi
                mark = ni
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ni = mark
            } else {
                return false
            }
        }
        while pi < pattern.count, pattern[pi] == "*" { pi += 1 }
        return pi == pattern.count
    }

}

private final class ParseState {
    var entries: [SSHConfigEntry] = []
    var current: [SSHConfigEntry] = []
    var inMatch = false
    var visiting: Set<String> = []
    var depth = 0

    func flush() {
        entries.append(contentsOf: current)
        current = []
    }

    func consume(
        text: String,
        origin: String?,
        homeDirectory: String,
        readFile: ((String) -> String?)?,
        listDirectory: ((String) -> [String])?
    ) {
        if let origin {
            if visiting.contains(origin) || depth >= SSHConfigParser.maxIncludeDepth { return }
            visiting.insert(origin)
        }
        depth += 1
        defer {
            depth -= 1
            if let origin { visiting.remove(origin) }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (keyword, value) = SSHConfigParserSplit.split(line)
            guard !keyword.isEmpty else { continue }

            switch keyword {
            case "host":
                flush()
                inMatch = false
                let patterns = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                current =
                    patterns
                    .filter { pattern in !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") }
                    .map { SSHConfigEntry(alias: SSHConfigParserSplit.unquote($0)) }
            case "match":
                flush()
                inMatch = true
            case "include":
                guard !inMatch, let readFile, let listDirectory else { continue }
                let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                for token in tokens {
                    let paths = SSHConfigParser.resolveInclude(token: token, homeDirectory: homeDirectory, listDirectory: listDirectory)
                    for path in paths {
                        guard let body = readFile(path) else { continue }
                        consume(
                            text: body,
                            origin: path,
                            homeDirectory: homeDirectory,
                            readFile: readFile,
                            listDirectory: listDirectory
                        )
                    }
                }
            default:
                guard !inMatch, !current.isEmpty else { continue }
                let cleaned = SSHConfigParserSplit.unquote(value)
                for index in current.indices {
                    switch keyword {
                    case "hostname": if current[index].hostName == nil { current[index].hostName = cleaned }
                    case "user": if current[index].user == nil { current[index].user = cleaned }
                    case "port": if current[index].port == nil { current[index].port = Int(cleaned) }
                    case "identityfile": if current[index].identityFile == nil { current[index].identityFile = cleaned }
                    case "proxyjump": if current[index].proxyJump == nil { current[index].proxyJump = cleaned }
                    default: break
                    }
                }
            }
        }
    }
}

private enum SSHConfigParserSplit {
    static func split(_ line: String) -> (String, String) {
        guard let sepIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line.lowercased(), "")
        }
        let key = String(line[..<sepIndex]).lowercased()
        var rest = line[sepIndex...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        return (key, String(rest).trimmingCharacters(in: .whitespaces))
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
