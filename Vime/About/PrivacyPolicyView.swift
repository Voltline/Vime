import SwiftUI

struct PrivacyPolicy: Decodable {
    /// A paragraph of inline Markdown, or a table rendered as one card per row.
    enum Block: Decodable {
        struct Table: Decodable { let columns: [String]; let rows: [[String]] }
        case text(String), table(Table)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) { self = .text(text) }
            else { self = .table(try container.decode(Table.self)) }
        }
        /// Searchable plain content, including every table cell.
        var text: String {
            switch self {
            case .text(let text): text
            case .table(let table): (table.columns + table.rows.flatMap { $0 }).joined(separator: "\n")
            }
        }
    }
    struct Section: Decodable { let title: String; let paragraphs: [Block] }
    let updated: String
    let effective: String
    let scope: String
    let introduction: String
    let highlights: [String]
    let sections: [Section]
    /// Translations live beside the Simplified Chinese source as
    /// PrivacyPolicy-<language>.json; the app's current localization picks one.
    static let translations = ["zh-Hant", "ja", "en", "ko"]
    static func load(bundle: Bundle = .main, language: String? = nil) throws -> Self {
        let preferred = language ?? bundle.preferredLocalizations.first ?? "zh-Hans"
        let name = translations.contains(preferred) ? "PrivacyPolicy-" + preferred : "PrivacyPolicy"
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: "PrivacyPolicy", withExtension: "json") else { throw PolicyError.missing }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    enum PolicyError: LocalizedError {
        case missing
        var errorDescription: String? { String(localized: "隐私政策文件未找到") }
    }
}

struct PrivacyPolicyView: View {
    @State private var policy: PrivacyPolicy?
    @State private var error: String?
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let policy {
                        header(policy)
                        highlights(policy)
                        contents(policy, reader: reader)
                        ForEach(policy.sections.indices, id: \.self) { index in
                            section(policy.sections[index]).id(index)
                        }
                        Link("联系开发者", destination: URL(string: "https://github.com/Voltline/Vime/issues")!)
                    }
                    if let error { Text(error).foregroundStyle(.secondary) }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .multilineTextAlignment(.leading)
        .accessibilityIdentifier("vime.privacy.document")
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("隐私政策").navigationBarTitleDisplayMode(.inline)
        .task { do { policy = try PrivacyPolicy.load() } catch { self.error = error.localizedDescription } }
    }

    private func header(_ policy: PrivacyPolicy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vime 隐私政策").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("更新日期：\(policy.updated)\n生效日期：\(policy.effective)")
                .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
            Text(policy.scope).font(.subheadline)
            Divider().padding(.vertical, 4)
            paragraph(policy.introduction)
        }
    }

    private func highlights(_ policy: PrivacyPolicy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("要点速览").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(policy.highlights, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(Color.vimeBlue).frame(width: 6, height: 6).accessibilityHidden(true)
                    paragraph(item)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.vimeBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func contents(_ policy: PrivacyPolicy, reader: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("目录").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(policy.sections.indices, id: \.self) { index in
                Button { withAnimation { reader.scrollTo(index, anchor: .top) } } label: {
                    Text(policy.sections[index].title).font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.vimeBlue)
            }
        }
    }

    private func section(_ section: PrivacyPolicy.Section) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(section.paragraphs.indices, id: \.self) { index in
                switch section.paragraphs[index] {
                case .text(let text): paragraph(text)
                case .table(let table): tableCards(table)
                }
            }
        }
    }

    /// Phone-width tables: each row is a card, its first cell the card title.
    private func tableCards(_ table: PrivacyPolicy.Block.Table) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(table.rows.indices, id: \.self) { index in
                let row = table.rows[index]
                VStack(alignment: .leading, spacing: 10) {
                    Text(row.first ?? "").font(.subheadline.weight(.semibold))
                    ForEach(Array(zip(table.columns, row).dropFirst().enumerated()), id: \.offset) { _, cell in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cell.0).font(.caption).foregroundStyle(.secondary)
                            Text(cell.1).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        policyText(text).lineSpacing(7).fixedSize(horizontal: false, vertical: true)
    }

    private func policyText(_ text: String) -> Text {
        let formatted = try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(formatted ?? AttributedString(text))
    }
}
