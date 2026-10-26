# MenuSSH 调研：iTermGUI 与 Termius

> 调研日期：2026-10-26。iTermGUI 是直接读的仓库源码（通过 GitHub API 和 raw 文件，没有 clone）；Termius 只看了官网和官方文档，未实际安装使用。

## 1. iTermGUI（StakeSquid/iTermGUI）

源码：<https://github.com/StakeSquid/iTermGUI>（MIT，Swift）

### 1.1 概况

| 维度 | 做法 |
| --- | --- |
| 工程形态 | 纯 SwiftPM（`Package.swift`，tools 6.2，平台 macOS 26），依赖 SwiftTerm；没有 xcodeproj |
| 打包 | `Scripts/build_app.sh`：`swift build -c release` 之后手工组装 `.app`。默认 ad-hoc 签名，也可用本地自签名身份 "iTermGUI Local Dev" 来稳定钥匙串授权 |
| CI | GitHub Actions `macos-26`，用 create-dmg 生成 DMG，再用 `softprops/action-gh-release` 发布 |
| 数据 | 每个 profile 一个 JSON，放在 `~/Documents/iTermGUI/`；密码用 SecItem 封装存入 Keychain |
| 终端 | 同步 iTerm2 Dynamic Profiles，并用 AppleScript 打开 iTerm2；同时内嵌 SwiftTerm 终端 |
| 功能 | 智能分组（全部 / 收藏 / 最近）、标签、搜索、菜单栏 Quick Connect、`~/.ssh/config` 导入与同步、`SSH_ASKPASS` 密码助手、SFTP |
| 测试 | AppleScriptRunner、ProcessRunner、KeychainStore、ProfileFileStore 都以协议注入，测试用 fake 替身，约 379 个测试 |

### 1.2 值得借鉴

1. **纯 SwiftPM 加打包脚本**：不用 Xcode 工程也能产出 `.app`，CI 只需 `swift build`，Linux 上也能跑 Core 的测试。MenuSSH 直接沿用。
2. **副作用全部抽象成可注入接口**（AppleScript、Process、Keychain、文件）。核心逻辑因此可以单测，MenuSSH 的 `MenuSSHCore` 就是按这个思路拆出来的。
3. **智能分组**：收藏 / 最近，加上自定义分组和标签。
4. **SSH_ASKPASS 密码助手**：app 自身作为 askpass 程序，从 Keychain 读密码，避免明文出现在命令行或剪贴板。MenuSSH 计划在 M3 实现。
5. **`~/.ssh/config` 导入**：以 alias 作为连接目标，保留 config 中的全部选项。
6. **签名注意点**：ad-hoc 签名每次构建身份都会变，Keychain 的“始终允许”随之失效。开发期需要稳定的自签名身份，正式发布用 Developer ID。

### 1.3 不采用 / 需要规避

1. **命令拼接没有转义**：`buildSSHCommand` 用空格把参数直接拼起来，host、用户名或路径里有空格或 shell 元字符时会出错，甚至可被注入。MenuSSH 必须先构建 argv，再统一做 POSIX 单引号转义，并做输入校验（见 design.md §4）。
2. **要求 macOS 26 / Swift 6.2**：门槛太高。MenuSSH 定在 macOS 14+、Swift 5.9 工具链，GitHub `macos-14` runner 可以直接构建。
3. **内嵌终端（SwiftTerm）和 SFTP**：工作量大，也偏离“在用户自己的终端里打开”的定位，不做。
4. **数据放在 `~/Documents`**：容易被 iCloud 同步或误删。MenuSSH 放到 `~/Library/Application Support/MenuSSH/`，并设为 0600 权限。
5. **只深度支持 iTerm2**：MenuSSH 要同时支持 Terminal.app、iTerm2 和 Ghostty。

## 2. Termius

官网：<https://termius.com/index.html>

参考文档：

- 分组与标签：<https://docs.termius.com/organize-and-connect-to-hosts/groups-and-tags>
- 身份（Identities）：<https://docs.termius.com/keychain/identities>
- 代码片段（Snippets）：<https://docs.termius.com/terminal/snippets>
- 端口转发：<https://docs.termius.com/organize-and-connect-to-hosts/port-forwarding-and-tunneling>

### 2.1 核心概念

