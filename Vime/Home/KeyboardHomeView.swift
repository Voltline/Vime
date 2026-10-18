import SwiftUI

struct KeyboardHomeView: View {
    @State private var text = ""
    @State private var composition = ""
    @State private var focusRequest = 0
    @State private var clearRequest = 0
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("输入一段文字").foregroundStyle(.tertiary)
                                .padding(.horizontal, 6).padding(.top, 4)
                                .allowsHitTesting(false)
                        }
                        // Keep the genuine system host intact; no embedded keyboard.
                        SystemKeyboardEditor(text: $text, composition: $composition,
                            focusRequest: focusRequest, clearRequest: clearRequest)
                            .frame(height: 144)
                    }
                    HStack {
                        Button("开始试打") { focusRequest += 1 }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("vime.home.focus")
                        Spacer()
                        Button("清空") { text = ""; composition = ""; clearRequest += 1 }
                            .buttonStyle(.borderless)
                            .disabled(text.isEmpty && composition.isEmpty)
                    }
                }.padding(.vertical, 4)
            } header: { Text("试打一段文字") } footer: {
                Text(composition.isEmpty ? "长按地球键，选择 Vime 日本語。" : "待确认：\(composition)")
            }
            Section {
                NavigationLink { KeyboardSetupGuide() } label: {
                    AppSettingsLabel(title: "启用键盘", subtitle: "首次使用？按步骤添加 Vime", symbol: "keyboard.badge.ellipsis")
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    hint("空格", "开始转换，再按一次切换候选")
                    hint("回车", "确认输入，确认后再按可换行")
                    hint("あ / ア", "切换平假名与片假名")
                    hint("日 / 英", "切换日语与英文")
                }.padding(.vertical, 4)
            } header: { Text("输入操作") }
                .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("键盘试打")
        .scrollDismissesKeyboard(.interactively)
    }
    private func hint(_ key: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key).font(.subheadline.weight(.medium)).frame(width: 58, alignment: .leading)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct KeyboardSetupGuide: View {
    var body: some View {
        AppSettingsPage {
            AppInformationSection("添加键盘") {
                Text("1. 打开 iPhone 的“设置”。")
                Text("2. 进入“通用 → 键盘 → 键盘”。")
                Text("3. 点击“添加新键盘”，选择 Vime。")
            }
            AppInformationSection("切换键盘") {
                Text("打开输入框，长按地球键，选择 Vime 日本語。基本输入无需完全访问。")
            }
            AppInformationSection("声音与振动") {
                Text("进入“设置 → 通用 → 键盘 → 键盘 → Vime 日本語”，开启“允许完全访问”。")
                Text("声音与振动也可在键盘左上角快速调整，静音时不播放按键声。")
            }
            AppInformationSection("系统限制") {
                Text("密码输入框和部分 App 使用系统键盘。修改 App 设置后，重新打开键盘即可读取更新。")
            }
            AppSettingsActionGroup {
                NavigationLink { PrivacyPolicyView() } label: {
                    AppSettingsActionRow(title: "隐私政策", subtitle: "了解输入数据和权限的处理方式", symbol: "lock.shield")
                }.accessibilityIdentifier("vime.setup.privacy")
            }
        }
        .navigationTitle("启用键盘").navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    KeyboardHomeView()
}
