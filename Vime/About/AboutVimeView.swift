import SwiftUI

struct AboutVimeView: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(uiImage: KeyboardGlyphs.logo(size: 60, appIcon: true)).resizable()
                        .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Vime \(version)").font(.title2.weight(.semibold))
                        Text("日语输入法").foregroundStyle(.secondary)
                        if !build.isEmpty { Text("构建 \(build)").font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 8)
            }
            Section {
                Link("开源项目", destination: URL(string: "https://github.com/Voltline/Vime")!)
                NavigationLink("隐私政策") { PrivacyPolicyView() }
                NavigationLink("开源组件与许可") { LicenseListView() }.accessibilityIdentifier("vime.about.licenses")
            }
            Section("本地模型") {
                Text("Vime 日语模型 v2.1")
                Text("用于候选排序和下一词联想，在设备上运行").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于 Vime").navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenseListView: View {
    @State private var catalog: LicenseCatalog?
    @State private var error: String?
    @State private var search = ""
    private let categories = ["转换与分词", "语言与表情数据", "其他依赖", "本项目"]
    private var filtered: [LicenseComponent] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (catalog?.components ?? []).filter {
            query.isEmpty || ($0.name + " " + $0.use + " " + $0.license).localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        List {
            if let error { Section { Text(error).foregroundStyle(.secondary) } }
            ForEach(categories, id: \.self) { category in
                let rows = filtered.filter { $0.category == category }
                if !rows.isEmpty {
                    Section(category) {
                        ForEach(rows) { component in
                            NavigationLink {
                                LicenseDetailView(component: component)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(component.name)
                                    Text(component.use).font(.caption).foregroundStyle(.secondary)
                                    Text(component.license).font(.caption2).foregroundStyle(.secondary)
                                }.padding(.vertical, 3)
                            }.accessibilityIdentifier("vime.license." + component.id)
                        }
                    }
                }
            }
            if catalog != nil && filtered.isEmpty { Text("没有匹配的组件").foregroundStyle(.secondary) }
            if catalog != nil {
                Section { NavigationLink("完整许可汇总") { FullLicenseNoticesView() } }
            }
        }
        .navigationTitle("开源组件与许可").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索组件或许可")
        .task { do { catalog = try LicenseCatalog() } catch { self.error = error.localizedDescription } }
    }
}

struct LicenseDetailView: View {
    let component: LicenseComponent
    @State private var notice = ""
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text(component.use)
                LabeledContent("许可", value: component.license)
                Text("版权方\n\(component.copyright)").font(.subheadline)
                if !component.revision.isEmpty { Text("版本 / 修订\n\(component.revision)").font(.subheadline) }
                if let url = URL(string: component.source) { Link("查看来源", destination: url) }
            }
            if !component.modified.isEmpty { Section("补充说明") { Text(component.modified).font(.subheadline) } }
            Section("许可原文") {
                Text(error ?? notice).font(.footnote).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("vime.license.notice")
            }
        }
        .navigationTitle(component.name).navigationBarTitleDisplayMode(.inline)
        .task {
            do { notice = try LicenseCatalog().notice(for: component) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct FullLicenseNoticesView: View {
    @State private var text = ""
    var body: some View {
        ScrollView {
            Text(text).font(.footnote).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .navigationTitle("完整许可汇总").navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { throw LicenseCatalog.ResourceError.missing }
                let catalog = try LicenseCatalog()
                guard let own = catalog.components.first(where: { $0.id == "vime" }) else { throw LicenseCatalog.ResourceError.invalid }
                text = try String(contentsOf: url, encoding: .utf8) + "\n\n" + catalog.notice(for: own)
            } catch { text = error.localizedDescription }
        }
    }
}
