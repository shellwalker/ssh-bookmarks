import Foundation

public struct DiagnosticFileSnapshot: Equatable, Sendable {
    public var name: String
    public var byteCount: Int
    public var modifiedAt: Date

    public init(name: String, byteCount: Int, modifiedAt: Date) {
        self.name = name
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct DiagnosticRetentionPlan: Equatable, Sendable {
    /// 这些文件删掉。当前文件要轮转时，轮转完成后再按这个名单删。
    public var delete: [String]
    /// 当前文件再写就会超过单文件上限，先把它改成 `.1` 并顺移更旧的文件。
    public var rotate: Bool

    public init(delete: [String], rotate: Bool) {
        self.delete = delete
        self.rotate = rotate
    }
}

/// 诊断文件默认关。打开后保留 7 天，合计约 10 MiB，最多 5 个文件。
public enum DiagnosticRetention {
    public static let maxTotalBytes = 10 * 1024 * 1024
    public static let maxFiles = 5
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    public static let currentName = "diagnostics.log"
    public static var perFileBytes: Int { maxTotalBytes / maxFiles }

    public static func plan(files: [DiagnosticFileSnapshot], appending: Int, now: Date) -> DiagnosticRetentionPlan {
        var delete: [String] = []
        var live: [DiagnosticFileSnapshot] = []
        for file in files {
            if now.timeIntervalSince(file.modifiedAt) > maxAge {
                delete.append(file.name)
            } else {
                live.append(file)
            }
        }
        let currentBytes = live.first { $0.name == currentName }?.byteCount ?? 0
        let rotate = currentBytes > 0 && currentBytes + appending > perFileBytes
        if rotate && live.count >= maxFiles {
            let archived = live.filter { $0.name != currentName }
            if let oldest = archived.max(by: { rank($0.name) < rank($1.name) }) {
                delete.append(oldest.name)
                live.removeAll { $0.name == oldest.name }
            }
        }
        var total = live.reduce(0) { $0 + $1.byteCount }
        if rotate {
            total = total - currentBytes + appending
        } else {
            total += appending
        }
        var archived = live.filter { $0.name != currentName }.sorted { rank($0.name) < rank($1.name) }
        while total > maxTotalBytes, let oldest = archived.popLast() {
            delete.append(oldest.name)
            total -= oldest.byteCount
        }
        return DiagnosticRetentionPlan(delete: delete, rotate: rotate)
    }

    /// 序号越大越旧。`diagnostics.log.4` 比 `.1` 先被丢掉。
    private static func rank(_ name: String) -> Int {
        guard name != currentName, let suffix = name.split(separator: ".").last, let number = Int(suffix) else { return 0 }
        return number
    }
}
