# 学习与个性化

## 两套机制

azooKey Learning Memory 记录真实候选选择，影响引擎转换与原生联想。Vime 的轻量偏好层补充重复选择、近期使用和上下文证据，使神经重排也能读取用户偏好。语言模型判断上下文自然度，不执行在线权重训练，也不能代替原生学习；Zenzai 当前未启用。

## 可信确认

生产宿主的选词先创建待确认反馈。宿主写入回执及约 1.5 秒文本保留窗口共同决定是否接受；立即撤回或删除、移动光标、切换字段、外部正文变化、缺失回执会使事件失效。

只有接受的事件进入学习。点击候选与空格确认采用不同证据权重，重复选择非首选通常比惯性确认首选提供更强偏好证据。无宿主的直接测试接口仅用于组件验证，不能证明真实扩展的回执路径正确。

[CandidateLearningFeedback](../../Shared/Candidates/CandidateLearningFeedback.swift) 管理该边界；[KeyboardHostConnection](../../Shared/Host/KeyboardHostConnection.swift) 提供正文、字段与提交回执。

## 原生学习

生产 worker 在目录可写时使用 `.inputAndOutput`，最多 8,192 条原生记忆。直接构造 `JapaneseCandidateEngine` 的默认参数不启用学习，测试或其他调用方应显式选择。

引擎保留真实 Candidate，使用独立 learning session 管理 `setCompletedData` 与 `updateLearningData`，避免普通候选查询切换污染已确认上下文。原生确认后联想使用 `updateLearningData(base, with: prediction)`，不能把展示字符串伪装成原生对象。

接受反馈及生命周期边界在后台调用 `commitUpdateLearningData()`；按键查询不写学习磁盘。当前 API 调用次序与 session 切换以 [引擎实现](../../Shared/Candidates/JapaneseCandidateEngine.swift) 为准。

## Vime 偏好

[CandidatePreferenceMemory](../../Shared/Candidates/CandidatePreferenceMemory.swift) 按 scope、reading、surface 和上下文记录 evidence、确认次数及时间。持久偏好至少需要两次确认，频次按 30 天半衰期衰减；近期加分按较短窗口衰减。全局和上下文证据均有上限，不采用 last-selected-wins。

上下文使用左侧末尾 12 字和 4 字的 SHA256 桶。它用于匹配，不是加密或匿名化保证。未选中的词不会自动受到永久拒绝惩罚。

下一词历史召回数量有界，要求重复确认及兼容上下文，再通过真实 LM 分数检验；模型评分失败时不会用未评分历史替代正常建议。

## 存储与并发

学习目录优先为 App Group 下的 `Vime/AzooKeyMemory`，共享目录不可用时回退本地 Application Support。Vime 偏好文件为 `VimeSelectionFrequency.json`，最多 2,048 条记录，读取大小上限为 4 MiB。

Vime 层按新增事件积累 delta，写入时使用独立 `.lock` 文件的跨进程锁，读取最新磁盘状态、合并新 delta，再原子保存；不能把两个旧快照直接相加。清空产生新 epoch，拒绝旧事件复活记忆。损坏或不支持的文件保留归档，失败写入保留待重试数据。

该事务锁只覆盖 Vime 偏好 JSON，不覆盖 azooKey 自身文件。其他进程的内存缓存也不会即时刷新全部偏好，当前在后续写入协调时更新。App Group 访问和磁盘可写性影响共享学习是否可用。

`clearLearning()` 清除原生学习、Vime 偏好和相关会话缓存。用户词典与学习记忆独立：删除注册词不等于删除它已有的选择记录。
