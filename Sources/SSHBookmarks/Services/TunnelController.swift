import Combine
import Darwin
import Foundation
import SSHBookmarksCore

struct TunnelSession: Identifiable, Equatable {
    var id: UUID
    var hostID: UUID
    var label: String
    var hostname: String
    var listenPort: Int
    var bindAddress: String?
    var phase: TunnelPhase
    var message: String
    var failures: Int
    var pid: Int32?
    var startedAt: Date?
    var sshPath: String
    var reconnect: Bool
    var generation: Int

    var displayAddress: String {
        let host = bindAddress.flatMap { TunnelAddress.isLoopback($0) ? $0 : nil } ?? "127.0.0.1"
        return "\(host):\(listenPort)"
    }
}

enum TunnelLaunchError: Error {
    case missingPassword
}

enum TunnelStartWarning: Equatable {
    case privileged(Int)
    case nonLoopback(String)
}

struct TunnelStartPrompt: Identifiable, Equatable {
    var id: UUID { forward.id }
    var host: SSHHost
    var forward: PortForward
    var warning: TunnelStartWarning

    static func make(host: SSHHost, forward: PortForward) -> TunnelStartPrompt? {
        if (1..<1024).contains(forward.listenPort) {
            return TunnelStartPrompt(host: host, forward: forward, warning: .privileged(forward.listenPort))
        }
        if let bind = forward.bindAddress?.trimmingCharacters(in: .whitespaces), !bind.isEmpty, !TunnelAddress.isLoopback(bind) {
            return TunnelStartPrompt(host: host, forward: forward, warning: .nonLoopback(bind))
        }
        return nil
    }

    var title: String {
        switch warning {
        case .privileged(let port):
            return L10n.format("Listen on privileged port %lld?", Int64(port))
        case .nonLoopback:
            return String(localized: "Listen beyond this Mac?")
        }
    }

    var message: String {
        switch warning {
        case .privileged:
            return String(localized: "macOS may refuse ports below 1024.")
        case .nonLoopback(let address):
            return L10n.format("Connections to %@ will be accepted from the network, not only from this Mac.", address)
        }
    }
}

enum TunnelAddress {
    static func isLoopback(_ value: String) -> Bool {
        let folded = value.lowercased()
        return folded.isEmpty || folded == "127.0.0.1" || folded == "localhost" || folded == "::1"
    }
}

/// 菜单栏里的本地隧道。界面测试不启动 ssh，只做端口预检和假失败。
@MainActor
final class TunnelController: ObservableObject {
    static let shared = TunnelController()

    @Published private(set) var sessions: [UUID: TunnelSession] = [:]
    @Published var pendingPrompt: TunnelStartPrompt?
    private var stderrTail: [UUID: String] = [:]
    private var readers: [UUID: FileHandle] = [:]
    private var launchGeneration: [UUID: Int] = [:]
    private var ownedGroups: [pid_t: PIDRecord] = [:]

    var runningCount: Int {
        sessions.values.filter { $0.phase == .running || $0.phase == .starting }.count
    }

    var runningForwardIDs: Set<UUID> {
        Set(sessions.values.filter { $0.phase == .running }.map(\.id))
    }

    private init() {
        if !UITestLaunch.isEnabled {
            reapOrphans()
        }
    }

    func session(for forwardID: UUID) -> TunnelSession? { sessions[forwardID] }

    func toggle(host: SSHHost, forward: PortForward) {
        if let existing = sessions[forward.id], existing.phase == .running || existing.phase == .starting {
            stop(forward.id, userInitiated: true)
            return
        }
        start(host: host, forward: forward, inheritedFailures: 0, manual: true, acknowledged: false)
    }

    func acknowledgePrompt() {
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        start(host: prompt.host, forward: prompt.forward, inheritedFailures: 0, manual: true, acknowledged: true)
    }

    func cancelPrompt() {
        pendingPrompt = nil
    }

    func stopAll() {
        for id in Array(sessions.keys) { stop(id, userInitiated: true) }
    }

