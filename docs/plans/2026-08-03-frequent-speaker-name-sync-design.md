# 常用说话人名称同步修复设计

## 背景

常用说话人名称有两个入口：

- 设置页的“常用说话人”管理。
- 转录说话人重命名时自动记住新名称。

当前设置页只修改 `SettingsViewModel.frequentSpeakerNames` 中的临时副本，直到用户点击“保存设置”才整包写回 `AppSettingsStore`。转录页则直接追加到 `AppSettingsStore`。这会导致两个问题：

1. 设置页新增的名称在保存前无法出现在转录弹窗。
2. 设置页保存时可能用旧副本覆盖转录页刚追加的名称。

## 目标行为

- 常用名称的新增和删除立即持久化，不依赖底部“保存设置”按钮。
- 设置页和转录页共用 `AppSettingsStore` 中的同一份列表。
- 从任意入口添加名称时，保留已有名称并按现有规则规范化、去重。
- 从设置页删除名称时，立即从共享列表移除。
- 其他设置仍然需要点击“保存设置”。

## 数据流

`AppSettingsStore.frequentSpeakerNames` 继续是唯一持久化数据源。

- `SettingsViewModel.addFrequentSpeakerName()` 将新名称与存储中的当前列表合并，立即写回，再用存储结果刷新界面状态。
- `SettingsViewModel.removeFrequentSpeakerName(_:)` 基于存储中的当前列表删除，立即写回，再刷新界面状态。
- `MeetingDetailViewModel.renameSpeaker(_:to:)` 继续通过 `rememberSpeakerName` 追加并去重。
- `SettingsViewModel.save()` 不再写入 `frequentSpeakerNames`，避免临时副本覆盖共享存储。保存完成后从存储重新同步列表。

## 一致性与错误处理

`UserDefaults` 写入在当前架构中是同步操作，无需新增异步任务或错误状态。所有写入都必须以存储层的最新列表为基础，不能以界面中可能过期的副本为基础。现有的空白、40 字符上限和不区分大小写去重规则保持不变。

## 验证

回归测试必须先在现有代码上失败，然后验证：

1. 设置页添加名称后，`AppSettingsStore` 立即包含该名称。
2. 转录页追加名称后，设置页再保存其他选项不会丢失该名称。
3. 设置页与转录页交替添加名称后，最终列表合并、顺序稳定且无重复。
4. 设置页删除名称后立即持久化。
5. 现有设置、转录命名和完整单元测试仍然通过。
