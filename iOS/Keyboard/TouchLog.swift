// TouchLog — log gỡ lỗi "gõ nhanh bị rớt chữ" (abcdefgh → abegh, 25/09/2026).
//
// TẮT mặc định; bật trong app VietTelex → Giới thiệu → Debug mode. Ghi thời điểm,
// độ trễ giao touch, số ngón đang đè, chạm trúng phím nào, lệnh xoá/chèn gửi sang
// app. KÝ TỰ (maintainer 25/09/2026: "record từng ký tự cho dễ debug") CHỈ vào file
// App Group mà user tự xem/xoá — os_log hệ thống KHÔNG nhận ký tự (sysdiagnose có
// thể rời máy).
// Hai đích: os_log "VTKB touch" (Console.app qua cáp) VÀ file touchlog.txt trong App
// Group — app đọc + nút Copy (cần "Cho phép Toàn quyền": không có Full Access thì
// extension không ghi được container chung, chỉ còn os_log).
import Foundation
import os.log
import QuartzCore
import UIKit

enum TouchLog {
    nonisolated(unsafe) static var enabled = false
    private static let log = OSLog(subsystem: "com.viettelex.ios.keyboard", category: "touch")
    nonisolated(unsafe) private static var seq = 0

    /// Ghi KÝ TỰ vào log? Chỉ bản build DEBUG (máy dev). Bản App Store: KHÔNG — Privacy
    /// Policy cam kết không lưu nội dung gõ, và reviewer soi kỹ bàn phím Full Access.
    #if DEBUG
    static let recordsCharacters = true
    #else
    static let recordsCharacters = false
    #endif

    static func loadSetting() {
        enabled = UserDefaultsProvider.shared?.bool(forKey: "debugTouchLog") ?? false
    }

