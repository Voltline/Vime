import XCTest
import Combine
import SwiftUI
@testable import Vime

@MainActor
final class AppPresentationTests: XCTestCase {
    private struct AlignmentProbe: UIViewRepresentable {
        let view: UIView
        func makeUIView(context: Context) -> UIView { view }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }
    func testSettingsPageStartsAtLeadingMarginOnWideAndNarrowScreens() async {
        for width in [CGFloat(390), 1024] {
            let marker = UIView()
            let controller = UIHostingController(rootView: Vime.AppSettingsPage {
                AlignmentProbe(view: marker).frame(width: 80, height: 44)
            })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 768))
            window.rootViewController = controller; window.isHidden = false
            controller.view.layoutIfNeeded()
            await Task.yield()
            controller.view.layoutIfNeeded()
            let origin = marker.convert(CGPoint.zero, to: controller.view)
            XCTAssertEqual(origin.x, 20, accuracy: 1)
            XCTAssertLessThan(origin.y, controller.view.safeAreaInsets.top + 24)
            window.isHidden = true
        }
    }
    static let reportedStatus = Vime.KeyboardExtensionStatus(lastSeen: Date(), fullAccess: true,
        modelVersion: "4.2-epoch20-step1081942-int8-b32-v1")
    static func settingsSummary(status: Vime.KeyboardExtensionStatus?, added: Bool = false) -> Vime.KeyboardSettingsSummary {
        Vime.KeyboardSettingsSummary(status: status, ranking: .languageModel, suggestions: true, hapticIntensity: 0.6,
            nineKeyNumbers: true, autoPairBrackets: true, symbolCount: 12, clipboard: false, appVersion: "1.0", added: added)
    }

    func testExtensionStatusRoundTripsOnlyFromTheExtensionProcess() throws {
        let suite = "vime.tests.status." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(Vime.KeyboardExtensionStatus.isExtensionProcess, "The test host is the app")
        Vime.KeyboardExtensionStatus.update(defaults: defaults) { $0.fullAccess = true }
        XCTAssertNil(Vime.KeyboardExtensionStatus.load(from: defaults), "The app must never report keyboard activity")
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        Vime.KeyboardExtensionStatus.update(defaults: defaults, requireExtension: false) {
            $0.lastSeen = seen; $0.fullAccess = true; $0.modelVersion = "4.2-epoch20-step1081942-int8-b32-v1"
        }
        Vime.KeyboardExtensionStatus.update(defaults: defaults, requireExtension: false) { $0.modelPaused = true }
        let status = try XCTUnwrap(Vime.KeyboardExtensionStatus.load(from: defaults))
        XCTAssertEqual(status.lastSeen, seen)
        XCTAssertTrue(status.fullAccess)
        XCTAssertTrue(status.modelPaused, "Later reports keep earlier fields")
        XCTAssertEqual(status.modelShortVersion, "4.2")
    }

    func testSettingsSummaryDescribesRankingFeelAndSymbols() {
        var summary = Self.settingsSummary(status: nil)
        XCTAssertEqual(summary.rankingValue, "待使用")
        summary.status = Self.reportedStatus
        XCTAssertEqual(summary.rankingValue, "已开启")
        summary.status?.modelPaused = true
        XCTAssertEqual(summary.rankingValue, "已暂停")
        summary.status?.modelPaused = false; summary.status?.modelVersion = nil
        XCTAssertEqual(summary.rankingValue, "待加载")
        summary.ranking = .engine
        XCTAssertEqual(summary.rankingValue, "词典排序")
        XCTAssertEqual(summary.feelDetail, "振动中 · 九宫格")
        summary.hapticIntensity = 0; summary.nineKeyNumbers = false
        XCTAssertEqual(summary.feelDetail, "振动关 · 全键盘")
        summary.hapticIntensity = 0.35
        XCTAssertEqual(summary.feelDetail, "振动35% · 全键盘")
        XCTAssertEqual(summary.symbolDetail, "12 个常用 · 自动配对开")
    }

    func testLearnedConversionCountIsDistinctReadingAndSurface() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = Vime.CandidatePreferenceMemory(directory: directory)
        let now = Date()
        memory.record(reading: "ハシ", surface: "橋", scope: "conversion", now: now)
        memory.record(reading: "ハシ", surface: "橋", context: "川を", scope: "conversion", now: now)
        memory.record(reading: "ハシ", surface: "箸", scope: "conversion", now: now)
        memory.record(reading: "ハシ", surface: "端", context: "", scope: "choice", now: now)
        memory.flush()
        XCTAssertEqual(Vime.CandidatePreferenceMemory(directory: directory).learnedConversionCount, 2)
    }

    func testEveryLanguageBundleResolvesAppAndKeyboardStrings() throws {
        let expected: [String: [String: String]] = [
            "zh-Hant": ["设置": "設定", "剪贴板": "剪貼簿", "符号与括号": "符號與括號"],
            "ja": ["设置": "設定", "剪贴板": "クリップボード", "符号与括号": "記号と括弧"],
            "en": ["设置": "Settings", "剪贴板": "Clipboard", "符号与括号": "Symbols & Brackets"],
            "ko": ["设置": "설정", "剪贴板": "클립보드", "符号与括号": "기호 및 괄호"],
        ]
        // Counts resolve plural forms, so check the formatted text for one and two.
        let counts: [String: [String: [String]]] = [
            "zh-Hant": ["%lld 条": ["1 條", "2 條"], "%lld 个": ["1 個", "2 個"]],
            "ja": ["%lld 条": ["1 件", "2 件"], "%lld 个": ["1 語", "2 語"]],
            "en": ["%lld 条": ["1 entry", "2 entries"], "%lld 个": ["1 word", "2 words"]],
            "ko": ["%lld 条": ["1개 항목", "2개 항목"], "%lld 个": ["1개", "2개"]],
        ]
        for (language, values) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for (key, value) in values {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), value, "\(language): \(key)")
            }
            for (key, forms) in counts[language] ?? [:] {
                let format = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertEqual([1, 2].map { String(format: format, locale: Locale(identifier: language), Int64($0)) }, forms, "\(language): \(key)")
            }
            // Runtime keys (symbol categories, license fields) are catalog entries too.
            XCTAssertNotEqual(bundle.localizedString(forKey: "箭头", value: nil, table: nil), "箭头", language)
            XCTAssertNotEqual(bundle.localizedString(forKey: "假名汉字转换与预测", value: nil, table: nil), "假名汉字转换与预测", language)
        }
    }

    func testEveryPrivacyPolicyTranslationLoadsWithTheSourceStructure() throws {
        let source = try Vime.PrivacyPolicy.load(language: "zh-Hans")
        for language in Vime.PrivacyPolicy.translations {
            let policy = try Vime.PrivacyPolicy.load(language: language)
            XCTAssertEqual(policy.updated, source.updated, language)
            XCTAssertEqual(policy.highlights.count, source.highlights.count, language)
            XCTAssertEqual(policy.sections.map(\.paragraphs.count), source.sections.map(\.paragraphs.count), language)
            XCTAssertNotEqual(policy.introduction, source.introduction, "\(language) must not fall back to the source text")
        }
    }

    func testNumberSymbolLinkRoutesDirectlyToAppEditorAndRejectsOtherURLs() throws {
        let router = Vime.AppRouter()
        router.openURL(Vime.KeyboardNumberSymbols.settingsURL)
        XCTAssertEqual(router.tab, .settings)
        XCTAssertEqual(router.settingsPath, [.numberSymbols])
        router.tab = .customize
        router.openURL(Vime.KeyboardAppLinks.settings)
        XCTAssertEqual(router.tab, .settings)
        XCTAssertTrue(router.settingsPath.isEmpty)
        router.openURL(try XCTUnwrap(URL(string: "vime://settings/unknown")))
        XCTAssertTrue(router.settingsPath.isEmpty)
        XCTAssertNil(router.sheet)
        XCTAssertFalse(router.importing)
    }
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
        XCTAssertEqual(catalog.components.count, 14)
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
        let ownNotice = try catalog.notice(for: own)
        XCTAssertTrue(ownNotice.contains("GNU GENERAL PUBLIC LICENSE") && ownNotice.contains("Version 3, 29 June 2007"))
        XCTAssertTrue(ownNotice.contains("Additional permission under GNU GPL version 3 section 7"))
        let policy = try Vime.PrivacyPolicy.load()
        XCTAssertFalse(policy.introduction.isEmpty)
        XCTAssertEqual(policy.effective, policy.updated)
        XCTAssertTrue(policy.sections.contains { $0.title.contains("系统权限") })
        let paragraphs = policy.sections.flatMap(\.paragraphs).map(\.text)
        XCTAssertTrue(policy.highlights.contains { $0.contains("不包含任何联网代码") })
        let clipboardPolicy = try XCTUnwrap(paragraphs.first { $0.contains("剪贴板（默认关闭）") })
        XCTAssertTrue(clipboardPolicy.contains("不纳入系统备份"))
        XCTAssertTrue(clipboardPolicy.contains("最近 24 小时"))
        XCTAssertTrue(paragraphs.contains { $0.contains("删除词典条目也不会同时删除已有学习记录") })
        XCTAssertTrue(paragraphs.contains { $0.contains("键盘状态") }, "The status record shown in Settings is disclosed")
        XCTAssertTrue(paragraphs.contains { $0.contains("清空学习记录") }, "The in-app learning reset is the documented deletion path")
        let licenseComponent = try XCTUnwrap(catalog.components.first { $0.id == "azookey" })
        for (name, page) in [("试打-未检测", AnyView(Vime.KeyboardHomeView(keyboardReady: false))),
                             ("试打", AnyView(Vime.KeyboardHomeView(keyboardReady: true))),
                             ("试打-大字", AnyView(Vime.KeyboardHomeView(keyboardReady: false).environment(\.dynamicTypeSize, .accessibility1))),
                             ("试打-深色", AnyView(Vime.KeyboardHomeView(keyboardReady: true).environment(\.colorScheme, .dark))),
                             ("试打-等待完全访问", AnyView(Vime.KeyboardHomeView(progress: .init(added: true, fullAccess: false)))),
                             ("设置-未检测", AnyView(Vime.KeyboardSettingsView(summary: Self.settingsSummary(status: nil)))),
                             ("设置-等待完全访问", AnyView(Vime.KeyboardSettingsView(summary: Self.settingsSummary(status: nil, added: true)))),
                             ("设置-运行正常", AnyView(Vime.KeyboardSettingsView(summary: Self.settingsSummary(status: Self.reportedStatus),
                                 counts: .init(dictionary: 24, learned: 312)))),
                             ("设置-运行正常-深色", AnyView(Vime.KeyboardSettingsView(summary: Self.settingsSummary(status: Self.reportedStatus),
                                 counts: .init(dictionary: 24, learned: 312)).environment(\.colorScheme, .dark))),
                             ("设置-运行正常-大字", AnyView(Vime.KeyboardSettingsView(summary: Self.settingsSummary(status: Self.reportedStatus),
                                 counts: .init(dictionary: 24, learned: 312)).environment(\.dynamicTypeSize, .accessibility1))),
                             ("定制", AnyView(Vime.KeyboardSkinsView().environmentObject(Vime.AppRouter()))),
                             ("定制-大字", AnyView(Vime.KeyboardSkinsView().environmentObject(Vime.AppRouter()).environment(\.dynamicTypeSize, .accessibility1))),
                             ("定制-深色", AnyView(Vime.KeyboardSkinsView().environmentObject(Vime.AppRouter()).environment(\.colorScheme, .dark))),
                             ("学习与隐私", AnyView(Vime.KeyboardDataPrivacyView())),
                             ("学习与隐私-大字", AnyView(Vime.KeyboardDataPrivacyView().environment(\.dynamicTypeSize, .accessibility1))),
                             ("剪贴板设置", AnyView(Vime.KeyboardClipboardSettingsView())),
                             ("剪贴板设置-大字", AnyView(Vime.KeyboardClipboardSettingsView().environment(\.dynamicTypeSize, .accessibility1))),
                             ("剪贴板设置-深色", AnyView(Vime.KeyboardClipboardSettingsView().environment(\.colorScheme, .dark))),
                             ("启用键盘", AnyView(Vime.KeyboardSetupGuide())),
                             ("关于", AnyView(Vime.AboutVimeView())),
                             ("关于-大字", AnyView(Vime.AboutVimeView().environment(\.dynamicTypeSize, .accessibility1))),
                             ("许可详情", AnyView(Vime.LicenseDetailView(component: licenseComponent))),
                             ("用户词典", AnyView(Vime.KeyboardUserDictionaryView())),
                             ("手感与布局", AnyView(Vime.KeyboardFeedbackSettingsView().environmentObject(Vime.AppRouter()))),
                             ("手感与布局-大字", AnyView(Vime.KeyboardFeedbackSettingsView().environmentObject(Vime.AppRouter()).environment(\.dynamicTypeSize, .accessibility1))),
                             ("符号与括号", AnyView(Vime.KeyboardNumberSymbolsView())),
                             ("符号与括号-大字", AnyView(Vime.KeyboardNumberSymbolsView().environment(\.dynamicTypeSize, .accessibility1))),
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
