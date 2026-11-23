// Tab Tính Năng (27/09/2026, thu gọn 05/11/2026 — docs/SETTINGS-CLEANUP-SPEC.md §4): trang chính là
// các nhóm (icon + tên + tóm tắt trạng thái), mỗi nhóm mở một trang con. Ô tìm kiếm trên đầu lọc
// theo tên/từ khoá rồi mở đúng trang (chỉ mục + danh sách trang: SettingsIndex.swift). KHÔNG đổi
// key/mặc định/cổng Plus: các trang con đọc/ghi cùng key App Group như trước. Android dùng cùng
// cấu trúc (ui/FeaturePages.kt).
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let featureDefaults = UserDefaults(suiteName: AppFlavor.appGroup)

extension FeaturePage {
    var icon: String {
        switch self {
        case .suaLoi: return "checkmark.seal"
        case .goVuot: return "hand.draw"
        case .goTat: return "text.quote"
        case .phim: return "keyboard"
        case .giaoDien: return "paintpalette"
        case .riengTu: return "lock"
        case .nangCao: return "wrench.and.screwdriver"
        }
    }
    var color: Color {
        switch self {
        case .suaLoi: return .green
        case .goVuot: return .purple
        case .goTat: return .teal
        case .phim: return .gray
        case .giaoDien: return .pink
        case .riengTu: return .indigo
        case .nangCao: return .brown
        }
    }
    var guideURL: URL? { guideAnchor.map { L10n.guideURL(os: "ios", anchor: $0) } }

    @ViewBuilder var destination: some View {
        switch self {
        case .suaLoi: SuaLoiPage()
        case .goVuot: GoVuotPage()
        case .goTat: GoTatPage()
        case .phim: PhimPage()
        case .giaoDien: ThemeSettingsView()
        case .riengTu: FeaturePageList(page: .riengTu) { RiengTuSection(); SaoLuuSection() }
        case .nangCao: FeaturePageList(page: .nangCao) { DebugSection() }
        }
    }
}

extension SettingsIndexEntry.Condition {
    /// Mục chỉ hiện trong kết quả khi điều kiện đúng trên máy này.
    var isMet: Bool {
        switch self {
        case .always: return true
        case .phoneOnly: return UIDevice.current.userInterfaceIdiom == .phone
        case .addTones: return PlusGate.isUnlocked(.sentenceDiacritics)
        case .aiProofread: return PlusGate.isUnlocked(.aiProofread) && PlusFeature.aiProofread.isAvailableOnDevice
        case .textTools: return PlusGate.isUnlocked(.textTools)
        case .translate: return PlusFeature.translate.isAvailableOnDevice && PlusGate.isUnlocked(.translate)
        case .iCloud: return ICloudSync.isUnlocked()
        }
    }
}

/// Nhãn nhỏ cạnh tên cài đặt: "Thử nghiệm" (mặc định) hoặc "Máy học" (Gõ vuốt — Phil 12/11/2026).
struct ExperimentalBadge: View {
    var text: String = L("Thử nghiệm")
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.purple.opacity(0.15)))
            .foregroundStyle(.purple)
    }
}

/// Toggle có nhãn "Thử nghiệm" (cùng kiểu settingToggle).
func experimentalToggle(_ title: String, _ caption: String, isOn: Binding<Bool>,
                        badge: String = L("Thử nghiệm")) -> some View {
    Toggle(isOn: isOn) {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) { Text(title); ExperimentalBadge(text: badge) }
            Text(caption).font(.footnote).foregroundStyle(.secondary)
        }
    }
    .tint(.green)
}

