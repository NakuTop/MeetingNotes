# MeetingNotes 应用内更新发布

本文档定义 Sparkle 2.9.2 、GitHub Release 和 GitHub Pages appcast 的
唯一发布路径。普通 branch push 和 pull request 不会发布任何内容；
`.github/workflows/publish-update.yml` 只能通过 GitHub Actions 的
**Run workflow** 手动触发。

## 一次性准备

1. 在 GitHub Pages 中选择 `gh-pages` branch 的根目录作为发布源。
2. 创建 `gh-pages` branch，至少包含 `.nojekyll`。工作流会在完整
   验证后只修改被选中的文件：
   - Beta：`updates/beta/appcast.xml`
   - 正式版：`updates/stable/appcast.xml`
3. 创建受保护的 GitHub Actions environment `release`，建议开启人工
   approval。
4. 配置下列 repository 或 `release` environment secrets：

   - `DEVELOPER_ID_P12_BASE64`
   - `DEVELOPER_ID_P12_PASSWORD`
   - `DEVELOPMENT_TEAM`
   - `APPLE_NOTARY_KEY_ID`
   - `APPLE_NOTARY_ISSUER_ID`
   - `APPLE_NOTARY_PRIVATE_KEY`
   - `SPARKLE_ED_PRIVATE_KEY`

缺少任何一项时，工作流必须在构建、创建 Release 和更改 feed
之前失败。

## Sparkle EdDSA 密钥

MeetingNotes 使用独立账户 `NakuTop.MeetingNotes`。私钥主本保存在
macOS 登录钥匙串，另一份导出备份必须位于仓库外的受保护
位置，文件权限必须为 `600`。私钥不得出现在 Git、日志、
appcast、DMG 或聊天记录中。

GitHub secret `SPARKLE_ED_PRIVATE_KEY` 的内容是 Sparkle `generate_keys -x`
导出文件的原始内容。发布工作流通过 stdin 把它传给
`generate_appcast --ed-key-file -`，不在仓库内生成私钥文件。

丢失私钥后无法为现有安装用户生成可信任的更新。轮换密钥时：

1. 保留旧私钥，不要删除或覆盖。
2. 用旧私钥发布一个“桥接版”，桥接版应用内嵌新公钥。
3. 确认用户已完成桥接版更新，再改用新私钥签名后续版本。

不得直接用新密钥覆盖公钥并跳过桥接版。

## 首个支持应用内更新的版本

旧版 MeetingNotes 没有 Sparkle，因此首个内嵌 Sparkle 的版本仍需
用户从 GitHub Release 手动下载 DMG 并安装一次。从该版本开始，
后续版本才能使用“检查更新”。

发布前必须用实际 Developer ID 和 Apple 公证生成这个首发版本。
本地 ad-hoc DMG 仅可测试，不能放入 appcast。

## 发布 Beta

1. 确认 Beta 的版本、build、bundle ID 和人工验收已通过。
2. 在 Actions 中运行 **Publish signed in-app update**。
3. `channel` 选择 `beta`，输入与源码一致的 version/build。
4. 确认文本必须精确为 `PUBLISH beta VERSION (BUILD)`。
5. 工作流只能创建 GitHub **prerelease**，并只能修改 Beta
   appcast。

## 发布正式版

1. 正式版必须完成独立回归、签名、公证和人工验收。
2. `channel` 选择 `stable`。
3. 确认文本必须精确为 `PUBLISH stable VERSION (BUILD)`。
4. 工作流创建非 prerelease GitHub Release，且只修改 stable
   appcast。

Beta feed 和 stable feed 不得相互拷贝，也不得在同一次运行中
同时更改。

## 发布前的强制验证

`Scripts/validate_update_release.sh` 必须在创建 Release 和 push `gh-pages`
之前成功。它验证：

- DMG 完整性、Developer ID、secure timestamp、hardened runtime、
  Gatekeeper、公证与 stapling；
- 应用身份、麦克风隐私字符串、沙盒/音频/网络权限及 Sparkle
  XPC Mach lookup；
- Sparkle framework、Updater、Autoupdate、Downloader 和 Installer 的
  嵌套签名；
- appcast 的 URL、字节长度、version/build、arm64 限制与 EdDSA
  签名字段。

`build_and_package.sh` 输出 `PUBLISHABLE=NO` 时，任何工作流都不得
创建 Release 或更改 feed。

## 撤回错误更新

1. 立即停止新的发布工作流。
2. 在 `gh-pages` 上只从受影响的 Beta 或 stable appcast 删除错误
   `<item>`，保留另一通道不变。
3. 如果 feed 已开启整体签名，必须用原 EdDSA 私钥重新生成/
   签名 appcast，不得手工修改后直接上传。
4. 等 GitHub Pages 上的 feed 已不再引用错误文件后，再决定是否
   撤回或删除 GitHub Release 资产。
5. 优先发布 build 号更高的修正版，不得用同一 build 覆盖。

## 降级与手动备用路径

当 GitHub Pages、Sparkle 或 appcast 异常时，应用内更新可以暂停，但
已验证的 GitHub Release 页面是唯一手动下载备用入口。不得上传
ad-hoc、未公证或身份不匹配的 DMG 作为临时替代。
