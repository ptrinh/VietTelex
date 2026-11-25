// KeyboardView — programmatic UIKit clone of Apple's Vietnamese keyboard.
// M1: letters plane + shift/caps + backspace (with repeat) + 123 plane +
// globe/space/return. Metrics follow Apple's stock layout; the pixel-perfect
// fidelity pass (balloons, exact colors per appearance, iPad) is M2.
import UIKit
import AudioToolbox
import CoreHaptics

final class KeyboardView: UIView, UIInputViewAudioFeedback {

    enum Key {
        case letter(Character)
        case text(String)
        case space
        case doubleSpacePeriod        // "  " fast → ". " (Apple behavior)
        case newline
        /// Xuống dòng KHÔNG gửi: giữ lâu Return, hoặc ⇧ (bấm tay, một lần) + Return —
        /// controller chèn "\n" qua LineBreak (ô chat web bắt Return = Gửi).
        case lineBreak
        case backspace
        case moveCursor(Int)          // space-hold trackpad mode (ký tự, âm = trái)
        case moveLine(Int)            // trackpad lên/xuống (dòng, âm = lên)
        case clearField               // nút thùng rác plane mẫu câu → xoá sạch ô
        /// Huỷ phím chữ vừa gõ rồi chèn chuỗi (iPad vuốt xuống ra ký tự phụ).
        case replaceLastLetter(String)
    }

    /// emojiSearch = hàng ô tìm emoji + plane chữ (phím chặn vào EmojiSearchSession).
    /// keypad = bàn số lớn kiểu Apple (ô numberPad / decimalPad / OTP — NumericKeypad).
    private enum Plane { case letters, numbers, symbols, emoji, templates, emojiSearch, keypad }
    /// Plane có phím chữ qua router (chữ thường + chế độ tìm emoji).
    private var lettersLike: Bool { plane == .letters || plane == .emojiSearch }

    /// Gần-trong-suốt nhưng KHÔNG clear: vùng alpha 0 không nhận touch ở cấp hệ thống
    /// (touch rơi sang app host). Dùng cho mọi nền phủ vùng bàn phím.
    static let touchableClear = UIColor(white: 0, alpha: 0.01)

    /// Strip gợi ý khi mở ở mức "Chiều cao thanh gợi ý" = Thấp (bố cục cũ). 36 → 30 (25/09/2026,
    /// so ảnh stock: vùng bar stock ≈53pt, VietTelex ≈59pt), +4 đệm trên ⇒ 34. Mức Vừa (mặc định
    /// từ 18/10/2026) / Cao cộng SuggestionBarHeight.delta (openStripNow).
    static let openStrip: CGFloat = 34
    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// Bo góc phím như stock iOS 26+ (cũ: 5).
    static let keyRadius: CGFloat = 8
    /// Khe ngang giữa phím: iPad stock rộng hơn (~10pt) iPhone (6).
    private static var keyGap: CGFloat { isPad ? 10 : 6 }
    /// Lề trái/phải hàng phím (iPhone 6.5 như stock — KeyGeometry).
    private static var sideMargin: CGFloat { KeyGeometry.sideMargin(pad: isPad) }
    /// SF Compact như stock iOS 26/27 (KeyGeometry.Typography); nil nếu hệ thống không có
    /// (lọt về font khác) → SF Pro cỡ fallback.
    private static let compactDescriptor: UIFontDescriptor? = {
        let design = UIFontDescriptor.SystemDesign(rawValue: "NSCTFontUIFontDesignCompact")
        guard let d = UIFont.systemFont(ofSize: 20).fontDescriptor.withDesign(design) else { return nil }
        return UIFont(descriptor: d, size: 20).fontName.localizedCaseInsensitiveContains("compact") ? d : nil
    }()
    static var hasCompactFont: Bool { compactDescriptor != nil }
    static func keyFont(_ size: CGFloat) -> UIFont {
        let lf = labelFonts
        // Tuỳ chỉnh nâng cao (Plus): phông/độ đậm/cỡ — UIFont cache theo cỡ (KeyLabelFonts).
        if lf.active { return lf.font(size: size * lf.scale) }
        // Mặc định: cùng một UIFont mỗi cỡ (mỗi phím từng tạo lại từ descriptor).
        if let f = defaultKeyFonts[size] { return f }
        let f = compactDescriptor.map { UIFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        defaultKeyFonts[size] = f
        return f
    }
    nonisolated(unsafe) private static var defaultKeyFonts: [CGFloat: UIFont] = [:]
    /// "Tuỳ chỉnh nâng cao" đang áp (sau cổng Plus) — đặt lại mỗi lần hiện (applyAppearance),
    /// TRƯỚC khi dựng phím. Mặc định = như cũ (không đo, không kẹp, bo 8).
    nonisolated(unsafe) static var labelFonts = KeyLabelFonts(style: .default, compact: compactDescriptor)
    /// Bo góc phím tuỳ chỉnh (% nửa cạnh ngắn, KeyStyle.corner); nil = keyRadius.
    nonisolated(unsafe) static var cornerPercent: Int?
    private var keyStyle = KeyStyle()
    private func applyKeyStyle(_ style: KeyStyle) {
        keyStyle = style
        let custom = style.assets.font == nil ? nil : themeAssets?.font
        if Self.labelFonts.font != style.font || Self.labelFonts.weight != style.weight
            || Self.labelFonts.scale != style.labelScale || Self.labelFonts.active != style.customizesLabels
            || !Self.labelFonts.sameCustom(custom) {
            Self.labelFonts = KeyLabelFonts(style: style, compact: Self.compactDescriptor, custom: custom)
        }
        Self.cornerPercent = style.corner
        if balloonMade { balloon.invalidateStyle() }   // ô phóng to lấy phông mới lần hiện kế
        refreshBarFonts()
    }
    /// Phông ô phóng to / popup ký tự phụ: cùng phông + độ đậm với phím (KHÔNG nhân cỡ), kẹp để
    /// dấu chồng (Ễ, Ỗ) không bị UILabel cắt. Mặc định ⇒ y như cũ.
    static func popupFont(_ size: CGFloat, height: CGFloat) -> UIFont {
        let lf = labelFonts
        guard lf.active else { return .systemFont(ofSize: size) }
        let fitted = KeyLabelFit.centeredSize(want: size, em: lf.em(KeyLabelEm.stackedSample), height: height)
        return lf.font(size: fitted.rounded(.down))
    }
    /// Nhãn chữ phím iPhone: cỡ theo hoa/thường + canh baseline stock. iPad: cỡ/baseline
    /// theo hướng máy do KeyButton.padRole lo (KeyGeometry.Typography.Pad).
    private func applyKeycapFont(_ b: KeyButton, title: String) {
        guard !Self.isPad else { return }
        let size = KeyGeometry.Typography.size(for: title, compact: Self.hasCompactFont)
        if b.requestedFontSize != size || !Self.labelFonts.active && b.titleFont.pointSize != size {
            b.titleFont = Self.keyFont(size)
            b.requestedFontSize = size
        }
        b.baselineAligned = true
    }
    /// Nhãn chữ phím chức năng iPhone (123/ABC/#+=): SF Compact cỡ stock, cùng baseline.
    private func applyLabelFont(_ b: KeyButton, size: CGFloat) {
        // iPad: nhãn phím đổi plane dạt góc dưới-trái như stock (#+=, 123, ABC).
        guard !Self.isPad else { b.padRole = .corner(left: true); return }
        b.titleFont = Self.keyFont(size)
        b.baselineAligned = true
    }
    /// Khe shift↔Z, M↔⌫ (khe giữa chữ là 6).
    static let shiftGap: CGFloat = 12
    /// Đệm trên của bar (user 25/09/2026): host có app KHÔNG vẽ dải khung phía trên
    /// cửa sổ bàn phím (Telegram, app VietTelex) → bar dính mép. Không có tín hiệu nào
    /// để phát hiện (log hình học y hệt WhatsApp) → đệm cố định 4pt mọi nơi.
    static let barTopPad: CGFloat = 4
    private enum ShiftState { case off, on, caps }

    var enableInputClicksWhenVisible: Bool { true }

    private let onKey: (Key) -> Void
    private var needsGlobe: Bool
    // Globe key theo hợp đồng Apple: addTarget thẳng vào UIInputViewController
    // với .allTouchEvents — long-press mở picker bàn phím chỉ chạy khi
    // handleInputModeList nhận event THẬT.
    private weak var inputController: UIInputViewController?

    /// M2 suggestion bar: gate qua toggle showSuggestions trong app.
    var onSuggestion: ((String) -> Void)?
    private var heightConstraint: NSLayoutConstraint?
    /// Chiều cao tự xin (KeyLayout.chrome total) — CHƯA cộng hostFillExtra.
    private(set) var baseRequestedHeight: CGFloat = 0
    /// Phần xin thêm để lấp dải container hệ thống lộ phía trên view (HostFill — controller
    /// quyết định). Phím hấp thụ (rowsHeight @900), strip/headroom balloon giữ nguyên.
    var hostFillExtra: CGFloat = 0 {
        didSet { if hostFillExtra != oldValue { updateSuggestionChrome() } }
    }
    /// Lệch tạm (1 pixel) cộng vào constraint chiều cao để host đo lại (HostOversize .bump, #151);
    /// controller trả về 0 ngay sau. Không đụng hình học hàng phím.
    var heightNudge: CGFloat = 0 {
        didSet {
            guard heightNudge != oldValue else { return }
            applyHeightConstant()
        }
    }
    /// Chiều cao xin của lần hiện ĐÃ cấu hình gần nhất (cả process). View mới dựng chưa được
    /// controller cấu hình (chưa đọc cài đặt: chưa có thanh gợi ý…) xin số này thay vì chiều cao
    /// mặc định — WhatsApp quay lại từ nền đo bàn phím ĐÚNG lúc đó (232 thay vì 267) rồi giữ khung
    /// kính cao sai tới khi app bị tắt hẳn (dải xám trên bàn phím, log máy Phil 07/11/2026).
    nonisolated(unsafe) static var lastConfiguredHeight: CGFloat = 0
    /// Nơi nhớ chiều cao đó QUA các lần process bàn phím bị iOS tắt (nil = không nhớ; test tự gán).
    /// Process mới (lastConfiguredHeight = 0) từng xin chiều cao chưa cấu hình (251) rồi mới lên
    /// 266: Zalo đo bàn phím đúng lúc đó nên ô nhập nằm thấp 15pt, bị bàn phím che (log máy
    /// tester 22/11/2026: 2 process mới trong 20 giây). Defaults riêng của extension — không cần
    /// Full Access. Khoá theo kích thước màn hình (dọc / ngang khác chiều cao).
    nonisolated(unsafe) static var primedDefaults: UserDefaults? =
        NSClassFromString("XCTestCase") == nil ? .standard : nil
    nonisolated(unsafe) private static var persistedHeights: [String: CGFloat] = [:]
    static func primedKey(screen: CGSize) -> String { "primedHeight.\(Int(screen.width))x\(Int(screen.height))" }
    /// Chiều cao đã nhớ cho màn hình này; 0 nếu chưa có hoặc số vô lý.
    static func storedPrimedHeight(screen: CGSize) -> CGFloat {
        guard screen.width > 0, let d = primedDefaults else { return 0 }
        let h = CGFloat(d.double(forKey: primedKey(screen: screen)))
        return (100...700).contains(h) ? h : 0
    }
    static func storePrimedHeight(_ h: CGFloat, screen: CGSize) {
        guard screen.width > 0, (100...700).contains(h), let d = primedDefaults else { return }
        let key = primedKey(screen: screen)
        guard persistedHeights[key] != h else { return }   // gọi mỗi lần đổi constraint: chỉ ghi khi đổi
        persistedHeights[key] = h
        d.set(Double(h), forKey: key)
    }
    /// Kích thước màn hình controller đưa vào (khoá nhớ chiều cao); .zero = không nhớ.
    var primedScreen: CGSize = .zero
    /// Controller đã chạy cấu hình lần hiện cho view này (markConfigured).
    private(set) var appearanceConfigured = false
    /// Chỉ view của controller (installKeyboard) mượn lastConfiguredHeight trước khi cấu hình;
    /// view dựng riêng (test, preview) xin đúng chiều cao của chính nó.
    var primesLastHeight = false
    /// Constant đặt cho constraint chiều cao (xem lastConfiguredHeight).
    var constraintHeight: CGFloat {
        if primesLastHeight, !appearanceConfigured, Self.lastConfiguredHeight > 0 { return Self.lastConfiguredHeight }
        return baseRequestedHeight + hostFillExtra + heightNudge
    }
    private func applyHeightConstant() {
        if primesLastHeight, appearanceConfigured {
            Self.lastConfiguredHeight = requestedHeight
            Self.storePrimedHeight(requestedHeight, screen: primedScreen)
        }
        let total = constraintHeight
        if heightConstraint?.constant != total { heightConstraint?.constant = total }
    }
    /// Controller bật primesLastHeight ngay sau khi dựng view: xin luôn chiều cao lần hiện trước.
    func applyPrimedHeight() {
        if Self.lastConfiguredHeight <= 0 { Self.lastConfiguredHeight = Self.storedPrimedHeight(screen: primedScreen) }
        applyHeightConstant()
    }
    /// Controller gọi cuối phần cấu hình lần hiện: từ đây xin đúng chiều cao theo cài đặt.
    func markConfigured() {
        appearanceConfigured = true
        applyHeightConstant()
    }
    /// Chiều cao đang xin host (constant constraint, gồm phần xin thêm, không gồm lệch tạm).
    var requestedHeight: CGFloat { baseRequestedHeight + hostFillExtra }
    /// Nền theme đục / ảnh nền đang vẽ (dải kính hệ thống lộ ra mới thấy khác màu).
    var paintsBackdrop: Bool { !themeBackdrop.isHidden || wallpaperActive }
    /// Debug log: constant + priority của constraint chiều cao xin host.
    var heightRequestInfo: String {
        guard let h = heightConstraint else { return "-" }
        return "\(h.constant)@\(Int(h.priority.rawValue)) base=\(baseRequestedHeight) fill=\(hostFillExtra)"
    }
    private let suggestionBar = SuggestionBar()
    private var suggestionsEnabled = false
    /// Thanh gợi ý đang bật cho ô hiện tại (setSuggestionsEnabled) — controller đối chiếu.
    var suggestionsShownState: Bool { suggestionsEnabled }
    private var stripReserved = false

    private var plane: Plane = .letters {
        didSet {
            // Vào plane số/ký hiệu từ plane khác → đếm lại; 123⇄#+= giữ nguyên.
            if oldValue != .numbers, oldValue != .symbols { typedInSymbolPlane = false }
            // Rời plane chữ sang 123/#+=/emoji: tắt Caps Lock + shift một-lần như stock
            // (Phil 06/10/2026). Về ABC đánh giá lại viết hoa đầu câu (reevaluateShiftForLetters).
            if oldValue == .letters, shift != .off, PlanePolicy.clearsShiftLeavingLetters(to: planeTarget(plane)) {
                shift = .off
            }
        }
    }
    private func planeTarget(_ p: Plane) -> PlanePolicy.Target {
        switch p {
        case .letters: return .letters
        case .numbers, .symbols, .keypad: return .symbols
        case .emoji: return .emoji
        case .emojiSearch: return .emojiSearch
        case .templates: return .templates
        }
    }
    /// Đã gõ ký tự ở plane 123/#+= → space kế tiếp quay về chữ (PlanePolicy).
    private var typedInSymbolPlane = false
    private var shift: ShiftState = .on {        // Apple: sentence start = shifted
        // Thanh gợi ý theo Shift như Gboard (SuggestionCase) — báo controller khi đổi.
        // Đang vuốt: shift đổi tạm (trả lại/nhả quanh cú vuốt) — swipeEnded tự vẽ lại bar.
        didSet {
            shiftByHand = false                  // mọi đổi khác phím ⇧ (shiftDown đặt lại sau)
            if shift != oldValue, !swipeActive { onShiftChange?() }
            if oldValue == .caps, shift != .caps { Self.pianoShiftChanged(shift == .on ? .on : .off) }
        }
    }
    /// Shift/Caps Lock vừa đổi (tay, đầu câu, nhả sau một chữ, rời plane chữ…).
    var onShiftChange: (() -> Void)?
    /// Trạng thái Shift cho hoa/thường của gợi ý (SuggestionCase).
    var suggestionShift: SuggestionCase.Shift {
        switch shift { case .off: return .off; case .on: return .once; case .caps: return .capsLock }
    }
    /// Chọn gợi ý = gõ một từ: nhả Shift một-lần như phím chữ (Caps Lock giữ nguyên).
    func releaseOneShotShift() {
        if shift == .on { shift = .off; applyShiftAppearance() }
    }
    private var returnTitle = "return"
    private var dark = false

    /// Vùng hàng phím — khung tính tay ở layoutRowsArea (KeyRowLayout.rowsArea: cùng thang ưu
    /// tiên rows↔view như các constraint cũ), không Auto Layout.
    private let rowsContainer = KeyGridView()
    /// Đỉnh vùng hàng mong muốn (= strip + headroom, KeyLayout.chrome) — thay rowsTop @997 cũ.
    private var rowsTopWanted: CGFloat = 0
    /// Chiều cao vùng hàng mong muốn (sàn @998, đích @900, trần +60 bắt buộc).
    private var rowsHeightWanted: CGFloat = 212
    /// Sàn đỉnh (@999): host cấp thiếu thì strip nhường tới đây rồi phím mới co.
    private var rowsMinTop: CGFloat = KeyLayout.balloonHeadroom
    /// Đáy vùng hàng cách đáy view (safe area máy gập + "Nâng bàn phím").
    private var rowsBottomGap: CGFloat = 0
    /// Lề trái/phải vùng hàng (chế độ một tay).
    private var rowsSideInsets: (left: CGFloat, right: CGFloat) = (0, 0)
    private var repeatTimer: Timer?
    private var lastSuggestionSig: BarSignature?
    private var wordDeleteTick = 0
    /// Giữ backspace >3s → xoá theo TỪ (controller đọc proxy, off hot path).
    var onDeleteWord: (() -> Void)?
    private var lastSpaceTap: TimeInterval = 0
    /// Phím nhấc-mới-chốt đang đè — xem KeyCommitQueue (thứ tự khi gõ chồng ngón).
    private let commits = KeyCommitQueue()
    private var trackpadGesture = TrackpadGesture()
    /// "Độ nhạy con trỏ" — controller đặt lúc hiện (KeyboardSettings); áp khi bắt đầu kéo.
    var trackpadSpeed = TrackpadSpeed.defaultValue
    private var backspaceHoldStart: TimeInterval = 0

    // Màu lấy từ theme (KeyboardTheme.swift — token tập trung một chỗ). Theme
    // Hệ thống = fill đục xấp xỉ stock (alpha-white trên nền trong suốt làm phím
    // đổi sắc theo màu app phía sau — chỉ theme Kính cố ý làm vậy).
    private var palette = KeyboardTheme.system.palette(systemDark: false)
    private var systemDark = false
    private var themeSettings = ThemeSettings()
    private var plainFill: UIColor { palette.keyFill.ui }
    private var specialFill: UIColor { palette.specialFill.ui }
    /// Chữ/icon trên phím (đã áp độ trong suốt ký tự). Balloon/popup dùng `palette.ink`.
    private var ink: UIColor { palette.keyInk.ui }
    private func inkFaded(_ a: Double) -> UIColor { palette.keyInk.alpha(a).ui }
    /// Nhãn / logo trên phím cách: phím cách tô nền chức năng riêng (Piano: đen) ⇒ chữ phím chức năng.
    private var spaceInk: RGBA { palette.functionFill != nil ? palette.fnInk : palette.keyInk }
    /// Phím chức năng + phím cách: nền / chữ-icon (= phím chữ trừ theme tô riêng — Xanh lá).
    /// Đọc một lần lúc dựng phím.
    private var fnFill: UIColor { palette.fnFill.ui }
    private var fnInk: UIColor { palette.fnInk.ui }
    /// Nền theme + ảnh nền + lớp phủ: 3 view phẳng dưới hàng phím (không blur,
    /// không bóng). Ẩn hết ở theme nền trong suốt → giữ touchableClear như cũ.
    private let themeBackdrop = UIView()
    private let wallpaperView = UIImageView()
    private let wallpaperDim = UIView()
    /// Hoạ tiết nền (Tim đen / Hoa xanh): MỘT CAShapeLayer trong themeBackdrop, path dựng lại chỉ
    /// khi đổi cỡ — rasterize một lần, không vẽ gì mỗi phím / mỗi lần gõ.
    private let decorLayer = CAShapeLayer()
    /// Dải phủ nền của motif "bokeh" (Mưa đêm — KeyboardDecoration.bokehShade): dựng lười, theme khác không có.
    private var decorShade: CAGradientLayer?
    private var decorGaps: [KeyboardDecoration.Gap]?
    /// Cảnh nền (motif cảnh "pitch"… — ThemeScene): dựng lười lần đầu theme có cảnh; theme khác ⇒ chưa từng tạo.
    private var sceneLayer: ThemeSceneLayer?
    private var decorWidth: CGFloat = 0
    /// Dải cực quang tĩnh mép trên (theme AI, "borderFx":"aurora" — AuroraFx): gradient ngang + mặt nạ gradient dọc trong
    /// themeBackdrop, dựng lười lần đầu cần; theme khác ⇒ chưa từng tạo (0 chi phí).
    private var auroraBand: CAGradientLayer?
    /// Nền gradient dọc (theme JSON "bg2" — Lạc trôi): MỘT CAGradientLayer đáy themeBackdrop, dựng lười; theme khác ⇒ nil.
    private var bgGradient: CAGradientLayer?
    private var auroraBandColors: [UInt32]?
    /// Ký hiệu mờ ở góc trên phải (theme Cung hoàng đạo — palette.cornerGlyph): MỘT CATextLayer trong themeBackdrop, dựng
    /// lười; theme khác ⇒ chưa từng tạo / ẩn (0 chi phí).
    private var cornerGlyphLayer: CATextLayer?
    private var wallpaperActive = false
    private var wallpaperLoadedFor: CGSize = .zero
    /// Ảnh nền / ảnh nền + tiền cảnh theme: mới nhất thắng qua các khung tạm của host (SizedDecodeGate).
    private let wallpaperGate = SizedDecodeGate()
    private let themeScreenGate = SizedDecodeGate()
    /// Khung tạm đang chờ đứng yên (SizedDecodeGate.settleDelay) — hết giờ mà cỡ không đổi ⇒ giải ở cỡ đó.
    private var pendingSettle: (size: CGSize, work: DispatchWorkItem)?
    /// Cỡ tạm đã đứng yên đủ lâu ⇒ không hoãn nữa.
    private var settledSize: CGSize?
    /// Tệp tải về của theme (theme JSON: phông / ảnh nền / tiền cảnh / skin phím) — nạp MỘT lần mỗi theme
    /// (ThemeAssetLoader, cache theo chữ ký). Theme không có tệp ⇒ nil, mọi đường bên dưới thoát ngay.
    private var themeAssets: LoadedThemeAssets?
    /// Bộ tải về (trước khi gắn skin điểm ảnh) — dáng phím "pixel" dựng skin theo bảng màu mỗi lần palette đổi.
    private var downloadedAssets: LoadedThemeAssets?
    /// Ảnh nền theme (trên màu nền, dưới ảnh nền người dùng — ảnh người dùng bật thì thắng).
    private let themeImageView = UIImageView()
    /// Ảnh tiền cảnh: TRÊN hàng phím, căng đúng cỡ bàn phím, không nhận chạm; ô phóng to / hiệu ứng nằm trên.
    private let foregroundView = UIImageView()
    private var themeScreenLoadedFor: (size: CGSize, sig: String)?
    private var builtAssetsSig: String?

    /// `deferInitialBuild`: KHÔNG dựng phím ở init (controller dựng một lần sau khi biết
    /// sáng/tối + theme + loại ô — trước đây init dựng plane chữ kiểu mặc định rồi viewWillAppear
    /// dựng LẠI khi máy ở chế độ tối / có theme / ô số: ~40 phím xé + dựng 2 lần mỗi lần hiện).
    init(needsGlobe: Bool, inputController: UIInputViewController?, deferInitialBuild: Bool = false,
         onKey: @escaping (Key) -> Void) {
        self.needsGlobe = needsGlobe
        self.inputController = inputController
        self.onKey = onKey
        super.init(frame: .zero)
        // Compact (user 2026-07-23): no reserved candidate strip — 4pt breathing
        // room on top, keys, 2pt below. Top-row balloons now overlap the key
        // area (extensions cannot draw outside their own bounds); the strip
        // returns in M2 when suggestions land there.
        // Priority 999, NOT required: during extension load the host briefly
        // imposes its own (much taller) frame — a required constant fought it
        // and Auto Layout broke OUR constraint for those frames.
        let height = heightAnchor.constraint(equalToConstant: 216)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height
        // Fast typists ROLL fingers: the next key is pressed before the previous
        // lifts. Default isMultipleTouchEnabled=false made iOS reject that second
        // touch outright — the missed-keypress bug.
        isMultipleTouchEnabled = true
        // ROOT CAUSE rớt phím khi gõ nhanh (log thiết bị 25/09/2026): nền view TRONG
        // SUỐT → iOS hit-test ở render server THEO PIXEL để chọn process nhận touch;
        // chạm vào khe giữa phím / góc bo rơi xuyên xuống UIRemoteKeyboardWindow của
        // app host (backboardd giao touch cho Notes, không cho extension) → mất phím.
        // Gõ chậm chạm giữa phím nên không bị; gõ nhanh hay lệch vào khe. hitInsets /
        // nearest-key router chỉ có tác dụng SAU khi touch đã tới process này.
        // Alpha 0.01: đủ để render server coi là "có nội dung", mắt không thấy.
        backgroundColor = Self.touchableClear
        // Vùng hàng: khung đặt tay mỗi lượt layout (layoutRowsArea) — thang ưu tiên cũ (rows height
        // @900 nhường host, trần +60, đỉnh = strip @997, sàn cao @998, sàn đỉnh headroom @999, đỉnh
        // ≥ 0) giờ là KeyRowLayout.rowsArea; xem lịch sử constraint ở đó.
        addSubview(rowsContainer)
        // Suggestion bar sống trong "khoảng trống 2" — chỉ hiện khi bật. KHUNG CỐ ĐỊNH
        // (frame đặt ở layoutSubviews, không constraint): xem SuggestionBar.
        suggestionBar.isHidden = true
        addSubview(suggestionBar)
        if deferInitialBuild {
            initialBuildPending = true
        } else {
            StartupTrace.span("kv.initRebuild") { rebuild() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { repeatTimer?.invalidate() }

    /// Bàn phím ẩn hẳn (viewDidDisappear): xé cả cây view. Lý do (RAM-AUDIT.md #1): iOS 26+
    /// UIKit giữ `UIInputView` của controller mãi (vòng `UIInputView` ⇄ `_UIInputViewContent`
    /// qua associated object — tái hiện được với UIInputView RỖNG trong ViewTreeLeakTests),
    /// kèm trait corner-provider trỏ vào UIStackView cũ ⇒ cây phím cũ (~1,8 MB) sống theo mỗi
    /// lần hiện. Xé: dừng timer/display link, bỏ planeCache + ảnh nền, gỡ đệ quy mọi subview —
    /// thứ gì còn bị UIKit níu chỉ là vỏ rỗng vài KB. View đã xé KHÔNG dùng lại: controller
    /// dựng KeyboardView mới nếu cùng controller hiện lại (KeyboardViewController.viewWillAppear).
    private(set) var isTornDown = false
    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        dropSnapshot()
        repeatTimer?.invalidate(); repeatTimer = nil
        trackpadLink?.invalidate(); trackpadLink = nil
        altTimer?.cancel(); altTimer = nil
        commaTimer?.cancel(); commaTimer = nil
        dropAltHold()
        planeCache.removeAll()
        EmojiData.dropCaches()
        barEmojiTiles?.reset(); barEmojiTiles = nil
        letterKeys.removeAll(); shiftKeys = []; crossRowConstraints = []
        spaceBar = nil; spaceLogo = nil; spaceCode = nil; indentedRow = nil
        overlayPanel?.removeFromSuperview(); overlayPanel = nil
        keyEffects?.halt(); keyEffects = nil; fxRect = nil
        beatFlash?.halt(); beatFlash = nil
        keyFloat?.halt(); keyFloat = nil
        buddy?.halt(); buddy = nil
        aiEye?.halt(); aiEye = nil
        rainbow?.halt(); rainbow = nil
        hueFill?.halt(); hueFill = nil
        mole?.halt(); mole = nil
        spotlight?.halt(); spotlight = nil
        wallpaperView.image = nil
        wallpaperLoadedFor = .zero
        themeImageView.image = nil; foregroundView.image = nil; themeScreenLoadedFor = nil
        wallpaperGate.cancel(); themeScreenGate.cancel()
        pendingSettle?.work.cancel(); pendingSettle = nil
        Self.stripSubviews(of: self, constraints: true)
        removeFromSuperview()
    }

    /// Cảnh báo bộ nhớ: bỏ các plane KHÔNG hiện (planeCache — plane đang hiện nằm ở
    /// rowsContainer, không trong cache) + bảng emoji (lưới đang mở đã giữ bản riêng).
    func dropCaches() {
        planeCache.removeAll()
        EmojiData.dropCaches()
        if let t = barEmojiTiles {
            t.reset()   // ô đang hiện giữ ảnh của nó; ô đang chờ (việc nền vừa bị bỏ) xin lại
            for (i, b) in emojiButtons.enumerated() where barEmojiWanted[i] != nil && b.title(for: .normal) == nil
                && (suggestionBar.emojiImages[i]?.isHidden ?? true) { applyBarEmoji(i) }
            t.flush()
        }
        KeyButton.dropTextSizeCache()
    }

    #if DEBUG
    var debugPlaneCacheCount: Int { planeCache.count }
    var debugWallpaperImage: UIImage? { wallpaperView.image }
    #endif

    /// Gỡ đệ quy (lá trước): cắt mọi tham chiếu cha→con để phần UIKit còn níu không kéo theo
    /// cả cây. Arranged subview của UIStackView gỡ qua removeFromSuperview là đủ (UIKit bỏ
    /// luôn khỏi arrangedSubviews). `constraints`: gỡ luôn constraint của từng view (chỉ dùng
    /// cho cây của mình — view gốc của controller còn constraint hệ thống, đừng đụng).
    static func stripSubviews(of v: UIView, constraints: Bool = false) {
        for s in v.subviews {
            stripSubviews(of: s, constraints: constraints)
            s.removeFromSuperview()
        }
        if constraints { v.removeConstraints(v.constraints) }
    }

    /// Bật/tắt thanh gợi ý cho ô hiện tại. `reserveStrip` = công tắc toàn cục: ô từ chối
    /// gợi ý vẫn GIỮ dải strip (trống) để chiều cao bàn phím không đổi khi đổi ô.
    func setSuggestionsEnabled(_ on: Bool, reserveStrip: Bool? = nil) {
        let emojiBefore = emojiInBar
        suggestionsEnabled = on
        stripReserved = reserveStrip ?? on
        lastSuggestionSig = nil        // chrome đổi → lượt show kế phải ghi lại UI
        updateSuggestionChrome()
        // Nút emoji Thanh trên: thanh bật/tắt ở ô này ⇒ 😊 rời / về hàng đáy.
        if emojiInBar != emojiBefore { rebuild(); setNeedsLayout() }
    }

    // Nút ⌄ thu gọn thanh gợi ý đã BỎ (10/2026, user: "không cần, nhường chỗ cho gợi ý") —
    // gợi ý / 📋 / 😊 / nhân vật dời sát mép phải. Muốn bỏ hẳn thanh: Cài đặt → tắt Gợi ý.
    // Khoá "suggestionBarCollapsed" cũ không còn đọc ⇒ ai đang thu gọn sẽ thấy thanh mở lại.
    // 11/2026: ⌄ trở lại ở góc phải nhưng để ẨN BÀN PHÍM, chỉ khi bật "Nút ẩn bàn phím"
    // (KeyboardDismissButton, mặc định TẮT ⇒ bố cục y như trên) — xem dismissZone.

    /// "Nút ẩn bàn phím" (đọc lúc hiện — applyAppearance). Tắt ⇒ không tạo nút, không chừa chỗ.
    var dismissButtonEnabled = KeyboardDismissButton.defaultValue {
        didSet { if dismissButtonEnabled != oldValue { stripZonesKey = nil; setNeedsLayout() } }
    }
    /// ⌄ đang hiện: bật + dải có chỗ (kể cả ô mật khẩu — dải trống) + không ở bàn emoji.
    private var dismissShownNow: Bool {
        KeyboardDismissButton.shown(enabled: dismissButtonEnabled, stripReserved: stripReserved,
                                    emojiPlane: plane == .emoji || plane == .emojiSearch)
    }
    /// Phần chừa ở mép phải cho ⌄ (0 khi tắt / không hiện ⇒ mọi khung y như chưa có nút).
    private var dismissInset: CGFloat { KeyboardDismissButton.rightInset(shown: dismissShownNow) }
    private var dismissZoneMade = false
    private lazy var dismissZone: UIButton = {
        dismissZoneMade = true
        let b = UIButton(type: .custom)
        b.accessibilityLabel = L("Ẩn bàn phím")
        b.addAction(UIAction { [weak self] _ in
            Self.clickModifier()
            self?.inputController?.dismissKeyboard()
        }, for: .touchUpInside)
        addSubview(b)
        return b
    }()
    #if DEBUG
    /// Test hook: nút ⌄ ẩn bàn phím (nil = ẩn / chưa tạo).
    var debugDismissButton: UIButton? { dismissZoneMade && !dismissZone.isHidden ? dismissZone : nil }
    #endif
    /// Khung ⌄ — THUẦN để test: ô cao trọn strip sát mép phải (= ô ☰ bên trái).
    static func dismissZoneFrame(width: CGFloat, strip: CGFloat) -> CGRect {
        CGRect(x: width - KeyboardDismissButton.zoneWidth, y: 0, width: KeyboardDismissButton.zoneWidth, height: strip)
    }
    private func layoutDismissZone() {
        let show = dismissShownNow && bounds.width > 0
        if !show { if dismissZoneMade { dismissZone.isHidden = true }; return }
        let strip = max(rowsTopWanted, openStripNow)
        let f = Self.dismissZoneFrame(width: bounds.width, strip: strip)
        dismissZone.isHidden = false
        defer { bringSubviewToFront(dismissZone) }
        // layoutSubviews chạy cả khi gõ: trạng thái không đổi ⇒ khỏi dựng lại ảnh.
        let key = DismissZoneKey(frame: f, rowTop: barRowTop(strip: strip), ink: palette.barInk)
        guard key != dismissZoneKey else { return }
        dismissZoneKey = key
        dismissZone.frame = f
        dismissZone.setImage(UIImage(systemName: "keyboard.chevron.compact.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)), for: .normal)
        dismissZone.tintColor = palette.barInk.ui.withAlphaComponent(0.45)
        dismissZone.contentEdgeInsets = barContentInsets(strip: strip)   // canh hàng chữ gợi ý như ☰ / 📋
    }
    private struct DismissZoneKey: Equatable { let frame: CGRect; let rowTop: CGFloat; let ink: RGBA }
    private var dismissZoneKey: DismissZoneKey?

    // Burger (☰) khi bar MỞ: nút GHIM CỐ ĐỊNH ở mép trái, cao trọn
    // strip, tự vẽ icon + nhận tap. Trước nằm trong bar (fillProportionally) nên
    // trôi vào giữa khi hết gợi ý + vùng tap chỉ 20pt sát mép rất khó bấm
    // (user 2026-07-25). Giờ frame lớn, luôn ở mép → bấm đâu trong vùng cũng ăn.
    static let stripZoneWidth: CGFloat = 52
    /// Burger: chạm = mẫu câu; giữ lâu = bật/tắt chế độ một tay (iPhone). Bảng sửa văn
    /// bản (icon con trỏ) đã bỏ 27/09/2026 — ưu tiên gọn/nhẹ; một tay vẫn bật được ở đây
    /// hoặc trong app (Cài đặt → Chế độ một tay).
    /// Tắt "Mẫu câu" (iPhone): ô mép trái KHÔNG biến mất mà thành nút MỘT TAY (icon bàn phím
    /// một tay, chạm hoặc giữ = bật/tắt) — tester Plus 1.2.8: tắt mẫu câu thì ☰ mất, không còn
    /// lối bật một tay trên bàn phím. Ô này vốn đã chừa chỗ (bar thụt stripZoneWidth) nên
    /// không thêm gì vào thanh gợi ý. iPad / bàn tách đôi: không có một tay ⇒ ẩn như cũ.
    private var burgerZoneMade = false
    private lazy var burgerZone: UIButton = {
        burgerZoneMade = true
        let b = UIButton(type: .custom)
        b.addAction(UIAction { [weak self] _ in self?.leftZoneTapped() }, for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(burgerHold(_:)))
        hold.minimumPressDuration = 0.45
        b.addGestureRecognizer(hold)
        addSubview(b)
        return b
    }()
    /// Ô mép trái thanh gợi ý đang làm gì (thuần theo cài đặt — OneHandTests).
    /// `.tools`: Mẫu câu TẮT nhưng Công cụ văn bản hiện (Plus + công tắc — `toolsEnabled` là
    /// KeyboardSettings.textToolsActive()) ⇒ ☰ vẫn hiện, chạm mở thẳng danh sách công cụ
    /// (user 10/2026: tắt Mẫu câu làm mất lối vào Công cụ). Giữ lâu vẫn bật/tắt một tay.
    enum LeftZone: Equatable { case templates, tools, oneHand, none }
    static func leftZone(templatesEnabled: Bool, toolsEnabled: Bool = false,
                         pad: Bool, split: Bool) -> LeftZone {
        if templatesEnabled { return .templates }
        if toolsEnabled { return .tools }
        return pad || split ? .none : .oneHand
    }
    private var leftZone: LeftZone {
        Self.leftZone(templatesEnabled: templatesEnabled, toolsEnabled: textToolsEnabled,
                      pad: Self.isPad, split: splitMode)
    }
    private func leftZoneTapped() {
        switch leftZone {
        case .templates, .tools: toggleTemplates()
        case .oneHand: toggleOneHandFromKeyboard()
        case .none: break
        }
    }
    /// Icon ô mép trái: ☰ (mẫu câu) hoặc bàn phím một tay (theo bên sẽ bật / đang bật).
    private func leftZoneImage(pointSize: CGFloat) -> UIImage? {
        let name: String
        switch leftZone {
        case .oneHand:
            let side = oneHand == .off ? lastOneHandSide : oneHand
            name = side == .left ? "keyboard.onehanded.left" : "keyboard.onehanded.right"
        default: name = "line.3.horizontal"
        }
        return UIImage(systemName: name,
                       withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
    }
    private func applyLeftZoneAccessibility(_ b: UIButton) {
        switch leftZone {
        case .oneHand:
            b.accessibilityLabel = oneHand == .off ? L("Bật chế độ một tay") : L("Thoát chế độ một tay")
            b.accessibilityHint = nil
        case .tools:
            b.accessibilityLabel = templatesActive ? L("Đóng công cụ văn bản") : L("Công cụ văn bản")
            b.accessibilityHint = Self.isPad ? nil : L("Giữ lâu để bật hoặc tắt chế độ một tay")
        default:
            b.accessibilityLabel = templatesActive ? L("Đóng mẫu câu") : L("Mẫu câu")
            b.accessibilityHint = Self.isPad ? nil : L("Giữ lâu để bật hoặc tắt chế độ một tay")
        }
    }

    @objc private func burgerHold(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        toggleOneHandFromKeyboard()
    }
    /// Giữ lâu burger: bật/tắt một tay (iPad bỏ qua). Long-press đã nhận ⇒ UIButton huỷ
    /// touchUpInside nên chạm-giữ không mở mẫu câu.
    private func toggleOneHandFromKeyboard() {
        guard !Self.isPad else { return }
        Self.clickModifier()
        setOneHand(OneHand.toggled(oneHand, preferred: lastOneHandSide))
    }

    /// Bar là HÀNG NỘI DUNG ghim đỉnh, cao barRowNow (20 ở mức Thấp, + delta "Chiều cao thanh
    /// gợi ý"), thụt mép trái chừa burgerZone, mép phải chừa 📋 / 😊 / nhân vật (không còn ⌄) —
    /// không chồng lên nút mép. Frame thường không đổi ⇒ SuggestionBar không layout lại.
    /// Đỉnh hàng nội dung bar với `strip` đang dùng: canh giữa dải đỉnh bàn phím → đỉnh phím
    /// hàng đầu (SuggestionBarHeight.rowTop, pinned by SuggestionBarHeightTests). Bar, ☰, 📋,
    /// 😊 và vùng chạm đều lấy từ đây ⇒ luôn cùng tâm.
    private func barRowTop(strip: CGFloat) -> CGFloat {
        SuggestionBarHeight.rowTop(strip: strip, capGap: rowSpec.gap, row: barRowNow, topPad: Self.barTopPad)
    }
    /// Đệm nội dung cho nút mép (☰ / 📋 / 😊) cao trọn strip: icon canh giữa hàng nội dung bar.
    private func barContentInsets(strip: CGFloat) -> UIEdgeInsets {
        let top = barRowTop(strip: strip)
        return UIEdgeInsets(top: top, left: 0, bottom: max(strip - barRowNow - top, 0), right: 0)
    }

    private func layoutSuggestionBar() {
        let w = Self.stripZoneWidth
        let right = barRightExtras
        let (y, h) = suggestionRowSpan()
        let f = CGRect(x: w, y: y, width: max(bounds.width - w - right, 0), height: h)
        if suggestionBar.frame != f { suggestionBar.frame = f }
    }

    /// Đỉnh + cao dòng chữ gợi ý (toạ độ view). Host cấp thiếu chiều cao ⇒ strip co (phím giữ nguyên): bar Vừa/Cao co
    /// về chỗ còn lại trước (sàn 20 = mức Thấp), hết chỗ mới dời lên VỪA đủ để không đè hàng đầu. Mắt AI canh tâm theo.
    private func suggestionRowSpan() -> (y: CGFloat, h: CGFloat) {
        let top = barRowTop(strip: max(rowsTopWanted, openStripNow))
        let room = rowsContainer.frame.height > 0 ? rowsContainer.frame.minY - top : .greatestFiniteMagnitude
        let h = max(min(barRowNow, room), min(barRowNow, SuggestionBarHeight.baseRow))
        let squeeze = rowsContainer.frame.height > 0
            ? min(0, rowsContainer.frame.minY - (top + h)) : 0
        return (top + squeeze, h)
    }

    /// Đặt lại frame + icon + ẩn/hiện nút mép trái (☰) theo trạng thái bar. Gọi mỗi
    /// layoutSubviews. Chiều cao lấy từ HẰNG SỐ constraint (rowsTop), KHÔNG từ
    /// frame — frame có thể chưa kịp cập nhật trong cùng pass → strip=0 → tịt.
    private func layoutStripZones() {
        let open = suggestionsEnabled && plane != .emoji && plane != .emojiSearch
        let zone = leftZone
        // Ẩn mà chưa từng tạo ⇒ khỏi tạo (dựng lười lần đầu cần hiện).
        let hideBurger = !open || zone == .none
        if burgerZoneMade || !hideBurger { burgerZone.isHidden = hideBurger }
        layoutDismissZone()   // trước guard: dải trống (ô mật khẩu) vẫn có ⌄
        layoutClipboardExtras(stripOpen: open)
        layoutBuddy(stripOpen: open)
        layoutEmojiBarButton()
        guard open, bounds.width > 0 else { stripZonesKey = nil; return }
        let strip = max(rowsTopWanted, openStripNow)
        // layoutSubviews chạy cả khi gõ (shift/balloon) — trạng thái không đổi thì khỏi
        // dựng lại ảnh SF Symbol + insets mỗi lượt.
        let key = StripZonesKey(width: bounds.width, strip: strip, rowTop: barRowTop(strip: strip),
                                templates: templatesActive, ink: palette.barInk,
                                zone: zone, oneHand: oneHand, lastSide: lastOneHandSide)
        guard burgerZoneMade || !hideBurger else { stripZonesKey = nil; return }
        defer { bringSubviewToFront(burgerZone) }
        guard key != stripZonesKey else { return }
        stripZonesKey = key
        let w = Self.stripZoneWidth
        burgerZone.frame = CGRect(x: 0, y: 0, width: w, height: strip)
        let ink = palette.barInk.ui
        burgerZone.setImage(leftZoneImage(pointSize: 13), for: .normal)
        let lit = zone == .oneHand ? oneHand != .off : templatesActive
        burgerZone.tintColor = ink.withAlphaComponent(lit ? 0.9 : 0.45)
        applyLeftZoneAccessibility(burgerZone)
        // Icon canh giữa HÀNG NỘI DUNG bar (cùng tâm chữ gợi ý), không phải cả strip
        // (tâm strip thấp hơn chữ, user 2026-07-25) — barContentInsets.
        burgerZone.contentEdgeInsets = barContentInsets(strip: strip)
    }
    private struct StripZonesKey: Equatable {
        let width: CGFloat, strip: CGFloat, rowTop: CGFloat, templates: Bool, ink: RGBA
        let zone: LeftZone, oneHand: OneHandSide, lastSide: OneHandSide
    }
    private var stripZonesKey: StripZonesKey?

    /// User chỉnh ±10pt/hàng qua Settings (Giao diện); 4 hàng nên tổng đổi 4×. iPhone: so với
    /// bàn phím gốc của máy (0 = như bàn phím iPhone — KeyGeometry.RowAdjust).
    private var rowHeightAdjust: CGFloat = 0
    /// "Nâng bàn phím" (Giao diện, 0…48pt): đệm trống dưới hàng phím đáy — view cao thêm đúng
    /// bấy nhiêu, phím dời lên. Đọc mỗi lần hiện (applyAppearance); 0 = không đổi gì.
    private var keyboardRaise: CGFloat = 0

    /// Hàng phím số 1…0 trên hàng chữ (Settings → Giao diện, mặc định TẮT; khoá
    /// App Group "numberRow"). Nằm trong chữ ký rebuild → đổi là vứt planeCache.
    var numberRowEnabled = false {
        didSet { if numberRowEnabled != oldValue { rebuild() } }
    }
    static let numberRowKey = "numberRow"
    /// Hàng số cao bằng hàng chữ (Giao diện, mặc định TẮT — KeyGeometry.numberRowFullHeightKey):
    /// chỉ đổi tỉ lệ constraint + tổng chiều cao, không tốn gì mỗi lần gõ.
    var numberRowFullHeight = false {
        didSet { if numberRowFullHeight != oldValue { rebuild() } }
    }
    /// "Phím cạnh dấu cách" (Phím & cử chỉ, mặc định "," — SpaceSideKey): phím hẹp bên phải space
    /// bàn chữ iPhone ô thường. Trong chữ ký rebuild; đọc ở applyAppearance, không tốn gì mỗi phím.
    var spaceSideKey: SpaceSideKey = .defaultValue {
        didSet { if spaceSideKey != oldValue { rebuild() } }
    }
    /// "Phím to" (Phím & cử chỉ, mặc định TẮT — LargeKeys): "," "." hàng đáy rộng bằng phím
    /// emoji, ⇧ / ⌫ hàng Z lấp khe. Trong chữ ký rebuild; chỉ đổi constraint lúc dựng hàng.
    var largeKeys = LargeKeys.defaultValue {
        didSet { if largeKeys != oldValue { rebuild() } }
    }
    /// Phím to chỉ áp iPhone (iPad giữ hàng stock).
    private var largeKeysActive: Bool { largeKeys && !Self.isPad }
    /// "Nút emoji" (Phím & cử chỉ, mặc định Hàng dưới — EmojiKeyPlacement). Trong chữ ký rebuild
    /// qua [emojiInBar]; đọc ở applyAppearance, không tốn gì mỗi phím.
    var emojiKeyPlacement: EmojiKeyPlacement = .defaultValue {
        didSet { if emojiKeyPlacement != oldValue { rebuild(); setNeedsLayout() } }
    }
    /// Nút 😊 nằm trên thanh gợi ý thay hàng đáy bàn chữ: chọn Thanh trên + thanh gợi ý bật ở ô
    /// này (không thì giữ 😊 ở hàng đáy — emoji luôn có lối vào) + iPhone.
    var emojiInBar: Bool {
        EmojiKeyPlacement.emojiInBar(emojiKeyPlacement, barShown: suggestionsEnabled, pad: Self.isPad)
    }

    // MARK: giữ phím chữ ra ký tự phụ (KeyAlternates, issue #98)
    private var altNumbersSetting = true
    private var altSymbolsSetting = false
    /// VoiceOver bật ⇒ tắt ký tự phụ (giữ phím là cử chỉ của VoiceOver). Controller đặt.
    var altAccessibility = false {
        didSet { if altAccessibility != oldValue { rebuild() } }
    }
    /// Bảng ký tự phụ của lần dựng hiện tại (rỗng ⇒ không nhãn, không hẹn giờ).
    private var activeAlts: [Character: String] = [:]
    private var builtAlts: [Character: String] = [:]
    /// iPad: đúng nhãn ký tự phụ trên phím (KeyAlternates.padMap) — giữ = vuốt xuống.
    private func currentAlts() -> [Character: String] {
        if Self.isPad { return KeyAlternates.padMap() }
        return KeyAlternates.map(numbers: altNumbersSetting, symbols: altSymbolsSetting,
                          numberRow: numberRowEnabled, isPad: Self.isPad, accessibility: altAccessibility)
    }
    func configureKeyAlternates(numbers: Bool, symbols: Bool, holdShift: Bool = true, flickDown: Bool = false) {
        holdShiftSetting = holdShift
        flickDownSetting = flickDown
        shiftAlts = currentShiftAlts()
        guard numbers != altNumbersSetting || symbols != altSymbolsSetting else { return }
        altNumbersSetting = numbers; altSymbolsSetting = symbols
        rebuild()
    }

    // MARK: giữ ⇧ + phím chữ ra ký tự phụ (ShiftHold) — "Giữ Shift để gõ số và ký hiệu"
    private var holdShiftSetting = true
    /// Bảng giữ ⇧ (rỗng ⇒ tắt / iPad / VoiceOver: hành vi cũ). Đặt lại mỗi rebuild.
    private var shiftAlts: [Character: String] = [:]
    private var shiftHold = ShiftHold()
    /// true trong lúc gửi ký tự phụ của giữ ⇧ ⇒ controller chèn NGUYÊN VĂN (VNI không bỏ dấu).
    private(set) var literalTextInFlight = false
    private func currentShiftAlts() -> [Character: String] {
        KeyAlternates.shiftMap(enabled: holdShiftSetting, numbers: altNumbersSetting,
                               symbols: altSymbolsSetting, numberRow: numberRowEnabled,
                               isPad: Self.isPad, accessibility: altAccessibility)
    }
    private func shiftDown(now: TimeInterval) {
        shift = Self.fromCase(shiftHold.down(Self.toCase(shift), now: now))
        shiftByHand = shift == .on
        shiftTouchedByHand = true
        applyShiftAppearance()
    }
    /// Người dùng đã chạm ⇧ (bật HOẶC tắt) kể từ lần auto-shift gần nhất — controller dùng để
    /// không cho tiếng vọng host tới trễ đè lựa chọn tay (FieldPolicy.hostEchoKeepsHandShift).
    private(set) var shiftTouchedByHand = false
    /// Shift một-lần đang bật DO NGƯỜI DÙNG chạm ⇧ (không phải viết hoa đầu câu tự động —
    /// tự động thì Return phải gửi như cũ, kẻo "Chào. ⏎" thành xuống dòng).
    private var shiftByHand = false
    private func shiftUp() {
        let s = Self.fromCase(shiftHold.up(Self.toCase(shift)))
        if s != shift { shift = s; applyShiftAppearance() }
    }
    private static func toCase(_ s: ShiftState) -> SuggestionCase.Shift {
        switch s { case .off: return .off; case .on: return .once; case .caps: return .capsLock }
    }
    private static func fromCase(_ s: SuggestionCase.Shift) -> ShiftState {
        switch s { case .off: return .off; case .once: return .on; case .capsLock: return .caps }
    }
    /// Phím chữ `b` chạm lúc `time` khi đang giữ ⇧: ký tự phụ phải gõ thay chữ (nil ⇒ chữ như cũ).
    private func shiftSymbol(for b: KeyButton, time: TimeInterval) -> String? {
        // Nút ⇧ bị gỡ (rebuild) giữa lúc giữ thì không có touchUp: ⇧ phải thật sự đang bị đè.
        guard shiftKeyTracking else { shiftHold.cancel(); return nil }
        guard let base = letterKeys.first(where: { $0.button === b })?.base.first else { return nil }
        return shiftHold.symbol(base, map: shiftAlts, now: time)
    }
    private var shiftKeyTracking: Bool {
        #if DEBUG
        if let t = debugShiftTrackingOverride { return t }
        #endif
        return shiftKeys.contains { $0.isTracking }
    }
    #if DEBUG
    /// Test: giả lập ngón đang đè ⇧ (UIControl.isTracking không bật khi gọi sendActions).
    var debugShiftTrackingOverride: Bool?
    #endif
    /// Gõ ký tự phụ của giữ ⇧ trên phím `b` (thay cho action chữ của nút).
    private func typeShiftSymbol(_ sym: String, on b: KeyButton) {
        Self.clickLetter()
        showBalloon(over: b, text: sym)
        fxMark(b)
        literalTextInFlight = true
        tapped(.text(sym))
        literalTextInFlight = false
    }
    /// Có phím nào ra ký tự phụ không — controller bật checkpoint huỷ phím chữ theo cờ này.
    var altHoldActive: Bool { !currentAlts().isEmpty }
    /// "Vuốt phím xuống ra ký tự phụ" (iPhone) — KeyAlternates.flickDownEnabled.
    private var flickDownSetting = false
    private var flickDownActive: Bool {
        flickDownSetting && KeyAlternates.flickDownEnabled(setting: true, swipeTyping: swipeEnabled,
                                                           isPad: Self.isPad, alternates: activeAlts)
    }
    /// Cùng công tắc: phím hàng chữ trên cùng vuốt thẳng LÊN ra ký tự phụ — cả khi gõ vuốt bật.
    private var flickUpActive: Bool {
        flickDownSetting && KeyAlternates.flickUpEnabled(setting: true, isPad: Self.isPad, alternates: activeAlts)
    }
    private var altHold: (id: ObjectIdentifier, button: KeyButton, hold: KeyAlternates.Hold)?
    private var altTimer: DispatchWorkItem?

    /// iPhone 216pt dọc / 162pt ngang; iPad 240/300 — GỌN hơn stock (264/352)
    /// theo ý user 2026-07-24, phím vẫn rộng thoải mái nhờ bề ngang iPad.
    /// Tổng key area = base + rowHeightAdjust × 4 hàng — heightConstraint và
    /// rowsContainer cùng đi qua đây nên tổng luôn khớp từng hàng.
    private var landscapeCache: (size: CGSize, landscape: Bool)?
    /// Bề ngang + màn hình ĐOÁN cho lúc CHƯA layout (bounds 0) — controller đặt ở viewWillAppear
    /// trước khi cấu hình. Chiều cao xin host lúc đó phải là chiều cao cuối (KeyLayout.layoutWidth:
    /// Zalo chỉ dùng chiều cao đầu). Đã layout thì bề ngang thật thắng.
    struct LayoutHint: Equatable {
        var width: CGFloat
        var screen: CGSize?
    }
    var layoutHint: LayoutHint? {
        didSet { if layoutHint != oldValue { phoneFormCache = nil; landscapeCache = nil } }
    }
    /// Bề ngang cho hình học / chiều cao: bounds thật, chưa layout thì layoutHint.
    private var layoutWidth: CGFloat { KeyLayout.layoutWidth(bounds: bounds.width, hint: layoutHint?.width) }
    private var isLandscapeNow: Bool {
        // iPhone: theo bề ngang (KeyLayout.isPhoneLandscape) — orientation scene extension
        // có lúc lệch host ⇒ xin chiều cao ngang 162pt khi đang dọc (phím lùn ngẫu nhiên).
        // Máy gập mở (.unfolded) cũng dùng hình học "ngang": không cắt hàng đáy, khe trên 10.
        if !Self.isPad, layoutWidth > 0 { return phoneForm != .portrait }
        // interfaceOrientation chép cả bộ scene settings mỗi lần đọc; xoay/Split View luôn
        // đổi bounds ⇒ cache theo kích thước (chỉ khi đã gắn window).
        if let c = landscapeCache, c.size == bounds.size, window != nil { return c.landscape }
        if let o = window?.windowScene?.interfaceOrientation {
            landscapeCache = (bounds.size, o.isLandscape)
            return o.isLandscape
        }
        return UIDevice.current.userInterfaceIdiom == .phone && layoutWidth > 500
    }
    /// Dạng bàn phím iPhone (KeyLayout.phoneForm) — cache theo kích thước view: đọc màn hình
    /// + trait chỉ khi bounds đổi (xoay / gập-mở), không phải mỗi lần tính chiều cao.
    private var phoneFormCache: (size: CGSize, form: KeyLayout.PhoneForm)?
    private var phoneForm: KeyLayout.PhoneForm {
        if let c = phoneFormCache, c.size == bounds.size { return c.form }
        let t = traitCollection
        var screen = window?.windowScene?.screen.bounds.size ?? layoutHint?.screen
        #if DEBUG
        if let s = debugScreenSize { screen = s }
        #endif
        let f = KeyLayout.phoneForm(viewWidth: layoutWidth, screenSize: screen,
                                    regularBoth: t.horizontalSizeClass == .regular && t.verticalSizeClass == .regular)
        // Chỉ cache khi đã có bề ngang thật (bounds 0 = đang dùng hint, rẻ, không cache).
        if window != nil, bounds.width > 0 { phoneFormCache = (bounds.size, f) }
        return f
    }
    /// Safe area đáy hàng phím phải tránh (KeyLayout.keyboardSafeBottom): 0 trên iPhone thường
    /// / iPad; vạch home trên máy gập mở. Cập nhật ở safeAreaInsetsDidChange.
    private var safeBottom: CGFloat = 0
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        syncSafeBottom()
    }
    /// Gọi cả ở layoutSubviews: xoay / gập-mở máy gập lúc bàn phím đang hiện có khi đổi safe
    /// area mà không qua safeAreaInsetsDidChange của view này (một phép so sánh mỗi lượt).
    private func syncSafeBottom() {
        var v = safeAreaInsets.bottom
        #if DEBUG
        if let o = debugSafeOverride { v = o }
        #endif
        let s = KeyLayout.keyboardSafeBottom(pad: Self.isPad, viewSafeBottom: v)
        if s != safeBottom { safeBottom = s; updateSuggestionChrome() }
    }
    /// Đáy hàng phím cách đáy view: safe area (máy gập mở) + "Nâng bàn phím".
    private var bottomInset: CGFloat { safeBottom + keyboardRaise }
    /// Hình học hàng phím hiện tại (KeyGeometry.RowSpec): iPhone = số đo bàn phím gốc + chỉnh
    /// tay ±pt mỗi hàng; iPad / máy gập mở = bố cục VietTelex + chỉnh tay. Thuần + rẻ
    /// (phoneForm cache theo bounds) — gọi được trên đường layout.
    var rowSpec: KeyGeometry.RowSpec {
        let pad = Self.isPad
        let landscape = isLandscapeNow
        let width = layoutWidth
        let form: KeyLayout.PhoneForm? = (!pad && width > 0) ? phoneForm : nil
        let base: CGFloat
        if pad {
            base = landscape ? 300 : 240
        } else {
            // 216 → 218 (25/09/2026): phím nhỉnh hơn chút; 224 làm cả bàn phím cao
            // hơn stock (user) — phần dư của stock nằm ở vùng đáy, không phải hàng phím.
            // 218 → 216 − 4 (27/09/2026, đo stock iOS 26/27 — KeyGeometry): bước hàng 54
            // như stock, hàng đáy vùng 50 → 3 hàng chữ trùng vị trí stock tính từ đáy.
            // Máy gập mở: 208 (KeyLayout.phoneKeyAreaBase) thay 162 "ngang" — phím lùn.
            // 12/10/2026: iPhone thường dùng số đo stock (KeyGeometry.rowSpec bỏ qua base).
            base = form.map(KeyLayout.phoneKeyAreaBase) ?? (landscape ? 162 : KeyGeometry.phonePortraitBase)
        }
        return KeyGeometry.rowSpec(pad: pad, landscape: landscape, unfolded: form == .unfolded,
                                   width: width, base: base, adjust: rowHeightAdjust,
                                   homeButton: !pad && needsGlobe)
    }
    /// iPhone dọc: hàng đáy thấp hơn 4pt để 3 hàng chữ nằm đúng chỗ stock (KeyGeometry).
    private var bottomTrim: CGFloat { rowSpec.bottomTrim }
    private func keyAreaHeight() -> CGFloat {
        rowSpec.keyArea(numberRow: numberRowEnabled, fullHeight: numberRowFullHeight)
    }
    /// Chiều cao một hàng phím chuẩn (hàng số: KeyLayout.numberRowHeight).
    private func rowUnitHeight() -> CGFloat { rowSpec.unit }
    /// Lề / khe ngang theo hình học hiện tại (preset ngang: lề 4.33, khe 6.67 như stock).
    private var sideMarginNow: CGFloat { rowSpec.sideMargin }
    private var keyGapNow: CGFloat { rowSpec.keyGap }

    #if DEBUG
    func debugSetRowAdjust(_ a: Int) {
        rowHeightAdjust = CGFloat(KeyGeometry.RowAdjust.clamp(a))
        lastLayoutWidth = -1; setNeedsLayout(); rebuild()
    }
    func debugSetRaise(_ r: Int) {
        keyboardRaise = CGFloat(KeyGeometry.RowAdjust.clampRaise(r))
        updateSuggestionChrome(); setNeedsLayout()
    }
    /// Test hook "Chiều cao thanh gợi ý" (như applyAppearance đọc từ App Group).
    func debugSetBarHeight(_ h: SuggestionBarHeight) {
        barHeight = h
        updateSuggestionChrome(); setNeedsLayout()
    }
    var debugOpenStrip: CGFloat { openStripNow }
    var debugBarRow: CGFloat { barRowNow }
    var debugSlotFontSize: CGFloat { slotFont.pointSize }
    /// Vùng chạm ô gợi ý đầu (toạ độ view) — bar + hitInsets.
    var debugSlotHitRect: CGRect {
        guard let b = slotButtons.first else { return .zero }
        return convert(b.bounds.inset(by: b.hitInsets ?? .zero), from: b)
    }
    #endif
    /// Strip gợi ý mở: iPhone = khoảng từ mép trên tới phím như thanh dự đoán stock (dọc 29:
    /// 29 + khe 11 = 40 ≈ stock 39.7–40); mặc định 34.
    private var openStripNow: CGFloat {
        let spec = rowSpec
        let base = spec.stock
            ? KeyGeometry.StockSize.openStrip(width: layoutWidth, landscape: isLandscapeNow,
                                              homeButton: needsGlobe) ?? Self.openStrip
            : Self.openStrip
        return base + barHeight.delta(landscape: barLandscapeCap)
    }
    /// "Chiều cao thanh gợi ý" (SuggestionBarHeight, mặc định Vừa) — đọc mỗi lần hiện (applyAppearance).
    private var barHeight = SuggestionBarHeight.defaultValue
    /// iPhone xoay ngang: mức Cao kẹp về Vừa (màn thấp). Máy gập mở / iPad: không kẹp.
    private var barLandscapeCap: Bool { !Self.isPad && layoutWidth > 0 && phoneForm == .landscape }
    /// Hàng nội dung bar (chữ gợi ý + icon ☰/📋/😊): 20 ở mức Thấp, + delta ở Vừa/Cao.
    private var barRowNow: CGFloat { barHeight.rowHeight(landscape: barLandscapeCap) }
    /// Headroom balloon phía trên hàng đầu (KeyLayout.headroom): chỉ chừa khi có thứ cần vẽ
    /// lên trên phím (ô phóng to / giữ phím ra ký tự phụ). Tắt cả hai ⇒ gợi ý tắt không còn
    /// dải trống 20pt (#119 "thừa khoảng trắng khi đã tắt các chức năng bổ trợ").
    private var headroomNow: CGFloat {
        KeyLayout.headroom(needsBalloon: keyPreviewEnabled || !activeAlts.isEmpty)
    }

    // Gắn vào window mới biết interfaceOrientation thật — ép layout lại để
    // chiều cao đúng ngay pass đầu (và sau khi host xoay lúc keyboard ẩn).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        landscapeCache = nil; phoneFormCache = nil
        if window != nil { lastLayoutWidth = -1; setNeedsLayout(); Self.releaseSystemTouchDelays(for: self) }
    }

    /// Phím sát mép trái/phải (q a p l ⇧ ⌫ …) ăn chậm khi bấm/giữ: window extension có
    /// recognizer cổng cử chỉ hệ thống (_UISystemGestureGateGestureRecognizer…) với
    /// delaysTouchesBegan = true — gần mép màn hình iOS giữ touchesBegan ~0.3–1s để phân xử
    /// vuốt hệ thống, phím giữa thì không. Tắt trì hoãn trên recognizer của window + chuỗi
    /// superview (KHÔNG cancel, không đổi việc nhận diện — chỉ giao touch ngay). Chạy 1 lần
    /// mỗi lần gắn window (didMoveToWindow + viewDidAppear), vài recognizer, 0 việc mỗi phím.
    /// Trả số recognizer đã đổi (test / log).
    @discardableResult
    static func releaseSystemTouchDelays(for view: UIView) -> Int {
        var all: [UIGestureRecognizer] = []
        var v: UIView? = view.superview
        while let cur = v { all += cur.gestureRecognizers ?? []; v = cur.superview }
        if let w = view.window, w !== view.superview { all += w.gestureRecognizers ?? [] }
        return releaseTouchDelays(all)
    }

    /// Hàm thuần: tắt delaysTouchesBegan/Ended của từng recognizer; trả số cái đã đổi.
    @discardableResult
    static func releaseTouchDelays(_ recognizers: [UIGestureRecognizer]) -> Int {
        var changed = 0
        for g in recognizers where g.delaysTouchesBegan || g.delaysTouchesEnded {
            g.delaysTouchesBegan = false
            g.delaysTouchesEnded = false
            changed += 1
        }
        return changed
    }

    private var chromeMode: KeyLayout.ChromeMode {
        switch plane {
        case .emoji: return .emoji
        case .emojiSearch: return .emojiSearch
        default: return .keys
        }
    }

    /// Strip gợi ý chỉ hiện khi bật VÀ đang ở plane chữ/số — trong emoji plane
    /// ẩn đi cho gọn (user 2026-07-24). strip 30pt sát nút; phần dưới hàng
    /// phím cuối là vùng globe/mic hệ thống, không thuộc view mình.
    private func updateSuggestionChrome() {
        let visible = suggestionsEnabled && plane != .emoji && plane != .emojiSearch
        // Strip mở (bar 20pt + đệm trên) / 0 tắt. Plane emoji GIỮ NGUYÊN
        // chiều cao strip (chỉ ẩn bar): đổi chiều cao bàn phím khi vào emoji làm host
        // relayout dở dang — dải trống + vạch đè hàng emoji đầu (Telegram, 25/09/2026).
        let strip = KeyLayout.stripHeight(reserved: stripReserved, open: openStripNow)
        // Lưới emoji chiếm luôn dải strip (thanh tìm nằm đúng chỗ thanh gợi ý như stock):
        // chỉ dời vùng hàng phím, tổng chiều cao GIỮ NGUYÊN → host không relayout.
        // Tìm emoji: ô tìm thế chỗ strip, phím chữ giữ đủ keyArea (KeyLayout.chrome).
        let spec = rowSpec
        let headroom = headroomNow
        let c = KeyLayout.chrome(keyArea: spec.keyArea(numberRow: numberRowEnabled, fullHeight: numberRowFullHeight),
                                 strip: strip, mode: chromeMode, headroom: headroom)
        if rowsTopWanted != c.rowsTop { rowsTopWanted = c.rowsTop; setNeedsLayout() }
        // Một nguồn (KeyLayout.requestedHeight). Lúc viewWillAppear (bounds 0) rowSpec dùng
        // layoutHint ⇒ chiều cao này đã là chiều cao cuối — host đo ở đây.
        baseRequestedHeight = KeyLayout.requestedHeight(spec: spec, numberRow: numberRowEnabled,
                                                        numberRowFullHeight: numberRowFullHeight,
                                                        strip: strip, headroom: headroom, mode: chromeMode,
                                                        bottomInset: bottomInset)
        applyHeightConstant()
        if rowsBottomGap != bottomInset || rowsHeightWanted != c.rows || rowsMinTop != c.minTop {
            rowsBottomGap = bottomInset; rowsHeightWanted = c.rows; rowsMinTop = c.minTop
            setNeedsLayout()
        }
        if rowsContainer.headerHeight != nil { rowsContainer.headerHeight = KeyLayout.emojiSearchBarHeight(strip: strip) }
        suggestionBar.isHidden = !visible
        suggestionBar.alpha = 1
        if !visible { if pasteCardMade { pasteCard.isHidden = true }; notePasteOffer(false) }   // emoji plane
        lastSuggestionSig = nil   // chrome đổi → lượt show kế ghi lại (kể cả thẻ Dán)
        if visible { buildSuggestionPoolIfNeeded() }
        refreshBarFonts()
        refreshBarHitInsets()
        layoutEmojiBarButton()   // 😊 Thanh trên: ẩn/hiện theo plane ngay (không đợi layoutSubviews)
    }

    // Rotation / Split View: indent hàng 2 và chiều cao tính theo bounds THẬT,
    // không dùng UIScreen.main (deprecated, sai trong Split View).
    private var lastLayoutWidth: CGFloat = 0
    #if DEBUG
    /// Chẩn đoán (KeyboardRenderBudgetTests): != nil ⇒ ghi call stack mỗi lần layer của
    /// KeyboardView bị đánh dấu cần layout (cả từ UIKit/CA, vd sublayer đổi cỡ). Chỉ DEBUG.
    static var debugNeedsLayoutLog: [String]?
    final class TraceLayer: CALayer {
        override func setNeedsLayout() {
            if KeyboardView.debugNeedsLayoutLog != nil { KeyboardView.debugNeedsLayoutLog!.append(Thread.callStackSymbols.prefix(12).joined(separator: "\n")) }
            super.setNeedsLayout()
        }
    }
    override class var layerClass: AnyClass { TraceLayer.self }
    #endif
    override func layoutSubviews() {
        #if DEBUG
        Self.perfLayoutPasses += 1
        #endif
        inLayoutPass = true
        defer { inLayoutPass = false }
        StartupTrace.span("kv.layout") { layoutSubviewsBody() }
    }
    private func layoutSubviewsBody() {
        if initialBuildPending, !rebuildDeferred, !isTornDown, snapState != .armed { rebuild() }
        if Self.isPad { KeyButton.padLandscape = isLandscapeNow }   // phím tự áp cỡ chữ theo hướng
        super.layoutSubviews()
        letterGeometryCache = nil
        syncSafeBottom()
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            updateSuggestionChrome()
            // Tách đôi (chỉ khi công tắc bật): xoay / gập-mở đổi bề ngang ⇒ dựng lại theo bề
            // ngang mới (vào/ra kiểu tách, bề rộng phím). Công tắc tắt: không làm gì.
            if splitSetting, splitMode || builtSplit { rebuild() }
            // Preset stock: xoay đổi khe/lề (dọc 11/6/6.67 ↔ ngang 8/6.67/4.33) ⇒ dựng lại.
            else if builtGeom != nil, builtGeom != geomSig { rebuild() }
        }
        applyOversizeShift()
        syncKeyEffectsSpace()
        applyOneHand()
        layoutRowsArea()
        if snapState == .armed || snapState == .showing { layoutSnapshot() }   // khung vùng phím đã biết
        if let r = indentedRow {
            // Thụt theo bề ngang VÙNG PHÍM (một tay: hẹp hơn view) — hàng 2 đúng nửa phím.
            let inset = KeyGeometry.indentedMargin(width: keysWidth, margin: sideMarginNow,
                                                   gap: keyGapNow, units: indentedRowInset)
            if r.margins.left != inset {
                r.margins = UIEdgeInsets(top: rowSpec.gap, left: inset, bottom: 0, right: inset)
            }
        }
        applyBottomTrim()
        if plane == .keypad { applyKeypadMetrics() }
        layoutSuggestionBar()
        layoutStripZones()
        layoutOverlayPanel()
        layoutBackdrop()
        if balloonMade { balloonHost.shareCoordinateSpace(with: self) }
        mole?.shareCoordinateSpace(with: self)
        spotlight?.shareCoordinateSpace(with: self)
        StartupTrace.span("kv.wallpaper+screens") {
            loadWallpaperIfNeeded()
            loadThemeScreensIfNeeded()
        }
        logGeometryIfChanged()
        if pasteCardMade, pasteCard.superview != nil, !pasteCard.isHidden {   // xoay màn hình
            let w = Self.stripZoneWidth
            let clipW = barRightExtras   // chừa nút 📋 / 😊
            pasteCard.frame = CGRect(x: w, y: Self.barTopPad, width: max(bounds.width - w - clipW, 0),
                                     height: openStripNow - Self.barTopPad)
        }
    }

    /// Phần host cấp dư nằm trên thanh gợi ý (#151, KeyRowLayout.oversizeShift): gốc bounds dời
    /// lên đúng phần đó ⇒ mọi khung tính từ đỉnh (strip, buddy, gợi ý) nằm sát hàng phím; nền
    /// (khung = bounds) phủ cả phần dư. 0 = bình thường.
    private(set) var oversizeShift: CGFloat = 0
    /// Chiều cao dùng để xếp (bounds trừ phần dư nằm trên thanh gợi ý).
    private var layoutHeight: CGFloat { bounds.height - oversizeShift }
    private func applyOversizeShift() {
        let k = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        let s = KeyRowLayout.oversizeShift(viewHeight: bounds.height, requested: requestedHeight + heightNudge, scale: k)
        oversizeShift = s
        if bounds.origin.y != -s { bounds.origin.y = -s }
    }

    /// Khung vùng hàng phím (thay các constraint rows↔view cũ): thang ưu tiên tính tay
    /// (KeyRowLayout.rowsArea), mép làm tròn pixel như Auto Layout; lưới xếp hàng theo toạ độ
    /// chính xác để mép từng phím cũng làm tròn y như trước.
    private func layoutRowsArea() {
        let a = KeyRowLayout.rowsArea(viewHeight: layoutHeight, bottomInset: rowsBottomGap, top: rowsTopWanted,
                                      rows: rowsHeightWanted, minTop: rowsMinTop)
        let exact = CGRect(x: rowsSideInsets.left, y: a.top,
                           width: max(bounds.width - rowsSideInsets.left - rowsSideInsets.right, 0), height: a.height)
        let k = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        let f = KeyRowLayout.rounded(x0: exact.minX, x1: exact.maxX, y0: exact.minY, y1: exact.maxY, scale: k)
        if rowsContainer.exactFrame != exact { rowsContainer.exactFrame = exact; rowsContainer.setNeedsLayout() }
        if rowsContainer.frame != f { rowsContainer.frame = f }
    }

    /// Cập nhật gợi ý theo layout stock: ["nguyên văn"] | từ gợi ý | emoji(≤3),
    /// ngăn cách bằng divider mảnh. Mảng rỗng → dọn bar.
    struct SuggestionSet {
        var literal: String? = nil
        var word: String? = nil
        var word2: String? = nil       // ứng viên inline thứ hai (khi không có emoji)
        /// Ứng viên inline thứ 3, 4… (chỉ khi "Số từ gợi ý" > 3 — SuggestionCount).
        var moreWords: [String] = []
        var emojis: [String] = []
        var nextWords: [String] = []   // gợi ý khi CHƯA gõ (đầu câu / sau space)
        var paste = false               // thẻ Dán thay bar (vừa copy, xem controller)
        var pasteIsImage = false        // clipboard là ẢNH: bàn phím không chèn được → chỉ hướng dẫn
        var restoreLabel: String? = nil // ô "Khôi phục" sau vuốt ⌫ xoá theo từ (slot đầu)
        var restorePayload: String? = nil // payload ô restoreLabel (nil = restoreToken; toolUndoToken = hoàn tác công cụ văn bản)
        var number: String? = nil       // chip số (NumberChips) — luôn ở slot GIỮA, payload numberToken
        var math: String? = nil         // kết quả phép tính "…=" (MathResults) — slot ĐẦU, payload mathToken
        /// Chip tách số từ nội dung vừa copy ("Dán STK 0123…") — thay thẻ Dán.
        var clipChips: [(display: String, insert: String)] = []
        var actionLabel: String? = nil  // chip hành động slot đầu ("Thêm dấu" / "Hoàn tác")…
        var actionPayload: String? = nil // …và payload (addTonesToken / undoTonesToken)
        /// ONBOARDING-SPEC §8: từ đang soạn gõ sai và `word` là bản tự sửa đủ chắc — ô `word` tô nền
        /// (dấu cách sẽ thay đúng chữ này khi "Tự sửa từ gõ sai" bật); chạm ô nguyên văn gửi
        /// `keepTypedPrefix` + chữ gốc (giữ nguyên + không sửa lại). CorrectionHint.apply đặt.
        var correction = false
        var isEmpty: Bool {
            literal == nil && word == nil && word2 == nil && moreWords.isEmpty && emojis.isEmpty && nextWords.isEmpty
                && number == nil && math == nil
        }
    }

    // Pool cố định: 3 nút chính + 2 vạch ngăn + 3 nút emoji con. Mỗi keystroke
    // CHỈ đổi title/hidden của ô nào khác — không removeFromSuperview/addSubview.
    private var slotButtons: [KeyButton] { suggestionBar.slots }
    private var emojiButtons: [KeyButton] { suggestionBar.emojis }
    private var slotDividers: [UIView] { suggestionBar.dividers }
    /// Cỡ chữ ô gợi ý / chip theo "Chiều cao thanh gợi ý" (17/18/19, chip 14/15) — instance
    /// cố định (setText so ===), chỉ đổi khi mức đổi (refreshBarFonts, lúc dựng chrome).
    private var slotFont = UIFont.systemFont(ofSize: 17, weight: .regular)
    private var chipFont = UIFont.systemFont(ofSize: 14, weight: .regular)
    private func refreshBarFonts() {
        let cap = barLandscapeCap
        let s = barHeight.slotFontSize(landscape: cap), c = barHeight.chipFontSize(landscape: cap)
        // Phông điểm ảnh (theme Pixel 8-bit) cả trên thanh gợi ý; phông khác: thanh giữ phông hệ thống như cũ.
        let pixel = Self.labelFonts.font == .pixel && Self.labelFonts.custom == nil
        func make(_ size: CGFloat) -> UIFont {
            pixel ? KeyLabelFonts.make(.pixel, .regular, size: size, compact: nil) : .systemFont(ofSize: size, weight: .regular)
        }
        if slotFont.pointSize != s || barPixelFont != pixel { slotFont = make(s) }
        if chipFont.pointSize != c || barPixelFont != pixel { chipFont = make(c) }
        barPixelFont = pixel
    }
    private var barPixelFont = false
    private var barInkApplied: UIColor?
    private var barLabelInkApplied: UIColor?
    /// "Màu chữ gợi ý" (SuggestionInk, mặc định Xám) — đọc mỗi lần hiện (applyAppearance).
    private var suggestionInk = SuggestionInk.defaultValue
    private var barWired = false

    /// Thanh gợi ý theo KHUNG CỐ ĐỊNH (27/09/2026): `slotCount` ô bằng nhau (cài đặt "Số từ
    /// gợi ý" — SuggestionCount; Tự động = 3), vạch ngăn ở mép giữa các ô, emoji chia đều ô
    /// cuối. Pool cố định 5 ô (SuggestionCount.max) tạo một lần; ô ngoài slotCount ẩn. Frame chỉ tính lại khi bề rộng bar / số emoji đổi — mỗi
    /// phím chỉ đổi chữ. Trước: UIStackView + ô Auto Layout, setTitle đổi intrinsic size
    /// ⇒ giải constraint + layout lại cả KeyboardView mỗi phím (~1.8 ms main/phím, bench B).
    private final class SuggestionBar: UIView {
        static let poolSize = SuggestionCount.max
        let slots: [KeyButton]
        /// Chữ slot: UILabel riêng phủ trọn nút (không setTitle) — UIButton dò lại rect
        /// title/ảnh mỗi lần đổi chữ (~¼ thời gian layout+vẽ bar, Time Profiler 27/09).
        let labels: [UILabel]
        let emojis: [KeyButton]
        let dividers: [UIView]
        /// Nền ô tô nền (ONBOARDING-SPEC §8) — nằm dưới các ô, không nhận chạm.
        let pill = UIView()
        private(set) var pillIndex: Int?
        private(set) var cellFrames: [CGRect] = []
        private var laidOut: CGSize = .zero
        private var emojiCount = 0
        /// "Số từ gợi ý" (0 = Tự động) — đổi ⇒ tính lại số ô.
        var setting = SuggestionCount.auto {
            didSet { if setting != oldValue { relayout() } }
        }
        /// Số ô đang dùng = SuggestionCount.fit(setting, bề rộng bar): bar chật (ô < 44pt) ⇒ bớt ô.
        private(set) var slotCount = SuggestionCount.autoSlots
        /// Số ô đổi (bề rộng / cài đặt) ⇒ view vẽ lại nội dung theo số ô mới.
        var onSlotCountChange: (() -> Void)?
        /// Chip clipboard (1–3): CHIA ĐỀU bar như Android/Gboard; 0 = 3 ô cố định. Trước đây
        /// [Dán SĐT…][Dán] nằm trong 2/3 ô, ô 3 trống ⇒ thanh gợi ý trông "ngắn 1 đoạn"
        /// (Hữu Đông 28/09/2026).
        private(set) var chipCount = 0
        /// Hit-area nở của slot (âm = rộng hơn bar): bar 20pt, nút ăn cả phần strip còn lại.
        var hitInsets: UIEdgeInsets = .zero

        init(makeSlot: () -> KeyButton) {
            slots = (0..<Self.poolSize).map { _ in makeSlot() }
            labels = (0..<Self.poolSize).map { _ in UILabel() }
            emojis = (0..<3).map { _ in makeSlot() }
            dividers = (0..<(Self.poolSize - 1)).map { _ in UIView() }
            super.init(frame: .zero)
            pill.isUserInteractionEnabled = false
            pill.isHidden = true
            pill.layer.cornerCurve = .continuous
            addSubview(pill)
            for (b, l) in zip(slots, labels) {
                l.textAlignment = .center
                l.lineBreakMode = .byTruncatingMiddle   // như titleLabel UIButton cũ
                l.minimumScaleFactor = 0.7              // ô cố định: chữ dài co lại, không nở ô
                l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                b.addSubview(l)
                addSubview(b)
            }
            for b in emojis {
                b.titleFont = .systemFont(ofSize: 20)   // vừa content box 22pt
                b.isHidden = true
                addSubview(b)
            }
            for d in dividers { d.isUserInteractionEnabled = false; addSubview(d) }
        }
        convenience init() { self.init(makeSlot: { KeyButton() }) }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != laidOut else { return }
            laidOut = bounds.size
            relayout()
        }

        /// Chỉ khi bề rộng bar / cài đặt đổi.
        private func relayout() {
            let n = SuggestionCount.fit(setting, barWidth: bounds.width)
            let changed = n != slotCount
            slotCount = n
            let w = bounds.width / CGFloat(n), h = bounds.height
            cellFrames = (0..<n).map { CGRect(x: CGFloat($0) * w, y: 0, width: w, height: h) }
            layoutSlots()
            layoutEmojis()
            if changed { onSlotCountChange?() }
        }

        /// Chỉ chạy khi bề rộng bar / số chip đổi — mỗi phím không đụng frame.
        func setChipCount(_ n: Int) {
            let n = min(max(n, 0), 3)
            guard n != chipCount else { return }
            chipCount = n
            layoutSlots()
        }
        private func layoutSlots() {
            guard !cellFrames.isEmpty else { return }
            let n = chipCount > 0 ? chipCount : slotCount
            let cw = bounds.width / CGFloat(n), h = bounds.height
            for (i, b) in slots.enumerated() {
                let cell = i < n ? CGRect(x: CGFloat(i) * cw, y: 0, width: cw, height: h)
                    : i < cellFrames.count ? cellFrames[i] : .zero
                b.frame = cell == .zero ? .zero : cell.insetBy(dx: 3, dy: 0)
                labels[i].frame = b.bounds
                Self.fitShrink(labels[i])
            }
            for (i, d) in dividers.enumerated() {
                let x = i + 1 < n ? CGFloat(i + 1) * cw : i < cellFrames.count ? cellFrames[i].maxX : 0
                d.frame = CGRect(x: x - 0.5, y: 4, width: 1, height: max(h - 8, 0))
            }
            layoutPill()
        }

        /// Ô tô nền `i` (nil = gỡ). Chỉ đổi frame khi ô đổi.
        func setPill(_ i: Int?) {
            guard i != pillIndex else { return }
            pillIndex = i
            layoutPill()
        }
        private func layoutPill() {
            guard let i = pillIndex, i < slots.count, slots[i].frame != .zero else { pill.isHidden = true; return }
            // Cao hơn chữ một chút (ô 20pt), bo tròn như phím.
            let f = slots[i].frame.insetBy(dx: 1, dy: -3)
            pill.frame = f
            pill.layer.cornerRadius = min(8, f.height / 2)
            pill.isHidden = false
        }
        /// Số vạch ngăn dùng được ở chế độ hiện tại (chip: giữa các chip).
        var usableDividers: Int { (chipCount > 0 ? chipCount : slotCount) - 1 }
        /// Số ô có thể đang hiện (ô thường hoặc chip clipboard).
        var shownCells: Int { max(slotCount, chipCount) }

        /// Emoji hiện chia đều ô 3 (như stack fillEqually cũ: 1 emoji = cả ô).
        func setEmojiCount(_ n: Int) {
            guard n != emojiCount else { return }
            emojiCount = n
            layoutEmojis()
        }
        private func layoutEmojis() {
            guard let c = cellFrames.last, emojiCount > 0 else { return }
            let ew = c.width / CGFloat(emojiCount)
            for (i, b) in emojis.enumerated() where i < emojiCount {
                b.frame = CGRect(x: c.minX + CGFloat(i) * ew, y: 0, width: ew, height: c.height)
                if let v = emojiImages[i] { v.frame = emojiImageFrame(in: b.bounds) }
            }
        }

        /// Ảnh emoji (atlas — SuggestionEmojiTiles) trong ô emoji `i`: tạo lười lần đầu có ảnh, cạnh
        /// cố định = glyph chữ cùng cỡ, căn giữa ô (khung chỉ tính lại khi ô / cạnh đổi — mỗi phím chỉ
        /// đổi `image`). Ô giữ nguyên kích thước dù ảnh hay chữ.
        private(set) var emojiImages: [UIImageView?] = [nil, nil, nil]
        private var emojiImageSide: CGFloat = 0
        func emojiImageView(_ i: Int, side: CGFloat) -> UIImageView {
            if side != emojiImageSide {
                emojiImageSide = side
                for (j, v) in emojiImages.enumerated() { v?.frame = emojiImageFrame(in: emojis[j].bounds) }
            }
            if let v = emojiImages[i] { return v }
            let v = UIImageView()
            v.contentMode = .scaleAspectFit
            v.isUserInteractionEnabled = false
            v.isAccessibilityElement = false
            v.frame = emojiImageFrame(in: emojis[i].bounds)
            emojis[i].addSubview(v)
            emojiImages[i] = v
            return v
        }
        func hideEmojiImage(_ i: Int) {
            guard let v = emojiImages[i], !v.isHidden else { return }
            v.isHidden = true
            v.image = nil
        }
        private func emojiImageFrame(in b: CGRect) -> CGRect {
            let s = emojiImageSide
            let k = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
            return CGRect(x: ((b.width - s) / 2 * k).rounded() / k, y: ((b.height - s) / 2 * k).rounded() / k,
                          width: s, height: s)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.inset(by: hitInsets).contains(point)
        }

        /// Đặt chữ slot; chỉ ghi khi chữ/font đổi.
        func setText(_ i: Int, _ text: String, font: UIFont) {
            let l = labels[i]
            guard l.text != text || l.font !== font else { return }
            l.text = text
            if l.font !== font { l.font = font }
            slots[i].accessibilityLabel = text
            Self.fitShrink(l)
        }

        /// adjustsFontSizeToFitWidth tốn một lượt đo co chữ mỗi lần vẽ — chỉ bật khi chữ
        /// CÓ THỂ không vừa ô (ước lượng trên: mọi glyph ≤ 0.95em; ô 0 = chưa layout ⇒ bật).
        static func fitShrink(_ l: UILabel) {
            let n = CGFloat(l.text?.count ?? 0)
            let need = l.bounds.width <= 0 || n * l.font.pointSize * 0.95 > l.bounds.width
            if l.adjustsFontSizeToFitWidth != need { l.adjustsFontSizeToFitWidth = need }
        }
    }

    /// Hit-area ô gợi ý nở xuống đúng phần strip còn lại dưới bar (barRowNow; strip preset 29 ≠ 34,
    /// + delta "Chiều cao thanh gợi ý" — xoay máy / đổi mức đổi strip ⇒ cập nhật, không lấn hàng Q–P).
    private var barHitStrip: CGFloat = -1
    private func refreshBarHitInsets() {
        guard barWired else { return }
        let strip = openStripNow
        guard strip != barHitStrip else { return }
        barHitStrip = strip
        let barHit = UIEdgeInsets(top: -8, left: -3, bottom: -barContentInsets(strip: strip).bottom, right: -3)
        suggestionBar.hitInsets = UIEdgeInsets(top: barHit.top, left: 0, bottom: barHit.bottom, right: 0)
        for b in slotButtons + emojiButtons { b.hitInsets = barHit }
    }

    private func buildSuggestionPoolIfNeeded() {
        guard !barWired else { return }
        barWired = true
        // Số ô đổi (xoay máy, bar co vì nút 📋/😊, đổi cài đặt) ⇒ vẽ lại bộ gợi ý hiện tại.
        suggestionBar.onSlotCountChange = { [weak self] in
            guard let self, let set = self.lastShownSet else { return }
            self.lastSuggestionSig = nil
            self.showSuggestions(set)
        }
        // Bar 20pt trong strip openStrip → nút nở hit-area xuống ĐÚNG phần còn lại
        // của strip (34−20−4 = 10pt), không lấn hàng Q–P bên dưới.
        barHitStrip = -1
        refreshBarHitInsets()
        for b in slotButtons + emojiButtons {
            b.backgroundColor = .clear
            b.isMultipleTouchEnabled = true
            // Chốt payload lúc CHẠM XUỐNG: gợi ý nền về giữa down/up đổi ô thì vẫn chèn
            // đúng chữ đang hiện dưới ngón tay (bug 27/09/2026).
            b.addAction(UIAction { [weak b] _ in b?.downPayload = b?.payload }, for: .touchDown)
            b.addAction(UIAction { [weak self, weak b] _ in
                guard let b else { return }
                let s = b.downPayload ?? b.payload
                b.downPayload = nil
                if let s { self?.onSuggestion?(s); self?.buddy?.cheer() }
            }, for: .touchUpInside)
            b.addAction(UIAction { [weak b] _ in b?.downPayload = nil }, for: [.touchCancel, .touchUpOutside])
        }
        // Burger KHÔNG nằm trong bar: nút ghim cố định ở mép trái (burgerZone — xem layoutStripZones).
    }

    // MARK: mẫu câu nhanh (burger menu, user 2026-07-24)

    /// Mặc định = ios-mau-cau.yml bundle theo build (user 2026-07-24 — sửa file
    /// là build sau có bộ mới); dùng khi user CHƯA tự chỉnh trong app (tab Mẫu
    /// Câu, App Group "userTemplates" = [["label":…, "text":…]]). Bubble hiện
    /// label (👋) nếu có, không thì text truncate đuôi "…".
    static let templates: [(label: String, text: String)] = {
        guard let url = Bundle(for: KeyboardView.self)
                .url(forResource: "ios-mau-cau", withExtension: "yml"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [("👋", "Chào buổi sáng"), ("😴", "Chúc ngủ ngon"), ("", "Miss you")] }
        let parsed = parseTemplatesYAML(text)
        return parsed.isEmpty ? [("👋", "Chào buổi sáng")] : parsed
    }()

    /// Flat YAML: `- "label | text"` hoặc `- text` (cùng format app export).
    static func parseTemplatesYAML(_ text: String) -> [(label: String, text: String)] {
        text.split(separator: "\n").compactMap { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#"), s.hasPrefix("- ") else { return nil }
            s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
                s = String(s.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
            guard !s.isEmpty else { return nil }
            if let r = s.range(of: " | ") {
                let body = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty else { return nil }
                return (String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), body)
            }
            return ("", s)
        }
    }

    /// Danh sách mẫu câu — đọc LƯỜI lúc mở plane mẫu câu (nil = chưa đọc). Tắt "Mẫu câu"
    /// (Tính Năng → Gõ tắt) ⇒ không bao giờ đọc App Group / parse YAML bundle (0 chi phí).
    private var userTemplatesCache: [(label: String, text: String)]?
    private var userTemplates: [(label: String, text: String)] {
        if let c = userTemplatesCache { return c }
        let c: [(label: String, text: String)]
        // Một lần: thêm mẫu động có sẵn (tỷ giá/vàng/BTC) vào danh sách đã tự chỉnh.
        DynamicSnippets.migrateIfNeeded(UserDefaultsProvider.shared)
        if let raw = UserDefaultsProvider.shared?.array(forKey: "userTemplates") as? [[String: String]] {
            c = raw.compactMap { e in
                guard let t = e["text"], !t.isEmpty else { return nil }
                return (e["label"] ?? "", t)
            }
        } else {
            c = Self.templates
        }
        userTemplatesCache = c
        return c
    }
    #if DEBUG
    var debugTemplatesLoaded: Bool { userTemplatesCache != nil }
    var debugBurgerVisible: Bool { burgerZoneMade && burgerZone.superview != nil && !burgerZone.isHidden }
    var debugLeftZone: LeftZone { leftZone }
    /// Test hook: chạm ô mép trái thanh gợi ý (☰ hoặc nút một tay) — đúng action của nút.
    func debugTapLeftZone() { burgerZone.sendActions(for: .touchUpInside) }
    var debugLeftZoneSymbol: String? { burgerZone.accessibilityLabel }
    var debugInTemplates: Bool { plane == .templates }
    /// Test hook: chạm chip thứ `index` của lưới mẫu câu / công cụ (đúng delegate của lưới).
    @discardableResult
    func debugSelectTemplateChip(_ index: Int) -> Bool {
        guard let chips = rowsContainer.arrangedSubviews.lazy.compactMap({ $0 as? TemplateChipsView }).first
        else { return false }
        return chips.debugSelect(index)
    }
    /// Test hook: nhãn các ô công cụ (tab Công cụ; rỗng ở tab Mẫu câu).
    var debugTemplateExtras: [String] {
        rowsContainer.arrangedSubviews.lazy.compactMap { $0 as? TemplateChipsView }.first?.debugExtras ?? []
    }
    /// Test hook: bảng ☰ có thanh chọn [Mẫu câu | Công cụ].
    var debugTemplateSegmented: Bool {
        rowsContainer.arrangedSubviews.lazy.compactMap { $0 as? TemplateChipsView }.first?.debugSegmented ?? false
    }
    /// Test hook: chọn đoạn thứ `i` của thanh chọn (0 = Mẫu câu, 1 = Công cụ).
    func debugSelectTemplateSegment(_ i: Int) {
        rowsContainer.arrangedSubviews.lazy.compactMap { $0 as? TemplateChipsView }.first?.debugSelectSegment(i)
    }
    #endif
    private var templatesEnabled = true
    /// "Hiện mẫu câu theo dòng" (#175): bảng ☰ mỗi mẫu một dòng, nhãn + nội dung. Mặc định tắt.
    private var templatesAsList = false
    private var templatesActive: Bool { plane == .templates }
    /// Chèn thẳng vào input, KHÔNG qua máy học từ (câu nhiều từ làm bẩn model).
    var onTemplate: ((String) -> Void)?
    /// Bubble ⚙️ cuối lưới → controller mở tab Mẫu Câu của app.
    var onOpenTemplates: (() -> Void)?

    // MARK: công cụ văn bản (Plus) — lối vào: thanh chọn [Mẫu câu | Công cụ] đầu bảng ☰:
    // "Công cụ" → lưới danh sách thao tác (áp lên phần đang chọn /
    // câu trước con trỏ), chạm thao tác → về bàn phím chữ.

    /// KeyboardSettings.textToolsActive() (Plus + công tắc "Công cụ văn bản") — controller
    /// đặt mỗi lần hiện bàn phím.
    var textToolsEnabled = false {
        didSet {
            guard oldValue != textToolsEnabled else { return }
            // Chỉ-công-cụ (Mẫu câu tắt) mà công cụ vừa tắt ⇒ lưới rỗng: về bàn phím chữ.
            if templatesActive, !templatesEnabled, !textToolsEnabled { plane = .letters; rebuild() }
            else if templatesActive { rebuildUncachedPlane() }
            setNeedsLayout()   // ô mép trái (☰ / một tay) đổi theo
        }
    }
    var onTextTool: ((TextTool) -> Void)?
    /// Chip "Dịch ↔ <đích>" cuối danh sách công cụ (Plus .translate, iOS 26+); nil = ẩn.
    /// Controller đặt mỗi lần hiện bàn phím.
    var translateChipLabel: String? {
        didSet {
            if oldValue != translateChipLabel, templatesActive { rebuildUncachedPlane() }
        }
    }
    var onTranslate: (() -> Void)?
    private static let translateID = "\u{E000}translate"
    /// Ô "Thêm dấu" (AddTones, Plus .sentenceDiacritics) trong danh sách công cụ.
    static let addTonesID = "\u{E000}addTones"
    var onAddTones: (() -> Void)?
    /// Tab đang chọn của thanh [Mẫu câu | Công cụ] — nhớ lựa chọn cuối (không đặt lại khi đóng ☰).
    private var textToolsMode = false

    /// Dựng lại plane mẫu câu (không cache) đang hiện dù chữ ký không đổi —
    /// rebuild() bỏ qua khi builtPlane == plane (lật danh sách công cụ, bật/tắt Plus).
    private func rebuildUncachedPlane() {
        if plane == .templates { builtPlane = nil }
        rebuild()
    }

    private func toggleTemplates() {
        guard templatesEnabled || textToolsEnabled else { return }
        Self.clickModifier()
        if !templatesEnabled { textToolsMode = true }   // chỉ-công-cụ: mở thẳng danh sách công cụ
        plane = templatesActive ? .letters : .templates
        lastSuggestionSig = nil
        rebuild()
        styleBurger()
    }

    private func styleBurger() {
        // Icon/tint burgerZone do layoutStripZones set theo templatesActive —
        // ép layout lại để đổi trạng thái đậm/nhạt ngay khi bật/tắt mẫu câu.
        setNeedsLayout()
    }

    /// Payload của nút Dán trên bar — ký tự Private Use, không thể là từ thật.
    static let pasteToken = "\u{E000}paste"
    /// Clipboard là ảnh: iOS không cho bàn phím chèn ảnh (chỉ insertText) — thẻ chỉ
    /// hướng dẫn; chạm = ẩn thẻ.
    static let pasteImageToken = "\u{E000}pasteImage"
    /// Payload ô "Khôi phục" (chèn lại đoạn vừa vuốt ⌫ xoá).
    static let restoreToken = "\u{E000}restore"
    /// Payload chip số: controller giữ NumberChip (đuôi cần thay + chữ chèn).
    static let numberToken = "\u{E000}number"
    /// Chip kết quả phép tính (MathResults) — controller giữ chữ cần chèn.
    static let mathToken = "\u{E000}math"
    /// Payload ô "↩︎ Hoàn tác" sau khi áp công cụ văn bản.
    static let toolUndoToken = "\u{E000}toolUndo"
    /// Payload chip thông báo Dịch trên máy ("Đang dịch…", "Mở app … tải gói dịch").
    static let translateNoticeToken = "\u{E000}translateNotice"
    /// Payload chip "Thêm dấu" / "Hoàn tác" (AddTones — chỉ khi người dùng bấm).
    static let addTonesToken = "\u{E000}addTones"
    static let undoTonesToken = "\u{E000}undoTones"
    /// Payload chip "↩︎ từ cũ": hoàn tác lần vuốt vừa sửa lại từ vuốt trước (SwipeRevise).
    static let undoReviseToken = "\u{E000}undoRevise"
    /// Payload chip "↩︎ chữ gốc": trả lại chữ đã gõ của lần tự sửa vừa rồi (AutoCorrect).
    static let undoAutoCorrectToken = "\u{E000}undoAutoCorrect"
    /// Payload ô ngoặc kép cạnh ô tô nền (§8): tiền tố + chữ gốc — giữ nguyên, ghi "từng hoàn tác tự sửa".
    static let keepTypedPrefix = "\u{E000}keep:"
    /// Payload chip sửa ngược tiếng Anh ("His car is") — công tắc "Tự sửa từ phía trước" TẮT.
    static let retroOfferToken = "\u{E000}retroOffer"
    /// Payload chip "↩︎ Khôi phục" sau khi tự sửa ngược (công tắc BẬT).
    static let undoRetroToken = "\u{E000}undoRetro"

    /// Khoá "nội dung bar không đổi" của `showSuggestions` (trước: chuỗi ghép mỗi lần refresh).
    struct BarSignature: Equatable {
        struct Slot: Equatable { let display: String; let insert: String }
        enum Paste: Equatable { case none, text, image }
        let dark: Bool
        let theme: KeyboardTheme
        /// Màu chữ thanh gợi ý — theme tự tạo / tuỳ chỉnh đổi màu mà `theme` vẫn là .system.
        var ink: RGBA = .black
        let slots: [Slot?]
        let emojis: [String]
        let paste: Paste
        /// Ô tô nền (§8) — nil = không.
        var pill: Int? = nil
    }

    /// Bộ gợi ý vừa vẽ — vẽ lại khi số ô đổi (xoay máy / đổi "Số từ gợi ý").
    private var lastShownSet: SuggestionSet?

    /// "Số từ gợi ý" (SuggestionCount, 0 = Tự động) — đọc mỗi lần hiện bàn phím.
    var suggestionCountSetting: Int {
        get { suggestionBar.setting }
        set { suggestionBar.setting = newValue }
    }
    /// Số ô thanh gợi ý đang dùng (đã trừ ô không vừa bề rộng).
    var suggestionSlotCount: Int { suggestionBar.slotCount }

    func showSuggestions(_ set: SuggestionSet) {
        guard suggestionsEnabled else { return }
        buildSuggestionPoolIfNeeded()
        lastShownSet = set

        // Thứ tự ưu tiên slot (hoàn tác > clipboard > Thêm dấu > chip số > chữ): SuggestionSlots.
        var texts = [(display: String, insert: String)?](repeating: nil, count: SuggestionBar.poolSize)
        var emojis: [String] = []
        var pasteCardOn = false
        var chipCount = 0
        var pillIndex: Int?
        switch SuggestionSlots.arrange(set, count: suggestionBar.slotCount) {
        case .slots(let s, let e):
            for (i, x) in s.enumerated() where i < texts.count { texts[i] = x.map { ($0.label, $0.payload) } }
            emojis = e
            pillIndex = s.firstIndex { $0?.highlight == true }
        case .chips(let c):
            for (i, x) in c.prefix(3).enumerated() { texts[i] = (x.label, x.payload) }
            chipCount = min(c.count, 3)
        case .pasteCard:
            pasteCardOn = true
        case .pill(let u):
            texts[0] = (u.label, u.payload)
        }
        // Lời mời dán có thực sự lên bar không (PasteOfferOnce: mời một lần mỗi mục).
        notePasteOffer(pasteCardOn || texts.contains { t in
            t.map { $0.insert == Self.pasteToken || $0.insert.hasPrefix(Self.clipTokenPrefix) } ?? false
        })
        // Nội dung không đổi (nextWords thường ổn định giữa các phím) → bỏ qua
        // toàn bộ ghi UI: setTitle trên bar fillProportionally kéo theo một
        // lượt đo text/Auto Layout mỗi keystroke.
        // So bằng struct Equatable (chỉ copy tham chiếu chuỗi) — không ghép chuỗi khoá mỗi lần.
        let sig = BarSignature(
            dark: dark, theme: themeSettings.theme, ink: palette.barInk,
            slots: texts.map { $0.map { .init(display: $0.display, insert: $0.insert) } },
            emojis: emojis,
            paste: pasteCardOn ? (set.pasteIsImage ? .image : .text) : .none,
            pill: pillIndex)
        if sig == lastSuggestionSig { return }
        lastSuggestionSig = sig
        // Token AI: vệt sáng quét dải gợi ý khi GỢI Ý đổi thật (không tính chữ đang gõ). Kiểu khác ⇒ một phép so sánh.
        if let fx = keyEffects, fx.effect == .tokens {
            var words: [String] = []
            if let w = set.word { words.append(w) }
            if let w = set.word2 { words.append(w) }
            words += set.moreWords; words += set.nextWords; words += set.emojis
            fx.suggestionsChanged(words, bar: suggestionBar.frame)
        }

        suggestionBar.setChipCount(chipCount)
        applyBarInk()
        // Chỉ ghi thuộc tính THỰC SỰ đổi (chữ literal đổi mỗi phím, 2 ô kia thường giữ).
        for (i, b) in slotButtons.enumerated() {
            if let t = texts[i] {
                let chip = t.insert.hasPrefix(Self.clipTokenPrefix) || (t.insert == Self.pasteToken)
                suggestionBar.setText(i, t.display, font: chip ? chipFont : slotFont)
                b.payload = t.insert
                if b.isHidden { b.isHidden = false }
            } else {
                if !b.isHidden { b.isHidden = true }
                b.payload = nil
            }
        }
        // Ô tô nền (§8): nền + chữ theo màu phím của theme.
        suggestionBar.setPill(pillIndex)
        applyPillInk()
        // slot emoji (chỉ ở chế độ đang gõ, khi có emoji)
        // Ảnh từ atlas (SuggestionEmojiTiles) — không vẽ chữ emoji ⇒ không nạp font Apple Color Emoji.
        suggestionBar.setEmojiCount(emojis.count)
        for (i, b) in emojiButtons.enumerated() {
            if i < emojis.count {
                if barEmojiWanted[i] != emojis[i] {
                    barEmojiWanted[i] = emojis[i]
                    applyBarEmoji(i)
                }
                b.payload = emojis[i]
                if b.isHidden { b.isHidden = false }
            } else {
                if !b.isHidden { b.isHidden = true }
                b.payload = nil
                barEmojiWanted[i] = nil
            }
        }
        barEmojiTiles?.flush()
        // Vạch ngăn cố định: hiện khi bar có nội dung (ô trống vẫn giữ chỗ — như stock).
        let anyVisible = texts.contains { $0 != nil } || !emojis.isEmpty
        let usable = suggestionBar.usableDividers
        for (i, d) in slotDividers.enumerated() {
            let hide = !anyVisible || pasteCardOn || i >= usable
            if d.isHidden != hide { d.isHidden = hide }
        }
        // Nút Dán kiểu iOS 27: MỘT ô rộng giữa bar, 2 dòng, thay cả 3 slot.
        setPasteCard(visible: pasteCardOn, image: set.pasteIsImage, ink: ink)
    }

    // MARK: emoji trên thanh gợi ý (atlas)

    /// Tạo lười ở emoji ĐẦU TIÊN của phiên (bàn phím không gợi ý emoji ⇒ không mở atlas). Sống cùng
    /// KeyboardView (tearDown nhả).
    private var barEmojiTiles: SuggestionEmojiTiles?
    /// Emoji mỗi ô emoji đang muốn hiện (nil = ô ẩn). Kết quả nền chỉ áp khi còn khớp ⇒ không bao
    /// giờ hiện emoji cũ / sai.
    private var barEmojiWanted: [String?] = [nil, nil, nil]
    /// Test: thay nguồn atlas của bar (mặc định App Group).
    static var barEmojiOpener: (() -> EmojiAtlasStore?)?

    private func barTiles() -> SuggestionEmojiTiles {
        if let t = barEmojiTiles { return t }
        let scale = UIScreen.main.scale
        let open = Self.barEmojiOpener ?? SuggestionEmojiTiles.keyboardOpener(
            scale: scale, pad: UIDevice.current.userInterfaceIdiom == .pad)
        let t = SuggestionEmojiTiles(fontSize: emojiButtons.first?.titleFont.pointSize ?? 20, scale: scale, open: open)
        t.onReady = { [weak self] e in self?.barEmojiReady(e) }
        barEmojiTiles = t
        return t
    }

    /// Vẽ ô emoji `i` theo `barEmojiWanted[i]`: ảnh có sẵn / chữ (không atlas, không có trong atlas) /
    /// trống một nhịp (đang giải mã — ô giữ nguyên kích thước).
    private func applyBarEmoji(_ i: Int) {
        guard i < emojiButtons.count, let e = barEmojiWanted[i] else { return }
        let b = emojiButtons[i]
        b.accessibilityLabel = e
        let tiles = barTiles()
        switch tiles.lookup(e) {
        case .image(let img):
            let v = suggestionBar.emojiImageView(i, side: tiles.side)
            if v.image !== img { v.image = img }
            if v.isHidden { v.isHidden = false }
            if b.title(for: .normal) != nil { b.setTitle(nil, for: .normal) }
        case .text:
            suggestionBar.hideEmojiImage(i)
            if b.title(for: .normal) != e { b.setTitle(e, for: .normal) }
        case .pending:
            suggestionBar.hideEmojiImage(i)
            if b.title(for: .normal) != nil { b.setTitle(nil, for: .normal) }
        }
    }

    private func barEmojiReady(_ e: String) {
        for i in barEmojiWanted.indices where barEmojiWanted[i] == e { applyBarEmoji(i) }
        barEmojiTiles?.flush()
    }

    #if DEBUG
    /// Test: mỗi ô emoji đang hiện — (ảnh atlas?, chữ đang vẽ).
    func debugBarEmojiCells() -> [(image: UIImage?, title: String?)] {
        emojiButtons.enumerated().filter { !$0.element.isHidden }.map { i, b in
            let v = suggestionBar.emojiImages[i]
            return (v.flatMap { $0.isHidden ? nil : $0.image }, b.title(for: .normal))
        }
    }
    var debugBarEmojiTiles: SuggestionEmojiTiles? { barEmojiTiles }
    #endif

    // MARK: Clipboard (lịch sử + chip) — không có chỉ báo ẩn danh (Phil 27/09 bỏ icon mắt gạch)
    /// Payload chip tách số: prefix + giá trị cần chèn.
    static let clipTokenPrefix = "\u{E000}clip:"
    static let clipZoneWidth: CGFloat = 40
    /// Lời mời dán (thẻ Dán / chip clipboard) hiện (true) / rời bar (false). Gọi khi ĐỔI,
    /// và mỗi lượt vẽ khi đang hiện (copy mới giữa chừng vẫn được ghi nhận); lúc gõ chữ
    /// (không có lời mời) không gọi.
    var onPasteOfferVisible: ((Bool) -> Void)?
    private var pasteOfferOn = false
    private func notePasteOffer(_ on: Bool) {
        guard on || on != pasteOfferOn else { return }
        pasteOfferOn = on
        onPasteOfferVisible?(on)
    }
    private var clipboardButtonVisible = false
    var onOpenClipboard: (() -> Void)?
    /// Panel phủ vùng phím: touch trong panel KHÔNG đi qua router phím chữ.
    weak var overlayPanel: UIView?
    var isDarkAppearance: Bool { dark }
    /// Vùng phím (dưới strip) — nơi đặt panel clipboard.
    var keyAreaFrame: CGRect { rowsContainer.frame }

    private var clipZoneMade = false
    private lazy var clipZone: UIButton = {
        clipZoneMade = true
        let b = UIButton(type: .custom)
        b.accessibilityLabel = L("Lịch sử clipboard")
        b.addAction(UIAction { [weak self] _ in
            Self.clickModifier()
            self?.onOpenClipboard?()
        }, for: .touchUpInside)
        addSubview(b)
        return b
    }()
    #if DEBUG
    var debugClipboardButtonVisible: Bool { clipboardButtonVisible }
    #endif
    func setClipboardButton(visible: Bool) {
        guard visible != clipboardButtonVisible else { return }
        clipboardButtonVisible = visible
        setNeedsLayout()   // bề rộng bar (layoutSuggestionBar)
    }

    /// Panel clipboard bám ĐÚNG vùng phím mỗi lượt layout. Trước đây chỉ đặt frame lúc mở
    /// + autoresizing (cao cố định, neo đáy): bàn phím đổi chiều cao khi panel đang mở (xoay,
    /// host cấp lại khung) ⇒ panel trồi lên đè dải gợi ý / hở hàng phím.
    private func layoutOverlayPanel() {
        guard let p = overlayPanel, p.superview === self else { return }
        let f = rowsContainer.frame
        if p.frame != f { p.frame = f }
        bringSubviewToFront(p)
    }

    // MARK: Nút emoji trên thanh gợi ý ("Nút emoji" = Thanh trên, EmojiKeyPlacement)
    static let emojiZoneWidth: CGFloat = 40
    /// Bề ngang chừa bên phải bar (sát mép phải): 📋 (lịch sử clipboard) + 😊 (Thanh trên) + nhân vật + ⌄ (nếu bật).
    private var barRightExtras: CGFloat {
        (clipboardButtonVisible ? Self.clipZoneWidth : 0) + (emojiInBar ? Self.emojiZoneWidth : 0) + buddyZone + dismissInset
    }
    private var emojiZoneMade = false
    private lazy var emojiZone: UIButton = {
        emojiZoneMade = true
        let b = UIButton(type: .custom)
        b.accessibilityLabel = "Emoji"
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Self.clickModifier()
            self.emojiABCSlot = nil          // ABC về chỗ mặc định của plane emoji
            self.plane = .emoji
            self.rebuild()
        }, for: .touchUpInside)
        addSubview(b)
        return b
    }()
    /// Khung nút 😊 trên thanh — THUẦN để test: ô cao trọn strip bên trái 📋 (hoặc nhân vật / ⌄ / mép phải).
    static func emojiBarFrame(width: CGFloat, strip: CGFloat, clip: Bool, buddy: CGFloat = 0,
                              dismiss: CGFloat = 0) -> CGRect {
        let x = width - dismiss - buddy - (clip ? clipZoneWidth : 0) - emojiZoneWidth
        return CGRect(x: x, y: 0, width: emojiZoneWidth, height: strip)
    }
    private func layoutEmojiBarButton() {
        let visible = emojiInBar && suggestionsEnabled && plane != .emoji && plane != .emojiSearch
        if !visible { if emojiZoneMade { emojiZone.isHidden = true }; return }
        guard bounds.width > 0 else { return }
        let strip = max(rowsTopWanted, openStripNow)
        let f = Self.emojiBarFrame(width: bounds.width, strip: strip,
                                   clip: clipboardButtonVisible, buddy: buddyZone, dismiss: dismissInset)
        emojiZone.isHidden = false
        defer { bringSubviewToFront(emojiZone) }
        // layoutSubviews chạy cả khi gõ (shift/balloon): trạng thái không đổi ⇒ khỏi dựng lại ảnh.
        let key = EmojiZoneKey(frame: f, ink: palette.barInk)
        guard key != emojiZoneKey else { return }
        emojiZoneKey = key
        emojiZone.frame = f
        emojiZone.setImage(UIImage(systemName: "face.smiling",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)),
            for: .normal)
        emojiZone.tintColor = palette.barInk.ui.withAlphaComponent(0.6)
        // Icon canh hàng chữ gợi ý như 📋 / ☰.
        emojiZone.contentEdgeInsets = barContentInsets(strip: strip)
    }
    private struct EmojiZoneKey: Equatable { let frame: CGRect; let ink: RGBA }
    private var emojiZoneKey: EmojiZoneKey?
    #if DEBUG
    /// Test hook: khung nút 😊 trên thanh (nil = ẩn / chưa tạo).
    var debugEmojiBarButton: UIButton? { emojiZoneMade && !emojiZone.isHidden ? emojiZone : nil }
    #endif

    private func layoutClipboardExtras(stripOpen: Bool) {
        let showClip = stripOpen && clipboardButtonVisible
        if clipboardButtonVisible || clipZoneMade { clipZone.isHidden = !showClip }
        if showClip, bounds.width > 0 {
            let strip = max(rowsTopWanted, openStripNow)
            let cw = Self.clipZoneWidth
            clipZone.frame = CGRect(x: bounds.width - dismissInset - buddyZone - cw, y: 0, width: cw, height: strip)
            clipZone.setImage(UIImage(systemName: "doc.on.clipboard",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)), for: .normal)
            clipZone.tintColor = palette.barInk.ui.withAlphaComponent(overlayPanel == nil ? 0.45 : 0.9)
            clipZone.contentEdgeInsets = barContentInsets(strip: strip)
            bringSubviewToFront(clipZone)
        }
    }

    // MARK: Debug — hình học cửa sổ (25/09/2026)
    // Thanh gợi ý "bị cắt" ở Telegram / app VietTelex nhưng không ở WhatsApp/Notes: host
    // có lúc KHÔNG vẽ dải khung phía trên cửa sổ extension. Ghi hình học mỗi khi đổi để
    // tìm dấu hiệu phân biệt (chỉ khi Debug mode bật).
    private var lastGeomKey = ""
    private func logGeometryIfChanged() {
        guard TouchLog.enabled, let w = window else { return }
        let inWin = convert(bounds, to: w)
        let key = "\(w.bounds) \(inWin) \(w.safeAreaInsets) \(safeAreaInsets) \(superview?.frame ?? .zero)"
        guard key != lastGeomKey else { return }
        lastGeomKey = key
        TouchLog.write("geom window=\(NSCoder.string(for: w.bounds)) view=\(NSCoder.string(for: inWin)) "
            + "winSafe=\(NSCoder.string(for: w.safeAreaInsets)) viewSafe=\(NSCoder.string(for: safeAreaInsets)) "
            + "super=\(NSCoder.string(for: superview?.frame ?? .zero)) "
            + "host=\(inputController?.parent.map { String(describing: type(of: $0)) } ?? "-")")
    }

    // MARK: Nút Dán (iOS 27 style, 25/09/2026)
    // Stock hiện nội dung clipboard + "Paste from <App>" — bàn phím bên thứ ba KHÔNG
    // làm vậy được: đọc nội dung = iOS báo/hỏi quyền dán MỖI lần bàn phím hiện, và
    // app nguồn không lộ cho extension. Nên: "Dán" / "Nội dung vừa copy".
    /// Dựng LƯỜI lần đầu thẻ Dán hiện (khởi động lạnh: không tạo 2 stack + 3 label khi ẩn).
    private var pasteCardMade = false
    private lazy var pasteCard: KeyButton = {
        pasteCardMade = true
        let b = KeyButton()
        b.backgroundColor = .clear
        b.hitInsets = UIEdgeInsets(top: -8, left: 0, bottom: 0, right: 0)
        b.accessibilityLabel = L("Dán nội dung vừa copy")
        let title = UILabel(), sub = UILabel()
        title.text = L("Dán")
        title.font = .systemFont(ofSize: 14, weight: .regular)
        sub.text = L("Nội dung vừa copy")
        sub.font = .systemFont(ofSize: 10, weight: .regular)
        title.tag = 91; sub.tag = 92
        let icon = UIImageView(image: UIImage(systemName: "doc.on.clipboard",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)))
        icon.tag = 93
        let text = UIStackView(arrangedSubviews: [title, sub])
        text.axis = .vertical; text.alignment = .leading; text.spacing = -2
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.axis = .horizontal; row.alignment = .center; row.spacing = 8
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(row)
        // Neo SÁT ĐỈNH (user 25/09/2026: căn giữa strip 30pt làm dòng phụ chạm hàng
        // Q–P). Cả dải phía trên cửa sổ là khung host — không vẽ lên đó được.
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            row.topAnchor.constraint(equalTo: b.topAnchor, constant: 0),
        ])
        b.payload = Self.pasteToken
        b.addAction(UIAction { [weak self, weak b] _ in
            Self.clickModifier()
            if let p = b?.payload { self?.onSuggestion?(p) }
        }, for: .touchUpInside)
        return b
    }()

    /// Đang gõ dở: ẩn thẻ Dán NGAY ở phím (không đợi kết quả gợi ý chạy nền).
    func hidePasteCard() {
        notePasteOffer(false)
        guard pasteCardMade, !pasteCard.isHidden else { return }
        pasteCard.isHidden = true
        lastSuggestionSig = nil
    }

    private func setPasteCard(visible: Bool, image: Bool = false, ink: UIColor) {
        if visible {
            (pasteCard.viewWithTag(91) as? UILabel)?.text = image ? L("Ảnh vừa copy") : L("Dán")
            (pasteCard.viewWithTag(92) as? UILabel)?.text = image ? L("Giữ ô nhập → Dán") : L("Nội dung vừa copy")
            (pasteCard.viewWithTag(93) as? UIImageView)?.image = UIImage(
                systemName: image ? "photo.on.rectangle" : "doc.on.clipboard",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            pasteCard.payload = image ? Self.pasteImageToken : Self.pasteToken
            pasteCard.accessibilityLabel = image ? L("Ảnh vừa copy — giữ ô nhập rồi chọn Dán")
                                                 : L("Dán nội dung vừa copy")
            if pasteCard.superview == nil { addSubview(pasteCard) }
            let w = Self.stripZoneWidth
            let clipW = barRightExtras   // chừa nút 📋 / 😊
            pasteCard.frame = CGRect(x: w, y: Self.barTopPad, width: max(bounds.width - w - clipW, 0),
                                     height: openStripNow - Self.barTopPad)
            (pasteCard.viewWithTag(91) as? UILabel)?.textColor = ink
            (pasteCard.viewWithTag(92) as? UILabel)?.textColor = ink.withAlphaComponent(0.55)
            (pasteCard.viewWithTag(93) as? UIImageView)?.tintColor = ink.withAlphaComponent(0.8)
            bringSubviewToFront(pasteCard)
        }
        if visible || pasteCardMade { pasteCard.isHidden = !visible }
        // Thẻ Dán THAY cả bar: ẩn hẳn nội dung slot (trước đây chỉ alpha=0 cho bar — mọi
        // chỗ đặt lại alpha=1 như updateSuggestionChrome khi rebuild/đổi plane làm chữ
        // gợi ý hiện ĐÈ lên thẻ Dán, user 27/09/2026).
        if visible {
            for b in slotButtons + emojiButtons { b.isHidden = true; b.payload = nil }
            for d in slotDividers { d.isHidden = true }
        }
    }

    func configureReturnKey(type: UIReturnKeyType) {
        switch type {
        case .go: returnTitle = "go"
        case .search, .google, .yahoo: returnTitle = "search"
        case .send: returnTitle = "send"
        case .next: returnTitle = "next"
        case .done: returnTitle = "done"
        case .join: returnTitle = "join"
        default: returnTitle = "return"
        }
        rebuild()   // no-op nếu nhãn không đổi (chữ ký trong rebuild)
    }

    /// Gom cấu hình mỗi lần hiện (return / appearance / input kind) thành MỘT
    /// lần rebuild: trước đây configureReturnKey rồi configureInputKind mỗi hàm
    /// tự rebuild (và configureInputKind còn vứt cache) → xé + dựng ~40 phím
    /// 2 lần mỗi lần hiện dù không có gì đổi. Trong body mọi rebuild() bị hoãn;
    /// cuối cùng rebuild một lần — và rebuild tự bỏ qua khi chữ ký không đổi.
    func batchConfigure(_ body: () -> Void) {
        beginBatch()
        body()
        endBatch()
    }
    /// Như batchConfigure nhưng mở/đóng tách rời (controller gom CẢ lần hiện: dựng KeyboardView
    /// → đọc cài đặt → trait ô/theme/sáng-tối ⇒ dựng phím MỘT lần với kiểu cuối). Lồng được.
    func beginBatch() { batchDepth += 1 }
    func endBatch() {
        guard batchDepth > 0 else { return }
        batchDepth -= 1
        if batchDepth == 0 { rebuild() }
    }
    private var batchDepth = 0
    private var rebuildDeferred: Bool { batchDepth > 0 }
    /// Dựng bằng `deferInitialBuild` và CHƯA dựng plane nào. layoutSubviews dựng bù nếu
    /// tới lượt layout mà chưa ai dựng (willAppear bị nuốt…) — không bao giờ hiện bàn phím rỗng.
    private(set) var initialBuildPending = false

    /// Loại ô nhập (từ textDocumentProxy.keyboardType) → đổi layout như stock:
    /// number mở thẳng plane số; email đổi hàng đáy thành phím @ và . ; url
    /// thành . / (đuôi .com/.vn… ở giữ "."); search (thanh địa chỉ/tìm kiếm trình duyệt, .webSearch) đổi
    /// "," thành "." như stock. Chỉ ảnh hưởng hàng đáy plane CHỮ + plane mở đầu.
    enum InputKind {
        case normal, number, email, url, search
        /// Ô chữ tự do: gõ tiếng Việt / vuốt / chọn phím theo ngữ cảnh như ô thường.
        var isFreeText: Bool { self == .normal || self == .search }
    }
    private var inputKind: InputKind = .normal

    func configureInputKind(_ kind: InputKind, keypad: NumericKeypad.Style? = nil) {
        inputKind = kind
        keypadStyle = keypad
        plane = keypad != nil ? .keypad : (kind == .number) ? .numbers : .letters
        let shiftDropped = plane == .letters && shift == .on
        if shiftDropped { shift = .off }
        // Kind nằm trong chữ ký của rebuild: đổi kind → cache vứt + dựng lại;
        // KHÔNG đổi → giữ cache, khỏi xé ~40 phím mỗi lần hiện.
        rebuild()
        // Shift đổi KHÔNG bao giờ rebuild — retitle tại chỗ (rebuild bị bỏ qua
        // thì phím cũ vẫn đang hiện chữ hoa).
        if shiftDropped, plane == .letters { applyShiftAppearance() }
    }

    /// Chỉ đổi sáng/tối (không đọc lại settings) — gọi khi trait host resolve muộn.
    func updateDark(_ isDark: Bool) {
        guard isDark != systemDark else { return }
        systemDark = isDark
        resolvePalette()
        rebuild()
    }

    /// Theme (App Group) + sáng/tối hệ thống + ảnh nền → palette; `dark` đi theo
    /// palette để emoji plane/icon hệ thống chọn đúng nhánh sáng/tối.
    private func resolvePalette() {
        let fileExists = Wallpaper.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        wallpaperActive = themeSettings.wallpaperActive(fileExists: fileExists)
        palette = themeSettings.palette(systemDark: systemDark, wallpaperActive: wallpaperActive)
        dark = palette.isDark
        // Thanh gợi ý theo palette MỚI ngay (không đợi lượt gợi ý kế — bug nền tối chữ đen).
        applyBarInk()
        // Ô phóng to / popup: kiểu phím của theme, giải + đổi sang UIColor MỘT lần ở đây (không mỗi lần bấm).
        popup = PopupUI(KeyPopupStyle.make(palette, style: themeSettings.effectiveKeyStyle,
                                           systemDark: systemDark, wallpaper: wallpaperActive))
        if balloonMade { balloon.invalidateStyle() }
        // Hiệu ứng theo màu nhấn MỚI (đổi sáng/tối giữa chừng).
        keyEffects.map { $0.configure(effect: $0.effect, color: palette.accent.alpha(1).ui,
                                      keyFill: palette.keyFill.ui, dark: palette.isDark) }
        buddy?.setBar(palette.buddyBar)
        configureTrailColors()
        applyPixelKeys()
        applyBackdrop()
    }

    /// Dáng phím "pixel" (theme JSON "keyShape"): skin điểm ảnh dựng từ palette VỪA giải (cache theo màu — đổi sáng/tối
    /// ⇒ chữ ký khác ⇒ plane dựng lại). Skin tải về của theme ("keys") thắng. Theme khác: một phép so sánh.
    private func applyPixelKeys() {
        let st = themeSettings.effectiveKeyStyle
        guard st.keyShape == PixelKeys.shape || st.keyShape == GlassKeys.shape, st.assets.keys.isEmpty else {
            if themeAssets !== downloadedAssets { themeAssets = downloadedAssets }
            return
        }
        // "glass" (Kính màu): ô kính màu theo chữ + viền chì — cùng đường skin (GlassKeys).
        themeAssets = st.keyShape == GlassKeys.shape ? GlassKeys.assets(over: downloadedAssets, palette: palette)
            : PixelKeys.assets(over: downloadedAssets, palette: palette)
    }

    /// Chữ + vạch ngăn thanh gợi ý theo palette hiện tại; y hệt thì 0 việc.
    private func applyBarInk() {
        guard !suggestionBar.labels.isEmpty else { return }   // thanh chưa dựng: lần dựng đầu tự áp
        let ink = palette.barInk.ui
        // "Màu chữ gợi ý" (SuggestionInk, mặc định Xám như stock): chỉ chữ ô gợi ý; vạch ngăn theo barInk.
        let label = SuggestionInk.color(barInk: palette.barInk,
                                        behind: SuggestionInk.behindBar(palette, systemDark: systemDark,
                                                                        wallpaper: wallpaperActive),
                                        mode: suggestionInk).ui
        guard barInkApplied != ink || barLabelInkApplied != label else { return }
        barInkApplied = ink
        barLabelInkApplied = label
        for d in slotDividers { d.backgroundColor = ink.withAlphaComponent(0.18) }
        for l in suggestionBar.labels { l.textColor = label }   // cả ô đang ẩn
        pillInkApplied = nil
        applyPillInk()
    }

    /// Màu ô tô nền (ONBOARDING-SPEC §8): nền = mặt phím chữ, chữ = chữ trên phím của theme đang
    /// dùng ⇒ theo sáng/tối, theme có sẵn, theme tự tạo, độ trong suốt phím.
    static func pillColors(_ p: KeyboardPalette) -> (fill: RGBA, ink: RGBA) { (p.keyFill, p.keyInk) }
    private var pillInkApplied: (index: Int, fill: UIColor, ink: UIColor)?
    private func applyPillInk() {
        guard let i = suggestionBar.pillIndex, i < suggestionBar.labels.count else {
            if let old = pillInkApplied, old.index < suggestionBar.labels.count {
                suggestionBar.labels[old.index].textColor = barLabelInkApplied
            }
            pillInkApplied = nil
            return
        }
        let c = Self.pillColors(palette)
        let fill = c.fill.ui, ink = c.ink.ui
        if let old = pillInkApplied, old.index == i, old.fill == fill, old.ink == ink { return }
        if let old = pillInkApplied, old.index != i, old.index < suggestionBar.labels.count {
            suggestionBar.labels[old.index].textColor = barLabelInkApplied
        }
        suggestionBar.pill.backgroundColor = fill
        suggestionBar.labels[i].textColor = ink
        pillInkApplied = (i, fill, ink)
    }
    /// Test: ô tô nền đang hiện (nil = không) và màu nền / chữ của nó.
    var debugPillSlot: Int? { suggestionBar.pill.isHidden ? nil : suggestionBar.pillIndex }
    var debugPillFill: UIColor? { suggestionBar.pill.backgroundColor }
    var debugPillLabelInk: UIColor? { suggestionBar.pillIndex.map { suggestionBar.labels[$0].textColor } }
    /// Test: màu thanh gợi ý (vạch ngăn) đang áp (nil = chưa dựng thanh).
    var debugBarInkApplied: UIColor? { barInkApplied }
    /// Test: màu chữ ô gợi ý đang áp (nil = chưa dựng thanh).
    var debugSuggestionLabelInk: UIColor? { barLabelInkApplied }
    /// Test hook "Màu chữ gợi ý" (như applyAppearance đọc từ App Group).
    func debugSetSuggestionInk(_ m: SuggestionInk) { suggestionInk = m; applyBarInk() }
    /// Test: bộ gợi ý vừa vẽ + chữ các ô slot đang hiện (chip mời/hoàn tác có thật sự lên thanh không).
    var debugLastShownSet: SuggestionSet? { lastShownSet }
    var debugVisibleSlotTexts: [String] {
        guard !suggestionBar.isHidden, suggestionBar.alpha > 0 else { return [] }
        return zip(slotButtons, suggestionBar.labels).compactMap { b, l in
            b.isHidden ? nil : l.text.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Kiểu ô phóng to / popup đã đổi sang UIColor (KeyPopupStyle) — dựng lại khi palette đổi.
    struct PopupUI {
        let style: KeyPopupStyle
        let fill: UIColor, ink: UIColor, selectedFill: UIColor, selectedInk: UIColor
        let border: CGColor?
        init(_ s: KeyPopupStyle) {
            style = s
            fill = s.fill.ui; ink = s.ink.ui; selectedFill = s.selectedFill.ui; selectedInk = s.selectedInk.ui
            border = s.border?.ui.cgColor
        }
    }
    private var popup = PopupUI(KeyPopupStyle.make(KeyboardTheme.system.palette(systemDark: false), style: .default,
                                                    systemDark: false, wallpaper: false))
    /// Test: kiểu ô phóng to / popup đang dùng.
    var debugPopupStyle: KeyPopupStyle { popup.style }

    private func applyBackdrop() {
        if themeBackdrop.superview == nil {
            for v in [themeBackdrop, themeImageView, wallpaperView, wallpaperDim] {
                v.isUserInteractionEnabled = false
                v.frame = bounds
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
            wallpaperView.contentMode = .scaleAspectFill
            wallpaperView.clipsToBounds = true
            themeImageView.contentMode = .scaleAspectFill
            themeImageView.clipsToBounds = true
            themeImageView.isHidden = true
            insertSubview(themeBackdrop, at: 0)
            insertSubview(themeImageView, aboveSubview: themeBackdrop)
            insertSubview(wallpaperView, aboveSubview: themeImageView)
            insertSubview(wallpaperDim, aboveSubview: wallpaperView)
        }
        // Theme nền trong suốt (mặc định Hệ thống): KHÔNG phủ nền đục — vật liệu bàn phím hệ
        // thống lộ ra nên vùng phím cùng màu dải 🌐/🎤 iOS vẽ bên dưới (ThemeSettings.clearBackground).
        let clear = themeSettings.clearBackground(systemDark: systemDark, wallpaperActive: wallpaperActive)
        themeBackdrop.backgroundColor = clear ? nil : palette.background?.ui
        themeBackdrop.isHidden = clear || palette.background == nil
        applyBackgroundGradient(hidden: clear)
        applyDecoration(hidden: clear)
        applyAurora(hidden: clear)
        applyCornerGlyph(hidden: clear)
        // Nền tự vẽ: bo 2 góc trên theo khung kính bàn phím iOS 26+ (không còn góc vuông đen
        // chồng lên góc bo xám của hệ thống). cornerRadius trên view lá màu phẳng / ảnh ⇒ không
        // offscreen pass.
        let r = clear ? 0 : KeyLayout.backdropCornerRadius(phone: !Self.isPad, systemMajor: Self.systemMajor)
        for v in [themeBackdrop, themeImageView, foregroundView, wallpaperView, wallpaperDim] where v.layer.cornerRadius != r {
            v.layer.cornerRadius = r
            v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            v.layer.cornerCurve = .circular   // khớp khung hệ thống (đo pixel, KeyLayout)
        }
        wallpaperView.isHidden = !wallpaperActive
        // Ảnh nền luôn đục — độ trong suốt phím chỉ đụng phím (KeyboardPalette.wallpaperLayer).
        let wl = palette.wallpaperLayer(dim: themeSettings.dim)
        wallpaperView.alpha = CGFloat(wl.imageAlpha)
        wallpaperDim.isHidden = !wallpaperActive
        wallpaperDim.backgroundColor = wl.overlay.ui
        if !wallpaperActive {
            wallpaperView.image = nil          // nhả bitmap ngay khi tắt ảnh nền
            spotlight?.setPhoto(nil)
            wallpaperLoadedFor = .zero
            wallpaperGate.cancel()             // việc đang chờ không gán lại ảnh
        } else {
            wallpaperLoadedFor = .zero         // version/cỡ có thể đã đổi → nạp lại
            setNeedsLayout()
        }
        applyThemeScreens()
    }

    /// Ảnh nền theme (ảnh nền người dùng đang bật thì thắng) + tiền cảnh. Không có ⇒ ẩn, nhả bitmap.
    private func applyThemeScreens() {
        let bg = ThemeAssetPlan.showsThemeBackground(userWallpaperActive: wallpaperActive,
                                                     themeBackgroundReady: themeAssets?.backgroundURL != nil)
        let fg = themeAssets?.foregroundURL != nil
        themeImageView.isHidden = !bg
        if !bg { themeImageView.image = nil }
        if fg, foregroundView.superview == nil {
            foregroundView.isUserInteractionEnabled = false     // chạm xuyên xuống phím
            foregroundView.contentMode = .scaleToFill           // căng đúng cỡ bàn phím
            foregroundView.clipsToBounds = true
            foregroundView.frame = bounds
            insertSubview(foregroundView, aboveSubview: rowsContainer)
        }
        foregroundView.isHidden = !fg
        if !fg { foregroundView.image = nil }
        themeScreenLoadedFor = nil
        if bg || fg { setNeedsLayout() }
    }

    /// Giải ảnh nền / tiền cảnh theme ở đúng cỡ view, ngoài main (một lần mỗi cỡ + theme).
    private func loadThemeScreensIfNeeded() {
        guard let a = themeAssets, a.backgroundURL != nil || a.foregroundURL != nil,
              bounds.width > 0, bounds.height > 0 else { return }
        if foregroundView.superview === self, foregroundView.frame != bounds { foregroundView.frame = bounds }
        if let l = themeScreenLoadedFor, l.size == bounds.size, l.sig == a.signature { return }
        guard !deferDecodeForInterimSize() else { return }
        themeScreenLoadedFor = (bounds.size, a.signature)
        let size = bounds.size, sig = a.signature
        let scale = Wallpaper.decodeScale(screenScale: window?.screen.scale ?? UIScreen.main.scale)
        let bgURL = themeImageView.isHidden ? nil : a.backgroundURL, fgURL = a.foregroundURL
        let gate = themeScreenGate, ticket = gate.next()
        Wallpaper.queue.async { [weak self] in
            guard gate.isCurrent(ticket) else { return }     // đã có yêu cầu mới hơn (khung tạm) ⇒ không giải
            let bg = bgURL.flatMap { ThemeAssetLoader.loadScreen($0, viewSize: size, scale: scale, fill: true) }
            guard gate.isCurrent(ticket) else { return }
            let fg = fgURL.flatMap { ThemeAssetLoader.loadScreen($0, viewSize: size, scale: scale, fill: false) }
            DispatchQueue.main.async {
                guard let self, self.themeAssets?.signature == sig else { return }
                switch gate.verdict(ticket, requested: size, current: self.bounds.size) {
                case .stale: return
                case .resized:
                    // Đổi cỡ trong lúc giải: xin lại ở cỡ hiện tại (cùng cỡ cũ quay lại cũng phải gán).
                    self.themeScreenLoadedFor = nil; self.setNeedsLayout(); return
                case .apply: break
                }
                #if DEBUG
                self.debugThemeScreenApplies.append(size)
                #endif
                if !self.themeImageView.isHidden { self.themeImageView.image = bg }
                if !self.foregroundView.isHidden { self.foregroundView.image = fg }
            }
        }
    }

    /// true ⇒ view đang ở khung tạm của host (chiều cao ≠ chiều cao xin — SizedDecodeGate.isInterim):
    /// hoãn giải ảnh, hẹn kiểm lại sau settleDelay. Cỡ đứng yên đủ lâu (host giữ cỡ khác) ⇒ coi là cỡ
    /// cuối và giải — ảnh nền KHÔNG bao giờ bị bỏ. Chỉ view của controller (primesLastHeight): view
    /// dựng riêng (test, preview) không có chuỗi khung host.
    private func deferDecodeForInterimSize() -> Bool {
        guard primesLastHeight, settledSize != bounds.size,
              SizedDecodeGate.isInterim(viewHeight: bounds.height, expected: constraintHeight) else { return false }
        let size = bounds.size
        if let p = pendingSettle, p.size == size { return true }
        pendingSettle?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.pendingSettle = nil
            guard self.bounds.size == size else { return }   // lại đổi cỡ: lượt layout của cỡ mới tự lo
            self.settledSize = size
            self.loadWallpaperIfNeeded()
            self.loadThemeScreensIfNeeded()
        }
        pendingSettle = (size, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + SizedDecodeGate.settleDelay, execute: work)
        return true
    }

    private static let systemMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    /// Nền theme / ảnh nền / lớp phủ phủ TRỌN view (= cả input view: strip, headroom balloon,
    /// phần host cấp dư hoặc thiếu) — đặt frame tường minh mỗi lượt layout, không dựa
    /// autoresizing từ frame lúc chèn (có thể là .zero).
    private func layoutBackdrop() {
        for v in [themeBackdrop, themeImageView, wallpaperView, wallpaperDim] where v.superview === self && v.frame != bounds {
            v.frame = bounds
        }
        layoutDecoration()
        layoutAurora()
        if let g = bgGradient, !g.isHidden, g.frame != themeBackdrop.bounds {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            g.frame = themeBackdrop.bounds
            CATransaction.commit()
        }
        layoutCornerGlyph()
        layoutRainbow()
        layoutStringGaps()
    }

    /// "bg2": gradient dọc bg → bg2 phủ trọn nền (vẽ một lần — 0 chi phí mỗi phím). Không có ⇒ ẩn (nếu từng dựng).
    private func applyBackgroundGradient(hidden: Bool) {
        guard let top = palette.background, let bottom = palette.background2, !hidden else {
            bgGradient?.isHidden = true; return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let g = bgGradient ?? CAGradientLayer()
        if bgGradient == nil {
            g.startPoint = CGPoint(x: 0.5, y: 0); g.endPoint = CGPoint(x: 0.5, y: 1)
            themeBackdrop.layer.insertSublayer(g, at: 0)
            bgGradient = g
        }
        g.colors = [top.ui.cgColor, bottom.ui.cgColor]
        g.isHidden = false
        g.frame = themeBackdrop.bounds
        CATransaction.commit()
    }
    #if DEBUG
    var debugBackgroundGradient: CAGradientLayer? { bgGradient }
    #endif

    /// Cỡ ký hiệu góc (pt) + độ đậm so với chữ theme. Android ImeRootView y hệt (CornerGlyph).
    static let cornerGlyphSize: CGFloat = 26
    static let cornerGlyphAlpha: CGFloat = 0.22

    private func applyCornerGlyph(hidden: Bool) {
        guard let g = palette.cornerGlyph, !hidden else { cornerGlyphLayer?.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let l = cornerGlyphLayer ?? {
            let t = CATextLayer()
            t.contentsScale = UIScreen.main.scale
            t.alignmentMode = .right
            t.font = UIFont.systemFont(ofSize: Self.cornerGlyphSize)
            t.fontSize = Self.cornerGlyphSize
            themeBackdrop.layer.addSublayer(t)
            cornerGlyphLayer = t
            return t
        }()
        l.string = g
        l.foregroundColor = palette.ink.ui.withAlphaComponent(Self.cornerGlyphAlpha).cgColor
        l.isHidden = false
        CATransaction.commit()
        layoutCornerGlyph()
    }

    private func layoutCornerGlyph() {
        guard let l = cornerGlyphLayer, !l.isHidden else { return }
        // Góc trên phải NỘI DUNG (gốc 0 của view — #151 phần host cấp dư nằm trên).
        let top = themeBackdrop.convert(CGPoint.zero, from: self).y
        let h = Self.cornerGlyphSize * 1.25
        let f = CGRect(x: themeBackdrop.bounds.width - h * 1.6 - 6, y: top + 4, width: h * 1.6, height: h)
        guard l.frame != f else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.frame = f
        CATransaction.commit()
    }

    private func applyAurora(hidden: Bool) {
        guard palette.auroraBorder, !hidden else { auroraBand?.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Tự hào: dải theo sọc cờ — đổi cờ ⇒ dựng lại (chỉ lúc đổi theme / cờ).
        let band = palette.auroraColors.map(AuroraFx.stops) ?? AuroraFx.band
        if let g = auroraBand, (g.locations ?? []).map(\.doubleValue) != band.map(\.location) || auroraBandColors != palette.auroraColors {
            g.removeFromSuperlayer(); auroraBand = nil
        }
        auroraBandColors = palette.auroraColors
        if auroraBand == nil {
            let g = CAGradientLayer()
            g.colors = band.map { v -> CGColor in
                UIColor(red: CGFloat((v.color >> 16) & 0xFF) / 255, green: CGFloat((v.color >> 8) & 0xFF) / 255,
                        blue: CGFloat(v.color & 0xFF) / 255, alpha: 1).cgColor
            }
            g.locations = band.map { NSNumber(value: $0.location) }
            g.startPoint = CGPoint(x: 0, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            let m = CAGradientLayer()   // độ đậm theo chiều dọc: AuroraFx.bandOpacity (mép trên → 0)
            let steps = 6
            m.colors = (0...steps).map { UIColor(white: 1, alpha: CGFloat(AuroraFx.bandOpacity(AuroraFx.bandHeight * Double($0) / Double(steps)))).cgColor }
            m.locations = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
            g.mask = m
            themeBackdrop.layer.insertSublayer(g, at: 0)
            auroraBand = g
        }
        auroraBand?.isHidden = false
        CATransaction.commit()
        layoutAurora()
    }

    private func layoutAurora() {
        guard let g = auroraBand, !g.isHidden else { return }
        // Mép trên NỘI DUNG (gốc 0 của view) — khi host cấp dư (#151) phần dư nằm trên, dải vẫn sát thanh gợi ý.
        let top = themeBackdrop.convert(CGPoint.zero, from: self).y
        let f = CGRect(x: 0, y: top, width: themeBackdrop.bounds.width, height: CGFloat(AuroraFx.bandHeight))
        guard g.frame != f else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        g.frame = f
        g.mask?.frame = g.bounds
        CATransaction.commit()
    }

    /// Khe giữa các hàng phím (toạ độ view) từ khung phím của lượt layout này — chỉ gọi lúc layout (hoạ tiết / Rung dây).
    private func keyRowGaps() -> [KeyboardDecoration.Gap] {
        if snapState == .showing {
            // Khung đầu còn là ảnh lưới phím: khe hàng theo khung phím lưu kèm ảnh (hoạ tiết / cảnh nền
            // dựng sống đúng chỗ ngay khung đầu).
            return KeyboardDecoration.rowGaps(snapOutlines.map {
                let f = rowsContainer.convert($0.rect, to: self)
                return (Double(f.minY), Double(f.maxY))
            })
        }
        rowsContainer.layoutIfNeeded()            // khung phím của lượt layout này (hàng xếp lồng nhau)
        var spans: [(top: Double, bottom: Double)] = []
        for row in rowsContainer.arrangedSubviews where !row.isHidden {
            row.layoutIfNeeded()
            func walk(_ v: UIView) {
                if v is KeyButton, !v.isHidden, v.bounds.height > 0 {
                    let f = v.convert(v.bounds, to: self)
                    spans.append((Double(f.minY), Double(f.maxY)))
                } else { v.subviews.forEach(walk) }
            }
            walk(row)
        }
        return KeyboardDecoration.rowGaps(spans)
    }

    /// Rung dây: khe hàng cho overlay (dây rung ở khe gần phím). Kiểu khác ⇒ không làm gì (0 chi phí).
    private func layoutStringGaps() {
        guard let o = keyEffects, o.effect == .string else { return }
        let g = keyRowGaps()
        if g != o.stringGaps { o.stringGaps = g }
    }

    /// Hoạ tiết theme: bật/tắt + màu (mỗi lần đổi theme / sáng-tối). Không theme nào có hoạ tiết
    /// ⇒ layer chưa từng được thêm (0 chi phí như trước).
    private func applyDecoration(hidden: Bool) {
        guard let d = palette.decoration, !hidden else {
            if decorLayer.superlayer != nil { decorLayer.isHidden = true }
            decorShade?.isHidden = true
            sceneLayer?.isHidden = true
            return
        }
        if d.isScene, sceneLayer == nil {
            let l = ThemeSceneLayer()
            themeBackdrop.layer.insertSublayer(l, at: 0)
            sceneLayer = l
        }
        sceneLayer?.isHidden = !d.isScene
        sceneLayer?.opacity = Float(palette.surfaceAlpha)   // độ trong suốt phím: cảnh mờ theo nền
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if decorLayer.superlayer == nil { themeBackdrop.layer.addSublayer(decorLayer) }
        decorLayer.isHidden = false
        if d.hasShade {
            if decorShade == nil {
                let g = CAGradientLayer()
                g.colors = KeyboardDecoration.bokehShade.map { RGBA(hex: $0.argb & 0xFF_FFFF, alpha: Double($0.argb >> 24) / 255).ui.cgColor }
                g.locations = KeyboardDecoration.bokehShade.map { NSNumber(value: $0.location) }
                themeBackdrop.layer.insertSublayer(g, below: decorLayer)
                decorShade = g
            }
            decorShade?.isHidden = false
            decorShade?.frame = themeBackdrop.bounds
        } else {
            decorShade?.isHidden = true
        }
        decorLayer.fillColor = d.color.ui.cgColor
        decorGaps = nil                           // motif có thể đã đổi → dựng lại path
        CATransaction.commit()
        layoutDecoration()
    }

    private func layoutDecoration() {
        guard let d = palette.decoration, decorLayer.superlayer != nil, !decorLayer.isHidden else { return }
        let size = themeBackdrop.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if let g = decorShade, !g.isHidden, g.frame != themeBackdrop.bounds {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            g.frame = themeBackdrop.bounds
            CATransaction.commit()
        }
        if d.isScene, let l = sceneLayer {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            l.update(motif: d.motif, color: d.color, dark: palette.surfaceDark ?? palette.isDark, size: size)
            CATransaction.commit()
        }
        // Khe giữa các hàng phím (toạ độ view) — chỉ khi layout (không mỗi lần gõ), chỉ theme có hoạ tiết.
        let gaps = keyRowGaps()
        guard gaps != decorGaps || size.width != decorWidth else { return }
        decorGaps = gaps; decorWidth = size.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        decorLayer.frame = CGRect(origin: .zero, size: size)
        decorLayer.path = d.isScene ? nil
            : d.path(KeyboardDecoration.placements(width: Double(size.width), gaps: gaps, density: d.density), width: Double(size.width))
        CATransaction.commit()
    }
    #if DEBUG
    /// Test: cỡ (lúc xin) của mỗi lần ảnh nền / ảnh theme thật sự được gán — mới nhất thắng.
    var debugWallpaperApplies: [CGSize] = []
    var debugThemeScreenApplies: [CGSize] = []
    /// Test: frame nền theme / ảnh nền / lớp phủ + bán kính bo.
    var debugBackdrop: (frames: [CGRect], radius: CGFloat) {
        ([themeBackdrop.frame, wallpaperView.frame, wallpaperDim.frame], themeBackdrop.layer.cornerRadius)
    }
    /// Test: alpha ảnh nền + màu lớp phủ (độ trong suốt phím không được làm mất ảnh nền).
    var debugWallpaperLayer: (alpha: CGFloat, overlay: UIColor?) { (wallpaperView.alpha, wallpaperDim.backgroundColor) }
    /// Test: palette đã giải (theme + tuỳ chỉnh riêng theme + độ trong suốt) — giải một lần mỗi lần hiện.
    var debugPalette: KeyboardPalette { palette }
    /// Test: nền + màu glyph phím ⇧ khi bật (màu nhấn nếu người dùng chọn).
    var debugShiftOnColors: (fill: UIColor, ink: UIColor) { (shiftOnFill, shiftOnInk) }
    /// Test: dải phủ nền của motif "bokeh" đang hiện (Mưa đêm) — nil = chưa từng dựng.
    var debugDecorShade: CAGradientLayer? { decorShade.flatMap { $0.isHidden ? nil : $0 } }
    /// Test: hoạ tiết nền đang hiện (có path) hay không.
    var debugDecorationVisible: Bool {
        decorLayer.superlayer != nil && !decorLayer.isHidden && !themeBackdrop.isHidden && decorLayer.path != nil
    }
    /// Test: khung (toạ độ view) của từng motif đang vẽ + khung mọi phím đang hiện.
    var debugDecorationBoxes: (motifs: [CGRect], keys: [CGRect]) {
        let motifs = KeyboardDecoration.placements(width: Double(decorWidth), gaps: decorGaps ?? [], density: palette.decoration?.density ?? 100)
            .map { CGRect(x: $0.x - $0.size / 2, y: $0.y - $0.size / 2, width: $0.size, height: $0.size) }
        var keys: [CGRect] = []
        func walk(_ v: UIView) {
            if v is KeyButton, !v.isHidden { keys.append(v.convert(v.bounds, to: self)) } else { v.subviews.forEach(walk) }
        }
        walk(rowsContainer)
        return (decorLayer.isHidden ? [] : motifs, keys)
    }
    var debugRowsMinY: CGFloat { rowsContainer.frame.minY }
    /// Test: khung dòng chữ gợi ý (toạ độ view) — Mắt AI canh tâm dọc theo đó.
    var debugSuggestionBarFrame: CGRect { suggestionBar.frame }
    /// Test: số lớp lỗ thoát âm trên phím cách chính (Ghi-ta: 3; theme khác: 0) + path lỗ tối.
    var debugSoundhole: (count: Int, hole: CGPath?) { (spaceBarButton?.soundholeLayers.count ?? 0, spaceBarButton?.soundholeLayers.first?.path) }
    #endif

    /// Giải ảnh nền ở đúng cỡ view, ngoài main thread (ImageIO thumbnail).
    private func loadWallpaperIfNeeded() {
        guard wallpaperActive, bounds.width > 0, bounds.height > 0,
              bounds.size != wallpaperLoadedFor else { return }
        guard !deferDecodeForInterimSize() else { return }   // khung tạm của host: chưa giải
        wallpaperLoadedFor = bounds.size
        let size = bounds.size
        let scale = Wallpaper.decodeScale(screenScale: window?.screen.scale ?? UIScreen.main.scale)
        let version = themeSettings.version
        let gate = wallpaperGate, ticket = gate.next()
        Wallpaper.queue.async { [weak self] in
            // Vé cũ (đã có yêu cầu ở cỡ khác) ⇒ bỏ: không giải, không đuổi ảnh đang cache.
            guard gate.isCurrent(ticket) else { return }
            let img = Wallpaper.loadForKeyboard(version: version, viewSize: size, scale: scale,
                                                stillWanted: { gate.isCurrent(ticket) })
            DispatchQueue.main.async {
                guard let self, self.wallpaperActive else { return }
                switch gate.verdict(ticket, requested: size, current: self.bounds.size) {
                case .stale: return
                case .resized:
                    // Đổi cỡ trong lúc giải: xin lại ở cỡ hiện tại (cùng cỡ cũ quay lại cũng phải gán).
                    self.wallpaperLoadedFor = .zero; self.setNeedsLayout(); return
                case .apply: break
                }
                #if DEBUG
                self.debugWallpaperApplies.append(size)
                #endif
                self.wallpaperView.image = img
                self.spotlight?.setPhoto(img?.cgImage)   // Đèn rọi: CÙNG CGImage (không sao chép)
            }
        }
    }

    func applyAppearance(_ appearance: UIKeyboardAppearance, style: UIUserInterfaceStyle) {
        StartupTrace.span("kv.applyAppearance") { applyAppearanceBody(appearance, style: style) }
    }
    private func applyAppearanceBody(_ appearance: UIKeyboardAppearance, style: UIUserInterfaceStyle) {
        systemDark = AppearancePolicy.isDark(appearance: appearance, style: style)
        themeSettings = ThemeSettings.load(UserDefaultsProvider.shared)
        // Tệp tải về: chỉ theme có khai báo mới đọc mục lục / giải ảnh (một lần, cache theo chữ ký).
        let assetSpec = themeSettings.effectiveKeyStyle.assets
        if assetSpec.isEmpty {
            if downloadedAssets != nil { ThemeAssetLoader.dropCache() }
            downloadedAssets = nil
        } else {
            downloadedAssets = ThemeAssetLoader.load(ThemeAssetPlan.make(assetSpec))
        }
        themeAssets = downloadedAssets
        applyKeyStyle(themeSettings.effectiveKeyStyle)
        suggestionInk = SuggestionInk.load(UserDefaultsProvider.shared)   // "Màu chữ gợi ý" — resolvePalette áp
        resolvePalette()
        configureKeyEffects()
        configureSwipeTrail()
        configureRainbow()
        StartupTrace.span("kv.buddy") { configureBuddy() }
        configureMole()
        configureSpotlight()
        // Chiều cao hàng phím ±10pt (Settings → Giao diện) — đọc mỗi lần hiện. Bản cũ (có công
        // tắc "Kích thước như bàn phím iPhone") chưa được app chuyển đổi ⇒ tính trong bộ nhớ,
        // không ghi (KeyGeometry.RowAdjust.effectiveAdjust).
        let screen = window?.windowScene?.screen.bounds.size ?? UIScreen.main.bounds.size
        rowHeightAdjust = CGFloat(KeyGeometry.RowAdjust.effectiveAdjust(
            UserDefaultsProvider.shared, pad: Self.isPad, portraitWidth: min(screen.width, screen.height)))
        keyboardRaise = CGFloat(KeyGeometry.RowAdjust.raise(UserDefaultsProvider.shared))
        numberRowEnabled = UserDefaultsProvider.shared?.bool(forKey: Self.numberRowKey) ?? false
        numberRowFullHeight = UserDefaultsProvider.shared?.bool(forKey: KeyGeometry.numberRowFullHeightKey) ?? false
        spaceSideKey = SpaceSideKey.load(UserDefaultsProvider.shared)
        symbolReturn = SymbolReturn.load(UserDefaultsProvider.shared)
        largeKeys = LargeKeys.load(UserDefaultsProvider.shared)
        emojiKeyPlacement = EmojiKeyPlacement.load(UserDefaultsProvider.shared)
        dismissButtonEnabled = KeyboardDismissButton.load(UserDefaultsProvider.shared)   // "Nút ẩn bàn phím"
        suggestionBar.setting = SuggestionCount.load(UserDefaultsProvider.shared)   // "Số từ gợi ý"
        barHeight = SuggestionBarHeight.load(UserDefaultsProvider.shared)   // "Chiều cao thanh gợi ý" — rebuild() cuối hàm áp
        // Bàn phím tách đôi (mặc định TẮT) — rebuild() cuối hàm áp nếu đổi.
        splitSetting = UserDefaultsProvider.shared?.bool(forKey: SplitLayout.settingKey) ?? false
        keyPreviewEnabled = Self.keyPreviewSetting(UserDefaultsProvider.shared)
        if !keyPreviewEnabled { hideBalloon() }
        keyPressHighlightEnabled = Self.keyPressHighlightSetting(UserDefaultsProvider.shared)
        snapshotSettingOff = KeySnapshot.featureOn && (UserDefaultsProvider.shared?.bool(forKey: KeySnapshot.disableKey) ?? false)
        // Mẫu câu: danh sách user tự quản trong app + toggle bật/tắt.
        let d = UserDefaultsProvider.shared
        templatesEnabled = d?.object(forKey: "templatesEnabled") == nil
            || d?.bool(forKey: "templatesEnabled") == true
        templatesAsList = d?.bool(forKey: "templatesAsList") == true
        userTemplatesCache = nil      // đọc lại (lười) lần mở plane mẫu câu kế — app có thể vừa sửa
        if !templatesEnabled, !textToolsEnabled, plane == .templates { plane = .letters }
        rebuild()
    }

    /// needsInputModeSwitchKey chỉ đáng tin SAU khi extension nối host —
    /// đánh giá lại ở viewWillAppear; đổi thì dựng lại hàng đáy.
    func setNeedsGlobe(_ on: Bool) {
        guard on != needsGlobe else { return }
        needsGlobe = on
        rebuild()   // globe nằm trong chữ ký → cache (hàng đáy cũ) bị vứt
    }

    /// Viết hoa đầu câu theo context hiện tại (controller đọc proxy) — nil = không áp.
    var autoShiftProbe: (() -> Bool?)?

    /// Về plane chữ bằng ABC: đánh giá lại shift (PlanePolicy.shiftOnReturnToLetters)
    /// thay vì ép off — ". " vừa gõ ở plane 123 phải viết hoa chữ kế. CAPS giữ nguyên.
    /// rebuild() ngay sau áp giao diện (cache) hoặc dựng phím theo shift mới.
    private func reevaluateShiftForLetters() {
        guard shift != .caps else { return }
        shift = PlanePolicy.shiftOnReturnToLetters(autoShift: autoShiftProbe?()) ? .on : .off
    }

    /// "Về bàn chữ sau ký hiệu" (Phím & cử chỉ, mặc định Tự động — SymbolReturn). Đọc lúc hiện
    /// (applyAppearance); không đổi bố cục ⇒ không rebuild.
    var symbolReturn: SymbolReturn = .defaultValue

    /// Ký tự ngay trước con trỏ (controller đọc proxy) — chỉ hỏi khi chạm "." "," ":" ở 123/#+=.
    var contextBeforeProbe: (() -> Character?)?

    /// Chèn ký tự của phím số/ký hiệu; ở plane 123/#+= mà là dấu kết vế ⇒ về chữ ngay
    /// (PlanePolicy.returnToLettersAfterSymbol), đánh giá lại viết hoa như chạm ABC.
    private func tapSymbol(_ s: String) {
        let inPlane = plane == .numbers || plane == .symbols
        let before = inPlane && PlanePolicy.needsBefore(s, mode: symbolReturn) ? contextBeforeProbe?() : nil
        tapped(.text(s))
        guard inPlane, plane == .numbers || plane == .symbols,
              PlanePolicy.returnToLettersAfterSymbol(s, mode: symbolReturn, inSymbolPlane: true,
                                                      numericField: inputKind == .number, before: before)
        else { return }
        plane = .letters
        reevaluateShiftForLetters()
        rebuild()
    }
    #if DEBUG
    /// Test: chạm phím ký tự `s` ở plane hiện tại (đường chốt của textButton).
    func debugTapSymbol(_ s: String) { typedInSymbolPlane = true; tapSymbol(s) }
    #endif

    /// Sentence-start auto-shift (only upgrades OFF→ON; never downgrades CAPS).
    func setAutoShift(_ on: Bool) {
        shiftTouchedByHand = false
        guard shift != .caps, plane != .emojiSearch else { return }
        let want: ShiftState = on ? .on : .off
        if shift != want { shift = want; applyShiftAppearance() }
    }


    // Shift changes must NEVER rebuild: tearing the buttons down mid-typing
    // deallocates the key already under the user's finger, so its touch-up
    // never fires (the missed-keypress bug). Retitle in place instead.
    private var letterKeys: [(button: KeyButton, base: String)] = []
    private weak var spaceBar: KeyButton?
    private var spaceBarButton: KeyButton? { spaceBar as? KeyButton }
    private weak var spaceLogo: UIImageView?
    /// Mã "VI"/"EN" góc dưới-phải phím cách (thay logo khi bật vuốt đổi ngôn ngữ — SpaceMark).
    private weak var spaceCode: UILabel?
    /// Logo hoặc mã ngôn ngữ đang trên phím cách (ẩn/hiện khi trượt nhãn, badge).
    private var spaceMarkView: UIView? { spaceCode ?? spaceLogo }
    private weak var indentedRow: KeyRow?
    private var indentedRowInset: CGFloat = 0
    private var shiftKeys: [KeyButton] = []   // iPad có 2 shift
    private func applyShiftAppearance() {
        if snapState == .showing { goLive(); return }   // ảnh chụp shift cũ ⇒ phím thật (dựng theo shift mới)
        for (b, s) in letterKeys {
            let t = shift == .off ? s : s.uppercased()
            b.setTitle(t, for: .normal)
            if let k = b as? KeyButton { applyKeycapFont(k, title: t) }
        }
        for b in shiftKeys {
            let symbol = shift == .caps ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
            b.setImage(UIImage(systemName: symbol), for: .normal)
            // Shift ON/CAPS = phím đảo màu (nền trắng, glyph đen) như stock —
            // cả dark mode, nếu không ON và OFF trông y hệt nhau.
            let fill = shift != .off ? shiftOnFill : fnFill
            b.tintColor = shift != .off ? shiftOnInk : fnInk
            b.normalBackground = fill
            // ⇧ đổi trạng thái ở touchDown — ngón còn đè thì giữ nền sẫm, nhả tay mới về nền mới.
            if let k = b as? KeyButton, k.skin != nil {
                // Skin theme: glyph theo chữ phím chức năng (đọc được trên skin); bật = ảnh đè của skin (nếu có).
                b.tintColor = fnInk
                k.setSkinLatched(shift != .off)
                continue
            }
            if !((b as? KeyButton)?.pressShown ?? false) { b.backgroundColor = fill }
        }
        capsKey?.setImage(UIImage(systemName: shift == .caps ? "capslock.fill" : "capslock"),
                          for: .normal)
    }
    private weak var capsKey: KeyButton?
    /// Shift ON = phím trắng glyph đen; phím trong suốt quá nửa thì glyph theo chữ phím.
    /// "Màu nhấn" (Tuỳ chỉnh nâng cao) ⇒ phím ⇧ bật tô màu nhấn + chữ trên nhấn (palette.accentShift).
    private var shiftOnFill: UIColor {
        palette.accentShift ? palette.accent.ui : RGBA.white.alpha(palette.surfaceAlpha).ui
    }
    private var shiftOnInk: UIColor {
        if palette.accentShift { return palette.accentInk.ui }
        return palette.surfaceAlpha >= 0.5 ? RGBA.black.alpha(palette.keyInk.a).ui : ink
    }


    // MARK: chế độ một tay (iPhone)

    /// Chế độ hiện tại. Controller đặt lúc hiện (configureOneHand, theo OneHand.resolve);
    /// bàn phím tự đổi qua giữ lâu burger / rail rồi báo
    /// onOneHandChange để controller lưu.
    private(set) var oneHand: OneHandSide = .off
    /// Bên dùng gần nhất — giữ lâu bật lại bên này.
    var lastOneHandSide: OneHandSide = .right
    var onOneHandChange: ((OneHandSide) -> Void)?

    /// Đặt từ controller (không báo lại). iPad luôn tắt.
    func configureOneHand(_ side: OneHandSide) {
        let s = Self.isPad ? .off : side
        guard s != oneHand else { return }
        oneHand = s
        if s != .off { lastOneHandSide = s }
        applyOneHand()
        setNeedsLayout()
    }

    /// Người dùng đổi trên bàn phím.
    private func setOneHand(_ side: OneHandSide) {
        configureOneHand(side)
        onOneHandChange?(oneHand)
    }

    /// Plane hiện tại có thu hẹp không (emoji / mẫu câu tự dàn đầy bề ngang).
    private var oneHandActive: Bool {
        oneHand != .off && !Self.isPad && plane != .emoji && plane != .templates
            && plane != .emojiSearch   // họ emoji: ô tìm + chữ đầy bề ngang (Android y hệt)
            && !splitMode              // bàn tách đôi đã chia hai bên — một tay vô nghĩa
    }
    /// Bề ngang vùng phím (thụt hàng 2 tính theo đây).
    private var keysWidth: CGFloat {
        oneHandActive ? bounds.width * OneHand.ratio : bounds.width
    }

    private func applyOneHand() {
        let side: OneHandSide = oneHandActive ? oneHand : .off
        let i = OneHand.insets(width: bounds.width, side: side)
        if rowsSideInsets != (i.left, i.right) { rowsSideInsets = (i.left, i.right); setNeedsLayout() }
        layoutRail(side)
    }

    /// Rail: 2 nút tròn ở dải trống — đổi bên (trên) / thoát (dưới). Chỉ tạo khi cần.
    private var railButtons: [KeyButton] = []
    private func layoutRail(_ side: OneHandSide) {
        guard let r = OneHand.rail(width: bounds.width, side: side), r.width >= 24 else {
            railButtons.forEach { $0.isHidden = true }
            return
        }
        if railButtons.isEmpty {
            for (i, symbol) in ["arrow.left.arrow.right", "arrow.up.left.and.arrow.down.right"].enumerated() {
                let b = baseButton(title: "", special: true)
                b.styledKey = false        // nút tròn của rail, không phải phím
                b.setSkin(nil)
                b.setImage(UIImage(systemName: symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
                b.accessibilityLabel = i == 0 ? L("Đổi bên bàn phím một tay") : L("Thoát chế độ một tay")
                b.addAction(UIAction { _ in Self.clickModifier() }, for: .touchDown)
                b.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    self.setOneHand(i == 0 ? self.oneHand.switched : .off)
                }, for: .touchUpInside)
                addSubview(b)
                railButtons.append(b)
            }
        }
        let top = rowsTopWanted
        let h = max(layoutHeight - top, 0)
        let size = min(r.width - 12, 44)
        for (i, b) in railButtons.enumerated() {
            let cy = top + h * (i == 0 ? 0.3 : 0.7)
            b.frame = CGRect(x: r.x + (r.width - size) / 2, y: cy - size / 2, width: size, height: size)
            b.layer.cornerRadius = size / 2
            b.backgroundColor = specialFill
            b.normalBackground = specialFill
            b.pressedBackground = plainFill
            b.tintColor = dark ? .white : .black
            b.isHidden = false
            bringSubviewToFront(b)
        }
    }

    // MARK: layout

    // Dedupe: rebuild bị gọi nhiều lần mỗi lần hiện (init, configureReturnKey,
    // applyAppearance, configureInputKind, setNeedsGlobe) — chỉ xé/dựng lại khi
    // có gì đó thật sự đổi. Chữ ký = mọi thứ làm nhãn/màu/inset/hàng đáy của
    // plane khác đi; đổi chữ ký → mọi plane cache đều sai nên vứt hết.
    private var builtPlane: Plane?
    private var builtReturn = ""
    private var builtDark = false
    private var builtPalette = KeyboardTheme.system.palette(systemDark: false)
    private var builtWidth: CGFloat = -1
    private var builtGlobe = false
    private var builtKind: InputKind = .normal
    private var builtNumberRow = false
    private var builtNumberRowFull = false
    private var builtSpaceSide: SpaceSideKey = .defaultValue
    private var builtLargeKeys = LargeKeys.defaultValue
    private var builtEmojiInBar = false
    private var builtPressHighlight = KeyboardView.keyPressHighlightDefault
    /// Khe/lề dựng vào constraint lúc build (preset stock: dọc ≠ ngang) — đổi là dựng lại.
    /// (Phần cắt / đệm hàng đáy đổi tại chỗ ở applyBottomTrim — không cần dựng lại.)
    private struct GeomSig: Equatable { let gap, keyGap, sideMargin: CGFloat }
    private var geomSig: GeomSig {
        let s = rowSpec
        return GeomSig(gap: s.gap, keyGap: s.keyGap, sideMargin: s.sideMargin)
    }
    private var builtGeom: GeomSig?
    private var builtKeyStyle = KeyStyle()

    // Cache view theo plane: bấm 123/#+=/ABC chỉ tráo arrangedSubviews thay vì
    // xé/dựng lại ~40 button + constraints mỗi lần. Emoji KHÔNG cache (recents
    // phải tươi mỗi lần mở). Đổi return/dark/width → mọi plane cache đều sai
    // nhãn/màu/inset nên vứt hết.
    private struct CachedPlane {
        let rows: [UIView]
        let letterKeys: [(button: KeyButton, base: String)]
        let shiftKeys: [KeyButton]
        let spaceBar: KeyButton?
        let spaceLogo: UIImageView?
        let spaceCode: UILabel?
        let indentedRow: KeyRow?
        let indentedRowInset: CGFloat
        let crossRow: [NSLayoutConstraint]
        let distribution: UIStackView.Distribution   // bàn số lớn (chế độ stack)
        let mode: KeyGridView.Mode
        let heights: KeyRowLayout.Heights            // chế độ lưới: chiều cao hàng
    }
    /// Ràng buộc GIỮA các hàng — chỉ còn bàn số lớn (chế độ stack: số 0 rộng bằng số 1). UIKit
    /// tự gỡ chúng khi row rời hierarchy (lúc tráo plane) — lưu lại để bật lại khi
    /// khôi phục từ cache (bug 26/09/2026: về từ mẫu câu, phím lệch cỡ).
    private var crossRowConstraints: [NSLayoutConstraint] = []
    private func crossRow(_ c: NSLayoutConstraint) {
        c.isActive = true
        crossRowConstraints.append(c)
    }
    private var planeCache: [Plane: CachedPlane] = [:]
    #if DEBUG
    static var perfFullBuilds = 0   // xé + dựng mới cả plane (đắt)
    static var perfCacheSwaps = 0   // tráo rows từ planeCache (rẻ)
    /// Lượt layoutSubviews của KeyboardView / của mọi KeyButton (KeyboardRenderBudgetTests).
    static var perfLayoutPasses = 0
    static var perfKeyLayoutPasses = 0
    #endif

    // MARK: ảnh lưới phím cho khung đầu (KeySnapshot — StartupTrace.swift, docs/KEYBOARD-STARTUP.md §6)

    /// off: chưa xét · armed: có ảnh cùng khoá trạng thái, hoãn dựng tới lượt layout (biết khung) ·
    /// showing: khung đang là ảnh, phím thật chưa dựng · done: đã dựng thật / không dùng ảnh — đời
    /// view này không xét lại.
    private enum SnapState { case off, armed, showing, done }
    private var snapState: SnapState = .off
    private var snapLayer: CALayer?
    private var snapEntry: KeySnapshot.Entry?
    /// Khung từng phím lưu kèm ảnh — viền cầu vồng / cực quang / Ảo giác (lớp RIÊNG trên hàng phím, không
    /// nằm trong ảnh) vẽ đúng chỗ ngay khung đầu, trên ảnh.
    private var snapOutlines: [KeySnapshot.Store.Outline] = []
    /// Nhãn "ViệtTelex" xin lúc chưa có phím cách thật — hiện khi phím thật dựng.
    private var snapBadgePending = false
    /// Đã có chạm / phím từ lúc hiện ⇒ không còn trạng thái mở đầu, không chụp.
    private var snapInteracted = false
    private var snapCaptureScheduled = false
    /// Công tắc chạy `KeySnapshot.disableKey` (đọc ở applyAppearance).
    private var snapshotSettingOff = false
    private let snapPost = PostFrameWork()
    /// Đang trong layoutSubviews (goLive khi đó không gọi layoutIfNeeded lồng).
    private var inLayoutPass = false

    private var snapshotEnabled: Bool { KeySnapshot.featureOn && !snapshotSettingOff }
    /// Lưới hợp lệ cho ảnh: plane chữ / số / ký hiệu (emoji, mẫu câu chứa nội dung người dùng; bàn số
    /// lớn, tìm emoji bỏ qua) và không lớp phủ nào bám khung TỪNG phím (viền cầu vồng, nền đổi sắc,
    /// hoạ tiết khe hàng, viền cực quang, đập chuột, đèn rọi, phím lơ lửng) — chúng cần phím thật ở
    /// khung đầu. Bạn đồng hành / hiệu ứng bấm / nền theme không bám phím ⇒ vẫn dùng được, dựng như cũ.
    private var snapshotEligible: Bool {
        (plane == .letters || plane == .numbers || plane == .symbols)
            && KeySnapshot.themeAllows(
                keyMotion: themeSettings.effectiveKeyStyle.keyMotion, keyShape: themeSettings.effectiveKeyStyle.keyShape,
                floatActive: keyFloat != nil, keyFrameOverlays: mole != nil)
    }
    #if DEBUG
    var debugSnapshotEligible: Bool { snapshotEligible }
    var debugKeyEffectEmits: Int { keyEffects?.debugEmitCount ?? -1 }
    /// Test: viền cầu vồng (lớp riêng) — nằm TRÊN vùng phím (ảnh / phím thật), không thuộc cây vùng phím;
    /// số khung phím nó đang viền.
    var debugRainbowLayering: (aboveKeys: Bool, insideKeys: Bool, outlines: Int)? {
        guard let r = rainbow, let i = subviews.firstIndex(of: r),
              let k = subviews.firstIndex(of: rowsContainer) else { return nil }
        return (i > k, r.isDescendant(of: rowsContainer), r.outlines.count)
    }
    #endif
    private var displayScaleNow: CGFloat {
        traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
    }
    /// Khung đầu có thứ để hiện: phím thật hoặc ảnh lưới phím.
    var firstFrameReady: Bool { !initialBuildPending || snapState == .showing }

    /// Mọi thứ làm đổi hình lưới phím — không chắc thì có mặt. Khung vùng phím khoá riêng
    /// (KeySnapshot.frameKey). Thứ tự cố định, KHÔNG dùng phản chiếu (Mirror / in tên case enum tốn
    /// ~15–20 ms lúc tiến trình lạnh — đo 09/11/2026): enum ghi rawValue / mã tay, bảng màu liệt kê
    /// tay (KeySnapshot.paletteKey), kiểu phím + theme tự tạo qua chuỗi JSON chuẩn của chúng.
    func snapshotKeyParts() -> [String] {
        let tc = traitCollection
        func b(_ v: Bool) -> String { v ? "1" : "0" }
        let logo = UserDefaultsProvider.shared?.object(forKey: "showSpaceLogo").map { "\($0)" } ?? "nil"
        let a11y = [UIAccessibility.isBoldTextEnabled, UIAccessibility.isDarkerSystemColorsEnabled,
                    UIAccessibility.isReduceTransparencyEnabled, UIAccessibility.buttonShapesEnabled,
                    UIAccessibility.shouldDifferentiateWithoutColor, UIAccessibility.isGrayscaleEnabled,
                    UIAccessibility.isInvertColorsEnabled].map(b).joined()
        let planeCode: String
        switch plane {
        case .letters: planeCode = "letters"
        case .numbers: planeCode = "numbers"
        case .symbols: planeCode = "symbols"
        case .emoji: planeCode = "emoji"
        case .templates: planeCode = "templates"
        case .emojiSearch: planeCode = "emojiSearch"
        case .keypad: planeCode = "keypad"
        }
        let shiftCode = shift == .off ? "off" : (shift == .on ? "on" : "caps")
        let kindCode: String
        switch inputKind {
        case .normal: kindCode = "normal"
        case .number: kindCode = "number"
        case .email: kindCode = "email"
        case .url: kindCode = "url"
        case .search: kindCode = "search"
        }
        let keypadCode: String
        switch keypadStyle {
        case nil: keypadCode = "-"
        case .digits?: keypadCode = "digits"
        case .decimal(let sep)?: keypadCode = "decimal" + sep
        case .phone?: keypadCode = "phone"
        }
        func alts(_ m: [Character: String]) -> String {
            m.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" }.joined(separator: ",")
        }
        let g = geomSig
        let variant = themeSettings.variantChoice
        return [
            KeySnapshot.schema, KeySnapshot.buildVersion,
            "scale=\(displayScaleNow)", "pad=\(b(Self.isPad))", "land=\(b(isLandscapeNow))",
            "dir=\(effectiveUserInterfaceLayoutDirection.rawValue)",
            "cat=\(tc.preferredContentSizeCategory.rawValue)", "legib=\(tc.legibilityWeight.rawValue)",
            "contrast=\(tc.accessibilityContrast.rawValue)", "gamut=\(tc.displayGamut.rawValue)", "a11y=\(a11y)",
            "lang=\(L10n.lang)", "logo=\(b(AppFlavor.spaceBarLogo)),\(logo)",
            "plane=\(planeCode)", "shift=\(shiftCode)", "kind=\(kindCode)", "keypad=\(keypadCode)",
            "ret=\(returnTitle)", "dark=\(b(dark)),\(b(systemDark))", "wall=\(b(wallpaperActive))",
            "theme=\(themeSettings.themeId)", "variant=\(variant.zodiac.rawValue),\(variant.pride.rawValue)",
            "custom=\(themeSettings.custom?.canonical ?? "-")", "palette=\(KeySnapshot.paletteKey(palette))",
            "style=\(KeyStyleStore.json(keyStyle).canonical)",
            "assets=\(themeAssets?.signature ?? "-")", "corner=\(Self.cornerPercent.map { "\($0)" } ?? "-")",
            "globe=\(b(needsGlobe))", "nrow=\(b(numberRowEnabled)),\(b(numberRowFullHeight))",
            "side=\(spaceSideKey.rawValue)", "large=\(b(largeKeys))",
            "emoji=\(b(emojiInBar)),\(emojiKeyPlacement.rawValue)", "press=\(b(keyPressHighlightEnabled))",
            "alts=\(alts(activeAlts))", "salts=\(alts(shiftAlts))", "split=\(b(splitSetting)),\(b(splitMode))",
            "geom=\(g.gap),\(g.keyGap),\(g.sideMargin)", "adj=\(rowHeightAdjust),\(keyboardRaise)",
            "hand=\(oneHand.rawValue)", "space=\(spaceLanguage.rawValue),\(b(spaceFlickEnabled))",
            "piano=\(b(Self.pianoEnabled))",
            "bar=\(b(suggestionsEnabled)),\(barHeight.rawValue),\(b(dismissButtonEnabled))",
            "tpl=\(b(templatesEnabled)),\(b(textToolsEnabled))",
        ]
    }

    private func snapshotHash() -> String {
        StartupTrace.span("kv.snapshotKey") { KeySnapshot.digest(snapshotKeyParts()) }
    }

    /// rebuild() của lần dựng đầu: có ảnh cùng khoá ⇒ chuẩn bị như đầu rebuildBody (chiều cao xin,
    /// vùng phím, một tay…) nhưng KHÔNG dựng — lượt layout quyết (layoutSnapshot). true = đã hoãn.
    /// Không có ảnh nào / tắt ⇒ false ngay (không tính khoá).
    private func armSnapshot() -> Bool {
        guard snapState == .off || snapState == .armed, !isTornDown, snapshotEnabled,
              let stored = KeySnapshot.Store.current() else { return false }
        // Khoá trạng thái CHƯA so ở đây: sau endBatch controller còn đổi shift (updateAutoShift —
        // configureInputKind vừa tắt shift, đầu ô bật lại) ⇒ so ở layoutSnapshot với trạng thái cuối.
        guard KeySnapshot.decide(enabled: true, voiceOver: KeySnapshot.voiceOverRunning, eligible: snapshotEligible,
                                 stored: stored, hash: stored.hash, frame: nil) == .pending
        else { snapState = .done; return false }
        prepareForDeferredBuild()
        snapState = .armed
        setNeedsLayout()
        return true
    }

    /// Phần đầu của rebuildBody không cần phím (hình học lần hiện phải đúng như khi dựng thật).
    private func prepareForDeferredBuild() {
        letterGeometryCache = nil
        activeAlts = currentAlts()
        shiftAlts = currentShiftAlts()
        updateSuggestionChrome()
        applyOneHand()
    }

    /// Sau layoutRowsArea. armed ⇒ khung vùng phím đã biết: khớp ⇒ hiện ảnh, không ⇒ dựng ngay
    /// (đường cũ). showing ⇒ cỡ vùng phím hay khoá trạng thái đổi ⇒ phím thật.
    private func layoutSnapshot() {
        let k = displayScaleNow
        let size = rowsContainer.bounds.size
        switch snapState {
        case .armed:
            guard !rebuildDeferred, !isTornDown, initialBuildPending else { return }
            let frame = size.width > 0 && size.height > 0
                ? KeySnapshot.frameKey(exact: rowsContainer.exactFrame, scale: k) : nil
            let use = KeySnapshot.decide(enabled: snapshotEnabled, voiceOver: KeySnapshot.voiceOverRunning,
                                         eligible: snapshotEligible, stored: KeySnapshot.Store.current(),
                                         hash: snapshotHash(), frame: frame,
                                         pixelSize: KeySnapshot.pixelSize(size, scale: k))
            switch use {
            case .pending:
                return   // vùng phím 0 (host chưa đặt khung): chưa vẽ gì — chờ lượt có cỡ
            case .show(let e):
                if let got = StartupTrace.span("kv.snapshotLoad", { KeySnapshot.Store.load(e) }) {
                    snapOutlines = got.outlines
                    showSnapshot(got.image, entry: e)
                    return
                }
                snapState = .done
                rebuild()
            case .build:
                snapState = .done
                rebuild()
            }
        case .showing:
            if snapLayer?.frame.size != size || snapEntry?.hash != snapshotHash() { goLive() }
        case .off, .done:
            break
        }
    }

    private func showSnapshot(_ image: CGImage, entry: KeySnapshot.Entry) {
        let l = CALayer()
        l.contents = image
        l.contentsScale = displayScaleNow
        l.contentsGravity = .resize
        l.frame = rowsContainer.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rowsContainer.layer.addSublayer(l)
        CATransaction.commit()
        snapLayer = l
        snapEntry = entry
        snapState = .showing
        StartupTrace.event("keySnapshot")
        FrameTrace.event("keySnapshot")
        // Phím thật ngay sau commit khung đầu (cùng cơ chế việc hoãn của controller): khối main.async
        // này chạy TRƯỚC nguồn chạm của lượt runloop kế ⇒ chạm sau khung đầu đã gặp phím thật.
        snapPost.schedule { [weak self] in self?.goLive() }
    }

    /// Bỏ ảnh, dựng phím thật theo trạng thái HIỆN TẠI và xếp ngay — cùng một transaction ⇒ khung kế
    /// là phím thật đúng chỗ ảnh (không nháy rỗng). Ảnh (≈ rộng × cao × 4 byte) nhả ngay tại đây.
    func goLive() {
        guard snapState == .armed || snapState == .showing else { return }
        StartupTrace.span("kv.snapshotLive") {
            snapPost.cancel()
            snapState = .done
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            snapLayer?.removeFromSuperlayer()
            snapLayer = nil
            snapEntry = nil
            snapOutlines = []
            if !isTornDown {
                if initialBuildPending { rebuild() }   // batch đang mở ⇒ endBatch dựng
                if snapBadgePending, !initialBuildPending { snapBadgePending = false; showLanguageBadge() }
                if inLayoutPass { setNeedsLayout() } else { layoutIfNeeded() }
            }
            CATransaction.commit()
            #if DEBUG
            // Đo (KeyboardStartupTests): gồm cả phần vẽ phím ở commit kế.
            if StartupTrace.recording != nil, !inLayoutPass { CATransaction.flush() }
            #endif
        }
        StartupTrace.event("keysLive")
        FrameTrace.event("keysLive")
    }

    /// Xé view: bỏ ảnh + việc hẹn.
    private func dropSnapshot() {
        snapPost.cancel()
        snapLayer?.removeFromSuperlayer()
        snapLayer = nil
        snapEntry = nil
        snapState = .done
    }

    /// Controller gọi ở viewDidAppear: chụp sau `captureDelay` nếu vẫn đúng trạng thái mở đầu.
    func scheduleSnapshotCapture() {
        guard snapshotEnabled, !snapCaptureScheduled, !isTornDown else { return }
        snapCaptureScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + KeySnapshot.captureDelay) { [weak self] in
            self?.captureSnapshotIfNeeded()
        }
    }

    /// Chụp vùng phím (render(in:) trên main, ~một lần mỗi khi khoá đổi) rồi ghi nền. true = đã chụp.
    @discardableResult
    func captureSnapshotIfNeeded(done: (() -> Void)? = nil) -> Bool {
        guard snapshotEnabled, !isTornDown, window != nil, !KeySnapshot.Store.saving else { return false }
        let k = displayScaleNow
        let px = KeySnapshot.pixelSize(rowsContainer.bounds.size, scale: k)
        guard px.width > 0, px.height > 0 else { return false }
        let entry = KeySnapshot.Entry(hash: snapshotHash(),
                                      frame: KeySnapshot.frameKey(exact: rowsContainer.exactFrame, scale: k),
                                      pixelWidth: px.width, pixelHeight: px.height)
        guard KeySnapshot.shouldCapture(enabled: true, voiceOver: KeySnapshot.voiceOverRunning,
                                        eligible: snapshotEligible, interacted: snapInteracted,
                                        showing: snapState == .armed || snapState == .showing,
                                        keysBuilt: !initialBuildPending && !rowsContainer.arrangedSubviews.isEmpty,
                                        unstable: snapshotUnstable(), stored: KeySnapshot.Store.current(),
                                        entry: entry),
              let ctx = KeySnapshot.Store.makeContext(entry) else { return false }
        StartupTrace.span("kv.snapshotCapture") { renderRows(into: ctx, scale: k, pixelHeight: px.height) }
        KeySnapshot.Store.save(entry, context: ctx, outlines: keyOutlines(), done: done)
        return true
    }

    /// Khung + bo góc từng phím đang hiện (toạ độ rowsContainer) — như layoutRainbow đo.
    private func keyOutlines() -> [KeySnapshot.Store.Outline] {
        var out: [KeySnapshot.Store.Outline] = []
        func walk(_ x: UIView) {
            if let b = x as? KeyButton {
                if !b.isHidden, b.bounds.width > 0 {
                    out.append(.init(rect: b.convert(b.bounds, to: rowsContainer), radius: b.layer.cornerRadius))
                }
            } else { x.subviews.forEach(walk) }
        }
        walk(rowsContainer)
        return out
    }

    private func renderRows(into ctx: CGContext, scale k: CGFloat, pixelHeight: Int) {
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: k, y: -k)
        // Logo / mã ngôn ngữ phím cách ẩn trong ảnh: lần mở sau nhãn "ViệtTelex" chiếm chỗ đó
        // (đường cũ cũng ẩn logo lúc nhãn hiện) — ảnh khớp khung đầu của đường cũ.
        let mark = spaceMarkView
        let markHidden = mark?.isHidden ?? true
        mark?.isHidden = true
        UIGraphicsPushContext(ctx)
        rowsContainer.layer.render(in: ctx)
        UIGraphicsPopContext()
        mark?.isHidden = markHidden
    }

    /// Layer đang chạy animation (ảnh sẽ là trạng thái giữa chừng) hoặc loại render(in:) không vẽ
    /// đúng (bộ lọc, emitter, Metal, replicator) ⇒ không chụp.
    private func snapshotUnstable() -> Bool {
        func bad(_ l: CALayer) -> Bool {
            if let a = l.animationKeys(), !a.isEmpty { return true }
            if l.filters?.isEmpty == false || l.backgroundFilters?.isEmpty == false || l.compositingFilter != nil {
                return true
            }
            if l is CAEmitterLayer || l is CAMetalLayer || l is CAReplicatorLayer { return true }
            if let m = l.mask, bad(m) { return true }
            return l.sublayers?.contains(where: bad) ?? false
        }
        return bad(rowsContainer.layer)
    }

    #if DEBUG
    var debugSnapshotShowing: Bool { snapState == .showing }
    var debugSnapshotArmed: Bool { snapState == .armed }
    var debugSnapshotHash: String { KeySnapshot.digest(snapshotKeyParts()) }
    var debugSnapshotImage: CGImage? { snapLayer.map { $0.contents as! CGImage } }
    /// Test: vẽ vùng phím đang hiện đúng như lúc chụp (so điểm ảnh với ảnh đã lưu).
    func debugRenderRows() -> (entry: KeySnapshot.Entry, bytes: Data)? {
        let k = displayScaleNow
        let px = KeySnapshot.pixelSize(rowsContainer.bounds.size, scale: k)
        let e = KeySnapshot.Entry(hash: KeySnapshot.digest(snapshotKeyParts()),
                                  frame: KeySnapshot.frameKey(exact: rowsContainer.exactFrame, scale: k),
                                  pixelWidth: px.width, pixelHeight: px.height)
        guard px.width > 0, px.height > 0, let ctx = KeySnapshot.Store.makeContext(e), let p = ctx.data else { return nil }
        renderRows(into: ctx, scale: k, pixelHeight: px.height)
        return (e, Data(bytes: p, count: e.byteCount))
    }    #endif

    private func rebuild() {
        guard !rebuildDeferred else { return }   // batchConfigure rebuild 1 lần cuối
        // Ảnh lưới phím đang hiện mà trạng thái đổi ⇒ phím thật ngay (goLive dựng theo trạng thái mới).
        if snapState == .showing { goLive(); return }
        // Lần dựng đầu có ảnh cùng khoá ⇒ hoãn dựng tới lượt layout (biết khung vùng phím).
        if initialBuildPending, armSnapshot() { return }
        StartupTrace.span("kv.rebuild") { rebuildBody() }
    }
    private func rebuildBody() {
        if builtPlane != nil, builtPlane != plane { FrameTrace.untilCommit("plane") }   // Instruments: đổi mặt phím → commit
        initialBuildPending = false
        letterGeometryCache = nil
        // Hoạ tiết nền (chỉ theme có hoạ tiết): hàng phím mới ⇒ lượt layout kế đo lại khe giữa hàng
        // (khe không đổi thì không dựng lại path).
        if palette.decoration != nil || rainbow != nil { setNeedsLayout() }   // + viền cầu vồng: khung phím mới
        if let m = mole, m.isMoleUp || m.game.pending { m.hideNow() }   // Đập chuột: bảng phím đổi ⇒ dẹp chuột
        activeAlts = currentAlts()
        shiftAlts = currentShiftAlts()
        updateSuggestionChrome()
        applyOneHand()                           // plane mới có thể thu hẹp / đầy bề ngang
        // Tách đôi: công tắc TẮT ⇒ false ngay (không đọc gì thêm).
        let split = splitMode
        let styleChanged = builtReturn != returnTitle || builtDark != dark
            || builtPalette != palette
            || builtGlobe != needsGlobe || builtKind != inputKind
            || builtNumberRow != numberRowEnabled
            || builtNumberRowFull != numberRowFullHeight
            || builtSpaceSide != spaceSideKey
            || builtLargeKeys != largeKeys
            || builtEmojiInBar != emojiInBar
            || builtPressHighlight != keyPressHighlightEnabled
            || builtAlts != activeAlts
            || builtSplit != split
            || builtKeypad != keypadStyle
            || builtKeypadPaste != keypadPasteEnabled
            || builtGeom != geomSig
            || builtKeyStyle != keyStyle
            || builtAssetsSig != themeAssets?.signature
        let widthChanged = builtWidth != bounds.width
        let sigChanged = styleChanged || widthChanged
        if builtPlane == plane, !sigChanged { return }
        // Chỉ bề ngang đổi (view dựng ở init với width 0, rồi viewWillAppear thấy
        // width thật — MỖI lần hiện vì iOS tạo controller mới): phím không phụ
        // thuộc width ngoài inset hàng thụt, mà layoutSubviews tự chỉnh cho plane
        // đang hiện. Khỏi xé/dựng; chỉ vứt cache các plane khác (inset cũ sai).
        // Emoji/mẫu câu không cache, dựng tự do → vẫn dựng lại như cũ.
        // Tách đôi: bề rộng phím cố định theo bề ngang ⇒ đổi bề ngang là dựng lại.
        if builtPlane == plane, !styleChanged, !split,
           plane != .emoji, plane != .templates, plane != .emojiSearch {
            planeCache.removeAll()
            builtWidth = bounds.width
            return
        }
        if sigChanged {
            planeCache.removeAll()
        } else if let old = builtPlane, old != .emoji, old != .templates, old != .emojiSearch {
            // KHÔNG cache emoji/templates: cả hai đổi distribution sang .fill và
            // dựng layout tự do; khôi phục từ cache (distribution đã bị reset về
            // .fillEqually + constraint chiều cao hàng đáy còn treo) làm plane
            // mẫu câu lần 2 co dúm (bug user 2026-07-25). Dựng lại rẻ.
            planeCache[old] = CachedPlane(
                rows: rowsContainer.arrangedSubviews, letterKeys: letterKeys,
                shiftKeys: shiftKeys, spaceBar: spaceBar, spaceLogo: spaceLogo, spaceCode: spaceCode,
                indentedRow: indentedRow, indentedRowInset: indentedRowInset,
                crossRow: crossRowConstraints,
                distribution: rowsContainer.distribution,
                mode: rowsContainer.mode, heights: rowsContainer.heights)
        }
        // Rời lưới emoji / ô tìm emoji: nhả bảng category + trang atlas đã giải mã (lưới không
        // cache, dựng lại lười khi mở lại).
        if builtPlane == .emoji || builtPlane == .emojiSearch, plane != builtPlane { EmojiData.dropCaches() }
        builtPlane = plane; builtReturn = returnTitle
        builtDark = dark; builtPalette = palette; builtWidth = bounds.width
        builtKeyStyle = keyStyle
        builtAssetsSig = themeAssets?.signature
        builtGlobe = needsGlobe; builtKind = inputKind
        builtNumberRow = numberRowEnabled
        builtNumberRowFull = numberRowFullHeight
        builtSpaceSide = spaceSideKey
        builtLargeKeys = largeKeys
        builtEmojiInBar = emojiInBar
        builtPressHighlight = keyPressHighlightEnabled
        builtAlts = activeAlts
        builtSplit = split
        builtKeypad = keypadStyle
        builtKeypadPaste = keypadPasteEnabled
        builtGeom = geomSig
        dropAltHold()                            // phím cũ sắp bị gỡ
        commaTimer?.cancel(); commaTimer = nil; commaFired = false
        letterKeys.removeAll()
        shiftKeys = []
        crossRowConstraints = []
        indentedRow = nil
        rowsContainer.distribution = .fillEqually
        // Trượt từ 123 (#171): phím 123 đang bị đè phải Ở LẠI trong cửa sổ — gỡ nó là iOS huỷ luôn
        // chạm (không còn moved / ended) ⇒ hàng phím cũ sang chỗ đậu ẩn tới khi trượt xong.
        if planeSlideArmed { parkRowsForPlaneSlide(rowsContainer.arrangedSubviews) }
        else { rowsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() } }
        rowsContainer.heights = .equal
        rowsContainer.headerHeight = nil
        if let cached = planeCache[plane] {
            rowsContainer.setMode(cached.mode)
            rowsContainer.distribution = cached.distribution
            rowsContainer.heights = cached.heights
            cached.rows.forEach { rowsContainer.addArrangedSubview($0) }
            letterKeys = cached.letterKeys
            shiftKeys = cached.shiftKeys
            spaceBar = cached.spaceBar
            spaceLogo = cached.spaceLogo
            spaceCode = cached.spaceCode
            refreshSpaceMark()                       // ngôn ngữ có thể đã đổi khi plane nằm cache
            indentedRow = cached.indentedRow
            indentedRowInset = cached.indentedRowInset
            crossRowConstraints = cached.crossRow
            NSLayoutConstraint.activate(crossRowConstraints)
            // shift có thể đã đổi trong lúc plane này nằm ngoài màn hình
            if plane == .letters { applyShiftAppearance() }
            #if DEBUG
            Self.perfCacheSwaps += 1
            #endif
            return
        }
        #if DEBUG
        Self.perfFullBuilds += 1
        #endif
        // Emoji / mẫu câu / bàn số lớn: plane cũ trong UIStackView con; còn lại: lưới xếp tay.
        let stackPlane = plane == .emoji || plane == .templates || (plane == .keypad && keypadStyle != nil)
        rowsContainer.setMode(stackPlane ? .stack : .grid)
        switch plane {
        case .letters: buildLetters()
        case .numbers where builtSplit: buildSplitPlane(rows: numberRows, moreKey: "#+=", altKey: "ABC")
        case .symbols where builtSplit: buildSplitPlane(rows: symbolRows, moreKey: "123", altKey: "ABC")
        case .numbers where Self.isPad: buildPadSymbolic(numbers: true)
        case .symbols where Self.isPad: buildPadSymbolic(numbers: false)
        case .numbers: buildPlane(rows: numberRows, moreKey: "#+=", altKey: "ABC")
        case .symbols: buildPlane(rows: symbolRows, moreKey: "123", altKey: "ABC")
        case .emoji: buildEmoji()
        case .templates: buildTemplates()
        case .emojiSearch: buildEmojiSearch()
        case .keypad: buildKeypad()
        }
    }

    /// Plane mẫu câu / công cụ (☰): LƯỚI cột đều, khe đều (tester 11/2026 — trước là bubble
    /// rộng hẹp dàn dòng kiểu tag cloud, hàng không thẳng), cuộn dọc, nhãn dài cắt "…", có
    /// label thì ô chỉ hiện label. Cả Mẫu câu lẫn Công cụ bật ⇒ đầu bảng là thanh chọn
    /// [Mẫu câu | Công cụ] + ⚙️ (thay chip "⚒️ Công cụ" / "‹ Mẫu câu" — trông trùng với ☰);
    /// tab nhớ lựa chọn cuối. Hàng đáy giữ [ABC][space][return] để quay lại như plane số.
    /// Song sinh Android TemplatesMenu / TemplatesPane.
    private func buildTemplates() {
        rowsContainer.distribution = .fill
        // Mẫu câu tắt (☰ = .tools): chỉ danh sách công cụ, không thanh chọn / ⚙️.
        let toolsOnly = !templatesEnabled
        if !textToolsEnabled { textToolsMode = false }
        let tools = textToolsEnabled && (textToolsMode || toolsOnly)
        let segmented = templatesEnabled && textToolsEnabled
        let extras = tools
            ? Self.toolItems(addTones: PlusGate.isUnlocked(.sentenceDiacritics), translateLabel: translateChipLabel)
            : []
        let chips = TemplateChipsView(items: tools || toolsOnly ? [] : userTemplates, extras: extras,
                                      segments: segmented ? [L("Mẫu câu"), L("Công cụ")] : nil,
                                      selectedSegment: tools ? 1 : 0,
                                      showGear: templatesEnabled, list: templatesAsList, dark: dark,
                                      plainFill: plainFill,
                                      ink: palette.barInk.ui,
                                      onSegment: { [weak self] i in
            guard let self, self.textToolsMode != (i == 1) else { return }
            Self.clickModifier()
            self.textToolsMode = i == 1
            self.rebuildUncachedPlane()
        },
                                      onExtra: { [weak self] id in
            guard let self else { return }
            let tool = TextTool(rawValue: id)
            guard tool != nil || id == Self.translateID || id == Self.addTonesID else { return }
            Self.clickModifier()
            self.plane = .letters
            self.rebuild()
            self.styleBurger()
            if let tool { self.onTextTool?(tool) }
            else if id == Self.addTonesID { self.onAddTones?() }
            else { self.onTranslate?() }
        },
                                      onTap: { [weak self] text in
            guard let self else { return }
            Self.clickLetter()
            self.plane = .letters
            self.rebuild()
            self.styleBurger()
            self.onTemplate?(text)
        }, onGear: { [weak self] in
            Self.clickModifier()
            self?.onOpenTemplates?()   // mở tab Mẫu Câu trong app
        })
        chips.setContentHuggingPriority(.defaultLow, for: .vertical)
        chips.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        rowsContainer.addArrangedSubview(chips)       // giãn hết phần còn lại
        let bottom = bottomRow(planeKey: "ABC", clearInsteadOfEmoji: true)
        rowsContainer.addArrangedSubview(bottom)
        // Hằng số = đúng chiều cao 1 hàng phím thường; multiplier×rows từng làm
        // hàng đáy phình theo phần host cấp dư (user 2026-07-24).
        bottom.heightAnchor.constraint(equalToConstant: rowUnitHeight() - bottomTrim).isActive = true
    }

    // MARK: lưới mẫu câu / công cụ — hàm THUẦN (TemplateGridTests), song sinh Android TemplatesMenu

    /// Ô công cụ theo thứ tự (cùng Android EditPanel.toolCells): TextTool…, Thêm dấu, Dịch.
    static func toolItems(addTones: Bool, translateLabel: String?) -> [(display: String, id: String)] {
        TextTool.allCases.map { ($0.label, $0.rawValue) }
            + (addTones ? [(L("Thêm dấu"), addTonesID)] : [])
            + (translateLabel.map { [($0, translateID)] } ?? [])
    }

    /// Số cột lưới mẫu câu theo bề ngang (pt): điện thoại 5, rộng hơn thêm cột, 4…8.
    static func snippetCols(width: CGFloat) -> Int { min(8, max(4, Int(width / 72))) }
    /// "Hiện mẫu câu theo dòng" (#175): `list` ⇒ một cột, mỗi mẫu một dòng. Song sinh Android TemplatesMenu.snippetCols.
    static func snippetCols(width: CGFloat, list: Bool) -> Int { list ? 1 : snippetCols(width: width) }
    /// Chữ một ô mẫu câu. Lưới: có nhãn ⇒ chỉ nhãn. Theo dòng: "nhãn  nội dung" (nhãn rỗng / trùng nội dung ⇒
    /// chỉ nội dung). Xuống dòng ⇒ dấu cách. Song sinh Android TemplatesMenu.cellText.
    static func templateCellText(label: String, text: String, list: Bool) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        let l = label.replacingOccurrences(of: "\n", with: " ")
        if l.isEmpty { return t }
        if !list || l == t { return l }
        return l + "  " + t
    }
    /// Số cột lưới công cụ: điện thoại 3, iPad / ngang 4.
    static func toolCols(width: CGFloat) -> Int { width >= 560 ? 4 : 3 }

    /// Lưới `count` ô, `cols` cột bằng nhau phủ đúng left…right, khe ngang = khe dọc = `gap`.
    /// Hàng cuối thiếu ô: `stretchLast` ⇒ giãn đều phủ kín hàng (công cụ — không chỗ trống),
    /// không thì giữ đúng cột, canh trái (danh sách mẫu câu).
    static func templateGrid(count: Int, cols: Int, left: CGFloat, right: CGFloat, top: CGFloat,
                             cellH: CGFloat, gap: CGFloat, stretchLast: Bool) -> [CGRect] {
        guard count > 0, cols > 0 else { return [] }
        var out: [CGRect] = []
        out.reserveCapacity(count)
        let colW = (right - left - gap * CGFloat(cols - 1)) / CGFloat(cols)
        var r = 0, done = 0
        while done < count {
            let k = min(cols, count - done)
            let w = k < cols && stretchLast ? (right - left - gap * CGFloat(k - 1)) / CGFloat(k) : colW
            let t = top + CGFloat(r) * (cellH + gap)
            for i in 0..<k { out.append(CGRect(x: left + CGFloat(i) * (w + gap), y: t, width: w, height: cellH)) }
            done += k; r += 1
        }
        return out
    }

    /// Lưới mẫu câu / công cụ: thanh chọn tuỳ chọn ở đầu + UICollectionView xếp theo templateGrid.
    private final class TemplateChipsView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
        private let items: [(label: String, text: String)]
        /// Ô công cụ (tab Công cụ) — chạm gửi id qua onExtra; rỗng ở tab Mẫu câu.
        private let extras: [(display: String, id: String)]
        /// ⚙️ là ô cuối lưới (không có thanh chọn); có thanh chọn thì ⚙️ nằm bên phải thanh.
        private let gearCell: Bool
        private let list: Bool
        private let onExtra: (String) -> Void
        private let dark: Bool
        private let fill: UIColor
        private let ink: UIColor
        private let onTap: (String) -> Void
        private let onGear: () -> Void
        private let onSegment: (Int) -> Void
        private var segment: UISegmentedControl?
        static let cellH: CGFloat = 34
        static let gap: CGFloat = 6

        init(items: [(label: String, text: String)],
             extras: [(display: String, id: String)] = [],
             segments: [String]? = nil, selectedSegment: Int = 0,
             showGear: Bool = true, list: Bool = false,
             dark: Bool, plainFill: UIColor, ink: UIColor,
             onSegment: @escaping (Int) -> Void = { _ in },
             onExtra: @escaping (String) -> Void = { _ in },
             onTap: @escaping (String) -> Void, onGear: @escaping () -> Void) {
            self.items = items
            self.extras = extras
            self.gearCell = showGear && segments == nil && extras.isEmpty
            self.list = list
            self.onExtra = onExtra
            self.dark = dark
            self.fill = plainFill
            self.ink = ink
            self.onTap = onTap
            self.onGear = onGear
            self.onSegment = onSegment
            super.init(frame: .zero)
            let tools = !extras.isEmpty
            let layout = GridLayout(stretchLast: tools,
                                    cols: tools ? KeyboardView.toolCols(width:)
                                        : { [list] w in KeyboardView.snippetCols(width: w, list: list) })
            let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
            cv.backgroundColor = .clear
            cv.disableKeyboardEdgeEffects()
            cv.alwaysBounceVertical = true
            cv.dataSource = self
            cv.delegate = self
            cv.register(ChipCell.self, forCellWithReuseIdentifier: "chip")
            cv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cv)
            var cvTop = topAnchor
            if let segments {
                // Đầu bảng: [Mẫu câu | Công cụ] giãn hết, ⚙️ bên phải — cùng cao ô lưới, lề 6, khe 6.
                let seg = UISegmentedControl(items: segments)
                seg.selectedSegmentIndex = selectedSegment
                seg.selectedSegmentTintColor = plainFill
                seg.backgroundColor = plainFill.withAlphaComponent(0.45)
                seg.setTitleTextAttributes([.foregroundColor: ink, .font: UIFont.systemFont(ofSize: 14, weight: .medium)], for: .normal)
                seg.setTitleTextAttributes([.foregroundColor: ink, .font: UIFont.systemFont(ofSize: 14, weight: .semibold)], for: .selected)
                seg.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
                seg.translatesAutoresizingMaskIntoConstraints = false
                addSubview(seg)
                segment = seg
                var cons = [
                    seg.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                    seg.leftAnchor.constraint(equalTo: leftAnchor, constant: 6),
                    seg.heightAnchor.constraint(equalToConstant: Self.cellH),
                ]
                if showGear {
                    let g = UIButton(type: .system)
                    g.setTitle("⚙️", for: .normal)
                    g.titleLabel?.font = .systemFont(ofSize: 16)
                    g.backgroundColor = plainFill
                    g.layer.cornerRadius = 8
                    g.accessibilityLabel = L("Quản lý mẫu câu")
                    g.addTarget(self, action: #selector(gearTapped), for: .touchUpInside)
                    g.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(g)
                    cons += [
                        g.centerYAnchor.constraint(equalTo: seg.centerYAnchor),
                        g.heightAnchor.constraint(equalToConstant: Self.cellH),
                        g.widthAnchor.constraint(equalToConstant: Self.cellH * 1.4),
                        g.rightAnchor.constraint(equalTo: rightAnchor, constant: -6),
                        seg.rightAnchor.constraint(equalTo: g.leftAnchor, constant: -Self.gap),
                    ]
                } else {
                    cons.append(seg.rightAnchor.constraint(equalTo: rightAnchor, constant: -6))
                }
                NSLayoutConstraint.activate(cons)
                cvTop = seg.bottomAnchor
            }
            NSLayoutConstraint.activate([
                cv.topAnchor.constraint(equalTo: cvTop),
                cv.bottomAnchor.constraint(equalTo: bottomAnchor),
                cv.leftAnchor.constraint(equalTo: leftAnchor),
                cv.rightAnchor.constraint(equalTo: rightAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }

        @objc private func segmentChanged(_ s: UISegmentedControl) { onSegment(s.selectedSegmentIndex) }
        @objc private func gearTapped() { onGear() }

        /// Xếp ô theo KeyboardView.templateGrid (cột đều, khe đều); số cột theo bề ngang.
        private final class GridLayout: UICollectionViewLayout {
            let stretchLast: Bool
            let cols: (CGFloat) -> Int
            private var frames: [CGRect] = []
            private var contentH: CGFloat = 0
            init(stretchLast: Bool, cols: @escaping (CGFloat) -> Int) {
                self.stretchLast = stretchLast; self.cols = cols
                super.init()
            }
            required init?(coder: NSCoder) { fatalError() }
            override func prepare() {
                super.prepare()
                guard let cv = collectionView else { return }
                let w = cv.bounds.width
                frames = KeyboardView.templateGrid(count: cv.numberOfItems(inSection: 0), cols: cols(w),
                                                   left: 6, right: w - 6, top: 8, cellH: TemplateChipsView.cellH,
                                                   gap: TemplateChipsView.gap, stretchLast: stretchLast)
                contentH = (frames.last?.maxY ?? 0) + 8
            }
            override var collectionViewContentSize: CGSize {
                CGSize(width: collectionView?.bounds.width ?? 0, height: contentH)
            }
            private func attrs(_ i: Int) -> UICollectionViewLayoutAttributes {
                let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
                a.frame = frames[i]
                return a
            }
            override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
                frames.indices.filter { frames[$0].intersects(rect) }.map(attrs)
            }
            override func layoutAttributesForItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
                ip.item < frames.count ? attrs(ip.item) : nil
            }
            override func shouldInvalidateLayout(forBoundsChange b: CGRect) -> Bool {
                b.width != collectionView?.bounds.width
            }
        }

        func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int {
            extras.isEmpty ? items.count + (gearCell ? 1 : 0) : extras.count
        }

        func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "chip", for: ip) as! ChipCell
            if !extras.isEmpty {
                cell.set(display: extras[ip.item].display, fill: fill, ink: ink, dark: dark)
                cell.accessibilityLabel = nil
            } else if ip.item == items.count {
                cell.set(display: "⚙️", fill: fill, ink: ink, dark: dark)
                cell.accessibilityLabel = L("Quản lý mẫu câu")
            } else {
                let item = items[ip.item]
                cell.set(display: KeyboardView.templateCellText(label: item.label, text: item.text, list: list),
                         fill: fill, ink: ink, dark: dark, leading: list)
                cell.accessibilityLabel = nil
            }
            return cell
        }

        #if DEBUG
        var debugExtras: [String] { extras.map(\.display) }
        var debugSegmented: Bool { segment != nil }
        func debugSelectSegment(_ i: Int) {
            segment?.selectedSegmentIndex = i
            onSegment(i)
        }
        func debugSelect(_ index: Int) -> Bool {
            guard let cv = subviews.lazy.compactMap({ $0 as? UICollectionView }).first,
                  index < collectionView(cv, numberOfItemsInSection: 0) else { return false }
            collectionView(cv, didSelectItemAt: IndexPath(item: index, section: 0))
            return true
        }
        #endif

        func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
            if !extras.isEmpty { onExtra(extras[ip.item].id) }
            else if ip.item == items.count { onGear() } else { onTap(items[ip.item].text) }
        }

        private final class ChipCell: UICollectionViewCell {
            private let label = UILabel()
            override init(frame: CGRect) {
                super.init(frame: frame)
                contentView.layer.cornerRadius = 8
                contentView.layer.shadowColor = UIColor.black.cgColor
                contentView.layer.shadowOffset = CGSize(width: 0, height: 1)
                contentView.layer.shadowRadius = 0
                label.font = .systemFont(ofSize: 16)
                label.textAlignment = .center
                label.lineBreakMode = .byTruncatingTail   // "Chào buổi s…"
                label.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                    label.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 6),
                    label.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -6),
                ])
            }
            required init?(coder: NSCoder) { fatalError() }
            func set(display: String, fill: UIColor, ink: UIColor, dark: Bool, leading: Bool = false) {
                label.text = display
                label.textAlignment = leading ? .natural : .center   // ô tái dùng: đặt lại mỗi lần
                label.textColor = ink
                contentView.backgroundColor = fill
                contentView.layer.shadowOpacity = dark ? 0.30 : 0.35
                setNeedsLayout()
            }
            /// Bóng theo hình chip có sẵn (shadowPath) — không thì Core Animation phải vẽ offscreen
            /// để lấy hình bóng từ alpha nội dung, mỗi chip một lần. Chỉ khi nền ĐỤC: nền trong
            /// suốt (theme trong suốt) thì bóng theo alpha nhạt hơn bóng theo path ⇒ giữ như cũ.
            override func layoutSubviews() {
                super.layoutSubviews()
                let l = contentView.layer
                let opaque = (contentView.backgroundColor?.cgColor.alpha ?? 0) >= 1
                let path: CGPath? = opaque
                    ? UIBezierPath(roundedRect: l.bounds, cornerRadius: l.cornerRadius).cgPath : nil
                if l.shadowPath != path { l.shadowPath = path }
            }
        }
    }

    private func buildLetters() {
        if plane == .letters, builtSplit { buildSplitLetters(); return }
        if UIDevice.current.userInterfaceIdiom == .pad { buildLettersPad(); return }
        let r1 = "qwertyuiop".map { String($0) }
        let r2 = "asdfghjkl".map { String($0) }
        let r3 = "zxcvbnm".map { String($0) }
        if numberRowEnabled {
            rowsContainer.addArrangedSubview(row(KeyLayout.digits.map { textButton($0) }))
        }
        let r1btns = r1.map(letterButton)
        let row1 = row(r1btns)
        rowsContainer.addArrangedSubview(row1)
        // Apple indents row 2 by half a key on iPhone.
        rowsContainer.addArrangedSubview(row(r2.map(letterButton), sideInset: 0.5))
        let shiftBtn = shiftButton()
        let r3btns = r3.map(letterButton)     // z x c v b n m
        let backBtn = backspaceButton()
        var third: [UIView] = [shiftBtn]
        third += r3btns
        third.append(backBtn)
        let thirdRow = row(third)
        rowsContainer.addArrangedSubview(thirdRow)
        // Như stock: khe shift↔Z và M↔⌫ RỘNG hơn khe giữa chữ (feedback 26/09/2026
        // "bên phải Shift, bên trái Xoá chưa có khoảng trắng"). Chữ hàng 3 = đúng
        // bề rộng hàng 1; shift/⌫ bằng nhau, ăn phần còn lại (~1.4 phím).
        // Khe là vùng chết với UIButton nhưng router trả về phím gần nhất.
        // Chỉ iPhone: iPad stock giữ khe đều giữa shift và chữ.
        // "Phím to": khe = khe chữ ⇒ ⇧ / ⌫ nở lấp khe, chữ giữ chỗ (LargeKeys).
        if UIDevice.current.userInterfaceIdiom == .phone {
            let sg = LargeKeys.shiftGap(on: largeKeysActive, standard: Self.shiftGap, keyGap: keyGapNow)
            thirdRow.setCustomSpacing(sg, after: shiftBtn)
            if let m = r3btns.last { thirdRow.setCustomSpacing(sg, after: m) }
        }
        // z…m rộng đúng q (hàng 1 là neo); ⇧ = ⌫ chia đôi phần còn lại (cùng .flex).
        for b in r3btns { thirdRow.setWidth(.units(1), for: b) }
        thirdRow.anchor = row1
        rowsContainer.addArrangedSubview(bottomRow(planeKey: "123"))
        applyRowHeights()
    }

    /// Có hàng số / iPhone (hàng đáy cắt bớt): chiều cao hàng theo hàng chuẩn r — hàng số =
    /// KeyLayout.numberRowHeight (phím số 0.8× phím chữ, hoặc 1× khi bật "Hàng số cao bằng hàng chữ"),
    /// hàng đáy = r − bottomTrim, còn lại = r (KeyRowLayout.heights; lưu cùng plane trong planeCache).
    /// iPad không số: các hàng bằng nhau.
    private func applyRowHeights() {
        let rows = rowsContainer.arrangedSubviews
        let numberRow = numberRowEnabled && rows.count == 5
        guard numberRow || !Self.isPad, rows.count >= 4 else { rowsContainer.heights = .equal; return }
        let num = numberRow ? KeyRowLayout.Heights.NumberRow(
            multiplier: KeyLayout.numberRowMultiplier(fullHeight: numberRowFullHeight),
            constant: rowSpec.numberRowConstant(fullHeight: numberRowFullHeight)) : nil
        rowsContainer.heights = .ref(numberRow: num, trim: bottomTrim)
    }

    /// Xoay máy không dựng lại plane đang hiện (chỉ đổi bề ngang) → chỉnh phần cắt hàng
    /// đáy + khe trên nó theo hướng mới tại chỗ.
    private func applyBottomTrim() {
        guard !Self.isPad, rowsContainer.mode == .grid,
              case .ref(let num, let oldTrim) = rowsContainer.heights else { return }
        let spec = rowSpec
        let trim = spec.bottomTrim
        if oldTrim != trim { rowsContainer.heights = .ref(numberRow: num, trim: trim) }
        if let bottom = rowsContainer.arrangedSubviews.last as? KeyRow {
            if bottom.margins.top != spec.bottomTop { bottom.margins.top = spec.bottomTop }
            if bottom.margins.bottom != spec.bottomPad { bottom.margins.bottom = spec.bottomPad }
        }
    }

    /// Kiểu bàn phím iPad như stock (KeyLayout.PadStyle): mini = compact. Theo cạnh ngắn
    /// MÀN HÌNH (không theo bề ngang view — Split View không đổi kiểu).
    private lazy var padStyle: KeyLayout.PadStyle = {
        let b = window?.windowScene?.screen.bounds ?? UIScreen.main.bounds
        return KeyLayout.padStyle(screenShortSide: min(b.width, b.height))
    }()
    /// Test: ép kiểu iPad (rồi rebuild).
    func debugSetPadStyle(compact: Bool) {
        padStyle = compact ? .compact : .full
        planeCache.removeAll(); builtPlane = nil; rebuild()
    }

    /// Layout iPad như stock iPadOS 27 (KeyLayout.padLetterRows), đơn vị = bề rộng phím q:
    ///   full:    [tab 1.3] q…p [⌫ 1.3] / [⇪ 1.67] a…l [return] / [⇧ 2.2] z…m [!,] [?.] [⇧]
    ///   compact: q…p [⌫ 1.23] / ␣ a…l [return] / [⇧] z…m [!,] [?.] [⇧ 1.23]
    ///   [🌐][.?123][☺︎][space][,][.?123][⌨︎]   (bottomRow, padLetters)
    /// Mọi phím nền trắng; full: icon/nhãn phím chức năng ở góc dưới (padCorner),
    /// compact: giữa phím (padCenter).
    private func buildLettersPad() {
        let style = padStyle
        func make(_ id: String) -> UIView? {
            switch id {
            case "caps":
                let b = controlButton(title: "") { [weak self] in
                    guard let self else { return }
                    self.shift = (self.shift == .caps) ? .off : .caps
                    self.applyShiftAppearance()
                }
                b.setImage(UIImage(systemName: "capslock"), for: .normal)
                b.accessibilityLabel = "Caps Lock"
                padFunction(b, left: true)
                capsKey = b
                return b
            case "shiftL", "shiftR":
                let b = shiftButton() as! KeyButton
                padFunction(b, left: id == "shiftL")
                return b
            case "-", "=", _ where KeyLayout.digits.contains(id): return textButton(id)
            case "!,": return padPunctButton(lower: ",", upper: "!")
            case "?.": return padPunctButton(lower: ".", upper: "?")
            default: return padCommonKey(id) ?? letterButton(id)
            }
        }
        let layoutRows = (numberRowEnabled ? [KeyLayout.padNumberRow] : []) + KeyLayout.padLetterRows(style)
        buildPadRows(layoutRows, reference: "q", make: make)
        rowsContainer.addArrangedSubview(bottomRow(planeKey: "123"))
        applyRowHeights()
    }

    /// Plane số / ký hiệu iPad đúng stock (KeyLayout.padNumberRows / padSymbolRows): cùng
    /// khung phím plane chữ; phím có ký tự phụ (padNumberHints) vuốt xuống / giữ ra ký tự đó.
    private func buildPadSymbolic(numbers: Bool) {
        let style = padStyle
        let rows = numbers ? KeyLayout.padNumberRows(style) : KeyLayout.padSymbolRows(style)
        func make(_ id: String) -> UIView? {
            switch id {
            case "more", "more2":
                let title = numbers ? "#+=" : "123"
                let b = controlButton(title: title, fire: .down) { [weak self] in
                    guard let self else { return }
                    self.plane = (self.plane == .numbers) ? .symbols : .numbers
                    self.rebuild()
                }
                b.accessibilityLabel = numbers ? L("Ký hiệu") : L("Số")
                padFunction(b, left: id == "more")
                return b
            case "undo", "redo":
                // Ô undo/redo stock: bàn phím bên thứ ba không tới được undo manager của app.
                let b = textButton(KeyLayout.padSlotTitle(id) ?? ",") as! KeyButton
                b.isSpecial = true          // bề rộng theo units, không bằng phím ký tự
                return b
            case "!,": return padPunctButton(lower: ",", upper: "!")
            case "?.": return padPunctButton(lower: ".", upper: "?")
            default:
                if let v = padCommonKey(id) { return v }
                return textButton(id, hint: numbers ? KeyLayout.padNumberHints[id] : nil)
            }
        }
        buildPadRows(rows, reference: "1", make: make)
        rowsContainer.addArrangedSubview(bottomRow(planeKey: "ABC"))
        applyRowHeights()
    }

    /// Phím chung mọi plane iPad: tab, ⌫, return, ô thụt hàng 2 (compact).
    private func padCommonKey(_ id: String) -> UIView? {
        switch id {
        case "tab":
            let b = controlButton(title: "") { [weak self] in self?.tapped(.text("\t")) }
            b.setImage(UIImage(systemName: "arrow.right.to.line"), for: .normal)
            b.accessibilityLabel = "Tab"
            padFunction(b, left: true)
            return b
        case "back":
            let b = backspaceButton() as! KeyButton
            padFunction(b, left: false)
            return b
        case "return":
            let b = returnButton()
            if returnTitle == "return" { padFunction(b, left: false) }
            return b
        case "indent":
            return KeySpacer(.flex)
        default: return nil
        }
    }

    /// Dựng các hàng iPad theo id rồi neo bề rộng units × phím `reference` (hàng neo).
    private func buildPadRows(_ layoutRows: [[KeyLayout.Key]], reference: String,
                              make: (String) -> UIView?) {
        var anchor: KeyRow?
        var rows: [KeyRow] = []
        for keys in layoutRows {
            let pairs = keys.compactMap { k -> (KeyLayout.Key, UIView)? in
                guard let v = make(k.id) else { return nil }
                return (k, v)
            }
            let r = row(pairs.map(\.1))
            // Bề rộng = units × phím neo `reference`; đúng MỘT phím co giãn mỗi hàng (KeyLayout).
            for (k, v) in pairs { r.setWidth(k.units.map { .units($0) } ?? .flex, for: v) }
            if anchor == nil, pairs.contains(where: { $0.0.id == reference }) { anchor = r }
            rows.append(r)
            rowsContainer.addArrangedSubview(r)
        }
        for r in rows where r !== anchor { r.anchor = anchor }
    }

    /// Phím chức năng iPad theo kiểu: full → góc dưới (padCorner), compact → giữa phím.
    private func padFunction(_ b: KeyButton, left: Bool) {
        padCorner(b, left: left)
        if padStyle == .compact { b.padRole = .center }
    }

    /// Phím chức năng iPad kiểu stock: nền trắng như phím chữ (đè thì sẫm), icon /
    /// nhãn dạt góc dưới trái hoặc phải.
    private func padCorner(_ b: KeyButton, left: Bool) {
        b.backgroundColor = fnFill
        b.normalBackground = fnFill
        b.pressedBackground = specialFill
        // Cỡ nhãn/icon + lề góc theo hướng máy: KeyGeometry.Typography.Pad (KeyButton.padRole).
        b.padRole = .corner(left: left)
        let ink = self.fnInk
        b.tintColor = ink            // icon (tab/⇪/⇧/⌫/return…) đậm, không xanh/mờ
        b.setTitleColor(ink, for: .normal)
    }

    /// Ký tự phụ (xám, phía trên) của phím chữ iPad — vuốt xuống trên phím để gõ.
    static let padSecondary: [String: String] =
        Dictionary(uniqueKeysWithValues: KeyAlternates.padHints.map { (String($0.key), $0.value) })

    /// Phím dấu 2 tầng của iPad ("!" trên "," dưới, cùng cỡ như stock). Shift bật →
    /// ra ký tự trên (nhả shift một lần như phím chữ), tắt → ký tự dưới.
    private func padPunctButton(lower: String, upper: String) -> KeyButton {
        let b = baseButton(title: "", special: false)
        b.pressedBackground = specialFill
        // Hai nhãn đặt theo BASELINE quanh tâm phím như stock (Typography.Pad.punct*),
        // cỡ đổi theo hướng máy ở KeyButton.
        for text in [upper, lower] {
            let l = UILabel()
            l.text = text
            l.textColor = ink
            l.isUserInteractionEnabled = false
            l.isAccessibilityElement = false
            b.addOverlay(l, .centerBaseline(belowCenter: 0))
            b.padPunctLabels.append(l)
        }
        b.padRole = .punct
        b.accessibilityLabel = lower
        b.addAction(UIAction { _ in Self.clickLetter() }, for: .touchDown)   // âm/rung như phím ký tự
        armPadAlternate(b, alt: upper)          // vuốt xuống / giữ → ký tự trên như stock
        armCommit(b) { [weak self, weak b] in
            guard let self else { return }
            if b?.takePadAlt() == true {
                self.tapped(.text(upper))
            } else if self.shift != .off {
                if self.shift == .on { self.shift = .off; self.applyShiftAppearance() }
                self.tapped(.text(upper))
            } else {
                self.tapped(.text(lower))
            }
        }
        return b
    }

    // Emoji plane render theo stock (video 2026-07-24): search bar + lưới
    // cuộn ngang column-major theo category + hàng [ABC][icons][⌫].
    // rowsContainer là fillEqually — plane emoji cần layout tự do nên đổi
    // distribution sang .fill khi vào plane này (rebuild() phục hồi).
    private var emojiABCSlot: EmojiPlane.ABCSlot?

    private func buildEmoji() {
        rowsContainer.distribution = .fill
        let plane = EmojiPlane(dark: palette.surfaceDark ?? dark, abcSlot: emojiABCSlot)
        plane.onEmoji = { [weak self] e in self?.tapped(.text(e)) }
        plane.onABC = { [weak self] in
            guard let self else { return }
            self.plane = .letters
            self.reevaluateShiftForLetters()     // shift đã tắt lúc vào emoji
            self.rebuild()
        }
        plane.onBackspace = { [weak self] in self?.tapped(.backspace) }
        plane.onKaomoji = { [weak self] s in self?.onKey(.text(s)) }
        plane.onSearch = { [weak self] in
            guard let self else { return }
            self.emojiSearch.clear()
            self.shift = .off
            self.plane = .emojiSearch
            self.rebuild()
        }
        rowsContainer.addArrangedSubview(plane)
    }

    // MARK: tìm emoji (27/09/2026)
    // Hàng ô tìm + kết quả chèn lên đầu plane chữ, thế chỗ strip gợi ý; phần nó cao hơn
    // strip thì bàn phím cao thêm (KeyLayout.chrome .emojiSearch) — phím chữ giữ đủ
    // keyArea (29/09/2026: trước chia 5 hàng trong keyArea, phím bị ép). Mọi phím chữ /
    // space / ⌫ đi vào EmojiSearchSession (Telex riêng), không tới ô nhập; chạm kết
    // quả mới chèn emoji thật. return / phím emoji → về lưới emoji; 123 → plane số.
    /// Lười: tạo (đọc cài đặt Telex) lần đầu mở ô tìm — không nằm trong khởi động bàn phím.
    private lazy var emojiSearch = EmojiSearchSession()
    private weak var searchBar: EmojiSearchBar?

    private func buildEmojiSearch() {
        let bar = EmojiSearchBar(dark: palette.surfaceDark ?? dark)
        bar.onPick = { [weak self] e in
            Self.clickLetter()
            EmojiPlane.noteUsed(e)
            self?.onKey(.text(e))
        }
        bar.onClear = { [weak self] in
            guard let self else { return }
            Self.clickModifier()
            self.emojiSearch.clear()
            self.refreshSearchBar()
        }
        searchBar = bar
        buildLetters()
        // iPad (không hàng số): hàng chữ bằng nhau (.equal) — ô tìm có chiều cao RIÊNG (hàng đầu
        // cố định), không chia phần với hàng chữ.
        rowsContainer.insertArrangedSubview(bar, at: 0)
        // Ô tìm cao cố định = phần bàn phím cao thêm (KeyLayout.chrome .emojiSearch) — trước
        // đây bằng một hàng chữ và CHIA keyArea với 4 hàng chữ ⇒ phím bị ép (bug 1.2.x).
        let strip = KeyLayout.stripHeight(reserved: stripReserved, open: openStripNow)
        rowsContainer.headerHeight = KeyLayout.emojiSearchBarHeight(strip: strip)
        refreshSearchBar()
    }

    private func refreshSearchBar() {
        let q = emojiSearch.query
        let list = q.trimmingCharacters(in: .whitespaces).isEmpty
            ? EmojiPlane.recents : EmojiSearch.search(q)
        searchBar?.update(query: q, results: list)
    }

    /// Phím trong chế độ tìm: vào ô tìm thay vì ô nhập. true = đã xử lý.
    private func handleSearchKey(_ key: Key) -> Bool {
        guard plane == .emojiSearch else { return false }
        switch key {
        case .letter(let c): emojiSearch.type(c)
        case .text(let t): emojiSearch.insert(t)
        case .space, .doubleSpacePeriod: emojiSearch.space()
        case .backspace: emojiSearch.backspace()
        case .replaceLastLetter(let t): emojiSearch.backspace(); emojiSearch.insert(t)
        case .newline, .lineBreak:
            plane = .emoji
            rebuild()
            return true
        case .moveCursor, .moveLine, .clearField: return true
        }
        refreshSearchBar()
        return true
    }

    /// Plane 123 / #+= iPhone (và bàn tách đôi) — KeyLayout.phoneSymbolicRows: bật hàng số ⇒
    /// thêm đúng hàng 1…0 của plane chữ (5 hàng, không nhảy hàng khi chuyển 123/ABC).
    private var numberRows: [[String]] { KeyLayout.phoneSymbolicRows(numbers: true, numberRow: numberRowEnabled) }
    private var symbolRows: [[String]] { KeyLayout.phoneSymbolicRows(numbers: false, numberRow: numberRowEnabled) }
    /// Phím #+= / 123 đầu hàng 3 plane số / ký hiệu.
    private func makeMoreKey(_ moreKey: String) -> KeyButton {
        let more = controlButton(title: moreKey, fire: .down) { [weak self] in
            guard let self else { return }
            self.plane = (self.plane == .numbers) ? .symbols : .numbers
            self.rebuild()
        }
        more.accessibilityLabel = moreKey == "#+=" ? L("Ký hiệu") : L("Số")
        applyLabelFont(more, size: KeyGeometry.Typography.rowToggleSize)
        return more
    }

    private func buildPlane(rows planeRows: [[String]], moreKey: String, altKey: String) {
        for r in planeRows { rowsContainer.addArrangedSubview(row(r.map { textButton($0) })) }
        let more = makeMoreKey(moreKey)
        var third: [UIView] = [more]
        third += [".",",","?","!","'"].map { textButton($0) }
        third.append(backspaceButton())
        rowsContainer.addArrangedSubview(row(third, proportional: true))
        rowsContainer.addArrangedSubview(bottomRow(planeKey: altKey))
        applyRowHeights()
    }

    // MARK: bàn phím tách đôi (SplitLayout — Settings → Giao diện, mặc định TẮT)
    // Công tắc tắt ⇒ splitSetting false ⇒ splitMode false ngay (một phép AND), không view /
    // constraint / vòng lặp nào thêm. Bật + đủ rộng ⇒ plane chữ / 123 / #+= dựng thành hai
    // nửa (mỗi hàng: [nửa trái][khe chết][nửa phải]); emoji / mẫu câu / tìm emoji giữ đầy
    // bề ngang. Phím chữ vẫn qua router gần-nhất (letterKeys); gõ vuốt + một tay tắt.

    /// Công tắc App Group `splitKeyboard` (đọc mỗi lần hiện — applyAppearance).
    private var splitSetting = false
    /// Tách đôi ở bề ngang hiện tại (công tắc + ≥ SplitLayout.minWidth).
    private var splitMode: Bool { splitSetting && SplitLayout.active(setting: true, width: bounds.width) }
    /// Các plane chữ / số dựng theo kiểu tách đôi (chữ ký rebuild — đổi là dựng lại).
    private var builtSplit = false
    /// Hàng phím có nửa trái/phải lồng (router duyệt thêm một tầng stack).
    private var nestedRows: Bool { builtSplit && (plane == .letters || plane == .numbers || plane == .symbols) }

    private var splitMetrics: SplitLayout.Metrics {
        SplitLayout.metrics(width: bounds.width, margin: sideMarginNow, gap: keyGapNow)
    }
    private func fixWidth(_ v: UIView, _ w: CGFloat) {
        if let b = v as? KeyButton { b.rowWidth = .fixed(w) } else if let r = v as? KeyRow { r.rowWidth = .fixed(w) }
    }
    /// Một nửa hàng: phím + lề trong (pt) hai bên.
    private func splitHalf(_ views: [UIView], left: CGFloat, right: CGFloat) -> KeyRow {
        KeyRow(views, spacing: keyGapNow, margins: UIEdgeInsets(top: 0, left: left, bottom: 0, right: right))
    }
    /// Hàng tách: [nửa trái `half`][khe co giãn, không nhận chạm][nửa phải `half`].
    private func splitRow(_ l: KeyRow, _ r: KeyRow, half: CGFloat, top: CGFloat? = nil) -> KeyRow {
        fixWidth(l, half)
        fixWidth(r, half)
        return KeyRow([l, KeySpacer(.flex), r], spacing: 0,
                      margins: UIEdgeInsets(top: top ?? rowSpec.gap, left: sideMarginNow, bottom: 0, right: sideMarginNow))
    }

    private func buildSplitLetters() {
        let m = splitMetrics
        indentedRow = nil
        func keys(_ s: String) -> [UIView] {
            s.map { c -> UIView in let b = letterButton(String(c)); fixWidth(b, m.keyWidth); return b }
        }
        if numberRowEnabled {
            let d = SplitLayout.halves(KeyLayout.digits.map { t -> UIView in
                let b = textButton(t); fixWidth(b, m.keyWidth); return b
            })
            rowsContainer.addArrangedSubview(splitRow(splitHalf(d.left, left: 0, right: m.pitch / 2),
                                                      splitHalf(d.right, left: m.pitch / 2, right: 0), half: m.half))
        }
        for i in 0..<2 {
            let r = SplitLayout.letterRows[i], ind = SplitLayout.letterIndents[i]
            rowsContainer.addArrangedSubview(splitRow(
                splitHalf(keys(r.left), left: ind.left.l * m.pitch, right: ind.left.r * m.pitch),
                splitHalf(keys(r.right), left: ind.right.l * m.pitch, right: ind.right.r * m.pitch),
                half: m.half))
        }
        // Hàng 3: [⇧] z x c v | v b n m [⌫] — ⇧ / ⌫ co giãn (≈ 1.5 bước), khe rộng như iPhone.
        let r3 = SplitLayout.letterRows[2]
        let shiftBtn = shiftButton(), backBtn = backspaceButton()
        let l3 = splitHalf([shiftBtn] + keys(r3.left), left: 0, right: 0)
        let rk = keys(r3.right)
        let r3s = splitHalf(rk + [backBtn], left: 0, right: 0)
        let sg = LargeKeys.shiftGap(on: largeKeysActive, standard: Self.shiftGap, keyGap: keyGapNow)
        l3.setCustomSpacing(sg, after: shiftBtn)
        if let last = rk.last { r3s.setCustomSpacing(sg, after: last) }
        rowsContainer.addArrangedSubview(splitRow(l3, r3s, half: m.half))
        rowsContainer.addArrangedSubview(splitBottomRow(planeKey: "123", m: m))
        applyRowHeights()
    }

    private func buildSplitPlane(rows planeRows: [[String]], moreKey: String, altKey: String) {
        let m = splitMetrics
        indentedRow = nil
        func keys(_ a: [String]) -> [UIView] {
            a.map { t -> UIView in let b = textButton(t); fixWidth(b, m.keyWidth); return b }
        }
        for r in planeRows {
            let h = SplitLayout.halves(r)
            rowsContainer.addArrangedSubview(splitRow(splitHalf(keys(h.left), left: 0, right: m.pitch / 2),
                                                      splitHalf(keys(h.right), left: m.pitch / 2, right: 0),
                                                      half: m.half))
        }
        let more = makeMoreKey(moreKey)
        let back = backspaceButton()
        let l3 = splitHalf([more] + keys([".", ","]), left: 0, right: m.pitch / 2)
        let r3 = splitHalf(keys(["?", "!", "'"]) + [back], left: m.pitch / 2, right: 0)
        rowsContainer.addArrangedSubview(splitRow(l3, r3, half: m.half))
        rowsContainer.addArrangedSubview(splitBottomRow(planeKey: altKey, m: m))
        applyRowHeights()
    }

    /// Hàng đáy tách: [123][🌐?][☺︎][space] | [space Vᴛ][,][return]. Hai phím cách cùng gõ
    /// dấu cách; phím phải mang logo / vuốt đổi ngôn ngữ và ưu tiên mép với "," (KeyHitBias).
    private func splitBottomRow(planeKey: String, m: SplitLayout.Metrics) -> KeyRow {
        var left: [UIView] = []
        let planeBtn = makePlaneKey(planeKey)
        fixWidth(planeBtn, m.keyWidth)
        left.append(planeBtn)
        if needsGlobe {
            let g = makeGlobeKey()
            fixWidth(g, m.keyWidth)
            left.append(g)
        }
        let emoji = makeEmojiKey()
        fixWidth(emoji, m.keyWidth)
        left.append(emoji)
        left.append(makeSpaceKey(primary: false))
        var right: [UIView] = [makeSpaceKey(primary: true)]
        let puncts: [(title: String, insert: String, mult: CGFloat)]
        switch planeKey == "123" ? inputKind : .normal {
        case .email: puncts = [("@", "@", 0), (".", ".", 0)]
        case .url: puncts = [(".", ".", 0), ("/", "/", 0)]
        case .search: puncts = [(".", ".", 0)]
        default: puncts = [(",", ",", 0)]
        }
        for p in makePunctKeys(puncts, planeKey: planeKey) {
            // "Phím to": "," / "." rộng bằng 😊 / 123 bên trái (m.keyWidth).
            let big = largeKeysActive && LargeKeys.widens(p.btn.currentTitle ?? "")
            fixWidth(p.btn, m.keyWidth * (big ? 1 : 0.9))
            right.append(p.btn)
        }
        let ret = returnButton()
        fixWidth(ret, m.keyWidth * 1.9)
        right.append(ret)
        let top = rowSpec.bottomTop
        return splitRow(splitHalf(left, left: 0, right: 0), splitHalf(right, left: 0, right: 0),
                        half: m.half, top: top)
    }

    /// Nút thật của một hàng phím — hàng tách đôi lồng thêm một tầng (nửa trái/phải).
    private func rowControls(_ row: UIView) -> [UIControl] {
        // Bàn số lớn (chế độ stack) giữ hàng UIStackView cũ.
        if let stack = row as? UIStackView { return stack.arrangedSubviews.compactMap { $0 as? UIControl } }
        guard let r = row as? KeyRow else { return [] }
        guard nestedRows else { return r.arrangedSubviews.compactMap { $0 as? UIControl } }
        var out: [UIControl] = []
        for v in r.arrangedSubviews {
            if let c = v as? UIControl { out.append(c) }
            else if let h = v as? KeyRow { out += h.arrangedSubviews.compactMap { $0 as? UIControl } }
        }
        return out
    }

    /// Giữ Return bấy lâu = xuống dòng không gửi (Android RETURN_HOLD_MS = 450).
    static let returnHoldDuration: TimeInterval = 0.45
    private var returnHoldFired = false

    /// Ô cho "xuống dòng không gửi": ô chữ thường có Return / Gửi. Ô tìm, URL, email, số,
    /// Return dạng go/search/next/done/join ⇒ không (giữ lâu / ⇧ + Return = Return thường) —
    /// iOS không cho biết ô nhiều dòng như Android, "\n" trong ô một dòng vô nghĩa.
    static func lineBreakAllowed(kind: InputKind, returnTitle: String) -> Bool {
        kind == .normal && (returnTitle == "return" || returnTitle == "send")
    }
    private var lineBreakAllowed: Bool { Self.lineBreakAllowed(kind: inputKind, returnTitle: returnTitle) }

    /// Chạm Return: Shift một-lần DO TAY (không phải viết hoa đầu câu tự động, không Caps Lock)
    /// ⇒ xuống dòng không gửi (thay Shift+Enter bàn phím bên thứ ba không gửi được).
    static func returnTapKey(shiftOn: Bool, byHand: Bool, allowed: Bool) -> Key {
        shiftOn && byHand && allowed ? .lineBreak : .newline
    }

    @objc private func returnHold(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let v = g.view, lineBreakAllowed else { return }
        // Ngón khác chạm xuống đã chốt (flush) Return ⇒ không còn là giữ lâu.
        let id = ObjectIdentifier(v)
        guard commits.isArmed(id) else { return }
        commits.disarm(id)                       // nhả tay KHÔNG gửi
        returnHoldFired = true
        Self.flickFeedback()
        showBalloon(over: v, text: "↵", force: true)
        tapped(.lineBreak)
    }

    /// Phím return theo returnKeyType của ô (xám + icon, hoặc xanh + chữ/mũi tên).
    private func returnButton() -> KeyButton {
        let ret = controlButton(title: returnTitle == "return" ? "" : returnTitle,
                                armed: true, isReturn: true) { [weak self] in
            guard let self else { return }
            let key = Self.returnTapKey(shiftOn: self.shift == .on, byHand: self.shiftByHand,
                                        allowed: self.lineBreakAllowed)
            // ⇧ + Return dùng hết Shift một-lần (như một chữ); viết hoa dòng mới do auto-shift.
            if case .lineBreak = key { self.shift = .off; self.applyShiftAppearance() }
            self.tapped(key)
        }
        // Giữ lâu = xuống dòng không gửi (như Android giữ lâu Enter): hiện "↵", nhả tay không
        // gửi. Luôn gắn (nút nằm trong cache plane) — loại ô kiểm lúc giữ (lineBreakAllowed).
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(returnHold(_:)))
        hold.minimumPressDuration = Self.returnHoldDuration
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        hold.cancelsTouchesInView = false
        ret.addGestureRecognizer(hold)
        ret.addAction(UIAction { [weak self] _ in
            guard let self, self.returnHoldFired else { return }
            self.returnHoldFired = false
            self.hideBalloon()
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        ret.accessibilityLabel = returnTitle == "return" ? L("Xuống dòng") : returnTitle
        if Self.isPad, returnTitle == "return" { ret.padRole = .icon }
        if returnTitle == "return" {
            ret.setImage(UIImage(systemName: "return.left",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
            // Đậm như stock iOS 26+ (trước: mờ 0.16 ngang logo Vᴛ — khó thấy).
            ret.tintColor = fnInk
        } else {
            // Return dạng HÀNH ĐỘNG (go/search/send/done…): nút XANH nổi bật +
            // chữ trắng như stock (Safari search…), thay vì xám lẫn phím thường.
            let accent = palette.accent.ui
            ret.backgroundColor = accent
            ret.normalBackground = accent
            ret.pressedBackground = palette.accent.alpha(0.7).ui
            ret.setTitleColor(palette.accentInk.ui, for: .normal)
            ret.titleFont = .systemFont(ofSize: 16, weight: .semibold)
            // "go"/"search" (Safari, Gmail…): stock hiện MŨI TÊN → trắng, không chữ.
            if returnTitle == "go" || returnTitle == "search" {
                ret.setTitle("", for: .normal)
                ret.setImage(UIImage(systemName: "arrow.right",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
                ret.tintColor = palette.accentInk.ui
            }
        }
        if themeAssets != nil {
            applySkin(ret, role: "return")
            if ret.skin?.pixelated == true {
                // Skin điểm ảnh tô theo palette: return hành động giữ màu nhấn (chữ accentInk như không skin).
                if returnTitle != "return" { applySkin(ret, role: PixelKeys.actionReturnRole) }
            } else if ret.skin != nil, returnTitle != "return" {
                // Skin thay nền nhấn ⇒ chữ/icon theo màu phím chức năng (đọc được trên skin).
                ret.setTitleColor(fnInk, for: .normal); ret.tintColor = fnInk
            }
        }
        return ret
    }

    /// Phím 123 / ABC hàng đáy (iPhone, iPad, bàn tách đôi).
    private func makePlaneKey(_ planeKey: String) -> KeyButton {
        let planeBtn = controlButton(title: planeKey, fire: .down) { [weak self] in
            guard let self else { return }
            // Trượt từ 123 (#171): chỉ plane chữ → plane số, iPhone, không tách đôi, không bàn số lớn.
            self.planeSlideArmed = planeKey == "123" && self.plane == .letters && self.keypadStyle == nil
                && !Self.isPad && !self.builtSplit
            // Từ ô tìm emoji: 123 ra plane số (thoát tìm).
            // Ô bàn số lớn: "123" ở bàn chữ quay lại bàn số lớn (NumericKeypad).
            self.plane = (self.plane == .letters || self.plane == .emojiSearch)
                ? (self.keypadStyle != nil ? .keypad : .numbers) : .letters
            if self.plane == .letters { self.reevaluateShiftForLetters() }
            self.rebuild()
        }
        planeBtn.accessibilityLabel = planeKey == "123" ? L("Số") : L("Chữ")
        applyLabelFont(planeBtn, size: KeyGeometry.Typography.planeKeySize)
        if planeKey == "123", !Self.isPad {
            // Sau action đổi plane (thêm trước) + carryPress: bắt đầu theo dõi ngón trượt.
            planeBtn.addAction(UIAction { [weak self, weak planeBtn] _ in
                guard let self, self.planeSlideArmed else { return }
                self.planeSlideArmed = false
                guard self.plane == .numbers else { self.unparkPlaneSlideRows(); return }
                self.beginPlaneSlide(touch: planeBtn?.lastBeganTouch)
                if self.planeSlide == nil { self.unparkPlaneSlideRows() }   // không trượt (VoiceOver…)
            }, for: .touchDown)
            planeBtn.onTouchPhase = { [weak self] t, phase in self?.planeSlideEvent(t, phase) }
        }
        return planeBtn
    }

    private func makeGlobeKey() -> KeyButton {
        let globe = baseButton(title: "", special: true)
        globe.setImage(UIImage(systemName: "globe",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        globe.tintColor = fnInk
        globe.accessibilityLabel = L("Bàn phím tiếp theo")
        if Self.isPad { globe.padRole = .icon }
        globe.addAction(UIAction { _ in Self.clickModifier() }, for: .touchDown)
        if let c = inputController {
            // hợp đồng Apple: event thật + allTouchEvents để long-press
            // mở keyboard picker hoạt động
            globe.addTarget(c, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                            for: .allTouchEvents)
        }
        return globe
    }

    private func makeEmojiKey() -> KeyButton {
        // Nhấc tay như stock; touch bị hệ thống huỷ (sát vùng 🌐/mic) vẫn mở emoji.
        let emojiBtn = controlButton(title: "", fire: .upOrCancel) { [weak self] in
            guard let self else { return }
            self.plane = .emoji
            self.rebuild()
        }
        emojiBtn.setImage(Self.emojiKeyIcon, for: .normal)
        // Nhớ chỗ phím emoji (touchDown chạy trước action đổi plane) → EmojiPlane
        // đặt ABC đúng chỗ đó (Phil 26/09, chốt lại 30/09/2026).
        emojiBtn.addAction(UIAction { [weak self] a in
            guard let self, let v = a.sender as? UIView else { return }
            let r = self.convert(v.bounds, from: v)
            self.emojiABCSlot = .init(minX: r.minX, maxX: r.maxX,
                                      top: self.rowsContainer.frame.maxY - r.minY)
        }, for: .touchDown)
        emojiBtn.tintColor = fnInk
        emojiBtn.accessibilityLabel = "Emoji"
        return emojiBtn
    }

    /// Phím cách. `primary`: phím mang logo / mã ngôn ngữ (spaceBar — vuốt đổi ngôn ngữ, ưu
    /// tiên mép với ","). Bàn tách đôi có thêm một phím cách phụ bên trái, cùng hành vi gõ.
    private func makeSpaceKey(primary: Bool) -> KeyButton {
        let space = baseButton(title: "", special: true)
        space.backgroundColor = fnFill
        space.normalBackground = fnFill
        applySkin(space, role: "space")
        space.pressedBackground = specialFill      // space sẫm lại khi đè
        space.accessibilityLabel = L("Dấu cách")
        space.isSpaceKey = true
        if primary { spaceBar = space; installSpaceMark(on: space) }
        if palette.spaceSoundhole {   // Ghi-ta: lỗ thoát âm + vành hoa văn (vẽ một lần, theo cỡ phím)
            space.setSoundhole(ring: palette.accent.alpha(0.85 * palette.surfaceAlpha).ui, inner: spaceInk.alpha(0.45).ui)
        }
        space.addAction(UIAction { _ in Self.clickSpace() }, for: .touchDown)
        space.addTarget(self, action: #selector(spaceTouchDown(_:event:)), for: .touchDown)
        // Vuốt đổi ngôn ngữ (SpaceFlick): theo dõi ngón — công tắc tắt ⇒ handler thoát ngay.
        space.addTarget(self, action: #selector(spaceDrag(_:event:)),
                        for: [.touchDragInside, .touchDragOutside, .touchUpInside, .touchUpOutside])
        // Chốt qua KeyCommitQueue: arm lúc chạm, chốt lúc nhấc / bị huỷ / khi ngón
        // khác chạm xuống trước (gõ chồng ngón). touchUpOutside CŨNG chốt: ngón trượt
        // khỏi mép lúc nhấc là chuyện thường. Trackpad (spaceHold) disarm.
        armCommit(space) { [weak self, weak space] in
            guard let self else { return }
            if self.consumeSpaceFlick() { return }    // flick đổi ngôn ngữ: không ra dấu cách
            if let space { self.fxMark(space) }
            let now = CACurrentMediaTime()
            if now - self.lastSpaceTap < 0.35 {
                Self.chordSentenceEnd()               // ". " tự chèn = kết câu ⇒ vòng hợp âm cách về đầu
                self.tapped(.doubleSpacePeriod)
            } else {
                self.tapped(.space)
            }
            self.lastSpaceTap = now
            if PlanePolicy.returnToLettersOnSpace(
                inSymbolPlane: self.plane == .numbers || self.plane == .symbols,
                typedInPlane: self.typedInSymbolPlane,
                numericField: self.inputKind == .number) {
                self.plane = .letters
                self.rebuild()
            }
        }
        let spacePan = UILongPressGestureRecognizer(target: self, action: #selector(spaceHold(_:)))
        spacePan.minimumPressDuration = 0.3   // 0.4 → 0.3: vào trackpad nhanh hơn (cảm giác stock)
        // KHÔNG delay/cancel touch của phím khác: recognizer mặc định trì hoãn
        // touchesEnded ~0.15s và cancel touch khi nhận diện — nguồn rớt/khựng
        // phím kề khi gõ nhanh. Chỉ theo dõi touch bắt đầu TRÊN space.
        spacePan.delaysTouchesBegan = false
        spacePan.delaysTouchesEnded = false
        spacePan.cancelsTouchesInView = false
        space.addGestureRecognizer(spacePan)
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return space
    }

    /// Phím dấu câu hàng đáy (",", hoặc "@ ." / ". /" ô email/url…). `sideKey`: phím hẹp cạnh
    /// space bàn chữ iPhone ô thường ("Phím cạnh dấu cách") — giữ ra ký tự còn lại của cặp , / .
    private func makePunctKeys(_ puncts: [(title: String, insert: String, mult: CGFloat)],
                               planeKey: String, sideKey: SpaceSideKey? = nil) -> [(btn: KeyButton, mult: CGFloat)] {
        var punctKeys: [(btn: KeyButton, mult: CGFloat)] = []
        for p in puncts {
            let b = baseButton(title: p.title, special: false)
            b.pressedBackground = specialFill
            if Self.isPad { b.padRole = .digit }
            // Âm / rung + balloon lúc chạm như mọi phím ký tự (tester 1.2.8: "rung chưa áp dụng
            // với dấu chấm" — "," / "." / "@" / "/" hàng đáy trước đây im lặng hoàn toàn).
            let shown = p.title
            let ends = ChordProgression.isSentenceEnd(shown)   // "." hàng đáy: kết câu ⇒ vòng hợp âm cách về đầu
            b.addAction(UIAction { [weak self, weak b] _ in
                Self.clickLetter(sentenceEnd: ends)
                if let self, let b { self.showBalloon(over: b, text: shown) }
            }, for: .touchDown)
            b.addAction(UIAction { [weak self] _ in self?.hideBalloonAfterTap() },
                        for: [.touchUpInside, .touchUpOutside, .touchCancel])
            armCommit(b) { [weak self] in self?.tapSymbol(p.insert) }
            // Bàn chữ iPhone: giữ "," ra "." / giữ "." ra "," (phím cạnh space — KeyAlternates.commaHold:
            // bảng ký tự phụ không rỗng; VoiceOver đã rỗng sẵn; iPad có phím ",/." 2 tầng riêng).
            if !Self.isPad, let side = sideKey, p.title == side.char, let alt = side.holdAlt, planeKey == "123",
               KeyAlternates.commaHold(alternates: activeAlts) {
                armCommaHold(b, alt: alt)
            }
            // Phím "," / "." cạnh space: vuốt thẳng xuống ra dấu còn lại (công tắc xét lúc vuốt).
            if !Self.isPad, sideKey != nil, planeKey == "123", p.title == "," || p.title == "." {
                armPunctFlick(b)
            }
            // Ô địa chỉ / URL / email: giữ "." ra hàng đuôi tên miền như stock (DomainPopup).
            let tlds = DomainPopup.choices(kind: inputKind, key: p.title, lettersPlane: planeKey == "123")
            if !tlds.isEmpty { armDomainHold(b, choices: tlds) }
            punctKeys.append((b, p.mult))
        }
        return punctKeys
    }

    private func bottomRow(planeKey: String, clearInsteadOfEmoji: Bool = false) -> KeyRow {
        var views: [UIView] = []
        let planeBtn = makePlaneKey(planeKey)
        views.append(planeBtn)
        // globe sát bên phải [123] như stock (muscle memory), emoji sau đó
        let globeBtn = needsGlobe ? makeGlobeKey() : nil
        if let globe = globeBtn { views.append(globe) }
        // Slot cạnh trái space: bình thường là nút emoji; plane mẫu câu thay
        // bằng THÙNG RÁC = xoá sạch ô nhập (user 2026-07-25). Cùng kiểu nút đơn
        // sắc như ABC nên giữ chung biến emojiBtn để ăn width multiplier 0.10.
        // "Nút emoji" = Thanh trên (EmojiKeyPlacement): bàn CHỮ iPhone không có 😊 — nút nằm trên
        // thanh gợi ý; thanh không hiện ở ô này ⇒ giữ 😊 (emojiInBar false).
        let emojiBtn: KeyButton?
        if planeKey == "123", !clearInsteadOfEmoji, plane == .letters, emojiInBar {
            emojiBtn = nil
        } else if clearInsteadOfEmoji {
            let clear = controlButton(title: "") { [weak self] in
                self?.tapped(.clearField)
            }
            clear.setImage(UIImage(systemName: "trash",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
            clear.tintColor = fnInk
            clear.accessibilityLabel = L("Xoá ô nhập")
            emojiBtn = clear
        } else {
            emojiBtn = makeEmojiKey()
        }
        if let e = emojiBtn { views.append(e) }
        // "Cả hai" (SpaceSideKey.both): phím "," hẹp BÊN TRÁI space (cùng cỡ phím hẹp phải).
        let leftPunctKeys: [(btn: KeyButton, mult: CGFloat)]
        let sideApplies = planeKey == "123" && !Self.isPad && !clearInsteadOfEmoji
            && ![.email, .url, .search].contains(inputKind)
        if sideApplies {
            leftPunctKeys = makePunctKeys(KeyLayout.phoneLettersSides(spaceSideKey).left
                                            .map { ($0, $0, KeyLayout.phoneLettersComma) },
                                          planeKey: planeKey, sideKey: spaceSideKey)
        } else { leftPunctKeys = [] }
        views += leftPunctKeys.map(\.btn)
        let space = makeSpaceKey(primary: true)
        views.append(space)
        // Nhóm phím dấu câu bên phải space. Bình thường là dấu phẩy; ô email/url
        // đổi thành phím tắt như stock (@ . cho email; . / cho url). Chỉ áp
        // ở hàng đáy plane CHỮ (planeKey == "123").
        // iPad plane chữ / số / ký hiệu: hàng đáy kiểu stock (KeyLayout.padBottomRow).
        let padLetters = Self.isPad && planeKey == "123"
        let padSym = Self.isPad && !padLetters && !clearInsteadOfEmoji
            && (plane == .numbers || plane == .symbols)
        let padStock = padLetters || padSym
        let puncts: [(title: String, insert: String, mult: CGFloat)]
        if padSym {
            // compact: ô undo/redo stock bên phải space (",", "₫"); full: không có phím.
            let t = KeyLayout.padSlotTitle(plane == .numbers ? "undo" : "redo") ?? ","
            puncts = padStyle == .compact ? [(t, t, KeyLayout.units("slot", in:
                KeyLayout.padBottomRow(.compact, letters: false)) ?? 0.079)] : []
        } else if planeKey == "123" {
            switch inputKind {
            case .email: puncts = [("@", "@", 0.11), (".", ".", 0.09)]
            // Ô URL (issue #113): không phím ".com" riêng — space rộng như stock; đuôi tên
            // miền (.com .vn .com.vn …) ở giữ "." (DomainPopup). Giữ "/".
            case .url:   puncts = [(".", ".", 0.075), ("/", "/", 0.075)]
            // Thanh địa chỉ: stock hiện "." thay "," (gõ tên miền); iPad đã có ".?" riêng.
            case .search: puncts = padLetters ? [] : [(".", ".", 0.075)]
            // iPad plane chữ: không phím "," riêng như stock ("!," hàng 3 đã có). iPhone: phím
            // hẹp theo "Phím cạnh dấu cách" ("," / "." cùng chỗ cùng cỡ; Tắt ⇒ không phím).
            default:     puncts = padLetters ? [] : KeyLayout.phoneLettersSides(spaceSideKey).right
                                                        .map { ($0, $0, KeyLayout.phoneLettersComma) }
            }
        } else {
            puncts = [(",", ",", 0.075)]
        }
        let sideKey: SpaceSideKey? = sideApplies ? spaceSideKey : nil
        let rightPunctKeys = makePunctKeys(puncts, planeKey: planeKey, sideKey: sideKey)
        views += rightPunctKeys.map(\.btn)
        let punctKeys = leftPunctKeys + rightPunctKeys
        // iPad: return nằm cuối hàng 2 như stock (buildLettersPad / buildPadSymbolic).
        var ret: KeyButton?
        if !padStock {
            let r = returnButton()
            views.append(r)
            ret = r
        }
        // iPad: 🌐 lên đầu hàng như stock ([🌐][.?123|ABC][☺︎]…) — cả plane số/ký hiệu.
        if padStock, let g = globeBtn, let gi = views.firstIndex(where: { $0 === g }) {
            views.remove(at: gi)
            views.insert(g, at: 0)
        }
        // iPad: phím 123 / ABC thứ hai bên phải space như stock.
        var planeBtn2: KeyButton?
        if padStock {
            let b = controlButton(title: planeKey, fire: .down) { [weak self] in
                guard let self else { return }
                self.plane = padLetters ? .numbers : .letters
                if self.plane == .letters { self.reevaluateShiftForLetters() }
                self.rebuild()
            }
            b.accessibilityLabel = padLetters ? L("Số") : L("Chữ")
            views.append(b)
            planeBtn2 = b
        }
        // iPad: phím ẩn bàn phím góc phải dưới như stock
        var dismissBtn: KeyButton?
        if UIDevice.current.userInterfaceIdiom == .pad {
            let d = baseButton(title: "", special: true)
            d.setImage(UIImage(systemName: "keyboard.chevron.compact.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
            d.tintColor = fnInk
            d.accessibilityLabel = L("Ẩn bàn phím")
            d.padRole = .icon
            d.addAction(UIAction { _ in Self.clickModifier() }, for: .touchDown)
            d.addAction(UIAction { [weak self] _ in
                self?.inputController?.dismissKeyboard()
            }, for: .touchUpInside)
            dismissBtn = d
            views.append(d)
        }

        // Hàng đáy SÁT đáy hơn như stock (so ảnh 25/09/2026: stock cách đáy bàn phím
        // 214px, VietTelex 241px): cùng chiều cao phím, dời xuống 3pt (top 8/bottom 2
        // thay 5/5). Vùng globe/mic dưới đó do host vẽ — không dời được.
        // Phím phẳng không bóng như stock (26/09/2026) → hàng đáy sát đáy 0pt.
        // iPhone dọc: vùng 50 = khe 7 + phím 43 như stock (27/09: phím đáy 44 trông cao
        // hơn stock) — applyBottomTrim chỉnh lại khi xoay.
        // iPad: safe area đáy của view (≈5pt) từng lọt vào layoutMargins → phím hàng đáy thấp
        // hơn 3 hàng trên 5pt (45 thay 50, ngang 60 thay 65) và icon/nhãn sát đáy (đo 27/09).
        // Safe area KHÔNG lọt vào lề hàng (mọi máy): đáy hàng phím tránh vạch home DUY NHẤT qua
        // safeBottom (rowsBottom). Trước đây iPhone để true ⇒ xoay/gập máy gập lúc safeBottom chưa
        // kịp đổi thì hàng đáy ăn 18pt vào lề ⇒ phím dẹt (Duo gập + ngang, Phil 06/10/2026).
        let bottomTop = rowSpec.bottomTop
        let stack = KeyRow(views, spacing: keyGapNow,
                           margins: UIEdgeInsets(top: bottomTop, left: sideMarginNow,
                                                 bottom: rowSpec.bottomPad, right: sideMarginNow))
        // Tỉ lệ từ KeyLayout (test: đúng một phím co giãn = space).
        let spec = padStock ? KeyLayout.padBottomRow(padStyle, letters: padLetters) : KeyLayout.phoneBottom
        func frac(_ id: String) -> CGFloat { KeyLayout.units(id, in: spec) ?? 0.1 }
        stack.setWidth(.fraction(frac("plane")), for: planeBtn)
        if let e = emojiBtn { stack.setWidth(.fraction(frac("emoji")), for: e) }
        // Globe PHẢI có width cố định: thiếu thì nó và space cùng "tự do", stack
        // bóp globe còn bề ngang icon và chia lại mỗi lần phím đổi trạng thái —
        // hàng đáy iPad nhảy size khi bấm (feedback 26/09/2026). Chỉ space co giãn.
        if let g = globeBtn { stack.setWidth(.fraction(frac("globe")), for: g) }
        // iPhone plane chữ: "," hẹp hơn stock (KeyLayout.phoneLettersComma), phần dư cho
        // space — chạm space hay lẹm sang "," (Phil 06/10/2026; thêm KeyHitBias).
        let lettersComma = !padStock && planeKey == "123" && !clearInsteadOfEmoji
        let punctUnits: [(title: String, units: CGFloat)] = punctKeys.map { pk in
            let t = pk.btn.currentTitle ?? ""
            let m = t != "," ? pk.mult
                : lettersComma ? KeyLayout.phoneLettersComma : (KeyLayout.units("comma", in: spec) ?? pk.mult)
            return (t, m)
        }
        // "Phím to" (iPhone): "," / "." rộng bằng phím emoji, space co lại (LargeKeys).
        let large = largeKeysActive && !padStock
        let others = frac("plane") + (globeBtn != nil ? frac("globe") : 0)
            + (emojiBtn != nil ? frac("emoji") : 0) + (ret != nil ? frac("return") : 0)
        let widths = LargeKeys.punctUnits(punctUnits, otherUnits: others, on: large)
        for (pk, m) in zip(punctKeys, widths) { stack.setWidth(.fraction(m), for: pk.btn) }
        if let r = ret { stack.setWidth(.fraction(frac("return")), for: r) }
        if let b = planeBtn2 { stack.setWidth(.fraction(frac("plane2")), for: b) }
        if let d = dismissBtn { stack.setWidth(.fraction(padStock ? frac("dismiss") : 0.07), for: d) }
        if padStock {
            // Stock: plane chữ full ".?123", compact (mini) "123"; plane số/ký hiệu "ABC".
            let t = padLetters ? (padStyle == .compact ? "123" : ".?123") : planeKey
            planeBtn.setTitle(t, for: .normal)
            planeBtn2?.setTitle(t, for: .normal)
            padFunction(planeBtn, left: true)
            if let b = planeBtn2 { padFunction(b, left: false) }   // nhãn phải dạt phải như stock
            if let g = globeBtn { padFunction(g, left: true) }
            if let e = emojiBtn { padFunction(e, left: true) }
            if let d = dismissBtn { padFunction(d, left: false) }
            for pk in punctKeys { pk.btn.backgroundColor = plainFill; pk.btn.normalBackground = plainFill }
        }
        return stack
    }

    /// `.fill` + width constraint tường minh (mọi phím chữ bằng nhau, shift/⌫
    /// hàng 3 = 1.5 phím — đặt ở buildLetters): hình học KHÔNG phụ thuộc cỡ
    /// title. `.fillProportionally` đo intrinsic size của title → mỗi lần shift
    /// retitle 26 phím là stack tính lại tỉ lệ và relayout cả bàn phím.
    /// `proportional` chỉ cho hàng 3 plane số/ký hiệu (#+= … ⌫): hàng đó không bao
    /// giờ retitle, giữ nguyên hình học cũ.
    private func row(_ views: [UIView], sideInset: CGFloat = 0,
                     proportional: Bool = false) -> KeyRow {
        // bounds.width có thể = 0 lúc init — layoutSubviews chỉnh lại ngay
        // pass đầu (và sau mỗi lần xoay / đổi cỡ Split View)
        // 10/0 thay 5/5 (khe giữa hàng vẫn 10): hàng đáy sát đáy (26/09/2026).
        let side = KeyGeometry.indentedMargin(width: keysWidth, margin: sideMarginNow,
                                              gap: keyGapNow, units: sideInset)
        let r = KeyRow(views, spacing: keyGapNow,
                       margins: UIEdgeInsets(top: rowSpec.gap, left: side, bottom: 0, right: side))
        if sideInset > 0 { indentedRow = r; indentedRowInset = sideInset }
        // Phím ký tự thường: bằng nhau (mặc định của KeyRow). Hàng tỉ lệ: như .fillProportionally
        // của UIStackView — nội dung từng phím, phím ký tự buộc bằng nhau, ⌫ ≥ 42.
        if proportional {
            r.proportional = (
                intrinsic: { ($0 as? KeyButton)?.contentWidth ?? $0.intrinsicContentSize.width },
                group: { v in
                    if let b = v as? KeyButton, !b.isSpecial { return -1 }
                    return views.firstIndex { $0 === v } ?? 0
                },
                minimum: { ($0 as? KeyButton)?.minWidth ?? 0 })
        }
        return r
    }

    // MARK: bàn số lớn (NumericKeypad — ô numberPad / decimalPad / OTP, iPhone)

    /// Kiểu bàn số lớn của ô hiện tại (nil = ô thường). Đặt qua configureInputKind.
    private var keypadStyle: NumericKeypad.Style?
    private var builtKeypad: NumericKeypad.Style?
    private var builtKeypadPaste = false
    /// 📋 trên bàn số lớn (controller bật khi có Toàn quyền). Đổi ⇒ dựng lại nếu đang ở bàn số.
    var keypadPasteEnabled = false {
        didSet { if oldValue != keypadPasteEnabled, plane == .keypad { rebuild() } }
    }
    /// Chạm 📋 bàn số — controller đọc clipboard, lọc (`NumericKeypad.cleanPaste`) rồi chèn.
    var onKeypadPaste: (() -> Void)?
    /// Nhãn số + chữ cái phụ của plane bàn số đã dựng (cỡ chữ đổi theo hướng tại chỗ).
    private var keypadLabels: [(digit: UILabel, letters: UILabel)] = []
    private var keypadLandscape: Bool?
    /// Đang hiện bàn số lớn — controller chèn số THẲNG (không phím dấu VNI).
    var keypadShown: Bool { plane == .keypad }

    /// Lưới 3×4 như stock: 1 2 3 / 4 5 6 / 7 8 9 / [góc] 0 ⌫. Hàng phẳng (không lồng) ⇒
    /// router khe (nearestControl) / một tay / bottomTrim dùng chung đường plane thường.
    private func buildKeypad() {
        guard let style = keypadStyle else { return buildPlane(rows: numberRows, moreKey: "#+=", altKey: "ABC") }
        indentedRow = nil
        keypadLabels = []
        keypadLandscape = nil
        var firstDigit: UIView?
        for digits in NumericKeypad.gridRows {
            let keys = digits.map { keypadDigit($0, style: style) }
            rowsContainer.addArrangedSubview(keypadRow(keys))      // cùng cha rồi mới ràng buộc
            for k in keys.dropFirst() { k.widthAnchor.constraint(equalTo: keys[0].widthAnchor).isActive = true }
            if firstDigit == nil { firstDigit = keys[0] }
        }
        var corner: [UIView] = []
        for c in NumericKeypad.corner(style: style, needsGlobe: needsGlobe, paste: keypadPasteEnabled) {
            switch c {
            case .globe: corner.append(makeGlobeKey())
            case .letters:
                corner.append(makePlaneKey("ABC"))
            case .text(let t): corner.append(keypadSymbol(t, style: style))
            case .paste: corner.append(makeKeypadPasteKey())
            }
        }
        let zero = keypadDigit("0", style: style)
        let back = backspaceButton()
        rowsContainer.addArrangedSubview(keypadRow(corner + [zero, back]))
        for k in corner.dropFirst() { k.widthAnchor.constraint(equalTo: corner[0].widthAnchor).isActive = true }
        back.widthAnchor.constraint(equalTo: zero.widthAnchor).isActive = true
        if let f = firstDigit { crossRow(zero.widthAnchor.constraint(equalTo: f.widthAnchor)) }
        applyKeypadMetrics()
    }

    private func keypadRow(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = Self.keyGap
        stack.distribution = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.insetsLayoutMarginsFromSafeArea = false
        let side = NumericKeypad.sideMargin(keysWidth: keysWidth, margin: Self.sideMargin)
        stack.layoutMargins = UIEdgeInsets(top: KeyGeometry.rowGap, left: side, bottom: 0, right: side)
        return stack
    }

    /// Phím số: số lớn + chữ cái nhỏ bên dưới (nhãn riêng — title trống, a11y = số).
    private func keypadDigit(_ d: String, style: NumericKeypad.Style) -> KeyButton {
        let b = baseButton(title: "", special: false)
        b.accessibilityLabel = d
        let letters = NumericKeypad.letters(under: d, style: style)
        let digit = UILabel(), sub = UILabel()
        digit.text = d
        sub.text = letters
        for l in [digit, sub] {
            l.textColor = ink
            l.textAlignment = .center
            l.isUserInteractionEnabled = false
            l.isAccessibilityElement = false
        }
        let col = UIStackView(arrangedSubviews: [digit, sub])
        col.axis = .vertical
        col.alignment = .center
        col.spacing = -1
        col.isUserInteractionEnabled = false
        col.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(col)
        NSLayoutConstraint.activate([col.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                                     col.centerYAnchor.constraint(equalTo: b.centerYAnchor)])
        keypadLabels.append((digit, sub))
        keypadPressFeedback(b, preview: d)
        armCommit(b) { [weak self] in self?.tapped(.text(d)) }
        let hold = NumericKeypad.holdChoices(for: d, style: style)
        if !hold.isEmpty { armDomainHold(b, choices: hold, variants: true) }
        return b
    }

    /// 📋 Dán ở ô góc bàn số (icon như nút lịch sử clipboard trên dải).
    private func makeKeypadPasteKey() -> KeyButton {
        let b = controlButton(title: "") { [weak self] in self?.onKeypadPaste?() }
        b.setImage(UIImage(systemName: "doc.on.clipboard",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        b.tintColor = fnInk
        b.accessibilityLabel = L("Dán")
        return b
    }

    /// Phím ký tự ở ô góc (dấu thập phân, *, #).
    private func keypadSymbol(_ t: String, style: NumericKeypad.Style) -> KeyButton {
        let b = baseButton(title: t, special: false)
        b.titleFont = Self.keyFont(24)
        keypadPressFeedback(b, preview: t)
        armCommit(b) { [weak self] in self?.tapped(.text(t)) }
        let hold = NumericKeypad.holdChoices(for: t, style: style)
        if !hold.isEmpty { armDomainHold(b, choices: hold, variants: true) }
        return b
    }

    /// Âm/rung như phím ký tự. Đè: "Phím sẫm khi bấm" BẬT ⇒ sẫm nền như bàn số stock (không
    /// balloon — ô to, ngón không che); TẮT ⇒ ô phóng to nếu công tắc phóng to bật.
    private func keypadPressFeedback(_ b: KeyButton, preview: String) {
        if keyPressHighlightEnabled { b.pressedBackground = specialFill }
        b.addAction(UIAction { [weak self, weak b] _ in
            Self.clickLetter()
            guard let self, let b, !self.keyPressHighlightEnabled else { return }
            self.showBalloon(over: b, text: preview)
        }, for: .touchDown)
        if !keyPressHighlightEnabled {
            b.addAction(UIAction { [weak self] _ in self?.hideBalloon() },
                        for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
    }

    /// Lề hàng (một tay / máy rộng căn giữa) + cỡ chữ theo hướng — gọi lúc dựng và mỗi
    /// layoutSubviews khi đang ở bàn số (xoay không dựng lại plane).
    private func applyKeypadMetrics() {
        let side = NumericKeypad.sideMargin(keysWidth: keysWidth, margin: Self.sideMargin)
        for case let r as UIStackView in rowsContainer.arrangedSubviews where r.layoutMargins.left != side {
            r.layoutMargins = UIEdgeInsets(top: KeyGeometry.rowGap, left: side, bottom: 0, right: side)
        }
        let land = isLandscapeNow
        guard keypadLandscape != land else { return }
        keypadLandscape = land
        let t = NumericKeypad.typography(landscape: land)
        for l in keypadLabels {
            l.digit.font = Self.keyFont(t.digit)
            l.letters.font = .systemFont(ofSize: max(t.letters, 1), weight: .semibold)
            l.letters.isHidden = t.letters == 0 || (l.letters.text ?? "").isEmpty
        }
    }

    // MARK: buttons

    /// Phím: UIControl nhẹ thay UIButton (khởi động lạnh — tạo UIButton + bộ máy titleLabel của
    /// nó ~25–35 ms cho cả lưới). Giữ đúng phần API UIButton bàn phím dùng (một nhãn, một ảnh
    /// thường/đè, lề nội dung, căn trái/phải/trên/dưới, ảnh sẫm khi đè) — nhãn/ảnh tạo lười
    /// MỘT lần, khung tính tay ở layoutSubviews theo đúng quy tắc làm tròn của UIButton
    /// (nhãn: cỡ làm tròn lên điểm nguyên, gốc làm tròn pixel; ảnh: gốc làm tròn xuống pixel).
    /// Touch / sự kiện vẫn là UIControl (touchDown, drag, up inside/outside, cancel) như cũ.
    final class KeyButton: UIControl {
        override init(frame: CGRect) {
            super.init(frame: frame)
            // UIButton tự là phần tử trợ năng (nhãn = chữ trên phím, vai "nút"); UIControl thì không.
            isAccessibilityElement = true
            accessibilityTraits = .button
        }
        required init?(coder: NSCoder) { fatalError() }

        // MARK: nội dung kiểu UIButton
        private var title: String?
        private var titleColorNormal: UIColor?
        /// Phông nhãn — giữ riêng để đặt phông KHÔNG tạo nhãn cho phím chỉ có icon.
        var titleFont: UIFont = .systemFont(ofSize: 15) {
            didSet { if titleFont !== oldValue { label?.font = titleFont; setNeedsLayout() } }
        }
        private var label: UILabel?
        private var imageNormal: UIImage?
        private var imageHighlighted: UIImage?
        private var symbolConfigNormal: UIImage.SymbolConfiguration?
        private var symbolConfigHighlighted: UIImage.SymbolConfiguration?
        private var iconView: UIImageView?
        /// Như UIButton.contentEdgeInsets.
        var contentEdgeInsets: UIEdgeInsets = .zero {
            didSet { if contentEdgeInsets != oldValue { setNeedsLayout() } }
        }
        override var contentHorizontalAlignment: UIControl.ContentHorizontalAlignment {
            didSet { if contentHorizontalAlignment != oldValue { setNeedsLayout() } }
        }
        override var contentVerticalAlignment: UIControl.ContentVerticalAlignment {
            didSet { if contentVerticalAlignment != oldValue { setNeedsLayout() } }
        }
        /// Như UIButton: không có ảnh "đè" riêng ⇒ icon sẫm lại khi đè.
        var adjustsImageWhenHighlighted = true

        func setTitle(_ t: String?, for state: UIControl.State) {
            guard state == .normal, t != title else { return }
            title = t
            if let t, !t.isEmpty {
                let l = titleLabel!
                if l.text != t { l.text = t }
                if l.isHidden { l.isHidden = false }
            } else {
                label?.isHidden = true
            }
            setNeedsLayout()
        }
        var currentTitle: String? { title }
        func title(for state: UIControl.State) -> String? { title }

        func setTitleColor(_ c: UIColor?, for state: UIControl.State) {
            guard state == .normal else { return }
            titleColorNormal = c
            label?.textColor = c ?? .white
        }
        func titleColor(for state: UIControl.State) -> UIColor? { titleColorNormal ?? .white }

        /// Nhãn (tạo lười như UIButton.titleLabel). Phím chỉ có icon không bao giờ tạo.
        var titleLabel: UILabel? {
            if let label { return label }
            let l = UILabel()
            l.font = titleFont
            l.textColor = titleColorNormal ?? .white
            l.lineBreakMode = .byTruncatingMiddle    // như UIButton
            l.isAccessibilityElement = false
            l.text = title
            l.isHidden = (title ?? "").isEmpty
            addSubview(l)
            label = l
            return l
        }

        func setImage(_ img: UIImage?, for state: UIControl.State) {
            if state == .highlighted { imageHighlighted = img } else if state == .normal { imageNormal = img } else { return }
            refreshIcon()
        }
        func image(for state: UIControl.State) -> UIImage? {
            state == .highlighted ? (imageHighlighted ?? imageNormal) : imageNormal
        }
        var currentImage: UIImage? { isHighlighted ? (imageHighlighted ?? imageNormal) : imageNormal }
        var imageView: UIImageView? { iconView }
        func setPreferredSymbolConfiguration(_ c: UIImage.SymbolConfiguration?, forImageIn state: UIControl.State) {
            if state == .highlighted { symbolConfigHighlighted = c } else if state == .normal { symbolConfigNormal = c } else { return }
            refreshIcon()
        }

        override var isHighlighted: Bool {
            didSet { if isHighlighted != oldValue, iconView != nil { refreshIcon() } }
        }
        override func tintColorDidChange() {
            super.tintColorDidChange()
            if isHighlighted, iconView != nil { refreshIcon() }
        }
        /// Ảnh đang hiện (ảnh đè nếu có khi đè; áp cấu hình SF Symbol ưu tiên) + sẫm khi đè như UIButton.
        private func refreshIcon() {
            let useHighlighted = isHighlighted && imageHighlighted != nil
            var img = useHighlighted ? imageHighlighted : imageNormal
            let cfg = useHighlighted ? (symbolConfigHighlighted ?? symbolConfigNormal) : symbolConfigNormal
            if let c = cfg, let i = img, i.isSymbolImage { img = i.applyingSymbolConfiguration(c) ?? i }
            guard let img else {
                if let v = iconView, v.image != nil { v.image = nil; v.isHidden = true }
                return
            }
            let v = iconView ?? {
                let v = UIImageView()
                v.isAccessibilityElement = false
                // Dưới nhãn như UIButton (ảnh trước, nhãn sau) — trên lớp skin / lỗ thoát âm (layer).
                if let l = label { insertSubview(v, belowSubview: l) } else { addSubview(v) }
                iconView = v
                return v
            }()
            if v.image !== img {
                if v.image?.size != img.size { setNeedsLayout() }
                v.image = img
            }
            if v.isHidden { v.isHidden = false; setNeedsLayout() }
            // UIButton (custom) vẽ icon sẫm lại khi đè nếu không có ảnh đè riêng (~0,53 sáng).
            let dim = isHighlighted && !useHighlighted && adjustsImageWhenHighlighted
            if dim { v.tintColor = Self.dimmed(tintColor); iconDimmed = true }
            else if iconDimmed { v.tintColor = nil; iconDimmed = false }
        }
        private var iconDimmed = false
        static func dimmed(_ c: UIColor) -> UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return c }
            let k: CGFloat = 8 / 15
            return UIColor(red: r * k, green: g * k, blue: b * k, alpha: a)
        }

        /// Cỡ chữ đã đo (dùng chung mọi phím, sống cả process): bàn phím dựng lại MỖI lần hiện
        /// (controller mới) — chữ / phông / bề ngang không đổi thì khỏi đo lại bằng CoreText.
        private struct TextKey: Hashable {
            let text: String, font: String, size: CGFloat, width: CGFloat, fit: Bool, minScale: CGFloat
        }
        nonisolated(unsafe) private static var textSizes: [TextKey: CGSize] = [:]
        static func dropTextSizeCache() { textSizes.removeAll() }
        /// Cỡ tự nhiên của nhãn phụ (UILabel.intrinsicContentSize) — cache như trên.
        static func labelSize(_ l: UILabel) -> CGSize {
            guard let t = l.text else { return l.intrinsicContentSize }
            let key = TextKey(text: t, font: l.font.fontName, size: l.font.pointSize, width: -1, fit: false, minScale: 0)
            if let s = textSizes[key] { return s }
            let s = l.intrinsicContentSize
            textSizes[key] = s
            return s
        }

        /// Cỡ nhãn trong bề ngang `width` như UIButton: UILabel.textRect (chữ dài ⇒ cắt / co chữ khi
        /// adjustsFontSizeToFitWidth), làm tròn lên điểm nguyên.
        private func titleTextSize(width: CGFloat = .greatestFiniteMagnitude) -> CGSize {
            guard let t = title, let l = label else { return .zero }
            let w = max(width, 0), fit = l.adjustsFontSizeToFitWidth
            let key = TextKey(text: t, font: l.font.fontName, size: l.font.pointSize, width: w, fit: fit,
                              minScale: fit ? l.minimumScaleFactor : 0)
            if let s = Self.textSizes[key] { return s }
            let r = l.textRect(forBounds: CGRect(x: 0, y: 0, width: w, height: CGFloat.greatestFiniteMagnitude),
                               limitedToNumberOfLines: 1)
            var size = CGSize(width: ceil(r.width), height: ceil(r.height))
            if fit, w < .greatestFiniteMagnitude {
                // Co chữ cho vừa (nhãn góc iPad): UIButton đo hộp theo phông ĐÃ co (thấp hơn).
                let natural = (t as NSString).size(withAttributes: [.font: l.font as Any])
                if natural.width > w, natural.width > 0 {
                    // Co tới đáy (minimumScaleFactor) vẫn không vừa ⇒ hộp = chữ đã cắt giữa ở phông nhỏ nhất.
                    let k = max(l.minimumScaleFactor, w / natural.width)
                    let small = l.font.withSize(l.font.pointSize * k)
                    if natural.width * l.minimumScaleFactor <= w {
                        let h = (t as NSString).size(withAttributes: [.font: small]).height
                        size = CGSize(width: ceil(natural.width * k), height: ceil(h))
                    } else {
                        let m = Self.measureLabel
                        m.font = small
                        m.text = t
                        let r2 = m.textRect(forBounds: CGRect(x: 0, y: 0, width: w, height: CGFloat.greatestFiniteMagnitude),
                                            limitedToNumberOfLines: 1)
                        size = CGSize(width: ceil(r2.width), height: ceil(r2.height))
                    }
                }
            }
            Self.textSizes[key] = size
            return size
        }
        /// Nhãn nháp đo chữ đã co (chỉ nhãn góc iPad chật — hiếm).
        private static let measureLabel: UILabel = {
            let l = UILabel()
            l.lineBreakMode = .byTruncatingMiddle
            return l
        }()
        private var pixelScale: CGFloat {
            let s = traitCollection.displayScale
            return s > 0 ? s : UIScreen.main.scale
        }

        /// Vùng nội dung = bounds trừ lề, nở ra mép pixel (gốc làm tròn xuống, mép xa làm tròn lên)
        /// như UIButton — nhãn/icon dạt phải/dưới bám đúng pixel như cũ.
        private func contentRect() -> CGRect {
            let i = contentEdgeInsets
            // Không dùng CGRect.inset: lề lớn hơn phím ⇒ rect âm bị chuẩn hoá thành bề rộng dương.
            let r = CGRect(x: bounds.minX + i.left, y: bounds.minY + i.top,
                           width: max(bounds.width - i.left - i.right, 0), height: max(bounds.height - i.top - i.bottom, 0))
            let k = pixelScale
            // ±1e-4 px: khung phím đã làm tròn pixel (32.333…·3 = 97.0000001) không nở thêm 1 px.
            let e: CGFloat = 1e-4
            let x0 = (r.minX * k + e).rounded(.down) / k, y0 = (r.minY * k + e).rounded(.down) / k
            let x1 = (r.maxX * k - e).rounded(.up) / k, y1 = (r.maxY * k - e).rounded(.up) / k
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }

        /// Khung nhãn trong `bounds` như UIButton.titleRect(forContentRect:) (+ baseline stock).
        private func titleFrame() -> CGRect {
            let content = contentRect()
            var size = titleTextSize(width: content.width)
            var x: CGFloat, y: CGFloat
            switch contentHorizontalAlignment {
            case .left, .leading: x = content.minX
            case .right, .trailing: x = content.maxX - size.width
            case .fill: x = content.minX; size.width = max(content.width, 0)
            default: x = content.minX + (content.width - size.width) / 2
            }
            switch contentVerticalAlignment {
            case .top: y = content.minY
            case .bottom: y = content.maxY - size.height
            case .fill: y = content.minY; size.height = max(content.height, 0)
            default: y = content.minY + (content.height - size.height) / 2
            }
            let k = pixelScale
            let r = CGRect(x: (x * k).rounded() / k, y: (y * k).rounded() / k, width: size.width, height: size.height)
            return baselineAdjusted(r)
        }

        /// Khung icon như UIButton.imageRect(forContentRect:): cỡ ảnh, gốc làm tròn XUỐNG pixel.
        private func imageFrame(_ img: UIImage) -> CGRect {
            let content = contentRect()
            // Phím thấp/hẹp hơn ảnh: ảnh co theo vùng nội dung (như UIButton).
            let size = CGSize(width: min(img.size.width, max(content.width, 0)),
                              height: min(img.size.height, max(content.height, 0)))
            var x: CGFloat, y: CGFloat
            switch contentHorizontalAlignment {
            case .left, .leading: x = content.minX
            case .right, .trailing: x = content.maxX - size.width
            default: x = content.minX + (content.width - size.width) / 2
            }
            switch contentVerticalAlignment {
            case .top: y = content.minY
            case .bottom: y = content.maxY - size.height
            default: y = content.minY + (content.height - size.height) / 2
            }
            let k = pixelScale
            return CGRect(x: (x * k).rounded(.down) / k, y: (y * k).rounded(.down) / k, width: size.width, height: size.height)
        }

        private func layoutContent() {
            pixelShift = targetPixelShift()
            let ps = pixelShift
            if let l = label, !l.isHidden {
                let f = titleFrame().offsetBy(dx: ps, dy: ps)
                if l.frame != f { l.frame = f }
            }
            if let v = iconView, !v.isHidden, let img = v.image {
                let f = imageFrame(img).offsetBy(dx: ps, dy: ps)
                if v.frame != f { v.frame = f }
            }
            layoutOverlays()
        }

        // MARK: nhãn phụ trên phím (ký tự phụ góc trên-phải, mã VI/EN + logo phím cách, nhãn phụ /
        // nhãn 2 tầng iPad) — đặt khung tay (trước: 2 constraint mỗi nhãn ⇒ Auto Layout cả phím).
        enum OverlayPin {
            /// Mép phải cách `right`, đỉnh cách `top` (cỡ = cỡ tự nhiên của nhãn).
            case topRight(right: CGFloat, top: CGFloat)
            /// Mép phải cách `right`, đáy cách `bottom`.
            case bottomRight(right: CGFloat, bottom: CGFloat)
            /// Cỡ cố định, mép phải cách `right`, giữa theo chiều dọc.
            case rightCenterY(right: CGFloat, size: CGSize)
            /// Giữa theo ngang; baseline dòng đầu = tâm phím + `belowCenter` (âm = phía trên).
            case centerBaseline(belowCenter: CGFloat)
            /// Giữa phím (cỡ tự nhiên).
            case center
        }
        private var overlays: [(view: UIView, pin: OverlayPin)] = []
        var hasOverlays: Bool { !overlays.isEmpty }
        func addOverlay(_ v: UIView, _ pin: OverlayPin) {
            addSubview(v)
            overlays.append((v, pin))
            setNeedsLayout()
        }
        func setOverlayPin(_ v: UIView, _ pin: OverlayPin) {
            guard let i = overlays.firstIndex(where: { $0.view === v }) else { return }
            overlays[i].pin = pin
            setNeedsLayout()
        }
        override func willRemoveSubview(_ subview: UIView) {
            super.willRemoveSubview(subview)
            overlays.removeAll { $0.view === subview }
        }
        /// Khung CHÍNH XÁC của phím (toạ độ gốc lưới, KeyRow đặt) + gốc đã làm tròn — nhãn phụ tính
        /// theo khung chính xác rồi làm tròn từng mép theo toạ độ gốc như Auto Layout. nil ⇒ bounds.
        var exactFrame: CGRect?
        var roundedOrigin: CGPoint = .zero
        /// Như Auto Layout: cỡ = intrinsicContentSize, từng mép làm tròn về pixel.
        private func layoutOverlays() {
            guard !overlays.isEmpty else { return }
            let k = pixelScale
            let o = exactFrame == nil ? .zero : roundedOrigin
            let bounds = exactFrame ?? self.bounds
            for (v, pin) in overlays {
                let size: CGSize
                var x0: CGFloat, y0: CGFloat
                switch pin {
                case .topRight(let r, let t):
                    size = Self.overlaySize(v)
                    x0 = bounds.maxX - r - size.width; y0 = bounds.minY + t
                case .bottomRight(let r, let b):
                    size = Self.overlaySize(v)
                    x0 = bounds.maxX - r - size.width; y0 = bounds.maxY - b - size.height
                case .rightCenterY(let r, let s):
                    size = s
                    x0 = bounds.maxX - r - s.width; y0 = bounds.midY - s.height / 2
                case .center:
                    size = Self.overlaySize(v)
                    x0 = bounds.midX - size.width / 2; y0 = bounds.midY - size.height / 2
                case .centerBaseline(let below):
                    size = Self.overlaySize(v)
                    x0 = bounds.midX - size.width / 2
                    let ascent = (v as? UILabel)?.font.ascender ?? size.height
                    y0 = bounds.midY + below - Self.firstBaselineOffset(size.height, ascent: ascent, label: v as? UILabel)
                }
                let f = KeyRowLayout.rounded(x0: x0, x1: x0 + size.width, y0: y0, y1: y0 + size.height, scale: k)
                    .offsetBy(dx: -o.x, dy: -o.y)
                if v.frame != f { v.frame = f }
            }
        }
        private static func overlaySize(_ v: UIView) -> CGSize {
            if let l = v as? UILabel { return labelSize(l) }
            return v.intrinsicContentSize
        }
        /// Khoảng từ đỉnh nhãn một dòng (cỡ tự nhiên) tới baseline dòng đầu.
        static func firstBaselineOffset(_ height: CGFloat, ascent: CGFloat, label: UILabel?) -> CGFloat {
            guard let f = label?.font else { return ascent }
            // UILabel đặt dòng chữ giữa hộp cao `height` (≥ lineHeight): baseline = đỉnh + phần đệm + ascender.
            return (height - f.lineHeight) / 2 + f.ascender
        }

        /// Luật bề rộng trong hàng (KeyRow) — nil = phím ký tự thường ⇒ bằng nhau, phím chức năng ⇒ co giãn.
        var rowWidth: KeyRowLayout.Width?
        /// Bề rộng tối thiểu (⇧ / ⌫ = 42) — chỉ hàng tỉ lệ (hàng 3 bàn số) dùng, như ràng buộc ≥ 42 cũ.
        var minWidth: CGFloat = 0

        /// Bề ngang nội dung như UIButton.intrinsicContentSize (nhãn ≥ 30pt, icon = bề ngang ảnh,
        /// + lề nội dung) — chỉ hàng tỉ lệ (hàng 3 bàn số) dùng. intrinsicContentSize để mặc định
        /// (không có): phím đặt khung tay, Auto Layout không cần đo chữ từng phím.
        var contentWidth: CGFloat {
            var w: CGFloat = 0
            if let img = currentImage { w = img.size.width }
            else if let t = title, !t.isEmpty { _ = titleLabel; w = max(titleTextSize().width, 30) }
            else { w = 30 }
            return w + contentEdgeInsets.left + contentEdgeInsets.right
        }

        override var accessibilityLabel: String? {
            get { super.accessibilityLabel ?? ((title ?? "").isEmpty ? nil : title) }
            set { super.accessibilityLabel = newValue }
        }

        var isSpecial = false
        /// Phím cách (chính hoặc phụ bàn tách đôi) — vùng nở của nó không được lấn khung phím dấu câu.
        var isSpaceKey = false
        var payload: String?    // suggestion slot: nội dung sẽ chèn khi bấm
        var downPayload: String? // payload chốt lúc chạm xuống (slot gợi ý)
        var normalBackground: UIColor?
        /// nil = không đổi màu khi đè. Phím chữ/số/ký hiệu: chỉ có khi bật "Phím sẫm khi bấm".
        var pressedBackground: UIColor?
        /// Đổi nền phím (đè / nhả): một phép gán màu trên layer sẵn có — không view/layer mới,
        /// không alloc. pressedBackground nil ⇒ no-op. KHÔNG bọc CATransaction riêng: layer của
        /// UIView vốn không có implicit animation ngoài khối UIView.animate (UIView trả NSNull
        /// cho action), còn begin/commit tường minh ngoài transaction ngầm lại ép commit đồng bộ
        /// lên render server — đo 12/10/2026 (KeyboardBench): sync_p50 +~0.1ms/phím.
        func showPressed(_ on: Bool) {
            if let sl = skinLayer {
                // Skin theme: đổi ảnh đè / thường = gán con trỏ CGImage (ảnh đã giải sẵn, dùng chung).
                pressShown = on
                let img = on || skinLatched ? (skinPressed ?? skinNormal) : skinNormal
                if (sl.contents as AnyObject?) !== img { sl.contents = img }
                setPixelSunk(on || skinLatched)
                return
            }
            guard let c = on ? pressedBackground : (pressedBackground != nil ? normalBackground : nil) else { return }
            pressShown = on
            if backgroundColor != c { backgroundColor = c }
        }
        /// Đang hiện nền đè (applyShiftAppearance không ghi đè nền khi ngón còn trên ⇧).
        private(set) var pressShown = false

        // MARK: skin phím (theme JSON "keys") — ảnh 9-slice thay nền màu; nil = như cũ (0 chi phí).
        private(set) var skinLayer: CALayer?
        private(set) var skinNormal: CGImage?
        private var skinPressed: CGImage?
        private var skinInsets: [Int]?
        private var skinLaidOut: CGSize = .zero
        /// ⇧ bật/Caps trên phím có skin: giữ ảnh đè (thay cho nền đảo màu).
        private var skinLatched = false
        func setSkinLatched(_ on: Bool) {
            guard let sl = skinLayer, skinLatched != on else { return }
            skinLatched = on
            guard !pressShown else { return }
            let img = on ? (skinPressed ?? skinNormal) : skinNormal
            if (sl.contents as AnyObject?) !== img { sl.contents = img }
            setPixelSunk(on)
        }
        /// Skin điểm ảnh: nhãn / icon theo tâm MẶT phím (PixelKeys.labelShift) — lún thì dời theo, KHÔNG lượt layout
        /// (dời thẳng tâm view; layoutContent áp lại cùng độ dời). Skin khác: 0.
        private var pixelShift: CGFloat = 0
        private var pixelSunk = false
        private var pixelBlock: CGFloat { bounds.height / CGFloat(PixelKeys.cells) }
        private func targetPixelShift() -> CGFloat {
            guard skin?.pixelated == true, bounds.height > 0 else { return 0 }
            return CGFloat(PixelKeys.labelShift(block: Double(pixelBlock), pressed: pixelSunk))
        }
        private func setPixelSunk(_ sunk: Bool) {
            guard skin?.pixelated == true, sunk != pixelSunk else { return }
            pixelSunk = sunk
            let t = targetPixelShift(), d = t - pixelShift
            guard d != 0 else { return }
            pixelShift = t
            if let l = label, !l.isHidden { l.center = CGPoint(x: l.center.x + d, y: l.center.y + d) }
            if let v = iconView, !v.isHidden { v.center = CGPoint(x: v.center.x + d, y: v.center.y + d) }
        }
        /// Skin đang dùng (ô phóng to vẽ cùng skin).
        private(set) var skin: LoadedThemeAssets.Skin?
        /// Có skin ⇒ nền màu luôn trong (màu theme chỉ là dự phòng khi thiếu ảnh).
        override var backgroundColor: UIColor? {
            get { super.backgroundColor }
            set { super.backgroundColor = skinLayer == nil ? newValue : .clear }
        }
        func setSkin(_ s: LoadedThemeAssets.Skin?) {
            skin = s
            guard let s else {
                if let sl = skinLayer { sl.removeFromSuperlayer(); skinLayer = nil; backgroundColor = normalBackground }
                skinNormal = nil; skinPressed = nil; skinInsets = nil
                return
            }
            let sl = skinLayer ?? {
                let l = CALayer()
                // Không hoạt ảnh ngầm (đổi ảnh đè phải tức thì, không tốn transaction).
                l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                             "contentsScale": NSNull(), "contentsCenter": NSNull(), "frame": NSNull()]
                layer.insertSublayer(l, at: 0)
                skinLayer = l
                return l
            }()
            skinNormal = s.normal; skinPressed = s.pressed; skinInsets = s.insets
            sl.contents = s.normal
            // Ảnh điểm ảnh 16 px phóng ~8× ⇒ "nearest" giữ khối vuông sắc (ảnh tải về: mượt như cũ).
            let filter: CALayerContentsFilter = s.pixelated ? .nearest : .linear
            if sl.magnificationFilter != filter { sl.magnificationFilter = filter }
            pixelSunk = false
            sl.contentsCenter = s.insets.map { NineSlice.contentsCenter($0, w: s.normal.width, h: s.normal.height) }
                ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            super.backgroundColor = .clear
            layer.borderWidth = 0
            // Skin có ảnh đè ⇒ bật đường đè (dù "Phím sẫm khi bấm" tắt) — chỉ đổi con trỏ ảnh.
            if s.pressed != nil, pressedBackground == nil { pressedBackground = .clear }
            skinLaidOut = .zero
            setNeedsLayout()
        }
        /// Lúc layout (không mỗi lần gõ): khung + contentsScale để góc 9-slice đúng cỡ (NineSlice).
        private func layoutSkin() {
            guard let sl = skinLayer, let img = skinNormal, bounds.size != skinLaidOut,
                  bounds.width > 0, bounds.height > 0 else { return }
            skinLaidOut = bounds.size
            sl.frame = bounds
            let h = Double(img.height)
            if let ins = skinInsets {
                let k = NineSlice.shrink(ins, srcH: img.height, width: Double(bounds.width), height: Double(bounds.height))
                sl.contentsScale = CGFloat(h / (Double(bounds.height) * k))
            } else {
                sl.contentsScale = CGFloat(h / Double(bounds.height))
            }
        }
        #if DEBUG
        var debugSkinLayer: CALayer? { skinLayer }
        #endif
        private var pressedAt: CFTimeInterval = 0
        private(set) var releasePending = false
        /// Chạm xuống: sẫm + ghi giờ. pressedBackground nil (công tắc TẮT) ⇒ thoát ngay.
        func press() {
            guard pressedBackground != nil else { return }
            if releasePending {
                releasePending = false
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(releaseDeferred),
                                                       object: nil)
            }
            pressedAt = CACurrentMediaTime()
            showPressed(true)
        }
        /// Nhấc / huỷ: thôi sẫm — nhưng nếu mới sẫm chưa tới BalloonGeometry.minVisible thì
        /// thôi TRỄ. Phím sát mép màn hình (q/a/1, p/l/0, ⇧, ⌫, 123, return): iOS giữ touch để
        /// phân xử cử chỉ hệ thống rồi giao began + ended CÙNG một vòng runloop ⇒ sẫm rồi
        /// thôi sẫm trước khi kịp lên màn hình (bug tester 1.2.10 — ô phóng to đã có cùng cách
        /// chữa, hideBalloonAfterTap). Đường thường: một phép trừ, không hẹn giờ.
        func release() {
            guard pressedBackground != nil, pressShown, !releasePending else { return }
            let d = BalloonGeometry.hideDelay(shownFor: CACurrentMediaTime() - pressedAt)
            guard d > 0 else { showPressed(false); return }
            releasePending = true
            perform(#selector(releaseDeferred), with: nil, afterDelay: d, inModes: [.common])
        }
        @objc private func releaseDeferred() {
            guard releasePending else { return }
            releasePending = false
            showPressed(false)
        }
        /// Hit-area tuỳ biến (âm = nở rộng). Slot trên bar 20pt cần nở XUỐNG
        /// 16pt phủ hết strip 36 — tâm ngón tay hay rơi dưới đáy bar là vùng
        /// chết, nguồn của "chevron/burger bấm mãi không ăn".
        var hitInsets: UIEdgeInsets?
        /// Nhãn chữ đặt theo baseline stock (KeyGeometry.Typography) thay vì căn giữa hộp dòng.
        var baselineAligned = false
        /// Nhãn chữ: dời hộp nhãn (đang căn giữa) để baseline về đúng chỗ stock.
        private func baselineAdjusted(_ r: CGRect) -> CGRect {
            guard baselineAligned, let f = label?.font, bounds.height > 0 else { return r }
            // Hộp nhãn đang căn giữa phím; dời để baseline về đúng chỗ stock.
            let dy: CGFloat
            if let below = padBaselineBelowCenter {
                let m = KeyGeometry.Typography.Pad.metrics(landscape: Self.padLandscape)
                dy = KeyGeometry.Typography.offsetY(toBaseline: bounds.height / 2 + m.scaled(below, keyHeight: bounds.height),
                                                    keyHeight: bounds.height,
                                                    ascender: f.ascender, descender: f.descender)
            } else {
                dy = KeyGeometry.Typography.titleOffsetY(keyHeight: bounds.height,
                                                         ascender: f.ascender, descender: f.descender)
            }
            let lf = KeyboardView.labelFonts
            if styledKey, lf.active {
                // Chữ to / phông khác: giữ baseline stock nếu mực còn trong phím, không thì dời.
                let h = bounds.height
                let natural = h / 2 + (f.ascender + f.descender) / 2   // baseline khi căn giữa hộp dòng
                let fitted = KeyLabelFit.baseline(preferred: natural + dy, size: f.pointSize,
                                                  em: lf.em(KeyLabelEm.keySample), keyHeight: h)
                return r.offsetBy(dx: 0, dy: (bounds.midY - r.midY) + fitted - natural)
            }
            return r.offsetBy(dx: 0, dy: (bounds.midY - r.midY) + dy)
        }

        // MARK: iPad — chữ theo KeyGeometry.Typography.Pad, đổi theo hướng máy TẠI CHỖ
        // (xoay không dựng lại plane): KeyboardView đặt `padLandscape` đầu mỗi layout pass,
        // mỗi phím tự áp lại ở layoutSubviews của nó khi hướng khác lần áp trước.
        /// `center`: kiểu compact (iPad mini) — icon/nhãn giữa phím như stock.
        enum PadRole { case letter, digit, corner(left: Bool), icon, punct, center }
        static var padLandscape = false
        var padRole: PadRole? { didSet { padApplied = nil; setNeedsLayout() } }
        /// (hướng máy, chiều cao phím) lần áp trước — số đo quanh tâm co theo chiều cao.
        private var padApplied: (landscape: Bool, height: CGFloat)?
        private var padBaselineBelowCenter: CGFloat?
        weak var padHint: UILabel?
        /// Ký tự phụ iPad của phím thường (plane số, phím 2 tầng) — armPadAlternate.
        var padAlt: String?
        var padAltChosen = false
        var padAltStart: CGPoint?
        var padAltTimer: DispatchWorkItem?
        var onPadAltChoose: (() -> Void)?
        // MARK: chạm mới khi phím đang đè chốt rồi đổi plane (KeyCommitQueue.flush(except:changes:))
        /// Gọi TRƯỚC touchDown của UIControl: chốt phím đang đè. true ⇒ plane đã đổi và chạm đã
        /// chuyển sang plane mới — nút này (plane cũ, không còn hiện) bỏ qua mọi sự kiện của chạm đó.
        var preTouchDown: ((KeyButton, UITouch, UIEvent?) -> Bool)?
        /// Sự kiện tiếp theo (moved / ended / cancelled) của chạm đã chuyển.
        var onForwardedTouches: ((UITouch.Phase, Set<UITouch>, UIEvent?) -> Void)?
        private var forwardedTouches: Set<ObjectIdentifier> = []
        /// Chạm vừa bắt đầu trên nút (phím đổi plane theo dõi nó sau khi bị gỡ — carryPress).
        weak var lastBeganTouch: UITouch?
        /// Phím ký tự của plane số / ký hiệu: ký tự chèn khi trượt từ phím 123 tới rồi nhấc (#171).
        var slideInsert: String?
        /// Chỉ phím 123: moved / ended / cancelled của chạm trên nút (trượt từ 123 — #171). nil ⇒ 0 việc.
        var onTouchPhase: ((UITouch, UITouch.Phase) -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            lastBeganTouch = touches.first
            guard let pre = preTouchDown else { return super.touchesBegan(touches, with: event) }
            var keep = touches
            for t in touches where pre(self, t, event) {
                keep.remove(t)
                forwardedTouches.insert(ObjectIdentifier(t))
                // Giữ space cũ (trackpad) không được nhận diện trên nút đã bỏ.
                gestureRecognizers?.forEach { $0.isEnabled = false; $0.isEnabled = true }
            }
            if !keep.isEmpty { super.touchesBegan(keep, with: event) }
        }
        private func splitForwarded(_ touches: Set<UITouch>, _ phase: UITouch.Phase, _ event: UIEvent?) -> Set<UITouch> {
            guard !forwardedTouches.isEmpty else { return touches }
            var fwd = Set<UITouch>(), rest = Set<UITouch>()
            for t in touches {
                let id = ObjectIdentifier(t)
                guard forwardedTouches.contains(id) else { rest.insert(t); continue }
                fwd.insert(t)
                if phase != .moved { forwardedTouches.remove(id) }
            }
            if !fwd.isEmpty { onForwardedTouches?(phase, fwd, event) }
            return rest
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            let rest = splitForwarded(touches, .moved, event)
            if let f = onTouchPhase { for t in rest { f(t, .moved) } }
            if !rest.isEmpty { super.touchesMoved(rest, with: event) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let rest = splitForwarded(touches, .ended, event)
            if let f = onTouchPhase { for t in rest { f(t, .ended) } }
            if !rest.isEmpty { super.touchesEnded(rest, with: event) }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            let rest = splitForwarded(touches, .cancelled, event)
            if let f = onTouchPhase { for t in rest { f(t, .cancelled) } }
            if !rest.isEmpty { super.touchesCancelled(rest, with: event) }
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            if padAlt != nil { padAltStart = touch.location(in: self) }
            return super.beginTracking(touch, with: event)
        }
        /// Vuốt XUỐNG quá ngưỡng → ký tự phụ; trôi ngang/lên quá slop → huỷ hẹn giờ giữ.
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            if padAlt != nil, !padAltChosen, let s = padAltStart {
                let p = touch.location(in: self)
                if KeyLayout.isPadFlick(dx: p.x - s.x, dy: p.y - s.y, threshold: KeyboardView.flickDistance) {
                    onPadAltChoose?()
                } else if hypot(p.x - s.x, p.y - s.y) > KeyAlternates.slop {
                    padAltTimer?.cancel(); padAltTimer = nil
                }
            }
            return super.continueTracking(touch, with: event)
        }
        /// Đọc + xoá lựa chọn ký tự phụ lúc phím chốt (lần chạm sau bắt đầu sạch).
        func takePadAlt() -> Bool { defer { padAltChosen = false }; return padAltChosen }
        var padPunctLabels: [UILabel] = []

        override func layoutSubviews() {
            #if DEBUG
            KeyboardView.perfKeyLayoutPasses += 1
            #endif
            applyPadTypographyIfNeeded()
            applyKeyStyleIfNeeded()
            layoutSkin()
            layoutSoundhole()
            super.layoutSubviews()
            layoutContent()
        }

        // MARK: lỗ thoát âm (theme Ghi-ta, "spaceDeco":"soundhole") — chỉ phím cách của theme đó; khác ⇒ rỗng (0 chi phí).
        /// [lỗ tối, vành ngoài, vành trong] — path dựng lại chỉ khi cỡ phím đổi (lúc layout, không mỗi lần gõ).
        private(set) var soundholeLayers: [CAShapeLayer] = []
        private var soundholeLaidOut: CGSize = .zero
        func setSoundhole(ring: UIColor, inner: UIColor) {
            if soundholeLayers.isEmpty {
                for i in 0..<3 {
                    let l = CAShapeLayer()
                    l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
                    if i == 0 { l.strokeColor = nil } else { l.fillColor = nil }
                    layer.insertSublayer(l, at: UInt32(skinLayer == nil ? i : i + 1))
                    soundholeLayers.append(l)
                }
            }
            soundholeLayers[0].fillColor = UIColor.black.withAlphaComponent(CGFloat(Soundhole.holeAlpha)).cgColor
            soundholeLayers[1].strokeColor = ring.cgColor
            soundholeLayers[2].strokeColor = inner.cgColor
            soundholeLaidOut = .zero
            setNeedsLayout()
        }
        private func layoutSoundhole() {
            guard !soundholeLayers.isEmpty, bounds.size != soundholeLaidOut, bounds.width > 0, bounds.height > 0 else { return }
            soundholeLaidOut = bounds.size
            let r = CGFloat(Soundhole.radius(width: Double(bounds.width), height: Double(bounds.height)))
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            func circle(_ rr: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr), transform: nil) }
            soundholeLayers[0].frame = bounds; soundholeLayers[0].path = circle(r)
            for (i, ring) in Soundhole.rings.enumerated() {
                let l = soundholeLayers[1 + i]
                l.frame = bounds
                l.lineWidth = CGFloat(ring.width) * r
                l.path = circle(CGFloat(ring.radius) * r)
            }
        }
        /// Phím (baseButton) — nhận bo góc / kẹp chữ của Tuỳ chỉnh nâng cao. Slot gợi ý, nút rail: false.
        var styledKey = false
        /// Cỡ applyKeycapFont đã xin (chưa nhân hệ số / chưa kẹp).
        var requestedFontSize: CGFloat = 0
        /// Tuỳ chỉnh nâng cao lúc LAYOUT (không mỗi lần gõ): bo góc theo cỡ phím; chữ to /
        /// phông rộng ⇒ thu nhỏ vừa phím (chữ rộng nhất + dấu mũ/móc, phần dưới dòng).
        private func applyKeyStyleIfNeeded() {
            guard styledKey, bounds.width > 0, bounds.height > 0 else { return }
            if let pct = KeyboardView.cornerPercent {
                let r = KeyStyle.cornerRadius(percent: pct, size: bounds.size, fallback: KeyboardView.keyRadius)
                if layer.cornerRadius != r { layer.cornerRadius = r }
            }
            let lf = KeyboardView.labelFonts
            guard lf.active, let t = currentTitle, !t.isEmpty else { return }
            let f = titleFont
            let em = lf.em(KeyLabelEm.keySample)
            var fitted = KeyLabelFit.size(want: f.pointSize, em: em, keyWidth: bounds.width, keyHeight: bounds.height)
            if t.count > 1 {   // nhãn nhiều ký tự (123, return…): đo thật bề ngang
                let w = (t as NSString).size(withAttributes: [.font: f]).width
                let room = bounds.width - 2 * KeyLabelFit.sidePad
                if w > room, w > 0 { fitted = min(fitted, f.pointSize * room / w) }
            }
            if fitted < f.pointSize - 0.25 { titleFont = lf.font(size: fitted.rounded(.down)) }
        }
        /// Icon SF Symbol cỡ stock iPad (kể cả ảnh đặt lại sau: shift/caps đổi trạng thái).
        private func applyPadSymbolSize(_ m: KeyGeometry.Typography.Pad.Metrics) {
            let c = UIImage.SymbolConfiguration(pointSize: m.iconPointSize, weight: .regular)
            setPreferredSymbolConfiguration(c, forImageIn: .normal)
            setPreferredSymbolConfiguration(c, forImageIn: .highlighted)
            // Ảnh dựng sẵn cỡ riêng (return/🌐/⌨︎ pointSize 17) không nhận preferred config
            // → thay config của chính ảnh.
            for st in [UIControl.State.normal, .highlighted] {
                if let img = image(for: st), img.isSymbolImage,
                   img.symbolConfiguration?.isEqual(to: c) != true {
                    setImage(img.withConfiguration(c), for: st)
                }
            }
        }
        private func applyPadTypographyIfNeeded() {
            guard let role = padRole else { return }
            let land = Self.padLandscape, h = bounds.height
            if let a = padApplied, a.landscape == land, a.height == h { return }
            padApplied = (land, h)
            let m = KeyGeometry.Typography.Pad.metrics(landscape: land)
            switch role {
            case .letter, .digit:
                if case .letter = role { titleFont = KeyboardView.keyFont(m.letterSize) }
                else { titleFont = KeyboardView.keyFont(m.digitSize) }
                contentVerticalAlignment = .center
                contentEdgeInsets = .zero
                baselineAligned = true
                if case .letter = role {
                    padBaselineBelowCenter = m.letterBaselineBelowCenter
                    padHint?.font = KeyboardView.keyFont(m.hintSize)
                    if let l = padHint { setOverlayPin(l, .centerBaseline(belowCenter: -m.scaled(m.hintBaselineAboveCenter, keyHeight: h))) }
                } else {
                    padBaselineBelowCenter = m.digitBaselineBelowCenter
                }
            case .corner(let left):
                contentHorizontalAlignment = left ? .left : .right
                contentVerticalAlignment = .bottom
                if let t = currentTitle, !t.isEmpty {
                    let f = KeyboardView.keyFont(m.labelSize)
                    titleFont = f
                    titleLabel?.adjustsFontSizeToFitWidth = true
                    titleLabel?.minimumScaleFactor = 0.7
                    // Đáy hộp nhãn = baseline + descender (descender < 0).
                    let bottom = max(m.labelBaselineAboveBottom + f.descender, 0)
                    contentEdgeInsets = UIEdgeInsets(top: 0, left: m.labelSideInset,
                                                     bottom: bottom, right: m.labelSideInset)
                } else {
                    // Ảnh vẽ tay (☺︎) không có lề trong như SF Symbol → dùng thẳng số đo mép nét.
                    let sym = currentImage?.isSymbolImage ?? true
                    let ins = sym ? KeyGeometry.Typography.Pad.iconContentInsets(m)
                                  : (side: m.iconSideInset, bottom: m.iconBottomInset)
                    contentEdgeInsets = UIEdgeInsets(top: 0, left: ins.side, bottom: ins.bottom, right: ins.side)
                }
                applyPadSymbolSize(m)
            case .icon:
                applyPadSymbolSize(m)
            case .center:
                contentHorizontalAlignment = .center
                contentVerticalAlignment = .center
                contentEdgeInsets = .zero
                if let t = currentTitle, !t.isEmpty {
                    let size = t == "#+=" ? m.centerToggleLabelSize : m.centerLabelSize
                    titleFont = KeyboardView.keyFont(size)
                    titleLabel?.adjustsFontSizeToFitWidth = true
                    titleLabel?.minimumScaleFactor = 0.6
                }
                var c = m
                c.iconPointSize = m.centerIconPointSize
                applyPadSymbolSize(c)
            case .punct:
                let f = KeyboardView.keyFont(m.punctSize)
                for (i, l) in padPunctLabels.enumerated() {
                    l.font = f
                    let v = i == 0 ? m.punctUpperBaselineBelowCenter : m.punctLowerBaselineBelowCenter
                    setOverlayPin(l, .centerBaseline(belowCenter: m.scaled(v, keyHeight: h)))
                }
            }
        }
        // Khe hở giữa phím (spacing 6 + padding hàng 5) là VÙNG CHẾT với
        // UIButton thường — chạm trúng khe = mất phím. Stock keyboard route
        // mọi điểm chạm về phím gần nhất; mở rộng hit area phủ nửa khe cho
        // hiệu quả tương đương, không đổi kiến trúc touch.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            if let i = hitInsets { return bounds.inset(by: i).contains(point) }
            return bounds.insetBy(dx: -3, dy: -5.5).contains(point)
        }
    }

    /// Icon phím emoji vẽ tay giống stock iOS (không SF Symbol nào khớp): mặt
    /// cười viền tròn, mắt tròn, miệng mở với dải răng cong theo môi trên.
    /// Template → tintColor tô theo sáng/tối.
    private static let emojiKeyIcon: UIImage = {
        let d: CGFloat = 21, lw: CGFloat = 1.7
        let img = UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { ctx in
            let c = ctx.cgContext
            UIColor.black.set()
            c.setLineWidth(lw)
            c.strokeEllipse(in: CGRect(x: lw / 2, y: lw / 2, width: d - lw, height: d - lw))
            let er: CGFloat = 1.2
            c.fillEllipse(in: CGRect(x: 7.4 - er, y: 8 - er, width: 2 * er, height: 2 * er))
            c.fillEllipse(in: CGRect(x: 13.6 - er, y: 8 - er, width: 2 * er, height: 2 * er))
            // Miệng: môi trên cong nhẹ, môi dưới cong sâu.
            let l = CGPoint(x: 4.3, y: 12.3), r = CGPoint(x: 16.7, y: 12.3)
            let mouth = CGMutablePath()
            mouth.move(to: l)
            mouth.addQuadCurve(to: r, control: CGPoint(x: 10.5, y: 14.9))
            mouth.addCurve(to: l, control1: CGPoint(x: 16.2, y: 19.6),
                           control2: CGPoint(x: 4.8, y: 19.6))
            mouth.closeSubpath()
            c.addPath(mouth); c.fillPath()
            // Răng: đục rỗng dải song song môi trên, rồi vẽ lại viền miệng để
            // dải không phá mép.
            c.saveGState()
            c.addPath(mouth); c.clip()
            c.setBlendMode(.clear)
            let band = CGMutablePath()
            band.move(to: CGPoint(x: 3, y: 12.7))
            band.addQuadCurve(to: CGPoint(x: 18, y: 12.7), control: CGPoint(x: 10.5, y: 15.3))
            band.addLine(to: CGPoint(x: 18, y: 14.7))
            band.addQuadCurve(to: CGPoint(x: 3, y: 14.7), control: CGPoint(x: 10.5, y: 17.3))
            band.closeSubpath()
            c.addPath(band); c.fillPath()
            c.setBlendMode(.normal)
            c.setLineWidth(1.3)
            c.addPath(mouth); c.strokePath()
            c.restoreGState()
        }
        return img.withRenderingMode(.alwaysTemplate)
    }()

    private func baseButton(title: String, special: Bool) -> KeyButton {
        // .custom, not .system: system buttons run tint/highlight animations on
        // the main thread per touch — visible latency on a keyboard.
        let b = KeyButton()
        // ĐẦU TIÊN trong mọi touchDown (kể cả phím chữ qua router sendActions): chốt
        // các phím nhấc-mới-chốt đang đè TRƯỚC khi phím này làm gì — đúng thứ tự
        // khi gõ chồng ngón (KeyCommitQueue).
        b.addAction(UIAction { [weak self, weak b] _ in
            self?.settleAltHold()                 // ký tự phụ đang giữ chốt TRƯỚC phím mới
            self?.commits.flush(except: b.map(ObjectIdentifier.init))
        }, for: .touchDown)
        // Chạm thật trên nút (không qua router): chốt TRƯỚC khi UIControl bắt đầu theo dõi — chốt
        // đổi plane (space / dấu ở 123 về ABC) ⇒ chạm chuyển sang plane mới (flushBeforeButtonDown).
        b.preTouchDown = { [weak self] b, t, e in self?.flushBeforeButtonDown(b, touch: t, event: e) ?? false }
        b.onForwardedTouches = { [weak self] phase, ts, e in self?.reroutedTouchEvents(phase, ts, e) }
        b.isMultipleTouchEnabled = true
        b.isSpecial = special
        b.setTitle(title, for: .normal)
        b.titleFont = .systemFont(ofSize: special ? 16 : 23)
        if !special { applyKeycapFont(b, title: title) }
        b.layer.cornerRadius = Self.keyRadius
        b.styledKey = true
        if let border = palette.keyBorder {
            b.layer.borderWidth = 1
            b.layer.borderColor = border.ui.cgColor
        }
        b.setTitleColor(special ? fnInk : ink, for: .normal)
        // iOS 26+: MỌI phím cùng nền (phím chức năng không còn xám) — 26/09/2026. Theme tô phím
        // chức năng riêng (Xanh lá) ⇒ fnFill.
        b.backgroundColor = special ? fnFill : plainFill
        b.normalBackground = b.backgroundColor
        // Pressed state cho phím chức năng: swap màu phẳng, KHÔNG
        // UIView.animate — animation per-touch trên main thread là latency
        // thấy được trên bàn phím (lý do dùng .custom ở trên). Đè = sẫm lại.
        if special { b.pressedBackground = specialFill }
        // Phím chữ / số / ký hiệu: pressedBackground chỉ gán khi công tắc "Phím sẫm khi bấm"
        // BẬT (lúc dựng plane) — TẮT ⇒ nil ⇒ hai closure này thoát ngay như trước.
        b.addAction(UIAction { [weak b] _ in b?.press() }, for: .touchDown)
        b.addAction(UIAction { [weak b] _ in b?.release() },
                    for: [.touchUpInside, .touchUpOutside, .touchCancel])
        if themeAssets != nil { applySkin(b, role: special ? "special" : "default") }
        return b
    }

    /// Skin theme cho vai `role` (đã giải thứ tự từng phím → nhóm trong ThemeAssetPlan). Không có ⇒ màu theme.
    private func applySkin(_ b: KeyButton, role: String) {
        guard let a = themeAssets else { return }
        b.setSkin(a.skins[role])
    }

    // Âm click phát ở TOUCH-DOWN như stock (nguồn cảm giác "nhanh").
    // playInputClick tôn trọng Settings→Sounds→Keyboard Clicks (AudioServices
    // trước đây bỏ qua setting); mất phân biệt 3 tông — chấp nhận.
    // Rung: iOS vô hiệu UIFeedbackGenerator trong keyboard extension khi
    // không có Full Access — controller chỉ bật cờ khi setting ON + hasFullAccess.
    nonisolated(unsafe) static var hapticsEnabled = false
    /// "Âm thanh phím" (setting keySound + Full Access): BẬT ⇒ tiếng riêng qua KeySound,
    /// KHÔNG kèm playInputClick (không kêu đôi). TẮT ⇒ y như cũ (click hệ thống).
    nonisolated(unsafe) static var customSoundEnabled = false
    /// "Âm thanh nét vuốt" (SwipeSound): nil = Tắt / thiếu Full Access (controller đặt lúc hiện) ⇒ đường vuốt chỉ đọc
    /// một optional.
    nonisolated(unsafe) static var swipeSound: SwipeSound?
    /// Kiểu "Piano" / "Đàn tranh" (cùng customSoundEnabled): mỗi phím một nốt theo nhãn phím (`pianoMap`) —
    /// controller bật khi kiểu là nhạc cụ (KeyInstrument). Kiểu khác: đường 3 tiếng như cũ.
    nonisolated(unsafe) static var pianoEnabled = false
    /// Bảng nốt của nhạc cụ đang chọn (Piano / Đàn tranh) — controller đặt một lần lúc hiện.
    nonisolated(unsafe) static var pianoMap: NoteMap = .piano
    /// Pedal ngân của Piano (Shift/Caps người dùng bấm).
    nonisolated(unsafe) static var pianoPedal = PianoPedal()
    /// Vòng hợp âm phím cách (Piano / Ghi-ta; count 0 = nhạc cụ không có vòng — Đàn tranh) — controller đặt lúc hiện.
    nonisolated(unsafe) static var chordProgression = ChordProgression(count: 0)
    /// Đồng hồ (giây) của vòng hợp âm — test thay để giả lập nghỉ gõ.
    nonisolated(unsafe) static var progressionClock: () -> Double = { CACurrentMediaTime() }
    static var pianoActive: Bool { customSoundEnabled && pianoEnabled }
    #if DEBUG
    /// Test hook: đường âm lần bấm gần nhất — "system" | "custom:<loại>".
    nonisolated(unsafe) static var debugLastClickRoute: String?
    #endif
    private static func feedback(_ kind: KeySoundKind) {
        if customSoundEnabled {
            KeySound.shared.play(kind)
            #if DEBUG
            debugLastClickRoute = "custom:\(kind)"
            #endif
        } else {
            UIDevice.current.playInputClick()
            #if DEBUG
            debugLastClickRoute = "system"
            #endif
        }
        if hapticsEnabled { impact() }
    }
    /// Rung một nhịp (Core Haptics, độ mạnh theo cài đặt). UIImpactFeedbackGenerator IM LẶNG trong keyboard extension trên
    /// iOS 27 dù đủ setting + Full Access (đo trên iPhone Phil 28/09/2026: App Group có
    /// hapticFeedback=1, kbFullAccess=1 mà không rung) — extension không phải app
    /// "active" nên UIKit bỏ qua. Dùng system sound 1519 (Peek, Taptic nhẹ) — không
    /// phụ thuộc trạng thái app, không phát tiếng.
    private static func impact() {
        if KeyHaptics.shared.play() { return }
        // Dự phòng (không Core Haptics / đang lùi sau lỗi): vẫn theo thanh trượt (1519 nhẹ / 1520 mạnh).
        AudioServicesPlaySystemSound(KeyHaptics.fallbackSoundID(forPercent: KeyHaptics.shared.percent))
    }
    /// Phím ký tự; `key` = nhãn phím (Piano chọn nốt theo vị trí). Kiểu khác bỏ qua `key`.
    /// `sentenceEnd`: phím không nhãn nhưng là dấu kết câu ("." hàng đáy) — vòng hợp âm cách về đầu.
    static func clickLetter(_ key: String? = nil, sentenceEnd: Bool = false) {
        if pianoActive {
            if chordProgression.count > 0 {
                chordProgression.typed(now: progressionClock(), sentenceEnd: sentenceEnd || ChordProgression.isSentenceEnd(key))
            }
            piano(.note(pianoMap.midi(forKey: key)), typed: true)
            return
        }
        feedback(.letter)
    }
    static func clickDelete() {
        if pianoActive {
            if chordProgression.count > 0 { chordProgression.typed(now: progressionClock(), sentenceEnd: false) }
            piano(.delete, typed: false)
            return
        }
        feedback(.delete)
    }
    static func clickModifier() { feedback(.modifier) }
    /// Phím cách: Piano / Ghi-ta ⇒ hợp âm KẾ TIẾP của vòng (ChordProgression: C → Am → F → G / Am → F → C → G, nghỉ
    /// > 3 s hoặc kết câu ⇒ về đầu); Đàn tranh ⇒ hợp âm dây buông cố định; kiểu khác ⇒ tiếng phím chức năng như cũ.
    static func clickSpace() {
        if pianoActive {
            if chordProgression.count > 0 { piano(.chord(chordProgression.space(now: progressionClock())), typed: false) }
            else { piano(.space, typed: false) }
            return
        }
        feedback(.modifier)
    }
    /// Enter: Piano ⇒ hợp âm "kết" (chủ + năm); Máy chữ ⇒ tiếng phím + "ding" về dòng (KeySound.playReturn);
    /// kiểu khác ⇒ tiếng phím chức năng.
    static func clickReturn() {
        if pianoActive {
            if chordProgression.count > 0 { chordProgression.returnKey(now: progressionClock()) }   // chủ rồi về đầu vòng
            piano(.returnKey, typed: false)
            return
        }
        if customSoundEnabled {
            KeySound.shared.playReturn()
            #if DEBUG
            debugLastClickRoute = "custom:return"
            #endif
            if hapticsEnabled { impact() }
            return
        }
        feedback(.modifier)
    }
    /// Phím Shift vừa bấm, `result` = trạng thái SAU khi bấm. Piano ⇒ tiếng pedal (xuống) hoặc damper
    /// (tắt Caps); kiểu khác ⇒ tiếng phím chức năng như cũ.
    static func clickShift(_ result: PianoPedal.Shift) {
        guard pianoActive else { feedback(.modifier); return }
        switch pianoPedal.shiftPressed(result) {
        case .pedalDown: KeySound.shared.playPiano(.pedal, sustain: false)
        case .damper: KeySound.shared.damper()
        case .none: break
        }
        #if DEBUG
        debugLastClickRoute = "piano:pedal:\(pianoPedal.state)"
        #endif
        if hapticsEnabled { impact() }
    }
    /// Kết câu không qua phím "." (cách đúp ⇒ ". "): vòng hợp âm cách về đầu.
    static func chordSentenceEnd() {
        guard pianoActive, chordProgression.count > 0 else { return }
        chordProgression.typed(now: progressionClock(), sentenceEnd: true)
    }
    /// Shift đổi không do bấm phím Shift (rời plane…): Caps tắt ⇒ damper.
    static func pianoShiftChanged(_ now: PianoPedal.Shift) {
        guard pianoActive, pianoPedal.shiftChanged(now) == .damper else { return }
        KeySound.shared.damper()
    }
    private static func piano(_ ev: PianoEvent, typed: Bool) {
        let sustain = typed ? pianoPedal.noteTyped() : pianoPedal.isDown
        KeySound.shared.playPiano(ev, sustain: sustain)
        #if DEBUG
        if case .note(let m) = ev { debugLastClickRoute = "piano:\(m)\(sustain ? ":sustain" : "")" }
        else { debugLastClickRoute = "piano:\(ev)" }
        #endif
        if hapticsEnabled { impact() }
    }
    /// Nấc vuốt ⌫ thêm/bớt một từ: chỉ âm (không rung), theo đường âm đang chọn.
    static func clickWordStep() {
        if customSoundEnabled { KeySound.shared.play(.delete) } else { UIDevice.current.playInputClick() }
    }
    /// Đổi ngôn ngữ bằng vuốt phím cách: chỉ rung nhẹ (theo công tắc Rung phím).
    static func flickFeedback() {
        guard hapticsEnabled else { return }
        impact()
    }

    private func letterButton(_ s: String) -> UIView {
        let title = (shift == .off) ? s : s.uppercased()
        let b = baseButton(title: title, special: false)
        // Touch của phím CHỮ do router (touchesBegan/Ended của KeyboardView)
        // điều phối — nearest-key, không thể miss. Button chỉ còn là visual +
        // hộp action được sendActions() kích.
        b.isUserInteractionEnabled = false
        if keyPressHighlightEnabled { b.pressedBackground = specialFill }
        if themeAssets != nil, ThemeAssetSpec.skinKeys.contains(s.lowercased()) { applySkin(b, role: s.lowercased()) }
        letterKeys.append((b, s))
        if Self.isPad {
            // Chữ + ký tự phụ căn theo tâm phím như stock (KeyGeometry.Typography.Pad).
            if let sec = Self.padSecondary[s] { addPadHint(sec, to: b) }
            b.padRole = .letter
        } else if let c = s.first, let alt = activeAlts[c] {
            // Nhãn ký tự phụ nhỏ, mờ ở góc trên-phải như Gboard — dựng một lần theo layout.
            let l = UILabel()
            l.text = alt
            l.font = .systemFont(ofSize: 10, weight: .medium)
            l.textColor = inkFaded(0.45)
            l.isUserInteractionEnabled = false
            l.isAccessibilityElement = false
            b.addOverlay(l, .topRight(right: 3, top: 2))
        }
        // Chèn NGAY touch-down như stock iOS: chữ lên tức thì, không phụ thuộc
        // vào việc giao touch-up (main thread bận → touch-up trễ → "phím không
        // ăn"). Rollover vẫn đúng vì mỗi down tự chèn ký tự của nó.
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self, let b else { return }
            Self.clickLetter(s)                      // feedback tức thì (Piano: nốt theo phím)
            self.showBalloon(over: b, text: b.currentTitle ?? title)
            self.fxMark(b)
            self.shiftBeforeLastLetter = self.shift
            let cased: Character = (self.shift == .off) ? Character(s) : Character(s.uppercased())
            if let d = self.deferredLetterID {        // gõ vuốt / vuốt-lên-lệnh + vùng chọn: chèn lúc nhấc
                // Điểm chạm (tự sửa) + khung hiệu ứng của CHÍNH phím này đi cùng chữ hoãn.
                let report = self.deferredLetterReport, fx = self.fxRect
                self.fxRect = nil
                self.commits.arm(d) { [weak self] in
                    report?()
                    self?.fxRect = fx
                    self?.tapped(.letter(cased))
                }
            } else {
                self.tapped(.letter(cased))
            }
            if self.shift == .on { self.shift = .off; self.applyShiftAppearance() }
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in
            self?.hideBalloonAfterTap()
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    // MARK: key preview balloon — callout bezier LIỀN KHỐI với phím như stock:
    // bubble loe rộng phía trên, cổ cong ôm xuống trọn footprint phím.
    // (Hàng trên cùng vẫn bị kẹp trong bounds extension — giới hạn đã biết,
    // docs/ios-app.md; bar gợi ý bật thì có 30pt headroom.)
    private final class BalloonView: UIView {
        let label = UILabel()
        private let shape = CAShapeLayer()
        private var pathKey = ""
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.zPosition = 10
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 1)
            layer.shadowRadius = 2
            layer.shadowOpacity = 0.3
            layer.addSublayer(shape)
            label.font = .systemFont(ofSize: 34)
            label.textAlignment = .center
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError() }
        /// Phông nhãn đổi (Tuỳ chỉnh nâng cao) ⇒ lần hiện kế dựng lại path + phông.
        func invalidateStyle() { pathKey = "" }

        /// keyRect trong toạ độ superview. Path cache theo hình dạng — gõ cùng
        /// một hàng phím thì không dựng lại path (không alloc trên hot path).
        /// Skin phím (theme JSON): bubble vẽ cùng ảnh 9-slice với phím; nil ⇒ chỉ màu (như cũ).
        private var skinLayer: CALayer?
        private var skinFor: (image: CGImage, w: CGFloat, h: CGFloat)?
        private func applySkin(_ skin: LoadedThemeAssets.Skin?, bubble: CGSize) {
            guard let skin else { skinLayer?.isHidden = true; return }
            let sl = skinLayer ?? {
                let l = CALayer()
                l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
                             "contentsScale": NSNull(), "contentsCenter": NSNull()]
                layer.insertSublayer(l, above: shape)
                skinLayer = l
                return l
            }()
            sl.isHidden = false
            if let f = skinFor, f.image === skin.normal, f.w == bubble.width, f.h == bubble.height { return }
            skinFor = (skin.normal, bubble.width, bubble.height)
            sl.contents = skin.normal
            sl.magnificationFilter = skin.pixelated ? .nearest : .linear
            sl.frame = CGRect(origin: .zero, size: bubble)
            let img = skin.normal
            if let ins = skin.insets {
                sl.contentsCenter = NineSlice.contentsCenter(ins, w: img.width, h: img.height)
                let k = NineSlice.shrink(ins, srcH: img.height, width: Double(bubble.width), height: Double(bubble.height))
                sl.contentsScale = CGFloat(Double(img.height) / (Double(bubble.height) * k))
            } else {
                sl.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
                sl.contentsScale = CGFloat(img.height) / max(bubble.height, 1)
            }
        }
        #if DEBUG
        var debugSkinContents: AnyObject? { skinLayer?.isHidden == false ? skinLayer?.contents as AnyObject? : nil }
        #endif

        func present(keyRect: CGRect, text: String, popup: PopupUI, topLimit: CGFloat, containerWidth: CGFloat,
                     skin: LoadedThemeAssets.Skin? = nil) {
            // Sát mép màn hình: bubble dời vào trong (BalloonGeometry), không tràn ra bị cắt.
            frame = BalloonGeometry.frame(keyRect: keyRect, containerWidth: containerWidth, topLimit: topLimit)
            let bubbleW = frame.width, top = frame.minY
            let kx0 = keyRect.minX - frame.minX, kx1 = keyRect.maxX - frame.minX
            let bubbleH = max(keyRect.minY - top - 6, 22)
            let H = frame.height
            let key = "\(bubbleW)|\(kx0)|\(H)|\(bubbleH)|\(keyRect.width)"
            if key != pathKey {
                pathKey = key
                // Bo góc như phím (Tuỳ chỉnh nâng cao / theme) — kẹp để cổ + bubble vẫn liền khối.
                let st = popup.style
                let kr = min(st.radius(size: keyRect.size, fallback: KeyboardView.keyRadius), keyRect.width / 2, (H - bubbleH) / 2)
                let r = min(st.radius(size: keyRect.size, fallback: 9), bubbleH / 2, bubbleW / 2)
                let neckY = min(bubbleH + 12, H)
                let p = UIBezierPath()
                p.move(to: CGPoint(x: 0, y: bubbleH))
                p.addLine(to: CGPoint(x: 0, y: r))
                p.addQuadCurve(to: CGPoint(x: r, y: 0), controlPoint: .zero)
                p.addLine(to: CGPoint(x: bubbleW - r, y: 0))
                p.addQuadCurve(to: CGPoint(x: bubbleW, y: r),
                               controlPoint: CGPoint(x: bubbleW, y: 0))
                p.addLine(to: CGPoint(x: bubbleW, y: bubbleH))
                // cổ phải: S-curve từ mép bubble vào mép phím
                p.addCurve(to: CGPoint(x: kx1, y: neckY),
                           controlPoint1: CGPoint(x: bubbleW, y: bubbleH + 7),
                           controlPoint2: CGPoint(x: kx1, y: bubbleH + 5))
                p.addLine(to: CGPoint(x: kx1, y: H - kr))
                p.addQuadCurve(to: CGPoint(x: kx1 - kr, y: H),
                               controlPoint: CGPoint(x: kx1, y: H))
                p.addLine(to: CGPoint(x: kx0 + kr, y: H))
                p.addQuadCurve(to: CGPoint(x: kx0, y: H - kr),
                               controlPoint: CGPoint(x: kx0, y: H))
                p.addLine(to: CGPoint(x: kx0, y: neckY))
                // cổ trái
                p.addCurve(to: CGPoint(x: 0, y: bubbleH),
                           controlPoint1: CGPoint(x: kx0, y: bubbleH + 5),
                           controlPoint2: CGPoint(x: 0, y: bubbleH + 7))
                p.close()
                shape.path = p.cgPath
                layer.shadowPath = p.cgPath
                label.frame = CGRect(x: 0, y: 0, width: bubbleW, height: bubbleH)
                // Bubble thấp (ít headroom): co chữ cho vừa — không để glyph bị cắt nửa. Cỡ chữ theo
                // "Cỡ chữ trên phím" (kẹp vừa bubble trong popupFont).
                let size = min(34 * CGFloat(st.labelScale), (bubbleH * 0.9).rounded())
                let f = KeyboardView.popupFont(size, height: bubbleH)
                if label.font != f { label.font = f }
                shape.fillColor = popup.fill.cgColor
                shape.strokeColor = popup.border
                shape.lineWidth = CGFloat(st.borderWidth)
                label.textColor = popup.ink
            }
            if skin != nil || skinLayer != nil {
                applySkin(skin, bubble: CGSize(width: bubbleW, height: max(keyRect.minY - top - 6, 22)))
            }
            label.text = text
            isHidden = false
        }
    }

    /// Ô phóng to chữ khi bấm (Tính năng → Giao diện, App Group "keyPreviewEnabled",
    /// mặc định BẬT). Tắt ⇒ không tạo BalloonView, không vẽ gì khi bấm (bớt CPU/GPU).
    static let keyPreviewKey = "keyPreviewEnabled"
    private(set) var keyPreviewEnabled = true
    /// Đọc cài đặt (nil/không có key = bật như trước).
    static func keyPreviewSetting(_ d: UserDefaults?) -> Bool {
        d?.object(forKey: keyPreviewKey) == nil || d?.bool(forKey: keyPreviewKey) == true
    }
    /// "Phím sẫm khi bấm" (Tính năng → Phím & cử chỉ, App Group "keyPressHighlight"): phím
    /// chữ/số/ký hiệu đổi nền như stock khi đè, độc lập với ô phóng to. Đọc MỘT lần lúc hiện
    /// (applyAppearance), nằm trong chữ ký rebuild — TẮT ⇒ phím không có pressedBackground,
    /// đường chạm không làm thêm gì.
    static let keyPressHighlightKey = "keyPressHighlight"
    static let keyPressHighlightDefault = true
    var keyPressHighlightEnabled = KeyboardView.keyPressHighlightDefault {
        didSet { if keyPressHighlightEnabled != oldValue { rebuild() } }
    }
    static func keyPressHighlightSetting(_ d: UserDefaults?) -> Bool {
        guard let d, d.object(forKey: keyPressHighlightKey) != nil else { return keyPressHighlightDefault }
        return d.bool(forKey: keyPressHighlightKey)
    }
    private var balloonMade = false
    private lazy var balloon: BalloonView = { balloonMade = true; return BalloonView() }()
    /// Lớp chứa ô phóng to: khung = bounds KeyboardView (toạ độ trùng nhau). Ô phóng to đổi cỡ
    /// theo phím ⇒ Core Animation đánh dấu SUPERLAYER cần layout; nằm thẳng trong KeyboardView thì
    /// MỖI phím chạy cả layoutSubviews của bàn phím (KeyboardRenderBudgetTests.testKeypressBudget).
    /// Lớp chứa rỗng: layout của nó không làm gì.
    private lazy var balloonHost: UIView = {
        let v = UIView(frame: bounds)
        v.isUserInteractionEnabled = false
        v.backgroundColor = nil
        v.layer.zPosition = 10   // như ô phóng to cũ: trên phím / hiệu ứng / tiền cảnh
        return v
    }()
    var debugBalloonMade: Bool { balloonMade }
    #if DEBUG
    /// Mọi lớp phủ trọn bàn phím vẽ theo toạ độ của KeyboardView (test #151: phải chung hệ toạ độ).
    /// Thêm lớp phủ mới kiểu này ⇒ thêm vào đây.
    var debugCoordinateOverlays: [UIView] {
        [keyEffects, balloonMade ? balloonHost : nil, mole, spotlight].compactMap { $0 }
    }
    /// Test: tệp tải về đang nạp + view ảnh nền / tiền cảnh theme + skin ô phóng to.
    var debugThemeAssets: LoadedThemeAssets? { themeAssets }
    var debugThemeImageView: UIImageView { themeImageView }
    var debugForegroundView: UIImageView { foregroundView }
    var debugBalloonSkin: AnyObject? { balloonMade ? balloon.debugSkinContents : nil }
    func debugShowBalloon(over key: UIView, text: String) { showBalloon(over: key, text: text, force: true) }
    /// Thứ tự (chỉ số subview) của hàng phím / tiền cảnh / ô phóng to.
    var debugZOrder: (rows: Int?, foreground: Int?, balloon: Int?) {
        (subviews.firstIndex(of: rowsContainer), subviews.firstIndex(of: foregroundView),
         balloonMade ? subviews.firstIndex(of: balloonHost) : nil)
    }
    #endif
    private func showBalloon(over key: UIView, text: String, force: Bool = false) {
        guard keyPreviewEnabled || force else { return }
        let f = convert(key.bounds, from: key)
        // Không bao giờ vượt mép trên view (extension bị cắt ở đó) — headroom luôn có
        // (KeyLayout.balloonHeadroom); bubble thấp thì chữ co cho vừa.
        let topLimit: CGFloat = 0
        if balloonHost.superview !== self { addSubview(balloonHost) }
        balloonHost.shareCoordinateSpace(with: self)
        if balloon.superview !== balloonHost { balloonHost.addSubview(balloon) }
        if balloonHidePending {               // balloon chạm trước đang chờ ẩn trễ — huỷ
            balloonHidePending = false
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideBalloonDeferred), object: nil)
        }
        balloon.present(keyRect: f, text: text, popup: popup, topLimit: topLimit, containerWidth: bounds.width,
                        skin: themeAssets == nil ? nil : (key as? KeyButton)?.skin)
        balloonShownAt = CACurrentMediaTime()
    }
    private func hideBalloon() { if balloonMade { balloon.isHidden = true } }
    /// Nhấc tay khỏi phím ký tự: ẩn balloon, nhưng nếu nó mới hiện chưa tới
    /// BalloonGeometry.minVisible (touch sát mép bị iOS giao began+ended một lượt) thì
    /// ẩn trễ cho kịp lên màn hình. Đường thường: một phép trừ, không hẹn giờ.
    private func hideBalloonAfterTap() {
        guard balloonMade, !balloon.isHidden else { return }
        let d = BalloonGeometry.hideDelay(shownFor: CACurrentMediaTime() - balloonShownAt)
        guard d > 0 else { balloon.isHidden = true; return }
        balloonHidePending = true
        perform(#selector(hideBalloonDeferred), with: nil, afterDelay: d, inModes: [.common])
    }
    @objc private func hideBalloonDeferred() {
        guard balloonHidePending else { return }
        balloonHidePending = false
        hideBalloon()
    }
    private var balloonShownAt: CFTimeInterval = 0
    private var balloonHidePending = false
    #if DEBUG
    var debugBalloonHidePending: Bool { balloonHidePending }
    #endif

    private func textButton(_ s: String, hint: String? = nil) -> UIView {
        let b = baseButton(title: s, special: false)
        if keyPressHighlightEnabled { b.pressedBackground = specialFill }
        if Self.isPad { b.padRole = .digit }   // số/ký hiệu: cỡ chữ iPad, căn giữa như stock
        b.slideInsert = s
        if let hint {
            // Plane số iPad: ký tự phụ xám phía trên như stock, khối chữ theo tâm phím.
            addPadHint(hint, to: b)
            b.padRole = .letter
            armPadAlternate(b, alt: hint)
        }
        b.addAction(UIAction { [weak self, weak b] _ in
            Self.clickLetter(s)
            if let self, let b { self.showBalloon(over: b, text: s); self.fxMark(b) }
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in self?.hideBalloonAfterTap() },
                    for: [.touchUpInside, .touchUpOutside, .touchCancel])
        armCommit(b) { [weak self, weak b] in
            guard let self else { return }
            self.typedInSymbolPlane = true
            // Plane lúc CHẠM: dấu kết vế có thể đưa về chữ (tapSymbol) — không nhả shift vừa đánh giá lại.
            let onLetters = self.plane == .letters
            self.tapSymbol(b?.takePadAlt() == true ? (hint ?? s) : s)
            // Phím số/ký hiệu NGAY TRÊN plane chữ (hàng số, iPad "-" "="): như phím chữ —
            // nhả Shift một-lần (đầu câu hay ⇧ tay), Caps Lock giữ (issue #143: "1" đầu câu
            // rồi chữ kế vẫn hoa). Controller không đánh giá lại viết hoa sau .text.
            if onLetters { self.releaseOneShotShift() }
        }
        // Giữ ra hàng biến thể như stock (KeyVariants) — chỉ bàn số/ký hiệu, phím KHÔNG có
        // nhãn phụ iPad (nhãn phụ đã dùng cử chỉ giữ). Chạm thường vẫn chèn ký tự gốc.
        if hint == nil {
            let v = KeyVariants.variants(for: s, symbolPlane: plane == .numbers || plane == .symbols,
                                         numericField: inputKind == .number)
            if !v.isEmpty { armDomainHold(b, choices: v, variants: true) }
        }
        return b
    }

    /// Nhãn ký tự phụ iPad (xám, trên tâm phím) — cỡ/baseline do KeyButton.padRole áp.
    private func addPadHint(_ text: String, to b: KeyButton) {
        let l = UILabel()
        l.text = text
        l.textColor = inkFaded(Double(KeyGeometry.Typography.Pad.hintAlpha(dark: dark)))
        l.isUserInteractionEnabled = false
        l.isAccessibilityElement = false
        b.addOverlay(l, .centerBaseline(belowCenter: 0))
        b.padHint = l
    }

    /// Phím (UIButton thường, không qua router chữ) có ký tự phụ iPad: VUỐT XUỐNG quá
    /// flickDistance hoặc GIỮ holdDelay mà không trôi → chọn ký tự phụ (balloon hiện nó);
    /// phím chốt lúc nhấc như cũ, action đọc `padAltChosen`.
    private func armPadAlternate(_ b: KeyButton, alt: String) {
        b.padAlt = alt
        b.onPadAltChoose = { [weak self, weak b] in
            guard let self, let b else { return }
            self.choosePadAlt(b)
        }
        // Chạm xuống: bắt đầu sạch + hẹn giờ GIỮ (vuốt xuống do KeyButton.continueTracking).
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self, let b else { return }
            b.padAltChosen = false
            b.padAltTimer?.cancel()
            let w = DispatchWorkItem { [weak self, weak b] in
                guard let self, let b, b.isTracking else { return }
                self.choosePadAlt(b)
            }
            b.padAltTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + KeyAlternates.holdDelay, execute: w)
        }, for: .touchDown)
        // Nhấc/huỷ: tắt hẹn giờ + ẨN balloon ký tự phụ (trước đây balloon kẹt lại trên
        // phím "?." / "!," sau khi giữ — Phil 27/09).
        b.addAction(UIAction { [weak self, weak b] _ in
            b?.padAltTimer?.cancel(); b?.padAltTimer = nil
            self?.hideBalloon()   // vô điều kiện: takePadAlt() (action chốt) có thể đã reset padAltChosen trước
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    private func choosePadAlt(_ b: KeyButton) {
        guard !b.padAltChosen, let alt = b.padAlt else { return }
        b.padAltChosen = true
        b.padAltTimer?.cancel(); b.padAltTimer = nil
        showBalloon(over: b, text: alt)
    }

    /// Phím ra KÝ TỰ lúc nhấc (space, dấu câu, số/ký hiệu, return): arm lúc chạm,
    /// chốt lúc nhấc — hoặc lúc touch bị hệ thống huỷ (không nuốt phím ở hàng sát
    /// home indicator), hoặc sớm hơn khi ngón khác chạm xuống (baseButton flush).
    private func armCommit(_ b: UIControl, fire: @escaping () -> Void) {
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self, let b else { return }
            self.commits.arm(ObjectIdentifier(b), fire: fire)
        }, for: .touchDown)
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self, let b else { return }
            self.commits.release(ObjectIdentifier(b))
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    /// `fire`: lúc nào chạy action (mặc định nhấc tay). `.down` cho phím đổi plane
    /// (123/ABC/#+=) như stock — không còn phụ thuộc touch-up (bị hệ thống huỷ sát vùng
    /// 🌐/mic, hoặc ngón trượt) — nguồn "chuyển lại không ăn, phải ấn lần nữa".
    private func controlButton(title: String, armed: Bool = false, fire: ControlFire = .up, isReturn: Bool = false,
                               action: @escaping () -> Void) -> KeyButton {
        let b = baseButton(title: title, special: true)
        b.addAction(UIAction { _ in if isReturn { Self.clickReturn() } else { Self.clickModifier() } }, for: .touchDown)
        if armed { armCommit(b, fire: action) }
        else if case .down = fire {
            // Phím đổi plane (123/ABC/#+=) đổi ở touchDown ⇒ phím vừa chạm bị gỡ ngay; phím
            // plane mới nằm đúng chỗ ngón tay sẫm thay (như stock) tới khi nhấc.
            b.addAction(UIAction { [weak self] a in
                guard let self, let v = a.sender as? KeyButton else { action(); return }
                let slot = self.controlSlot(of: v)
                action()
                self.carryPress(from: v, slot: slot)
            }, for: .touchDown)
            b.addAction(UIAction { [weak self] _ in self?.releaseCarriedPress() },
                        for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        else { b.addAction(UIAction { _ in action() }, for: fire.events) }
        return b
    }
    /// Phím mới (sau đổi plane) đang sẫm thay cho phím cũ còn giữ touch.
    private weak var carriedPress: KeyButton?
    /// (hàng tính TỪ ĐÁY — hàng số làm plane chữ nhiều hàng hơn, thứ tự nút thật trong hàng) — plane mới đặt phím đổi plane cùng chỗ (123 ↔ ABC,
    /// #+= ↔ 123). Theo cấu trúc, không theo frame: plane mới chưa layout lúc touchDown.
    private func controlSlot(of c: UIControl) -> (row: Int, index: Int)? {
        let rows = rowsContainer.arrangedSubviews
        for (r, row) in rows.enumerated() {
            if let i = rowControls(row).firstIndex(where: { $0 === c }) { return (rows.count - 1 - r, i) }
        }
        return nil
    }
    private func carryPress(from old: KeyButton, slot: (row: Int, index: Int)?) {
        releaseCarriedPress()
        // rowsContainer (không phải self): lúc trượt từ 123 hàng cũ còn đậu ẩn trong self.
        guard let slot, !old.isDescendant(of: rowsContainer) else { return }
        old.showPressed(false)   // nằm cache plane cũ — đừng để sẫm treo lúc quay lại
        let rows = rowsContainer.arrangedSubviews
        guard slot.row < rows.count else { return }
        let cs = rowControls(rows[rows.count - 1 - slot.row])
        guard slot.index < cs.count, let nb = cs[slot.index] as? KeyButton,
              nb.isSpecial, nb.pressedBackground != nil else { return }
        nb.press()
        carriedPress = nb
        watchCarriedTouch(old.lastBeganTouch)
    }
    private func releaseCarriedPress() {
        carriedWatch?.invalidate(); carriedWatch = nil
        carriedPress?.release()
        carriedPress = nil
    }
    /// Phím cũ đã bị gỡ khỏi màn hình ngay lúc chạm xuống ⇒ có thể KHÔNG nhận được nhấc / huỷ
    /// (bug 1.2.31: bấm 123 xong phím ABC cùng chỗ sẫm mãi tới khi mở lại bàn phím). Theo dõi
    /// chính chạm đó: kết thúc / huỷ / không còn chạm ⇒ thôi sẫm. Trần 10 giây.
    private var carriedWatch: Timer?
    private func watchCarriedTouch(_ touch: UITouch?) {
        carriedWatch?.invalidate()
        let start = CACurrentMediaTime()
        carriedWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak touch] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Self.carriedTouchEnded(phase: touch?.phase, elapsed: CACurrentMediaTime() - start) {
                    self.releaseCarriedPress()
                }
            }
        }
    }
    // MARK: trượt từ phím 123 (#171) — PlaneSlide

    /// Phím 123 vừa chạm từ plane chữ (đặt trong action đổi plane, đọc ngay sau đó).
    private var planeSlideArmed = false
    private var planeSlide: PlaneSlide<KeyButton>?
    private weak var planeSlideTouch: UITouch?
    /// Nút 123 cũ đã bị gỡ ⇒ có thể không nhận moved / ended (xem carryPress): đọc thẳng chạm
    /// mỗi 50ms làm dự phòng. Chỉ chạy trong lúc trượt.
    private var planeSlideWatch: Timer?

    /// `touch` nil (VoiceOver / sendActions) hoặc đã kết thúc ⇒ không trượt: chạm 123 như cũ.
    private func beginPlaneSlide(touch: UITouch?) {
        guard let touch, touch.phase != .ended, touch.phase != .cancelled,
              !UIAccessibility.isVoiceOverRunning else { return }
        startPlaneSlide(touch: touch)
        let start = CACurrentMediaTime()
        planeSlideWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak touch] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let touch, CACurrentMediaTime() - start < 10 else {
                    self.endPlaneSlide(at: nil, cancelled: true)
                    return
                }
                self.planeSlideEvent(touch, touch.phase == .ended || touch.phase == .cancelled ? touch.phase : .moved)
            }
        }
    }

    /// Ngón thứ hai chạm một phím lúc đang trượt: bỏ trượt, không chèn (phím mới gõ như thường).
    private func planeSlideSecondTouch() { endPlaneSlide(at: nil, cancelled: true) }

    /// Chỗ đậu ẩn của hàng phím plane chữ trong lúc trượt từ 123: nút 123 còn trong cửa sổ nên
    /// chạm của nó sống tới khi nhấc. Ẩn ⇒ không vẽ, không nhận chạm mới. Chỉ gắn vào khi trượt.
    private let planeSlidePark: UIView = { let v = UIView(); v.isHidden = true; return v }()
    private func parkRowsForPlaneSlide(_ rows: [UIView]) {
        if planeSlidePark.superview == nil { insertSubview(planeSlidePark, at: 0) }
        planeSlidePark.frame = rowsContainer.frame
        rows.forEach { planeSlidePark.addSubview($0) }
    }
    /// Trượt xong / không trượt: hàng còn đậu (chưa được plane chữ lấy lại từ cache) rời cửa sổ như thường.
    private func unparkPlaneSlideRows() {
        guard planeSlidePark.superview != nil else { return }
        planeSlidePark.subviews.forEach { $0.removeFromSuperview() }
        planeSlidePark.removeFromSuperview()
    }

    private func startPlaneSlide(touch: UITouch?) {
        planeSlide = PlaneSlide()
        planeSlideTouch = touch
    }

    /// Sự kiện của chạm 123 (từ nút cũ, hoặc đồng hồ dự phòng).
    private func planeSlideEvent(_ t: UITouch, _ phase: UITouch.Phase) {
        guard planeSlide != nil, t === planeSlideTouch else { return }
        let p = t.location(in: self)
        switch phase {
        case .ended: endPlaneSlide(at: p, cancelled: false)
        case .cancelled: endPlaneSlide(at: p, cancelled: true)
        default: planeSlideMove(to: p)
        }
    }

    /// Phím ký tự (chèn được) của plane hiện tại dưới điểm `p` (toạ độ self).
    private func slideInsertKey(at p: CGPoint) -> KeyButton? {
        layoutIfNeeded()                         // plane số vừa dựng lúc chạm, có thể chưa layout
        for row in rowsContainer.arrangedSubviews {
            for c in rowControls(row) {
                guard let b = c as? KeyButton, b.slideInsert != nil, !b.isHidden,
                      convert(b.bounds, from: b).contains(p) else { continue }
                return b
            }
        }
        return nil
    }

    private func planeSlideMove(to p: CGPoint) {
        guard var s = planeSlide else { return }
        let change = s.move(over: slideInsertKey(at: p))
        planeSlide = s
        guard let change else { return }
        if let old = change.leave { old.release(); hideBalloon() }
        if let k = change.enter {
            releaseCarriedPress()                // ABC (chỗ 123 cũ) thôi sẫm: ngón đã rời
            k.press()
            showBalloon(over: k, text: k.slideInsert ?? "")
        }
    }

    /// Kết thúc trượt. `p` nil = không có điểm nhấc (ngón thứ hai, chạm mất) ⇒ không chèn.
    private func endPlaneSlide(at p: CGPoint?, cancelled: Bool) {
        guard let s = planeSlide else { return }
        planeSlide = nil
        planeSlideTouch = nil
        planeSlideWatch?.invalidate(); planeSlideWatch = nil
        if let o = s.over { o.release(); hideBalloon() }
        let k = cancelled ? nil : p.flatMap(slideInsertKey(at:))
        guard let target = PlaneSlide.lift(over: k, cancelled: cancelled) else { unparkPlaneSlideRows(); return }
        releaseCarriedPress()
        // Đúng đường chạm thường của phím đó: âm/rung, balloon, KeyCommitQueue, tapSymbol
        // (ranh giới từ, tự cách, VNI, về chữ theo PlanePolicy).
        target.sendActions(for: .touchDown)
        target.sendActions(for: .touchUpInside)
        if plane != .letters {                   // như chạm ABC
            plane = .letters
            reevaluateShiftForLetters()
            rebuild()
        }
        unparkPlaneSlideRows()                   // hàng plane chữ đã về lưới (cache) — dọn chỗ đậu
    }

    /// Thuần (test được): sẫm thay của phím đổi plane hết khi chạm không còn / đã nhấc / huỷ, hoặc quá 10s.
    static func carriedTouchEnded(phase: UITouch.Phase?, elapsed: CFTimeInterval) -> Bool {
        guard let phase, elapsed < 10 else { return true }
        return phase == .ended || phase == .cancelled
    }
    enum ControlFire {
        case up, upOrCancel, down
        var events: UIControl.Event {
            switch self {
            case .up: return [.touchUpInside, .touchUpOutside]
            case .upOrCancel: return [.touchUpInside, .touchUpOutside, .touchCancel]
            case .down: return .touchDown
            }
        }
    }

    private func shiftButton() -> UIView {
        let symbol = shift == .caps ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
        let b = baseButton(title: "", special: true)
        applySkin(b, role: "shift")
        b.setImage(UIImage(systemName: symbol), for: .normal)
        if Self.isPad { b.padRole = .icon }
        b.accessibilityLabel = "Shift"
        if shift != .off, b.skin != nil {
            // Skin (tải về / điểm ảnh): bật = ảnh đè, glyph màu chức năng — như applyShiftAppearance (trước: glyph
            // shiftOnInk đen trên skin khi plane dựng lúc ⇧ đang bật).
            b.tintColor = fnInk
            b.setSkinLatched(true)
        } else if shift != .off {
            b.backgroundColor = shiftOnFill
            b.tintColor = shiftOnInk
        } else {
            b.tintColor = fnInk
        }
        b.normalBackground = b.backgroundColor
        shiftKeys.append(b)
        // Toggle ở TOUCH-DOWN: roll shift+chữ nhanh phải ra chữ hoa —
        // touch-up thì chữ đã kịp chốt trước khi shift bật.
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Chạm / chạm đôi (Caps) / giữ làm phím bổ trợ — ShiftHold (THUẦN).
            self.shiftDown(now: CACurrentMediaTime())
            // Sau khi đổi trạng thái: Piano cần biết Shift một-lần hay Caps (pedal); kiểu khác = tiếng chức năng.
            Self.clickShift(self.shift == .caps ? .caps : (self.shift == .on ? .on : .off))
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in
            self?.shiftUp()   // đã giữ ⇧ gõ ký tự phụ ⇒ không để lại viết hoa một lần
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        b.minWidth = 42
        return b
    }

    private func backspaceButton() -> UIView {
        let b = baseButton(title: "", special: true)
        applySkin(b, role: "delete")
        b.setImage(UIImage(systemName: "delete.left"), for: .normal)
        if Self.isPad { b.padRole = .icon }   // icon cỡ stock iPad (Typography.Pad)
        b.setImage(UIImage(systemName: "delete.left.fill"), for: .highlighted)
        b.tintColor = fnInk
        b.accessibilityLabel = L("Xoá")
        // touchDown xoá 1 ký tự như cũ; kéo ngang → vuốt xoá theo từ (xem MARK dưới).
        b.addTarget(self, action: #selector(backspaceDown(_:event:)), for: .touchDown)
        b.addTarget(self, action: #selector(backspaceDrag(_:event:)),
                    for: [.touchDragInside, .touchDragOutside])
        b.addTarget(self, action: #selector(backspaceUp(_:event:)),
                    for: [.touchUpInside, .touchUpOutside, .touchCancel])
        // press & hold repeats (starts after 0.5s, ~11 Hz — Apple cadence)
        let long = UILongPressGestureRecognizer(target: self, action: #selector(backspaceHold(_:)))
        long.minimumPressDuration = 0.5
        long.delaysTouchesBegan = false
        long.delaysTouchesEnded = false
        long.cancelsTouchesInView = false
        b.addGestureRecognizer(long)
        b.minWidth = 42
        return b
    }

    @objc private func backspaceHold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard !wordSwipe.active else { return }   // đang vuốt → không giữ-lặp
            backspaceHoldStart = CACurrentMediaTime()
            wordDeleteTick = 0
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                guard let self else { return }
                // Apple accelerates a sustained hold: ~1.6s cadence doubles,
                // ~3s chuyển sang xoá theo từ (~2.8 từ/s).
                let held = CACurrentMediaTime() - self.backspaceHoldStart
                if held > 3.0, self.plane != .emojiSearch, let deleteWord = self.onDeleteWord {
                    self.wordDeleteTick += 1
                    if self.wordDeleteTick % 4 == 1 { deleteWord(); self.buddy?.deletePressed() }
                    return
                }
                self.tapped(.backspace)
                if held > 1.6 { self.tapped(.backspace) }
            }
        case .ended, .cancelled, .failed:
            repeatTimer?.invalidate()
            repeatTimer = nil
        default: break
        }
    }

    // MARK: vuốt trái trên ⌫ = xoá theo từ (kiểu Gboard)
    // Extension không tạo được vùng chọn trong app host → xem trước bằng nhãn nổi
    // trên phím ⌫ ("⌫ 2 từ"), NHẤC TAY mới xoá; kéo về dưới ngưỡng rồi nhấc = huỷ.
    // Chỉ kích hoạt khi chưa giữ-lặp và kéo ngang ≥ WordDelete.swipeActivation.

    /// Chạm ⌫ xuống — controller chụp context TRƯỚC lần xoá của chạm này.
    var onBackspaceTouchDown: (() -> Void)?
    /// Số từ tối đa xoá được (controller đếm trên context đã chụp). 0 = không vuốt.
    var wordSwipeLimit: (() -> Int)?
    /// Nhấc tay sau khi vuốt: số từ đã chọn (0 = huỷ).
    var onWordSwipeEnd: ((Int) -> Void)?

    private struct WordSwipeState {
        var startX: CGFloat = 0
        var tracking = false
        var active = false
        var maxWords = 0
        var words = 0
    }
    private var wordSwipe = WordSwipeState()
    private weak var wordSwipeKey: UIView?
    private var wordSwipePill: UILabel?

    @objc private func backspaceDown(_ sender: UIControl, event: UIEvent?) {
        Self.clickDelete()
        // Ô tìm emoji: ⌫ chỉ xoá trong ô tìm — không chụp context / vuốt xoá từ ô nhập.
        if plane == .emojiSearch { tapped(.backspace); return }
        onBackspaceTouchDown?()
        let x = event?.allTouches?.first(where: { $0.view === sender })?.location(in: self).x
        wordSwipeKey = sender
        backspaceSwipeBegan(x: x ?? 0)
        tapped(.backspace)
    }

    @objc private func backspaceDrag(_ sender: UIControl, event: UIEvent?) {
        guard let x = event?.allTouches?.first(where: { $0.view === sender })?.location(in: self).x
        else { return }
        backspaceSwipeMoved(x: x)
    }

    @objc private func backspaceUp(_ sender: UIControl, event: UIEvent?) {
        backspaceSwipeEnded()
    }

    private func backspaceSwipeBegan(x: CGFloat) {
        wordSwipe = WordSwipeState(startX: x, tracking: true)
    }

    private func backspaceSwipeMoved(x: CGFloat) {
        guard wordSwipe.tracking else { return }
        let dragLeft = wordSwipe.startX - x
        if !wordSwipe.active {
            // giữ-lặp đã chạy = đã xoá nhiều ký tự → không chuyển sang vuốt nữa
            guard dragLeft >= WordDelete.swipeActivation, repeatTimer == nil else { return }
            let limit = wordSwipeLimit?() ?? 0
            guard limit > 0 else { wordSwipe.tracking = false; return }
            wordSwipe.active = true
            wordSwipe.maxWords = limit
        }
        let step = WordDelete.swipeStep(letterKeyWidth: letterKeys.first?.button.bounds.width)
        let n = WordDelete.words(dragLeft: dragLeft, step: step, max: wordSwipe.maxWords)
        if n != wordSwipe.words {
            wordSwipe.words = n
            Self.clickWordStep()
        }
        showWordSwipePill(words: n)
    }

    private func backspaceSwipeEnded() {
        let s = wordSwipe
        wordSwipe = WordSwipeState()
        hideWordSwipePill()
        guard s.active else { return }
        onWordSwipeEnd?(s.words)
    }

    private func showWordSwipePill(words n: Int) {
        let pill: UILabel
        if let p = wordSwipePill { pill = p } else {
            pill = UILabel()
            pill.font = .systemFont(ofSize: 15, weight: .semibold)
            pill.textAlignment = .center
            pill.layer.cornerRadius = 8
            pill.layer.masksToBounds = true
            pill.isUserInteractionEnabled = false
            wordSwipePill = pill
        }
        pill.text = n > 0 ? L("\u{232B} %@ từ", n) : L("Huỷ")
        pill.textColor = popup.ink
        pill.backgroundColor = popup.fill
        if pill.superview == nil { addSubview(pill) }
        bringSubviewToFront(pill)
        let key = wordSwipeKey.map { convert($0.bounds, from: $0) }
            ?? CGRect(x: bounds.width - 50, y: layoutHeight - 100, width: 44, height: 42)
        let size = pill.intrinsicContentSize
        let w = size.width + 20, h: CGFloat = 32
        pill.frame = CGRect(x: max(4, min(key.maxX - w, bounds.width - w - 4)),
                            y: max(0, key.minY - h - 6), width: w, height: h)
        pill.isHidden = false
    }

    private func hideWordSwipePill() {
        wordSwipePill?.isHidden = true
    }

    @objc private func spaceTouchDown(_ sender: UIControl, event: UIEvent) {
        if spaceFlickEnabled, plane != .emojiSearch,
           let touch = event.allTouches?.first(where: { $0.view === sender }) {
            flickStart = (touch.location(in: self), CACurrentMediaTime())
            flickLast = flickStart?.p
            flickHoldGone = false
        } else {
            flickStart = nil
        }
        guard TouchLog.enabled else { return }       // Debug mode tắt ⇒ 0 việc mỗi lần space
        TouchLog.buttonDown("space", touchTimestamp: event.allTouches?.first(where: { $0.view === sender })?.timestamp)
    }

    /// Space-hold = trackpad mode: kéo ngang dời con trỏ 6pt/ký tự, kéo dọc ~24pt/dòng; kéo
    /// nhanh thì quãng kéo nhân hệ số (tăng tốc). Trục + tăng tốc: TrackpadGesture (thuần).
    @objc private func spaceHold(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        let t = CACurrentMediaTime()
        switch g.state {
        case .began:
            // Trackpad = không gõ: nhả ra KHÔNG có dấu cách (stock), kể cả khi
            // chưa di con trỏ. cancelsTouchesInView=false nên touchUpInside vẫn tới.
            if let v = g.view { commits.disarm(ObjectIdentifier(v)) }
            if flickStart != nil { flickStart = nil; endFlickPreview(committed: false, animated: false) }
            trackpadBegan(p, t: t)
        case .changed:
            trackpadMoved(p, t: t)
        case .ended, .cancelled, .failed:
            trackpadEnded()
        default: break
        }
    }

    // Làm mượt (góp ý user 27/09/2026 "di con trỏ lag"): bước KHÔNG gửi ngay mỗi touch
    // event — gom vào TrackpadCoalescer, CADisplayLink xả ≤1 adjustTextPosition/frame.
    // Controller được báo bắt đầu/kết thúc để tạm ngưng auto-shift/gợi ý/đọc context
    // mỗi bước (chỉ tính 1 lần lúc nhả tay).
    /// true = bắt đầu trackpad, false = nhả tay (sau lệnh dời cuối).
    var onTrackpad: ((Bool) -> Void)?
    private var trackpadCoalescer = TrackpadCoalescer()
    private var trackpadLink: CADisplayLink?
    private(set) var trackpadActive = false

    private func trackpadBegan(_ p: CGPoint, t: CFTimeInterval) {
        if trackpadGesture.curve != trackpadSpeed.curve { trackpadGesture = TrackpadGesture(speed: trackpadSpeed) }
        trackpadGesture.begin(x: Double(p.x), y: Double(p.y), t: t)
        _ = trackpadCoalescer.drain()
        trackpadActive = true
        setTrackpadDimmed(true)            // phản hồi thị giác NGAY, không chờ host
        onTrackpad?(true)
    }

    private func trackpadMoved(_ p: CGPoint, t: CFTimeInterval) {
        guard trackpadActive,
              let step = trackpadGesture.move(x: Double(p.x), y: Double(p.y), t: t) else { return }
        trackpadCoalescer.add(step)
        if trackpadLink == nil, window != nil {
            let link = CADisplayLink(target: TrackpadLinkTarget(self), selector: #selector(TrackpadLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            trackpadLink = link
        }
        trackpadLink?.isPaused = false
    }

    /// Một frame: gửi phần đã gom (thường 1 lệnh); hết việc thì dừng link (không đốt pin).
    fileprivate func trackpadFrame() {
        let steps = trackpadCoalescer.drain()
        if steps.isEmpty { trackpadLink?.isPaused = true; return }
        for s in steps {
            tapped(s.axis == .horizontal ? .moveCursor(s.count) : .moveLine(s.count))
        }
    }

    /// Ngón thứ hai chạm lúc trackpad: rung nhẹ một lần mỗi lượt kéo (báo đã nhận, không gõ).
    private var trackpadExtraFingerSeen = false
    private func trackpadExtraFinger() {
        guard !trackpadExtraFingerSeen else { return }
        trackpadExtraFingerSeen = true
        Self.flickFeedback()
    }

    private func trackpadEnded() {
        guard trackpadActive else { return }
        trackpadExtraFingerSeen = false
        trackpadFrame()                    // bước cuối chưa xả
        trackpadLink?.invalidate(); trackpadLink = nil
        trackpadActive = false
        setTrackpadDimmed(false)
        onTrackpad?(false)
    }

    /// CADisplayLink giữ target mạnh → proxy weak để KeyboardView không bị giữ.
    private final class TrackpadLinkTarget: NSObject {
        weak var owner: KeyboardView?
        init(_ o: KeyboardView) { owner = o }
        @objc func tick() { owner?.trackpadFrame() }
    }

    /// Trackpad mode: mờ keycap + phẳng màu phím như stock — báo hiệu đang
    /// di caret chứ không gõ. Không nằm trên hot path (chỉ chạy khi hold 0.4s).
    private var trackpadDimmed = false
    private func setTrackpadDimmed(_ dim: Bool) {
        guard dim != trackpadDimmed else { return }
        trackpadDimmed = dim
        hideBalloon()
        func walk(_ v: UIView) {
            if let b = v as? KeyButton {
                for sub in b.subviews { sub.alpha = dim ? 0.2 : 1 }
                b.backgroundColor = dim ? plainFill : (b.normalBackground ?? b.backgroundColor)
            } else {
                v.subviews.forEach(walk)
            }
        }
        walk(rowsContainer)
    }

    // MARK: vuốt phím cách đổi Tiếng Việt ↔ Tiếng Anh (SpaceFlick, kiểu HeliBoard)
    // Kéo ngang: nhãn ngôn ngữ hiện tại trượt theo ngón + mờ dần, nhãn kia trượt vào từ
    // phía đối diện. Nhấc nhanh (trước ngưỡng trackpad 0,3 s) đủ ~1 phím ⇒ đổi: nhãn mới
    // vào giữa, sáng một nhịp rồi mờ đi, logo Vᴛ/E đổi theo. Không đủ ⇒ trượt về, mờ đi.
    var onSpaceFlick: (() -> Void)?
    /// Đang ở bảng chữ — vuốt mới chuyển luôn từ đang soạn (ONBOARDING-SPEC §7).
    var spaceFlickConvertsWord: Bool { plane == .letters }
    private(set) var spaceFlickEnabled = false
    var spaceLanguage: KeyboardLanguage = .vi {
        didSet { if oldValue != spaceLanguage { refreshSpaceMark() } }
    }
    private var flickStart: (p: CGPoint, t: CFTimeInterval)?
    private var flickLast: CGPoint?
    /// Ngón đã trượt quá allowableMovement của recognizer giữ (spacePan) trước khi giữ đủ
    /// 0,3 s ⇒ recognizer fail, trackpad không thể bật trong lần chạm này ⇒ kéo chậm vẫn đổi
    /// ngôn ngữ (#147).
    private var flickHoldGone = false
    private var flickCarousel: (box: UIView, cur: UILabel, next: UILabel)?

    func configureSpaceFlick(enabled: Bool, language: KeyboardLanguage) {
        if snapState == .showing, enabled != spaceFlickEnabled || language != spaceLanguage { goLive() }
        let changed = spaceFlickEnabled != enabled
        spaceFlickEnabled = enabled
        if !enabled { flickStart = nil; endFlickPreview(committed: false, animated: false) }
        spaceLanguage = language
        if changed {
            // logo ↔ mã VI/EN: thay tại chỗ trên plane đang hiện; plane cache dựng lại khi mở.
            planeCache.removeAll()
            if let space = spaceBar { installSpaceMark(on: space) }
        }
        refreshSpaceMark()
    }

    /// Logo Vᴛ hoặc mã VI/EN trên phím cách (SpaceMark). Gọi lúc dựng plane, và tại chỗ khi
    /// công tắc vuốt đổi ngôn ngữ đổi (configureSpaceFlick — không dựng lại cả plane).
    private func installSpaceMark(on space: KeyButton) {
        // logo Vᴛ mờ ở mép phải nút space (thay "VI EN" — user 2026-07-23);
        // PNG 2x/3x render từ MenuIcon.pdf nên sắc nét, tint theo appearance.
        // Ẩn được qua Settings của app (showSpaceLogo, App Group).
        // Bật vuốt đổi ngôn ngữ ⇒ mã "VI"/"EN" nhỏ góc dưới-phải như stock (SpaceMark).
        let showLogo = AppFlavor.spaceBarLogo && (UserDefaultsProvider.shared?.object(forKey: "showSpaceLogo") == nil
            || UserDefaultsProvider.shared?.bool(forKey: "showSpaceLogo") == true)
        if spaceLogo?.superview === space { spaceLogo?.removeFromSuperview() }
        if spaceCode?.superview === space { spaceCode?.removeFromSuperview() }
        spaceLogo = nil; spaceCode = nil
        switch SpaceMark.choose(flickEnabled: spaceFlickEnabled, showLogo: showLogo, language: spaceLanguage) {
        case .none: break
        case .code(let code):
            let l = UILabel()
            l.text = code
            l.font = .systemFont(ofSize: Self.isPad ? 13 : 11, weight: .medium)
            l.textColor = spaceInk.alpha(0.45).ui     // mờ như stock; theo độ trong suốt ký tự
            l.isUserInteractionEnabled = false
            l.isAccessibilityElement = false
            spaceCode = l
            space.addOverlay(l, .bottomRight(right: Self.isPad ? 10 : 7, bottom: Self.isPad ? 6 : 4))
        case .logo:
            let hint = UIImageView(image: spaceLogoImage())
            hint.tintColor = spaceInk.alpha(0.16).ui
            hint.contentMode = .scaleAspectFit
            spaceLogo = hint
            space.addOverlay(hint, .rightCenterY(right: 10, size: CGSize(width: 22, height: 22)))
        }
    }

    private func refreshSpaceMark() {
        spaceLogo?.image = spaceLogoImage()
        spaceCode?.text = spaceLanguage.shortCode
    }

    private func spaceLogoImage() -> UIImage? {
        UIImage(named: spaceLanguage == .en ? "SpaceLogoEN" : "SpaceLogo")?.withRenderingMode(.alwaysTemplate)
    }

    private var flickKeyWidth: CGFloat { bounds.width / 10 }

    @objc private func spaceDrag(_ sender: UIControl, event: UIEvent) {
        guard let start = flickStart,
              let touch = event.allTouches?.first(where: { $0.view === sender }) else { return }
        let p = touch.location(in: self)
        flickLast = p
        guard touch.phase == .moved, let space = spaceBar else { return }
        let dx = p.x - start.p.x, dy = p.y - start.p.y
        let elapsed = CACurrentMediaTime() - start.t
        if !flickHoldGone, !trackpadActive,
           let hold = sender.gestureRecognizers?.lazy.compactMap({ $0 as? UILongPressGestureRecognizer }).first,
           hold.state == .failed
            || (elapsed < hold.minimumPressDuration && hypot(dx, dy) > hold.allowableMovement) {
            flickHoldGone = true
        }
        let q = SpaceFlick.progress(dx: dx, dy: dy, elapsed: elapsed,
                                    span: SpaceFlick.previewSpan(keyWidth: flickKeyWidth),
                                    trackpadPossible: !flickHoldGone)
        if q == 0 {
            if flickCarousel != nil { endFlickPreview(committed: false, animated: true) }
            return
        }
        let c = flickCarousel ?? makeFlickCarousel(in: space)
        layoutFlickCarousel(c, q: q)
    }

    /// Lúc space chốt (nhấc tay): true = flick đổi ngôn ngữ (đã xử lý, không chèn dấu cách).
    private func consumeSpaceFlick() -> Bool {
        guard let start = flickStart else { return false }
        flickStart = nil
        let p = flickLast ?? start.p
        let dir = SpaceFlick.classify(dx: p.x - start.p.x, dy: p.y - start.p.y,
                                      duration: CACurrentMediaTime() - start.t, keyWidth: flickKeyWidth,
                                      trackpadPossible: !flickHoldGone)
        guard let dir, spaceFlickEnabled else {
            if flickCarousel != nil { endFlickPreview(committed: false, animated: true) }
            return false
        }
        Self.flickFeedback()
        if flickCarousel == nil, let space = spaceBar {
            layoutFlickCarousel(makeFlickCarousel(in: space), q: dir == .left ? -0.2 : 0.2)
        }
        onSpaceFlick?()
        endFlickPreview(committed: true, animated: true, direction: dir)
        return true
    }

    private func makeFlickCarousel(in space: UIView) -> (box: UIView, cur: UILabel, next: UILabel) {
        let box = UIView(frame: space.bounds)
        box.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.clipsToBounds = true
        box.isUserInteractionEnabled = false
        func label(_ l: KeyboardLanguage) -> UILabel {
            let v = UILabel()
            v.text = l.displayName
            v.font = .systemFont(ofSize: 16, weight: .regular)
            v.textColor = spaceInk.ui
            v.sizeToFit()
            box.addSubview(v)
            return v
        }
        let c = (box, label(spaceLanguage), label(spaceLanguage.toggled))
        space.addSubview(box)
        spaceMarkView?.alpha = 0
        flickCarousel = c
        return c
    }

    /// q ∈ [-1, 1]: nhãn hiện tại lệch q·W/2 theo ngón, nhãn kia theo sau một nửa bề ngang.
    private func layoutFlickCarousel(_ c: (box: UIView, cur: UILabel, next: UILabel), q: CGFloat) {
        let w = c.box.bounds.width, mid = CGPoint(x: w / 2, y: c.box.bounds.height / 2)
        let off = q * w / 2
        c.cur.center = CGPoint(x: mid.x + off, y: mid.y)
        c.next.center = CGPoint(x: mid.x + off - (q < 0 ? -1 : 1) * w / 2, y: mid.y)
        c.cur.alpha = 0.6 * (1 - abs(q))
        c.next.alpha = 0.6 * abs(q)
    }

    private func endFlickPreview(committed: Bool, animated: Bool,
                                 direction: SpaceFlick.Direction = .right) {
        guard let c = flickCarousel else { return }
        flickCarousel = nil
        let restoreLogo = { [weak self] in
            c.box.removeFromSuperview()
            guard let self, self.flickCarousel == nil else { return }
            UIView.animate(withDuration: 0.2) { self.spaceMarkView?.alpha = 1 }
        }
        guard animated else { restoreLogo(); return }
        if committed {
            // nhãn mới vào giữa, sáng một nhịp (~0,5 s) rồi mờ — như HeliBoard
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.layoutFlickCarousel(c, q: direction == .left ? -1 : 1)
                c.next.alpha = 1
            } completion: { _ in
                UIView.animate(withDuration: 0.3, delay: 0.5, options: [.curveEaseOut]) {
                    c.next.alpha = 0
                } completion: { _ in restoreLogo() }
            }
        } else {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.layoutFlickCarousel(c, q: 0.0001)
                c.cur.alpha = 0; c.next.alpha = 0
            } completion: { _ in restoreLogo() }
        }
    }

    /// Stock iOS flashes the layout name ("English (US)") on the spacebar when
    /// the keyboard appears. Same here: "ViệtTelex" for ~700ms, then fade.
    func showLanguageBadge() {
        // Ảnh lưới phím (chưa có phím thật): nhãn hiện khi phím thật dựng (goLive).
        if snapState == .armed || snapState == .showing { snapBadgePending = true; return }
        guard let space = spaceBar else { return }
        let l = UILabel()
        l.text = spaceLanguage == .en ? KeyboardLanguage.en.displayName : "ViệtTelex"
        l.font = .systemFont(ofSize: 16, weight: .regular)
        l.textColor = spaceInk.ui
        spaceMarkView?.isHidden = true     // logo Vᴛ nhường chỗ, khỏi đè lên badge
        space.addOverlay(l, .center)
        UIView.animate(withDuration: 0.3, delay: 0.7, options: [.curveEaseOut]) {
            l.alpha = 0
        } completion: { [weak self] _ in
            l.removeFromSuperview()
            self?.spaceMarkView?.isHidden = false
        }
    }

    // MARK: touch router cho phím chữ (ForwardingView-style)
    // UIButton event system có các mode fail đã biết (touch bị hệ thống cancel,
    // hit-test theo z-order thay vì khoảng cách, tracking per-control không
    // rollover được). Phím chữ tắt interaction; touch nổi lên đây và được gán
    // cho phím GẦN NHẤT — mọi điểm chạm trong vùng chữ đều trúng một phím.
    private var routedTouches: [ObjectIdentifier: KeyButton] = [:]

    // Vùng phím chữ (kể cả khe giữa phím) hit-test về CHÍNH KeyboardView —
    // một mặt touch duy nhất, isMultipleTouchEnabled=true của self có hiệu lực
    // thật. Trước đây hit view là row UIStackView (multipleTouch=false mặc
    // định) rồi forward lên qua responder chain: ngón thứ hai chạm xuống khi
    // ngón trước chưa nhấc bị nuốt ngay ở row stack → gõ nhanh rớt chữ.
    // Button thật (space, shift, backspace, số/ký hiệu, slot bar…) vẫn nhận
    // touch trực tiếp như cũ.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Chạm khi khung đầu còn là ảnh lưới phím: dựng phím thật NGAY rồi hit-test như thường
        // (chạm không mất — KeyboardStartupTests.testSnapshotTouchBeforeLiveKeysIsNotLost).
        if snapState == .showing { goLive() }
        if event?.type == .touches { snapInteracted = true }
        let v = routedHitTest(point, with: event, time: event?.timestamp)
        if TouchLog.enabled, let e = event, e.type == .touches {
            let target: String
            if v === self { target = "router" }
            else if let b = v as? KeyButton {
                target = "button[\(b.accessibilityLabel ?? b.currentTitle ?? "?")]"
            } else if let b = v as? UIButton {
                target = "button[\(b.accessibilityLabel ?? b.currentTitle ?? "?")]"
            } else { target = v.map { String(describing: type(of: $0)) } ?? "nil" }
            TouchLog.hitTest(target: target, y: Double(point.y), stamp: e.timestamp)
        }
        return v
    }

    private func routedHitTest(_ point: CGPoint, with event: UIEvent?, time: TimeInterval?) -> UIView? {
        // Trackpad đang chạy: mọi ngón MỚI (phím chữ lẫn nút thật) về router để nuốt — xem routeDown.
        if trackpadActive, bounds.contains(point) { return self }
        // Chỉ ô chừa trong strip được vuốt ve; phần hình tràn xuống vẫn thuộc phím.
        if let buddy = buddyFigureView, !buddy.isHidden, !suggestionBar.isHidden, bounds.contains(point) {
            let strip = max(rowsTopWanted, openStripNow)
            let zone = Self.buddyZoneFrame(width: bounds.width, strip: strip, placement: buddyPlacement,
                                           dismiss: dismissInset)
            if BuddyTap.tickles(x: Double(point.x), y: Double(point.y),
                                zone: BuddyRect(x: Double(zone.minX), y: Double(zone.minY), w: Double(zone.width), h: Double(zone.height)),
                                stripHeight: Double(strip), figure: BuddyRect(x: Double(buddy.frame.minX), y: Double(buddy.frame.minY), w: Double(buddy.frame.width), h: Double(buddy.frame.height))) { return buddyTickleZone }
        }
        let v = super.hitTest(point, with: event)
        if let p = overlayPanel, !p.isHidden, p.frame.contains(point) { return v }
        // Phím chữ ưu tiên trong FOOTPRINT thật của nó, kể cả khi hit-area nở của
        // shift/backspace kề bên "cướp" điểm chạm — nếu không, chạm mép z/m thành
        // toggle shift / xoá thay vì ra chữ (nguồn rớt phím ở hàng 3, 2026-07-26).
        if lettersLike, letterCoreContains(point) { return self }
        if let c = v as? UIControl {
            // Mép chung (KeyHitBias): space thắng ","/"." kề. Phím chữ KHÔNG BAO GIỜ lấn
            // ⇧ / ⌫ (bug 1.2.6/1.2.7 "bấm ⌫ thành m / l" — SpecialKeyGutter).
            if let r = biasedHit(c, at: point, time: time) { return r }
            return v
        }
        // Khe cùng hàng cạnh phím chức năng (m↔⌫, z↔⇧, mép màn hình) ⇒ phím chức năng,
        // trừ 3pt sát mép phím chữ (SpecialKeyGutter) — trước đây router chữ ăn trọn nửa khe.
        if v != nil, lettersLike, let s = gutterSpecial(at: point) { return biasedHit(s, at: point, time: time) ?? s }
        // Khe / mép trong vùng phím: nút thật GẦN NHẤT (123, emoji, ⇧, ⌫, số…) hoặc phím chữ
        // gần hơn (router). Trước đây khe trên mỗi hàng nút (4.5pt: nút chỉ nở 5.5 trong khe
        // 10) là vùng CHẾT — chạm cao phím 123/ABC/emoji mất hẳn, chạm cao emoji ra chữ z.
        if v != nil, let b = nearestControl(at: point) {
            if let l = nearestLetterDistance(at: TouchGeometry.keySelectionPoint(point, top: rowsContainer.frame.minY)),
               l < b.distance { return self }
            return biasedHit(b.button, at: point, time: time) ?? b.button
        }
        if v != nil, nearestLetterButton(at: point) != nil { return self }
        return v
    }

    /// Ưu tiên ở mép chung (KeyHitBias, iPhone): điểm rơi vào "," / "." nhưng trong dải sát
    /// space ⇒ space — CHỈ ngoài khung nhìn thấy của phím dấu (khe / phần nở); trong khung
    /// ⇒ luôn phím dấu (Phil 04/11/2026, #145 "bấm , toàn trượt sang space"). Ngược lại vùng
    /// nở của space lỡ phủ vào khung phím dấu kề (khe hẹp) ⇒ trả về phím dấu.
    /// ⇧ / ⌫ không bao giờ nhường cho phím chữ (SpecialKeyGutter).
    /// nil = giữ `c`. Chỉ chạy khi điểm chạm trúng "," / "." hoặc space (rẻ).
    private func biasedHit(_ c: UIControl, at point: CGPoint, time: TimeInterval?) -> UIView? {
        if let s = c as? KeyButton, s.isSpaceKey, let row = s.superview {
            for case let k as KeyButton in row.subviews
            where k !== s && !k.isSpecial && !k.isHidden && k.isUserInteractionEnabled {
                if KeyHitBias.insidePunct(point, punct: convert(k.bounds, from: k)) { return k }
            }
            return nil
        }
        guard !Self.isPad else { return nil }
        // Khe giữa phím dấu bất kỳ và space kề (cùng hàng) ⇒ space. Trước đây chỉ đúng nhờ thứ tự
        // hit-test + sai số làm tròn khung của Auto Layout ở điểm giữa khe; giờ là luật tường minh.
        if let space = spaceBar, c !== space, let b = c as? KeyButton, !b.isSpecial,
           b.superview != nil, b.superview === space.superview {
            let pf = convert(b.bounds, from: b)
            if !KeyHitBias.insidePunct(point, punct: pf),
               KeyHitBias.intrudes(point, loser: pf, winner: convert(space.bounds, from: space), band: 0) {
                return space
            }
        }
        let since = time.flatMap { t in lastLetterDownTime.map { t - $0 } }
        if let space = spaceBar, c !== space, let b = c as? KeyButton,
           let t = b.currentTitle, t == "," || t == ".",
           b.superview != nil, b.superview === space.superview {
            let band = KeyHitBias.spaceBand(sinceLetter: since)
            if KeyHitBias.spaceClaims(point, punct: convert(b.bounds, from: b),
                                      space: convert(space.bounds, from: space), band: band) {
                return space
            }
        }
        return nil
    }

    /// Nút thật (phím chức năng) sở hữu khe cùng hàng chứa `point` (SpecialKeyGutter).
    /// Chỉ chạy ở khe (hiếm), ≤ ~15 rect.
    private func gutterSpecial(at point: CGPoint) -> UIControl? {
        guard point.y >= rowsContainer.frame.minY, rowsContainer.frame.contains(point) else { return nil }
        var buttons: [UIControl] = []
        for row in rowsContainer.arrangedSubviews {
            for c in rowControls(row)
            where c.isUserInteractionEnabled && !c.isHidden && c.alpha > 0.01 {
                buttons.append(c)
            }
        }
        guard !buttons.isEmpty else { return nil }
        let i = SpecialKeyGutter.owner(point, specials: buttons.map { convert($0.bounds, from: $0) },
                                       letters: letterGeometry().rects)
        return i.map { buttons[$0] }
    }

    /// Nút thật (bật tương tác, đang hiện) trong các hàng phím gần `point` nhất — chỉ chạy ở
    /// khe/mép (hiếm), ≤ ~40 rect. Tầm với 22pt như router chữ.
    private func nearestControl(at point: CGPoint) -> (button: UIControl, distance: CGFloat)? {
        guard point.y >= rowsContainer.frame.minY, rowsContainer.frame.contains(point) else { return nil }
        var buttons: [UIControl] = []
        for row in rowsContainer.arrangedSubviews {
            for c in rowControls(row)
            where c.isUserInteractionEnabled && !c.isHidden && c.alpha > 0.01 {
                buttons.append(c)
            }
        }
        let rects = buttons.map { convert($0.bounds, from: $0) }
        guard let n = KeyGeometry.nearest(point, in: rects, reach: 22) else { return nil }
        return (buttons[n.index], n.distance)
    }

    private func nearestLetterDistance(at p: CGPoint) -> CGFloat? {
        guard lettersLike, !letterKeys.isEmpty else { return nil }
        let rects = letterKeys.map { convert($0.button.bounds, from: $0.button) }
        return KeyGeometry.nearest(p, in: rects, reach: 22)?.distance
    }

    private func letterCoreContains(_ point: CGPoint) -> Bool {
        guard point.y >= rowsContainer.frame.minY else { return false }
        return letterGeometry().rects.contains { $0.contains(point) }
    }

    /// Frame phím chữ (toạ độ self) + ký tự gốc, CACHE giữa các lần layout: router chạy
    /// hitTest + routeDown (+ smartPick) mỗi chạm — trước đây 2–3 lượt convert 26 phím và
    /// cấp phát 2 mảng mỗi chạm. Vứt ở mỗi layoutSubviews / rebuild (phím dời ⇒ tính lại).
    private var letterGeometryCache: (rects: [CGRect], chars: [Character])?
    private func letterGeometry() -> (rects: [CGRect], chars: [Character]) {
        if let c = letterGeometryCache, c.rects.count == letterKeys.count { return c }
        let g = (letterKeys.map { convert($0.button.bounds, from: $0.button) },
                 letterKeys.map { $0.base.first ?? " " })
        letterGeometryCache = g
        return g
    }

    private func nearestLetterButton(at point: CGPoint) -> KeyButton? {
        // Chỉ route touch TRONG vùng phím — touch ở strip gợi ý phía trên là
        // của chevron/slot, router mà cướp thì chevron "bấm mãi không ăn".
        guard lettersLike, !letterKeys.isEmpty,
              point.y >= rowsContainer.frame.minY else { return nil }
        var best: (Int, CGFloat)?
        for (i, f) in letterGeometry().rects.enumerated() {
            if f.insetBy(dx: -3, dy: -5.5).contains(point) { return letterKeys[i].button }
            let dx = max(f.minX - point.x, 0, point.x - f.maxX)
            let dy = max(f.minY - point.y, 0, point.y - f.maxY)
            let d = dx * dx + dy * dy
            if best == nil || d < best!.1 { best = (i, d) }
        }
        // chỉ nhận khi thật sự gần hàng phím chữ (~nửa chiều cao phím)
        guard let (i, d) = best else { return nil }
        if d <= 21 * 21 { return letterKeys[i].button }
        // Lề hàng thụt (a…l): từ mép màn hình tới a / sau l (~26pt) là của a / l như stock —
        // trước đây quá tầm 21pt ⇒ chạm sát mép hàng a/l mất phím. Chỉ khi điểm nằm TRONG dải
        // cao của hàng và ở ngoài phím đầu / cuối hàng (hiếm — đường thường đã return ở trên).
        let rects = letterGeometry().rects, f = rects[i]
        guard point.y >= f.minY, point.y <= f.maxY else { return nil }
        let first = i == 0 || rects[i - 1].midY != f.midY
        let last = i == rects.count - 1 || rects[i + 1].midY != f.midY
        if (first && point.x < f.minX) || (last && point.x > f.maxX) { return letterKeys[i].button }
        return nil
    }

    /// Chọn phím theo ngữ cảnh (thử nghiệm, TouchTarget): controller trả P(phím | từ đang
    /// gõ) lúc chạm, nil = không biết / tắt. nil (mặc định) ⇒ router gần-nhất như cũ.
    var letterPrior: (() -> ((Character) -> Float?)?)?

    /// Tự sửa (thử nghiệm): điểm chạm của phím chữ sắp chèn — lệch so với tâm phím, theo cỡ
    /// phím. Gọi NGAY TRƯỚC khi phím đó tới controller. nil (tắt) ⇒ không tính gì.
    var onLetterTouch: ((Float, Float) -> Void)?

    /// Vùng biên giữa 2 phím ⇒ TouchTarget.choose; lõi phím ⇒ giữ ngay (0 alloc).
    private func smartPick(_ hit: KeyButton, at p: CGPoint,
                           prior lp: () -> ((Character) -> Float?)?) -> KeyButton {
        guard plane == .letters,
              let hi = letterKeys.firstIndex(where: { $0.button === hit }),
              !TouchTarget.inCore(p, letterGeometry().rects[hi]) else { return hit }
        // Chốt phím nhấc-mới-chốt đang đè (vd space) TRƯỚC để prior thấy từ đang gõ mới nhất
        // (sendActions(.touchDown) sau đó flush lần nữa = no-op).
        commits.flush(except: nil)
        guard let prior = lp(), let idx = letterKeys.firstIndex(where: { $0.button === hit }) else { return hit }
        let g = letterGeometry()
        return letterKeys[TouchTarget.choose(p, rects: g.rects, keys: g.chars, nearest: idx, prior: prior)].button
    }

    // MARK: chạm mới đã gán cho nút của plane CŨ (UIKit hit-test trước khi phím đang đè chốt)

    /// Chạm đã chuyển sang plane mới: router chữ (routedTouches) hoặc nút thật (reroutedControls).
    /// Giữ UITouch để dọn nếu nút cũ (đã gỡ) không còn nhận sự kiện nhấc.
    private var reroutedTouches: [ObjectIdentifier: UITouch] = [:]
    private var reroutedControls: [ObjectIdentifier: UIControl] = [:]

    /// KeyButton.preTouchDown: chốt phím đang đè (như hook touchDown của baseButton). Space /
    /// dấu kết vế ở 123/#+= có thể về ABC lúc chốt — nút `b` (plane cũ) không còn hiện ⇒ tra lại
    /// điểm chạm ở plane mới: vùng chữ ⇒ routeDown, nút thật ⇒ gửi touchDown cho nút đó.
    private func flushBeforeButtonDown(_ b: KeyButton, touch t: UITouch, event: UIEvent?) -> Bool {
        if planeSlide != nil, t !== planeSlideTouch { planeSlideSecondTouch() }
        sweepReroutedTouches()
        settleAltHold()
        guard commits.flush(except: ObjectIdentifier(b), changes: { plane }),
              !b.isDescendant(of: self) else { return false }
        layoutIfNeeded()                         // plane mới vừa dựng: khung phím cho router
        let id = ObjectIdentifier(t), raw = t.location(in: self)
        let target = bounds.contains(raw) ? routedHitTest(raw, with: event, time: t.timestamp) : nil
        if target === self {
            reroutedTouches[id] = t
            routeDown(id, at: raw, time: t.timestamp, batch: 1)
        } else if let c = target as? UIControl, c !== b {
            reroutedTouches[id] = t
            reroutedControls[id] = c
            c.sendActions(for: .touchDown)
        }
        return true
    }

    private func reroutedTouchEvents(_ phase: UITouch.Phase, _ touches: Set<UITouch>, _ event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard reroutedTouches[id] != nil else { continue }
            if phase == .moved {
                if reroutedControls[id] == nil { touchesMoved([t], with: event) }
                continue
            }
            endRerouted(id, touch: t, cancelled: phase == .cancelled)
        }
    }

    private func endRerouted(_ id: ObjectIdentifier, touch t: UITouch, cancelled: Bool) {
        reroutedTouches[id] = nil
        if let c = reroutedControls.removeValue(forKey: id) {
            let inside = c.bounds.contains(t.location(in: c))
            c.sendActions(for: cancelled ? .touchCancel : inside ? .touchUpInside : .touchUpOutside)
        } else {
            routeUp(id, at: t.location(in: self), time: t.timestamp, cancelled: cancelled)
        }
    }

    /// Nút cũ đã gỡ có thể không nhận nhấc ⇒ chạm đã kết thúc mà chưa dọn: chốt như huỷ.
    private func sweepReroutedTouches() {
        guard !reroutedTouches.isEmpty else { return }
        for (id, t) in reroutedTouches where t.phase == .ended || t.phase == .cancelled {
            endRerouted(id, touch: t, cancelled: true)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        sweepReroutedTouches()
        for t in touches {
            routeDown(ObjectIdentifier(t), at: t.location(in: self), time: t.timestamp,
                      batch: touches.count)
        }
    }

    /// Chạm xuống vùng chữ: gán phím gần nhất và chèn NGAY (touchDown). Gõ vuốt bật ⇒
    /// touch duy nhất được route bắt đầu phân loại chạm/vuốt (GestureClassifier) và chữ của
    /// nó HOÃN tới lúc nhấc (#172); phản hồi (balloon, rung, âm) vẫn ngay lúc chạm.
    private func routeDown(_ id: ObjectIdentifier, at raw: CGPoint, time: TimeInterval, batch: Int) {
        // Ngón thứ hai lúc trackpad (bàn phím Apple: chuyển sang chọn chữ). iOS không cho bàn phím
        // bên thứ ba đặt vùng chọn (UITextDocumentProxy chỉ có adjustTextPosition) ⇒ nuốt ngón đó:
        // KHÔNG gõ phím dưới ngón (trước đây ra một chữ lạc giữa lúc di con trỏ).
        if TrackpadTouch.swallows(trackpadActive: trackpadActive, isTrackpadFinger: false) {
            trackpadExtraFinger()
            return
        }
        let p = TouchGeometry.keySelectionPoint(raw, top: rowsContainer.frame.minY)
        var b = swipeActive ? nil : nearestLetterButton(at: p)
        // Giữ ⇧ + phím có ký tự phụ ⇒ gõ ký tự phụ (không chọn phím theo ngữ cảnh chữ).
        let shiftSym = shiftHold.held && !shiftAlts.isEmpty && plane == .letters
            ? b.flatMap { shiftSymbol(for: $0, time: time) } : nil
        if shiftSym == nil, let hit = b, let lp = letterPrior { b = smartPick(hit, at: p, prior: lp) }
        TouchLog.touchBegan(active: routedTouches.count, batch: batch,
                            touchTimestamp: time, hit: b != nil, y: Double(p.y),
                            key: b?.currentTitle)
        guard let b else { return }
        if classifier != nil {                   // ngón thứ hai lúc chưa quyết ⇒ khoá chạm
            classifier?.secondTouch()
            stopClassifying()
        }
        if keyCmd != nil { cancelKeyCommand() }  // ngón thứ hai ⇒ không còn là cử chỉ lệnh
        routedTouches[id] = b
        if Self.isPad || flickDownActive { routedStart[id] = raw }
        let since = lastLetterDownTime.map { time - $0 }
        lastLetterDownTime = time
        if let sym = shiftSym {                  // không vuốt / lệnh / giữ ký tự phụ cho chạm này
            typeShiftSymbol(sym, on: b)
            return
        }
        // Phím đang chờ chốt (chữ hoãn của ngón trước, space đang đè…) chốt TRƯỚC khi ghi điểm
        // chạm của phím này — chốt sau sẽ tiêu mất điểm chạm (tự sửa) của phím này.
        if !commits.isEmpty { settleAltHold(); commits.flush(except: nil) }
        var report: (() -> Void)?
        if let r = onLetterTouch, plane == .letters {               // tự sửa: lệch so với tâm phím
            let k = convert(b.bounds, from: b)
            if k.width > 0, k.height > 0 {
                let dx = Float((p.x - k.midX) / k.width), dy = Float((p.y - k.midY) / k.height)
                report = { r(dx, dy) }
            }
        }
        // Vuốt phím lên = lệnh (tắt ⇒ một phép so bool). Đang có vùng chọn ⇒ HOÃN chữ tới lúc
        // nhấc (KeyCommitQueue) — chèn ngay sẽ thay mất vùng chọn trước khi kịp sao chép/cắt.
        var cmd: KeyCommandGesture?
        if keyCommandsEnabled, plane == .letters, routedTouches.count == 1 {
            cmd = beginKeyCommand(b, at: raw)
        }
        let selectionDefer = cmd != nil && keyCommandHasSelection?() == true
        // Hàng chữ trên cùng vuốt thẳng lên = ký tự phụ (số). Phím có lệnh thì lệnh thắng.
        var upAlt: String?
        if cmd == nil, flickUpActive, plane == .letters, routedTouches.count == 1 {
            (cmd, upAlt) = beginFlickUp(b, at: raw)
        }
        // Gõ vuốt bật + chạm có thể thành vuốt ⇒ cũng HOÃN chữ tới lúc nhấc (#172): ngón còn
        // đè thì chưa ghi gì vào ô; chạm ⇒ chữ chèn lúc nhấc (hoặc khi ngón khác chạm xuống),
        // vuốt ⇒ chỉ từ vuốt. Tắt gõ vuốt ⇒ chèn ngay lúc chạm như cũ (không trễ).
        let swipeKW = !selectionDefer && swipeEnabled && plane == .letters && !builtSplit
            && routedTouches.count == 1 ? letterKeyPitch() : nil
        if selectionDefer || swipeKW != nil {
            deferredLetterID = id
            deferredLetterReport = report
        } else {
            report?()
        }
        b.sendActions(for: .touchDown)
        deferredLetterID = nil
        deferredLetterReport = nil
        if let cmd {
            keyCmd = cmd
            keyCmdTouchID = id
            keyCmdButton = b
            keyCmdAlt = upAlt
        }
        // Chữ hoãn vì vùng chọn: không gõ vuốt / ký tự phụ cho chạm này.
        guard !selectionDefer else { return }
        if let kw = swipeKW {
            startClassifying(id, at: p, time: time, key: convert(b.bounds, from: b),
                             keyWidth: kw, since: since)
        }
        if !activeAlts.isEmpty { armAltHold(id, button: b, at: raw) }
    }

    /// Chạm phím có ký tự phụ: hẹn giờ `holdDelay`. Chữ đã chèn lúc chạm (gõ vuốt bật: hoãn,
    /// chèn ngay trước khi thay); hết giờ mà ngón chưa trôi / chưa thành vuốt ⇒ balloon hiện
    /// ký tự phụ, nhấc tay thì thay chữ.
    private func armAltHold(_ id: ObjectIdentifier, button b: KeyButton, at raw: CGPoint) {
        guard let base = letterKeys.first(where: { $0.button === b })?.base.first,
              let alt = activeAlts[base] else { return }
        altHold = (id, b, KeyAlternates.Hold(alt: alt, start: raw))
        let w = DispatchWorkItem { [weak self] in self?.fireAltHold() }
        altTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + KeyAlternates.holdDelay, execute: w)
    }

    private func fireAltHold() {
        altTimer = nil
        guard var h = altHold, !swipeActive, h.hold.fire() else { return }
        altHold = h
        if swipeTouchID == h.id { stopClassifying() }   // đã là giữ: trôi sau đó không thành vuốt
        if keyCmdTouchID == h.id { cancelKeyCommand() } // popup ký tự phụ thắng vuốt-lên
        Self.flickFeedback()
        showBalloon(over: h.button, text: h.hold.alt, force: true)
    }

    /// Ngón mới chạm (phím bất kỳ): giữ chưa đủ giờ ⇒ chỉ là chạm; đã bắn ⇒ chốt ký tự phụ
    /// NGAY (trước phím mới, kẻo checkpoint huỷ chữ trỏ nhầm phím).
    private func settleAltHold() {
        guard let h = altHold else { return }
        altTimer?.cancel(); altTimer = nil
        altHold = nil
        guard let alt = h.hold.commit else { return }
        commits.release(h.id)                    // chữ hoãn (gõ vuốt bật) chèn trước rồi mới thay
        commitAlt(alt)
    }

    private func dropAltHold() {
        altTimer?.cancel(); altTimer = nil
        altHold = nil
    }

    /// Phím "," có giữ ra ".": nhãn nhỏ góc trên-phải như phím chữ; chạm hẹn giờ `holdDelay`,
    /// hết giờ mà "," còn chờ chốt ⇒ đổi thành "." (KeyAlternates.holdComma) + balloon + rung.
    /// Chốt lúc nhấc / khi ngón khác chạm như "," ⇒ từ đang gõ được chốt y hệt.
    private func armCommaHold(_ b: KeyButton, alt: String = KeyAlternates.commaAlt) {
        let l = UILabel()
        l.text = alt
        l.font = .systemFont(ofSize: 10, weight: .medium)
        l.textColor = inkFaded(0.45)
        l.isUserInteractionEnabled = false
        l.isAccessibilityElement = false
        b.addOverlay(l, .topRight(right: 3, top: 2))
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self, let b else { return }
            self.commaTimer?.cancel()
            let w = DispatchWorkItem { [weak self, weak b] in
                guard let self, let b else { return }
                self.fireCommaHold(b, alt: alt)
            }
            self.commaTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + KeyAlternates.holdDelay, execute: w)
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.commaTimer?.cancel(); self.commaTimer = nil
            if self.commaFired { self.commaFired = false; self.hideBalloon() }
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    private func fireCommaHold(_ b: KeyButton, alt: String = KeyAlternates.commaAlt) {
        commaTimer = nil
        let fired = KeyAlternates.holdComma(commits, id: ObjectIdentifier(b), alt: alt) { [weak self] alt in
            self?.hideBalloon()
            self?.tapped(.text(alt))
        }
        guard fired else { return }
        commaFired = true
        Self.flickFeedback()
        showBalloon(over: b, text: alt, force: true)
    }
    private var commaTimer: DispatchWorkItem?
    private var commaFired = false

    // MARK: vuốt "," / "." hàng đáy thẳng xuống ⇒ dấu còn lại của cặp (KeyAlternates.punctFlick)

    /// Theo ngón trên phím; đủ quãng thẳng xuống mà phím còn chờ chốt ⇒ đổi ký tự chờ chốt
    /// (cùng đường với giữ phím: balloon + rung, chốt lúc nhấc / khi ngón khác chạm).
    private func armPunctFlick(_ b: KeyButton) {
        b.addTarget(self, action: #selector(punctFlickTouch(_:event:)),
                    for: [.touchDown, .touchDragInside, .touchDragOutside])
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.punctFlickStart = nil
            if self.commaFired { self.commaFired = false; self.hideBalloon() }
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    @objc private func punctFlickTouch(_ sender: UIControl, event: UIEvent?) {
        guard let b = sender as? KeyButton,
              let t = event?.allTouches?.first(where: { $0.view === sender }) else { return }
        let p = t.location(in: self), id = ObjectIdentifier(b)
        if t.phase == .began || punctFlickStart?.id != id { punctFlickStart = (id, p); return }
        punctFlickMoved(b, to: p)
    }
    private func punctFlickMoved(_ b: KeyButton, to p: CGPoint) {
        guard let s = punctFlickStart, s.id == ObjectIdentifier(b), !commaFired,
              KeyAlternates.isPunctFlick(dx: p.x - s.p.x, dy: p.y - s.p.y),
              let alt = KeyAlternates.punctFlick(b.currentTitle ?? "", setting: flickDownSetting,
                                                 alternates: activeAlts) else { return }
        commaTimer?.cancel()
        fireCommaHold(b, alt: alt)
    }
    private var punctFlickStart: (id: ObjectIdentifier, p: CGPoint)?

    // MARK: giữ "." ⇒ popup đuôi tên miền (ô .search / .url / .email, bàn chữ)

    /// Hẹn giờ `holdDelay` như giữ ","; hết giờ mà phím còn chờ chốt ⇒ dựng popup (lần đầu
    /// mới tạo view), phím chờ chốt đổi thành "chèn đuôi đang chọn" — chốt lúc nhấc / khi ngón
    /// khác chạm y như "." ⇒ từ đang gõ được chốt cùng đường. Trượt xa ⇒ không chọn ⇒ nhấc
    /// không chèn gì.
    private func armDomainHold(_ b: KeyButton, choices: [String], variants: Bool = false) {
        b.addTarget(self, action: #selector(domainTouch(_:event:)),
                    for: [.touchDown, .touchDragInside, .touchDragOutside])
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self, let b, !UIAccessibility.isVoiceOverRunning else { return }
            self.domainTimer?.cancel()
            let w = DispatchWorkItem { [weak self, weak b] in
                guard let self, let b, b.isTracking else { return }
                self.fireDomainHold(b, choices: choices, variants: variants)
            }
            self.domainTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + KeyAlternates.holdDelay, execute: w)
        }, for: .touchDown)
        // Sau armCommit (release chạy trước ⇒ đuôi đã chèn), rồi dọn popup.
        b.addAction(UIAction { [weak self] _ in
            self?.domainTimer?.cancel(); self?.domainTimer = nil
            self?.closeDomainPopup()
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func domainTouch(_ sender: UIControl, event: UIEvent?) {
        guard let t = event?.allTouches?.first(where: { $0.view === sender }) else { return }
        let p = t.location(in: self)
        domainLastPoint = p
        if domainHold?.button === sender { domainMoved(to: p) }
    }

    /// `variants`: hàng biến thể ký tự (KeyVariants) — ô hẹp hơn, chữ to hơn đuôi tên miền.
    private func fireDomainHold(_ b: KeyButton, choices: [String], variants: Bool = false) {
        domainTimer = nil
        let id = ObjectIdentifier(b)
        guard commits.isArmed(id) else { return }       // "." đã chốt (ngón khác chạm trước)
        commits.disarm(id)
        commits.arm(id) { [weak self] in
            guard let self else { return }
            let s = self.domainHold.flatMap { h in h.track.selection.map { h.choices[$0] } }
            self.closeDomainPopup()
            if let s {
                if variants {                                    // như chạm thường (space / dấu kết vế về chữ)
                    self.typedInSymbolPlane = true
                    self.tapSymbol(s)
                } else {
                    self.tapped(.text(s))
                }
            }
        }
        let key = convert(b.bounds, from: b)
        let itemW: CGFloat = variants ? (Self.isPad ? 56 : 38) : (Self.isPad ? 68 : 56)
        let panelH: CGFloat = Self.isPad ? 52 : 46
        // Chật một hàng ⇒ hai hàng chồng lên (#154) — chỉ khi phía trên đủ chỗ cho cả hai.
        let l = DomainPopup.layout(keyMidX: key.midX, itemWidth: itemW, count: choices.count,
                                   containerWidth: bounds.width, rowHeight: panelH,
                                   maxRows: key.minY - 8 - 2 * panelH >= 0 ? 2 : 1)
        let top = max(key.minY - 8 - panelH * CGFloat(l.rows), 0)       // không vượt mép trên (bị cắt)
        let p = domainLastPoint ?? CGPoint(x: key.midX, y: key.midY)
        let track = DomainPopup.Track(layout: l, top: top, bottom: key.maxY, start: p)
        let sel = track.selection
        domainHold = (b, choices, track)
        debugLastDomainLayout = l
        debugLastDomainTop = top
        hideBalloon()
        domainPopupMade = true
        if domainPopup == nil { domainPopup = DomainPopupView() }
        guard let v = domainPopup else { return }
        if v.superview == nil { addSubview(v) }
        v.present(layout: l, key: key, top: top, panelH: panelH, choices: choices,
                  popup: popup,
                  fontSize: (variants ? (Self.isPad ? 26 : 24) : (Self.isPad ? 20 : 18)) * CGFloat(popup.style.labelScale))
        v.select(sel)
        Self.flickFeedback()
    }

    private func domainMoved(to p: CGPoint) {
        guard var h = domainHold, h.track.move(to: p) else { return }
        let sel = h.track.selection
        domainHold = h
        domainPopup?.select(sel)
        if sel != nil { Self.flickFeedback() }
    }

    private func closeDomainPopup() {
        domainHold = nil
        domainLastPoint = nil
        domainPopup?.isHidden = true
    }

    private var domainTimer: DispatchWorkItem?
    private var domainLastPoint: CGPoint?
    private var domainHold: (button: KeyButton, choices: [String], track: DomainPopup.Track)?
    private var domainPopup: DomainPopupView?
    private var domainPopupMade = false
    var debugDomainPopupMade: Bool { domainPopupMade }
    private(set) var debugLastDomainLayout: DomainPopup.Layout?
    private(set) var debugLastDomainTop: CGFloat?
    #if DEBUG
    /// Khung phím `title` theo toạ độ view (test popup).
    func debugDomainKeyFrame(_ title: String) -> CGRect? { debugButton(title).map { convert($0.bounds, from: $0) } }
    func debugDomainKeyView(_ title: String) -> UIView? { debugButton(title) }
    #endif
    /// Đuôi đang chọn khi popup mở (nil = đóng / không chọn).
    var debugDomainSelection: String? { domainHold.flatMap { h in h.track.selection.map { h.choices[$0] } } }
    var debugDomainPopupVisible: Bool { domainPopup.map { !$0.isHidden && $0.superview != nil } ?? false }

    /// Popup đuôi tên miền: panel bo góc liền khối với phím (cùng nền balloon, bóng như
    /// balloon), ô đang chọn nền xanh hệ thống chữ trắng như stock.
    private final class DomainPopupView: UIView {
        private let shape = CAShapeLayer()
        private let highlight = CALayer()
        private var labels: [UILabel] = []
        private var slots: [CGRect] = []
        private var ink: UIColor = .label
        private var selectedInk: UIColor = .white
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.zPosition = 11
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 1)
            layer.shadowRadius = 3
            layer.shadowOpacity = 0.3
            layer.addSublayer(shape)
            highlight.backgroundColor = UIColor.systemBlue.cgColor
            highlight.cornerRadius = 7
            highlight.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer.addSublayer(highlight)
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Toạ độ `key`, `layout`, `top` theo superview (KeyboardView).
        func present(layout l: DomainPopup.Layout, key: CGRect, top: CGFloat, panelH: CGFloat,
                     choices: [String], popup: PopupUI, fontSize: CGFloat) {
            let inset: CGFloat = 4
            let panel = CGRect(x: l.originX - inset, y: top, width: l.width + inset * 2,
                               height: panelH * CGFloat(l.rows))
            let f = panel.union(key)
            frame = f
            let lp = panel.offsetBy(dx: -f.minX, dy: -f.minY)
            let lk = key.offsetBy(dx: -f.minX, dy: -f.minY)
            // Bo góc / viền / màu như phím (KeyPopupStyle); ô chọn = màu nhấn.
            let st = popup.style
            let path = UIBezierPath(roundedRect: lp, cornerRadius: min(st.radius(size: lk.size, fallback: 10), lp.height / 2))
            // Cổ nối panel xuống trọn phím (phủ phím như balloon).
            let neck = CGRect(x: lk.minX, y: lp.maxY - 10, width: lk.width, height: lk.maxY - lp.maxY + 10)
            path.append(UIBezierPath(roundedRect: neck,
                                     cornerRadius: min(st.radius(size: lk.size, fallback: KeyboardView.keyRadius), lk.width / 2)))
            shape.path = path.cgPath
            shape.fillColor = popup.fill.cgColor
            shape.strokeColor = popup.border
            shape.lineWidth = CGFloat(st.borderWidth)
            layer.shadowPath = path.cgPath
            self.ink = popup.ink
            self.selectedInk = popup.selectedInk
            highlight.backgroundColor = popup.selectedFill.cgColor
            while labels.count < choices.count {
                let lb = UILabel()
                lb.textAlignment = .center
                lb.adjustsFontSizeToFitWidth = true
                lb.minimumScaleFactor = 0.7
                addSubview(lb)
                labels.append(lb)
            }
            slots = []
            for (i, lb) in labels.enumerated() {
                guard i < choices.count else { lb.isHidden = true; continue }
                // Hai hàng: hàng 0 (ô đầu) dưới cùng, sát phím; hàng 1 ở trên.
                let rowTop = lp.minY + panelH * CGFloat(l.rows - 1 - l.rowOf(i))
                let r = CGRect(x: l.slotMinX(i) - f.minX, y: rowTop + inset,
                               width: l.itemWidth, height: panelH - inset * 2)
                slots.append(r)
                lb.isHidden = false
                lb.text = choices[i]
                lb.font = KeyboardView.popupFont(fontSize, height: r.height)
                lb.frame = r
            }
            isHidden = false
        }

        func select(_ i: Int?) {
            for (j, lb) in labels.enumerated() { lb.textColor = j == i ? selectedInk : ink }
            guard let i, i < slots.count else { highlight.isHidden = true; return }
            highlight.frame = slots[i].insetBy(dx: 1, dy: 0)
            highlight.isHidden = false
        }
    }

    private func commitAlt(_ alt: String) {
        hideBalloon()
        if shiftBeforeLastLetter == .on, shift == .off { shift = .on; applyShiftAppearance() }
        tapped(.replaceLastLetter(alt))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let h = altHold, !h.hold.fired {
            for t in touches where ObjectIdentifier(t) == h.id {
                if altHold?.hold.move(to: t.location(in: self)) == true { dropAltHold() }
            }
        }
        if let kid = keyCmdTouchID {
            for t in touches where ObjectIdentifier(t) == kid { keyCommandMoved(to: t.location(in: self)) }
        }
        guard let id = swipeTouchID else { return }     // tắt / không theo dõi ⇒ 0 việc
        for t in touches where ObjectIdentifier(t) == id {
            let samples = (event?.coalescedTouches(for: t) ?? [t]).lazy.map { ($0.location(in: self), $0.timestamp) }
            if !swipeMovedBatch(samples) { return }
        }
    }

    /// Một lượt touchesMoved của ngón đang vuốt: MỌI điểm gộp (coalesced, 120 Hz) vào decoder + nét như
    /// trước, nhưng nét chỉ dựng path + commit MỘT lần cuối lượt (màn 60 Hz chỉ hiện lần cuối).
    /// false = ngón thôi được theo dõi (phân loại ra chạm) — dừng như trước.
    @discardableResult
    private func swipeMovedBatch<S: Sequence>(_ samples: S) -> Bool where S.Element == (CGPoint, TimeInterval) {
        var dirty = false
        defer { if dirty { trail?.redraw() } }
        for (p, time) in samples {
            if swipeMoved(to: p, time: time) { dirty = true }
            if swipeTouchID == nil { return false }
        }
        return true
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            routeUp(ObjectIdentifier(t), at: t.location(in: self), time: t.timestamp, cancelled: false)
        }
    }

    private func routeUp(_ id: ObjectIdentifier, at raw: CGPoint, time: TimeInterval, cancelled: Bool) {
        var command: KeyCommand?
        var upAlt: String?
        if id == keyCmdTouchID {
            if keyCmdAlt != nil { upAlt = flickUpEnd(at: raw, time: time, cancelled: cancelled) }
            else { command = keyCommandUp(at: raw, time: time, cancelled: cancelled) }
        }
        let swiped = swipeUp(id, at: raw, time: time)
        let b = routedTouches.removeValue(forKey: id)
        let start = routedStart.removeValue(forKey: id)
        TouchLog.touchEnded(cancelled: cancelled, routed: b != nil)
        // Chữ HOÃN của chạm này (gõ vuốt bật / vuốt-lên-lệnh + vùng chọn) còn chờ — chưa bị ngón
        // khác chạm xuống chốt, chưa thành vuốt (beginSwipe đã bỏ). Thành lệnh ⇒ bỏ; không ⇒ chèn
        // NGAY lúc nhấc (cả khi hệ thống huỷ touch: không nuốt phím), trước ký tự phụ.
        let letterDeferred = commits.isArmed(id)
        if letterDeferred, command != nil { commits.disarm(id) }
        if letterDeferred { commits.release(id) }
        guard let b else { return }
        if let command {
            if altHold?.id == id { dropAltHold() }
            b.sendActions(for: .touchUpInside)
            onKeyCommand?(command, letterDeferred)
            return
        }
        var alt: String?
        if let h = altHold, h.id == id { alt = h.hold.commit; dropAltHold() }
        b.sendActions(for: .touchUpInside)
        if let upAlt, !swiped {
            // Vuốt thẳng lên ở hàng chữ trên cùng: cùng đường huỷ-phím-rồi-chèn như vuốt xuống
            // (chữ hoãn vừa được chèn ở trên, chữ chèn lúc chạm thì đã có sẵn).
            if shiftBeforeLastLetter == .on, shift == .off { shift = .on; applyShiftAppearance() }
            tapped(.replaceLastLetter(upAlt))
            return
        }
        if let alt, !swiped { commitAlt(alt); return }  // cancel vẫn chốt như chữ thường
        guard !swiped, !cancelled else { return }
        // iPad: vuốt xuống trên phím chữ = ký tự phụ như stock. Chữ đã chèn lúc
        // chạm (touchDown) → HUỶ đúng phím đó (không ⌫: phím dấu Telex đã đổi từ)
        // rồi chèn ký tự phụ; shift một lần mà phím đó đã nhả thì trả lại.
        if let start, KeyLayout.isPadFlick(dx: raw.x - start.x, dy: raw.y - start.y,
                                           threshold: Self.flickDistance),
           let base = letterKeys.first(where: { $0.button === b })?.base,
           Self.isPad, let sec = Self.padSecondary[base] {
            if shiftBeforeLastLetter == .on, shift == .off { shift = .on; applyShiftAppearance() }
            tapped(.replaceLastLetter(sec))
        } else if !Self.isPad, let start, flickDownActive,
                  KeyAlternates.isFlickDown(dx: raw.x - start.x, dy: raw.y - start.y),
                  let c = letterKeys.first(where: { $0.button === b })?.base.first, let sec = activeAlts[c] {
            // iPhone "Vuốt phím xuống ra ký tự phụ": cùng đường huỷ-phím-rồi-chèn như iPad.
            if shiftBeforeLastLetter == .on, shift == .off { shift = .on; applyShiftAppearance() }
            tapped(.replaceLastLetter(sec))
        }
    }
    private var routedStart: [ObjectIdentifier: CGPoint] = [:]
    private var shiftBeforeLastLetter: ShiftState = .off
    fileprivate static let flickDistance: CGFloat = 18

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // hệ thống cancel (edge gesture…) — vẫn CHỐT chữ thay vì nuốt phím; cú vuốt
        // đang dở cũng chốt (chữ đầu đã bỏ — bỏ ngang là mất chữ).
        for t in touches {
            routeUp(ObjectIdentifier(t), at: t.location(in: self), time: t.timestamp, cancelled: true)
        }
    }

    // MARK: vuốt phím lên = lệnh sao chép / cắt / dán (KeyCommandGesture, mặc định TẮT)
    // Chỉ phím chữ ở plane chữ, một ngón. Chữ vẫn chèn lúc chạm (trừ khi đang có vùng chọn hoặc
    // gõ vuốt bật ⇒ hoãn tới lúc nhấc); thành lệnh thì chữ hoãn bị bỏ, chữ đã chèn thì controller
    // huỷ (onKeyCommand, letterDeferred = false) rồi chạy lệnh. Tắt công tắc ⇒ không tạo gì,
    // touchesMoved không thêm việc.

    /// Controller bật theo công tắc "Vuốt phím để sao chép/dán".
    var keyCommandsEnabled = false {
        didSet { if !keyCommandsEnabled, oldValue { cancelKeyCommand() } }
    }
    /// Ô đang có vùng chọn khác rỗng — chỉ hỏi khi chạm phím C / X / V lúc công tắc bật.
    var keyCommandHasSelection: (() -> Bool)?
    /// Nhãn xem trước lúc cử chỉ đang bật: tên lệnh, hoặc lý do không chạy được.
    var keyCommandLabel: ((KeyCommand) -> String)?
    /// Nhấc tay lúc đang bật: lệnh + chữ của phím đã bị HOÃN (chưa chèn) hay chưa.
    var onKeyCommand: ((KeyCommand, Bool) -> Void)?

    private var keyCmd: KeyCommandGesture?
    private var keyCmdTouchID: ObjectIdentifier?
    private weak var keyCmdButton: KeyButton?
    /// Đặt trong lúc router gửi touchDown cho phím chữ ⇒ phím đó HOÃN chữ (commits.arm).
    private var deferredLetterID: ObjectIdentifier?
    /// Điểm chạm (tự sửa) của phím hoãn — báo lúc chữ thật sự chèn.
    private var deferredLetterReport: (() -> Void)?
    private var keyCmdPill: UILabel?
    /// Cử chỉ đang theo dõi là vuốt-lên-ra-ký-tự-phụ (hàng chữ trên cùng): ký tự sẽ chèn.
    private var keyCmdAlt: String?

    /// Phím hàng chữ trên cùng có ký tự phụ ⇒ cử chỉ vuốt thẳng lên + ký tự đó.
    private func beginFlickUp(_ b: KeyButton, at raw: CGPoint) -> (KeyCommandGesture?, String?) {
        guard let base = letterKeys.first(where: { $0.button === b })?.base.first,
              let alt = activeAlts[base], let kw = letterKeyPitch() else { return (nil, nil) }
        let key = convert(b.bounds, from: b), top = rowsContainer.frame.minY
        guard KeyAlternates.isTopRow(keyMinY: key.minY, keyHeight: key.height, keyAreaTop: top),
              let g = KeyCommandGesture.beginUp(start: raw, keyAreaTop: top, keyPitch: kw) else { return (nil, nil) }
        return (g, alt)
    }

    /// Nhấc tay: ký tự phụ nếu cử chỉ đang bật; chưa bật ⇒ như keyCommandUp (gõ vuốt xét điểm cuối).
    private func flickUpEnd(at raw: CGPoint, time: TimeInterval, cancelled: Bool) -> String? {
        guard var g = keyCmd, let alt = keyCmdAlt else { endKeyCommand(); return nil }
        let fired = !cancelled && g.endArmed(at: raw)
        endKeyCommand()
        if !fired, !cancelled, !swipeActive, var c = classifier {
            let d = c.move(to: TouchGeometry.keySelectionPoint(raw), time: time)
            classifier = c
            if d == .swipe { beginSwipe() }
        }
        return fired ? alt : nil
    }

    private func beginKeyCommand(_ b: KeyButton, at raw: CGPoint) -> KeyCommandGesture? {
        guard let base = letterKeys.first(where: { $0.button === b })?.base.first,
              let kw = letterKeyPitch() else { return nil }
        return KeyCommandGesture.begin(enabled: true, key: base, start: raw,
                                       keyAreaTop: rowsContainer.frame.minY, keyPitch: kw)
    }

    private func keyCommandMoved(to raw: CGPoint) {
        guard var g = keyCmd else { return }
        let e = g.move(to: raw)
        keyCmd = g
        switch e {
        case .armed:
            Self.flickFeedback()
            hideBalloon()
            (keyCmdButton as? KeyButton)?.showPressed(false)
            if let alt = keyCmdAlt { showKeyCommandPill(alt) }
            else if let c = g.command { showKeyCommandPill(keyCommandLabel?(c) ?? L(c.viLabel)) }
        case .disarmed:
            hideKeyCommandPill()
        case .rejected:
            cancelKeyCommand()
        case .none:
            break
        }
    }

    /// Nhấc tay của touch đang theo dõi: lệnh nếu đang bật. Chưa bật mà gõ vuốt đang chờ ⇒
    /// cho bộ phân loại xét điểm cuối (vuốt dọc "xe" vẫn thành từ).
    private func keyCommandUp(at raw: CGPoint, time: TimeInterval, cancelled: Bool) -> KeyCommand? {
        guard var g = keyCmd else { endKeyCommand(); return nil }
        let fired = cancelled ? nil : g.end(at: raw)
        endKeyCommand()
        if fired == nil, !cancelled, !swipeActive, var c = classifier {
            let d = c.move(to: TouchGeometry.keySelectionPoint(raw), time: time)
            classifier = c
            if d == .swipe { beginSwipe() }
        }
        return fired
    }

    private func endKeyCommand() {
        keyCmd = nil
        keyCmdTouchID = nil
        keyCmdButton = nil
        keyCmdAlt = nil
        hideKeyCommandPill()
    }

    /// Huỷ cử chỉ (ngón thứ hai, popup ký tự phụ, đường đi lệch). Chữ hoãn VẪN chờ nhấc tay
    /// (routeUp chèn nó theo commits, không cần id cử chỉ).
    private func cancelKeyCommand() {
        keyCmd = nil
        keyCmdTouchID = nil
        keyCmdButton = nil
        keyCmdAlt = nil
        hideKeyCommandPill()
    }

    private func showKeyCommandPill(_ text: String) {
        keyCmdFlash?.cancel(); keyCmdFlash = nil
        let pill: UILabel
        if let p = keyCmdPill { pill = p } else {
            pill = UILabel()
            pill.font = .systemFont(ofSize: 15, weight: .semibold)
            pill.textAlignment = .center
            pill.layer.cornerRadius = 8
            pill.layer.masksToBounds = true
            pill.isUserInteractionEnabled = false
            keyCmdPill = pill
        }
        pill.text = text
        pill.textColor = popup.ink
        pill.backgroundColor = popup.fill
        if pill.superview == nil { addSubview(pill) }
        bringSubviewToFront(pill)
        // Ngay dưới đỉnh vùng phím, thẳng phím xuất phát — ngón đang ở trên nên không che.
        let key = keyCmdButton.map { convert($0.bounds, from: $0) }
            ?? CGRect(x: bounds.midX - 22, y: rowsContainer.frame.minY, width: 44, height: 42)
        let w = pill.intrinsicContentSize.width + 20, h: CGFloat = 32
        pill.frame = CGRect(x: max(4, min(key.midX - w / 2, bounds.width - w - 4)),
                            y: rowsContainer.frame.minY + 4, width: w, height: h)
        pill.isHidden = false
    }

    private func hideKeyCommandPill() {
        keyCmdFlash?.cancel(); keyCmdFlash = nil
        keyCmdPill?.isHidden = true
    }

    /// Thông báo ngắn sau lệnh ("Đã sao chép", "Chưa chọn chữ"…) ở chỗ nhãn xem trước, ~1.2s.
    func flashKeyCommandHint(_ text: String) {
        showKeyCommandPill(text)
        let w = DispatchWorkItem { [weak self] in self?.keyCmdPill?.isHidden = true }
        keyCmdFlash?.cancel()
        keyCmdFlash = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
    private var keyCmdFlash: DispatchWorkItem?

    #if DEBUG
    /// Test hook: cử chỉ đang bật (nhãn xem trước đang hiện) — nil = không theo dõi.
    var debugKeyCommandPill: String? { keyCmdPill?.isHidden == false ? keyCmdPill?.text : nil }
    /// Test hook: số cú vuốt đã giao cho controller.
    private(set) var debugSwipeUps = 0
    /// Test hook: đỉnh vùng phím (toạ độ KeyboardView) — ngưỡng bật của vuốt-lên-lệnh.
    func debugKeyAreaTop() -> CGFloat {
        layoutIfNeeded()
        return rowsContainer.frame.minY
    }
    #endif

    // MARK: gõ vuốt (thử nghiệm) — router + vệt vuốt
    // Chỉ từ phím chữ ở plane chữ (space/⌫/shift là button riêng, không tới đây).
    // Bật ⇒ chữ của chạm có thể thành vuốt HOÃN tới lúc nhấc (#172: ngón còn đè thì không ghi
    // gì vào ô); thành vuốt thì chữ hoãn bị bỏ (beginSwipe), nhấc tay giao đường vuốt
    // (onSwipeEnded). Tắt ⇒ không phân loại, không lưu điểm, chữ chèn ngay lúc chạm.

    /// Controller bật theo công tắc + SwipePolicy (ô nhập, iPad, VoiceOver).
    var swipeEnabled = false {
        didSet { if !swipeEnabled, oldValue { cancelSwipeTracking() } }
    }
    /// Touch vừa thành vuốt (chữ đầu hoãn đã bỏ, shift đã được trả lại trước khi gọi).
    var onSwipeBegan: (() -> Void)?
    /// Nhấc tay sau vuốt: đường vuốt (toạ độ self, đã dời như điểm chọn phím) + chữ hoa.
    var onSwipeEnded: ((SwipePath, SwipeCase) -> Void)?

    private var swipeTouchID: ObjectIdentifier?
    private var classifier: GestureClassifier?
    private var swipePath: SwipePath?           // cấp một lần, dùng lại
    private var swipeActive = false
    private var swipeCase: SwipeCase = .lower
    private var lastLetterDownTime: TimeInterval?
    private var trail: SwipeTrailRenderer?      // chỉ tạo khi có cú vuốt đầu; kiểu Tắt ⇒ nil
    /// Kiểu nét vuốt thực vẽ (SwipeTrailPolicy, giải lúc hiện bàn phím — "Theo giao diện" ⇒ theme đang dùng).
    private(set) var trailStyle: SwipeTrailStyle = .simple

    /// Đọc cài đặt "Hiệu ứng nét vuốt" lúc hiện (applyAppearance). Tắt ⇒ gỡ renderer (0 chi phí).
    private func configureSwipeTrail() {
        trailStyle = SwipeTrailPolicy.current(UserDefaultsProvider.shared,
                                              themeSwipe: themeSettings.effectiveKeyStyle.swipe)
        if trailStyle == .none {
            trail?.settleNow(); trail?.layer.removeFromSuperlayer(); trail = nil
            return
        }
        configureTrailColors()
    }

    /// Màu / kiểu của renderer đang có (đổi sáng/tối giữa chừng). Không đổi gì ⇒ 0 việc.
    private func configureTrailColors() {
        trail?.configure(style: trailStyle, trail: palette.trail, accent: palette.accent.alpha(1), dark: palette.isDark)
    }

    /// Controller đã chốt từ vuốt ⇒ "Pháo hoa cuối nét" bắn ở chỗ nhấc tay (kiểu khác: 0 việc).
    func swipeCommitted() { trail?.commitBurst() }

    /// Bước phím ngang (tâm q → tâm w), nil nếu chưa có layout chữ.
    private func letterKeyPitch() -> CGFloat? {
        guard letterKeys.count >= 2,
              let q = letterKeys.first(where: { $0.base == "q" })?.button,
              let w = letterKeys.first(where: { $0.base == "w" })?.button else { return nil }
        let d = convert(w.bounds, from: w).midX - convert(q.bounds, from: q).midX
        return d > 1 ? d : nil
    }

    /// Layout cho SwipeDecoder: tâm a–z theo toạ độ KeyboardView thật.
    func swipeLayout() -> SwipeLayout? {
        // Tách đôi: G/V lặp hai nửa + khe giữa — decoder vuốt (một tâm mỗi chữ) không dùng được.
        guard plane == .letters, !builtSplit, let kw = letterKeyPitch() else { return nil }
        var m: [Character: (x: Float, y: Float)] = [:]
        for (b, s) in letterKeys {
            guard s.count == 1, let c = s.first else { continue }
            let f = convert(b.bounds, from: b)
            m[c] = (Float(f.midX), Float(f.midY))
        }
        guard m.count == 26 else { return nil }
        return SwipeLayout(keyWidth: Float(kw), centers: m)
    }

    private func startClassifying(_ id: ObjectIdentifier, at p: CGPoint, time: TimeInterval,
                                  key: CGRect, keyWidth kw: CGFloat, since: TimeInterval?) {
        classifier = GestureClassifier(start: p, time: time, startKey: key, keyWidth: kw,
                                       sinceLastLetter: since)
        swipeTouchID = id
        let minD = Float(kw / 5)
        if swipePath?.minDistance != minD { swipePath = SwipePath(minDistance: minD) }
        swipePath?.reset()
        swipePath?.add(x: Float(p.x), y: Float(p.y), t: time)
    }

    private func stopClassifying() {
        classifier = nil
        if !swipeActive { swipeTouchID = nil }
    }

    /// Một điểm của ngón đang theo dõi. Trả true khi nét vuốt cần vẽ lại — người gọi (swipeMovedBatch)
    /// vẽ một lần cho cả lượt điểm gộp.
    private func swipeMoved(to raw: CGPoint, time: TimeInterval) -> Bool {
        let p = TouchGeometry.keySelectionPoint(raw)
        swipePath?.add(x: Float(p.x), y: Float(p.y), t: time)
        if swipeActive {
            Self.swipeSound?.move(x: Double(p.x), y: Double(p.y), t: time)   // cùng toạ độ swipePath (begin)
            trail?.add(raw, time)   // hạt (pháo hoa…) vẫn bắn theo từng điểm
            return trail != nil
        }
        guard var c = classifier else { return false }
        if keyCmd?.isCandidate == true { return false }    // vuốt-lên-lệnh còn sống ⇒ chưa quyết vuốt
        let d = c.move(to: p, time: time)
        classifier = c
        switch d {
        case .swipe: beginSwipe(redraw: false); return trail != nil
        case .tap: stopClassifying()
        case .undecided: break
        }
        return false
    }

    /// `redraw` false: đang trong một lượt điểm gộp — swipeMovedBatch vẽ một lần cuối lượt.
    private func beginSwipe(redraw: Bool = true) {
        swipeActive = true
        classifier = nil
        if let id = swipeTouchID { commits.disarm(id) }   // chữ đầu hoãn: bỏ, chưa từng chèn
        dropAltHold()
        hideBalloon()
        for b in routedTouches.values { (b as? KeyButton)?.showPressed(false) }   // vuốt: phím đầu thôi sẫm
        // Phím chữ đầu đã nhả shift một lần — trả lại để từ vuốt viết hoa đúng.
        if shiftBeforeLastLetter == .on, shift == .off { shift = .on; applyShiftAppearance() }
        swipeCase = shift == .caps ? .upper : (shift == .on ? .capitalized : .lower)
        onSwipeBegan?()
        if let s = Self.swipeSound, let path = swipePath, path.count > 0 {
            // Từ điểm chạm đầu, đưa nốt các điểm đã có: Nốt nhạc theo phím gảy cả phím bắt đầu + phím đi qua lúc phân loại.
            s.begin(x: Double(path.xs[0]), y: Double(path.ys[0]), t: path.ts[0])
            for j in 1..<path.count { s.move(x: Double(path.xs[j]), y: Double(path.ys[j]), t: path.ts[j]) }
        }
        guard trailStyle != .none else { return }
        let t = trail ?? SwipeTrailRenderer()
        if trail == nil {
            trail = t
            t.configure(style: trailStyle, trail: palette.trail, accent: palette.accent.alpha(1), dark: palette.isDark)
        }
        if trailStyle.usesKeys {   // Phím sáng theo đường / Ma trận: khung phím chữ (cache) — một lần mỗi cú vuốt
            let g = letterGeometry()
            t.setKeys(g.rects, g.chars, hitDy: TouchGeometry.yOffset)
        }
        t.begin(bounds: bounds)
        layer.addSublayer(t.layer)               // lên trên cùng
        if let path = swipePath {
            for i in 0..<path.count {
                t.add(CGPoint(x: CGFloat(path.xs[i]), y: CGFloat(path.ys[i]) + TouchGeometry.yOffset),
                      path.ts[i])
            }
        }
        if redraw { t.redraw() }
    }

    /// Nhấc tay: true nếu touch này là một cú vuốt (đã giao cho controller).
    private func swipeUp(_ id: ObjectIdentifier, at raw: CGPoint, time: TimeInterval) -> Bool {
        guard id == swipeTouchID else { return false }
        guard swipeActive, swipePath != nil else { stopClassifying(); return false }
        let p = TouchGeometry.keySelectionPoint(raw)
        swipePath?.add(x: Float(p.x), y: Float(p.y), t: time, force: true)
        guard let path = swipePath else { return false }
        let sc = swipeCase
        swipeActive = false
        swipeTouchID = nil
        classifier = nil
        trail?.fadeOut(reduceMotion: false)   // Giảm chuyển động KHÔNG tắt hiệu ứng (Phil 11/2026)
        if let ss = Self.swipeSound {          // điểm nhấc tay vào đo tốc độ, rồi tiếng nhấc tay (kiểu có)
            ss.move(x: Double(p.x), y: Double(p.y), t: time)
            ss.end(liftAt: time)
        }
        if shift == .on { shift = .off; applyShiftAppearance() }
        #if DEBUG
        debugSwipeUps += 1
        #endif
        onSwipeEnded?(path, sc)
        return true
    }

    private func cancelSwipeTracking() {
        swipeActive = false
        swipeTouchID = nil
        classifier = nil
        trail?.fadeOut(reduceMotion: true)
        Self.swipeSound?.end()
    }

    #if DEBUG
    var debugTrail: SwipeTrailRenderer? { trail }
    #endif

    private func tapped(_ key: Key) {
        snapInteracted = true   // đã gõ ⇒ không còn trạng thái mở đầu, không chụp ảnh lưới phím
        // Hiệu ứng khi bấm phím: lấy điểm đã đánh dấu (fxMark), chữ chèn TRƯỚC rồi mới hẹn vẽ.
        let fx = fxRect
        fxRect = nil
        if handleSearchKey(key) { return }
        onKey(key)
        KeystrokeCounter.tick()                  // tắt (mặc định) ⇒ đọc một hằng số
        if let f = beatFlash, Self.isBeatKey(key) { f.kick() }   // Sàn nhảy LED: flash nền ở phím cách; kiểu khác ⇒ nil
        if let fx {
            keyEffects?.emit(key: fx, isReturn: Self.isReturnKey(key))
            spotlight?.light(key: fx)            // Đèn rọi (theme "photoFx":"spotlight"): theme khác ⇒ nil
        }
        rainbow?.poke()                          // Gaming RGB: theme khác ⇒ nil, chỉ đọc một optional
        if let h = hueFill { h.poke(at: fx.map { CGPoint(x: $0.midX, y: $0.midY) }) }   // Ảo giác: nền đổi sắc + gợn sóng
        if let b = buddy {                       // Bạn đồng hành: tắt ⇒ nil, chỉ đọc một optional
            if case .backspace = key { b.deletePressed() } else { b.keyPressed() }
        }
        if let e = aiEye, let fx { e.keyPressed(at: CGPoint(x: fx.midX, y: fx.midY)) }   // Mắt AI: nhìn về phím vừa bấm
        keyFloat?.poke()                         // Lơ lửng (Lạc trôi / hiệu ứng "float"): khác ⇒ nil
        if let m = mole { m.typed(Self.moleLetter(key), at: CACurrentMediaTime()) }   // Đập chuột: theme khác ⇒ nil
    }

    // MARK: Bạn đồng hành (KeyboardBuddy*.swift) — Tắt / chưa Plus ⇒ nil: không view, không layer, 0 chi phí.
    private(set) var buddy: BuddyView?
    private var buddyTickleZoneMade = false
    private lazy var buddyTickleZone: UIControl = {
        buddyTickleZoneMade = true
        let v = UIControl(frame: .zero)
        v.accessibilityLabel = L("Cù bạn đồng hành")
        v.addAction(UIAction { [weak self] _ in
            self?.buddy?.tickle()
            self?.aiEye?.tickle()
            UIDevice.current.playInputClick()  // iOS tự im lặng khi tiếng click hệ thống tắt.
        }, for: .touchUpInside)
        addSubview(v)
        return v
    }()
    /// Ô nhân vật sát MÉP PHẢI (thanh gợi ý co lại đúng bấy nhiêu, 📋 / 😊 dời trái) — không đè chip gợi ý.
    static let buddyZoneWidth: CGFloat = 34
    private var buddyZone: CGFloat {
        buddy == nil && aiEye == nil ? 0 : CGFloat(buddyPlacement.zoneWidth(Double(Self.buddyZoneWidth)))
    }
    /// View đang đứng ở ô nhân vật (Bạn đồng hành hoặc Mắt AI) — vùng chạm "cù".
    private var buddyFigureView: UIView? { buddy ?? aiEye }

    // MARK: Mắt AI (AIEye.swift) — nhân vật "ai": cùng ô / công tắc / "Vị trí & cỡ" với Bạn đồng hành; khác ⇒ nil.
    private(set) var aiEye: AIEyeView?

    /// Khung VẼ Mắt AI — THUẦN để test: hình vuông cạnh = strip × AIEye.slotSize, TÂM DỌC = tâm dòng chữ gợi ý `rowMid`
    /// (nil ⇒ giữa strip), canh giữa ô chừa (không vượt mép phải), không vượt mép trên / không tràn xuống phím; cỡ / lề
    /// theo BuddyPlacement (neo đáy-phải như nhân vật, to hơn thì lớn dần xuống phím).
    static func aiEyeFrame(width: CGFloat, strip: CGFloat, rowMid: CGFloat? = nil, placement: BuddyPlacement = .standard,
                           height: CGFloat? = nil, dismiss: CGFloat = 0) -> CGRect {
        let zone = buddyZoneFrame(width: width, strip: strip, placement: placement, dismiss: dismiss)
        let slot = AIEye.slot(strip: Double(strip), rowMid: Double(rowMid ?? strip / 2))
        let s = CGFloat(slot.side)
        let base = BuddyRect(x: Double(min(zone.midX - s / 2, width - s)), y: slot.top, w: Double(s), h: Double(s))
        let f = placement.frame(standard: base, minWidth: Double(s), fullHeight: height.map(Double.init))
        return CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
    }

    /// Token AI: đích bay — tâm Mắt AI nếu đang hiện, không thì tâm dải gợi ý, không thì giữa mép trên (toạ độ view).
    func tokenTargetPoint() -> CGPoint {
        if let e = aiEye, !e.isHidden, e.bounds.width > 0 { return e.eyeCenter }
        let f = suggestionBar.frame
        if !suggestionBar.isHidden, f.width > 0, f.height > 0 { return CGPoint(x: f.midX, y: f.midY) }
        return CGPoint(x: bounds.midX, y: bounds.minY + 14)
    }
    /// "Vị trí & cỡ" (BuddyPlacement, chung mọi nhân vật) — đọc lúc hiện bàn phím.
    private var buddyPlacement = BuddyPlacement.standard

    /// Phần nhân vật tràn xuống hàng phím đầu (theo tỉ lệ strip) — chỉ là hình, không nhận chạm
    /// (BuddyView.isUserInteractionEnabled = false) nên phím bên dưới vẫn bấm bình thường.
    static let buddyOverlapRatio: CGFloat = 0.65

    /// Ô chừa cho nhân vật trong thanh gợi ý (chip gợi ý / 📋 / 😊 dời trái đúng bấy nhiêu) — sát mép phải,
    /// hoặc sát trái ⌄ ẩn bàn phím khi bật (`dismiss` = KeyboardDismissButton.rightInset).
    static func buddyZoneFrame(width: CGFloat, strip: CGFloat, placement: BuddyPlacement = .standard,
                               dismiss: CGFloat = 0) -> CGRect {
        let w = CGFloat(placement.zoneWidth(Double(buddyZoneWidth)))
        return CGRect(x: width - dismiss - w, y: 0, width: w, height: strip)
    }

    /// Khung VẼ nhân vật — THUẦN để test: cao strip + phần tràn xuống phím, rộng vuông (dáng ngủ nằm ngang không
    /// bị cắt), canh giữa ô chừa nhưng không vượt mép phải; được đè lên 📋 / phím (lớp trên cùng, không nhận chạm).
    /// Cỡ / lề (BuddyPlacement): neo đáy-phải khung cỡ gốc; to hơn thì lớn dần xuống phím (trần bàn phím không vẽ được).
    static func buddyFrame(width: CGFloat, strip: CGFloat, placement: BuddyPlacement = .standard,
                           height: CGFloat? = nil, dismiss: CGFloat = 0) -> CGRect {
        let zone = buddyZoneFrame(width: width, strip: strip, dismiss: dismiss)
        let h = (strip * (1 + buddyOverlapRatio)).rounded()
        let w = max(zone.width, h)
        let base = BuddyRect(x: Double(min(zone.midX - w / 2, width - w)), y: 0, w: Double(w), h: Double(h))
        let f = placement.frame(standard: base, minWidth: Double(zone.width), fullHeight: height.map(Double.init))
        return CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
    }

    /// Lúc hiện / đổi cài đặt: gắn hoặc gỡ nhân vật (cài đặt + Plus), nguồn điện thấp ⇒ chỉ dáng tĩnh.
    private func configureBuddy() {
        let c = BuddyPolicy.current(UserDefaultsProvider.shared)
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        if c == .off {
            buddy?.halt(); buddy?.removeFromSuperview(); buddy = nil
            aiEye?.halt(); aiEye?.removeFromSuperview(); aiEye = nil
            if buddyTickleZoneMade { buddyTickleZone.isHidden = true }
            return
        }
        // Vị trí & cỡ: chung mọi nhân vật — chỉ đổi khung (layout kế), không dựng lại view.
        let placementNow = BuddyPlacement.load(UserDefaultsProvider.shared)
        if placementNow != buddyPlacement { buddyPlacement = placementNow; setNeedsLayout() }
        // Mắt AI: view riêng (không khung hình / điệu nhảy) — 0 ảnh, dựng một lần.
        if c == .ai {
            buddy?.halt(); buddy?.removeFromSuperview(); buddy = nil
            if let e = aiEye { e.lowPower = low; return }
            let e = AIEyeView(lowPower: low)
            addSubview(e)
            aiEye = e
            setNeedsLayout()
            return
        }
        aiEye?.halt(); aiEye?.removeFromSuperview(); aiEye = nil
        // Trang phục mùa lễ: theme lễ đang dùng, không thì theo ngày (một lần lúc hiện, không mỗi phím).
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        let season = BuddySeason.resolve(themeID: themeSettings.effectiveTheme.rawValue,
                                         year: today.year ?? 0, month: today.month ?? 0, day: today.day ?? 0)
        // Kiểu vẽ riêng nhân vật (Hoạt hình mặc định / Vẽ nét) — đổi ⇒ dựng view mới, chỉ nạp tài nguyên kiểu đó.
        let style = BuddyStyle.load(UserDefaultsProvider.shared, c)
        let stamp = (today.year ?? 0) * 10_000 + (today.month ?? 0) * 100 + (today.day ?? 0)
        let hour = Calendar(identifier: .gregorian).component(.hour, from: Date())
        let part = BuddyClock.part(hour: hour, minute: 0)
        if let b = buddy, b.character == c, b.season == season, b.artStyle == style,
           b.appearanceDay == stamp, (style != .vector || season != nil || b.outfitClockPart == part) {
            b.lowPower = low
            b.setBar(palette.buddyBar)
            return
        }
        buddy?.halt(); buddy?.removeFromSuperview()
        // Ảnh atlas (PNG 1–1,6 MB) giải NỀN — khung đầu không chờ; ô trống tới khi xong (không lóe hình sai).
        let b = BuddyView(character: c, bar: palette.buddyBar, lowPower: low, season: season, artStyle: style,
                          asyncAtlas: true)
        b.onTimeChanged = { [weak self] in self?.configureBuddy() }
        addSubview(b)
        buddy = b
        setNeedsLayout()
    }

    private func layoutBuddy(stripOpen: Bool) {
        if let e = aiEye { layoutAIEye(e, stripOpen: stripOpen); return }
        guard let b = buddy else { return }
        let wasHidden = b.isHidden
        let zone = Self.buddyZoneFrame(width: bounds.width, strip: max(rowsTopWanted, openStripNow), placement: buddyPlacement,
                                       dismiss: dismissInset)
        buddyTickleZone.isHidden = !stripOpen
        buddyTickleZone.frame = zone
        bringSubviewToFront(buddyTickleZone)
        let show = stripOpen && bounds.width > 0
        b.isHidden = !show
        guard show else { b.halt(); return }
        if wasHidden { b.tick() }
        // Strip thật (rowsContainer bắt đầu ngay dưới); ô nhân vật tràn xuống hàng phím đầu (không nhận chạm).
        let strip = min(max(rowsTopWanted, openStripNow),
                        rowsContainer.frame.height > 0 ? rowsContainer.frame.minY : .greatestFiniteMagnitude)
        let f = Self.buddyFrame(width: bounds.width, strip: strip, placement: buddyPlacement, height: layoutHeight,
                                dismiss: dismissInset)
        if b.frame != f { b.frame = f }
        b.layer.zPosition = 1000   // trên cùng: không bị phím / popup / hiệu ứng đè hay chèn
        bringSubviewToFront(b)
    }

    private func layoutAIEye(_ e: AIEyeView, stripOpen: Bool) {
        let zone = Self.buddyZoneFrame(width: bounds.width, strip: max(rowsTopWanted, openStripNow), placement: buddyPlacement,
                                       dismiss: dismissInset)
        buddyTickleZone.isHidden = !stripOpen
        buddyTickleZone.frame = zone
        bringSubviewToFront(buddyTickleZone)
        let show = stripOpen && bounds.width > 0
        e.isHidden = !show
        guard show else { e.halt(); return }
        let strip = min(max(rowsTopWanted, openStripNow),
                        rowsContainer.frame.height > 0 ? rowsContainer.frame.minY : .greatestFiniteMagnitude)
        // Tâm dọc dòng chữ gợi ý: khung bar thật (layoutSuggestionBar chạy ngay trước), chưa có ⇒ công thức như bar.
        let bar = suggestionBar.frame
        let row = bar.height > 0 ? (y: bar.minY, h: bar.height) : suggestionRowSpan()
        let f = Self.aiEyeFrame(width: bounds.width, strip: strip, rowMid: row.y + row.h / 2, placement: buddyPlacement,
                                height: layoutHeight, dismiss: dismissInset)
        if e.frame != f { e.frame = f }
        e.layer.zPosition = 1000   // trên cùng như nhân vật (token bay VÀO mắt: lớp hiệu ứng ở dưới)
        bringSubviewToFront(e)
    }

    // MARK: Đập chuột (MoleGame.swift / MoleOverlay.swift) — chỉ theme có "game":"mole"; khác ⇒ nil (0 lớp, 0 việc).
    private(set) var mole: MoleOverlayView?
    /// Chữ đang soạn (controller: bridge.composedWord) — chỉ đọc lúc thả chuột.
    var moleWordPrefix: (() -> String)?

    /// Phím chữ ⇒ chữ thường a–z (ASCII); phím khác ⇒ nil. O(1), không cấp phát.
    @inline(__always) static func moleLetter(_ key: Key) -> Character? {
        guard case .letter(let c) = key, let a = c.asciiValue else { return nil }
        if a >= 65 && a <= 90 { return Character(Unicode.Scalar(a + 32)) }
        return a >= 97 && a <= 122 ? c : nil
    }

    /// Lúc hiện / đổi theme: gắn hoặc gỡ lớp chuột (trên hàng phím + hiệu ứng, không nhận chạm).
    private func configureMole() {
        let on = MolePolicy.active(game: themeSettings.effectiveKeyStyle.game,
                                   plus: PlusGate.isUnlocked(.premiumThemes),
                                   lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                   voiceOver: UIAccessibility.isVoiceOverRunning)
        KeySound.shared.setSqueakEnabled(on)
        guard on else {
            mole?.halt(); mole?.removeFromSuperview(); mole = nil
            return
        }
        let v = mole ?? MoleOverlayView()
        if v.superview !== self {
            addSubview(v)
            v.layer.zPosition = 6                 // trên phím + hiệu ứng (5), dưới ô phóng to (10)
        }
        v.shareCoordinateSpace(with: self)
        v.keyFrame = { [weak self, weak v] c in
            guard let self, let v, self.lettersLike, !self.rowsContainer.isHidden,
                  let b = self.letterKeys.first(where: { $0.base.count == 1 && $0.base.first == c })?.button,
                  !b.isHidden, b.bounds.width > 0, b.window != nil || self.window == nil else { return nil }
            return (b.convert(b.bounds, to: v), b.layer.cornerRadius)
        }
        v.context = { [weak self] in
            guard let self else { return ("", []) }
            let set = self.lastShownSet
            var words: [String] = []
            for w in [set?.word, set?.word2].compactMap({ $0 }) { words.append(w) }
            words += set?.moreWords ?? []
            words += set?.nextWords ?? []
            return (self.moleWordPrefix?() ?? "", words)
        }
        mole = v
    }

    #if DEBUG
    /// Test: khung phím chữ `s` theo toạ độ của chính view này.
    func debugMoleKeyFrame(_ c: Character) -> CGRect? { mole?.keyFrame?(c)?.rect }
    #endif

    // MARK: Đèn rọi (NightClub.swift) — chỉ theme có "photoFx":"spotlight"; khác ⇒ nil (0 lớp, 0 việc).
    private(set) var spotlight: SpotlightView?

    /// Lúc hiện / đổi theme: gắn hoặc gỡ lớp đèn rọi (trên nền / ảnh nền + lớp phủ, dưới hiệu ứng dải dưới + phím).
    private func configureSpotlight() {
        let on = SpotlightPolicy.active(photoFx: themeSettings.effectiveKeyStyle.photoFx,
                                        plus: PlusGate.isUnlocked(.premiumThemes),
                                        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        guard on else {
            spotlight?.halt(); spotlight?.removeFromSuperview(); spotlight = nil
            return
        }
        let v = spotlight ?? SpotlightView()
        if v.superview !== self {
            if wallpaperDim.superview === self { insertSubview(v, aboveSubview: wallpaperDim) }
            else { insertSubview(v, belowSubview: rowsContainer) }
        }
        v.shareCoordinateSpace(with: self)
        v.setCornerRadius(wallpaperView.layer.cornerRadius)
        // Người nhảy (không ảnh nền): chàng trai nếu Bạn đồng hành đang chọn chàng trai, còn lại cô gái.
        v.dancer = NightDancer.character(BuddyCharacter.load(UserDefaultsProvider.shared))
        v.setPhoto(wallpaperActive ? wallpaperView.image?.cgImage : nil)
        spotlight = v
    }

    // MARK: Viền phím cầu vồng (RainbowBorder.swift) — chỉ theme có "borderFx":"rainbow"; khác ⇒ nil (0 chi phí).
    private(set) var rainbow: RainbowBorderView?

    /// Lúc hiện / đổi theme: gắn hoặc gỡ lớp viền cầu vồng (trên hàng phím, dưới hiệu ứng / ô phóng to).
    private func configureRainbow() {
        configureHueFill()
        guard palette.rainbowBorder || palette.auroraBorder || palette.hueFlow else {
            rainbow?.halt(); rainbow?.removeFromSuperview(); rainbow = nil
            return
        }
        // AI ("aurora") / Ảo giác ("hueflow"): cùng lớp mặt nạ viền, bộ số khác — đổi kiểu ⇒ dựng view mới.
        let kind: RainbowBorderView.Kind = palette.auroraBorder ? .aurora : palette.hueFlow ? .hueflowBorder : .rainbow
        // Tự hào: viền tĩnh theo sọc cờ — đổi cờ ⇒ dựng view mới.
        if let r = rainbow, r.kind != kind || r.auroraColors != (kind == .aurora ? palette.auroraColors : nil) {
            r.halt(); r.removeFromSuperview(); rainbow = nil
        }
        let v = rainbow ?? RainbowBorderView(kind: kind, colors: palette.auroraColors)
        if v.superview !== self {
            v.frame = bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            insertSubview(v, aboveSubview: rowsContainer)
        }
        rainbow = v
        layoutRainbow()
    }

    /// Nền đổi sắc của "Ảo giác" ("borderFx":"hueflow" — HueFlow): ngay DƯỚI hàng phím (trên nền / hoạ tiết / ảnh nền), cả
    /// khung bàn phím; gợn sóng màu toả trong lớp này (sau phím). Theme khác ⇒ nil (0 chi phí).
    private(set) var hueFill: RainbowBorderView?
    private func configureHueFill() {
        // Ảnh nền người dùng thắng: không phủ sắc lên ảnh (Android y hệt).
        guard palette.hueFlow, !wallpaperActive else { hueFill?.halt(); hueFill?.removeFromSuperview(); hueFill = nil; return }
        let v = hueFill ?? RainbowBorderView(kind: .hueflowFill)
        if v.superview !== self {
            v.frame = bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            insertSubview(v, belowSubview: rowsContainer)
        }
        hueFill = v
    }

    /// Khung phím đang hiện → mặt nạ viền (chỉ dựng lại path khi khung đổi — RainbowBorderView.setKeys).
    private func layoutRainbow() {
        if let h = hueFill, h.frame != bounds { h.frame = bounds }
        guard let v = rainbow else { return }
        if v.frame != bounds { v.frame = bounds }
        var frames: [CGRect] = [], radii: [CGFloat] = []
        if snapState == .showing {
            // Khung đầu còn là ảnh: viền theo khung phím lưu kèm ảnh (phím thật chưa dựng).
            for o in snapOutlines { frames.append(rowsContainer.convert(o.rect, to: v)); radii.append(o.radius) }
        } else if !rowsContainer.isHidden {
            // Khung phím của lượt layout NÀY (hàng xếp lồng nhau — như hoạ tiết): đo sau khi hàng đã xếp.
            rowsContainer.layoutIfNeeded()
            for row in rowsContainer.arrangedSubviews where !row.isHidden { row.layoutIfNeeded() }
            func walk(_ x: UIView) {
                if let b = x as? KeyButton {
                    if !b.isHidden, b.bounds.width > 0 { frames.append(b.convert(b.bounds, to: v)); radii.append(b.layer.cornerRadius) }
                } else { x.subviews.forEach(walk) }
            }
            walk(rowsContainer)
        }
        v.setKeys(frames, radii: radii)
    }

    // MARK: Hiệu ứng khi bấm phím (KeyEffects.swift) — TẮT ⇒ overlay nil, đường phím chỉ đọc optional.
    private(set) var keyEffects: KeyEffectOverlay?
    /// Khung phím vừa chạm (toạ độ self) — chỉ ghi khi hiệu ứng bật; `tapped` tiêu thụ. Chỉ là TOẠ ĐỘ:
    /// hiệu ứng (vd mảnh vỡ của Tia sét) không bao giờ đụng tới view phím thật.
    private var fxRect: CGRect?
    @inline(__always) private func fxMark(_ v: UIView) {
        // Mắt AI cũng cần tâm phím (nhìn theo); Ảo giác: gợn sóng màu từ phím.
        guard keyEffects != nil || aiEye != nil || spotlight != nil || hueFill != nil else { return }
        fxRect = convert(v.bounds, from: v)
        // Phím sáng: chữ + phông đang hiện trên phím (kiểu khác ⇒ chỉ một phép so sánh).
        if let o = keyEffects, o.effect == .keyglow {
            let b = v as? KeyButton
            o.markGlowGlyph(b?.currentTitle, font: b?.titleFont)
        }
    }
    /// Overlay hiệu ứng dùng CHUNG hệ toạ độ với KeyboardView: khung = bounds, gốc bounds = gốc bounds
    /// của view (#151 dời gốc lên phần host cấp dư). Khung phím (fxRect, khe hàng) tính theo toạ độ view
    /// nên dùng thẳng được. Trước đây overlay giữ khung lúc gắn: gắn khi host đang cao tạm thời ⇒ gốc
    /// lệch mãi, tia sét / mảnh vỡ vẽ ra ngoài bàn phím (lên tận thanh trạng thái).
    private func syncKeyEffectsSpace() {
        beatFlash?.shareCoordinateSpace(with: self)
        guard let o = keyEffects else { return }
        KeyEffectOverlay.match(o, to: self)
    }

    // MARK: Sàn nhảy LED — flash nền ở phím cách (BeatFlashView). Kiểu khác ⇒ nil (0 view, 0 việc mỗi phím).
    private(set) var beatFlash: BeatFlashView?
    /// Phím kết thúc một từ (nhịp "BOOM" của âm Nhịp club) — chỉ những phím này flash.
    static func isBeatKey(_ k: Key) -> Bool {
        switch k {
        case .space, .doubleSpacePeriod: return true
        default: return false
        }
    }
    /// Phím Enter (Sút!: sút bóng từ phím này).
    static func isReturnKey(_ k: Key) -> Bool {
        switch k {
        case .newline, .lineBreak: return true
        default: return false
        }
    }
    /// Gắn / gỡ lớp flash: ngay DƯỚI hàng phím (trên nền / ảnh / đèn rọi / nhân vật), phủ trọn bàn phím.
    private func configureBeatFlash(_ on: Bool) {
        guard on else {
            beatFlash?.halt(); beatFlash?.removeFromSuperview(); beatFlash = nil
            keyEffects?.flashGate = nil
            return
        }
        let v = beatFlash ?? BeatFlashView()
        if let i = subviews.firstIndex(of: v), let k = subviews.firstIndex(of: rowsContainer), i == k - 1 {
            // đã đúng chỗ
        } else {
            v.removeFromSuperview()
            insertSubview(v, belowSubview: rowsContainer)
        }
        v.shareCoordinateSpace(with: self)
        beatFlash = v
        keyEffects?.flashGate = v.gate   // nháy cả bàn phím dùng chung cổng ≤ 3 lần / giây
    }
    /// Đọc cài đặt lúc hiện (applyAppearance): kiểu + cổng Plus + nguồn điện thấp + giảm chuyển động.
    private func configureKeyEffects() {
        // Matrix / Mực loang / Sóng nước: dải DƯỚI phím (ngay dưới rowsContainer, trên nền / ảnh nền).
        // Theme JSON: hạt ("Theo giao diện") + từ khoá tự tạo của theme đang dùng — theme không có ⇒ nil (0 chi phí).
        keyEffects = KeyEffectOverlay.install(KeyEffectPolicy.current(UserDefaultsProvider.shared),
                                              color: palette.accent.alpha(1).ui, keyFill: palette.keyFill.ui,
                                              dark: palette.isDark, in: self, keys: rowsContainer, existing: keyEffects,
                                              themeFx: ThemeFxPolicy.current(themeSettings.effectiveSpec))
        if keyEffects == nil { fxRect = nil }
        // Laser: tia bắn từ phím cách thật (khung đọc lúc bắn — đổi bàn số / ký hiệu vẫn đúng). Kiểu khác ⇒ nil.
        // Công đức: cùng khung phím cách làm chỗ đặt nhãn "Công đức hôm nay" (góc trên-trái phím cách).
        let spaceAnchored = keyEffects?.effect == .laser || keyEffects?.effect == .merit
        keyEffects?.laserOrigin = spaceAnchored ? { [weak self] in self?.spaceBarFrame() } : nil
        // Công đức: bộ đếm trong ngày lưu App Group (chỉ một số đếm). Kiểu khác ⇒ nil.
        keyEffects?.meritStore = keyEffects?.effect == .merit ? MeritStore.defaults(UserDefaultsProvider.shared) : nil
        // Token AI: đích bay đọc lúc bắn (Mắt AI / dải gợi ý có thể đổi chỗ). Kiểu khác ⇒ nil.
        keyEffects?.tokenTarget = keyEffects?.effect == .tokens ? { [weak self] in self?.tokenTargetPoint() } : nil
        // Biển: mỗi con sóng mới một tiếng sóng vỗ (chỉ khi Âm thanh phím bật). Buffer chỉ dựng khi Biển được chọn.
        let sea = keyEffects?.effect == .sea
        let goal = keyEffects?.effect == .goal
        // Tiếng sự kiện (một buffer + 2 node riêng): sóng vỗ (Biển) / hò reo (Sút!). Kiểu khác ⇒ nhả.
        KeySound.shared.setEventSound(sea ? .surf : goal ? .cheer : nil)
        keyEffects?.onSeaWave = sea ? { Self.seaSurf(size: $0) } : nil
        keyEffects?.onThemeEvent = goal ? { Self.goalCheer() } : nil
        // Cho cá ăn: bộ đếm thức ăn theo máy (App Group) — kiểu khác ⇒ nil.
        keyEffects?.themeDefaults = keyEffects?.effect == .fishfeed ? UserDefaultsProvider.shared : nil
        configureBeatFlash(keyEffects?.effect == .dancefloor)
        // Chòm sao: cung người dùng chọn (đọc cùng ThemeSettings lúc hiện — 0 chi phí mỗi phím).
        if keyEffects?.effect == .constellation { keyEffects?.zodiacSign = themeSettings.variantChoice.zodiac }
        // Cầu vồng: màu theo lá cờ người dùng chọn (theme Tự hào).
        if keyEffects?.effect == .rainbowburst { keyEffects?.prideFlag = themeSettings.variantChoice.pride }
        syncKeyEffectsSpace()
        layoutStringGaps()
        configureKeyFloat()
    }

    // MARK: Lơ lửng (Drift.swift) — hiệu ứng "float" hoặc theme "keyMotion":"float"; khác ⇒ nil (0 animation, 0 việc).
    private(set) var keyFloat: KeyFloat?
    private func configureKeyFloat() {
        let on = FloatPolicy.active(effect: keyEffects?.effect ?? .none,
                                    keyMotion: themeSettings.effectiveKeyStyle.keyMotion,
                                    plus: PlusGate.isUnlocked(.premiumThemes),
                                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if on {
            if keyFloat == nil { keyFloat = KeyFloat(target: rowsContainer) { $0 is KeyButton } }
        } else {
            keyFloat?.halt(); keyFloat = nil
        }
    }

    #if DEBUG
    /// Test: số lần xin phát tiếng sóng vỗ (đã qua công tắc Âm thanh phím).
    nonisolated(unsafe) static var debugSurfs = 0
    #endif
    /// Một con sóng mới của hiệu ứng Biển: tiếng sóng vỗ CHỈ khi Âm thanh phím (đường riêng) bật — to hơn chút khi sóng to.
    static func seaSurf(size: Double) {
        guard SeaFx.shouldSurf(customSound: customSoundEnabled) else { return }
        #if DEBUG
        debugSurfs += 1
        #endif
        KeySound.shared.playSurf(volume: Float(SeaFx.surfVolume(size: size)))
    }

    #if DEBUG
    /// Test: số lần xin phát tiếng hò reo (đã qua công tắc Âm thanh phím).
    nonisolated(unsafe) static var debugCheers = 0
    #endif
    /// Một cú sút của Sút!: tiếng hò reo CHỈ khi Âm thanh phím (đường riêng) bật.
    static func goalCheer() {
        guard customSoundEnabled else { return }
        #if DEBUG
        debugCheers += 1
        #endif
        KeySound.shared.playSurf(volume: Float(KeySoundSynth.cheerVolume))
    }

    /// Khung phím cách chính theo toạ độ view (= toạ độ overlay hiệu ứng) — nil khi plane không có / chưa xếp.
    private func spaceBarFrame() -> CGRect? {
        guard let s = spaceBar, s.window != nil, !s.isHidden, s.bounds.width > 0 else { return nil }
        return convert(s.bounds, from: s)
    }

    #if DEBUG
    /// Test hook: đi một vòng sang plane số rồi về chữ (về từ planeCache).
    func debugCycleThroughNumbers() {
        plane = .numbers; rebuild()
        plane = .letters; rebuild()
    }
    /// Test hook: chạm ☰ (burgerZone — bật/tắt mẫu câu), đúng đường người dùng.
    func debugTapBurger() { toggleTemplates() }
    /// Test hook: mở mẫu câu rồi về chữ (đường của bug 26/09/2026).
    func debugCycleThroughTemplates() {
        plane = .templates; rebuild(); layoutIfNeeded()
        plane = .letters; rebuild()
    }
    /// Test hook: mô phỏng chạm ⌫ tại x, kéo qua các điểm `xs`, rồi nhấc tay.
    /// Trả về nhãn xem trước sau điểm cuối (nil = không hiện).
    @discardableResult
    func debugBackspaceSwipe(from x0: CGFloat, through xs: [CGFloat]) -> String? {
        onBackspaceTouchDown?()
        backspaceSwipeBegan(x: x0)
        tapped(.backspace)
        for x in xs { backspaceSwipeMoved(x: x) }
        let label = wordSwipePill?.isHidden == false ? wordSwipePill?.text : nil
        backspaceSwipeEnded()
        return label
    }
    /// Test hook: payload 3 slot chính đang hiện (nil = ẩn).
    /// Test hook: nút slot `i` (chạm xuống/nhấc tay bằng sendActions).
    func debugSlotControl(_ i: Int) -> UIControl { slotButtons[i] }
    /// Test hook: chữ 3 slot đang hiện (nil = ẩn).
    func debugSlotTitles() -> [String?] {
        zip(slotButtons, suggestionBar.labels).prefix(suggestionBar.shownCells).map { $0.isHidden ? nil : $1.text }
    }
    func debugSlotPayloads() -> [String?] {
        slotButtons.prefix(suggestionBar.shownCells).map { $0.isHidden ? nil : $0.payload }
    }
    /// Test hook thanh gợi ý: frame (toạ độ KeyboardView) của 3 ô slot + 2 vạch ngăn,
    /// frame chữ các slot đang HIỆN (hiện thật = không ẩn và bar alpha > 0), thẻ Dán.
    func debugSuggestionGeometry() -> (cells: [CGRect], dividers: [CGRect],
                                        visibleTitles: [CGRect], pasteCard: CGRect?) {
        layoutIfNeeded()
        let cells = suggestionBar.cellFrames.map { convert($0, from: suggestionBar) }
        let divs = slotDividers.prefix(max(suggestionBar.shownCells - 1, 0)).map { convert($0.bounds, from: $0) }
        let barShown = !suggestionBar.isHidden && suggestionBar.alpha > 0
        var titles: [CGRect] = []
        let shown = Array(zip(slotButtons, suggestionBar.labels.map { $0 as UILabel? }))
            + Array(zip(emojiButtons, emojiButtons.map(\.titleLabel)))
        for (b, l) in shown where barShown && !b.isHidden && !(l?.text ?? "").isEmpty {
            b.layoutIfNeeded()
            if let l { titles.append(convert(l.bounds, from: l)) }
        }
        // Emoji vẽ bằng ảnh atlas: khung ảnh thay khung chữ.
        for (i, b) in emojiButtons.enumerated() where barShown && !b.isHidden {
            if let v = suggestionBar.emojiImages[i], !v.isHidden, v.image != nil { titles.append(convert(v.bounds, from: v)) }
        }
        let card = pasteCardMade && pasteCard.superview != nil && !pasteCard.isHidden ? pasteCard.frame : nil
        return (cells, divs, titles, card)
    }
    /// Test hook dải gợi ý: frame bar, nút 📋 (nil = ẩn/chưa tạo), ô slot.
    /// `slots`/`dividers`: frame (toạ độ KeyboardView) các ô / vạch ngăn đang HIỆN.
    func debugStripLayout() -> (bar: CGRect, clip: CGRect?, cells: [CGRect],
                                slots: [CGRect], dividers: [CGRect]) {
        layoutIfNeeded()
        let clip: CGRect? = clipZoneMade && !clipZone.isHidden ? clipZone.frame : nil
        return (suggestionBar.frame, clip,
                suggestionBar.cellFrames.map { convert($0, from: suggestionBar) },
                slotButtons.filter { !$0.isHidden }.map { convert($0.bounds, from: $0) },
                slotDividers.filter { !$0.isHidden }.map { convert($0.bounds, from: $0) })
    }
    /// Test hook căn dọc thanh gợi ý: tâm y (toạ độ view) vùng nội dung ☰ / 📋 / 😊 đang hiện,
    /// tâm hàng bar, và đỉnh phím hàng đầu (dải người dùng thấy = 0…capTop).
    func debugBarVerticalCenters() -> (bar: CGFloat, icons: [String: CGFloat], capTop: CGFloat) {
        layoutIfNeeded()
        func mid(_ b: UIButton) -> CGFloat { b.frame.minY + b.bounds.inset(by: b.contentEdgeInsets).midY }
        var icons: [String: CGFloat] = [:]
        if burgerZoneMade, !burgerZone.isHidden { icons["burger"] = mid(burgerZone) }
        if clipZoneMade, !clipZone.isHidden { icons["clip"] = mid(clipZone) }
        if emojiZoneMade, !emojiZone.isHidden { icons["emoji"] = mid(emojiZone) }
        return (suggestionBar.frame.midY, icons, rowsContainer.frame.minY + rowSpec.gap)
    }
    /// Test hook: mô phỏng rebuild (đổi plane / xoay) — đường từng đặt lại alpha bar.
    func debugRefreshChrome() { updateSuggestionChrome() }
    /// Test hook trackpad: chạy đúng đường began/moved/frame/ended với thời gian giả;
    /// `frameEvery` = số touch event giữa 2 frame (120Hz touch / 60Hz màn = 2).
    /// `coalesce: false` mô phỏng hành vi cũ (mỗi bước gửi ngay).
    func debugTrackpadDrag(_ pts: [(x: CGFloat, y: CGFloat, t: CFTimeInterval)],
                           frameEvery: Int = 2, coalesce: Bool = true) {
        guard let first = pts.first else { return }
        trackpadBegan(CGPoint(x: first.x, y: first.y), t: first.t)
        for (i, e) in pts.dropFirst().enumerated() {
            trackpadMoved(CGPoint(x: e.x, y: e.y), t: e.t)
            if !coalesce || (i + 1) % max(frameEvery, 1) == 0 { trackpadFrame() }
        }
        trackpadEnded()
    }
    var debugTrackpadDimmed: Bool { trackpadDimmed }
    /// Test hook: giữ phím cách vào trackpad / nhả (không kéo).
    func debugTrackpadBegin() { trackpadBegan(.zero, t: CACurrentMediaTime()) }
    func debugTrackpadEnd() { trackpadEnded() }
    func debugSetKeyPreview(_ on: Bool) { keyPreviewEnabled = on }
    func debugShowEmojiPlane() { plane = .emoji; rebuild() }
    /// Test hook: chạm ABC của plane emoji (đường onABC thật).
    func debugEmojiABC() {
        (rowsContainer.arrangedSubviews.first { $0 is EmojiPlane } as? EmojiPlane)?.onABC?()
    }
    /// Test hook: frame phím emoji (toạ độ self) ở hàng đáy plane đang hiện.
    var debugEmojiKeyFrame: CGRect? { debugControl("Emoji").map { convert($0.bounds, from: $0) } }
    var debugBalloonVisible: Bool { balloonMade && !balloon.isHidden && balloon.superview?.superview != nil }
    /// Test hook: một touch chữ chạm tại `p0`, kéo qua `points` (cách nhau `dt` giây),
    /// nhấc tay ở điểm cuối — đi đúng đường router (routeDown → swipeMoved → routeUp).
    /// Trả true nếu touch thành vuốt. `coalesced` n: mỗi lượt touchesMoved mang n điểm gộp (cảm ứng
    /// 120 Hz trên màn 60 Hz ⇒ 2) — cùng đường swipeMovedBatch như touchesMoved thật.
    @discardableResult
    func debugTouch(from p0: CGPoint, through points: [CGPoint], dt: TimeInterval = 0.016,
                    start t0: TimeInterval, coalesced: Int = 1) -> Bool {
        let token = NSObject()
        let id = ObjectIdentifier(token)
        routeDown(id, at: p0, time: t0, batch: 1)
        var t = t0
        var swiped = false
        let n = max(coalesced, 1)
        for start in stride(from: 0, to: points.count, by: n) {
            let chunk = points[start..<min(start + n, points.count)]
            var samples: [(CGPoint, TimeInterval)] = []
            for p in chunk { t += dt; samples.append((p, t)) }
            if keyCmdTouchID == id, let last = chunk.last { keyCommandMoved(to: last) }
            if swipeTouchID == id { swipeMovedBatch(samples) }
            if swipeActive { swiped = true }
        }
        let ups = debugSwipeUps
        routeUp(id, at: points.last ?? p0, time: t, cancelled: false)
        withExtendedLifetime(token) {}
        return swiped || debugSwipeUps != ups   // vuốt có thể được quyết lúc nhấc (vuốt-lên-lệnh)
    }
    /// Test hook giữ phím ký tự phụ: chạm tâm phím `s`, trôi `drift` pt, (tuỳ) hết giờ giữ
    /// (gọi thẳng như timer bắn), rồi nhấc — đường router thật. Trả có hẹn giờ không.
    @discardableResult
    func debugHold(_ s: String, drift: CGFloat = 0, fire: Bool = true, secondTouch: String? = nil) -> Bool {
        guard let f = debugLetterFrame(s) else { return false }
        let token = NSObject(), id = ObjectIdentifier(token)
        let c = CGPoint(x: f.midX, y: f.midY)
        routeDown(id, at: c, time: 1, batch: 1)
        let armed = altHold != nil
        if drift > 0, let h = altHold, h.id == id, altHold?.hold.move(to: CGPoint(x: c.x + drift, y: c.y)) == true {
            dropAltHold()
        }
        if fire { altTimer?.cancel(); fireAltHold() }
        if let s2 = secondTouch, let f2 = debugLetterFrame(s2) {
            let t2 = NSObject(), id2 = ObjectIdentifier(t2)
            routeDown(id2, at: CGPoint(x: f2.midX, y: f2.midY), time: 1.1, batch: 1)
            routeUp(id2, at: CGPoint(x: f2.midX, y: f2.midY), time: 1.2, cancelled: false)
            withExtendedLifetime(t2) {}
        }
        routeUp(id, at: CGPoint(x: c.x + drift, y: c.y), time: 2, cancelled: false)
        withExtendedLifetime(token) {}
        return armed
    }
    /// Test hook "Vuốt phím xuống ra ký tự phụ": chạm giữa phím `s`, nhấc ở điểm lệch (dx, dy).
    func debugFlickDown(_ s: String, dx: CGFloat = 0, dy: CGFloat) {
        guard let f = debugLetterFrame(s) else { return }
        let token = NSObject(), id = ObjectIdentifier(token)
        let c = CGPoint(x: f.midX, y: f.midY)
        routeDown(id, at: c, time: 1, batch: 1)
        if let h = altHold, h.id == id, altHold?.hold.move(to: CGPoint(x: c.x + dx, y: c.y + dy)) == true {
            dropAltHold()
        }
        routeUp(id, at: CGPoint(x: c.x + dx, y: c.y + dy), time: 1.15, cancelled: false)
        withExtendedLifetime(token) {}
    }
    /// Test hook giữ phím "," hàng đáy: chạm, (tuỳ) hết giờ giữ, (tuỳ) ngón khác chạm phím chữ
    /// `secondTouch`, rồi nhấc — đường action thật của nút. Trả có hẹn giờ không.
    @discardableResult
    func debugCommaHold(fire: Bool = true, secondTouch: String? = nil, secondBeforeFire: Bool = false) -> Bool {
        guard let b = debugCommaButton else { return false }
        b.sendActions(for: .touchDown)
        let armed = commaTimer != nil
        func second() {
            guard let s2 = secondTouch, let f2 = debugLetterFrame(s2) else { return }
            let t2 = NSObject(), id2 = ObjectIdentifier(t2)
            routeDown(id2, at: CGPoint(x: f2.midX, y: f2.midY), time: 1.1, batch: 1)
            routeUp(id2, at: CGPoint(x: f2.midX, y: f2.midY), time: 1.2, cancelled: false)
            withExtendedLifetime(t2) {}
        }
        if secondBeforeFire { second() }
        if fire, armed { commaTimer?.cancel(); fireCommaHold(b, alt: spaceSideKey.holdAlt ?? KeyAlternates.commaAlt) }   // như timer bắn
        if !secondBeforeFire { second() }
        b.sendActions(for: .touchUpInside)
        return armed
    }
    /// Test hook giữ phím "." ô địa chỉ/URL/email: chạm tâm phím, (tuỳ) hết giờ giữ, trượt
    /// (dx, dy), (tuỳ) ngón khác chạm phím chữ, rồi nhấc — đường action thật. Trả có hẹn giờ không.
    @discardableResult
    func debugDomainHold(_ title: String, fire: Bool = true, dx: CGFloat = 0, dy: CGFloat = 0,
                         secondTouch: String? = nil, keepOpen: Bool = false) -> Bool {
        guard let b = debugButton(title) else { return false }
        let key = convert(b.bounds, from: b)
        domainLastPoint = CGPoint(x: key.midX, y: key.midY)
        b.sendActions(for: .touchDown)
        let armed = domainTimer != nil
        if fire, armed {
            domainTimer?.cancel()
            let tlds = DomainPopup.choices(kind: inputKind, key: title, lettersPlane: plane == .letters)
            if tlds.isEmpty {
                fireDomainHold(b, choices: KeyVariants.variants(
                    for: title, symbolPlane: plane == .numbers || plane == .symbols,
                    numericField: inputKind == .number), variants: true)
            } else {
                fireDomainHold(b, choices: tlds)
            }
        }
        if dx != 0 || dy != 0 { domainMoved(to: CGPoint(x: key.midX + dx, y: key.midY + dy)) }
        if let s2 = secondTouch, let f2 = debugLetterFrame(s2) {
            let t2 = NSObject(), id2 = ObjectIdentifier(t2)
            routeDown(id2, at: CGPoint(x: f2.midX, y: f2.midY), time: 1.1, batch: 1)
            routeUp(id2, at: CGPoint(x: f2.midX, y: f2.midY), time: 1.2, cancelled: false)
            withExtendedLifetime(t2) {}
        }
        if !keepOpen { b.sendActions(for: .touchUpInside) }
        return armed
    }
    #if DEBUG
    /// Test (KeyboardRenderBudgetTests): bấm phím đổi mặt phím (123 ⇄ ABC) như ngón thật.
    @discardableResult
    func debugTapPlaneKey() -> Bool {
        func find(_ v: UIView) -> KeyButton? {
            if let b = v as? KeyButton, b.accessibilityLabel == L("Số") || b.accessibilityLabel == L("Chữ") { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        guard let b = find(rowsContainer) else { return false }
        b.sendActions(for: .touchDown)
        b.sendActions(for: .touchUpInside)
        return true
    }
    /// Chỉ chạm xuống phím 123 (nút bị gỡ ngay, không bao giờ nhận nhấc — bug 1.2.31).
    func debugPressPlaneKeyDownOnly() -> Bool {
        func find(_ v: UIView) -> KeyButton? {
            if let b = v as? KeyButton, b.accessibilityLabel == L("Số") || b.accessibilityLabel == L("Chữ") { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        guard let b = find(rowsContainer) else { return false }
        b.sendActions(for: .touchDown)
        return true
    }
    var debugCarriedPressActive: Bool { carriedPress != nil }
    var debugCarriedPressShown: Bool { carriedPress?.pressShown ?? false }
    #endif
    private func debugButton(_ title: String) -> KeyButton? {
        func find(_ v: UIView) -> KeyButton? {
            if let b = v as? KeyButton, b.currentTitle == title { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return find(rowsContainer)
    }
    /// Test hook vuốt phím dấu câu `title` hàng đáy: chạm, trượt (dx, dy), nhấc — đường thật.
    func debugPunctFlick(_ title: String, dx: CGFloat, dy: CGFloat) {
        func find(_ v: UIView) -> KeyButton? {
            if let b = v as? KeyButton, b.currentTitle == title { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        guard let b = find(rowsContainer) else { return }
        b.sendActions(for: .touchDown)
        let c = convert(b.bounds, from: b)
        punctFlickStart = (ObjectIdentifier(b), CGPoint(x: c.midX, y: c.midY))
        punctFlickMoved(b, to: CGPoint(x: c.midX + dx, y: c.midY + dy))
        b.sendActions(for: .touchUpOutside)
    }
    private var debugCommaButton: KeyButton? {
        func find(_ v: UIView) -> KeyButton? {
            if let b = v as? KeyButton, b.currentTitle == (spaceSideKey.char ?? ",") { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return find(rowsContainer)
    }
    /// Nhãn "." nhỏ trên phím "," (Dấu chấm: nhãn "," trên phím "."; nil = không có nhãn).
    var debugCommaHint: String? {
        guard let b = debugCommaButton else { return nil }
        return b.subviews.compactMap { ($0 as? UILabel) }.first { $0 !== b.titleLabel }?.text
    }
    /// Nhãn ký tự phụ đang vẽ trên phím chữ `s` (nil = không có nhãn).
    func debugAltHint(_ s: String) -> String? {
        guard let b = letterKeys.first(where: { $0.base == s })?.button else { return nil }
        return b.subviews.compactMap { ($0 as? UILabel) }.first { $0 !== b.titleLabel }?.text
    }
    /// Test hook: vào chế độ tìm emoji (như bấm 🔍), gõ từng phím chữ/space qua
    /// đường tapped thật; trả (query, kết quả đang hiện).
    func debugEmojiSearch(_ keys: [Key]) -> (query: String, results: [String]) {
        emojiSearch.clear()
        plane = .emojiSearch; rebuild()
        for k in keys { tapped(k) }
        return (emojiSearch.query, searchBar?.shownResults ?? [])
    }
    var debugInEmojiSearch: Bool { plane == .emojiSearch }
    /// Test hook: màn hình giả (máy gập mở 951×669…) cho KeyLayout.phoneForm khi view chưa có window.
    var debugScreenSize: CGSize? { didSet { phoneFormCache = nil; lastLayoutWidth = -1; setNeedsLayout() } }
    /// Test hook: safe area đáy giả (vạch home máy gập mở = 18).
    func debugSetSafeBottom(_ v: CGFloat) {
        debugSafeOverride = v
        syncSafeBottom()
    }
    private(set) var debugSafeOverride: CGFloat?
    /// Test hook: mọi stack hàng phím (kể cả nửa tách đôi) — kiểm tra không ăn safe area vào lề.
    var debugRowStacks: [KeyRow] {
        var out: [KeyRow] = []
        func walk(_ v: UIView, depth: Int) {
            guard depth < 4 else { return }
            for c in v.subviews { if let st = c as? KeyRow { out.append(st) }; walk(c, depth: depth + 1) }
        }
        walk(rowsContainer, depth: 0)
        return out
    }
    /// Test hook: bật/tắt bàn tách đôi (như công tắc App Group) rồi dựng lại.
    func debugSetSplit(_ on: Bool) { splitSetting = on; rebuild() }
    /// Test hook: plane đang hiện dựng kiểu tách đôi.
    var debugIsSplit: Bool { builtSplit }
    /// Test hook: số phím chữ (kể cả G/V lặp) + có layout gõ vuốt không.
    var debugLetterKeyCount: Int { letterKeys.count }
    /// Test hook: chế độ một tay đang thu hẹp vùng phím.
    var debugOneHandActive: Bool { oneHandActive }
    /// Test hook: frame các hàng của plane đang hiện (toạ độ self).
    func debugRowFrames() -> [CGRect] {
        rowsContainer.arrangedSubviews.map { convert($0.bounds, from: $0) }
    }
    /// Test hook: plane chữ ↔ số.
    func debugSetPlane(numbers: Bool) {
        plane = numbers ? .numbers : .letters; rebuild()
    }
    /// Test hook: dấu hiệu trên phím cách — "logo", mã "VI"/"EN", nil = không có.
    func debugSpaceMark() -> String? {
        if let c = spaceCode, c.superview != nil { return c.text }
        if let l = spaceLogo, l.superview != nil { return "logo" }
        return nil
    }
    /// Test hook: button phím text (hàng số / plane số) theo nhãn, trong plane đang hiện.
    func debugKeyButton(_ title: String) -> KeyButton? {
        func find(_ v: UIView) -> KeyButton? {
            if let b = v as? KeyButton, !b.isSpecial, b.currentTitle == title { return b }
            for s in v.subviews { if let r = find(s) { return r } }
            return nil
        }
        return rowsContainer.arrangedSubviews.lazy.compactMap(find).first
    }
    /// Test hook: mọi nút phím (KeyButton) đang dựng trong plane hiện tại, theo thứ tự cây view.
    func debugAllKeyButtons() -> [KeyButton] {
        var out: [KeyButton] = []
        func walk(_ v: UIView) {
            if let b = v as? KeyButton { out.append(b); return }
            v.subviews.forEach(walk)
        }
        walk(rowsContainer)
        return out
    }
    /// Test hook: nền hiện tại / nền thường / nền khi đè của một nút phím.
    func debugKeyColors(_ b: KeyButton) -> (current: UIColor?, normal: UIColor?, pressed: UIColor?) {
        let k = b as? KeyButton
        return (b.backgroundColor, k?.normalBackground, k?.pressedBackground)
    }
    /// Test hook: lớp skin + ảnh đang hiện của một nút phím (nil = không skin).
    func debugSkinContents(_ b: KeyButton) -> AnyObject? {
        (b as? KeyButton)?.debugSkinLayer?.contents as AnyObject?
    }
    func debugSkinLayer(_ b: KeyButton) -> CALayer? { (b as? KeyButton)?.debugSkinLayer }
    /// Test hook: đè / nhả một nút (đường press/release thật).
    func debugPress(_ b: KeyButton, _ on: Bool) {
        guard let k = b as? KeyButton else { return }
        if on { k.press() } else { k.showPressed(false) }
    }
    /// Test hook: các phím đang hiện nền đè (sẫm), theo thứ tự cây view.
    func debugPressedKeys() -> [KeyButton] {
        var out: [KeyButton] = []
        func walk(_ v: UIView) {
            if let b = v as? KeyButton, b.pressShown, b.backgroundColor == b.pressedBackground { out.append(b) }
            v.subviews.forEach(walk)
        }
        walk(rowsContainer)
        return out
    }
    /// Test hook: phím đang chờ thôi sẫm trễ (touch sát mép giao began + ended một lượt).
    func debugReleasePending(_ b: KeyButton) -> Bool { (b as? KeyButton)?.releasePending ?? false }
    /// Test hook: nút phím chữ `s` (router điều phối, không nhận touch trực tiếp).
    func debugLetterButton(_ s: String) -> KeyButton? { letterKeys.first { $0.base == s }?.button }
    /// Test hook: frame balloon đang hiện (toạ độ self), nil nếu ẩn.
    var debugBalloonFrame: CGRect? { debugBalloonVisible ? balloon.frame : nil }
    /// Test hook: frame nút rail một tay đang hiện (toạ độ self).
    func debugRailFrames() -> [CGRect] {
        railButtons.filter { !$0.isHidden }.map { $0.frame }
    }
    /// Test hook: bấm nút rail (0 = đổi bên, 1 = thoát).
    func debugTapRail(_ i: Int) {
        railButtons[i].sendActions(for: .touchUpInside)
    }
    /// Test hook: giữ lâu burger (bật/tắt một tay).
    func debugHoldBurger() { toggleOneHandFromKeyboard() }
    /// Test hook: hitTest như một touch thật ở thời điểm `time` (giây, cùng trục với
    /// debugTouch `start`) — để test dải gõ cuộn (thời gian từ chữ trước).
    func debugHitTest(_ p: CGPoint, time: TimeInterval) -> UIView? {
        routedHitTest(p, with: nil, time: time)
    }
    /// Test hook: chạm / nhấc một touch router riêng lẻ (lăn ngón: giữ chữ rồi chạm phím khác).
    func debugRouteDown(_ id: ObjectIdentifier, at p: CGPoint, time: TimeInterval) {
        routeDown(id, at: p, time: time, batch: 1)
    }
    func debugRouteUp(_ id: ObjectIdentifier, at p: CGPoint, time: TimeInterval) {
        routeUp(id, at: p, time: time, cancelled: false)
    }
    /// Test hook trượt 123 (#171): chạm "123" như nút thật (đổi plane lúc chạm), theo dõi trượt
    /// không cần UITouch. false nếu không có phím 123 / không sang plane số.
    @discardableResult
    func debugPlaneSlideBegin() -> Bool {
        func find(_ v: UIView) -> KeyButton? {
            if let b = v as? KeyButton, b.isSpecial, b.currentTitle == "123" { return b }
            for s in v.subviews { if let r = find(s) { return r } }
            return nil
        }
        guard let b = rowsContainer.arrangedSubviews.lazy.compactMap(find).first else { return false }
        b.sendActions(for: .touchDown)
        guard plane == .numbers else { return false }
        startPlaneSlide(touch: nil)
        return true
    }
    func debugPlaneSlideMove(to p: CGPoint) { planeSlideMove(to: p) }
    func debugPlaneSlideLift(at p: CGPoint, cancelled: Bool = false) { endPlaneSlide(at: p, cancelled: cancelled) }
    func debugPlaneSlideSecondTouch() { if planeSlide != nil { planeSlideSecondTouch() } }
    var debugPlaneSlideActive: Bool { planeSlide != nil }
    /// Ký tự của phím đang sẫm dưới ngón trượt (nil = không có).
    var debugPlaneSlideOver: String? { planeSlide?.over?.slideInsert }
    /// Test hook: touch router đang đè bị hệ thống huỷ.
    func debugRouteCancel(_ id: ObjectIdentifier, at p: CGPoint, time: TimeInterval) {
        routeUp(id, at: p, time: time, cancelled: true)
    }
    /// Test hook: kéo touch router đang đè qua `points` (như touchesMoved), CHƯA nhấc.
    /// Trả true nếu touch đã thành vuốt.
    @discardableResult
    func debugRouteMove(_ id: ObjectIdentifier, through points: [CGPoint], dt: TimeInterval = 0.016,
                        start t0: TimeInterval) -> Bool {
        var t = t0
        for p in points {
            t += dt
            if keyCmdTouchID == id { keyCommandMoved(to: p) }
            if swipeTouchID == id { swipeMovedBatch([(p, t)]) }
        }
        return swipeActive && swipeTouchID == id
    }
    /// Bench hook (KeyboardBenchTests): một chạm phím chữ tại `p` đi đúng đường thật —
    /// hitTest (router) → routeDown (smartPick, sendActions touchDown → chèn) → routeUp.
    func benchTap(at p: CGPoint, time: TimeInterval) {
        _ = hitTest(p, with: nil)
        let token = NSObject()
        let id = ObjectIdentifier(token)
        routeDown(id, at: p, time: time, batch: 1)
        routeUp(id, at: p, time: time + 0.06, cancelled: false)
        withExtendedLifetime(token) {}
    }
    /// Bench hook: phím cách (click + lệnh space như lúc nhấc tay).
    func benchSpace() {
        Self.clickModifier()
        tapped(.space)
    }
    /// Test hook: nút thật theo accessibilityLabel ("Số", "Chữ", "Emoji", "Shift"…).
    /// Test: nhãn từng phím theo hàng (trái → phải): ký tự phím / accessibilityLabel phím
    /// chức năng, ô trống (thụt hàng) = "␣".
    func debugRowLabels() -> [[String]] {
        rowsContainer.arrangedSubviews.map { r in
            ((r as? KeyRow)?.arrangedSubviews ?? (r as? UIStackView)?.arrangedSubviews ?? []).map { v in
                guard let b = v as? KeyButton else { return "␣" }
                if b.isSpecial || (b.currentTitle ?? "").isEmpty {
                    if let t = b.currentTitle, !t.isEmpty, b.accessibilityLabel == nil { return t }
                    return b.accessibilityLabel ?? b.currentTitle ?? "?"
                }
                return b.currentTitle ?? "?"
            }
        }
    }
    /// Test: ký tự phụ (nhãn xám) của phím có tiêu đề `title`.
    func debugPadHint(_ title: String) -> String? {
        (debugKeyButton(title) as? KeyButton)?.padHint?.text
    }
    /// Test: giả lập vuốt xuống / giữ trên phím có ký tự phụ rồi nhấc → ký tự gõ ra.
    func debugPadAlternate(_ title: String) {
        guard let b = debugKeyButton(title) as? KeyButton else { return }
        b.sendActions(for: .touchDown)
        choosePadAlt(b)
        b.sendActions(for: .touchUpInside)
    }
    /// Test: giả lập hết giờ GIỮ trên một phím có ký tự phụ (đang chạm).
    func debugChoosePadAlt(_ c: UIControl) { if let b = c as? KeyButton { choosePadAlt(b) } }
    /// Test: chạm xuống phím có ký tự phụ có hẹn giờ giữ không (rồi huỷ chạm).
    func debugPadAltArmsOnTouchDown(_ title: String) -> Bool {
        guard let b = debugKeyButton(title) as? KeyButton else { return false }
        b.sendActions(for: .touchDown)
        let armed = b.padAltTimer != nil
        b.sendActions(for: .touchCancel)
        return armed
    }
    func debugControl(_ label: String) -> UIControl? {
        func find(_ v: UIView) -> UIControl? {
            if let c = v as? UIControl, c.accessibilityLabel == label { return c }
            for s in v.subviews { if let r = find(s) { return r } }
            return nil
        }
        return find(rowsContainer)
    }
    var debugPlaneName: String { "\(plane)" }
    /// Test hook: phím bàn số lớn theo nhãn (số = accessibilityLabel, ký hiệu = title, "Chữ", "Xoá").
    func debugKeypadKey(_ label: String) -> UIControl? {
        guard plane == .keypad else { return nil }
        for row in rowsContainer.arrangedSubviews {
            for c in rowControls(row) {
                if c.accessibilityLabel == label || (c as? KeyButton)?.currentTitle == label { return c }
            }
        }
        return nil
    }
    /// Test hook: chữ cái phụ đang hiện dưới số `d` ("" = không có / ẩn).
    func debugKeypadLetters(_ d: String) -> String {
        guard let b = debugKeypadKey(d) else { return "" }
        let ls = (b.subviews.first { $0 is UIStackView } as? UIStackView)?.arrangedSubviews
            .compactMap { $0 as? UILabel } ?? []
        guard ls.count == 2, !ls[1].isHidden else { return "" }
        return ls[1].text ?? ""
    }
    /// Test hook: giữ phím bàn số tới khi hiện hàng lựa chọn, chọn ô đầu, nhấc.
    func debugKeypadHold(_ label: String) {
        guard let b = debugKeypadKey(label) as? KeyButton else { return }
        let key = convert(b.bounds, from: b)
        domainLastPoint = CGPoint(x: key.midX, y: key.midY)
        b.sendActions(for: .touchDown)
        domainTimer?.cancel()
        fireDomainHold(b, choices: NumericKeypad.holdChoices(for: label, style: keypadStyle ?? .digits),
                       variants: true)
        b.sendActions(for: .touchUpInside)
    }
    var debugShiftOn: Bool { shift != .off }
    var debugShiftCaps: Bool { shift == .caps }
    /// Test: ngón chạm / nhấc phím ⇧ lúc `time` (đường ShiftHold thật, không cần nút).
    func debugShiftDown(at time: TimeInterval) { debugShiftTrackingOverride = true; shiftDown(now: time) }
    func debugShiftUp() { shiftUp(); debugShiftTrackingOverride = nil }
    /// Test: chạm + nhấc phím chữ `s` qua router lúc `time`.
    func debugTapLetter(_ s: String, at time: TimeInterval) {
        guard let f = debugLetterFrame(s) else { return }
        let token = NSObject(), id = ObjectIdentifier(token)
        let c = CGPoint(x: f.midX, y: f.midY)
        routeDown(id, at: c, time: time, batch: 1)
        routeUp(id, at: c, time: time + 0.05, cancelled: false)
        withExtendedLifetime(token) {}
    }
    /// Test hook: hiện balloon trên phím chữ `s` (như chạm / giữ ra ký tự phụ `text`), trả
    /// frame balloon + khung chữ + cỡ chữ (toạ độ self).
    func debugBalloon(letter s: String, text: String) -> (frame: CGRect, label: CGRect, fontSize: CGFloat)? {
        guard let b = letterKeys.first(where: { $0.base == s })?.button else { return nil }
        showBalloon(over: b, text: text, force: true)
        let l = balloon.label
        return (balloon.frame, convert(l.bounds, from: l), l.font.pointSize)
    }
    /// Test hook: chiều cao xin host + vùng hàng (constant constraint).
    var debugRequestedHeight: CGFloat { heightConstraint?.constant ?? 0 }
    var debugRowsTop: CGFloat { rowsTopWanted }
    func debugEnterEmojiSearch() { plane = .emojiSearch; rebuild() }
    /// Test hook: phông + bán kính bo của phím chữ `s` (sau layout).
    func debugLetterStyle(_ s: String) -> (font: UIFont?, radius: CGFloat, size: CGSize)? {
        letterKeys.first { $0.base == s }.map { ($0.button.titleLabel?.font, $0.button.layer.cornerRadius, $0.button.bounds.size) }
    }
    /// Test hook: frame phím chữ (toạ độ self).
    /// Thứ tự lớp: nền (màu / ảnh theme / ảnh nền / lớp tối) + hàng phím.
    var debugBackdropViews: [UIView] { [themeBackdrop, themeImageView, wallpaperView, wallpaperDim] }
    /// Test: dải cực quang (theme AI) — nil = chưa từng tạo.
    var debugAuroraBand: CAGradientLayer? { auroraBand }
    var debugCornerGlyph: CATextLayer? { cornerGlyphLayer }
    var debugRowsContainer: UIView { rowsContainer }
    /// Test: đường phím thật sau khi chạm (onKey + hiệu ứng) cho phím `k`.
    func debugTapped(_ k: Key) { tapped(k) }
    func debugLetterFrame(_ s: String) -> CGRect? {
        letterKeys.first { $0.base == s }.map { convert($0.button.bounds, from: $0.button) }
    }
    /// Mọi phím chữ `s` (bàn tách đôi: G / V có hai phím).
    func debugLetterFrames(_ s: String) -> [CGRect] {
        letterKeys.filter { $0.base == s }.map { convert($0.button.bounds, from: $0.button) }
    }
    #endif
}


