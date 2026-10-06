# Vime

Vime 是一款 iOS 日语罗马音输入法，提供 QWERTY 键盘、平假名 / 片假名、英文输入和离线假名汉字转换。主 App 内置试打区，系统键盘扩展可在支持第三方键盘的 App 中使用。

输入时，宿主输入框即时显示假名草稿（preedit）；尚未完成的辅音保留为罗马字。候选在后台持续预测，每次按键和假名退格都会发起更新，无需等到音节完成。

## 功能

- 26 字母 QWERTY；支持平假名、片假名和英文切换，提供系统、樱花、海蓝、深夜四种皮肤。
- 离线词典转换与预测，支持单词、部分候选和完整句子转换。
- 内置本地日语语言模型（7.4M 参数，INT8）：可选用 LM 重排转换候选；确定文字后在候选栏联想下一个词。详见 [本地语言模型](Docs/LanguageModel.md)。
- 输入停顿后提供离线误输与近音建议，候选旁显示建议读音；草稿仍保留字面假名，点击建议才采用。
- 按显示的假名退格；未完成辅音逐字符删除，长按退格连续删除。
- 连续触摸面覆盖键缝，小幅手指漂移保留原键，上滑符号在松手时确认。
- 按键预览使用实色浮窗，始终位于候选栏上方；工具栏与表情页保持固定顶部间距。
- 横滑按键区域移动光标，长按空格后可横向和纵向拖动，包含自动折行文字；系统键盘纵向定位使用近似排版。
- 退格上滑删除本行光标之前的内容，滑回可取消；删除后可在假名切换按钮左侧撤回。
- 日语第二行 `L` 右侧提供 `ー` 长音键；数字默认九宫格，可改为全键盘。
- 单行候选保留片假名入口；展开后只显示候选面板，返回后恢复候选栏。
- 分类浏览 Emoji 和 160 个颜文字，面板占用整个键盘区域，提供明确的「返回键盘」按钮。
- 主 App 提供可上下拖动的键盘高度预览，保存后同步到系统键盘。

## 安装与启用

项目最低部署版本为 iOS 18，已使用 Xcode 27.1 构建验证。UIKit 管理键盘的系统材质；iOS 26 及以上使用对应系统外观。

1. 用 Xcode 打开 [Vime.xcodeproj](Vime.xcodeproj)，选择 `Vime` scheme。首次构建需要联网下载 SwiftPM 依赖及捆绑词典，依赖修订已固定在 [Package.resolved](Vime.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)。
2. 在模拟器或 iPhone 上运行主 App，点击「开始试打」即可体验。安装到自己的 iPhone 前，为 `Vime` 和 `VimeKeyboard` target 配置签名团队和相同的 App Group（当前为 `group.com.Voltline.Vime`）；实机测试还需配置 `VimeKeyboardTests` 的签名。更换 bundle ID 时请同时更新 App Group 和 entitlements。
3. 在 iPhone「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」中添加 Vime。
4. 打开支持第三方键盘的 App，长按地球键，选择「Vime 日本語」。
5. 如需按键声、振动及从主 App 同步设置，在「设置 → 通用 → 键盘 → 键盘 → Vime 日本語」中开启「允许完全访问」。基本输入和词典转换无需此权限；静音会关闭按键声。

更新安装后，可先切换到其他键盘再切回 Vime，让系统扩展重新加载。

## 输入与操作

| 操作 | 行为 |
| --- | --- |
| 输入罗马音 | 即时显示假名；未完成辅音保留为罗马字并持续请求预测 |
| 空格 | 开始转换，再次按下切换候选；候选尚未就绪时保留转换意图 |
| 点击候选 | 确认该候选；部分候选只消费对应输入，剩余内容继续组合 |
| 回车 | 确认当前假名或已选候选；没有组合文字时执行宿主回车动作 |
| 退格 | 转换预览中先取消选择；平常删除一个显示字符；无组合文字时删除宿主文字 |
| 长按退格 | 连续删除；删空后停止声音、振动和重复，松手或取消后停止 |
| 退格上滑 | 向上滑动进入删行手势后才出现红色提示；松手删除当前换行符分隔行的光标前内容，滑回或系统取消不删除 |
| 删行后撤回 | 假名切换按钮左侧出现撤回按钮；恢复刚删的文字，继续输入或移动光标后失效 |
| 按键区域横滑 | 暂时隐藏键帽，左右移动宿主光标，松手恢复键帽 |
| 长按空格后拖动 | 暂时隐藏键帽，左右及上下移动光标；试打区按实际显示行定位，系统扩展按近似折行定位 |
| 字母键上滑 | 显示额外符号预览，松手输入；滑回可撤销，系统取消不输入 |
| `あ` / `ア` | 切换平假名和片假名 |
| 底部日英按钮 | 切换日语和英文输入 |
| 表情键 | 打开全区域 Emoji / 颜文字 / 符号分类面板，点击文字直接插入，点击「返回键盘」退出 |
| 数字 → 符号 | 分类浏览常用、箭头、标点、括号、数学、序号、单位、图形、字母、上下标及其他符号 |
| 左上角蓝色 Vime 标志 | 快速设置声音、振动 0…5 档和数字布局；其他偏好在主 App「键盘设置」中调整 |
| 点击联想 | 确定文字后候选栏显示的下一个词；点击插入并继续联想，任何按键都会清除 |
| 主 App「调整键盘高度」 | 上下拖动预览顶部横条，实时调整键盘高度；保存后重载系统键盘生效，也可恢复默认 |

