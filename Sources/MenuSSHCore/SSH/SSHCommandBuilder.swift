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

    /// 完整 argv，第一个元素是 ssh 可执行文件路径。
    public func argv(for host: SSHHost) throws -> [String] {
        [sshPath] + (try arguments(for: host))
    }

    /// ssh 之后的参数。
    public func arguments(for host: SSHHost) throws -> [String] {
        var args: [String] = []

        let hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        guard !hostname.isEmpty else { throw SSHCommandError.emptyHostname }
        guard Self.isValidHostname(hostname) else { throw SSHCommandError.invalidHostname(hostname) }

        let username = host.username.trimmingCharacters(in: .whitespaces)
        if !username.isEmpty {
            guard Self.isValidUsername(username) else { throw SSHCommandError.invalidUsername(username) }
            args += ["-l", username]
        }

        if let port = host.port {
            guard (1...65535).contains(port) else { throw SSHCommandError.invalidPort(port) }
            args += ["-p", String(port)]
        }

        if host.authMethod == .publicKey, let identity = host.identityFile?.trimmingCharacters(in: .whitespaces), !identity.isEmpty {
            guard !identity.containsControlCharacters, !identity.hasPrefix("-") else {
                throw SSHCommandError.invalidIdentityFile(identity)
            }
            args += ["-i", expandTilde(identity)]
            // 只用指定的密钥，避免 agent 里的大量密钥触发 “Too many authentication failures”。
            args += ["-o", "IdentitiesOnly=yes"]
        }

        if let jump = host.jumpHost?.trimmingCharacters(in: .whitespaces), !jump.isEmpty {
            guard Self.isValidJumpSpec(jump) else { throw SSHCommandError.invalidJumpHost(jump) }
            args += ["-J", jump]
        }

        for forward in host.portForwards {
            args += try forwardArguments(forward)
        }

        for option in host.extraOptions {
            guard Self.isValidOptionKey(option.key), !option.value.containsControlCharacters else {
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

    // MARK: - Validation

    static func isValidHostname(_ s: String) -> Bool {
        guard !s.hasPrefix("-"), !s.containsControlCharacters else { return false }
        // 主机名、IPv4、IPv6（可带 [] 和 %zone）、ssh_config 别名常见字符。
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%[]"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isValidUsername(_ s: String) -> Bool {
        guard !s.hasPrefix("-"), !s.containsControlCharacters else { return false }
        return !s.unicodeScalars.contains { CharacterSet.whitespaces.contains($0) }
    }

    static func isValidJumpSpec(_ s: String) -> Bool {
        guard !s.containsControlCharacters else { return false }
        let hops = s.split(separator: ",", omittingEmptySubsequences: false)
        guard !hops.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%[]@"))
        return hops.allSatisfy { hop in
            !hop.isEmpty && !hop.hasPrefix("-") && hop.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    static func isValidOptionKey(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) && $0.isASCII }
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
