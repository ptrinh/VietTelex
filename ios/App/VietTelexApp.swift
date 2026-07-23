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
    /// "1.0.0 · build 24/07/2026" — ngày build = mtime của binary.
    static var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let exe = (Bundle.main.executableURL ?? Bundle.main.bundleURL).path
        let date = (try? FileManager.default.attributesOfItem(atPath: exe)[.modificationDate]) as? Date ?? Date()
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"
        return "\(v) · build \(f.string(from: date))"
    }

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
                    Link(destination: URL(string: "https://ptrinh.github.io/viettelex/")!) {
                        Label("Website", systemImage: "globe")
                    }
                    Link(destination: URL(string: "https://ptrinh.github.io/viettelex/learn/")!) {
                        Label("Học gõ Telex (mở trình duyệt)", systemImage: "graduationcap")
                    }
                    Link(destination: URL(string: "https://github.com/ptrinh/viettelex")!) {
                        Label("Mã nguồn trên GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: { Text("Tài nguyên") }
                Section {
                    LabeledContent("Phiên bản", value: Self.versionLine)
                    Text("© Phil Trinh \(Calendar.current.component(.year, from: Date()))")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Không Full Access · Không mạng · Không thu thập dữ liệu")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Giới thiệu") }
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
            .tint(.blue)
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
    private var simpleTelex = true
    @AppStorage("quickTelex", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var quickTelex = false
    @AppStorage("modernTone", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var modernTone = false
    @AppStorage("liveSpellCheck", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var liveSpellCheck = true
    @AppStorage("autoRestore", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var autoRestore = true
    @AppStorage("showSpaceLogo", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var showSpaceLogo = true
    @AppStorage("showSuggestions", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var showSuggestions = true
    @AppStorage("filterSensitive", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var filterSensitive = true

    var body: some View {
        Section {
            Toggle("Telex đơn giản", isOn: $simpleTelex)
            Toggle("Bỏ dấu tự do", isOn: $freeMarking)
            Toggle("Gõ nhanh (Quick Telex)", isOn: $quickTelex)
            Toggle("Bỏ dấu kiểu mới", isOn: $modernTone)
        } header: { Text("Kiểu gõ") }

        Section {
            Toggle("Tự khôi phục từ tiếng Anh", isOn: $autoRestore)
            Toggle("Kiểm tra chính tả khi gõ", isOn: $liveSpellCheck)
            Toggle("Hiện logo Vᴛ", isOn: $showSpaceLogo)
            // Thanh gợi ý bật = tự học từ hay dùng (learnWords đi theo, không
            // còn toggle riêng — quyết định 2026-07-24)
            Toggle("Thanh gợi ý", isOn: $showSuggestions)
            Toggle("Lọc từ nhạy cảm khỏi gợi ý", isOn: $filterSensitive)
            Button("Xóa từ đã học", role: .destructive) {
                if let dir = FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.viettelex") {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("userlm.plist"))
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("userlm.json"))
                }
            }
        } header: { Text("Tính năng") } footer: {
            Text("Cài đặt áp dụng ngay lần mở bàn phím kế tiếp.")
        }
    }
}
