// KeyAlternates — giữ phím chữ để ra ký tự phụ (issue #98, kiểu Gboard): hàng trên
// q…p → 1…0, hàng 2–3 → ký hiệu. Phần THUẦN, bản Kotlin song sinh:
// android/keyboard/src/main/kotlin/com/viettelex/keyboard/KeyAlternates.kt — sửa ở đây
// thì sửa y hệt bên kia (bảng khớp fixture chung Fixtures/key-alternates.txt).
//
// Bảng ký hiệu gốc Gboard tiếng Anh (a@ s# … m?), đổi 3 phím cho tiếng Việt: d → $,
// c → %, b → / (tiếng Việt ít dùng ' và ;, hay dùng % và / — ngày tháng, link; ₫ vẫn ở
// bàn ký hiệu). Không trùng ký tự nào giữa các phím.
//
// Giữ phím "," hàng đáy (iPhone, bàn chữ) ra "." như Gboard — bật khi có ÍT NHẤT một
// công tắc giữ phím đang có hiệu lực (số khi hàng số tắt, hoặc ký hiệu), tức `map` không
// rỗng. "." chốt từ đang gõ y như ",". (Android: "," đã có giữ lâu = gõ giọng nói thì giữ
// nguyên, không ra ".".)
import CoreGraphics
import Foundation

enum KeyAlternates {
    static let digits: [Character: String] = [
        "q": "1", "w": "2", "e": "3", "r": "4", "t": "5",
        "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
    ]
    static let symbols: [Character: String] = [
        "a": "@", "s": "#", "d": "$", "f": "_", "g": "&", "h": "-", "j": "+", "k": "(", "l": ")",
        "z": "*", "x": "\"", "c": "%", "v": ":", "b": "/", "n": "!", "m": "?",
    ]

    /// iPad: ký tự phụ stock in xám trên phím chữ (KHÁC bảng iPhone) — vuốt xuống hoặc
    /// giữ `holdDelay` đều ra ký tự này. Nhãn luôn hiện như stock ⇒ giữ luôn bật, không
    /// theo công tắc longPress* của iPhone (xem `padMap`).
    static let padHints: [Character: String] = [
        "q": "1", "w": "2", "e": "3", "r": "4", "t": "5",
        "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
        "a": "@", "s": "#", "d": "$", "f": "&", "g": "*",
        "h": "(", "j": ")", "k": "'", "l": "\"",
        "z": "%", "x": "-", "c": "+", "v": "=", "b": "/", "n": ";", "m": ":",
    ]
    /// Bảng giữ phím của iPad = đúng nhãn đang vẽ trên phím (luôn vẽ ⇒ luôn bật; VoiceOver
    /// giữ nguyên như vuốt xuống iPad — không gate riêng).
    static func padMap() -> [Character: String] { padHints }

    /// Giữ bao lâu thì thành ký tự phụ — ngắn hơn giữ ⌫/emoji (0,45–0,5 s), dài hơn
    /// trackpad phím cách (0,3 s) để gõ chậm không lỡ tay.
    static let holdDelay: TimeInterval = 0.38
    /// Ngón trôi quá ngần này (pt/dp) trước khi đủ giờ ⇒ không phải giữ (vuốt / trượt).
    static let slop: CGFloat = 10

    /// "Vuốt phím xuống ra ký tự phụ" (iPhone, mặc định TẮT): cùng ký tự với giữ phím, không phải
    /// chờ `holdDelay`. Gõ vuốt bật ⇒ tắt (kéo xuống từ một phím là đầu một nét vuốt — không phân
    /// biệt được); bảng rỗng (VoiceOver, hai công tắc giữ phím đều tắt) ⇒ tắt. iPad có cử chỉ riêng.
    static func flickDownEnabled(setting: Bool, swipeTyping: Bool, isPad: Bool,
                                 alternates: [Character: String]) -> Bool {
        setting && !swipeTyping && !isPad && !alternates.isEmpty
    }
    /// Quãng kéo xuống tối thiểu (pt/dp) — hơn nửa chiều cao phím điện thoại: ngón trôi lúc gõ
    /// nhanh (vài pt) không dính.
    static let flickDownDistance: CGFloat = 24
    /// Nhấc tay: có phải vuốt THẲNG xuống không — đủ quãng và dọc gấp đôi ngang (kéo chéo sang
    /// phím hàng dưới không tính).
    static func isFlickDown(dx: CGFloat, dy: CGFloat) -> Bool {
        dy >= flickDownDistance && dy >= 2 * abs(dx)
    }

