// SettingsWindow.swift
// SwiftUI settings (5 tabs: Gõ phím, Gợi ý & công cụ, Gõ tắt, Ứng dụng, Chung — sắp xếp
// lại 14/10/2026, bỏ tab Thử nghiệm + "Ẩn tính năng nâng cao"; thu gọn theo
// docs/SETTINGS-CLEANUP-SPEC.md 05/11/2026: mỗi nhóm có "Nâng cao" thu gọn). The window is created
// only when opened from the IMK menu and released when closed (windowWillClose
// drops the reference).
//
// There is no VI/EN enable/disable: Vietnamese is on whenever VietTelex is the active
// macOS input source. To type English, switch input source (macOS remembers it per
// app when "automatically switch to a document's input source" is on).

import AppKit
import SwiftUI
import TelexCore
import UniformTypeIdentifiers

/// Thứ tự case = thứ tự tab trên thanh tab (allCases). Mọi tab luôn hiện.
enum SettingsTab: Hashable, CaseIterable {
    case typing, tools, shortcuts, apps, general

    /// Khoá chuỗi (VTLocalized) của nhãn tab.
    var titleKey: String {
        switch self {
        case .typing: return "Typing"
        case .tools: return "Suggestions & tools"
        case .shortcuts: return "Shortcuts"
        case .apps: return "Apps"
        case .general: return "General"
        }
    }

    /// SF Symbol (macOS 13+) của tab.
    var icon: String {
        switch self {
        case .typing: return "keyboard"
        case .tools: return "wand.and.stars"
        case .shortcuts: return "text.badge.plus"
        case .apps: return "square.grid.2x2"
        case .general: return "gearshape"
        }
    }
}

// MARK: - Window controller

final class SettingsWindowController: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var model: SettingsModel?

    /// `modeFilter`: điền sẵn ô lọc của Bảng cơ chế gõ (menu "Cơ chế gõ" truyền bundle
    /// id của app đang gõ — maintainer 12/09/2026).
    /// `revealUpdate`: cuộn tab Chung tới khối cập nhật (mục menu "Có bản cập nhật",
    /// thông báo cập nhật hằng tuần).
    func show(tab: SettingsTab, modeFilter: String? = nil, revealUpdate: Bool = false) {
        NSApp.setActivationPolicy(.regular)
        buildWindowIfNeeded(tab: tab)
        model?.selectedTab = tab
        if let modeFilter { model?.modeFilter = modeFilter }
        if revealUpdate { model?.revealUpdate = true }
        // NOT in this runloop turn: the .accessory→.regular policy flip above needs a
        // window-server round trip before an activation can stick. Activating in the
        // same turn intermittently loses the race — the window is created but never
        // ordered front, and only a SECOND click on "Cài đặt…" (policy already
        // .regular by then) shows it (field report 2026-07-30: "vào Cài Đặt 2 lần
        // mới thấy hiện ra"). One async hop makes the first click reliable.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            // macOS 26 cooperative activation can still swallow the first activate
            // while the policy flip settles (field report 2026-08-01: one async hop
            // was not enough — "vào Cài đặt 2 lần mới hiện"). Verify and self-retry
            // once, so the "second click" happens automatically.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let self, let win = self.window, !win.isKeyWindow else { return }
                NSApp.activate(ignoringOtherApps: true)
                win.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Creates the hosting window + model (not shown, no activation). `show` calls it;
    /// tests call it directly to render the SwiftUI graph without stealing focus.
    func buildWindowIfNeeded(tab: SettingsTab) {
        guard window == nil else { return }
        let model = SettingsModel(selected: tab)
        let root = SettingsView().environmentObject(model)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = VTLocalized("VietTelex — Settings")
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Height is a first-creation default — users who resized keep their own frame.
        // (660 dates from the old scroll-less About tab; its content now lives in the
        // scrolling General form, but the mode table still likes the room.)
        win.setContentSize(NSSize(width: 680, height: 660))
        win.contentMinSize = NSSize(width: 640, height: 500)
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.center() // only on first creation — later shows keep the user's position
        self.window = win
        self.model = model
    }

    /// The live Settings window, if any (tests: deallocation on close).
    var currentWindow: NSWindow? { window }
    var currentModel: SettingsModel? { model }

    func windowWillClose(_ notification: Notification) {
        // Tear the SwiftUI hosting graph off the window EXPLICITLY (issue #59,
        // 25/08/2026: heap audit found SettingsModel + NSHostingView + phần lớn
        // AttributeGraph vẫn live sau khi đóng, peak footprint 137 MB, và mỗi lần
        // mở lại tạo thêm một graph mới). Dropping our strong refs alone leaves
        // the window→hostingController→rootView chain intact until AppKit decides
        // to free the closed window; cutting contentViewController (and the
        // delegate back-reference) lets the whole graph deallocate now, so the
        // pressure_relief below actually has pages to hand back.
        if let win = notification.object as? NSWindow {
            win.delegate = nil
            win.contentViewController = nil
        }
        window = nil
        model = nil
        // Sửa trong Cài đặt (setting, gõ tắt) lên iCloud — no-op khi đồng bộ tắt.
        ICloudSync.shared.syncNow()
        // Per-session memoization only: an app installed WHILE Settings was closed must
        // show up next time it opens (the caches are "apps don't come and go while a
        // window is open", not "…for the life of the process").
        SettingsModel.installedCache.removeAll()
        SettingsModel.nameCache.removeAll()
        // back to background agent — unless the onboarding window is still up.
        if !OnboardingWindowController.shared.isOpen { NSApp.setActivationPolicy(.accessory) }
        // Hand the freed pages back to the OS. Dropping the window/model above frees
        // the SwiftUI graph (AttributeGraph nodes, DisplayLists, SF Symbol renders,
        // autolayout constraints — measured ~20 MB), but malloc keeps those pages on
        // its own free lists, so an input method that lives for the whole login session
        // showed a permanent high-water mark in Activity Monitor after the user opened
        // Settings ONCE (peak 159 MB → resident 68 MB, audit 17/08/2026). Several
        // passes, not one hop later: the graph keeps freeing for seconds after close
        // (see MemoryFootprint.relieveAfterTransientPeak for the numbers).
        MemoryFootprint.relieveAfterTransientPeak()
    }
}

// MARK: - Model

final class SettingsModel: ObservableObject {
    @Published var selectedTab: SettingsTab
    @Published var autoRestore: Bool { didSet { AppState.shared.autoRestore = autoRestore } }
    @Published var freeMarking: Bool { didSet { AppState.shared.freeMarking = freeMarking } }
    @Published var modernOrthography: Bool { didSet { AppState.shared.modernOrthography = modernOrthography } }
    /// "Sửa dấu từ đã gõ" — key có từ trước (mặc định bật), có UI + đồng bộ iCloud từ 11/2026.
    @Published var reEditWord: Bool { didSet { AppState.shared.reEditWord = reEditWord } }
    @Published var liveSpellCheck: Bool { didSet { AppState.shared.liveSpellCheck = liveSpellCheck } }
    @Published var simpleTelex: Bool { didSet { AppState.shared.simpleTelex = simpleTelex } }
    @Published var teencode: Bool { didSet { AppState.shared.teencode = teencode } }
    @Published var autoCircumflex: Bool { didSet { AppState.shared.autoCircumflex = autoCircumflex } }
    @Published var quickTelex: Bool { didSet { AppState.shared.quickTelex = quickTelex } }
    @Published var vniMode: Bool { didSet { AppState.shared.vniMode = vniMode } }
    @Published var contextualEnglish: Bool { didSet { AppState.shared.contextualEnglish = contextualEnglish } }
    @Published var retroactiveEnglish: Bool { didSet { AppState.shared.retroactiveEnglish = retroactiveEnglish } }
    @Published var englishByFrequency: Bool { didSet { AppState.shared.englishByFrequency = englishByFrequency } }
    @Published var collisionPrefersVietnamese: Bool { didSet { AppState.shared.collisionPrefersVietnamese = collisionPrefersVietnamese } }
    @Published var stickyInputSource: Bool { didSet { AppState.shared.stickyInputSource = stickyInputSource } }
    @Published var switchSound: Bool { didSet { AppState.shared.switchSound = switchSound } }
    @Published var switchHotkey: String { didSet { AppState.shared.switchHotkey = switchHotkey } }
    @Published var textToolsInMenu: Bool { didSet { AppState.shared.textToolsInMenu = textToolsInMenu } }
    /// Công cụ → Dịch: ngôn ngữ đích (TranslatePrefs; chỉ hiện trên macOS 26+).
    @Published var translateTarget: String { didSet { AppState.shared.translateTarget = translateTarget } }
    /// Cuộn tab Chung tới khối cập nhật (xem SettingsWindowController.show).
    @Published var revealUpdate = false
    /// Thẻ một lần cho người dùng cũ (ONBOARDING-SPEC §5) — chỉ tới nhóm "Gõ lẫn tiếng Anh".
    @Published var mixedCardPending: Bool = OnboardingLogic.cardPending(AppState.shared.defaults)
    /// Cuộn tab Gõ phím tới nhóm "Gõ lẫn tiếng Anh".
    @Published var revealMixed = false
    /// Hồ sơ chọn gần nhất (onboarding / bộ chọn nhanh) — chỉ để hiển thị/xác nhận, không điều
    /// khiển hành vi. Bộ chọn trong Cài đặt không còn dòng "Chủ yếu tiếng Anh" (≡ "Việt + Anh
    /// nhiều" trên Mac) nên `en` hiện thành `mixed` (OnboardingLogic.settingsMatch).
    @Published var lastProfile: String = AppState.shared.defaults.string(forKey: OnboardingLogic.profileKey) ?? ""
    /// Hồ sơ chờ xác nhận ở bộ chọn nhanh (sẽ đổi công tắc người dùng tự chỉnh).
    @Published var confirmingProfile: TypingProfile?
    @Published var mathResults: Bool { didSet { AppState.shared.mathResults = mathResults } }
    @Published var numberChips: Bool { didSet { AppState.shared.numberChips = numberChips } }
    @Published var typoHints: Bool { didSet { AppState.shared.typoHints = typoHints } }
    @Published var toneHints: Bool { didSet { AppState.shared.toneHints = toneHints } }
    @Published var dateHints: Bool { didSet { AppState.shared.dateHints = dateHints } }
    @Published var filterSensitive: Bool { didSet { AppState.shared.filterSensitive = filterSensitive } }
    @Published var learnWords: Bool { didSet { AppState.shared.learnWords = learnWords } }
    @Published var addTonesHotkey: String {
        didSet {
            AppState.shared.addTonesHotkey = addTonesHotkey
            TextActionHotkey.apply(addTonesHotkey)
        }
    }
    /// Phím tắt mở bảng Công cụ… — đăng ký/gỡ ngay khi đổi (mặc định tắt = không đăng ký).
    @Published var toolsPanelHotkey: String {
        didSet {
            AppState.shared.toolsPanelHotkey = toolsPanelHotkey
            TextActionHotkey.applyToolsPanel(toolsPanelHotkey)
        }
    }
    @Published var icloudSync: Bool { didSet { ICloudSync.shared.setEnabled(icloudSync) } }
    /// "vt" / "star". didSet ghi đè MenuIcon.pdf ngay (hiệu lực sau restart máy);
    /// menuIconApplied bật để view hiện dòng "cần khởi động lại".
    @Published var menuIcon: String {
        didSet {
            AppState.shared.menuIcon = menuIcon
            if MenuIconSwitcher.applyIfNeeded(choice: menuIcon) { menuIconApplied = true }
        }
    }
    @Published var menuIconApplied = false
    @Published var bracketVowels: Bool { didSet { AppState.shared.bracketVowels = bracketVowels } }
    /// ASCII keyboard layout Telex composes on ("" = inherit macOS's). Applied
    /// immediately as well as persisted: waiting for the next activateServer would
    /// leave the user's very next keystroke on the old layout.
    @Published var keyboardLayoutID: String {
        didSet {
            AppState.shared.keyboardLayoutID = keyboardLayoutID
            KeyboardLayoutOverride.apply(keyboardLayoutID)
        }
    }
    @Published var safeUnknownApps: Bool { didSet { AppState.shared.safeUnknownApps = safeUnknownApps } }
    @Published var debugLogging: Bool { didSet { AppState.shared.debugLogging = debugLogging } }
    /// Tín hiệu "kết thúc từ" (#156): đổi là đăng ký / gỡ observer ngay.
    @Published var endWordSignal: Bool {
        didSet {
            AppState.shared.endWordSignal = endWordSignal
            EndWordSignal.apply(enabled: endWordSignal)
        }
    }
    @Published var autoUpdateCheck: Bool { didSet { AppState.shared.autoUpdateCheck = autoUpdateCheck } }
    /// UI language: "system" / "en" / "vi". Changing it re-renders every view that
    /// observes this model (they call `loc(_:)`), so the switch is live — no relaunch.
    @Published var uiLanguage: String { didSet { AppState.shared.uiLanguage = uiLanguage } }
    @Published var shortcuts: [ShortcutRow] = []
    /// Khoá gõ tắt cũng có trong Text Replacements của macOS (#117).
    @Published var systemConflicts: [SystemTextReplacements.Conflict] = []
    @Published var modeRows: [AppModeRow] = []            // Bảng chế độ gõ
    @Published var modeFilter: String = ""                // live filter over the table
    /// Header-click sort for the mode table (default: App name A-Z).
    @Published var modeSortOrder: [KeyPathComparator<AppModeRow>] = [
        KeyPathComparator(\AppModeRow.name),
    ]
    @Published var manualModes: [String: String] = [:]   // bundleID -> AppMode.rawValue
    @Published var newModeAppID: String = ""              // mode table: bundle id to add
    @Published var recentApps: [(id: String, name: String)] = []  // recent, not-yet-listed apps
    /// Rows the user added by hand this session but hasn't pinned yet (mode still
    /// auto, nothing learned) — kept visible so the dropdown can be used on them.
    private var addedApps: Set<String> = []
    /// Snapshot of the AX trust state for the General-tab warning banner. NOT polled:
    /// refreshed on appear, when the Settings window regains key, and — since the user
    /// does not have to come back to this window at all — the moment macOS says the
    /// Accessibility list changed (`com.apple.accessibility.api`, the same signal
    /// `main.swift` uses to rebuild the tap). Coming back used to be the ONLY trigger,
    /// which left the red warning standing next to a checkbox the user had just ticked.
    @Published var accessibilityTrusted: Bool = Accessibility.isTrusted

