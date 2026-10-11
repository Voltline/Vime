# 分段转换、邻键纠错与语言资源

日期：2026-10-11。以本地工作区为事实来源，azooKey 固定修订为 `d59a28e4c7ca049aef04f29a91eae9677a7753f2`。产品版本保持 **1.0**；App 和扩展 build 对齐为 **10**，修复构建时发现的版本不一致警告。

## 本轮交付

已删除原生 Mac 入口、InputMethodKit 宿主、候选窗口、设置窗口、Mac tests、scheme、构建/安装/注册脚本及工程 target。保留通用 session、宿主协议和语言展示接口；`CandidateRankingMode` 留在共享候选目录。没有操作 macOS 当前输入源或卸载系统目录中的已安装副本。

新增可调分段转换、部分候选词频学习、两假名短词的单次邻键纠错、表记偏好与离线口语词库。没有修改触摸 ownership、Roman 解析、marked text 基础流程或模型训练与量化格式。

## 原因与设计依据

原有引擎并非完全没有部分候选：azooKey 的 `ConversionResult.firstClauseResults` 和 `mainResults` 后部包含首词/短段候选，选择路径也已能提交 `remainingComposition`。主要缺口在 Vime：最终列表截为 15 项，没有缩短转换范围的 UI；partial candidate 以整个 reading 计算 exact/full 优势；Vime 的频率层还要求 `fullConsumption`，因此短段选择不参与词频提升。

