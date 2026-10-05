# 键盘实现与验证（更新至 2026-10-05）

## 系统材质与候选遮挡

Apple 的 [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) 说明，自定义背景可能覆盖系统材质或滚动边缘效果。并不是任意 UIView 自动获得玻璃：主 App 试打使用 `.keyboard` 样式的 [UIInputView](https://developer.apple.com/documentation/uikit/uiinputview)，扩展使用 UIInputViewController 自带的 inputView。系统皮肤的根内容视图保持透明，由系统提供外围材质；樱花、海蓝、深夜皮肤在相同布局上加入配色背景。触摸面与候选 padding 使用 0.01 alpha 的背景，确保扩展自身的可触摸像素不完全透明，见下方死区修复记录。

iOS 26 新增 UIScrollView 的 [topEdgeEffect](https://developer.apple.com/documentation/uikit/uiscrollview/topedgeeffect)。候选栏是短小的横向滚动区域，自动边缘效果会覆盖文字。候选条、展开面板、Emoji 网格及分类滚动条的四个边缘都设置 [isHidden](https://developer.apple.com/documentation/uikit/uiscrolledgeeffect/ishidden)，并关闭自动 contentInset 调整。表情页此前漏用了这一策略，导致底部一行出现材质遮罩；补齐后用户确认无遮挡。

## 行内输入与单行候选

通过 [UITextDocumentProxy.setMarkedText(_:selectedRange:)](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/setmarkedtext(_:selectedrange:)) 在宿主输入框即时显示假名 preedit，未完成的辅音保留为罗马字，标记范围内光标使用 UTF-16 长度。空格转换时预览选中候选，确认时清除自己的标记范围并插入确认文本，调用 [unmarkText()](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/unmarktext()) 结束组合。不会通过连续 deleteBackward 重建宿主文字。外部光标或文档变化时丢弃旧范围的所有权，避免误改新的输入位置；主 App 试打也使用同一适配器连接 UITextView。

移除键盘内部的假名/罗马字双标签，只保留一行候选。输入期间隐藏设置及假名按钮，候选从左边开始填满可用空间；结束组合后恢复工具栏。440 pt 宽度的顶部由 78 pt 缩短为 56 pt，键盘内容高度由 372 pt 降至 350 pt（包含底部地球键区），按键大小和行间距保持原值。日语长音键 ー 移到第二行 L 右侧，该行十键等距排布；隐藏长音键或切换英文后恢复九键缩进，底部恢复六键与较宽空格。

## 日语引擎

采用 [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) 的完整默认词典模块，固定修订 `d59a28e4c7ca049aef04f29a91eae9677a7753f2`。SwiftPM 的 Package.resolved 同时固定依赖。引擎在 iOS 原生运行，具备词典分词和连接成本评分，避免原先只按词长与单词成本拼接的错误。

使用 ComposingText 持续管理罗马音输入，deleteBackwardFromCursorPosition(count: 1) 删除显示字符，包括小假名；不删除一个原始字母后重新解析。独立 nn 生成一个 ん；字面输入保持上游解析，例如 kanna → かんあ、rennai → れんあい。末尾单个 n 在平常输入和预测期间不固化，仍能继续组成 na/nya，仅在空格/确认边界变成 ん。其他 n 边界只作为后台候选查询，提供 かんな、こんにちは、恋愛 等选项，不重写输入。原查询完全匹配保留引擎排序，预测候选后置；纯片假名候选通常保留在第四个位置，片假名模式优先提供它。通用误输建议由下方有限纠错搜索实现。未加载 Zenzai 或实验语言模型；关闭永久学习、经典 typo 开关及英文预测，不传输输入。

原先每次 type 都在主线程同步 requestCandidates，候选算完才能返回触摸事件；returnKeyType 的相同值回调也重建整条候选。现将引擎与缓存限定在后台串行队列，主线程仅管理 ComposingText、标记文字和视图。取消未执行的旧请求，结果携带输入版本，确认/重置后的旧结果被丢弃。候选等待时保留上一轮列表，不插入临时假名列表；包括尚未完成的辅音在内，每键都发起预测（如 nanim → なにm，同时预测 何も），当前版本的结果就绪后立即发布，不等待完整音节。空格可以显式解析末尾单个 n。旧列表暂不接受选词，避免丢失后续输入；空格意图在对应结果到达时解析。候选按钮被复用；只有文字或字体变化才重新测量宽度。单行候选使用直接 frame 排布，发布时完成实际按钮布局，避免动态 UIStackView 约束求解。语言图标仅在模式/外观变化时绘制，不因每键输入重绘。

当前定向回归验证双 n 的实际读音、逐键/批量输入一致性、候选读音元数据、假名退格即时预测、宿主 marked text，以及第二行长音键的位置和新键缝归属；不重复扫描整个键盘。性能测量口径与结果见下方更新记录。

## 反馈与设置

Apple 的 [Open Access 配置](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard) 定义扩展授权方式。Info.plist 声明 RequestsOpenAccess，运行时通过 hasFullAccess 控制声音/振动；转换本身无需此授权。

按键声使用 Apple 官方的 UIDevice.playInputClick()，由扩展和试打区共用的 KeyboardInputView 在真正的 input view 根视图实现 UIInputViewAudioFeedback；遵循系统按键声音与静音设置，不使用固定 SystemSoundID。振动使用 UIImpactFeedbackGenerator，0 关闭、1...5 逐级增加，最高 heavy/intensity 1.0。硬件效果不能在模拟器衡量。声音默认开、振动默认中。设置同时提供数字九宫格/全键盘、长音键和普通预览。主 App 试打与扩展的偏好分别保存在各自的 UserDefaults 容器。

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

此节保留当时的验证记录。10 月 4 日的双 n 输入层重写已由下方 10 月 5 日的字面输入与候选分离方案替代。

退格仍以已显示的假名为单位：nanimo → なにも，退格后为 なに；未完成的 nanim → なにm，退格后同样为 なに。两条路径均立即请求新预测。完成的 mo 不退回 m。

旧 warm 数据的 p95（4.76 / 13.05 ms）混合了冷启动、未附着窗口及不同布局计时范围，不能证明优化有效或退化。新基准在真实 UIWindow 中，先跑一轮预热，再跑三轮完全相同的 nihongo/nani/nanim/nanimo/arigat，共 84 次候选发布。candidatePublication 从 refresh 入口量到返回，包含按钮文字设置、宽度测量、实际候选帧与 label 布局，修改前后使用相同外层计时。candidateUIUpdate 是辅助指标，其范围本次扩展到整个 refresh，不用于跨版本主比较。

统一基准结果（Debug、每侧 84 次发布）：模拟器 candidatePublication p95 5.143 → 2.695 ms；iPhone 16 Pro Max 3.328 → 1.331 ms（约降低 60%）。实机 typeToMarked p95 0.273 → 0.226 ms。原始数据为 Artifacts/candidate-profile-unified-{simulator,device}-{before,after}.json；基准包含实际文字与布局处理，没有把布局移出计时窗口。主要删除了每轮候选更新的 UIStackView 动态约束处理、重复按钮分配，以及每次刷新重绘语言图标的开销。

定向回归：模拟器 15 项通过，另仅重跑扩展后的 1 项快速输入测试；实机 4 项通过。快速输入使用相同 native touch 状态转移，先连续突发 35 键，再以 20 ms 间隔输入同样 35 键，让候选发布与后续按键交错；raw、即时 marked text、完整句子和最新候选均正确。实机记录 70 次 typeToMarked，交错期间共 29 次候选发布，快速输入的 typeToMarked p95 为 0.579 ms。第二行 L/ー 新键缝和右边缘的 resolver 定向检查通过，未重复全区域网格。

限制：词典质量与上下文预测仍有限；未启用永久学习、纠错或神经模型。正在执行的过期词典请求不能中断，但其结果会被丢弃；候选计算期间 preedit 即时更新，旧候选只显示、不可选择。实机 XCTest 共用视图/会话测试不能替代所有第三方 App 的扩展触摸体验，也不等于已量化人手漏字率。

最终 Release 实机包构建通过，已正常更新到连接的 iPhone 16 Pro Max（未卸载或清除数据）。核对运行中的 VimeKeyboard 来自本轮安装包后，用户在其他 App 中切换重载并试第二行长音键、kanna/konnichiha 与快速连打，确认：“都正常，输入顺畅”。本轮人工扩展验收和实机 XCTest 均通过，未统计人手漏字率。汇总结果见 Artifacts/keyboard-remaining-fixes-audit.json。

## 2026-10-05 n 读音：字面输入与候选分离

此前的双 n 补丁在输入层重用第二个 n，导致 rennai 被改成 れんない，恋愛（レンアイ）无法生成。renai 本身仍解析为 れない，但也缺少用户需要的 恋愛 选项。现在移除输入层重写：konna → こんあ，rennai → れんあい，renai → れない。

仅在后台候选查询中探索 n + 元音/y 的其他边界，最多四个不同读音。原查询和备选读音在同一个 converter 的不同会话中处理，共享词典缓存。备选读音只取完整单词匹配，附带少量评分惩罚；原查询保持引擎排序，不按原始 lattice 分数重排完整句子。最多加入三个备选，避免挤掉部分转换候选。

konna 可优先选择 こんな，konichiha/konnichiha 可选择 こんにちは，renai/rennai 可选择 恋愛。字面草稿和假名选项仍保留，未选词时回车确认字面草稿。备选仅支持完整消费，按原查询的 input.count 消费，不把额外分隔符或 n 写入 live composition。

优先修复版已单独构建为 Release 并安装到 iPhone 16 Pro Max，用户在其他 App 中重载系统键盘后确认 renai/rennai 与 konna 的行为「符合预期」。n 的修复及定向回归完成后才开始处理其他新增功能。

## 2026-10-05 光标、面板和皮肤

继续使用原有连续 KeyboardTouchSurface 和不重叠的几何分区，不扩大键帽或相邻 hitbox。Press 额外保留最初触点。单指横移至少 60 个缩放点且明显大于纵向位移时进入光标模式；已经锁定的上滑 alternate 不转为横滑。进入模式后确认当前草稿、暂时隐藏键帽，横移每 8 个缩放点移动一个组合字符，松手或系统取消后恢复键帽。

空格稳定按住 350 ms 后进入二维光标模式；按住前明显移动、多指按下或取消会撤销计时器，普通空格保持原行为。纵向每 24 个缩放点移动一行，并保留目标横坐标。KeyboardTextNavigation 为 UITextView 使用 caretRect/closestPosition 读取实际显示行。系统扩展最初只按可见上下文的换行符计算 UTF-16 偏移，导致没有回车的自动折行段落纵移为零；后续修复使用 KeyboardProxyCursorLayout 估计折行，见下节。每次新手势及横向调整重置目标横坐标。

原生退格短按改为松手删除，长按 420 ms 后开始重复；该意图判断不是输入 debounce，字母即时反馈及松手提交不变。退格上移 30 个缩放点时接管触摸并停止重复计时器，松手才删除本行光标前内容，取消不删除；因此不会先误删一个字符，也不会在行首误删前一行的换行符。系统扩展逐块读取上下文并调用 deleteBackward，最多 64 块，遇到换行符或无上下文即停止。两根手指仍共用一条可停止的退格重复计时器。

展开候选时隐藏原候选 scroll/divider，只显示面板和返回箭头；收起后恢复单行候选。纯片假名候选在最终去重后预留通常第四位，避免被 15 个候选上限截断，首选词保持原有排序。

Emoji 使用 [Unicode 18.0 的 emoji-test.txt](https://www.unicode.org/Public/18.0.0/emoji/emoji-test.txt) 生成的 3,972 个 fully-qualified/component 序列，覆盖肤色变体、组合及旗帜，许可附在 ThirdPartyNotices。脚本只在开发时运行，资源随 App 和扩展捆绑。颜文字为八类共 160 个。KeyboardSymbolPanel 用 UICollectionView 复用屏幕内单元，不一次创建几千个 UIButton；分类可横向滚动，内容纵向滚动，顶部提供 Emoji/颜文字/符号切换和明确的返回按钮。后续界面修复移除了外层标题和箭头，保留面板自己的返回按钮。

KeyboardTheme 提供系统、樱花、海蓝、深夜四种配色，设置后立即更新现有按键、候选与符号面板，并保存在各自 UserDefaults。系统/樱花/海蓝跟随明暗，深夜固定深色；不改变布局和触摸分区。当前未提供自定义图片皮肤、Emoji 搜索或最近使用列表；完整目录经后台 CoreText 整个序列塑形检测，只有能形成完整 AppleColorEmoji 图形簇的项进入网格（混合肤色组合允许多个同原点的叠加字形）；未知或拆分的 ZWJ 序列被排除，按分类缓存结果，revision 防止旧分类覆盖新分类。

本轮先跑 18 项模拟器和 10 项实机定向回归，均通过。实机测量发现 n 的备选查询也执行了无法选中的预测分支，随后将备选限定 N_best=3、关闭备选预测；原查询 autoMix 逐键预测保持原值。只重跑相关的 9 项模拟器、5 项实机测试，仍全部通过。相同预热基准的最终 84 次实机发布 p95 为 1.472 ms，typeToMarked p95 为 0.278 ms，后台 candidateCompute p95 为 18.721 ms。额外读音查询有计算成本，但仍在后台串行队列，不阻塞输入；不能把短词预热结果当作长句的延迟保证。实机 70 键突发/交错输入的每键草稿和完整句子正确。

最终 Release 构建、安装及 App/扩展 Emoji 资源核对通过。用户重载扩展后，实际试光标、长按空格、删行、表情返回和换肤，确认「都正常」。共用视图的自动测试与用户真实扩展验收分开记录；未统计人手漏字率。汇总见 Artifacts/keyboard-2026-10-05-audit.json，测试图片仅在 /private/tmp 的本地结果中保留，未加入 Git。

## 2026-10-05 自动折行与界面细节修复

用户补充确认纵向移动失效发生在没有回车的自动折行文字中。根因是旧 proxy 导航把整个段落视为一行，纵向偏移始终为零，手势本身已经进入二维模式。KeyboardProxyCursorLayout 复用一个 UITextView/TextKit 排版容器，以可见上下文、17 pt 字体和键盘宽度减 48 pt 估计折行，使用 caretRect/closestPosition 计算目标 UTF-16 偏移，再经 adjustTextPosition 移动宿主光标；上下移动保留目标横坐标，横移或新手势清除。主 App 继续读取真实 UITextView 几何。

这能让自动折行段落上下移动，但不是宿主的精确显示行定位。公开 [UITextDocumentProxy 文档](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards) 没有提供宿主排版几何，宿主字体、边距、宽度及截断上下文会造成估计偏差。此限制需要继续在不同 App 中人工验证，不能用共用视图测试宣称所有宿主都一致。

KeyboardDeletePrompt 替换居中的删行文字，在退格键上方显示白底红色浮层及垃圾桶图标。普通按下、短按和长按重复均不显示浮窗，只有上移进入删行手势后才显示「松手清空」；滑回原位或横向离开会解除删除意图，松手不删也不产生额外退格。KeyboardHostConnection 保存一次删除返回的准确文字与删除后的文档、前后上下文和选择范围，KeyboardView 在假名切换按钮左侧显示撤回。撤回前必须匹配保存的锚点；新输入、导航、外部编辑或离开键盘会清除记录，避免插入到错误位置。记录只保存在内存中，不保存宿主文字到偏好或验收数据。

表情面板 frame 改为整个 KeyboardView.bounds，打开时隐藏原顶部 header 和底部地球键，去掉「表情与颜文字」大标题。只保留面板自身的返回、模式及分类控件；440 pt 时 Emoji 网格每行九列，单元可复用，滚动内容占用原工具栏和底部空白。

主 App 的 KeyboardHeightEditor 提供可拖动顶部横条的真实键盘预览，以及保存、取消和恢复默认。KeyboardMetrics 的 heightFactor 只调整四行键帽高度及行距，范围 0.85…1.60，宽度和列归属规则不变。保存至 group.com.Voltline.Vime 的 UserDefaults；App 和扩展共用 Configuration/Vime.entitlements 并使用同一 App Group。扩展在 viewWillAppear 重读高度并更新现有高度约束，试打区同时刷新 intrinsicContentSize。共享同步需要允许完全访问，其他偏好仍各自独立保存；换签名团队/bundle ID 时也需重新配置 App Group。

针对性回归：模拟器 9 项、iPhone 16 Pro Max 4 项均通过，覆盖无换行的混合文字纵移、删行精确恢复及失效锚点、手势滑回取消、符号页全区域与返回、高度拖动和 App Group 到扩展控制器读值。另复核原有 sticky/alternate 与 70 键交错输入；没有重跑全键盘网格或逐个 Emoji 测试。界面渲染图只留在本地 xcresult 中；本轮验收单独记录在 Artifacts/keyboard-ui-refinements-audit.json。

后续实机发现向上后再向下仍有失效：宿主移动期间的 after-context 可能缺失，旧实现每次用新的前后上下文重建布局，使虚拟光标停在截断文本的末尾。现在每次手势开始时建立文本与光标镜像，在同一手势内按已发出的 UTF-16 偏移更新位置；新手势重新读取宿主。未公开的宿主排版仍只能近似。用户重载后确认 Emoji 底部、上下往返移动、普通退格无浮窗三项均正常。

## 2026-10-05 离线纠错与近音候选

正常查询仍使用原始 ComposingText 与 autoMix，先发布正常候选。后台串行 worker 在正常结果返回后等待 140 ms，再为当前 revision 搜索一处误输。新输入取消尚未开始的搜索；生成变体与每次词典查询间检查取消。每条纠错查询都从独立 correction session 的空转换状态开始，与正常会话共享同一个 DicdataStore 和字典缓存。n 备选也在每条查询前清空自己的转换状态：长句中的两种 n 分隔方式此前会触发上游增量 lattice 停滞，这项定向修复通过长句回归验证。

KeyboardCorrectionVariants 按 QWERTY 几何邻键、漏字、多字、相邻转置、清浊音及小假名等通用规则生成单处变体，含 tsu/zu 的读音近似。没有 shitsuka、静か 等示例整词映射。最多 384 个变体，原输入最多 40 个元素、显示文本 3…24 字符；末尾未完成辅音保持普通预测。每次搜索最多 24 次上游查询、3 个补充候选，并在查询前检查 60 ms 软预算。上游同步查询不可中断，因此预算不代表单次查询的硬上限；冷查询及较长词句可能超时，仍在后台执行。

CorrectionReadings.bin 从固定修订的真实默认词典派生，为 245,506 个读音保存哈希、最佳词条成本和左右词类连接 ID，共 4,910,128 字节，映射为只读 Data。查询规划综合错误成本、原转换的兜底片段、替换片段的词典成本及与左右词的 getCCValue 连接增益，再调用正常转换引擎验证完整读音、完整消费和真实词典条目；固定分数的假名展示兜底不能作为证据。最终 lattice 分数按读音长度归一化，扣除错误成本并要求超过原读音一定差距。分数是启发式排序值，不是纠错概率。找到一组合格读音后停止继续探测，最近 96 个独立读音查询使用有界缓存。

CandidateSnapshot 增加 correction 来源、原/建议读音、可选罗马音、错误类型与位置单位、原输入数量和实际消费数量。完整纠错快照的 remainingComposition 为空，消费原 query.input.count，包括分隔符，而不是纠正后的字符数。去重同时比较正文与消费数量；同字的真实原读音匹配优先，其他读音的旧预测若被验证为纠错，则刷新原位置的元数据。

候选条和展开面板共用 CandidatePresentation，纠错候选下方显示「しずか · 建议」，VoiceOver 同时读出建议与原读音；提示不进入宿主。正文相同、读音或来源变化也触发刷新，只有正文、提示宽度或字体变化才重新测量。一般在保留前两项正常候选后加入建议，并继续预留片假名入口。用户一旦用空格选中候选，整个候选列表被冻结；revision 改变或组合结束后，迟到的纠错结果直接丢弃。marked text、假名退格与未选词时回车确认字面假名保持原行为。

未启用经典 typo 模式、Zenzai、实验 N-gram 或任何网络模型。此版只使用当前组合中的词句连接，不使用宿主已提交段落作为语言上下文；不支持多处错误、部分纠错消费或自动改写草稿。人名与罕见词仍可能收到不必要建议，不能把词典支持当作语境正确。真实正反样本、独立样本及同口径性能结果另见本次纠错验收记录。

## 2026-10-05 按键浮窗与顶部间距

浮窗遮挡可稳定复现：KeyboardKey 原来把预览直接加到 KeyboardView 上并 bringSubviewToFront；随后 KeyboardView.layoutSubviews 再把 header 移到最上层，候选文字便覆盖预览，造成透底的观感。原 key 背景颜色实际已有 alpha=1，问题主要是层级。现在 KeyboardView 拥有独立 previewOverlay，各键使用弱引用把浮窗放入该层；布局结束保持它在最上层，layer.zPosition=1，高于其他自有界面。该层不接受触摸，浮窗显式 alpha=1、背景 alpha=1；松手、取消或切换面板时仍清理预览。横屏第一行预览的位置限制在自有键盘边界内，避免被输入容器上缘裁掉。

此前普通工具栏按中心定位，默认顶部约 10.75 pt，而表情页返回按钮为 y=0、picker 为 y=2，页面没有统一顶部间距。现由 KeyboardMetrics.toolbarTopInset 统一提供 8 pt；正常工具按钮和表情页返回按钮都从该位置排布，picker 与返回按钮垂直居中。顶部间距不随高度系数变化，表情页仍占用整个自有面板。

输入容器初始化也修正为当前配置：扩展先读取 footer/地球键需求，再用已保存高度系数计算首个高度约束，而不是临时固定为不含 footer 的默认 272 pt；之后仅在目标高度变化时更新约束。主 App 的 SandboxInputView 首帧也用真实 preferredHeight 初始化。这样避免首次展示使用默认高度、随后重新布局跳到保存高度。

定向验证共六项：候选发布/重新布局期间浮窗置顶且不拦截输入、表情顶部在重开/高度变化后不变、面板返回、共享高度初始化、原有 sticky/alternate，以及 70 键突发/交错输入。首次高度断言追加后仅补跑相关三项，均通过；未重复触点网格或逐个表情扫描。渲染图只保存在 /private/tmp。自动测试使用附着窗口的 UIKit 输入容器；模拟器试验没有实际弹出系统软件键盘，因此不能据此宣称复现了所有宿主的偶发外部顶部留白。系统扩展的最终间距仍需实机确认，详见 Artifacts/keyboard-presentation-audit.json。
