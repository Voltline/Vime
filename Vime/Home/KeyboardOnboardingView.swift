import SwiftUI

/// What the app can observe of the setup. iOS lists added keyboards in the
/// global AppleKeyboards preference; full access is proved only by the
/// extension's own report, written the first time it runs with access.
struct KeyboardSetupProgress: Equatable {
    var added: Bool
    var fullAccess: Bool

    static let extensionBundleID = (Bundle.main.bundleIdentifier ?? "com.Voltline.Vime") + ".Keyboard"

    /// `AppleKeyboards` is a global preference listing the added keyboards.
    static func load(keyboards: [String] = UserDefaults.standard.stringArray(forKey: "AppleKeyboards") ?? [],
                     status: KeyboardExtensionStatus? = KeyboardExtensionStatus.load()) -> Self {
        return Self(added: status != nil || keyboards.contains { $0.hasPrefix(extensionBundleID) },
                    fullAccess: status?.fullAccess == true)
    }
}

/// First launch: three steps that check themselves off while the user is in
/// Settings, then hand over to 试打 without asking for confirmation.
struct KeyboardOnboardingView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var progress: KeyboardSetupProgress
    @State private var text = ""
    @State private var composition = ""
    @State private var focusRequest = 0
    /// Fixed state for rendering tests; the live page polls.
    private let fixed: Bool
    let onFinish: () -> Void

    init(progress: KeyboardSetupProgress? = nil, onFinish: @escaping () -> Void) {
        _progress = State(initialValue: progress ?? .load())
        fixed = progress != nil
        self.onFinish = onFinish
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("三步启用 Vime").font(.largeTitle.weight(.bold))
                    Text("完成后这页会自动跳到试打，不用回来确认。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    step(1, "添加键盘", done: progress.added,
                         detail: progress.added ? "已检测到 Vime 日本語" : "设置 › 通用 › 键盘 › 添加新键盘 › Vime")
                    step(2, "允许完全访问", done: progress.fullAccess,
                         detail: "用于按键声音、振动、共享词典与学习。输入内容只在本机处理，不会上传。",
                         path: "设置 › 通用 › 键盘 › 键盘 › Vime 日本語 › 允许完全访问")
                    step(3, "打一句试试", done: progress.fullAccess, detail: "长按地球键切到 Vime，输入 nihongo") {
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty && composition.isEmpty {
                                Text("点这里试打").foregroundStyle(.tertiary)
                                    .padding(.horizontal, 6).padding(.top, 4).allowsHitTesting(false)
                            }
                            SystemKeyboardEditor(text: $text, composition: $composition, focusRequest: focusRequest)
                                .frame(height: 64)
                        }
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("vime.onboarding.editor")
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(20).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { footer }
        .task {
            guard !fixed else { return }
            // The keyboard runs in another process; its report arrives through
            // the App Group while this page stays open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                progress = .load()
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active && !fixed { progress = .load() } }
        .onChange(of: progress.fullAccess) { _, ready in
            guard ready else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                onFinish()
            }
        }
        .accessibilityIdentifier("vime.onboarding")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if progress.fullAccess {
                Label("全部完成，正在打开试打…", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.green)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.added ? "正在等待完全访问…" : "正在等待添加键盘…")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                if progress.fullAccess { onFinish() }
                else if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text(progress.fullAccess ? "开始试打" : "打开系统设置").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.vimeBlue, in: Capsule())
            }
            .accessibilityIdentifier("vime.onboarding.primary")
            Button("先逛逛，稍后再说") { onFinish() }
                .font(.subheadline).frame(minHeight: 44)
                .accessibilityIdentifier("vime.onboarding.skip")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 560)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func step(_ number: Int, _ title: LocalizedStringResource, done: Bool, detail: LocalizedStringResource,
                      path: LocalizedStringResource? = nil) -> some View {
        step(number, title, done: done, detail: detail, path: path) { EmptyView() }
    }

    private func step<Extra: View>(_ number: Int, _ title: LocalizedStringResource, done: Bool,
                                   detail: LocalizedStringResource, path: LocalizedStringResource? = nil,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.vimeBlue.opacity(0.14))
                if done { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.white) }
                else { Text(verbatim: "\(number)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.vimeBlue) }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let path {
                    Text(path).font(.footnote.weight(.medium)).foregroundStyle(Color.vimeBlue)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.vimeBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
        .accessibilityElement(children: .contain)
        .accessibilityValue(done ? Text("已完成") : Text("未完成"))
    }
}

#Preview {
    KeyboardOnboardingView(progress: .init(added: true, fullAccess: false)) {}
}
