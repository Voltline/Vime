import XCTest
import UIKit

@MainActor
final class KeyboardSkinTests: XCTestCase {
    func testPortableSkinImportRoundTripAndValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeyboardSkinStore(directory: directory)
        var document = KeyboardSkinDocument(); document.name = "菱格测试"; document.style.pattern = "diamonds"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { ctx in
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        document.images["badge"] = try XCTUnwrap(image.pngData()); document.keyImages["letter.a"] = "badge"
        try store.save(document)
        XCTAssertEqual(try store.load(document.id), document)
        let file = directory.appendingPathComponent("external.vimeskin"); try document.encoded().write(to: file)
        let imported = try store.importFile(file)
        XCTAssertNotEqual(imported.id, document.id)
        XCTAssertEqual(imported.images, document.images)
        XCTAssertEqual(store.summaries().count, 2)
        var invalid = document; invalid.id = "../escape"; XCTAssertThrowsError(try store.save(invalid))
        invalid = document; invalid.keyImages["space"] = "missing"; XCTAssertThrowsError(try invalid.encoded())
        invalid = document; invalid.palette.text = "red"; XCTAssertThrowsError(try invalid.encoded())
        invalid = document; invalid.images["badge"] = Data("invalid".utf8); XCTAssertThrowsError(try invalid.encoded())
        XCTAssertThrowsError(try KeyboardSkinDocument.decode(Data(count: KeyboardSkinDocument.maximumFileBytes + 1)))
    }

    func testArtworkPreservesKeyTouchOwnershipAndActions() throws {
        let key = KeyboardKey(title: "A"); key.accessibilityIdentifier = "vime.key.a"
        key.frame = CGRect(x: 0, y: 0, width: 40, height: 56)
        key.touchBounds = CGRect(x: -4, y: -5, width: 48, height: 66)
        var document = KeyboardSkinDocument()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { ctx in
            UIColor.brown.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        document.images["art"] = try XCTUnwrap(image.pngData()); document.keyImages["letter.a"] = "art"
        key.applySkin(KeyboardSkinAppearance(document), key: "letter.a"); key.layoutIfNeeded()
        XCTAssertTrue(key.hasSkinArtwork)
        XCTAssertTrue(key.point(inside: CGPoint(x: -3, y: 20), with: nil))
        XCTAssertFalse(key.point(inside: CGPoint(x: -6, y: 20), with: nil))
        var count = 0; key.action = { count += 1 }; key.sendActions(for: .touchUpInside)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(key.title(for: .normal), "A")
        key.applySkin(nil, key: "letter.a"); key.layoutIfNeeded()
        XCTAssertFalse(key.hasSkinArtwork)
    }
    func testArtworkCaptionsStayVisibleAtNormalAndCompactHeights() throws {
        var document = KeyboardSkinDocument(); document.style.font = "handwritten"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20)).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        }
        document.images["art"] = try XCTUnwrap(image.pngData())
        for id in ["return", "space", "letter.q"] { document.keyImages[id] = "art" }
        let skin = KeyboardSkinAppearance(document)
        for (id, width, titles) in [("return", 86.4, ["换行", "发送", "確定", "下一项"]),
                                    ("space", 136.5, ["変換", "次候補"]), ("letter.q", 36.8, ["Q"])] {
            for height in [46.5, 33.0, 28.05] {
                let key = KeyboardKey(); key.frame = CGRect(x: 0, y: 0, width: width, height: height)
                key.applySkin(skin, key: id)
                key.applySkinMetrics(size: id == "letter.q" ? 23 : 16.5, scale: 1)
                for title in titles {
                    key.setTitle(title, for: .normal); key.setNeedsLayout(); key.layoutIfNeeded()
                    let label = try XCTUnwrap(key.titleLabel)
                    let art = try XCTUnwrap(key.subviews.compactMap { $0 as? UIImageView }.first { $0 !== key.imageView && $0.image != nil })
                    XCTAssertTrue(key.bounds.contains(label.frame), title)
                    XCTAssertGreaterThanOrEqual(label.frame.height + 0.5, label.font.lineHeight, title)
                    if !art.isHidden { XCTAssertFalse(art.frame.intersects(label.frame), title) }
                    XCTAssertEqual(key.title(for: .normal), title)
                }
            }
        }
    }

    func testSelectedSkinReloadsAndRendersKeyboard() throws {
        var document = KeyboardSkinDocument(); document.style.pattern = "diamonds"
        // Optional local fixture for visual review; not shipped with the App.
        if let url = Bundle(for: Self.self).url(forResource: "LocalSkinPreview", withExtension: "vimeskin") {
            document = try KeyboardSkinDocument.decode(Data(contentsOf: url))
            document.id = UUID().uuidString
        }
        let preferences = KeyboardPreferences()
        let oldTheme = preferences.theme, oldID = preferences.customSkinID, oldRevision = preferences.skinRevision
        let store = KeyboardSkinStore()
        try store.save(document); store.select(document)
        let session = KeyboardSession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(keyboard); window.isHidden = false
        defer {
            window.isHidden = true; keyboard.stopInteractions()
            try? store.remove(document.id)
            preferences.theme = oldTheme; preferences.customSkinID = oldID; preferences.skinRevision = oldRevision
            keyboard.reloadPreferences()
        }
        keyboard.frame.size.height = keyboard.preferredHeight(for: 440)
        keyboard.layoutIfNeeded()
        XCTAssertEqual(KeyboardPalette.skin?.document.id, document.id)
        let image = UIGraphicsImageRenderer(bounds: keyboard.bounds).image { keyboard.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image); attachment.name = "custom-skin-keyboard"; attachment.lifetime = .keepAlways; add(attachment)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("VimeSkinPreview.png")
        try image.pngData()?.write(to: file)
        print("SKIN_PREVIEW_FILE \(file.path)")
        document.palette.text = "#123456"; try store.save(document)
        keyboard.reloadPreferences()
        XCTAssertEqual(KeyboardPalette.skin?.document.palette.text, "#123456")
        preferences.theme = .system; keyboard.reloadPreferences()
        XCTAssertNil(KeyboardPalette.skin)
    }

}
