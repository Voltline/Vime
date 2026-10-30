import SwiftUI
import UniformTypeIdentifiers

private struct UserDictionaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct KeyboardUserDictionaryView: View {
    private let store = JapaneseUserDictionaryStore()
    @State private var entries: [JapaneseUserDictionaryEntry] = []
    @State private var search = ""
    @State private var editing: JapaneseUserDictionaryEntry?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = UserDictionaryDocument()
    @State private var errorMessage: String?
    @AppStorage private var textReplacements: Bool

    init() {
        let preferences = KeyboardPreferences()
        _textReplacements = AppStorage(wrappedValue: preferences.textReplacements, "vime.textReplacements", store: preferences.store)
    }
    private var visibleEntries: [JapaneseUserDictionaryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let readingQuery = RomajiConverter.katakana(query)
        return entries.filter { query.isEmpty || $0.surface.localizedCaseInsensitiveContains(query)
            || $0.reading.localizedCaseInsensitiveContains(readingQuery) }
    }

    var body: some View {
        List {
            Section {
                if visibleEntries.isEmpty {
                    ContentUnavailableView(entries.isEmpty ? "添加你的常用词" : "没有匹配的词条",
                        systemImage: "character.book.closed",
                        description: Text(entries.isEmpty ? "点右上角 +，记下姓名、专业词或常用短语。" : "试试其他词语或读音。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(visibleEntries) { entry in
                    Button { editing = entry } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.surface).foregroundStyle(.primary)
                            Text((entry.reading.applyingTransform(.hiraganaToKatakana, reverse: true) ?? entry.reading)
                                + (entry.kind == .shortcut ? String(localized: " · 短语快捷输入") : String(localized: " · 词语")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onDelete { offsets in
                    let ids = Set(offsets.map { visibleEntries[$0].id })
                    let values = entries.filter { !ids.contains($0.id) }
                    perform { try store.save(values); entries = values }
                }
            }
            Section {
                Button("导入词典", systemImage: "square.and.arrow.down") { importing = true }
                Button("导出词典", systemImage: "square.and.arrow.up") { perform { exportDocument = UserDictionaryDocument(data: try store.exportData()); exporting = true } }
            } footer: { Text("词典只保存在本机。导入会与已有词条合并。") }
            Section {
                Toggle("使用 iOS 文本替换", isOn: $textReplacements).accessibilityIdentifier("vime.settings.textReplacements")
            } footer: {
                Text("在“设置 > 通用 > 键盘 > 文本替换”中添加的短语会出现在候选中：假名输入码在日语转换时出现，英文输入码在英文输入时出现。系统短语只在键盘中读取，不会保存到 Vime 词典。")
            }
            Section {
                DisclosureGroup("词典使用说明") {
                    Text("词语可参与分段转换和预测；短语仅在完整读音匹配时出现。\n\n读音支持假名或完整罗马字。开启键盘完全访问后，词典会共享到其他 App；重新打开键盘或继续输入即可读取更新。\n\n导入与导出使用 JSON 文件，最多保留 1,024 条。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
        }
        .listStyle(.insetGrouped)
        .appReadableList()
        .navigationTitle("用户词典").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索词语或读音")
        .toolbar { ToolbarItem(placement: .primaryAction) {
            Button { editing = .init(reading: "", surface: "") } label: { Image(systemName: "plus") }.accessibilityLabel("添加词条")
        } }
        .onAppear { perform { entries = try store.entries() } }
        .sheet(item: $editing) { entry in
            UserDictionaryEntryEditor(entry: entry) { value in
                var values = entries
                if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
                else { values.append(value) }
                try store.save(values); entries = try store.entries()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            perform {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: JapaneseUserDictionaryStore.maximumBytes + 1) ?? Data()
                try store.importData(data); entries = try store.entries()
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "VimeUserDictionary") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("词典操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }
}

private struct UserDictionaryEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: JapaneseUserDictionaryEntry
    let save: (JapaneseUserDictionaryEntry) throws -> Void
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("读音，例如 とうきょう / toukyou", text: $entry.reading)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("词语或短语", text: $entry.surface)
                    Picker("类型", selection: $entry.kind) {
                        Text("词语").tag(JapaneseUserDictionaryEntry.Kind.word)
                        Text("短语快捷输入").tag(JapaneseUserDictionaryEntry.Kind.shortcut)
                    }
                } footer: {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("词条")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { do { try save(entry); dismiss() } catch { errorMessage = error.localizedDescription } }
                }
            }
        }
    }
}
