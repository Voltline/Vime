import SwiftUI

/// Reading content lives on the page; only controls and destinations use cards.
struct AppSettingsPage<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

struct AppSettingsActionGroup<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .buttonStyle(.plain)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct AppSettingsActionRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var accessory = "chevron.right"
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body).foregroundStyle(.tint)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: accessory).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct AppInformationSection<Content: View>: View {
    let title: String
    private let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
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
