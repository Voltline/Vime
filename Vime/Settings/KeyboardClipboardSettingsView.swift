import SwiftUI

struct KeyboardClipboardSettingsView: View {
    @AppStorage private var enabled: Bool
    @State private var confirming = false
    @Environment(\.openURL) private var openURL

    init() {
        let preferences = KeyboardPreferences()
        _enabled = AppStorage(wrappedValue: preferences.clipboardSuggestions, "vime.clipboardSuggestions", store: preferences.store)
    }

    var body: some View {
        AppSettingsPage {
            VStack(alignment: .leading, spacing: 10) {
                AppSettingsActionGroup {
                    Toggle("自动读取剪贴板", isOn: Binding(get: { enabled }, set: { value in
                        if value { confirming = true } else { enabled = false }
                    }))
                    .padding(16)
                    .accessibilityIdentifier("vime.settings.clipboard.enabled")
                }
                Text("默认关闭。开启后，仅在键盘显示期间每 2 秒检查一次变化；连续显示期间内容未变时不重复读取。主 App 不在后台自动读取。")
                    .font(.footnote).foregroundStyle(.secondary).lineSpacing(4)
                    .padding(.horizontal, 4)
            }

            AppSettingsActionGroup {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    AppSettingsActionRow(title: "打开 iOS 中的 Vime 设置", subtitle: "管理完全访问及系统粘贴权限", symbol: "gearshape", accessory: "arrow.up.right")
                }
                Divider().padding(.leading, 52)
                NavigationLink { PrivacyPolicyView() } label: {
                    AppSettingsActionRow(title: "阅读隐私政策", subtitle: "了解剪贴板和输入数据的处理方式", symbol: "doc.text")
                }
            }

            AppInformationSection("使用方式") {
                Text("复制文字后，键盘顶部会出现剪贴板按钮。点击按钮，在候选栏预览；再点击预览即可输入完整文字。不会自动插入，也不会打乱正常候选。")
                Text("只暂存最新一条文本，不保存历史。图片、纯空白及超过 64 KB 的文字不提供候选；键盘隐藏或关闭本功能时清空暂存。")
            }
            AppInformationSection("授权须知") {
                Text("在 iOS“设置 → 通用 → 键盘 → 键盘 → Vime”中开启“允许完全访问”，并允许系统的粘贴请求。这是两项不同的授权。")
                Text("若不希望每次确认，可在“设置 → App → Vime → 从其他 App 粘贴”中选择“允许”。如果弹窗显示的是当前使用的 App，请检查该 App 的对应设置。选项通常在首次请求后出现，名称和位置以系统显示为准。")
                Text("拒绝后，不会定时反复申请读取同一份内容。首次授权或调整权限后，如未出现按钮，请重新复制文字再打开键盘。")
            }
            AppInformationSection("数据处理") {
                Text("剪贴板可能包含密码、验证码或其他敏感信息，请按需开启。Vime 不上传剪贴板内容，不保存历史，也不因检测或粘贴操作直接写入学习词典。")
                Text("点击输入后，文字会交给当前 App，其保存、同步等处理适用该 App 自身政策。此后正常输入所使用的光标上下文仍按 Vime 隐私政策在本机处理。")
            }
        }
        .navigationTitle("剪贴板").navigationBarTitleDisplayMode(.inline)
        .alert("开启自动读取剪贴板？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("了解并开启") { enabled = true }
        } message: {
            Text("键盘显示时会读取你复制的文本，可能包含敏感信息。内容仅在本机临时处理，不上传、不保存历史；你可以随时关闭。iOS 仍会单独请求粘贴权限。")
        }
    }
}
