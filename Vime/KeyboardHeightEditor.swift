import SwiftUI
import UIKit

struct KeyboardHeightEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var factor = KeyboardPreferences().heightFactor
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("拖动键盘上方的横条，向上拉高、向下降低。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)
                KeyboardHeightPreview(factor: $factor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("恢复默认高度") { factor = 1 }
                Text("保存后同步到系统键盘；同步需要允许完全访问。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            .padding(.vertical, 12)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("键盘高度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { KeyboardPreferences().heightFactor = factor; dismiss() }
                }
            }
        }
    }
}

private struct KeyboardHeightPreview: UIViewRepresentable {
    @Binding var factor: Double
    func makeUIView(context: Context) -> KeyboardHeightAdjustmentView {
        let view = KeyboardHeightAdjustmentView()
        view.onChange = { factor = Double($0) }
        return view
    }
    func updateUIView(_ view: KeyboardHeightAdjustmentView, context: Context) { view.factor = CGFloat(factor) }
}
