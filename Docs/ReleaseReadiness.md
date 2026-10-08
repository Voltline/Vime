# 1.0 发布候选检查（2026-10-08）

结论：代码与资源可以准备 1.0 的发布候选，建议先进行短轮 TestFlight 验收；本轮未执行签名、上传或正式发布，不能将未签名归档当成可直接上传的包。
版本号保持 **1.0**，主 App 与键盘扩展构建号均为 **2**。

| 检查 | 结果与证据 |
| --- | --- |
| v2.1 接入 | 默认 `resourceVersion=.v21`；保留 CPU_ONLY、身份/校验和检查及词典回退 |
| 主工作区资源 | 起初缺少被 Git 忽略的 V2 模型和 tokenizer；已从本地 VimeML 交付目录按 manifest 安装完整资源 |
| Release 构建门禁 | 自动校验 V2 manifest、tokenizer、compiled 文件集合及 SHA256；缺失资源的反例会失败 |
| Release 归档 | `xcodebuild archive` 成功，采用 `CODE_SIGNING_ALLOWED=NO`；最低系统 iOS 18 |
| 实际归档内容 | 分别校验 Vime.app 与 VimeKeyboard.appex；两者均为 1.0 (2)，模型版本为 `2.1-extend5-step40000-int8-b32-v1`，所有模型/tokenizer 哈希匹配 |
| 隐私声明 | 两个 bundle 根目录都包含 PrivacyInfo.xcprivacy；UserDefaults 使用 CA92.1/1C8F.1，计时使用 35F9.1；无跟踪及离设备数据收集 |
| 诊断排除 | 正式 Release 二进制不包含 audit sentinel 文件名与启用启动参数；显式开发构建可单独使用 `VIME_EXTENSION_AUDIT` |
| 定向验证 | 3/3 通过：V2 联合评分与固定 INT8 参考一致；取消/整池回退；确认后的联想与插入 |

隐私声明理由对应 Apple 的[必要 API 使用理由](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)。本轮声明覆盖已检查的直接 API 用途，不代表 App Store Connect 的最终验证或审核结果。

本轮未重跑完整回归、准确率、吞吐量及内存基准，也没有新增真机录制。此前 [v2.1 真机报告](LanguageModelV21.md) 的 AJIMEE 144/200、footprint 峰值 34.72 MiB、模型评分 p95 53.92 ms、下一词 p95 38.11 ms 均是既有数据。报告中约 1.93 秒的候选发布最大等待及末段内存增长尚未定位，不能用本轮三项通过结果消除该限制。

正式上架前仍需：

1. 核对 App Store Connect 中 1.0 的状态及已上传构建号；若 2 已占用，只递增构建号，版本继续保持 1.0。
2. 生成并验证签名归档，通过 App Store Connect 的包验证及上传检查。
3. 在 TestFlight 包中短轮确认宿主切换、连续输入和联想，重点观察候选尾延迟及扩展是否被系统终止。

本轮归档：`/tmp/Vime-1.0-2-release-ready.xcarchive`；三项定向结果：`/tmp/Vime-v21-release-check-20261008.xcresult`。这些是本机临时产物。模型大文件仍按原约定独立交付，新 checkout 必须先安装；Release 门禁用于防止漏带模型，未将资源迁移到 Git。
