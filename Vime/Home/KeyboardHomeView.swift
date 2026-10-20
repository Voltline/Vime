import SwiftUI

struct KeyboardHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var text = ""
    @State private var composition = ""
    @State private var focusRequest = 0
    @State private var clearRequest = 0
    @State private var keyboardReady: Bool
    /// Fixed state for rendering tests; the live page rereads the status record.
    private let fixed: Bool

    init(keyboardReady: Bool? = nil) {
        _keyboardReady = State(initialValue: keyboardReady ?? Self.keyboardReported())
        fixed = keyboardReady != nil
    }

    /// Same signal as the settings status card: a report proves full access.
    private static func keyboardReported() -> Bool { KeyboardExtensionStatus.load()?.fullAccess == true }

    var body: some View {
        AppDashboardPage {
            if !keyboardReady { setupBanner }
            editorCard
            VStack(alignment: .leading, spacing: 10) {
                AppSectionTitle("输入操作")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                         count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                    operation("空格", "开始转换，再按切换候选", tint: .blue)
                    operation("回车", "确认输入，再按换行", tint: .teal)
                    operation("あ / ア", "切换平假名与片假名", tint: .indigo)
                    operation("日 / 英", "切换日语与英文", tint: .orange)
                }
                Text("字母上滑输入符号，长按空格拖动移动光标。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
        .navigationTitle("试打")
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    private func reload() {
        guard !fixed else { return }
        keyboardReady = Self.keyboardReported()
    }

    private var setupBanner: some View {
        NavigationLink { KeyboardSetupGuide() } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("还没检测到 Vime").font(.subheadline.weight(.semibold))
                    Text("添加键盘并开启完全访问后再来试打").font(.footnote).foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("去启用").font(.subheadline.weight(.semibold)).foregroundStyle(Color.vimeBlue)
                    .padding(.horizontal, 14).frame(minHeight: 34).background(.white, in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.vimeBlue, in: RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vime.home.setup")
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("长按地球键，选择 Vime 日本語").font(.footnote).foregroundStyle(.secondary)
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
            if !composition.isEmpty {
                Text("待确认：\(composition)").font(.footnote).foregroundStyle(Color.vimeBlue)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.vimeBlue.opacity(0.12), in: Capsule())
            }
            HStack {
                Button { focusRequest += 1 } label: {
                    Text("开始试打").font(.body.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).frame(minHeight: 44)
                        .background(Color.vimeBlue, in: Capsule())
                }
                .accessibilityIdentifier("vime.home.focus")
                Spacer()
                let clearable = !text.isEmpty || !composition.isEmpty
                Button { text = ""; composition = ""; clearRequest += 1 } label: {
                    Text("清空").foregroundStyle(clearable ? Color.primary : Color(uiColor: .tertiaryLabel))
                        .padding(.horizontal, 18).frame(minHeight: 44)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                }
                .disabled(!clearable)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .appCard(cornerRadius: 24)
    }

    private func operation(_ key: LocalizedStringResource, _ detail: LocalizedStringResource, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(key).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
        .accessibilityElement(children: .combine)
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
