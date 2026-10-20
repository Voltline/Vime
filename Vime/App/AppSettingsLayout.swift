import SwiftUI

/// Reading content lives on the page; only controls and destinations use cards.
struct AppSettingsPage<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .multilineTextAlignment(.leading)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

struct AppSettingsActionGroup<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .buttonStyle(.plain)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct AppSettingsActionRow: View {
    let title: LocalizedStringResource
    var subtitle: LocalizedStringResource? = nil
    let symbol: String
    var accessory = "chevron.right"
    var body: some View {
        HStack(spacing: 12) {
            AppSettingsLabel(title: title, subtitle: subtitle, symbol: symbol)
            Spacer(minLength: 8)
            if !accessory.isEmpty {
                Image(systemName: accessory).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The same label fits native list rows and the action groups on reading pages.
struct AppSettingsLabel: View {
    let title: LocalizedStringResource
    var subtitle: LocalizedStringResource? = nil
    let symbol: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, subtitle == nil ? 2 : 4)
        } icon: {
            Image(systemName: symbol).font(.body).foregroundStyle(.tint)
                .frame(width: 24).accessibilityHidden(true)
        }
    }
}

struct AppInformationSection<Content: View>: View {
    let title: LocalizedStringResource
    private let content: Content
    init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            content.font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Color {
    static let vimeBlue = Color(uiColor: UIColor(cgColor: VimeLogo.blue))
}

/// Tab root used by 试打, 定制 and 设置: cards on the grouped background.
struct AppDashboardPage<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

extension View {
    /// The white (dark: elevated gray) surface shared by dashboard tiles.
    func appCard(cornerRadius: CGFloat = 20) -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Small section caption above a group of dashboard cards.
struct AppSectionTitle: View {
    let text: LocalizedStringResource
    init(_ text: LocalizedStringResource) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Tinted rounded square holding a glyph or SF Symbol.
struct AppIconChip: View {
    enum Icon { case glyph(String), symbol(String) }
    let icon: Icon
    let tint: Color
    var body: some View {
        Group {
            switch icon {
            case .glyph(let text): Text(text).font(.headline)
            case .symbol(let name): Image(systemName: name).font(.body.weight(.semibold))
            }
        }
        .foregroundStyle(tint)
        .frame(width: 34, height: 34)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

/// Radio-style mark for option cards: filled ring when selected.
struct AppSelectionMark: View {
    let selected: Bool
    var body: some View {
        Circle()
            .strokeBorder(selected ? Color.vimeBlue : Color(uiColor: .tertiaryLabel), lineWidth: selected ? 6 : 1.5)
            .background(Circle().fill(selected ? Color.white : .clear).padding(5))
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

/// Option card border: blue when selected, otherwise invisible.
extension View {
    func appOptionBorder(_ selected: Bool, cornerRadius: CGFloat = 20) -> some View {
        overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(selected ? Color.vimeBlue : .clear, lineWidth: 2))
    }
}
