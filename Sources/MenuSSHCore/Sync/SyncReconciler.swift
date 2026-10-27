import Foundation

public struct SyncReconcileResult: Equatable, Sendable {
    public var library: HostLibrary
    public var conflictCount: Int

    public init(library: HostLibrary, conflictCount: Int) {
        self.library = library
        self.conflictCount = conflictCount
    }
}

/// iCloud 冲突副本的文件名：`menu-ssh-sync 2.json`、`hosts 2.json` 这种“名字 + 空格 + 序号”。
public enum SyncConflictNames {
    public static func isCopy(_ fileName: String, of canonical: String) -> Bool {
        let canonicalURL = URL(fileURLWithPath: canonical)
        let stem = canonicalURL.deletingPathExtension().lastPathComponent
        let ext = canonicalURL.pathExtension
        let prefix = stem + " "
        let suffix = "." + ext
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix), fileName.count > prefix.count + suffix.count else {
            return false
        }
        let middle = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        guard let number = Int(middle), number >= 2, String(number) == middle else { return false }
        return true
    }

    public static func copies(in fileNames: [String], of canonical: String) -> [String] {
        fileNames.filter { isCopy($0, of: canonical) }.sorted()
    }
}

/// 同步文件的读写。macOS 上走 `NSFileCoordinator`；Linux 上直接读写，方便核心测试。
enum SyncFileCoordination {
    static func read(url: URL) throws -> Data? {
        #if os(macOS)
        try coordinatedRead(url)
        #else
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
        #endif
    }

    static func write(_ data: Data, to url: URL) throws {
        #if os(macOS)
        try coordinatedWrite(data, to: url)
        #else
        try AtomicFileWrite.write(data, to: url, permissions: 0o600)
        #endif
    }

    #if os(macOS)
    static func unresolvedConflictDocuments(of url: URL) -> [SyncDocument] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        var documents: [SyncDocument] = []
        for version in versions {
            guard let data = try? read(url: version.url), let document = try? SyncCodec.decode(data) else { continue }
            documents.append(document)
        }
        return documents
    }

    static func resolveConflicts(of url: URL) {
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        for version in versions {
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }

    private static func coordinatedRead(_ url: URL) throws -> Data? {
        var coordinationError: NSError?
        var result: Result<Data?, Error> = .success(nil)
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            guard FileManager.default.fileExists(atPath: readURL.path) else {
                result = .success(nil)
                return
            }
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do {
                try AtomicFileWrite.write(data, to: writeURL, permissions: 0o600)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
    #endif
}

public enum AtomicFileWrite {
    /// 先写同目录临时文件，再替换目标。替换前把权限设好。
    public static func write(_ data: Data, to url: URL, permissions: UInt16 = 0o600) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp)
        try fm.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: temp.path)
        if fm.fileExists(atPath: url.path) {
            let result = try fm.replaceItemAt(url, withItemAt: temp)
            let replaced = result ?? url
            try? fm.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: replaced.path)
        } else {
            try fm.moveItem(at: temp, to: url)
            try? fm.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        }
    }
}

/// 读同步目录、并入冲突副本、原子写回，然后删除已合并的副本。
public enum SyncReconciler {
    public static func reconcile(local: HostLibrary, directory: URL, deviceId: String, now: Date = Date()) throws -> SyncReconcileResult {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fileURL = directory.appendingPathComponent(SyncDocument.fileName)
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let copyNames = SyncConflictNames.copies(in: names, of: SyncDocument.fileName)

        let remote = try load(fileURL, missing: SyncDocument(deviceId: deviceId))
        var decodedCopies: [SyncDocument] = []
        var mergedCopyNames: [String] = []
        for name in copyNames {
            let url = directory.appendingPathComponent(name)
            guard let data = try? SyncFileCoordination.read(url: url), let copy = try? SyncCodec.decode(data) else { continue }
            decodedCopies.append(copy)
            mergedCopyNames.append(name)
        }
        #if os(macOS)
        decodedCopies.append(contentsOf: SyncFileCoordination.unresolvedConflictDocuments(of: fileURL))
        #endif

        let withCopies = SyncMerger.mergeCopies(primary: remote, copies: decodedCopies, now: now, writingDeviceId: deviceId)
        let merged = SyncMerger.merge(
            local: SyncDocument(library: local.pruningTombstones(now: now), deviceId: deviceId),
            remote: withCopies.document,
            now: now,
            writingDeviceId: deviceId
        )
        try SyncCodec.write(merged.document, to: fileURL)
        for name in mergedCopyNames {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        #if os(macOS)
        SyncFileCoordination.resolveConflicts(of: fileURL)
        #endif
        return SyncReconcileResult(
            library: merged.document.makeLibrary(),
            conflictCount: withCopies.conflictCount + merged.conflictCount
        )
    }

    private static func load(_ url: URL, missing: SyncDocument) throws -> SyncDocument {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return missing }
        let data: Data?
        do {
            data = try SyncFileCoordination.read(url: url)
        } catch {
            throw SyncFormatError.unreadablePrimary
        }
        guard let data else { return missing }
        do {
            return try SyncCodec.decode(data)
        } catch let error as SyncFormatError {
            throw error
        } catch {
            throw SyncFormatError.unreadablePrimary
        }
    }
}

public enum SyncCodec {
    public static func encode(_ document: SyncDocument) throws -> Data {
        let data = try HostFileStore.makeEncoder().encode(document)
        let object = try JSONSerialization.jsonObject(with: data)
        let keys = SyncSecretScan.keys(in: object)
        if let hit = keys.first(where: { SyncSecretScan.forbiddenKeys.contains($0) }) {
            throw SyncFormatError.secretKey(hit)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> SyncDocument {
        try HostFileStore.makeDecoder().decode(SyncDocument.self, from: data)
    }

    public static func write(_ document: SyncDocument, to url: URL) throws {
        try SyncFileCoordination.write(try encode(document), to: url)
    }
}
