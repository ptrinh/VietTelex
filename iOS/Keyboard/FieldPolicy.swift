import UIKit

/// Khi nào gõ LITERAL (bỏ Telex) theo trait của ô nhập.
///
/// Trước đây: mọi ô `autocorrectionType == .no` ⇒ literal. Sai với ô tìm kiếm —
/// thanh địa chỉ Safari/Chrome và Spotlight đều tắt autocorrect nhưng người dùng
/// cần gõ tiếng Việt ở đó. Giờ chỉ literal ở ô có NGỮ NGHĨA không phải chữ Việt:
/// email, URL thuần, username, mã OTP, mật khẩu (giống Android FieldMapping).
enum FieldPolicy {
    static func passthrough(keyboardType: UIKeyboardType,
                            contentType: UITextContentType?) -> Bool {
        switch keyboardType {
        case .emailAddress, .URL: return true
        default: break
        }
        guard let c = contentType else { return false }
        let literal: Set<UITextContentType> = [
            .username, .emailAddress, .URL, .oneTimeCode, .password, .newPassword,
        ]
        return literal.contains(c)
    }

    /// Ô email (người nhận To/Cc Gmail, Outlook…): Telex/VNI vẫn BẬT như ô chữ — ô này cũng là ô
    /// TÌM danh bạ theo tên ("Sơn"), bàn phím tiếng Việt của iOS gõ được ở đó — nhưng địa chỉ
    /// được bảo vệ bằng `EmailTokenGuard`. Không áp ở ô URL và ô đăng nhập/mật khẩu/OTP (vẫn literal).
    static func emailCompose(keyboardType: UIKeyboardType, contentType: UITextContentType?) -> Bool {
        guard keyboardType == .emailAddress || (contentType == .emailAddress && keyboardType != .URL) else {
            return false
        }
        guard let c = contentType else { return true }
        return ![UITextContentType.username, .URL, .oneTimeCode, .password, .newPassword].contains(c)
    }
}

/// Bảo vệ địa chỉ ở ô email (`FieldPolicy.emailCompose`) — THUẦN, song sinh Android
/// `EmailTokenGuard`. Token = chuỗi không có khoảng trắng / "," / ";" tính từ ranh giới gần nhất.
/// - Token chưa có "@"/"." ⇒ gõ Telex/VNI như ô chữ ("Sown" → "Sơn").
/// - Gõ "@" hoặc "." ⇒ phần token DO BÀN PHÍM GÕ được trả lại ĐÚNG phím thô đã bấm (ASCII, không
///   dấu — "nguyeenx" + "@" → "nguyeenx@", "dduc" + "@" → "dduc@"), rồi gõ thô tới hết token.
///   Chữ số và "_" "-" "+" trong token: soạn như thường, tới "@"/"." thì cũng được trả lại thô.
/// - Chữ đã có trên màn hình trước khi bridge theo dõi (app chèn chip người nhận, con trỏ dời
///   tới) KHÔNG bao giờ bị viết lại — chỉ đọc để biết token đã là địa chỉ chưa (một lần sau reset).
/// Chi phí mỗi phím: một phép so "@"/"." ở phím ranh giới; phím chữ chỉ đọc cờ `literal`.
struct EmailTokenGuard: Equatable {
    static func isSeparator(_ c: Character) -> Bool { c.isWhitespace || c == "," || c == ";" }
    static func isMark(_ c: Character) -> Bool { c == "@" || c == "." }
    static func hasMark<S: StringProtocol>(_ s: S) -> Bool { s.contains(where: isMark) }
    /// Token cuối của `context` (sau ranh giới cuối cùng).
    static func tokenTail(_ context: String) -> Substring {
        guard let i = context.lastIndex(where: isSeparator) else { return context[...] }
        return context[context.index(after: i)...]
    }

    /// Đã biết trạng thái token (sau reset phải đọc lại context một lần).
    private(set) var synced = false
    /// Token đã có "@"/"." ⇒ phím chữ chèn thô, không qua engine.
    private(set) var literal = false
    /// Phần token có sẵn trước khi theo dõi (không phải mình gõ) có "@"/".".
    private var prefixMark = false
    /// Phần token bàn phím đã gõ VÀ đã chốt (không gồm từ engine đang soạn): chữ đang hiện…
    private(set) var shown = ""
    /// …và đúng phím thô tương ứng.
    private(set) var raw = ""

    /// Đổi ô / con trỏ dời / host đổi chữ: quên — phím kế đọc lại context.
    mutating func invalidate() { self = EmailTokenGuard() }