    /// Bảng đang dùng. Hàng số bật ⇒ bỏ số (đã có phím riêng). iPad có ký tự phụ vuốt
    /// xuống riêng; VoiceOver/TalkBack: giữ phím là cử chỉ của trình đọc ⇒ tắt hết.
    /// Rỗng ⇒ không hẹn giờ, không vẽ nhãn (0 chi phí).
    static func map(numbers: Bool, symbols sym: Bool, numberRow: Bool,
                    isPad: Bool = false, accessibility: Bool = false) -> [Character: String] {
        guard !isPad, !accessibility else { return [:] }
        var m: [Character: String] = [:]
        if numbers, !numberRow { m.merge(digits) { a, _ in a } }
        if sym { m.merge(symbols) { a, _ in a } }
        return m
    }

    /// Bảng cho "Giữ Shift để gõ số và ký hiệu" (`ShiftHold`): cùng ký tự với `map`, nhưng số
    /// q…p vẫn có khi hàng số bật (nhất quán — giữ ⇧ + q luôn ra 1). Tắt / iPad / VoiceOver ⇒ rỗng
    /// (iPad: ⇧ giữ nguyên như stock).
    static func shiftMap(enabled: Bool, numbers: Bool, symbols sym: Bool, numberRow: Bool,
                         isPad: Bool = false, accessibility: Bool = false) -> [Character: String] {
        guard enabled else { return [:] }
        return map(numbers: numbers || numberRow, symbols: sym, numberRow: false,
                   isPad: isPad, accessibility: accessibility)
    }

    /// Ký tự phụ của phím "," hàng đáy.
    static let commaAlt = "."
    /// Giữ "," ra "." khi bảng ký tự phụ đang dùng không rỗng (mọi gating của `map`).
    static func commaHold(alternates: [Character: String]) -> Bool { !alternates.isEmpty }
    /// Giữ "," đủ giờ: đổi phím đang chờ chốt thành "." — vẫn chốt lúc nhấc / khi ngón khác
    /// chạm (cùng đường với ","). false nếu "," đã chốt rồi (ngón khác chạm trước khi đủ giờ).
    /// `alt`: ký tự thay — "." cho phím ",", "," cho phím "." ("Phím cạnh dấu cách" = Dấu chấm).
    static func holdComma(_ commits: KeyCommitQueue, id: ObjectIdentifier, alt: String = commaAlt,
                          fire: @escaping (String) -> Void) -> Bool {
        guard commits.isArmed(id) else { return false }
        commits.disarm(id)
        commits.arm(id) { fire(alt) }
        return true
    }

    /// Công tắc số chỉ có nghĩa (và chỉ hiện trong app) khi hàng phím số TẮT.
    static func numbersSettingVisible(numberRow: Bool) -> Bool { !numberRow }

    /// Theo dõi MỘT ngón đang giữ phím có ký tự phụ. Không đồng hồ bên trong: view hẹn
    /// giờ `holdDelay` rồi gọi `fire()`; mọi hủy (trôi, ngón khác, thành vuốt) đi qua đây.
    struct Hold: Equatable {
        let alt: String
        let start: CGPoint
        private(set) var fired = false
        private(set) var cancelled = false

        init(alt: String, start: CGPoint) { self.alt = alt; self.start = start }

