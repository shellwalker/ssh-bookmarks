# MenuSSH 技术方案

> 本文所写的 MenuSSHCore 已经实现，并在 Linux 上通过了单元测试；macOS 应用层（SwiftUI / AppKit）目前只做了语法解析检查，还需要在 Mac 或 CI 上实际编译和验证。§10 列出了所有未验证项。

## 1. 目标与边界

MenuSSH 是 macOS 菜单栏上的 SSH 站点管理器。点击菜单栏图标会弹出可搜索的站点列表，点击某个站点后，在用户选择的终端（Terminal / iTerm2 / Ghostty）里执行 `ssh`。

**不做**：内置终端、SFTP、云同步、账号体系。

## 2. 技术栈

| 选择 | 理由 |
| --- | --- |
| Swift 5.9 工具链，Swift 5 语言模式 | 用 macOS 14 runner 自带的 Xcode 15.4 和 Xcode 16 都能编译，避免 Swift 6 严格并发检查带来的大量噪声 |
| SwiftUI `MenuBarExtra(.window)` + `Window` scene | 原生菜单栏面板（支持搜索框和列表），代码量最少 |
| 少量 AppKit | 包括 Dock 图标切换（`NSApp.setActivationPolicy`）、`NSAppleScript`、`NSWorkspace`、`NSOpenPanel` |
| 最低 macOS 14 | 可以用 `openWindow`、`ContentUnavailableView` 等 API，覆盖绝大多数 Apple Silicon 用户 |
| 纯 SwiftPM，脚本打包 `.app` | 没有 xcodeproj 合并冲突，CI 只需 `swift build`，Core 可在 Linux 上测试（借鉴 iTermGUI） |
| 不用 SwiftPM resources | `Bundle.module` 放进 `.app` 后路径不规范，会影响 codesign。lproj 由脚本直接拷到 `Contents/Resources` |
| 不引入第三方依赖 | 减小供应链风险，签名和公证也更简单 |

## 3. 架构

```
Package.swift
├─ MenuSSHCore（library，只依赖 Foundation，Linux 可测）
│   ├─ Models/     SSHHost、HostGroup、HostLibrary（搜索 / 分区）、AppPreferences 枚举
│   ├─ SSH/        SSHCommandBuilder（argv + 校验）、Quoting（shell / AppleScript 转义）、SSHConfigParser
│   ├─ Terminal/   TerminalApp、TerminalLaunchPlanner（纯函数，生成 AppleScript 或 Process 计划）
│   └─ Storage/    HostFileStore（JSON 原子写，0600 权限）
├─ MenuSSH（executable，仅 macOS）
│   ├─ App/        MenuSSHApp（Scenes）、AppDelegate、DockIconController、AppearanceController
│   ├─ Services/   TerminalLauncher（执行计划）、KeychainService、LoginItemController
│   ├─ Stores/     SettingsStore（UserDefaults）、HostStoreModel（ObservableObject）
│   └─ Views/      MenuBar/、Hosts/（主窗口 + 编辑器）、Settings/（magpie 风格）
└─ Tests/MenuSSHCoreTests
```

数据流：View → `HostStoreModel` → `HostLibrary`（值类型）→ `HostFileStore.save`。连接时调用 `SSHCommandBuilder.argv` 生成 argv，交给 `TerminalLaunchPlanner.plan` 得到启动计划，再由 `TerminalLauncher.execute` 执行。

## 4. 终端调起与注入防护（重点）

### 4.1 构建 argv（`SSHCommandBuilder`）

argv 按以下顺序拼出：

```
/usr/bin/ssh [-l user] [-p port] [-i key -o IdentitiesOnly=yes] [-J jump]
             [-L/-R/-D ...] [-o Key=Value ...] -- <hostname>
```

校验规则（任一不通过就拒绝连接，并提示用户）：

- 所有字段都不能包含控制字符（包括换行和 NUL），以此防止向终端“多输入一行命令”。
- hostname 只允许字母、数字和 `.-_:%[]`（覆盖 IPv6 和 scope id），且不能以 `-` 开头，以防被 ssh 当作选项解析。另外在 hostname 前面加 `--`。
- 用户名不能含空白、不能以 `-` 开头。端口必须在 1–65535 之间。跳板机按逗号拆分后逐段校验。
- 额外选项 `-o` 的 key 只允许 ASCII 字母，value 不能含控制字符。
- 私钥路径展开 `~`，只在认证方式为“私钥”时才传 `-i`。

### 4.2 转义

- **Shell 层**（`ShellQuoting`）：只含安全字符集 `[A-Za-z0-9@%+=:,./_-]` 的参数原样输出；其他参数一律用单引号包裹，内部的 `'` 写成 `'\''`。这种写法在 bash、zsh、fish 中都有效。
- **AppleScript 层**（`AppleScriptQuoting`）：在 shell 转义的结果上，再把 `\` 和 `"` 转义，然后放进 AppleScript 字符串字面量。脚本中只拼接这一个字面量，不插入任何其他用户数据。
- Ghostty 旧版走 `Process` 加 argv，完全不经过 shell 解析。