    static let fileName = "touchlog.txt"
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppFlavor.appGroup)?
            .appendingPathComponent(fileName)
    }
    private static let queue = DispatchQueue(label: "com.viettelex.touchlog", qos: .utility)
    private static let stampFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    /// Trần file: quá `capBytes` ⇒ giữ ~`keepBytes` mới nhất (cắt ở đầu dòng) + chép lại header.
    static let capBytes = 256_000
    static let keepBytes = 128_000

    // Trạng thái CHỈ đụng trên `queue` (serial): header hiện hành + đã ghi chưa, bộ gộp dòng lặp.
    nonisolated(unsafe) private static var qHeader: [String] = []
    nonisolated(unsafe) private static var qHeaderWritten = false
    nonisolated(unsafe) private static var qCollapse = TouchLogFormat.Collapser()

    /// Append off-main. No-op khi Debug mode TẮT — mọi caller (kể cả log nút Dán mỗi lần
    /// refresh bar) đi qua cổng này. `@autoclosure`: chuỗi (nội suy, String(format:)…) CHỈ được
    /// dựng khi Debug mode bật — tắt (mặc định) thì caller trên đường phím không tốn cấp phát nào.
    /// Dòng lặp y hệt dòng trước (trừ giờ) gộp thành một dòng "×N".
    static func write(_ line: @autoclosure () -> String) {
        guard enabled, let url = fileURL else { return }
        let stamp = stampFormat.string(from: Date()), text = line()
        queue.async { append(url, stamp: stamp, text) }
    }

    /// Chạy trên `queue`. File mới (lần đầu / app vừa Xoá log) hoặc header đổi ⇒ ghi header trước.
    private static func append(_ url: URL, stamp: String, _ text: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
            qHeaderWritten = false
            qCollapse = TouchLogFormat.Collapser()
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size > UInt64(capBytes), let data = try? Data(contentsOf: url) {
            let kept = TouchLogFormat.trimmed(data, keep: keepBytes, header: qHeader)
            try? h.truncate(atOffset: 0)
            try? h.write(contentsOf: kept)
            qCollapse = TouchLogFormat.Collapser()
            qHeaderWritten = !qHeader.isEmpty   // trimmed() đã đặt header lên đầu
        }
        var out: [String] = []
        if !qHeaderWritten, !qHeader.isEmpty {
            out += qCollapse.flush() + qHeader
            qHeaderWritten = true
        }
        out += qCollapse.push(text).map { $0.hasPrefix(" ") ? $0 : stamp + " " + $0 }
        guard !out.isEmpty else { return }
        try? h.write(contentsOf: Data((out.joined(separator: "\n") + "\n").utf8))
    }

    /// `touchTimestamp` = UITouch.timestamp (same clock as CACurrentMediaTime).
    static func touchBegan(active: Int, batch: Int, touchTimestamp: TimeInterval, hit: Bool, y: Double,
                           key: String? = nil) {
        guard enabled else { return }
        seq += 1
        let lagMs = (CACurrentMediaTime() - touchTimestamp) * 1000
        let where_ = hit ? "hit" : String(format: "MISS y=%.0f", y)
        os_log("VTKB touch #%d BEGAN batch=%d active=%d lag=%.1fms %{public}@",
               log: log, type: .default, seq, batch, active, lagMs, where_)
        write(String(format: "#%d BEGAN batch=%d active=%d lag=%.1fms ", seq, batch, active, lagMs) + where_
              + (recordsCharacters ? (key.map { " [\($0)]" } ?? "") : ""))
    }

    /// Button keys (space, return, dấu câu…) don't go through the letter router —
    /// log their touch-down lag too: the bottom row sits on the system-gesture edge.
    static func buttonDown(_ name: String, touchTimestamp: TimeInterval?) {
        guard enabled else { return }
        let lag = touchTimestamp.map { String(format: "%.1fms", (CACurrentMediaTime() - $0) * 1000) } ?? "?"
        os_log("VTKB touch %{public}@ DOWN lag=%{public}@", log: log, type: .default, name, lag)
        write("\(name) DOWN lag=\(lag)")
    }

    /// Every touch-began hit-test verdict (deduped per touch timestamp), so a touch
    /// that never reaches the letter router shows WHERE it went (slot/control/nil).
    nonisolated(unsafe) private static var lastHitStamp: TimeInterval = -1
    static func hitTest(target: String, y: Double, stamp: TimeInterval) {
        guard enabled, stamp != lastHitStamp else { return }
        lastHitStamp = stamp
        let s = String(format: "HIT %@ y=%.0f", target, y)
        os_log("VTKB touch %{public}@", log: log, type: .default, s)
        write(s)
    }

    static func touchEnded(cancelled: Bool, routed: Bool) {
        guard enabled else { return }
        os_log("VTKB touch %{public}@ routed=%d", log: log, type: .default,
               cancelled ? "CANCELLED" : "ended", routed ? 1 : 0)
        write("\(cancelled ? "CANCELLED" : "ended") routed=\(routed ? 1 : 0)")
    }

    static func key(kind: String, composing: Bool, lagMs: Double, char: String? = nil) {
        guard enabled else { return }
        os_log("VTKB touch key=%{public}@ composing=%d handle=%.2fms", log: log, type: .default,
               kind, composing ? 1 : 0, lagMs)
        write(String(format: "key %@ comp=%d %.2fms", kind, composing ? 1 : 0, lagMs)
              + (recordsCharacters ? (char.map { " [\($0)]" } ?? "") : ""))
    }

    static func edit(bs: Int, insertLen: Int, insert: String? = nil) {
        guard enabled else { return }
        os_log("VTKB touch edit bs=%d ins=%d", log: log, type: .default, bs, insertLen)
        write("edit bs=\(bs) ins=\(insertLen)"
              + (recordsCharacters ? (insert.map { " [\($0)]" } ?? "") : ""))
    }

    static func host(_ event: String, applyingEdit: Bool, composing: Bool) {
        guard enabled else { return }
        os_log("VTKB touch host %{public}@ applyingEdit=%d composing=%d", log: log, type: .default,
               event, applyingEdit ? 1 : 0, composing ? 1 : 0)
        write("host \(event) edit=\(applyingEdit ? 1 : 0) comp=\(composing ? 1 : 0)")
    }

    /// Mỗi lần bàn phím hiện: header đầy đủ (TouchLogFormat.header) — ghi lại CHỈ khi khác
    /// header trước (hoặc file mới / vừa cắt bớt), rồi một dòng "=== appear" ngắn.
    static func session(header: @autoclosure () -> [String], fullAccess: Bool, traits: String = "") {
        guard enabled, let url = fileURL else { return }
        let lines = header(), stamp = stampFormat.string(from: Date())
        let appear = "=== appear fa=\(fullAccess ? 1 : 0)" + (traits.isEmpty ? "" : " " + traits)
        queue.async {
            if lines != qHeader { qHeader = lines; qHeaderWritten = false }
            append(url, stamp: stamp, appear)
        }
    }

    /// Trait ô đổi giữa phiên (host đổi ô không qua viewWillAppear).
    static func traits(_ desc: String) {
        guard enabled else { return }
        write("traits " + desc)
    }

    /// Sau mỗi edit / thay đổi từ host: CHỈ độ dài context trước con trỏ (-1 = nil)
    /// và cờ context kết thúc bằng từ đang gõ — KHÔNG BAO GIỜ nội dung chữ.
    static func sync(_ event: String, ctxLen: Int, suffix: Bool, composingLen: Int) {
        guard enabled else { return }
        os_log("VTKB touch sync %{public}@ ctxLen=%d suffix=%d comp=%d", log: log, type: .default,
               event, ctxLen, suffix ? 1 : 0, composingLen)
        write("sync \(event) ctx=\(ctxLen) sfx=\(suffix ? 1 : 0) comp=\(composingLen)")
    }
}

