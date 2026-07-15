# Notion UUID 小写规范化设计

日期：2026-07-15

## 问题与证据

应用使用正确的 Notion Token 调用 `/v1/users/me` 能返回 200，目标页面、连接身份与页面共享关系也已核对。相同目标页面 ID 使用小写路径请求时返回 200，而应用通过 Swift `UUID.uuidString` 生成的大写路径返回 404。

因此，本次修复聚焦本地请求序列化：Notion API 请求中的 UUID 统一使用小写形式。

## 设计决策

在 `NotionClient` 的请求边界集中规范化 UUID，而不改变上层页面链接解析结果：

- 测试连接时，`GET /v1/pages/{page_id}` 中的 `page_id` 使用小写 UUID。
- 创建归档页面时，请求 JSON 的 `parent.page_id` 使用小写 UUID。
- 由 Notion 服务端返回并以 `String` 保存的页面 ID 不做额外改写，避免影响后续追加内容请求。
- 链接解析器继续返回强类型 `UUID`，错误提示与权限判断逻辑保持不变。

采用单一私有序列化辅助方法，避免不同调用点再次出现大小写差异。

## 测试策略

1. 先修改 `NotionClientTests`，断言测试连接 URL 中的页面 ID 为小写；在生产代码未修改前应失败。
2. 断言创建页面请求体中的 `parent.page_id` 为小写；在生产代码未修改前应失败。
3. 最小化修改 `NotionClient` 后运行定向测试、完整单元测试和签名应用构建。
4. 启动新构建进行真实连接验收，确认目标页面测试不再因大写 UUID 返回 404。

## 安全与兼容性

- 不记录、不输出 DeepSeek Key 或 Notion Token。
- 不改变 Keychain 存储、Notion API 版本、请求头或页面权限配置。
- 仅改变 UUID 的文本大小写，页面 ID 的值不变。
