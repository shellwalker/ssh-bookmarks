import MenuSSHCore
import SwiftUI

@main
enum MenuSSHMain {
    static func main() {
        // ssh 继承启动脚本的环境变量后再调用本二进制。普通打开没有这个变量。
        if ProcessInfo.processInfo.environment[AskpassTokenStore.environmentVariable] != nil {
            AskpassMain.run()
        }
        MenuSSHApp.main()
    }
}
