# V2.1 Core ML candidate（2026-10-08）

默认使用 VimeML extend5 best / step40000 的 INT8 block32、FP32 compute、CPU_ONLY、iOS18。
架构 tiny_gpt_v2（RMSNorm/SwiGLU），16384 词表、128 token、无 KV cache。
V2 tokenizer 与 V1 不同，资源必须整体安装；`VimeLMManifestV21.json` 绑定模型与 tokenizer。

## 安装与回退

当前匹配 manifest 的 V2.1 compiled model 和 V2 tokenizer 已随客户端仓库提交，普通 clone 和 Xcode Cloud 无需额外安装。首次接入新的模型交付包时，将 VimeML 结果 ZIP 解压到模型工作区，然后在尚未安装对应资源的客户端执行：

```sh
python3 Scripts/install_v21_resources.py /path/to/VimeML/artifacts/deployment/tiny-ja-v2.1-extend5-client-resources-v1/Resources
```

安装脚本先验证 manifest、tokenizer 和 compiled 文件集合/身份，再写入新资源名；已有 V2 不覆盖。
V1 的 `TinyJapaneseINT8.mlmodelc`、`VimeJapaneseTokenizer.model`、`VimeLMManifest.json`
全部保留。可在模型初始化处显式使用 `resourceVersion: .v1` 回退。
V2 校验/加载失败会保留词典候选，不自动混用 V1 tokenizer。
模型升级必须将 tokenizer、compiled model 和 manifest 作为同一组资源交付，并通过 `Scripts/validate_model_resources.py` 校验。

## 质量与验证

INT8 严格 FP32 logits 对齐失败（最大绝对差约1.01），PAD/causal 检查通过。
AJIMEE144/200、原 development122/137，与 FP32 命中数相同；逐条结果有变化。
扩大 development 标签仍为草稿：1481/2000，FP32 为1487/2000。
12 条 greedy 续写8条完全相同；没有改标签、增加后验别名或使用 blind 选模型。
这是独立 V2 候选，最终设备结论和互相关联 PR 见 VimeML 的 mac-20261008 报告。

原生 fixture 绑定 V2 tokenizer，包含6755条分词、4组联合评分和20条 beam。
选定真机测试验证分词、联合评分、取消/回退、PAD/causal、排序、联想和宿主性能。
宿主测量不能替代真实扩展测量；驻留内存不能与 physical footprint 混用。

本次iPhone16 Pro Max真实扩展记录201秒：内核footprint峰值34.72MiB，
私有驻留采样峰值73.78MiB；LM评分p95为53.92ms，下一词p95为38.11ms。
实际加载版本和两个开关已记录，用户确认看到建议且无异常。
末段内存高于中段，UI发布最大等待约1.93秒且原因未定位；保留为候选的已知项。
上述记录来自 v2.1 接入阶段，并非本轮重新测得。模型仍未正式发布；审计开关在当时已关闭。

## 临时真实扩展审计

`VimeExtensionAudit` 仅在真实 `.appex` 中、App Group `v21-audit-enabled.json`
明确设为 `{"enabled":true}` 时启用。Debug 构建和测试默认关闭；正式 Release 构建只保留无操作接口，不能通过遗留 sentinel 开启审计。优化构建的显式开发审计需要增加 `VIME_EXTENSION_AUDIT` 编译条件。
100ms 采样 footprint、resident 和进程生命周期峰值，每2秒导出 JSON，240秒自动停止。
记录版本、模型加载和键盘请求计时，不记录输入文本；计时包含请求取消/失败尝试，采样存在开销。

开发者在实际 App 启动参数中使用 `--v21-extension-audit-on` 开启、
`--v21-extension-audit-off` 关闭。普通启动不修改开关。
测量后必须关闭 sentinel；每个 PID 有独立文件 `v21-extension-audit-<pid>.json`，
从 `group.com.Voltline.Vime` 的 App Group 容器取回；Instruments trace 另用于私有驻留值。
如设备文件服务未显示 App Group 文件，用实际 App 的 `--v21-extension-audit-export`
启动参数从控制台导出这些有界 JSON；可以与 `--v21-extension-audit-off` 同时使用。

## 主工作区发布准备（2026-10-08）

- 已将交付包中的 v2.1 compiled model 和 V2 tokenizer 安装回 Vime 主工作区，安装前逐项匹配当前 manifest；没有从 V1 混用资源。当时模型大文件在 Git 之外交付；2026-10-09 已改为随客户端仓库提交，以保证 Xcode Cloud 的干净 checkout 能完成 Release 资源校验。
- `Scripts/validate_model_resources.py` 可检查源资源目录或实际 App/appex 资源根目录；Release 构建会自动执行，缺失、文件集合变化、校验和不符时停止。
- 资源路径仍为 `Shared/Resources`，源代码整理见 [项目目录](ProjectLayout.md)。
- 对应发布版本固定为 `1.0`，本轮构建号为 `2`。构建号是否可上传需与 App Store Connect 已有记录核对。
- 发布检查结果见 [发布准备](ReleaseReadiness.md)。本轮不重复完整质量、性能和内存基准。
