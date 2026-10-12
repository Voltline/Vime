# Vime

Vime 是一款 iOS 日语罗马音输入法，提供 QWERTY 键盘、平假名 / 片假名、英文直输，以及离线假名汉字转换。主 App 管理设置和用户数据，系统键盘扩展在支持第三方键盘的 App 中使用。

## 功能

- 即时假名草稿，保留未完成罗马音；后台更新转换和预测候选。
- 整句与分段转换；展开候选可调整转换范围，确认前段后继续处理后段。
- azooKey 词典生成与统一候选排序，可启用本地 Core ML 模型重排和下一词联想。
- 邻键、近音与有限多音纠错，以候选形式展示，选择后才接受修正。
- 原生候选学习与有界用户偏好记忆，结合重复选择、近期使用和上下文。
- 用户词典、短语快捷输入与 JSON 导入导出。
- 自定义皮肤、背景与按键图片，支持 `.vimeskin` 导入导出。
- 分类符号、Emoji 与颜文字，按键声音、振动及可调键盘高度。

## 安装与启用

最低部署版本为 iOS 18。使用 Xcode 打开 [Vime.xcodeproj](Vime.xcodeproj)，选择 `Vime` scheme。首次构建需要解析固定的 SwiftPM 依赖，模型和分词器资源已随仓库提供。签名与构建步骤见 [开发指南](Docs/Development.md)。

1. 构建并运行主 App；实机安装前为 App 与扩展配置签名及相同的 App Group。
2. 在 iPhone「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」中添加 Vime。
3. 在输入框长按地球键，切换到「Vime 日本語」。
4. 需要按键反馈、共享设置、自定义皮肤或用户词典同步时，开启「允许完全访问」。基本离线输入无需此权限，静音模式关闭按键声。

首页「开始试打」使用正常系统输入框；切换到 Vime 才会加载真正键盘扩展。更新安装或修改设置后，可切换键盘再切回，让扩展重新加载。

## 常用操作

| 操作 | 行为 |
| --- | --- |
| 输入罗马音 | 即时显示假名，未完成辅音保持罗马字 |
| 空格 | 开始转换，继续按下切换候选 |
| 点击候选 | 确认对应输入；部分候选保留后段继续转换 |
| 展开候选 → `−` / `+` / `整句` | 调整前段范围或恢复整句，滚动查看更多候选 |
| 回车 | 确认已选候选或字面草稿，无组合文字时执行宿主动作 |
| 退格 / 长按退格 | 删除显示字符 / 连续删除，删空后停止重复反馈 |
| `あ` / `ア`、日英按钮 | 切换假名表记或日英输入 |
| 字母上滑、按键区域横滑 | 输入符号 / 移动光标 |
| 长按空格拖动 | 移动光标 |
| 数字 → 符号、表情键 | 打开分类符号或 Emoji 面板 |
| 左上角 Vime 标志 | 快速反馈设置，完整设置在主 App 中管理 |

转换候选和纠错受词典、上下文及查询预算影响，不保证所有词或误输入都有理想结果。中文与原生 macOS 输入法当前未提供。

## 项目文档

- [文档索引](Docs/README.md)
- [项目目录](Docs/ProjectLayout.md) · [开发与验证](Docs/Development.md)
- [候选与联想](Docs/Architecture/Candidates.md) · [学习与个性化](Docs/Architecture/Personalization.md)
- [输入与宿主](Docs/Architecture/InputPipeline.md) · [后端接口](Docs/Architecture/InputBackends.md)
- [日语模型](Docs/Models/JapaneseModel.md)
- [自定义皮肤](Docs/Guides/CustomSkins.md) · [用户词典](Docs/Guides/UserDictionary.md)

## 许可与致谢

项目许可见 [LICENSE](LICENSE)。转换引擎使用 [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)，分词器使用 SentencePiece。第三方代码与数据的许可、致谢及来源分别保留在 [ThirdPartyNotices.txt](Shared/Resources/ThirdPartyNotices.txt)、[SentencePiece LICENSE](Dependencies/VimeSentencePiece/LICENSE) 和 [语言资源来源清单](Shared/Resources/LanguageResourceSources.json)。
