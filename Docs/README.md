# Vime 文档

这里维护与当前代码相符的使用说明、开发流程和设计约定。产品介绍及安装入口见仓库 [README](../README.md)。

## 使用指南

- [App 设置](Guides/AppSettings.md)：试打、定制、三档吸附与设置导航
- [隐私政策](Guides/Privacy.md)：与 App 内政策一致的公开文本

- [自定义皮肤](Guides/CustomSkins.md)：创建、导入、导出及文件格式。
- [用户词典](Guides/UserDictionary.md)：注册词语、短语快捷输入及 JSON 交换格式。

## 开发指南

- [项目目录](ProjectLayout.md)：App、扩展、共享代码、资源和测试的职责。
- [开发与验证](Development.md)：构建、真实键盘扩展测试、资源校验与发布检查。
- [日语模型](Models/JapaneseModel.md)：模型资源、评分方式、推理边界及替换流程。

## 架构

- [输入与宿主](Architecture/InputPipeline.md)：组合状态、分段转换、提交和异步身份。
- [候选与联想](Architecture/Candidates.md)：生成、统一排序、纠错和确认后联想。
- [学习与个性化](Architecture/Personalization.md)：可信确认、两套学习机制及持久化。
- [输入后端接口](Architecture/InputBackends.md)：语言接口、候选 token 和后端接入约定。
- [表情显示](Architecture/EmojiRendering.md)：入屏准备、异步预取、内存边界及验证。

## 文档维护

公开文档描述当前行为、接口和可复现流程。功能变更应更新对应主题，避免在 README 中追加实施对话、任务清单或逐次验收日志。稳定的测试输入、参考输出和资源来源仍随代码维护在 `Tests`、`Shared/Resources` 中。

个人计划、协作记录、审阅意见、运行日志、截图和临时交付文件放在 `Docs/internalDocs/`。该目录已加入 Git 忽略规则，不作为构建或公开文档的依赖；保留项目设计所需的结论时，应整理进上述主题文档。历史记录不代表当前版本已经通过验证。
