import Foundation

public enum SSHCommandError: Error, Equatable, Sendable {
    case emptyHostname
    case invalidHostname(String)
    case invalidUsername(String)
    case invalidPort(Int)
    case invalidIdentityFile(String)
    case invalidJumpHost(String)
    case invalidOption(String)
    case invalidPortForward(String)
    case invalidStartupCommand(String)
    case invalidSSHPath(String)

    /// 出错的字段，便于编辑器把错误显示在对应输入框旁边。
    public var field: HostField {
        switch self {
        case .emptyHostname, .invalidHostname: return .hostname
        case .invalidUsername: return .username
        case .invalidPort: return .port
        case .invalidIdentityFile: return .identityFile
        case .invalidJumpHost: return .jumpHost
        case .invalidOption: return .extraOptions
        case .invalidPortForward: return .portForwards
        case .invalidStartupCommand: return .startupCommand
        case .invalidSSHPath: return .sshPath
        }
    }
}

/// 站点中可被校验的字段。
public enum HostField: String, Sendable, CaseIterable {
    case hostname, username, port, identityFile, jumpHost, extraOptions, portForwards, startupCommand, sshPath
}

/// 把 SSHHost 转成 ssh 的 argv（不经过 shell）。
///
/// 安全原则：
/// 1. 只生成 argv 数组；需要拼成命令行时由 ShellQuoting 统一引用。
/// 2. 所有字段拒绝控制字符（换行可在终端里“回车执行”第二条命令）。
/// 3. hostname / username / jumpHost 不允许以 `-` 开头，防止被 ssh 当作选项（如 `-oProxyCommand=...`）。
/// 4. 目标主机放在 `--` 之后。
public struct SSHCommandBuilder: Sendable {
    public var sshPath: String
    public var homeDirectory: String

    public init(sshPath: String = "/usr/bin/ssh", homeDirectory: String = NSHomeDirectory()) {
        self.sshPath = sshPath
        self.homeDirectory = homeDirectory
    }

    /// 完整 argv，第一个元素是 ssh 可执行文件路径。同时校验连接后命令。
    public func argv(for host: SSHHost) throws -> [String] {
        _ = try Self.startupCommand(host.startupCommand)
        return [sshPath] + (try arguments(for: host))
    }

    /// 空字符串表示不追加。非空必须是单行，且不能含控制字符，避免打断 AppleScript / shell。
    public static func startupCommand(_ raw: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
        if trimmed.isEmpty { return nil }
        guard trimmed.utf8.count <= 500, !trimmed.containsControlCharacters else {
            throw SSHCommandError.invalidStartupCommand(raw)
        }
        return trimmed
    }

    /// ssh 之后的参数。
    public func arguments(for host: SSHHost) throws -> [String] {
        guard Self.isValidSSHPath(sshPath) else { throw SSHCommandError.invalidSSHPath(sshPath) }
        var args: [String] = []

        let hostname = host.hostname.trimmingCharacters(in: Self.plainSpaces)
        guard !hostname.isEmpty else { throw SSHCommandError.emptyHostname }
        guard Self.isValidHostname(hostname) else { throw SSHCommandError.invalidHostname(hostname) }

        let username = host.username.trimmingCharacters(in: Self.plainSpaces)
        if !username.isEmpty {
            guard Self.isValidUsername(username) else { throw SSHCommandError.invalidUsername(username) }
            args += ["-l", username]
        }

        if let port = host.port {
            guard (1...65535).contains(port) else { throw SSHCommandError.invalidPort(port) }
            args += ["-p", String(port)]
        }

        if host.authMethod == .publicKey, let identity = host.identityFile?.trimmingCharacters(in: Self.plainSpaces), !identity.isEmpty {
            guard Self.isValidPath(identity) else {
                throw SSHCommandError.invalidIdentityFile(identity)
            }
            args += ["-i", expandTilde(identity)]
            // 只用指定的密钥，避免 agent 里的大量密钥触发 “Too many authentication failures”。
            args += ["-o", "IdentitiesOnly=yes"]
        }

        if let jump = host.jumpHost?.trimmingCharacters(in: Self.plainSpaces), !jump.isEmpty {
            guard Self.isValidJumpSpec(jump) else { throw SSHCommandError.invalidJumpHost(jump) }
            args += ["-J", jump]
        }

        for forward in host.portForwards {
            args += try forwardArguments(forward)
        }

        if host.forwardAgent {
            // 放在用户额外选项之前：OpenSSH 采用第一次出现的值，开关优先。
            args += ["-o", "ForwardAgent=yes"]
        }

        for option in host.extraOptions {
            guard Self.isValidOptionKey(option.key), Self.isValidOptionValue(option.value) else {
                throw SSHCommandError.invalidOption(option.key)
            }
            args += ["-o", "\(option.key)=\(option.value)"]
        }

        args += ["--", hostname]
        return args
    }

