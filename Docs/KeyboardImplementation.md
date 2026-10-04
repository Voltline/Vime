# 键盘实现调研（2026-10-04）

## 系统材质与候选遮挡

Apple 的 [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) 说明，自定义背景可能覆盖系统材质或滚动边缘效果。并不是任意 UIView 自动获得玻璃：主 App 试打使用 `.keyboard` 样式的 [UIInputView](https://developer.apple.com/documentation/uikit/uiinputview)，扩展使用 UIInputViewController 自带的 inputView。根内容视图保持透明，删除自绘外边框、轮廓路径、描边及背景图层，系统负责外围材质。触摸面与候选 padding 使用 0.01 alpha 的背景，确保扩展自身的可触摸像素不完全透明，见下方死区修复记录。按键本身仍绘制白色/灰色表面。

iOS 26 新增 UIScrollView 的 [topEdgeEffect](https://developer.apple.com/documentation/uikit/uiscrollview/topedgeeffect)。候选栏是短小的横向滚动区域，自动边缘效果会覆盖文字。候选条及展开面板的四个边缘都设置 [isHidden](https://developer.apple.com/documentation/uikit/uiscrolledgeeffect/ishidden)，并关闭自动 contentInset 调整。测试断言这些属性，实际宿主界面另外检查候选是否完整可读。

## 行内输入与单行候选

通过 [UITextDocumentProxy.setMarkedText(_:selectedRange:)](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/setmarkedtext(_:selectedrange:)) 在宿主输入框即时显示假名 preedit，未完成的辅音保留为罗马字，标记范围内光标使用 UTF-16 长度。空格转换时预览选中候选，确认时清除自己的标记范围并插入确认文本，调用 [unmarkText()](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/unmarktext()) 结束组合。不会通过连续 deleteBackward 重建宿主文字。外部光标或文档变化时丢弃旧范围的所有权，避免误改新的输入位置；主 App 试打也使用同一适配器连接 UITextView。

移除键盘内部的假名/罗马字双标签，只保留一行候选。输入期间隐藏设置及假名按钮，候选从左边开始填满可用空间；结束组合后恢复工具栏。440 pt 宽度的顶部由 78 pt 缩短为 56 pt，键盘内容高度由 372 pt 降至 350 pt（包含底部地球键区），按键大小和行间距保持原值。日语长音键 ー 移到第二行 L 右侧，该行十键等距排布；隐藏长音键或切换英文后恢复九键缩进，底部恢复六键与较宽空格。

## 日语引擎

采用 [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) 的完整默认词典模块，固定修订 `d59a28e4c7ca049aef04f29a91eae9677a7753f2`。SwiftPM 的 Package.resolved 同时固定依赖。引擎在 iOS 原生运行，具备词典分词和连接成本评分，避免原先只按词长与单词成本拼接的错误。

使用 ComposingText 持续管理罗马音输入，deleteBackwardFromCursorPosition(count: 1) 删除显示字符，包括小假名；不删除一个原始字母后重新解析。独立 nn 生成一个 ん；当后续元音或 y 到来时，把已消耗的末尾 nn 改为 n + compositionSeparator + n，保留第二个 n 组成 na/nya 的能力。分隔符不是用户字符，raw 与候选消费计数仍由 ComposingText 管理。kanna → かんな、konnichiha → こんにちは，原有 so + nn + na → そんな 不变。末尾单个 n 在平常输入和预测期间不固化，仅在空格/确认边界变成 ん。完全匹配保留引擎排序，预测候选后置，关闭日语罗马音中的英文预测和拼写纠错。片假名模式优先提供片假名。未加载 Zenzai 神经模型；关闭永久学习，不传输输入。

原先每次 type 都在主线程同步 requestCandidates，候选算完才能返回触摸事件；returnKeyType 的相同值回调也重建整条候选。现将引擎与缓存限定在后台串行队列，主线程仅管理 ComposingText、标记文字和视图。取消未执行的旧请求，结果携带输入版本，确认/重置后的旧结果被丢弃。候选等待时保留上一轮列表，不插入临时假名列表；包括尚未完成的辅音在内，每键都发起预测（如 nanim → なにm，同时预测 何も），当前版本的结果就绪后立即发布，不等待完整音节。空格可以显式解析末尾单个 n。旧列表暂不接受选词，避免丢失后续输入；空格意图在对应结果到达时解析。候选按钮被复用；只有文字或字体变化才重新测量宽度。单行候选使用直接 frame 排布，发布时完成实际按钮布局，避免动态 UIStackView 约束求解。语言图标仅在模式/外观变化时绘制，不因每键输入重绘。

当前定向回归验证双 n 的实际读音、逐键/批量输入一致性、候选读音元数据、假名退格即时预测、宿主 marked text，以及第二行长音键的位置和新键缝归属；不重复扫描整个键盘。性能测量口径与结果见下方更新记录。

## 反馈与设置

Apple 的 [Open Access 配置](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard) 定义扩展授权方式。Info.plist 声明 RequestsOpenAccess，运行时通过 hasFullAccess 控制声音/振动；转换本身无需此授权。

按键声使用 System Sound Services 的系统按键点击音（1104），静音会抑制它；振动使用 UIImpactFeedbackGenerator，0 关闭、1...5 逐级增加，最高 heavy/intensity 1.0。硬件效果不能在模拟器衡量。声音默认开、振动默认中。设置同时提供数字九宫格/全键盘、长音键和普通预览。主 App 试打与扩展的偏好分别保存在各自的 UserDefaults 容器。

上滑符号通过键盘统一触摸跟踪实现：超过 18 pt 的上滑进入符号预览，滑回可撤销选择，松手才提交，系统取消不提交。没有长按替代符号手势；退格仍支持长按连续删除。

## 按键触摸容错

参考 Apple 的 [UIView.hitTest(_:with:)](https://developer.apple.com/documentation/uikit/uiview/hittest(_:with:)) 和微软研究的 [Usability Guided Key-Target Resizing for Soft Keyboards](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/paper-final.pdf)。研究讨论了过度扩大、按语言预测改写键位归属可能妨碍明确输入的问题。本实现采用固定几何分区，不宣称复现论文的概率模型，也不按候选词改变键位。

按键外观和布局保持原值；触摸区域覆盖键间空隙，并在相邻可见边缘的中线处分界。每行左右空隙归属于该行最外侧键；行间空隙按纵向中线分配。按键面覆盖整个自有视图，首行以上和末行以下空白也归属邻近键；候选条、设置面板和地球键等实际控件优先保留自身交互。各区域不重叠，直接点在可见键内仍属于该键，大尺寸退格/回车不会抢占旁边字母。

旧代码虽扩展了 point(inside:with:)，但松手依赖 touchUpInside；从扩展区边缘按下后轻微漂移，会触发 touchUpOutside 而不输入。现在 KeyboardTouchSurface 接收整个按键面的原生 touchesBegan/Moved/Ended/Cancelled，统一按固定几何分区选择并记录每根手指的按键所有权。可见键本体优先，空隙使用既有的中线分区，不按视图层级处理重叠，也不按词典猜测改变区域。

小幅漂移继续保留原键；移动达到半个键的较短边（至少 18 pt × 缩放），且进入邻键可见本体向内 5 pt × 缩放的区域，才允许切换。仅松手时的最终坐标不触发换键，仍会更新上滑选择。上滑一旦触发，本次手势锁定原键；可以滑回撤销符号，但不能借横移改选邻键。退格在按下时执行并保留重复删除，不能通过邻键横移触发退格。松手直接提交当前归属键，不再依赖 UIButton 的 touchUpInside。离开整个按键面超过 12 pt × 缩放且没有上滑锁定时取消；系统取消、切换布局、打开面板与视图离开窗口均停止预览和重复计时器。数字布局切换后的首次 hitTest 会先完成新布局，避免触碰旧按键对象。

验证：修改前 14 项测试通过；触摸改造后 17 项通过；补充边缘、数字布局及退格取消后，4 项触摸定向测试全部通过。扫描 440/375 pt 竖屏与 680 pt 紧凑布局的可见键、水平/垂直空隙、左右边缘和工具栏边界，所有按键区采样点只有一个归属。200 次两指重叠按键全部按顺序提交，没有重复或遗漏，触摸层耗时 11.34 ms（约 0.057 ms/键，不含词典与宿主）。模拟器原生拖动确认小幅漂移、明确拖入邻键、上滑松手三个路径，输入结果为 qw1。这是早期几何验证，不能量化人手误触率；后续扩展真实键缝验收见下方修复记录。


## 2026-10-04 系统扩展键缝死区修复

最吻合实机“每两个字母间都能找到死区”的原因是触摸面没有绘制背景，而不是几何分区没有覆盖。KeyboardView 的背景为 clear，KeyboardTouchSurface 原先没有背景；键帽之间的扩展自身像素完全透明。系统的键盘材质来自扩展外层，不能当作扩展自身的像素覆盖。

[Apple 开发者论坛的原始报告](https://developer.apple.com/forums/thread/702798)描述了同一现象：普通 view alpha 为 1，但 custom keyboard 中透明处不接收触摸；极低透明度的背景恢复事件。[LIME 的调查与修复记录](https://github.com/lime-ime/limeime/blob/master/docs/IOS_CANDI_TOUCH.md)也记录了扩大 frame、pointInside 和 hitTest 均无效，直到补上非零背景。它是开发者观察到的扩展行为，并非 Apple 在 UIView API 中承诺的通用规则。当前 Vime 已经有连续的 keyboard-level surface；继续扩大按钮不能修复触摸进入该 surface 之前的丢失。

KeyboardTouchSurface 现在绘制 UIColor(white: 0.5, alpha: 0.01)，UIView.alpha 仍为 1，不会淡化按键。候选按钮、候选/面板 scroll view 和输入中的展开按钮也获得相同的低透明度背景，避免透明 padding 发生同类问题。可见键的大小、按键间距和中线分区不变。根视图仍保持 clear，系统材质仍由 UIKit 提供。

触摸路径为：系统扩展像素覆盖 → KeyboardView.hitTest（保留真实候选/设置/地球控件）→ KeyboardTouchSurface.hitTest → resolvedKey（可见键本体优先，空白按行/键间中线唯一分配）→ 每根手指独立的 Press。第二、第三行缩进归各行最外侧键。小幅移动及松手漂移保留归属，明确移动进入邻键核心才换键；上滑锁定最初归属键。松手直接提交，原生 surface 路径不依赖 UIButton.touchUpInside/Outside。

同键多指原先共用 UIButton 上滑/反馈状态，松开一根会清除另一根的高亮和预览；现在选择在 Press 内独立维护，仍持有该键时保留反馈。退格两次按下原先覆盖 delayTimer 引用，导致松手后旧计时器仍重新启动删除；回归复现两次删除变成七次。现在每个键只保留一条重复计时器流，最后一根手指松开或系统取消时才停止；按下期间宿主回调取消也不能重启计时器。

验证（iOS 27.0 模拟器，Debug）：23 项触摸/文本集成/输入性能测试通过。375、440 pt 竖屏及 680 pt 紧凑布局的字母面采用 2 pt 网格，共 50,240 点，unresolved=0、nonunique=0、misrouted=0、wrongBodyOwner=0；同时验证分界线本身及 nextUp/nextDown、九宫格/全数字/符号布局。绘制扩展自己的图层（不包含外部 UIInputView 材质）后检查 177 个水平/垂直键缝位置，修复后全部存在非零 alpha。移除背景、保持完全相同 resolver 的对照点仍能 hitTest 成功，但像素 alpha=0；修复后同点 alpha=3/255。该对照揭示了旧几何测试为什么不能验证系统真实触摸分发。结果见 Artifacts/keyboard-touch-audit.json。测试不能直接给出真机漏字率或证明人手误触率不变。

临时诊断仅在 DEBUG 构建提供：键盘设置中的“触摸诊断（开发版）”默认关闭；开启后搜索控制台 VIME_TOUCH。日志记录 KeyboardView.hitTest、container.hitTest、KeyboardKey.pointInside、surface/KeyboardKey.touchDown、surface.touchUp/resolvedRelease，以及旧 UIButton 的 touchUpInside/touchUpOutside/touchCancel；记录坐标、类名和取消原因，不记录字符、标签或宿主文本。若键帽有日志而空隙没有任何 hitTest 日志，应继续查扩展前置分发/像素覆盖；若有 touchDown 后取消，应查 ownership/lifecycle。中央 surface 正常输入不经过 UIButton.pointInside/upInside/upOutside，不能把这些日志缺失误判成漏键。Release 构建排除日志及诊断开关。

实机验收：修复版已更新到当前连接的 iPhone 16 Pro Max，核对正在运行的 VimeKeyboard 进程来自新安装包。用户在其他 App 中按要求切换重载键盘并试键缝后确认：“键缝都响应，死区消失了”。真机严重死区得到行为验证；快速输入的漏字率尚未量化统计。真机 Debug 与模拟器 Release 构建均通过。


## 2026-10-04 双 n、布局与候选性能更新

退格仍以已显示的假名为单位：nanimo → なにも，退格后为 なに；未完成的 nanim → なにm，退格后同样为 なに。两条路径均立即请求新预测。完成的 mo 不退回 m。

旧 warm 数据的 p95（4.76 / 13.05 ms）混合了冷启动、未附着窗口及不同布局计时范围，不能证明优化有效或退化。新基准在真实 UIWindow 中，先跑一轮预热，再跑三轮完全相同的 nihongo/nani/nanim/nanimo/arigat，共 84 次候选发布。candidatePublication 从 refresh 入口量到返回，包含按钮文字设置、宽度测量、实际候选帧与 label 布局，修改前后使用相同外层计时。candidateUIUpdate 是辅助指标，其范围本次扩展到整个 refresh，不用于跨版本主比较。

统一基准结果（Debug、每侧 84 次发布）：模拟器 candidatePublication p95 5.143 → 2.695 ms；iPhone 16 Pro Max 3.328 → 1.331 ms（约降低 60%）。实机 typeToMarked p95 0.273 → 0.226 ms。原始数据为 Artifacts/candidate-profile-unified-{simulator,device}-{before,after}.json；基准包含实际文字与布局处理，没有把布局移出计时窗口。主要删除了每轮候选更新的 UIStackView 动态约束处理、重复按钮分配，以及每次刷新重绘语言图标的开销。

定向回归：模拟器 15 项通过，另仅重跑扩展后的 1 项快速输入测试；实机 4 项通过。快速输入使用相同 native touch 状态转移，先连续突发 35 键，再以 20 ms 间隔输入同样 35 键，让候选发布与后续按键交错；raw、即时 marked text、完整句子和最新候选均正确。实机记录 70 次 typeToMarked，交错期间共 29 次候选发布，快速输入的 typeToMarked p95 为 0.579 ms。第二行 L/ー 新键缝和右边缘的 resolver 定向检查通过，未重复全区域网格。

限制：词典质量与上下文预测仍有限；未启用永久学习、纠错或神经模型。正在执行的过期词典请求不能中断，但其结果会被丢弃；候选计算期间 preedit 即时更新，旧候选只显示、不可选择。实机 XCTest 共用视图/会话测试不能替代所有第三方 App 的扩展触摸体验，也不等于已量化人手漏字率。

最终 Release 实机包构建通过，已正常更新到连接的 iPhone 16 Pro Max（未卸载或清除数据）。核对运行中的 VimeKeyboard 来自本轮安装包后，用户在其他 App 中切换重载并试第二行长音键、kanna/konnichiha 与快速连打，确认：“都正常，输入顺畅”。本轮人工扩展验收和实机 XCTest 均通过，未统计人手漏字率。汇总结果见 Artifacts/keyboard-remaining-fixes-audit.json。
