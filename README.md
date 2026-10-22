# Vime

**简体中文** | [English](README.en.md) | [日本語](README.ja.md)

![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-blue) ![Swift](https://img.shields.io/badge/Swift-UIKit%20%2B%20SwiftUI-orange) ![License](https://img.shields.io/badge/license-GPL--3.0--or--later-green)

Vime 是一款完全离线的 iOS 日语输入法。它支持罗马字 QWERTY 和假名九宫格两种布局，平假名、片假名和英文可以随时切换。假名汉字转换基于 [azooKey](https://github.com/azooKey/AzooKeyKanaKanjiConverter) 词典引擎，再由设备上的小型 Core ML 语言模型对候选重新排序，并在确认文字后给出下一词联想。转换、纠错、学习和联想都在本机完成，输入内容不会上传。

主 App 负责启用引导、试打练习、外观定制和各项设置；系统键盘扩展可在任何支持第三方键盘的 App 中使用。

## 亮点

### 输入

- **两种日语布局**：罗马字全键盘；或假名九宫格，点按输入あ段、上下左右滑动输入其他段，连续点按同一键依次切换（トグル入力）。九宫格带 `↶` 回退、`゛゜小` 修饰和 `→` 结束连打键，「確定」占两行高度，更好按。
- **即时假名草稿**：输入时立即显示假名，未凑成假名的辅音保留为罗马字；转换和预测在后台更新，不打断输入。
- **英文直输**与日英一键切换；数字页可选九宫格或全键盘。
- 长按空格拖动、或在按键区横向滑动都能移动光标；字母键上滑输入符号。

### 转换与候选

- **整句与分段转换**：展开候选后用 `−` / `+` 调整前段范围，确认前段后继续转换后段，正文只写入已确认的部分。
- **智能排序**：azooKey 生成候选，再由本地语言模型（INT8、仅 CPU）结合上文重新打分；也可改用纯词典排序。
- **下一词联想**：确认文字后，空闲的候选栏会显示后续词，点击即可接着输入。
- **纠错候选**：邻键误触、近音和有限的多音错误以候选形式出现，只有你选中时才会采用。
- **格式候选**：半角片假名（ｶﾞｯｺｳ）和全角英数字（ａｂｃ１２３）。

### 效率工具

- **用户词典与短语快捷输入**，支持 JSON 导入导出（最多 1,024 条）。
- **剪贴板建议**（默认关闭）：新复制的文字会出现在候选栏；另保留最近 24 小时的历史，只存在本机。
- **数字页计算**：输入 `1+1` 时候选给出 `2` 和 `1+1=2`。
- **自动补全括号**：支持 `()`、`（）`、`「」` 等，光标放在括号中间。
- 分类符号、Emoji 和颜文字面板；数字页左侧栏的符号可以自定义。

### 个性化

- 内置多种外观，可自建皮肤：背景、按键图片和配色均可设置，以 `.vimeskin` 文件导入导出。
- 键盘高度可拖动调节，按键声音和连续可调的振动强度。
- 在本机学习你的选词习惯，可随时一键清空。

### 主 App

- **三步启用引导**：添加键盘、开启完全访问、切换到 Vime，完成后自动进入试打。
- **跟打练习**：照着例句输入，打对的部分逐字标蓝。
- 设置页的状态卡会显示键盘是否在正常工作、已加载的模型版本和学习统计。
- 界面支持简体中文、繁體中文、日本語和 English。

## 安装与启用

需要 iOS 18 或更高版本，以及支持当前 SDK 的 Xcode。

1. 用 Xcode 打开 [Vime.xcodeproj](Vime.xcodeproj)，选择 `Vime` scheme。首次构建会解析固定版本的 SwiftPM 依赖，模型和分词器资源已包含在仓库中。
2. 安装到真机前，为主 App 和 `VimeKeyboard` 扩展配置签名，两者须使用相同的 App Group（当前为 `group.com.Voltline.Vime`）。详见 [开发与验证](Docs/Development.md)。
3. 运行主 App，按首页引导操作；也可以手动在「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」中添加 Vime。
4. 在任意输入框长按地球键，选择「Vime 日本語」。

基本的离线输入不需要「允许完全访问」。按键声音和振动、App 与键盘共享设置、自定义皮肤、用户词典同步以及剪贴板建议需要开启完全访问。修改设置后，切换到其他键盘再切回来，扩展就会重新读取设置。

## 常用操作

| 操作 | 行为 |
| --- | --- |
| 输入罗马字 | 即时显示假名，未完成的辅音保持罗马字 |
| 九宫格点按 / 滑动 | 点按输入あ段，上下左右滑动输入其他段；连续点按同一键依次切换 |
| `↶` / `゛゜小` / `→` | 退回连打的上一个字 / 切换浊音、半浊音和小写 / 结束连打，用同一键输入新字 |
| 空格 | 开始转换，再按切换到下一个候选 |
| 点击候选 | 确认该候选；分段时后段继续保持转换状态 |
| 展开候选 → `−` / `+` / `整句` | 调整前段范围或恢复整句，滚动查看更多候选 |
| 回车 / 確定 | 确认已选候选或当前假名；没有输入中的文字时执行宿主 App 的回车动作 |
| 退格 / 长按退格 | 删除一个字符 / 连续删除 |
| `あ` / `ア`、日英键 | 切换平片假名，或切换日英输入 |
| 字母上滑、横滑按键区、长按空格拖动 | 输入符号、移动光标 |
| 数字键、表情键 | 打开数字页、分类符号或 Emoji 面板 |
| 左上角 Vime 标志 | 快捷设置：剪贴板历史、声音与振动、数字布局 |

候选质量受词典、上下文和查询时间预算影响，不保证每个词或每种误输入都能得到理想结果。目前不提供中文输入，也没有 macOS 版。

## 隐私

- 转换、纠错、排序、联想和学习都在设备上完成，没有网络请求，不上传输入内容或剪贴板。
- 学习数据、用户词典和皮肤保存在 App Group 共享容器中；剪贴板历史不纳入系统备份。
- 完整说明见 [隐私政策](Docs/Guides/Privacy.md)（另有 [繁體中文](Docs/Guides/Privacy.zh-Hant.md)、[日本語](Docs/Guides/Privacy.ja.md)、[English](Docs/Guides/Privacy.en.md)）。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `Vime/` | 主 App（SwiftUI）：首页、引导、定制、设置和关于 |
| `Keyboard/` | 键盘扩展入口 `KeyboardViewController` |
| `Shared/` | App 与扩展共用：输入会话、候选引擎、语言模型、键盘 UI、设置和资源 |
| `Tests/` | 引擎、候选、会话、UI 组件和扩展的 XCTest |
| `Dependencies/` | 内置的 SentencePiece 分词器 |
| `Scripts/` | 资源生成、模型和 App 资源校验、可复现测试脚本 |
| `Docs/` | 使用指南、开发流程和架构文档 |

## 开发

```bash
python3 Scripts/validate_model_resources.py
```

```bash
python3 Scripts/validate_app_resources.py
```

前者校验模型 manifest、分词器和 SHA256，后者校验许可声明、隐私政策和本地化目录是否完整。界面文字统一放在 `Shared/Resources/Localizable.xcstrings`，新增文字需要补全四种语言。完整测试流程（`Scripts/verify_review.sh`）、真实键盘扩展的验证方法和排查办法见 [开发与验证](Docs/Development.md)。

## 文档

- [文档索引](Docs/README.md)
- 使用：[App 设置](Docs/Guides/AppSettings.md) · [自定义皮肤](Docs/Guides/CustomSkins.md) · [用户词典](Docs/Guides/UserDictionary.md)
- 开发：[项目目录](Docs/ProjectLayout.md) · [开发与验证](Docs/Development.md) · [日语模型](Docs/Models/JapaneseModel.md)
- 架构：[输入与宿主](Docs/Architecture/InputPipeline.md) · [候选与联想](Docs/Architecture/Candidates.md) · [学习与个性化](Docs/Architecture/Personalization.md) · [输入后端接口](Docs/Architecture/InputBackends.md) · [表情显示](Docs/Architecture/EmojiRendering.md)

## 许可与致谢

Vime 以 [GPL-3.0-or-later](LICENSE) 许可发布，并依 GPLv3 第 7 条附加一项额外许可，允许在 App Store 等应用商店分发，条件是同时提供对应源代码，见 [LICENSE-EXCEPTION](LICENSE-EXCEPTION)。2026-10-22 之前的版本仍以 GPL-2.0-only 发布。随附的 [VimeML](https://github.com/Voltline/VimeML) 日语模型采用相同许可，训练语料的署名见第三方声明。假名汉字转换使用 [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)，分词使用 [SentencePiece](https://github.com/google/sentencepiece)。第三方代码与数据的许可、致谢和来源见 [ThirdPartyNotices.txt](Shared/Resources/ThirdPartyNotices.txt)、[SentencePiece LICENSE](Dependencies/VimeSentencePiece/LICENSE) 和 [语言资源来源清单](Shared/Resources/LanguageResourceSources.json)，App 内「设置 → 关于 Vime → 开源组件与许可」也可查看完整原文。