/// Phần thuần của log Debug mode (test: TouchLogFormatTests): header, gộp dòng lặp, cắt file.
/// PRIVACY: header chỉ có phiên bản / mã máy / cài đặt / SỐ LƯỢNG — không tên máy, không nội
/// dung gõ, không cặp gõ tắt (chỉ đếm).
enum TouchLogFormat {
    /// Bối cảnh máy + app (không thông tin cá nhân).
    struct Context: Equatable {
        var version = "?", build = "?"
        var os = "?"            // "iOS 26.1"
        var device = "?"        // mã máy "iPhone17,3" (không phải tên người dùng đặt cho máy)
        var idiom = "?"         // phone / pad
        var install = "?"       // appstore / testflight / dev
        var locale = "?"        // Locale.current.identifier
        var keyboards: [String] = []   // ngôn ngữ các bàn phím đang bật
        var fullAccess = false
        var uiLanguage = "?"
    }

    /// Giao diện / hiệu ứng (cho lỗi UI) — giá trị thô từ App Group.
    struct Appearance: Equatable {
        var theme = "system", effect = "none", buddy = "none", oneHand = "off"
        var wallpaper = false
    }

    static func header(_ c: Context, settings s: KeyboardSettings, appearance a: Appearance) -> [String] {
        func b(_ v: Bool) -> String { v ? "1" : "0" }
        let method = s.vniMode ? "vni" : (s.simpleTelex ? "telex-simple" : "telex")
        return [
            "=== VietTelex iOS \(c.version) (\(c.build)) keyboard debug log",
            "device: \(c.device) \(c.idiom) · \(c.os) · install \(c.install)",
            "locale: \(c.locale) · ui \(c.uiLanguage) · keyboards: "
                + (c.keyboards.isEmpty ? "?" : c.keyboards.joined(separator: ",")),
            "access: fullAccess=\(b(c.fullAccess))",
            "typing: method=\(method) free=\(b(s.freeMarking)) modern=\(b(s.modernTone)) quick=\(b(s.quickTelex))"
                + " spell=\(b(s.liveSpellCheck)) restore=\(b(s.autoRestore)) teen=\(b(s.teencode)) hat=\(b(s.autoCircumflex))"
                + " ctxEn=\(b(s.contextualEnglish)) retroEn=\(b(s.retroEnglishAuto)) freqEn=\(b(s.englishByFrequency))"
                + " reEdit=\(b(s.reEditWord)) adjFix=\(b(s.autoFixAdjacent)) autoCorrect=\(b(s.autoCorrect))"
                + " caps=\(b(s.autoCapitalize)) spaceAfterPunct=\(b(s.autoSpaceAfterPunct))",
            "suggest: on=\(b(s.showSuggestions)) count=\(s.suggestionCount) filter=\(b(s.filterSensitive))"
                + " noSuggestFields=\(b(s.suggestInNoSuggestFields)) emoji=\(b(s.emojiSuggest)) paste=\(b(s.pasteButton))"
                + " numbers=\(b(s.numberChips)) math=\(b(s.mathResults)) addTones=\(b(s.addTonesChip))"
                + " tools=\(b(s.textToolsEnabled)) ai=\(b(s.aiProofread))",
            "input: swipe=\(b(s.swipeTyping)) swipeEn=\(b(s.swipeEnglish)) futo=\(b(s.swipeFuto))"
                + " smartTouch=\(b(s.smartTouch)) spaceLang=\(b(s.spaceSwipeLanguage)) keyCmds=\(b(s.swipeKeyCommands))"
                + " trackpad=\(s.trackpadSpeed.rawValue) holdShift=\(b(s.holdShiftSymbols)) flickDown=\(b(s.flickDownAlternates))"
                + " lpNumbers=\(b(s.longPressNumbers)) lpSymbols=\(b(s.longPressSymbols))",
            "ui: theme=\(a.theme) effect=\(a.effect) wallpaper=\(b(a.wallpaper)) buddy=\(a.buddy) oneHand=\(a.oneHand)"
                + " haptic=\(b(s.hapticFeedback)):\(s.hapticStrength) sound=\(b(s.keySound)):\(s.keySoundStyle):\(s.keySoundVolume)",
            // Đếm thôi: cặp gõ tắt là nội dung người dùng.
            "shortcuts: \(s.shortcutsEnabled ? "on" : "off"):\(s.shortcuts.entries.count)"
                + " systemReplacement=\(b(s.useSystemTextReplacement))",
        ]
    }

