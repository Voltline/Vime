# Vime 中文输入规划：基于 librime

日期：2026-10-09。状态：中文/Rime 仍为规划；已做共用接口准备，见 [输入后端接口说明](InputBackendInterfaces.md)。尚无中文后端、原生依赖或中文切换入口，Phase 0 未开始。版本号继续为 1.0。

## 1. 推荐路线

采用 **librime 负责中文输入状态与词典转换，Vime 负责键盘、宿主连接和产品体验**。先交付可离线使用的简体全拼，再加入双拼和可选模糊音；九宫格、中文神经排序、输入后联想放到基础体验验证之后。

Rime 是基础输入引擎，不能单凭接入它就保证现代输入法级别的词库、纠错和句后预测。方案、词典与额外模型分别决定这些能力。日文 v2.1 模型/tokenizer 不直接用于中文排序。

首版范围：

- 26 键全拼，简体输出；音节分隔、简拼/词语补全按所选 schema 配置验证。
- 连续组词、分段选词、长候选展开、翻页与退格。
- 原生用户词典调频与持久化、内部清空能力。
- 中文标点、数字、英文混输；沿用声音、振动、皮肤和符号页。
- 日文/中文/英文切换，主 App 设置与试打入口。

## 2. 已核对的事实

本地日文 `KeyboardSession` 直接依赖 azooKey `ComposingText`，`CandidateSnapshot` 保存 azooKey `Candidate`，日文内部模式仍是平假名/片假名/英文。键盘视图现通过 `KeyboardInputSession` 使用它。中文仍需独立实现 backend：拼音不应进入 RomajiConverter，候选选择也不是直接插入字符串。

