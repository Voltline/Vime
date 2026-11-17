import SwiftUI
import UniformTypeIdentifiers

/// The user's own pinyin phrases, and a way to what pinyin input learned.
struct ChineseUserDictionaryList: View {
    private let store = ChineseUserDictionaryStore()
    @State private var entries: [ChineseUserPhrase] = []
    let search: String
    let addRequest: Int
    @State private var editing: ChineseUserPhrase?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = UserDictionaryDocument()
    @State private var exportType = UTType.json
    @State private var importSummary: String?
    @State private var errorMessage: String?

    private var visibleEntries: [ChineseUserPhrase] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = query.lowercased().filter { ("a"..."z").contains($0) }
        return entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
            || (!letters.isEmpty && $0.pinyin.replacingOccurrences(of: " ", with: "").contains(letters)) }
    }

    var body: some View {
        List {
            Section {
                if visibleEntries.isEmpty {
                    ContentUnavailableView(entries.isEmpty ? "添加中文常用词" : "没有匹配的词条",
                        systemImage: "character.book.closed.zh",
                        description: Text(entries.isEmpty ? "点右上角 +，填写词语和拼音，打拼音时就会出现在候选里。" : "试试其他词语或拼音。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(visibleEntries) { entry in
                    Button { editing = entry } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text).foregroundStyle(.primary)
                            Text(entry.pinyin).font(.caption).foregroundStyle(.secondary)
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
                Menu("导出词典", systemImage: "square.and.arrow.up") {
                    Button("导出为 Vime JSON") { export(.json) { try store.exportData() } }
                    Button("导出为文本（词语 + Tab + 拼音）") { export(.plainText) { try store.exportText() } }
                }
            } footer: { Text("词典只保存在本机。导入会与已有词条合并，可读取 Vime JSON 和每行“词语 + Tab + 拼音”的文本。") }
            Section {
                NavigationLink { ChineseLearnedWordsView() } label: {
                    Label("学到的词", systemImage: "brain")
                }.accessibilityIdentifier("vime.dictionary.learned")
            } footer: { Text("拼音输入从你的选择中学到的词语，可以逐条删除，或导出、导入 Rime 用户词典文本。") }
            Section {
                DisclosureGroup("词典使用说明") {
                    Text("整段拼音与词条的完整拼音，或两个以上音节的首字母一致时，词条排在候选第一位，例如 weimai 或 wm。\n\n开启键盘完全访问后，词典会共享到其他 App；重新打开键盘或继续输入即可读取更新。最多保留 1,024 条。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
        }
        .listStyle(.insetGrouped)
        .appReadableList()
        .onChange(of: addRequest) { editing = .init(pinyin: "", text: "") }
        .onAppear { perform { entries = try store.entries() } }
        .sheet(item: $editing) { entry in
            ChinesePhraseEditor(entry: entry) { value in
                var values = entries
                if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
                else { values.append(value) }
                try store.save(values); entries = try store.entries()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .text, .tabSeparatedText]) { result in
            perform {
                let data = try readImport(result, limit: ChineseUserDictionaryStore.maximumImportBytes)
                let result = try store.importFile(data); entries = try store.entries()
                importSummary = result.skipped == 0 ? String(localized: "已添加 \(result.added) 条。")
                    : String(localized: "已添加 \(result.added) 条，跳过 \(result.skipped) 条无法使用的词条。")
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: "VimeChineseDictionary") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("词典操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("导入完成", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("好", role: .cancel) { importSummary = nil }
        } message: { Text(importSummary ?? "") }
    }

    private func export(_ type: UTType, _ data: () throws -> Data) {
        perform { exportDocument = UserDictionaryDocument(data: try data()); exportType = type; exporting = true }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }
}

/// Reads a picked file, one byte past `limit` at most so the caller can refuse it.
func readImport(_ result: Result<URL, Error>, limit: Int) throws -> Data {
    let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    return try handle.read(upToCount: limit + 1) ?? Data()
}

private struct ChinesePhraseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: ChineseUserPhrase
    let save: (ChineseUserPhrase) throws -> Void
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("拼音，例如 wei mai / weimai", text: $entry.pinyin)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("词语或短语", text: $entry.text)
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

/// What pinyin input learned. Deleting and importing take effect the next
/// time the keyboard opens, which is when it merges the changes.
struct ChineseLearnedWordsView: View {
    private let learned = ChineseLearnedWords.shared()
    @State private var words: [ChineseLearnedWord] = []
    @State private var loading = true
    @State private var search = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = UserDictionaryDocument()
    @State private var importSummary: String?
    @State private var errorMessage: String?
    private var resetPending: Bool {
        let requests = KeyboardPreferences().learningResetRequests
        return requests.chinese.isPending || requests.isPending
    }

    private var visibleWords: [ChineseLearnedWord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = query.lowercased().filter { ("a"..."z").contains($0) }
        return words.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
            || (!letters.isEmpty && $0.pinyin.replacingOccurrences(of: " ", with: "").contains(letters)) }
    }

    var body: some View {
        List {
            Section {
                if !loading && visibleWords.isEmpty {
                    ContentUnavailableView(resetPending ? "等待清空" : words.isEmpty ? "还没有学到的词" : "没有匹配的词语",
                        systemImage: "brain",
                        description: Text(resetPending ? "下次打开键盘时清空中文学习记录。"
                            : words.isEmpty ? "用拼音输入选过的词语会出现在这里。" : "试试其他词语或拼音。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(visibleWords) { word in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(word.text)
                        Text(word.pinyin + String(localized: " · 选过 \(word.commits) 次")).font(.caption).foregroundStyle(.secondary)
                    }
                }.onDelete { offsets in
                    let removed = offsets.map { visibleWords[$0] }
                    perform {
                        try learned.delete(removed)
                        let ids = Set(removed.map(\.id)); words.removeAll { ids.contains($0.id) }
                    }
                }
            } footer: {
                if !words.isEmpty { Text("共 \(words.count) 个。删除和导入会在下次打开键盘时生效。") }
            }
            Section {
                Button("导入 Rime 用户词典", systemImage: "square.and.arrow.down") { importing = true }
                Button("导出 Rime 用户词典", systemImage: "square.and.arrow.up") {
                    perform { exportDocument = UserDictionaryDocument(data: try learned.exportText()); exporting = true }
                }.disabled(words.isEmpty)
            } footer: { Text("文本每行为“词语 + Tab + 拼音 + Tab + 次数”，与 Rime 的用户词典导出格式相同，可用于备份或在其他 Rime 输入法之间迁移。") }
        }
        .listStyle(.insetGrouped)
        .appReadableList()
        .navigationTitle("学到的词").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索词语或拼音")
        .overlay { if loading { ProgressView() } }
        .task { await reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.text, .tabSeparatedText]) { result in
            perform {
                let data = try readImport(result, limit: ChineseLearnedWords.maximumImportBytes)
                let result = try learned.importFile(data)
                importSummary = result.skipped == 0 ? String(localized: "已导入 \(result.added) 个词，下次打开键盘时生效。")
                    : String(localized: "已导入 \(result.added) 个词，跳过 \(result.skipped) 行无法使用的内容。下次打开键盘时生效。")
                Task { await reload() }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .plainText, defaultFilename: "VimeLearnedWords") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("词典操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("导入完成", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("好", role: .cancel) { importSummary = nil }
        } message: { Text(importSummary ?? "") }
    }

    private func reload() async {
        if resetPending { words = []; loading = false; return }
        let learned = learned
        let result = await Task.detached(priority: .userInitiated) { Result { try learned.words() } }.value
        loading = false
        switch result {
        case .success(let values): words = values
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }
}
