# AGENTS.md

给所有在这个仓库里工作的编码代理（Cursor cloud agent、Codex、Grok Bot 等）的协作说明。人类贡献者同样适用。

## 项目概览

SSH Bookmarks 是 macOS 14+ 的菜单栏 SSH 站点管理器（SwiftUI + AppKit），在 Terminal、iTerm2 或 Ghostty 里打开 `ssh`，并管理快捷隧道。

纯 SwiftPM 构建（`Package.swift`，tools 5.9）：

| 目标 | 路径 | 说明 |
| --- | --- | --- |
| `SSHBookmarksCore`（library） | `Sources/SSHBookmarksCore/` | 只依赖 Foundation：模型、ssh 命令构建、终端启动计划、存储、同步、迁移、诊断、隧道状态机。Linux 上也能编译和测试。 |
| `SSHBookmarks`（executable） | `Sources/SSHBookmarks/` | macOS 应用（`App/ Services/ Stores/ Support/ Views/`）。只在 `#if os(macOS)` 下声明。 |
| `SSHBookmarksCoreTests` | `Tests/SSHBookmarksCoreTests/` | XCTest 单元测试；`SSHIntegrationTests` 需要 CI 的临时 sshd。 |
| UI 测试 | `UITests/` | XCUITest，由 `Scripts/ci_ui_tests.sh`（借助 `project.yml`）生成工程后运行。 |

其他：`Resources/`（Info.plist、entitlements、`en.lproj` / `zh-Hans.lproj`），`Scripts/`（`build_app.sh`、`package.sh`、`ci_sshd_fixture.sh`、`ci_ui_tests.sh`、`notarize.sh`），`docs/`（设计与测试说明，见 `docs/testing.md`），`.github/workflows/`（`build.yml` CI，`release.yml` 发布）。

## 分支模型

- `develop`：日常开发。`main`：发布。
- 新工作从 `develop` 拉 `feature/*` 或 `fix/*` 分支。
- PR 只开到 `develop`。`develop → main` 只有在 owner 明确说要发版时才做。
- 从 `main` 打 `v*` tag 触发 `release.yml`。

## 提交

- 约定式前缀：`feat:`、`fix:`、`test:`、`docs:`、`refactor:`、`chore:`、`ci:`；可以加范围，如 `fix(review):`。
- 小而有逻辑的提交，一个提交只做一件事。
- **禁止 force push，禁止改写已推送的历史。** 远端有新提交时，在本地 rebase 未推送的提交或 merge，然后正常推送。
- **绝不打印、记录或提交令牌、密码、私钥。** 不要把 `gh auth token` 之类的输出贴进日志、提交或 PR。

## PR 规则

- 使用 `.github/pull_request_template.md`。标题和描述必须与实际 diff（`git diff develop...<branch>`）一致，不写计划中但没做的内容。
- CI 全绿后才把草稿 PR 标为 ready（`gh pr ready <PR>`）。
- 仓库已开启合并后自动删除分支；合并时也要确认源分支被删除。
- **没有 owner 的明确同意绝不合并。**

## 角色

- **Owner（shellwalker）**：批准并合并，或者明确说「合并」。
- **Grok Bot（协调者）**：规划、审阅、开 / 更新 PR、盯 CI、汇报。
- **Codex**：代码审阅和修复。
- **Cloud agents**：按任务实现功能。

## 如何验证

- Linux 机器不能构建 macOS 应用目标，只能跑 Core：`swift build`、`swift test`（不含依赖 Darwin 的集成测试）。最终结果以 GitHub Actions 为准（`build.yml`，`macos-14` arm64）：swift-format lint → `swift test` → 打包 → 临时 sshd 集成测试 → UI 测试。
- 常用命令：
  - `gh pr checks <PR> --watch`
  - `gh run view <run-id> --log-failed`
  - `gh run download <run-id> -n ui-screenshots`
- UI 截图来自 CI artifact `ui-screenshots`（`build/ui-screenshots/`），CI 也会在 PR 上评论截图索引。不做像素比对。

## 编码规则

- Swift 并发：界面和 store 在 `@MainActor`；阻塞 I/O 和子进程等待不要放在主线程。回调要校验 pid / generation 等身份，避免旧进程的事件改写新状态。
- 本地化：所有用户可见文字同时提供 zh-Hans 和 en（`Resources/zh-Hans.lproj/Localizable.strings`、`Resources/en.lproj/Localizable.strings`）；不需要翻译的值用 `Text(verbatim:)`。
- SSH 选项安全（`Sources/SSHBookmarksCore/SSH/SSHCommandBuilder.swift`）：
  - OpenSSH 采用第一次出现的 `-o`。应用强制的选项（如 `StrictHostKeyChecking=yes`、`ExitOnForwardFailure=yes`、隧道的 `ForkAfterAuthentication=no` / `ControlMaster=no` / `ControlPath=none`）必须写在用户额外选项之前；想让用户覆盖的（`ServerAliveInterval` 等）写在之后。
  - 保留 `blockedOptionKeys`（`ProxyCommand`、`LocalCommand`、`KnownHostsCommand` 等会在本机执行代码的选项）和隧道专用的 `tunnelBlockedOptionKeys`，不要放宽。
  - 不要把用户输入交给本地 shell 拼接执行。
- 日志打码：诊断日志与导出包走 `DiagnosticRedactor`；不记录密码，askpass 不回显密码。
- 格式：遵循 `.swift-format`，CI 会 lint。

## 需要真机验证的内容

CI 覆盖不到，改动涉及时请在 PR 的「Needs real-Mac verification」里列出：

- 睡眠 / 唤醒、网络切换后的隧道行为，退出应用时隧道进程被清理。
- iCloud 云盘实时同步与冲突版本处理（`NSFileVersion`）。
- 钥匙串访问弹窗和 askpass 密码自动填写（含跳板机、keyboard-interactive）。
- Terminal / iTerm2 / Ghostty 的自动化授权与启动命令。
- 旧数据目录迁移（MenuSSH → SSH Bookmarks）。
