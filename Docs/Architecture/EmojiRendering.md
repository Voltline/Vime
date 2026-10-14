# 表情显示与滚动

`KeyboardSymbolPanel` 使用一个 UICollectionView，横向连续排列 Emoji、颜文字和符号。分类内不分页，分类与模式标签随内容偏移更新。Emoji 点击后插入目录中的完整 Unicode 序列，显示缓存不改变肤色、ZWJ 或旗帜文字。

## 入屏准备

正常路径由串行后台 worker 提前解码、合成未压缩的 premultiplied BGRA 小位图。CGContext 的输出已有完整像素，不再额外执行 UIImage 图片准备。后台结果先写入加锁的缓存，再向主线程发送 UI 回调；主线程忙于触摸或布局时，也可以立即读到已经完成的图像。

UIKit 的预取不保证每个图像都在入屏前准备好。跳分类、冷缓存、快甩和反向滑动都可能超出预测范围。因此，`willDisplay` 查询缓存后，在未命中时直接准备该表情的位图，不排在预取队列后面，也不展示空白等待回填。单元格配置阶段的推测性请求仍异步执行。

这项策略增加了未命中时的主线程工作，需要同时测量入屏图像是否就绪和整帧滚动准备耗时。不能只以空白面积为零宣称流畅。`emojiVisibleDecode` 单独记录入屏补齐的耗时，`emojiDecode` 包含前后台实际解码。计时默认关闭。

CoreText 只做 shaping。字体和字体表保持只读，每次调用独立创建文字布局对象和 CGContext，因此不需要让入屏请求等待后台串行队列。实现继续使用系统字体的 sbix/EMJC 按需解码；格式兼容性与许可见 [位图解码说明](../ThirdParty/EmojiBitmapDecoding.md)。

## 生命周期与内存

缓存最多保留 8 MiB 像素、240 张图像；预取范围受到保护，避免被其他单元格准备挤出。后台最多有 192 个 pending job，其中 speculative job 不超过 96，等待主线程交付的结果不超过 24。没有提前解码整个目录。

UIKit 可能再次展示已经离屏的 prepared cell，而不重新配置它。离屏时取消未完成订阅，已准备的图像保留到复用或面板隐藏；隐藏时释放所有登记单元格的图像。收起、外观变化及键盘内存压力清空缓存。缓存插入与 generation 校验使用同一把锁，旧任务不能重新填充已清空缓存。复用还会校验单元格身份，防止写入上一表情。

8 MiB 是缓存像素上限，不是表情页或键盘进程总占用。单元格持有的图像、解码临时数据、等待交付的结果、CoreAnimation 和语言模型必须一起测量。模拟器峰值不能保证实机不会 OOM。

## 布局

竖屏固定五行；440 pt 宽时，Emoji 约十列，横向间距约 43 pt。首末单元格距离表情区边缘各 2 pt，行间距随可用高度分布，减少网格上下留白。分类标签间距 56 pt。横屏按可用高度确定行数，继续遵循键盘边界，不添加纵向滚动。

## 验证

`KeyboardFeatureTests` 包含不等待主队列回填的冷缓存分类跳转、饱和请求队列、后台已完成图像的即时读取，以及完整目录、颜色、组合字形和复用检查。

`VimeLanguageModelMemoryTests/testEmojiScrollPreparationPerformance` 通过 `TEST_RUNNER_VIME_EMOJI_SCROLL_AUDIT=1` 启用；可设置 `TEST_RUNNER_VIME_EMOJI_SCROLL_STEP`、`TEST_RUNNER_VIME_EMOJI_SCROLL_HZ` 和 `TEST_RUNNER_VIME_EMOJI_SCROLL_LANDSCAPE=1`。它记录图像未准备面积、滚动准备耗时和实际 display-link 间隔。请求 120 Hz 不代表模拟器实际运行在 120 Hz，也不能代表最终呈现像素。

完整目录十轮内存测试通过 `TEST_RUNNER_VIME_EMOJI_MEMORY_AUDIT=1` 启用，设置 `TEST_RUNNER_VIME_EMOJI_MEMORY_NEURAL=1` 可先预热语言模型。该测试等待图像和停留，因此只用于内存验证。它记录模型/字体 shaping 后的基线、全进程峰值和十轮收起占用；检查末四轮占用范围小于 2 MiB，同时限制相对初始基线的峰值增长。60 MiB 增量是包含模型预热的模拟器回归预算，不是设备 Jetsam 阈值。真实扩展手势由 `KeyboardExtensionLifecycleTests/testSymbolCategorySwipesPreserveScrollingAndSelection` 覆盖。实机应检查首次浏览、快速反向、跳分类、横屏和多次收起重开，并观察是否持续增长或重启。

## 调研依据

- [Apple WWDC21：Make blazing fast lists and collection views](https://developer.apple.com/videos/play/wwdc2021/10252/)：预取只争取更多准备时间；prepared cell 可被再次显示；解码后的图像占用实际像素内存。
- [CoreText 多线程说明](https://developer.apple.com/library/archive/documentation/StringsTextFonts/Conceptual/CoreText_Programming/Overview/Overview.html)：只读字体允许跨线程使用，布局参数不能被并发修改。
- [Apple WWDC18：iOS Memory Deep Dive](https://developer.apple.com/videos/play/wwdc2018/416/)：检查 footprint、dirty/compressed 分量与扩展内存边界。
- [Mohamed Salah 的 Emoji 键盘实测分享](https://medium.com/@mohasalah/from-2014-to-now-fixing-coretext-emoji-glyphs-memory-retention-on-ios-1c6a227d592d)：原生彩色字形缓存可能保留大量内存；取消缓存又增加快滚 CPU 压力。文章中的具体阈值是作者环境观察，不能当作所有设备的系统保证。本文实现没有采用其全局 NSCache swizzling。
- [Instagram IGListKit 的 UICollectionView 经验](https://github.com/Instagram/IGListKit/blob/main/Guides/Working%20with%20UICollectionView.md)：其历史实现曾因预取变慢而建议关闭；不能直接套用于当前 UIKit。Vime 保留预取，并测试实际成本。

没有资料能证明微信输入法使用哪一种内部渲染架构。
