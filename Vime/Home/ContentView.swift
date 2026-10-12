import SwiftUI

struct ContentView: View {
    @StateObject private var router = AppRouter()
    private let blue = Color(uiColor: UIColor(cgColor: VimeLogo.blue))
    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack { KeyboardHomeView() }
                .tabItem { Label("试打", systemImage: "keyboard") }.tag(AppRouter.Tab.typing)
            NavigationStack { KeyboardSkinsView() }
                .tabItem { Label("定制", systemImage: "paintpalette") }.tag(AppRouter.Tab.customize)
            NavigationStack { KeyboardSettingsView() }
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(AppRouter.Tab.settings)
        }
        .environmentObject(router)
        .tint(blue)
        .onOpenURL { router.openSkin($0) }
        .sheet(item: $router.sheet, onDismiss: router.sheetDismissed) { sheet in
            switch sheet {
            case .skin(let document): KeyboardSkinEditor(document: document, store: KeyboardSkinStore())
            case .height: KeyboardHeightEditor()
            }
        }
        .alert("皮肤导入失败", isPresented: Binding(get: { router.error != nil }, set: { if !$0 { router.acknowledgeError() } })) {
            Button("好", role: .cancel) { router.acknowledgeError() }
        } message: { Text(router.error ?? "") }
    }
}

#Preview { ContentView() }
