<!-- 标题用一句话概括改动（英文、约定式前缀可选），例如：Round 5: keyboard tunnel toggle; fix sync row layout -->
<!-- 目标分支必须是 develop。develop → main 只在 owner 明确说要发版时进行。 -->

## Summary / 概要

<!-- 2–3 行：做了什么、为什么。 -->

## Changes / 改动

<!-- 按主题分组；修复类按严重度（P0 / P1 / P2）列出。只写这个 PR 里真实存在的改动。 -->

-

## Tests / 测试

<!-- 新增或更新了哪些测试；CI 运行链接。 -->

- 新增 / 更新：
- CI：<!-- https://github.com/shellwalker/ssh-bookmarks/actions/runs/... -->

## Screenshots / 截图

<!-- UI 改动必填。截图来自 CI artifact `ui-screenshots`（运行页面底部）。 -->

## Not in this PR / 暂不包含

-

## Needs real-Mac verification / 需要真机验证

<!-- CI 覆盖不到的行为：睡眠唤醒、iCloud 实时同步、钥匙串弹窗、终端自动化授权等。 -->

-

## Notes / 备注

- 只合并到 `develop`；合并后删除源分支。

## Checklist

- [ ] CI 全绿（`gh pr checks <PR> --watch`）
- [ ] 测试已新增或更新
- [ ] 新增界面文字同时有 zh-Hans 和 en（`Resources/*.lproj/Localizable.strings`）
- [ ] 日志、提交、PR 描述里没有令牌、密码或其他密钥
- [ ] 目标分支是 `develop`
- [ ] 合并后删除源分支
- [ ] UI 改动附了截图
