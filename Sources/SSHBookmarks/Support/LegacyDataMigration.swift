import Foundation
import SSHBookmarksCore

/// 升级后的第一次启动：搬 Application Support，并抄一次旧 UserDefaults。
/// 界面测试使用独立目录和 suite，不碰用户的 MenuSSH 数据。
enum LegacyDataMigration {
    static func moveICloudFolderIfNeeded() {
        guard !UITestLaunch.isEnabled else { return }
        do {
            _ = try ICloudDirectoryMigration.migrate(home: NSHomeDirectory()) { source, destination in
                try coordinateMove(from: source, to: destination)
            }
        } catch {
            NSLog("SSH Bookmarks could not move iCloud Drive/MenuSSH: \(error.localizedDescription)")
        }
    }

    /// 搬 iCloud 目录时通知文件协调器，避免云盘还在读旧文件夹。
    private static func coordinateMove(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        let parent = destination.deletingLastPathComponent()
        NSFileCoordinator().coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: parent, options: .forMerging, error: &coordinationError
        ) { sourceURL, parentURL in
            let destinationURL = parentURL.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                moveError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }

    static func moveSupportFolderIfNeeded() {
        guard !UITestLaunch.isEnabled else { return }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            _ = try SupportDirectoryMigration.migrate(applicationSupport: appSupport)
        } catch {
            NSLog("SSH Bookmarks could not move Application Support/MenuSSH: \(error.localizedDescription)")
        }
    }

    static func copyDefaultsIfNeeded(into defaults: UserDefaults) {
        guard !UITestLaunch.isEnabled else { return }
        _ = DefaultsMigration.migrateLegacyDomain(into: defaults)
    }
}
