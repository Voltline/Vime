# 开发与验证

## 构建

最低部署版本为 iOS 18。使用支持工程当前 SDK 的 Xcode 打开 [Vime.xcodeproj](../Vime.xcodeproj)，选择 `Vime` scheme。首次构建需解析 SwiftPM 依赖，固定修订见 [Package.resolved](../Vime.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)。

安装到设备前，为主 App、`VimeKeyboard` 和所用测试 target 配置签名。App 与扩展须使用相同 App Group；当前标识为 `group.com.Voltline.Vime`。更换标识时同时核对 [App entitlements](../Configuration/Vime.entitlements)、[扩展配置](../Keyboard/Info.plist)、[设置存储](../Shared/Preferences/KeyboardPreferences.swift) 及引擎的共享容器配置。

模型资源随仓库提供。构建前可在仓库根目录运行：

```sh
python3 Scripts/validate_model_resources.py
```

该校验核对 manifest 身份、tokenizer 和完整 compiled model 文件集及 SHA256。Release 构建同样执行模型资源校验；资源缺失时应修复交付包，不能以运行时词典回退代替打包完整性。模型说明见 [日语模型](Models/JapaneseModel.md)。

App 的分组件许可与隐私政策可以用 `python3 Scripts/validate_app_resources.py` 校验，构建产物可传 `--resources <Vime.app>`，以检查声明原文和公开政策的一致性

## 本地化

App 与键盘支持简体中文（源语言）、繁体中文、日语、英语和韩语。界面文字统一放在 [Localizable.xcstrings](../Shared/Resources/Localizable.xcstrings)，由 App 与键盘扩展共用：

- SwiftUI 字面量（`Text`、`Button`、`Toggle`、`navigationTitle` 等）自动提取；自定义组件的文字参数使用 `LocalizedStringResource`，不要用 `String` 接收再交给 `Text`。
- 计算出的文字和 UIKit 标签使用 `String(localized:)`，整句作为一个 key，用插值代替字符串拼接，便于各语言调整语序。
- 同时作为逻辑标识的文字（如数字键盘的按键值、符号分组名、许可清单字段）保留中文原值作为 ID，显示时再用 `String(localized: String.LocalizationValue(...))` 查找；这类运行时 key 在目录中标记为 manual。
- 「変換 / 次候補 / 確定」等日语输入法惯用语在中文和日文界面保持原样，英文界面译为 Convert / Next / Confirm，韩文界面译为 변환 / 다음 후보 / 확정。

新增或修改文字后运行 `xcodebuild -exportLocalizations -project Vime.xcodeproj -scheme Vime -localizationPath <目录>` 同步目录，再补全四种语言的翻译。`python3 Scripts/validate_app_resources.py` 会拒绝任何未翻译的条目；带复数变体的条目还必须显式写出 zh-Hans 值，否则简体中文会回退到英文的复数形式。隐私政策按语言保存为 `Vime/Resources/PrivacyPolicy[-zh-Hant|-ja|-en|-ko].json`，公开文本由 `--write-policy` 生成，校验要求各语言日期和结构一致。

测试断言使用简体中文界面文字，共享 scheme 的测试语言固定为 `zh-Hans` / `CN`，不随模拟器系统语言变化。

## 测试层次

| 层次 | 覆盖范围 | 边界 |
| --- | --- | --- |
| `Tests/UIKit` | 原生引擎、候选排序、会话、宿主适配、学习及组件交互 | 内嵌组件通过不等于第三方宿主通过 |
| `Tests/ExtensionUI` / `VimeExtensionTests` | iOS 实际加载的键盘扩展 | 模拟器不能证明真机内存、能耗或所有 App 的行为 |
| 真机手动验证 | 第三方宿主、连续输入、光标变化、反馈和性能 | 记录输入串、操作步骤、版本及宿主，避免只记录最终截图 |

主 App 首页的试打框使用正常系统输入框，添加 Vime 后用地球键切换，才会加载键盘扩展。「设置 → 问题诊断」提供真实键盘扩展的待确认文本观察和记录入口。`Vime/Sandbox` 的内嵌 `KeyboardView` 适合组件开发，不代替上述路径。

分段输入应验证整个过程：点击前段后，正文只增加已选文字，后段仍保持 marked text；继续选后段、退格、移光标和切换字段时，检查正文中没有重复插入或意外确认尾部。候选栏和完整候选菜单都要覆盖。

