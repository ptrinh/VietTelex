// ICloudSync.swift
// Đồng bộ cài đặt gõ + gõ tắt Mac ↔ iPhone/iPad qua iCloud Key-Value Store, CÙNG store,
// key ("vt.sync.settings" / "vt.sync.shortcuts") và định dạng LWW với app iOS — lõi hợp
// nhất dùng chung iOS/App/Backup/SyncCore.swift (biên dịch theo đường dẫn, project.yml).
// Mặc định TẮT. Không đồng bộ mẫu câu (macOS không có — nhóm đó không được đọc/ghi, nên
// không đè/xoá gì trên iCloud) và từ đã học.
//
// Cần entitlement com.apple.developer.ubiquity-kvstore-identifier = 84T567KMYD.com.viettelex.ios
// (store của app iOS) + provisioning profile Developer ID nhúng trong bundle
// (VietTelex-iCloud.entitlements, Scripts/notarize-install.sh). Bản ký thiếu entitlement:
// công tắc bị khoá trong Cài đặt và mọi hàm ở đây là no-op — không chạm KVS.
//
// Chi phí: tắt = 0 (không observer, không đụng NSUbiquitousKeyValueStore). Bật = một lượt
// gộp lúc khởi động, lúc đóng Cài đặt và khi iCloud báo máy khác vừa đổi — không bao giờ
// theo phím gõ.

import Foundation
import Security

/// SyncLocal của macOS: map tên setting CHUẨN (BackupSettings iOS/Android) ⇄ AppState.
final class MacSyncStore: SyncLocal {
    struct Setting { let canonical: String; let local: String }
    /// Chỉ setting cùng nghĩa trên cả hai nền tảng. Không có: vniMode/bracketVowels (chỉ
    /// macOS), các setting bàn phím cảm ứng.
    static let settings: [Setting] = [
        Setting(canonical: "simpleTelex", local: "simpleTelex"),
        Setting(canonical: "freeMarking", local: "freeMarking"),
        Setting(canonical: "quickTelex", local: "quickTelex"),
        Setting(canonical: "modernTone", local: "modernOrthography"),
        Setting(canonical: "contextualEnglish", local: "contextualEnglish"),
        Setting(canonical: "retroactiveEnglish", local: "retroactiveEnglish"),   // "Tự sửa từ phía trước"
        Setting(canonical: "englishByFrequency", local: "englishByFrequency"),   // "Đoán từ trùng theo tần suất"
        Setting(canonical: "teencode", local: "teencode"),
        Setting(canonical: "autoCircumflex", local: "autoCircumflex"),         // "Tự thêm dấu mũ"
        Setting(canonical: "autoRestore", local: "autoRestore"),
        Setting(canonical: "liveSpellCheck", local: "liveSpellCheck"),
        Setting(canonical: "reEditWords", local: "reEditWord"),            // "Sửa dấu từ đã gõ"
        Setting(canonical: "filterSensitive", local: "filterSensitive"),   // "Lọc từ nhạy cảm"
    ]
    static let managed = Set(settings.map(\.canonical))
    /// Setting dạng chuỗi, giá trị hợp lệ = `allowed` (cùng spec BackupSettings iOS — giá trị
    /// lạ từ iCloud bị bỏ qua). Hiện có: ngôn ngữ đích của Dịch.
    struct TextSetting { let canonical: String; let allowed: [String] }
    static let textSettings: [TextSetting] = [
        TextSetting(canonical: TranslatePrefs.targetKey, allowed: TranslatePrefs.knownTargets),
    ]
    static func ledgerKey(_ s: SyncSection) -> String { "syncLedger.\(s.rawValue)" }

    let ledgerDefaults: UserDefaults
    let getSetting: (String) -> Bool
    let setSetting: (String, Bool) -> Void
    let getShortcuts: () -> [String: String]
    let setShortcuts: ([String: String]) -> Void
    /// nil = không quản lý key đó (giá trị trong sổ giữ nguyên, như setting chỉ iPhone có).
    let getText: (String) -> String?
    let setText: (String, String) -> Void

    init(ledgerDefaults: UserDefaults,
         getSetting: @escaping (String) -> Bool, setSetting: @escaping (String, Bool) -> Void,
         getShortcuts: @escaping () -> [String: String], setShortcuts: @escaping ([String: String]) -> Void,
         getText: @escaping (String) -> String? = { _ in nil }, setText: @escaping (String, String) -> Void = { _, _ in }) {
        self.ledgerDefaults = ledgerDefaults
        self.getSetting = getSetting
        self.setSetting = setSetting
        self.getShortcuts = getShortcuts
        self.setShortcuts = setShortcuts
        self.getText = getText
        self.setText = setText
    }

