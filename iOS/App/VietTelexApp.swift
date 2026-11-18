// Container app: onboarding + Telex settings (shared with the keyboard via the
// App Group) + a link that opens the Learn site in the browser. Deliberately
// minimal — no WebView, no third-party dependencies (docs/ios-app.md).
import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

@main
struct VietTelexApp: App {
    init() {
        // Onboarding (docs/ONBOARDING-SPEC.md §5): nhận diện người dùng cũ TRƯỚC mọi chuyển đổi bên
        // dưới (chúng ghi key vào App Group ngay lần mở đầu của người mới).
        OnboardingFlow.migrate(UserDefaults(suiteName: AppFlavor.appGroup), settingKeys: Self.onboardingSettingKeys)
        // Apple Intelligence (Sửa lỗi, Plus): màn Plus / Tính Năng hỏi model có dùng được không.
        AIAvailability.probe = { IntelligenceEngine.status() }
        // "Chiều cao hàng phím": mức 0 = bàn phím iPhone gốc (bỏ công tắc "Kích thước như bàn
        // phím iPhone" #119). Chuyển đổi MỘT lần giá trị cũ để người dùng cũ không thấy đổi
        // (KeyGeometry.RowAdjust) — bàn phím tự tính trong bộ nhớ nếu app chưa chạy.
        let screen = UIScreen.main.bounds.size
        KeyGeometry.RowAdjust.migrateIfNeeded(UserDefaults(suiteName: AppFlavor.appGroup),
                                              pad: UIDevice.current.userInterfaceIdiom == .pad,
                                              portraitWidth: min(screen.width, screen.height),
                                              extraStateKeys: BackupSettings.all.map(\.key) + KeyStyleStore.legacyKeys)
        // "Tuỳ chỉnh nâng cao" chung cũ → riêng theme đang chọn; "Trắng hồng" (đã bỏ) → Hệ thống +
        // màu nhấn hồng. Một lần, lặp lại vô hại (ThemeSettings.migrateStored) — bàn phím tự chuyển
        // trong bộ nhớ nếu app chưa chạy.
        ThemeSettings.migrateStored(UserDefaults(suiteName: AppFlavor.appGroup))
        ThemeSettings.refreshCustom(UserDefaults(suiteName: AppFlavor.appGroup))   // Giao diện JSON
        // Tệp tải về (phông / ảnh) không theme nào còn dùng (xoá trên máy khác qua iCloud…) ⇒ dọn, nền.
        DispatchQueue.global(qos: .utility).async {
            ThemeAssetStore.collectGarbage(dir: ThemeAssetStore.defaultDir, referenced: ThemeAssetStore.referencedKeys(
                specs: Array(CustomThemeStore.load(UserDefaults(suiteName: AppFlavor.appGroup)).values),
                styles: Array(KeyStyleStore.parse(UserDefaults(suiteName: AppFlavor.appGroup)?
                    .string(forKey: KeyStyleStore.key)).values)))
        }
        // Ảnh emoji vẽ sẵn cho bàn phím (RAM-AUDIT.md §4b): dựng nền nếu thiếu/cũ.
        EmojiAtlasBuilder.ensureFresh()
        #if DEBUG
        let g = UserDefaults(suiteName: AppFlavor.appGroup)
        NSLog("DBG kbFullAccess=%d kbLastSeen=%f",
              g?.bool(forKey: "kbFullAccess") ?? false ? 1 : 0,
              g?.double(forKey: "kbLastSeen") ?? -1)
        #endif
    }
    var body: some Scene {
        WindowGroup { RootView() }
    }

    /// Key cài đặt người dùng — có bất kỳ key nào ⇒ bản nâng cấp (người dùng cũ).
    static var onboardingSettingKeys: Set<String> {
        Set(BackupSettings.all.map(\.key)).union(BackupStore.localKey.values).union(KeyStyleStore.legacyKeys)
            .union(KeyGeometry.StockSize.userStateKeys).union([BackupStore.templatesKey, BackupStore.shortcutsKey])
    }
}

/// Màu nhấn thích ứng sáng/tối — xanh đậm ở nền sáng (user: .blue vẫn nhạt),
/// xanh sáng hơn ở nền tối để chữ trắng vẫn nổi rõ.
let accentBlue = Color(UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.30, green: 0.52, blue: 1.00, alpha: 1)
        : UIColor(red: 0.02, green: 0.32, blue: 0.84, alpha: 1)
})

/// Bàn phím VietTelex đã được bật trong Cài đặt chưa — quét danh sách bàn phím
/// đang hoạt động tìm bundle id của extension.
func isKeyboardEnabled() -> Bool {
    UITextInputMode.activeInputModes.contains {
        ($0.value(forKey: "identifier") as? String)?
            .hasPrefix(AppFlavor.keyboardBundleID) == true
    }
}