输入期间，顶部工具按钮让位于候选栏。所有偏好保存在 App Group 中，由主 App 与系统扩展共用；共享位置未设置的选项会迁移各自已有的偏好。同步需要允许完全访问，键盘重新打开时应用变更。主 App「键盘设置」提供智能排序、下一词联想、皮肤、长音键、按键预览、高度及反馈设置。

### 罗马音与退格示例

| 输入 / 操作 | 显示或结果 |
| --- | --- |
| `nihongo` | 草稿 `にほんご`，可转换为 `日本語` |
| `naniwo` | 草稿 `なにを`，可转换为 `何を` |
| `nn` | `ん`；一次退格删除整个 `ん` |
| `kanna` / `konna` | 草稿 `かんあ` / `こんあ`，候选提供 `かんな` / `こんな` |
| `konnichiha` / `konichiha` | 字面草稿 `こんいちは` / `こにちは`，候选优先提供 `こんにちは` |
| `sonnna`（`so + nn + na`） | `そんな` |
| `renai` / `rennai` | 草稿 `れない` / `れんあい`，均可选择 `恋愛` |
| `kan` 后接 `a` / `ya` | `かn → かな` / `かにゃ`；末尾单个 `n` 仍可继续组成音节 |
| `nanim` | 草稿 `なにm`，未输入 `o` 时也能预测 `何も` |
| `shitsuka` | 草稿 `しつか`，停顿后可建议 `静か` / `しずか`，标注建议读音 `しずか`；未选词时回车仍确认 `しつか` |
| `ki` / `ko` | 分别保持 `き` / `こ`，短合法输入不生成通用纠错；后续词句可提供更多词典证据 |
| `nanimo` 后退格一次 | `なにも → なに`，完成的 `mo` 作为一个假名删除 |
| `sh` 后退格一次 | `sh → s`，未完成辅音逐字符删除 |
| `kya` 后退格一次 | `きゃ → き`，小假名可单独删除 |
| 片假名模式输入 `ko-hi-` | `コーヒー`；`-` 与专用 `ー` 键均可输入长音 |

长音键默认显示在日语第二行，设置中可以隐藏；隐藏后或切换英文时，第二行恢复九键缩进。底部为六键布局，保留较宽空格。

## 实现与项目结构

转换使用 [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)，固定修订 `d59a28e4c7ca049aef04f29a91eae9677a7753f2`，默认词典由 SwiftPM 捆绑。转换使用词典分词及语法连接评分，优先完整读音匹配，并为未完成的辅音提供预测。运行时转换与纠错无需网络；未启用经典 typo 开关、英文预测或 Zenzai。候选重排与联想使用 Vime 自带的 Core ML 模型，见 [本地语言模型](Docs/LanguageModel.md)。

`n` 的其他可能边界只用于候选查询，保留字面假名草稿；未选词时回车确认字面输入。备选查询与原查询共用词典缓存，但使用独立转换会话。平假名与片假名变体参与统一特征排序并按表记去重，片假名模式优先对应表记。

通用纠错在正常候选发布后等待 140 ms，期间的新输入会取消旧搜索。仅探索一处邻键、漏字、多字、转置或近音错误，通过词典读音、词句连接分数和错误成本筛选；不使用示例整词替换表。最多 384 个变体、24 次词典查询、3 个补充候选，搜索有 60 ms 软预算。单次上游转换无法中断，冷查询可能超过该预算。完整建议按原输入元素数消费，包括分隔符；后到结果不能改变已选候选。详见 [纠错调研与实现记录](Docs/KeyboardCorrectionResearch.md)。

