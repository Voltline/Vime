# 用户词典

主 App → 设置 → 输入与联想 → 用户词典，可以增加、编辑、删除词语或短语，也可导入 / 导出 Vime JSON。读音可填写完整罗马字或假名，保存时规范化为片假名。

- **词语（word）**：通过 azooKey 的动态 words 通道参与转换、分段和预测。
- **短语（shortcut）**：通过 shortcuts 通道，仅在完整读音匹配时提供。

注册词进入统一排序，保留用户词典来源及独立的预测状态，不固定插入候选位置。删除条目不会同时清除已学到的选择记忆。

## 交换格式

```json
{
  "version": 1,
  "entries": [
    {
      "id": "71D7B113-CFA0-4896-888E-AED01D7161E0",
      "reading": "トウキョウ",
      "surface": "東京",
      "kind": "word"
    }
  ]
}
```

最多 1,024 条，导入文件不超过 1 MiB。规范化读音为 1–64 个假名，surface 为 1–128 字符且不得含控制字符；未完成的 Roman suffix 不接受为词条。kind 为 `word` 或 `shortcut`。

导入先验证整个文件，再合并并去重，重复 UUID 会重建。非法数据或不支持的版本不会覆盖现有词典。目前不直接导入 Rime / SKK 格式。

## 同步

数据保存在 App Group 的 `Vime/UserDictionary.json`。App 原子保存后更新共享 revision，worker 在初次使用或 revision 改变时重载；普通按键不反复读文件。继续输入或重新打开键盘后，候选使用新词典。

共享读取需要完全访问。共享容器不可用时使用本地 Application Support，这不保证 App 与扩展仍共享数据。读取失败保留最后一个合法 snapshot。当前编辑入口在主 App，词典文件没有多写入方的事务合并。

实现见 [JapaneseUserDictionary.swift](../../Shared/Candidates/JapaneseUserDictionary.swift)。
