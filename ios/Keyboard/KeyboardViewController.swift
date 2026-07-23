// VietTelex iOS keyboard — M1: working QWERTY that types Vietnamese via
// TelexEngine diff-edits. UI is programmatic UIKit, laid out to Apple's stock
// metrics (fidelity pass = M2). No Full Access, no network, no timers at idle.
import UIKit
import TelexCore

final class KeyboardViewController: UIInputViewController {

    private var bridge = EngineBridge()
    private var keyboard: KeyboardView!

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboard = KeyboardView(
            needsGlobe: needsInputModeSwitchKey,
            onKey: { [weak self] key in self?.handle(key) },
            onGlobe: { [weak self] sender in
                self?.handleInputModeList(from: sender, with: UIEvent())
            }
        )
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leftAnchor.constraint(equalTo: view.leftAnchor),
            keyboard.rightAnchor.constraint(equalTo: view.rightAnchor),
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        bridge = EngineBridge()                       // fresh settings + buffer
        keyboard.configureReturnKey(type: textDocumentProxy.returnKeyType ?? .default)
        keyboard.applyAppearance(textDocumentProxy.keyboardAppearance ?? .default)
        // Thanh gợi ý: gate qua toggle trong app; tự tắt ở field từ chối
        // gợi ý (mật khẩu, autocorrection = .no) — đúng hành vi stock.
        let traitsAllow = textDocumentProxy.autocorrectionType != .no
            && (textDocumentProxy as UITextInputTraits).isSecureTextEntry != true
        keyboard.setSuggestionsEnabled(KeyboardSettings.load().showSuggestions && traitsAllow)
        keyboard.onSuggestion = { [weak self] item in self?.acceptSuggestion(item) }
        updateAutoShift()
        keyboard.showLanguageBadge()   // "ViệtTelex" thoáng trên spacebar như stock
    }

    /// Apple behavior: shift turns on at sentence start when the field asks for
    /// .sentences autocapitalization (empty context, or after ".!?" + space).
    private func updateAutoShift() {
        guard textDocumentProxy.autocapitalizationType == .sentences else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let t = before.trimmingCharacters(in: .whitespaces)
        let auto = before.isEmpty
            || (before.hasSuffix(" ") && (t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?")))
            || before.hasSuffix("\n")
        keyboard.setAutoShift(auto)
    }

    override func textWillChange(_ textInput: UITextInput?) {
        // Selection is about to change from OUTSIDE our own edits (tap elsewhere,
        // field switch) — the composition anchor is gone. Our own proxy edits do
        // not call this re-entrantly during handle().
        if !applyingEdit { bridge.reset() }
    }

    private var applyingEdit = false

    private struct Proxy: TextProxyLike {
        let p: UITextDocumentProxy
        func insertText(_ text: String) { p.insertText(text) }
        func deleteBackward() { p.deleteBackward() }
        var isSecure: Bool { (p as? UITextInputTraits)?.isSecureTextEntry ?? false }
    }

    private func handle(_ key: KeyboardView.Key) {
        let proxy = Proxy(p: textDocumentProxy)
        applyingEdit = true
        defer { applyingEdit = false }
        switch key {
        case .letter(let ch):
            bridge.letter(ch, proxy: proxy)
        case .text(let s):                            // numbers, symbols
            bridge.boundary(s, proxy: proxy)
        case .space:
            bridge.boundary(" ", proxy: proxy)
        case .doubleSpacePeriod:
            // Apple: double-space converts the just-typed space into ". "
            if textDocumentProxy.documentContextBeforeInput?.hasSuffix(" ") == true {
                textDocumentProxy.deleteBackward()
                textDocumentProxy.insertText(". ")
            } else {
                bridge.boundary(" ", proxy: proxy)
            }
        case .moveCursor(let delta):
            bridge.reset()                        // caret moved → composition gone
            textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
        case .newline:
            bridge.boundary("\n", proxy: proxy)
        case .backspace:
            bridge.backspace(proxy: proxy)
        }
        UIDevice.current.playInputClick()
        switch key {
        case .space, .newline, .doubleSpacePeriod, .backspace, .moveCursor:
            updateAutoShift()
        default: break
        }
        updateSuggestions()
    }

    /// Gợi ý cho từ đang gõ: emoji (khớp cả "yêu" lẫn "love" — bảng
    /// EmojiSuggest) + hoàn thiện từ tiếng Việt từ VNLexicon ("nguoi"/"ng" →
    /// "người"): ưu tiên ứng viên chỉ khác dấu, rồi completion dài hơn.
    private func updateSuggestions() {
        let composed = bridge.composedWord
        var set = KeyboardView.SuggestionSet()
        if !composed.isEmpty {
            set.literal = composed
            set.word = VNLexicon.completions(forFolded: VNLexicon.fold(composed),
                                             limit: 1, excluding: composed.lowercased()).first
            var emojis = EmojiSuggest.emojis(for: composed)
            if emojis.isEmpty { emojis = EmojiSuggest.emojis(for: bridge.rawWord.lowercased()) }
            set.emojis = emojis
        }
        keyboard.showSuggestions(set)
    }

    /// Tap gợi ý (hành vi QuickType): emoji thay hẳn từ; từ tiếng Việt thay
    /// từ + thêm space để gõ tiếp luôn.
    private func acceptSuggestion(_ item: String) {
        applyingEdit = true
        defer { applyingEdit = false }
        let isWord = item.first?.isLetter == true
        let n = bridge.composedWord.count
        for _ in 0..<n { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(isWord ? item + " " : item)
        bridge.reset()
        keyboard.showSuggestions(KeyboardView.SuggestionSet())
        UIDevice.current.playInputClick()
        updateAutoShift()
    }
}

extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
