import SwiftUI
import UniformTypeIdentifiers

/// Learned Korean words stored locally in `KoreanPersonalLearningStore`.
/// Supports browsing by frequency, swipe-to-delete, clearing all, and exporting as `word\tcount` text.
struct KoreanLearnedWordsView: View {
    private let store: KoreanPersonalLearningStore
    @State private var words: [KoreanPersonalLearningStore.WordRecord] = []
    @State private var search = ""
    @State private var confirmClearAll = false
    @State private var exporting = false
    @State private var exportDocument = UserDictionaryDocument()
    @State private var errorMessage: String?

    init(store: KoreanPersonalLearningStore = .shared) {
        self.store = store
    }

    private var visibleWords: [KoreanPersonalLearningStore.WordRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return words }
        return words.filter { $0.surface.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                if visibleWords.isEmpty {
                    ContentUnavailableView(
                        words.isEmpty ? "还没有学到的词" : "没有匹配的词语",
                        systemImage: "brain",
                        description: Text(words.isEmpty ? "用韩语输入选过或提交的词语会出现在这里。" : "试试其他词语。")
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(visibleWords, id: \.surface) { word in
                    HStack {
                        Text(word.surface)
                        Spacer(minLength: 8)
                        Text(String(localized: "选过 \(word.count) 次"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let removed = offsets.map { visibleWords[$0].surface }
                    for surface in removed {
                        store.forgetAndPersist(word: surface)
                    }
                    words.removeAll { removed.contains($0.surface) }
                }
            } footer: {
                if !words.isEmpty {
                    Text("共 \(words.count) 个。删除后键盘会在下次输入时同步更新。")
                }
            }

            Section {
                Button("导出为文本", systemImage: "square.and.arrow.up") {
                    exportDocument = UserDictionaryDocument(data: store.exportText())
                    exporting = true
                }
                .disabled(words.isEmpty)
                .accessibilityIdentifier("vime.koreanLearned.export")

                Button("全部清空", systemImage: "trash", role: .destructive) {
                    confirmClearAll = true
                }
                .disabled(words.isEmpty)
                .accessibilityIdentifier("vime.koreanLearned.clearAll")
            } footer: {
                Text("文本每行为“词语 + Tab + 次数”，只保存在本机。")
            }
        }
        .listStyle(.insetGrouped)
        .appReadableList()
        .navigationTitle("韩语学到的词").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索韩语词语")
        .onAppear { reload() }
        .confirmationDialog("清空韩语学到的词？", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("全部清空", role: .destructive) {
                store.clearAllAndPersist()
                words = []
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空本机保存的所有韩语常用词和下一词联想记录，此操作无法撤销。")
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "VimeKoreanLearnedWords"
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() {
        words = store.allWords()
    }
}
