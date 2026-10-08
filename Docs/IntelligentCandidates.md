# Vime 智能候选改造交付记录

日期：2026-10-05。事实来源是开始执行时的本地工作区，包括已有未提交修改；未使用 GitHub 工作区替代本地代码。依赖为本地解析出的 azooKey revision `d59a28e4c7ca049aef04f29a91eae9677a7753f2`。

## 1. 排序异常的真实根因

先保留行为，分别 dump `.manualMix`、`.autoMix` 的 `mainResults` / `predictionResults` 和旧 Vime presentation。完整结果见 `Artifacts/intelligent-candidates-baseline.json`。

`yo-roppa` 的 manualMix 原始 conversion 第一名已经是「ヨーロッパ」；autoMix 将预测扩展「ヨーロッパ人」「ヨーロッパ史」放在它前面，原词是第三名。Vime 随后做 exact/full grouping，但固定片假名插入逻辑用 surface + consumption 去重，删掉了**真正的词典候选**，再把同字面的人工 script candidate 插到 index 3。这同时破坏排名和可学习 Candidate 的身份。因此问题由 engine 混合策略与 Vime presentation 共同形成，不能归咎于原始 conversion。

旧脚本插入也会让其他标准片假名词发生相同问题。新管线不按来源数组的拼接顺序展示，也不预留脚本位置。

## 2. Candidate Model

`Shared/Candidates/CandidateSnapshot.swift` 保留原始 azooKey `Candidate`，直到选择反馈给 converter。包含：surface、ruby/normalized reading、source、原始 composingCount、engine/full selection consumption、exact reading、prediction 状态、engine value/rank、script type、learning eligibility、learned evidence、correction metadata、revision、剩余 composing text、评分 features。

来源为 `conversion`、`prediction`、`scriptVariant`、`readingAlternative`、`typoCorrection`。`readingAlternative` 承接原有 n 边界解释；没有重新修改稳定的 RomajiConverter。

UI 从 snapshot 派生字符串和 `CandidatePresentation`。同字面不同 consumption 的部分确认候选仍是不同对象；纠错的 originalInput / correctedInput / correctedReading 不会随字符串化丢失。

## 3. Unified Reranker

`Shared/Candidates/CandidateReranker.swift` 集中管理权重。所有候选先进入同一池，再评分、去重、确定排序、截取展示列表。主要 features：

| Feature | 策略 |
| --- | --- |
| EngineScore | 原始顺序 `-2 × log1p(rank)`，加 reading 长度归一化后饱和的 engine value；不同来源 raw value 不直接当统一概率 |
| ExactReading | full + exact + 真实 lexical evidence 加 8；无词典依据的 fallback 不享受此项 |
| FullConsumption | 加 3，保留 engine 消费与用户选择消费两种信息 |
| PredictionOverrun | 已完成读音的非 exact prediction 减 4；未完成 Roman suffix 不用此罚分 |
| ScriptConsistency | 纯假名混用且候选池有同表记的词典全片假名证据时减 4；汉字＋假名不罚 |
| Continuity | 上次实际显示的 Top1 与增长输入兼容时最多加 0.8；不能冻结错误候选 |
| ScriptAvailability | 通用脚本候选加 2，未完成 suffix 减 3；片假名模式是显式偏好加分，不是固定 slot |
| TypoCost | 错误通道成本负分；只有通过词典增益门槛的纠错获得证据加分 |
| Context | 词典 CC/MM 连接增益乘 0.25，限制在 ±2.5 |
| UserLearning | 已嵌入 engine value/order，额外评分保持 0，避免重复计数；diagnostics 单独标记 learned |

同 surface + consumption 去重时优先保留词典 Candidate；普通 exact lexical 不被同字面的纠错替换。最终 tie break 明确且可重复。纠错准入政策也集中在 `CandidateCorrectionPolicy`。

## 4. 前后候选对比

以下为未学习、无上下文的独立请求，`-` 按实际长音键转换为 `ー`。