/// Các tab của app — floating menu kiểu iOS ở đáy (user 2026-07-24).
/// Tab Mẫu Câu chỉ hiện khi bật tính năng trong Tính Năng → Gõ tắt & mẫu câu.
enum AppTab: CaseIterable {
    case kieuGo, tinhNang, mauCau, gioiThieu
    var title: String {
        switch self {
        case .kieuGo: return L("Kiểu Gõ")
        case .tinhNang: return L("Tính Năng")
        case .mauCau: return L("Mẫu Câu")
        case .gioiThieu: return L("Giới Thiệu")
        }
    }
    var icon: String {
        switch self {
        case .kieuGo: return "keyboard"
        case .tinhNang: return "slider.horizontal.3"
        case .mauCau: return "text.quote"
        case .gioiThieu: return "info.circle"
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardEnabled = isKeyboardEnabled()
    @State private var pasteReady = Self.readPasteReady()
    /// Đọc thẳng App Group (bàn phím ghi từ process khác — @AppStorage không chắc
    /// nhận thay đổi chéo process), làm mới mỗi lần app active.
    static func readPasteReady() -> Bool {
        let d = UserDefaults(suiteName: AppFlavor.appGroup)
        return d?.bool(forKey: "kbFullAccess") == true && d?.bool(forKey: "pasteNoPrompt") == true
    }
    @State private var tryItText = ""
    /// DEBUG `-focusTryIt 1`: tự focus ô thử gõ khi mở app (chụp màn hình bàn phím trên
    /// simulator không cần chạm — vd. đo bố cục iPhone Duo gập/mở).
    @FocusState private var tryItFocused: Bool
    @State private var tab: AppTab = Self.initialTab
    /// Bản Debug: `-startTab tinhnang` (launch argument) mở thẳng tab — chụp màn hình tự động.
    private static var initialTab: AppTab {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "startTab") == "tinhnang" { return .tinhNang }
        #endif
        return .kieuGo
    }
    @State private var barCollapsed = false
    /// Onboarding người dùng mới (ONBOARDING-SPEC §2) — màn đang hiện, nil = không.
    @State private var onboarding: OnboardingFlow.Screen?
    /// Thẻ một lần cho người dùng cũ (§5).
    @AppStorage(OnboardingFlow.tipKey, store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var mixedTip = false
    @AppStorage("vniMode", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var tipVniMode = false
    /// Trang con có bàn phím mẫu ở đáy (Luyện vuốt) ẩn FloatingTabBar — nó đè hàng
    /// phím dưới (Phil 27/09/2026).
    @ObservedObject private var tabBarVisibility = TabBarVisibility.shared
    /// Bàn phím đang hiện → ẩn FloatingTabBar: overlay đáy bị iOS đẩy lên theo bàn
    /// phím và đè đúng dải khung "kính" phía trên bàn phím (host vẽ) → thanh gợi ý
    /// trông như bị cắt (user 25/09/2026).
    @State private var keyboardShown = false
    /// viettelex://dich → trang Dịch trên máy (chọn ngôn ngữ, tải gói).
    @State private var showTranslate = false
    @AppStorage("templatesEnabled", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var templatesEnabled = true
    /// Ngôn ngữ giao diện ("vi" | "en", mặc định "vi" — KHÔNG theo máy). Đổi ở Tính Năng
    /// → dựng lại toàn bộ cây view (id bên dưới) nên áp dụng ngay, không cần mở lại app.
    @AppStorage(L10n.defaultsKey, store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var uiLanguage = "vi"

    private var visibleTabs: [AppTab] {
        templatesEnabled ? AppTab.allCases
                         : AppTab.allCases.filter { $0 != .mauCau }
    }

    /// "1.0.0 · build 24/07/2026" — ngày build = mtime của binary.
    static var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let exe = (Bundle.main.executableURL ?? Bundle.main.bundleURL).path
        let date = (try? FileManager.default.attributesOfItem(atPath: exe)[.modificationDate]) as? Date ?? Date()
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"
        return "\(v) · build \(f.string(from: date))"
    }

    // Bar tự chế nổi THẬT trên content (user 2026-07-24): system tab bar
    // reserve nguyên dải đáy — hai bên pill lộ nền list thành 2 khối chắn.
    // Overlay + contentMargins để content cuộn xuyên dưới capsule glass.
    var body: some View {
        // Đồng bộ bảng tra trước khi con dựng lại (kể cả khi iCloud/sao lưu đổi key).
        let _ = L10n.apply(uiLanguage)
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    switch tab {
                    case .kieuGo: kieuGoTab
                    case .tinhNang: TinhNangSections()
                    case .mauCau: MauCauSections()
                    case .gioiThieu: gioiThieuTab
                    }
                }
                .navigationTitle(tab == .kieuGo ? "VietTelex" : tab.title)
                .bottomBarScrollMargin()
                .collapseBarOnScroll($barCollapsed)
                // Ô "Thử gõ": cuộn là đóng bàn phím. KHÔNG gắn TapGesture lên List —
                // nó nuốt tap của mọi Button trong row (+, Import, Export, Xoá từ đã học…).
                .scrollDismissesKeyboard(.immediately)
                // Tìm cài đặt chọn một mục "Gõ lẫn tiếng Anh" ⇒ danh sách Kiểu Gõ vừa dựng cuộn tới đó.
                .onAppear { if tab == .kieuGo { MixedTypingFocus.shared.scrollIfPending(proxy) } }
                // Đang ở sẵn tab Kiểu Gõ (thẻ người dùng cũ mở nhóm) ⇒ không dựng lại ⇒ cuộn ở đây.
                .onReceive(MixedTypingFocus.shared.$scrollTick.dropFirst()) { _ in
                    if tab == .kieuGo { MixedTypingFocus.shared.scrollIfPending(proxy) }
                }
            }
        }
        // Đổi tab ⇒ dựng lại stack: trang con đang mở (vd Tính Năng → Giao diện) không
        // còn đè lên tab mới.
        // … và đổi ngôn ngữ cũng dựng lại để mọi chữ lấy bản dịch mới.
        .id("\(tab)|\(uiLanguage)")
        .overlay(alignment: .bottom) {
            if !keyboardShown && !tabBarVisibility.hidden {
                FloatingTabBar(selected: $tab, tabs: visibleTabs, collapsed: barCollapsed)
                    .id(uiLanguage)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        .onChange(of: scenePhase) { phase in
            // Quay lại từ Cài đặt → cập nhật trạng thái bật bàn phím ngay.
            if phase == .active {
                keyboardEnabled = isKeyboardEnabled()
                refreshOnboarding()
                pasteReady = Self.readPasteReady()
                // Plus: đọc entitlement đã verify → cờ App Group cho bàn phím.
                Task { await PlusShared.model.refreshEntitlements() }
                ICloudSync.shared.start()          // tắt ⇒ không làm gì
                EmojiAtlasBuilder.ensureFresh()    // vừa cập nhật iOS ⇒ font emoji có thể đổi
            } else if phase == .background {
                ICloudSync.shared.syncNow()        // đẩy thay đổi vừa sửa lên iCloud
            }
        }
        // Ô tìm cài đặt (Tính Năng) chọn mục thuộc nhóm "Gõ lẫn tiếng Anh" ⇒ sang tab Kiểu Gõ.
        .onReceive(MixedTypingFocus.shared.$request.compactMap { $0 }) { item in
            MixedTypingFocus.shared.request = nil
            MixedTypingFocus.shared.open(item)
            tab = .kieuGo
        }
        #if DEBUG
        // `-mixedTypingOpen englishByFrequency`: giả lập chọn kết quả tìm kiếm (chụp màn hình tự động).
        .onAppear {
            if let raw = UserDefaults.standard.string(forKey: "mixedTypingOpen"), let item = MixedTypingItem(rawValue: raw) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MixedTypingFocus.shared.request = item }
            }
        }
        #endif
        .onAppear { refreshOnboarding() }
        .fullScreenCover(isPresented: Binding(get: { onboarding != nil }, set: { if !$0 { onboarding = nil } })) {
            OnboardingView(start: onboarding ?? .choose, keyboardEnabled: keyboardEnabled) { onboarding = nil }
        }
        .onChange(of: templatesEnabled) { on in
            if !on && tab == .mauCau { tab = .tinhNang }
        }
        // Bubble ⚙️ trên bàn phím → viettelex://maucau → nhảy thẳng tab Mẫu Câu.
        .onOpenURL { url in
            guard url.scheme == AppFlavor.urlScheme else { return }
            if url.host == "maucau" {
                templatesEnabled = true   // user chủ động mở từ keyboard
                tab = .mauCau
            }
            if url.host == "dich" { showTranslate = true }   // chip "thiếu gói dịch" trên bàn phím
        }
        .sheet(isPresented: $showTranslate) {
            if #available(iOS 26.0, *) {
                NavigationStack { TranslateSettingsView() }
            }
        }
        #if DEBUG
        // `-wallpaperEditorDemo 1`: mở thẳng trình chỉnh ảnh nền với ảnh mẫu — chụp màn hình tự động.
        .fullScreenCover(isPresented: .constant(UserDefaults.standard.bool(forKey: "wallpaperEditorDemo"))) {
            WallpaperEditorView.demo()
        }
        #endif
    }