        /// Ngón di chuyển; true nếu vừa hủy vì trôi quá slop (trước khi bắn).
        mutating func move(to p: CGPoint) -> Bool {
            guard !fired, !cancelled else { return false }
            if hypot(p.x - start.x, p.y - start.y) > KeyAlternates.slop { cancelled = true; return true }
            return false
        }
        /// Ngón khác chạm / cú vuốt bắt đầu / bàn phím ẩn.
        mutating func cancel() { if !fired { cancelled = true } }
        /// Hết giờ: true nếu thành ký tự phụ (chưa hủy).
        mutating func fire() -> Bool {
            guard !fired, !cancelled else { return false }
            fired = true
            return true
        }
        /// Nhấc tay: ký tự phụ phải chèn (thay chữ đã chèn lúc chạm), nil = chạm thường.
        var commit: String? { fired ? alt : nil }
    }
}


/// Phím ⇧ bàn phím cảm ứng: chạm (viết hoa một lần), chạm đôi (Caps Lock), và GIỮ làm phím
/// bổ trợ — "Giữ Shift để gõ số và ký hiệu" (mặc định BẬT): ngón đè ⇧ + chạm phím chữ ⇒ ký tự
/// phụ của phím (số nhỏ q…p, ký hiệu a…m — cùng ký tự giữ lâu cho) thay vì chữ hoa.
///
/// - Chạm ⇧ nhanh: một-lần như cũ; chạm đôi < `doubleTap`: Caps Lock.
/// - Đã giữ ⇧ gõ ký tự phụ: nhả KHÔNG để lại viết hoa một-lần (Caps Lock trước đó giữ nguyên),
///   và lần chạm ⇧ kế tiếp không tính là chạm đôi. Chạm đôi rồi giữ: vẫn Caps Lock.
/// - Gõ chồng ngón (phím chữ chạm < `rollover` sau ⇧, ⇧ chưa nhả) vẫn là chữ hoa.
/// - Phím không có ký tự phụ / tắt cài đặt (bảng rỗng): `symbol` trả nil ⇒ chữ như cũ.
///
/// Đường phím chữ chỉ thêm một phép kiểm tra bool (`held`). Ký tự phụ vào controller là
/// NGUYÊN VĂN (VNI không lấy số làm dấu — người dùng giữ ⇧ là muốn SỐ).
/// THUẦN — pinned by ShiftHoldTests (trong KeyAlternatesTests.swift). Bản Kotlin song sinh:
/// android/keyboard/src/main/kotlin/com/viettelex/keyboard/ShiftHold.kt.
struct ShiftHold {
    typealias Shift = SuggestionCase.Shift
    static let doubleTap: TimeInterval = 0.3
    static let rollover: TimeInterval = 0.15

    /// Có ngón đang đè ⇧.
    private(set) var held = false
    private var before: Shift = .off
    private var pressed: Shift = .off
    private var lastTap: TimeInterval?
    private var downAt: TimeInterval = 0
    private var symbolsUsed = false

    /// Ngón chạm ⇧ lúc `now` (giây) khi shift đang là `cur`: trả shift mới.
    mutating func down(_ cur: Shift, now: TimeInterval) -> Shift {
        before = cur
        held = true; symbolsUsed = false
        let next: Shift
        if let t = lastTap, now - t < Self.doubleTap { next = .capsLock }
        else { next = cur == .off ? .once : .off }
        lastTap = now; downAt = now
        pressed = next
        return next
    }

    /// Phím chữ `label` (chữ thường) vừa chạm lúc `now`: ký tự phụ phải gõ thay chữ, hoặc nil.
    /// `map` = `KeyAlternates.shiftMap` (rỗng khi tắt cài đặt).
    mutating func symbol(_ label: Character, map: [Character: String], now: TimeInterval) -> String? {
        guard held, now - downAt >= Self.rollover, let s = map[label] else { return nil }
        symbolsUsed = true
        return s
    }

    /// Nhấc ngón khỏi ⇧ khi shift đang là `cur`: trả shift mới.
    mutating func up(_ cur: Shift) -> Shift {
        guard held else { return cur }
        held = false
        guard symbolsUsed else { return cur }
        symbolsUsed = false
        lastTap = nil
        return (before == .capsLock || pressed == .capsLock) ? .capsLock : .off
    }

    /// Huỷ mọi chạm: bỏ trạng thái giữ, shift để nguyên.
    mutating func cancel() { held = false; symbolsUsed = false }
}
