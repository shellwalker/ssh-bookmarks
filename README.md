# MenuSSH

macOS 菜单栏上的 SSH 站点管理器。点击菜单栏图标可以搜索并选择站点，选中后在你自己的终端（Terminal、iTerm2 或 Ghostty）里打开 `ssh`。

仓库：<https://github.com/shellwalker/ssh-menu>

> 状态：**M0 骨架**。核心库（模型、命令构建、转义、ssh config 解析、存储）已实现并有单元测试；界面还在骨架阶段，尚未在真机上验证。

## 功能（规划）

- 菜单栏面板：搜索，按收藏和分组列出站点，点击即可连接
- 站点管理窗口（风格参考 Termius）：分组、标签、收藏，可编辑 host、user、port、私钥和跳板机
- 支持 Terminal.app、iTerm2 和 Ghostty，可选新窗口或新标签页
- 设置窗口（风格参考 magpie）：外观、语言（跟随系统 / 简体中文 / English）、开机自启、Dock 图标（隐藏 / 跟随窗口 / 显示）、会话终端
- 密码和私钥口令保存在系统钥匙串，站点数据以 JSON 保存在 `~/Library/Application Support/MenuSSH/`
- 可导入 `~/.ssh/config`

## 系统要求

- macOS 14 Sonoma 或更高版本（主要面向 Apple Silicon）
- 从源码构建需要 Xcode 15.4 或更高版本（Swift 5.9+）

## 构建

```bash
swift test                 # 运行核心库测试（Linux 上也能跑）
Scripts/build_app.sh       # 产出 build/MenuSSH.app（默认 ad-hoc 签名）
Scripts/package.sh         # 产出 dist/MenuSSH-<版本>-arm64.zip
open build/MenuSSH.app
```

如有 Developer ID 证书，可以这样签名：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build_app.sh
```

### 首次运行

- 未签名或 ad-hoc 签名的版本：在 Finder 中右键点击应用，选择“打开”；或者执行 `xattr -dr com.apple.quarantine /Applications/MenuSSH.app`。
- 第一次连接时，系统会询问是否允许 MenuSSH 控制 Terminal / iTerm2 / Ghostty，请点“好”。如果之前拒绝过，可以到“系统设置 › 隐私与安全性 › 自动化”中开启。

## 目录结构

```
Sources/MenuSSHCore/    纯 Foundation 核心库（可在 Linux 测试）
Sources/MenuSSH/        macOS 应用（SwiftUI + AppKit）
Tests/MenuSSHCoreTests/ 单元测试
Resources/              Info.plist、entitlements、本地化文件
Scripts/                构建、打包、公证脚本
docs/                   调研（research.md）与技术方案（design.md）
.github/workflows/      CI（build.yml）与发布（release.yml）
```

## 分支与发布

- 日常开发在 `develop` 分支，稳定后合并到 `main`。
- 从 `main` 打 `v*` tag（例如 `v0.1.0`）会自动构建并创建 GitHub Release。tag 名中含 `-` 的（例如 `v0.2.0-beta.1`）会标记为预发布。
- 签名和公证是可选的，在仓库中配置以下 secrets 后自动启用：`MACOS_CERT_P12_BASE64`、`MACOS_CERT_PASSWORD`、`MACOS_SIGN_IDENTITY`、`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD`。

## 安全

- 连接命令一律先构建为 argv，再统一做 shell 和 AppleScript 转义，并校验 hostname、用户名等输入，防止命令注入。
- 密码不会写入 JSON 文件，也不会出现在命令行中。
- 应用不启用 App Sandbox：它需要读取 `~/.ssh`、调用 `/usr/bin/ssh` 并控制其他终端应用。详细原因见 `docs/design.md`。
