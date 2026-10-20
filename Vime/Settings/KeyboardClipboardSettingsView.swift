import SwiftUI

struct KeyboardClipboardSettingsView: View {
    @AppStorage private var enabled: Bool
    @State private var confirming = false
    @State private var historyCount = 0
    @State private var historyError: String?
    private let history = ClipboardHistoryStore()
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
                Text("复制的文字会出现在候选栏，点击即可输入。仅在键盘显示时读取，相邻相同内容不重复提示。")
                    .font(.footnote).foregroundStyle(.secondary).lineSpacing(4)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                AppSettingsActionGroup {
                    Button(role: .destructive) {
                        Task {
                            do { try await history.clear(); historyCount = 0; historyError = nil }
                            catch { historyError = String(localized: "清空失败，请稍后重试") }
                        }
                    } label: {
                        AppSettingsActionRow(title: "清空剪贴板历史", subtitle: "当前 \(historyCount) 条记录", symbol: "trash", accessory: "")
                    }
                    .disabled(historyCount == 0)
                    .accessibilityIdentifier("vime.settings.clipboard.clear")
                }
                Text(historyError ?? String(localized: "历史仅在本机保留 24 小时，不上传。关闭此功能会清空历史。"))
                    .font(.footnote).foregroundStyle(.secondary).lineSpacing(4).padding(.horizontal, 4)
            }

            AppSettingsActionGroup {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    AppSettingsActionRow(title: "前往系统设置", subtitle: "管理完全访问与粘贴权限", symbol: "gearshape", accessory: "arrow.up.right")
                }
                Divider().padding(.leading, 52)
                NavigationLink { PrivacyPolicyView() } label: {
                    AppSettingsActionRow(title: "阅读隐私政策", subtitle: "了解剪贴板和输入数据的处理方式", symbol: "doc.text")
                }
            }

            DisclosureGroup("使用与权限说明") {
                VStack(alignment: .leading, spacing: 24) {
                    AppInformationSection("使用方式") {
                        Text("仅在键盘显示期间响应剪贴板变化，打开键盘时也会检查。主 App 不在后台自动读取。")
                        Text("读到与上一次不同的文字时，键盘候选栏会自动显示剪贴板预览。点击文字即可输入完整内容，点击右侧 × 收起提示；30 秒未操作会自动收起，记录仍保留在历史中。正在转换或使用数字键盘时优先显示正常候选与快捷符号。连续复制相同内容不会重复提示；A → B → A 时，最后的 A 会正常提示。")
                        Text("在键盘左上角菜单中打开“剪贴板历史”，点击记录即可输入，也可以清空历史。键盘隐藏时收起临时提示，历史仍保留。")
                        Text("只记录键盘获得授权后实际读取到的文本，不会获取系统过去的复制记录。图片、纯空白及超过 64 KB 的文字不保存；过期记录会在下次使用功能时清理。")
                    }
                    AppInformationSection("授权须知") {
                        Text("在 iOS“设置 → 通用 → 键盘 → 键盘 → Vime”中开启“允许完全访问”，并允许系统的粘贴请求。这是两项不同的授权。")
                        Text("若不希望每次确认，可在“设置 → App → Vime → 从其他 App 粘贴”中选择“允许”。如果弹窗显示的是当前使用的 App，请检查该 App 的对应设置。选项通常在首次请求后出现，名称和位置以系统显示为准。")
                        Text("拒绝后，不会反复申请读取同一份内容。首次授权或调整权限后，如未出现预览，请重新复制文字再打开键盘。")
                    }
                    AppInformationSection("数据处理") {
                        Text("剪贴板可能包含密码、验证码或其他敏感信息，请按需开启。历史保存在本机数据库，不上传、不纳入 Vime 的系统备份，也不因检测或粘贴操作直接写入学习词典。")
                        Text("最多保存 100 条记录、文本合计最多 1 MB，超出时先删除最旧记录。")
                        Text("点击输入后，文字会交给当前 App，其保存、同步等处理适用该 App 自身政策。此后正常输入所使用的光标上下文仍按 Vime 隐私政策在本机处理。")
                    }
                }.padding(.top, 16)
            }
            .font(.subheadline)
            .accessibilityIdentifier("vime.clipboard.instructions")
        }
        .navigationTitle("剪贴板").navigationBarTitleDisplayMode(.inline)
        .task(id: enabled) {
            do {
                if !enabled { try await history.clear(includingReadState: true) }
                historyCount = try await history.entries().count
                historyError = nil
            } catch { historyError = String(localized: "历史暂时无法读取，请稍后重试") }
        }
        .alert("开启自动读取剪贴板？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("了解并开启") { enabled = true }
        } message: {
            Text("键盘显示时会读取你复制的文本，可能包含敏感信息。最近 24 小时的记录仅保存在本机，不上传；你可以清空历史，关闭功能也会删除记录。iOS 仍会单独请求粘贴权限。")
        }
    }
}
