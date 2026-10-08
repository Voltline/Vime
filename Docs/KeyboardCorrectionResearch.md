# 日语纠错与近音候选调研

调研日期：2026-10-05。范围：当时工作区代码、项目固定的 AzooKeyKanaKanjiConverter 修订 `d59a28e4c7ca049aef04f29a91eae9677a7753f2`、网上的上游实现与论文。调研部分来自源码检查；下方「实现与验证」另行记录随后完成的运行代码与真实词典实验。原调研中的行号与项目现状描述保留作历史参考。

## 结论

建议首版沿用现有离线转换，在后台增加独立、有限的纠错/近音候选查询，并显示候选的建议读音。自动生成建议，只有选择候选或空格转换后确认才采用；没有选择时回车仍确认字面输入。若之后要做直接改写草稿或自动提交，需要另行设计置信度、撤销和偏好设置。

不能只把 `typoCorrectionMode` 改成 `.enabled`：固定版本的经典规则没有覆盖两个目标例子。也不能仅按编辑距离选最常见词：`ki` / `ko` 都是合法输入，容易误判。首版适合通过完整词/词句证据生成建议；更强的上下文纠错可在验证模型体积、内存、延迟后接入上游实验 API。

## 项目现状与修改入口

- `Shared/Candidates/JapaneseCandidateEngine.swift:9–17`：`typoCorrectionMode: .disabled`，`learningType: .nothing`，未开启 Zenzai；逐键正常转换使用 `.autoMix`。
- `Shared/Input/RomajiConverter.swift`：原始罗马音由上游 `ComposingText` 解析；已有 `nReadingAlternatives`，仅生成候选查询，不改写字面草稿。可借鉴这种查询分离方式，但通用纠错应有独立来源。
- `Shared/Candidates/JapaneseCandidateEngine.swift:46–49,97–115`：优先 ruby 完全匹配；再合并其他候选、按文字去重、截取 15 个。因此即使引擎产生纠错候选，也需要明确合并位置、标注与去重政策，不能假定开关后自然排在可见区域。
- `Shared/Candidates/CandidateSnapshot.swift`：仅保存 candidate、revision、source、remainingComposition；缺少建议读音、原始读音、改动范围和纠错类型。
- `Shared/Input/KeyboardSession.swift`：`choose` 从快照取得剩余组合；未选候选时 `confirm` 提交字面假名。`candidates` 只暴露 `[String]`。
- `Shared/UI/KeyboardView.swift:15–77,861–883,939–960`：候选按钮和刷新缓存只比较文字/选择；增加读音标注后，必须让元数据变化触发刷新和宽度测量，否则同样的候选文字会残留旧提示。展开面板和 VoiceOver 也要同步。
- `Shared/Candidates/JapaneseCandidateWorker.swift`：后台串行计算、取消未启动请求、revision 防过期。正在执行的旧计算不能中断，新增大量查询会延迟最新候选。不能每键无界枚举再逐个请求词典。
- 键盘扩展能读 `textDocumentProxy.documentContextBeforeInput`，目前用于宿主状态/导航，没有作为 `leftSideContext` 传入候选引擎；宿主上下文可缺失或截断。首版可先利用当前组合内的词句连接评分，完整宿主上下文接入属于额外工作。

## azooKey 已有机制

### 1. 经典词典纠错

本地固定依赖的 `Sources/KanaKanjiConverterModule/ConverterAPI/ConvertRequestOptions.swift` 定义 `.automatic / .enabled / .disabled`；`KanaKanjiConverter.swift:1348` 中 `.automatic` 在 iOS 开启，在其他平台关闭。Vime 明确 `.disabled`，不受这个默认值影响。

`Sources/KanaKanjiConverterModule/DictionaryManagement/TypoCorrection.swift:354` 中罗马音纠错只有 10 个定向映射：`bs→ba`、`no→bo`、`li→ki`、`lo→ko`、`lu→ku`、`my→mu`、`tp→to`、`ts→ta`、`wi→wo`、`pu→ou`。它在词典检索中展开输入、加入惩罚并剪枝，是轻量的候选纠错，不是通用拼写检查器。

