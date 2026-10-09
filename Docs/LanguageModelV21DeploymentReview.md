# V2.1 新交付版部署评估（2026-10-09）

决定：保留当前默认的 `2.1-extend5-step40000-int8-b32-v1`，本轮不部署 KV 版。

当前 Vime 已经使用 INT8 block32、FP32 compute、CPU_ONLY 的 V2.1 模型。最新交付版
`2.1-extend5-step40000-int8-b32-kv-v1` 使用相同 checkpoint、tokenizer 和压缩权重，
主要变化是显式 KV 输入输出及客户端请求内缓存复用，没有新增预测准确率收益。

## 核对与已有证据

- 当前 manifest 与模型工作区原 V2.1 交付包的 manifest 完全一致，当前 Release 资源预检通过。
- 最新 KV compiled payload 的全部文件 SHA-256 与真机验收 manifest 一致。
- 两版 tokenizer、checkpoint、`weights/weight.bin` SHA-256 相同。
- 模型侧已完成 2337 条冻结候选对照，Top-1 和完整排序均未变化；12 条增量 greedy 续写与原 INT8 一致。
- 后续真机验收记录为 13 项功能测试通过、4 个新进程性能测量、81 次 worker 联想循环和 100 次快速输入/退格取消检查通过。这些是交付包中的既有结果，本轮没有重复运行。

## 真机性能决定部署选择

iPhone 16 Pro Max、iOS 27.2、Release、CPU_ONLY；同一测试二进制、固定输入，
两轮分别按原版→KV、KV→原版执行，每个新进程只加载一种后端。表中范围是两轮各自的 p50，
不是合并样本的分位数。

| 请求 | 原 INT8 p50（ms） | KV p50（ms） |
| --- | ---: | ---: |
| 短上下文评分 | 3.70–3.79 | 3.46–3.58 |
| 17-token 上下文评分 | 8.13–8.13 | 9.22–9.29 |
| 下一词 | 12.86–12.96 | 13.93–14.33 |
| beam | 94.49–94.56 | 99.03–99.55 |

短评分 p50 约改善 5–7%，但其 p95 从 4.80–4.82 ms 升至 5.20–5.48 ms；
下一词和 beam 的 p50、p95 均变慢。测试宿主内核生命周期 footprint 峰值由
56.80–56.89 MiB 增至 87.49–88.03 MiB。宿主内存不能直接当作实际键盘扩展的内存预算。

实际扩展另有两轮手动记录，已确认加载版本和智能排序／下一词开关；KV 的测得内存更高，
但操作内容与采样时段未冻结，不能单独据此推断 KV 的因果影响。两版均有结果到 UI 发布的长尾。
模拟器约 1.9× 下一词、2.4× beam 加速没有迁移到上述真机固定工作负载，故不据模拟器结果替换默认。
这也不否定其他设备、其他长度或以后优化后的 KV 实现可能受益。

## 交付边界与证据位置

本轮只执行资源身份核对和当前模型预检，没有替换模型、接入实验缓存后端、安装到手机或上传 App Store Connect。
版本仍为 1.0。后续提交警告清理和评估文档不改变本次保留原默认模型的决定。

主要证据来自模型工作区 `handoff/vimeml-v21-kv-iphone-results-handoff.json` 的 `acceptance`，
以及 `vimeml-v21-kv-iphone-results.zip` 内的
`outputs/deployment/v21-kv-iphone-closeout-v1/report-zh-CN.md`。
Mac／模拟器的旧报告为 `docs/reports/mac-20261009/v21-kv-cache.md`；最新真机报告优先用于本次部署决定。
