# 设计 v2：同步、终端回退、凭据

本文只定方案。代码只做了 B3（终端按版本选择启动方式，以及首选终端缺失时的回退）。其余不在本轮实现。

和 `docs/design.md` 的关系：存储仍是本机 `hosts.json` + 钥匙串；终端调起仍以该文档 §4 为准。这里补充换机、多机和「新 Mac 上终端没装」时怎么处理。

## 遗留问题

代码签名暂缓，是已知开放项，本轮不实施。现状是 ad-hoc 签名（每次构建身份都会变，换到其他 Mac 时 Gatekeeper 拦截）。可选：自签证书（本机钥匙串和登录项的身份稳定，换机仍会警告）；Developer ID + 公证（Apple Developer Program，$99/年，可去掉警告）。`release.yml` 已留有 `MACOS_CERT_P12_BASE64`、`MACOS_CERT_PASSWORD`、`MACOS_SIGN_IDENTITY`、`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD` 占位，未配置时继续 ad-hoc。

## B2 站点配置的 iCloud 同步

只同步站点与分组，不同步密码、口令或私钥。三选一：

| 方案 | 要什么账号 | 未沙盒时的权限 | 容量与冲突 | 结论 |
| --- | --- | --- | --- | --- |
| CloudKit | Apple Developer Program、iCloud 容器、描述文件。未沙盒也要 entitlement | `com.apple.developer.icloud-services`、容器 id | 按记录冲突（`serverRecordChanged`），适合按 host id 合并 | 有开发者账号后再做。现在不做前置 |
| iCloud Drive 上的一个文件 | 用户登录了 iCloud 即可 | 不需要额外 entitlement。路径在 `~/Library/Mobile Documents/com~apple~CloudDocs/` 下，例如 `MenuSSH/menu-ssh-sync.json` | 整文件同步。两边同时写会变成「文件 2」副本 | 个人使用的推荐路径 |
| `NSUbiquitousKeyValueStore` | 同样要开发者账号和 `com.apple.developer.ubiquity-kvstore-identifier` | 键值存储，上限约 1MB，不适合当站点主库 | 不采用 |

推荐先把同步文件放在 iCloud Drive（或用户选的任意文件夹，见 B4）。CloudKit 留到有开发者账号、并且需要按字段合并的时候。iCloud Drive 没有记录级冲突 API，必须自己合并，并在写入时用 `NSFileCoordinator`，读端用 file presenter，减少系统复制出「文件 2」。

合并规则（iCloud Drive 与 B4 共用一套）：

- 单位是 host id / group id，不是整文件覆盖。
- 同一 id 以 `updatedAt` 较新的一边为准（last-write-wins）。
- 删除用墓碑 `{ id, deletedAt }`。没有墓碑的话，另一台机器上的旧副本会把已删站点复活。分组同样处理。`HostGroup` 今天没有 `updatedAt`，做同步文件时要补上。
- 文件带 `schemaVersion`。读到更高版本就拒绝写入，避免新字段被旧客户端抹掉。
- 两边 `updatedAt` 相等时如何取舍，见开放问题。
- 钥匙串条目永不进这个文件。

## B3 终端启动方式与缺失回退（已实现）

启动方式只跟 Ghostty 的版本走。Terminal.app 和 iTerm2 始终用 AppleScript，传入的版本号被忽略。iTerm2 的 `create window / tab with default profile` 覆盖目前的公开版本，不为它发明第二套路径。

| 终端 | 条件 | 方式 |
| --- | --- | --- |
| Terminal.app | 任意版本，含未知 | AppleScript `do script` |
| iTerm2 | 任意版本，含未知 | AppleScript `create window/tab with default profile` + `write text` |
| Ghostty | `CFBundleShortVersionString` ≥ 1.3.0 | AppleScript（`initial input`） |
| Ghostty | &lt; 1.3.0，或读不到版本 | `/usr/bin/open -na Ghostty --args -e` |

版本比较在 `TerminalLaunchPlanner.mechanism(for:version:)`。`plan()` 的 Ghostty 分支只问这一个结果。

