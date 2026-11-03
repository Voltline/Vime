# 候选质量基准

[KeyboardCandidateBenchmarkTests](../../Tests/UIKit/Diagnostics/KeyboardCandidateBenchmarkTests.swift) 在模拟器上驱动真实的 `JapaneseCandidateEngine`，逐键输入罗马字，统计用户看到的候选质量。它不调整模型，只衡量引擎、排序策略和随包的 VimeML 模型组合后的结果，用来比较排序策略改动前后的效果。

## 运行

```sh
bash Scripts/candidate_benchmark.sh               # everyday 两组；已构建 AJIMEE-Bench 时一并运行
bash Scripts/candidate_benchmark.sh --ajimee      # 先克隆并构建 AJIMEE-Bench 组
VIME_CANDIDATE_BENCHMARK_LIMIT=20 bash Scripts/candidate_benchmark.sh   # 每组只取前 20 条，快速查看
```

`VIME_SIMULATOR`、`VIME_DERIVED_DATA` 与 [test.sh](../../Scripts/test.sh) 相同，`--` 之后的参数交给 xcodebuild。脚本设置 `TEST_RUNNER_VIME_CANDIDATE_BENCHMARK=1` 后只运行 `testCandidateQualityBenchmark`；普通单元测试中该用例直接跳过，不影响 CI。报告写入 `Artifacts/CandidateBenchmark/report/`（已忽略），包括：

- `candidate-benchmark.md`：汇总表、分类表、首位错误原因计数，以及智能模式下每条首位错误的前五个候选；
- `candidate-benchmark.json`：每条用例在两种模式下的完整结果。

终端还会打印 `VIME_CANDIDATE_BENCHMARK` 汇总行。完整运行在本机 Debug 模拟器上约需 15 分钟，主要花在 AJIMEE-Bench 的长句上。

`testRomajiTypingReproducesReadings` 检查罗马字生成规则：ん 在辅音前打 `n`，在元音、y、n、标点和末尾前打 `nn`；っ 重复下一个辅音（ち 前为 `cch`，azooKey 不接受 `tch`）；长音符和读点、句点（ー、。）使用键盘上的独立按键。生成的罗马字无法还原读音的用例记为跳过，跳过数不为零时基准用例失败。

## 测量方式

每条用例从空组合开始，按会话的方式逐键请求候选：每次请求前用上一次显示的首选设置连续性，`includeCorrections: false`，与 worker 的首次发布路径一致。每条用例先运行一次再重置引擎，两种模式互不影响：

- **词典**：只用 `CandidateReranker` 的排序；
- **智能**：在词典排序之上用 `VimeLanguageModel.rerank` 重排，最多比较 `JapaneseCandidateWorker.initialRankingCandidateLimit`（8）个候选。基准不设 60 ms 发布窗口，等待评分完成，结果不受模拟器速度影响；实际键盘中错过窗口时会显示词典排序。

左侧上下文通过 `reconcileContext` 传入，智能模式使用 `VimeLanguageModel.sentenceContext`。基准使用独立的空学习目录，并要求用户词典为空。

| 指标 | 含义 |
| --- | --- |
| top-1 / top-3 | 最后一键后，消费整个输入的正解排在第 1 / 前 3 位 |
| 在列表中 | 正解出现在候选列表中的任意位置 |
| 首位为部分文节 | 首选只转换输入的前一段，其余留在 preedit |
| 部分文节压过正解 | 正解在列表中，且排在它前面的候选里有部分文节 |
| 半程 top-3 | 读音不少于 4 个假名时，在输入一半读音、没有未完成罗马字的那一键，完整正解已在前 3 位（不含最后一键） |
| 可省按键 | 正解首次进入前 3 位后剩余的按键数，占全部按键的比例 |

首位错误按原因归类：`partial_clause`（部分文节）、`prediction`（读音更长的预测）、`kana_over_kanji` / `kanji_over_kana`（正解与首选一个是读音本身的假名，一个不是）、`homophone_or_segmentation`（同音异字或切分不同）、`missing`（正解不在列表中）、`correction`（纠错候选）。

半程 top-3 和可省按键只计算与正解完全一致的预测。读音更长的预测带 `predictionOverrun` 惩罚，排在当前读音的转换之后，所以输入一半时完整短语很少进入前 3；可省按键大多是在最后一个音节的辅音键处已出现正解。

## 数据