| 路径 | 职责 |
| --- | --- |
| [Vime/](Vime/) | SwiftUI 主 App、启用指南、开源许可和试打容器 |
| [Keyboard/](Keyboard/) | 系统键盘扩展、宿主回调和完全访问配置 |
| [Shared/KeyboardSession.swift](Shared/KeyboardSession.swift) | 输入状态、假名退格、模式切换、转换与提交 |
| [Shared/RomajiConverter.swift](Shared/RomajiConverter.swift)、[PreeditPresentation.swift](Shared/PreeditPresentation.swift) | `n` 候选读音查询、字面假名显示和确认边界 |
| [Shared/JapaneseCandidateEngine.swift](Shared/JapaneseCandidateEngine.swift)、[JapaneseCandidateWorker.swift](Shared/JapaneseCandidateWorker.swift) | 候选生成与排序、后台串行计算、过期请求处理 |
| [Shared/KeyboardCorrectionVariants.swift](Shared/KeyboardCorrectionVariants.swift)、[CorrectionReadingIndex.swift](Shared/CorrectionReadingIndex.swift)、[CandidateSnapshot.swift](Shared/CandidateSnapshot.swift) | 有限误输变体、词典轻量索引、纠错读音与原输入消费元数据 |
| [Shared/VimeLanguageModel.swift](Shared/VimeLanguageModel.swift)、[Dependencies/VimeSentencePiece/](Dependencies/VimeSentencePiece/)、[Shared/Resources/](Shared/Resources/) | 本地语言模型：SentencePiece 分词、Core ML 推理、候选评分与下一个词联想 |
| [Shared/KeyboardHostConnection.swift](Shared/KeyboardHostConnection.swift) | 通过 UIKit marked text 更新宿主草稿并提交文字 |
| [Shared/KeyboardTextNavigation.swift](Shared/KeyboardTextNavigation.swift) | 组合字符安全的光标移动及行内删除 |
| [Vime/KeyboardSettingsView.swift](Vime/KeyboardSettingsView.swift)、[Vime/KeyboardHeightEditor.swift](Vime/KeyboardHeightEditor.swift)、[Shared/KeyboardHeightAdjustmentView.swift](Shared/KeyboardHeightAdjustmentView.swift) | 主 App 高度拖动预览及共享高度设置 |
| [Shared/KeyboardView.swift](Shared/KeyboardView.swift)、[KeyboardMetrics.swift](Shared/KeyboardMetrics.swift) | 主 App 与扩展共用的界面、候选条、布局和设置 |
| [Shared/KeyboardTouchSurface.swift](Shared/KeyboardTouchSurface.swift) | 连续触摸面、唯一按键归属、多指状态、符号上滑和光标/删行手势 |
| [Shared/KeyboardSymbolPanel.swift](Shared/KeyboardSymbolPanel.swift)、[KeyboardSymbolCatalog.swift](Shared/KeyboardSymbolCatalog.swift) | 复用网格单元的 Emoji / 颜文字面板及分类数据 |
| [Shared/KeyboardTheme.swift](Shared/KeyboardTheme.swift) | 四种皮肤的键帽、功能键、文字与强调色 |
| [Tests/UIKit/](Tests/UIKit/) | 输入、预测、宿主集成、触摸与性能回归 |
| [Docs/](Docs/)、[Artifacts/](Artifacts/) | 实现记录、验收与性能数据；测试截图仅在本地保留 |

主线程即时更新输入与 marked text，词典计算在后台串行执行。未开始的旧请求可取消，过期结果不会覆盖新输入。仅在当前候选计算期间保留上一轮列表，旧列表不能选词；当前结果就绪后立即发布。候选条复用按钮、缓存文字宽度并直接排布，语言图标只在模式或外观变化时重绘。

触摸由整个键盘的连续 surface 接收，先按可见键本体、再按行与键间中线唯一分配。轻微漂移保持归属，明显进入邻键才切换；上滑锁定原键。触摸面和候选 padding 绘制极低透明度背景，避免系统扩展在完全透明键缝处丢失事件。详细根因、架构与调研链接见 [实现文档](Docs/KeyboardImplementation.md)。

旧 Mozc 精简词典与生成脚本保留为历史资料，已从构建资源中排除，不参与当前转换。