日语分段转换应明确转换范围，而不依靠“删掉后半段再重打”。参考了 [Apple 的日语文节转换说明](https://support.apple.com/ja-jp/guide/japanese-input-method/jpim10263/6.3/mac/26) 和 [Mozc 的 CommitSegments / ResizeSegment 接口](https://github.com/google/mozc/blob/master/src/converter/converter_interface.h)。实现直接复用固定 azooKey 的 Candidate、ComposingText 和会话 API，没有引入第二个转换引擎。

## 输入与候选流程

```text
原始 composition（即时 preedit，保持字面输入）
  → azooKey 整段 conversion / prediction
  → 首文节结果 + 一次首词范围查询
  → 小批匹配的离线词库条目
  → 表记 variant / script variant
  → scope-aware normalization / reranking / dedup
  → 当前 revision 的基本候选
  → 异步 LM / typo 补充（latest-wins）
  → 可见候选页
```

展开面板的标题显示 `前段｜后段`。首次点击 `−` 优先采用最佳完整 lexical candidate 的首词边界；之后每次缩短一个假名。`+` 加长，`整句` 恢复默认请求。最短范围为一个假名。范围变化只改变候选查询，不自动改写草稿。

用户例子已验证：`tennanhantenn` 的字面 reading 为 `てんあんはんてん`，范围缩至 `てんあん｜はんてん` 后可选「天安」；宿主插入「天安」，`hantenn` 原始后缀完整保留，preedit 为 `はんてん`；随后可选「飯店」。未知整体词也可继续缩短至单个假名，选择词典项或原样假名。

普通请求保留整句优先，在同一池加入首词候选。显式范围请求关闭预测扩展，`N_best=40`；普通整段保持原 `N_best=10`。不针对「天安」「ヨーロッパ」等词做特判。取消列表的 15 项截断；候选栏默认取 20 个，面板滚动每页增加 40 个，使用原列表 token 选择。分页接口避免主线程先生成数百个 annotation/token。

## Candidate Model 与排序

`CandidateSnapshot` 保留 native Candidate、source、revision、native composingCount、reading、engine score/rank、剩余 ComposingText、learning eligibility 和 correction metadata。新增：

- `consumedReadingCount`：对应当前输入的假名范围。
- `scopeReading` / `explicitScope`：用于当前转换段的 exact/full 判断。
- `displaySurface`：区分生成的表记与 native Candidate 的词典表记。
- `orthographyScore` 与 `features.orthography/segmentation`：可解释的表记/短段分数。

保持 `fullConsumption` 表示整份输入是否消费完；`scopeFullConsumption` 表示所选转换段是否完成。普通短段有集中管理的 6 分 penalty，使完成的合法整句候选优先；显式范围没有此 penalty。未完成 Roman suffix 的普通前缀不获得 exact/full scope bonus，避免把「ヨーロッパ時」之类短段抬到 `yo-roppajin` 的预测「ヨーロッパ人」之前。

原有 engine order/value、script consistency、continuity、prediction overrun、context、user learning 和 typo cost 继续参与。表记偏好总分限制为 ±1.6，既参与经典排序，也加入最后的神经个性化分数，反复用户选择可覆盖默认偏好。真实 native 表记优先于生成表记保留。LM 只比较同一有效范围的 exact lexical conversions，不跨长度比较普通短段与整句的 log probability；冻结的模型 scorer 没有改变。

## 安全切分与学习

不能用 surface 字数直接切 raw Roman，也不能假定 `.surfaceCount` 总保留 Roman 后缀。azooKey 会把 `n+ha` 等视为一个独立片段，直接切 surface 可能冻结后面的 `ha`。`CompositionSegmentBoundary` 先使用 upstream input/surface 映射；必要时只在同一独立片段内寻找能通过 upstream parser 复现目标后缀的原始输入边界。确实无法独立切开的 `き｜ょ` 等使用 upstream frozen/surface-count 处理。

显式范围查询使用独立 prefix session，在匹配词库未变化时保留原整段 lattice。部分确认时，仅给 `setCompletedData` 的 context 副本映射实际 raw consumption；学习仍使用 untouched native Candidate。无法对应原 lattice 或外部 context 已变化时丢弃旧转换缓存，以免继续退格触发错误的 after-complete 范围。

部分 native lexical 候选现在也记录其自身 reading 的词频，复用既有宿主回执、保留时间、撤销取消、频率衰减和上下文收缩。真实 Candidate 仍通过 `setCompletedData`、确认后 `updateLearningData` 和边界批量 `commitUpdateLearningData` 接入 azooKey。没有按每个 keystroke 写盘。

新增测试验证：非 Top1 的部分候选「箸」重复确认后 **第 2 位 → 第 1 位**，引擎重建后仍有 azooKey learned evidence 和 Vime 频率分；取消 staged feedback 不产生持久化偏好。生成的表记不把原汉字 Candidate 假装成用户选择的假名反馈给 azooKey，只在 Vime 的 style scope 中记录偏好。学习目录、清空能力和宿主外部变更的 reconcile 流程继续复用现有实现。

学习记忆负责用户选择；LM 负责当前语境的语言自然程度。二者继续独立；选择前段后，已提交前段成为剩余候选的左侧上下文。

## 邻键纠错

原先 `generate` 的最短 reading 是三假名，因此 `dedu` 的两假名 `でづ` 不进入邻键搜索。现在两假名、至少四个纯 Roman 输入元素开放**单处邻键替换**，不用删除/插入/换位/两处音近通道，admission margin 由 2 增至 4，仍需真实词典与连接成本增益。单假名保持关闭，末尾未完成辅音仍不纠正。

`dedu → desu → です` 已验证，`arigatougozaimadu → ありがとうございます` 的句内邻键路径也验证可产生建议；`desu`、`masu`、`sushi`、`kega` 正常输入在定向样本中没有纠错。没有偷偷改写 preedit。原有最多两处音近混杂通道与 query/budget 上限保持不变。

方法遵循错误通道与词语/语境证据分离的思路，参考 [Brill & Moore 的噪声通道研究](https://aclanthology.org/P00-1037.pdf)；[Gboard 的键位空间个性化研究](https://research.google/pubs/spatial-model-personalization-in-gboard/)说明个性化坐标需要实际样本，本轮没有假装已有触点学习数据。

## 表记与词库数据

官方依据为文化厅 [《公用文作成の考え方》解説](https://www.bunka.go.jp/seisaku/bunkashingikai/kokugo/hokoku/pdf/93731901_01.pdf)，参考其挨拶、当て字和辅助用言等区别。公用文建议不是对所有私人聊天的强制规则。辅助用言、形式名词需要语义角色，因此本轮没有无条件把所有「事」「下さい」「見る」替换成假名。

实际数据来自 **2026-10-11 的 JMdict**，格式与标记含义见 [EDRDG DTD](https://www.edrdg.org/jmdict/jmdict_dtd_h.html)。

| 数据包 | 本轮内容 |
| --- | --- |
| `OrthographyPreferences.json` | 2,000 项；1,890 项 dictionary usage、102 项 ateji guidance、8 项直接公用文表记 |
| `SupplementalLexicon.json` | 2,000 个 reading/surface 项，1,543 个 reading；307 项 Internet slang，1,100 项 slang（标签可重叠） |
| `LanguageResourceSources.json` | upstream 日期、SHA-256、输出 count/hash、许可与重建命令 |

「怪我」在 JMdict 中是 **ateji**，不是 `uk`；「けが」偏好来自公用文当て字方针与该词典事实的结合，没有把它说成文化厅明确逐词规定。已验证「けが」在经典和神经排序都先于「怪我」；生成 variant 保留 native lexical evidence，但不得错误学习原表记。

词库优先网络用语、slang、漫画用语，其次一般口语/缩写；只导入名词，排除过时、粗俗、贬义标签，避免把外部词典 POS 编号或活用规则复制进 azooKey。词典的 tagged entry 可能多义，本轮筛选不能替代语义消歧。部分增量词与已捆绑词典重叠，统一候选去重；不把 2,000 项宣称为 2,000 个此前完全不存在的词。

运行时以 reading 索引查找前缀，每个 reading 最多四个 surface；只有匹配的小批条目进入 `importDynamicUserDictionary`，变化时才重装，统一采用 azooKey 自己的一般名词 CID/MID 和保守的 -18 初始值，不加载整个外部词典。词库也能用于分段后的剩余查询。

衍生 JMdict 数据采用 [CC BY-SA 4.0](https://www.edrdg.org/edrdg/licence.html)，完整许可及修改说明在 `ThirdPartyNotices.txt` 和 App 开源许可页，应用代码许可独立。`Scripts/build_language_resources.py` 可从保存的 upstream gzip 离线重建，排序、限额与哈希可复现。更新时下载新文件并重新筛选/审核，不在键盘输入时联网。

调查了 Sudachi、NEologd、SKK 与 BCCWJ。默认 azooKey 词典已有相关基础词库；本轮用 JMdict 的明确标签构建小包，避免加入大包重复词或未核实再分发条件的数据。没有将 SKK 主词库或 BCCWJ 频率表直接打入产品，也不把 NEologd 的历史 seed 当成最新网络用语。

## 验收与性能

模拟器：iPhone 16 Pro Max / iOS 27.0，Xcode 27.1，Debug；本轮没有重新跑全部触摸、Emoji、模型 benchmark 或实机 suite。

先运行本地改动前的现有候选语料测试捕获基线；四个代表例子前三候选如下（无外部上下文）：

| 输入 | 改动前前三项 | 本轮前三项 |
| --- | --- | --- |
| `yo-r` | ヨーロッパ / よーr / ヨーr | ヨーロッパ / よーr / ヨーr |
| `yo-roppa` | ヨーロッパ / europe / よーろっぱ | ヨーロッパ / europe / よーろっぱ |
| `yo-roppajin` | ヨーロッパ人 / よーろっぱじn / ヨーロッパジn | ヨーロッパ人 / よーろっぱじn / ヨーロッパジn |
| `be-to-ben` | ベートーベン / べーとーべn / ベートーベn | ベートーベン / べーとーべn / ベートーベn |

新增六项测试覆盖实际分段选择、每个假名边界、Roman 尾部保留、学习重建与取消、短词纠错保护、表记/词库、uncapped pool 与计时。另选取原有宿主 token/backend、n、preedit、候选语料、逐键连续性和确认回执测试。14 项与 9 项两个功能验收批次均通过，有重叠，不按 23 个不同测试计算。

短输入与词组的同步 engine 定向计时（4–7 个小样本，包含冷转换）：

| 阶段 | mean ms | p95 ms | max ms |
| --- | ---: | ---: | ---: |
| 原始 conversion | 30.41 | 22.91 | 121.59 |
| 首词补充 conversion | 1.28 | 1.39 | 2.69 |
| unified reranking | 2.18 | 3.54 | 4.72 |
| 增量词库查找（已加载） | 0.009 | 0.012 | 0.018 |
| context reconciliation | 4.15 | 0.001 | 20.76 |
| typo search | 21.87 | 36.11 | 64.09 |
| 基础候选整条计算（含 context / alternatives / prefix） | 63.20 | 49.94 | 197.83 |

这些不是实机电量、Release 延迟或可靠总体 p95；小样本的 p95 定义取排序后的下分位，不涵盖单次冷峰值。typo 的 60ms deadline 在查询之间检查，一次不可中断的 upstream 查询可能超过截止时间。所有该类工作位于 worker queue，preedit 不等待它。

另通过实际 UIKit 的 70 次按键测试：触摸视觉反馈 p95 **0.29ms**，按键→preedit p95 **1.33ms**（mean 1.36ms，首次 UIKit 使用峰值 36.08ms），候选发布 p95 **4.17ms**（3 次发布，最大 14.27ms）。突发、候选中途发布后继续输入、最终候选和全部 70 键的字面 composition 均正确；过期请求不覆盖新输入。

长句 Debug 背景候选计算 mean **150.07ms**、最大 **430.58ms**，请求→结果 mean **188.47ms**、最大 **494.88ms**；这表明冷词典/模型、n alternative 和不可中断请求仍影响候选出现时间，不能将即时 preedit 误说成所有候选也即时。数据包含模拟器、Debug upstream 日志与冷初始化，尚无本轮实机 Release 的同口径数据。该测试同步等待一个实际中途结果，避免假设冷模型一定在 20ms 键间隔内完成；产品没有增加 debounce。

最终通过的定向测试共 **19 个不同 case**（包含多个重叠复核批次），完成后主 App 和键盘扩展的 Debug 构建也通过。编译仍有原诊断审计代码读取主 actor 偏好的隔离 warning 和 AppIntents metadata 提示，本轮没有扩大为整个项目 warning 清理。诊断增加 `lexiconLookup` 和 `prefixConversion`；候选诊断包含 scope 与新增 score。运行时不默认记录宿主文本。验收记录见 [SegmentedConversion20261011.json](Validation/SegmentedConversion20261011.json)。

## 当前限制

- 分段能力受词典和用户选择影响；未知固有名词没有保证一个整词候选，但可以分小段逐步构成。
- 不可独立拆开的拗音内部会使用 azooKey frozen kana；普通词边界尽量保留 Roman suffix。
- 显式范围查询当前不额外跑 typo；选中前段后，剩余输入重新走普通纠错路径。没有自动按可信度改写草稿。
- 两假名邻键通道仍偏保守，不保证修复每个有效同音词；没有训练个性化触点概率或新神经错误通道。
- 表记表是有限数据与有上限的偏好，不是完备规范或严格语义分析器；小词库不保证实时追踪所有流行语。
- 词典查询与冷 LM 加载开始后不能立即中断，候选可能延后；revision/token 保护保证过期结果不会提交或覆盖新输入。没有用固定 debounce 隐藏耗时。
- 保留旧宿主的外部修改/caret reset 行为；未在本轮验证所有第三方 App 的 marked-text 差异。

本轮没有 archive/上传。

## 分段确认修复（2026-10-11）

用户进一步明确了实际路径：在备忘录和 ChatGPT App 输入 `tennanhantenn`，展开完整候选菜单点击「天」，整份 `天あんはんてん` 失去继续转换的状态。同步文本框测试中，这个候选自身的消费量正确：reading 为 `テン`，剩余 Roman 为 `anhantenn`、reading 为 `あんはんてん`。因此不能把引擎消费量或确认键入口的修复当成这个点击问题的结论。

扩展控制器原来只在同步调用 `insertText` / `setMarkedText` 期间设置 `isApplyingEdits`，随后立即记录 proxy 的实际上下文。如果宿主稍后才更新 proxy 并发出 `textDidChange`，已提交「天」的新上下文与记录的旧上下文不同，就会被当成外部编辑，调用 `host.abandon()` 和 `keyboard.resetComposition()`；后段的文字仍在正文，session 和候选却被清空。新增测试直接继承实际 `KeyboardViewController`，使用写入真实 `UITextView`、延迟发布 context 的 `UITextDocumentProxy`，按用户给出的完整菜单点击路径验证此问题。禁用自身提交回执识别后，该测试在延迟通知到来时从 `输入中：あんはんてん` 变为 `あ`，定向失败；启用后通过。此测试证明这条回调时序缺陷，不等同于采集到了用户设备上两个 App 的实际回调轨迹。

现在候选确认的 committed edits 和剩余 preedit 在一个宿主事务中应用，避免两者间的同步通知缝隙；`KeyboardPartialCommitReceipt` 只接受本次实际发出的前段插入、对应的后段 mark、同一 document、同一右侧 context、无外部选择的回执。兼容宿主先发布前段、再发布后段 mark 的步骤；比较有限左侧窗口，保持 proxy 的 context 截断兼容性。它不使用时间宽限，不吞任意宿主变更；异字段、外部文字、真正光标移动仍拒绝并 reset。收到最终回执后清除；新的提交或 session reset 也替换/清除。字段身份优先使用公开的 [documentIdentifier](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/documentidentifier)，通过 Objective-C 对象读取避免 disconnected proxy 的 nil UUID 桥接崩溃；不可用时回退旧对象身份。学习与撤销锚点使用同一字段身份，缺少可核实的即时学习回执时继续采取取消学习的保守策略。

同时确认了独立的确认键遗漏：调整 `conversionLength` 只改变查询范围，不设置 `selectedIndex`，但 `confirm()` 在没有空格预览时直接走整段字面假名 fallback，没有检查范围。

改动前，输入 `toukyouhantenn`、选定 `とうきょう｜はんてん` 后按确认，无论候选是否已返回，都会插入 `とうきょうはんてん` 并清空整个 composition。现在候选已返回时确认当前高亮候选「東京」，只保留 `hantenn` 等待下一次转换；候选仍在计算时，立即确认所选范围的 `とうきょう`，保留同样的原始 Roman 后段。后者取消旧请求并创建新的 revision，过期前段结果不能覆盖剩余输入。普通整句字面确认和明确结束全部 composition 的 `confirmAll()` 边界语义继续保留。

新增六个分段 UI/session 用例：范围确认无需空格、候选尚未返回时的范围确认与旧结果拒绝、实际展开面板点击「天安」后继续选「飯店」、关闭范围面板后使用确认键并继续选后段、直接点击自动首段候选「東京」后继续选后段，以及完整菜单点「天」后保留全部 `あんはんてん`。另加实际扩展控制器的延迟宿主测试及回执拒绝异字段/光标/外部文字测试。复核原有分段 Roman 后缀/学习、假名 preedit、disconnected 扩展控制器及面板布局三个用例，共十一项；App 和扩展同时完成 Debug 模拟器编译。没有做全量测试或 archive，版本仍为 1.0。此次复现未连接用户设备上的真实备忘录/ChatGPT App，尚需实机确认修复是否覆盖其具体回调行为。