    /// Màn onboarding cần hiện (đang hiện thì giữ nguyên — quay lại từ Cài đặt không đổi màn).
    private func refreshOnboarding() {
        guard onboarding == nil else { return }
        #if DEBUG
        // `-mixedTipDemo 1`: hiện thẻ người dùng cũ (chụp màn hình tự động).
        if UserDefaults.standard.bool(forKey: "mixedTipDemo") { mixedTip = true }
        // `-onboardingDemo choose|tryIt [-onboardingDemoProfile mixed]`: chụp màn hình tự động.
        if let demo = UserDefaults.standard.string(forKey: "onboardingDemo") {
            if let p = UserDefaults.standard.string(forKey: "onboardingDemoProfile").flatMap(OnboardingProfile.init(rawValue:)) {
                OnboardingSettings.apply(p, to: UserDefaults(suiteName: AppFlavor.appGroup))
            }
            onboarding = demo == "tryIt" ? .tryIt : .choose
            return
        }
        #endif
        onboarding = OnboardingFlow.screen(UserDefaults(suiteName: AppFlavor.appGroup), keyboardEnabled: keyboardEnabled)
    }

    @ViewBuilder private var kieuGoTab: some View {
        Section {
            OnboardingCard(enabled: keyboardEnabled, pasteReady: pasteReady)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        // Thẻ chỉ tới nhóm Gõ lẫn tiếng Anh: chọn VNI thì nhóm ẩn ⇒ chưa hiện thẻ (giữ cờ cho Telex).
        if mixedTip, !MixedTypingUI.groupHidden(vniMode: tipVniMode) {
            Section {
                MixedTypingTipCard(onOpen: {
                    mixedTip = false
                    MixedTypingFocus.shared.request = .section
                }, onDismiss: {
                    withAnimation { mixedTip = false }
                })
            }
        }
        Section {
            // KHÔNG .autocorrectionDisabled(): bàn phím coi ô autocorrection == .no là
            // ô mã/username → passthrough (literal, tắt Telex) — ô thử gõ mất tác dụng
            // (log Debug mode 25/09/2026: composing=0 mọi phím).
            // .sentences: để thử được "Tự động viết hoa đầu câu" (.never làm bàn phím tôn
            // trọng ô và không bao giờ tự bật shift — Phil 28/09).
            TextField(L("Thử gõ tại đây…"), text: $tryItText, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.sentences)
                .focused($tryItFocused)
                #if DEBUG
                .onAppear {
                    if UserDefaults.standard.bool(forKey: "focusTryIt") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { tryItFocused = true }
                    }
                }
                #endif
        } header: { Text(L("Thử gõ")) } footer: {
            Text(L("Bấm 🌐 dưới bàn phím để chuyển sang VietTelex, rồi gõ thử: vieejt → việt."))
        }
        KieuGoSection()
        // Ngay sau Kiểu gõ — nhóm thu gọn (mặc định đóng), docs/ONBOARDING-SPEC.md §4.
        MixedTypingSection()
    }

