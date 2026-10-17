# 学习与个性化

## 两套机制

azooKey Learning Memory 记录真实候选选择，影响引擎转换与原生联想。Vime 的轻量偏好层补充重复选择、近期使用和上下文证据，使神经重排也能读取用户偏好。语言模型判断上下文自然度，不执行在线权重训练，也不能代替原生学习；Zenzai 当前未启用。

## 可信确认

生产宿主的选词先创建待确认反馈。提交编辑后等待宿主文本回执，允许远程代理在稍后的文本通知中返回新内容；约 1.5 秒保留窗口、下一次提交或键盘隐藏时完成确认。iOS 在空输入框或已拥有的待确认文本周围可能返回 nil 正文；此时仍创建选词意图，但只有之后返回非 nil、包含所选文本的回执才接受学习。右侧 nil 和空字符串视作同一个空边界。

宿主可以只返回固定长度的正文窗口，确认比较双方已知的共同后缀，并要求所选文本可见。已经验证上屏的选择，在发送、光标移动、切换字段、外部清空正文或隐藏键盘时保留；这些操作不再被当作撤销。保留窗口内由键盘直接删除所选文本会取消反馈；从未收到有效回执的事件不进入学习。

只有接受的事件进入学习。点击候选、用空格切换到非首选再确认，都提供主动选择证据；惯性确认首选仅提供较弱的频次证据。无宿主的直接测试接口仅用于组件验证，不能证明真实扩展的回执路径正确。

[CandidateLearningFeedback](../../Shared/Candidates/Learning/CandidateLearningFeedback.swift) 管理该边界；[KeyboardHostConnection](../../Shared/Host/KeyboardHostConnection.swift) 提供正文、字段与提交回执。

## 原生学习

生产 worker 在目录可写时使用 `.inputAndOutput`，最多 8,192 条原生记忆。直接构造 `JapaneseCandidateEngine` 的默认参数不启用学习，测试或其他调用方应显式选择。

引擎保留真实 Candidate，使用独立 learning session 管理 `setCompletedData` 与 `updateLearningData`，避免普通候选查询切换污染已确认上下文。原生确认后联想使用 `updateLearningData(base, with: prediction)`，不能把展示字符串伪装成原生对象。

接受反馈及生命周期边界在后台调用 `commitUpdateLearningData()`；按键查询不写学习磁盘。当前 API 调用次序与 session 切换以 [引擎实现](../../Shared/Candidates/Engine/JapaneseCandidateEngine.swift) 为准。

## Vime 偏好

[CandidatePreferenceMemory](../../Shared/Candidates/Learning/CandidatePreferenceMemory.swift) 按 scope、reading、surface 和上下文记录 evidence、确认次数及时间。普通频次至少需要两次确认；主动选择从第一次开始加分，同一上下文重复选择形成更强保护。频次按 30 天半衰期衰减，近期加分按较短窗口衰减。

主动偏好优先使用末尾 12 字的上下文，其次使用末尾 4 字；没有本地选择记录的新句子继承全局偏好，置信度最高为 0.8，约三次主动选择可达到保护门槛。具体上下文中的新选择可以覆盖全局习惯，更新的主动纠正也可以取代旧习惯。偏好加分有上限，神经重排尊重强偏好；同一轮已经显示的候选仍冻结顺序，学习影响后续输入。

单词和短语的原生分词都记录有界的词级偏好，使单词选择可以影响新短语，短语选择也可以影响单词；跨短语证据仅提供温和加分，不形成整句锁定。

上下文使用左侧末尾 12 字和 4 字的 SHA256 桶。它用于匹配，不是加密或匿名化保证。未选中的词不会自动受到永久拒绝惩罚。

下一词历史召回数量有界，要求重复确认及兼容上下文，再通过真实 LM 分数检验；模型评分失败时不会用未评分历史替代正常建议。

## 存储与并发

学习目录优先为 App Group 下的 `Vime/AzooKeyMemory`，共享目录不可用时回退本地 Application Support。Vime 偏好文件为 `VimeSelectionFrequency.json`，最多 2,048 条记录，读取大小上限为 4 MiB。

Vime 层按新增事件积累 delta，写入时使用独立 `.lock` 文件的跨进程锁，读取最新磁盘状态、合并新 delta，再原子保存；不能把两个旧快照直接相加。清空产生新 epoch，拒绝旧事件复活记忆。损坏或不支持的文件保留归档，失败写入保留待重试数据。

每次转换或联想查询前，worker 检查偏好文件的 inode、大小和修改时间；文件变化时读取新快照并合并本实例尚未保存的 delta，无需先产生自己的写入。清空 epoch 变化会丢弃旧代待保存事件和近期加分；损坏文件不会覆盖最后一个有效内存快照。

该事务锁和刷新机制只覆盖 Vime 偏好 JSON，不覆盖 azooKey 自身文件。App Group 访问和磁盘可写性影响共享学习是否可用。

`clearLearning()` 清除原生学习、Vime 偏好和相关会话缓存。用户词典与学习记忆独立：删除注册词不等于删除它已有的选择记录。
