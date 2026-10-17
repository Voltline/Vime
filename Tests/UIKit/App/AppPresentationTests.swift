import XCTest
import Combine
import SwiftUI
@testable import Vime

@MainActor
final class AppPresentationTests: XCTestCase {
    func testExternalSkinWaitsForDraftAndImportsWithoutOverwritingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Vime.KeyboardSkinStore(directory: directory.appendingPathComponent("skins"))
        let router = Vime.AppRouter(store: store)
        var draft = Vime.KeyboardSkinDocument(); draft.name = "未保存草稿"
        var imported = Vime.KeyboardSkinDocument(); imported.name = "外部皮肤"
        imported.images["badge"] = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image {
            UIColor.systemBlue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }.pngData())
        imported.keyImages["letter.a"] = "badge"
        let file = directory.appendingPathComponent("external.vimeskin")
        try imported.encoded().write(to: file)
        router.present(.skin(draft)); router.openSkin(file)
        XCTAssertFalse(router.importing)
        XCTAssertTrue(store.summaries().isEmpty)
        guard case .skin(let current) = router.sheet else { return XCTFail("Draft was dismissed") }
        XCTAssertEqual(current, draft)
        let ready = expectation(description: "Queued file opens after draft dismissal")
        let subscription = router.$sheet.compactMap { $0 }.sink {
            if case .skin(let document) = $0, document.name == "外部皮肤" { ready.fulfill() }
        }
        router.sheet = nil; router.sheetDismissed()
        await fulfillment(of: [ready], timeout: 5)
        withExtendedLifetime(subscription) {}
        let saved = try XCTUnwrap(store.summaries().first)
        XCTAssertEqual(saved.name, "外部皮肤")
        XCTAssertNotEqual(saved.id, imported.id)
        XCTAssertEqual(try store.load(saved.id).palette, imported.palette)
        XCTAssertEqual(try store.load(saved.id).images, imported.images)
        XCTAssertFalse(router.importing)
    }
    func testFailedImportDoesNotChangeSelectionAndQueuedFileWaitsForAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Vime.KeyboardSkinStore(directory: directory.appendingPathComponent("skins"))
        let router = Vime.AppRouter(store: store)
        let preferences = Vime.KeyboardPreferences(), previous = preferences.snapshot
        let bad = directory.appendingPathComponent("bad.vimeskin"), good = directory.appendingPathComponent("good.vimeskin")
        try Data("invalid skin".utf8).write(to: bad)
        var document = Vime.KeyboardSkinDocument(); document.name = "排队导入"
        try document.encoded().write(to: good)
        let failed = expectation(description: "Malformed external file fails")
        let errorSubscription = router.$error.compactMap { $0 }.first().sink { _ in failed.fulfill() }
        router.beginFilePicker(); router.openSkin(good)
        XCTAssertFalse(router.importing)
        // Finish the picker with a bad file first; its own selected file is appended
        // after the external file, so acknowledge any errors before proceeding.
        router.finishFilePicker(.failure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)))
        XCTAssertNotNil(router.error)
        XCTAssertTrue(store.summaries().isEmpty)
        // Use a second router to test failure from actual file decoding.
        let decoderRouter = Vime.AppRouter(store: store)
        let decodeFailed = expectation(description: "Invalid data reaches decoder error")
        let decoderSubscription = decoderRouter.$error.compactMap { $0 }.first().sink { _ in decodeFailed.fulfill() }
        decoderRouter.openSkin(bad); decoderRouter.openSkin(good)
        await fulfillment(of: [failed, decodeFailed], timeout: 5)
        XCTAssertTrue(store.summaries().isEmpty)
        XCTAssertEqual(preferences.snapshot, previous)
        let ready = expectation(description: "Valid file opens after acknowledging error")
        let sheetSubscription = decoderRouter.$sheet.compactMap { $0 }.first().sink { _ in ready.fulfill() }
        decoderRouter.acknowledgeError()
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(store.summaries().map(\.name), ["排队导入"])
        XCTAssertEqual(preferences.snapshot, previous)
        withExtendedLifetime((errorSubscription, decoderSubscription, sheetSubscription)) {}
    }
    func testBundledComponentNoticesCoverOriginalBytesAndPolicyLoadsOffline() async throws {
        let catalog = try Vime.LicenseCatalog()
        XCTAssertEqual(catalog.components.count, 12)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"))
        let original = try String(contentsOf: url, encoding: .utf8)
        var sections: [(String.Index, String)] = []
        for component in catalog.components where component.id != "vime" {
            let notice = try catalog.notice(for: component)
            let range = try XCTUnwrap(original.range(of: notice), "Missing original notice for \(component.name)")
            sections.append((range.lowerBound, notice))
        }
        XCTAssertEqual(sections.sorted { $0.0 < $1.0 }.map(\.1).joined(), original)
        let own = try XCTUnwrap(catalog.components.first { $0.id == "vime" })
        XCTAssertTrue(try catalog.notice(for: own).contains("GNU GENERAL PUBLIC LICENSE"))
        let policy = try Vime.PrivacyPolicy.load()
        XCTAssertFalse(policy.introduction.isEmpty)
        XCTAssertEqual(policy.effective, policy.updated)
        XCTAssertTrue(policy.sections.contains { $0.title.contains("系统权限") })
        let paragraphs = policy.sections.flatMap(\.paragraphs)
        let clipboardPolicy = try XCTUnwrap(paragraphs.first { $0.contains("剪贴板信息") })
        XCTAssertTrue(clipboardPolicy.contains("默认关闭"))
        XCTAssertTrue(clipboardPolicy.contains("仅保存在本机"))
        XCTAssertTrue(clipboardPolicy.contains("不会上传"))
        XCTAssertTrue(paragraphs.contains { $0.contains("不会同时删除已有学习记录") })
        let licenseComponent = try XCTUnwrap(catalog.components.first { $0.id == "azookey" })
        for (name, page) in [("数据与隐私", AnyView(Vime.KeyboardDataPrivacyView())),
                             ("数据与隐私-大字", AnyView(Vime.KeyboardDataPrivacyView().environment(\.dynamicTypeSize, .accessibility1))),
                             ("剪贴板设置", AnyView(Vime.KeyboardClipboardSettingsView())),
                             ("剪贴板设置-大字", AnyView(Vime.KeyboardClipboardSettingsView().environment(\.dynamicTypeSize, .accessibility1))),
                             ("剪贴板设置-深色", AnyView(Vime.KeyboardClipboardSettingsView().environment(\.colorScheme, .dark))),
                             ("启用键盘", AnyView(Vime.KeyboardSetupGuide())),
                             ("关于", AnyView(Vime.AboutVimeView())),
                             ("关于-大字", AnyView(Vime.AboutVimeView().environment(\.dynamicTypeSize, .accessibility1))),
                             ("许可详情", AnyView(Vime.LicenseDetailView(component: licenseComponent))),
                             ("用户词典", AnyView(Vime.KeyboardUserDictionaryView())),
                             ("手感与布局", AnyView(Vime.KeyboardFeedbackSettingsView())),
                             ("隐私政策", AnyView(Vime.PrivacyPolicyView()))] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let controller = UIHostingController(rootView: NavigationStack { page })
            window.rootViewController = controller; window.isHidden = false
            defer { window.isHidden = true }
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
