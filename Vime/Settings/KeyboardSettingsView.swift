import SwiftUI

/// Settings home: the keyboard's reported status, then destinations as tiles.
struct KeyboardSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var summary: KeyboardSettingsSummary
    @State private var counts: KeyboardSettingsCounts
    @State private var refresh = 0
    /// Fixed values for rendering tests; the live page reloads on appear.
    private let fixed: Bool

    init(summary: KeyboardSettingsSummary? = nil, counts: KeyboardSettingsCounts? = nil) {
        _summary = State(initialValue: summary ?? .load())
        _counts = State(initialValue: counts ?? KeyboardSettingsCounts())
        fixed = summary != nil
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        AppDashboardPage {
            KeyboardStatusCard(summary: summary, counts: counts)
            SettingsQuickToggles { reload() }
            VStack(alignment: .leading, spacing: 10) {
                AppSectionTitle("更多设置")
                LazyVGrid(columns: columns, spacing: 12) {
                    SettingsTile(title: "转换与联想", detail: summary.suggestions ? String(localized: "下一词联想 开") : String(localized: "下一词联想 关"),
                                 icon: .glyph("あ"), tint: .blue, id: "vime.settings.input") { KeyboardInputSettingsView() }
                    SettingsTile(title: "用户词典", detail: String(localized: "姓名、词语与短语"),
                                 icon: .symbol("character.book.closed"), tint: .orange, id: "vime.settings.dictionary") { KeyboardUserDictionaryView() }
                    SettingsTile(title: "手感与布局", detail: summary.feelDetail,
                                 icon: .symbol("keyboard"), tint: .teal, id: "vime.settings.feedback") { KeyboardFeedbackSettingsView() }
                    SettingsTile(title: "符号与括号", detail: summary.symbolDetail,
                                 icon: .symbol("number"), tint: .indigo, id: "vime.settings.symbols") { KeyboardNumberSymbolsView() }
                    SettingsTile(title: "剪贴板", detail: summary.clipboard ? String(localized: "自动读取已开启") : String(localized: "自动读取已关闭"),
                                 icon: .symbol("doc.on.clipboard"), tint: .gray, id: "vime.settings.clipboard") { KeyboardClipboardSettingsView() }
                    SettingsTile(title: "学习与隐私", detail: String(localized: "清空学习 · 隐私政策"),
                                 icon: .symbol("checkmark.shield"), tint: .green, id: "vime.settings.privacy") { KeyboardDataPrivacyView() }
                }
            }
            AppSettingsActionGroup {
                NavigationLink { KeyboardSetupGuide() } label: { SettingsListRow(title: "启用指南") }
                    .accessibilityIdentifier("vime.settings.setup")
                Divider().padding(.leading, 16)
                NavigationLink { TipJarView() } label: { SettingsListRow(title: "赞助开发") }
                    .accessibilityIdentifier("vime.settings.tips")
                Divider().padding(.leading, 16)
#if DEBUG
                // Developer test host; App Store builds use the home typing tab instead.
                NavigationLink { KeyboardExtensionTestView() } label: { SettingsListRow(title: "问题诊断") }
                    .accessibilityIdentifier("vime.settings.diagnostics")
                Divider().padding(.leading, 16)
#endif
                NavigationLink { AboutVimeView() } label: { SettingsListRow(title: "关于 Vime", value: summary.appVersion) }
                    .accessibilityIdentifier("vime.settings.about")
            }
        }
        .navigationTitle("设置")
        .onAppear { reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
        .task(id: refresh) { if !fixed { counts = await KeyboardSettingsCounts.load() } }
        .task {
            // The keyboard may first report while this page is open.
            while !fixed && !Task.isCancelled && summary.status?.fullAccess != true {
                try? await Task.sleep(for: .seconds(1))
                summary = .load()
            }
        }
    }

    /// Returning from a sub-page or from iOS Settings may change any value.
    private func reload() {
        guard !fixed else { return }
        summary = .load()
        refresh += 1
    }
}

