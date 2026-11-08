#if DEBUG
import SwiftUI

/// Debug-only page for the Chinese engine: its own letter keys drive Rime
/// directly, so it works before the keyboard extension has a Chinese mode.
/// Launch with --chinese-tryout. Its user dictionary is separate from the
/// keyboard's.
struct ChineseTryOutView: View {
    @State private var text = ""
    @State private var state = RimeState()
    @State private var engine: RimeEngine?
    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: text.isEmpty ? " " : text)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading).padding(10)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("vime.chinese.text")
            Text(verbatim: state.preedit.isEmpty ? " " : state.preedit)
                .font(.callout.monospaced()).foregroundStyle(.secondary)
                .accessibilityIdentifier("vime.chinese.preedit")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(state.candidates.prefix(30).enumerated()), id: \.offset) { index, candidate in
                        Button { send(.select(index)) } label: { Text(verbatim: candidate.text).font(.title3) }
                            .accessibilityIdentifier("vime.chinese.candidate.\(index)")
                    }
                }.frame(minHeight: 36)
            }
            Spacer()
            Text(verbatim: "\(state.duration.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            VStack(spacing: 8) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 5) {
                        ForEach(row.map(String.init), id: \.self) { letter in
                            key(letter) { send(.type(letter)) }
                        }
                    }
                }
                HStack(spacing: 5) {
                    key("'") { send(.type("'")) }
                    key("⌫") { if state.isComposing { send(.backspace) } else if !text.isEmpty { text.removeLast() } }
                    key("␣") { state.candidates.isEmpty ? (text += " ") : send(.select(0)) }
                    key("⏎") { state.isComposing ? send(.commitInput) : (text += "\n") }
                }
            }
        }
        .padding()
        .navigationTitle(Text(verbatim: "Rime"))
        .task {
            guard engine == nil, let data = RimeEngine.bundledData else { return }
            let user = URL.applicationSupportDirectory.appendingPathComponent("RimeTryOut")
            engine = RimeEngine(data: data, userDirectory: user)
        }
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label).font(.body).frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 6))
        .accessibilityIdentifier("vime.chinese.key.\(label)")
    }

    private func send(_ command: RimeEngine.Command) {
        engine?.send(command) { result in
            Task { @MainActor in
                if let commit = result.commit { text += commit }
                state = result
            }
        }
    }
}
#endif
