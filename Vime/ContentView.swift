import SwiftUI

struct ContentView: View {
    @State private var text = ""
    @State private var composition = ""
    @State private var focusRequest = 0
    @State private var showingGuide = false
    @State private var showingNotices = false
    private let green = Color(red: 0.08, green: 0.65, blue: 0.39)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center, spacing: 15) {
                        Text("あ")
                            .font(.system(size: 37, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 68, height: 68)
                            .background(green, in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Vime").font(.system(size: 30, weight: .semibold))
                            Text("日语，轻松打出来。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 12)

                    HStack(spacing: 8) {
                        Label("26 键", systemImage: "keyboard")
                        Text("·")
                        Text("罗马音")
                        Text("·")
                        Label("离线输入", systemImage: "checkmark.shield")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("试着输入一句日语").font(.headline)
                            Spacer()
                            if !text.isEmpty {
                                Button("清空") { text = ""; composition = "" }
                                    .font(.subheadline)
                                    .tint(.secondary)
                            }
                        }
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("点这里，输入 nihongo…")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 17)
                                    .padding(.top, 17)
                                    .allowsHitTesting(false)
                            }
                            KeyboardSandbox(text: $text, composition: $composition, focusRequest: focusRequest)
                                .frame(height: 142)
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        Text(composition.isEmpty ? "nihongo → にほんご → 日本語" : "正在输入：\(composition)")
                            .font(.caption)
                            .foregroundStyle(composition.isEmpty ? Color.secondary : green)
                        Button { focusRequest += 1 } label: {
                            Text("开始试打")
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(green)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("在其他 App 中使用").font(.headline)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "plus.circle").foregroundStyle(green)
                            Text("前往系统设置，添加 Vime 日本語键盘，然后通过地球键切换。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Button { showingGuide = true } label: {
                            HStack {
                                Text("查看启用步骤")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .font(.subheadline.weight(.medium))
                        }
                        .tint(green)
                    }
                    .padding(18)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("几个顺手的小操作").font(.headline)
                        hint("空格", "开始转换，再按一次切换候选")
                        hint("回车", "确认当前输入；确认后再按即可换行")
                        hint("あ / ア", "切换平假名与片假名")
                        hint("日/英", "切换日语与英文输入")
                    }

                    Button("开源词典与许可") { showingNotices = true }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showingGuide) { guide }
            .sheet(isPresented: $showingNotices) { notices }
        }
    }

    private func hint(_ key: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.caption.weight(.medium))
                .frame(width: 55, height: 27)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 5))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).padding(.top, 3)
        }
    }

    private var guide: some View {
        NavigationStack {
            List {
                Section("添加键盘") {
                    Text("1. 打开 iPhone「设置」")
                    Text("2. 进入「通用 → 键盘 → 键盘」")
                    Text("3. 点击「添加新键盘」，选择 Vime")
                }
                Section("开始输入") {
                    Text("打开任意支持第三方键盘的 App，长按地球键，选择「Vime 日本語」。")
                    Text("基本输入无需完全访问。按键声和振动请进入「设置 → 通用 → 键盘 → 键盘 → Vime 日本語」，开启「允许完全访问」。点击键盘左上角的调节图标，可设置声音、振动强度、数字布局和长音键。")
                }
                Section("系统限制") {
                    Text("密码输入框和部分 App 会使用系统键盘。数字、电话和邮箱输入框会根据系统允许的方式切换布局。")
                }
            }
            .navigationTitle("启用 Vime")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingGuide = false } } }
        }
    }

    private var notices: some View {
        NavigationStack {
            ScrollView {
                Text(licenseText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
            }
            .navigationTitle("开源许可")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingNotices = false } } }
        }
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "开源词典许可文件未找到。" }
        return "Vime 使用 azooKey 开源日语转换引擎及其默认词典。日语转换离线完成，不加载神经模型。\n\n" + text
    }
}

#Preview { ContentView() }
