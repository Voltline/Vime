# Vime

Vime 是一款 iOS 日语罗马音输入法，提供 QWERTY 键盘、平假名 / 片假名、英文输入和离线假名汉字转换。主 App 内置试打区，系统键盘扩展可在支持第三方键盘的 App 中使用。

输入时，宿主输入框即时显示假名草稿（preedit）；尚未完成的辅音保留为罗马字。候选在后台持续预测，每次按键和假名退格都会发起更新，无需等到音节完成。

## 功能

- 26 字母 QWERTY；支持平假名、片假名和英文切换，浅色 / 深色跟随系统。
- 离线词典转换与预测，支持单词、部分候选和完整句子转换。
- 按显示的假名退格；未完成辅音逐字符删除，长按退格连续删除。
- 连续触摸面覆盖键缝，小幅手指漂移保留原键，上滑符号在松手时确认。
- 日语第二行 `L` 右侧提供 `ー` 长音键；数字默认九宫格，可改为全键盘。
- 单行可滚动候选、展开候选、符号页，以及声音、振动和按键预览设置。

## 安装与启用

项目最低部署版本为 iOS 17，已使用 Xcode 27.1 构建验证。UIKit 管理键盘的系统材质；iOS 26 及以上使用对应系统外观。

1. 用 Xcode 打开 [Vime.xcodeproj](Vime.xcodeproj)，选择 `Vime` scheme。首次构建需要联网下载 SwiftPM 依赖及捆绑词典，依赖修订已固定在 [Package.resolved](Vime.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)。
2. 在模拟器或 iPhone 上运行主 App，点击「开始试打」即可体验。安装到自己的 iPhone 前，为 `Vime` 和 `VimeKeyboard` target 配置签名团队；实机测试还需配置 `VimeKeyboardTests` 的签名。
3. 在 iPhone「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」中添加 Vime。
4. 打开支持第三方键盘的 App，长按地球键，选择「Vime 日本語」。
5. 如需按键声和振动，在「设置 → 通用 → 键盘 → 键盘 → Vime 日本語」中开启「允许完全访问」。基本输入和词典转换无需此权限；静音会关闭按键声。

更新安装后，可先切换到其他键盘再切回 Vime，让系统扩展重新加载。

## 输入与操作

| 操作 | 行为 |
| --- | --- |
| 输入罗马音 | 即时显示假名；未完成辅音保留为罗马字并持续请求预测 |
| 空格 | 开始转换，再次按下切换候选；候选尚未就绪时保留转换意图 |
| 点击候选 | 确认该候选；部分候选只消费对应输入，剩余内容继续组合 |
| 回车 | 确认当前假名或已选候选；没有组合文字时执行宿主回车动作 |
| 退格 | 转换预览中先取消选择；平常删除一个显示字符；无组合文字时删除宿主文字 |
| 长按退格 | 连续删除，松手或取消后停止 |
| 字母键上滑 | 显示额外符号预览，松手输入；滑回可撤销，系统取消不输入 |
| `あ` / `ア` | 切换平假名和片假名 |
| 底部日英按钮 | 切换日语和英文输入 |
| 左上角调节图标 | 设置声音、振动 0…5 档、数字布局、长音键和普通按键预览 |

输入期间，顶部工具按钮让位于候选栏。设置分别保存在主 App 与系统扩展各自的 UserDefaults 容器中，两处偏好独立。

### 罗马音与退格示例

| 输入 / 操作 | 显示或结果 |
| --- | --- |
| `nihongo` | 草稿 `にほんご`，可转换为 `日本語` |
| `naniwo` | 草稿 `なにを`，可转换为 `何を` |
| `nn` | `ん`；一次退格删除整个 `ん` |
| `kanna` | `かんな` |
| `konnichiha` | `こんにちは` |
| `sonnna`（`so + nn + na`） | `そんな` |
| `kan` 后接 `a` / `ya` | `かn → かな` / `かにゃ`；末尾单个 `n` 仍可继续组成音节 |
| `nanim` | 草稿 `なにm`，未输入 `o` 时也能预测 `何も` |
| `nanimo` 后退格一次 | `なにも → なに`，完成的 `mo` 作为一个假名删除 |
| `sh` 后退格一次 | `sh → s`，未完成辅音逐字符删除 |
| `kya` 后退格一次 | `きゃ → き`，小假名可单独删除 |
| 片假名模式输入 `ko-hi-` | `コーヒー`；`-` 与专用 `ー` 键均可输入长音 |

