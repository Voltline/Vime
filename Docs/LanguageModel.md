# 本地语言模型

当前默认使用 [v2.1](LanguageModelV21.md)，其模型和 tokenizer 必须作为一组安装。以下参数、资源与性能表保留 v1 历史口径；通用推理流程仍适用。

Vime 的 v1 模型来自 [VimeML](https://github.com/Voltline/VimeML) 训练的 tiny-ja-v1（7.39M 参数日语 GPT），用于两件事：重排转换候选，以及在确定文字后联想下一个词。模型在设备上离线运行，最低系统 iOS 18。训练、转换与量化的细节见 VimeML 的 `docs/coreml.md`。

## 资源

| 文件 | 说明 |
| --- | --- |
| `Shared/Resources/TinyJapaneseINT8.mlmodelc` | Core ML 编译模型：权重 INT8 block32，计算 FP32，`.cpuOnly` |
| `Shared/Resources/VimeJapaneseTokenizer.model` | SentencePiece unigram，16,384 词表 |
| `Shared/Resources/VimeLMManifest.json` | tokenizer 与编译模型各文件的 SHA256；加载前逐一核对 |
| `Dependencies/VimeSentencePiece` | 官方 SentencePiece 0.2.1 源码 + C 桥接（模块 `CSentencePiece`），Apache-2.0 |

模型接口：输入 `input_ids` INT32 `[1,T]`（1 ≤ T ≤ 128，BOS=2，右侧 PAD=0），输出 `logits` FP32 `[1,T,16384]`。没有 KV cache。

## 代码

| 位置 | 职责 |
| --- | --- |
| `Shared/Models/VimeLanguageModel.swift` | 分词、`predict`、候选评分 `scores`、重排 `rerank`、下一个词 `nextWords`、句子续写 `suggestions`（beam，仅作参考实现）、句内上下文 `sentenceContext` |
| `Shared/Candidates/JapaneseCandidateWorker.swift` | 在候选串行队列上懒加载单个模型实例；按排序模式重排；执行联想请求 |
| `Shared/Input/KeyboardSession.swift` | 排序模式与联想开关；确定后发起联想，任何输入都会清除联想 |
| `Shared/UI/KeyboardView.swift` | 候选栏同时显示转换候选和联想；声音、振动、数字布局快捷设置 |
| `Shared/Preferences/KeyboardPreferences.swift` | `vime.candidateRanking`、`vime.phraseSuggestions` |

模型加载失败（资源缺失或哈希不符）时会记录日志，键盘照常使用词典候选。

## 上下文

模型只用单句训练（BOS + 一句 + EOS），没有见过跨句文本。所以重排和联想都只取光标前**当前句**：从最后一个 `。！？!?` 或换行之后开始，最多 64 个字符，并去掉开头的空白（`VimeLanguageModel.sentenceContext`）。字符截断后仍检查 token 长度；无法放入 128 token 窗口时保留词典顺序或跳过联想。

## 候选排序

主 App「键盘设置 → 智能输入」中的「词典排序 / 智能排序」，默认智能排序。下一词联想可独立开关；偏好通过 App Group 共用，键盘重新打开时刷新，并保留旧版已设置的选择。

- **词典排序**：AzooKey 的顺序（包含用户学习）加上 Vime 的特征重排，完全不调用模型。
- **智能排序**：先发布引擎结果，再在后台对其中「完整、精确读音、有词典依据」的普通转换候选按 LM 分数重新排序，只在这些候选原来占据的位置之间互换。部分转换、片假名、读音替代和纠错候选的位置不变。片假名模式下不重排。

LM 分数：`context + candidate` 整体分词，从与 context 的公共 token 前缀之后开始累加完整词表的 log-softmax，不加 EOS。分数相同时保持原顺序。出现以下情况时保留引擎顺序：序列过长、分词无法 roundtrip、请求被新输入取消、评分超过 250 ms。用户已经选中候选（空格选择）后，迟到的重排结果不会再改变列表。

## 下一个词联想

主 App 设置中的「下一词联想」开关，默认开启。

- **触发**：点选候选、回车确定、插入标点（`insertLiteral`）或点选联想之后，如果当前句还没结束（句子上下文非空），且不是英文模式。
- **生成**（`nextWords`）：取下一个位置概率最高的 15 个 token 作为起点，依次展开，直到凑够 5 个词：
  - 下一个 token 概率 ≥ 0.4 时继续向后接，最多 3 个 token；
  - 单个字符（敬语前缀「お」「ご」、汉字词干「飲」等）和 byte fallback 的半个字符必须再接一个 token，助词「は が を に で と も の へ や か ね よ な」除外；
  - 遇到 `。！？、，「」（）…・` 或换行时截断，以 ASCII 符号开头的候选丢弃，结果去重。
  - 结果都是词或短语，例如「コーヒーを」→ 飲み / 飲んだ / 飲む，「パスワードを入力して」→ ログイン / ください / 設定。
- **显示与使用**：结果显示在候选栏，不高亮任何一项。点一条即插入，然后基于新的上下文继续联想下一个词。
- **清除**：输入字母、退格、空格、回车、切换到英文、宿主光标或文档变化都会清除联想，并取消尚未完成的请求。

联想和候选请求共用同一个串行队列和取消槽，所以新的按键会立即中止正在进行的联想（每次 forward 前检查一次）。每次联想最多 1 + 5 × 2 = 11 次 forward。

## 测试

`Tests/UIKit/VimeLanguageModelTests.swift`：

| 测试 | 内容 |
| --- | --- |
| `testNativeSentencePieceMatchesFrozenCorpusAndUnicode` | 1000+ 条语料与 Unicode 样例的分词和解码与 Python 一致 |
| `testJointSuffixScoresMatchMacINT8IncludingBoundaryRetokenization` | 候选分数与 Mac INT8 参考相差 < 0.002 |
| `testWholePoolFallbackAndCancellation` | 重复 / 空候选、超长、取消、非法 ID 都会整体回退 |
| `testPaddingAndCausality` | 右 PAD 和未来 token 不影响有效位置 |
| `testRerankerRetainsMetadataAndExplicitScriptAndCancelledOrders` | 只在允许的位置之间重排，片假名与取消保持原序 |
| `testNativeBeamMatchesTwentyMacINT8Prefixes` | 20 个前缀的首选与 Mac INT8 一致 |
| `testSentenceContextKeepsOnlyUnfinishedSentence` | 句内上下文截取 |
| `testEngineRankingPublishesNoLanguageModelReorder` | 引擎排序模式下没有 LM 重排发布 |
| `testNextWordsAreShortAndStopBeforePunctuation` | 下一个词不含标点、不超过 4 个 token、不重复 |
| `testSessionShowsAndInsertsPhraseSuggestionsAfterCommit` | 确定 → 联想显示 → 点选插入 → 输入清除 |

`VimeLMFixtures.json`（测试资源）由 VimeML 的 Mac INT8 参考生成。

```sh
xcodebuild test -project Vime.xcodeproj -scheme Vime \
  -destination 'platform=iOS Simulator,name=Vime Keyboard QA' \
  -parallel-testing-enabled NO -only-testing:VimeKeyboardTests/VimeLanguageModelTests
```

## 设备性能

iPhone 16 Pro Max，`-O` 构建，`.cpuOnly`，`VimeLanguageModelBenchmarkTests`（运行方式见文件头注释），在测试宿主 App 进程内测量：

| 项目 | 结果 |
| --- | --- |
| 模型加载（含 SHA256 校验） | 首次 80 ms，再次 16 ms |
| 单次 `predict` | T1 1.1 ms、T16 0.67 ms、T64 1.8 ms、T128 3.0 ms |
| 单行 log-softmax（16,384） | 0.08 ms |
| 候选重排（20 组读音，平均 14 个候选） | p50 10.4 ms，p95 12.7 ms，最大 13.1 ms；没有超过 250 ms 的 |
| 下一个词 `nextWords` | p50 5.8 ms，p95 6.6 ms |
| 句子续写 `suggestions`（beam 8 × 8） | p50 44.5 ms |
| 对照：词典候选生成 | p50 13.8 ms，p95 32.2 ms |
| 内存 | 加载前 24.5 MB → 加载后 48.7 MB（+24.2 MB），宿主进程峰值 74.8 MB |

加载后增加的内存（约 24 MB）接近 FP32 权重的大小（29.5 MB），推测 CPU 路径会把 INT8 权重展开为 FP32 常驻内存：INT8 减小了包体积，但没有减少运行内存。键盘扩展进程的实际内存见 `Docs/LanguageModelMemory.md`。

### 计算单元

| 单元 | 结果 |
| --- | --- |
| `.cpuOnly` | 见上表 |
| `.cpuAndNeuralEngine` | 加载 361 ms，推理速度与 CPU 相同。这个包是 FP32 计算，ANE 无法执行，实际仍在 CPU 上运行 |
| `.cpuAndGPU`、`.all` | 进程直接崩溃：MPS `MPSNDArrayQuantizedGatherND` 断言失败（量化 embedding gather 在形状变化时出错） |

所以 `VimeLanguageModel` 固定使用 `.cpuOnly`。另有一个 FP16 计算、固定长度档位的版本（VimeML `scripts/deployment/coreml_ane.py`），在 Mac 上确实会跑在 ANE，但每次调用比 CPU 慢 3～4 倍，见 VimeML `docs/coreml.md#neural-engine`。

## 质量

见 VimeML `docs/coreml.md#质量`：INT8 相对 FP32 的平均 KL 为 0.006 nats/token，开发集与 AJIMEE 的 Top-1 与 FP32 相同（122/137、124/200）。这些是离线基准的结果；应用里的候选池包含预测、纠错和学习，和基准并不相同。

## 本次轻量检查与优化（2026-10-06）

- 保留评分、分词及模型资源，未重新执行准确率、吞吐量或内存基准；上文数据仍属于原评测。
- 片假名模式或不足两个可重排词典候选时，在 worker 中提前跳过模型加载。
- 清除联想时同时取消后台请求，避免空格、退格或英文输入后的过期生成继续占用队列。
- 关闭智能排序和下一词联想后，在所属串行队列上释放缓存模型；后续开启时按需加载。
- 主 App 管理完整设置，键盘只保留常用反馈与数字布局。设置快照未变化时不重建界面，移除原先每次 sandbox 更新时强制同步 UserDefaults 的行为。

本轮验证：App 与键盘扩展编译成功；四项定向检查通过（共享偏好迁移、现有键盘皮肤刷新、重排元数据/取消、确认后的联想与插入）。未运行全套回归、准确率基准、性能基准或内存压力测试。
