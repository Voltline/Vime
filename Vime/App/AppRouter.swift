import SwiftUI
import Combine

/// All temporary editors share one presenter; external files wait for drafts.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable { case typing, customize, settings }
    enum Sheet: Identifiable {
        case skin(KeyboardSkinDocument), height
        var id: String {
            switch self { case .skin(let doc): "skin-" + doc.id; case .height: "height" }
        }
    }
    @Published var tab: Tab = .typing
    @Published var sheet: Sheet?
    @Published private(set) var importing = false
    @Published private(set) var skinRevision = 0
    @Published var error: String?
    private var pendingFiles: [URL] = []
    private var sheetPresented = false
    private var filePickerPresented = false
    private let store: KeyboardSkinStore
    init(store: KeyboardSkinStore? = nil) { self.store = store ?? KeyboardSkinStore() }

    func present(_ sheet: Sheet) {
        guard !sheetPresented, !importing, !filePickerPresented else { return }
        sheetPresented = true; self.sheet = sheet
    }
    func sheetDismissed() {
        sheetPresented = false; skinRevision += 1
        processPendingFiles()
    }
    func beginFilePicker() { filePickerPresented = true }
    func finishFilePicker(_ result: Result<URL, Error>) {
        filePickerPresented = false
        switch result {
        case .success(let url): pendingFiles.append(url)
        case .failure(let failure):
            // Cancelling the system picker is not an import error.
            if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
        }
        processPendingFiles()
    }
    func finishExport() { filePickerPresented = false; processPendingFiles() }
    func openSkin(_ url: URL) {
        guard url.isFileURL else { return }
        pendingFiles.append(url)
        processPendingFiles()
    }
    private func processPendingFiles() {
        guard error == nil, !sheetPresented, !filePickerPresented, !importing, !pendingFiles.isEmpty else { return }
        let url = pendingFiles.removeFirst()
        importing = true
        Task {
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    var document = try KeyboardSkinDocument.read(from: url)
                    // Imported files never overwrite an existing skin by ID.
                    document.id = UUID().uuidString
                    return document
                }.value
                // Save only after validation; a failed import leaves the selection intact.
                try store.save(document)
                importing = false; skinRevision += 1; tab = .customize
                present(.skin(document))
            } catch {
                importing = false; self.error = error.localizedDescription
                // Keep subsequent files queued until the error is acknowledged.
            }
        }
    }
    func acknowledgeError() { error = nil; processPendingFiles() }
}
