// swift-tools-version: 5.9
//
// MenuSSH 使用纯 SwiftPM 构建：
// - MenuSSHCore：只依赖 Foundation 的核心逻辑（模型、ssh 命令构建、终端启动计划、存储、ssh_config 解析），
//   可在 Linux 上编译和测试。
// - MenuSSH：SwiftUI/AppKit 菜单栏应用，仅在 macOS 上声明。
// - .app 由 Scripts/build_app.sh 打包（Info.plist、本地化资源、签名）。
import PackageDescription

var products: [Product] = [
    .library(name: "MenuSSHCore", targets: ["MenuSSHCore"])
]

var targets: [Target] = [
    .target(
        name: "MenuSSHCore",
        path: "Sources/MenuSSHCore"
    ),
    .testTarget(
        name: "MenuSSHCoreTests",
        dependencies: ["MenuSSHCore"],
        path: "Tests/MenuSSHCoreTests"
    ),
]

#if os(macOS)
    products.append(.executable(name: "MenuSSH", targets: ["MenuSSH"]))
    targets.append(
        .executableTarget(
            name: "MenuSSH",
            dependencies: ["MenuSSHCore"],
            path: "Sources/MenuSSH"
        )
    )
#endif

let package = Package(
    name: "MenuSSH",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
