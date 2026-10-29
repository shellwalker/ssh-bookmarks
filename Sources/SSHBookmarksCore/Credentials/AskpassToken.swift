#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

/// 一次连接对应一个令牌。用过或过期后就不能再换密码。
public struct AskpassTokenStore: Equatable, Sendable {
    public static let environmentVariable = "SSHBOOKMARKS_ASKPASS_TOKEN"
    /// 旧构建写过这个名字。读令牌时两个都认，启动脚本只写新名字。
    public static let legacyEnvironmentVariable = "MENUSH_ASKPASS_TOKEN"

    public static func token(in environment: [String: String]) -> String? {
        EnvironmentAlias.string(primary: environmentVariable, legacy: legacyEnvironmentVariable, environment: environment)
    }

    public static let defaultTTL: TimeInterval = 60

    public private(set) var records: [AskpassTokenRecord]

    public init(records: [AskpassTokenRecord] = []) {
        self.records = records
    }

    public mutating func issue(hostID: UUID, now: Date, ttl: TimeInterval = AskpassTokenStore.defaultTTL, token: String) -> String {
        records.removeAll { $0.expiresAt <= now }
        records.removeAll { $0.token == token }
        records.append(AskpassTokenRecord(token: token, hostID: hostID, expiresAt: now.addingTimeInterval(ttl)))
        return token
    }

    /// 成功返回 host id，并立刻作废。过期、未知或第二次使用都返回 nil。
    public mutating func redeem(_ token: String, now: Date) -> UUID? {
        records.removeAll { $0.expiresAt <= now }
        guard let index = records.firstIndex(where: { $0.token == token }) else { return nil }
        let record = records.remove(at: index)
        guard record.expiresAt > now else { return nil }
        return record.hostID
    }
}

public struct AskpassTokenRecord: Codable, Equatable, Sendable {
    public var token: String
    public var hostID: UUID
    public var expiresAt: Date

    public init(token: String, hostID: UUID, expiresAt: Date) {
        self.token = token
        self.hostID = hostID
        self.expiresAt = expiresAt
    }
}

public enum AskpassRandom {
    /// 32 字节十六进制。读不到系统随机源时退回两个 UUID。
    public static func hex(count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let fd = open("/dev/urandom", O_RDONLY)
        if fd >= 0 {
            let readCount = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, count) }
            close(fd)
            if readCount == count {
                return bytes.map { String(format: "%02x", $0) }.joined()
            }
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

/// 磁盘上的令牌表。权限 0600。赎回会写回，所以第二次调用失败。
public enum AskpassTokenFile {
    public static func issue(hostID: UUID, fileURL: URL, now: Date, ttl: TimeInterval = AskpassTokenStore.defaultTTL, token: String? = nil)
        throws -> String
    {
        var store = load(fileURL)
        let value = token ?? AskpassRandom.hex()
        _ = store.issue(hostID: hostID, now: now, ttl: ttl, token: value)
        try save(store, fileURL: fileURL)
        return value
    }

    public static func redeem(token: String, fileURL: URL, now: Date) throws -> UUID? {
        var store = load(fileURL)
        let hostID = store.redeem(token, now: now)
        try save(store, fileURL: fileURL)
        return hostID
    }

    static func load(_ fileURL: URL) -> AskpassTokenStore {
        guard let data = try? Data(contentsOf: fileURL),
            let records = try? HostFileStore.makeDecoder().decode([AskpassTokenRecord].self, from: data)
        else { return AskpassTokenStore() }
        return AskpassTokenStore(records: records)
    }

    static func save(_ store: AskpassTokenStore, fileURL: URL) throws {
        let data = try HostFileStore.makeEncoder().encode(store.records)
        try AtomicFileWrite.write(data, to: fileURL, permissions: 0o600)
    }
}

/// ssh 传给 askpass 程序的提示语。只有密码提示才回答，避免把密码填进主机密钥确认框。
public enum AskpassPrompt {
    public static func isPasswordPrompt(_ prompt: String) -> Bool {
        let folded = prompt.lowercased()
        if folded.contains("passphrase") || prompt.contains("口令") { return false }
        if folded.contains("yes/no") || folded.contains("fingerprint") { return false }
        return folded.contains("password") || prompt.contains("密码")
    }
}

/// 终端里实际执行的启动脚本：删掉自己，把一次性令牌放进环境变量，再 exec ssh。
/// 脚本里没有密码。
public enum AskpassLauncherScript {
    public static func contents(askpassExecutable: String, sshPath: String, token: String) -> String? {
        guard !askpassExecutable.containsControlCharacters, !sshPath.containsControlCharacters, !token.containsControlCharacters else {
            return nil
        }
        guard !token.isEmpty, sshPath.hasPrefix("/") else { return nil }
        return """
            #!/bin/sh
            rm -f -- "$0"
            export SSH_ASKPASS_REQUIRE=force
            export SSH_ASKPASS=\(ShellQuoting.quote(askpassExecutable))
            export \(AskpassTokenStore.environmentVariable)=\(ShellQuoting.quote(token))
            exec \(ShellQuoting.quote(sshPath)) "$@"
            """
    }
}
