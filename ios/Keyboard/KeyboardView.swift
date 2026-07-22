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
        case newline
        case backspace
    }

    private enum Plane { case letters, numbers, symbols }
    private enum ShiftState { case off, on, caps }

    var enableInputClicksWhenVisible: Bool { true }

    private let onKey: (Key) -> Void
    private let onGlobe: (UIButton) -> Void
    private let needsGlobe: Bool

    private var plane: Plane = .letters
    private var shift: ShiftState = .on          // Apple: sentence start = shifted
    private var returnTitle = "return"
    private var dark = false
    private var lastShiftTap: TimeInterval = 0

    private var rowsContainer = UIStackView()
    private var repeatTimer: Timer?

    init(needsGlobe: Bool, onKey: @escaping (Key) -> Void, onGlobe: @escaping (UIButton) -> Void) {
        self.needsGlobe = needsGlobe
        self.onKey = onKey
        self.onGlobe = onGlobe
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 216).isActive = true
        rowsContainer.axis = .vertical
        rowsContainer.distribution = .fillEqually
        rowsContainer.spacing = 0
        rowsContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsContainer)
        NSLayoutConstraint.activate([
            rowsContainer.leftAnchor.constraint(equalTo: leftAnchor),
            rowsContainer.rightAnchor.constraint(equalTo: rightAnchor),
            rowsContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rowsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

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

    // MARK: layout

    private func rebuild() {
        rowsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch plane {
        case .letters: buildLetters()
        case .numbers: buildPlane(rows: [
            ["1","2","3","4","5","6","7","8","9","0"],
            ["-","/",":",";","(",")","₫","&","@","\""],
        ], moreKey: "#+=", altKey: "ABC")
        case .symbols: buildPlane(rows: [
            ["[","]","{","}","#","%","^","*","+","="],
            ["_","\\","|","~","<",">","$","£","¥","•"],
        ], moreKey: "123", altKey: "ABC")
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
        if needsGlobe {
            let globe = baseButton(title: "", special: true)
            globe.setImage(UIImage(systemName: "globe"), for: .normal)
            globe.tintColor = dark ? .white : .black
            globe.addAction(UIAction { [weak self, weak globe] _ in
                if let g = globe { self?.onGlobe(g) }
            }, for: .touchUpInside)
            views.append(globe)
        }
        let space = controlButton(title: "space") { [weak self] in self?.tapped(.space) }
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(space)
        let ret = controlButton(title: returnTitle) { [weak self] in self?.tapped(.newline) }
        views.append(ret)

        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 3, bottom: 5, right: 3)
        planeBtn.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.12).isActive = true
        ret.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.24).isActive = true
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
    }

    private func baseButton(title: String, special: Bool) -> KeyButton {
        let b = KeyButton(type: .system)
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

    private func letterButton(_ s: String) -> UIView {
        let title = (shift == .off) ? s : s.uppercased()
        let b = baseButton(title: title, special: false)
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let cased: Character = (self.shift == .off) ? Character(s) : Character(s.uppercased())
            self.tapped(.letter(cased))
            if self.shift == .on { self.shift = .off; self.rebuild() }
        }, for: .touchUpInside)
        return b
    }

    private func textButton(_ s: String) -> UIView {
        let b = baseButton(title: s, special: false)
        b.addAction(UIAction { [weak self] _ in self?.tapped(.text(s)) }, for: .touchUpInside)
        return b
    }

    private func controlButton(title: String, action: @escaping () -> Void) -> KeyButton {
        let b = baseButton(title: title, special: true)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func shiftButton() -> UIView {
        let symbol = shift == .caps ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
        let b = baseButton(title: "", special: true)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = (shift != .off) ? (dark ? .white : .black) : (dark ? .white : .black)
        if shift != .off && !dark { b.backgroundColor = .white }
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if now - self.lastShiftTap < 0.3 { self.shift = .caps }
            else { self.shift = (self.shift == .off) ? .on : .off }
            self.lastShiftTap = now
            self.rebuild()
        }, for: .touchUpInside)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return b
    }

    private func backspaceButton() -> UIView {
        let b = baseButton(title: "", special: true)
        b.setImage(UIImage(systemName: "delete.left"), for: .normal)
        b.tintColor = dark ? .white : .black
        b.addAction(UIAction { [weak self] _ in self?.tapped(.backspace) }, for: .touchDown)
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
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                self?.tapped(.backspace)
            }
        case .ended, .cancelled, .failed:
            repeatTimer?.invalidate()
            repeatTimer = nil
        default: break
        }
    }

    private func tapped(_ key: Key) { onKey(key) }
}