    /// Đọc trạng thái token từ chữ trước con trỏ (nil = không biết ⇒ coi như token mới).
    mutating func sync(context: String?) {
        let tail = context.map(Self.tokenTail) ?? ""
        prefixMark = Self.hasMark(tail)
        literal = prefixMark
        shown = ""; raw = ""
        synced = true
    }

    /// Phím ranh giới `text` phải trả token về phím thô trước khi chèn?
    func needsRestore(_ text: String) -> Bool { !literal && Self.hasMark(text) }

    /// Kế hoạch viết lại khi gõ "@"/".": (chữ đang hiện cần xoá, phím thô chèn lại) cho phần token
    /// mình gõ + từ đang soạn. nil = đã đúng phím thô, không cần sửa.
    func restorePlan(composed: String, composedRaw: String) -> (shown: String, raw: String)? {
        let s = shown + composed, r = raw + composedRaw
        return s == r ? nil : (s, r)
    }

    /// Màn hình vừa thêm `shown` (ứng với phím thô `raw`) rồi ký tự ranh giới `text`.
    mutating func appended(shown s: String, raw r: String, text: String = "") {
        if let i = text.lastIndex(where: Self.isSeparator) {
            // token mới bắt đầu sau ranh giới cuối
            let rest = String(text[text.index(after: i)...])
            prefixMark = false
            shown = rest; raw = rest
            literal = Self.hasMark(rest)
            synced = true
            return
        }
        shown += s + text; raw += r + text
        if Self.hasMark(text) || Self.hasMark(s) { literal = true }
    }

    /// Phần token mình gõ vừa được viết lại thành phím thô `raw` (sau đó là `text`).
    mutating func restored(to r: String, text: String) {
        shown = ""; raw = ""
        appended(shown: r, raw: r, text: text)
    }

    /// ⌫ xoá MỘT ký tự đã chốt trước con trỏ (engine trống). Ký tự cuối khớp phím thô ⇒ bớt cả
    /// hai; lệch (chữ có dấu) ⇒ phần còn lại thành "có sẵn" (không bao giờ viết lại nữa). Hết phần
    /// mình gõ ⇒ đang xoá chữ có sẵn: quên, phím kế đọc lại context.
    mutating func deletedOne() {
        guard synced else { return }
        guard let last = shown.last else { invalidate(); return }
        if raw.last == last {
            shown.removeLast(); raw.removeLast()
        } else {
            shown.removeLast()
            prefixMark = prefixMark || Self.hasMark(shown)
            shown = ""; raw = ""
        }
        literal = prefixMark || Self.hasMark(shown)
    }
}

