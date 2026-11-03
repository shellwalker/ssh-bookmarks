import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Pipe callbacks append synchronously under the same lock used by exit handling.
/// No queued UI task can deliver the last stderr chunk after classification.
public final class TunnelStderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var tail = Data()

    public init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] _ in self?.drain() }
    }

    public func finish() -> String {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        drainLocked()
        return String(decoding: tail, as: UTF8.self)
    }

    public func stop() {
        handle.readabilityHandler = nil
    }

    private func drain() {
        lock.lock()
        defer { lock.unlock() }
        drainLocked()
    }

    private func drainLocked() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        // poll avoids blocking on pipes still held open by ProxyJump children.
        for _ in 0..<64 {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 0) > 0 else { return }
            let count = read(handle.fileDescriptor, &bytes, bytes.count)
            if count == -1 && errno == EINTR { continue }
            guard count > 0 else {
                if count == 0 { handle.readabilityHandler = nil }
                return
            }
            tail.append(contentsOf: bytes.prefix(count))
            if tail.count > 2048 { tail = Data(tail.suffix(2048)) }
        }
    }
}
