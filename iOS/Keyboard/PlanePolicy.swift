/// Khi nào tự quay về plane CHỮ như stock iOS: đang ở plane 123/#+= mà đã gõ
/// ít nhất một ký tự, nhấn space → về chữ (feedback 26/09/2026: gõ "," xong
/// space vẫn kẹt ở 123). Ô số (keyboardType số) thì ở lại plane số.
enum PlanePolicy {
    static func returnToLettersOnSpace(inSymbolPlane: Bool, typedInPlane: Bool,
                                       numericField: Bool) -> Bool {
        inSymbolPlane && typedInPlane && !numericField
    }

    /// Dấu KẾT VẾ: chạm ở plane 123/#+= ⇒ về plane chữ NGAY, không cần dấu cách (Phil
    /// 06/11/2026; chế độ "Tự động" của SymbolReturn). Gồm dạng in ấn trong hàng biến thể
    /// (… ” ’ ») và & $ @ (Phil 15/11/2026: sau chúng là chữ — "a&b", "$tên", "@gmail").
    /// "." KHÔNG về (15/11/2026: người dùng hay gõ "..." — về sau chấm đầu thì phải bấm 123
    /// lại); dấu cách vẫn đưa về chữ. ")" KHÔNG về (Phil 17/11/2026: hay gõ ":)))", "(a))").
    /// Ngoặc / nháy MỞ (( “ ‘ «), / # % * - _ + = [ { < > \ |,
    /// số, tiền tệ khác, toán: giữ plane.
    static let clauseEnders: Set<String> = [",", "?", "!", "\"", "'", ":", ";", "&", "$", "@",
                                            "\u{2026}", "\u{201D}", "\u{2019}", "\u{00BB}"]
    /// Dấu nằm GIỮA số: ngay sau chữ số thì ở lại plane số ("2.5", "1,000", "10:30").
    static let digitSeparators: Set<String> = [".", ",", ":"]

    /// Vừa chèn `inserted` ở plane 123/#+= (chạm, giữ chọn biến thể — mọi đường chèn ký tự
    /// của plane). `before` = ký tự ngay trước con trỏ TRƯỚC khi chèn (chỉ cần khi `inserted`
    /// thuộc digitSeparators). Ô số (keyboardType số) ở lại như luật space.
    /// `mode` = "Về bàn chữ sau ký hiệu": `.auto` chỉ dấu kết vế, `.always` mọi ký hiệu (chữ số
    /// ở lại), `.off` không bao giờ. Song sinh Android PlanePolicy.returnToLettersAfterSymbol.
    static func returnToLettersAfterSymbol(_ inserted: String, mode: SymbolReturn = .auto,
                                           inSymbolPlane: Bool, numericField: Bool,
                                           before: Character?) -> Bool {
        guard inSymbolPlane, !numericField, !inserted.isEmpty else { return false }
        switch mode {
        case .off: return false
        case .auto: guard clauseEnders.contains(inserted) else { return false }
        case .always: guard !isNumeral(inserted) else { return false }
        }
        if digitSeparators.contains(inserted), let b = before, b.isASCII, b.isNumber { return false }
        return true
    }

    /// Chữ số (0–9 và dạng số khác trong hàng biến thể: ½ ¹ …) — "Luôn" vẫn ở lại plane số.
    static func isNumeral(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .decimalNumber, .letterNumber, .otherNumber: return true
            default: return false
            }
        }
    }

    /// Có cần đọc ký tự trước con trỏ cho `inserted` không (chỉ . , : và chế độ khác Tắt) —
    /// tránh đọc proxy mỗi phím.
    static func needsBefore(_ inserted: String, mode: SymbolReturn) -> Bool {
        mode != .off && digitSeparators.contains(inserted)
    }

    /// Chạm ABC (123/#+= → chữ): shift bật hay tắt. `autoShift` = viết hoa đầu câu
    /// đánh giá theo context LÚC CHẠM (nil = công tắc tắt / ô không viết hoa).
    /// Bug tester 1.2.x: gõ "." ở plane 123 + "Tự thêm dấu cách" → ". " rồi về ABC,
    /// code cũ ép shift = off vô điều kiện ⇒ chữ kế không viết hoa. Stock đánh giá lại.
    static func shiftOnReturnToLetters(autoShift: Bool?) -> Bool {
        autoShift ?? false
    }

    /// Plane đích (thuần, KeyboardView ánh xạ plane riêng của nó sang đây).
    enum Target { case letters, symbols, emoji, emojiSearch, templates }

    /// Rời plane chữ: stock iOS TẮT Caps Lock (và shift một-lần) khi sang 123/#+= hay
    /// emoji — Caps Lock → 123 → ABC về chữ thường (Phil 06/10/2026: trước đây vẫn hoa).
    /// Mẫu câu (bảng phủ của VietTelex, không đổi bàn chữ) giữ shift. Về ABC thì
    /// shiftOnReturnToLetters đánh giá lại viết hoa đầu câu. Song sinh Android
    /// PlanePolicy.clearsShiftLeavingLetters.
    static func clearsShiftLeavingLetters(to target: Target) -> Bool {
        switch target {
        case .symbols, .emoji, .emojiSearch: return true
        case .letters, .templates: return false
        }
    }
}