/// Values shown on the home page. Each read is a UserDefaults lookup.
struct KeyboardSettingsSummary: Equatable {
    var status: KeyboardExtensionStatus?
    var ranking: CandidateRankingMode
    var suggestions: Bool
    var hapticIntensity: Double
    var nineKeyNumbers: Bool
    var autoPairBrackets: Bool
    var symbolCount: Int
    var clipboard: Bool
    var appVersion: String
    /// Listed in iOS's added keyboards; it may not have run since.
    var added = false

    static func load(preferences: KeyboardPreferences = KeyboardPreferences(),
                     status: KeyboardExtensionStatus? = KeyboardExtensionStatus.load()) -> Self {
        Self(status: status, ranking: preferences.candidateRanking, suggestions: preferences.phraseSuggestions,
             hapticIntensity: preferences.hapticIntensity, nineKeyNumbers: preferences.nineKeyNumbers,
             autoPairBrackets: preferences.autoPairBrackets, symbolCount: preferences.numberSymbols.count,
             clipboard: preferences.clipboardSuggestions,
             appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
             added: KeyboardSetupProgress.load(status: status).added)
    }

    var feelDetail: String {
        let level = HapticIntensity.levels.first { abs($0.value - hapticIntensity) < 1e-7 }?.title
            ?? "\(Int((hapticIntensity * 100).rounded()))%"
        let haptic = hapticIntensity == 0 ? String(localized: "振动关") : String(localized: "振动\(level)")
        let layout = nineKeyNumbers ? String(localized: "九宫格") : String(localized: "全键盘")
        return String(localized: "\(haptic) · \(layout)")
    }
    var symbolDetail: String {
        autoPairBrackets ? String(localized: "\(symbolCount) 个常用 · 自动配对开")
            : String(localized: "\(symbolCount) 个常用 · 自动配对关")
    }

    /// Ranking stat on the status card.
    var rankingValue: String {
        guard ranking == .languageModel else { return String(localized: "词典排序") }
        guard let status else { return String(localized: "待使用") }
        if status.modelPaused { return String(localized: "已暂停") }
        // The model version is diagnostics detail; users only need the state.
        return status.modelShortVersion == nil ? String(localized: "待加载") : String(localized: "已开启")
    }
}

/// File-backed counts, read off the main thread. nil: not available here.
nonisolated struct KeyboardSettingsCounts: Equatable, Sendable {
    var dictionary: Int?
    var learned: Int?

    static func load() async -> Self {
        await Task.detached(priority: .userInitiated) {
            let dictionary = try? JapaneseUserDictionaryStore().entries().count
            let learned = CandidatePreferenceMemory.sharedDirectory.map {
                CandidatePreferenceMemory(directory: $0).learnedConversionCount
            }
            return Self(dictionary: dictionary, learned: learned)
        }.value
    }
}

private struct KeyboardStatusCard: View {
    let summary: KeyboardSettingsSummary
    let counts: KeyboardSettingsCounts
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    private let blue = Color.vimeBlue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let status = summary.status, status.fullAccess {
                header(symbol: nil, title: "键盘运行正常", detail: String(localized: "完全访问已开启 · \(Self.lastSeen(status.lastSeen))"))
                let stats = Group {
                    stat("智能排序", summary.rankingValue, id: "vime.settings.status.ranking") { KeyboardInputSettingsView() }
                    stat("已学习", counts.learned.map { String(localized: "\($0) 个") } ?? "—", id: "vime.settings.status.learned") { KeyboardDataPrivacyView() }
                    stat("用户词典", counts.dictionary.map { String(localized: "\($0) 条") } ?? "—", id: "vime.settings.status.dictionary") { KeyboardUserDictionaryView() }
                }
                if typeSize.isAccessibilitySize { VStack(spacing: 8) { stats } }
                else { HStack(alignment: .top, spacing: 8) { stats } }
            } else {
                if summary.status != nil {
                    header(symbol: "exclamationmark.triangle", title: "完全访问未开启",
                           detail: String(localized: "声音、振动、共享词典与学习需要完全访问"))
                } else if summary.added {
                    // Full access is unknown until the keyboard runs and reports.
                    header(symbol: "keyboard", title: "正在等待完全访问…",
                           detail: String(localized: "在任意输入框切换到 Vime 打一个字"))
                } else {
                    header(symbol: "exclamationmark.triangle", title: "还没检测到键盘",
                           detail: String(localized: "添加 Vime 并开启完全访问后，这里会显示状态"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "设置 › 通用 › 键盘 › 添加新键盘 › Vime")
                    step(2, "点 Vime，打开「允许完全访问」")
                    step(3, "在任意输入框切换到 Vime 打一个字")
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Text("打开系统设置").font(.subheadline.weight(.semibold)).foregroundStyle(blue)
                            .frame(maxWidth: .infinity, minHeight: 44).background(.white, in: Capsule())
                    }.accessibilityIdentifier("vime.settings.status.openSettings")
                    NavigationLink { KeyboardSetupGuide() } label: {
                        Text("启用指南").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 44).background(.white.opacity(0.18), in: Capsule())
                    }.accessibilityIdentifier("vime.settings.status.guide")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .foregroundStyle(.white)
        .background(blue, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vime.settings.status")
    }

    private func header(symbol: String?, title: LocalizedStringResource, detail: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let symbol { Image(systemName: symbol).font(.title3.weight(.semibold)) }
                else { VimeLogoMark().stroke(.white, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)).padding(7) }
            }
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold))
                Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stat<Destination: View>(_ title: LocalizedStringResource, _ value: String, id: String,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.85))
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func step(_ number: Int, _ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.caption.weight(.semibold))
                .frame(width: 20, height: 20).overlay(Circle().stroke(.white, lineWidth: 1.5))
                .accessibilityHidden(true)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func lastSeen(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "刚刚使用过") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans")
        formatter.unitsStyle = .full
        return String(localized: "\(formatter.localizedString(for: date, relativeTo: now))使用过")
    }
}

