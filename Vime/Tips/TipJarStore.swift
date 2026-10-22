import Combine
import StoreKit

/// Optional tips sold as App Store consumables. A tip unlocks nothing, so the
/// app keeps no purchase record: every transaction is finished immediately.
@MainActor
final class TipJarStore: ObservableObject {
    enum Phase: Equatable {
        case loading, ready, unavailable, pending, thanked
        case purchasing(String)
        case failed(String)
    }

    static let productIDs = ["com.Voltline.Vime.tip.small", "com.Voltline.Vime.tip.medium", "com.Voltline.Vime.tip.large"]

    @Published private(set) var products: [Product] = []
    @Published private(set) var phase = Phase.loading

    func load() async {
        phase = .loading
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            phase = products.isEmpty ? .unavailable : .ready
        } catch { phase = .unavailable }
    }

    /// `buy` defaults to the scene-less purchase; the page passes SwiftUI's
    /// purchase action so the payment sheet attaches to the right window.
    func purchase(_ product: Product,
                  using buy: (Product) async throws -> Product.PurchaseResult = { try await $0.purchase() }) async {
        guard !isPurchasing else { return }
        phase = .purchasing(product.id)
        do {
            switch try await buy(product) {
            case .success(let result):
                await result.unsafePayloadValue.finish()
                if case .verified = result { phase = .thanked }
                else { phase = .failed(String(localized: "无法验证这笔交易")) }
            case .pending: phase = .pending
            case .userCancelled: phase = .ready
            @unknown default: phase = .ready
            }
        } catch { phase = .failed(error.localizedDescription) }
    }

    var isPurchasing: Bool {
        if case .purchasing = phase { return true }
        return false
    }

    /// Finishes tips completed outside `purchase`, such as Ask to Buy approvals
    /// or purchases interrupted by the app quitting.
    static func finishTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            for await update in Transaction.updates { await update.unsafePayloadValue.finish() }
        }
    }
}
