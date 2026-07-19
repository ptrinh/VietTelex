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

enum SettingsTab: Hashable { case general, shortcuts, about }

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
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.setContentSize(NSSize(width: 580, height: 440))
            win.delegate = self
            win.isReleasedWhenClosed = false
            self.window = win
            self.model = model
        }
        model?.selectedTab = tab
        window?.center()
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
    /// UI language: "system" / "en" / "vi". Changing it re-renders every view that
    /// observes this model (they call `loc(_:)`), so the switch is live — no relaunch.
    @Published var uiLanguage: String { didSet { AppState.shared.uiLanguage = uiLanguage } }
    @Published var shortcuts: [ShortcutRow] = []
    @Published var fallbackApps: [String] = []
    @Published var inPlaceApps: [String] = []

    init(selected: SettingsTab) {
        selectedTab = selected
        autoRestore = AppState.shared.autoRestore
        freeMarking = AppState.shared.freeMarking
        modernOrthography = AppState.shared.modernOrthography
        liveSpellCheck = AppState.shared.liveSpellCheck
        simpleTelex = AppState.shared.simpleTelex
        uiLanguage = AppState.shared.uiLanguage
        reloadShortcuts()
        reloadLearnedApps()
    }

    /// Localized string for the user's chosen UI language (see `VTLocalized`).
    func loc(_ key: String) -> String { VTLocalized(key) }

    func reloadLearnedApps() {
        fallbackApps = AppState.shared.learnedFallbackApps
        inPlaceApps = AppState.shared.learnedInPlaceApps
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

// MARK: - Root view

struct SettingsView: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            GeneralTab().tabItem { Text(model.loc("Settings")) }.tag(SettingsTab.general)
            ShortcutsTab().tabItem { Text(model.loc("Shortcuts")) }.tag(SettingsTab.shortcuts)
            AboutTab().tabItem { Text(model.loc("About")) }.tag(SettingsTab.about)
        }
        .padding(16)
        .frame(width: 580, height: 440)
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
            Section(model.loc("App compatibility")) {
                if model.fallbackApps.isEmpty && model.inPlaceApps.isEmpty {
                    Text(model.loc("No apps learned yet."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if !model.fallbackApps.isEmpty {
                        Text(String(format: model.loc("Marked text: %@"), model.fallbackApps.joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !model.inPlaceApps.isEmpty {
                        Text(String(format: model.loc("In-place OK: %@"), model.inPlaceApps.joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Button(model.loc("Reset (re-probe)")) {
                    AppState.shared.resetLearnedApps()
                    model.reloadLearnedApps()
                }
                Text(model.loc("VietTelex learns the right method per app. If an app shows underlines or types wrong, tap Reset to re-probe."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(model.loc("Language")) {
                Picker(model.loc("Language"), selection: $model.uiLanguage) {
                    Text(model.loc("System")).tag("system")
                    Text("Tiếng Việt").tag("vi")
                    Text("English").tag("en")
                }
            }
        }
        .formStyle(.grouped)
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
            Link("Website", destination: URL(string: "https://ptrinh.github.io/VietTelex/")!)

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
