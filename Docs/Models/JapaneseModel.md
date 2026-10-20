# 日语语言模型

## 资源契约

运行时默认资源为 v4.2，v2.1 随包保留为回退。模型版本以各自 manifest 为准。

| 资源 / 属性 | v4.2（默认） | v2.1（回退） |
| --- | --- | --- |
| 编译模型 | `TinyJapaneseV42INT8.mlmodelc` | `TinyJapaneseV21INT8.mlmodelc` |
| 分词器 | `VimeJapaneseTokenizerV4.model` | `VimeJapaneseTokenizerV2.model` |
| Manifest | `VimeLMManifestV42.json` / `vime_ios_lm_v4` | `VimeLMManifestV21.json` / `vime_ios_lm_v2` |
| 词表 / 上下文 | 8,192 / 128 tokens | 16,384 / 128 tokens |
| 保留 token | 4–6 为转换标记，不作为输入或输出 | 无 |
| 计算设备 / 量化 | `CPU_ONLY` / INT8 block 32 | 同左 |
| 特殊 token | pad 0、unk 1、bos 2、eos 3 | 同左 |

这些资源已纳入版本控制，App 与键盘扩展都携带两套。worker 按 `VimeLanguageModel.Variant.runtimePreference`（v4.2 → v2.1）依次加载：v4.2 缺失或未通过 manifest / Core ML 检查时记录日志并尝试 v2.1；两套都不可用时，输入继续使用词典候选。进程内同时只持有一个模型。`VimeLanguageModel()` 的默认变体与运行时首选一致；v2.1 参考数据测试（`VimeLanguageModelTests`、`VimeLMFixturesV21.json`）显式指定 `.v21`，v4.2 参考数据测试为 `VimeLanguageModelV42Tests` / `VimeLMFixturesV42.json`。

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

### 资源安装与基准

v4.2 资源用 [install_v42_resources.py](../../Scripts/install_v42_resources.py) 从 VimeML 的 `tiny-ja-v4.2-epoch20-client-resources-v1` 安装；`validate_model_resources.py` 要求 v4.2 与 v2.1 两套完整且哈希一致，任一缺失都会使 Release preflight 失败。`Scripts/benchmark_lm_variants.py` 在独立测试进程中交替运行两种变体的基准测试（`TEST_RUNNER_VIME_LM_VARIANT=v21|v42`，未设置时测量运行时默认模型）。模拟器结果不能代表真机的 60 ms 首发窗口是否足够，切换默认模型后仍需按真机设备测量延迟与内存。

[install_v21_resources.py](../../Scripts/install_v21_resources.py) 用于补齐缺失的匹配资源，不是覆盖已有模型的一般升级器。实际替换应遵守脚本校验和资源契约，并使用固定参考数据核对候选评分、联想、输入边界和内存。Release 资源输入见 [ModelResources.Release.xcfilelist](../../Configuration/ModelResources.Release.xcfilelist)。