    @ViewBuilder private var gioiThieuTab: some View {
        // Sao lưu & đồng bộ chuyển sang Tính Năng (27/09/2026).
        // Logo + tên app trên đầu tab (user 2026-07-24), như About của macOS.
        Section {
            VStack(spacing: 10) {
                if let icon = vtAppIcon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                } else {
                    Text("⌨️").font(.system(size: 64))
                }
                Text("VietTelex").font(.title2.bold())
                Text(L("Bàn phím Telex tiếng Việt"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
        Section { PlusEntryRow() }
        Section {
            Link(destination: L10n.guideURL(os: "ios")) {
                Label(L("Hướng dẫn sử dụng"), systemImage: "book")
            }
            Link(destination: URL(string: "https://ptrinh.github.io/viettelex/")!) {
                Label("Website", systemImage: "globe")
            }
            Link(destination: URL(string: "https://ptrinh.github.io/viettelex/learn/")!) {
                Label(L("Học gõ Telex"), systemImage: "graduationcap")
            }
            Link(destination: URL(string: "https://github.com/ptrinh/viettelex")!) {
                Label(L("Mã nguồn trên GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
        } header: { Text(L("Tài nguyên")) }
        Section {
            LabeledContent(L("Phiên bản"), value: Self.versionLine)
            HStack {
                Text(verbatim: "© Phil Trinh \(String(Calendar.current.component(.year, from: Date())))")
                Spacer()
                Link("vt@trinh.uk", destination: URL(string: "mailto:vt@trinh.uk")!)
                    .foregroundStyle(accentBlue)
            }
            .font(.footnote).foregroundStyle(.secondary)
            Text(L("Không thu thập dữ liệu · Không theo dõi · Mã nguồn mở"))
                .font(.footnote).foregroundStyle(.secondary)
            // Ghi công theo giấy phép dữ liệu bigram gõ vuốt (vnlm.bin) — docs/DATA-SOURCES.md
            Link(destination: URL(string: "https://github.com/ptrinh/viettelex/blob/main/docs/DATA-SOURCES.md")!) {
                Text(L(SettingCaption.swipeDataCredit))
                    .multilineTextAlignment(.leading)
            }
            .font(.footnote).foregroundStyle(.secondary)
            // Liệt kê ĐỦ mọi tính năng cần quyền (FullAccessNotice + kiểm hasFullAccess ở bàn phím) —
            // L10nTests.testFullAccessFooterListsEveryGatedFeature giữ danh sách khỏi lệch.
            Text(L("Toàn quyền Truy cập là tuỳ chọn, chỉ dùng cho: Rung phím, Âm thanh phím, Nút Dán, Lịch sử clipboard, Mẫu câu động, lưu từ đã học."))
                .font(.footnote).foregroundStyle(.secondary)
        } header: { Text(L("Giới thiệu")) }
        // Gỡ lỗi chuyển sang Tính Năng → "Nâng cao / Gỡ lỗi" (SETTINGS-CLEANUP-SPEC §4, 05/11/2026).
    }
}

/// Thanh tab nổi Liquid Glass tự chế: capsule ôm đúng nội dung, content cuộn
/// xuyên bên dưới. iOS 26 dùng glassEffect thật (khúc xạ + interactive);
/// iOS cũ fallback material + viền specular. Pill chọn morph bằng
/// matchedGeometryEffect + spring.
/// Trang con xin ẩn FloatingTabBar khi đang hiện (`.hidesFloatingTabBar()`).
final class TabBarVisibility: ObservableObject {
    static let shared = TabBarVisibility()
    @Published var hidden = false
}

extension View {
    /// Ẩn FloatingTabBar khi view này đang hiện (vd trang có bàn phím mẫu ở đáy).
    func hidesFloatingTabBar() -> some View {
        onAppear { TabBarVisibility.shared.hidden = true }
            .onDisappear { TabBarVisibility.shared.hidden = false }
    }
}

struct FloatingTabBar: View {
    @Binding var selected: AppTab
    var tabs: [AppTab] = AppTab.allCases
    /// Cuộn xuống → thu về icon-only (mô phỏng minimize của system bar);
    /// cuộn lên → bung lại đủ label.
    var collapsed = false
    @Namespace private var pillNS

    private var buttons: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { t in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        selected = t
                    }
                } label: {
                    // Icon TRÊN text (user 2026-07-24): 4 tab nằm ngang mà
                    // icon+label cùng hàng thì bar dài quá bề ngang màn hình.
                    VStack(spacing: 2) {
                        Image(systemName: t.icon).font(.subheadline.weight(.medium))
                        if !collapsed {
                            Text(t.title).font(.caption2.weight(.semibold))
                                .lineLimit(1).fixedSize()
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, collapsed ? 11 : 12)
                    .padding(.vertical, collapsed ? 9 : 6)
                    .foregroundStyle(selected == t ? Color.white : Color.primary)
                    .background {
                        if selected == t {
                            Capsule()
                                .fill(accentBlue)
                                .matchedGeometryEffect(id: "pill", in: pillNS)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                buttons.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                buttons
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .white.opacity(0.06)],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
            }
        }
        .padding(.bottom, 8)
    }
}

extension View {
    /// Chừa lối cuộn cho bar nổi: hàng cuối cuộn lên được trên capsule
    /// (iOS 17+; iOS 16 chấp nhận hàng cuối lấp dưới bar một chút).
    @ViewBuilder func bottomBarScrollMargin() -> some View {
        if #available(iOS 17.0, *) {
            self.contentMargins(.bottom, 72, for: .scrollContent)
        } else {
            self
        }
    }

    /// Theo dõi hướng cuộn để thu/bung bar nổi (iOS 18+; máy cũ giữ bar full).
    /// Ngưỡng 3pt lọc rung tay; chỉ thu khi đã cuộn quá 40pt khỏi đỉnh.
    @ViewBuilder func collapseBarOnScroll(_ collapsed: Binding<Bool>) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
                guard abs(new - old) > 3 else { return }
                let want = new > old && new > 40
                if want != collapsed.wrappedValue {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        collapsed.wrappedValue = want
                    }
                }
            }
        } else {
            self
        }
    }