- **Host**：包含 label、地址、端口、标签。列表卡片显示首字母头像、label 以及 `ssh user@host -p port` 形式的副标题。
- **Group**：不只是文件夹。分组可以嵌套，组内主机继承分组设置（凭据、跳板机、启动 snippet、主题等）。
- **Tags**：可跨分组过滤。
- **Keychain / Identity**：把“用户名 + 密码 / 私钥”做成可复用的身份，多台主机共用。支持生成密钥和 FIDO2。
- **Port Forwarding**：本地、远程、动态（SOCKS）三种。
- **其他**：Snippets、SFTP、Workspaces（多标签布局）、自动补全，以及加密云同步和团队 Vault（付费）。
- **UI**：左侧导航（Hosts / Keychain / Port Forwarding / Snippets…），右侧是卡片或列表，顶部有搜索框。

### 2.2 借鉴

1. **信息架构**：左侧分组 / 筛选，右侧带搜索的主机列表；用首字母彩色头像，副标题显示 `user@host:port`。
2. **数据模型**：Host 包含 label、host、port、user、group、tags、认证方式、私钥、跳板机和端口转发。模型中先预留字段，UI 分阶段开放。
3. **分组继承**：例如组级默认用户名和跳板机，可作为 M3 之后的增强（见 design.md 的开放问题）。
4. **Identity 概念**：M3 可以做轻量版，用一个可复用的“用户名 + 私钥 / 密码”条目。

### 2.3 不采用

1. 云同步、团队 Vault、账号体系：不做，数据只保存在本地。
2. 内置终端、SFTP、Workspaces、自动补全：交给用户自己的终端。
3. 自有加密存储：直接用系统 Keychain。

## 3. 终端调起方式调研

| 终端 | 方式 | 说明 / 来源 |
| --- | --- | --- |
| Terminal.app | AppleScript `do script "<cmd>"` | 会新开窗口。“新标签页”只能靠 System Events 模拟 ⌘T，需要辅助功能权限，因此不支持 |
| iTerm2 | AppleScript `create window with default profile`（或 `create tab`）+ `write text` | iTerm2 官方 AppleScript 字典 |
| Ghostty ≥ 1.3.0 | AppleScript：`new surface configuration`，设置 `initial input`，再执行 `new window` / `new tab` | <https://ghostty.org/docs/features/applescript>。首次使用会弹出 TCC 自动化授权；用户可用 `macos-applescript = false` 禁用 |
| Ghostty < 1.3.0 | `open -na Ghostty --args --quit-after-last-window-closed=true -e <argv>` | macOS 上的 `ghostty` CLI 不能启动终端，见讨论 <https://github.com/ghostty-org/ghostty/discussions/7867>、<https://github.com/ghostty-org/ghostty/discussions/9221>、<https://github.com/ghostty-org/ghostty/discussions/10201>。每次都会新开一个 Ghostty 实例 |

权限方面：

- 发送 Apple Events 需要在 Info.plist 中写 `NSAppleEventsUsageDescription`。
- 开启 Hardened Runtime 时，还需要 entitlement `com.apple.security.automation.apple-events`。
- 用户拒绝授权后，脚本返回错误 `-1743`（errAEEventNotPermitted），需要引导用户到“隐私与安全性 › 自动化”中开启。

## 4. 参考 UI：magpie 设置页

参考图见 `ref/magpie-settings.png`：左侧是分类导航；右侧顶部是“设置 / 常规”面包屑和“查找设置”搜索框，下方是卡片式分组，每行左边标题、右边分段控件或下拉框。

MenuSSH 沿用的行：

| 设置 | 选项 |
| --- | --- |
| 外观 | 跟随系统 / 浅色 / 深色 |
| 语言 | 下拉 |
| 开机自启 | 关闭 / 开启 |
| 显示程序坞 | 隐藏 / 跟随窗口 / 显示 |
| 会话终端 | 系统默认（Terminal）/ Ghostty / iTerm2 |

## 5. 结论摘要

1. 采用 iTermGUI 的工程形态（纯 SwiftPM、脚本打包、副作用可注入），规避它的命令拼接缺陷。
2. 采用 Termius 的信息架构（分组、标签、搜索、首字母头像、`user@host:port` 副标题），不做云端、内置终端和 SFTP。
3. 用户自己的终端是唯一的会话载体：Terminal / iTerm2 走 AppleScript，Ghostty 按版本选择 AppleScript 或 `open -na`。
4. 安全底线：只走 argv，统一转义，做输入校验，密码只存 Keychain，不出现在命令行里。
