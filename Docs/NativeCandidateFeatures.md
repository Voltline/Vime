# azooKey 原生能力接入

本轮接入确认后联想、特殊转换与 emoji 联想、用户词典。依赖固定为 `d59a28e4c7ca049aef04f29a91eae9677a7753f2`，版本号保持 1.0。没有新增模型或启用 Zenzai。

## 确认后联想

原路径只有 Vime CoreML 生成及历史记忆；现在在后台串行 worker 中先调用 `requestPostCompositionPredictionCandidates`，立即发布原生候选，再按智能排序设置异步生成和重排合并后的建议。词典排序模式完全不必加载 CoreML，模型不可用也保留原生建议。联想开关同时控制两套来源。

`NativePostCompositionPrediction` 保存原生 base Candidate、text、value、PredictionType、isTerminal 与 expectedLeftContext，并在 converter 队列上重建上游 prediction 对象。它不被提前转为 String；CandidateSource 区分 enginePrediction / contextPrediction / emoji。追加与替换同形候选按操作分别去重，相同追加内容保留原生对象用于学习。

特别注意：上游 replacement 的 `text` 是新增后缀，完整替换内容在 `replacementData` 中。例如它可表达「東京」→「東京都」，text 为「都」。Vime 展示完整替换词，并执行经过验证的尾部删除 + 完整插入，不能删掉「東京」后只插入「都」。UI 显示「替换『東京』」说明，原生 `join(to:)` 负责后续词条和词性上下文。isTerminal 候选确认后停止继续联想。

发布与选择都受 generation / selection token、真实左侧文本、document identity、右侧文本及无选区限制。候选返回前用户继续输入或 reset，就取消旧发布。选择时正文或字段不匹配则不返回删除／插入操作。原生替换也使用已有宿主回执和保留窗口；回执 anchor 位于被替换尾部之前。确认保留后调用 `updateLearningData(base, with: prediction)`，在隔离的学习 session 中更新完成数据并持久化。撤回、字段改变或缺失回执不学习。

初始合并采用集中管理的、有界来源内排名证据及已有用户偏好，不直接把词典 value 和 LM logP 相加。智能模式随后按相同 continuation token 边界评分整个可评分候选池；replacement 使用新增后缀，避免 prompt 中已有文字重复参与条件概率。原生 emoji 或不能往返 tokenize 的文本保留基础证据。该补充重排有 250ms 软预算；取消与 latest-wins 不改变即时 preedit。

## 特殊转换与 emoji

通过上游 Calendar、TimeExpression、CommaSeparatedNumber、Unicode、EmailAddress provider 获取候选，Vime 标记 specialConversion，保留 ruby 与 consumption。provider 候选统一交给 reranker，特殊转换证据 5、emoji 证据 1.5，仍弱于合法 exact lexical evidence；没有固定候选位置。动态日期／格式输出不反馈为普通词的学习。

已验证的可操作路径包括 `1230` → `12:30`、`1000000` → `1,000,000`、`reiwa6nenn` → `2024年`。年号数字需符合上游支持的格式，不能把「ろく」口头读音当成该 provider 支持的数字解析。数字仅在普通文本框的日文模式进入 composition；专用数字字段和英文模式保留直接输入。按回车不选格式时仍提交字面数字。

TextReplacer 使用随依赖附带的默认 emoji 词典。在输入中按 reading 查询相关 emoji（最多六个基本表情），并让原生确认后联想使用词语关联表情；基础词语与 emoji 分源，emoji 不假冒 lexical Candidate。完整 Unicode 表情面板仍使用 Vime 原有目录，这次没有改动其资源或触摸逻辑。

Unicode 和邮箱 provider 使用原始 ASCII 查询的独立 direct 副本，输出只加入候选池，不重写字面假名草稿；仅在 `u` / `U` 前缀或 `@` 出现时执行该查询。例如 `u3042` / `u+3042` → `あ`，`test@` → `test@gmail.com`。符号面板的 `+`（Unicode 输入时）、`@` 和邮箱中的 `.` 可继续该 composition。消费计数映射回真实 query，邮箱各域名保留上游来源内排名。本轮没有把英文直通模式改成英文 conversion session，因此这些特殊候选在日文模式使用。

## 用户词典

