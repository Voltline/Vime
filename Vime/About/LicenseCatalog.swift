import Foundation

struct LicenseComponent: Decodable, Identifiable {
    let id: String
    let name: String
    let use: String
    let category: String
    let license: String
    let copyright: String
    let source: String
    let revision: String
    let modified: String
    let noticeFile: String
}

struct LicenseCatalog {
    let components: [LicenseComponent]
    let bundle: Bundle
    init(bundle: Bundle = .main) throws {
        self.bundle = bundle
        guard let url = bundle.url(forResource: "LicenseManifest", withExtension: "json") else { throw ResourceError.missing }
        components = try JSONDecoder().decode([LicenseComponent].self, from: Data(contentsOf: url))
        guard !components.isEmpty, Set(components.map(\.id)).count == components.count else { throw ResourceError.invalid }
    }
    func notice(for component: LicenseComponent) throws -> String {
        guard let url = bundle.url(forResource: component.noticeFile, withExtension: "txt")
            ?? bundle.url(forResource: component.noticeFile, withExtension: "txt", subdirectory: "Licenses") else { throw ResourceError.missing }
        return try String(contentsOf: url, encoding: .utf8)
    }
    enum ResourceError: LocalizedError {
        case missing, invalid
        var errorDescription: String? {
            switch self { case .missing: "许可文件未找到"; case .invalid: "许可目录格式无效" }
        }
    }
}
