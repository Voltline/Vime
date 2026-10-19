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
    let title: String
    let subtitle: String
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
    let title: String
    var subtitle = ""
    let symbol: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, subtitle.isEmpty ? 2 : 4)
        } icon: {
            Image(systemName: symbol).font(.body).foregroundStyle(.tint)
                .frame(width: 24).accessibilityHidden(true)
        }
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
