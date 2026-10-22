import StoreKit
import SwiftUI

struct TipJarView: View {
    @StateObject private var store: TipJarStore
    @Environment(\.purchase) private var purchase
    init(store: TipJarStore? = nil) { _store = StateObject(wrappedValue: store ?? TipJarStore()) }

    var body: some View {
        AppSettingsPage {
            AppInformationSection("支持 Vime 的开发") {
                Text("Vime 的全部功能都已包含在应用中。赞助完全自愿，不会解锁任何功能、皮肤或其他内容。")
            }
            tiers
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("vime.tips.status") }
            AppInformationSection("说明") {
                Text("付款由 Apple 处理，Vime 不会收到你的付款信息，也不保存购买记录。每次赞助都是一次性购买，无需恢复购买。")
            }
        }
        .navigationTitle("赞助开发").navigationBarTitleDisplayMode(.inline)
        .task { if store.products.isEmpty { await store.load() } }
    }

    @ViewBuilder private var tiers: some View {
        if store.products.isEmpty {
            if store.phase == .loading { ProgressView().frame(maxWidth: .infinity, minHeight: 60) }
        } else {
            AppSettingsActionGroup {
                ForEach(Array(store.products.enumerated()), id: \.element.id) { index, product in
                    if index > 0 { Divider().padding(.leading, 52) }
                    Button { Task { await store.purchase(product) { try await purchase($0) } } } label: {
                        TipRow(product: product, busy: store.phase == .purchasing(product.id))
                    }
                    .disabled(store.isPurchasing)
                    .accessibilityIdentifier("vime.tip." + (product.id.split(separator: ".").last.map(String.init) ?? product.id))
                }
            }
        }
    }

    private var message: String? {
        switch store.phase {
        case .thanked: String(localized: "感谢你的支持！")
        case .pending: String(localized: "购买正在等待批准，批准后会自动完成。")
        case .unavailable: String(localized: "暂时无法连接 App Store，请稍后再试。")
        case .failed(let reason): String(localized: "购买未完成：\(reason)")
        case .loading, .ready, .purchasing: nil
        }
    }
}

private struct TipRow: View {
    let product: Product
    let busy: Bool
    private var symbol: String {
        switch product.id {
        case TipJarStore.productIDs[0]: "cup.and.saucer"
        case TipJarStore.productIDs[1]: "mug"
        default: "fork.knife"
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName).font(.body).foregroundStyle(.primary)
                    if !product.description.isEmpty {
                        Text(product.description).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            } icon: {
                Image(systemName: symbol).font(.body).foregroundStyle(.tint).frame(width: 24).accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            Group {
                if busy { ProgressView() } else { Text(product.displayPrice).font(.subheadline.weight(.semibold)) }
            }
            .foregroundStyle(Color.vimeBlue)
            .frame(minWidth: 64, minHeight: 30)
            .background(Color.vimeBlue.opacity(0.12), in: Capsule())
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(Rectangle())
    }
}
