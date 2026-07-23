// Container app: onboarding + Telex settings (shared with the keyboard via the
// App Group) + a link that opens the Learn site in the browser. Deliberately
// minimal — no WebView, no third-party dependencies (docs/ios-app.md).
import SwiftUI

@main
struct VietTelexApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    OnboardingCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                SettingsSection()
                Section {
                    Link(destination: URL(string: "https://ptrinh.github.io/viettelex/learn/")!) {
                        Label("Học gõ Telex (mở trình duyệt)", systemImage: "graduationcap")
                    }
                    Link(destination: URL(string: "https://github.com/ptrinh/viettelex")!) {
                        Label("Mã nguồn trên GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: { Text("Tài nguyên") }
                Section {
                    LabeledContent("Phiên bản",
                                   value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    Text("Không Full Access · Không mạng · Không thu thập dữ liệu")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("VietTelex")
        }
    }
}

struct OnboardingCard: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("⌨️").font(.system(size: 52))
            Text("Bật bàn phím VietTelex").font(.title3.bold())
            VStack(alignment: .leading, spacing: 10) {
                Label("Cài đặt → Cài đặt chung → Bàn phím → Bàn phím", systemImage: "1.circle.fill")
                Label("Thêm bàn phím mới… → Tiếng Việt (VietTelex)", systemImage: "2.circle.fill")
                Label("Khi gõ, bấm 🌐 để chuyển sang VietTelex", systemImage: "3.circle.fill")
            }
            .font(.subheadline)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Mở Cài đặt").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
        .padding(.vertical, 6)
    }
}

/// Telex settings — the same keys EngineBridge reads from the App Group.
struct SettingsSection: View {
    @AppStorage("freeMarking", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var freeMarking = true
    @AppStorage("simpleTelex", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var simpleTelex = false
    @AppStorage("liveSpellCheck", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var liveSpellCheck = true
    @AppStorage("autoRestore", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var autoRestore = true
    @AppStorage("showSpaceLogo", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var showSpaceLogo = true
    @AppStorage("showSuggestions", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var showSuggestions = true
    @AppStorage("learnWords", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var learnWords = true
    @AppStorage("filterSensitive", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var filterSensitive = true

    var body: some View {
        Section {
            Toggle("Bỏ dấu tự do", isOn: $freeMarking)
            Toggle("Simple Telex (w lẻ giữ nguyên)", isOn: $simpleTelex)
            Toggle("Kiểm tra chính tả khi gõ", isOn: $liveSpellCheck)
            Toggle("Tự khôi phục từ tiếng Anh", isOn: $autoRestore)
            Toggle("Hiện logo Vᴛ trên phím space", isOn: $showSpaceLogo)
            Toggle("Thanh gợi ý (emoji)", isOn: $showSuggestions)
            Toggle("Học từ hay dùng (trên máy)", isOn: $learnWords)
            Toggle("Lọc từ nhạy cảm khỏi gợi ý", isOn: $filterSensitive)
            Button("Xóa từ đã học", role: .destructive) {
                if let dir = FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.viettelex") {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("userlm.plist"))
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("userlm.json"))
                }
            }
        } header: { Text("Cách gõ") } footer: {
            Text("Cài đặt áp dụng ngay lần mở bàn phím kế tiếp. Ví dụ: vieetj → việt, dd → đ, w → ư.")
        }
    }
}
