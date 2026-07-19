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
    @Published var englishToneDetection: Bool { didSet { AppState.shared.englishToneDetection = englishToneDetection } }
    @Published var shortcuts: [ShortcutRow] = []
    @Published var whitelist: [String] = []
    @Published var fallbackApps: [String] = []
    @Published var inPlaceApps: [String] = []

    init(selected: SettingsTab) {
        selectedTab = selected
        autoRestore = AppState.shared.autoRestore
        freeMarking = AppState.shared.freeMarking
        modernOrthography = AppState.shared.modernOrthography
        liveSpellCheck = AppState.shared.liveSpellCheck
        simpleTelex = AppState.shared.simpleTelex
        englishToneDetection = AppState.shared.englishToneDetection
        reloadShortcuts()
        reloadWhitelist()
        reloadLearnedApps()
    }

    func reloadWhitelist() {
        whitelist = AppState.shared.restoreWhitelistWords
    }

    func addWhitelistWord(_ word: String) {
        AppState.shared.addWhitelistWord(word)
        reloadWhitelist()
    }

    func removeWhitelistWord(_ word: String) {
        AppState.shared.removeWhitelistWord(word)
        reloadWhitelist()
    }

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
    @State private var newWhitelistWord = ""

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section("Kiểu gõ") {
                Toggle("Simple Telex", isOn: $model.simpleTelex)
                Text("Chữ w đứng một mình luôn là 'w' (gõ 'uw' để ra ư). Tắt = Telex đầy đủ (cw→cư).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Bỏ dấu tự do", isOn: $model.freeMarking)
                Text("Tắt = Telex nghiêm ngặt: dấu chỉ nhận khi gõ sát nguyên âm, hợp cho English/code (data→data). Bật: dấu đặt tự do (ama→âm).")
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
                Toggle("Phát hiện từ tiếng Anh", isOn: $model.englishToneDetection)
                Text("Từ tiếng Anh trùng âm Việt (test→tét, list→lít) được giữ nguyên: dấu thanh gõ giữa từ rồi gõ tiếp là dấu hiệu tiếng Anh. Tự tắt nếu bạn quen bỏ dấu sớm (tieesng).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Từ ngoại lệ (không tự khôi phục)") {
                ForEach(model.whitelist, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(role: .destructive) { model.removeWhitelistWord(word) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("wifi, tên riêng…", text: $newWhitelistWord)
                        .onSubmit { addWhitelistWord() }
                    Button("Thêm") { addWhitelistWord() }
                        .disabled(newWhitelistWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Các từ trong danh sách không bao giờ bị tự khôi phục về phím gốc dù không phải âm tiết tiếng Việt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tương thích ứng dụng") {
                if model.fallbackApps.isEmpty && model.inPlaceApps.isEmpty {
                    Text("Chưa có ứng dụng nào được ghi nhớ.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if !model.fallbackApps.isEmpty {
                        Text("Dùng marked text: " + model.fallbackApps.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !model.inPlaceApps.isEmpty {
                        Text("Gõ trực tiếp OK: " + model.inPlaceApps.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Button("Đặt lại (dò lại từ đầu)") {
                    AppState.shared.resetLearnedApps()
                    model.reloadLearnedApps()
                }
                Text("VietTelex tự học cách gõ phù hợp cho từng ứng dụng. Nếu một ứng dụng gõ bị gạch chân hoặc sai, bấm Đặt lại để dò lại.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Giới thiệu") {
                Text("© Phil Trinh @ SenPrints")
                Text("Version \(appVersion)")
            }
        }
        .formStyle(.grouped)
    }

    private func addWhitelistWord() {
        let w = newWhitelistWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        model.addWhitelistWord(w)
        newWhitelistWord = ""
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
                TableColumn("Gõ", value: \.key)
                TableColumn("Thành", value: \.value)
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
                TextField("gõ", text: $newKey).frame(width: 120)
                TextField("thành", text: $newValue)
                Button(isEditing ? "Cập nhật" : "Thêm") { save() }
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Bấm một dòng để sửa.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Nhập từ plist…") { importPlist() }
                Button("Xuất ra plist…") { exportPlist() }
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
            alert.messageText = "Gõ tắt “\(key)” đã tồn tại"
            alert.informativeText = "Ghi đè giá trị hiện có?"
            alert.addButton(withTitle: "Ghi đè")
            alert.addButton(withTitle: "Huỷ")
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
            alert.messageText = "Không đọc được file"
            alert.informativeText = "File phải là plist dạng dictionary String → String (như file Xuất ra plist… tạo)."
            alert.runModal()
            return
        }
        // Merge (imported entries win) rather than replace, so importing a shared
        // list never silently wipes the user's existing shortcuts.
        let merged = AppState.shared.shortcuts.merging(dict) { _, imported in imported }
        AppState.shared.setShortcuts(merged)
        model.reloadShortcuts()
        let alert = NSAlert()
        alert.messageText = "Đã nhập \(dict.count) gõ tắt"
        alert.informativeText = "Gộp vào bảng hiện có (mục trùng lấy giá trị mới)."
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
