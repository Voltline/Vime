import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

extension UTType {
    static let vimeSkin = UTType(exportedAs: "com.voltline.vime.skin", conformingTo: .json)
}

struct KeyboardSkinFile: FileDocument {
    static var readableContentTypes: [UTType] { [.vimeSkin, .json] }
    var document: KeyboardSkinDocument
    init(_ document: KeyboardSkinDocument) { self.document = document }
    init(configuration: ReadConfiguration) throws {
        document = try KeyboardSkinDocument.decode(configuration.file.regularFileContents ?? Data())
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try document.encoded())
    }
}

struct KeyboardSkinsView: View {
    var initialURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var skins: [KeyboardSkinStore.Summary] = []
    @State private var selectedID = KeyboardPreferences().customSkinID
    @State private var editing: KeyboardSkinDocument?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportFile: KeyboardSkinFile?
    @State private var error: String?
    @State private var deleting: KeyboardSkinStore.Summary?
    private let store = KeyboardSkinStore()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("创建皮肤", systemImage: "paintpalette") { editing = KeyboardSkinDocument() }
                    Button("导入皮肤文件", systemImage: "square.and.arrow.down") { importing = true }
                } footer: {
                    Text("支持 .vimeskin 文件，也可从「文件」App 分享到 Vime。配色、背景和按键图片随文件一起导入。")
                }
                Section("我的皮肤") {
                    ForEach(skins) { skin in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skin.name)
                                if selectedID == skin.id && KeyboardPreferences().theme == .custom {
                                    Text("当前使用").font(.caption).foregroundStyle(.blue)
                                }
                            }
                            Spacer()
                            Menu {
                                Button("使用") { perform { store.select(try store.load(skin.id)); reload() } }
                                Button("编辑") { perform { editing = try store.load(skin.id) } }
                                Button("导出") { perform { exportFile = KeyboardSkinFile(try store.load(skin.id)); exporting = true } }
                                Button("删除", role: .destructive) { deleting = skin }
                            } label: { Image(systemName: "ellipsis.circle").padding(8) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { perform { store.select(try store.load(skin.id)); reload() } }
                    }
                    if skins.isEmpty { Text("创建或导入第一款皮肤").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("我的皮肤")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                reload()
                if let initialURL { importSkin(initialURL) }
            }
            .sheet(item: $editing, onDismiss: reload) { document in
                KeyboardSkinEditor(document: document, store: store)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.vimeSkin, .json]) { result in
                switch result { case .success(let url): importSkin(url); case .failure(let failure): error = failure.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: .vimeSkin,
                          defaultFilename: exportFile?.document.name ?? "Vime皮肤") { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }
            }
            .alert("无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .confirmationDialog("删除这个皮肤？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) { if let deleting { perform { try store.remove(deleting.id); reload() } }; deleting = nil }
            }
        }
    }
    private func reload() { skins = store.summaries(); selectedID = KeyboardPreferences().customSkinID }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    private func importSkin(_ url: URL) { perform { editing = try store.importFile(url); reload() } }
}

