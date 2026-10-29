import Foundation

/// 诊断打码用的主机名和用户名：站点本身，加上跳板规格里的每一跳，以及这些跳板若也是已保存站点时的下一条链。
public enum DiagnosticNames {
    public static func collect(from hosts: [SSHHost]) -> (hostnames: [String], usernames: [String]) {
        var hostnames: [String] = []
        var usernames: [String] = []
        var seen = Set<UUID>()

        func addHost(_ name: String) {
            let trimmed = name.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
            if trimmed.count >= 2, !hostnames.contains(trimmed) { hostnames.append(trimmed) }
        }

        func addUser(_ name: String) {
            let trimmed = name.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
            if trimmed.count >= 2, !usernames.contains(trimmed) { usernames.append(trimmed) }
        }

        func walk(_ host: SSHHost) {
            if !seen.insert(host.id).inserted { return }
            addHost(host.hostname)
            addUser(host.username)
            for hop in HostSafeguards.hopHosts(host.jumpHost) {
                addHost(hop)
                let next = hosts.filter { $0.hostname.compare(hop, options: .caseInsensitive) == .orderedSame }
                next.forEach(walk)
            }
            for user in jumpUsers(host.jumpHost) { addUser(user) }
        }

        hosts.forEach(walk)
        return (hostnames, usernames)
    }

    static func jumpUsers(_ jump: String?) -> [String] {
        guard let jump else { return [] }
        return jump.split(separator: ",", omittingEmptySubsequences: false).compactMap { hop in
            let text = hop.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
            guard let at = text.lastIndex(of: "@") else { return nil }
            let user = text[..<at].trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
            return user.isEmpty ? nil : String(user)
        }
    }
}

/// 写入诊断文件和导出包之前的脱敏。密码、令牌和私钥永远去掉。主机名和用户名默认打码。
public struct DiagnosticRedactor: Equatable, Sendable {
    public var redactNames: Bool
    public var hostnames: [String]
    public var usernames: [String]

    public init(redactNames: Bool = true, hostnames: [String] = [], usernames: [String] = []) {
        self.redactNames = redactNames
        self.hostnames = hostnames
        self.usernames = usernames
    }

    public func redact(_ text: String) -> String {
        var result = redactPrivateKeys(text)
        result = redactAssignments(result)
        result = redactPublicKeys(result)
        result = redactHexTokens(result)
        if redactNames {
            result = redactKnownNames(result)
        }
        return result
    }

    private func redactAssignments(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?i)((?:password|passwd|secret)\s*=\s*)\S+"#,
            #"(?i)(--password\s+)\S+"#,
            #"(?i)(sshpass\s+-p\s+)\S+"#,
            #"((?:SSHBOOKMARKS_ASKPASS_TOKEN|MENUSH_ASKPASS_TOKEN)\s*=\s*)\S+"#,
            #"(SSH_ASKPASS\s*=\s*)\S+"#,
        ]
        for pattern in patterns {
            result = replacing(result, pattern: pattern, template: "$1[redacted]")
        }
        return result
    }

    private func redactHexTokens(_ text: String) -> String {
        replacing(text, pattern: #"\b[0-9a-fA-F]{64}\b"#, template: "[token]")
    }

    private func redactPublicKeys(_ text: String) -> String {
        let types = "ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521"
        let sk = "sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com"
        return replacing(text, pattern: "(?:\(types)|\(sk))\\s+\\S+", template: "[key]")
    }

    private func redactPrivateKeys(_ text: String) -> String {
        replacing(
            text,
            pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----",
            template: "[private-key]"
        )
    }

    private func redactKnownNames(_ text: String) -> String {
        var result = text
        let names = (hostnames + usernames).filter { $0.count >= 2 }.sorted { $0.count > $1.count }
        for name in names {
            result = result.replacingOccurrences(of: name, with: nameIsUser(name) ? "user" : "host")
        }
        return result
    }

    private func nameIsUser(_ name: String) -> Bool {
        usernames.contains(name) && !hostnames.contains(name)
    }

    private func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
