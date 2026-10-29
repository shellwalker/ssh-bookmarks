// swift-tools-version: 5.9
//
// SSH Bookmarks 使用纯 SwiftPM 构建：
// - SSHBookmarksCore：只依赖 Foundation 的核心逻辑（模型、ssh 命令构建、终端启动计划、存储、ssh_config 解析），
//   可在 Linux 上编译和测试。
// - SSHBookmarks：SwiftUI/AppKit 菜单栏应用，仅在 macOS 上声明。产物名没有空格；
//   .app 显示名是 “SSH Bookmarks”，由 Scripts/build_app.sh 打包。
import PackageDescription

var products: [Product] = [
    .library(name: "SSHBookmarksCore", targets: ["SSHBookmarksCore"])
]

var targets: [Target] = [
    .target(
        name: "SSHBookmarksCore",
        path: "Sources/SSHBookmarksCore"
    ),
    .testTarget(
        name: "SSHBookmarksCoreTests",
        dependencies: ["SSHBookmarksCore"],
        path: "Tests/SSHBookmarksCoreTests"
    ),
]

#if os(macOS)
    products.append(.executable(name: "SSHBookmarks", targets: ["SSHBookmarks"]))
    targets.append(
        .executableTarget(
            name: "SSHBookmarks",
            dependencies: ["SSHBookmarksCore"],
            path: "Sources/SSHBookmarks"
        )
    )
#endif

let package = Package(
    name: "SSHBookmarks",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
