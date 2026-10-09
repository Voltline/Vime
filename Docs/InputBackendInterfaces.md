# Vime 输入后端接口准备

日期：2026-10-09。范围：优化当前共用边界，为未来中文留接口；没有接入 Rime、改变日文转换/模型算法或新增语言设置。版本继续为 1.0。

## 检查结论与本轮落地

原来的主要耦合不是键盘布局，而是 `KeyboardView` 直接读取日文 session 的模式、preedit 和整数候选索引。宿主只接收字符串，并固定把 marked selection 放在末尾。展开候选面板在每次刷新时销毁重建所有按钮。

| 边界 | 当前实现 |
| --- | --- |
| 会话 | `Shared/Input/KeyboardInputSession.swift` 定义主线程 session 协议；键盘接收任意实现，现有日文 `KeyboardSession` 直接遵循 |
| 语言展示 | `KeyboardInputTraits` 提供语言、模式文字、标点、确认键文字、长音键和变体按钮能力；视图不再读取日文 `InputMode` |
| 候选展示 | `CandidatePresentation.swift` 不导入 azooKey；支持一般 annotation 和 backend 选择 token；原日文快照保留完整 azooKey 数据 |
| 选词身份 | token 的 session ID、列表 generation、类别由 session 校验；index 由 backend 解释，UI 不再通过 UIButton.tag 选词 |
| preedit | `KeyboardPreedit` 保存 text 和 UTF-16 selectedRange；系统扩展与 App 试打均已接入，日文默认仍是末尾光标 |
| 异步 commit | 可发送 `KeyboardCommitBatch(hostEpoch, edits)`；视图拒绝已 reset/切换宿主的旧 epoch；日文仍同步返回 edits |
| 控件复用 | 展开面板保留按钮并更新展示，收缩时回收入池；每次 refresh 只取得一次候选栏 presentation 数组 |
| 按需加载 | 未使用过的 worker 在 reset/deinit 时只处理已缓存引擎，不为清空空会话而初始化词典/学习目录 |

候选 token 的 generation 不等同于输入 revision：同一次输入的补充纠错/模型重排，也会生成新列表身份。候选尚未完成时禁止旧列表点选；重排后旧 token 不能误选新位置的另一词。token 是应用内部身份，不是安全凭证。

同一 preedit 文本只有选区变化也会送到宿主；完全相同的状态才去重。`fromUTF8` 显式将 native 字节范围转换为 UIKit 的 UTF-16 范围，拒绝越界、拆分编码和无效选区。不能把 Rime 字节位置直接传给 UIKit。字符串回调保留兼容入口，但生产宿主使用带选区的回调，避免两次发布。

## 未来 backend 接入约定

1. 新建独立中文 session 实现协议；实例注入 `KeyboardView(frame:session:)`。默认构造路径继续是日文。语言 enum 中的 `.chinese` 只是接口值，不代表功能已开放。
2. `type/backspace/chooseCandidate/confirm/reset` 等输入命令必须有序执行。Rime worker 自己维护串行状态机，不能复用日文 worker 的“取消旧转换查询”来丢弃 `process_key`。
3. UI latest-wins 只针对可替换的候选快照。backend 按原生身份选择候选，复制结果后释放 native 内存，不暴露 C 指针。候选分页与完整消费 metadata 在中文 adapter 内实现，不伪造 azooKey 分数。
4. 每次 commit 要么返回 edits，要么异步发送 batch，不能两者都做；同一 epoch 内按命令顺序发送，不能把普通新输入作为丢弃 commit 的理由。异步排队/恰好一次消费仍需由具体 worker 实现，当前接口不替代这些机制。
5. 宿主字段、光标或外部正文变化通过现有 `resetComposition()` 路径递增 epoch；中文路由器切换语言也须使旧 backend 的 epoch 失效。日文跨英文模式切换同样递增 epoch，正常确认后的 composing reset 保留它。
6. `leftContextProvider`/`learningContextProvider` 是宿主实况入口。中文原生学习须按 Rime API 实现，不复制日文 azooKey 的延迟写入逻辑，也不复用日文学习目录。

协议现阶段仍使用当前 `CandidateRankingMode` 设置和日文兼容的可选纠错展示 metadata。中文首版可以选择不启用日文神经排序；中文专属策略、方案、原生生命周期及用户词典操作留在 backend 中扩展。

## 下一批值得做的优化

| 优先级 | 优化 | 原因与边界 |
| --- | --- | --- |
| 高 | 引擎 activate/deactivate 与内存压力策略 | 当前日文模型按需加载，关闭智能功能可释放；未来语言切换还需安全释放非活动模型/词典，避免日中两套常驻。先测实机内存与重新激活延迟 |
| 高 | 按语言隔离设置、学习和资源目录 | 当前设置面向日文；未来中文 schema、模糊音、简繁和用户 DB 需独立，App 试打/扩展同时访问 Rime DB 时明确单写入方 |
| 高 | 原生命令队列与分页 | 当前日文是查询式转换；中文输入、选词、翻页与取 commit 必须作为有序事务实现 |
| 中 | 按语言定义符号和滑动快捷输入 | 本轮提取标点和 composition 符号能力；字母上滑映射、数字符号行和符号分类仍保留现有内容，中文接入时再制定策略 |
| 中 | 中文质量与资源可复现构建 | 独立固定词库、引擎与小 corpus；日文 script/exact-reading 特征及 v2.1 模型不直接用于中文。沿用资源 manifest/preflight，先保证 Cloud 不缺资源 |

本轮不更改 Core ML compute units、模型结构或权重，不增加持久化写频率，也未引入未经实机验证的延迟/功耗收益声明。按钮复用仅说明减少控件创建，不代表整体输入耗时已有量化提升。

## 验证范围

新增 `KeyboardInputBoundaryTests` 四项：UTF-8/UTF-16 选区和宿主去重、同 revision 重排/跨 session 的过期选词拒绝、独立测试 backend 的语言与 annotation/原生选择身份/面板按钮复用、异步 commit 顺序与旧宿主 epoch 拒绝。

另外只选与本轮边界相关的既有日文检查：确认/长音、未完成 Roman 和 kana preedit、marked text 周边正文、候选确认/英文切换、学习宿主回执、补充纠错的选词保护/metadata 展示、无宿主时的扩展生命周期。原纠错测试的快照比较更新为区分 engine presentation 和带 token 的 UI presentation，同时验证选中后 token 不改变。未跑完整模型 benchmark 或全量测试。

结果：12 项不同的定向测试最终通过；Release 模拟器 App、扩展与测试 target 编译通过。新增选区测试发现 UTF-16 surrogate 中间位置未被普通范围转换拒绝，修复后通过。构建仍有既有 AppIntents 提取提示，以及主 App build 10/扩展 build 2 不一致提示；本轮未调整发布编号，营销版本仍为 1.0。