/// The folded V of the app icon, drawn from the shared logo geometry.
private struct VimeLogoMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        path.move(to: point(0.25, 0.35)); path.addLine(to: point(0.46, 0.69)); path.addLine(to: point(0.75, 0.28))
        path.move(to: point(0.65, 0.69)); path.addLine(to: point(0.77, 0.69))
        return path
    }
}

/// The switches changed most often, without opening a sub-page.
private struct SettingsQuickToggles: View {
    @AppStorage private var suggestions: Bool
    @AppStorage private var sound: Bool
    @AppStorage private var clipboard: Bool
    @State private var confirmingClipboard = false
    let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        let prefs = KeyboardPreferences(), store = prefs.store
        _suggestions = AppStorage(wrappedValue: prefs.phraseSuggestions, "vime.phraseSuggestions", store: store)
        _sound = AppStorage(wrappedValue: prefs.sound, "vime.sound", store: store)
        _clipboard = AppStorage(wrappedValue: prefs.clipboardSuggestions, "vime.clipboardSuggestions", store: store)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionTitle("常用开关")
            AppSettingsActionGroup {
                toggle("下一词联想", "确认文字后建议接下来的词", symbol: "text.append", isOn: $suggestions,
                       id: "vime.settings.quick.suggestions")
                Divider().padding(.leading, 52)
                toggle("按键声音", "需要允许完全访问", symbol: "speaker.wave.2", isOn: $sound, id: "vime.settings.quick.sound")
                Divider().padding(.leading, 52)
                // Same consent as the clipboard page: confirm before reading,
                // and turning it off deletes the history.
                toggle("自动读取剪贴板", "复制的文字出现在候选栏", symbol: "doc.on.clipboard",
                       isOn: Binding(get: { clipboard }, set: { value in
                           if value { confirmingClipboard = true; return }
                           clipboard = false
                           Task { try? await ClipboardHistoryStore().clear(includingReadState: true) }
                       }), id: "vime.settings.quick.clipboard")
            }
        }
        .onChange(of: suggestions) { onChange() }
        .onChange(of: sound) { onChange() }
        .onChange(of: clipboard) { onChange() }
        .alert("开启自动读取剪贴板？", isPresented: $confirmingClipboard) {
            Button("取消", role: .cancel) {}
            Button("了解并开启") { clipboard = true }
        } message: {
            Text("键盘显示时会读取你复制的文本，可能包含敏感信息。最近 24 小时的记录仅保存在本机，不上传；你可以清空历史，关闭功能也会删除记录。iOS 仍会单独请求粘贴权限。")
        }
    }

    private func toggle(_ title: LocalizedStringResource, _ subtitle: LocalizedStringResource, symbol: String,
                        isOn: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: isOn) { AppSettingsLabel(title: title, subtitle: subtitle, symbol: symbol) }
            .tint(.vimeBlue)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 60)
            .accessibilityIdentifier(id)
    }
}