| 输入 | 旧 Vime 前四项 | 新 Vime 前四项 |
| --- | --- | --- |
| yo-r | ヨーロッパ / ヨーロッパ人 / yor / ヨーr | ヨーロッパ / よーr / ヨーr / ヨーロッパ人 |
| yo-roppa | europe / よーろっぱ / ヨーロッパ人 / ヨーロッパ | ヨーロッパ / europe / よーろっぱ / ヨーロッパ人 |
| yo-roppajin | — | ヨーロッパ人 / よーろっぱじn / ヨーロッパジn / ヨーロッパ時n |
| be-to-ben | ベートーベン / べートーベn / ベーとーベn / ベートーベn | ベートーベン / べーとーべn / ベートーベn / べートーベn |
| shitsuka | 質か / 失か / 静か / シツカ | 質か / 静か（纠错） / 失か / しずか（纠错） |

`yo-roppa` 的 Top1 现在保留真实 conversion、exact/full/learning evidence。逐字输入测试覆盖 `yo-r → yo-roppa → yo-roppajin`，最后自然让「ヨーロッパ人」升到第一。

## 5. ベートーベン与脚本策略

末尾单个 n 仍按现有规则保留预测；没有改动基础输入。额外用 `be-to-benn` 检查读音完全结束的情况：「ベートーベン」第一，「べートーベン」第六。通用 mixed-kana penalty 使用同词典全片假名证据，而不是单词特判。`カタカナ語`、`日本語を`、`おニュー` 等不会被粗暴过滤。

平假名、片假名直接表记都是 `scriptVariant`，与其他来源一起评分。如果词典有相同 surface，保留词典对象；人工表记不能覆盖它，也没有第 N 位插入。

## 6. Learning 接入与持久化

生产 `KeyboardView` 使用异步 worker；worker 创建 converter 时开启 `.inputAndOutput`。memory 优先位于 App Group `group.com.Voltline.Vime` 下的 `Vime/AzooKeyMemory`；共享目录不可写时回退到本进程 Application Support 同名目录。`maxMemoryCount = 8192`。测试可注入独立目录，直接诊断 engine 默认关闭学习，避免测试间互相污染用户偏好。

实际候选确认按当前依赖 API 执行：`setCompletedData(realCandidate)` → 对合格词典候选 `updateLearningData(realCandidate)` → 在串行 converter 队列的确认/生命周期边界 `commitUpdateLearningData()`。全量确认和部分确认都经过这一链路。普通键击不落盘；人工脚本和仅修改表记的 synthetic 候选不伪造可学习对象。

学习测试从 `hashi` 的第三名词典候选开始，选择 8 次，排名记录（0 起算）为 `[2, 0, 0, 0, 0, 0, 0, 0, 0]`；重建 converter 后仍为 0，且有 `.isLearned` 证据。这是 azooKey 自带学习的提升，不是 Vime last-selected-wins。同步 session 和生产 worker 分别验证。`KeyboardSession.clearLearning()` / worker / engine 提供内部清空入口，调用 `resetMemory()` 并清缓存；重建后确认旧 learned evidence 已消失。

本轮没有另造 frequency/recency/rejection 偏好数据库。单次选择的提升幅度由 azooKey 控制；长期衰减、撤销惩罚尚未增加。

## 7. Context、Zenzai 与 Learning 的分工

Learning 记录过去真实确认的 Candidate；上下文评分评价当前左侧文本的语法连接。二者独立参与最终顺序，Zenzai 不能替代 `updateLearningData()`。

生产 extension 从 `documentContextBeforeInput` 获取左侧正文，排除已知 marked suffix；sandbox 从 UITextView 的 marked range / selection 获取已提交前缀。候选确认保留 completedData，并维护最近 96 字文本。部分确认使用即将插入的前缀，避免 host 尚未 apply edit 时误判上下文。

每次候选请求 reconcile 实际 host 前缀；变化或 nil 会清除旧 completed/context/continuity 状态并重新解析。caret、正文外部修改、session reset 会取消旧 revision，旧结果不能覆盖新输入。外部上下文解析不调用学习。