struct KeyboardSkinEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: KeyboardSkinDocument
    @State private var photo: PhotosPickerItem?
    @State private var imageTarget = "background"
    @State private var error: String?
    @State private var importingPhoto = false
    @State private var photoGeneration = 0
    private let store: KeyboardSkinStore
    init(document: KeyboardSkinDocument, store: KeyboardSkinStore) {
        _draft = State(initialValue: document); self.store = store
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { SkinPreview(document: draft).frame(height: 210).listRowInsets(EdgeInsets()) }
                Section("皮肤信息") { TextField("名称", text: $draft.name); TextField("作者（可选）", text: $draft.author) }
                Section("配色") {
                    colorPicker("背景", \KeyboardSkinDocument.Palette.background)
                    colorPicker("菱格", \KeyboardSkinDocument.Palette.pattern)
                    colorPicker("普通按键", \KeyboardSkinDocument.Palette.key)
                    colorPicker("功能按键", \KeyboardSkinDocument.Palette.utility)
                    colorPicker("文字", \KeyboardSkinDocument.Palette.text)
                    colorPicker("强调色", \KeyboardSkinDocument.Palette.accent)
                    colorPicker("按下颜色", \KeyboardSkinDocument.Palette.pressed)
                }
                Section("样式") {
                    Picker("字体", selection: $draft.style.font) {
                        Text("系统").tag("system"); Text("圆体").tag("rounded"); Text("手写").tag("handwritten")
                    }
                    Picker("背景图案", selection: $draft.style.pattern) {
                        Text("纯色").tag("none"); Text("菱格").tag("diamonds")
                    }
                    slider("键帽不透明度", value: $draft.style.keyOpacity, range: 0...1)
                    slider("键帽圆角", value: $draft.style.cornerRadius, range: 0...24)
                    slider("阴影", value: $draft.style.shadowOpacity, range: 0...0.5)
                }
                Section {
                    Picker("图片位置", selection: $imageTarget) {
                        Text("背景").tag("background"); Text("所有字母").tag("letter")
                        Text("左上角设置").tag("brand")
                        Text("空格").tag("space"); Text("退格").tag("backspace")
                        Text("回车").tag("return"); Text("Shift").tag("shift")
                        Text("表情").tag("emoji"); Text("数字切换").tag("numbers")
                        ForEach(Array("abcdefghijklmnopqrstuvwxyz").map(String.init), id: \.self) { Text("字母 \($0.uppercased())").tag("letter." + $0) }
                    }
                    PhotosPicker("从照片选择图片", selection: $photo, matching: .images)
                        .disabled(importingPhoto)
                    Button("移除当前位置图片", role: .destructive) {
                        if imageTarget == "background" { draft.backgroundImage = nil }
                        else { draft.keyImages.removeValue(forKey: imageTarget) }
                        pruneImages()
                    }
                } header: { Text("背景和按键图片") } footer: {
                    Text("单独字母图片优先于「所有字母」。图片保持比例，背景会裁切填满键盘；透明 PNG 适合按键贴图。导入后在菜单中点「使用」即可应用。")
                }
            }
            .navigationTitle("编辑皮肤").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { do { try store.save(draft); dismiss() } catch { self.error = error.localizedDescription } }
                        .disabled(importingPhoto)
                }
            }
            .task(id: photo) { await loadPhoto() }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func colorPicker(_ title: String, _ path: WritableKeyPath<KeyboardSkinDocument.Palette, String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(uiColor: KeyboardSkinAppearance.color(draft.palette[keyPath: path])) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            draft.palette[keyPath: path] = String(format: "#%02X%02X%02X", Int((min(1, max(0, r)) * 255).rounded()), Int((min(1, max(0, g)) * 255).rounded()), Int((min(1, max(0, b)) * 255).rounded()))
        }), supportsOpacity: false)
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) { Text(title); Slider(value: value, in: range) }
    }
    private func pruneImages() {
        let used = Set(draft.keyImages.values).union([draft.backgroundImage].compactMap { $0 })
        draft.images = draft.images.filter { used.contains($0.key) }
    }
    private func loadPhoto() async {
        guard let photo else { return }
        let target = imageTarget
        photoGeneration += 1
        let generation = photoGeneration
        importingPhoto = true
        defer { if generation == photoGeneration { importingPhoto = false } }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw KeyboardSkinDocument.SkinError.image }
            let resized = try await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024
                      ] as CFDictionary) else { throw KeyboardSkinDocument.SkinError.image }
                let bytes = NSMutableData()
                let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
                let type = opaque ? UTType.jpeg : UTType.png
                guard let output = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil) else { throw KeyboardSkinDocument.SkinError.image }
                CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                guard CGImageDestinationFinalize(output) else { throw KeyboardSkinDocument.SkinError.image }
                return bytes as Data
            }.value
            guard !Task.isCancelled, generation == photoGeneration else { return }
            let id = "photo-" + UUID().uuidString
            var updated = draft
            updated.images[id] = resized
            if target == "background" { updated.backgroundImage = id } else { updated.keyImages[target] = id }
            let used = Set(updated.keyImages.values).union([updated.backgroundImage].compactMap { $0 })
            updated.images = updated.images.filter { used.contains($0.key) }
            try updated.validate(); draft = updated
        } catch { if !Task.isCancelled, generation == photoGeneration { self.error = error.localizedDescription } }
    }
}

/// Preview caches decoded artwork when the draft changes, independently of the live keyboard palette.
private struct SkinPreview: UIViewRepresentable {
    let document: KeyboardSkinDocument
    final class Preview: UIView {
        let canvas = KeyboardSkinCanvas()
        let letters = Array("QWERTYUIOPASDFGHJKLZXCVBNM").map { String($0) }
        var keys: [KeyboardSkinCaption] = []
        var pictures: [UIImageView] = []
        var document: KeyboardSkinDocument?
        override init(frame: CGRect) {
            super.init(frame: frame); addSubview(canvas); clipsToBounds = true
            for text in letters {
                let image = UIImageView(); image.contentMode = .scaleAspectFit; addSubview(image); pictures.append(image)
                let label = KeyboardSkinCaption(); label.text = text; addSubview(label); keys.append(label)
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        func apply(_ doc: KeyboardSkinDocument) {
            guard document != doc else { return }; document = doc
            let appearance = KeyboardSkinAppearance(doc); canvas.appearance = appearance
            for (index, key) in keys.enumerated() {
                key.textColor = KeyboardSkinAppearance.color(doc.palette.text)
                key.font = appearance.font(size: 16)
                pictures[index].image = appearance.image(for: "letter." + letters[index].lowercased()) ?? appearance.image(for: "letter")
                key.backgroundColor = KeyboardSkinAppearance.color(doc.palette.key).withAlphaComponent(doc.style.keyOpacity)
                key.layer.cornerRadius = doc.style.cornerRadius; key.clipsToBounds = true
            }
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews(); canvas.frame = bounds
            var index = 0
            for (row, count) in [10, 9, 7].enumerated() {
                let width = (bounds.width - 12) / 10
                let offset = (bounds.width - CGFloat(count) * width) / 2
                for column in 0..<count {
                    let rect = CGRect(x: offset + CGFloat(column) * width, y: 6 + CGFloat(row) * 65, width: width - 3, height: 59)
                    let decorated = pictures[index].image != nil
                    keys[index].frame = decorated ? CGRect(x: rect.minX, y: rect.minY + 37, width: rect.width, height: 22) : rect
                    pictures[index].frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 35)
                    index += 1
                }
            }
        }
    }
    func makeUIView(context: Context) -> Preview { Preview() }
    func updateUIView(_ uiView: Preview, context: Context) { uiView.apply(document) }
}
