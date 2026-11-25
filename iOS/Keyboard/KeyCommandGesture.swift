// KeyCommandGesture.swift — "Vuốt phím để sao chép/dán" (Tính năng → Phím & cử chỉ,
// App Group "swipeKeyCommands", mặc định TẮT; ý tưởng từ tweak SwipeExtender).
//
// Chạm một phím chữ rồi vuốt THẲNG LÊN quá mép trên vùng phím (ra khỏi hàng phím trên
// cùng, vào dải thanh gợi ý) và nhấc tay ⇒ lệnh theo VỊ TRÍ phím QWERTY (không phụ thuộc
// Telex/VNI): C sao chép, X cắt, V dán. iOS không cho bàn phím đặt vùng chọn, chọn hết,
// hoàn tác/làm lại ⇒ chỉ ba lệnh này (Android thêm A/Z/Y — KeyCommandGesture.kt).
//
// Phần THUẦN (không UIKit, test được — KeyCommandGestureTests). Ngưỡng GIỐNG Android:
//   dy = start.y − y (lên là dương), dx = |x − start.x|, pitch = bước phím ngang.
//   • HUỶ hẳn (rejected) khi đường đi không còn "gần thẳng đứng":
//       dx > 0.5·pitch + 0.45·max(dy, 0)   (≈ lệch ≤ 24° quanh trục dọc + nửa phím dung sai)
//     hoặc kéo XUỐNG quá nửa phím (dy < −0.5·pitch), hoặc ngón thứ hai chạm, hoặc popup
//     ký tự phụ đã bật. Đã huỷ thì không bao giờ sống lại (gõ vuốt tiếp quản).
//   • BẬT (armed) khi ngón lên tới y ≤ keyAreaTop − 4pt (đỉnh vùng phím, kể cả hàng số).
//   • TẮT lại (disarmed) khi ngón quay xuống y > keyAreaTop; lên lại thì bật lại.
//   • Nhấc tay lúc đang bật ⇒ lệnh. Tắt công tắc ⇒ `begin` trả nil (0 việc mỗi chạm).
// Gõ vuốt: khi cử chỉ còn sống (chưa huỷ), bộ phân loại gõ vuốt KHÔNG được quyết "vuốt";
// huỷ ⇒ phân loại tiếp với toàn bộ đường đã ghi; nhấc tay khi chưa bật ⇒ cho bộ phân
// loại xét điểm cuối (vuốt dọc "xe" từ x lên e vẫn ra từ) — KeyboardView lo phần này.
import CoreGraphics
import Foundation

enum KeyCommand: String, CaseIterable, Equatable {
    case copy, cut, paste

    /// Phím vật lý (ký tự gốc của phím QWERTY, không phân biệt hoa) → lệnh; nil = phím thường.
    static func forKey(_ base: Character) -> KeyCommand? {
        switch base {
        case "c", "C": return .copy
        case "x", "X": return .cut
        case "v", "V": return .paste
        default: return nil
        }
    }

    /// Nhãn tiếng Việt (khoá L10n).
    var viLabel: String {
        switch self {
        case .copy: return LK("Sao chép")
        case .cut: return LK("Cắt")
        case .paste: return LK("Dán")
        }
    }
}

struct KeyCommandGesture: Equatable {
    enum State: Equatable { case tracking, armed, rejected }
    enum Event: Equatable { case none, armed, disarmed, rejected }

    struct Params: Equatable {
        /// Dung sai ngang cố định, tính theo bước phím.
        var lateralKeys: CGFloat = 0.5
        /// Dung sai ngang thêm theo quãng lên (tan góc lệch cho phép).
        var slope: CGFloat = 0.45
        /// Kéo xuống quá chừng này (theo bước phím) ⇒ huỷ.
        var downKeys: CGFloat = 0.5
        /// Phải lên quá đỉnh vùng phím ít nhất chừng này (pt) mới bật.
        var armMargin: CGFloat = 4
    }

    /// nil = cử chỉ vuốt-thẳng-lên không gắn lệnh (hàng chữ trên cùng → số, `beginUp`).
    let command: KeyCommand?
    let start: CGPoint
    let keyAreaTop: CGFloat
    let pitch: CGFloat
    let params: Params
    private(set) var state: State = .tracking

    /// nil khi công tắc tắt, phím không có lệnh, hoặc chưa có layout (pitch ≤ 0).
    static func begin(enabled: Bool, key: Character, start: CGPoint, keyAreaTop: CGFloat,
                      keyPitch: CGFloat, params: Params = Params()) -> KeyCommandGesture? {
        guard enabled, keyPitch > 0, let cmd = KeyCommand.forKey(key) else { return nil }
        return KeyCommandGesture(command: cmd, start: start, keyAreaTop: keyAreaTop,
                                 pitch: keyPitch, params: params)
    }

    /// Cùng cử chỉ, không gắn lệnh: phím hàng chữ trên cùng vuốt thẳng lên ra ký tự phụ (số).
    /// KeyboardView tự giữ ký tự; nhấc tay hỏi `endArmed`.
    static func beginUp(start: CGPoint, keyAreaTop: CGFloat, keyPitch: CGFloat,
                        params: Params = Params()) -> KeyCommandGesture? {
        guard keyPitch > 0 else { return nil }
        return KeyCommandGesture(command: nil, start: start, keyAreaTop: keyAreaTop,
                                 pitch: keyPitch, params: params)
    }

    var isArmed: Bool { state == .armed }
    /// Còn sống (chưa huỷ) — gõ vuốt phải chờ.
    var isCandidate: Bool { state != .rejected }

