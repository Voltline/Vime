import SwiftUI

struct KeyboardSettingsView: View {
    var body: some View {
        List {
            Section("输入") {
                NavigationLink { KeyboardInputSettingsView() } label: {
                    AppSettingsLabel(title: "输入与联想", subtitle: "候选排序、下一词联想", symbol: "text.cursor")
                }.accessibilityIdentifier("vime.settings.input")
                NavigationLink { KeyboardFeedbackSettingsView() } label: {
                    AppSettingsLabel(title: "手感与布局", subtitle: "键盘高度、声音、振动、数字布局", symbol: "hand.tap")
                }.accessibilityIdentifier("vime.settings.feedback")
                NavigationLink { KeyboardNumberSymbolsView() } label: {
                    AppSettingsLabel(title: "常用符号", subtitle: "数字键盘左侧的符号栏", symbol: "number")
                }.accessibilityIdentifier("vime.settings.symbols")
                NavigationLink { KeyboardUserDictionaryView() } label: {
                    AppSettingsLabel(title: "用户词典", subtitle: "姓名、词语与常用短语", symbol: "character.book.closed")
                }.accessibilityIdentifier("vime.settings.dictionary")
            }
            Section("数据") {
                NavigationLink { KeyboardClipboardSettingsView() } label: {
                    AppSettingsLabel(title: "剪贴板", symbol: "doc.on.clipboard")
                }.accessibilityIdentifier("vime.settings.clipboard")
                NavigationLink { KeyboardDataPrivacyView() } label: {
                    AppSettingsLabel(title: "数据与隐私", symbol: "lock.shield")
                }.accessibilityIdentifier("vime.settings.privacy")
            }
            Section("帮助与关于") {
                NavigationLink { KeyboardSetupGuide() } label: { AppSettingsLabel(title: "启用键盘", symbol: "plus.circle") }
                    .accessibilityIdentifier("vime.settings.setup")
                NavigationLink { AboutVimeView() } label: { AppSettingsLabel(title: "关于 Vime", symbol: "info.circle") }.accessibilityIdentifier("vime.settings.about")
                NavigationLink { KeyboardExtensionTestView() } label: { AppSettingsLabel(title: "问题诊断", symbol: "stethoscope") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("键盘设置")
    }
}

struct KeyboardInputSettingsView: View {
    @State private var retryRequested = false
    @AppStorage private var ranking: CandidateRankingMode
    @AppStorage private var suggestions: Bool
    @AppStorage private var autoPairBrackets: Bool
    init() {
        let prefs = KeyboardPreferences()
        _ranking = AppStorage(wrappedValue: prefs.candidateRanking, "vime.candidateRanking", store: prefs.store)
        _suggestions = AppStorage(wrappedValue: prefs.phraseSuggestions, "vime.phraseSuggestions", store: prefs.store)
        _autoPairBrackets = AppStorage(wrappedValue: prefs.autoPairBrackets, "vime.autoPairBrackets", store: prefs.store)
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
            } footer: {
                Text("智能排序使用本地模型调整候选顺序\n下一词联想在确认文字后提供建议\n关闭智能排序或联想不会清除已有学习数据")
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
                Toggle("自动补全括号", isOn: $autoPairBrackets)
                    .accessibilityIdentifier("vime.settings.autoPairBrackets")
            } header: { Text("符号输入") } footer: {
                Text("输入左括号时补上右括号，光标移到中间\n支持 ()、（）、「」等括号；关闭后只输入单个括号\n剪贴板粘贴保持原样")
            }
            Section {
                NavigationLink("用户词典") { KeyboardUserDictionaryView() }
            } footer: {
                Text("添加姓名、专业词或常用短语\n词典和学习数据保存在本机")
            }
            Section {
                NavigationLink("数字键盘常用符号") { KeyboardNumberSymbolsView() }
                    .accessibilityIdentifier("vime.settings.numberSymbols")
            } footer: { Text("自定义数字九宫格左侧的符号，支持添加、删除和排序") }
        }
        .navigationTitle("输入与联想").navigationBarTitleDisplayMode(.inline)
    }
}

struct KeyboardFeedbackSettingsView: View {
    @EnvironmentObject private var router: AppRouter
    @ScaledMetric(relativeTo: .caption) private var scaleHeight = 24.0
    @AppStorage private var sound: Bool
    @AppStorage private var intensity: Double
    @AppStorage private var nineKeyNumbers: Bool
    @AppStorage private var prolongedKey: Bool
    @AppStorage private var previews: Bool
    init() {
        let prefs = KeyboardPreferences(), store = prefs.store
        _sound = AppStorage(wrappedValue: prefs.sound, "vime.sound", store: store)
        _intensity = AppStorage(wrappedValue: prefs.hapticIntensity, "vime.hapticIntensity", store: store)
        _nineKeyNumbers = AppStorage(wrappedValue: prefs.nineKeyNumbers, "vime.nineKeyNumbers", store: store)
        _prolongedKey = AppStorage(wrappedValue: prefs.prolongedKey, "vime.prolongedKey", store: store)
        _previews = AppStorage(wrappedValue: prefs.previews, "vime.previews", store: store)
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
                Picker("数字布局", selection: $nineKeyNumbers) {
                    Text("九宫格").tag(true); Text("全键盘").tag(false)
                }
                Toggle("显示长音键 ー", isOn: $prolongedKey)
                Toggle("按键预览", isOn: $previews)
            } header: { Text("布局") } footer: {
                Text("声音、振动和数字布局也可在键盘左上角快速调整\n修改后重新打开键盘即可读取更新")
            }
        }
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
        if resetRequest.isEmpty { return "清空后将重新学习输入习惯。用户词典、剪贴板历史和皮肤会保留。" }
        if resetRequest != resetCompleted { return "清空请求已保存，下次打开键盘时执行；完成前可再次打开键盘重试。" }
        return "上次清空已完成。键盘会重新学习输入习惯；用户词典、剪贴板历史和皮肤保留。"
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
        .navigationTitle("数据与隐私").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清空所有学习记录？", isPresented: $confirmLearningReset, titleVisibility: .visible) {
            Button("清空学习记录", role: .destructive) { KeyboardPreferences().learningResetRequests.request() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次打开键盘时清空词语偏好和转换学习，此操作无法撤销。用户词典、剪贴板历史和皮肤不会删除。")
        }
    }
}
