# 自动化测试

CI 在一台 `macos-14` arm64 runner 上按顺序跑完。排队中的并行 job 曾在大约 15 分钟后被取消，所以现在合成一个 job。任一失败都会让整次工作流变红，没有 `continue-on-error`。

| 阶段 | 做什么 |
| --- | --- |
| Build & test | `swift-format`、`swift test`（核心库）、`Scripts/build_app.sh`、打包 zip |
| SSH and sync end-to-end | 本机两个临时 sshd，加上同步文件 schema 检查 |
| UI automation and screenshots | 启动测试模式的 `.app`，用 XCUITest 走主路径，并截全屏 |

触发条件与原来的构建一样：推送到 `develop` / `main`，或向这两个分支提 PR。发布工作流 `release.yml` 在打包之前也会跑同一套 sshd 集成测试（`SSHBOOKMARKS_INTEGRATION=1`，旧名 `MENUSH_INTEGRATION` 仍有效）。界面测试仍只在 PR / `develop` 的 `build.yml` 里跑。

## CI 已经覆盖

- 核心库单元测试（命令构建、转义、导入、分组树、同步合并、askpass 令牌等）。集成测试在这个 job 里是跳过的，真正执行在下面的端到端 job。
- 菜单栏面板的同一份视图：搜索、最近连接、打开站点窗口。测试模式不点 `MenuBarExtra`（见下文权衡）。
- 站点窗口：选中父组能看到子孙主机，新建分组并放入父组，新建主机。
- 编辑表单：跳板（从已有主机填入）、启动命令、ForwardAgent、`-o` 额外选项、本地端口转发的增改，保存后的 JSON，以及假终端日志里的 argv。动态转发不显示目标主机和端口。保存按钮在接近生产高度（站点窗口约 920×580，表单滚动、按钮钉在底部）时可点。
- 空站点面板：导入 `~/.ssh/config`（报告导入条数、跳过的重复项，并说明连接用别名、HostName 进备注）和新建站点。密钥选择器列出带 `.pub` 的私钥。
- 删除站点前有确认框；取消编辑未保存的修改前也会确认。
- 设置窗口分页都会打开，包括「诊断」和「关于」。关于页显示版本、构建号和口号。
- 快捷隧道：测试模式拨动面板开关后出现数量；端口被占用时显示冲突；`MENUSH_FAKE_TUNNEL_FAILURE=hostKey` 显示主机密钥错误和「在终端中打开一次以信任」。不启动真 ssh。
- 端到端：`tunnelArguments` 对临时 sshd 做 `-L`，先 `ssh-keyscan` 写入 known_hosts（生产 argv 强制 `StrictHostKeyChecking=yes`，不能靠 `no` 绕过），curl 读到约定字节，停止后进程和本地端口都消失。
- 诊断脱敏、ZIP 不含秘密、schema v3 仍能读 v2，在 `Round3CoreTests`。
- 浅色 / 深色、英文 / 简体中文的全屏截图，作为 artifact `ui-screenshots`。索引在 artifact 里的 `index.md`，也会写进该 job 的 Summary，并更新 PR 评论。**不做像素比对**，避免时钟、字体抗锯齿和动画让 CI 误红。
- 公钥登录、askpass 密码登录、`-J` 两个 sshd、`-L` / `-R` / `-D`、启动命令经 pty 送到远端 shell、`ForwardAgent`、带 `Include` 的 config 解析后按字段连上。
- 同步文件 schema 1 读入、与更新的记录合并后写成 schema 2，且编码结果里没有 `password` 等禁止键。备注里出现 “password” 这个词不算泄密。

测试模式只在 `SSHBOOKMARKS_UI_TEST=1`（或 `--ui-test`）时生效。旧名 `MENUSH_UI_TEST` 以及下面每个 `MENUSH_*` 仍作为别名。

