import SwiftUI

struct KeyboardSettingsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { KeyboardInputSettingsView() } label: {
                    SettingsRow(title: "输入与联想", subtitle: "排序、下一词联想、用户词典", symbol: "text.cursor")
                }
                NavigationLink { KeyboardFeedbackSettingsView() } label: {
                    SettingsRow(title: "手感与布局", subtitle: "声音、振动、按键预览", symbol: "hand.tap")
                }.accessibilityIdentifier("vime.settings.feedback")
                NavigationLink { KeyboardDataPrivacyView() } label: {
                    SettingsRow(title: "数据与隐私", subtitle: "本地数据、隐私政策", symbol: "lock.shield")
                }.accessibilityIdentifier("vime.settings.privacy")
            }
            Section("帮助") {
                NavigationLink { KeyboardSetupGuide() } label: { Label("启用键盘", systemImage: "plus.circle") }
                NavigationLink { KeyboardExtensionTestView() } label: { Label("问题诊断", systemImage: "stethoscope") }
            }
            Section {
                NavigationLink { AboutVimeView() } label: { Label("关于 Vime", systemImage: "info.circle") }.accessibilityIdentifier("vime.settings.about")
            }
        }
        .navigationTitle("键盘设置")
    }
}

private struct SettingsRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
    }
}

struct KeyboardInputSettingsView: View {
    @AppStorage private var ranking: CandidateRankingMode
    @AppStorage private var suggestions: Bool
    init() {
        let prefs = KeyboardPreferences()
        _ranking = AppStorage(wrappedValue: prefs.candidateRanking, "vime.candidateRanking", store: prefs.store)
        _suggestions = AppStorage(wrappedValue: prefs.phraseSuggestions, "vime.phraseSuggestions", store: prefs.store)
    }
    var body: some View {
        Form {
            Section {
                Picker("候选排序", selection: $ranking) {
                    ForEach(CandidateRankingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("下一词联想", isOn: $suggestions)
            } footer: {
                Text("智能排序使用本地模型调整候选顺序\n下一词联想在确认文字后提供建议\n关闭智能排序或联想不会清除已有学习数据")
            }
            Section {
                NavigationLink("用户词典") { KeyboardUserDictionaryView() }
            } footer: {
                Text("添加姓名、专业词或常用短语\n词典和学习数据保存在本机")
            }
        }
        .navigationTitle("输入与联想").navigationBarTitleDisplayMode(.inline)
    }
}

struct KeyboardFeedbackSettingsView: View {
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
            Section("布局") {
                Picker("数字布局", selection: $nineKeyNumbers) {
                    Text("九宫格").tag(true); Text("全键盘").tag(false)
                }
                Toggle("显示长音键 ー", isOn: $prolongedKey)
                Toggle("按键预览", isOn: $previews)
            }
            Section {
                Text("声音、振动和数字布局也可在键盘左上角快速调整\n修改后重新打开键盘即可读取更新")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("手感与布局").navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppHapticSlider: UIViewRepresentable {
    @Binding var value: Double
    func makeUIView(context: Context) -> HapticIntensitySlider {
        let slider = HapticIntensitySlider()
        slider.tintColor = UIColor(cgColor: VimeLogo.blue)
        return slider
    }
    func updateUIView(_ view: HapticIntensitySlider, context: Context) {
        view.onValue = { value, _ in self.value = value }
        // SwiftUI updates must not reposition the thumb during a native drag.
        if !view.isAdjusting { view.setIntensity(value) }
    }
}

private struct AppHapticScale: UIViewRepresentable {
    func makeUIView(context: Context) -> HapticIntensityScale { HapticIntensityScale() }
    func updateUIView(_ view: HapticIntensityScale, context: Context) { view.setNeedsLayout() }
}

struct KeyboardDataPrivacyView: View {
    var body: some View {
        List {
            Section("本地数据") {
                Text("转换、纠错、智能排序和联想在设备上运行")
                Text("确认的词语、读音与使用情况用于本地学习，帮助调整以后的候选")
                Text("App 与键盘通过 App Group 共享设置、皮肤、用户词典和学习文件")
            }
            Section("管理") {
                NavigationLink("用户词典") { KeyboardUserDictionaryView() }
                Text("自定义皮肤可在定制页编辑、导出和删除")
                Text("关闭智能排序或下一词联想只关闭对应功能，已有学习数据会保留")
                Text("系统备份可能包含本地数据，恢复备份也可能恢复这些数据")
            }
            Section {
                NavigationLink("隐私政策") { PrivacyPolicyView() }
            }
        }
        .navigationTitle("数据与隐私").navigationBarTitleDisplayMode(.inline)
    }
}
