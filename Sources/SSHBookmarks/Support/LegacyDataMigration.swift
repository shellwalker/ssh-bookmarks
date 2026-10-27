import Foundation
import SSHBookmarksCore

/// 升级后的第一次启动：搬 Application Support，并抄一次旧 UserDefaults。
/// 界面测试使用独立目录和 suite，不碰用户的 MenuSSH 数据。
enum LegacyDataMigration {
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
