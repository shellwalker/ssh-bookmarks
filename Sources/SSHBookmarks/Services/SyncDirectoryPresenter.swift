import Foundation
import SSHBookmarksCore

/// 监视目录而非文件本身，原子替换同步文件后仍能收到通知。回调由 store 去抖并串行处理。
final class SyncDirectoryPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var lastContents: [String: Data]?
    private let changed: @Sendable () -> Void

    init(directory: URL, changed: @escaping @Sendable () -> Void) {
        presentedItemURL = directory
        self.changed = changed
        super.init()
        lastContents = contents()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    deinit { stop() }

    // 写协调结束也可能发通知，即使没有写入。只因内容变化再同步，防止自己的空事务形成通知循环。
    // 这些回调均在上面的串行 operation queue 执行。
    private func notifyIfChanged() {
        let current = contents()
        guard current != lastContents else { return }
        lastContents = current
        changed()
    }

    private func contents() -> [String: Data]? {
        guard let directory = presentedItemURL,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        var result: [String: Data] = [:]
        for name in names where name == SyncDocument.fileName || SyncConflictNames.isCopy(name, of: SyncDocument.fileName) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            result[name] = data
        }
        return result
    }

    func presentedItemDidChange() { notifyIfChanged() }
    func presentedItemDidGain(_ version: NSFileVersion) { changed() }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { changed() }
    func presentedSubitemDidAppear(at url: URL) { notifyIfChanged() }
    func presentedSubitemDidChange(at url: URL) { notifyIfChanged() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { notifyIfChanged() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        changed()
        completionHandler(nil)
    }
}
