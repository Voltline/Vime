import SwiftUI

struct KeyboardHomeView: View {
    @State private var text = ""
    @State private var composition = ""
    @State private var focusRequest = 0
    @State private var clearRequest = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("试打一段文字").font(.headline)
                        Spacer()
                        Button("清空") { text = ""; composition = ""; clearRequest += 1 }
                            .disabled(text.isEmpty && composition.isEmpty)
                    }
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("输入 nihongo").foregroundStyle(.tertiary)
                                .padding(.horizontal, 13).padding(.top, 17)
                                .allowsHitTesting(false)
                        }
                        // Keep the genuine system host intact; no embedded keyboard.
                        SystemKeyboardEditor(text: $text, composition: $composition,
                            focusRequest: focusRequest, clearRequest: clearRequest)
                            .frame(height: 154)
                    }
                    Text(composition.isEmpty ? "长按地球键选择 Vime 日本語" : "待确认：\(composition)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { focusRequest += 1 } label: {
                        Text("开始试打").frame(maxWidth: .infinity).padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("vime.home.focus")
                }
                .padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                NavigationLink { KeyboardSetupGuide() } label: {
                    Label("启用键盘", systemImage: "plus.circle")
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("输入操作").font(.headline)
                    hint("空格", "开始转换，再按一次切换候选")
                    hint("回车", "确认输入，确认后再按可换行")
                    hint("あ / ア", "切换平假名与片假名")
                    hint("日 / 英", "切换日语与英文")
                }
            }
            .padding(20).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("键盘试打")
        .scrollDismissesKeyboard(.interactively)
    }
    private func hint(_ key: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key).font(.caption.weight(.medium)).frame(minWidth: 58, minHeight: 28)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
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