    /// Nền card theo Liquid Glass (iOS 26); iOS cũ giữ material xám nhẹ.
    @ViewBuilder func glassCard(cornerRadius: CGFloat = 18) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular,
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Nút hành động chính: glass prominent (iOS 26) / borderedProminent (cũ),
    /// cùng tint accentBlue.
    @ViewBuilder func prominentGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(accentBlue)
        } else {
            self.buttonStyle(.borderedProminent).tint(accentBlue)
        }
    }
}

/// Tab Mẫu Câu — quản lý câu soạn sẵn cho nút ☰ trên bàn phím
/// (App Group key "userTemplates", mỗi entry ["label": …, "text": …]).
struct MauCauSections: View {
    private static let store = UserDefaults(suiteName: AppFlavor.appGroup)
    /// Mặc định từ ios-mau-cau.yml bundle theo build — cùng file với keyboard.
    static let bundledDefaults: [TemplateItem] = {
        guard let url = Bundle.main.url(forResource: "ios-mau-cau", withExtension: "yml"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [TemplateItem(label: "👋", text: "Chào buổi sáng")] }
        return parseYAML(text)
    }()

    static func load() -> [TemplateItem] {
        DynamicSnippets.migrateIfNeeded(store)
        guard let raw = store?.array(forKey: "userTemplates") as? [[String: String]] else {
            return bundledDefaults
        }
        return raw.compactMap { e in
            guard let t = e["text"], !t.isEmpty else { return nil }
            return TemplateItem(label: e["label"] ?? "", text: t)
        }
    }

    @State private var templates = MauCauSections.load()
    @State private var newLabel = ""
    @State private var newText = ""
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var notice: String?
    @State private var editingIndex: Int?
    @State private var editLabel = ""
    @State private var editText = ""

    /// Báo lý do ở ngay dưới hàng đang thao tác (thêm mới / sửa).
    @State private var addNotice: String?
    /// addNotice là thông báo thành công (xám) hay lý do từ chối (cam) — trước đây
    /// dò tiền tố "Đã", vỡ khi giao diện tiếng Anh.
    @State private var addNoticeOK = false

    /// Lưu dòng đang sửa; rỗng/trùng câu dòng khác → báo lý do, giữ nguyên ô sửa.
    private func commitEdit() {
        guard let i = editingIndex, templates.indices.contains(i) else { editingIndex = nil; return }
        switch TemplateEdit.update(templates, at: i, label: editLabel, text: editText) {
        case .ok(let items):
            templates = items
            editingIndex = nil
            addNotice = nil
            persist()
        case .rejected(let r):
            addNotice = TemplateEdit.message(r, items: templates); addNoticeOK = false
        }
    }

    /// Nút ⊕: thêm, hoặc báo lý do không thêm (trước đây trùng câu → return IM LẶNG).
    private func commitAdd() {
        endEditing()
        switch TemplateEdit.add(templates, label: newLabel, text: newText) {
        case .ok(let items):
            templates = items
            addNotice = L("Đã thêm mẫu câu (dòng %@).", items.count); addNoticeOK = true
            newLabel = ""; newText = ""
            persist()
        case .rejected(let r):
            addNotice = TemplateEdit.message(r, items: templates); addNoticeOK = false
        }
    }

    /// Chốt chữ đang soạn (marked text của bàn phím) vào binding trước khi đọc ô.
    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func persist() {
        Self.store?.set(templates.map { ["label": $0.label, "text": $0.text] },
                        forKey: "userTemplates")
    }

