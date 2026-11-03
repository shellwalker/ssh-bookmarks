#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

/// 占住一个本机端口，用来在拉起 ssh 之前发现冲突。SO_REUSEADDR 保持关闭。
public final class HeldLocalPort: @unchecked Sendable {
    private var fd: Int32
    private let lock = NSLock()
    public let port: Int

    init(fd: Int32, port: Int) {
        self.fd = fd
        self.port = port
    }

    deinit { release() }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

public enum LocalPortProbe {
    /// `port` 为 0 时由系统分配。失败返回 nil。
    public static func hold(host: String = "127.0.0.1", port: Int = 0) -> HeldLocalPort? {
        guard (0...65535).contains(port) else { return nil }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        var addresses: UnsafeMutablePointer<addrinfo>?
        let name = host == "localhost" ? "127.0.0.1" : host
        guard getaddrinfo(name, String(port), &hints, &addresses) == 0, let address = addresses else { return nil }
        defer { freeaddrinfo(addresses) }
        let fd = socket(address.pointee.ai_family, hints.ai_socktype, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard bind(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else {
            close(fd)
            return nil
        }
        var boundAddress = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            return nil
        }
        let assigned: Int = withUnsafePointer(to: &boundAddress) {
            if address.pointee.ai_family == AF_INET6 {
                return $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
            }
            return $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
        }
        return HeldLocalPort(fd: fd, port: assigned)
    }

    public static func isFree(host: String = "127.0.0.1", port: Int) -> Bool {
        guard let held = hold(host: host, port: port) else { return false }
        held.release()
        return true
    }
}
