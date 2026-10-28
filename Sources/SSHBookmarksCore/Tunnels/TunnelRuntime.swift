import Foundation

public enum TunnelFailureKind: Equatable, Sendable {
    case portInUse
    case privilegedPort
    case authentication
    case hostKeyNew
    case hostKeyChanged
    case jumpFailed
    case timedOut
    case sshMissing
    case other

    /// 端口占用、认证、主机密钥、特权端口和找不到 ssh 都不重连。
    public var reconnects: Bool {
        switch self {
        case .other, .timedOut, .jumpFailed: return true
        case .portInUse, .privilegedPort, .authentication, .hostKeyNew, .hostKeyChanged, .sshMissing: return false
        }
    }
}

public enum TunnelFailureClassifier {
    /// 先看密钥变化，再看没见过的密钥，避免普通的 “host key” 字样盖住更具体的一类。
    public static func classify(stderr: String, exitCode: Int32? = nil) -> TunnelFailureKind {
        let folded = stderr.lowercased()
        if folded.contains("remote host identification has changed") { return .hostKeyChanged }
        if folded.contains("host key verification failed") || folded.contains("host key for") { return .hostKeyNew }
        if folded.contains("address already in use") { return .portInUse }
        if folded.contains("permission denied") && (folded.contains("bind") || folded.contains("listen")) { return .privilegedPort }
        if folded.contains("permission denied") || folded.contains("authentication failed") { return .authentication }
        if folded.contains("timed out") || folded.contains("timeout") || exitCode == 255 && folded.contains("operation timed out") {
            return .timedOut
        }
        if folded.contains("proxyjump") || folded.contains("jump host") { return .jumpFailed }
        if folded.contains("no such file") && folded.contains("ssh") { return .sshMissing }
        return .other
    }
}

public enum TunnelOrphanAction: Equatable, Sendable {
    /// 进程已死、启动时间对不上（PID 被复用）或可执行文件不是当初那个 ssh：只忘记录，不发信号。
    case forget
    /// 进程还在，而且启动时间和 ssh 路径都吻合：对进程组发 SIGTERM。不把管道认领回来。
    case terminate
}

public enum TunnelOrphanDecision {
    public static func decide(processAlive: Bool, startTimeMatches: Bool, executableMatches: Bool) -> TunnelOrphanAction {
        if processAlive && startTimeMatches && executableMatches { return .terminate }
        return .forget
    }
}

public enum TunnelPortConflict {
    public static func listenPorts(in forwards: [PortForward]) -> [Int] {
        forwards.filter { $0.kind == .local || $0.kind == .dynamic }.map(\.listenPort)
    }

    public static func clashes(listenPort: Int, with others: [Int]) -> Bool {
        others.contains(listenPort)
    }
}

public enum TunnelPhase: Equatable, Sendable {
    case idle
    case starting
    case running
    case failed(TunnelFailureKind)
}

public struct TunnelStep: Equatable, Sendable {
    public var phase: TunnelPhase
    public var spawn: Bool
    public var stop: Bool
    public var retryAfter: TimeInterval?
    public var failures: Int

    public init(phase: TunnelPhase, spawn: Bool, stop: Bool, retryAfter: TimeInterval?, failures: Int) {
        self.phase = phase
        self.spawn = spawn
        self.stop = stop
        self.retryAfter = retryAfter
        self.failures = failures
    }
}

public enum TunnelReducer {
    public static let maxConcurrent = 8
    /// 意外退出后最多再试这么多次。间隔是 2、4、8、16、30 秒。
    public static let maxRetries = 5

    public static func backoff(afterFailure count: Int) -> TimeInterval {
        let steps = [2, 4, 8, 16, 30]
        let index = min(max(count, 1), steps.count) - 1
        return TimeInterval(steps[index])
    }

    public static func onStart(runningCount: Int, portBusy: Bool) -> TunnelStep {
        if portBusy {
            return TunnelStep(phase: .failed(.portInUse), spawn: false, stop: false, retryAfter: nil, failures: 0)
        }
        if runningCount >= maxConcurrent {
            return TunnelStep(phase: .failed(.other), spawn: false, stop: false, retryAfter: nil, failures: 0)
        }
        return TunnelStep(phase: .starting, spawn: true, stop: false, retryAfter: nil, failures: 0)
    }

    public static func onRunning() -> TunnelStep {
        TunnelStep(phase: .running, spawn: false, stop: false, retryAfter: nil, failures: 0)
    }

    public static func onUserStop() -> TunnelStep {
        TunnelStep(phase: .idle, spawn: false, stop: true, retryAfter: nil, failures: 0)
    }

    /// `failuresSoFar` 不含这一次退出。可重连时第 1 到第 5 次失败会排队重试，第 6 次停住。
    public static func onExit(kind: TunnelFailureKind, reconnect: Bool, failuresSoFar: Int, runningCount: Int) -> TunnelStep {
        let failures = failuresSoFar + 1
        let room = runningCount < maxConcurrent
        if reconnect && kind.reconnects && failures <= maxRetries && room {
            return TunnelStep(
                phase: .starting,
                spawn: true,
                stop: false,
                retryAfter: backoff(afterFailure: failures),
                failures: failures
            )
        }
        return TunnelStep(phase: .failed(kind), spawn: false, stop: false, retryAfter: nil, failures: failures)
    }
}
