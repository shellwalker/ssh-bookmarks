# 自动化测试

CI 在 `macos-14` arm64 runner 上分三个 job 并行跑。任一失败都会让整次工作流变红，没有 `continue-on-error`。

| Job | 做什么 |
| --- | --- |
| Build & test | `swift-format`、`swift test`（核心库）、`Scripts/build_app.sh`、打包 zip |
| UI automation and screenshots | 启动测试模式的 `.app`，用 XCUITest 走主路径，并截全屏 |
| SSH and sync end-to-end | 本机两个临时 sshd，加上同步文件 schema 检查 |

触发条件与原来的构建一样：推送到 `develop` / `main`，或向这两个分支提 PR。

## CI 已经覆盖

- 核心库单元测试（命令构建、转义、导入、分组树、同步合并、askpass 令牌等）。集成测试在这个 job 里是跳过的，真正执行在下面的端到端 job。
- 菜单栏面板的同一份视图：搜索、最近连接、打开站点窗口。测试模式不点 `MenuBarExtra`（见下文权衡）。
- 站点窗口：选中父组能看到子孙主机，新建分组并放入父组，新建主机。
- 编辑表单：跳板（从已有主机填入）、启动命令、ForwardAgent、本地端口转发的增改，保存后的 JSON，以及假终端日志里的 argv。
- 设置窗口四个分页都会打开。
- 浅色 / 深色、英文 / 简体中文的全屏截图，作为 artifact `ui-screenshots`。索引在 artifact 里的 `index.md`，也会写进该 job 的 Summary，并更新 PR 评论。**不做像素比对**，避免时钟、字体抗锯齿和动画让 CI 误红。
- 公钥登录、askpass 密码登录、`-J` 两个 sshd、`-L` / `-R` / `-D`、启动命令经 pty 送到远端 shell、`ForwardAgent`、带 `Include` 的 config 解析后按字段连上。
- 同步文件 schema 1 读入、与更新的记录合并后写成 schema 2，且编码结果里没有 `password` 等禁止键。备注里出现 “password” 这个词不算泄密。

测试模式只在 `MENUSH_UI_TEST=1`（或 `--ui-test`）时生效：

- `MENUSH_DATA_DIR` 指向独立目录，不碰 `~/Library/Application Support/MenuSSH`。
- 使用单独的 UserDefaults，并强制关闭同步、面板在连接后不关、Dock 图标保持显示。
- `MENUSH_APPEARANCE=light|dark` 固定外观。语言用启动参数 `-AppleLanguages`。
- `MENUSH_FAKE_TERMINAL_LOG` 把将要执行的 argv 和启动命令写成一行 JSON，不跑 AppleScript、不打开 Terminal。

没有这些变量时，正式行为不变。

### 菜单栏面板的权衡

GitHub runner 上点按 `MenuBarExtra` 不稳定，也不该依赖辅助功能授权。测试模式把 `MenuBarContentView` 放进一个普通 `WindowGroup`，正式版仍然是菜单栏面板。因此 CI **没有**覆盖“点菜单栏图标弹出面板”这一下。

## 仍需真机

- 系统「自动化」授权弹窗，以及拒绝后的提示文案。
- 钥匙串密码的「始终允许」、第一次解锁、以及 SSH_ASKPASS 在用户终端里的真实密码提示。
- iCloud 同步目录、冲突副本（`菜单名 2.json`）在未登录或未开 iCloud 时的行为。
- Terminal / iTerm2 / Ghostty 的真实 AppleScript 或 `open -e`（CI 只用假终端日志）。旧版 Ghostty 的 `/bin/sh -c` 也要在装了对应版本的机器上看。
- 开机自启（登录项）和系统设置里的批准。
- ad-hoc 签名换机器后的 Gatekeeper、隔离属性、钥匙串访问身份变化。
- 菜单栏面板的实际弹出、快捷键和输入法组词。
- 非 POSIX 登录 shell 下，终端里那一行 ssh 命令的表现。

## 本地运行

核心库：

```bash
swift test
```

端到端（需要 macOS，会创建用户 `menushssh` 并监听 `127.0.0.1:22221` 和 `:22222`）：

```bash
Scripts/ci_sshd_fixture.sh start
set -a
source build/sshd-fixture.env
set +a
swift test --filter Integration
Scripts/ci_sshd_fixture.sh stop
```

`build/sshd-fixture.env` 只有端口、用户名和路径，没有密码。密码在临时 askpass 脚本里，权限 `0700`。

界面测试（需要 Xcode，以及 XcodeGen 2.42.0；脚本会在缺少时下载）：

```bash
Scripts/ci_ui_tests.sh
```

截图在 `build/ui-screenshots/`，结果包在 `build/ui-results.xcresult`。

只看测试模式的界面、不跑 XCUITest：

```bash
Scripts/build_app.sh
mkdir -p /tmp/menush-preview
MENUSH_UI_TEST=1 MENUSH_DATA_DIR=/tmp/menush-preview \
  MENUSH_APPEARANCE=light MENUSH_FAKE_TERMINAL_LOG=/tmp/menush-preview/terminal.log \
  open build/MenuSSH.app
```
