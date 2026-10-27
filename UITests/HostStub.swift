import Cocoa

/// Xcode 需要一个应用目标当 UI 测试宿主。构建后会被 build/SSH Bookmarks.app 整包替换。
@main
enum HostStub {
    static func main() {
        NSApplication.shared.run()
    }
}