/// Công tắc phụ thuộc (SETTINGS-CLEANUP-SPEC §0.4): KHÔNG ẩn — `reason` khác nil thì làm mờ, khoá
/// và ghi lý do ngay dưới chú thích ("Cần bật …", "Chỉ áp dụng cho Telex").
func dependentToggle(_ title: String, _ caption: String, isOn: Binding<Bool>,
                     reason: String?, experimental: Bool = false) -> some View {
    Toggle(isOn: isOn) {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) { Text(title); if experimental { ExperimentalBadge() } }
            Text(caption).font(.footnote).foregroundStyle(.secondary)
            if let reason {
                Label(L(reason), systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    .tint(.green)
    .disabled(reason != nil)
}

/// Dòng mở trang con: tên + dòng phụ (tóm tắt / những gì bên trong).
struct SubPageRow: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// Tên + MỘT dòng chú thích ngay dưới, cùng một hàng (06/11/2026) — hàng có bộ chọn bên dưới.
func settingTitle(_ title: String, _ caption: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(caption).font(.footnote).foregroundStyle(.secondary)
    }
}

/// Ô icon màu kiểu app Cài đặt.
struct FeatureIcon: View {
    let page: FeaturePage
    var body: some View {
        Image(systemName: page.icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(page.color))
    }
}

/// Dòng "Tìm hiểu thêm" cuối mỗi trang con (trang không có mục Hướng dẫn: chỉ chú thích).
struct GuideLinkSection: View {
    let page: FeaturePage
    var body: some View {
        Section {
            if let url = page.guideURL {
                Link(destination: url) {
                    Label(L("Tìm hiểu thêm trong Hướng dẫn"), systemImage: "book")
                }
            }
        } footer: {
            Text(L("Cài đặt áp dụng ngay lần mở bàn phím kế tiếp."))
        }
    }
}

/// Khung trang con: List + tiêu đề inline + link Hướng dẫn + chừa lối cho bar nổi.
struct FeaturePageList<Content: View>: View {
    let page: FeaturePage
    @ViewBuilder var content: Content
    var body: some View {
        List {
            content
            GuideLinkSection(page: page)
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarScrollMargin()
    }
}

/// Trang đích của một kết quả tìm kiếm (mục ở tab Kiểu Gõ cấp 1 đi đường khác — đổi tab).
@ViewBuilder func searchDestination(_ location: SettingsLocation) -> some View {
    switch location {
    case .page(let p): p.destination
    case .feedback: FeedbackPage()
    case .typingAdvanced: TypingAdvancedPage()
    case .mixedAdvanced(let m): MixedAdvancedPage(highlight: m)
    case .mixed: EmptyView()
    }
}

// ============================================================== Trang chính

/// Tab Tính Năng — ô tìm kiếm + các nhóm kèm tóm tắt trạng thái hiện tại.
struct TinhNangSections: View {
    @State private var query = ""
    @State private var shortcutCount = ShortcutStore.load().count
    @State private var theme = ThemeSettings.load(featureDefaults)

    // Chỉ để dựng dòng tóm tắt — trang con ghi, @AppStorage tự cập nhật.
    @AppStorage("liveSpellCheck", store: featureDefaults) private var liveSpellCheck = true
    /// Chọn VNI ⇒ kết quả "Nâng cao" của Gõ lẫn tiếng Anh mở nhóm (dòng ghi chú) — SettingsLocation.resolved.
    @AppStorage("vniMode", store: featureDefaults) private var vniMode = false
    @AppStorage("autoCorrect", store: featureDefaults) private var autoCorrect = false
    @AppStorage("showSuggestions", store: featureDefaults) private var showSuggestions = true
    @AppStorage("emojiSuggest", store: featureDefaults) private var emojiSuggest = true
    @AppStorage("swipeTyping", store: featureDefaults) private var swipeTyping = false
    @AppStorage("swipeFuto", store: featureDefaults) private var swipeFuto = false
    @AppStorage(ShortcutFile.enabledKey, store: featureDefaults) private var shortcutsEnabled = true
    @AppStorage("templatesEnabled", store: featureDefaults) private var templatesEnabled = true
    @AppStorage("numberRow", store: featureDefaults) private var numberRow = false
    @AppStorage(KeyGeometry.numberRowFullHeightKey, store: featureDefaults) private var numberRowFullHeight = false
    @AppStorage("swipeKeyCommands", store: featureDefaults) private var swipeKeyCommands = false
    @AppStorage("autoSpaceAfterPunct", store: featureDefaults) private var autoSpaceAfterPunct = false
    @AppStorage("hapticFeedback", store: featureDefaults) private var hapticFeedback = false
    @AppStorage("keySound", store: featureDefaults) private var keySound = false
    @AppStorage(PlusFeature.textToolsKey, store: featureDefaults) private var textToolsEnabled = true
    @AppStorage("oneHandMode", store: featureDefaults) private var oneHandMode = "off"
    @AppStorage(SpaceSideKey.key, store: featureDefaults) private var spaceSideKey = SpaceSideKey.defaultValue.rawValue
    @AppStorage(SymbolReturn.key, store: featureDefaults) private var symbolReturn = SymbolReturn.defaultValue.rawValue
    @AppStorage(EmojiKeyPlacement.key, store: featureDefaults) private var emojiKeyPlacement = EmojiKeyPlacement.defaultValue.rawValue
    @AppStorage(LargeKeys.key, store: featureDefaults) private var largeKeys = LargeKeys.defaultValue
    @AppStorage("clipboardHistory", store: featureDefaults) private var clipboardHistory = false
    @AppStorage("incognitoMode", store: featureDefaults) private var incognitoMode = false
    @AppStorage(ICloudSync.enabledKey, store: featureDefaults) private var iCloudSync = false
    @AppStorage("debugTouchLog", store: featureDefaults) private var debugTouchLog = false
    @AppStorage(L10n.defaultsKey, store: featureDefaults) private var uiLanguage = "vi"

    private static func join(_ parts: [(Bool, String)], none: String) -> String {
        let on = parts.filter(\.0).map(\.1)
        return on.isEmpty ? none : on.joined(separator: " · ")
    }

    private func summary(_ p: FeaturePage) -> String {
        switch p {
        case .suaLoi:
            return Self.join([(liveSpellCheck, L("Kiểm tra chính tả")), (autoCorrect, L("Tự sửa")),
                              (showSuggestions, L("Thanh gợi ý")), (showSuggestions && emojiSuggest, "Emoji")],
                             none: L("Đang tắt"))
        case .goVuot:
            guard swipeTyping else { return L("Đang tắt") }
            return Self.join([(true, L("Bật")), (swipeFuto, "Neural")], none: "")
        case .goTat:
            let st = shortcutsEnabled ? (shortcutCount == 0 ? L("Gõ tắt bật") : L("Gõ tắt: %@ mục", shortcutCount)) : L("Gõ tắt tắt")
            let tools = textToolsEnabled && PlusGate.isUnlocked(.textTools)
            return st + " · " + (templatesEnabled ? L("Mẫu câu bật") : L("Mẫu câu tắt"))
                + (tools ? " · " + L("Công cụ văn bản") : "")
        case .phim:
            return Self.join([(numberRow, numberRowFullHeight ? L("Hàng số cao") : L("Hàng số")),
                              (SpaceSideKey.parse(spaceSideKey) != .defaultValue, L("Phím cạnh dấu cách")),
                              (EmojiKeyPlacement.parse(emojiKeyPlacement) != .defaultValue, L("Nút emoji")),
                              (largeKeys && UIDevice.current.userInterfaceIdiom == .phone
                                && LargeKeys.settingVisible(SpaceSideKey.parse(spaceSideKey)), L("Cỡ phím chấm và phẩy")),
                              (swipeKeyCommands, L("Vuốt sao chép/dán")),
                              (autoSpaceAfterPunct, L("Cách sau dấu câu")),
                              (SymbolReturn.parse(symbolReturn) != .defaultValue, L("Về bàn chữ sau ký hiệu")),
                              (hapticFeedback, L("Rung")), (keySound, L("Âm phím")),
                              (oneHandMode != "off", L("Một tay"))], none: L("Mặc định"))
        case .giaoDien:
            let wp = theme.wallpaperActive(fileExists: Wallpaper.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            return theme.effectiveTheme.title + (wp ? " · " + L("Ảnh nền") : "")
                + (theme.keyboardTransparency > 0 || theme.labelTransparency > 0 ? " · " + L("Trong suốt") : "")
        case .riengTu:
            return (clipboardHistory ? L("Lịch sử clipboard bật") : L("Lịch sử clipboard tắt"))
                + (incognitoMode ? " · " + L("Ẩn danh") : "")
                + (iCloudSync && ICloudSync.isUnlocked() ? " · " + L("Đồng bộ iCloud bật") : "")
        case .nangCao:
            return debugTouchLog ? L("Đang ghi log chạm phím") : L("Log chạm phím cho tester")
        }
    }

    var body: some View {
        // Ngôn ngữ giao diện — mục ĐẦU TIÊN của Tính Năng, nhãn song ngữ để ai cũng tìm thấy.
        Section {
            Picker(selection: Binding(get: { uiLanguage == "en" ? "en" : "vi" },
                                      set: { L10n.apply($0); uiLanguage = $0 })) {
                Text(verbatim: "Tiếng Việt").tag("vi")
                Text(verbatim: "English").tag("en")
            } label: {
                Label { Text(verbatim: "Ngôn ngữ / Language") } icon: {
                    Image(systemName: "globe").foregroundStyle(accentBlue)
                }
            }
        }
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                // KHÔNG .autocorrectionDisabled(): bàn phím VietTelex coi ô đó là ô mã → tắt Telex.
                TextField(L("Tìm cài đặt…"), text: $query)
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("Xoá tìm kiếm"))
                }
            }
            .onAppear {
                // Quay về từ trang con → làm mới các giá trị không phải @AppStorage.
                shortcutCount = ShortcutStore.load().count
                theme = ThemeSettings.load(featureDefaults)
            }
        }

        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ForEach(Array(FeaturePage.groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group) { p in
                        NavigationLink { p.destination } label: { row(p, subtitle: summary(p)) }
                    }
                }
            }
        } else {
            let hits = SettingsIndex.search(query) { $0.isMet }
            Section {
                if hits.isEmpty {
                    Text(L("Không tìm thấy cài đặt nào.")).foregroundStyle(.secondary)
                }
                ForEach(hits, id: \.self) { e in
                    switch e.location.resolved(vniMode: vniMode) {
                    case .page(let p):
                        NavigationLink { p.destination } label: {
                            row(p, title: e.title, subtitle: e.isPage ? summary(p) : p.title)
                        }
                    case .mixed(let m):
                        // Cấp 1 nhóm "Gõ lẫn tiếng Anh" ở tab Kiểu Gõ: RootView đổi tab, mở nhóm, cuộn tới dòng.
                        Button { MixedTypingFocus.shared.request = m } label: { otherRow(e, chevron: true) }
                            .buttonStyle(.plain)
                    case let loc:
                        NavigationLink { searchDestination(loc) } label: { otherRow(e, chevron: false) }
                    }
                }
            } header: { Text(L("Kết quả")) }
        }
    }

    /// Dòng kết quả ở trang con / tab Kiểu Gõ: icon theo nơi chứa + đường dẫn.
    private func otherRow(_ e: SettingsIndexEntry, chevron: Bool) -> some View {
        let isTyping: Bool
        switch e.location {
        case .page, .feedback: isTyping = false
        default: isTyping = true
        }
        return HStack(spacing: 12) {
            if isTyping {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.teal))
            } else {
                FeatureIcon(page: .phim)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title)
                Text(e.location.pathKeys.map { L($0) }.joined(separator: " › "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            if chevron {
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func row(_ p: FeaturePage, title: String? = nil, subtitle: String) -> some View {
        HStack(spacing: 12) {
            FeatureIcon(page: p)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title ?? p.title)
                    if let b = p.badge, title == nil { ExperimentalBadge(text: b) }
                }
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// ============================================================== Trang con

/// "Sửa lỗi & gợi ý" (gộp "Chính tả & sửa lỗi" + "Gợi ý & từ điển", 05/11/2026): chính tả, các
/// mục sửa chạm trượt (công tắc riêng, xếp liền nhau), thanh gợi ý, từ đã học.
struct SuaLoiPage: View {
    @AppStorage("liveSpellCheck", store: featureDefaults) private var liveSpellCheck = true
    @AppStorage("reEditWord", store: featureDefaults) private var reEditWord = true
    /// Thử nghiệm — mặc định BẬT, xem KeyboardSettings.smartTouch.
    @AppStorage("smartTouch", store: featureDefaults) private var smartTouch = true
    /// Thử nghiệm — mặc định TẮT, xem KeyboardSettings.autoCorrect.
    @AppStorage("autoCorrect", store: featureDefaults) private var autoCorrect = false
    /// Mặc định BẬT (KeyboardSettings.autoFixAdjacent).
    @AppStorage("autoFixAdjacent", store: featureDefaults) private var autoFixAdjacent = true
    @AppStorage("showSuggestions", store: featureDefaults) private var showSuggestions = true
    @AppStorage("filterSensitive", store: featureDefaults) private var filterSensitive = true
    @AppStorage("emojiSuggest", store: featureDefaults) private var emojiSuggest = true
    @AppStorage("numberChips", store: featureDefaults) private var numberChips = true
    @AppStorage("mathResults", store: featureDefaults) private var mathResults = true
    @AppStorage("suggestInNoSuggestFields", store: featureDefaults) private var suggestInNoSuggestFields = true
    /// "Nút ẩn bàn phím" (⌄ góc phải thanh gợi ý) — mặc định TẮT (KeyboardDismissButton).
    @AppStorage(KeyboardDismissButton.key, store: featureDefaults) private var keyboardDismissButton = KeyboardDismissButton.defaultValue
    @AppStorage("pasteButton", store: featureDefaults) private var pasteButton = true
    @AppStorage("addTonesChip", store: featureDefaults) private var addTonesChip = false
    /// Plus, iOS 26+, mặc định TẮT — KeyboardSettings.aiProofread.
    @AppStorage(PlusFeature.aiProofreadKey, store: featureDefaults) private var aiProofread = false
    /// Bộ chọn Telex/VNI ở trang khác ⇒ mục chỉ-Telex làm mờ + lý do (SettingsDeps, spec §6).
    @AppStorage("vniMode", store: featureDefaults) private var vniMode = false
    @State private var confirmErase = false
    @State private var erased = false

    /// Mô tả + ghi chú khi model chưa hỗ trợ tiếng Việt / cần Toàn quyền.
    private var aiProofreadNote: String {
        var t = L(SettingCaption.aiProofread)
        if !IntelligenceEngine.supportsVietnamese() {
            t += " " + L("Apple Intelligence trên máy này chưa hỗ trợ tiếng Việt — sửa tiếng Việt có thể kém.")
        }
        return t
    }

    var body: some View {
        FeaturePageList(page: .suaLoi) {
            Section {
                settingToggle(L("Kiểm tra chính tả khi gõ"), L(SettingCaption.liveSpellCheck), isOn: $liveSpellCheck)
                settingToggle(L(SettingLabel.reEditWord), L(SettingCaption.reEditWord), isOn: $reEditWord)
            } header: { Text(L("Chính tả")) }
            Section {
                // Mục cha ở trang/nhóm khác ⇒ mờ + lý do (SETTINGS-CLEANUP-SPEC §0.4/§6): bàn phím
                // tắt ngầm hai mục đầu ở VNI; gợi ý chạm trượt hiện trên Thanh gợi ý (nhóm dưới).
                let telexOnly = SettingsDeps.telexOnlyReason(vniMode: vniMode)
                dependentToggle(L("Chọn phím thông minh"), L(SettingCaption.smartTouch), isOn: $smartTouch,
                                reason: telexOnly, experimental: true)
                dependentToggle(L("Tự sửa từ gõ sai"), L(SettingCaption.autoCorrect), isOn: $autoCorrect,
                                reason: telexOnly, experimental: true)
                dependentToggle(L("Gợi ý sửa lỗi chạm trượt"), L(SettingCaption.autoFixAdjacent), isOn: $autoFixAdjacent,
                                reason: SettingsDeps.autoFixAdjacentReason(showSuggestions: showSuggestions))
            } header: { Text(L("Chạm trượt")) } footer: {
                Text(L(SettingCaption.adjacentFooter))
            }
            Section {
                // Thanh gợi ý bật = tự học từ hay dùng (learnWords đi theo — quyết định 2026-07-24).
                settingToggle(L("Thanh gợi ý"), L(SettingCaption.showSuggestions), isOn: $showSuggestions)
                if showSuggestions {
                    SuggestionCountRow()
                    // ⌄ chỉ có khi dải gợi ý có chỗ ⇒ ẩn cùng các mục thanh khi tắt Thanh gợi ý.
                    settingToggle(L("Nút ẩn bàn phím"), L(SettingCaption.keyboardDismissButton), isOn: $keyboardDismissButton)
                    settingToggle(L("Gợi ý cả khi ứng dụng tắt gợi ý"), L(SettingCaption.suggestInNoSuggestFields), isOn: $suggestInNoSuggestFields)
                    settingToggle(L("Gợi ý emoji"), L(SettingCaption.emojiSuggest), isOn: $emojiSuggest)
                    settingToggle(L(SettingLabel.numberChips), L(SettingCaption.numberChips), isOn: $numberChips)
                    settingToggle(L("Hiện kết quả phép tính"), L(SettingCaption.mathResults), isOn: $mathResults)
                    settingToggle(L("Nút Dán"), L(SettingCaption.pasteButton), isOn: $pasteButton)
                    if PlusGate.isUnlocked(.sentenceDiacritics) {
                        settingToggle(L(SettingLabel.addTones), L(SettingCaption.addTones), isOn: $addTonesChip)
                    }
                    // Theo trạng thái model (AISettingUI): máy không hỗ trợ ⇒ ẩn; chưa bật Apple
                    // Intelligence / mô hình đang tải ⇒ hiện nhưng khoá + hướng dẫn.
                    let aiUI = AISettingUI.current
                    if PlusGate.isUnlocked(.aiProofread), aiUI.isShown {
                        settingToggle(L("Sửa lỗi bằng Apple Intelligence"),
                                      aiUI.hint.map { aiProofreadNote + "\n" + $0 } ?? aiProofreadNote, isOn: $aiProofread)
                            .disabled(!aiUI.isEnabled)
                    }
                }
                settingToggle(L("Lọc từ nhạy cảm"), L(SettingCaption.filterSensitive), isOn: $filterSensitive)
            } header: { Text(L("Thanh gợi ý")) }
            Section {
                NavigationLink {
                    UserDictView()
                } label: {
                    SubPageRow(title: L("Từ điển cá nhân"), subtitle: L(SettingCaption.userDictionary))
                }
                // Không hoàn tác được ⇒ hỏi lại trước khi xoá, xoá xong báo ngay dưới nút.
                Button(L("Xoá từ đã học"), role: .destructive) { confirmErase = true }
                    .confirmationDialog(L("Xoá mọi từ bàn phím đã học?"), isPresented: $confirmErase,
                                        titleVisibility: .visible) {
                        Button(L("Xoá từ đã học"), role: .destructive) {
                            // Xoá file + đổi mốc userlmResetAt ⇒ bàn phím bỏ bảng trong RAM lần hiện kế tiếp.
                            UserDictStore.eraseAll()
                            erased = true
                        }
                        Button(L("Huỷ"), role: .cancel) {}
                    } message: {
                        Text(L("Gợi ý sẽ học lại từ đầu. Từ bạn thêm tay trong Từ điển cá nhân cũng bị xoá. Không hoàn tác được."))
                    }
                if erased {
                    Label(L("Đã xoá từ đã học."), systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                }
            } header: { Text(L("Từ đã học")) }
        }
    }
}

/// "Số từ gợi ý" (SuggestionCount): một hàng gọn − [giá trị] +, Tự động → 1 → … → 5
/// (− ở 1 về Tự động). VoiceOver: một phần tử chỉnh được (vuốt lên/xuống).
struct SuggestionCountRow: View {
    @AppStorage(SuggestionCount.key, store: featureDefaults) private var count = SuggestionCount.auto

    private var valueText: String { count <= SuggestionCount.auto ? L("Tự động") : "\(count)" }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Số từ gợi ý"))
                Text(L(SettingCaption.suggestionCount))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                Button { count = SuggestionCount.step(count, by: -1) } label: {
                    Image(systemName: "minus").frame(width: 36, height: 32)
                }
                .disabled(count <= SuggestionCount.auto)
                Text(valueText)
                    .monospacedDigit()
                    .frame(minWidth: 64)
                Button { count = SuggestionCount.step(count, by: 1) } label: {
                    Image(systemName: "plus").frame(width: 36, height: 32)
                }
                .disabled(count >= SuggestionCount.max)
            }
            .buttonStyle(.borderless)   // trong List: hai nút bấm riêng, không ăn cả hàng
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Số từ gợi ý"))
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: count = SuggestionCount.step(count, by: 1)
            case .decrement: count = SuggestionCount.step(count, by: -1)
            @unknown default: break
            }
        }
    }
}

