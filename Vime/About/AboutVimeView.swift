import SwiftUI

struct AboutVimeView: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    var body: some View {
        AppSettingsPage {
            HStack(spacing: 16) {
                Image(uiImage: KeyboardGlyphs.logo(size: 48, appIcon: true)).resizable()
                    .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Vime \(version)").font(.headline)
                    Text("日语输入法").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            AppSettingsActionGroup {
                Link(destination: URL(string: "https://github.com/Voltline/Vime")!) {
                    AppSettingsActionRow(title: "开源项目", subtitle: "在 GitHub 查看源码和反馈问题", symbol: "chevron.left.forwardslash.chevron.right", accessory: "arrow.up.right")
                }
                Divider().padding(.leading, 52)
                NavigationLink { PrivacyPolicyView() } label: {
                    AppSettingsActionRow(title: "隐私政策", subtitle: "了解本地数据与系统权限", symbol: "lock.shield")
                }
                Divider().padding(.leading, 52)
                NavigationLink { LicenseListView() } label: {
                    AppSettingsActionRow(title: "开源组件与许可", subtitle: "查看组件来源及完整许可", symbol: "doc.text")
                }.accessibilityIdentifier("vime.about.licenses")
            }
            AppInformationSection("本地模型") {
                Text("Vime 日语模型 V\(VimeLanguageModel.Variant.runtimeDefault.displayVersion)")
                Text("用于候选排序和下一词联想，在设备上运行。")
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
            query.isEmpty || ($0.name + " " + $0.localizedUse + " " + $0.license).localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        List {
            if let error { Section {} footer: { Text(error) } }
            ForEach(categories, id: \.self) { category in
                let rows = filtered.filter { $0.category == category }
                if !rows.isEmpty {
                    Section(LicenseComponent.localizedCategory(category)) {
                        ForEach(rows) { component in
                            NavigationLink {
                                LicenseDetailView(component: component)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(component.name)
                                    Text(component.localizedUse).font(.caption).foregroundStyle(.secondary)
                                    Text(component.license).font(.caption2).foregroundStyle(.secondary)
                                }.padding(.vertical, 3)
                            }.accessibilityIdentifier("vime.license." + component.id)
                        }
                    }
                }
            }
            if catalog != nil && filtered.isEmpty {
                Section {} footer: { Text("没有匹配的组件") }
            }
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
        AppSettingsPage {
            AppInformationSection("组件信息") {
                Text(component.localizedUse)
                LabeledContent("许可", value: component.license)
                Text("版权方\n\(component.copyright)")
                if !component.revision.isEmpty { Text("版本 / 修订\n\(component.revision)") }
            }
            if let url = URL(string: component.source) {
                AppSettingsActionGroup {
                    Link(destination: url) {
                        AppSettingsActionRow(title: "查看来源", subtitle: "打开组件的官方来源页面", symbol: "link", accessory: "arrow.up.right")
                    }
                }
            }
            if !component.modified.isEmpty {
                AppInformationSection("补充说明") { Text(component.localizedModified) }
            }
            AppInformationSection("许可原文") {
                Text(error ?? notice).font(.footnote).foregroundStyle(.primary).textSelection(.enabled)
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
