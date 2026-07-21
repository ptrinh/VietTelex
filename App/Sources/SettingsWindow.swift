// SettingsWindow.swift
// SwiftUI settings (3 tabs: Tùy chỉnh, Gõ tắt, Giới thiệu). The window is created
// only when opened from the IMK menu and released when closed (windowWillClose
// drops the reference).
//
// There is no VI/EN enable/disable: Vietnamese is on whenever VietTelex is the active
// macOS input source. To type English, switch input source (macOS remembers it per
// app when "automatically switch to a document's input source" is on).

import AppKit
import SwiftUI
import TelexCore

enum SettingsTab: Hashable { case general, shortcuts, modeTable, experimental, about }

// MARK: - Window controller

final class SettingsWindowController: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var model: SettingsModel?

    func show(tab: SettingsTab) {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let model = SettingsModel(selected: tab)
            let root = SettingsView().environmentObject(model)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = VTLocalized("VietTelex — Settings")
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(NSSize(width: 680, height: 560))
            win.contentMinSize = NSSize(width: 640, height: 500)
            win.delegate = self
            win.isReleasedWhenClosed = false
            win.center() // only on first creation — later shows keep the user's position
            self.window = win
            self.model = model
        }
        model?.selectedTab = tab
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
        NSApp.setActivationPolicy(.accessory) // back to background agent
    }
}

// MARK: - Model

final class SettingsModel: ObservableObject {
    @Published var selectedTab: SettingsTab
    @Published var autoRestore: Bool { didSet { AppState.shared.autoRestore = autoRestore } }
    @Published var freeMarking: Bool { didSet { AppState.shared.freeMarking = freeMarking } }
    @Published var modernOrthography: Bool { didSet { AppState.shared.modernOrthography = modernOrthography } }
    @Published var liveSpellCheck: Bool { didSet { AppState.shared.liveSpellCheck = liveSpellCheck } }
    @Published var simpleTelex: Bool { didSet { AppState.shared.simpleTelex = simpleTelex } }
    /// Advanced (terminal tap latency) — see AppState for the full semantics.
    @Published var tapModifyEventInPlace: Bool { didSet { AppState.shared.tapModifyEventInPlace = tapModifyEventInPlace } }
    @Published var tapSkipSyntheticKeyUp: Bool { didSet { AppState.shared.tapSkipSyntheticKeyUp = tapSkipSyntheticKeyUp } }
    @Published var axSelectionReplace: Bool { didSet { AppState.shared.axSelectionReplace = axSelectionReplace } }
    @Published var tapCascadeBreaker: Bool { didSet { AppState.shared.tapCascadeBreaker = tapCascadeBreaker } }
    @Published var debugLogging: Bool { didSet { AppState.shared.debugLogging = debugLogging } }
    /// Shows/hides the Bảng chế độ gõ + Thử Nghiệm tabs. When turned off while one
    /// of them is frontmost, selection falls back to Tùy chỉnh.
    @Published var advancedFeatures: Bool {
        didSet {
            AppState.shared.advancedFeatures = advancedFeatures
            if !advancedFeatures,
               selectedTab == .modeTable || selectedTab == .experimental {
                selectedTab = .general
            }
        }
    }
    /// UI language: "system" / "en" / "vi". Changing it re-renders every view that
    /// observes this model (they call `loc(_:)`), so the switch is live — no relaunch.
    @Published var uiLanguage: String { didSet { AppState.shared.uiLanguage = uiLanguage } }
    @Published var shortcuts: [ShortcutRow] = []
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

    init(selected: SettingsTab) {
        selectedTab = selected
        autoRestore = AppState.shared.autoRestore
        freeMarking = AppState.shared.freeMarking
        modernOrthography = AppState.shared.modernOrthography
        liveSpellCheck = AppState.shared.liveSpellCheck
        simpleTelex = AppState.shared.simpleTelex
        tapModifyEventInPlace = AppState.shared.tapModifyEventInPlace
        tapSkipSyntheticKeyUp = AppState.shared.tapSkipSyntheticKeyUp
        axSelectionReplace = AppState.shared.axSelectionReplace
        tapCascadeBreaker = AppState.shared.tapCascadeBreaker
        debugLogging = AppState.shared.debugLogging
        advancedFeatures = AppState.shared.advancedFeatures
        uiLanguage = AppState.shared.uiLanguage
        reloadShortcuts()
        reloadModeTable()
    }

