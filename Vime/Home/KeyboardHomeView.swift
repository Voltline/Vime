import SwiftUI

struct KeyboardHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var text = ""
    @State private var composition = ""
    @State private var focusRequest = 0
    @State private var clearRequest = 0
    @State private var keyboardReady: Bool
    @State private var practiceIndex = 0
    /// Onboarding covers this page while the keyboard first reports in.
    @AppStorage("vime.onboarding.completed") private var onboardingCompleted = false
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
            practiceCard
            VStack(alignment: .leading, spacing: 10) {
                AppSectionTitle("键位速查")
                AppSettingsActionGroup {
                    operation("空格", "开始转换，再按切换候选", tint: .blue)
                    Divider().padding(.leading, 16)
                    operation("回车", "确认输入，再按换行", tint: .teal)
                    Divider().padding(.leading, 16)
                    operation("あ / ア", "切换平假名与片假名", tint: .indigo)
                    Divider().padding(.leading, 16)
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
        .onChange(of: onboardingCompleted) { reload() }
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
        // Typography sets the chip column; a fixed width would clip large type.
        let chip = Text(key).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        let detail = Text(detail).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { chip; detail }
            } else {
                HStack(spacing: 12) { chip.frame(minWidth: 72, alignment: .leading); detail }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Practice

    private var practice: TypingPractice { TypingPractice.sentences[practiceIndex % TypingPractice.sentences.count] }

    /// Follows the editor: the committed text is compared with the target.
    private var practiceCard: some View {
        let target = practice.target
        let matched = TypingPractice.matchedCount(typed: text, target: target)
        let done = matched == target.count
        var shown = AttributedString(String(target.prefix(matched)))
        shown.foregroundColor = Color.vimeBlue
        var rest = AttributedString(String(target.dropFirst(matched)))
        rest.foregroundColor = Color.primary
        shown.append(rest)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("跟打练习").font(.subheadline.weight(.semibold))
                Text(verbatim: "\(practiceIndex % TypingPractice.sentences.count + 1)/\(TypingPractice.sentences.count)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    practiceIndex += 1
                    text = ""; composition = ""; clearRequest += 1; focusRequest += 1
                } label: {
                    Label("换一句", systemImage: "arrow.triangle.2.circlepath").font(.subheadline)
                        .padding(.horizontal, 12).frame(minHeight: 34)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vime.home.practice.next")
            }
            Text(shown).font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("vime.home.practice.target")
            Text(verbatim: practice.romaji).font(.footnote.monospaced()).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ProgressView(value: Double(matched), total: Double(max(1, target.count)))
                .tint(done ? .green : .vimeBlue)
                .accessibilityLabel("练习进度")
            if done {
                Label("完成！换一句继续", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.green)
            } else {
                Text("在上方输入框照着打一遍，打对的部分会变成蓝色。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .appCard(cornerRadius: 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vime.home.practice")
    }
}

/// Short everyday sentences with the romaji that produces them.
struct TypingPractice: Equatable {
    let target: String
    let romaji: String

    static let sentences = [
        TypingPractice(target: "今日はいい天気ですね", romaji: "kyouha ii tenki desune"),
        TypingPractice(target: "ありがとうございます", romaji: "arigatou gozaimasu"),
        TypingPractice(target: "明日の会議は十時からです", romaji: "ashitano kaigiha juujikara desu"),
        TypingPractice(target: "駅まで歩いて五分です", romaji: "ekimade aruite gofun desu"),
        TypingPractice(target: "お疲れさまでした", romaji: "otsukaresama deshita"),
        TypingPractice(target: "よろしくお願いします", romaji: "yoroshiku onegaishimasu"),
    ]

    /// Leading characters of the target already typed. Surrounding whitespace
    /// is ignored so a trailing newline or space doesn't reset progress.
    static func matchedCount(typed: String, target: String) -> Int {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return zip(typed, target).prefix { $0 == $1 }.count
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
