import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// POSIX child fixture avoids Foundation.Process's CFSocket dependency in the Linux sandbox.
enum Review2Process {
    static func start(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { environment in
                posix_spawn(
                    &pid, executable, nil, nil, UnsafeMutablePointer(mutating: args.baseAddress!),
                    UnsafeMutablePointer(mutating: environment.baseAddress!))
            }
        }
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        return pid
    }

    static func wait(_ pid: Int32) -> Int32 {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        return result == pid ? status : -1
    }

    static func terminate(_ pid: Int32) {
        _ = kill(pid, SIGTERM)
    }
}