    /// 给 Terminal / iTerm2 / Ghostty “输入”用的命令行。
    public func commandLine(for host: SSHHost) throws -> String {
        ShellQuoting.join(try argv(for: host))
    }

    // MARK: - Validation（白名单）

    /// 只去掉首尾的普通空格；不用 `.whitespaces`，否则零宽字符等会被悄悄剥掉而绕过校验。
    static let plainSpaces = CharacterSet(charactersIn: " ")

    private static func ascii(_ chars: String) -> Set<Unicode.Scalar> {
        Set(chars.unicodeScalars)
    }

    private static let asciiLetters = ascii("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let asciiAlphanumerics = asciiLetters.union(ascii("0123456789"))
    /// 主机名 / IPv4 / IPv6（含 %zone）/ ssh_config 别名。只允许 ASCII：国际化域名请用 punycode（xn--）。
    private static let hostnameScalars = asciiAlphanumerics.union(ascii(".-_:%"))
    /// 用户名：POSIX 可移植用户名字符，外加 `@`（AD / 邮箱式账号）。
    private static let usernameScalars = asciiAlphanumerics.union(ascii("._-@"))

    /// 这些选项会在本机执行命令或加载代码，不允许通过站点的“额外选项”设置（需要的话请写进 ~/.ssh/config）。
    static let blockedOptionKeys: Set<String> = [
        "proxycommand", "localcommand", "permitlocalcommand", "knownhostscommand",
        "include", "match", "pkcs11provider", "securitykeyprovider",
    ]

    static func isValidHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 253, !s.hasPrefix("-") else { return false }
        return s.unicodeScalars.allSatisfy { hostnameScalars.contains($0) }
    }

    static func isValidUsername(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 128, !s.hasPrefix("-") else { return false }
        return s.unicodeScalars.allSatisfy { usernameScalars.contains($0) }
    }

    static func isValidPort(_ s: Substring) -> Bool {
        guard !s.isEmpty, s.count <= 5, s.allSatisfy(\.isASCII), let p = Int(s) else { return false }
        return (1...65535).contains(p)
    }

    /// `-J` 规格：逗号分隔的 `[user@]host[:port]`，IPv6 需写成 `[addr]:port`。
    static func isValidJumpSpec(_ s: String) -> Bool {
        let hops = s.split(separator: ",", omittingEmptySubsequences: false)
        guard !hops.isEmpty else { return false }
        return hops.allSatisfy(isValidJumpHop)
    }

    private static func isValidJumpHop(_ hop: Substring) -> Bool {
        var rest = hop
        if let at = rest.lastIndex(of: "@") {
            guard isValidUsername(String(rest[..<at])) else { return false }
            rest = rest[rest.index(after: at)...]
        }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return false }
            let addr = rest[rest.index(after: rest.startIndex)..<close]
            guard addr.contains(":"), isValidHostname(String(addr)) else { return false }
            let tail = rest[rest.index(after: close)...]
            if tail.isEmpty { return true }
            guard tail.hasPrefix(":") else { return false }
            return isValidPort(tail.dropFirst())
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return isValidHostname(String(parts[0]))
        case 2: return isValidHostname(String(parts[0])) && isValidPort(parts[1])
        default: return false
        }
    }

    static func isValidOptionKey(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { asciiLetters.contains($0) }
            && !blockedOptionKeys.contains(s.lowercased())
    }

    static func isValidOptionValue(_ s: String) -> Bool {
        !s.isEmpty && !s.containsControlCharacters
    }

    /// 文件路径（私钥）：允许空格和 Unicode，但不允许控制 / 格式字符（含零宽、双向覆盖）和前导 `-`。
    static func isValidPath(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && !s.containsControlCharacters
    }

    /// ssh 可执行文件必须是绝对路径。
    static func isValidSSHPath(_ s: String) -> Bool {
        s.hasPrefix("/") && !s.containsControlCharacters
    }

    private func forwardArguments(_ f: PortForward) throws -> [String] {
        func validPort(_ p: Int?) -> Bool { p.map { (1...65535).contains($0) } ?? false }
        func validAddr(_ a: String?) -> Bool { a.map { !$0.isEmpty && Self.isValidHostname($0) } ?? true }

        guard validPort(f.listenPort), validAddr(f.bindAddress) else {
            throw SSHCommandError.invalidPortForward("listen \(f.listenPort)")
        }
        let bind = f.bindAddress.map { "\($0):" } ?? ""
        switch f.kind {
        case .dynamic:
            return ["-D", "\(bind)\(f.listenPort)"]
        case .local, .remote:
            guard let dh = f.destinationHost, !dh.isEmpty, Self.isValidHostname(dh), validPort(f.destinationPort) else {
                throw SSHCommandError.invalidPortForward("destination")
            }
            let flag = f.kind == .local ? "-L" : "-R"
            return [flag, "\(bind)\(f.listenPort):\(dh):\(f.destinationPort!)"]
        }
    }

    private func expandTilde(_ path: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory + String(path.dropFirst(1)) }
        return path
    }
}