private struct SettingsTile<Destination: View>: View {
    let title: LocalizedStringResource
    let detail: String
    let icon: AppIconChip.Icon
    let tint: Color
    let id: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 14) {
                AppIconChip(icon: icon, tint: tint)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .appCard()
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

private struct SettingsListRow: View {
    let title: LocalizedStringResource
    var value: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let value { Text(value).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct KeyboardInputSettingsView: View {
    @State private var retryRequested = false
    @AppStorage private var ranking: CandidateRankingMode
    @AppStorage private var suggestions: Bool
    @AppStorage private var undoConversion: Bool
    @AppStorage private var autoCapitalize: Bool
    @AppStorage private var doubleSpacePeriod: Bool
    @AppStorage private var englishCompletion: Bool
    init() {
        let prefs = KeyboardPreferences()
        _ranking = AppStorage(wrappedValue: prefs.candidateRanking, "vime.candidateRanking", store: prefs.store)
        _suggestions = AppStorage(wrappedValue: prefs.phraseSuggestions, "vime.phraseSuggestions", store: prefs.store)
        _undoConversion = AppStorage(wrappedValue: prefs.undoConversionOnBackspace, "vime.undoConversionOnBackspace", store: prefs.store)
        _autoCapitalize = AppStorage(wrappedValue: prefs.autoCapitalize, "vime.autoCapitalize", store: prefs.store)
        _doubleSpacePeriod = AppStorage(wrappedValue: prefs.doubleSpacePeriod, "vime.doubleSpacePeriod", store: prefs.store)
        _englishCompletion = AppStorage(wrappedValue: prefs.englishCompletion, "vime.englishCompletion", store: prefs.store)
    }
    var body: some View {
        Form {
            Section {
                Picker("候选排序", selection: Binding(get: { ranking }, set: { value in
                    ranking = value
                    if value == .languageModel { KeyboardPreferences().requestNeuralRetry() }
                })) {
                    ForEach(CandidateRankingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("下一词联想", isOn: $suggestions)
                Toggle("退格撤销转换", isOn: $undoConversion)
                    .accessibilityIdentifier("vime.settings.undoConversion")
            } footer: {
                Text("智能排序使用本地模型调整候选顺序\n下一词联想在确认文字后提供建议\n退格撤销转换：转换后立即按退格，回到读音重新选择\n关闭智能排序或联想不会清除已有学习数据")
            }
            if ranking == .languageModel {
                Section {
                    Button("重试智能排序") {
                        KeyboardPreferences().requestNeuralRetry()
                        retryRequested = true
                    }.accessibilityIdentifier("vime.settings.neural.retry")
                } footer: {
                    Text(retryRequested ? "已发送重试请求，下次打开键盘时生效。" : "内存紧张后智能排序可能暂停。重试后，后续输入将重新尝试使用本地模型。")
                }
            }
            Section {
                Toggle("自动大写", isOn: $autoCapitalize)
                    .accessibilityIdentifier("vime.settings.autoCapitalize")
                Toggle("连按两下空格输入句号", isOn: $doubleSpacePeriod)
                    .accessibilityIdentifier("vime.settings.doubleSpacePeriod")
                Toggle("英文单词补全", isOn: $englishCompletion)
                    .accessibilityIdentifier("vime.settings.englishCompletion")
            } header: { Text("英文输入") } footer: {
                Text("自动大写按输入框的要求在句首或词首切换为大写\n连按两下空格会在单词后输入句号和空格\n单词补全在候选栏提供拼写补全，点按即替换当前单词")
            }
        }
        .appReadableList()
        .navigationTitle("转换与联想").navigationBarTitleDisplayMode(.inline)
    }
}

struct KeyboardFeedbackSettingsView: View {
    @EnvironmentObject private var router: AppRouter
    @ScaledMetric(relativeTo: .caption) private var scaleHeight = 24.0
    @AppStorage private var sound: Bool
    @AppStorage private var intensity: Double
    @AppStorage private var nineKeyNumbers: Bool
    @AppStorage private var kanaLayout: Bool
    @AppStorage private var prolongedKey: Bool
    @AppStorage private var previews: Bool
    @AppStorage private var oneHanded: KeyboardOneHandedSide
    init() {
        let prefs = KeyboardPreferences(), store = prefs.store
        _sound = AppStorage(wrappedValue: prefs.sound, "vime.sound", store: store)
        _intensity = AppStorage(wrappedValue: prefs.hapticIntensity, "vime.hapticIntensity", store: store)
        _nineKeyNumbers = AppStorage(wrappedValue: prefs.nineKeyNumbers, "vime.nineKeyNumbers", store: store)
        _kanaLayout = AppStorage(wrappedValue: prefs.kanaLayout, "vime.kanaLayout", store: store)
        _prolongedKey = AppStorage(wrappedValue: prefs.prolongedKey, "vime.prolongedKey", store: store)
        _previews = AppStorage(wrappedValue: prefs.previews, "vime.previews", store: store)
        _oneHanded = AppStorage(wrappedValue: prefs.oneHanded, "vime.oneHanded", store: store)
    }
    var body: some View {
        Form {
            Section {
                Toggle("按键声音", isOn: $sound)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("振动强度")
                        Spacer()
                        Text(HapticIntensity.description(intensity)).font(.subheadline).foregroundStyle(.tint)
                    }
                    AppHapticSlider(value: $intensity).frame(height: 44)
                    AppHapticScale().frame(height: scaleHeight)
                        .accessibilityHidden(true)
                }.padding(.vertical, 4)
            } header: { Text("按键反馈") } footer: {
                Text("靠近关闭、中、强时松手会吸附，档位之间可连续调节\n声音与振动需要允许完全访问\n静音时不播放按键声，振动效果以实际设备为准")
            }
            Section {
                Button { router.present(.height) } label: {
                    HStack {
                        Text("键盘高度").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.accessibilityIdentifier("vime.settings.height")
                Picker("日语布局", selection: $kanaLayout) {
                    Text("罗马字").tag(false); Text("假名九宫格").tag(true)
                }
                .accessibilityIdentifier("vime.settings.kanaLayout")
                Picker("数字布局", selection: $nineKeyNumbers) {
                    Text("九宫格").tag(true); Text("全键盘").tag(false)
                }
                Toggle("显示长音键 ー", isOn: $prolongedKey).disabled(kanaLayout)
                Toggle("按键预览", isOn: $previews)
            } header: { Text("布局") } footer: {
                Text("假名九宫格：点按输入あ段，上下左右滑动输入其他段；连续点按同一键依次切换\n声音、振动和数字布局也可在键盘左上角快速调整\n修改后重新打开键盘即可读取更新")
            }
            if UIDevice.current.userInterfaceIdiom == .phone {
                Section {
                    Picker("单手模式", selection: $oneHanded) {
                        Text("关闭").tag(KeyboardOneHandedSide.off)
                        Text("靠左").tag(KeyboardOneHandedSide.left)
                        Text("靠右").tag(KeyboardOneHandedSide.right)
                    }
                    .accessibilityIdentifier("vime.settings.oneHanded")
                } footer: {
                    Text("单手模式仅在竖屏时生效，点按键盘旁的空白条可恢复全宽，也可在键盘左上角快速切换")
                }
            }
        }
        .appReadableList()
        .navigationTitle("手感与布局").navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppHapticSlider: View {
    @Binding var value: Double
    var body: some View {
        // Native tracking arbitrates with NavigationStack's content-back swipe.
        // The extension's raw-touch slider is specific to the keyboard host.
        Slider(value: $value, in: 0...1, onEditingChanged: { editing in
            if !editing { value = HapticIntensity.snapped(value) }
        })
        .tint(Color(cgColor: VimeLogo.blue))
        .accessibilityLabel("振动强度")
        .accessibilityIdentifier("vime.setting.haptics")
        .accessibilityValue(HapticIntensity.description(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = HapticIntensity.levels.first { $0.value > value + 1e-6 }?.value ?? 1
            case .decrement: value = HapticIntensity.levels.last { $0.value < value - 1e-6 }?.value ?? 0
            @unknown default: break
            }
        }
    }
}

private struct AppHapticScale: UIViewRepresentable {
    func makeUIView(context: Context) -> HapticIntensityScale { HapticIntensityScale() }
    func updateUIView(_ view: HapticIntensityScale, context: Context) { view.setNeedsLayout() }
}

struct KeyboardDataPrivacyView: View {
    @State private var confirmLearningReset = false
    @AppStorage private var resetRequest: String
    @AppStorage private var resetCompleted: String
    init() {
        let store = KeyboardPreferences().store
        _resetRequest = AppStorage(wrappedValue: "", "vime.learningReset.request", store: store)
        _resetCompleted = AppStorage(wrappedValue: "", "vime.learningReset.completed", store: store)
    }
    private var learningResetMessage: String {
        if resetRequest.isEmpty { return String(localized: "清空后将重新学习输入习惯。用户词典、剪贴板历史和皮肤会保留。") }
        if resetRequest != resetCompleted { return String(localized: "清空请求已保存，下次打开键盘时执行；完成前可再次打开键盘重试。") }
        return String(localized: "上次清空已完成。键盘会重新学习输入习惯；用户词典、剪贴板历史和皮肤保留。")
    }
    var body: some View {
        AppSettingsPage {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.title2).foregroundStyle(.tint).frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("输入数据留在本机").font(.headline)
                    Text("转换、纠错、排序和联想在设备上完成，不上传输入或剪贴板内容。")
                        .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("学习记录").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                AppSettingsActionGroup {
                    Button { confirmLearningReset = true } label: {
                        AppSettingsActionRow(title: "清空学习记录", subtitle: "重置词语偏好与转换学习", symbol: "arrow.counterclockwise")
                    }.accessibilityIdentifier("vime.privacy.resetLearning")
                }
                Text(learningResetMessage)
                    .font(.footnote).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("管理与政策").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                AppSettingsActionGroup {
                    NavigationLink { KeyboardClipboardSettingsView() } label: {
                        AppSettingsActionRow(title: "剪贴板自动读取", subtitle: "管理一天历史、读取开关与系统授权", symbol: "doc.on.clipboard")
                    }.accessibilityIdentifier("vime.privacy.clipboard")
                    Divider().padding(.leading, 52)
                    NavigationLink { KeyboardUserDictionaryView() } label: {
                        AppSettingsActionRow(title: "用户词典", subtitle: "编辑、删除或导出已添加的词条", symbol: "character.book.closed")
                    }.accessibilityIdentifier("vime.privacy.dictionary")
                    Divider().padding(.leading, 52)
                    NavigationLink { PrivacyPolicyView() } label: {
                        AppSettingsActionRow(title: "隐私政策", subtitle: "阅读完整的信息处理与权限说明", symbol: "doc.text")
                    }.accessibilityIdentifier("vime.privacy.policy")
                }
            }

            DisclosureGroup("本地数据说明") {
                VStack(alignment: .leading, spacing: 24) {
                    AppInformationSection("输入与学习") {
                        Text("确认的词语、读音和使用情况用于本地学习，帮助调整候选。关闭智能排序或下一词联想会保留已有学习数据。")
                    }
                    AppInformationSection("存储与备份") {
                        Text("App 与键盘在本机共享设置、皮肤、用户词典和学习文件。系统备份可能包含这些数据，恢复备份时也可能恢复。剪贴板历史仅保留最近 24 小时，并排除在备份之外。")
                    }
                    AppInformationSection("管理与删除") {
                        Text("自定义皮肤可在“定制”页编辑、导出和删除。学习记录可单独清空；删除词典条目不会同时删除已有学习记录。")
                    }
                }.padding(.top, 16)
            }
            .font(.subheadline)
        }
        .navigationTitle("学习与隐私").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清空所有学习记录？", isPresented: $confirmLearningReset, titleVisibility: .visible) {
            Button("清空学习记录", role: .destructive) { KeyboardPreferences().learningResetRequests.request() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次打开键盘时清空词语偏好和转换学习，此操作无法撤销。用户词典、剪贴板历史和皮肤不会删除。")
        }
    }
}
