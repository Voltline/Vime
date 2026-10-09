# Vime Personalization Learning — Technical Report

日期：2026-10-09。基于本地工作区，起点 `54c7de7`。本轮保留 Vime 1.0、v2.1 INT8 模型、CPU_ONLY 配置和既有输入/触控语义。

## 1. 问题与本轮范围

此前已有 azooKey `.inputAndOutput` 学习，以及 Vime 的轻量词频文件。实际不足主要有三点：

1. 用户选择后立即更新学习，不能区分保留、误选后删除、宿主未完成插入等情况。
2. 旧记忆保存整数次数，在新选择时刷新整个条目的时间戳；很久以前的次数会重新获得完整权重。转换偏好只看 reading，没有上下文区分。
3. 联想生成降成字符串后用数组位置代替模型概率；历史短语没有经过 LM 验证即可补入列表。

本轮实现可信反馈、分层衰减记忆、基于真实 LM 分数的联想。模型权重保持固定，没有部署在线梯度更新、向量索引、GRPO 或 KV Cache。

## 2. 研究如何影响设计

- [Neural cache（Grave 等，2017）](https://arxiv.org/abs/1612.04426)：近期记忆可以补充固定 LM。本轮采用短期、可移除的选择事件，没有实现论文中的隐藏向量 cache；用户记忆与计算用 KV Cache 是不同机制。
- [kNN-LM（Khandelwal 等，2020）](https://arxiv.org/abs/1911.00172)：检索与基础 LM 可以共同决定概率。本轮只召回少量同上下文历史文本，并由现有 LM 评分，没有声称实现完整 kNN-LM。
- [Federated personalization（2019）](https://arxiv.org/abs/1910.10252)：个性化需要区分反馈训练与后续评估。本轮先建设可信数据和有界偏好；尚无时间切分的真实用户效果评估，不能引用论文收益作为 Vime 的收益。
- [Position bias（Joachims 等，2017）](https://www.cs.cornell.edu/~tj/publications/joachims_etal_17a.pdf)：展示位置会影响选择。本轮区分主动选择与默认确认，未点选项不被当作负例；权重是工程启发式，没有已校准的 propensity 或完整无偏学习。

## 3. 可信反馈与宿主确认

`CandidateLearningFeedback` 保留事件 ID、确认方式、展示索引、选择前上下文和时间。`PendingCandidateFeedback` 保留插入前的 document identity、左右上下文、待确认文本、剩余字符及宿主回执。

生产流程：

```text
选择候选
  → setCompletedData(real Candidate)，立即更新转换上下文
  → 暂存学习事件及可移除的会话证据
  → 宿主 apply edits / marked range 更新
  → 校验真实正文、字段、右侧上下文和选择状态
  → 保留 1.5 秒，或在下一次提交动作前再次校验
  → 接受：更新 azooKey + Vime 长期记忆，后台持久化
  → 取消：移除暂存证据，不调用 azooKey updateLearningData
```

1.5 秒是**反馈观察窗口**，不延迟按键、preedit 或基础候选发布。未收到宿主插入回执、部分/完整删除、字段变化、光标移动、外部正文变化、非保留型 session reset 会放弃待定反馈。批量插入候选和随后标点时，校验也包括同批次的尾随文字；删除尾随标点不等于删除候选。

扩展使用现有 proxy identity 和实际正文，排除 Vime 自己的 marked suffix；App 试打页使用 UITextView 的 marked/selection range。没有访问 UIKit 断开连接时可能为 nil 的 `documentIdentifier`。左上下文为 nil 时不接受学习。

当前只有一个待定事件。下一个提交动作关闭前一个有效窗口；界面退出/reset 采取保守取消。正文前缀校验取末尾 64 字，不能保证识别所有第三方宿主行为。

### 反馈强度

| 事件 | Top1 | 非 Top1 |
| --- | ---: | ---: |
| 直接点击候选 / 联想 | 0.7 | 1.0 |
| 空格转换后确认 | 0.35 | 0.7 |

以上权重用于 Vime 记忆。azooKey API 接收真实 Candidate，没有浮点权重参数；接受的合格候选仍按其原生机制学习。首次选择的 azooKey 排名影响不受 Vime 的次数门槛控制。

直接 engine `complete` 和无宿主 provider 的 headless session 保留原有可信调用语义，用于已有转换客户端/测试。扩展和 App 试打页均安装 provider，走上述延后确认链路。

## 4. azooKey 生命周期

固定依赖 revision：`d59a28e4c7ca049aef04f29a91eae9677a7753f2`。已检查本地 `KanaKanjiConverter.swift`：

- `setCompletedData` 设置当前转换 session 的完成数据。
- `updateLearningData` 更新共享词典学习状态，并使用当前 session 的 `lastData`。
- `stopComposition` 重置该 session 的状态，包括 `lastData`。
- `commitUpdateLearningData` 执行磁盘持久化；没有单条撤销 API。

因此确认时先更新实际转换 session；延后接受学习时使用独立 learning session，防止后续查询/reset 的 `lastData` 混入学习。外部上下文失配或非保留 reset 会清除此学习 session 的连接状态；合成表记和下一词不伪造词典 Candidate。

继续使用 `.inputAndOutput`，azooKey 条目上限 8192。目录优先为 App Group `group.com.Voltline.Vime` 的 `Vime/AzooKeyMemory`，失败时沿用现有本地 Application Support 回退。Vime 记忆在同目录 `VimeSelectionFrequency.json`。

所有生产 converter/LM/记忆操作由同一个串行 worker 队列执行。接受反馈时 flush，reset/deinit 同样 flush 已接受的脏数据；普通查询不写磁盘。`clearLearning()` 清除原生学习、Vime 长期/近期记忆和缓存。

## 5. 分层记忆与衰减

长期条目保存 `scope / reading / context / surface / evidence / confirmations / selectedAt`。scope 区分转换、直接表记风格和下一词。

```text
effective(t) = evidence × 2^(-age / 30天)
新 evidence = effective(选择时刻) + feedbackWeight
globalBonus = log(1 + max(0, effective - 1))，至少两次确认
```

先衰减再更新，避免旧频次复活。长期上限为 3 分；短期事件 5 分钟半衰期、最多 128 条、短期加分上限 0.6。取消只移除对应事件，session reset 清空近期层，近期事件不会写进文件。

转换记忆有 reading 的全局层，以及前文末尾 12 字和 4 字的 SHA256 桶。上下文分布用全局分布作为 prior，prior mass 为 4；局部后验对全局 prior 的正 log-ratio 作为加分，4 字层乘 0.25，上下文调整最多 1 分。不会把未选择候选当拒绝。

这是字符后缀匹配与平滑回退，**不是语义 embedding、分词话题识别或精确 POS 个性化**。不保存该层的原始前文；仍保存必要的 reading/surface，SHA256 也不等同于匿名化或加密。

索引按 scope/reading/context 组织，查询只访问内存。最多 2048 个条目（含全局与上下文层），文件读取/写入上限 4 MiB。格式 v1 自动迁移到 v2，保留旧次数与最后时间；旧记录的逐次历史时间不可恢复。未知/非法记录忽略。

## 6. 联想统一评分及概率复用

`ScoredNextWord` 保存显示文本、真实 `logProbabilitySum`、计分 token 数；`NextWordSuggestion` 保留来源、模型分数、用户分数和最终分数。生产没有 ordinal/string-only 评分适配器。

生成策略保留：最多 5 个词/短语，最多 3 个生成 token，置信度不足停止，遇标点截断。历史召回最多 3 条；完整上下文要求至少两次确认，4 字回退至少三次，且有效证据大于 1。近期历史只在原上下文召回，超过两个短期半衰期不再召回。

生成与历史显示文本进行 `context + text` joint tokenization，统一公共上下文边界，不加 EOS、不做额外长度归一化。最终分数：

```text
FinalScore = 真正的 suffix log-probability sum + 有界 UserPreferenceScore
历史准入：LMScore ≥ 最佳生成 LMScore - 3
```

历史与生成同文本去重，模型证据过弱的历史不能仅靠高词频进入列表。LM 不可用/评分失败时不发布未评分历史。

为避免重复预测，生成同时保留 token IDs 和逐步 log-probability sum。只有 canonical tokenization **完全一致**且公共边界仍在完整 context 末尾时复用；标点截断、边界重新分词或历史短语使用原 scorer 的 teacher-forced suffix 计算。复用的是同次请求里的概率，不是 Transformer KV Cache。

生成的保守最坏上限是 `1 + 15 × 2 = 31` 次 forward（包含舍弃的起点），补充评分最多 8 次，常见边界稳定时只评分历史。记录 `nextWordScoreReuses / nextWordScoringPasses`，并在每次模型调用前检查取消；已开始的单次 CoreML 调用不能中断。

## 7. 排序与上下文分工

- azooKey：词典生成、实际词条学习与连接信息。
- Vime 统一 reranker：沿用 exact/full/script/continuity/typo 特征，加入上下文相关、有界的用户偏好；人工直接表记可以记录独立 style 偏好。
- 固定 v2.1 LM：评价当前句中哪个文本更自然；普通 lexical 候选神经排序为 LM sum + user score。
- 记忆：反映经过验证的个人选择和近期重复，不修改模型权重。

已有神经 rerank 的可重排范围、250 ms 回退、revision/latest-wins 与选中后列表冻结语义继续保留。未改 Roman 解析、unfinished suffix、marked text 生成、触控 ownership 或皮肤。

## 8. 定向验证与性能

遵循只做必要定向验证的要求，使用 Release、iOS Simulator、`Vime Keyboard QA`，没有跑全量准确率/回归矩阵。覆盖：

| 验证 | 结果 |
| --- | --- |
| 旧格式迁移、历史频次不复活、上下文隔离、近期取消 | 通过 |
| 重复选择、原子持久化、converter 重建、清空 | 通过 |
| 删除/部分删除、字段改变、缺失宿主回执不学习 | 通过 |
| 实际 1.5 秒计时窗口接受有效回执 | 通过 |
| 历史 LM 准入、偏好上限、真实概率及 token metadata | 通过 |
| 概率复用与原 scorer 一致，含原 Mac INT8 fixture 的边界重分词 | 通过 |
| 既有下一词生成和 session 显示/插入流程 | 通过 |

重复选择用例中「端」神经排序索引从 1 提升到 0，重建后 user score 约 2.77；这是特定测试 reading 的证据，不是整体准确率收益。

性能开启 `KeyboardPerformance`，无正文日志。新增 `lmNextWordScoring / personalization / learningAcceptance`，已有生成、rerank 和输入阶段计时保持。最初全量重复评分版本，3 个固定上下文的额外评分均值 41.13 ms；概率复用后的首轮观察为 17.89 ms。样本少、模拟器负载不稳定，不能作为稳定 P95、实机耗电或统计显著的加速结论。

初次 8 项、优化后 4 项、最终 8 项，以及显示文本 roundtrip 的单项补充复核均通过，共覆盖 10 个不同的定向用例；最终 8 项执行时间 3.49 秒，不含构建与模拟器启动。App 与键盘扩展 Release 模拟器构建通过。保留现有的 AppIntents 元数据跳过和父 App build 10 / 扩展 build 2 不一致警告，没有在学习改造中更改版本配置。

最终模拟器观察值如下，三个固定上下文各一次，非稳定统计基准：

| 阶段 | 样本数 | 平均 ms | 最大 ms |
| --- | ---: | ---: | ---: |
| 既有下一词生成 | 3 | 56.68 | 64.81 |
| 分词校验、概率复用及补充模型评分 | 3 | 15.72 | 35.27 |
| 记忆准入/统一排序 | 3 | 0.41 | 0.48 |

`プログラムを`、`明日の会議までに` 各复用 5 条生成结果，仅补做 1 次历史评分；`朝起きたら、コーヒーを` 的边界不满足复用条件，6 条重新评分。全部分数与未复用 scorer 相差小于测试容差 `0.0001`；公共边界变化时不强行复用。这些只是一轮模拟器样本，不能与之前实机报告的绝对数值比较。

新模型/记忆工作均在后台，候选基线先发布；本轮没有额外的输入 debounce。未重跑输入路径全量性能，不能据此宣称实机输入延迟或能耗改善。

复现核心定向检查：

```sh
xcodebuild test -project Vime.xcodeproj -scheme Vime -configuration Release \
  -destination 'platform=iOS Simulator,name=Vime Keyboard QA' \
  -parallel-testing-enabled NO \
  -only-testing:VimeKeyboardTests/KeyboardPersonalizationTests \
  -only-testing:VimeKeyboardTests/VimeLanguageModelTests/testJointSuffixScoresMatchMacINT8IncludingBoundaryRetokenization \
  -only-testing:VimeKeyboardTests/VimeLanguageModelTests/testSessionShowsAndInsertsPhraseSuggestionsAfterCommit
```

## 9. 限制与后续

1. 观察窗口关闭后，后续撤销无法逐条恢复 azooKey 学习；本轮没有持久负反馈惩罚或拒绝数据库。退出界面过快可能丢失一条有效学习，采取保守策略。
2. Native learning 是二元接收，反馈强度只用于 Vime 分数；一次主动选择可能影响 azooKey 自带排名。
3. 字符后缀上下文可能稀疏或碰撞；没有向量检索、话题归纳、用户模型权重训练。
4. 长度使用现有 raw log-probability sum，长短短语仍存在分数差异；没有借本轮修改模型的长度策略。
5. 多进程同时写 App Group 记忆仍沿用原有原子替换，未实现进程间合并/锁；也未做真机宿主兼容、最大记忆容量压力或能耗测试。
6. 最多三条历史不会覆盖任意用户词汇的新生成；纠错接受只通过实际候选学习，未新增纠错通道概率的在线训练。
7. 建议后续先做时间切分的保留率/撤销率、个性化命中与延迟评估，再决定是否训练小型线性 ranker。需要真实展示概率记录和回滚/验证机制，不能直接把未点选项作负例。

## 10. 实现入口

`CandidateLearningFeedback.swift` → `KeyboardSession.swift` / 宿主 provider → `JapaneseCandidateWorker.swift` → `JapaneseCandidateEngine.swift` / `CandidatePreferenceMemory.swift`；联想由 `VimeLanguageModel.scoredNextWords` 生成、复用与补充评分，最终进入 memory 的统一排序。

相关文档已同步：`Docs/LanguageModel.md`、`Docs/CustomSkins.md`；`Docs/IntelligentCandidates.md` 标记为初次改造的历史记录。