    init(selected: SettingsTab) {
        selectedTab = selected
        autoRestore = AppState.shared.autoRestore
        freeMarking = AppState.shared.freeMarking
        modernOrthography = AppState.shared.modernOrthography
        reEditWord = AppState.shared.reEditWord
        liveSpellCheck = AppState.shared.liveSpellCheck
        simpleTelex = AppState.shared.simpleTelex
        teencode = AppState.shared.teencode
        autoCircumflex = AppState.shared.autoCircumflex
        quickTelex = AppState.shared.quickTelex
        vniMode = AppState.shared.vniMode
        contextualEnglish = AppState.shared.contextualEnglish
        retroactiveEnglish = AppState.shared.retroactiveEnglish
        englishByFrequency = AppState.shared.englishByFrequency
        collisionPrefersVietnamese = AppState.shared.collisionPrefersVietnamese
        stickyInputSource = AppState.shared.stickyInputSource
        switchSound = AppState.shared.switchSound
        switchHotkey = AppState.shared.switchHotkey
        textToolsInMenu = AppState.shared.textToolsInMenu
        translateTarget = AppState.shared.translateTarget
        mathResults = AppState.shared.mathResults
        numberChips = AppState.shared.numberChips
        typoHints = AppState.shared.typoHints
        toneHints = AppState.shared.toneHints
        dateHints = AppState.shared.dateHints
        filterSensitive = AppState.shared.filterSensitive
        learnWords = AppState.shared.learnWords
        addTonesHotkey = AppState.shared.addTonesHotkey
        // Giá trị lạ (không thuộc danh sách) ⇒ "off", để Picker luôn có tag khớp.
        let tools = AppState.shared.toolsPanelHotkey
        toolsPanelHotkey = TextActionHotkey.toolsChoices.contains { $0.id == tools } ? tools : "off"
        icloudSync = ICloudSync.shared.isEnabled
        menuIcon = AppState.shared.menuIcon
        bracketVowels = AppState.shared.bracketVowels
        // A layout uninstalled since it was chosen (system update, removed third-party
        // bundle) would leave the Picker with no matching tag and render blank — fall
        // back to "system default" so the control always shows a real selection.
        let savedLayout = AppState.shared.keyboardLayoutID
        keyboardLayoutID = KeyboardLayoutOverride.isInstalled(savedLayout)
            ? savedLayout : KeyboardLayoutOverride.systemDefault
        safeUnknownApps = AppState.shared.safeUnknownApps
        debugLogging = AppState.shared.debugLogging
        endWordSignal = AppState.shared.endWordSignal
        autoUpdateCheck = AppState.shared.autoUpdateCheck
        uiLanguage = AppState.shared.uiLanguage
        reloadShortcuts()
        reloadModeTable()
    }

    /// Localized string for the user's chosen UI language (see `VTLocalized`).
    /// Installed ASCII-capable layouts for the Keyboard layout picker. Resolved once
    /// per Settings window — TISCreateInputSourceList walks every installed layout
    /// bundle (~112 on a stock Mac), which is far too much for a view body that
    /// SwiftUI re-evaluates on each toggle. The set can't change while the window is
    /// open without installing software.
    lazy var keyboardLayouts: [KeyboardLayoutOption] = KeyboardLayoutOverride.installed()

    func loc(_ key: String) -> String { VTLocalized(key) }

    /// Đóng thẻ "Bạn hay gõ trộn Anh/Việt?" — không bao giờ hiện lại. `reveal`: cuộn tới nhóm.
    func dismissMixedCard(reveal: Bool) {
        OnboardingLogic.dismissCard(AppState.shared.defaults)
        mixedCardPending = false
        if reveal { revealMixed = true }
    }

    // MARK: Bộ chọn nhanh hồ sơ (ONBOARDING-SPEC §4) — đầu nhóm "Gõ lẫn tiếng Anh"

    /// Công tắc hồ sơ đang có (đúng `OnboardingLogic.mixedKeys`).
    var mixedValues: [String: Bool] {
        ["autoRestore": autoRestore, "contextualEnglish": contextualEnglish,
         "retroactiveEnglish": retroactiveEnglish, "englishByFrequency": englishByFrequency,
         "collisionPrefersVietnamese": collisionPrefersVietnamese]
    }

    /// Hồ sơ khớp đúng cài đặt (trong `OnboardingLogic.settingsProfiles`); nil = "Tuỳ chỉnh".
    var matchedProfile: TypingProfile? {
        OnboardingLogic.settingsMatch(mixedValues, lastChosen: TypingProfile(rawValue: lastProfile))
    }

    /// Bấm một hồ sơ: đang "Tuỳ chỉnh" và sẽ đổi công tắc ⇒ chờ xác nhận; còn lại áp ngay.
    func pickProfile(_ p: TypingProfile) {
        guard p != matchedProfile else { return }
        if OnboardingLogic.needsConfirmation(mixedValues, applying: p, lastChosen: TypingProfile(rawValue: lastProfile)) {
            confirmingProfile = p
        } else {
            applyProfile(p)
        }
    }

    /// Ghi hồ sơ qua các thuộc tính của model (didSet ghi AppState ⇒ engine nhận ngay).
    func applyProfile(_ p: TypingProfile) {
        confirmingProfile = nil
        OnboardingLogic.apply(p, defaults: AppState.shared.defaults) { self.setMixed($0, $1) }
        lastProfile = p.rawValue
    }

    private func setMixed(_ key: String, _ v: Bool) {
        switch key {
        case "autoRestore": autoRestore = v
        case "contextualEnglish": contextualEnglish = v
        case "retroactiveEnglish": retroactiveEnglish = v
        case "englishByFrequency": englishByFrequency = v
        case "collisionPrefersVietnamese": collisionPrefersVietnamese = v
        default: AppState.shared.setMixedSetting(key, v)
        }
    }

    /// Nội dung hộp xác nhận: "Các công tắc bạn đã tự chỉnh sẽ đổi:" + từng dòng.
    func profileChangeList(_ p: TypingProfile) -> String {
        let target = OnboardingLogic.dict(p)
        let lines = OnboardingLogic.changes(from: mixedValues, to: p).map { k in
            "• " + loc(OnboardingModel.title(k)) + ": " + loc(target[k] == true ? "on" : "off")
        }
        return ([loc("Switches you changed yourself will change:")] + lines).joined(separator: "\n")
    }

    /// Khoá chú thích mục Công cụ văn bản theo số công cụ thật của bảng (6, hoặc 7 khi
    /// máy dịch được) — chú thích cũ ghi cứng "1–6" kể cả khi bảng có Dịch ở phím 7.
    static func textToolsCaptionKey(toolCount: Int) -> String {
        toolCount >= 7
            ? "Select text, open Tools…, press 1–7: add tones, change case, remove tones, translate."
            : "Select text, open Tools…, press 1–6: add tones, change case, remove tones."
    }

    /// Re-read the Accessibility trust snapshot (see `accessibilityTrusted`).
    /// `readTrustNow`, not `isTrusted`: this is a UI path, and the cached reader can
    /// serve the pre-grant answer while its background probe is still in flight.
    func refreshAccessibilityStatus() {
        // Settings opened / became key: also start the tap now if the grant landed
        // without a system notification (no-op while the tap runs).
        TerminalTapController.shared.recheckTrust(reason: "settings window")
        let now = Accessibility.readTrustNow()
        if now != accessibilityTrusted { accessibilityTrusted = now }
    }