主 App 设置新增词典页面，可增加、编辑、删除词语与短语快捷输入，以及 JSON 合并导入／导出。支持完整罗马字或假名读音，保存时规范化为片假名。词语使用 `importDynamicUserDictionary(words, shortcuts:)` 的 words 通道；短语使用 shortcuts，仅在完整读音匹配时生成。词语参与词典分段与预测，不自行实现候选硬插入。

文件位于共享容器 `Vime/UserDictionary.json`；App 原子保存后更新共享 UserDefaults 中的 revision。worker 仅在初次使用或 revision 改变时读取文件，之后使用内存 snapshot。没有共享访问时使用本地 Application Support fallback；键盘要读取主 App 的词典仍需要完全访问。读取失败保留最后一个合法 snapshot，不在每个按键重复读取坏文件。

格式：`{"version":1,"entries":[{"id":"UUID","reading":"トウキョウ","surface":"東京","kind":"word"}]}`；kind 可为 word / shortcut。读音 1–64 假名，surface 1–128 字符且禁止控制字符，最多 1,024 条、导入文件最大 1 MB。导入先验证整个文件，再合并去重；重复 ID 会重建，未来版本或非法文件不覆盖已有词典。读音未完成的 Roman suffix 不会作为有效词条保存。

CandidateSource 标记 userDictionary，与 predictionStatus 独立，避免“注册词同时是 prediction”丢失预测惩罚或元数据。注册词得到有上限的来源证据，仍由原生 engine score、完整消费、读音、学习与上下文共同排序；神经排序保留注册证据。既有补充词库和用户词典共同导入，互不覆盖。

## 验证与限制

定向测试覆盖特殊格式消费、emoji 与 lexical 共存、用户词典变更／重建／删除／导入校验、无需 LM 的联想与句点停止、真实替换的宿主 identity 和回执、异步过期选词拒绝，以及 native replacement 的神经后缀评分。并复核分段尾部与学习、学习回执、现有句子排序三个相关用例。第一完整定向批次 **10 个用例、0 失败**，用例阶段 7.32 秒（不含构建／模拟器启动）。另新增真实 KeyboardView 数字按钮用例，确认普通文本草稿和 numberPad 直通的区别，并复核词典、异步联想，共 3 个用例通过；合计 **11 个不同用例**。日志分别位于 `/private/tmp/vime-native-features-tests-final2.log` 和 `/private/tmp/vime-native-features-final-routing.log`。App 与键盘扩展 Debug 模拟器构建通过。

示例原生结果：确认「猫」后得到猫表情、「猫の」「猫が」等建议；确认「東京」后包括东京塔表情、「東京都」「東京大学」等替换和助词；确认「です」后包含「。」「！」。神经后缀评分测试中「東京都」「東京大学」「東京帝国大学」分别约为 -8.53 / -10.36 / -14.25，且与直接对「都」「大学」「帝国大学」评分一致，证明没有把「東京」重复计入。

最后对 ASCII 入口和受影响的数字／排序路径复核 3 个用例，全部通过，日志 `/private/tmp/vime-native-features-special-final.log`；`u+3042` 的第一个候选为「あ」，`test@` 的第一个格式候选为 `test@gmail.com`。这次增量构建也包含主 App 和键盘扩展。各复核批次的重复用例不计入上述 11 个不同用例。

没有运行完整 UI、触摸、emoji 或模型 benchmark；没有改动 touch ownership、基础 marked text 与 Roman suffix 处理。原生联想本身不保证候选风格理想，基础词典有口语和语气扩展，智能模式可继续参与过滤和排序。EMA／用户训练或 Zenzai 实验纠错不在本轮范围。

emoji 词语映射受固定依赖附带的 emoji 版本限制，不等于 Vime 表情面板的全部新 Unicode 表情都能按词语检索。JSON 是 Vime 的交换格式，目前不导入 Rime/SKK 文件。删除词典词条不清除此前已确认的学习记忆。词典编辑不是即时同步旧的候选列表，继续输入或重新打开键盘后读新 revision。多进程同时编辑同一个词典尚无事务合并；目前编辑入口只有主 App。

候选与 LM 工作仍在后台串行队列：CoreML 或词典调用开始后不能强制中断，只有调用间的取消检查；250ms 是软预算，不是单次推理的硬超时。新增 `nativeNextWords` 计时，真实设备耗时与能耗尚待验证。
