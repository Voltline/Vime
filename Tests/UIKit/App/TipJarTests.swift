import StoreKitTest
import SwiftUI
import XCTest
@testable import Vime

/// Runs the tip jar against the same local StoreKit configuration the Vime
/// scheme uses, so product IDs in code and configuration cannot drift.
@MainActor
final class TipJarTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        let configuration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Configuration/VimeTips.storekit")
        session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
    }

    func testTipsLoadAsConsumablesInPriceOrderAndPurchaseThanks() async throws {
        let store = Vime.TipJarStore()
        await store.load()
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.products.map(\.id), Vime.TipJarStore.productIDs)
        XCTAssertTrue(store.products.allSatisfy { $0.type == .consumable })

        await store.purchase(store.products[1])
        XCTAssertEqual(store.phase, .thanked)
        XCTAssertEqual(session.allTransactions().map(\.productIdentifier), [Vime.TipJarStore.productIDs[1]])
    }

    /// SKTestSession's Ask to Buy waits on a dialog, so these outcomes are
    /// injected through the purchase action instead.
    func testPendingCancelledAndFailedPurchasesLeaveNoThanks() async throws {
        let store = Vime.TipJarStore()
        await store.load()
        let tip = try XCTUnwrap(store.products.first)
        await store.purchase(tip) { _ in .pending }
        XCTAssertEqual(store.phase, .pending)
        await store.purchase(tip) { _ in .userCancelled }
        XCTAssertEqual(store.phase, .ready)
        await store.purchase(tip) { _ in throw StoreKitError.networkError(URLError(.notConnectedToInternet)) }
        guard case .failed = store.phase else { return XCTFail("Expected a failure, got \(store.phase)") }
        XCTAssertTrue(session.allTransactions().isEmpty)
    }

    func testTipJarPageRendersTiers() async throws {
        for (name, scheme) in [("赞助开发", ColorScheme.light), ("赞助开发-深色", .dark)] {
            let store = Vime.TipJarStore()
            await store.load()
            XCTAssertEqual(store.products.count, 3)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let controller = UIHostingController(rootView: NavigationStack { Vime.TipJarView(store: store) }.environment(\.colorScheme, scheme))
            window.rootViewController = controller; window.isHidden = false
            defer { window.isHidden = true }
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
