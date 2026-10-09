# V2.1 KV cache 实验

从 2026-10-09 最新 main `1ea4cf8` 建立独立分支。沿用 V2.1 extend5 step40000
权重、V2 tokenizer、INT8 block32、FP32 compute、CPU_ONLY 和 iOS18。
默认构建仍选择 `.v21`；显式 `.v21KV` 或 KV 构建配置选择新版本。

## 安装与启用

先按 [V2.1 安装文档](LanguageModelV21.md) 安装原模型和 tokenizer，再安装匹配的新资源：

```sh
python3 Scripts/install_kv_resources.py /path/to/VimeML/artifacts/deployment/tiny-ja-v2.1-extend5-kv-client-resources-v2/Resources
python3 Scripts/validate_model_resources.py --kv
xcodebuild -project Vime.xcodeproj -scheme Vime -configuration Release \
  -xcconfig Configuration/KVCache.xcconfig -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR' build
```

`KVCache.xcconfig` 增加 `VIME_KV_CACHE` 编译条件，并选择包含新资源的预检文件清单。
App 和键盘使用相同配置。普通构建不要求外部 KV 资源；Release KV 构建缺资源或身份不符会失败。
初始化也校验 manifest、tokenizer、模型文件和缓存形状。KV 大模型不提交 Git，从结果 ZIP 安装。

## 缓存边界

每份 K/V 为 FP32 `[6,1,5,128,64]`，两者共1.875MiB，不含运行时临时量与分支副本。
显式输入输出避免候选共享可变模型状态；每次预测产生新快照，用 scatter 更新对应绝对位置。
不训练或改变权重，不改联合分词、公共前缀、完整词表 log-softmax、suffix logP sum 与稳定并列顺序。

- 排序按 context 和所有联合候选的实际 token 公共前缀预填充一次，再分别计算候选后缀。
- 下一词的各分支从同一前缀快照出发，后续只追加新 token；beam 的子分支共享只读父快照。
- 只在单次评分/联想请求内保留缓存。请求结束、取消后释放，不跨请求复用；退格、宿主上下文变化重新预填充。
- 学习式位置编码始终使用绝对 token 位置；达到128 token 时保留原拒绝/停止规则，不滑动缓存。
- 图输出 `[1,Q,16384]` 仅对应新输入 Q 个 token；单 token 解码只有64KiB logits。
  预填充仍计算完整新增前缀行，客户端取出最后一行后释放其余输出。避免转换图内额外动态输出切片。
- 失败仍保留词典候选，原 `.v21` 和显式 `.v1` 可选。

## 验证范围

Mac 与优化模拟器对照结果及已知限制见 VimeML `docs/reports/mac-20261009/v21-kv-cache.md`。
本轮用户选择仅 Mac/模拟器验证，不复用前一天的真机内存或延迟作为此版本结果。
缓存本身和显式输出拷贝有开销；收益以端到端请求计时为准，不能由减少的 token 数直接推断。

本次优化模拟器13项功能检查通过；2337条冻结候选的Top-1及完整排序均与原INT8一致，
12条增量greedy续写也完全一致。KV与同权重无缓存模型的logits最大差约0.00004768。
原INT8相对FP32的严格数值偏差仍保留，KV没有修复量化偏差。

Apple M3 /16GiB、iOS27.0 Simulator，两个独立测试进程分别只加载一种后端：

| 请求 | 无缓存 /KV p50(ms) | p50加速 |
| --- | ---: | ---: |
| 短上下文评分 | 6.94 /6.47 | 1.07× |
| 17-token上下文、4个候选 | 41.93 /24.54 | 1.71× |
| 下一词 | 57.75 /29.96 | 1.93× |
| beam | 455.19 /189.68 | 2.40× |

模拟器宿主内核footprint峰值48.03 /48.30MiB；50次追加请求后为41.50 /42.08MiB。
这些是模拟器进程值，不能当作真实键盘扩展的内存预算或长期稳定性结论。
