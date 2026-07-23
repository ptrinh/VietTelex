// KeyboardView — programmatic UIKit clone of Apple's Vietnamese keyboard.
// M1: letters plane + shift/caps + backspace (with repeat) + 123 plane +
// globe/space/return. Metrics follow Apple's stock layout; the pixel-perfect
// fidelity pass (balloons, exact colors per appearance, iPad) is M2.
import UIKit

final class KeyboardView: UIView, UIInputViewAudioFeedback {

    enum Key {
        case letter(Character)
        case text(String)
        case space
        case doubleSpacePeriod        // "  " fast → ". " (Apple behavior)
        case newline
        case backspace
        case moveCursor(Int)          // space-hold trackpad mode
    }

    private enum Plane { case letters, numbers, symbols, emoji }
    private enum ShiftState { case off, on, caps }

    var enableInputClicksWhenVisible: Bool { true }

    private let onKey: (Key) -> Void
    private let needsGlobe: Bool
    // Globe key theo hợp đồng Apple: addTarget thẳng vào UIInputViewController
    // với .allTouchEvents — long-press mở picker bàn phím chỉ chạy khi
    // handleInputModeList nhận event THẬT.
    private weak var inputController: UIInputViewController?

    /// M2 suggestion bar: gate qua toggle showSuggestions trong app.
    var onSuggestion: ((String) -> Void)?
    private var heightConstraint: NSLayoutConstraint?
    private let suggestionBar = UIStackView()
    private var suggestionsEnabled = false

    private var plane: Plane = .letters
    private var shift: ShiftState = .on          // Apple: sentence start = shifted
    private var returnTitle = "return"
    private var dark = false
    private var lastShiftTap: TimeInterval = 0

    private var rowsContainer = UIStackView()
    private var rowsHeightConstraint: NSLayoutConstraint?
    private var repeatTimer: Timer?
    private var lastSuggestionSig = ""
    private var wordDeleteTick = 0
    /// Giữ backspace >3s → xoá theo TỪ (controller đọc proxy, off hot path).
    var onDeleteWord: (() -> Void)?
    private var lastSpaceTap: TimeInterval = 0
    private var spaceHoldX: CGFloat = 0
    private var backspaceHoldStart: TimeInterval = 0

    // Fill đục xấp xỉ stock — alpha-white trên nền trong suốt làm phím
    // đổi sắc theo màu app phía sau.
    private var plainFill: UIColor {
        dark ? UIColor(white: 0.42, alpha: 1) : .white
    }
    private var specialFill: UIColor {
        dark ? UIColor(white: 0.26, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
    }

    init(needsGlobe: Bool, inputController: UIInputViewController?, onKey: @escaping (Key) -> Void) {
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
        rowsContainer.axis = .vertical
        rowsContainer.distribution = .fillEqually
        rowsContainer.spacing = 0
        rowsContainer.isMultipleTouchEnabled = true
        rowsContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsContainer)
        // Pin the KEYS to the BOTTOM with a FIXED height instead of stretching
        // from the top: while the host settles on the final height (~100ms at
        // keyboard switch), any excess shows as empty strip ABOVE the keys —
        // invisible — instead of stretching every key tall (the 'flash' bug).
        let rowsHeight = rowsContainer.heightAnchor.constraint(equalToConstant: 212)
        NSLayoutConstraint.activate([
            rowsContainer.leftAnchor.constraint(equalTo: leftAnchor),
            rowsContainer.rightAnchor.constraint(equalTo: rightAnchor),
            rowsHeight,
            rowsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
        ])
        rowsHeightConstraint = rowsHeight
        // Suggestion bar sống trong "khoảng trống 2" — chỉ hiện khi bật.
        suggestionBar.axis = .horizontal
        suggestionBar.distribution = .fillProportionally
        suggestionBar.spacing = 6
        suggestionBar.isLayoutMarginsRelativeArrangement = true
        suggestionBar.layoutMargins = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        suggestionBar.translatesAutoresizingMaskIntoConstraints = false
        suggestionBar.isHidden = true
        addSubview(suggestionBar)
        NSLayoutConstraint.activate([
            suggestionBar.leftAnchor.constraint(equalTo: leftAnchor),
            suggestionBar.rightAnchor.constraint(equalTo: rightAnchor),
            suggestionBar.topAnchor.constraint(equalTo: topAnchor),
            suggestionBar.bottomAnchor.constraint(equalTo: rowsContainer.topAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { repeatTimer?.invalidate() }

    /// Bật/tắt thanh gợi ý: mở rộng khoảng trống phía trên vừa đủ (44pt).
    func setSuggestionsEnabled(_ on: Bool) {
        suggestionsEnabled = on
        lastSuggestionSig = ""        // chrome đổi → lượt show kế phải ghi lại UI
        updateSuggestionChrome()
    }

    /// 216pt dọc / ~162pt ngang trên iPhone (stock co chiều cao khi xoay).
    private func keyAreaHeight() -> CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return 216 }
        let landscape = window?.windowScene?.interfaceOrientation.isLandscape
            ?? (bounds.width > 500)
        return landscape ? 162 : 216
    }

    /// Strip gợi ý chỉ hiện khi bật VÀ đang ở plane chữ/số — trong emoji plane
    /// ẩn đi cho gọn (user 2026-07-24). strip 30pt sát nút; phần dưới hàng
    /// phím cuối là vùng globe/mic hệ thống, không thuộc view mình.
    private func updateSuggestionChrome() {
        let visible = suggestionsEnabled && plane != .emoji
        suggestionBar.isHidden = !visible
        let keyArea = keyAreaHeight()
        heightConstraint?.constant = visible ? keyArea + 30 : keyArea
        rowsHeightConstraint?.constant = keyArea - 4
    }

    // Rotation / Split View: indent hàng 2 và chiều cao tính theo bounds THẬT,
    // không dùng UIScreen.main (deprecated, sai trong Split View).
    private var lastLayoutWidth: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            updateSuggestionChrome()
            if let r = indentedRow {
                let inset = 3 + indentedRowInset * bounds.width / 10
                r.layoutMargins = UIEdgeInsets(top: 5, left: inset, bottom: 5, right: inset)
            }
        }
    }

