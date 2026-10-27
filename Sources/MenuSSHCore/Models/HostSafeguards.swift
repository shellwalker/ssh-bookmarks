import Foundation

/// 编辑站点时能在 Core 里判断的误操作。界面负责确认框；这里只判断。
public enum HostSafeguards {
    public struct JumpNode: Equatable, Sendable {
        public var hostname: String
        public var jumpHost: String?

        public init(hostname: String, jumpHost: String?) {
            self.hostname = hostname
            self.jumpHost = jumpHost
        }
    }

    public enum JumpIssue: Equatable, Sendable {
        case referencesSelf
        case cycle
    }

    public enum PortForwardIssue: Equatable, Sendable {
        /// 同一站点上 -L / -D 监听了同一个本地端口。
        case duplicateListen(Int)
        /// 小于 1024 的 -L / -D。允许保存，只是警告。
        case privileged(Int)
    }

    public static func jumpIssue(hostname: String, jumpHost: String?, others: [JumpNode]) -> JumpIssue? {
        let start = normalizedHost(hostname)
        guard !start.isEmpty else { return nil }
        let ownHops = hopHosts(jumpHost)
        if ownHops.contains(where: { normalizedHost($0) == start }) { return .referencesSelf }

        var jumps: [String: String?] = [:]
        for node in others {
            let key = normalizedHost(node.hostname)
            if !key.isEmpty { jumps[key] = node.jumpHost }
        }
        jumps[start] = jumpHost

        var stack = Set<String>()
        var finished = Set<String>()
        func walks(_ name: String) -> Bool {
            if stack.contains(name) { return true }
            if finished.contains(name) { return false }
            stack.insert(name)
            for hop in hopHosts(jumps[name] ?? nil) {
                if walks(normalizedHost(hop)) { return true }
            }
            stack.remove(name)
            finished.insert(name)
            return false
        }
        return walks(start) ? .cycle : nil
    }

    public static func portForwardIssues(_ forwards: [PortForward]) -> [PortForwardIssue] {
        var issues: [PortForwardIssue] = []
        var seen = Set<Int>()
        for forward in forwards where forward.kind == .local || forward.kind == .dynamic {
            if !seen.insert(forward.listenPort).inserted {
                issues.append(.duplicateListen(forward.listenPort))
            }
            if (1..<1024).contains(forward.listenPort) {
                issues.append(.privileged(forward.listenPort))
            }
        }
        return issues
    }

    /// 从 `-J` 规格里取出每一跳的主机名（去掉用户和端口）。
    public static func hopHosts(_ jump: String?) -> [String] {
        guard let jump else { return [] }
        let trimmed = jump.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
        if trimmed.isEmpty { return [] }
        return trimmed.split(separator: ",", omittingEmptySubsequences: false).compactMap { hopHostname(String($0)) }
    }

    private static func normalizedHost(_ hostname: String) -> String {
        hostname.trimmingCharacters(in: SSHCommandBuilder.plainSpaces).lowercased()
    }

    private static func hopHostname(_ hop: String) -> String? {
        var rest = hop.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
        if rest.isEmpty { return nil }
        if let at = rest.lastIndex(of: "@") {
            rest = String(rest[rest.index(after: at)...])
        }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let addr = rest[rest.index(after: rest.startIndex)..<close]
            return addr.isEmpty ? nil : String(addr)
        }
        let colons = rest.filter { $0 == ":" }.count
        if colons == 1, let colon = rest.lastIndex(of: ":") {
            let port = rest[rest.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy(\.isNumber) {
                let host = rest[..<colon]
                return host.isEmpty ? nil : String(host)
            }
        }
        return rest
    }
}
