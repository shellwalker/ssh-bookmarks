import Foundation

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