当前使用实际 committed Candidate 或独立 converter session 解析的词典 CC/MM 连接证据。测试中 `kaku` 在「昨日」后前五为「各／書く／核／格／角」，在「プログラムを」后为「各／書く／描く／核／辛く」；`hashi` 也出现次序差异。它是有限的词典语法上下文，不等同于语义语言模型。当前本地配置 Zenzai 为 off，没有模型 latency 数据。

## 8. Typo Correction 与 UI

保留并接入工作区已有的一处局部错误生成器：QWERTY topology、漏字、多字、相邻交换、通用清浊音/近音规则；词典及连接成本决定是否准入。没有添加 Levenshtein 引擎或整词替换表。

首先发布普通 conversion/prediction，再在同一后台队列进行可取消的补充搜索（最多 24 个词典请求、60 ms 搜索预算）。删除原来的固定 140 ms correction 延迟。当前 azooKey classic `typoCorrectionMode` 已接入 fallback；只在其支持的通用输入通道和短输入范围启用，避免无收益的 Roman lattice 工作吞掉搜索预算。

experimental API 已有独立接入口：可注入 `ExperimentalTypoCorrectionConfig`，传入 leftSideContext，保存 correctedInput、convertedText、lmScore、channelCost、prominence，并再次验证词典读音。**当前未配置训练好的实验模型，因此生产未启用 LM 纠错，也没有用真实模型验证效果。**

`shitsuka` 会出现「静か」与「しずか」，annotated reading 为「しずか · 建议」，accessibility 包含原读音；原 preedit 仍为「しつか」，选择后才接受修正。`shizuka` 不产生纠错。`kikoro → こころ` 覆盖完整词中的邻键元音误触；孤立 `ki` / `ko` 歧义过大，本阶段不猜测纠正，至少三假名且已完成的 reading 才进入补充搜索。

现有 corpus 测得 recall 11/12、正确输入误建议 0/33；held-out 9/10、误建议 0/15。这些数字只描述本地测试语料，不代表所有日语输入。每次最多补充三个候选，正确 literal lexical evidence 保留，但最终排序由统一分数决定。

## 9. Diagnostics 与测试

设置 engine `diagnosticsEnabled = true` 可读取 `rawDiagnostics` / `finalDiagnostics`。每行包括 surface/ruby/source、engine score/rank、consumption、exact/full、script/continuity/user/context/typo 分数、最终 score/rank、revision、learning eligibility、纠错信息。默认不开启正文日志。阶段计时使用 `KeyboardPerformance`。

新增 `KeyboardIntelligentCandidateTests` 的 7 项测试，覆盖 14 个标准输入、纠错、连续输入、script policy、同步/worker 学习持久化及清空、host context 差异/reconciliation、latest-wins、warm profile。保留原有输入、n 解释、touch ownership、preedit、unfinished Roman、correction UI 等回归。异步测试注入独立 memory 目录；旧 fixed-slot/prefix-order 断言改为 lexical evidence 与表记可用性断言。

候选＋纠错专项：13/13 通过。最后收紧 script policy 的同读音判断后，候选、纠错、Core、Prediction、Preedit、n 解释合并复核：26/26 通过，见 `Artifacts/intelligent-tests-final.json`。完整 UIKit 回归：60 项，58 通过，2 项失败。详见 `Artifacts/intelligent-tests-focused.json` / `intelligent-tests-full.json`。

两项失败位于本轮没有修改的现有触控逻辑：

- `testNumericLayoutsLongVowelAndModeIndicator`：独立复现仍 crash。堆栈为 `rebuildKeys → cancelAllPresses → layoutIfNeeded → layoutSubviews → KeyboardMetrics.numberPadFrame`；page 已切到 numbers，旧字母行仍被按五列九宫格访问，数组越界。候选转换不在故障堆栈中。
- `testNumberLayoutSwitchPanelAndRepeatCancellation`：仍要求 touchDown 立即删除，当前本地实现与另一个现有测试均采用释放时短按删除，实际为 0 而断言为 1。

遵守本轮输入/触控范围约束，保留这两处问题，没有为了测试通过重新修改 touch system。完整回归不能标为全绿。