### 4.3 各终端的调起方式

| 终端 | 新窗口 | 新标签页 | 备注 |
| --- | --- | --- | --- |
| Terminal.app | `do script` | 不支持（需要辅助功能权限） | Terminal 未运行时复用自动打开的 window 1，避免出现两个窗口 |
| iTerm2 | `create window with default profile` + `write text` | `create tab with default profile` | |
| Ghostty ≥ 1.3 | `new window with configuration cfg` | `new tab in front window with configuration cfg` | `initial input` = 命令 & 换行 |
| Ghostty < 1.3 | `open -na Ghostty --args --quit-after-last-window-closed=true -e <argv>` | 不支持 | 版本号读取 bundle 的 `CFBundleShortVersionString` |

命令是“输入”到用户的登录 shell 中，而不是用 `exec` 执行，所以 ssh 断开后窗口仍停留在本地 shell（是否改为自动关闭窗口见开放问题）。

### 4.4 权限、Entitlements 与 Sandbox

- Info.plist 中写 `NSAppleEventsUsageDescription`。首次控制每个终端时，系统都会弹出“自动化”授权对话框。
- `MenuSSH.entitlements` 中写 `com.apple.security.automation.apple-events = true`。开启 Hardened Runtime（Developer ID 和公证都要求）后，没有这一项就无法发送 Apple Events。
- 授权被拒时返回 `-1743`。应用会把它映射为可读的错误提示，并在设置页提供“打开隐私设置”按钮。
- **不启用 App Sandbox**，原因有三：
  1. 沙盒应用发送 Apple Events 需要为每个目标 app 申请 `temporary-exception.apple-events`，而 Mac App Store 审核对此限制严格。
  2. 需要读取 `~/.ssh/config` 和私钥，执行 `/usr/bin/ssh`，以及通过 `open` 启动 Ghostty，这些在沙盒内都受限。
  3. 分发渠道是 GitHub Release 加 Developer ID 公证，不需要沙盒。

## 5. 数据与存储

- 站点数据：`~/Library/Application Support/MenuSSH/hosts.json`。
  - 格式：`{ schemaVersion, groups[], hosts[] }`，排序后的 key、ISO 8601 日期。
  - 目录权限 0700，文件权限 0600，原子写入。
  - 解析失败时，先把原文件备份为 `hosts.corrupt-<时间戳>.json`，再报错，不会覆盖用户数据。
  - 解码比较宽松：缺失字段使用默认值，方便将来升级 schema。
- `SSHHost` 字段：id、label、hostname、port?、username、groupID?、tags、authMethod（automatic / publicKey / password）、identityFile?、jumpHost?、portForwards[]、extraOptions[]、isFavorite、notes、lastConnectedAt、createdAt、updatedAt。
- 机密信息：Keychain generic password。
  - `service` 为 bundle id，`account` 为 `host.<uuid>.password` 或 `host.<uuid>.passphrase`，`accessible` 为 WhenUnlocked。
  - 删除站点时同时清理对应条目。
  - 机密信息绝不写入 JSON，也绝不出现在命令行里。
- 密码登录（M3）：
  - 设置 `SSH_ASKPASS=<MenuSSH.app 可执行文件> --askpass <hostID>` 和 `SSH_ASKPASS_REQUIRE=force`，由 app 自身从 Keychain 读出密码并打印给 ssh。
  - 这些环境变量需要通过终端传递，具体方案待定：可以写入一个一次性的 0700 包装脚本，或使用 Ghostty / iTerm2 的环境变量配置。
  - 要让 Keychain 的“始终允许”持续有效，需要稳定的签名身份。
- `~/.ssh/config` 导入：
  - 只导入非通配的 Host 别名，跳过 `Match` 块，不展开 `Include`（M3 补上）。
  - hostname 填写 alias 本身，这样 ssh 会应用 config 中该 Host 的全部配置；同时打上标签 `ssh-config`。
- 设置：UserDefaults，见 §6。

## 6. 设置项（参考 magpie）

| 分类 | 设置 | 控件 | 存储 / 实现 |
| --- | --- | --- | --- |
| 常规 | 外观 | 分段：跟随系统 / 浅色 / 深色 | `NSApp.appearance` |
| 常规 | 语言 | 下拉：跟随系统 / 简体中文 / English | 写入 `AppleLanguages`，重启后生效，并显示提示 |
| 常规 | 开机自启 | 分段：关闭 / 开启 | `SMAppService.mainApp`，状态以系统为准；需要批准时跳转到登录项设置 |
| 常规 | 显示程序坞 | 分段：隐藏 / 跟随窗口 / 显示 | `LSUIElement=YES`，运行时调用 `setActivationPolicy(.regular / .accessory)`；“跟随窗口”监听 NSWindow 通知 |
| 终端 | 会话终端 | 下拉：系统默认（Terminal）/ iTerm2 / Ghostty，未安装的会标注 | `NSWorkspace.urlForApplication(withBundleIdentifier:)` |
| 终端 | 打开方式 | 分段：新窗口 / 新标签页（终端不支持时禁用） | |
| 终端 | SSH 路径 | 文本框，默认 `/usr/bin/ssh` | |
| 终端 | 自动化权限 | 按钮：打开隐私设置 | |
| 站点 | 导入 `~/.ssh/config` / 数据文件位置 | 按钮 | |
| 关于 | 版本、源码链接 | | |

