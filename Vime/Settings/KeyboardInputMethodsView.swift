import SwiftUI

/// The input methods the keyboard offers, chosen from one list. Japanese has
/// two layouts, of which one is used; one input method always stays on.
struct KeyboardInputMethodsView: View {
    enum Method: CaseIterable, Identifiable {
        case romaji, kana, pinyin
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self { case .romaji, .kana: "日语"; case .pinyin: "简体中文" }
        }
        var layout: LocalizedStringResource {
            switch self { case .romaji: "罗马字"; case .kana: "假名九宫格"; case .pinyin: "全拼" }
        }
        var glyph: String {
            switch self { case .romaji: "A"; case .kana: "あ"; case .pinyin: "中" }
        }
        var identifier: String { "vime.settings.inputMethod.\(self)" }
    }

    @AppStorage private var japanese: Bool
    @AppStorage private var chinese: Bool
    @AppStorage private var kanaLayout: Bool
    @AppStorage private var inputLanguage: KeyboardInputLanguage
    private let chineseAvailable: Bool

    init(chineseAvailable: Bool = RimeEngine.bundledData != nil) {
        let prefs = KeyboardPreferences(), store = prefs.store
        _japanese = AppStorage(wrappedValue: true, "vime.japaneseInputEnabled", store: store)
        _chinese = AppStorage(wrappedValue: prefs.chineseInputEnabled, "vime.chineseInputEnabled", store: store)
        _kanaLayout = AppStorage(wrappedValue: prefs.kanaLayout, "vime.kanaLayout", store: store)
        _inputLanguage = AppStorage(wrappedValue: prefs.inputLanguage, "vime.inputLanguage", store: store)
        self.chineseAvailable = chineseAvailable
    }

    private var methods: [Method] { chineseAvailable ? Method.allCases : [.romaji, .kana] }
    /// As KeyboardPreferences reads them: Japanese is on whenever Chinese is off.
    private var japaneseOn: Bool { japanese || !chineseOn }
    private var chineseOn: Bool { chinese && chineseAvailable }

    private func isOn(_ method: Method) -> Bool {
        switch method {
        case .romaji: japaneseOn && !kanaLayout
        case .kana: japaneseOn && kanaLayout
        case .pinyin: chineseOn
        }
    }

    /// The last input method on cannot be turned off.
    private func canToggle(_ method: Method) -> Bool {
        !isOn(method) || methods.filter(isOn).count > 1
    }

    private func toggle(_ method: Method) {
        guard canToggle(method) else { return }
        switch method {
        case .romaji, .kana:
            let kana = method == .kana
            if japaneseOn && kanaLayout == kana {
                japanese = false
            } else {
                // The two layouts take turns: choosing one leaves the other.
                kanaLayout = kana
                japanese = true
            }
        case .pinyin:
            if chineseOn {
                japanese = true
                chinese = false
            } else {
                chinese = true
            }
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(methods) { method in
                    Button { toggle(method) } label: { row(method) }
                        .disabled(!canToggle(method))
                        .accessibilityIdentifier(method.identifier)
                        .accessibilityAddTraits(isOn(method) ? .isSelected : [])
                }
            } footer: {
                Text("日语的罗马字与假名九宫格二选一，至少保留一种输入法\n假名九宫格：点按输入あ段，上下左右滑动输入其他段；连续点按同一键依次切换\n切换后，下次打开键盘时生效")
            }
            if japaneseOn && chineseOn {
                Section {
                    Picker("输入语言", selection: $inputLanguage) {
                        Text("日语").tag(KeyboardInputLanguage.japanese)
                        Text("简体中文").tag(KeyboardInputLanguage.chinese)
                    }.accessibilityIdentifier("vime.settings.inputLanguage")
                } footer: {
                    Text("打开键盘时使用的语言；在键盘上，向上滑动语言键即可在日语和中文之间切换")
                }
            }
        }
        .appReadableList()
        .navigationTitle("输入法").navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ method: Method) -> some View {
        HStack(spacing: 12) {
            Text(method.glyph)
                .font(.body.weight(.semibold)).foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(method.title).foregroundStyle(Color.primary)
                Text(method.layout).font(.footnote).foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 8)
            if isOn(method) {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension KeyboardSettingsSummary {
    /// The input methods on, for the home page tile.
    var inputMethodsDetail: String {
        var names: [String] = []
        if japanese { names.append(kanaLayout ? String(localized: "假名九宫格") : String(localized: "罗马字")) }
        if chinese { names.append(String(localized: "全拼")) }
        return names.joined(separator: " · ")
    }
}