- `SSHBOOKMARKS_DATA_DIR`（别名 `MENUSH_DATA_DIR`）指向独立目录，不碰 `~/Library/Application Support/SSH Bookmarks`，也不把用户的 `MenuSSH` 目录改名。
- 使用单独的 UserDefaults，并强制关闭同步、面板在连接后不关、Dock 图标保持显示。不从 `com.shellwalker.MenuSSH` 抄偏好。
- `SSHBOOKMARKS_APPEARANCE=light|dark`（别名 `MENUSH_APPEARANCE`）固定外观。语言用启动参数 `-AppleLanguages`。
- `SSHBOOKMARKS_FAKE_TERMINAL_LOG`（别名 `MENUSH_FAKE_TERMINAL_LOG`）把将要执行的 argv 和启动命令写成一行 JSON，不跑 AppleScript、不打开 Terminal。
- 升级迁移（Application Support 改名、UserDefaults 抄写、钥匙串 service 选择、iCloud 目录名保持 `MenuSSH`）在 `DataMigrationTests` 里用临时目录和临时 suite 覆盖。日志在 Application Support 的 `Logs/`，跟着文件夹一起搬。
- 站点窗口保持接近生产尺寸（宽不超过 960、高不超过 580），不再为了测试把窗口拉满屏幕。编辑表单自己滚动，保存栏始终露在外面。面板窗口仍靠右，高度不变。

没有这些变量时，正式行为不变。

### 菜单栏面板的权衡

GitHub runner 上点按 `MenuBarExtra` 不稳定，也不该依赖辅助功能授权。测试模式把 `MenuBarContentView` 放进一个普通 `WindowGroup`，正式版仍然是菜单栏面板。因此 CI **没有**覆盖“点菜单栏图标弹出面板”这一下。

## 编辑时的防护

这些判断在 `SSHBookmarksCore` 有单测；确认框本身在 macOS 界面上。

| 操作 | 行为 |
| --- | --- |
| 删除站点或分组 | 先确认。分组会说明站点移到未分组、子分组上移一级。站点窗口可用 ⌘Z 撤销库的改动；已从钥匙串删掉的密码不会回来。 |
| 导入 `~/.ssh/config` | 同名 hostname 跳过，不覆盖。提示导入数和跳过数，并说明别名策略。 |
| 打开同步或更换文件夹 | 打开同步沿用明文警告。换文件夹再确认一次：本机站点保留，和新文件合并，不会被空库覆盖。 |
| 替换或清除已存密码 | 单独确认。清除只在保存时从钥匙串删除。 |
| 跳板机 | 拒绝指向自己，或和已有站点的跳板形成环。 |
| 端口转发 | 同一站点上重复的本地监听端口（`-L` / `-D`）不能保存。小于 1024 的端口允许保存，但给出警告。 |
| 主机名、端口、用户名 | 保存时去掉首尾空格；空格和控制字符仍拒绝。端口 1–65535。 |
| 未保存就关闭 | Cancel / Esc 先问要不要放弃。 |
| `ssh-copy-id` | 仍须确认后才在用户的终端里运行。 |
| 危险的 `-o` | `ProxyCommand` 等会在本机执行命令或加载代码的选项，编辑时就拒绝，并说明原因。 |
| 启动命令 | 去掉末尾换行。像是带了密码（`password=`、`sshpass` 等）时警告，仍允许保存。 |
| 私钥 | 选了 `.pub` 会改用对应私钥。文件缺失或权限宽于 0600 时警告，仍允许保存。不同站点可以共用或各用各的密钥。 |
| 悬停 | 只改变行的背景，不移动键盘选中项。 |

## 仍需真机

- 系统「自动化」授权弹窗，以及拒绝后的提示文案。
- 钥匙串密码的「始终允许」、第一次解锁、以及 SSH_ASKPASS 在用户终端里的真实密码提示。
- iCloud 同步目录、`NSFileCoordinator` 协调读写，以及系统冲突版本（`NSFileVersion`）在未登录或未开 iCloud 时的行为。文件名冲突副本（`菜单名 2.json`）的合并有核心测试。
- 钥匙串里替换或清除密码的系统确认（「始终允许」）是否再弹一次。
- 私钥权限警告是否和本机 `ssh` 的拒绝一致（含外接卷上的密钥）。
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

截图在 `build/ui-screenshots/`（若测试进程没拿到绝对路径，会先写到 `/tmp/menush-ui-screenshots`，脚本结束时拷回来）。结果包在 `build/ui-results.xcresult`。

只看测试模式的界面、不跑 XCUITest：

```bash
Scripts/build_app.sh
mkdir -p /tmp/menush-preview
SSHBOOKMARKS_UI_TEST=1 SSHBOOKMARKS_DATA_DIR=/tmp/menush-preview \
  SSHBOOKMARKS_APPEARANCE=light SSHBOOKMARKS_FAKE_TERMINAL_LOG=/tmp/menush-preview/terminal.log \
  open build/SSH Bookmarks.app
```