## 可复现检查

[verify_review.sh](../Scripts/verify_review.sh) 支持 `focused`、`full`、`extension`、`all`。显式指定模拟器和已经解析好的依赖缓存，例如：

```sh
export VIME_TEST_DESTINATION='platform=iOS Simulator,id=<SIMULATOR_UDID>'
export VIME_PACKAGE_CACHE='<PATH_TO_RESOLVED_SOURCE_PACKAGES>'
bash Scripts/verify_review.sh all
```

输出默认保存到独立临时目录；也可用 `VIME_REVIEW_OUTPUT` 指定新的本地证据目录，不能覆盖旧结果。`VIME_DERIVED_DATA` 可指定构建缓存，`VIME_SWIFT_OPTIMIZATION` 可选 `-Onone` 或 `-O`。保存长期排查材料时放入 `Docs/internalDocs/Evidence/`。

脚本保存源码与资源快照、命令、退出码和 XCTest 结果，检查预期测试方法是否实际被发现及执行。失败、缺失用例或非预期跳过均不算通过。两个 benchmark 和内存场景默认按需运行，其跳过不构成性能验证；CPU_ONLY 模型不能因测试名称含 Neural Engine 就视为已支持其他计算设备。

测试预期应独立于被测实现。模型参考输出与 corpus 随测试版本维护，不能为通过测试而把预期改成当前错误输出。出现失败要保留输入、命令和失败结果，再补充修复后的证据。

## 排查键盘退出

键盘被切回系统输入法不一定代表 Swift 崩溃，也可能是系统因内存压力终止扩展，或宿主进入不支持第三方键盘的输入框。先记录设备、系统版本、构建号、宿主 App 和发生时间，再核对设备上的 `VimeKeyboard` 崩溃报告与同一时段的 `JetsamEvent`。Jetsam 报告中出现 Vime 的进程名不等于它被终止，必须核对该进程对应的终止原因，不能用主 App 或模拟器的旧崩溃代替扩展证据

扩展使用 `com.Voltline.Vime` / `ExtensionLifecycle` 系统日志记录加载、显示、隐藏和内存警告，字段只有 PID、控制器存活时间与物理内存占用，不包含输入文本。`LanguageModel` 类别记录模型加载和推理状态，采集日志时按发生时间与进程核对

候选工作队列在每个任务结束时释放 autorelease 临时对象。收到 UIKit 内存警告后，扩展取消旧请求，在同一工作队列释放模型与临时候选缓存，并清理闲置 UI；当前组合、选中候选、分段范围及待确认学习反馈保留。未完成的基础候选请求会重新发起，神经排序与神经联想暂停，继续使用词典能力。普通按键与宿主切换不会立即重新加载模型；将排序切到词典再切回模型可显式重试，扩展进程重建后也可重试

内存警告不保证在系统终止前送达，已经进入的 Core ML 推理也不能被立即中断。模拟器的物理内存采样仅用于观察趋势，不能证明真机扩展未触及系统限制，也不能据此给出固定内存上限。报告格式和终止原因见 [Apple 的 Jetsam 排查说明](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports)

定向回归用例为 `KeyboardMemoryPressureTests`，覆盖加载过的模型释放、避免反复加载、异步候选重发、未完成罗马字以及分段选择保持。`VimeLanguageModelMemoryTests/testProcessMemoryProfile` 需显式设置 `TEST_RUNNER_VIME_MEMORY_SCENARIO=lm_words`，确认执行和联想发布次数后再解读内存数据。实际扩展路径另用 `KeyboardExtensionTests/testExpandedPartialSelectionKeepsHostMarkedRange` 验证，不能把模拟内存警告测试表述为真实 Jetsam 验收

## 发布检查

- 营销版本保持 `1.0`；上传构建号必须高于 App Store Connect 已接收的构建。Xcode Cloud 的下一构建号与本地工程设置分别核对。
- 核对 App / 扩展签名、App Group、版本、资源清单及 [隐私声明](../Shared/Resources/PrivacyInfo.xcprivacy)。
- 对最终构建执行对应测试并验收真正键盘扩展；不能把历史报告或旧构建的通过结果当作当前 archive 的证明。
- 确认模型 preflight 和 Release archive 成功，再进行分发。上传、签名凭据和发布审核不属于文档脚本。