struct GoVuotPage: View {
    @AppStorage("swipeTyping", store: featureDefaults) private var swipeTyping = false
    /// "Vuốt từ tiếng Anh" — mặc định BẬT (KeyboardSettings.swipeEnglish), chỉ có tác dụng khi bật
    /// Gõ vuốt ⇒ ngay dưới công tắc Gõ vuốt, ẨN khi Gõ vuốt tắt (SETTINGS-CLEANUP-SPEC §1, §0.4/§6).
    @AppStorage("swipeEnglish", store: featureDefaults) private var swipeEnglish = true
    /// Decoder FUTO Swipe — mặc định TẮT, xem KeyboardSettings.swipeFuto.
    @AppStorage("swipeFuto", store: featureDefaults) private var swipeFuto = false
    /// "Hiệu ứng nét vuốt" (SwipeTrailStyle) — trang con SwipeTrailPickerView.
    @AppStorage(SwipeTrailStyle.key, store: featureDefaults) private var swipeTrailRaw = SwipeTrailStyle.defaultValue.rawValue
    /// "Âm thanh nét vuốt" (SwipeSoundStyle) — trang con SwipeSoundPickerView.
    @AppStorage(SwipeSoundStyle.key, store: featureDefaults) private var swipeSoundRaw = SwipeSoundStyle.defaultValue.rawValue

