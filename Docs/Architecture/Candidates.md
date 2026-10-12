# 候选与联想

## 候选池

azooKey 是候选生成器，Vime 负责统一展示排序。原始转换和预测、读音边界备选、脚本变体、特殊转换、用户词典、表记变体与纠错进入同一候选池，规范化后去重。顺序不由固定来源拼接或固定片假名位置决定。

[CandidateSnapshot](../../Shared/Candidates/CandidateSnapshot.swift) 保留 surface、ruby / reading、原生 Candidate、来源、消费计数、实际剩余输入、exact / full 标志、预测状态、引擎值、脚本类别、学习资格、纠错 metadata 和 revision。UI 使用独立的 `CandidatePresentation`，排序及确认不降成只有字符串的数组。

## 基础排序

[CandidateReranker](../../Shared/Candidates/CandidateReranker.swift) 集中管理权重和诊断特征：

| 特征 | 作用 |
| --- | --- |
| 引擎值与来源内顺序 | 保留原始词典证据，处理不同结果类型的分值尺度 |
| 完整读音与完整消费 | 输入完整时优先对应当前读音的合法词条 |
| 预测延伸惩罚 | 区分当前词与额外预测出的后续文字 |
| 脚本一致性与用户模式 | 修正同一假名词内不自然混用；允许正常汉字 / 假名混合 |
| 连续性 | 前一首选仍兼容新输入时给予有界加分，不冻结结果 |
| 用户学习与上下文 | 结合可信重复选择与实际左侧文本 |
| 纠错成本与词典收益 | 修改越多，进入候选池需要越强证据 |
| 分段、表记和来源 | 区分显式范围，加入有上限的语言资源和注册词证据 |

平假名、片假名变体作为候选来源参与排序；与词典相同表记去重，保留有价值的原生 payload。词典已经提供标准片假名词时，通用脚本候选不会靠固定位置挤占它。

表记偏好与补充词库来自 [语言资源来源清单](../../Shared/Resources/LanguageResourceSources.json)。偏好是弱证据，不禁止另一表记，也不覆盖明确模式、上下文或长期用户选择。

## 神经重排

智能模式对适用的 lexical、完整范围、exact-reading 候选计算条件概率；显式分段范围可以作为独立完整范围。转换、表记变体和注册词保留相应资格及来源证据。片假名模式跳过该神经重排。

神经评分结合有界用户偏好、表记和注册词证据，稳定处理并列分数。评分失败、取消或超出软预算时回退到基础候选顺序，不能发布一半评分造成的偶然排序。细节见 [模型说明](../Models/JapaneseModel.md)。

## 纠错

正常候选先发布；输入停顿约 140 ms 后补充查询一处邻键替换、漏字、多字、转置、近音，以及最多两处音近组合。规则基于键位与音组，使用词典索引和真实转换结果筛选，不维护整词示例替换表，也不以 Levenshtein 距离独立决定结果。

变体上限为 384，另有最多 32 个配对音假设；最多 24 次转换查询、两个接受的修正读音和四个展示候选。额外错误承担额外成本，短合法输入需要更强收益。classic typo 仅作受限补充，experimental LM typo 与 Zenzai 当前未启用。

60 ms 搜索预算包含准备与查询，是软预算：不可中断的原生调用可能超时，准备阶段也可能耗尽预算而没有执行查询。纠错覆盖与实机耗时仍需按 corpus 验证，不能保证所有误音都产生建议。

纠错候选保留原输入、建议 Roman 输入、建议读音、修改范围与成本。候选 UI 显示建议读音；只有用户选择后才接受修正，不自动改 marked text。

## 确认后联想

后台首先请求 `requestPostCompositionPredictionCandidates` 并发布原生建议；智能模式再融合模型生成与符合条件的历史建议。词典模式或模型不可用时仍能提供原生联想。不同来源先使用有界的来源内证据，避免把词典 value 与 LM logP 直接相加；可评分内容随后按统一 continuation 边界重排。

联想保留追加、替换、原生 base Candidate、prediction 对象及终止标志。原生替换的 `text` 可能只是新增后缀，展示与提交须使用完整替换词；例如替换「東京」为「東京都」时，不能删掉「東京」后只写「都」。神经概率评分只计算新增后缀。

发布和选择均校验候选身份、实际左右正文、字段身份及选区；正文不匹配时不执行删除或插入。终止候选确认后停止继续联想，可信保留后才反馈原生学习。

## 特殊候选

Calendar、TimeExpression、CommaSeparatedNumber、Unicode、EmailAddress provider 提供年号、时间、数字格式、Unicode 和邮箱候选。普通文本框日文模式的数字可进入 composition；专用数字字段与英文模式直接输入。Unicode / 邮箱使用独立 ASCII 查询，不重写字面草稿。

词语相关 emoji 来自依赖的 TextReplacer 数据，与 lexical 分源；其覆盖范围不同于 Vime 的完整 Emoji 面板。动态格式与 emoji 不冒充可学习的普通词条。

入口代码：[引擎](../../Shared/Candidates/JapaneseCandidateEngine.swift)、[worker](../../Shared/Candidates/JapaneseCandidateWorker.swift)、[联想模型](../../Shared/Candidates/PostCompositionSuggestions.swift)。
