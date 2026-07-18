// SettingsWindow.swift
// SwiftUI settings (2 tabs). The window is created only when opened from the IMK
// menu and released when closed (windowWillClose drops the reference).
//
// There is no VI/EN enable/disable: Vietnamese is on whenever VietTelex is the active
// macOS input source. To type English, switch input source (macOS remembers it per
// app when "automatically switch to a document's input source" is on).

import AppKit
import SwiftUI
import TelexCore

enum SettingsTab: Hashable { case general, shortcuts }

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
            win.title = "VietTelex — Cài đặt"
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
    @Published var shortcuts: [ShortcutRow] = []

    init(selected: SettingsTab) {
        selectedTab = selected
        autoRestore = AppState.shared.autoRestore
        freeMarking = AppState.shared.freeMarking
        modernOrthography = AppState.shared.modernOrthography
        liveSpellCheck = AppState.shared.liveSpellCheck
        simpleTelex = AppState.shared.simpleTelex
        reloadShortcuts()
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

struct ShortcutRow: Identifiable { let id = UUID(); let key: String; let value: String }

// MARK: - Root view

struct SettingsView: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            GeneralTab().tabItem { Text("Chung") }.tag(SettingsTab.general)
            ShortcutsTab().tabItem { Text("Gõ tắt") }.tag(SettingsTab.shortcuts)
        }
        .padding(16)
        .frame(width: 580, height: 440)
    }
}

// MARK: - Tab: Chung

struct GeneralTab: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Kiểu gõ") {
                Toggle("Simple Telex", isOn: $model.simpleTelex)
                Text("Chữ w đứng một mình luôn là 'w' (gõ 'uw' để ra ư). Tắt = Telex đầy đủ (cw→cư).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Bỏ dấu tự do", isOn: $model.freeMarking)
                Text("Tắt = Telex nghiêm ngặt: dấu chỉ nhận khi gõ sát nguyên âm, hợp cho English/code (data→data). Bật: dấu đặt tự do như OpenKey (ama→âm).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Bỏ dấu kiểu mới (oà, uý)", isOn: $model.modernOrthography)
                Text("Tắt = kiểu cũ (hòa, thủy, khỏe). Bật = kiểu mới (hoà, thuý, khoẻ). Chỉ đổi vị trí dấu ở oa/oe/uy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Chính tả") {
                Toggle("Tự khôi phục từ không hợp lệ", isOn: $model.autoRestore)
                Toggle("Kiểm tra chính tả khi gõ", isOn: $model.liveSpellCheck)
                Text("Ngừng bỏ dấu ngay khi từ không thể là tiếng Việt (google, github…) thay vì đợi hết từ.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Giới thiệu") {
                Text("© Phil Trinh @ SenPrints")
                Text("Version 1.0")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab: Gõ tắt

struct ShortcutsTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(model.shortcuts) {
                TableColumn("Gõ", value: \.key)
                TableColumn("Thành", value: \.value)
                TableColumn("") { row in
                    Button(role: .destructive) { model.removeShortcut(row.key) } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless)
                }.width(40)
            }
            .frame(minHeight: 220)

            HStack {
                TextField("gõ", text: $newKey).frame(width: 120)
                TextField("thành", text: $newValue)
                Button("Thêm") {
                    model.addShortcut(key: newKey, value: newValue)
                    newKey = ""; newValue = ""
                }.disabled(newKey.isEmpty)
            }

            HStack {
                Button("Nhập từ plist…") { importPlist() }
                Button("Xuất ra plist…") { exportPlist() }
                Spacer()
            }
        }
    }

    private func importPlist() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return }
        AppState.shared.setShortcuts(dict)
        model.reloadShortcuts()
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
