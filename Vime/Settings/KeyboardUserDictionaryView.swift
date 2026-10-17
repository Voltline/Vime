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
    private var visibleEntries: [JapaneseUserDictionaryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let readingQuery = RomajiConverter.katakana(query)
        return entries.filter { query.isEmpty || $0.surface.localizedCaseInsensitiveContains(query)
            || $0.reading.localizedCaseInsensitiveContains(readingQuery) }
    }

    var body: some View {
        List {
            Section {
                ForEach(visibleEntries) { entry in
                    Button { editing = entry } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.surface).foregroundStyle(.primary)
                            Text((entry.reading.applyingTransform(.hiraganaToKatakana, reverse: true) ?? entry.reading)
                                + (entry.kind == .shortcut ? " · 短语快捷输入" : " · 词语"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onDelete { offsets in
                    let ids = Set(offsets.map { visibleEntries[$0].id })
                    let values = entries.filter { !ids.contains($0.id) }
                    perform { try store.save(values); entries = values }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if entries.isEmpty { Text("词典为空，点击右上角 + 添加姓名、专业词或常用短语。") }
                    else if visibleEntries.isEmpty { Text("没有匹配的词条，请尝试其他词语或读音。") }
                    Text("词语可参与分段转换和预测；短语仅在完整读音匹配时出现\n读音支持假名或完整罗马字\n开启键盘完全访问后，词典会共享到其他 App；重新打开键盘或继续输入即可读取更新")
                }
            }
            Section {
                Button("导入词典 JSON") { importing = true }
                Button("导出词典 JSON") { perform { exportDocument = UserDictionaryDocument(data: try store.exportData()); exporting = true } }
            } footer: { Text("导入会与已有词条合并并去重，最多 1,024 条\n词典只保存在本机") }
        }
        .navigationTitle("用户词典")
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