    /// Localized string for the user's chosen UI language (see `VTLocalized`).
    func loc(_ key: String) -> String { VTLocalized(key) }

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

    func reloadModeTable() {
        manualModes = AppState.shared.manualModes
        // User data (manual pins, probe results, hand-added) is always listed —
        // even for apps since uninstalled, so a stale pin stays visible/removable.
        var ids = Set(manualModes.keys)
        ids.formUnion(AppState.shared.learnedFallbackApps)
        ids.formUnion(AppState.shared.learnedInPlaceApps)
        ids.formUnion(addedApps)
        // Every HARDCODED rule set is filtered to apps actually installed — the
        // table shows this system's real defaults, not our whole knowledge base.
        let installed: (String) -> Bool = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        ids.formUnion(AppState.builtInFallbackApps.filter(installed))
        ids.formUnion(AppState.builtInInPlaceApps.filter(installed))
        ids.formUnion(AppState.builtInSpecialApps.filter(installed))
        ids.formUnion(ClientPolicy.forcePassthroughBundleIDs.filter(installed))
        ids.insert(Self.spotlightRowID)   // always listed; dedupes with learned entry
        modeRows = ids.map { makeRow(id: $0, name: Self.appName(for: $0)) }
        // Up to 10 recently-focused apps not yet in the table — quick add candidates.
        recentApps = FrontmostApp.shared.recent
            .filter { !ids.contains($0.id) }
            .prefix(10).map { $0 }
    }

    /// Display name for a bundle id (the installed app's name; the raw id when the
    /// app isn't found — e.g. learned on another machine or since uninstalled).
    static func appName(for id: String) -> String {
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
        case .inPlace: base = loc("In-place")
        case .marked: base = loc("Marked text")
        case .tap: base = loc("Tap (backspace)"); needsAX = true
        case .selection: base = loc("Selection-replace"); needsAX = true
        case .emptyReset: base = loc("Empty-reset"); needsAX = true
        case .axDetect: base = loc("Per-field (AX)"); needsAX = true
        case .passthrough: base = loc("Passthrough")
        case .auto, nil:
            // Not classified: with the permission Auto will probe on first typing;
            // without it the blunt policy runs marked text (no probing).
            return Accessibility.isTrusted ? loc("not detected yet") : loc("Marked text")
        }
        // Without the permission, show the mode ACTUALLY in effect right now (what
        // the routing degrades to) — "Marked text", not the aspirational
        // "Tap (backspace)". The ⚠️ badge (autoMissingPermission) carries the reason.
        // Untrusted policy is blunt by decision: everything not positively known
        // in-place-good runs marked text (Spotlight alone is raw passthrough).
        if needsAX && !Accessibility.isTrusted {
            return mode == .selection ? loc("Passthrough") : loc("Marked text")
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
        case .inPlace: return loc("In-place")
        case .marked: return loc("Marked text")
        case .tap: return loc("Tap (backspace)")
        case .selection: return loc("Selection-replace")
        case .emptyReset: return loc("Empty-reset")
        case .axDetect: return loc("Per-field (AX)")
        case .passthrough: return loc("Passthrough")
        case .auto, nil: return loc("Auto")
        }
    }

    private func makeRow(id: String, name: String) -> AppModeRow {
        AppModeRow(id: id, name: name,
                   detected: autoLabel(id), manual: manualLabel(id),
                   missingPermission: autoMissingPermission(id))
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

    /// Add a row by hand (recent-apps picker or typed bundle id), mode = Auto.
    func addApp() {
        let id = newModeAppID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        addedApps.insert(id)
        newModeAppID = ""
        reloadModeTable()
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
    }

    func addShortcut(key: String, value: String) {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        AppState.shared.upsertShortcut(key: k, value: value)
        reloadShortcuts()
    }

    func removeShortcut(_ key: String) {
        AppState.shared.removeShortcut(key: key)
        reloadShortcuts()
    }
}

// id = key: selection survives reloads, and a row can be looked up by its key.
struct ShortcutRow: Identifiable { var id: String { key }; let key: String; let value: String }

/// One row of the mode table. `id` = bundle id (stable across reloads). The label
/// columns are precomputed at reload so the Table can sort by them (KeyPathComparator
/// needs stored Comparable properties) and the filter can match them.
struct AppModeRow: Identifiable {
    let id: String
    let name: String
    let detected: String          // localized Detected-column label
    let manual: String            // localized Manual-column label (current pick)
    let missingPermission: Bool   // show the ⚠️ badge
}

// MARK: - Root view

