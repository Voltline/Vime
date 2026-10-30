# 用户词典

主 App → 设置 → 用户词典（也可从状态卡的「用户词典」进入），可以增加、编辑、删除词语或短语，也可导入其他输入法的词典，导出为 Vime JSON 或 Google 日本語入力 文本。读音可填写完整罗马字或假名，保存时规范化为片假名。

- **词语（word）**：通过 azooKey 的动态 words 通道参与转换、分段和预测。
- **短语（shortcut）**：通过 shortcuts 通道，仅在完整读音匹配时提供。

注册词进入统一排序，保留用户词典来源及独立的预测状态，不固定插入候选位置。删除条目不会同时清除已学到的选择记忆。

## iOS 文本替换

「用户词典 → 使用 iOS 文本替换」默认开启。键盘显示时通过 `requestSupplementaryLexicon` 读取系统「设置 → 通用 → 键盘 → 文本替换」，与输入码相同的条目（如联系人姓名）被忽略：

- 输入码为假名的条目按短语处理，完整读音匹配时出现在日语候选中。
- 输入码为英文字母的条目在英文模式下匹配光标前的单词（不分大小写），候选栏显示替换短语，点按替换该单词并补一个空格。

这些条目只保存在键盘进程的内存中，不写入 `UserDictionary.json`，也不会导出；关闭开关后立即从候选中移除。

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

导入先验证整个文件，再合并并去重，重复 UUID 会重建。非法数据或不支持的版本不会覆盖现有词典。

## 其他输入法的词典

导入时按内容识别格式（文件不超过 4 MiB），实现见 [JapaneseUserDictionaryInterchange.swift](../../Shared/Candidates/Dictionary/JapaneseUserDictionaryInterchange.swift)：

- **制表符分隔文本**：Google 日本語入力 / Mozc、Microsoft IME、ATOK 导出的「读音⇥词语⇥词性⇥…」。编码可为 UTF-8、带 BOM 的 UTF-16 或 Shift_JIS；以 `!` 开头的文件头跳过。词性为「短縮よみ / 短縮読み」的导入为短语，「抑制単語」跳过，其余导入为词语。
- **macOS 用户词典**：「文本替换」拖出的 plist，`shortcut` 为读音，`phrase` 为词语，导入为词语。

读音不是假名（例如英文缩写）或词语不合法的条目逐条跳过，完成后显示添加与跳过的条数；合并后的总数仍受 1,024 条限制，超出则整个导入不生效。

「导出为 Google 日本語入力 文本」写出 Mozc 格式（UTF-8，平假名读音，词语为「固有名詞」、短语为「短縮よみ」），可在 Google 日本語入力的辞書ツール中导入。Vime JSON 才能完整还原条目 ID。目前不直接导入 Rime / SKK 格式。

## 同步

数据保存在 App Group 的 `Vime/UserDictionary.json`。App 原子保存后更新共享 revision，worker 在初次使用或 revision 改变时重载；普通按键不反复读文件。继续输入或重新打开键盘后，候选使用新词典。

共享读取需要完全访问。共享容器不可用时使用本地 Application Support，这不保证 App 与扩展仍共享数据。读取失败保留最后一个合法 snapshot。当前编辑入口在主 App，词典文件没有多写入方的事务合并。

实现见 [JapaneseUserDictionary.swift](../../Shared/Candidates/Dictionary/JapaneseUserDictionary.swift)。
