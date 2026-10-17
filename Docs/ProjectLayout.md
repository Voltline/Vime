# 项目目录

Vime 使用一个 Xcode 工程构建 iOS 主 App 和系统键盘扩展，共享 Swift 代码按职责组织。

| 路径 | 职责 |
| --- | --- |
| `Vime/App` | 三 Tab 路由、临时编辑及外部文件导入 |
| `Vime/Home` | 使用系统键盘的试打首页与启用指南 |
| `Vime/About` | 关于、隐私政策、开源许可目录和详情 |
| `Vime/Resources` | App 专用的隐私政策及分组件许可原文 |
| `Vime/Settings` | 设置、皮肤、高度和用户词典管理 |
| `Vime/Testing` | 使用系统键盘的试打与扩展诊断页面 |
| `Keyboard` | 系统键盘扩展入口及宿主接入 |
| `Shared/Input` | 会话协议、日语组合状态、罗马音及分段边界 |
| `Shared/Host` | preedit、marked text、提交回执及光标导航 |
| `Shared/Candidates` | 候选快照及 UI 展示数据；实现按职责分目录 |
| `Shared/Models` | Core ML 与 SentencePiece 封装 |
| `Shared/Preferences` | App Group 设置和皮肤存储 |
| `Shared/UI` | 共享界面组件，按键盘、按键、候选、符号、外观和控件分类 |
| `Shared/Diagnostics` | 可选性能、触摸和扩展审计 |
| `Shared/Resources` | 模型、分词器、词库、表情目录、隐私声明及第三方许可 |
| `Configuration` | App 信息、entitlements 与模型资源输入清单 |
| `Dependencies` | 本地 SentencePiece 包及其许可 |
| `Scripts` | 资源生成、模型安装、校验及测试工具 |
| `Tests/UIKit` | 引擎、会话、UI 组件测试和固定参考数据 |
| `Tests/ExtensionUI` | 真正系统键盘扩展的 UI 测试 |
| `Docs` | 公开使用、开发和架构文档 |
| `Docs/internalDocs` | Git 忽略的本地计划、历史记录和验证产物 |

## 共享 UI

| 路径 | 职责 |
| --- | --- |
| `Shared/UI/Keyboard` | 键盘主视图、输入根视图及布局尺寸 |
| `Shared/UI/Keys` | 按键、触摸归属、手势及删除提示 |
| `Shared/UI/Candidates` | 转换候选按钮及符号、计算、剪贴板快捷候选栏 |
| `Shared/UI/Symbols` | 符号、Emoji 和颜文字面板及目录模型 |
| `Shared/UI/Symbols/Emoji` | Emoji 可用性检测、字体位图解码和图片缓存 |
| `Shared/UI/Appearance` | 主题、皮肤文字、图标和 Logo 绘制 |
| `Shared/UI/Controls` | 振动强度滑块及高度调节控件 |

## 候选处理

| 路径 | 职责 |
| --- | --- |
| `Shared/Candidates/Engine` | 转换引擎及串行后台 worker |
| `Shared/Candidates/Ranking` | 候选竞争、重排、排序模式及联想排序 |
| `Shared/Candidates/Learning` | 学习反馈、频次和用户偏好持久化 |
| `Shared/Candidates/Correction` | 纠错变体与读音索引 |
| `Shared/Candidates/Dictionary` | 表记资源、补充词库及用户词典 |

## 测试

`Tests/UIKit` 下的 Swift 文件分为 `App`、`Candidates`、`Input`、`UI`、`Models`、`Diagnostics`、`Regression` 和 `Support`。跨模块的历史问题回归放在 `Regression`，测试辅助代码放在 `Support`。测试类名和 scheme 选择器保持稳定，可继续按类运行测试。

## 工程与资源

[Vime.xcodeproj](../Vime.xcodeproj) 使用 filesystem synchronized groups；target 包含关系及排除项以 [project.pbxproj](../Vime.xcodeproj/project.pbxproj) 为准。共享源码继续由 App 和扩展使用，目录分组不意味着独立 Swift 模块。

模型、分词器、语言数据和测试参考文件保留原位置。运行时资源从 bundle 查找，调整目录或更换文件名必须同时核对资源清单和加载代码。当前模型交付文件已纳入版本控制，正常 checkout 不需要另行安装模型。

[LanguageResourceSources.json](../Shared/Resources/LanguageResourceSources.json) 记录表记偏好与补充词库的来源、许可及校验和。修改这些语言数据时使用 [build_language_resources.py](../Scripts/build_language_resources.py)，不要用运行日志代替可复现的数据输入。测试使用的 corpus 和模型参考输出保留在 `Tests/UIKit/Resources`，不归入本地验收产物。
