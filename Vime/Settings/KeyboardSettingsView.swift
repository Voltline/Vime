import SwiftUI

struct KeyboardSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingHeightEditor = false
    @AppStorage private var sound: Bool
    @AppStorage private var hapticLevel: Int
    @AppStorage private var nineKeyNumbers: Bool
    @AppStorage private var prolongedKey: Bool
    @AppStorage private var previews: Bool
    @AppStorage private var theme: KeyboardTheme
    @AppStorage private var ranking: CandidateRankingMode
    @AppStorage private var suggestions: Bool
    private let levels = ["关闭", "很轻", "轻", "中", "强", "很强"]

    init() {
        let preferences = KeyboardPreferences()
        let store = preferences.store
        _sound = AppStorage(wrappedValue: preferences.sound, "vime.sound", store: store)
        _hapticLevel = AppStorage(wrappedValue: preferences.hapticLevel, "vime.hapticLevel", store: store)
        _nineKeyNumbers = AppStorage(wrappedValue: preferences.nineKeyNumbers, "vime.nineKeyNumbers", store: store)
        _prolongedKey = AppStorage(wrappedValue: preferences.prolongedKey, "vime.prolongedKey", store: store)
        _previews = AppStorage(wrappedValue: preferences.previews, "vime.previews", store: store)
        _theme = AppStorage(wrappedValue: preferences.theme, "vime.theme", store: store)
        _ranking = AppStorage(wrappedValue: preferences.candidateRanking, "vime.candidateRanking", store: store)
        _suggestions = AppStorage(wrappedValue: preferences.phraseSuggestions, "vime.phraseSuggestions", store: store)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("候选排序", selection: $ranking) {
                        ForEach(CandidateRankingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("下一词联想", isOn: $suggestions)
                } header: {
                    Text("智能输入")
                } footer: {
                    Text("智能排序结合当前句子调整候选顺序；下一词联想在确认文字后提供建议。两项功能均离线运行，可单独关闭。")
                }
                Section("外观") {
                    Picker("键盘皮肤", selection: $theme) {
                        ForEach(KeyboardTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button { showingHeightEditor = true } label: {
                        HStack {
                            Text("键盘高度")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                }
                Section("输入布局") {
                    Picker("数字布局", selection: $nineKeyNumbers) {
                        Text("九宫格").tag(true)
                        Text("全键盘").tag(false)
                    }
                    Toggle("显示长音键 ー", isOn: $prolongedKey)
                    Toggle("按键预览", isOn: $previews)
                }
                Section {
                    Toggle("按键声音", isOn: $sound)
                    Picker("振动强度", selection: $hapticLevel) {
                        ForEach(levels.indices, id: \.self) { Text(levels[$0]).tag($0) }
                    }
                } header: {
                    Text("按键反馈")
                } footer: {
                    Text("声音、振动和数字布局也可在键盘左上角快速调整。声音与振动需要允许完全访问，静音时不播放按键声。")
                }
                Section {
                    Text("开启键盘的「允许完全访问」后，设置可同步到其他 App 中的 Vime 键盘。修改后重新打开键盘即可生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("键盘设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .tint(Color(uiColor: UIColor(cgColor: VimeLogo.blue)))
            .sheet(isPresented: $showingHeightEditor) { KeyboardHeightEditor() }
        }
    }
}
