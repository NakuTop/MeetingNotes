# Notion 新归档会议置顶 · 1.3.7（build 35）

验证日期：2026-10-30。

首次归档会议时，MeetingNotes 在创建 Notion 子页面的请求中指定
`"position": {"type": "page_start"}`，将新记录插入父页面最前面。
连续归档的会议按新建顺序倒序显示，父页面继续使用一列会议标题。
原有 Notion Token 与父页面链接可继续使用。

再次归档已存在的会议仍更新原页面并复用归档检查点，不会新建副本，
也不会改变该页面在父页面中的位置。

## 自动验证

使用项目的后台测试脚本运行 NotionClientTests、NotionArchiveServiceTests
及 UpdateReleasePolicyTests，71 项测试通过，0 失败。
覆盖新建请求中的父页面、置顶参数与正文追加，以及现有归档的复用、
失败恢复和版本身份一致性。

```sh
bash Scripts/test_in_background.sh \
  -only-testing:MeetingNotesTests/NotionClientTests \
  -only-testing:MeetingNotesTests/NotionArchiveServiceTests \
  -only-testing:MeetingNotesTests/UpdateReleasePolicyTests
```

Release 构建与 DMG 打包完成，`PACKAGE_VALIDATION=PASS`。
应用身份为 `com.shenminghao.MeetingNotes`，版本 1.3.7 / 35，
使用现有固定本地证书签名。包内应用的签名、版本、沙盒、音频和网络
权限，以及 Sparkle 组件校验通过。该安装包未作 Developer ID 公证。

## 待手动验收

安装候选版本后，首次归档一场尚未上传的会议，确认新页面出现在父页面
列表顶部；再归档同一会议，确认仍更新原页面且没有新增副本。
自动测试使用模拟 HTTP 响应，未使用真实 Token 上传会议。
本次未运行 UI 自动化或交互式浮窗测试。
