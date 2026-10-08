import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct KeyboardSkinDocument: Codable, Identifiable, Equatable, Sendable {
    var format = "vime.skin.v1"
    var id = UUID().uuidString
    var name = "我的皮肤"
    var author = ""
    var palette = Palette()
    var style = Style()
    var backgroundImage: String?
    var keyImages: [String: String] = [:]
    // Codable embeds Data as base64: a single portable file, no paths or remote URLs.
    var images: [String: Data] = [:]
    struct Palette: Codable, Equatable, Sendable {
        var background = "#EEE5DB"
        var pattern = "#E3D6C8"
        var key = "#FFFAF5"
        var utility = "#E5D8CA"
        var text = "#513B25"
        var accent = "#2474F5"
        var pressed = "#DCCABA"
    }
    struct Style: Codable, Equatable, Sendable {
        var font = "system" // system / rounded / handwritten
        var pattern = "none" // none / diamonds
        var keyOpacity = 1.0
        var cornerRadius = 7.0
        var shadowOpacity = 0.18
    }
    static let maximumFileBytes = 8 * 1024 * 1024
    static let maximumImagePixels = 5_000_000

    func validate() throws {
        guard format == "vime.skin.v1", UUID(uuidString: id) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 60, author.count <= 100,
              ["system", "rounded", "handwritten"].contains(style.font),
              ["none", "diamonds"].contains(style.pattern),
              style.keyOpacity.isFinite, (0...1).contains(style.keyOpacity),
              style.cornerRadius.isFinite, (0...24).contains(style.cornerRadius),
              style.shadowOpacity.isFinite, (0...0.5).contains(style.shadowOpacity),
              images.count <= 40, keyImages.count <= 64 else { throw SkinError.invalid }
        for value in [palette.background, palette.pattern, palette.key, palette.utility,
                      palette.text, palette.accent, palette.pressed] {
            guard Self.isColor(value) else { throw SkinError.invalid }
        }
        var pixels = 0
        for (name, data) in images {
            guard !name.isEmpty, name.count <= 64, !data.isEmpty,
                  data.count <= 2 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 2048, height <= 2048 else { throw SkinError.image }
            pixels += width * height
            guard pixels <= Self.maximumImagePixels else { throw SkinError.image }
        }
        for value in Array(keyImages.values) + [backgroundImage].compactMap({ $0 }) {
            guard images[value] != nil else { throw SkinError.image }
        }
    }
    static func isColor(_ text: String) -> Bool {
        text.count == 7 && text.first == "#" && text.dropFirst().allSatisfy { "0123456789ABCDEFabcdef".contains($0) }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileBytes else { throw SkinError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileBytes else { throw SkinError.tooLarge }
        return data
    }
    enum SkinError: LocalizedError {
        case invalid, image, tooLarge, full
        var errorDescription: String? {
            switch self {
            case .invalid: "皮肤格式或颜色无效，请使用 Vime 导出的皮肤文件。"
            case .image: "图片无效或过大。仅支持 PNG/JPEG，总像素不超过 500 万。"
            case .tooLarge: "皮肤文件不能超过 8 MB。"
            case .full: "最多保留 30 个自定义皮肤，请先删除不需要的皮肤。"
            }
        }
    }
}

@MainActor
final class KeyboardSkinStore {
    struct Summary: Codable, Identifiable { let id: String; let name: String }
    let directory: URL
    init(directory: URL? = nil) {
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? root.appendingPathComponent("Vime/Skins", isDirectory: true)
    }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    func summaries() -> [Summary] {
        guard let data = try? Data(contentsOf: indexURL), data.count < 32 * 1024,
              let values = try? JSONDecoder().decode([Summary].self, from: data) else { return [] }
        return Array(values.filter { UUID(uuidString: $0.id) != nil && $0.name.count <= 60 }.prefix(30))
    }
    private func file(_ id: String) -> URL? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return directory.appendingPathComponent(uuid.uuidString + ".vimeskin")
    }
    func load(_ id: String) throws -> KeyboardSkinDocument {
        guard let file = file(id) else { throw KeyboardSkinDocument.SkinError.invalid }
        // Check file size before base64 decoding an externally imported document.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: KeyboardSkinDocument.maximumFileBytes + 1) ?? Data()
        return try KeyboardSkinDocument.decode(data)
    }
    func save(_ document: KeyboardSkinDocument) throws {
        let data = try document.encoded()
        guard let file = file(document.id) else { throw KeyboardSkinDocument.SkinError.invalid }
        var index = summaries()
        guard index.count < 30 || index.contains(where: { $0.id == document.id }) else {
            throw KeyboardSkinDocument.SkinError.full
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        index.removeAll { $0.id == document.id }
        index.append(Summary(id: document.id, name: document.name))
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        let preferences = KeyboardPreferences()
        if preferences.customSkinID == document.id { preferences.skinRevision += 1 }
    }
    @discardableResult
    func importFile(_ url: URL) throws -> KeyboardSkinDocument {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: KeyboardSkinDocument.maximumFileBytes + 1) ?? Data()
        var document = try KeyboardSkinDocument.decode(data)
        document.id = UUID().uuidString // Never trust an imported ID as a file path or overwrite target.
        try save(document)
        return document
    }
    func select(_ document: KeyboardSkinDocument) {
        let preferences = KeyboardPreferences()
        preferences.customSkinID = document.id
        preferences.skinRevision += 1
        preferences.theme = .custom
    }
    func remove(_ id: String) throws {
        guard let file = file(id) else { throw KeyboardSkinDocument.SkinError.invalid }
        try FileManager.default.removeItem(at: file)
        try JSONEncoder().encode(summaries().filter { $0.id != id }).write(to: indexURL, options: .atomic)
        let preferences = KeyboardPreferences()
        if preferences.customSkinID == id {
            preferences.customSkinID = ""; preferences.theme = .system; preferences.skinRevision += 1
        }
    }
}

