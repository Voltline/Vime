# 项目目录

目录按职责划分，App 与扩展继续共享相同 Swift 类型，未拆分新模块。

| 目录 | 职责 |
| --- | --- |
| `Vime/Home` | 主 App 首页 |
| `Vime/Settings` | 完整设置与高度编辑器 |
| `Vime/Sandbox` | 主 App 试打输入框 |
| `Keyboard` | 系统键盘扩展入口及 Info.plist |
| `Shared/Candidates` | azooKey 候选、统一排序、纠错与后台 worker |
| `Shared/Input` | 输入会话、Roman 转换、preedit 表示 |
| `Shared/Models` | Core ML 推理及 SentencePiece 桥接封装 |
| `Shared/Host` | 宿主 marked text、文字提交和导航 |
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
调整文件位置后，README、文档链接及图标生成命令同步更新。

v2.1 模型大文件保持外部交付约定。新 checkout 必须先运行安装脚本；Release 资源校验不能被词典回退掩盖。Debug 构建可继续进行不包含模型的词典开发。
