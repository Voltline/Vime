# 输入后端接口

当前后端是日语 azooKey。语言接口已为其他后端保留扩展点，`.chinese` 枚举值不代表已有中文输入或 Rime 实现。

| 接口 | 职责 |
| --- | --- |
| `KeyboardInputSession` | 主线程输入命令、preedit、候选及文档 edits |
| `KeyboardInputTraits` | 语言标签、标点、确认文字和可用模式能力 |
| `CandidatePresentation` | 不依赖 azooKey 的展示、annotation 与选择 token |
| `KeyboardPreedit` | 文字与 UTF-16 选区 |
| `KeyboardCommitBatch` | 带 host epoch 的异步文档提交 |

`KeyboardView(frame:session:)` 可注入实现；默认构造仍使用日语 `KeyboardSession`。原生 payload、分页、消费范围、词典和资源生命周期留在具体后端，UI 不解释底层原生候选索引。

## 接入约定

1. 输入、退格、选词、翻页、确认和 reset 必须按命令顺序执行。可以取消过期候选查询，不能取消已经产生提交的输入事务。
2. 候选 token 绑定 session、列表 generation 与类别。快照在后台完成后复制成稳定数据，不向 UI 暴露 C 指针或可失效的原生内存。
3. 原生选区按编码转换为 UTF-16，拒绝无效边界。原生消费计数不能用 surface 长度代替。
4. 每次提交同步返回 edits 或异步发送 batch，二者互斥；具体 worker 保证有序、恰好一次消费。接口本身不实现事务队列。
5. 字段、光标、外部正文和语言切换使旧 host epoch 失效。普通候选 refresh 与提交后的组合清空须区分。
6. 使用 `leftContextProvider` / `learningContextProvider` 读取真实宿主上下文。学习、设置和资源目录按语言隔离，原生学习按该引擎 API 实现。

现有排序模式和部分纠错展示 metadata 仍具有日语背景；其他后端应明确哪些功能适用，不能直接复用日语 LM、词典分数或 script 特征。

接口定义：[KeyboardInputSession.swift](../../Shared/Input/KeyboardInputSession.swift)、[CandidatePresentation.swift](../../Shared/Candidates/CandidatePresentation.swift)、[KeyboardPreedit.swift](../../Shared/Host/KeyboardPreedit.swift)。