    var body: some View {
        Section {
            ForEach(Array(templates.enumerated()), id: \.element.id) { i, t in
                if editingIndex == i {
                    // Sửa tại chỗ (không dùng sheet/alert — trong List chúng không hiện).
                    VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("👋", text: $editLabel)
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                        Divider()
                        TextField(L("Mẫu câu"), text: $editText, axis: .vertical)
                            .lineLimit(1...4)
                        Button { endEditing(); commitEdit() } label: {
                            Image(systemName: "checkmark.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        Button { editingIndex = nil; addNotice = nil } label: {
                            Image(systemName: "xmark.circle").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    if let addNotice, !addNoticeOK {
                        Text(addNotice).font(.footnote).foregroundStyle(.orange)
                    }
                    }
                } else {
                    Button {
                        editLabel = t.label; editText = t.text; editingIndex = i; addNotice = nil
                    } label: {
                        HStack {
                            Text(t.label.isEmpty ? "💬" : t.label).frame(minWidth: 30)
                            Text(t.text).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onDelete { offsets in
                templates.remove(atOffsets: offsets)
                persist()
            }
            if templates.isEmpty {
                Text(L("Chưa có mẫu câu nào.")).foregroundStyle(.secondary)
            }
        } header: { Text(L("Mẫu câu (%@)", templates.count)) } footer: {
            Text(L("Bấm ☰ trên bàn phím để chèn nhanh. Chạm một dòng để sửa, vuốt trái để xoá. Label (emoji/chữ ngắn) giúp bubble trên bàn phím gọn hơn."))
        }

        Section {
            HStack {
                TextField("👋", text: $newLabel)
                    .frame(width: 44)
                    .multilineTextAlignment(.center)
                Divider()
                TextField(L("Thêm mẫu câu…"), text: $newText, axis: .vertical)
                    .lineLimit(1...3)
                // KHÔNG .disabled theo newText: chữ đang soạn (marked text) chưa vào
                // binding → nút xám dù ô có chữ; bấm luôn được, lý do báo ở footer.
                Button { commitAdd() } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Thêm mẫu câu"))
            }
        } header: { Text(L("Thêm mới")) } footer: {
            if let addNotice {
                Text(addNotice).foregroundStyle(addNoticeOK ? Color.secondary : Color.orange)
            } else {
                Text(L("Ô nhỏ bên trái là label (không bắt buộc)."))
            }
        }

        Section {
            FullAccessNotice(reason: L("Mẫu câu động"))
        } header: { Text(L("Mẫu câu động (https://)")) } footer: {
            Text(L("Mẫu có nội dung bắt đầu bằng https:// sẽ fetch dữ liệu NGAY LÚC BẤM và chèn kết quả (tối đa 1000 bytes) — ví dụ 🌐 IP chèn địa chỉ IP hiện tại. Chưa cấp Toàn quyền thì bàn phím không có mạng, bấm sẽ chèn chính URL."))
        }

        Section {
            Button {
                showImporter = true
            } label: { Label("Import…", systemImage: "square.and.arrow.down") }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.yaml, .plainText, .text, .data]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    notice = L("Không đọc được file.")
                    return
                }
                let imported = Self.parseYAML(text)
                let before = templates.count
                for item in imported
                where !templates.contains(where: { $0.text == item.text }) {
                    templates.append(item)
                }
                persist()
                let added = templates.count - before
                notice = L("Đã thêm %@/%@ mẫu", added, imported.count)
                    + (imported.count > added ? L(" (trùng bị bỏ qua).") : ".")
            }
            Button {
                showExporter = true
            } label: { Label("Export ra YAML…", systemImage: "square.and.arrow.up") }
            .fileExporter(isPresented: $showExporter,
                          document: TemplatesDocument(text: Self.exportYAML(templates)),
                          contentType: .yaml,
                          defaultFilename: "viettelex-mau-cau") { result in
                if case .success = result { notice = L("Đã export %@ mẫu.", templates.count) }
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text(L("YAML phẳng, mỗi dòng “- \"👋 | Chào buổi sáng\"” (label | câu) hoặc “- \"câu\"”. Import gộp thêm, không thay thế."))
        }
    }

    static func parseYAML(_ text: String) -> [TemplateItem] { TemplateEdit.parseYAML(text) }
    static func exportYAML(_ items: [TemplateItem]) -> String { TemplateEdit.exportYAML(items) }
}

/// FileDocument tối giản cho export YAML.
struct TemplatesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.yaml, .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Icon app từ asset catalog (AppIcon) — đọc tên file icon từ Info.plist.
/// Dùng chung cho OnboardingCard và header tab Giới Thiệu.
let vtAppIcon: UIImage? = {
    guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
          let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
          let files = primary["CFBundleIconFiles"] as? [String],
          let name = files.last else { return nil }
    return UIImage(named: name)
}()

struct OnboardingCard: View {
    let enabled: Bool
    /// Ẩn hướng dẫn Dán khi đã xong cả hai bước: bàn phím báo có Toàn quyền
    /// (kbFullAccess) VÀ lần dán gần nhất iOS không hỏi (pasteNoPrompt).
    var pasteReady = false

    @ViewBuilder private var hero: some View {
        if let icon = vtAppIcon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            Text("⌨️").font(.system(size: 52))
        }
    }

    /// Một dòng checklist: xong = tick xanh, chưa = số thứ tự.
    private func step(_ n: Int, _ title: String, done: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle.fill")
                .foregroundStyle(done ? Color.green : Color.secondary)
        }
    }

    /// Tuỳ chọn thêm (user 25/09/2026): nút Dán trên thanh gợi ý cần Toàn quyền, và
    /// iOS hỏi "Allow Paste" MỖI lần trừ khi chọn Cho phép — không có API nào để bàn
    /// phím bên thứ ba dán mà không hỏi (UIPasteControl không vẽ trong extension).
    /// Trang Cài đặt của app chứa CẢ công tắc Toàn quyền (mục Bàn phím) lẫn
    /// "Dán từ ứng dụng khác" → một nút mở thẳng trang đó.
    @ViewBuilder private var pasteSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Để dán nhanh từ thanh gợi ý"), systemImage: "doc.on.clipboard")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("1. Bàn phím → VietTelex → bật Cho phép Toàn quyền"))
                Text(L("2. Dán từ ứng dụng khác → chọn Cho phép"))
                Text(L("Nếu chưa thấy mục 2: bấm nút Dán trên bàn phím một lần để iOS hỏi, rồi quay lại đây."))
                    .foregroundStyle(.tertiary)
            }
            .font(.footnote).foregroundStyle(.secondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text(L("Mở Cài đặt VietTelex")).font(.subheadline.weight(.semibold))
            }
            // .borderless: nút trong dòng List có nhiều control — kiểu mặc định để cả
            // dòng nuốt chạm, nút "không làm gì" (user 25/09/2026, như "Xem log" cũ).
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    var body: some View {
        VStack(spacing: 14) {
            if enabled {
                // Đã bật — thu gọn, chỉ xác nhận + nhắc thử gõ.
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2).foregroundStyle(Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Bàn phím đã bật")).font(.headline)
                        Text(L("Thử gõ ngay bên dưới."))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !pasteReady { pasteSetup }
            } else {
                hero
                Text(L("Bật bàn phím VietTelex")).font(.title3.bold())
                VStack(alignment: .leading, spacing: 10) {
                    step(1, L("Bật bàn phím trong Cài đặt"), done: enabled)
                    step(2, L("Thử gõ ngay bên dưới"), done: false)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Cài đặt → Cài đặt chung → Bàn phím → Bàn phím"))
                        Text(L("Thêm bàn phím mới… → VietTelex"))
                        Text(L("Khi gõ, bấm 🌐 để chuyển sang VietTelex"))
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.leading, 30)
                }
                .font(.subheadline)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text(L("Mở Cài đặt")).font(.headline).frame(maxWidth: .infinity)
                }
                .prominentGlassButton()
                if !pasteReady { pasteSetup }
            }
        }
        .padding(enabled ? 14 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .padding(.vertical, 6)
    }
}