长音键默认显示在日语第二行，设置中可以隐藏；隐藏后或切换英文时，第二行恢复九键缩进。底部为六键布局，保留较宽空格。

## 实现与项目结构

转换使用 [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)，固定修订 `d59a28e4c7ca049aef04f29a91eae9677a7753f2`，默认词典由 SwiftPM 捆绑。转换使用词典分词及语法连接评分，优先完整读音匹配，并为未完成的辅音提供预测。运行时转换无需网络；未启用永久学习、拼写纠错、英文预测或 Zenzai 神经模型。

| 路径 | 职责 |
| --- | --- |
| [Vime/](Vime/) | SwiftUI 主 App、启用指南、开源许可和试打容器 |
| [Keyboard/](Keyboard/) | 系统键盘扩展、宿主回调和完全访问配置 |
| [Shared/KeyboardSession.swift](Shared/KeyboardSession.swift) | 输入状态、假名退格、模式切换、转换与提交 |
| [Shared/RomajiConverter.swift](Shared/RomajiConverter.swift)、[PreeditPresentation.swift](Shared/PreeditPresentation.swift) | 双 `n` 接续处理、假名显示和确认边界 |
| [Shared/JapaneseCandidateEngine.swift](Shared/JapaneseCandidateEngine.swift)、[JapaneseCandidateWorker.swift](Shared/JapaneseCandidateWorker.swift) | 候选生成与排序、后台串行计算、过期请求处理 |
| [Shared/KeyboardHostConnection.swift](Shared/KeyboardHostConnection.swift) | 通过 UIKit marked text 更新宿主草稿并提交文字 |
| [Shared/KeyboardView.swift](Shared/KeyboardView.swift)、[KeyboardMetrics.swift](Shared/KeyboardMetrics.swift) | 主 App 与扩展共用的界面、候选条、布局和设置 |
| [Shared/KeyboardTouchSurface.swift](Shared/KeyboardTouchSurface.swift) | 连续触摸面、唯一按键归属、多指状态与上滑锁定 |
| [Tests/UIKit/](Tests/UIKit/) | 输入、预测、宿主集成、触摸与性能回归 |
| [Docs/](Docs/)、[Artifacts/](Artifacts/) | 实现记录、验收与性能数据；测试截图仅在本地保留 |

主线程即时更新输入与 marked text，词典计算在后台串行执行。未开始的旧请求可取消，过期结果不会覆盖新输入。仅在当前候选计算期间保留上一轮列表，旧列表不能选词；当前结果就绪后立即发布。候选条复用按钮、缓存文字宽度并直接排布，语言图标只在模式或外观变化时重绘。

触摸由整个键盘的连续 surface 接收，先按可见键本体、再按行与键间中线唯一分配。轻微漂移保持归属，明显进入邻键才切换；上滑锁定原键。触摸面和候选 padding 绘制极低透明度背景，避免系统扩展在完全透明键缝处丢失事件。详细根因、架构与调研链接见 [实现文档](Docs/KeyboardImplementation.md)。

旧 Mozc 精简词典与生成脚本保留为历史资料，已从构建资源中排除，不参与当前转换。

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

DEBUG 构建可在键盘设置中开启「触摸诊断（开发版）」，查看 `VIME_TOUCH` 日志。该诊断默认关闭，记录坐标、视图和取消原因，不记录输入字符或宿主文本；Release 不包含该开关及日志。性能计时为开发测试中显式启用的进程内统计，正常运行默认关闭。

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

## 已知限制

- 密码输入框及拒绝第三方键盘的 App 会使用系统键盘。marked text 支持和系统材质受宿主与 iOS 版本影响，已完成的实机验收不代表所有 App 都一致。
- 候选质量受离线词典和上下文评分影响，可能出现不合语境的预测；当前没有永久学习、拼写纠错或神经模型补充。
- 已开始的过期词典计算无法中断，可能推迟最新候选；preedit 仍即时更新，旧结果会被丢弃，旧候选暂不可选。
- 声音与振动需要完全访问，模拟器不能验证真实震感。字母键的额外符号通过上滑输入，未实现长按字母的附加字符菜单。
- 主 App 试打和系统扩展共用代码，但偏好设置独立；外部光标或文档变化会重置组合状态，以免误改其他位置。

## 第三方组件与词典许可

引擎及捆绑词典的来源、修订与许可文本见 [ThirdPartyNotices.txt](Shared/Resources/ThirdPartyNotices.txt)，主 App 的「开源词典与许可」也可查看。分发构建时应保留相应第三方声明；SwiftPM 依赖由项目固定修订管理。