新 Mac 上，设置里选的终端可能没装。本次会话的查找顺序是：配置的终端 → 下一个已安装的 → Terminal.app。顺序表是 iTerm2、Ghostty、Terminal.app。Terminal.app 即使不在「已安装」集合里也使用（系统自带）。

- 配置的就是 Terminal，或配置的终端已安装：照原样打开，没有提示。
- 配置的没装：用顺序表里下一个已安装的；都没有就用 Terminal.app。两者都给出提示。
- 提示不改 `SettingsStore.terminal`，只影响这一次连接。
- 文案：「未安装 %@，已改在 %@ 中打开本次会话。」菜单栏面板和站点窗口用橙色信息行显示。有提示时不自动关闭面板。
- 自动化被拒绝（-1743）时，错误里的名字是真正拿去执行脚本的那个终端。

单测在 `MenuSSHCore`：`TerminalLaunchPlannerTests`（除 Ghostty 外版本不影响路径）、`TerminalFallbackTests`（已安装则保持、缺 Ghostty 且有 iTerm 则用 iTerm、缺 iTerm 且有 Ghostty 则用 Ghostty、都没有则 Terminal 并提示、首选 Terminal 即使安装集合为空也不提示）。

## B4 便携同步文件与本机凭据（只设计）

同步文件是版本化 JSON，建议名 `menu-ssh-sync.json`。内容是 hosts 和 groups，字段与 `hosts.json` 对齐，但不含密码、口令、私钥材料。用户指定一个文件夹（iCloud Drive、Dropbox 或任意目录）。文件夹用 security-scoped bookmark 记在 UserDefaults；iCloud Drive 只是这个文件夹的一种选法，合并算法与 B2 相同，不另写一套。

每台机器的密码仍只留在本机钥匙串：

- 当前实现是 `kSecAttrAccessibleWhenUnlocked`。做到这一步时改为 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，并设 `kSecAttrSynchronizable = false`。
- 只在连接时读取。通过 `SSH_ASKPASS` 指向本应用（`--askpass <hostID>`），由助手从钥匙串取出后交给 ssh。不放进 argv，也不进同步文件。
- 换机器后密码要重新输入。文件里只保留「这台主机用密码登录」这个事实，不保留秘密。

新建站点时优先建议公钥，密码是次要路径（仍属 M3）：

- 扫描 `~/.ssh/*.pub`。已有 `id_ed25519.pub` 就把它当默认。
- 没有密钥时，说明如何执行 `ssh-keygen -t ed25519`，以及用 `ssh-copy-id` 装到服务器。应用只给出命令和选文件，不在这一步代跑会改 `~/.ssh` 的命令，除非用户明确确认。
- 密码登录留在编辑器里，作为公钥不可用时的备选，并继续标明秘密只进钥匙串。

## 阶段

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 0 | 终端按版本选路径；首选缺失时回退并提示，不改已存偏好 | 本轮已做 |
| 1 | 同步文件、文件夹选择、按 id / `updatedAt` / 墓碑合并。不含密码 | 未做 |
| 2 | `SSH_ASKPASS`、本机限定的钥匙串、新建站点时的公钥引导 | 未做 |
| 3 | 代码签名与公证 | 遗留，见文首 |
| 4 | 有开发者账号后再评估 CloudKit | 未做 |

## 开放问题

1. 同步文件夹是第一次启动就问，还是默认放到 iCloud Drive 的 `MenuSSH/`（未登录 iCloud 时再改问）？
2. 墓碑保留多久？一直留着最安全，文件会随删除历史变长；按时间裁剪可能让一台长期离线的机器把站点复活。
3. 回退是否写回终端偏好？本轮定为只影响当前会话。若改成写回，用户换回原终端后要自己再选一次。
4. 自动合并是静默完成，还是给一行摘要（新增、覆盖、因墓碑丢弃各多少）？
5. 分组继承和端口转发要不要进同步 schema。模型里已有 `parentID` 和 `portForwards`，UI 还没做全。同步文件若先省略，旧客户端会把它们抹掉。
6. 两边 `updatedAt` 相等时用设备 id 打破平局，还是保留两边并让用户选？`HostGroup` 补 `updatedAt` 之前，分组只能整表按 id 对齐，重名分组算两条。