    /// The Accessibility list changed while the user was in System Settings. Re-read
    /// NOW and once more after 1.5s: right after the toggle tccd can still report the
    /// OLD value (the same race `TerminalTapController.trustMayHaveChanged` guards
    /// against with the same delay), so an immediate read alone can latch the banner
    /// into lying in the other direction — claiming permission is fine right after a
    /// REVOKE. Two reads, no timer, no polling.
    func accessibilityMayHaveChanged() {
        refreshAccessibilityStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshAccessibilityStatus()
        }
    }

    /// Open System Settings → Privacy & Security → Accessibility (macOS 27: Device
    /// Control and Data Access — PrivacyPane). Used by the General-tab banner and the
    /// mode table's ⚠️ badge.
    static func openAccessibilitySettings() {
        PrivacyPane.openSettings()
    }

    // MARK: Bảng chế độ gõ

    /// Rebuild the mode table: every app VietTelex knows something about — manual
    /// overrides ∪ learned (probe) ∪ built-in pins ∪ rows added by hand — sorted by
    /// display name A-Z.
    /// Spotlight row — keyed by its REAL bundle id (IMKit reports com.apple.Spotlight
    /// as the client while the overlay is focused), so manual modes work like any
    /// other app; only tap-side DETECTION uses the window scan. Also kills the old
    /// duplicate-row problem (synthetic "system.spotlight" next to the learned
    /// com.apple.Spotlight entry).
    static let spotlightRowID = AppState.spotlightBundleID

    /// bundle id → installed? (see `reloadModeTable`). Main-thread only, like the model.
    static var installedCache: [String: Bool] = [:]      // internal: tests assert memoization
    /// bundle id → display name (see `appName(for:)`). Same reason as `installedCache`:
    /// resolving a name is a LaunchServices round trip + a `displayName(atPath:)` disk
    /// hit, and it ran for EVERY row on EVERY reload (once a second while the window is
    /// key) on the thread that also serves keystrokes. Both caches are dropped in
    /// `windowWillClose`. Main-thread only, like the model.
    static var nameCache: [String: String] = [:]         // internal: tests assert memoization
    /// Last reload (reference-date seconds) — see the `didBecomeKey` throttle.
    var lastModeReloadAt: TimeInterval = 0               // internal: tests drive the throttle

    /// Rebuild the table, at most once per second. `didBecomeKeyNotification` fires for
    /// EVERY window in this process (Settings tabs, alerts) and the user's flow is to
    /// alt-tab between Settings and the app they are testing — unthrottled that rebuilt the
    /// whole table on each switch, on the thread that also serves keystrokes.
    func reloadModeTableThrottled() {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastModeReloadAt >= 1 else { return }
        lastModeReloadAt = now
        reloadModeTable()
    }

    func reloadModeTable() {
        lastModeReloadAt = Date.timeIntervalSinceReferenceDate
        manualModes = AppState.shared.manualModes
        // Snapshot the learned sets ONCE. Both accessors sort under AppState's lock, and
        // `makeRow` asks for them per row — ~20-60 sorted() calls (plus lock traffic) per
        // reload, on the keystroke thread. One snapshot, passed down.
        let learnedFallback = Set(AppState.shared.learnedFallbackApps)
        let learnedInPlace = Set(AppState.shared.learnedInPlaceApps)
        // User data (manual pins, probe results, hand-added) is always listed —
        // even for apps since uninstalled, so a stale pin stays visible/removable.
        var ids = Set(manualModes.keys)
        ids.formUnion(learnedFallback)
        ids.formUnion(learnedInPlace)
        ids.formUnion(addedApps)
        // Every HARDCODED rule set is filtered to apps actually installed — the
        // table shows this system's real defaults, not our whole knowledge base.
        // MEMOIZED: `urlForApplication` is a LaunchServices round trip, and this filter runs
        // over ~50 hardcoded ids EVERY reload. Settings lives in the INPUT METHOD's process,
        // on the same main thread that handles keystrokes, so a burst of those lookups shows
        // up as typing hitches — tester report 2026-07-28: "mở settings lên lâu là bị đơ đơ,
        // tắt đi thì trở lại bình thường". Installed apps do not come and go while a window
        // is open, so one lookup per id per session is plenty.
        let installed: (String) -> Bool = { id in
            if let known = Self.installedCache[id] { return known }
            let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            Self.installedCache[id] = found
            return found
        }
        ids.formUnion(AppState.builtInFallbackApps.filter(installed))
        ids.formUnion(AppState.builtInInPlaceApps.filter(installed))
        ids.formUnion(AppState.builtInSpecialApps.filter(installed))
        ids.formUnion(ClientPolicy.forcePassthroughBundleIDs.filter(installed))
        ids.insert(Self.spotlightRowID)   // always listed; dedupes with learned entry
        modeRows = ids.map {
            makeRow(id: $0, name: Self.appName(for: $0),
                    learnedFallback: learnedFallback, learnedInPlace: learnedInPlace)
        }
        // Up to 10 recently-focused apps not yet in the table — quick add candidates.
        recentApps = FrontmostApp.shared.recent
            .filter { !ids.contains($0.id) }
            .prefix(10).map { $0 }
    }

    /// Display name for a bundle id (the installed app's name; the raw id when the
    /// app isn't found — e.g. learned on another machine or since uninstalled).
    /// MEMOIZED in `nameCache` — see that property for why.
    static func appName(for id: String) -> String {
        if let cached = nameCache[id] { return cached }
        let name = resolveAppName(for: id)
        nameCache[id] = name
        return name
    }

    private static func resolveAppName(for id: String) -> String {
        if id == spotlightRowID { return "Spotlight" }   // CoreServices — lookup can miss
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return id }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Current override for `id` as an AppMode raw value ("auto" when unset).
    func appMode(_ id: String) -> String { manualModes[id] ?? "auto" }
    func setAppMode(_ id: String, _ raw: String) {
        guard let mode = AppState.AppMode(rawValue: raw) else { return }
        AppState.shared.setManualMode(mode, for: id)
        if mode != .auto { addedApps.remove(id) }   // pinned now — persisted for real
        reloadModeTable()
    }

    /// Label for what Auto WANTS for this app, plus a "missing permission" warning
    /// when that mode needs Accessibility and it isn't granted — the truth is
    /// "per-field, but degraded right now", not "chưa dò".
    func autoLabel(_ id: String) -> String {
        // (Spotlight needs no special case any more: it sits in builtInInPlaceApps —
        // in-place field-verified on macOS 26 — and resolves like any other app.)
        let mode = AppState.shared.autoResolvedMode(id)
        let base: String
        var needsAX = false
        switch mode {
        case .inPlace: base = loc(ModeNames.inPlace)
        case .marked: base = loc(ModeNames.marked)
        case .tap: base = loc(ModeNames.tap); needsAX = true
        case .selection: base = loc(ModeNames.selection); needsAX = true
        case .emptyReset: base = loc(ModeNames.emptyReset); needsAX = true
        case .axDetect: base = loc(ModeNames.axDetect); needsAX = true
        case .passthrough: base = loc(ModeNames.passthrough)
        case .auto, nil:
            // Not classified: with the permission Auto will probe on first typing;
            // without it the blunt policy runs marked text (no probing).
            return Accessibility.isTrusted ? loc("not detected yet") : loc(ModeNames.marked)
        }
        // Without the permission, show the mode ACTUALLY in effect right now (what
        // the routing degrades to) — "Marked text", not the aspirational
        // "Tap (backspace)". The ⚠️ badge (autoMissingPermission) carries the reason.
        // Untrusted policy is blunt by decision: everything not positively known
        // in-place-good runs marked text (Spotlight alone is raw passthrough).
        if needsAX && !Accessibility.isTrusted {
            return mode == .selection ? loc(ModeNames.passthrough) : loc(ModeNames.marked)
        }
        return base
    }

    /// True when this app's ideal Auto mode needs Accessibility and it isn't
    /// granted — the Detected cell shows a ⚠️ with an explanatory tooltip.
    func autoMissingPermission(_ id: String) -> Bool {
        guard !Accessibility.isTrusted else { return false }
        switch AppState.shared.autoResolvedMode(id) {
        case .tap, .selection, .emptyReset, .axDetect: return true
        case .auto, nil: return true   // would probe if trusted; runs marked instead
        default: return false
        }
    }

    /// Localized label of the manual pick for `id` ("Tự động" when unset) — also
    /// what the filter matches against.
    func manualLabel(_ id: String) -> String {
        switch AppState.AppMode(rawValue: appMode(id)) {
        case .inPlace: return loc(ModeNames.inPlace)
        case .marked: return loc(ModeNames.marked)
        case .tap: return loc(ModeNames.tap)
        case .selection: return loc(ModeNames.selection)
        case .emptyReset: return loc(ModeNames.emptyReset)
        case .axDetect: return loc(ModeNames.axDetect)
        case .passthrough: return loc(ModeNames.passthrough)
        case .auto, nil: return loc("Auto")
        }
    }

    /// `learnedFallback`/`learnedInPlace` are the per-reload snapshot (see
    /// `reloadModeTable`) — never re-read AppState here, it's once per row.
    private func makeRow(id: String, name: String,
                         learnedFallback: Set<String>,
                         learnedInPlace: Set<String>) -> AppModeRow {
        let hasUserData = manualModes[id] != nil
            || learnedFallback.contains(id)
            || learnedInPlace.contains(id)
            || addedApps.contains(id)
        return AppModeRow(id: id, name: name,
                          detected: autoLabel(id), manual: manualLabel(id),
                          missingPermission: autoMissingPermission(id),
                          deletable: hasUserData)
    }

    /// Forget one row's user data (pin + learned + hand-added). A built-in default
    /// underneath, if any, takes over — the row then stays with Auto semantics.
    func deleteRow(_ id: String) {
        AppState.shared.forgetApp(id)
        addedApps.remove(id)
        reloadModeTable()
    }

    /// Rows matching the live filter (app name, bundle id, detected label, manual
    /// label) in the header-click sort order.
    var visibleModeRows: [AppModeRow] {
        let q = modeFilter.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? modeRows : modeRows.filter { row in
            row.name.localizedCaseInsensitiveContains(q)
                || row.id.localizedCaseInsensitiveContains(q)
                || row.detected.localizedCaseInsensitiveContains(q)
                || row.manual.localizedCaseInsensitiveContains(q)
        }
        return filtered.sorted(using: modeSortOrder)
    }

    /// Text that looks like a file path (typed / dragged .app) rather than a bundle id.
    static func looksLikeAppPath(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("file://") || t.hasSuffix(".app") || t.hasSuffix(".app/")
    }

    /// Bundle id of the .app at `url` (Bundle API, then Contents/Info.plist); caches its display name.
    static func bundleID(atAppURL url: URL) -> String? {
        let bid = Bundle(url: url)?.bundleIdentifier
            ?? (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String)
        guard let bid, !bid.isEmpty else { return nil }
        let displayName = FileManager.default.displayName(atPath: url.path)
        nameCache[bid] = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        return bid
    }

    /// Extracts a bundle ID from a typed or dropped .app path / file URL; nil if not a readable app.
    static func extractBundleID(from pathOrID: String) -> String? {
        let trimmed = pathOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeAppPath(trimmed) else { return nil }
        let url: URL
        if trimmed.hasPrefix("file://"), let u = URL(string: trimmed) { url = u }
        else { url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath) }
        return bundleID(atAppURL: url)
    }

    /// Add a row by hand (recent-apps picker, typed bundle id, or dragged .app path), mode = Auto.
    func addApp() {
        let text = newModeAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id: String
        if Self.looksLikeAppPath(text) {
            // A path that is not a readable app must not be stored as a "bundle id".
            guard let bid = Self.extractBundleID(from: text) else { return showBundleIDError(text) }
            id = bid
        } else {
            id = text
        }
        addedApps.insert(id)
        newModeAppID = ""
        reloadModeTable()
    }

    /// Opens an NSOpenPanel for the user to pick any .app from /Applications or anywhere on disk.
    func browseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = loc("Choose")
        panel.message = loc("Select an application to add")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bid = Self.bundleID(atAppURL: url) else { return showBundleIDError(url.lastPathComponent) }
        addedApps.insert(bid)
        newModeAppID = ""
        reloadModeTable()
    }

    private func showBundleIDError(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("Could not read application bundle identifier")
        alert.informativeText = (detail as NSString).lastPathComponent
        alert.runModal()
    }

    /// Forget everything learned so the probe re-classifies from scratch. Keeps the
    /// user's manual pins (they're choices, not learning).
    func clearLearned() {
        AppState.shared.resetLearnedApps()
        reloadModeTable()
    }

    /// Merge imported manual pins (bundleID → AppMode raw value). Invalid mode
    /// values are skipped; returns how many entries were applied. Learned lists are
    /// NOT importable on purpose — they're per-machine probe results and re-learn
    /// themselves; only deliberate user choices are worth carrying across installs.
    func importManualModes(_ dict: [String: String]) -> Int {
        var applied = 0
        for (id, raw) in dict {
            guard let mode = AppState.AppMode(rawValue: raw), mode != .auto,
                  !id.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            AppState.shared.setManualMode(mode, for: id)
            applied += 1
        }
        reloadModeTable()
        return applied
    }

    func reloadShortcuts() {
        shortcuts = AppState.shared.shortcuts
            .sorted { $0.key < $1.key }
            .map { ShortcutRow(key: $0.key, value: $0.value) }
        systemConflicts = SystemTextReplacements.conflicts(
            ours: AppState.shared.shortcuts, system: SystemReplacementGuard.shared.systemTable)
    }

    func addShortcut(key: String, value: String) {
        let k = key.trimmingCharacters(in: .whitespaces)
        // Khoá: không khoảng trắng, ≤ 64 ký tự (ký hiệu/số được: "->", "√√", "k2").
        guard ShortcutTable.isValidKey(k), !value.isEmpty else { return }
        AppState.shared.upsertShortcut(key: k, value: value)
        reloadShortcuts()
    }

    func removeShortcut(_ key: String) {
        AppState.shared.removeShortcut(key: key)
        reloadShortcuts()
    }
}

extension View {
    /// Nút hành động chính theo Liquid Glass (macOS 26) — fallback borderedProminent.
    @ViewBuilder func prominentGlass() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

// id = key: selection survives reloads, and a row can be looked up by its key.
struct ShortcutRow: Identifiable {
    var id: String { key }
    let key: String
    let value: String
    /// Nội dung nhiều dòng hiện trên MỘT dòng bảng: xuống dòng → " ⏎ ".
    var displayValue: String { Self.oneLine(value) }
    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: " ⏎ ")
    }
}

/// One row of the mode table. `id` = bundle id (stable across reloads). The label
/// columns are precomputed at reload so the Table can sort by them (KeyPathComparator
/// needs stored Comparable properties) and the filter can match them.
struct AppModeRow: Identifiable {
    let id: String
    let name: String
    let detected: String          // localized Detected-column label
    let manual: String            // localized Manual-column label (current pick)
    let missingPermission: Bool   // show the ⚠️ badge
    let deletable: Bool           // has user data (pin/learned/hand-added) to forget
}

