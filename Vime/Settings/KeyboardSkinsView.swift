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
    @EnvironmentObject private var router: AppRouter
    @Environment(\.colorScheme) private var colorScheme
    @State private var skins: [KeyboardSkinStore.Summary] = []
    @State private var selectedID = KeyboardPreferences().customSkinID
    @State private var previewDocument: KeyboardSkinDocument?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportFile: KeyboardSkinFile?
    @State private var error: String?
    @State private var deleting: KeyboardSkinStore.Summary?
    @AppStorage("vime.theme", store: KeyboardPreferences().store) private var theme: KeyboardTheme = .system
    private let store = KeyboardSkinStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                currentSkinSection
                builtInSection
                customSkinSection
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("布局")
                    HStack(spacing: 12) {
                        Button("键盘高度", systemImage: "arrow.up.and.down") { router.present(.height) }
                        NavigationLink { KeyboardFeedbackSettingsView() } label: { Label("输入布局", systemImage: "keyboard") }
                    }
                    .buttonStyle(SkinActionButtonStyle())
                }
            }
            .frame(maxWidth: 740, alignment: .leading)
            .padding(20).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .disabled(router.importing)
        .navigationTitle("定制")
        .onAppear(perform: reload)
        .onChange(of: router.skinRevision) { reload() }
        .onChange(of: theme) { reload() }
        .onChange(of: colorScheme) { reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.vimeSkin, .json], onCompletion: router.finishFilePicker)
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .vimeSkin,
                      defaultFilename: exportFile?.document.name ?? "Vime皮肤") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
            router.finishExport()
        }
        .alert("皮肤操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("删除这个皮肤？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let deleting { perform { try store.remove(deleting.id); reload() } }; deleting = nil }
        }
    }
    private var currentSkinSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前皮肤").font(.caption).foregroundStyle(.secondary)
                    Text(currentName).font(.headline)
                        .accessibilityIdentifier("vime.skin.currentName")
                }
                Spacer()
                Text("使用中").font(.caption.weight(.medium)).foregroundStyle(.tint)
            }
            if let previewDocument {
                SkinPreview(document: previewDocument).frame(height: 155)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("当前皮肤预览")
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("内置皮肤")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                ForEach(KeyboardTheme.allCases.filter { $0 != .custom }, id: \.self) { item in
                    Button { theme = item; reload() } label: {
                        VStack(spacing: 12) {
                            SkinColorPreview(palette: builtInDocument(item).palette).frame(height: 68)
                            HStack {
                                Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                Spacer()
                                selectionMark(theme == item)
                            }
                        }
                        .padding(12).skinCard(selected: theme == item)
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("vime.skin.builtin." + item.rawValue)
                    .accessibilityLabel(item.title)
                    .accessibilityValue(theme == item ? "当前使用" : "")
                }
            }
        }
    }
    private var customSkinSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("我的皮肤")
            HStack(spacing: 12) {
                Button("创建皮肤", systemImage: "plus") { router.present(.skin(KeyboardSkinDocument())) }
                Button("导入皮肤", systemImage: "square.and.arrow.down") {
                    router.beginFilePicker(); importing = true
                }
            }.buttonStyle(SkinActionButtonStyle())
            ForEach(skins) { customSkinRow($0) }
            if skins.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "paintpalette").font(.title3)
                    Text("创建或导入自己的皮肤").font(.subheadline)
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            if router.importing { ProgressView("正在导入") }
            Text("支持 .vimeskin 文件，可从文件 App 打开\n选中皮肤即可使用，修改后重新打开键盘")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
        }
    }
    private func customSkinRow(_ skin: KeyboardSkinStore.Summary) -> some View {
        HStack {
            Button { perform {
                let document = try store.load(skin.id)
                store.select(document)
                // The preference observer may arrive on a later run loop
                // Update the visible selection and preview in this action
                theme = .custom; selectedID = document.id; previewDocument = document
            } } label: {
                HStack {
                    Image(systemName: "paintpalette")
                        .foregroundStyle(.tint).frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    Text(skin.name).foregroundStyle(.primary)
                    Spacer()
                    selectionMark(selectedID == skin.id && theme == .custom)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("vime.skin.custom." + skin.id)
            .accessibilityLabel(skin.name)
            .accessibilityValue(selectedID == skin.id && theme == .custom ? "当前使用" : "")
            Menu {
                Button("编辑") { perform { router.present(.skin(try store.load(skin.id))) } }
                Button("导出") { perform {
                    exportFile = KeyboardSkinFile(try store.load(skin.id)); router.beginFilePicker(); exporting = true
                } }
                Button("删除", role: .destructive) { deleting = skin }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
            .buttonStyle(.plain)
            .accessibilityLabel("\(skin.name)的操作")
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
        .skinCard(selected: selectedID == skin.id && theme == .custom)
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline)
    }
    private func selectionMark(_ selected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold)).foregroundStyle(.tint)
            .frame(width: 24).opacity(selected ? 1 : 0)
            .accessibilityHidden(true)
    }
    private var currentName: String {
        theme == .custom ? skins.first { $0.id == selectedID }?.name ?? "自定义" : theme.title
    }
    private func reload() {
        skins = store.summaries(); selectedID = KeyboardPreferences().customSkinID
        if theme == .custom, let document = try? store.load(selectedID) { previewDocument = document; return }
        previewDocument = builtInDocument(theme)
    }
    private func builtInDocument(_ item: KeyboardTheme) -> KeyboardSkinDocument {
        var document = KeyboardSkinDocument(); document.name = item.title
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        func hex(_ color: UIColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
        document.palette.background = hex(item == .system ? .systemGray5 : item.background)
        document.palette.key = hex(item.key); document.palette.text = hex(item.text)
        document.palette.utility = hex(item.utility); document.palette.accent = hex(item.accent)
        return document
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
}

private extension View {
    func skinCard(selected: Bool) -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}

private struct SkinActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Lightweight palette thumbnails, without decoding custom artwork for every card
private struct SkinColorPreview: View {
    let palette: KeyboardSkinDocument.Palette
    var body: some View {
        VStack(spacing: 3) {
            ForEach([10, 9, 7], id: \.self) { count in
                HStack(spacing: 3) {
                    ForEach(0..<count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: KeyboardSkinAppearance.color(palette.key)))
                    }
                }.padding(.horizontal, CGFloat(10 - count) * 4)
            }
        }
        .padding(7)
        .background(Color(uiColor: KeyboardSkinAppearance.color(palette.background)), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

struct KeyboardSkinEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: KeyboardSkinDocument
    @State private var photo: PhotosPickerItem?
    @State private var imageTarget = "background"
    @State private var error: String?
    @State private var importingPhoto = false
    @State private var photoGeneration = 0
    @State private var advancedImages = false
    private let store: KeyboardSkinStore
    init(document: KeyboardSkinDocument, store: KeyboardSkinStore) {
        _draft = State(initialValue: document); self.store = store
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SkinPreview(document: draft).frame(height: 205).padding(.horizontal, 16)
                Form {
                    Section("皮肤信息") {
                        TextField("名称", text: $draft.name).accessibilityIdentifier("vime.skin.name")
                        TextField("作者（可选）", text: $draft.author)
                    }
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
                        Toggle("逐字母图片", isOn: $advancedImages)
                            .onChange(of: advancedImages) { if !advancedImages && imageTarget.hasPrefix("letter.") { imageTarget = "letter" } }
                        Picker("图片位置", selection: $imageTarget) {
                            Text("背景").tag("background"); Text("所有字母").tag("letter")
                            Text("左上角设置").tag("brand")
                            Text("空格").tag("space"); Text("退格").tag("backspace")
                            Text("回车").tag("return"); Text("Shift").tag("shift")
                            Text("表情").tag("emoji"); Text("数字切换").tag("numbers")
                            if advancedImages { ForEach(Array("abcdefghijklmnopqrstuvwxyz").map(String.init), id: \.self) { Text("字母 \($0.uppercased())").tag("letter." + $0) } }
                        }
                        PhotosPicker("从照片选择图片", selection: $photo, matching: .images)
                            .disabled(importingPhoto)
                        Button("移除当前位置图片", role: .destructive) {
                            if imageTarget == "background" { draft.backgroundImage = nil }
                            else { draft.keyImages.removeValue(forKey: imageTarget) }
                            pruneImages()
                        }
                    } header: { Text("背景和按键图片") } footer: {
                        Text("单独字母图片优先于所有字母\n背景会裁切填满键盘，透明 PNG 适合按键贴图\n保存后在定制页选中皮肤即可使用")
                    }
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
            .interactiveDismissDisabled()
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
            let rowHeight = max(1, (bounds.height - 12) / 3)
            var index = 0
            for (row, count) in [10, 9, 7].enumerated() {
                let width = (bounds.width - 12) / 10
                let offset = (bounds.width - CGFloat(count) * width) / 2
                for column in 0..<count {
                    let rect = CGRect(x: offset + CGFloat(column) * width, y: 6 + CGFloat(row) * rowHeight, width: width - 3, height: max(1, rowHeight - 6))
                    let decorated = pictures[index].image != nil
                    let captionHeight = min(22, rect.height * 0.38)
                    if let appearance = canvas.appearance {
                        keys[index].font = appearance.font(size: max(9, 16 * min(1, rowHeight / 65)))
                    }
                    keys[index].frame = decorated ? CGRect(x: rect.minX, y: rect.maxY - captionHeight, width: rect.width, height: captionHeight) : rect
                    pictures[index].frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, rect.height - captionHeight - 2))
                    index += 1
                }
            }
        }
    }
    func makeUIView(context: Context) -> Preview { Preview() }
    func updateUIView(_ uiView: Preview, context: Context) { uiView.apply(document) }
}
