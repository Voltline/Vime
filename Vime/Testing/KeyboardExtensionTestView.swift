import SwiftUI

/// Intentionally a normal document host, with no embedded Vime keyboard.
struct KeyboardExtensionTestView: View {
    @State private var text = ""
    @State private var composition = ""
    @State private var focusRequest = 0
    @State private var clearRequest = 0
    @State private var dismissRequest = 0
    @State private var sendRequest = 0
    @State private var events: [String] = []
    private let blue = Color(uiColor: UIColor(cgColor: VimeLogo.blue))
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("点击输入框，通过地球键选择 Vime 日本語\n这里使用 iOS 加载的键盘扩展")
                .font(.subheadline).foregroundStyle(.secondary)
            SystemKeyboardEditor(text: $text, composition: $composition, focusRequest: focusRequest,
                clearRequest: clearRequest, dismissRequest: dismissRequest, sendRequest: sendRequest, onSnapshot: { snapshot in
                    events.append(snapshot.description)
                    if events.count > 64 { events.removeFirst(events.count - 64) }
                })
                .frame(minHeight: 100, maxHeight: 170)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            Text(composition.isEmpty ? "待确认文本：无" : "待确认文本：\(composition)")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("vime.extension.marked")
            HStack {
                Button("开始输入") { focusRequest += 1 }
                    .accessibilityIdentifier("vime.extension.focus")
                Button("收起键盘") { dismissRequest += 1 }
                    .accessibilityIdentifier("vime.extension.dismiss")
                Spacer()
                Button("清空") {
                    text = ""; composition = ""; events = []; clearRequest += 1
                }.accessibilityIdentifier("vime.extension.clear")
                Button("复制测试记录") { UIPasteboard.general.string = events.joined(separator: "\n") }
            }.font(.subheadline).tint(blue)
#if DEBUG
            Button("模拟发送并保留键盘") { sendRequest += 1 }
                .accessibilityIdentifier("vime.extension.send")
#endif
            Text("可试：tennanhantenn → 展开候选 → 天 → 安 → 飯店\n点选前段后，剩余部分应继续显示为待确认文本")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
#if DEBUG
            Text(events.suffix(16).joined(separator: "\n"))
                .font(.system(size: 9, design: .monospaced))
                .frame(maxHeight: 90, alignment: .topLeading).clipped()
                .accessibilityIdentifier("vime.extension.events")
#endif
        }
        .padding(20)
        .navigationTitle("键盘扩展试打")
        .navigationBarTitleDisplayMode(.inline)
#if DEBUG
        .task { await runAutomaticLifecycleIfRequested() }
#endif
    }

#if DEBUG
    /// Counterexample for XCTest's accessibility cache: drive the native host
    /// without querying any accessibility elements in the keyboard process.
    /// This checks appearance/teardown only; it does not simulate key input.
    @MainActor private func runAutomaticLifecycleIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--keyboard-extension-auto-cycles"),
              index + 1 < arguments.count, let requested = Int(arguments[index + 1]), requested > 0 else { return }
        let cycles = min(500, requested)
        do {
            // Cold extension startup may exceed one second. Establish the
            // initial connection before measuring repeated host transitions.
            focusRequest += 1
            try await Task.sleep(for: .seconds(5))
            dismissRequest += 1
            try await Task.sleep(for: .seconds(2))
            for cycle in 1...cycles {
                focusRequest += 1
                try await Task.sleep(for: .seconds(2))
                dismissRequest += 1
                try await Task.sleep(for: .seconds(1))
                NSLog("VIME_EXTENSION_AUTOMATIC_LIFECYCLE cycle=%d", cycle)
            }
            NSLog("VIME_EXTENSION_AUTOMATIC_COMPLETED cycles=%d", cycles)
        } catch { NSLog("VIME_EXTENSION_AUTOMATIC_CANCELLED") }
    }
#endif
}