    /// Header của máy đang chạy — CHỈ gọi khi Debug mode bật (TouchLog.session autoclosure).
    static func liveHeader(settings: KeyboardSettings, fullAccess: Bool) -> [String] {
        var c = Context()
        let info = Bundle.main.infoDictionary ?? [:]
        c.version = info["CFBundleShortVersionString"] as? String ?? "?"
        c.build = info["CFBundleVersion"] as? String ?? "?"
        c.os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        c.device = machineIdentifier()
        c.idiom = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        #if DEBUG
        c.install = "dev"
        #else
        c.install = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "testflight" : "appstore"
        #endif
        c.locale = Locale.current.identifier
        c.keyboards = UITextInputMode.activeInputModes.compactMap { $0.primaryLanguage }
        c.fullAccess = fullAccess
        c.uiLanguage = L10n.lang
        let d = UserDefaultsProvider.shared
        var a = Appearance()
        // Theme tự tạo: chỉ ghi "custom" (JSON có thể mang tên người dùng đặt).
        let custom = d?.string(forKey: CustomThemeStore.activeKey).map { !$0.isEmpty } ?? false
        a.theme = custom ? "custom" : (d?.string(forKey: ThemeSettings.themeKey) ?? "system")
        a.effect = KeyEffect.load(d).rawValue
        a.wallpaper = d?.bool(forKey: ThemeSettings.wallpaperKey) ?? false
        a.buddy = d?.string(forKey: BuddyCharacter.key) ?? BuddyCharacter.defaultValue.rawValue
        a.oneHand = UserDefaults.standard.string(forKey: OneHand.key) ?? d?.string(forKey: OneHand.key) ?? "off"
        return header(c, settings: settings, appearance: a)
    }

    /// Mã phần cứng ("iPhone17,3"); simulator ⇒ mã máy giả lập.
    static func machineIdentifier() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim + "-sim" }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Gộp dòng y hệt dòng trước: dòng đầu của chuỗi in ngay, dòng lặp không in, hết chuỗi in
    /// "  ×N" (N = tổng số lần) trước dòng mới.
    struct Collapser {
        private var last: String?
        private var repeats = 0

        mutating func push(_ line: String) -> [String] {
            if line == last { repeats += 1; return [] }
            let out = flush() + [line]
            last = line
            return out
        }

        mutating func flush() -> [String] {
            guard repeats > 0 else { return [] }
            defer { repeats = 0; last = nil }
            return ["  ×\(repeats + 1)"]
        }
    }

    /// Giữ ~`keep` byte cuối (cắt ở đầu dòng), đặt header + dòng đánh dấu lên đầu — log dán cho
    /// dev luôn bắt đầu bằng bối cảnh dù file đã xoay vòng.
    static func trimmed(_ data: Data, keep: Int, header: [String]) -> Data {
        var tail = data.count > keep ? data.suffix(keep) : data[...]
        if data.count > keep, let nl = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: nl)...]
        }
        var out = Data()
        if !header.isEmpty { out.append(Data((header.joined(separator: "\n") + "\n").utf8)) }
        out.append(Data("… (older lines trimmed)\n".utf8))
        out.append(contentsOf: tail)
        return out
    }
}
