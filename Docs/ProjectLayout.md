# 项目目录

目录按职责划分，App 与扩展继续共享相同 Swift 类型，未拆分新模块。

| 目录 | 职责 |
| --- | --- |
| `Vime/Home` | 主 App 首页 |
| `Vime/Settings` | 完整设置、高度／皮肤编辑器与用户词典管理 |
| `Vime/Sandbox` | 主 App 试打输入框 |
| `Keyboard` | 系统键盘扩展入口及 Info.plist |
| `Shared/Candidates` | 独立候选展示类型，以及日文 azooKey payload、排序、纠错与后台 worker |
| `Shared/Input` | 通用 session 协议与语言展示配置；现有日文会话、Roman 转换 |
| `Shared/Models` | Core ML 推理及 SentencePiece 桥接封装 |
| `Shared/Host` | 带 UTF-16 选区的 preedit、宿主 marked text、文字提交和导航 |
| `Shared/Preferences` | App Group 偏好与迁移 |
| `Shared/UI` | 键盘、触摸面、候选与符号 UI、品牌及布局 |
| `Shared/Diagnostics` | 可选计时、触摸诊断与扩展审计 |
| `Shared/Resources` | 模型、tokenizer、词典索引、Emoji 与许可、隐私声明 |
| `Configuration` | entitlement 与构建资源输入清单 |
| `Dependencies` | 固定的 SentencePiece 源码依赖 |
| `Scripts` | 资源生成、安装及发布前校验工具 |
| `Tests/UIKit` | 现有定向测试与固定评测数据 |

Xcode 使用 filesystem synchronized groups，移动 Swift 文件后自动包含于原有 target。
资源目录保持原路径和文件名，运行时继续从 bundle 根目录查找，避免改变加载协议。
`Shared/Resources/OrthographyPreferences.json` 与 `SupplementalLexicon.json` 是离线语言数据；`LanguageResourceSources.json` 记录来源和校验和，`Scripts/build_language_resources.py` 可重新生成。转换范围和安全尾部映射由 `Shared/Input` 管理，数据加载和排序由 `Shared/Candidates` 管理。
调整文件位置后，README、文档链接及图标生成命令同步更新。

`JapaneseUserDictionaryStore` 原子保存 App Group 下的 `Vime/UserDictionary.json`，通过共享 revision 使后台 worker 重载词语与 shortcuts；普通按键不读写词典文件。`PostCompositionSuggestions` 保留原生联想的词条、追加／替换操作和终止状态，再由 worker 分阶段发布。

v2.1 模型大文件保持外部交付约定。新 checkout 必须先运行安装脚本；Release 资源校验不能被词典回退掩盖。Debug 构建可继续进行不包含模型的词典开发。
