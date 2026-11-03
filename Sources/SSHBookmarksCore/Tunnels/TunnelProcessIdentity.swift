import Foundation

/// A stopped child keeps its identity independently of any replacement session.
public struct TunnelProcessIdentity: Equatable, Sendable {
    public var pid: Int32
    public var startedAt: Date
    public var executablePath: String

    public init(pid: Int32, startedAt: Date, executablePath: String) {
        self.pid = pid
        self.startedAt = startedAt
        self.executablePath = Self.normalizedPath(executablePath)
    }

    public static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Normalize both sides so records from older versions containing a symlink still work.
    public static func pathsMatch(_ expected: String, _ actual: String?) -> Bool {
        guard let actual, !expected.isEmpty, !actual.isEmpty else { return false }
        return normalizedPath(expected) == normalizedPath(actual)
    }

    public func canSignal(
        observedStart: Date?, observedPath: String?, leaderAlive: Bool, groupAlive: Bool, ownsGroup: Bool
    ) -> Bool {
        guard groupAlive else { return false }
        if let observedStart {
            return abs(observedStart.timeIntervalSince(startedAt)) < 0.00001
                && Self.pathsMatch(executablePath, observedPath)
        }
        return ownsGroup && !leaderAlive
    }
}

/// Used for both stopped children and verified orphans, independently of forward sessions.
public struct TunnelCleanupPlan: Sendable {
    public enum Action: Equatable, Sendable {
        case retry(kill: Bool)
        case finished
        /// Keep the PID record for another recovery attempt; never claim cleanup succeeded.
        case retain
    }

    public let identity: TunnelProcessIdentity
    private var remainingKills = 5

    public init(identity: TunnelProcessIdentity) {
        self.identity = identity
    }

    public mutating func advance(
        observedStart: Date?, observedPath: String?, leaderAlive: Bool, groupAlive: Bool, ownsGroup: Bool
    ) -> Action {
        guard groupAlive else { return .finished }
        guard remainingKills > 0 else { return .retain }
        remainingKills -= 1
        return .retry(
            kill: identity.canSignal(
                observedStart: observedStart, observedPath: observedPath, leaderAlive: leaderAlive,
                groupAlive: groupAlive, ownsGroup: ownsGroup))
    }
}