extension FieldPolicy {
    /// Auto-shift theo kiểu viết hoa của ô: true = bật shift, false = tắt, nil =
    /// để nguyên. Host KHÔNG khai báo (nil) = mặc định UITextInputTraits là
    /// `.sentences` — trước đây nil bị coi như "không viết hoa" nên ô trống vẫn
    /// hiện phím chữ thường (feedback iPad 26/09/2026).
    static func autoShift(autocap: UITextAutocapitalizationType?, before: String) -> Bool? {
        switch autocap ?? .sentences {
        case .none: return nil
        case .allCharacters: return true
        case .words:
            return before.isEmpty || before.last?.isWhitespace == true
        case .sentences:
            let t = before.trimmingCharacters(in: .whitespaces)
            return before.isEmpty
                || (before.hasSuffix(" ") && (t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?")))
                || before.hasSuffix("\n")
        @unknown default: return nil
        }
    }

    /// Như trên + công tắc "Tự động viết hoa đầu câu": tắt ⇒ nil (không đụng shift tay)
    /// và KHÔNG gọi `before` (documentContextBeforeInput là XPC).
    static func autoShift(enabled: Bool, autocap: UITextAutocapitalizationType?,
                          before: () -> String) -> Bool? {
        guard enabled else { return nil }
        return autoShift(autocap: autocap, before: before())
    }

    /// Host báo đổi (textDidChange) nhưng chữ trước con trỏ `before` y như lần quyết định auto-shift
    /// gần nhất `decidedOn`, và người dùng đã chạm ⇧ từ lần đó ⇒ đây là tiếng vọng tới trễ của
    /// chính phím mình: giữ lựa chọn tay, không đặt lại shift ("Hello" ␣ ⇧ h phải ra "H").
    static func hostEchoKeepsHandShift(byHand: Bool, before: String?, decidedOn: String?) -> Bool {
        guard byHand, let before, let decidedOn else { return false }
        return before == decidedOn
    }
}

/// Ảnh chụp trait của ô nhập — phần THUẦN của refreshFieldTraits(). Host đổi ô trong
/// cùng app (ô tìm kiếm ↔ ô bình luận…) KHÔNG gọi lại viewWillAppear, nên controller
/// đọc lại trait ở textDidChange/selectionDidChange và chỉ cấu hình lại bàn phím khi
/// ảnh chụp KHÁC lần trước (configureInputKind còn nhảy plane — gọi thừa là mất plane
/// số/ký hiệu đang mở). KHÔNG dùng documentIdentifier: nil trước khi phiên nhập thiết
/// lập → bẫy crash.
struct FieldTraits: Equatable {
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var appearance: UIKeyboardAppearance = .default
    var autocorrection: UITextAutocorrectionType = .default
    var contentType: UITextContentType?
    var secure = false

    /// Gõ literal (bỏ Telex)?
    var passthrough: Bool {
        FieldPolicy.passthrough(keyboardType: keyboardType, contentType: contentType)
    }

    /// Ô email gõ Telex có bảo vệ địa chỉ (FieldPolicy.emailCompose). `passthrough` vẫn true ở ô
    /// này cho các tính năng khác (gõ tắt, tự sửa, vuốt, phép tính, tự thêm dấu cách: vẫn TẮT).
    var emailCompose: Bool {
        !secure && FieldPolicy.emailCompose(keyboardType: keyboardType, contentType: contentType)
    }

    /// Engine bỏ Telex (gõ literal) — ô passthrough trừ ô email (emailCompose).
    var telexLiteral: Bool { passthrough && !emailCompose }

    /// Chip kết quả phép tính (MathResults): không ở ô mật khẩu / URL / email / username /
    /// OTP (ô literal); ô số vẫn có.
    var allowsMathResults: Bool { !passthrough && !secure }

    /// Ô cho phép thanh gợi ý (stock tắt ở ô mật khẩu / autocorrection = .no). Ô email
    /// luôn có (chỉ hiện chip đuôi mail — EmailDomains), vì ô email hầu như đều tắt autocorrect.
    var allowsSuggestions: Bool { !secure && (autocorrection != .no || inputKind == .email) }

    /// Tự thêm dấu cách sau dấu câu: chỉ ô chữ thường (không email/URL/số/mật khẩu/omnibox).
    var allowsAutoSpace: Bool {
        !passthrough && !secure && inputKind == .normal
    }

    /// Loại layout (web input type=number/email/url ánh xạ sang keyboardType).
    var inputKind: KeyboardView.InputKind {
        switch keyboardType {
        case .numberPad, .numbersAndPunctuation, .decimalPad,
             .phonePad, .asciiCapableNumberPad:
            return .number
        case .emailAddress: return .email
        case .URL: return .url
        case .webSearch: return .search
        default: return .normal
        }
    }

    /// Dòng header log chẩn đoán: chỉ loại trait, không có nội dung người dùng.
    var logDescription: String {
        "keyboardType=\(keyboardType.rawValue) returnKeyType=\(returnKeyType.rawValue)"
            + " autocorrectionType=\(autocorrection.rawValue)"
            + " textContentType=\(contentType?.rawValue ?? "nil") secure=\(secure ? 1 : 0)"
    }

    /// Cần cấu hình lại bàn phím? Lần đầu (old nil) luôn cần; sau đó chỉ khi trait đổi.
    static func needsReconfigure(old: FieldTraits?, new: FieldTraits) -> Bool {
        old != new
    }
}

extension FieldTraits {
    /// Ô nhạy cảm: mật khẩu / mã OTP — dải gợi ý để TRỐNG (không ☰, không 📋, không mời Dán).
    var sensitive: Bool {
        if secure { return true }
        guard let c = contentType else { return false }
        return [UITextContentType.password, .newPassword, .oneTimeCode].contains(c)
    }

    /// Loại chip clipboard ưu tiên theo ô (ClipDetect.prioritize) — song sinh Android
    /// FieldTraits.clipPreference.
    var preferredClipKind: ClipChip.Kind? {
        if let c = contentType {
            let address: Set<UITextContentType> = [.fullStreetAddress, .streetAddressLine1, .streetAddressLine2,
                                                   .addressCity, .addressState, .addressCityAndState, .sublocality, .location]
            if address.contains(c) { return .address }
            if c == .telephoneNumber { return .phone }
            if c == .oneTimeCode { return .otp }
        }
        if keyboardType == .phonePad || keyboardType == .namePhonePad { return .phone }
        return nil
    }

    /// Ô URL / thanh "tìm hoặc nhập địa chỉ" (Safari, Chrome — keyboardType .webSearch):
    /// chip `www.` `.com` `.vn` (+ `https://` khi ô trống) ở dải công cụ (URLChips).
    var wantsURLChips: Bool { inputKind == .url || inputKind == .search }

    /// App tắt gợi ý (autocorrection = .no) ở ô CHỮ không nhạy cảm, không literal, không bàn số
    /// (thanh địa chỉ Safari .webSearch, ô chat…) — song sinh Android `FieldTraits.appNoSuggestions`.
    /// Cài đặt "Gợi ý cả khi ứng dụng tắt gợi ý" bật ⇒ vẫn gợi ý chữ (StripMode.full) nhưng
    /// `allowsSuggestions` vẫn false ⇒ AutoCorrect.fieldAllows giữ TẮT; và không học từ.
    var appNoSuggestions: Bool {
        autocorrection == .no && !sensitive && !passthrough && inputKind != .number
    }

    /// Ô địa chỉ / tìm kiếm ⇒ gợi ý chữ thường (không DisplayCase tên riêng, không hoa đầu câu)
    /// — song sinh Android `FieldMapping.isAddressOrSearch` (#113 thanh địa chỉ Firefox gõ
    /// "bình" ra "Thường"). .URL / .webSearch, hoặc Enter = Go / Search / Google / Yahoo.
    var lowercaseSuggestions: Bool {
        guard !sensitive else { return false }
        if inputKind == .url || inputKind == .search { return true }
        switch returnKeyType {
        case .go, .search, .google, .yahoo: return true
        default: return false
        }
    }
}

/// Dải gợi ý hiện gì ở ô hiện tại — song sinh Android StripMode (#113). Chiều cao dải KHÔNG
/// phụ thuộc chế độ này (giữ theo công tắc toàn cục, e72ae43) — chỉ nội dung đổi.
enum StripMode: Equatable {
    /// Tắt "Thanh gợi ý" trong cài đặt: không có dải (chỉ headroom balloon).
    case off
    /// Mật khẩu / OTP / ẩn danh / bàn số: dải trống giữ chiều cao.
    case blank
    /// Ô từ chối gợi ý chữ (autocorrection = .no: thanh địa chỉ Safari, ô URL…) nhưng không
    /// nhạy cảm: ☰ / 📋 + lời mời Dán (mời một lần, chip = Plus) + chip URL — không chữ.
    case tools
    /// Gợi ý đầy đủ.
    case full

    /// Dải có vẽ nội dung (thanh công cụ ± gợi ý).
    var shown: Bool { self == .tools || self == .full }

    /// THUẦN: công tắc + trait ô + ẩn danh → dải hiện gì. `suggestAnyway` = cài đặt "Gợi ý cả
    /// khi ứng dụng tắt gợi ý" (#113): ô `appNoSuggestions` (không ẩn danh) ⇒ .full.
    static func of(showSuggestions: Bool, traits t: FieldTraits, incognito: Bool,
                   suggestAnyway: Bool = false) -> StripMode {
        guard showSuggestions else { return .off }
        if t.allowsSuggestions { return .full }
        if overridesAppNoSuggest(suggestAnyway, traits: t, incognito: incognito) { return .full }
        if t.sensitive || incognito || t.inputKind == .number { return .blank }
        return .tools
    }

    /// Ô app tắt gợi ý mà VẪN gợi ý chữ (cài đặt bật, không nhạy cảm/literal/bàn số/ẩn danh).
    static func overridesAppNoSuggest(_ suggestAnyway: Bool, traits t: FieldTraits, incognito: Bool) -> Bool {
        suggestAnyway && t.appNoSuggestions && !t.allowsSuggestions && !incognito
    }

    /// THUẦN: học từ ở ô này? Ô app tắt gợi ý VẪN học như ô thường (Phil 05/10 — ô chat là nơi
    /// gõ nhiều nhất); ô nhạy cảm không bao giờ là appNoSuggestions; ẩn danh thì không học.
    /// Song sinh Android `StripMode.learns`.
    static func learns(learnWords: Bool, traits t: FieldTraits?, incognito: Bool) -> Bool {
        learnWords && !incognito && t?.emailCompose != true   // ô email: không học tên/địa chỉ
    }

    /// Ô URL / tìm kiếm ở chế độ .full: chip URL (URLChips) thay gợi ý chữ CHỈ ở "vị trí tên
    /// miền" — ô trống, hoặc token trước con trỏ đã có "." / "://" (đang gõ địa chỉ); còn lại
    /// gợi ý chữ như ô thường. Chế độ .tools: luôn chip URL như cũ.
    static func prefersURLChips(before: String, after: String) -> Bool {
        if before.isEmpty && after.isEmpty { return true }
        let token = before.reversed().prefix { !$0.isWhitespace }
        return token.contains(".") || String(token.reversed()).contains("://")
    }
}