// MARK: - Root view

struct SettingsView: View {
    @EnvironmentObject var model: SettingsModel

    // Tab bar TỰ VẼ (15/08/2026): NSTabView/TabView cổ điển của macOS chỉ hiện TEXT
    // trong dải tab — systemImage của Label bị bỏ qua (ảnh field 15/08 xác nhận).
    // Muốn icon thì phải tự vẽ: HStack các nút Label icon+text, nút đang chọn mang
    // nền accent bo góc — cùng dáng segmented control cũ (user 2026-07-24 đã thử
    // sidebar rồi quay lại tab ngang, nên giữ đúng hình khối đó).
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tabButton($0) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let selected = model.selectedTab == tab
        return Button { model.selectedTab = tab } label: {
            Label(model.loc(tab.titleKey), systemImage: tab.icon)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .lineLimit(1)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder private var activeTab: some View {
        switch model.selectedTab {
        case .typing:    TypingTab()
        case .tools:     ToolsTab()
        case .shortcuts: ShortcutsTab()
        case .apps:      ModeTableTab()
        case .general:   GeneralTab()
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            tabBar
            activeTab.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 500)
    }
}

// MARK: - Nhãn một hàng (dùng chung các tab)

/// Tên + MỘT dòng chú thích ngắn ngay dưới, cùng một hàng (06/11/2026 — như `TypingTab.rowLabel`).
/// Nhận chuỗi ĐÃ dịch.
struct SettingRowLabel: View {
    let title: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let c = caption, !c.isEmpty {
                Text(c).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Tên cách gõ theo app (bảng Ứng dụng + menu): theo triệu chứng, không thuật ngữ (06/11/2026,
/// cùng tinh thần bản Linux). Chỉ là nhãn — giá trị lưu (`AppState.AppMode`) không đổi.
enum ModeNames {
    static let auto = "Auto"
    static let inPlace = "Edit in the field"
    static let marked = "Underline"
    static let tap = "Real keystrokes"
    static let selection = "Select and retype"
    static let emptyReset = "Excel style"
    static let axDetect = "Detect per field (axDetect)"
    static let passthrough = "Vietnamese off"
    /// Đuôi cho mục cần quyền khi chưa cấp: "Tên (cần quyền Trợ năng)".
    static let needsPermission = "needs {PANE}"
    static let all = [inPlace, marked, tap, selection, emptyReset, axDetect, passthrough, needsPermission]
}

// MARK: - Tab: Gõ phím

struct TypingTab: View {
    @EnvironmentObject var model: SettingsModel

    /// `.id` của nhóm "Gõ lẫn tiếng Anh" — đích cuộn của thẻ người dùng cũ.
    static let mixedAnchor = "mixed"

    // Ba mục "Nâng cao" (SETTINGS-CLEANUP-SPEC §0.3): thu gọn mặc định, dòng phụ liệt kê bên trong.
    @State private var styleAdvancedOpen = false
    @State private var mixedAdvancedOpen = false
    @State private var switchAdvancedOpen = false

    /// Dòng phụ của từng mục "Nâng cao" (khoá Localizable.strings).
    static let styleAdvancedSummary = "Simple Telex, free tone placement, quick consonants, modern tone placement, teencode, bracket keys, keyboard layout…"
    static let mixedAdvancedSummary = "Restore English words, context, colliding words, fixing earlier words…"
    static let switchAdvancedSummary = "Keep VietTelex when macOS switches, macOS shortcut…"
    /// Dòng link cài đặt hệ thống cuối trang (thay mục "Viết hoa, gợi ý chữ…" cũ).
    /// Phil 10/11/2026: tính năng quan trọng của macOS mà người dùng không biết — đặt ở cấp 1 của mục
    /// "Chuyển Việt/Anh" (không nằm trong Nâng cao, không chỉ là dòng link cuối trang).
    static let perDocumentTitle = "Remember the keyboard for each app or document"
    static let perDocumentCaption = "Click Open… and turn on “Automatically switch to a document’s input source” in macOS settings."
    static let systemSettingsCaption = "Capitalization, word suggestions, period on double space, smart quotes: set in macOS."

    /// Chú thích MỘT dòng ngắn cho từng cài đặt (06/11/2026: rút gọn — mỗi chú thích ≤ ~90 ký tự,
    /// một ví dụ; test SettingsCleanupTests kiểm độ dài + có bản dịch).
    enum C {
        static let vni = "Tones with digits: 1–5 sắc/huyền/hỏi/ngã/nặng, 6 â ê ô, 7 ơ ư, 8 ă, 9 đ, 0 clears."
        static let simpleTelex = "A lone w stays w (type uw for ư)."
        static let freeMarking = "Put the tone anywhere in the word (ama → âm). Off: stricter, better for English/code."
        static let quickTelex = "Double the first consonant: kk → kh, nn → ng, pp → ph, tt → th…"
        static let modern = "hoà, thuý, khoẻ instead of hòa, thủy, khỏe."
        static let teencode = "Accept chat spellings: wá, zui zẻ, kó. Off: was, zoo stay as typed."
        static let autoCircumflex = "Type vietj for việt when the plain vowel isn’t a valid syllable."
        static let bracket = "[ types ơ, ] types ư (th[ → thơ). Leave off if you write code."
        static let reEdit = "Add a tone to a word already typed: toan + s → toán."
        static let layout = "Physical layout Telex reads (Colemak, Dvorak…)."
        static let autoRestore = "Words that aren’t Vietnamese go back to what you typed (google, github)."
        static let collisionVi = "e.g. list → lít. To keep English, double the tone key: lisst → list."
        static let collisionEn = "e.g. list stays list. For Vietnamese, type the tone last: lits → lít."
        static let context = "After an English word, the next stays English: “he is”, not “he í”."
        static let retro = "Fixes mis-toned words once the sentence turns out English: “Hí cả í” → “His car is”."
        static let frequency = "At the start, “his” stays English, not “hí”; switches back if the sentence is Vietnamese."
        static let hotkey = "Press and release just these keys to switch input source. Needs {PANE} permission."
        static let sticky = "When macOS switches input source on a new field (e.g. Word comments), switch back."
        static let switchSound = "A rising tone means VietTelex, a falling one another keyboard. Not when macOS switches per app."
        static let osShortcut = "Set in macOS Keyboard Shortcuts → Input Sources."
        static let liveSpell = "Stop adding tones once a word can’t be Vietnamese (google, github)."
        /// Thay cả nhóm "Gõ lẫn tiếng Anh" khi chọn VNI (spec §1) — cùng chữ iOS/Android.
        static let vniMixedNote = "VNI leaves English words as typed, so there is nothing to set here."
        static let all = [vni, simpleTelex, freeMarking, quickTelex, modern, teencode, autoCircumflex, bracket, reEdit, layout,
                          autoRestore, collisionVi, collisionEn, context, retro, frequency, hotkey, sticky,
                          osShortcut, liveSpell, vniMixedNote]
    }

    private func caption(_ key: String) -> some View {
        Text(model.loc(key)).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Nhãn một dòng cài đặt: tên + MỘT dòng chú thích ngắn ngay dưới (cùng một hàng Form, căn trái,
    /// công tắc bên phải). 06/11/2026: thay cho chú thích đứng riêng thành hàng — dài, lệch lề.
    private func rowLabel(_ titleKey: String, _ captionText: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.loc(titleKey))
            if let c = captionText, !c.isEmpty {
                Text(c).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Công tắc một hàng: tên + chú thích ngắn (khoá Localizable).
    private func toggleRow(_ titleKey: String, isOn: Binding<Bool>, caption captionKey: String) -> some View {
        Toggle(isOn: isOn) { rowLabel(titleKey, model.loc(captionKey)) }
    }

    /// Hàng "Nâng cao" bấm để mở/thu (thay DisclosureGroup: nội dung DisclosureGroup trong Form
    /// grouped của macOS bị thụt/căn giữa lệch). Nội dung là các hàng Form bình thường bên dưới.
    private func advancedRow(_ isOpen: Binding<Bool>, summary summaryKey: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack {
                rowLabel("Advanced", isOpen.wrappedValue ? nil : model.loc(summaryKey))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(model.loc(isOpen.wrappedValue ? "Expanded" : "Collapsed"))
    }

    /// Một dòng "Kiểu gõ › Nâng cao" (thứ tự + ẩn/hiện: SettingsDeps.styleRows).
    @ViewBuilder private func styleRow(_ r: SettingsDeps.StyleRow) -> some View {
        switch r {
        case .simpleTelex:
            toggleRow("Simple Telex", isOn: $model.simpleTelex, caption: C.simpleTelex)
        case .freeMarking:
            toggleRow("Free tone placement", isOn: $model.freeMarking, caption: C.freeMarking)
        case .quickTelex:
            toggleRow("Quick consonants (cc→ch, gg→gi…)", isOn: $model.quickTelex, caption: C.quickTelex)
        case .modern:
            toggleRow("Modern tone placement (oà, uý)", isOn: $model.modernOrthography, caption: C.modern)
        case .teencode:
            toggleRow("Teencode spelling", isOn: $model.teencode, caption: C.teencode)
        case .autoCircumflex:
            toggleRow("Auto-add circumflex", isOn: $model.autoCircumflex, caption: C.autoCircumflex)
        case .bracket:
            toggleRow("Bracket vowels: [ types ơ, ] types ư", isOn: $model.bracketVowels, caption: C.bracket)
        case .reEdit:
            // reEditWord: key có từ lâu (mặc định bật), spec §3 thêm công tắc, cùng tên mobile.
            toggleRow("Fix tones of typed words", isOn: $model.reEditWord, caption: C.reEdit)
        case .layout:
            Picker(selection: $model.keyboardLayoutID) {
                Text(model.loc("Follow the previous input source"))
                    .tag(KeyboardLayoutOverride.systemDefault)
                Divider()
                ForEach(model.keyboardLayouts) { layout in
                    Text(layout.name).tag(layout.id)
                }
            } label: {
                rowLabel("Keyboard layout", model.loc(C.layout))
            }
        }
    }

    /// Một dòng "Gõ lẫn tiếng Anh › Nâng cao" (ẩn/hiện: SettingsDeps.mixedAdvancedRows).
    @ViewBuilder private func mixedAdvancedRow(_ r: SettingsDeps.MixedAdvancedRow) -> some View {
        switch r {
        case .autoRestore:
            toggleRow("Auto-restore English words", isOn: $model.autoRestore, caption: C.autoRestore)
        case .collision:
            // "Ưu tiên khi trùng" (maintainer 12/09/2026, default tiếng Việt). Chú thích đổi theo
            // lựa chọn: luôn chỉ cách lấy dạng KIA (spec §1: mẹo gõ đúp phím dấu).
            Picker(selection: Binding(
                get: { model.collisionPrefersVietnamese ? "vi" : "en" },
                set: { model.collisionPrefersVietnamese = ($0 == "vi") })) {
                Text(model.loc("Prefer Vietnamese")).tag("vi")
                Text(model.loc("Prefer English")).tag("en")
            } label: {
                rowLabel("Word that is both English and Vietnamese",
                         model.loc(model.collisionPrefersVietnamese ? C.collisionVi : C.collisionEn))
            }
        case .context:
            toggleRow("Context-based decision", isOn: $model.contextualEnglish, caption: C.context)
        case .retro:
            toggleRow("Fix earlier words (experimental)", isOn: $model.retroactiveEnglish, caption: C.retro)
        case .frequency:
            toggleRow("Guess colliding words by frequency (experimental)", isOn: $model.englishByFrequency,
                      caption: C.frequency)
        }
    }

    /// Bộ chọn hồ sơ ở đầu nhóm (ONBOARDING-SPEC §4): câu hỏi + nút radio (chọn MỘT) — macOS chỉ
    /// hai hồ sơ (`OnboardingLogic.settingsProfiles`, spec cleanup §1).
    /// "Tuỳ chỉnh" chỉ hiện — đã chọn sẵn, không bấm được — khi công tắc bên dưới không khớp
    /// hồ sơ nào. Trước đây là danh sách dấu ✓ bên phải: người dùng không nhận ra là chọn một.
    @ViewBuilder private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.loc("How do you usually type?")).font(.subheadline.weight(.semibold))
            Text(model.loc("Pick one — the switches below are set to match."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
        let current = model.matchedProfile
        ForEach(OnboardingLogic.settingsProfiles, id: \.self) { p in
            Button { model.pickProfile(p) } label: {
                profileRow(model.loc(OnboardingLogic.title(p)), "“\(OnboardingLogic.example(p))”",
                           selected: current == p)
            }
            .buttonStyle(.plain)
        }
        Group {
            if current == nil {
                profileRow(model.loc("Custom"), model.loc("You changed the switches below yourself."),
                           selected: true)
            }
        }
        .alert(model.confirmingProfile.map {
                   String(format: model.loc("Apply “%@”?"), model.loc(OnboardingLogic.title($0)))
               } ?? "",
               isPresented: Binding(get: { model.confirmingProfile != nil },
                                    set: { if !$0 { model.confirmingProfile = nil } }),
               presenting: model.confirmingProfile) { p in
            Button(model.loc("Apply")) { model.applyProfile(p) }
            Button(model.loc("Cancel"), role: .cancel) {}
        } message: { p in
            Text(model.profileChangeList(p))
        }
    }

    /// Dòng radio: vòng tròn bên trái (đặc = đang chọn), tên + câu ví dụ.
    private func profileRow(_ title: String, _ caption: String, selected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.body)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(selected ? .semibold : .regular)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            // Thẻ một lần cho người dùng cũ (ONBOARDING-SPEC §5): nhóm mới nằm ngay dưới.
            // VNI: nhóm đích bị ẩn ⇒ chưa hiện thẻ (cờ giữ nguyên, đổi lại Telex thì hiện).
            if model.mixedCardPending, !OnboardingLogic.mixedGroupHidden(vniMode: model.vniMode) {
                Section {
                    Text(model.loc("Do you often mix English into Vietnamese? See the new Mixed Vietnamese/English typing group."))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(model.loc("Show me")) { model.dismissMixedCard(reveal: true) }
                            .prominentGlass()
                        Button(model.loc("Dismiss")) { model.dismissMixedCard(reveal: false) }
                    }
                }
            }
            // Recovery path for the single most damaging state the app can be in: no
            // Accessibility permission means Terminal/Chrome silently don't get tones.
            // First tab = what "Settings…" opens, so the warning can't be missed.
            if !model.accessibilityTrusted {
                Section {
                    Text("⚠️ " + model.loc("No {PANE} permission — typing will be underlined"))
                        .foregroundStyle(.red)
                    Button {
                        SettingsModel.openAccessibilitySettings()
                    } label: {
                        Label(model.loc("Open {PANE} Settings"), systemImage: "accessibility")
                    }
                    .prominentGlass()
                    Text(model.loc("Tick VietTelex in Privacy & Security → {PANE}. You may need to restart your Mac for the permission to take effect."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // SETTINGS-CLEANUP-SPEC (05/11/2026): cấp 1 chỉ còn Telex/VNI; mọi tuỳ chọn kiểu gõ vào
            // "Nâng cao". §0.4/§6 (06/11/2026): nằm ngay dưới bộ chọn ⇒ mục chỉ-Telex (Simple/Bỏ dấu
            // tự do/Gõ nhanh) ẨN khi chọn VNI (SettingsDeps.styleRows); teencode, phím ngoặc, kiểu
            // mới, sửa dấu từ đã gõ áp dụng cả hai.
            Section(header: Label(model.loc("Input style"), systemImage: "keyboard")) {
                Picker(selection: Binding(
                    get: { model.vniMode ? "vni" : "telex" },
                    set: { model.vniMode = ($0 == "vni") })) {
                    Text("Telex").tag("telex")
                    Text("VNI").tag("vni")
                } label: {
                    rowLabel("Typing method", model.vniMode ? model.loc(C.vni) : nil)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                advancedRow($styleAdvancedOpen, summary: Self.styleAdvancedSummary)
                if styleAdvancedOpen {
                    ForEach(SettingsDeps.styleRows(vniMode: model.vniMode), id: \.self) { r in
                        styleRow(r)
                    }
                }
            }
            // "Gõ lẫn tiếng Anh" (ONBOARDING-SPEC §4 + SETTINGS-CLEANUP-SPEC §1): cấp 1 chỉ là bộ
            // chọn hồ sơ; công tắc nằm trong "Nâng cao". Key lưu không đổi. Chọn VNI ⇒ cả nhóm vô
            // tác dụng: chỉ một dòng ghi chú (OnboardingLogic.mixedRows).
            Section(header: Label(model.loc("Mixed Vietnamese/English typing"), systemImage: "globe")) {
                let rows = OnboardingLogic.mixedRows(vniMode: model.vniMode)
                if rows.contains(.vniNote) {
                    caption(C.vniMixedNote)
                }
                if rows.contains(.profilePicker) {
                    profilePicker
                }
                if rows.contains(.advanced) {
                    advancedRow($mixedAdvancedOpen, summary: Self.mixedAdvancedSummary)
                }
                if rows.contains(.advanced) && mixedAdvancedOpen {
                    // §0.4/§6: mục con ngay dưới cha ⇒ ẩn khi cha tắt (SettingsDeps.mixedAdvancedRows).
                    ForEach(SettingsDeps.mixedAdvancedRows(autoRestore: model.autoRestore,
                                                           contextualEnglish: model.contextualEnglish),
                            id: \.self) { r in
                        mixedAdvancedRow(r)
                    }
                }
            }
            .id(Self.mixedAnchor)
            // "Chuyển Việt/Anh" (spec §1): phím chuyển (cấp 1) + Nâng cao: giữ VietTelex khi macOS tự
            // đổi bộ gõ, phím tắt nguồn nhập của macOS.
            Section(header: Label(model.loc("Switching Vietnamese/English"), systemImage: "arrow.left.arrow.right")) {
                Picker(selection: $model.switchHotkey) {
                    Text(model.loc("Off — use the macOS shortcut")).tag("off")
                    Text("⌃⇧  Control + Shift").tag("ctrl-shift")
                    Text("⌥⇧  Option + Shift").tag("opt-shift")
                    Text("⌘⇧  Command + Shift").tag("cmd-shift")
                } label: {
                    rowLabel("Toggle VietTelex with", model.loc(C.hotkey))
                }
                HStack {
                    rowLabel(Self.perDocumentTitle, model.loc(Self.perDocumentCaption))
                    Spacer()
                    Button(model.loc("Open…")) { TelexInputController.openKeyboardInputSources() }
                }
                advancedRow($switchAdvancedOpen, summary: Self.switchAdvancedSummary)
                if switchAdvancedOpen {
                    toggleRow("Keep VietTelex when macOS auto-switches the input source",
                              isOn: $model.stickyInputSource, caption: C.sticky)
                    toggleRow("Play a sound when switching Vietnamese/English",
                              isOn: $model.switchSound, caption: C.switchSound)
                    HStack {
                        rowLabel("macOS input source shortcut", model.loc(C.osShortcut))
                        Spacer()
                        Button(model.loc("Open…")) { TelexInputController.openInputSourceHotkeySettings() }
                    }
                }
            }
            Section(header: Label(model.loc("Spelling"), systemImage: "textformat.abc.dottedunderline")) {
                toggleRow("Live spell-check", isOn: $model.liveSpellCheck, caption: C.liveSpell)
            }
            // Spec §0.7/§4: không lặp cài đặt hệ thống — chỉ một dòng link cuối trang (trước 05/11 là
            // cả một mục có tiêu đề + đoạn liệt kê dài).
            Section {
                Button {
                    TelexInputController.openKeyboardInputSources()
                } label: {
                    Label(model.loc("Open Input Sources settings…"), systemImage: "gearshape")
                }
                caption(Self.systemSettingsCaption)
            }
        }
        .formStyle(.grouped)
        .onReceive(model.$revealMixed) { reveal in
            guard reveal else { return }
            model.revealMixed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation { proxy.scrollTo(Self.mixedAnchor, anchor: .top) }
            }
        }
        }
        .onAppear { model.refreshAccessibilityStatus() }
        // Event-driven, like the mode table: the user leaves for System Settings and
        // comes back, which makes this window key again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshAccessibilityStatus()
        }
        // …and the moment the checkbox is ticked, WITHOUT waiting for the user to come
        // back here. System Settings keeps the focus after a grant, so with only the
        // didBecomeKey trigger above the red warning stayed on screen next to a
        // permission that was already live — reported as "cấp quyền rồi nhưng vẫn báo".
        // Same distributed notification main.swift already observes for the tap.
        // receive(on: main): the DNC publisher gives no delivery-thread guarantee
        // (main.swift specifies queue: .main explicitly for the same reason), and
        // the handler mutates @Published state.
        .onReceive(DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("com.apple.accessibility.api"))
            .receive(on: DispatchQueue.main)) { _ in
            model.accessibilityMayHaveChanged()
        }
        // macOS 27: the pane above may not post that notification at all — the tap
        // controller's own poll / UI re-checks announce the transition instead.
        .onReceive(NotificationCenter.default.publisher(for: .telexTrustStateChanged)) { _ in
            model.refreshAccessibilityStatus()
        }
    }
}

// MARK: - Tab: Công cụ & gợi ý

/// Trước 14/10/2026 là một mục thu gọn được trong Tùy chỉnh; giờ phẳng, hai mục. Từ 05/11/2026
/// tên "Gợi ý & công cụ" (spec cleanup §4, cùng tên desktop) ⇒ gợi ý đứng trước.
struct ToolsTab: View {
    @EnvironmentObject var model: SettingsModel

    /// Chú thích MỘT dòng ngắn (06/11/2026, như `TypingTab.C`): ≤ 95 ký tự, một ví dụ.
    enum C {
        static let math = "Type a sum ending in = (12*3=); the result shows by the cursor, Tab inserts it."
        static let money = "Type 1tr2 + space → 1.200.000 ₫ shows by the cursor; Tab replaces."
        static let typo = "After a typo (tpoi), the fix (tôi) shows by the cursor; Tab replaces, Esc ignores."
        static let tones = "After 3+ unaccented syllables, toi di hoc → tôi đi học shows by the cursor; Tab replaces."
        static let dates = "Type hôm nay (or today) + space → the date (28/09/2026) shows; Tab replaces."
        static let filter = "Suggestions never offer swear words; typing them yourself still works."
        static let learn = "Learns words you type often; stays on this Mac. Needs macOS inline predictive text."
        static let toolsHotkey = "Opens Tools… by the cursor in any app; press again to close."
        static let addTones = "Adds tones to the selection in any app. Needs {PANE}; clipboard is restored."
        static let translate = "Translates the selection, or back to Vietnamese. Runs on this Mac; text is never sent."
        static let all = [math, money, typo, tones, dates, filter, learn, toolsHotkey, addTones, translate,
                          SettingsModel.textToolsCaptionKey(toolCount: 6),
                          SettingsModel.textToolsCaptionKey(toolCount: 7)]
    }

    private func toggleRow(_ titleKey: String, isOn: Binding<Bool>, caption: String) -> some View {
        Toggle(isOn: isOn) { SettingRowLabel(title: model.loc(titleKey), caption: model.loc(caption)) }
    }

    var body: some View {
        Form {
            Section(header: Label(model.loc("Suggestions next to the cursor"), systemImage: "text.cursor")) {
                toggleRow("Show maths results", isOn: $model.mathResults, caption: C.math)
                toggleRow("Money amount suggestions", isOn: $model.numberChips, caption: C.money)
                toggleRow("Suggest typo fixes", isOn: $model.typoHints, caption: C.typo)
                toggleRow("Suggest tones for unaccented sentences", isOn: $model.toneHints, caption: C.tones)
                toggleRow("Suggest dates and times", isOn: $model.dateHints, caption: C.dates)
                toggleRow("Filter sensitive words", isOn: $model.filterSensitive, caption: C.filter)
                // Học từ bạn gõ (LearnedWords.swift) — cạnh "Lọc từ nhạy cảm", cùng nhóm gợi ý từ.
                toggleRow("Learn from your typing", isOn: $model.learnWords, caption: C.learn)
                Button(model.loc("Clear learned words…")) { confirmClearLearned() }
            }
            Section(header: Label(model.loc("Text tools"), systemImage: "textformat")) {
                toggleRow("Show text tools in the VietTelex menu", isOn: $model.textToolsInMenu,
                          caption: SettingsModel.textToolsCaptionKey(toolCount: TextToolsPanelLogic.tools.count))
                Picker(selection: $model.toolsPanelHotkey) {
                    ForEach(TextActionHotkey.toolsChoices, id: \.id) { c in
                        Text(c.id == "off" ? model.loc("Off") : c.label).tag(c.id)
                    }
                } label: {
                    SettingRowLabel(title: model.loc("Tools panel hotkey"), caption: model.loc(C.toolsHotkey))
                }
                Picker(selection: $model.addTonesHotkey) {
                    ForEach(TextActionHotkey.choices, id: \.id) { c in
                        Text(c.id == "off" ? model.loc("Off") : c.label).tag(c.id)
                    }
                } label: {
                    SettingRowLabel(title: model.loc("Add-tones hotkey"), caption: model.loc(C.addTones))
                }
                if #available(macOS 26.0, *) {
                    TranslateSettingsRows()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "Xoá từ đã học…": hỏi xác nhận (Huỷ là nút mặc định) rồi xoá RAM + file (LearnedWords).
    private func confirmClearLearned() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = model.loc("Clear learned words?")
        alert.informativeText = model.loc("Word suggestions forget every word and word pair learned from your typing on this Mac. It cannot be undone.")
        alert.addButton(withTitle: model.loc("Cancel"))
        alert.addButton(withTitle: model.loc("Clear"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        LearnedWords.shared.clearAll()
    }
}

// MARK: - Tab: Bảng chế độ gõ

/// One table of every app VietTelex knows: learned by the probe, pinned by the
/// user, or built-in. Column 2 is a dropdown — "Auto — <detected>" plus the 5
/// manual strategies. Replaces the old "App compatibility" (Tùy chỉnh) and
/// "App mode" (Thử Nghiệm) sections.
struct ModeTableTab: View {
    @EnvironmentObject var model: SettingsModel

    /// Chú thích ngắn một dòng (06/11/2026: đoạn giải thích dài → một dòng; quyền nằm ở tên cách
    /// gõ cần nó, "Xoá dữ liệu đã học" giải thích bằng tooltip).
    enum C {
        static let intro = "App types wrong or underlines? Change its mode — if unsure, leave it on Auto."
        static let safe = "Unrecognized apps: Real keystrokes (Underline without permission) instead of guessing."
        static let relearn = "Forgets learned modes; the modes you picked stay."
        static let all = [intro, safe, relearn]
    }
    static let safeTitle = "Safe typing for unrecognized apps"

    /// Một dòng giải thích cách gõ đang chọn (tooltip của picker trong bảng), theo tag
    /// AppState.AppMode. Khoá Localizable.strings.
    static let modeHelp: [String: String] = [
        "auto": "Auto: VietTelex picks how to type in this app.",
        "inPlace": "Edit in the field: tones are fixed right inside the text field.",
        "tap": "Real keystrokes: types like a keyboard (Backspace, retype), no underline.",
        "marked": "Underline: the word being typed is underlined and always shows correctly.",
        "axDetect": "Detect per field: picks a mode for each field (address bar, page…).",
        "selection": "Select and retype: selects the word being typed, then types over it.",
        "emptyReset": "Excel style: only for Excel cells.",
        "passthrough": "Vietnamese off: keys reach this app unchanged.",
    ]

    /// Tên cách gõ cần quyền: thêm "(cần quyền …)" chỉ khi CHƯA cấp — cấp rồi thì gọn.
    private func axModeName(_ key: String) -> String {
        Accessibility.isTrusted ? model.loc(key) : model.loc(key) + " (" + model.loc(ModeNames.needsPermission) + ")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.loc(C.intro))
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.loc("Filter by app name, bundle id, or mode"), text: $model.modeFilter)
                    .textFieldStyle(.roundedBorder)
                if !model.modeFilter.isEmpty {
                    Button {
                        model.modeFilter = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(model.loc("Clear filter"))
                }
            }
            Table(model.visibleModeRows, sortOrder: $model.modeSortOrder) {
                TableColumn(model.loc("App"), value: \.name) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                        if row.name != row.id {
                            Text(row.id).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                TableColumn(model.loc("Detected"), value: \.detected) { row in
                    // What Auto resolves to for this app right now. Grayed out when a
                    // manual pick overrides it. ⚠️ = degraded because Accessibility
                    // is missing (tooltip explains on hover).
                    HStack(spacing: 4) {
                        Text(row.detected)
                            .foregroundStyle(model.appMode(row.id) == "auto" ? .primary : .tertiary)
                        if row.missingPermission {
                            // Clickable: seeing the warning and FIXING it should be
                            // one gesture, not a settings scavenger hunt.
                            Button {
                                SettingsModel.openAccessibilitySettings()
                            } label: { Text("⚠️") }
                                .buttonStyle(.borderless)
                                .help(model.loc("Missing {PANE} permission — click to open System Settings"))
                                .accessibilityLabel(model.loc("Missing {PANE} permission — click to open System Settings"))
                        }
                    }
                }.width(min: 120)
                TableColumn(model.loc("Manual"), value: \.manual) { row in
                    // Common picks first (Auto / In-place / Tap / Marked cover ~95%
                    // of real overrides — In-place lên ngay dưới Auto: maintainer
                    // 15/08/2026); the specialist modes sit below the divider —
                    // Empty-reset exists for exactly one app (Excel), and picking it
                    // elsewhere types stray U+202F.
                    Picker("", selection: Binding(get: { model.appMode(row.id) },
                                                  set: { model.setAppMode(row.id, $0) })) {
                        Text(model.loc("Auto")).tag("auto")
                        Text(model.loc(ModeNames.inPlace)).tag("inPlace")
                        Text(axModeName(ModeNames.tap)).tag("tap")
                        Text(model.loc(ModeNames.marked)).tag("marked")
                        Divider()
                        Text(axModeName(ModeNames.axDetect)).tag("axDetect")
                        Text(axModeName(ModeNames.selection)).tag("selection")
                        Text(axModeName(ModeNames.emptyReset)).tag("emptyReset")
                        Text(model.loc(ModeNames.passthrough)).tag("passthrough")
                    }
                    .labelsHidden()
                    .accessibilityLabel(row.name)
                    .help(model.loc(Self.modeHelp[model.appMode(row.id)] ?? Self.modeHelp["auto"]!))
                }.width(min: 150)
                TableColumn("") { row in
                    if row.deletable {
                        Button(role: .destructive) { model.deleteRow(row.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(model.loc("Forget this app (pin + learned data)"))
                        .accessibilityLabel(model.loc("Forget this app (pin + learned data)"))
                    }
                }.width(28)
            }
            .frame(minHeight: 230, maxHeight: .infinity)
            // A filter that matches nothing used to show an empty table with no
            // explanation — indistinguishable from "VietTelex knows no apps".
            .overlay {
                if model.visibleModeRows.isEmpty, !model.modeFilter.isEmpty {
                    Text(String(format: model.loc("No app matches “%@”"), model.modeFilter))
                        .font(.callout).foregroundStyle(.secondary)
                        .padding()
                }
            }

            if model.modeRows.isEmpty {
                Text(model.loc("Empty — type a few Vietnamese words in any app and it will appear here."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if !model.recentApps.isEmpty {
                    Picker(model.loc("Add recent app"), selection: $model.newModeAppID) {
                        Text(model.loc("Choose an app…")).tag("")
                        ForEach(model.recentApps, id: \.id) { app in
                            Text(app.name).tag(app.id)
                        }
                    }
                    .frame(maxWidth: 240)
                }
                TextField(model.loc("…or a bundle id"), text: $model.newModeAppID)
                    .textFieldStyle(.roundedBorder)
                Button { model.addApp() } label: { Label(model.loc("Add"), systemImage: "plus.circle") }
                    .disabled(model.newModeAppID.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { model.browseApp() } label: { Label(model.loc("Browse…"), systemImage: "folder") }
            }

            HStack {
                // role .destructive alone doesn't tint a bordered macOS button —
                // color the label explicitly so the destructive action reads as one.
                Button(role: .destructive) { model.clearLearned() } label: {
                    Label(model.loc("Clear & re-learn"), systemImage: "arrow.counterclockwise.circle").foregroundStyle(.red)
                }
                .help(model.loc(C.relearn))
                Spacer()
                Button { importModes() } label: { Label(model.loc("Import…"), systemImage: "square.and.arrow.down") }
                Button { exportModes() } label: { Label(model.loc("Export to YAML…"), systemImage: "square.and.arrow.up") }
            }
            // Từ tab Thử nghiệm (14/10/2026): "app nào gõ thế nào". "Giữ VietTelex khi macOS tự đổi
            // bộ gõ" chuyển sang Gõ phím → Chuyển Việt/Anh (spec cleanup §1, 05/11/2026).
            // 06/11/2026: hàng công tắc như tab Gõ phím — tên + một dòng chú thích, công tắc bên phải.
            Divider().padding(.vertical, 2)
            HStack {
                SettingRowLabel(title: model.loc(Self.safeTitle),
                                caption: model.loc(C.safe))
                Spacer()
                Toggle("", isOn: $model.safeUnknownApps)
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(model.loc(Self.safeTitle))
            }
        }
        .onAppear { model.reloadModeTable() }
        // The user's flow is: keep Settings open → type a tone word in the target
        // app → come back. Refresh when the Settings window regains key so the
        // just-learned row appears without reopening the tab (event-driven, no timer).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.reloadModeTableThrottled()
        }
    }

    /// Import manual pins (bundleID → mode) from a YAML/JSON/txt file — the same
    /// container format the Shortcuts tab uses, so the flow is familiar. Merge, not
    /// replace: imported entries win, everything else is kept.
    private func importModes() {
        let panel = NSOpenPanel()
        // YAML (typing-modes.yml, our export) — JSON/txt also accepted. Same set the
        // export panel offers, so the picker can't hand us a .png to "parse".
        panel.allowedContentTypes = [.yaml, .json, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let dict = ShortcutImporter.parse(data)
        else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = VTLocalized("Couldn’t read the file")
            alert.informativeText = VTLocalized("Supported formats: YAML, JSON, or one key:value per line.")
            alert.runModal()
            return
        }
        let applied = model.importManualModes(dict)
        let alert = NSAlert()
        alert.messageText = String(format: VTLocalized("Imported %lld app modes"), applied)
        alert.informativeText = VTLocalized("Merged into the table (existing pins for the same app take the imported value). Entries with an unknown mode were skipped.")
        alert.runModal()
    }

    /// Export the manual pins only — learned entries are per-machine probe results
    /// that re-learn themselves and would just be noise on another install.
    private func exportModes() {
        // Flat YAML like typing-modes.yml (user decision 2026-07-22).
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.nameFieldStringValue = "viettelex-app-modes.yml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let yaml = ShortcutImporter.exportYAML(AppState.shared.manualModes)
        try? Data(yaml.utf8).write(to: url)
    }
}

// MARK: - Tab: Chung

/// Tab cuối (14/10/2026): ngôn ngữ, icon menu bar, iCloud, cập nhật, Giới thiệu (gộp tab Giới thiệu
/// cũ), "Nâng cao / Gỡ lỗi" (nhật ký gỡ lỗi) ở cuối.
struct GeneralTab: View {
    @EnvironmentObject var model: SettingsModel

    /// `.id` của dòng đầu khối cập nhật — đích cuộn của `revealUpdate`.
    static let updateAnchor = "update"

    /// Chú thích MỘT dòng ngắn của tab Chung (06/11/2026, như `TypingTab.C`): ≤ 95 ký tự.
    enum C {
        static let menuIcon = "One color only. Changing it breaks the app’s code seal (it still works). Restart to apply."
        static let icloud = "Same Apple ID as VietTelex on iPhone. Syncs Telex options and shortcuts; iCloud wins first."
        static let icloudUnavailable = "Not available in this build (it isn’t signed with iCloud)."
        static let weekly = "Manual check: the newest release on GitHub. Weekly check: the stable channel."
        static let debugLog = "Records events in memory, never your text. Reproduce the bug, then copy the log."
        static let endWord = "Apps and scripts can post com.viettelex.endWord to end the word being typed."
        static let all = [menuIcon, icloud, icloudUnavailable, weekly, debugLog, endWord]
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                // Thứ tự spec cleanup §4 (05/11/2026): ngôn ngữ, biểu tượng, đồng bộ, cập nhật, (giới
                // thiệu), Nâng cao / Gỡ lỗi. Phím chuyển bộ gõ ở Gõ phím → Chuyển Việt/Anh.
                // No Section header: the Picker's own label already says "Language" —
                // two identical labels stacked read as a bug.
                Section {
                    Picker(model.loc("Language"), selection: $model.uiLanguage) {
                        Text(model.loc("System")).tag("system")
                        Text("Tiếng Việt").tag("vi")
                        Text("English").tag("en")
                    }
                }
                Section(header: Label(model.loc("Menu bar icon"), systemImage: "star.square")) {
                    Picker(selection: $model.menuIcon) {
                        Text("Vᴛ — " + model.loc("default")).tag("vt")
                        Text("★ — " + model.loc("five-pointed star")).tag("star")
                        Text("🇻🇳 — " + model.loc("Vietnam flag")).tag("flag")
                    } label: {
                        SettingRowLabel(title: model.loc("Icon"), caption: model.loc(C.menuIcon))
                    }
                    if model.menuIconApplied {
                        Text(model.loc("Icon saved — restart your Mac to see it."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section(header: Label(model.loc("iCloud sync"), systemImage: "icloud")) {
                    Toggle(isOn: $model.icloudSync) {
                        SettingRowLabel(title: model.loc("Sync typing settings and shortcuts with iPhone/iPad"),
                                        caption: model.loc(ICloudSync.hasEntitlement ? C.icloud : C.icloudUnavailable))
                    }
                    .disabled(!ICloudSync.hasEntitlement)
                    if model.icloudSync, !ICloudSync.shared.iCloudAvailable {
                        Text("⚠️ " + model.loc("This Mac isn’t signed in to iCloud."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                UpdateSection()
                AboutSection()
                DiagnosticsSection()
            }
            .formStyle(.grouped)
            .onReceive(model.$revealUpdate) { reveal in
                guard reveal else { return }
                model.revealUpdate = false
                // Một hop để Form dựng xong (mở mới: cửa sổ vừa tạo) rồi mới cuộn.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation { proxy.scrollTo(Self.updateAnchor, anchor: .top) }
                }
            }
        }
    }
}

/// Chẩn đoán (từ tab Thử nghiệm): nhật ký gỡ lỗi — ghi / chép / lưu / xoá.
struct DiagnosticsSection: View {
    /// Tên mục chung desktop (spec cleanup §4): "Nâng cao / Gỡ lỗi".
    static let headerKey = "Advanced / Debugging"
    static let endWordTitle = "Accept the “end of word” signal from other apps"
    @EnvironmentObject var model: SettingsModel
    @State private var saveResult: String?

    var body: some View {
        Section(header: Label(model.loc(Self.headerKey), systemImage: "stethoscope")) {
            // #156: tín hiệu cho người viết app/script (hdsd). Mặc định bật; tắt = 0 chi phí.
            Toggle(isOn: $model.endWordSignal) {
                SettingRowLabel(title: model.loc(Self.endWordTitle), caption: model.loc(GeneralTab.C.endWord))
            }
            Toggle(isOn: $model.debugLogging) {
                SettingRowLabel(title: model.loc("Record debug log"), caption: model.loc(GeneralTab.C.debugLog))
            }
            HStack {
                Button { copyLog() } label: { Label(model.loc("Copy debug log"), systemImage: "doc.on.doc") }
                Button { saveLog() } label: { Label(model.loc("Save debug log…"), systemImage: "square.and.arrow.down") }
                Button { DebugLog.clear(); saveResult = nil } label: { Label(model.loc("Clear"), systemImage: "trash") }
            }
            if let saveResult {
                Text(saveResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            // Đếm cục bộ (chỉ số lần, không bao giờ chữ): ⌫ trả lại chữ Việt sau khi tự khôi phục tiếng Anh.
            let undo = DebugLog.restoreUndoStats
            Text(String(format: model.loc("Undo after English restore: %d used / %d offered (this session)"),
                        undo.used, undo.offered))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Clipboard, not a file. The report flow (BAO-LOI.md) ends with the log pasted
    /// into a GitHub issue or a chat message, and save → find the file → attach it was
    /// the slowest step of it — for a user who is, by definition, already annoyed.
    /// Same snapshot as saveLog(), so a pasted log and a saved one are identical.
    private func copyLog() {
        let text = DebugLog.snapshot(header: DebugHeader.build())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        saveResult = model.loc("Copied — paste it into your bug report.")
    }

    private func saveLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "VietTelex-debug.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = DebugLog.snapshot(header: DebugHeader.build())
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            saveResult = String(format: model.loc("Saved to %@"), url.lastPathComponent)
        } catch {
            saveResult = model.loc("Couldn’t save the file.")
        }
    }
}

/// Extracted from the diagnostics UI so it's testable without a SwiftUI environment —
/// debugHeader() never touched `model`, only AppState.shared and statics.
enum DebugHeader {
    static func build() -> [String] {
        let s = AppState.shared
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        // Build timestamp = executable mtime — uniquely identifies THIS build, so we
        // can confirm the newest install is actually running (version string alone
        // doesn't change between rebuilds).
        let exePath = (Bundle.main.executableURL ?? Bundle.main.bundleURL).path
        let buildDate = (try? FileManager.default.attributesOfItem(atPath: exePath)[.modificationDate]) as? Date ?? Date()
        let bf = DateFormatter(); bf.dateFormat = "dd/MM HH:mm:ss"
        let build = bf.string(from: buildDate)
        let id = s.currentBundleID
        let frontID = FrontmostApp.shared.bundleID
        // tapRouting, not the per-mode getters — see the same note in showDebugLog:
        // browser page content is tap by policy without being in any tap-mode set.
        let routing = s.tapRouting(id)
        let mode: String
        if routing.selection { mode = "tap · selection-replace" }
        else if routing.tap { mode = "tap · backspace" }
        else if routing.emptyReset { mode = "tap · emptyReset" }
        else if s.usesMarkedText(id) { mode = "IMKit · marked text" }
        else { mode = "IMKit · in-place" }
        let inPlace = s.learnedInPlaceApps
        let fallback = s.learnedFallbackApps
        let manual = s.manualModes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let mem = MemoryFootprint.sample()
        return [
            "VietTelex debug log — v\(version) (build \(build))",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "accessibility: \(Accessibility.isTrusted ? "granted" : "MISSING")",
            "tap running: \(TerminalTapController.shared.isRunning)",
            "undo after English restore: \(DebugLog.restoreUndoStats.used) used / \(DebugLog.restoreUndoStats.offered) offered (this session)",
            // Activity Monitor's "Memory" for this process + its high-water mark: a large
            // gap = a transient peak (Settings) whose pages malloc still holds.
            "memory: \(MemoryFootprint.megabytes(mem.current)) (peak \(MemoryFootprint.megabytes(mem.peak)))",
            "current app: \(id ?? "?")  frontmost: \(frontID ?? "?")",
            "handling: \(mode)",
            "  usesTapMode(id)=\(s.usesTapMode(id)) usesTapMode(front)=\(s.usesTapMode(frontID))",
            "  usesMarkedText=\(s.usesMarkedText(id)) selectionReplace=\(s.usesSelectionReplace(id)) emptyReset=\(s.usesEmptyReset(id))",
            "  needsProbe=\(s.needsProbe(id)) spotlightVisible=\(SpotlightDetector.isVisible)",
            "learned in-place OK: \(inPlace.isEmpty ? "(none)" : inPlace.joined(separator: ", "))",
            "learned fallback (tap/marked): \(fallback.isEmpty ? "(none)" : fallback.joined(separator: ", "))",
            "manual overrides: \(manual.isEmpty ? "(none)" : manual.joined(separator: ", "))",
            // tapNativeFastPath: hidden flag (no UI — `defaults write com.viettelex.settings
            // tapNativeFastPath -bool false`), directly on the terminal-tap hot path. Missing
            // from every prior debug log meant a tester's own `defaults write` was invisible
            // evidence ("chỉ mỗi em bị" — 2026-08-05).
            "flags: modifyInPlace=\(s.tapModifyEventInPlace) skipKeyUp=\(s.tapSkipSyntheticKeyUp) axReplace=\(s.axSelectionReplace) breaker=\(s.tapCascadeBreaker) nativeFastPath=\(s.tapNativeFastPath)",
            "settings: simpleTelex=\(s.simpleTelex) freeMarking=\(s.freeMarking) modern=\(s.modernOrthography) liveSpell=\(s.liveSpellCheck) autoRestore=\(s.autoRestore) vni=\(s.vniMode) quick=\(s.quickTelex) ctxEnglish=\(s.contextualEnglish) retroEnglish=\(s.retroactiveEnglish) freqEnglish=\(s.englishByFrequency) teencode=\(s.teencode) autoCircumflex=\(s.autoCircumflex) collisionVN=\(s.collisionPrefersVietnamese) reEdit=\(s.reEditWord) bracket=\(s.bracketVowels) safeUnknown=\(s.safeUnknownApps) endWord=\(s.endWordSignal)",
            // Count only — the trigger/expansion pairs are USER-TYPED content the log
            // must never carry (same rule as everywhere else here), but a nonzero count
            // is itself diagnostic: a custom gõ tắt entry colliding with a Vietnamese
            // prefix is exactly the kind of "settings khác" one tester could have that
            // reproduces nothing on a clean install (2026-08-05 field discussion).
            "custom shortcuts: \(s.shortcuts.count)",
            // Recorded ALWAYS (not only with debug logging on): a key that took >250ms
            // and which app it was charged to — the evidence #118 lacked.
            ClientStallBreaker.shared.reportLine(),
            // Also always: superhuman key bursts passed verbatim (agents, #118).
            MachineTypingLog.reportLine(),
        ]
    }
}

// MARK: - Chung: Giới thiệu + cập nhật (tab Giới thiệu cũ)

/// Icon, tên, phiên bản, liên kết, gỡ cài đặt — một mục của tab Chung.
struct AboutSection: View {
    @EnvironmentObject var model: SettingsModel

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Build date (dd/MM/yyyy) from the executable's modification time — updates
    /// itself every build, no manual bump.
    private var buildDate: String {
        let path = (Bundle.main.executableURL ?? Bundle.main.bundleURL).path
        let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? Date()
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"
        return f.string(from: date)
    }

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    /// The app icon (Asset Catalog "AppIcon"). Resolved via the special
    /// application-icon name so it works regardless of icns vs asset-catalog.
    private var appIcon: NSImage {
        NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    var body: some View {
        Section(header: Label(model.loc("About"), systemImage: "info.circle")) {
            HStack(spacing: 14) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppState.isDevelopmentBuild ? "VietTelex Dev" : "VietTelex").font(.title3).bold()
                    Text(String(format: model.loc("Version %@ · %@"), appVersion, buildDate))
                        .foregroundStyle(.secondary)
                    Text("© \(String(currentYear)) Phil Trinh").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                Link("Website", destination: URL(string: "https://ptrinh.github.io/viettelex/")!)
                Link(model.loc("User guide"),
                     // UI đang tiếng Anh (kể cả "system" ra en) ⇒ bản tiếng Anh của trang.
                     destination: URL(string: model.loc("User guide") == "User guide"
                                      ? "https://viettelex.com/en/guide/?os=macos"
                                      : "https://viettelex.com/hdsd/?os=macos")!)
                Link(model.loc("Learn Telex typing"),
                     destination: URL(string: "https://ptrinh.github.io/viettelex/learn")!)
                Link(model.loc("FAQ"),
                     destination: URL(string: "https://ptrinh.github.io/viettelex/#faq")!)
                Link(model.loc("How to report a bug"),
                     destination: URL(string: "https://github.com/ptrinh/viettelex/blob/main/BAO-LOI.md")!)
            }
            .font(.callout)
            // Gỡ cài đặt trọn gói — hỏi xác nhận bằng NSAlert kiểu critical trước khi
            // làm gì (không hoàn tác được: xoá app + toàn bộ settings/gõ tắt).
            Button(role: .destructive) { confirmUninstall() } label: {
                Label(model.loc("Uninstall VietTelex…"), systemImage: "trash")
                    .foregroundStyle(.red)
            }
        }
    }

    /// Hỏi xác nhận (Huỷ là nút mặc định — Enter không được gỡ nhầm) rồi giao cho
    /// Uninstaller. Xong hiện tổng kết và thoát process — app đã tự xoá, không còn
    /// gì để chạy tiếp.
    private func confirmUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = model.loc("Uninstall VietTelex?")
        alert.informativeText = model.loc("This removes the app, every setting and all your shortcuts. It cannot be undone.")
        alert.addButton(withTitle: model.loc("Cancel"))          // nút đầu = default (Return)
        alert.addButton(withTitle: model.loc("Uninstall"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let summary = Uninstaller.run()
        let done = NSAlert()
        done.messageText = summary
        done.runModal()
        exit(0)
    }
}

/// Kiểm tra / cài cập nhật — đích của mục menu "Có bản cập nhật" (`GeneralTab.updateAnchor`).
struct UpdateSection: View {
    @EnvironmentObject var model: SettingsModel

    @State private var checking = false
    @State private var status: String?     // result line under the button
    /// Set only when a newer release exists — the version the button will install.
    /// (No URL state: SelfUpdater's own failure alert offers the releases page.)
    @State private var updateVersion: String?
    /// Changelog for `updateVersion`, PARSED once at assignment rather than held as raw
    /// Markdown: `body` re-runs on every `model` publish and on each checking/installing/
    /// status flip, and re-splitting a 4000-character release body inside `ForEach` on
    /// every one of those is work with no reason to repeat. Empty = no notes to show
    /// (release had no body, or GitHub couldn't be reached for it).
    @State private var noteBlocks: [UpdateCheck.NoteBlock] = []
    @State private var installing = false

    var body: some View {
        Section(header: Label(model.loc("Updates"), systemImage: "arrow.triangle.2.circlepath")) {
            // Manual update check — the only thing that touches the network, and
            // only on this click (see Updater.swift).
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if checking || installing {
                        ProgressView().controlSize(.small)
                    } else if let updateVersion {
                        // Self-install, the SAME path the weekly notification's "Update now"
                        // uses: download the release app.zip → verify Developer ID + our team
                        // → atomic bundle swap → relaunch. A failure falls back to the
                        // releases page via SelfUpdater's own alert.
                        Button {
                            installing = true
                            status = model.loc("Downloading and installing…")
                            SelfUpdater.run(version: updateVersion) {
                                installing = false
                                status = nil                     // SelfUpdater showed the reason
                            }
                        } label: {
                            Label(model.loc("Update now"), systemImage: "arrow.down.circle")
                        }
                        .prominentGlass()
                    } else {
                        Button { runCheck() } label: { Label(model.loc("Check for updates"), systemImage: "arrow.triangle.2.circlepath") }
                            .prominentGlass()
                    }
                    if let status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                // "Update available: 1.6.3" alone asks the user to install on faith. The
                // release body answers what changed — same box for both channels, since
                // the weekly check now stores its notes too (Updater.swift).
                if !noteBlocks.isEmpty {
                    releaseNotesBox()
                }
            }
            .id(GeneralTab.updateAnchor)
            // The release updater always installs into the stable app path.
            .disabled(!AppState.isStableBuild)
            // Opt-in weekly auto-check (default OFF): the toggle IS the user's
            // consent, so the "no network unless you ask" stance holds.
            // The two checks deliberately follow DIFFERENT channels (Updater.swift) —
            // say so, or "check" finding 1.4.21 right after the weekly notice said
            // 1.4.20 looks broken.
            Toggle(isOn: $model.autoUpdateCheck) {
                SettingRowLabel(title: model.loc("Check weekly and notify me"), caption: model.loc(GeneralTab.C.weekly))
            }
            .disabled(!AppState.isStableBuild)
        }
        .onAppear {
            // Weekly auto-check result, surfaced HERE rather than as a modal that steals
            // focus mid-sentence. This is also the fallback when notification permission
            // was denied — the only place the news can still reach the user.
            if status == nil, updateVersion == nil,
               let pending = UpdateCheck.outstandingUpdate(pending: UpdateCheck.pendingUpdateVersion,
                                                           current: UpdateCheck.currentVersion()) {
                updateVersion = pending
                noteBlocks = UpdateCheck.pendingUpdateNotes.map(UpdateCheck.noteBlocks) ?? []
                status = String(format: model.loc("Update available: %@"), pending)
            }
        }
    }

    /// The changelog, rendered from the release body's Markdown. Scrolls rather than
    /// stretching the form: a release can have three bullets or thirty.
    @ViewBuilder
    private func releaseNotesBox() -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.loc("What’s new")).font(.caption).bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(noteBlocks) { block in
                        switch block.kind {
                        case .heading:
                            Text(inlineMarkdown(block.text)).font(.caption).bold()
                        case .bullet:
                            // Hanging indent: the marker sits outside the text column so
                            // wrapped lines line up under the first word, not the bullet.
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("•").font(.caption).foregroundStyle(.secondary)
                                Text(inlineMarkdown(block.text)).font(.caption)
                            }
                        case .paragraph:
                            Text(inlineMarkdown(block.text)).font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 140)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            // Long bodies are cut at notesCharacterCap, and a body can also out-scroll the
            // box — either way the release page is where the rest lives. Derived from the
            // version, so the weekly channel (which persists no URL) gets the link too.
            if let updateVersion, let full = UpdateCheck.releasePageURL(forVersion: updateVersion) {
                Link(model.loc("Full changelog"), destination: full).font(.caption2)
            }
        }
        .padding(.top, 2)
    }

    /// `Text` interprets inline Markdown only, and only via AttributedString — bold, code
    /// spans and links survive; anything it can't parse falls back to the raw line rather
    /// than disappearing.
    private func inlineMarkdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    private func runCheck() {
        guard AppState.isStableBuild else { return }
        checking = true; status = nil; updateVersion = nil; noteBlocks = []
        UpdateCheck.pendingUpdateVersion = nil   // the user is looking; this is now live state
        UpdateCheck.pendingUpdateNotes = nil
        Task {
            let outcome = await UpdateCheck.check()
            await MainActor.run {
                checking = false
                switch outcome {
                case .upToDate(let v):
                    status = String(format: model.loc("You’re up to date (%@)."), v)
                case .update(let latest, _, let notes):
                    status = String(format: model.loc("Update available: %@"), latest)
                    updateVersion = latest
                    noteBlocks = notes.map(UpdateCheck.noteBlocks) ?? []
                case .failed(let e):
                    status = String(format: model.loc("Couldn’t check — %@."), e)
                }
            }
        }
    }
}

// MARK: - Tab: Gõ tắt

struct ShortcutsTab: View {
    @EnvironmentObject var model: SettingsModel

    /// Chú thích ngắn (06/11/2026): ≤ 95 ký tự.
    enum C {
        static let help = "Expands on space/Enter; case follows (ko → không, Ko → Không). ⌥↩ new line."
        static let conflict = "Chrome/Electron apps expand these via macOS. Short ones (h) can break words: delete in macOS."
        static let all = [help, conflict]
    }
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var selection: ShortcutRow.ID?
    /// The key the fields were LOADED from (row click). Kept separately from `selection`
    /// so editing the key field is a RENAME of that entry, not a silent Add of a second
    /// one — the old bug: click "vn", change the key to "vnn", press the button and you
    /// had both.
    @State private var editingKey: String?

    /// True when saving updates/renames an existing entry rather than adding a new one.
    private var isEditing: Bool {
        editingKey != nil
            || AppState.shared.shortcuts[newKey.trimmingCharacters(in: .whitespaces)] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(model.shortcuts, selection: $selection) {
                TableColumn(model.loc("Type"), value: \.key)
                TableColumn(model.loc("Becomes"), value: \.displayValue)
                TableColumn("") { row in
                    Button(role: .destructive) { model.removeShortcut(row.key) } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless)
                        .accessibilityLabel(model.loc("Delete this shortcut"))
                }.width(40)
            }
            .frame(minHeight: 220)
            .onChange(of: selection) { selected in
                // Click a row -> load it into the fields for editing in place.
                guard let key = selected,
                      let value = AppState.shared.shortcuts[key] else {
                    editingKey = nil
                    return
                }
                newKey = key
                newValue = value
                editingKey = key
            }

            HStack(alignment: .top) {
                TextField(model.loc("type"), text: $newKey).frame(width: 120)
                // Nhiều dòng: ⌥↩ (hoặc ⌃↩) xuống dòng trong ô, ↩ để lưu.
                TextField(model.loc("becomes"), text: $newValue, axis: .vertical)
                    .lineLimit(1...5)
                    .onSubmit { if canSave { save() } }
                Button { save() } label: {
                    Label(model.loc(isEditing ? "Update" : "Add"),
                          systemImage: isEditing ? "checkmark.circle" : "plus.circle")
                }
                    .disabled(!canSave)
            }
            if keyInvalid {
                Text(model.loc("A shortcut key can’t contain spaces (max 64 characters)."))
                    .font(.caption).foregroundStyle(.red)
            }
            Text(model.loc(C.help))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.systemConflicts.isEmpty { systemConflictNote }

            HStack {
                Button { importPlist() } label: { Label(model.loc("Import…"), systemImage: "square.and.arrow.down") }
                Button { exportPlist() } label: { Label(model.loc("Export to YAML…"), systemImage: "square.and.arrow.up") }
                Spacer()
            }
        }
    }

    /// Issue #117: khoá trùng Text Replacements của macOS ("h" → "giờ" ra "giờiờ" ở Lark).
    private var systemConflictNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(model.loc("Also in macOS Text Replacements:"), systemImage: "exclamationmark.triangle")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text(model.systemConflicts.map { c in
                c.sameExpansion ? c.key : "\(c.key) (macOS: \(ShortcutRow.oneLine(c.system)))"
            }.joined(separator: ", "))
                .font(.caption.monospaced())
            Text(model.loc(C.conflict))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.loc("Open Keyboard Settings…")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(model.loc("Check again")) { model.reloadShortcuts() }
            }.controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }

    private var trimmedKey: String { newKey.trimmingCharacters(in: .whitespaces) }
    private var keyInvalid: Bool { !trimmedKey.isEmpty && !ShortcutTable.isValidKey(trimmedKey) }
    private var canSave: Bool { ShortcutTable.isValidKey(trimmedKey) && !newValue.isEmpty }

    private func save() {
        let key = trimmedKey
        guard canSave else { return }
        // Overwriting a DIFFERENT entry than the one being edited needs a confirm —
        // otherwise a typo in the key field silently clobbers an existing shortcut.
        if AppState.shared.shortcuts[key] != nil, editingKey != key {
            let alert = NSAlert()
            alert.messageText = String(format: VTLocalized("Shortcut “%@” already exists"), key)
            alert.informativeText = VTLocalized("Overwrite the existing value?")
            alert.addButton(withTitle: VTLocalized("Overwrite"))
            alert.addButton(withTitle: VTLocalized("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // RENAME: the row was loaded from `editingKey` and the key field was changed, so
        // the user edited an entry — drop the old key instead of leaving a duplicate.
        if let old = editingKey, old != key {
            model.removeShortcut(old)
        }
        model.addShortcut(key: key, value: newValue)
        newKey = ""; newValue = ""; selection = nil; editingKey = nil
    }

    private func importPlist() {
        let panel = NSOpenPanel()
        // Any text-ish file: YAML, JSON, or "key:value" txt
        // (exports from other IMEs) — ShortcutImporter sniffs the format. Same set the
        // export panel writes, so an image/binary can't be handed to the parser.
        panel.allowedContentTypes = [.yaml, .json, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let dict = ShortcutImporter.parse(data)
        else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = VTLocalized("Couldn’t read the file")
            alert.informativeText = VTLocalized("Supported formats: YAML, JSON, or one key:value per line.")
            alert.runModal()
            return
        }
        // Merge (imported entries win) rather than replace, so importing a shared
        // list never silently wipes the user's existing shortcuts.
        let merged = AppState.shared.shortcuts.merging(dict) { _, imported in imported }
        AppState.shared.setShortcuts(merged)
        model.reloadShortcuts()
        let alert = NSAlert()
        alert.messageText = String(format: VTLocalized("Imported %lld shortcuts"), dict.count)
        alert.informativeText = VTLocalized("Merged into the existing table (duplicates take the new value).")
        alert.runModal()
    }

    private func exportPlist() {
        // Flat YAML (user decision 2026-07-22): readable, editable, and the
        // universal importer round-trips it.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.nameFieldStringValue = "viettelex-shortcuts.yaml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let yaml = ShortcutImporter.exportYAML(AppState.shared.shortcuts)
        try? Data(yaml.utf8).write(to: url)
    }
}