    func current(_ s: SyncSection) -> [String: String] {
        switch s {
        case .settings:
            // Setting chỉ iPhone có (showSuggestions…) giữ nguyên giá trị trong sổ: Mac
            // không có chúng nhưng cũng không được coi là "đã xoá" (tombstone) — không thì
            // hai bên đóng dấu qua lại mãi.
            var out = SyncMerge.live(ledger(.settings) ?? [:]).filter { !Self.managed.contains($0.key) }
            for m in Self.settings { out[m.canonical] = getSetting(m.local) ? "true" : "false" }
            for t in Self.textSettings { if let v = getText(t.canonical) { out[t.canonical] = v } }
            return out
        case .shortcuts: return getShortcuts()
        case .templates: return [:]
        }
    }

    func apply(_ s: SyncSection, _ values: [String: String]) {
        switch s {
        case .settings:
            for m in Self.settings {
                guard let v = values[m.canonical], v == "true" || v == "false" else { continue }
                let b = v == "true"
                if getSetting(m.local) != b { setSetting(m.local, b) }
            }
            for t in Self.textSettings {
                guard let v = values[t.canonical], t.allowed.contains(v),
                      let cur = getText(t.canonical), cur != v else { continue }
                setText(t.canonical, v)
            }
        case .shortcuts: if values != getShortcuts() { setShortcuts(values) }
        case .templates: break
        }
    }

    func isUntouched(_ s: SyncSection) -> Bool { false }
    func ledger(_ s: SyncSection) -> SyncDomain? { SyncMerge.decode(ledgerDefaults.data(forKey: Self.ledgerKey(s))) }
    func setLedger(_ s: SyncSection, _ d: SyncDomain) { ledgerDefaults.set(SyncMerge.encode(d), forKey: Self.ledgerKey(s)) }

    /// Store thật: đọc/ghi qua AppState (cache hot path cập nhật ngay).
    static func live(_ a: AppState = .shared) -> MacSyncStore {
        MacSyncStore(ledgerDefaults: a.defaults,
                     getSetting: { a.syncedSetting($0) ?? false },
                     setSetting: { a.setSyncedSetting($0, $1) },
                     getShortcuts: { a.shortcuts },
                     setShortcuts: { a.setShortcuts($0) },
                     getText: { $0 == TranslatePrefs.targetKey ? a.translateTarget : nil },
                     setText: { if $0 == TranslatePrefs.targetKey { a.translateTarget = $1 } })
    }
}

final class KVSCloud: SyncCloud {
    let kvs: NSUbiquitousKeyValueStore
    init(_ kvs: NSUbiquitousKeyValueStore = .default) { self.kvs = kvs }
    func data(forKey key: String) -> Data? { kvs.data(forKey: key) }
    func set(_ data: Data, forKey key: String) { kvs.set(data, forKey: key) }
}

final class ICloudSync {
    static let shared = ICloudSync()
    static let enabledKey = "icloudSyncEnabled"
    static let lastSyncKey = "icloudLastSync"
    static let sections: [SyncSection] = [.settings, .shortcuts]
    static let entitlement = "com.apple.developer.ubiquity-kvstore-identifier"

    /// Bản đang chạy có được ký kèm entitlement KVS không (đọc một lần từ chữ ký).
    static let hasEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) != nil
    }()

    private var observer: NSObjectProtocol?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppState.shared.defaults) { self.defaults = defaults }

    var isEnabled: Bool { Self.hasEntitlement && defaults.bool(forKey: Self.enabledKey) }
    /// false = máy chưa đăng nhập iCloud (KVS khi đó chỉ lưu cục bộ, không lỗi).
    var iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }
    var lastSync: Date? {
        let t = defaults.double(forKey: Self.lastSyncKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    /// Khởi động app / bật công tắc. Tắt hoặc thiếu entitlement ⇒ không làm gì.
    func start() {
        guard isEnabled else { return }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] _ in
                self?.syncNow()
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        syncNow()
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
    }

    /// MAIN thread (AppState setter + Settings đọc cùng thread).
    func syncNow() {
        guard isEnabled else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let r = SyncEngine.run(local: MacSyncStore.live(), cloud: KVSCloud(), now: now, sections: Self.sections)
        if !r.pushed.isEmpty { NSUbiquitousKeyValueStore.default.synchronize() }
        if !r.pulled.isEmpty { DebugLog.log("icloud-sync: pulled \(r.pulled.map(\.rawValue))") }
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastSyncKey)
    }
}