| 组 | 条数 | 来源 | 许可 | 是否入库 |
| --- | --- | --- | --- | --- |
| everyday | 240 | 为本基准编写的日常短输入 | GPL-3.0-or-later，与本仓库相同 | 是，[CandidateBenchmarkEveryday.json](../../Tests/UIKit/Resources/CandidateBenchmarkEveryday.json) |
| everyday-learned | 240 | 同上，换用带学习记录的引擎 | 同上 | 同上 |
| ajimee | 159 | [AJIMEE-Bench](https://github.com/azooKey/AJIMEE-Bench) `JWTD_v2/v1/evaluation_items.json`，源自日语维基百科输入错误数据集 | CC BY-SA 3.0 | 否，本地生成 |

everyday 覆盖单独输入的助词（35）、带上下文的助词（18）、助词短语（16）、问候（26）、惯用语（25）、语法结构（22）、常用词（40）、片假名词（12）、活用（16）和短句（30）。每条用例可以有多个可接受的写法（例如「お疲れ様です / お疲れさまです」）。单独输入的助词没有左侧上下文，「から / 空」这类候选本身有歧义；带上下文的同类输入另成一组。

everyday-learned 在运行前用 `CandidatePreferenceMemory` 写入一组常被单独确认的短文节（で、は、に、が、を、と、も、の、か、へ、や、ね、よ、手、目、気、日、今、私、本、前、中），每个在 conversion 和 choice 两种范围各记录 4 次，模拟这些文节已被单独确认过的用户。这一组测量学习记录会不会把较长的读音拆开。

AJIMEE-Bench 的许可不能转为 GPL-3.0，数据和生成结果都放在已忽略的 `Artifacts/CandidateBenchmark/`。[build_candidate_benchmark_corpus.py](../../Scripts/build_candidate_benchmark_corpus.py) 克隆仓库（或用 `--source` 指定已有的检出），只保留读音仅由片假名和 ー、。 组成的 159 条（共 200 条），转为平假名后写入 `ajimee.json`，并记录来源的提交号。有上下文的条目归为 `contextual`，其余为 `plain`。

不能用模型训练过的文本评测。v2.1 与 v4.2 的训练数据包括 FineWeb2-Edu 日语、Tatoeba、RealPersonaChat 与 Multi-Relational Multi-Party Chat Corpus（见 [vimeml.txt](../../Vime/Resources/Licenses/vimeml.txt)），用它们评测时，智能模式的分数主要反映模型对原句的记忆。因此不使用 Tatoeba 等常见例句集；AJIMEE-Bench 来自维基百科，不在上述训练集中。

## 结果

模型 v4.2（`4.2-epoch20-step1081942-int8-b32-v1`），Debug 构建，iOS 27.2 模拟器，2026-11-03。AJIMEE-Bench 取自 `JWTD_v2/v1` 的 159 条。

| 组 | 模式 | 条数 | top-1 | top-3 | 在列表中 | 首位为部分文节 | 部分文节压过正解 | 半程 top-3 | 可省按键 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| everyday | 词典 | 240 | 90.4% | 97.5% | 99.6% | 0.0% | 0.0% | 0.6% | 17.3% |
| everyday | 智能 | 240 | 93.8% | 99.2% | 99.6% | 0.0% | 0.0% | 0.6% | 17.3% |
| everyday-learned | 词典 | 240 | 90.4% | 97.1% | 99.6% | 0.0% | 1.2% | 0.0% | 17.2% |
| everyday-learned | 智能 | 240 | 93.8% | 99.2% | 99.6% | 0.0% | 1.2% | 0.6% | 17.0% |
| ajimee | 词典 | 159 | 47.2% | 67.3% | 71.7% | 0.0% | 0.0% | 0.0% | 0.8% |
| ajimee | 智能 | 159 | 67.3% | 71.1% | 71.7% | 0.0% | 0.0% | 0.0% | 0.8% |

### 学习记录拆开完整读音

加入部分文节规则（见 [候选与联想](../Architecture/Candidates.md)）之前，everyday-learned 组有 34 条首位是部分文节：

| 组 | 模式 | top-1 改前 | top-1 改后 | 首位为部分文节 改前 → 改后 |
| --- | --- | --- | --- | --- |
| everyday-learned | 词典 | 76.7% | 90.4% | 14.2% → 0.0% |
| everyday-learned | 智能 | 80.4% | 93.8% | 14.2% → 0.0% |

用户单独确认过「で」后，输入 deha 首选变成「で…」，「では」排第二；には、とは、でも、ので、のに、にも、への、でしか 等同理。原因是选择记忆按文节自身读音记录，「で」的学习加分（约 11.5）超过了部分文节的分段惩罚（6），而智能模式只比较完整候选，部分文节保持原位，模型无法纠正。改后这些输入的首选回到完整读音，部分文节排在第二位，与没有学习记录的 everyday 组结果一致；everyday 与 ajimee 组的结果不变。

剩下的 1.2%（3 条）是部分文节排在第二、正解排在第三或更后，例如「かどうか」的首选为「華道家」。首选不是部分文节，属于下面的同音问题。

### 其余错误

everyday 智能模式的 15 条首位错误：

- 无上下文的单独助词 8 条：から → 空、だけ → 竹、しか → 歯科、なら → 奈良、とも → 共、との → 外、での → 手の、くらい → クライ。这些读音单独输入时本身有歧义；带左侧上下文的同类输入（particle_in_context）智能模式全部正确。
- 汉字压过假名：こんにちは → 今日は、ただいま → ただ今、ました → 増田。
- 假名压过汉字：みてください、まってます（正解排第二）。
- 同音：あした → 朝。
- 缺失：おまたせしました 的候选中没有「お待たせしました」，只有「おまたせしました」「御またせしました」。

词典模式另有「まで → 間で」「ばかり → 秤」「お疲れ様です」排在假名之后等，智能模式能纠正其中大部分；短句类 top-1 词典模式为 80.0%，智能模式为 100%。

AJIMEE-Bench 的主要问题是长句缺失（44 条正解不在列表中），智能模式把同音错误从 39 条降到 7 条。

半程 top-3 很低是排序取向的结果：只有读音更长的预测才能在输入一半时给出完整正解，它们带预测延伸惩罚，排在当前读音的转换之后。
