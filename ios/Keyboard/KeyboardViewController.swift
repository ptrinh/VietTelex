// VietTelex iOS keyboard — M1: working QWERTY that types Vietnamese via
// TelexEngine diff-edits. UI is programmatic UIKit, laid out to Apple's stock
// metrics (fidelity pass = M2). No Full Access, no network, no timers at idle.
import UIKit
import TelexCore

final class KeyboardViewController: UIInputViewController {

    private var bridge = EngineBridge()
    private var keyboard: KeyboardView!
    private let langModel = UserLangModel()
    private var lastWord: String?         // từ liền trước trong câu (context bigram)
    private var lastWord2: String?        // từ trước nữa (context trigram)
    private var learnEnabled = true
    private var filterSensitive = true

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboard = KeyboardView(
            needsGlobe: needsInputModeSwitchKey,
            onKey: { [weak self] key in self?.handle(key) },
            onGlobe: { [weak self] sender in
                self?.handleInputModeList(from: sender, with: UIEvent())
            }
        )
        langModel.isKnownWord = { VNSuggest.contains($0) }
        // Datastore trống (lần đầu / vừa reset) → mồi bằng seed corpus để
        // ngày đầu tiên đã có gợi ý hợp lý; dữ liệu học thật vượt seed sau
        // vài ngày (weight seed ≤50, gõ thật +1/lần, decay tuần).
        langModel.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
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
        let settings = KeyboardSettings.load()
        learnEnabled = settings.learnWords
        filterSensitive = settings.filterSensitive
        keyboard.setSuggestionsEnabled(settings.showSuggestions && traitsAllow)
        keyboard.onSuggestion = { [weak self] item in self?.acceptSuggestion(item) }
        updateAutoShift()
        updateSuggestions()            // field trống → gợi mở đầu ngay khi hiện
        keyboard.showLanguageBadge()   // "ViệtTelex" thoáng trên spacebar như stock
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        langModel.save()
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
        if !applyingEdit { bridge.reset(); lastWord = nil; lastWord2 = nil }
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
            commitAndLearn(bridge.boundary(s, proxy: proxy))
            lastWord = nil; lastWord2 = nil            // dấu câu/ký hiệu = ngắt câu
        case .space:
            commitAndLearn(bridge.boundary(" ", proxy: proxy))
        case .doubleSpacePeriod:
            // Apple: double-space converts the just-typed space into ". "
            if textDocumentProxy.documentContextBeforeInput?.hasSuffix(" ") == true {
                textDocumentProxy.deleteBackward()
                textDocumentProxy.insertText(". ")
                lastWord = nil; lastWord2 = nil
            } else {
                commitAndLearn(bridge.boundary(" ", proxy: proxy))
            }
        case .moveCursor(let delta):
            bridge.reset()                        // caret moved → composition gone
            lastWord = nil; lastWord2 = nil
            textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
        case .newline:
            commitAndLearn(bridge.boundary("\n", proxy: proxy))
            lastWord = nil; lastWord2 = nil
        case .backspace:
            bridge.backspace(proxy: proxy)
            if !bridge.isComposing { lastWord = nil; lastWord2 = nil }  // xoá lấn vào chữ cũ → context mờ
        }
        UIDevice.current.playInputClick()
        switch key {
        case .space, .newline, .doubleSpacePeriod, .backspace, .moveCursor:
            updateAutoShift()
        default: break
        }
        // Gợi ý tính SAU khi ký tự đã lên màn hình (async main) và coalesce
        // theo generation — gõ nhanh chỉ tính cho phím cuối, không chặn render.
        suggestionGen += 1
        let gen = suggestionGen
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.suggestionGen else { return }
            self.updateSuggestions()
        }
    }

    private var suggestionGen = 0

    /// Từ vừa chốt: nạp vào model cá nhân + trượt cửa sổ context (prev2, prev1).
    /// `accepted` = user bấm nhận suggestion → weight 2 (tín hiệu mạnh hơn).
    private func commitAndLearn(_ word: String, accepted: Bool = false) {
        guard !word.isEmpty else { return }
        if learnEnabled {
            langModel.record(word: word, after: lastWord, prev2: lastWord2,
                             weight: accepted ? 2 : 1)
        }
        if UserLangModel.learnable(word) {
            lastWord2 = lastWord
            lastWord = word
        } else {
            lastWord = nil; lastWord2 = nil
        }
    }

    /// Gợi ý cho từ đang gõ: emoji (khớp cả "yêu" lẫn "love" — bảng
    /// EmojiSuggest) + hoàn thiện từ tiếng Việt từ VNLexicon ("nguoi"/"ng" →
    /// "người"): ưu tiên ứng viên chỉ khác dấu, rồi completion dài hơn.
    /// Đuôi email/domain phổ biến — rule cứng theo ngữ cảnh, không qua datastore
    /// (token chứa @/. không phải "từ" học được).
    private static let emailSuffixes = ["gmail.com", "yahoo.com", "outlook.com"]
    private static let domainTLDs = ["com", "vn", "net"]

    private func updateSuggestions() {
        let composed = bridge.composedWord
        var set = KeyboardView.SuggestionSet()
        // Ngữ cảnh email/domain: "phuc@" → gợi đuôi mail; "github." → gợi TLD.
        if composed.isEmpty, let before = textDocumentProxy.documentContextBeforeInput,
           let last = before.split(separator: " ").last {
            if last.hasSuffix("@"), last.count > 1 {
                keyboard.showSuggestions(.init(nextWords: Self.emailSuffixes))
                return
            }
            if last.hasSuffix("."), last.count > 1,
               last.dropLast().allSatisfy({ $0.isLetter || $0.isNumber }) {
                keyboard.showSuggestions(.init(nextWords: Self.domainTLDs))
                return
            }
        }
        if !composed.isEmpty {
            set.literal = composed
            // Inline suggestion (research 2026-07-24): pool tương thích dấu từ
            // VNSuggest, re-rank = log(staticFreq) + λ₁·log(personal) +
            // λ₂·context-bonus + λ₃·chỉ-còn-thiếu-dấu.
            let pool = VNSuggest.matches(composed, poolLimit: 24,
                                         excluding: composed.lowercased())
            if !pool.isEmpty {
                let ctx: Set<String> = lastWord.map {
                    Set(langModel.nextWords(after: $0, prev2: lastWord2, limit: 24))
                } ?? []
                let typedLen = composed.count
                func score(_ w: String, _ f: Int) -> Double {
                    log(Double(f) + 1)
                        + 2.5 * log(Double(langModel.count(of: w)) + 1)
                        + (ctx.contains(w) ? 4 : 0)
                        + (w.count == typedLen ? 1.5 : 0)
                }
                let ranked = SensitiveWords.filter(pool.sorted {
                    score($0.word, $0.freq) > score($1.word, $1.freq)
                }.map { $0.word }, enabled: filterSensitive)
                set.word = ranked.first.map(DisplayCase.apply)
                set.word2 = ranked.dropFirst().first.map(DisplayCase.apply)
            }
            var emojis = EmojiSuggest.emojis(for: composed)
            if emojis.isEmpty { emojis = EmojiSuggest.emojis(for: bridge.rawWord.lowercased()) }
            set.emojis = emojis
        } else if let prev = lastWord {
            // vừa space sau một từ → gợi từ KẾ TIẾP (trigram/bigram cá nhân
            // interpolate với seed)
            set.nextWords = SensitiveWords.filter(
                langModel.nextWords(after: prev, prev2: lastWord2, limit: 6),
                enabled: filterSensitive
            ).prefix(3).map(DisplayCase.apply)
        } else {
            // field trống chưa gõ gì → từ user hay mở đầu nhất
            set.nextWords = SensitiveWords.filter(langModel.topWords(limit: 6),
                                                  enabled: filterSensitive)
                .prefix(3).map(DisplayCase.apply)
        }
        keyboard.showSuggestions(set)
    }

    /// Tap gợi ý (hành vi QuickType): emoji thay hẳn từ; từ tiếng Việt thay
    /// từ + thêm space để gõ tiếp luôn.
    private func acceptSuggestion(_ item: String) {
        applyingEdit = true
        defer { applyingEdit = false }
        let isFragment = item.contains(".") || item.contains("@")   // gmail.com, com…
        let isWord = !isFragment && item.first?.isLetter == true
        let n = bridge.composedWord.count
        for _ in 0..<n { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(isWord ? item + " " : item)
        bridge.reset()
        if isWord { commitAndLearn(item, accepted: true) } else { lastWord = nil; lastWord2 = nil }
        UIDevice.current.playInputClick()
        updateAutoShift()
        updateSuggestions()
    }
}

extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