[librime C API](https://github.com/rime/librime/blob/master/src/rime_api.h) 提供会话、按键处理、composition/menu、commit、选词与方案选择。标准 `RimeCandidate` 只有 text/comment/reserved，没有可直接用作统一概率的 score，也没有 azooKey 的 composingCount。不存在的信息应保留为空，comment 也不能自动认定是标准 reading。

[API 实现](https://github.com/rime/librime/blob/master/src/rime_api_impl.h) 会为结果分配内存，并消费已取出的 commit。桥接层必须复制 Swift 数据后释放原生结果，不能跨线程保存候选指针；commit 只能被宿主应用一次。

## 3. 最小架构调整

```text
Shared keyboard UI / touch / skins / symbols
                 ↓
VimeInputSession：语言路由、宿主 epoch、统一展示
          ↙                         ↘
现有 Japanese KeyboardSession     ChineseInputSession
现有 azooKey worker / v2.1        串行 RimeWorker → C bridge → librime
          ↘                         ↙
现有 KeyboardHostConnection / UIKit document proxy
```

共用协议 `KeyboardInputSession` 已由现有日文 session 实现，不重写日文转换与基础触控。`KeyboardInputLanguage` 表示日文/中文/英文；日文保留自己的假名模式，未来中文保留自己的拼音方案和简繁选项。语言路由器尚未实现。

公共接口只抽取必要部分：输入动作、preedit/selection、候选展示、确认结果、reset 和生命周期。中文内部继续持有 Rime session，不把它伪装成 azooKey 查询。

已拆出的 `CandidatePresentation` 保存 surface/source/annotation 和选择 token；token 保存 session ID、候选列表 generation、由 backend 解释的 index 与候选类别。日文 payload 继续保留原 CandidateSnapshot。未来中文 adapter 需把 token 映射到原生候选索引与分页信息；点选仍通过原生身份定位，不能使用展示 index 直接选 Rime 词。

完整 reading、来源、消费范围、engine score 等是能力相关的可选 metadata。第一版中文保持 Rime 原始顺序建立 baseline，不照搬日文 exact-reading、script consistency 或神经可重排范围。

## 4. 输入时序：不能遗漏状态命令

Rime 是有状态的输入处理器。输入、退格、选词、翻页和 reset 必须在专属串行队列**按顺序处理**。不能因为出现新按键就跳过旧的 process_key。

- 候选展示和后续模型结果可以 latest-wins。
- 已确认的 commit 必须在同一宿主 epoch 内按事务顺序消费，不因后续普通打字而丢掉。
- 光标/字段/正文外部变化和语言切换会更新 epoch；旧宿主的结果不得写到新字段。
- 选词时验证候选版本；输入命令尚未完成时，旧候选不可点击。
- Rime 返回未处理的按键才进入宿主文字回退，避免标点、退格或回车执行两次。

拼音按键需要即时视觉反馈；引擎处理在后台。原型阶段验证有限的本地拼音 echo 与 Rime authoritative preedit 的衔接，尤其是部分选词后的汉字＋剩余拼音。不在主线程等待词库查询，也不先偷偷提交文字再回删。

桥接需核对所固定版本的 UTF-8 offsets，再转换为 UIKit UTF-16 selection range；不直接用 Swift 字符数量代替两者。日文现有默认光标行为不变。

中文产品约定单独验证：空格确认当前候选；composition 为空时回车遵循宿主发送/换行类型；composition 非空时明确确认与原始拼音上屏的行为。语言切换不擅自选择尚未确认的汉字，原型先确定取消/确认策略，再接入完整 UI。

## 5. 资源与 iOS 部署

建议新增独立原生依赖 `Dependencies/VimeRime`，以小 C wrapper 暴露给 Swift，C++ 异常不得越过桥接边界。固定 librime 和所有依赖的版本/hash，支持真机 arm64 与所需 simulator 架构；验证可重复构建及 Xcode Cloud archive。

第一版只打包选定方案、必要词库和转换数据，不默认装全套 Lua 插件、所有双拼方案和多个巨型词典。

资源分三类：

| 数据 | 计划 |
| --- | --- |
| 内置方案/词典 | 随包提供与引擎版本匹配的预编译资源，首启不要求在键盘扩展里完成大型部署 |
| 用户词典 | 可写目录，原生引擎维护，独立于日文学习 |
| 用户导入方案 | 后续在主 App 校验、部署、预览，完整成功后发布新的资源版本 |

RimeTraits 提供 shared/user/prebuilt/staging 目录接口，但预编译文件在构建端、模拟器和真机的兼容性仍要实测。发布 manifest 记录引擎版本、方案版本和资源 hash，避免重演缺少本地大资源导致 Cloud archive 失败的问题。

共享资源在 App Group 内以不可变版本目录发布；扩展仅在安全的 composition 边界切换。初次安装保留随包基础资源回退，不依赖主 App 先完成导入。

不让 App 试打页与扩展同时写同一用户 DB。初期 sandbox 使用独立用户目录，扩展拥有正式学习目录；备份/清空通过关闭数据库后的协调流程处理，主 App 不直接删除正在使用的文件。两端配置可共享，学习是否合并另行设计。

## 6. 学习与上下文

先使用 Rime 原生用户词典学习，不另造完整中文词频数据库。Vime 已有的宿主回执、保留/删除信号可以复用，但不能原样复制 azooKey 的延迟 updateLearningData 流程。

[Rime memory 实现](https://github.com/rime/librime/blob/master/src/rime/gear/memory.cc) 在 commit 回调中记忆，并有最近事务回退：未处理的 Backspace 可以尝试撤回最近提交。因此中文即使没有 composition，退格也需要先交给 Rime，再决定是否删除宿主文字。这条链路必须验证，不能把“删除词条”API 当成撤销最近学习。

需要验证：重复选择同音非首选→排名提升→session/进程重建仍保留；退格后最近学习如何变化；字段变化和宿主未插入是否留下原生学习。未完成原生回退验证前，不宣称拥有与日文相同的 1.5 秒学习撤销保证。

Rime 的 composition context 不等于宿主已经提交的整段正文。基础组句可以先用原生机制；宿主左上下文由 Vime 独立核对。未来中文模型用它做语义排序/下一词预测，字段变化时重建上下文，不能把 set_property 当成自动具备语义预测的接口。

## 7. 方案、词库与许可

工程上建议用一个小而完整的全拼方案跑通，然后对基础词库与雾凇拼音等候选资源做同一语料比较，再决定默认包。

已确认 [librime 是 BSD-3-Clause](https://github.com/rime/librime/blob/master/LICENSE)，[雾凇拼音仓库是 GPL-3.0](https://github.com/iDvel/rime-ice/blob/main/LICENSE)。本地 Vime 根 LICENSE 是 GPL v2 文本；引擎、插件、方案和词库的许可/来源需分别核对，不能因引擎许可就认定所有资源可以直接按同样方式发行。

官方 [朙月拼音](https://github.com/rime/rime-luna-pinyin) 可作为功能参考；本轮未确定生产词库的最终许可组合。Phase 0 固定具体版本并列出来源及声明后再做选型，不自动把整个第三方配置复制进仓库。

## 8. 实施阶段与完成标准

| 阶段 | 工作 | 完成标准 |
| --- | --- | --- |
| 0：可行性原型 | 固定引擎/词库、原生构建、最小 schema、独立试打、资源预编译 | 真机能输入 `nihao → 你好`、选词与退格；给出冷启、内存、包体和许可清单 |
| 1：基础中文 | 接入全拼 session、拼音 preedit、分段选词、分页、标点与原生学习 | 连续输入/退格正确，无重复上屏；非首选调频及重启持久化验证 |
| 2：Vime UI | 最小语言 adapter、中文切换、App 设置、候选展开、皮肤与声音复用 | 宿主字段/光标变化、语言切换与旧结果隔离正确，日文定向行为保持 |
| 3：输入方案 | 引入一到两种双拼；可选模糊音、简繁转换、自定义短语 | 配置可恢复，正确拼音不过度纠正；方案切换后记忆与资源一致 |
| 4：词库与部署体验 | 中文 corpus 调优、资源版本管理、学习清空/备份、可控导入 | 新词库可回滚，不在扩展内耗时编译，不并发损坏用户 DB |
| 5：中文智能增强 | 单独评估中文小模型、混输、错拼补充、语义重排及句后联想 | 相对固定 Rime baseline 有可测的质量收益，并满足实机延迟/内存预算 |

九宫格另列里程碑：它涉及按键到多字母编码的歧义、音节筛选和独立布局，不能把已有数字九宫格改几个标签就视为中文九宫格。五笔、注音、粤拼等依托方案机制后续扩展。

## 9. 精简验证与性能验收

先建立约 50～100 条小 corpus，覆盖全拼、简拼、长句、分段确认、`xi'an` 音节边界、`nv/nve`、英文数字与标点、Unicode offsets、候选分页，以及字段 reset。聚焦正确提交、候选可用性和学习，不用所有样例锁死 Top1，也不重跑全部日文大基准。

必要的日文保护检查仅覆盖：正常输入/marked ownership、unfinished Roman suffix、n 处理、候选选择和语言切换。触控只验证共用接口相关的路径。

实机记录 cold initialize、warm process_key、队列等待、候选 publish、词库部署时间、用户 DB 写入和峰值 footprint。初步性能目标是保持主线程按键/preedit 工作短于一帧、常用 warm 候选 P95 争取 20 ms 内；这是验收目标，不是已测结果。具体内存预算在原型测量后确定。

中文模式不同时常驻日文 LM；切换时要验证实际释放效果，不能仅调用 stopComposition 就假定词库/模型已经卸载。扩展可用内存与被系统终止的情况通过目标设备实测，不能把固定某个 MB 数当作所有设备的保证。

**下一步建议：先实施 Phase 0，只在独立试打入口证明 Rime 能在 Vime 的 iOS 环境稳定运行，再投入语言路由和完整键盘整合。**