## 10. 性能数据

运行环境：iOS 27.0、Vime Keyboard QA simulator（iPhone 16 Pro Max）、Debug。以下不是实机或 Release 数字，不能跨环境直接比较。

| 场景 / 阶段 | 平均 ms | P95 ms | 说明 |
| --- | ---: | ---: | --- |
| 常见 warm corpus：azooKey baseConversion | 4.05 | 8.29 | 84 次 |
| 常见 warm corpus：完整后台 candidateCompute | 12.19 | 23.04 | 包括既有 n alternatives |
| 常见 warm corpus：reranking | 0.56 | 0.89 | 84 次 |
| 常见 warm corpus：type → marked | 0.24 | 0.30 | 84 次真实 UIKit 输入 |
| 带慢分支 corpus：baseConversion | 25.50 | 184.46 | 27 次，保留真实长尾 |
| 带慢分支 corpus：reranking | 1.19 | 1.99 | 33 次 |
| 新上下文 reconcile | 2.07 | 2.17 | 27 次外部前缀解析 |
| classic typo fallback | 1.93 | 1.95 | 3 次；没有 experimental/LM 样本 |
| 纠错 UI profile：type → marked | 0.18 | 0.24 | 220 个 Roman 按键 |
| 纠错后台 compute | 10.28 | 19.63 | 50 次 |
| 纠错 profile：候选 publish | 1.82 | 2.26 | 60 次 |
| idle correction 请求 → UI | — | 248.25 | 30 个补充结果，包含 base conversion 与排队 |

完整输入 burst 的独立测试：35 个字符 13.87 ms，最慢键 1.16 ms。较冷 UI profile 的 type → marked P95 为 1.18 ms，最大 12.34 ms；没有只报 warm 最优值。

后台主转换仍有约 180–190 ms 的 engine 调用长尾，补充纠错可能约 250 ms 后出现。它不会阻塞 keypress/composition/preedit，但会拖慢候选展示；此次不以 debounce 掩盖它。运行中的 azooKey 同步请求不能中途取消，后续请求等待同一 converter 队列；cancel + revision 防止它发布过期结果。模型与磁盘也不能并发访问同一个 converter。

性能 JSON：`Artifacts/intelligent-warm-performance.json`、`intelligent-input-performance.json`、`intelligent-candidates-performance.json`、`intelligent-correction-performance.json`。完整回归中已加载其他视图/缓存，纠错 profile footprint 约 74.2 → 74.8 MB；专项独立运行约 43.9 → 46.1 MB。不能把共享进程的绝对 footprint 当成纯候选增量。

## 11. 剩余限制

- 尚无实机、Release、多进程共享 memory 同时写入压力测试；扩展缺少共享目录访问能力时，本地 fallback 学习不会跨进程共享。
- 上下文是词典语法连接，不是完整语义 LM；Zenzai / experimental trained model 未配置。
- 不主动纠正孤立 `ki` / `ko`、未完成 suffix、过长或低证据输入；保持字面输入与可选择纠错之间的边界。
- 搜索预算、最多一处局部编辑及最多三个补充候选限制 recall；尚无撤销/拒绝/风格偏好的独立学习层。
- 权重有注释及 corpus 测试，但尚需更广泛真实输入反馈；连续性仅加分，不保证历史第一名永不下降。
- azooKey base conversion 的慢分支和上述两个现有触控测试故障仍需后续处理。

## 12. 主要实现入口

`CandidateSnapshot.swift`（模型）→ `JapaneseCandidateEngine.swift`（生成/学习/上下文/纠错）→ `CandidateReranker.swift`（唯一展示排序策略）→ `JapaneseCandidateWorker.swift`（串行异步/取消/持久化）→ `KeyboardSession.swift`（revision/真实选择/host reconcile）→ `CandidatePresentation`（UI）。

本轮没有新增 whole-word 特判、固定脚本位置、偷偷修改 preedit、每键磁盘写入、Zenzai 替代用户学习或 Vime last-selected-wins。