    var body: some View {
        // Tắt Gõ vuốt ⇒ ẩn mọi dòng phụ thuộc trên trang này (SettingsDeps.swipeRows, spec §6).
        let rows = SettingsDeps.swipeRows(swipeTyping: swipeTyping)
        FeaturePageList(page: .goVuot) {
            Section {
                experimentalToggle(L("Gõ vuốt"), L(SettingCaption.swipeTyping), isOn: $swipeTyping, badge: L("Máy học"))
                if rows.contains(.swipeEnglish) {
                    settingToggle(L(SettingLabel.swipeEnglish), L(SettingCaption.swipeEnglish), isOn: $swipeEnglish)
                        .padding(.leading, 12)
                }
                if rows.contains(.neuralModel) {
                    settingToggle(L("Mô hình neural gõ vuốt"), L(SettingCaption.swipeFuto), isOn: $swipeFuto)
                    // Ghi công BẮT BUỘC theo FUTO Model Weights License 1.0 ("visible notice …
                    // within the product's settings") — Phil 27/09/2026: chỉ hiện ở đây (dưới công
                    // tắc, khi đã bật Gõ vuốt), chữ nhỏ mờ. KHÔNG xoá. Xem docs/DATA-SOURCES.md.
                    Link(destination: URL(string: "https://github.com/ptrinh/viettelex/blob/main/docs/DATA-SOURCES.md#futo-swipe")!) {
                        Text("powered by FUTO Swipe")
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
            } footer: {
                Text(L(SettingCaption.swipeFooterIos))
            }
            if rows.contains(.trailEffect) {
                Section {
                    NavigationLink {
                        SwipeTrailPickerView()
                    } label: {
                        HStack(spacing: 6) {
                            Text(L("Hiệu ứng nét vuốt"))
                            if !SwipeTrailGate.allows { SwipeTrailPlusBadge() }
                            Spacer()
                            Text(SwipeTrailStyle.displayed(swipeTrailRaw).title)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if rows.contains(.trailSound) {
                        NavigationLink {
                            SwipeSoundPickerView()
                        } label: {
                            HStack(spacing: 6) {
                                Text(L("Âm thanh nét vuốt"))
                                if !SwipeSoundGate.allows { SwipeTrailPlusBadge() }
                                Spacer()
                                Text(SwipeSoundStyle.displayed(swipeSoundRaw).title)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if rows.contains(.practice) {
                Section {
                    NavigationLink {
                        SwipePracticeView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Luyện vuốt"))
                            Text(L(SettingCaption.swipePractice))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct GoTatPage: View {
    @AppStorage("templatesEnabled", store: featureDefaults) private var templatesEnabled = true
    @AppStorage("templatesAsList", store: featureDefaults) private var templatesAsList = false
    @AppStorage(PlusFeature.textToolsKey, store: featureDefaults) private var textToolsEnabled = true

    var body: some View {
        FeaturePageList(page: .goTat) {
            ShortcutsSection()
            Section {
                settingToggle(L("Mẫu câu"), L(SettingCaption.templates), isOn: $templatesEnabled)
                settingToggle(L("Hiện mẫu câu theo dòng"), L(SettingCaption.templatesAsList), isOn: $templatesAsList)
                if PlusGate.isUnlocked(.textTools) {
                    // Mẫu câu tắt ⇒ ☰ vẫn hiện và mở thẳng Công cụ (KeyboardView.LeftZone.tools).
                    settingToggle(L("Công cụ văn bản"), L(SettingCaption.textTools), isOn: $textToolsEnabled)
                }
                if PlusFeature.translate.isAvailableOnDevice, PlusGate.isUnlocked(.translate), #available(iOS 26.0, *) {
                    NavigationLink { TranslateSettingsView() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Dịch trên máy"))
                            Text(L(SettingCaption.translate))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text(L("Mẫu câu")) }
        }
    }
}

struct PhimPage: View {
    @AppStorage("numberRow", store: featureDefaults) private var numberRow = false
    /// Hàng số cao bằng hàng chữ — mặc định TẮT (phím số 0.8×, KeyGeometry.numberRowFullHeightKey).
    @AppStorage(KeyGeometry.numberRowFullHeightKey, store: featureDefaults) private var numberRowFullHeight = false
    /// Giữ phím chữ ra ký tự phụ (KeyAlternates) — số mặc định BẬT, ký hiệu TẮT.
    @AppStorage("longPressNumbers", store: featureDefaults) private var longPressNumbers = true
    @AppStorage("longPressSymbols", store: featureDefaults) private var longPressSymbols = false
    /// Giữ ⇧ + phím chữ ra ký tự phụ (ShiftHold) — mặc định BẬT.
    @AppStorage("holdShiftSymbols", store: featureDefaults) private var holdShiftSymbols = true
    @AppStorage("flickDownAlternates", store: featureDefaults) private var flickDownAlternates = false
    // "Vuốt phím cách đổi Tiếng Việt / Tiếng Anh" chuyển sang nhóm "Gõ lẫn tiếng Anh" (tab Kiểu Gõ).
    /// Vuốt phím C / X / V lên ra lệnh sao chép / cắt / dán — mặc định TẮT (KeyCommandGesture).
    @AppStorage("swipeKeyCommands", store: featureDefaults) private var swipeKeyCommands = false
    /// "Độ nhạy con trỏ" khi giữ phím cách: "slow" | "medium" (mặc định) | "fast" (TrackpadSpeed).
    @AppStorage(TrackpadSpeed.key, store: featureDefaults) private var trackpadSpeed = TrackpadSpeed.defaultValue.rawValue
    /// Tự thêm dấu cách sau . , ? ! ; : — mặc định TẮT (KeyboardSettings.autoSpaceAfterPunct).
    @AppStorage("autoSpaceAfterPunct", store: featureDefaults) private var autoSpaceAfterPunct = false
    /// "off" | "left" | "right" — bàn phím đọc lúc hiện (OneHand.resolve).
    @AppStorage("oneHandMode", store: featureDefaults) private var oneHandMode = "off"
    /// "Phím cạnh dấu cách": "comma" (mặc định) | "period" | "both" | "off" — bàn phím đọc lúc hiện (SpaceSideKey).
    @AppStorage(SpaceSideKey.key, store: featureDefaults) private var spaceSideKey = SpaceSideKey.defaultValue.rawValue
    /// "Về bàn chữ sau ký hiệu": "auto" (mặc định) | "always" | "off" — bàn phím đọc lúc hiện (SymbolReturn).
    @AppStorage(SymbolReturn.key, store: featureDefaults) private var symbolReturn = SymbolReturn.defaultValue.rawValue
    /// "Nút emoji": "bottom" (mặc định) | "top" — bàn phím đọc lúc hiện (EmojiKeyPlacement).
    @AppStorage(EmojiKeyPlacement.key, store: featureDefaults) private var emojiKeyPlacement = EmojiKeyPlacement.defaultValue.rawValue
    /// "Phím to" — mặc định TẮT (LargeKeys): "," "." hàng đáy và ⇧ / ⌫ hàng Z rộng hơn. Miễn phí.
    @AppStorage(LargeKeys.key, store: featureDefaults) private var largeKeys = LargeKeys.defaultValue
    /// Ô phóng to chữ khi bấm phím — mặc định BẬT (KeyboardView.keyPreviewKey).
    @AppStorage("keyPreviewEnabled", store: featureDefaults) private var keyPreview = true
    @AppStorage("hapticFeedback", store: featureDefaults) private var hapticFeedback = false
    @AppStorage("keySound", store: featureDefaults) private var keySound = false

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        FeaturePageList(page: .phim) {
            Section {
                settingToggle(L("Hàng phím số"), L(SettingCaption.numberRow), isOn: $numberRow)
                if numberRow {
                    settingToggle(L("Hàng số cao bằng hàng chữ"), L(SettingCaption.numberRowFullHeight), isOn: $numberRowFullHeight)
                }
                // iPad có ký tự phụ vuốt xuống riêng ⇒ chỉ iPhone.
                if isPhone {
                    VStack(alignment: .leading, spacing: 6) {
                        settingTitle(L("Phím cạnh dấu cách"), L(SettingCaption.spaceSideKey))
                        Picker(L("Phím cạnh dấu cách"), selection: Binding(
                            get: { SpaceSideKey.parse(spaceSideKey).rawValue },
                            set: { spaceSideKey = $0 })) {
                            Text(L("Phẩy")).tag(SpaceSideKey.comma.rawValue)
                            Text(L("Chấm")).tag(SpaceSideKey.period.rawValue)
                            Text(L("Cả hai")).tag(SpaceSideKey.both.rawValue)
                            Text(L("Tắt")).tag(SpaceSideKey.off.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if LargeKeys.settingVisible(SpaceSideKey.parse(spaceSideKey)) {
                        settingToggle(L("Cỡ phím chấm và phẩy"), L(SettingCaption.largeKeys), isOn: $largeKeys)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        settingTitle(L("Nút emoji"), L(SettingCaption.emojiKeyPlacement))
                        Picker(L("Nút emoji"), selection: Binding(
                            get: { EmojiKeyPlacement.parse(emojiKeyPlacement).rawValue },
                            set: { emojiKeyPlacement = $0 })) {
                            Text(L("Hàng dưới")).tag(EmojiKeyPlacement.bottom.rawValue)
                            Text(L("Thanh trên")).tag(EmojiKeyPlacement.top.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if !numberRow {
                        settingToggle(L("Giữ phím hàng trên để ra số"), L(SettingCaption.longPressNumbers), isOn: $longPressNumbers)
                    }
                    settingToggle(L("Giữ phím hàng 2, 3 để ra ký tự đặc biệt"), L(SettingCaption.longPressSymbols), isOn: $longPressSymbols)
                    settingToggle(L("Giữ Shift để gõ số và ký hiệu"), L(SettingCaption.holdShiftSymbols), isOn: $holdShiftSymbols)
                    if UIDevice.current.userInterfaceIdiom != .pad {
                        settingToggle(L("Vuốt phím xuống để gõ số và ký hiệu"), L(SettingCaption.flickDownAlternates), isOn: $flickDownAlternates)
                    }
                }
                settingToggle(L("Tự thêm dấu cách sau dấu câu"), L(SettingCaption.autoSpaceAfterPunct), isOn: $autoSpaceAfterPunct)
                VStack(alignment: .leading, spacing: 6) {
                    settingTitle(L("Về bàn chữ sau ký hiệu"), L(SettingCaption.symbolReturn))
                    Picker(L("Về bàn chữ sau ký hiệu"), selection: Binding(
                        get: { SymbolReturn.parse(symbolReturn).rawValue },
                        set: { symbolReturn = $0 })) {
                        Text(L("Tự động")).tag(SymbolReturn.auto.rawValue)
                        Text(L("Luôn")).tag(SymbolReturn.always.rawValue)
                        Text(L("Tắt")).tag(SymbolReturn.off.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } header: { Text(L("Phím")) }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    settingTitle(L("Độ nhạy con trỏ"), L(SettingCaption.trackpadSpeed))
                    Picker(L("Độ nhạy con trỏ"), selection: Binding(
                        get: { TrackpadSpeed.parse(trackpadSpeed).rawValue },
                        set: { trackpadSpeed = $0 })) {
                        Text(L("Chậm")).tag(TrackpadSpeed.slow.rawValue)
                        Text(L("Vừa")).tag(TrackpadSpeed.medium.rawValue)
                        Text(L("Nhanh")).tag(TrackpadSpeed.fast.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                settingToggle(L("Vuốt phím để sao chép/dán"), L(SettingCaption.swipeKeyCommandsIos), isOn: $swipeKeyCommands)
                if isPhone {
                    VStack(alignment: .leading, spacing: 6) {
                        settingTitle(L("Chế độ một tay"), L(SettingCaption.oneHandIos))
                        Picker(L("Chế độ một tay"), selection: $oneHandMode) {
                            Text(L("Tắt")).tag("off")
                            Text(L("Trái")).tag("left")
                            Text(L("Phải")).tag("right")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            } header: { Text(L("Cử chỉ")) } footer: {
                Text(L(SettingCaption.gesturesFooterIos))
            }
            Section {
                // Rung, âm thanh, phóng to/sẫm phím: trang con riêng (SETTINGS-CLEANUP-SPEC §4).
                NavigationLink { FeedbackPage() } label: {
                    SubPageRow(title: L(SettingLabel.feedbackPage), subtitle: feedbackSummary)
                }
            }
        }
    }

    /// Dòng phụ của "Phản hồi khi chạm": những gì đang bật.
    private var feedbackSummary: String {
        let on = [(keyPreview, L("Phóng to chữ")), (hapticFeedback, L("Rung")), (keySound, L("Âm phím"))]
            .filter(\.0).map(\.1)
        return on.isEmpty ? L("Rung, âm thanh, phóng to chữ khi bấm") : on.joined(separator: " · ")
    }
}

/// Tính Năng › Phím & cử chỉ › "Phản hồi khi chạm": phóng to chữ, phím sẫm, rung, âm thanh phím.
struct FeedbackPage: View {
    @AppStorage("keyPreviewEnabled", store: featureDefaults) private var keyPreview = true
    @AppStorage("keyPressHighlight", store: featureDefaults) private var keyPressHighlight = true
    @AppStorage("hapticFeedback", store: featureDefaults) private var hapticFeedback = false
    @AppStorage("hapticStrength", store: featureDefaults) private var hapticStrength = KeyHaptics.defaultPercent
    @AppStorage("keySound", store: featureDefaults) private var keySound = false
    @AppStorage("keySoundStyle", store: featureDefaults) private var keySoundStyle = KeySoundStyle.defaultStyle.rawValue
    /// Rung thử khi kéo thanh trượt: ≤ 1 lần / 120 ms + lúc thả.
    @State private var hapticThrottle = PreviewThrottle()

    var body: some View {
        List {
            Section {
                settingToggle(L("Phóng to chữ khi bấm"), L(SettingCaption.keyPreview), isOn: $keyPreview)
                settingToggle(L("Phím sẫm khi bấm"), L(SettingCaption.keyPressHighlight), isOn: $keyPressHighlight)
                settingToggle(L("Rung phím"), L(SettingCaption.hapticFeedback), isOn: $hapticFeedback)
                if hapticFeedback {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("Độ mạnh rung"))
                            Spacer()
                            Text("\(hapticStrength)%").foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: Binding(get: { Double(hapticStrength) },
                                              set: { hapticStrength = Int($0.rounded()); previewHaptic(final: false) }),
                               in: 10...100, step: 5,
                               label: { Text(L("Độ mạnh rung")) },
                               minimumValueLabel: { Text(L("Nhẹ")).font(.caption) },
                               maximumValueLabel: { Text(L("Mạnh")).font(.caption) },
                               onEditingChanged: { editing in if !editing { previewHaptic(final: true) } })
                    }
                    FullAccessNotice(reason: L("Rung phím"))
                }
                settingToggle(L("Âm thanh phím"), L(SettingCaption.keySound), isOn: $keySound)
                if keySound {
                    // "Âm thanh gõ" (Phil 19/10/2026): trang con chọn kiểu + âm lượng + âm tự chọn.
                    NavigationLink { KeySoundStylePage() } label: {
                        HStack {
                            Text(L("Âm thanh gõ"))
                            Spacer()
                            Text(L(KeySoundStyle.resolve(keySoundStyle, customAvailable: true).viTitle))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if KeySoundStyle.needsEngine(keySoundStyle) {
                        FullAccessNotice(reason: L("Âm thanh phím"))
                    }
                }
            }
        }
        .navigationTitle(L(SettingLabel.feedbackPage))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarScrollMargin()
    }

    private func previewHaptic(final: Bool) {
        guard hapticThrottle.shouldFire(value: hapticStrength, now: CACurrentMediaTime(), final: final) else { return }
        KeyFeedbackPreview.shared.playHaptic(strength: hapticStrength)
    }
}

/// "Âm thanh gõ" (Phil 19/10/2026): chọn kiểu âm phím — "iOS" (click hệ thống) đầu, 11 kiểu tổng hợp + Piano,
/// "Âm của bạn" cuối. Chạm một kiểu = chọn + nghe thử chữ → xoá → phím chức năng. Âm lượng + nhập âm
/// tự chọn ở đây (Android: KeySoundPage, cùng bố cục). Mọi kiểu miễn phí.
struct KeySoundStylePage: View {
    @AppStorage("keySoundVolume", store: featureDefaults) private var keySoundVolume = 50
    @AppStorage("keySoundStyle", store: featureDefaults) private var keySoundStyle = KeySoundStyle.defaultStyle.rawValue
    @State private var volumeThrottle = PreviewThrottle()
    @State private var importing = false
    @State private var styleBeforeImport: String?
    @State private var customDuration: Double?
    @State private var importMessage: String?

    private var current: KeySoundStyle { KeySoundStyle.resolve(keySoundStyle, customAvailable: true) }

    var body: some View {
        List {
            Section {
                ForEach(KeySoundStyle.menuOrder, id: \.rawValue) { st in
                    Button { pickStyle(st.rawValue) } label: {
                        HStack {
                            Text(L(st.viTitle)).foregroundStyle(Color.primary)
                            Spacer()
                            if current == st {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).font(.body.weight(.semibold))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(current == st ? .isSelected : [])
                }
            } header: {
                Text(L("Chạm một kiểu để chọn và nghe thử."))
            } footer: {
                Text(L(SettingCaption.keySoundStylesIos))
            }
            if current == .custom || customDuration != nil {
                Section { customSoundRow }
            }
            if current.usesEngine {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("Âm lượng"))
                            Spacer()
                            Text("\(keySoundVolume)%").foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: Binding(get: { Double(keySoundVolume) },
                                              set: { keySoundVolume = Int($0.rounded()); previewSound(final: false) }),
                               in: 0...100, step: 5,
                               label: { Text(L("Âm lượng")) },
                               minimumValueLabel: { Image(systemName: "speaker.fill").font(.caption) },
                               maximumValueLabel: { Image(systemName: "speaker.wave.3.fill").font(.caption) },
                               onEditingChanged: { editing in if !editing { previewSound(final: true) } })
                        Text(L(SettingCaption.keySoundVolumeIos))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    FullAccessNotice(reason: L("Âm thanh phím"))
                }
            }
        }
        .bottomBarScrollMargin()
        .navigationTitle(L("Âm thanh gõ"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { customDuration = KeySoundImport.storedDuration() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            handleImport(result)
        }
        .alert(L("Âm của bạn"), isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button(L("OK"), role: .cancel) { importMessage = nil }
        } message: { Text(importMessage ?? "") }
    }

    /// Hàng "Âm của bạn": độ dài + chọn file khác + xoá.
    private var customSoundRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let d = customDuration {
                Text(L("Âm của bạn: %@ giây", String(format: "%.2f", d))).font(.subheadline)
            } else {
                Text(L("Chưa có âm — chọn một file âm thanh ngắn (m4a, mp3, wav, caf, aiff).")).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button(customDuration == nil ? L("Chọn file âm thanh…") : L("Chọn âm khác…")) {
                    styleBeforeImport = keySoundStyle; importing = true
                }
                if customDuration != nil {
                    Button(L("Xoá"), role: .destructive) {
                        KeySoundImport.remove()
                        customDuration = nil
                        if keySoundStyle == KeySoundStyle.custom.rawValue { keySoundStyle = KeySoundStyle.defaultStyle.rawValue }
                    }
                }
            }
            .buttonStyle(.borderless)
            Text(L(SettingCaption.customSound))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func pickStyle(_ raw: String) {
        if raw == KeySoundStyle.custom.rawValue && customDuration == nil {
            styleBeforeImport = keySoundStyle
            keySoundStyle = raw
            importing = true
            return
        }
        keySoundStyle = raw
        KeyFeedbackPreview.shared.playStyle(raw, volume: max(keySoundVolume, 20))
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let o = try KeySoundImport.importFile(url)
                customDuration = o.duration
                keySoundStyle = KeySoundStyle.custom.rawValue
                if o.truncated { importMessage = L("Âm dài hơn 0,3 giây nên đã được cắt ngắn.") }
                KeyFeedbackPreview.shared.playStyle(keySoundStyle, volume: max(keySoundVolume, 20))
            } catch {
                importMessage = error.localizedDescription
                revertAfterFailedImport()
            }
        case .failure:
            revertAfterFailedImport()
        }
        styleBeforeImport = nil
    }

    /// Huỷ/lỗi khi đang chọn "Âm của bạn" mà chưa có file ⇒ quay lại kiểu trước.
    private func revertAfterFailedImport() {
        if customDuration == nil, keySoundStyle == KeySoundStyle.custom.rawValue {
            keySoundStyle = styleBeforeImport ?? KeySoundStyle.defaultStyle.rawValue
        }
    }

    private func previewSound(final: Bool) {
        guard volumeThrottle.shouldFire(value: keySoundVolume, now: CACurrentMediaTime(), final: final) else { return }
        KeyFeedbackPreview.shared.playSound(style: keySoundStyle, volume: keySoundVolume)
    }
}