    /// Cập nhật gợi ý theo layout stock: ["nguyên văn"] | từ gợi ý | emoji(≤3),
    /// ngăn cách bằng divider mảnh. Mảng rỗng → dọn bar.
    struct SuggestionSet {
        var literal: String? = nil
        var word: String? = nil
        var word2: String? = nil       // ứng viên inline thứ hai (khi không có emoji)
        var emojis: [String] = []
        var nextWords: [String] = []   // gợi ý khi CHƯA gõ (đầu câu / sau space)
        var isEmpty: Bool {
            literal == nil && word == nil && word2 == nil && emojis.isEmpty && nextWords.isEmpty
        }
    }

    // Pool cố định: 3 nút chính + 2 divider + 3 nút emoji con. Mỗi keystroke
    // CHỈ đổi title/hidden — không removeFromSuperview/addSubview (churn view +
    // Auto Layout invalidate mỗi phím chính là nguồn lag/miss touch).
    private var slotButtons: [KeyButton] = []
    private var slotDividers: [UIView] = []
    private var emojiStack = UIStackView()
    private var emojiButtons: [KeyButton] = []

    private func buildSuggestionPoolIfNeeded() {
        guard slotButtons.isEmpty else { return }
        func makeSlot() -> KeyButton {
            let b = KeyButton(type: .custom)
            b.backgroundColor = .clear
            b.isMultipleTouchEnabled = true
            b.addAction(UIAction { [weak self, weak b] _ in
                if let s = b?.payload { self?.onSuggestion?(s) }
            }, for: .touchUpInside)
            return b
        }
        func makeDivider() -> UIView {
            let v = UIView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 1).isActive = true
            let line = UIView()
            line.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(line)
            NSLayoutConstraint.activate([
                line.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                line.widthAnchor.constraint(equalToConstant: 1),
                line.topAnchor.constraint(equalTo: v.topAnchor, constant: 7),
                line.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -7),
            ])
            line.tag = 77   // line lookup (tag phải nằm trên LINE, không phải wrapper)
            return v
        }
        emojiStack.axis = .horizontal
        emojiStack.distribution = .fillEqually
        for _ in 0..<3 {
            let b = makeSlot()
            b.titleLabel?.font = .systemFont(ofSize: 24)
            emojiButtons.append(b)
            emojiStack.addArrangedSubview(b)
        }
        for i in 0..<3 {
            let b = makeSlot()
            slotButtons.append(b)
            suggestionBar.addArrangedSubview(b)
            if i < 2 {
                let d = makeDivider()
                slotDividers.append(d)
                suggestionBar.addArrangedSubview(d)
            }
        }
        suggestionBar.addArrangedSubview(emojiStack)
    }

    func showSuggestions(_ set: SuggestionSet) {
        guard suggestionsEnabled else { return }
        buildSuggestionPoolIfNeeded()

        // gom nội dung 3 slot chính: nextWords HOẶC literal/word/word2
        var texts: [(display: String, insert: String)?] = [nil, nil, nil]
        if !set.nextWords.isEmpty {
            for (i, w) in set.nextWords.prefix(3).enumerated() { texts[i] = (w, w) }
        } else {
            if let l = set.literal { texts[0] = ("\u{201C}\(l)\u{201D}", l) }
            if let w = set.word { texts[1] = (w, w) }
            if set.emojis.isEmpty, let w2 = set.word2 { texts[2] = (w2, w2) }
        }
        // Nội dung không đổi (nextWords thường ổn định giữa các phím) → bỏ qua
        // toàn bộ ghi UI: setTitle trên bar fillProportionally kéo theo một
        // lượt đo text/Auto Layout mỗi keystroke.
        let sig = (dark ? "D" : "L")
            + texts.map { $0.map { $0.display + "\u{1}" + $0.insert } ?? "\u{2}" }.joined(separator: "\u{3}")
            + "\u{4}" + (set.nextWords.isEmpty ? set.emojis.prefix(3).joined() : "")
        if sig == lastSuggestionSig { return }
        lastSuggestionSig = sig

        let ink: UIColor = dark ? .white : .black
        for d in slotDividers {
            d.viewWithTag(77)?.backgroundColor = ink.withAlphaComponent(0.18)
        }
        for (i, b) in slotButtons.enumerated() {
            if let t = texts[i] {
                b.setTitle(t.display, for: .normal)
                b.setTitleColor(ink, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
                b.payload = t.insert
                b.isHidden = false
            } else {
                b.isHidden = true
                b.payload = nil
            }
        }
        // slot emoji (chỉ ở chế độ đang gõ, khi có emoji)
        let emojis = set.nextWords.isEmpty ? Array(set.emojis.prefix(3)) : []
        for (i, b) in emojiButtons.enumerated() {
            if i < emojis.count {
                b.setTitle(emojis[i], for: .normal)
                b.payload = emojis[i]
                b.isHidden = false
            } else {
                b.isHidden = true; b.payload = nil
            }
        }
        emojiStack.isHidden = emojis.isEmpty
        // divider hiện giữa các slot đang hiển thị
        let vis0 = !(slotButtons[0].isHidden), vis1 = !(slotButtons[1].isHidden)
        let vis2 = !(slotButtons[2].isHidden) || !emojiStack.isHidden
        slotDividers[0].isHidden = !(vis0 && (vis1 || vis2))
        slotDividers[1].isHidden = !(vis1 && vis2)
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
        rebuild()
    }

    func applyAppearance(_ appearance: UIKeyboardAppearance) {
        // Hầu hết host truyền .default — phải dò trait hệ thống, nếu không
        // bàn phím sáng trưng trên máy dark mode.
        dark = (appearance == .dark)
            || (appearance != .light && traitCollection.userInterfaceStyle == .dark)
        rebuild()
    }

    /// Sentence-start auto-shift (only upgrades OFF→ON; never downgrades CAPS).
    func setAutoShift(_ on: Bool) {
        guard shift != .caps else { return }
        let want: ShiftState = on ? .on : .off
        if shift != want { shift = want; applyShiftAppearance() }
    }


    // Shift changes must NEVER rebuild: tearing the buttons down mid-typing
    // deallocates the key already under the user's finger, so its touch-up
    // never fires (the missed-keypress bug). Retitle in place instead.
    private var letterKeys: [(button: UIButton, base: String)] = []
    private weak var spaceBar: UIButton?
    private weak var spaceLogo: UIImageView?
    private weak var indentedRow: UIStackView?
    private var indentedRowInset: CGFloat = 0
    private var shiftKey: KeyButton?
    private func applyShiftAppearance() {
        for (b, s) in letterKeys {
            b.setTitle(shift == .off ? s : s.uppercased(), for: .normal)
        }
        if let b = shiftKey {
            let symbol = shift == .caps ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
            b.setImage(UIImage(systemName: symbol), for: .normal)
            // Shift ON/CAPS = phím đảo màu (nền trắng, glyph đen) như stock —
            // cả dark mode, nếu không ON và OFF trông y hệt nhau.
            if shift != .off {
                b.backgroundColor = .white
                b.tintColor = .black
            } else {
                b.backgroundColor = specialFill
                b.tintColor = dark ? .white : .black
            }
            b.normalBackground = b.backgroundColor
        }
    }


    // MARK: layout

    // Dedupe: rebuild bị gọi 3 lần mỗi lần hiện (init, configureReturnKey,
    // applyAppearance) — chỉ xé/dựng lại khi có gì đó thật sự đổi.
    private var builtPlane: Plane?
    private var builtReturn = ""
    private var builtDark = false
    private var builtWidth: CGFloat = -1

    // Cache view theo plane: bấm 123/#+=/ABC chỉ tráo arrangedSubviews thay vì
    // xé/dựng lại ~40 button + constraints mỗi lần. Emoji KHÔNG cache (recents
    // phải tươi mỗi lần mở). Đổi return/dark/width → mọi plane cache đều sai
    // nhãn/màu/inset nên vứt hết.
    private struct CachedPlane {
        let rows: [UIView]
        let letterKeys: [(button: UIButton, base: String)]
        let shiftKey: KeyButton?
        let spaceBar: UIButton?
        let spaceLogo: UIImageView?
        let indentedRow: UIStackView?
        let indentedRowInset: CGFloat
    }
    private var planeCache: [Plane: CachedPlane] = [:]

    private func rebuild() {
        updateSuggestionChrome()
        if builtPlane == plane, builtReturn == returnTitle,
           builtDark == dark, builtWidth == bounds.width { return }
        if builtReturn != returnTitle || builtDark != dark || builtWidth != bounds.width {
            planeCache.removeAll()
        } else if let old = builtPlane, old != .emoji {
            planeCache[old] = CachedPlane(
                rows: rowsContainer.arrangedSubviews, letterKeys: letterKeys,
                shiftKey: shiftKey, spaceBar: spaceBar, spaceLogo: spaceLogo,
                indentedRow: indentedRow, indentedRowInset: indentedRowInset)
        }
        builtPlane = plane; builtReturn = returnTitle
        builtDark = dark; builtWidth = bounds.width
        letterKeys.removeAll()
        shiftKey = nil
        rowsContainer.distribution = .fillEqually
        rowsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let cached = planeCache[plane] {
            cached.rows.forEach { rowsContainer.addArrangedSubview($0) }
            letterKeys = cached.letterKeys
            shiftKey = cached.shiftKey
            spaceBar = cached.spaceBar
            spaceLogo = cached.spaceLogo
            indentedRow = cached.indentedRow
            indentedRowInset = cached.indentedRowInset
            // shift có thể đã đổi trong lúc plane này nằm ngoài màn hình
            if plane == .letters { applyShiftAppearance() }
            return
        }
        switch plane {
        case .letters: buildLetters()
        case .numbers: buildPlane(rows: [
            ["1","2","3","4","5","6","7","8","9","0"],
            // $ ở đúng chỗ bàn phím EN (user 2026-07-23); ₫ chuyển sang plane #+=
            ["-","/",":",";","(",")","$","&","@","\""],
        ], moreKey: "#+=", altKey: "ABC")
        case .symbols: buildPlane(rows: [
            ["[","]","{","}","#","%","^","*","+","="],
            // 3 currencies: EUR, CNY, VND (₫ thế chỗ JPY của layout EN)
            ["_","\\","|","~","<",">","€","¥","₫","•"],
        ], moreKey: "123", altKey: "ABC")
        case .emoji: buildEmoji()
        }
    }

    private func buildLetters() {
        let r1 = "qwertyuiop".map { String($0) }
        let r2 = "asdfghjkl".map { String($0) }
        let r3 = "zxcvbnm".map { String($0) }
        rowsContainer.addArrangedSubview(row(r1.map(letterButton)))
        // Apple indents row 2 by half a key on iPhone.
        rowsContainer.addArrangedSubview(row(r2.map(letterButton), sideInset: 0.5))
        var third: [UIView] = [shiftButton()]
        third += r3.map(letterButton)
        third.append(backspaceButton())
        rowsContainer.addArrangedSubview(row(third))
        rowsContainer.addArrangedSubview(bottomRow(planeKey: "123"))
    }

    // Emoji plane render theo stock (video 2026-07-24): search bar + lưới
    // cuộn ngang column-major theo category + hàng [ABC][icons][⌫].
    // rowsContainer là fillEqually — plane emoji cần layout tự do nên đổi
    // distribution sang .fill khi vào plane này (rebuild() phục hồi).
    private func buildEmoji() {
        rowsContainer.distribution = .fill
        let plane = EmojiPlane(dark: dark)
        plane.onEmoji = { [weak self] e in self?.tapped(.text(e)) }
        plane.onABC = { [weak self] in
            guard let self else { return }
            self.plane = .letters
            self.rebuild()
        }
        plane.onBackspace = { [weak self] in self?.tapped(.backspace) }
        rowsContainer.addArrangedSubview(plane)
    }

    private func buildPlane(rows planeRows: [[String]], moreKey: String, altKey: String) {
        rowsContainer.addArrangedSubview(row(planeRows[0].map(textButton)))
        rowsContainer.addArrangedSubview(row(planeRows[1].map(textButton)))
        let more = controlButton(title: moreKey) { [weak self] in
            guard let self else { return }
            self.plane = (self.plane == .numbers) ? .symbols : .numbers
            self.rebuild()
        }
        more.accessibilityLabel = moreKey == "#+=" ? "Ký hiệu" : "Số"
        var third: [UIView] = [more]
        third += [".",",","?","!","'"].map(textButton)
        third.append(backspaceButton())
        rowsContainer.addArrangedSubview(row(third))
        rowsContainer.addArrangedSubview(bottomRow(planeKey: altKey))
    }

    private func bottomRow(planeKey: String) -> UIView {
        var views: [UIView] = []
        let planeBtn = controlButton(title: planeKey) { [weak self] in
            guard let self else { return }
            self.plane = (self.plane == .letters) ? .numbers : .letters
            if self.plane == .letters, self.shift == .on { self.shift = .off }
            self.rebuild()
        }
        planeBtn.accessibilityLabel = planeKey == "123" ? "Số" : "Chữ"
        views.append(planeBtn)
        // globe sát bên phải [123] như stock (muscle memory), emoji sau đó
        if needsGlobe {
            let globe = baseButton(title: "", special: true)
            globe.setImage(UIImage(systemName: "globe"), for: .normal)
            globe.tintColor = dark ? .white : .black
            globe.accessibilityLabel = "Bàn phím tiếp theo"
            if let c = inputController {
                // hợp đồng Apple: event thật + allTouchEvents để long-press
                // mở keyboard picker hoạt động
                globe.addTarget(c, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                                for: .allTouchEvents)
            }
            views.append(globe)
        }
        // nút emoji bên trái space — icon đơn sắc như stock (user 2026-07-23)
        let emojiBtn = controlButton(title: "") { [weak self] in
            guard let self else { return }
            self.plane = .emoji
            self.rebuild()
        }
        emojiBtn.setImage(UIImage(systemName: "face.smiling.inverse",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)), for: .normal)
        emojiBtn.tintColor = dark ? .white : .black
        emojiBtn.accessibilityLabel = "Emoji"
        views.append(emojiBtn)
        let space = baseButton(title: "", special: true)
        space.backgroundColor = plainFill
        space.normalBackground = plainFill
        space.pressedBackground = specialFill      // space sẫm lại khi đè
        space.accessibilityLabel = "Dấu cách"
        spaceBar = space
        // logo Vᴛ mờ ở mép phải nút space (thay "VI EN" — user 2026-07-23);
        // PNG 2x/3x render từ MenuIcon.pdf nên sắc nét, tint theo appearance.
        // Ẩn được qua Settings của app (showSpaceLogo, App Group).
        let showLogo = UserDefaultsProvider.shared?.object(forKey: "showSpaceLogo") == nil
            || UserDefaultsProvider.shared?.bool(forKey: "showSpaceLogo") == true
        if showLogo {
            let hint = UIImageView(image: UIImage(named: "SpaceLogo")?.withRenderingMode(.alwaysTemplate))
            hint.tintColor = (dark ? UIColor.white : .black).withAlphaComponent(0.16)
            hint.contentMode = .scaleAspectFit
            hint.translatesAutoresizingMaskIntoConstraints = false
            spaceLogo = hint
            space.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.rightAnchor.constraint(equalTo: space.rightAnchor, constant: -10),
                hint.centerYAnchor.constraint(equalTo: space.centerYAnchor),
                hint.widthAnchor.constraint(equalToConstant: 22),
                hint.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        space.addAction(UIAction { _ in Self.clickModifier() }, for: .touchDown)
        space.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if now - self.lastSpaceTap < 0.35 {
                self.tapped(.doubleSpacePeriod)
            } else {
                self.tapped(.space)
            }
            self.lastSpaceTap = now
        }, for: .touchUpInside)
        let spacePan = UILongPressGestureRecognizer(target: self, action: #selector(spaceHold(_:)))
        spacePan.minimumPressDuration = 0.4
        space.addGestureRecognizer(spacePan)
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(space)
        // dấu phẩy bên phải space (user 2026-07-23)
        let comma = baseButton(title: ",", special: false)
        comma.pressedBackground = specialFill
        comma.addAction(UIAction { [weak self] _ in self?.tapped(.text(",")) }, for: .touchUpInside)
        views.append(comma)
        let ret = controlButton(title: returnTitle == "return" ? "" : returnTitle) { [weak self] in
            self?.tapped(.newline)
        }
        ret.accessibilityLabel = returnTitle == "return" ? "Xuống dòng" : returnTitle
        if returnTitle == "return" {
            ret.setImage(UIImage(systemName: "return.left",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
            // mờ ngang logo Vᴛ trên spacebar (user 2026-07-23)
            ret.tintColor = (dark ? UIColor.white : .black).withAlphaComponent(0.16)
        }
        views.append(ret)

        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 3, bottom: 5, right: 3)
        planeBtn.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.12).isActive = true
        emojiBtn.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.10).isActive = true
        comma.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.075).isActive = true
        ret.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.165).isActive = true
        return stack
    }

    private func row(_ views: [UIView], sideInset: CGFloat = 0) -> UIView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillProportionally
        stack.isLayoutMarginsRelativeArrangement = true
        // bounds.width có thể = 0 lúc init — layoutSubviews chỉnh lại ngay
        // pass đầu (và sau mỗi lần xoay / đổi cỡ Split View)
        let unit = bounds.width / 10
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 3 + sideInset * unit,
                                           bottom: 5, right: 3 + sideInset * unit)
        if sideInset > 0 { indentedRow = stack; indentedRowInset = sideInset }
        // equal widths for plain letter keys
        let letters = views.filter { ($0 as? KeyButton)?.isSpecial == false }
        if let first = letters.first {
            for v in letters.dropFirst() {
                v.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
            }
        }
        return stack
    }

    // MARK: buttons

    private final class KeyButton: UIButton {
        var isSpecial = false
        var payload: String?    // suggestion slot: nội dung sẽ chèn khi bấm
        var normalBackground: UIColor?
        var pressedBackground: UIColor?   // nil = không đổi màu khi đè (phím chữ dùng balloon)
        // Khe hở giữa phím (spacing 6 + padding hàng 5) là VÙNG CHẾT với
        // UIButton thường — chạm trúng khe = mất phím. Stock keyboard route
        // mọi điểm chạm về phím gần nhất; mở rộng hit area phủ nửa khe cho
        // hiệu quả tương đương, không đổi kiến trúc touch.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: -3, dy: -5.5).contains(point)
        }
    }

    private func baseButton(title: String, special: Bool) -> KeyButton {
        // .custom, not .system: system buttons run tint/highlight animations on
        // the main thread per touch — visible latency on a keyboard.
        let b = KeyButton(type: .custom)
        b.isMultipleTouchEnabled = true
        b.isSpecial = special
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: special ? 16 : 25)
        b.layer.cornerRadius = 5
        b.setTitleColor(dark ? .white : .black, for: .normal)
        b.backgroundColor = special ? specialFill : plainFill
        b.normalBackground = b.backgroundColor
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.layer.shadowOpacity = dark ? 0.30 : 0.35
        b.layer.shadowRadius = 0
        // Pressed state cho phím chức năng: swap màu phẳng, KHÔNG
        // UIView.animate — animation per-touch trên main thread là latency
        // thấy được trên bàn phím (lý do dùng .custom ở trên).
        if special { b.pressedBackground = plainFill }
        b.addAction(UIAction { [weak b] _ in
            if let c = b?.pressedBackground { b?.backgroundColor = c }
        }, for: .touchDown)
        b.addAction(UIAction { [weak b] _ in
            if b?.pressedBackground != nil, let c = b?.normalBackground { b?.backgroundColor = c }
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    // Âm click phát ở TOUCH-DOWN như stock (nguồn cảm giác "nhanh").
    // playInputClick tôn trọng Settings→Sounds→Keyboard Clicks (AudioServices
    // trước đây bỏ qua setting); mất phân biệt 3 tông — chấp nhận.
    static func clickLetter() { UIDevice.current.playInputClick() }
    static func clickDelete() { UIDevice.current.playInputClick() }
    static func clickModifier() { UIDevice.current.playInputClick() }

    // ROLLOVER: gõ nhanh thì ngón sau chạm xuống khi phím trước còn đè —
    // stock chốt phím trước ngay lúc đó. Thiếu rollover là ca "chữ ra chậm /
    // lộn thứ tự" khi gõ nhanh.
    private weak var pendingLetterButton: UIButton?
    private var pendingLetterCommit: (() -> Void)?
    private func commitPendingLetter() {
        let commit = pendingLetterCommit
        pendingLetterCommit = nil
        pendingLetterButton = nil
        commit?()
    }

    private func letterButton(_ s: String) -> UIView {
        let title = (shift == .off) ? s : s.uppercased()
        let b = baseButton(title: title, special: false)
        // Touch của phím CHỮ do router (touchesBegan/Ended của KeyboardView)
        // điều phối — nearest-key, không thể miss. Button chỉ còn là visual +
        // hộp action được sendActions() kích.
        b.isUserInteractionEnabled = false
        letterKeys.append((b, s))
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self, let b else { return }
            self.commitPendingLetter()               // rollover phím trước
            Self.clickLetter()                       // feedback tức thì
            self.showBalloon(over: b, text: b.currentTitle ?? title)
            self.pendingLetterButton = b
            self.pendingLetterCommit = { [weak self] in
                guard let self else { return }
                let cased: Character = (self.shift == .off) ? Character(s) : Character(s.uppercased())
                self.tapped(.letter(cased))
                if self.shift == .on { self.shift = .off; self.applyShiftAppearance() }
            }
        }, for: .touchDown)
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self else { return }
            self.hideBalloon()
            if self.pendingLetterButton === b { self.commitPendingLetter() }
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    // MARK: key preview balloon (clipped to our own bounds on the top row —
    // a documented extension limitation; see docs/ios-app.md)
    private let balloon = UILabel()
    private var balloonShadowWidth: CGFloat = -1
    private func showBalloon(over key: UIView, text: String) {
        balloon.text = text
        balloon.font = .systemFont(ofSize: 34)
        balloon.textAlignment = .center
        balloon.textColor = dark ? .white : .black
        balloon.backgroundColor = dark ? UIColor(white: 0.35, alpha: 1) : .white
        balloon.layer.cornerRadius = 8
        balloon.layer.masksToBounds = false   // cornerRadius vẫn bo nền; cần false để đổ bóng
        balloon.layer.shadowColor = UIColor.black.cgColor
        balloon.layer.shadowOffset = CGSize(width: 0, height: 1)
        balloon.layer.shadowRadius = 2
        balloon.layer.shadowOpacity = 0.3
        balloon.layer.zPosition = 10
        let f = convert(key.bounds, from: key)
        let w = max(f.width + 16, 44)
        // Bar gợi ý hiện = có 30pt headroom phía trên hàng phím đầu — cho
        // balloon leo vào đó thay vì kẹp sát -6.
        let topLimit: CGFloat = suggestionBar.isHidden ? -6 : 0
        balloon.frame = CGRect(x: f.midX - w / 2, y: max(f.minY - 52, topLimit), width: w, height: 50)
        if w != balloonShadowWidth {   // shadowPath cache theo width — tránh alloc mỗi phím
            balloonShadowWidth = w
            balloon.layer.shadowPath = UIBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: w, height: 50), cornerRadius: 8).cgPath
        }
        if balloon.superview == nil { addSubview(balloon) }
        balloon.isHidden = false
    }
    private func hideBalloon() { balloon.isHidden = true }

    private func textButton(_ s: String) -> UIView {
        let b = baseButton(title: s, special: false)
        b.addAction(UIAction { [weak self, weak b] _ in
            Self.clickLetter()
            if let self, let b { self.showBalloon(over: b, text: s) }
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in
            self?.hideBalloon()
            self?.tapped(.text(s))
        }, for: .touchUpInside)
        b.addAction(UIAction { [weak self] _ in self?.hideBalloon() },
                    for: [.touchUpOutside, .touchCancel])
        return b
    }

    private func controlButton(title: String, action: @escaping () -> Void) -> KeyButton {
        let b = baseButton(title: title, special: true)
        b.addAction(UIAction { _ in Self.clickModifier() }, for: .touchDown)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func shiftButton() -> UIView {
        let symbol = shift == .caps ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
        let b = baseButton(title: "", special: true)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.accessibilityLabel = "Shift"
        if shift != .off {
            b.backgroundColor = .white
            b.tintColor = .black
        } else {
            b.tintColor = dark ? .white : .black
        }
        b.normalBackground = b.backgroundColor
        shiftKey = b
        // Toggle ở TOUCH-DOWN: roll shift+chữ nhanh phải ra chữ hoa —
        // touch-up thì chữ đã kịp chốt trước khi shift bật.
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if now - self.lastShiftTap < 0.3 { self.shift = .caps }
            else { self.shift = (self.shift == .off) ? .on : .off }
            self.lastShiftTap = now
            self.applyShiftAppearance()
        }, for: .touchDown)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return b
    }

    private func backspaceButton() -> UIView {
        let b = baseButton(title: "", special: true)
        b.setImage(UIImage(systemName: "delete.left"), for: .normal)
        b.setImage(UIImage(systemName: "delete.left.fill"), for: .highlighted)
        b.tintColor = dark ? .white : .black
        b.accessibilityLabel = "Xoá"
        b.addAction(UIAction { [weak self] _ in
            Self.clickDelete()
            self?.tapped(.backspace)
        }, for: .touchDown)
        // press & hold repeats (starts after 0.5s, ~11 Hz — Apple cadence)
        let long = UILongPressGestureRecognizer(target: self, action: #selector(backspaceHold(_:)))
        long.minimumPressDuration = 0.5
        b.addGestureRecognizer(long)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return b
    }

    @objc private func backspaceHold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            backspaceHoldStart = CACurrentMediaTime()
            wordDeleteTick = 0
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                guard let self else { return }
                // Apple accelerates a sustained hold: ~1.6s cadence doubles,
                // ~3s chuyển sang xoá theo từ (~2.8 từ/s).
                let held = CACurrentMediaTime() - self.backspaceHoldStart
                if held > 3.0, let deleteWord = self.onDeleteWord {
                    self.wordDeleteTick += 1
                    if self.wordDeleteTick % 4 == 1 { deleteWord() }
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

    /// Space-hold = trackpad mode: sliding left/right moves the caret,
    /// one position per ~9pt of travel (stock feel).
    @objc private func spaceHold(_ g: UILongPressGestureRecognizer) {
        let x = g.location(in: self).x
        switch g.state {
        case .began:
            spaceHoldX = x
            setTrackpadDimmed(true)
        case .changed:
            let delta = Int((x - spaceHoldX) / 9)
            if delta != 0 {
                tapped(.moveCursor(delta))
                spaceHoldX = x
            }
        case .ended, .cancelled, .failed:
            setTrackpadDimmed(false)
        default: break
        }
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

    /// Stock iOS flashes the layout name ("English (US)") on the spacebar when
    /// the keyboard appears. Same here: "ViệtTelex" for ~700ms, then fade.
    func showLanguageBadge() {
        guard let space = spaceBar else { return }
        let l = UILabel()
        l.text = "ViệtTelex"
        l.font = .systemFont(ofSize: 16, weight: .regular)
        l.textColor = dark ? .white : .black
        l.translatesAutoresizingMaskIntoConstraints = false
        spaceLogo?.isHidden = true     // logo Vᴛ nhường chỗ, khỏi đè lên badge
        space.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: space.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: space.centerYAnchor),
        ])
        UIView.animate(withDuration: 0.3, delay: 0.7, options: [.curveEaseOut]) {
            l.alpha = 0
        } completion: { [weak self] _ in
            l.removeFromSuperview()
            self?.spaceLogo?.isHidden = false
        }
    }

    // MARK: touch router cho phím chữ (ForwardingView-style)
    // UIButton event system có các mode fail đã biết (touch bị hệ thống cancel,
    // hit-test theo z-order thay vì khoảng cách, tracking per-control không
    // rollover được). Phím chữ tắt interaction; touch nổi lên đây và được gán
    // cho phím GẦN NHẤT — mọi điểm chạm trong vùng chữ đều trúng một phím.
    private var routedTouches: [ObjectIdentifier: UIButton] = [:]

    private func nearestLetterButton(at point: CGPoint) -> UIButton? {
        guard plane == .letters, !letterKeys.isEmpty else { return nil }
        var best: (UIButton, CGFloat)?
        for (b, _) in letterKeys {
            let f = convert(b.bounds, from: b)
            if f.insetBy(dx: -3, dy: -5.5).contains(point) { return b }
            let dx = max(f.minX - point.x, 0, point.x - f.maxX)
            let dy = max(f.minY - point.y, 0, point.y - f.maxY)
            let d = dx * dx + dy * dy
            if best == nil || d < best!.1 { best = (b, d) }
        }
        // chỉ nhận khi thật sự gần hàng phím chữ (~nửa chiều cao phím)
        if let (b, d) = best, d <= 21 * 21 { return b }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let b = nearestLetterButton(at: t.location(in: self)) else { continue }
            routedTouches[ObjectIdentifier(t)] = b
            b.sendActions(for: .touchDown)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let b = routedTouches.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            b.sendActions(for: .touchUpInside)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // hệ thống cancel (edge gesture…) — vẫn CHỐT chữ thay vì nuốt phím
        for t in touches {
            guard let b = routedTouches.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            b.sendActions(for: .touchUpInside)
        }
    }

    private func tapped(_ key: Key) { onKey(key) }
}