struct SettingsView: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            GeneralTab().tabItem { Text(model.loc("Settings")) }.tag(SettingsTab.general)
            ShortcutsTab().tabItem { Text(model.loc("Shortcuts")) }.tag(SettingsTab.shortcuts)
            if model.advancedFeatures {
                ModeTableTab().tabItem { Text(model.loc("Typing modes")) }.tag(SettingsTab.modeTable)
                ExperimentalTab().tabItem { Text(model.loc("Experimental")) }.tag(SettingsTab.experimental)
            }
            AboutTab().tabItem { Text(model.loc("About")) }.tag(SettingsTab.about)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 500)
    }
}

// MARK: - Tab: Tùy chỉnh

struct GeneralTab: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Form {
            Section(model.loc("Input style")) {
                Toggle(model.loc("Simple Telex"), isOn: $model.simpleTelex)
                Text(model.loc("A lone “w” stays “w” (type “uw” for ư). Off = full Telex (cw→cư)."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(model.loc("Free tone placement"), isOn: $model.freeMarking)
                Text(model.loc("Off = strict Telex: tones apply only next to a vowel — good for English/code (data→data). On: free placement (ama→âm)."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(model.loc("Modern tone placement (oà, uý)"), isOn: $model.modernOrthography)
                Text(model.loc("Off = old style (hòa, thủy, khỏe). On = new style (hoà, thuý, khoẻ). Only oa/oe/uy differ."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(model.loc("Spelling")) {
                Toggle(model.loc("Auto-restore invalid words"), isOn: $model.autoRestore)
                Toggle(model.loc("Live spell-check"), isOn: $model.liveSpellCheck)
                Text(model.loc("Stop adding tones as soon as a word can’t be Vietnamese (google, github…) instead of waiting for word end."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(model.loc("Language")) {
                Picker(model.loc("Language"), selection: $model.uiLanguage) {
                    Text(model.loc("System")).tag("system")
                    Text("Tiếng Việt").tag("vi")
                    Text("English").tag("en")
                }
            }
            Section {
                Toggle(model.loc("Show advanced features"), isOn: $model.advancedFeatures)
                Text(model.loc("Adds the Typing modes and Experimental tabs — per-app overrides, latency flags, debug log. Not needed for everyday typing."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab: Bảng chế độ gõ

/// One table of every app VietTelex knows: learned by the probe, pinned by the
/// user, or built-in. Column 2 is a dropdown — "Auto — <detected>" plus the 5
/// manual strategies. Replaces the old "App compatibility" (Tùy chỉnh) and
/// "App mode" (Thử Nghiệm) sections.
struct ModeTableTab: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.loc("Filter by app name, bundle id, or mode"), text: $model.modeFilter)
                    .textFieldStyle(.roundedBorder)
                if !model.modeFilter.isEmpty {
                    Button {
                        model.modeFilter = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
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
                            Text("⚠️")
                                .help(model.loc("Missing Accessibility permission"))
                        }
                    }
                }.width(min: 120)
                TableColumn(model.loc("Manual"), value: \.manual) { row in
                    // Common picks first (Auto / Tap / Marked cover ~95% of real
                    // overrides); the specialist modes sit below the divider —
                    // Empty-reset exists for exactly one app (Excel), and picking it
                    // elsewhere types stray U+202F.
                    Picker("", selection: Binding(get: { model.appMode(row.id) },
                                                  set: { model.setAppMode(row.id, $0) })) {
                        Text(model.loc("Auto")).tag("auto")
                        Text(model.loc("Tap (backspace)")).tag("tap")
                        Text(model.loc("Marked text")).tag("marked")
                        Divider()
                        Text(model.loc("Per-field (AX)")).tag("axDetect")
                        Text(model.loc("In-place")).tag("inPlace")
                        Text(model.loc("Selection-replace")).tag("selection")
                        Text(model.loc("Empty-reset")).tag("emptyReset")
                        Text(model.loc("Passthrough")).tag("passthrough")
                    }
                    .labelsHidden()
                }.width(min: 150)
            }
            .frame(minHeight: 230, maxHeight: .infinity)

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
                Button(model.loc("Add")) { model.addApp() }
                    .disabled(model.newModeAppID.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                // role .destructive alone doesn't tint a bordered macOS button —
                // color the label explicitly so the destructive action reads as one.
                Button(role: .destructive) { model.clearLearned() } label: {
                    Text(model.loc("Clear & re-learn")).foregroundStyle(.red)
                }
                Spacer()
                Button(model.loc("Import from plist…")) { importModes() }
                Button(model.loc("Export to plist…")) { exportModes() }
            }
            Text(model.loc("An app types wrong or shows underlines? Pick Tap — real keystrokes, no underline (needs Accessibility). Marked text always renders correctly but underlines while typing. The modes below the divider are for special cases — leave them unless you know the app needs one. Clear forgets everything learned; manual picks are kept."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { model.reloadModeTable() }
        // The user's flow is: keep Settings open → type a tone word in the target
        // app → come back. Refresh when the Settings window regains key so the
        // just-learned row appears without reopening the tab (event-driven, no timer).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.reloadModeTable()
        }
    }

    /// Import manual pins (bundleID → mode) from a String → String plist — the same
    /// container format the Shortcuts tab uses, so the flow is familiar. Merge, not
    /// replace: imported entries win, everything else is kept.
    private func importModes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = VTLocalized("Couldn’t read the file")
            alert.informativeText = VTLocalized("The file must be a String → String dictionary plist (like the one Export to plist… creates).")
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "VietTelexAppModes.plist"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? PropertyListSerialization.data(
                fromPropertyList: AppState.shared.manualModes, format: .xml, options: 0)
        else { return }
        try? data.write(to: url)
    }
}

// MARK: - Tab: Thử Nghiệm

struct ExperimentalTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var saveResult: String?

    var body: some View {
        Form {
            Section(model.loc("Terminal typing latency")) {
                Toggle(model.loc("Modify key events in place"), isOn: $model.tapModifyEventInPlace)
                Text(model.loc("In terminals, apply a one-letter tone edit (w→ư) by rewriting the real keystroke instead of posting two synthetic events — lower latency."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(model.loc("Skip synthetic key-up"), isOn: $model.tapSkipSyntheticKeyUp)
                Text(model.loc("Post only the key-down for inserted letters in terminals, halving events per keystroke."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(model.loc("AX replace (Chrome/Spotlight)"), isOn: $model.axSelectionReplace)
                Text(model.loc("Apply tone edits in Chrome and Spotlight with one Accessibility edit instead of a burst of Shift+Left key events."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(model.loc("Safety")) {
                Toggle(model.loc("Cascade circuit breaker"), isOn: $model.tapCascadeBreaker)
                Text(model.loc("Keep this ON. Stops the terminal tap if it ever floods the keyboard with synthetic events, so a bug can’t freeze typing."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(model.loc("Diagnostics")) {
                Toggle(model.loc("Record debug log"), isOn: $model.debugLogging)
                Text(model.loc("Records tap health events in memory (never the text you type). Turn it on, reproduce the problem, then Save debug log and send us the file."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.loc("Save debug log…")) { saveLog() }
                    Button(model.loc("Clear")) { DebugLog.clear(); saveResult = nil }
                }
                if let saveResult {
                    Text(saveResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func saveLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "VietTelex-debug.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = DebugLog.snapshot(header: debugHeader())
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            saveResult = String(format: model.loc("Saved to %@"), url.lastPathComponent)
        } catch {
            saveResult = model.loc("Couldn’t save the file.")
        }
    }

    /// Current runtime state prepended to the log for context (no typed text).
    private func debugHeader() -> [String] {
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
        let mode: String
        if s.usesSelectionReplace(id) { mode = "tap · selection-replace" }
        else if s.usesTapMode(id) { mode = "tap · backspace" }
        else if s.usesMarkedText(id) { mode = "IMKit · marked text" }
        else { mode = "IMKit · in-place" }
        let inPlace = s.learnedInPlaceApps
        let fallback = s.learnedFallbackApps
        let manual = s.manualModes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return [
            "VietTelex debug log — v\(version) (build \(build))",
            "accessibility: \(Accessibility.isTrusted ? "granted" : "MISSING")",
            "tap running: \(TerminalTapController.shared.isRunning)",
            "current app: \(id ?? "?")  frontmost: \(frontID ?? "?")",
            "handling: \(mode)",
            "  usesTapMode(id)=\(s.usesTapMode(id)) usesTapMode(front)=\(s.usesTapMode(frontID))",
            "  usesMarkedText=\(s.usesMarkedText(id)) selectionReplace=\(s.usesSelectionReplace(id)) emptyReset=\(s.usesEmptyReset(id))",
            "  needsProbe=\(s.needsProbe(id)) spotlightVisible=\(SpotlightDetector.isVisible)",
            "learned in-place OK: \(inPlace.isEmpty ? "(none)" : inPlace.joined(separator: ", "))",
            "learned fallback (tap/marked): \(fallback.isEmpty ? "(none)" : fallback.joined(separator: ", "))",
            "manual overrides: \(manual.isEmpty ? "(none)" : manual.joined(separator: ", "))",
            "flags: modifyInPlace=\(s.tapModifyEventInPlace) skipKeyUp=\(s.tapSkipSyntheticKeyUp) axReplace=\(s.axSelectionReplace) breaker=\(s.tapCascadeBreaker)",
            "settings: simpleTelex=\(s.simpleTelex) freeMarking=\(s.freeMarking) modern=\(s.modernOrthography) liveSpell=\(s.liveSpellCheck) autoRestore=\(s.autoRestore)",
        ]
    }
}

// MARK: - Tab: Giới thiệu

struct AboutTab: View {
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

    @State private var checking = false
    @State private var status: String?     // result line under the button
    @State private var updateURL: URL?     // set only when a newer release exists

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
            Text("VietTelex").font(.title2).bold()
            Text(String(format: model.loc("Version %@ · %@"), appVersion, buildDate))
                .foregroundStyle(.secondary)
            Link("Website", destination: URL(string: "https://ptrinh.github.io/viettelex/")!)

            // Manual update check — the only thing that touches the network, and
            // only on this click (see Updater.swift).
            VStack(spacing: 4) {
                if checking {
                    ProgressView().controlSize(.small)
                } else if let updateURL {
                    Button(model.loc("Download update…")) { NSWorkspace.shared.open(updateURL) }
                } else {
                    Button(model.loc("Check for updates")) { runCheck() }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 44)

            Text("© Phil Trinh \(String(currentYear))").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runCheck() {
        checking = true; status = nil; updateURL = nil
        Task {
            let outcome = await UpdateCheck.check()
            await MainActor.run {
                checking = false
                switch outcome {
                case .upToDate(let v):
                    status = String(format: model.loc("You’re up to date (%@)."), v)
                case .update(let latest, let url):
                    status = String(format: model.loc("Update available: %@"), latest); updateURL = url
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
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var selection: ShortcutRow.ID?

    /// True when the fields hold an existing shortcut (save = update, not add).
    private var isEditing: Bool {
        AppState.shared.shortcuts[newKey.trimmingCharacters(in: .whitespaces)] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(model.shortcuts, selection: $selection) {
                TableColumn(model.loc("Type"), value: \.key)
                TableColumn(model.loc("Becomes"), value: \.value)
                TableColumn("") { row in
                    Button(role: .destructive) { model.removeShortcut(row.key) } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless)
                }.width(40)
            }
            .frame(minHeight: 220)
            .onChange(of: selection) { selected in
                // Click a row -> load it into the fields for editing in place.
                guard let key = selected,
                      let value = AppState.shared.shortcuts[key] else { return }
                newKey = key
                newValue = value
            }

            HStack {
                TextField(model.loc("type"), text: $newKey).frame(width: 120)
                TextField(model.loc("becomes"), text: $newValue)
                Button(model.loc(isEditing ? "Update" : "Add")) { save() }
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(model.loc("Click a row to edit."))
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button(model.loc("Import from plist…")) { importPlist() }
                Button(model.loc("Export to plist…")) { exportPlist() }
                Spacer()
            }
        }
    }

    private func save() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        // Overwriting a DIFFERENT entry than the one being edited needs a confirm —
        // otherwise a typo in the key field silently clobbers an existing shortcut.
        if AppState.shared.shortcuts[key] != nil, selection != key {
            let alert = NSAlert()
            alert.messageText = String(format: VTLocalized("Shortcut “%@” already exists"), key)
            alert.informativeText = VTLocalized("Overwrite the existing value?")
            alert.addButton(withTitle: VTLocalized("Overwrite"))
            alert.addButton(withTitle: VTLocalized("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.addShortcut(key: key, value: newValue)
        newKey = ""; newValue = ""; selection = nil
    }

    private func importPlist() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = VTLocalized("Couldn’t read the file")
            alert.informativeText = VTLocalized("The file must be a String → String dictionary plist (like the one Export to plist… creates).")
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "TelexShortcuts.plist"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? PropertyListSerialization.data(
                fromPropertyList: AppState.shared.shortcuts, format: .xml, options: 0)
        else { return }
        try? data.write(to: url)
    }
}
