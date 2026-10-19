import SwiftUI

struct PrivacyPolicy: Decodable {
    struct Section: Decodable { let title: String; let paragraphs: [String] }
    let updated: String
    let effective: String
    let scope: String
    let introduction: String
    let sections: [Section]
    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "PrivacyPolicy", withExtension: "json") else { throw PolicyError.missing }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    enum PolicyError: LocalizedError {
        case missing
        var errorDescription: String? { "隐私政策文件未找到" }
    }
}

struct PrivacyPolicyView: View {
    @State private var policy: PrivacyPolicy?
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if let policy {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Vime 隐私政策").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Text("更新日期：\(policy.updated)\n生效日期：\(policy.effective)")
                            .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                        Text(policy.scope).font(.subheadline)
                        Divider().padding(.vertical, 4)
                        policyText(policy.introduction).lineSpacing(7).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(policy.sections.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(policy.sections[index].title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            ForEach(policy.sections[index].paragraphs, id: \.self) {
                                policyText($0).lineSpacing(7).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Link("联系开发者", destination: URL(string: "https://github.com/Voltline/Vime/issues")!)
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .multilineTextAlignment(.leading)
        .accessibilityIdentifier("vime.privacy.document")
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("隐私政策").navigationBarTitleDisplayMode(.inline)
        .task { do { policy = try PrivacyPolicy.load() } catch { self.error = error.localizedDescription } }
    }

    private func policyText(_ text: String) -> Text {
        let formatted = try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(formatted ?? AttributedString(text))
    }
}