Emoji 数据由 [Unicode 18.0 的 emoji-test.txt](https://www.unicode.org/Public/18.0.0/emoji/emoji-test.txt) 生成，共 3,972 个标准序列（fully-qualified 与 component），包含肤色、组合序列及旗帜，省略同一符号的重复表现形式。用 [Scripts/generate_symbol_catalog.py](Scripts/generate_symbol_catalog.py) 从该文件重新生成资源；运行时不联网。是否能显示某个新 Emoji 取决于当前 iOS 字体。

纠错优先索引由同一固定修订的词典生成，包含读音哈希、词条成本和词类连接 ID，不含针对示例挑选的整词表。用 `python3 Scripts/generate_correction_readings.py <SwiftPM checkout 中的 Dictionary 目录>` 重新生成 [CorrectionReadings.bin](Shared/Resources/CorrectionReadings.bin)。索引仅用于安排查询顺序，最终建议仍必须由转换引擎验证读音和完整消费。

## 开发与测试

测试使用模拟器中的真实词典引擎。先准备一个 iOS 模拟器；以下命令使用本地名为 `Vime Keyboard QA` 的设备，也可替换为自己的模拟器名称或 ID。

只检查核心输入、退格和转换：

```sh
./Scripts/test_core.sh
```

检查罗马音草稿、逐键预测及布局：

```sh
xcodebuild test -project Vime.xcodeproj -scheme Vime \
  -destination 'platform=iOS Simulator,name=Vime Keyboard QA' \
  -parallel-testing-enabled NO \
  -only-testing:VimeKeyboardTests/KeyboardPreeditTests \
  -only-testing:VimeKeyboardTests/KeyboardPredictionTests \
  -only-testing:VimeKeyboardTests/KeyboardIntegrationTests/testReferenceLayoutAndToolbarHitTesting
```

按改动选择测试：触摸归属改动运行 `KeyboardTouchTests`，候选刷新或延迟改动运行 `KeyboardPerformanceTests`，宿主行为改动运行 `KeyboardIntegrationTests`。需要完整回归时移除 `-only-testing`。普通文档修改无需运行键盘测试；非触摸改动无需重复逐点扫描。

语言模型、候选排序模式或联想改动运行 `VimeLanguageModelTests`。`n` 读音改动选择 `KeyboardNInterpretationTests`，光标/删行手势、面板和皮肤选择 `KeyboardFeatureTests`；两者都只检查关键行为，不扫描整个键盘或逐个 Emoji 点击。测试截图在本地临时结果中保存，`Artifacts` 下的测试 PNG 已被 Git 忽略。

纠错改动选择 `KeyboardCorrectionTests`，覆盖真实词典正反例、独立样本、原输入消费、字面回车、候选元数据和后台更新；同时按改动运行输入/预测/宿主及性能回归。独立样本的未命中和不必要建议也会记录，不能把小样本结果当成真实用户误纠率。

浮窗层级与顶部间距选择 `KeyboardPresentationTests`：检查按住时的候选刷新/重新布局、表情页重开与高度切换，以及扩展首次高度是否匹配已保存设置。不需要重跑全键盘触点网格。

DEBUG 构建可通过 `KeyboardTouchDiagnostics.setEnabled(true)` 开启触摸诊断，查看 `VIME_TOUCH` 日志。该诊断默认关闭，记录坐标、视图和取消原因，不记录输入字符或宿主文本；Release 不包含诊断日志。性能计时为开发测试中显式启用的进程内统计，正常运行默认关闭。

### 已保存的验收结果（2026-10-04）

- 键缝修复阶段：23 项触摸、宿主集成与输入性能测试通过；旧布局 375 / 440 / 680 pt 的 2 pt 网格共 50,240 点，无未解析触点。177 个键缝采样像素均具有非零 alpha。用户在其他 App 中确认「键缝都响应，死区消失了」。详见 [触摸验收记录](Artifacts/keyboard-touch-audit.json)。
- 双 `n`、第二行长音键与候选优化阶段：模拟器 15 项定向回归、实机 4 项通过，并复核扩展后的快速输入测试。新长音键旁的键缝与右边缘归属检查通过，没有重跑全键盘网格。
- 实机快速输入：连续突发 35 键，再以 20 ms 间隔输入 35 键，使候选刷新与按键交错；70 次输入全部保留，逐键 marked text 和最终候选正确。最终 Release 包已更新到 iPhone 16 Pro Max，用户在其他 App 中确认「都正常，输入顺畅」。详见 [本轮验收记录](Artifacts/keyboard-remaining-fixes-audit.json)。

候选发布耗时使用相同 Debug 构建口径：附着真实 UIWindow，先预热一轮，再重复三轮相同输入，每侧 84 次发布；计时包含文字设置、测量及实际候选布局。

| 环境 | 修改前 p95 | 修改后 p95 |
| --- | ---: | ---: |
| iOS 模拟器 | 5.14 ms | 2.70 ms |
| iPhone 16 Pro Max | 3.33 ms | 1.33 ms |

实机候选发布 p95 下降约 60%。这些是特定测试环境的测量，人工漏字率和误触率尚未量化；旧 warm 数据使用不同计时范围，不与此表混用。原始数据及测量细节见 [Artifacts/](Artifacts/) 和 [实现文档](Docs/KeyboardImplementation.md)。

### 本次更新验收（2026-10-05）

`n` 字面输入与候选分离、光标和删行手势、候选/符号面板及皮肤的定向回归通过：模拟器 18 项、iPhone 16 Pro Max 10 项。关闭 n 备选读音中无用的预测计算后，只重跑相关的 9 项模拟器及 5 项实机测试，也全部通过，没有重复全区域网格。

最终实机 Debug 基准中，预热后 84 次候选发布 p95 为 1.47 ms，逐键 marked text 更新 p95 为 0.28 ms；额外读音查询使后台候选计算增加，p95 为 18.72 ms。突发/交错快速输入仍保留全部 70 键，草稿逐键即时更新，最新句子候选正确。最终 Release 已更新到 iPhone；用户分别确认 n 行为「符合预期」、新增手势及界面「都正常」。记录见 [本次验收](Artifacts/keyboard-2026-10-05-audit.json)。

随后针对自动折行纵向移动、删行提示与撤回、全区域表情页及高度拖动，补充了 9 项模拟器、4 项实机定向回归，均通过。高度共享值在主 App 和扩展控制器中一致；快速输入仍保留全部 70 键。没有重跑全键盘网格或逐个表情测试。详细记录见 [界面与导航修复验收](Artifacts/keyboard-ui-refinements-audit.json)。

离线纠错相关回归：模拟器 25 项、实机 11 项全部通过，70 键突发/交错输入全部保留。真实词典开发组命中 11/12、合法输入不必要建议 0/33；独立组实机命中 9/10、合法输入不必要建议 1/15（6.7%）。这是小型合成样本，不能代表实际用户误纠率。实机纠错计算 p95 为 41.8 ms，建议显示 p95 约 369 ms（含正常转换与停顿等待）；同口径普通候选 84 次发布 p95 为 1.35 ms。原始数据、内存和未命中案例见 [纠错验收](Artifacts/keyboard-correction-audit.json)。

## 已知限制

- 密码输入框及拒绝第三方键盘的 App 会使用系统键盘。marked text 支持和系统材质受宿主与 iOS 版本影响，已完成的实机验收不代表所有 App 都一致。
- 候选质量受离线词典和上下文评分影响，预测和纠错建议可能不合语境；完整词典候选确认后更新并持久化 AzooKey 学习；本地模型补充候选重排和下一词联想。纠错只搜索单处错误、最长 40 个输入元素和 3…24 个显示字符，跳过末尾未完成辅音；不处理多处错误或部分纠错消费，使用宿主光标前的当前句作为模型上下文；宿主上下文变化时重新核对会话。
- 已开始的过期词典计算无法中断，可能推迟最新候选；preedit 仍即时更新，旧结果会被丢弃，旧候选暂不可选。
- 声音与振动需要完全访问，模拟器不能验证真实震感。字母键的额外符号通过上滑输入，未实现长按字母的附加字符菜单。
- 主 App 试打和系统扩展共用代码；设置共享需要完全访问。外部光标或文档变化会重置组合状态及删行撤回，以免误改其他位置。
- 系统扩展无法读取宿主字体、输入框宽度及排版坐标，自动折行的上下移动使用 17 pt 字体与估计宽度进行近似定位，可能与宿主实际显示行有偏差；主 App 试打区按真实排版定位。删行仍以换行符为边界，超长行处理受宿主上下文长度影响。
- Emoji 目录包含完整 Unicode 序列，但面板只显示当前系统能完整绘制的项；字体检测在后台进行。没有 Animoji/Memoji、搜索和最近使用列表。皮肤目前提供四种预置配色。

## 第三方组件与词典许可

引擎及捆绑词典的来源、修订与许可文本见 [ThirdPartyNotices.txt](Shared/Resources/ThirdPartyNotices.txt)，主 App 的「开源词典与许可」也可查看。分发构建时应保留相应第三方声明；SwiftPM 依赖由项目固定修订管理。