## 7. 窗口与 Dock

- `MenuBarExtra` 是第一个 Scene。`Window("hosts")` 和 `Window("settings")` 通过 `openWindow(id:)` 打开，随后调用 `NSApp.activate`，否则在 accessory 模式下窗口会出现在其他应用后面。
- 不使用 SwiftUI 的 `Settings` scene：在 LSUIElement 应用中从菜单栏打开它不稳定（macOS 14 起 `showSettingsWindow:` 不再可用）。
- `applicationShouldTerminateAfterLastWindowClosed` 返回 `false`。
- 判断“是否有可见窗口”时，排除 `NSPanel`（MenuBarExtra 的弹出面板就是 NSPanel），并要求窗口带标题栏、层级为 normal。

## 8. 构建与发布

| 内容 | 实现 |
| --- | --- |
| `Scripts/build_app.sh` | `swift build -c release --arch arm64`，组装 `.app`，拷贝 Info.plist 和 lproj，用 PlistBuddy 写入版本号（tag 或 `VERSION`，构建号用提交数），`plutil -lint` 检查，签名（`SIGN_IDENTITY` 或 ad-hoc），最后 `codesign --verify --strict` |
| `Scripts/package.sh` | `ditto` 打 zip，`MAKE_DMG=1` 时额外生成 DMG，并生成 SHA256SUMS |
| `Scripts/notarize.sh` | 缺少凭据时跳过；否则依次执行 `notarytool submit --wait`、`stapler staple`、重新打包 |
| `build.yml` | push 或 PR 到 main / develop 时触发，运行在 macos-14（arm64）：swift-format lint、`swift test`、构建、打包、上传 artifact |
| `release.yml` | 推送 `v*` tag 时触发，先校验 tag 位于 main 上，再测试、构建、打包，有证书时签名和公证，最后执行 `gh release create`（tag 名含 `-` 时标记为 prerelease） |

可选 secrets（未配置时降级为 ad-hoc 签名，跳过公证）：`MACOS_CERT_P12_BASE64`、`MACOS_CERT_PASSWORD`、`MACOS_SIGN_IDENTITY`、`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD`。

分支策略：日常开发在 `develop`，合并到 `main` 后从 `main` 打 tag 发布。

## 9. 里程碑

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| **M0 骨架** | SwiftPM 工程、Core 模型和测试、各界面骨架、打包脚本、CI | CI 在 macos-14 上编译并产出 zip；Core 测试通过 |
| **M1 核心可用** | 站点增删改、分组、收藏、搜索；菜单栏面板连接；三种终端都能调起；错误提示 | 在三种终端里都能用菜单栏一键连上；含空格、引号的参数不会被注入 |
| **M2 设置** | 外观、语言（含完整中英文案）、开机自启、Dock 三态、会话终端、打开方式；设置页搜索（magpie 的“查找设置”） | 设置重启后保持；登录项在签名包中生效 |
| **M3 凭据与导入** | Keychain 密码和口令、SSH_ASKPASS 助手、私钥选择、`ssh-config` 导入（支持 Include 和去重更新）、分组继承（可选）、端口转发 UI | 密码主机无需手动输入即可登录；命令行和 `ps` 中看不到密码 |
| **M4 发布** | 图标、Developer ID 签名、公证、DMG、Release 说明、自动更新（Sparkle，可选） | 从 `v0.1.0` tag 产出公证过的 DMG，Gatekeeper 直接放行 |

## 10. 风险与未验证项（需要 Mac 或 CI 验证）

1. App 层代码只在 Linux 上做过语法解析，需要在 macos-14 CI 上首次编译，可能需要修正少量 API 用法或并发相关的警告。
2. `MenuBarExtra` 作为第一个 Scene 时，启动是否会自动弹出 `Window`：`.defaultLaunchBehavior(.suppressed)` 要到 macOS 15 才有。
3. Terminal.app 未运行时复用 window 1 的写法（以及其中 `delay` 的时长）。
4. Ghostty 1.3 AppleScript 语法：`initial input`、`new tab in front window with configuration`。旧版通过 `open --args -e` 传递 argv 的行为也需验证。
5. MenuBarExtra 弹出面板是否确实是 `NSPanel`，这影响“跟随窗口”模式的判断。
6. ad-hoc 签名下 `SMAppService.mainApp.register()` 的表现，以及 Keychain 授权的持久性。
7. 用户默认 shell 为 nushell 或 xonsh 等非 POSIX shell 时，“输入命令”的方式可能失效（fish 已兼容单引号转义）。
