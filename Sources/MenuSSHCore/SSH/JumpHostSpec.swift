import Foundation

/// 把已有站点收成一条 OpenSSH `-J` 跳：`[user@]host[:port]`。IPv6 加方括号。
public enum JumpHostSpec {
    public static func specification(for host: SSHHost) -> String? {
        let hostname = host.hostname.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
        guard SSHCommandBuilder.isValidHostname(hostname) else { return nil }
        let user = host.username.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
        if !user.isEmpty, !SSHCommandBuilder.isValidUsername(user) { return nil }
        if let port = host.port, !(1...65535).contains(port) { return nil }

        let hostPart = hostname.contains(":") ? "[\(hostname)]" : hostname
        var spec = user.isEmpty ? hostPart : "\(user)@\(hostPart)"
        if let port = host.port { spec += ":\(port)" }
        guard SSHCommandBuilder.isValidJumpSpec(spec) else { return nil }
        return spec
    }
}
