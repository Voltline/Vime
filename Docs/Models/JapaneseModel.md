# 日语语言模型

## 资源契约

当前默认资源为 v2.1，模型版本以 [VimeLMManifestV21.json](../../Shared/Resources/VimeLMManifestV21.json) 为准。

| 资源 / 属性 | 当前值 |
| --- | --- |
| 编译模型 | `TinyJapaneseV21INT8.mlmodelc` |
| 分词器 | `VimeJapaneseTokenizerV2.model` |
| Manifest | `VimeLMManifestV21.json` / `vime_ios_lm_v2` |
| 计算设备 | `CPU_ONLY` |
| 量化 | INT8，block size 32 |
| 词表 / 上下文 | 16,384 / 128 tokens |
| 特殊 token | pad 0、unk 1、bos 2、eos 3 |

这些资源已纳入版本控制。运行时只加载匹配的 v2.1 模型、分词器和 manifest；资源不合法或模型不可用时，输入继续使用词典候选。旧 v1 模型及其参考数据已移除，当前模型测试使用 `Tests/UIKit/Resources/VimeLMFixturesV21.json`。

[VimeLanguageModel](../../Shared/Models/VimeLanguageModel.swift) 校验 manifest 与校验和后按需加载，计算设备配置也受契约约束。改变 compute units 需要验证模型兼容性与整条输入路径，不能直接宣称 Neural Engine 更快或更省电。

## 转换评分

模型使用左侧最近未结束句子的有限上下文，当前最多 64 个字符；句首仅使用 BOS，完整 token 输入仍须满足 128 token 上限。prompt 与候选联合分词，通过公共 token 前缀确定需要评分的后缀，累加其 log-softmax 概率。重排直接复用逐项校验得到的联合 token 序列，避免评分前再次分词。

当前转换重排使用后缀 log-probability 总和，不追加 EOS、不按字符或 token 数做额外长度归一化，也不静默截断不合法输入。分段候选按实际选择范围评分；native replacement 只评分新增后缀。

模型可跨按键复用同一上下文下的精确序列评分、共同前缀及末行概率分布，但没有 transformer KV cache；分布行主要数据上限为 1 MiB，切换上下文即清空。引擎调用和 Core ML 单次推理不能强制中断；取消检查在调用之间执行，独立重排的 250 ms 为软预算。实际输入中的异步转换另受从请求开始计时的首次发布 60 ms 窗口约束：到期采用已完成的有效比较或词典结果，并在推理调用之间停止评分；模型冷启动不阻塞首批候选显示。

模型分数和用户证据的结合见 [候选排序](../Architecture/Candidates.md)。公开准确率或延迟结论应注明模型、数据集、评分口径、构建配置与设备，历史运行结果不能代表当前代码。

## 下一词

原生联想先发布，智能模式可追加有界模型生成：候选最多五项，当前生成长度最多三个 token，使用置信度与句子边界约束。历史词组先通过模型评分验证。模型结果不足时继续保留原生来源，不伪造未评分的历史结果。

模型使用当前正文作为上下文，不负责用户在线学习，也不会修改用户尚未确认的草稿。

## 更换资源

更新模型、分词器与 manifest 必须作为匹配交付包，资源清单同时更新。检查 App 和扩展都携带正确文件，再运行：

```sh
python3 Scripts/validate_model_resources.py
# 也可校验构建产物中的实际资源目录：
python3 Scripts/validate_model_resources.py --resources '<BUNDLE_RESOURCE_DIRECTORY>'
```

[install_v21_resources.py](../../Scripts/install_v21_resources.py) 用于补齐缺失的匹配资源，不是覆盖已有模型的一般升级器。实际替换应遵守脚本校验和资源契约，并使用固定参考数据核对候选评分、联想、输入边界和内存。Release 资源输入见 [ModelResources.Release.xcfilelist](../../Configuration/ModelResources.Release.xcfilelist)。
