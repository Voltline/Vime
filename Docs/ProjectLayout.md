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
| `Vime/Sandbox` | 内嵌键盘组件试打；不能代替扩展验收 |
| `Keyboard` | 系统键盘扩展入口及宿主接入 |
| `Shared/Input` | 会话协议、日语组合状态、罗马音及分段边界 |
| `Shared/Host` | preedit、marked text、提交回执及光标导航 |
| `Shared/Candidates` | 候选模型、生成、排序、纠错、学习和后台 worker |
| `Shared/Models` | Core ML 与 SentencePiece 封装 |
| `Shared/Preferences` | App Group 设置和皮肤存储 |
| `Shared/UI` | 键盘布局、候选、触摸、表情和符号面板 |
| `Shared/Diagnostics` | 可选性能、触摸和扩展审计 |
| `Shared/Resources` | 模型、分词器、词库、表情目录、隐私声明及第三方许可 |
| `Configuration` | App 信息、entitlements 与模型资源输入清单 |
| `Dependencies` | 本地 SentencePiece 包及其许可 |
| `Scripts` | 资源生成、模型安装、校验及测试工具 |
| `Tests/UIKit` | 引擎、会话、UI 组件测试和固定参考数据 |
| `Tests/ExtensionUI` | 真正系统键盘扩展的 UI 测试 |
| `Docs` | 公开使用、开发和架构文档 |
| `Docs/internalDocs` | Git 忽略的本地计划、历史记录和验证产物 |

## 工程与资源

[Vime.xcodeproj](../Vime.xcodeproj) 使用 filesystem synchronized groups；target 包含关系及排除项以 [project.pbxproj](../Vime.xcodeproj/project.pbxproj) 为准。共享源码继续由 App 和扩展使用，目录分组不意味着独立 Swift 模块。

模型、分词器、语言数据和测试参考文件保留原位置。运行时资源从 bundle 查找，调整目录或更换文件名必须同时核对资源清单和加载代码。当前模型交付文件已纳入版本控制，正常 checkout 不需要另行安装模型。

[LanguageResourceSources.json](../Shared/Resources/LanguageResourceSources.json) 记录表记偏好与补充词库的来源、许可及校验和。修改这些语言数据时使用 [build_language_resources.py](../Scripts/build_language_resources.py)，不要用运行日志代替可复现的数据输入。测试使用的 corpus 和模型参考输出保留在 `Tests/UIKit/Resources`，不归入本地验收产物。
