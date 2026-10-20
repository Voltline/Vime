import SwiftUI

struct KeyboardNumberSymbolsView: View {
    private let preferences: KeyboardPreferences
    @State private var symbols: [String]
    @State private var adding = false
    @State private var draft = ""
    @State private var confirmingReset = false
    @AppStorage private var autoPairBrackets: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(preferences: KeyboardPreferences = KeyboardPreferences()) {
        self.preferences = preferences
        _symbols = State(initialValue: preferences.numberSymbols)
        _autoPairBrackets = AppStorage(wrappedValue: preferences.autoPairBrackets, "vime.autoPairBrackets", store: preferences.store)
    }

    private var newSymbol: String? {
        guard let value = KeyboardNumberSymbols.normalized([draft]).first,
              !symbols.contains(value), symbols.count < KeyboardNumberSymbols.maximumCount else { return nil }
        return value
    }

    var body: some View {
        List {
            Section {
                Toggle("自动补全括号", isOn: $autoPairBrackets)
                    .accessibilityIdentifier("vime.settings.autoPairBrackets")
            } footer: {
                Text("输入左括号时补上右括号，光标移到中间；支持 ()、（）、「」等括号。剪贴板粘贴保持原样。")
            }
            Section {
                ForEach(symbols, id: \.self) { symbol in
                    Text(symbol).font(.title3).accessibilityIdentifier("vime.numberSymbols.item." + symbol)
                }
                .onDelete { symbols.remove(atOffsets: $0) }
                .onMove { symbols.move(fromOffsets: $0, toOffset: $1) }
            } header: { Text("数字键盘左侧栏") } footer: {
                Text("上下滑动左侧栏使用这些符号。可以删除或拖动排序，最多保留 32 项，每项最多 4 个字符。修改后重新打开键盘即可生效。")
            }
            Section {
                Button("恢复默认", role: .destructive) { confirmingReset = true }
                    .accessibilityIdentifier("vime.numberSymbols.reset")
            }
        }
        .navigationTitle("符号与括号").navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton().accessibilityIdentifier("vime.numberSymbols.reorder")
                Button("添加符号", systemImage: "plus") { draft = ""; adding = true }
                    .labelStyle(.iconOnly)
                    .disabled(symbols.count >= KeyboardNumberSymbols.maximumCount)
                    .accessibilityIdentifier("vime.numberSymbols.add")
            }
        }
        .onChange(of: symbols) { _, value in preferences.numberSymbols = value }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { symbols = preferences.numberSymbols }
        }
        .alert("添加符号", isPresented: $adding) {
            TextField("例如：%、¥、()", text: $draft).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("vime.numberSymbols.text")
            Button("取消", role: .cancel) { }
            Button("添加") { if let newSymbol { symbols.append(newSymbol) } }.disabled(newSymbol == nil)
        } message: { Text("输入 1–4 个字符，已有的内容无需重复添加。") }
        .confirmationDialog("恢复默认的常用符号和排列顺序？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { symbols = KeyboardNumberSymbols.defaults }
        }
    }
}