    func stop(hostID: UUID) {
        if pendingPrompt?.host.id == hostID { pendingPrompt = nil }
        for session in Array(sessions.values) where session.hostID == hostID {
            stop(session.id, userInitiated: true)
        }
    }

    /// 退出通知返回后队列就可能停止；在总计有界的等待内完成 TERM / KILL。
    func terminateAll() {
        var records = loadPIDs()
        for record in ownedGroups.values {
            records.removeAll { $0.pid == record.pid }
            records.append(record)
        }
        for id in Array(launchGeneration.keys) { launchGeneration[id, default: 0] += 1 }
        for record in records where matches(record) || ownsRemainingGroup(record) { TunnelSpawn.signalGroup(record.pid, SIGTERM) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.3
        while ProcessInfo.processInfo.systemUptime < deadline && records.contains(where: { TunnelSpawn.groupIsAlive($0.pid) }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        // 再核对进程启动时间和路径，不向复用后的 PID 发信号。无法确认的保留到下次启动。
        for record in records where TunnelSpawn.groupIsAlive(record.pid) && (matches(record) || ownsRemainingGroup(record)) {
            TunnelSpawn.signalGroup(record.pid, SIGKILL)
        }
        let killDeadline = ProcessInfo.processInfo.systemUptime + 0.2
        while ProcessInfo.processInfo.systemUptime < killDeadline && records.contains(where: { TunnelSpawn.groupIsAlive($0.pid) }) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        save(records.filter { TunnelSpawn.groupIsAlive($0.pid) })
    }

    func trustInTerminal(host: SSHHost, settings: SettingsStore) {
        HostStoreModel.shared.connect(host, settings: settings)
    }

    private func start(
        host: SSHHost, forward: PortForward, inheritedFailures: Int, manual: Bool, acknowledged: Bool
    ) {
        guard forward.kind == .local, forward.quickToggle else { return }
        if !acknowledged, let prompt = TunnelStartPrompt.make(host: host, forward: forward) {
            pendingPrompt = prompt
            return
        }
        let argv: [String]
        do {
            argv = try SSHCommandBuilder(sshPath: SettingsStore.shared.sshPath).tunnelArguments(for: host, forward: forward)
        } catch {
            HostStoreModel.shared.lastError = error.localizedDescription
            return
        }
        launchGeneration[forward.id, default: 0] += 1
        let generation = launchGeneration[forward.id, default: 0]
        stderrTail[forward.id] = ""
        let running = sessions.values.filter { $0.id != forward.id && ($0.phase == .running || $0.phase == .starting) }.count
        let busy = !LocalPortProbe.isFree(host: forward.bindAddress ?? "127.0.0.1", port: forward.listenPort)
            || TunnelPortConflict.clashes(listenPort: forward.listenPort, with: otherPorts(except: forward.id))
        let step = TunnelReducer.onStart(runningCount: running, portBusy: busy)
        var session = TunnelSession(
            id: forward.id, hostID: host.id, label: host.label, hostname: host.hostname,
            listenPort: forward.listenPort, bindAddress: forward.bindAddress, phase: step.phase,
            message: "",
            failures: manual ? TunnelFailureAccounting.afterManualStart() : TunnelFailureAccounting.carriedIntoRetry(inheritedFailures),
            pid: nil, startedAt: nil, sshPath: "", reconnect: forward.reconnect, generation: generation
        )
        if !step.spawn {
            session.message = message(for: step.phase, port: forward.listenPort)
            sessions[forward.id] = session
            DiagnosticLog.tunnel(
                event: "refused", port: forward.listenPort, kind: "port", exitCode: nil, detail: session.message, hosts: [host])
            return
        }
        if UITestLaunch.isEnabled {
            if UITestLaunch.fakeTunnelFailure == "hostKey" {
                session.phase = .failed(.hostKeyNew)
                session.message = message(for: session.phase, port: forward.listenPort)
            } else {
                session.phase = .running
                session.message = ""
            }
            sessions[forward.id] = session
            return
        }
        session.phase = .starting
        sessions[forward.id] = session
        do {
            let env = try childEnvironment(host: host)
            let child = try TunnelSpawn.start(argv: argv, environment: env)
            session.pid = child.pid
            session.startedAt = TunnelSpawn.startTime(child.pid) ?? Date()
            session.sshPath = argv[0]
            session.phase = .running
            sessions[forward.id] = session
            remember(session)
            watch(child.stderr, forwardID: forward.id, pid: child.pid, generation: generation)
            watchExit(pid: child.pid, forwardID: forward.id, generation: generation, host: host)
            scheduleStableReset(forwardID: forward.id, pid: child.pid)
            DiagnosticLog.tunnel(event: "start", port: forward.listenPort, kind: "local", exitCode: nil, detail: "", hosts: [host])
        } catch TunnelLaunchError.missingPassword {
            session.phase = .failed(.authentication)
            session.message = String(localized: "Save a password in the host editor before starting this tunnel")
            sessions[forward.id] = session
            return
        } catch {
            session.phase = .failed(.other)
            session.message = error.localizedDescription
            sessions[forward.id] = session
            DiagnosticLog.tunnel(
                event: "start-failed", port: forward.listenPort, kind: "other", exitCode: nil, detail: session.message, hosts: [host])
        }
    }

    private func stop(_ id: UUID, userInitiated: Bool) {
        guard var session = sessions[id] else { return }
        launchGeneration[id, default: 0] += 1
        let generation = launchGeneration[id, default: 0]
        let childGeneration = session.generation
        if let pid = session.pid {
            let startedAt = session.startedAt
            let sshPath = session.sshPath
            let actual = TunnelSpawn.startTime(pid)
            let sameLeader = startedAt.map { expected in
                actual.map { abs($0.timeIntervalSince(expected)) < 0.00001 } ?? false
            } == true && TunnelSpawn.executablePath(pid) == sshPath
            if sameLeader || (actual == nil && !TunnelSpawn.isAlive(pid) && TunnelSpawn.groupIsAlive(pid)) {
                TunnelSpawn.signalGroup(pid, SIGTERM)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                guard let self, self.launchGeneration[id] == generation, self.sessions[id]?.pid == pid else { return }
                let actual = TunnelSpawn.startTime(pid)
                let sameLeader = startedAt.map { expected in
                    actual.map { abs($0.timeIntervalSince(expected)) < 0.00001 } ?? false
                } == true && TunnelSpawn.executablePath(pid) == sshPath
                // 组长已回收时仍可清理其子进程：只发负 PID，存活进程组持有组号。
                let remainingGroup = actual == nil && !TunnelSpawn.isAlive(pid) && TunnelSpawn.groupIsAlive(pid)
                if sameLeader || remainingGroup { TunnelSpawn.signalGroup(pid, SIGKILL) }
                if !TunnelSpawn.groupIsAlive(pid) { self.forget(pid: pid, forwardID: id, generation: childGeneration) }
            }
        }
        readers[id]?.readabilityHandler = nil
        readers[id] = nil
        session.phase = .idle
        session.message = ""
        session.failures = userInitiated ? 0 : session.failures
        sessions[id] = session
        DiagnosticLog.tunnel(event: "stop", port: session.listenPort, kind: "local", exitCode: nil, detail: "", hosts: [])
    }

    private func watch(_ handle: FileHandle, forwardID: UUID, pid: pid_t, generation: Int) {
        readers[forwardID] = handle
        handle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            if data.isEmpty {
                file.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self, self.sessions[forwardID]?.pid == pid, self.launchGeneration[forwardID] == generation else { return }
                let existing = self.stderrTail[forwardID, default: ""]
                self.stderrTail[forwardID] = String((existing + text).suffix(2048))
            }
        }
    }

    private func watchExit(pid: pid_t, forwardID: UUID, generation: Int, host: SSHHost) {
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            guard result == pid else { return }
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : status
            Task { @MainActor in
                self?.handleExit(forwardID: forwardID, pid: pid, generation: generation, host: host, exitCode: Int32(code))
            }
        }
    }

