# 输入与宿主

## 主路径

`KeyboardView` 接收按键与手势，主线程 `KeyboardSession` 更新组合状态，并发布 `KeyboardPreedit` 和文档编辑操作。宿主适配器负责 marked text 与实际正文。词典查询、模型、纠错及学习工作在串行 worker 上执行；候选请求不阻塞即时假名草稿。

罗马音转换保留尚未完成的辅音；末尾未确定的 `n` 可以继续组成音节。候选查询可以探索其他读音边界，但不会偷偷改变草稿。未选择候选时确认的是字面输入。

## 候选与转换状态

普通输入持续更新候选。空格开始转换并继续切换候选；查询未完成时保留转换意图。回车确认已选候选，或提交尚未转换的草稿；没有组合内容时执行宿主提供的回车动作。

候选通过 `CandidateSelectionToken` 选择：session 身份、列表 generation、类别和索引必须相符。同一输入 revision 的补充结果也会产生新列表 generation，不能凭旧按钮索引选中更新后的另一词。已选候选不会被迟到的纠错或模型排序替换。

退格取消转换预览或待处理转换意图时，同步恢复当前草稿并重新请求候选。输入、reset 和后台发布共同受 revision 校验，旧请求不能覆盖新输入。

## 分段转换

原生候选的消费范围与剩余 `ComposingText` 一起保留。选取部分候选只确认对应前段，尾部仍作为组合输入继续转换。完整候选菜单提供范围缩短、增长和恢复整句，并按需加载更多候选。

消费计数来自 azooKey 的 `composingCount`，再通过真实 Roman / 假名边界计算尾部；不能按候选表面字符串长度切输入。完整消费、部分消费和显式选择范围分别保留 metadata。

宿主提交顺序是结束原 marked text、插入已确认前段、建立剩余 marked text。`KeyboardPartialCommitReceipt` 用于检查部分提交后的宿主状态；回调不能把此前已写入正文的内容当作新草稿再次提交。需要结合真正扩展和第三方宿主验证。

## 宿主边界

`KeyboardPreedit.selectedRange` 使用 UTF-16；原生字节选区须显式转换，拒绝拆开编码或越界的范围。相同文字但选区不同也须发送宿主更新。

光标移动、切换字段、外部修改正文和语言切换需要 reset / reconcile，并使旧 host epoch 与候选身份失效。上下文读取以宿主实际正文为准，排除当前 marked text，不能无限沿用内部已提交历史。

异步提交通过 `KeyboardCommitBatch(hostEpoch, edits)` 发送。每次提交只能同步返回 edits 或异步发布 batch 其中一种；后端负责命令有序与恰好一次消费。候选 latest-wins 不允许丢弃已经产生的文档提交。

## 触摸与诊断

触摸面统一管理 ownership，装饰层不参与命中。连续打字的小幅移动与明确上滑分别处理；抬指不能自行创建符号手势。修改候选或皮肤时保持该输入边界。

[KeyboardPerformance](../../Shared/Diagnostics/KeyboardPerformance.swift) 提供转换、重排、纠错、联想及发布计时；扩展审计与触摸诊断按开发开关启用。计时是当前运行的观测值，软预算不等于单次引擎调用的硬超时。

入口代码：[会话](../../Shared/Input/KeyboardSession.swift)、[宿主连接](../../Shared/Host/KeyboardHostConnection.swift)、[扩展控制器](../../Keyboard/KeyboardViewController.swift)。
