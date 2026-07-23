// KeyboardView — programmatic UIKit clone of Apple's Vietnamese keyboard.
// M1: letters plane + shift/caps + backspace (with repeat) + 123 plane +
// globe/space/return. Metrics follow Apple's stock layout; the pixel-perfect
// fidelity pass (balloons, exact colors per appearance, iPad) is M2.
import UIKit
import AudioToolbox

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
    private let onGlobe: (UIButton) -> Void
    private let needsGlobe: Bool

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
    private var repeatTimer: Timer?
    private var lastSpaceTap: TimeInterval = 0
    private var spaceHoldX: CGFloat = 0
    private var backspaceHoldStart: TimeInterval = 0

    init(needsGlobe: Bool, onKey: @escaping (Key) -> Void, onGlobe: @escaping (UIButton) -> Void) {
        self.needsGlobe = needsGlobe
        self.onKey = onKey
        self.onGlobe = onGlobe
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
        NSLayoutConstraint.activate([
            rowsContainer.leftAnchor.constraint(equalTo: leftAnchor),
            rowsContainer.rightAnchor.constraint(equalTo: rightAnchor),
            rowsContainer.heightAnchor.constraint(equalToConstant: 212),
            rowsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
        ])
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

    /// Bật/tắt thanh gợi ý: mở rộng khoảng trống phía trên vừa đủ (44pt).
    func setSuggestionsEnabled(_ on: Bool) {
        suggestionsEnabled = on
        suggestionBar.isHidden = !on
        // strip 32pt sát nút (user 2026-07-24: A/B/C về zero) — phần C dưới
        // hàng phím cuối là vùng globe/mic hệ thống, không thuộc view mình.
        heightConstraint?.constant = on ? 246 : 216
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
        let ink: UIColor = dark ? .white : .black
        for d in slotDividers {
            d.viewWithTag(77)?.backgroundColor = ink.withAlphaComponent(0.18)
        }

        // gom nội dung 3 slot chính: nextWords HOẶC literal/word/word2
        var texts: [(display: String, insert: String)?] = [nil, nil, nil]
        if !set.nextWords.isEmpty {
            for (i, w) in set.nextWords.prefix(3).enumerated() { texts[i] = (w, w) }
        } else {
            if let l = set.literal { texts[0] = ("\u{201C}\(l)\u{201D}", l) }
            if let w = set.word { texts[1] = (w, w) }
            if set.emojis.isEmpty, let w2 = set.word2 { texts[2] = (w2, w2) }
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
        dark = appearance == .dark
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
    private var shiftKey: UIButton?
    private func applyShiftAppearance() {
        for (b, s) in letterKeys {
            b.setTitle(shift == .off ? s : s.uppercased(), for: .normal)
        }
        if let b = shiftKey {
            let symbol = shift == .caps ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
            b.setImage(UIImage(systemName: symbol), for: .normal)
            b.backgroundColor = (shift != .off && !dark)
                ? .white
                : (dark ? UIColor(white: 1, alpha: 0.14) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1))
        }
    }


    // MARK: layout

    private func rebuild() {
        letterKeys.removeAll()
        shiftKey = nil
        rowsContainer.distribution = .fillEqually
        rowsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
        var third: [UIView] = [controlButton(title: moreKey) { [weak self] in
            guard let self else { return }
            self.plane = (self.plane == .numbers) ? .symbols : .numbers
            self.rebuild()
        }]
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
        views.append(planeBtn)
        // nút emoji bên trái space — icon đơn sắc như stock (user 2026-07-23)
        let emojiBtn = controlButton(title: "") { [weak self] in
            guard let self else { return }
            self.plane = .emoji
            self.rebuild()
        }
        emojiBtn.setImage(UIImage(systemName: "face.smiling.inverse",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)), for: .normal)
        emojiBtn.tintColor = dark ? .white : .black
        views.append(emojiBtn)
        if needsGlobe {
            let globe = baseButton(title: "", special: true)
            globe.setImage(UIImage(systemName: "globe"), for: .normal)
            globe.tintColor = dark ? .white : .black
            globe.addAction(UIAction { [weak self, weak globe] _ in
                if let g = globe { self?.onGlobe(g) }
            }, for: .touchUpInside)
            views.append(globe)
        }
        let space = baseButton(title: "", special: true)
        space.backgroundColor = dark ? UIColor(white: 1, alpha: 0.30) : .white
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
        comma.addAction(UIAction { [weak self] _ in self?.tapped(.text(",")) }, for: .touchUpInside)
        views.append(comma)
        let ret = controlButton(title: returnTitle == "return" ? "" : returnTitle) { [weak self] in
            self?.tapped(.newline)
        }
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
        ret.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.20).isActive = true
        return stack
    }

    private func row(_ views: [UIView], sideInset: CGFloat = 0) -> UIView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillProportionally
        stack.isLayoutMarginsRelativeArrangement = true
        let unit = UIScreen.main.bounds.width / 10
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 3 + sideInset * unit,
                                           bottom: 5, right: 3 + sideInset * unit)
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
        b.titleLabel?.font = .systemFont(ofSize: special ? 16 : 23)
        b.layer.cornerRadius = 5
        b.setTitleColor(dark ? .white : .black, for: .normal)
        b.backgroundColor = special
            ? (dark ? UIColor(white: 1, alpha: 0.14) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1))
            : (dark ? UIColor(white: 1, alpha: 0.30) : .white)
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.layer.shadowOpacity = dark ? 0 : 0.35
        b.layer.shadowRadius = 0
        return b
    }

    // Âm click phát ở TOUCH-DOWN như stock (nguồn cảm giác "nhanh"), qua
    // AudioServices — không cần Full Access: 1123 chữ, 1155 backspace, 1156 phím
    // chức năng (kinh nghiệm IME cộng đồng).
    static func clickLetter() { AudioServicesPlaySystemSound(1123) }
    static func clickDelete() { AudioServicesPlaySystemSound(1155) }
    static func clickModifier() { AudioServicesPlaySystemSound(1156) }

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
    private func showBalloon(over key: UIView, text: String) {
        balloon.text = text
        balloon.font = .systemFont(ofSize: 34)
        balloon.textAlignment = .center
        balloon.textColor = dark ? .white : .black
        balloon.backgroundColor = dark ? UIColor(white: 0.35, alpha: 1) : .white
        balloon.layer.cornerRadius = 8
        balloon.layer.masksToBounds = true
        balloon.layer.zPosition = 10
        let f = convert(key.bounds, from: key)
        let w = max(f.width + 16, 44)
        balloon.frame = CGRect(x: f.midX - w / 2, y: max(f.minY - 52, -6), width: w, height: 50)
        if balloon.superview == nil { addSubview(balloon) }
        balloon.isHidden = false
    }
    private func hideBalloon() { balloon.isHidden = true }

    private func textButton(_ s: String) -> UIView {
        let b = baseButton(title: s, special: false)
        b.addAction(UIAction { _ in Self.clickLetter() }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in self?.tapped(.text(s)) }, for: .touchUpInside)
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
        b.tintColor = dark ? .white : .black
        if shift != .off && !dark { b.backgroundColor = .white }
        shiftKey = b
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if now - self.lastShiftTap < 0.3 { self.shift = .caps }
            else { self.shift = (self.shift == .off) ? .on : .off }
            self.lastShiftTap = now
            self.applyShiftAppearance()
        }, for: .touchUpInside)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return b
    }

    private func backspaceButton() -> UIView {
        let b = baseButton(title: "", special: true)
        b.setImage(UIImage(systemName: "delete.left"), for: .normal)
        b.tintColor = dark ? .white : .black
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
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                guard let self else { return }
                // Apple accelerates a sustained hold: after ~1.6s the cadence
                // doubles (word-wise deletion comes later if ever needed).
                self.tapped(.backspace)
                if CACurrentMediaTime() - self.backspaceHoldStart > 1.6 {
                    self.tapped(.backspace)
                }
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
        case .changed:
            let delta = Int((x - spaceHoldX) / 9)
            if delta != 0 {
                tapped(.moveCursor(delta))
                spaceHoldX = x
            }
        default: break
        }
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
        space.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: space.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: space.centerYAnchor),
        ])
        UIView.animate(withDuration: 0.3, delay: 0.7, options: [.curveEaseOut]) {
            l.alpha = 0
        } completion: { _ in
            l.removeFromSuperview()
        }
    }

    private func tapped(_ key: Key) { onKey(key) }
}
