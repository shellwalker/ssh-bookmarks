import Darwin
import Foundation

enum TunnelSpawnError: Error {
    case spawn(Int32)
}

/// `ssh -N` 自己成为进程组长，这样 `-J` 拉起的子进程能一起停掉。
enum TunnelSpawn {
    struct Child {
        var pid: pid_t
        var stderr: FileHandle
    }

    static func start(argv: [String], environment: [String: String]) throws -> Child {
        guard let path = argv.first, !path.isEmpty else { throw TunnelSpawnError.spawn(EINVAL) }
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { throw TunnelSpawnError.spawn(errno) }
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw TunnelSpawnError.spawn(errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var pipes: [Int32] = [0, 0]
        guard pipe(&pipes) == 0 else { throw TunnelSpawnError.spawn(errno) }
        let devnull = open("/dev/null", O_RDWR)
        posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO)
        if devnull >= 0 {
            posix_spawn_file_actions_adddup2(&actions, devnull, STDIN_FILENO)
        }
        posix_spawn_file_actions_addclose(&actions, pipes[0])
        posix_spawn_file_actions_addclose(&actions, pipes[1])
        if devnull >= 0 { posix_spawn_file_actions_addclose(&actions, devnull) }

        let cPath = strdup(path)
        defer { free(cPath) }
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc: Int32 = cArgs.withUnsafeMutableBufferPointer { argsBuf in
            cEnv.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(&pid, cPath, &actions, &attr, argsBuf.baseAddress, envBuf.baseAddress)
            }
        }
        if devnull >= 0 { close(devnull) }
        close(pipes[1])
        guard rc == 0 else {
            close(pipes[0])
            throw TunnelSpawnError.spawn(rc)
        }
        return Child(pid: pid, stderr: FileHandle(fileDescriptor: pipes[0], closeOnDealloc: true))
    }

    static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        _ = kill(-pid, signal)
        _ = kill(pid, signal)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func startTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }
}