    /// Đường đi tới `p` còn "gần thẳng đứng, đi lên" không.
    func isVertical(_ p: CGPoint) -> Bool {
        let dy = start.y - p.y
        let dx = abs(p.x - start.x)
        if dy < -params.downKeys * pitch { return false }
        return dx <= params.lateralKeys * pitch + params.slope * max(dy, 0)
    }

    @discardableResult
    mutating func move(to p: CGPoint) -> Event {
        guard state != .rejected else { return .none }
        guard isVertical(p) else { state = .rejected; return .rejected }
        switch state {
        case .tracking where p.y <= keyAreaTop - params.armMargin:
            state = .armed
            return .armed
        case .armed where p.y > keyAreaTop:
            state = .tracking
            return .disarmed
        default:
            return .none
        }
    }

    /// Ngón thứ hai / popup ký tự phụ / hệ thống huỷ touch.
    @discardableResult
    mutating func reject() -> Event {
        guard state != .rejected else { return .none }
        state = .rejected
        return .rejected
    }

    /// Nhấc tay tại `p`: lệnh nếu đang bật (sau khi xét điểm cuối). Sau đó cử chỉ kết thúc.
    mutating func end(at p: CGPoint) -> KeyCommand? {
        endArmed(at: p) ? command : nil
    }

    /// Nhấc tay tại `p`: cử chỉ có đang bật không (cho cử chỉ không gắn lệnh). Sau đó kết thúc.
    mutating func endArmed(at p: CGPoint) -> Bool {
        move(to: p)
        let armed = state == .armed
        state = .rejected
        return armed
    }
}

// MARK: chạy lệnh trên ô gõ (qua giao thức — test bằng proxy/clipboard giả)

/// Phần của UITextDocumentProxy mà lệnh cần.
protocol KeyCommandHost: AnyObject {
    /// selectedText (iOS 16+): nil/rỗng = không chọn gì.
    var selectedText: String? { get }
    func insertText(_ text: String)
    func deleteBackward()
}

/// UIPasteboard.general (chỉ đọc/ghi chuỗi).
protocol KeyCommandClipboard: AnyObject {
    var string: String? { get set }
}

enum KeyCommandRunner {
    enum Outcome: Equatable {
        case copied(String)
        case cut(String)
        case pasted(String)
        /// Sao chép/cắt mà không có chữ đang chọn.
        case nothingSelected
        /// Clipboard không có chữ.
        case clipboardEmpty
        /// Bàn phím chưa có Truy cập đầy đủ ⇒ iOS chặn clipboard.
        case needsFullAccess
    }

    /// Lệnh chạy được không (để nhãn xem trước nói rõ thay vì im lặng). Dán: không đọc
    /// clipboard ở đây (đọc có thể bật hộp "Cho phép dán?") — chỉ xét Truy cập đầy đủ.
    static func precheck(_ cmd: KeyCommand, selectedText: String?, fullAccess: Bool) -> Outcome? {
        guard fullAccess else { return .needsFullAccess }
        switch cmd {
        case .copy, .cut: return (selectedText?.isEmpty ?? true) ? .nothingSelected : nil
        case .paste: return nil
        }
    }

    /// Chạy lệnh. Cắt = sao chép rồi xoá vùng chọn (deleteBackward xoá cả vùng chọn).
    /// Dán đi qua `paste` — CÙNG đường với nút Dán trên thanh gợi ý (controller); trả chữ
    /// đã chèn, nil/rỗng = clipboard không có chữ.
    static func run(_ cmd: KeyCommand, host: KeyCommandHost, clipboard: KeyCommandClipboard,
                    fullAccess: Bool, paste: () -> String?) -> Outcome {
        let sel = cmd == .paste ? nil : host.selectedText
        if let blocked = precheck(cmd, selectedText: sel, fullAccess: fullAccess) { return blocked }
        switch cmd {
        case .copy, .cut:
            let s = sel ?? ""
            clipboard.string = s
            if cmd == .copy { return .copied(s) }
            host.deleteBackward()
            return .cut(s)
        case .paste:
            guard let s = paste(), !s.isEmpty else { return .clipboardEmpty }
            return .pasted(s)
        }
    }

    /// Nhãn tiếng Việt (khoá L10n) cho thông báo ngắn sau lệnh / lúc xem trước.
    static func hint(_ o: Outcome) -> String? {
        switch o {
        case .nothingSelected: return LK("Chưa chọn chữ")
        case .clipboardEmpty: return LK("Clipboard trống")
        case .needsFullAccess: return LK("Cần Truy cập đầy đủ")
        case .copied, .cut, .pasted: return nil
        }
    }

    /// Loại kết quả cho nhật ký gỡ lỗi — KHÔNG kèm nội dung chữ.
    static func logKind(_ o: Outcome) -> String {
        switch o {
        case .copied: return "copied"
        case .cut: return "cut"
        case .pasted: return "pasted"
        case .nothingSelected: return "nothingSelected"
        case .clipboardEmpty: return "clipboardEmpty"
        case .needsFullAccess: return "needsFullAccess"
        }
    }
}

/// Khi nào vuốt-phím-lên-ra-lệnh được bật (ngoài công tắc): không ở ô mật khẩu (sao chép
/// mật khẩu không nên), không khi VoiceOver (router chạm khác).
enum KeyCommandPolicy {
    static func enabled(setting: Bool, traits: FieldTraits?, voiceOver: Bool) -> Bool {
        guard setting, !voiceOver else { return false }
        return traits?.secure != true
    }
}
