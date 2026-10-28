#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

/// 占住一个本机端口，用来在拉起 ssh 之前发现冲突。SO_REUSEADDR 保持关闭。
public final class HeldLocalPort: @unchecked Sendable {
    private var fd: Int32
    public let port: Int

    init(fd: Int32, port: Int) {
        self.fd = fd
        self.port = port
    }

    deinit { release() }

    public func release() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

public enum LocalPortProbe {
    /// `port` 为 0 时由系统分配。失败返回 nil。
    public static func hold(host: String = "127.0.0.1", port: Int = 0) -> HeldLocalPort? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host == "localhost" ? "127.0.0.1" : host)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            return nil
        }
        let assigned = Int(UInt16(bigEndian: boundAddress.sin_port))
        return HeldLocalPort(fd: fd, port: assigned)
    }

    public static func isFree(host: String = "127.0.0.1", port: Int) -> Bool {
        guard let held = hold(host: host, port: port) else { return false }
        held.release()
        return true
    }
}