/// Cảnh báo + nút mở Settings cho các tính năng cần Toàn quyền Truy cập
/// (Rung phím, Mẫu câu động https://) — dùng chung.
struct FullAccessNotice: View {
    var reason: String
    // Cờ do keyboard extension ghi vào App Group mỗi lần hiện (kbFullAccess) —
    // app chứa không tự hỏi được iOS về Full Access của extension.
    @State private var state = FullAccessNotice.check()

    /// granted: hasFullAccess extension báo về lần chạy gần nhất.
    /// kbSeen: bàn phím đã chạy bản có heartbeat ít nhất một lần chưa —
    /// chưa chạy thì cờ granted không có ý nghĩa.
    static func check() -> (granted: Bool, kbSeen: Bool) {
        guard let g = UserDefaults(suiteName: AppFlavor.appGroup) else {
            return (false, false)
        }
        return (g.bool(forKey: "kbFullAccess"),
                g.double(forKey: "kbLastSeen") > 0)
    }

    var body: some View {
        Group {
            if state.granted {
                Label {
                    Text(L("Đã cấp Toàn quyền Truy cập."))
                        .font(.footnote).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                notice
                if !state.kbSeen {
                    Text(L("Nếu đã bật rồi: mở bàn phím VietTelex một lần (gõ ở app bất kỳ) để app nhận trạng thái quyền."))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        // Refresh khi view hiện lại (đổi tab) và khi quay lại từ
        // Settings/bàn phím — cờ chỉ đổi ngoài app.
        .onAppear { state = Self.check() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            state = Self.check()
        }
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(L("%@ cần Toàn quyền Truy cập. Bật trong Cài đặt → Bàn phím → Cho phép Toàn quyền Truy cập. VietTelex không thu thập dữ liệu.", reason))
                    .font(.footnote).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text(L("Mở Cài đặt để cấp Toàn quyền"))
                    .font(.subheadline.weight(.medium))
            }
            // .borderless bắt buộc: Button nằm chung row trong List mà không
            // set style thì List nuốt tap (row nhiều phần tử tương tác).
            .buttonStyle(.borderless)
            .tint(accentBlue)
        }
    }
}

/// Toggle kèm chú giải nhỏ bên dưới tiêu đề — dùng chung cho 2 tab settings.
func settingToggle(_ title: String, _ caption: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(caption).font(.footnote).foregroundStyle(.secondary)
        }
    }
    .tint(.green)   // giữ màu toggle hệ thống — .tint(accentBlue) ở TabView lan xuống
}

