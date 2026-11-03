# 第三轮：快捷隧道与诊断日志

产品名是 **SSH Bookmarks**。本轮决定都已按下面实现。

## 快捷隧道

- 面板只开关本地 `-L`。`-D` 和 `-R` 仍保存在站点里，打开终端时带上，但不做面板开关。
- 新字段 `quickToggle`、`reconnect` 默认否。旧转发不会突然变成后台进程。
- 同步和本机库 schema 写 **v3**，仍读 v1 / v2。写出当前版本，旧客户端看到更高版本会拒绝覆盖。
- 隧道 argv：`ssh -N`，然后 `ExitOnForwardFailure=yes`、`StrictHostKeyChecking=yes`，非密码登录再加 `BatchMode=yes`，接着是用户、端口、密钥、`-J`、这一条 `-L`、`ForwardAgent`、用户的 `-o`，最后才是 `ServerAliveInterval=15` 和 `ServerAliveCountMax=3`。OpenSSH 取第一次出现的值，所以主机密钥检查不能被用户改成 `no`，keepalive 可以被用户自己的值覆盖。
- 密码登录不加 `BatchMode`。askpass 仍用一次性令牌，脚本写 `SSHBOOKMARKS_ASKPASS_TOKEN`，旧名 `MENUSH_ASKPASS_TOKEN` 仍接受。
- 自动重连默认关。打开后最多重试 5 次，间隔 2、4、8、16、30 秒。同时最多 8 条。端口占用、认证失败、主机密钥、特权端口、找不到 ssh 不重连。
- 主机密钥失败时提供「在终端中打开一次以信任」。应用不代答 yes。
- 菜单栏图标在数量大于 0 时显示数字，设置里可以关掉。界面测试点不开菜单栏，同一数字出现在面板的 `panel.tunnelBadge`。
- 界面测试不启动真 ssh。空闲端口记为运行；端口已被占用显示冲突；`SSHBOOKMARKS_FAKE_TUNNEL_FAILURE=hostKey`（别名 `MENUSH_FAKE_TUNNEL_FAILURE`）显示主机密钥错误。

## 诊断

- `os.Logger` 子系统 `com.shellwalker.SSHBookmarks`，始终记录。主机名和用户名用 privacy private。
- 文件默认关。路径是 `~/Library/Application Support/SSH Bookmarks/Logs/`。保留 7 天，合计约 10 MiB，最多 5 个文件。目录 0700，文件 0600。
- 密码、令牌、askpass 路径和私钥始终打码。主机名和用户名默认打码。
- 设置里「诊断」在「关于」之前。关于页有版本（开发版 / 正式版）、构建号和口号「菜单栏里的 SSH 书签」/ “SSH bookmarks in your menu bar.”。侧栏底部也有这句口号。
- 导出 ZIP 先脱敏再打包。iCloud 同步目录是 `SSH Bookmarks`。旧的 `MenuSSH` 目录在首次启动时搬过来。
