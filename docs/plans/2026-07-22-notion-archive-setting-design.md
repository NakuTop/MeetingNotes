# Notion 归档开关设计

## 目标

在设置中增加“总结后自动归档到 Notion”选项。该选项默认开启，以保持现有用户行为；关闭后，会议总结只保存在 MeetingNotes 本地，不读取 Notion 凭据，也不发起 Notion 网络请求。

## 方案选择

采用应用级持久化布尔开关，不修改会议数据库结构。

- 优点：改动范围小，不需要迁移现有会议数据，旧用户升级后行为不变。
- 关闭开关只改变总结后的归档行为，不删除已经保存的 Notion Token 或父页面链接。
- 重新开启后，可以直接把已经存在的本地总结归档到 Notion，不重复调用 DeepSeek。

未采用以下方案：

- 为每场会议保存独立归档目标：控制更细，但当前需求不需要数据库迁移和额外状态。
- 仅在界面隐藏 Notion 功能：无法保证底层流程不会继续访问 Notion。

## 设置与界面

`AppSettingsStore` 新增持久化布尔值 `isNotionArchivingEnabled`，未保存时返回 `true`。

`SettingsViewModel` 在加载时读取该值，在保存设置时写回。设置页 Notion 区域顶部显示开关：

- 开启：总结后自动归档到 Notion。
- 关闭：显示说明“总结只保存在本软件中，不会连接 Notion”。

Notion Token、父页面链接和连接测试仍可见，关闭开关不会清除已有配置，方便以后重新开启。

会议详情页根据开关调整操作文案：

- 开启且尚无总结：“总结并归档”。
- 关闭且尚无总结：“生成总结”。
- 关闭且本地总结已经生成：“已保存到本机”，不再触发归档。
- 重新开启且已有本地总结：“归档到 Notion”，直接使用现有总结。

`summaryReady` 的展示文案统一为“总结完成”，避免在关闭 Notion 时错误显示“待归档”。

## 数据流

1. 用户结束会议并点击主操作按钮。
2. 用例照常验证最终转录和 DeepSeek API Key。
3. DeepSeek 总结成功后，先把总结、建议标题和 `summaryReady` 状态保存到本地。
4. 若 Notion 归档开关关闭，用例在本地保存完成后返回。
5. 若开关开启，用例继续验证 Notion Token 与父页面链接并执行归档。
6. 已有本地总结时，关闭开关不会调用 DeepSeek 或 Notion；重新开启后只执行 Notion 归档。

## 错误处理

- 本地总结失败仍返回本地持久化错误。
- 开关关闭时，缺少 Notion Token 或页面链接不构成错误。
- 开关开启时，沿用现有 Notion 配置错误和归档失败提示。
- Notion 归档失败后仍保留本地总结，用户可直接重试。

## 测试

- `AppSettingsStoreTests`：验证默认开启以及跨实例保存关闭状态。
- `SettingsViewModelTests`：验证开关加载和保存。
- `SummarizeAndArchiveUseCaseTests`：验证关闭时只保存本地总结、不调用 Notion、不要求 Notion 配置；重新开启后归档已有总结且不重复调用 DeepSeek。
- `MeetingDetailViewModelTests`：验证按钮在开启、关闭和已有总结时的文案与可用状态。
- 最后运行相关单元测试、完整测试套件和 Release 构建。