/// Tab Kiểu Gõ — mục "Kiểu gõ" (SETTINGS-CLEANUP-SPEC §4): Telex/VNI · Tự động viết hoa đầu câu ·
/// › Nâng cao (TypingAdvancedPage). EngineBridge đọc cùng key qua App Group.
struct KieuGoSection: View {
    @AppStorage("vniMode", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var vniMode = false
    @AppStorage("numberRow", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var numberRow = false
    @AppStorage("autoCapitalize", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var autoCapitalize = true

    var body: some View {
        Section {
            // Telex / VNI loại trừ nhau → segmented (như radio macOS). Chọn VNI TỰ BẬT hàng
            // phím số (số là phím dấu — không có hàng số thì mỗi dấu phải chuyển plane 123);
            // tắt lại được ở Tính năng → Phím & cử chỉ.
            // Một hàng: tên (+ chú thích VNI ngay dưới) bên trái, nút chọn bên phải — như Android.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Kiểu gõ"))
                    if vniMode {
                        Text(L(SettingCaption.vni)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Picker(L("Kiểu gõ"), selection: Binding(
                    get: { vniMode ? "vni" : "telex" },
                    set: { v in
                        let vni = v == "vni"
                        if vni, !vniMode { numberRow = true }
                        vniMode = vni
                    })) {
                    Text("Telex").tag("telex")
                    Text("VNI").tag("vni")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            // iOS không cho bàn phím bên thứ ba đọc công tắc Tự động viết hoa của hệ thống.
            settingToggle(L(SettingLabel.autoCapitalize), L(SettingCaption.autoCapitalize), isOn: $autoCapitalize)
            NavigationLink { TypingAdvancedPage() } label: {
                SubPageRow(title: L(SettingLabel.typingAdvanced), subtitle: L(SettingLabel.typingAdvancedSubtitle))
            }
        } header: { Text(L("Kiểu gõ")) } footer: {
            Text(L("Cài đặt áp dụng ngay lần mở bàn phím kế tiếp."))
        }
    }
}

/// Kiểu Gõ › Kiểu gõ › "Nâng cao": tuỳ chọn ít người cần đổi. Nằm ngay dưới bộ chọn Telex/VNI ⇒
/// mục chỉ-Telex ẨN khi chọn VNI (SettingsDeps.typingAdvancedRows, SETTINGS-CLEANUP-SPEC §0.4/§6).
/// Teencode chạy cả ở VNI ⇒ luôn hiện. Cùng key như trước; đổi lại Telex thấy y như cũ.
struct TypingAdvancedPage: View {
    @AppStorage("freeMarking", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var freeMarking = true
    @AppStorage("simpleTelex", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var simpleTelex = true
    @AppStorage("quickTelex", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var quickTelex = false
    @AppStorage("modernTone", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var modernTone = false
    @AppStorage("teencode", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var teencode = false
    @AppStorage("autoCircumflex", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var autoCircumflex = false
    @AppStorage("vniMode", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var vniMode = false

    var body: some View {
        let rows = SettingsDeps.typingAdvancedRows(vniMode: vniMode)
        List {
            Section {
                ForEach(rows, id: \.self) { r in
                    switch r {
                    case .simpleTelex:
                        settingToggle(L(SettingLabel.simpleTelex), L(SettingCaption.simpleTelex), isOn: $simpleTelex)
                    case .freeMarking:
                        settingToggle(L(SettingLabel.freeMarking), L(SettingCaption.freeMarking), isOn: $freeMarking)
                    case .quickTelex:
                        settingToggle(L(SettingLabel.quickTelex), L(SettingCaption.quickTelex), isOn: $quickTelex)
                    case .modernTone:
                        settingToggle(L(SettingLabel.modernTone), L(SettingCaption.modernTone), isOn: $modernTone)
                    case .teencode:
                        settingToggle(L(SettingLabel.teencode), L(SettingCaption.teencode), isOn: $teencode)
                    case .autoCircumflex:
                        settingToggle(L(SettingLabel.autoCircumflex), L(SettingCaption.autoCircumflex), isOn: $autoCircumflex)
                    }
                }
            } footer: {
                Text(L("Cài đặt áp dụng ngay lần mở bàn phím kế tiếp."))
            }
        }
        .navigationTitle(L(SettingLabel.typingAdvanced))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarScrollMargin()
    }
}

// Tab Tính Năng: TinhNangSections + các trang con ở FeaturePages.swift.

/// Debug mode (25/09/2026): lấy log "gõ nhanh rớt chữ" không cần cáp/Console.
/// Bàn phím ghi touchlog.txt vào App Group (cần Full Access). Log hiện NGAY trong
/// section qua một Toggle — Button mở sheet / present UIKit đều "không hiện ra gì"
/// trên máy user (25/09/2026); Toggle trong cùng Form thì chạy chắc chắn.
struct DebugSection: View {
    @AppStorage("debugTouchLog", store: UserDefaults(suiteName: AppFlavor.appGroup))
    private var debugTouchLog = false
    @State private var showLog = false
    @State private var logText = ""
    @State private var clearLog = false

    static var logURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppFlavor.appGroup)?
            .appendingPathComponent("touchlog.txt")
    }
    private func reload() {
        logText = Self.logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    var body: some View {
        Section {
            settingToggle(L("Debug mode — ghi log chạm phím"),
                          L(SettingCaption.debugLogIos),
                          isOn: $debugTouchLog)
            if debugTouchLog {
                settingToggle(L("Hiện log (tự copy vào clipboard)"),
                              L(SettingCaption.showLog),
                              isOn: $showLog)
                settingToggle(L("Xoá log"), L(SettingCaption.clearLog), isOn: $clearLog)
                if showLog {
                    Text(logText.isEmpty
                         ? L("Chưa có log. Bật \"Cho phép Toàn quyền\" cho bàn phím VietTelex (Cài đặt → Chung → Bàn phím → Bàn phím → VietTelex), rồi gõ thử.")
                         : L("%@ dòng — đã copy vào clipboard.\n\n", logText.split(separator: "\n").count) + logText.split(separator: "\n").suffix(80).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: { Text(L("Gỡ lỗi")) }
        .onChange(of: showLog) { on in
            guard on else { return }
            reload()
            if !logText.isEmpty { UIPasteboard.general.string = TouchLogAlerts.alertsFirst(logText) }
        }
        .onChange(of: clearLog) { on in
            guard on else { return }
            if let u = Self.logURL { try? FileManager.default.removeItem(at: u) }
            logText = ""
            clearLog = false
        }
    }
}