@MainActor
final class KeyboardSkinAppearance {
    let document: KeyboardSkinDocument
    private let images: [String: UIImage]
    init(_ document: KeyboardSkinDocument) {
        self.document = document
        let referenced = Set(document.keyImages.values).union([document.backgroundImage].compactMap { $0 })
        let keyLimit = referenced.count > 16 ? 128 : 256
        let wideArtwork = document.keyImages["space"]
        images = Dictionary(uniqueKeysWithValues: document.images.compactMap { id, data -> (String, UIImage)? in
            guard referenced.contains(id), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: id == document.backgroundImage ? 1024 : id == wideArtwork ? 512 : keyLimit,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return (id, UIImage(cgImage: image))
        })
    }
    var backgroundImage: UIImage? { document.backgroundImage.flatMap { images[$0] } }
    func image(for key: String) -> UIImage? { document.keyImages[key].flatMap { images[$0] } }
    static func color(_ hex: String) -> UIColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    func font(size: CGFloat) -> UIFont {
        switch document.style.font {
        case "handwritten": UIFont(name: "Noteworthy-Light", size: size) ?? .systemFont(ofSize: size)
        case "rounded": UIFont(descriptor: UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded)
            ?? UIFont.systemFont(ofSize: size).fontDescriptor, size: size)
        default: .systemFont(ofSize: size)
        }
    }
}

/// Decorative canvas only. It never participates in hit testing or key ownership.
final class KeyboardSkinCanvas: UIView {
    var appearance: KeyboardSkinAppearance? { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false; isOpaque = false }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let appearance, let context = UIGraphicsGetCurrentContext() else { return }
        let doc = appearance.document
        KeyboardSkinAppearance.color(doc.palette.background).setFill(); context.fill(bounds)
        if doc.style.pattern == "diamonds" {
            KeyboardSkinAppearance.color(doc.palette.pattern).setFill()
            let width: CGFloat = 58, height: CGFloat = 108
            for row in -1...Int(bounds.height / height) + 1 {
                for column in -1...Int(bounds.width / width) + 1 {
                    let x = CGFloat(column) * width, y = CGFloat(row) * height
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: x + width / 2, y: y))
                    path.addLine(to: CGPoint(x: x + width, y: y + height / 2))
                    path.addLine(to: CGPoint(x: x + width / 2, y: y + height))
                    path.addLine(to: CGPoint(x: x, y: y + height / 2)); path.close(); path.fill()
                }
            }
        }
        if let image = appearance.backgroundImage {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height))
        }
    }
}
