import AppKit
import SSHBookmarksCore
import SwiftUI

@main
enum SSHBookmarksMain {
    static func main() {
        // 先搬旧的 Application Support，再让 askpass 或界面去创建新目录。
        LegacyDataMigration.moveSupportFolderIfNeeded()
        LegacyDataMigration.moveICloudFolderIfNeeded()
        // ssh 继承启动脚本的环境变量后再调用本二进制。普通打开没有这个变量。
        // 新脚本写 SSHBOOKMARKS_ASKPASS_TOKEN，旧脚本的 MENUSH_ASKPASS_TOKEN 仍认。
        if AskpassTokenStore.token(in: ProcessInfo.processInfo.environment) != nil {
            AskpassMain.run()
        }
        // 测试模式在 SwiftUI 建窗口之前就变成普通应用，否则 LSUIElement 下窗口出不来。
        // 正式路径仍进入 SSHBookmarksApp（菜单栏面板）。SceneBuilder 不能在运行时切换场景。
        if UITestLaunch.isEnabled {
            NSApplication.shared.setActivationPolicy(.regular)
            SSHBookmarksUITestApp.main()
        } else {
            SSHBookmarksApp.main()
        }
    }
}