    private func handleExit(forwardID: UUID, pid: pid_t, generation: Int, host: SSHHost, exitCode: Int32) {
        if !TunnelSpawn.groupIsAlive(pid) { forget(pid: pid, forwardID: forwardID, generation: generation) }
        guard var session = sessions[forwardID], session.pid == pid, session.generation == generation else { return }
        if session.phase == .idle {
            if !TunnelSpawn.groupIsAlive(pid) { session.pid = nil }
            sessions[forwardID] = session
            return
        }
        guard launchGeneration[forwardID] == generation else { return }
        readers[forwardID]?.readabilityHandler = nil
        readers[forwardID] = nil
        let kind = TunnelFailureClassifier.classify(stderr: stderrTail[forwardID] ?? "", exitCode: exitCode)
        let running = sessions.values.filter { $0.id != forwardID && ($0.phase == .running || $0.phase == .starting) }.count
        let step = TunnelReducer.onExit(kind: kind, reconnect: session.reconnect, failuresSoFar: session.failures, runningCount: running)
        session.failures = step.failures
        session.phase = step.phase
        session.pid = nil
        session.message = message(for: step.phase, port: session.listenPort)
        sessions[forwardID] = session
        DiagnosticLog.tunnel(
            event: "exit", port: session.listenPort, kind: "\(kind)", exitCode: exitCode,
            detail: stderrTail[forwardID] ?? "", hosts: [host]
        )
        guard step.spawn, let delay = step.retryAfter else { return }
        let hostID = session.hostID
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.launchGeneration[forwardID] == generation,
                self.sessions[forwardID]?.phase == .starting else { return }
            guard let target = TunnelRetryTarget.current(in: HostStoreModel.shared.library, hostID: hostID, forwardID: forwardID) else {
                self.sessions[forwardID] = nil
                return
            }
            self.start(host: target.host, forward: target.forward, inheritedFailures: step.failures, manual: false, acknowledged: true)
        }
    }

    private func scheduleStableReset(forwardID: UUID, pid: pid_t) {
        let generation = launchGeneration[forwardID, default: 0]
        DispatchQueue.main.asyncAfter(deadline: .now() + TunnelFailureAccounting.stableUptime) { [weak self] in
            guard let self, self.launchGeneration[forwardID] == generation else { return }
            guard var session = self.sessions[forwardID], session.phase == .running, session.pid == pid else { return }
            session.failures = TunnelFailureAccounting.afterUptime(TunnelFailureAccounting.stableUptime, current: session.failures)
            self.sessions[forwardID] = session
        }
    }

    private func otherPorts(except id: UUID) -> [Int] {
        sessions.values.filter { $0.id != id && ($0.phase == .running || $0.phase == .starting) }.map(\.listenPort)
    }

    private func childEnvironment(host: SSHHost) throws -> [String: String] {
        var env: [String: String] = [:]
        let parent = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOME", "LANG", "SSH_AUTH_SOCK"] {
            if let value = parent[key], !value.isEmpty { env[key] = value }
        }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        guard host.authMethod == .password else { return env }
        let account = KeychainService.account(hostID: host.id, kind: .password)
        guard let password = try KeychainService().get(account: account), !password.isEmpty else {
            throw TunnelLaunchError.missingPassword
        }
        guard let executable = Bundle.main.executablePath else { throw TunnelSpawnError.spawn(ENOENT) }
        let token = try AskpassTokenFile.issue(
            hostID: host.id, username: host.username.trimmingCharacters(in: .whitespaces),
            hostname: host.hostname.trimmingCharacters(in: .whitespaces), fileURL: AskpassPaths.tokenFileURL(), now: Date())
        DiagnosticLog.askpassIssued()
        env["SSH_ASKPASS"] = executable
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = "sshbookmarks"
        env[AskpassTokenStore.environmentVariable] = token
        return env
    }

    private func message(for phase: TunnelPhase, port: Int) -> String {
        switch phase {
        case .failed(.portInUse):
            return L10n.format("Local port %lld is already in use", Int64(port))
        case .failed(.privilegedPort):
            return L10n.format("No permission to listen on port %lld", Int64(port))
        case .failed(.authentication):
            return String(localized: "Login was refused. Check the key or the password in the Keychain")
        case .failed(.hostKeyNew):
            return String(localized: "This host key is not trusted yet.")
        case .failed(.hostKeyChanged):
            return String(localized: "The host key changed and was not accepted.")
        case .failed(.jumpFailed):
            return String(localized: "The jump host did not connect")
        case .failed(.timedOut):
            return String(localized: "The connection timed out")
        case .failed(.sshMissing):
            return String(localized: "ssh could not be found")
        case .failed:
            return String(localized: "The tunnel exited. The diagnostic log has the redacted detail.")
        case .idle, .starting, .running:
            return ""
        }
    }

    // MARK: PID file

    private struct PIDRecord: Codable {
        var pid: Int32
        var startedAt: Date
        var hostID: UUID
        var forwardID: UUID
        var listenPort: Int
        var sshPath: String
        var generation: Int?
    }

    private func pidURL() -> URL {
        AskpassPaths.applicationSupport().appendingPathComponent("tunnel-pids.json")
    }

    private func remember(_ session: TunnelSession) {
        guard let pid = session.pid, let started = session.startedAt else { return }
        let record = PIDRecord(
            pid: pid, startedAt: started, hostID: session.hostID, forwardID: session.id,
            listenPort: session.listenPort, sshPath: session.sshPath, generation: session.generation)
        ownedGroups[pid] = record
        var records = loadPIDs().filter { $0.pid != pid }
        records.append(record)
        save(records)
    }

    private func forget(pid: pid_t, forwardID: UUID, generation: Int) {
        if ownedGroups[pid]?.forwardID == forwardID && ownedGroups[pid]?.generation == generation {
            ownedGroups[pid] = nil
        }
        save(loadPIDs().filter { !($0.pid == pid && $0.forwardID == forwardID && $0.generation == generation) })
    }

    private func ownsRemainingGroup(_ record: PIDRecord) -> Bool {
        // 组长退出后，当前应用仍记得自己创建的组；组号在最后一个成员退出前不会释放。
        guard let owned = ownedGroups[record.pid], owned.forwardID == record.forwardID,
            owned.startedAt == record.startedAt, owned.generation == record.generation else { return false }
        return !TunnelSpawn.isAlive(record.pid) && TunnelSpawn.groupIsAlive(record.pid)
    }

    private func matches(_ record: PIDRecord) -> Bool {
        guard let started = TunnelSpawn.startTime(record.pid) else { return false }
        // PID 文件用 ISO 8601 保存，小数秒会丢失；同一秒内同路径的 PID 复用可以忽略。
        return abs(started.timeIntervalSince(record.startedAt)) < 1 && TunnelSpawn.executablePath(record.pid) == record.sshPath
    }

    private func reapOrphans() {
        var kept: [PIDRecord] = []
        for record in loadPIDs() {
            guard TunnelSpawn.groupIsAlive(record.pid) else { continue }
            if matches(record) { TunnelSpawn.signalGroup(record.pid, SIGTERM) }
            // 身份无法确认或 TERM 后尚未退出都留存，不能丢失监管记录。
            if TunnelSpawn.groupIsAlive(record.pid) { kept.append(record) }
        }
        save(kept)
    }

    private func loadPIDs() -> [PIDRecord] {
        guard let data = try? Data(contentsOf: pidURL()) else { return [] }
        return (try? JSONDecoder().decode([PIDRecord].self, from: data)) ?? []
    }

    private func save(_ records: [PIDRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? AtomicFileWrite.write(data, to: pidURL(), permissions: 0o600)
    }
}