重要区别：`.direct` 假名规则有清浊音/小假名变化，但 `.roman2kana` 不自动套用它们；其中 `ツ` 的变化是 `ッ / ヅ`，也不是目标的 `ズ`。`shitsuka → shizuka` 在罗马音上涉及 `tsu→zu`，在假名上是 `しつか→しずか`，应在音节/读音层处理，不能把任意 `ts` 都替成 `z`。

网上可核对同类实现：[上游 TypoCorrection.swift](https://github.com/azooKey/AzooKeyKanaKanjiConverter/blob/main/Sources/KanaKanjiConverterModule/DictionaryManagement/TypoCorrection.swift)。精确 API 以本地固定修订为准，网页 main 会变化。

### 2. 实验语言模型纠错

固定依赖已有 `KanaKanjiConverter.experimentalRequestTypoCorrection(leftSideContext:composingText:options:inputStyle:config:)`。配置支持 `.zenz` 或 `.ngram`，beam search 结合语言模型评分与错误通道成本；结果为 `ZenzaiTypoCandidate`，有 `correctedInput`、`convertedText`、`score`、`lmScore`、`channelCost`、`prominence`。

- `convertedText` 是纠正输入经过输入表转换后的显示字符串，不能直接视为最终汉字词候选；仍需查询通常的假名汉字转换，并保存原输入消费映射。
- `.zenz` 需要开启 Zenzai、实际模型权重和对应编译 trait。当前 Vime 未配备这些条件，直接调用会返回空列表。
- `.ngram` 需要四个训练好的 `.marisa` 文件；默认词典不包含这些模型。尤其 `Sources/EfficientNGram/Inference.swift` 的真实实现受 `#if canImport(SwiftyMarisa) && Zenzai` 限制，否则是均匀分布的 `Mock Implementation`。不能仅配置 `.ngram` 就认为获得真实语言模型；也不能假定启用 `ZenzaiCPU` 满足这个特定编译条件。
- 上游有 `testTypoCorrection_OneShot_Roman2Kana` 和逐键 N-gram 性能测试，可作为验证模板。API 明确实验性；`prominence` 是候选集合内的相对权重，不能当成经过校准的“正确概率”。

参考：[上游 converter API](https://github.com/azooKey/AzooKeyKanaKanjiConverter/blob/main/Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift)、[N-gram 实现](https://github.com/azooKey/AzooKeyKanaKanjiConverter/blob/main/Sources/EfficientNGram/Inference.swift)、[Zenzai 官方接入说明](https://github.com/azooKey/AzooKeyKanaKanjiConverter#zenzaiを使う)。这说明已有可复用的接口，但不保证两个例子无需调参即可命中。

## 其他方案及误判问题

[SymSpell](https://github.com/wolfgarbe/SymSpell) 是已有的快速近似词典检索方案，使用删除索引生成编辑距离候选并结合词频排序。适合作为读音索引的候选生成器；对本项目仍需构建日语读音词典、解决连续无空格输入和词句排序，不能拿英语词表直接修正日语罗马音。首版直接复用已有词典、有限生成变体更容易集成；规模增长后再评估独立索引。

[《Error Correcting Romaji-kana Conversion for Japanese Language Education》](https://aclanthology.org/W11-3506/) 研究罗马音纠错，采用近似匹配和字符语言模型。其讨论指出：误输结果本身是合法词时，需要上下文；放宽编辑距离会引入不相似候选。支持本项目采用“错误可能性 + 词句合理性”的方向，论文结果不能直接当作本项目效果保证。

## 建议的首版实现

1. 正常查询维持现有结果；新增独立 correction session，复用同一 converter 和词典缓存。先诊断经典 `.enabled` 的召回、误判与耗时，覆盖不足时生成有限的邻键替换、漏/多字、相邻转置和音节近似变体。音节规则应通用、定向且带成本，不硬编码示例整词。
2. 先实现单处错误搜索；限制变体数量、词典查询次数、候选数量及最长输入，使用缓存/剪枝。实际限额由测试确定。较重搜索在短暂停顿或显式空格转换时运行，正常逐键候选先发布；保持取消、revision 和最新输入保护。两阶段结果不能改变用户已经选中的候选。
3. 对每个变体，用独立会话请求词典转换，验证 ruby 与纠正读音一致、消费范围正确、存在真实词典条目。固定分数的假名兜底不能当作词典证据。先支持完整纠错候选；句子可有多个词典条目，不能照搬 n 查询的 `data.count == 1` 限制。若未来支持部分纠错，另建原输入跨度映射。
4. 排序综合变体成本、词典/连接评分、原查询证据及候选差距；不要把不同长度的原始 lattice 分数直接视为概率。默认保护强匹配和短合法输入；纠错仍可作为次级建议出现，不能仅因“存在合法词”就彻底禁用整句纠错。`ki` 不自动变 `ko`；在后续词句中寻找合理的 `ko` 方案。
5. 快照新增 `.correction` 和展示元数据，例如 `originalReading`、`suggestedReading`、纠错类型/范围；汉字读音从 `candidate.data.map(\.ruby).joined()` 提取并转为适合展示的假名，合成假名候选也保存读音。候选显示 `静か · しずか（建议）`，必要时辅以罗马音 `shizuka`。纯“预测补全”不能仅因 ruby 更长就误标为纠错。
6. 选择完整纠错候选时消费原查询 `query.input.count`，包括原输入中的分隔符等元素；不能用修改后输入长度或另一个查询的 `composingCount` 删除当前组合。保证插入的是候选正文，提示不进入宿主文本。去重时同字同消费范围优先保留原读音合法匹配，并防止丢失来源/读音元数据；不同消费范围不能只按文字去重。
7. 保持原始 preedit、未选择时回车、假名退格、n 备选、片假名入口与宿主 marked text 行为。若增加自动提交，另加开关、校准阈值、恢复原文能力及测试，不默认扩大首版范围。

## 验收重点

- `shitsuka` 的候选含真实词典支持的 `しずか` / `静か`，标注 `しずか`；原草稿仍为 `しつか`。正确输入 `shizuka` 的正常候选不被误标或降级。
- 单独 `ki` / `ko` 都保留各自字面输入及正常匹配；准备多个含邻键误输的完整词句，验证正确建议可见，同时准备同长度合法词、人名、罕见词作反例。用独立正反样本评估召回和误纠率，不能只测两个示例。
- 漏字、多字、转置、未完成辅音、n 边界、长句、假名退格、片假名、普通预测、同字不同元数据、选词后剩余组合和快速输入过期结果。
- 使用真实捆绑词典，运行相关 `KeyboardPredictionTests`、`KeyboardPreeditTests`、`KeyboardNInterpretationTests`、`KeyboardCoreTests`、宿主集成及 `KeyboardPerformanceTests`；重测后台计算、请求到结果、marked text 和候选发布 p95，并观察内存。
- 现有 2026-10-05 实机记录：候选计算 p95 18.72 ms、候选发布 1.47 ms、marked text 0.28 ms，属于旧版本特定设备/Debug口径；新增实现需同口径比较，不能把这些当成新功能的测量结果。

## 可复制给修改 agent 的 prompt

请基于 Vime 当前工作区实现离线日语纠错和近音候选，先读 `Docs/KeyboardCorrectionResearch.md`。依赖固定修订 d59a28e4；现有 `JapaneseCandidateEngine` 明确关闭 typo，经典 `.enabled` 只覆盖少量映射，不支持 shitsuka→shizuka 或 ki→ko；实验 LM API 需额外模型，默认 N-gram 还是 mock，首版不要未经验证直接启用。保留正常查询，复用词典缓存和独立会话，在后台生成有数量/时间预算的邻键、编辑、音节变体，以词典读音匹配、连接评分和错误成本筛选。shitsuka 应建议 静か/しずか，并在候选旁标注 しずか（可附 shizuka）；不要硬编码整词。ki/ko 都合法，短输入不强改，结合后续词句给建议。扩展 CandidateSnapshot 的纠错来源、建议读音和原输入消费信息，同步候选条/展开面板/无障碍及元数据刷新；选择完整纠错候选消费原查询输入，未选时回车仍提交字面假名。保留 n 备选、片假名、退格、marked text 和 revision 防过期；较重搜索延后，已选候选不能被后到结果改变。用真实词典验证正反例、漏/多字、转置和快速输入，运行相关回归并报告误纠率及同口径 p95/内存。工作区已有未提交修改，不覆盖。

## 实现与验证（2026-10-05）

已按上述首版方案实现，经典 typo 与实验 LM 仍关闭。正常候选先发布，随后等待 140 ms 才在同一后台队列搜索单处邻键、漏字、多字、转置及近音错误。独立查询会话共享词典缓存；候选旁显示建议读音，草稿及未选择时回车仍为字面假名。完整纠错按原始输入元素数消费，迟到结果不能改变已选候选。

查询规划使用从同一固定词典派生的只读索引：245,506 个读音、4,910,128 字节。结合局部词条和左右词类连接增益排序，再验证最终转换的真实词典读音、完整消费与扣除错误成本后的分数差距；不硬编码目标整词。最多 384 个变体、24 次词典查询、3 个补充候选，最长 40 个输入元素、3…24 个显示字符。60 ms 为查询前检查的软预算，单次上游同步查询不能中断；本轮开发样本最大记录为模拟器 195.1 ms、实机 164.7 ms，不能宣称硬性 60 ms 上限。

真实捆绑词典回归：模拟器 25 项、iPhone 16 Pro Max 11 项均通过，涵盖输入/预测、n 备选、假名退格、片假名、宿主 marked text、原输入消费、同字元数据刷新、候选冻结与性能。开发组命中 11/12，33 个合法输入不必要建议 0/33；独立组模拟器命中 8/10、实机 9/10，合法输入不必要建议均为 1/15（6.7%）。采用「合法输入新增任何纠错建议」的保守计数，尚未量化真人选错建议的概率。

限制案例如实保留：takaai 的合法姓氏读音受到保护，未命中意图 takai；yasahii 建议 やしい，未命中 やさしい；合法 amefurashi 收到 あめぐらし 的多余建议。模拟器还因预算未命中 soshitee，实机命中。这组独立样本没有用于追加整词规则或事后调参，所有误输与合法反例见 JSON 原始记录。

实机同口径 84 次普通候选发布 p95：修改前 3.206 ms、修改后 1.353 ms；每键 marked text 为 0.440 → 0.194 ms。模拟器发布为 1.942 → 2.004 ms。预热/设备状态会影响结果，这些观测不能证明纠错使 UI 提速。30 次停顿纠错的实机计算 p95 为 41.8 ms，从第一键到建议显示 p95 为 368.9 ms，包含正常转换与 140 ms 等待；其中候选发布 p95 为 3.763 ms。另一项 70 键突发/交错输入保留全部按键和逐键草稿，实机 marked text p95 为 0.808 ms。不同输入样本的 p95 不混作性能回归比较。

内存使用 task_vm_info 的 phys_footprint，实机测试宿主峰值 44.47 MiB、结束 32.49 MiB，模拟器峰值 49.49 MiB。该值包含测试 App、UIKit 与引擎，受系统内存回收影响，不是单独词典索引增量，也不是系统键盘扩展的内存上限证明。详细架构见 [KeyboardImplementation.md](KeyboardImplementation.md)，汇总与原始数据见 [keyboard-correction-audit.json](../Artifacts/keyboard-correction-audit.json)。测试截图仅在本地临时 xcresult 中保留。
