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
            inputController: self,     // globe key addTarget thẳng vào handleInputModeList
            onKey: { [weak self] key in self?.handle(key) }
        )
        langModel.isKnownWord = { VNSuggest.contains($0) }
        // Datastore trống (lần đầu / vừa reset) → mồi bằng seed corpus để
        // ngày đầu tiên đã có gợi ý hợp lý; dữ liệu học thật vượt seed sau
        // vài ngày (weight seed ≤50, gõ thật +1/lần, decay tuần).
        langModel.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        // Load plist chạy nền — bar mở-đầu refresh khi dữ liệu sẵn sàng.
        langModel.onReady = { [weak self] in self?.updateSuggestions() }
        keyboard.onDeleteWord = { [weak self] in self?.deleteWordBackward() }
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
        lastKeyWasEmailTrigger = false
        restoreUndo = nil; undoOfferActive = false
        keyboard.configureReturnKey(type: textDocumentProxy.returnKeyType ?? .default)
        keyboard.applyAppearance(textDocumentProxy.keyboardAppearance ?? .default)
        // Thanh gợi ý: gate qua toggle trong app; tự tắt ở field từ chối
        // gợi ý (mật khẩu, autocorrection = .no) — đúng hành vi stock.
        let traitsAllow = textDocumentProxy.autocorrectionType != .no
            && (textDocumentProxy as UITextInputTraits).isSecureTextEntry != true
        let settings = KeyboardSettings.load()
        learnEnabled = settings.learnWords
        filterSensitive = settings.filterSensitive
        suggestionsActive = settings.showSuggestions && traitsAllow
        keyboard.setSuggestionsEnabled(suggestionsActive)
        keyboard.onSuggestion = { [weak self] item in self?.acceptSuggestion(item) }
        updateAutoShift()
        updateSuggestions()            // field trống → gợi mở đầu ngay khi hiện
        keyboard.showLanguageBadge()   // "ViệtTelex" thoáng trên spacebar như stock
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        langModel.saveNow()   // extension có thể bị kill ngay sau disappear
    }

    // Host truyền .default là thường — dark/light thật nằm ở trait hệ thống,
    // đổi giữa chừng (auto dark theo giờ…) phải áp lại appearance.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            keyboard?.applyAppearance(textDocumentProxy.keyboardAppearance ?? .default)
        }
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
        autoShiftOn = auto
        keyboard.setAutoShift(auto)
    }

    override func textWillChange(_ textInput: UITextInput?) {
        // Selection is about to change from OUTSIDE our own edits (tap elsewhere,
        // field switch) — the composition anchor is gone. Our own proxy edits do
        // not call this re-entrantly during handle().
        if !applyingEdit {
            bridge.reset(); lastWord = nil; lastWord2 = nil
            restoreUndo = nil; undoOfferActive = false
        }
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
            restoreUndo = nil; undoOfferActive = false
        case .text(let s):                            // numbers, symbols
            commitAndLearn(bridge.boundary(s, proxy: proxy))
            lastWord = nil; lastWord2 = nil            // dấu câu/ký hiệu = ngắt câu
            restoreUndo = nil; undoOfferActive = false
        case .space:
            let composedBefore = bridge.composedWord
            let committed = bridge.boundary(" ", proxy: proxy)
            // Auto-restore vừa ghi đè dạng có dấu → nhớ lại cho backspace-undo.
            restoreUndo = (!composedBefore.isEmpty && committed != composedBefore)
                ? (raw: committed, composed: composedBefore) : nil
            undoOfferActive = false
            lastSpaceAfterText = !composedBefore.isEmpty
            commitAndLearn(committed)
        case .doubleSpacePeriod:
            // Apple: double-space converts the just-typed space into ". ".
            // Track bằng state thay vì documentContextBeforeInput — đọc proxy
            // là XPC round-trip, không được nằm trên hot path. Yêu cầu có chữ
            // trước space đầu (không biến "␣␣" ở đầu field thành ". ").
            if lastInsertWasSpace && lastSpaceAfterText {
                textDocumentProxy.deleteBackward()
                textDocumentProxy.insertText(". ")
                lastWord = nil; lastWord2 = nil
            } else {
                commitAndLearn(bridge.boundary(" ", proxy: proxy))
            }
            restoreUndo = nil; undoOfferActive = false
        case .moveCursor(let delta):
            bridge.reset()                        // caret moved → composition gone
            lastWord = nil; lastWord2 = nil
            restoreUndo = nil; undoOfferActive = false
            textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
        case .newline:
            commitAndLearn(bridge.boundary("\n", proxy: proxy))
            lastWord = nil; lastWord2 = nil
            restoreUndo = nil; undoOfferActive = false
        case .backspace:
            // Backspace NGAY SAU space có restore → xoá space và chào lại dạng
            // có dấu ở slot literal (trust fix cho collision kiểu "his"≡"hí").
            if !bridge.isComposing, lastInsertWasSpace, restoreUndo != nil {
                undoOfferActive = true
            } else {
                restoreUndo = nil; undoOfferActive = false
            }
            bridge.backspace(proxy: proxy)
            if !bridge.isComposing { lastWord = nil; lastWord2 = nil }  // xoá lấn vào chữ cũ → context mờ
        }
        switch key {
        case .space, .doubleSpacePeriod: lastInsertWasSpace = true
        default: lastInsertWasSpace = false
        }
        if case .text(let s) = key, s == "@" || s == "." {
            lastKeyWasEmailTrigger = true
        } else {
            lastKeyWasEmailTrigger = false
        }
        // updateAutoShift đọc documentContextBeforeInput (XPC) → cùng khối
        // async với suggestions, coalesce theo generation: gõ nhanh chỉ tính
        // cho phím cuối, ký tự không bao giờ chờ. Sound đã phát ở touch-down.
        let needsAutoShift: Bool
        switch key {
        case .space, .newline, .doubleSpacePeriod, .backspace, .moveCursor: needsAutoShift = true
        default: needsAutoShift = false
        }
        suggestionGen += 1
        let gen = suggestionGen
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.suggestionGen else { return }
            if needsAutoShift { self.updateAutoShift() }
            self.updateSuggestions()
        }
    }

    private var suggestionGen = 0
    private var lastInsertWasSpace = false
    private var autoShiftOn = false
    private var suggestionsActive = true
    /// Phím vừa gõ là "@" hoặc "." → rule email/TLD mới có thể ăn; chỉ khi đó
    /// mới đáng trả giá XPC đọc documentContextBeforeInput.
    private var lastKeyWasEmailTrigger = false
    /// Space vừa rồi có chữ đứng trước không — chặn double-space ". " ở đầu field.
    private var lastSpaceAfterText = false
    /// (raw đã chốt, dạng có dấu) khi auto-restore ghi đè — backspace ngay sau đó
    /// mở lại lối thoát: slot literal hiện dạng có dấu để 1 tap đổi từ.
    private var restoreUndo: (raw: String, composed: String)?
    private var undoOfferActive = false
    private var ctxCacheKey: String?
    private var ctxCache: Set<String> = []

    /// iOS defer touch gần mép ~1s để phân xử system gesture — nguồn số 1 của
    /// "ấn phím hàng dưới không ăn". Xin quyền nhận touch trước ở mép dưới.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.bottom] }

    /// Xoá theo TỪ khi giữ backspace lâu (>3s) — gesture giữ, không phải hot
    /// path nên đọc proxy (XPC) mỗi từ là chấp nhận được.
    private func deleteWordBackward() {
        applyingEdit = true
        defer { applyingEdit = false }
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard !before.isEmpty else { return }
        var chars = Array(before)
        var count = 0
        while let c = chars.last, c == " " || c == "\n" { chars.removeLast(); count += 1 }
        while let c = chars.last, !(c == " " || c == "\n") { chars.removeLast(); count += 1 }
        for _ in 0..<max(count, 1) { textDocumentProxy.deleteBackward() }
        updateAutoShift()
        updateSuggestions()
    }

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
        guard suggestionsActive else { return }       // bar tắt → khỏi tính toán
        let composed = bridge.composedWord
        var set = KeyboardView.SuggestionSet()
        // đầu câu (auto-shift): gợi ý viết hoa chữ đầu như stock (Em, Anh, Tôi)
        func caseForContext(_ w: String) -> String {
            autoShiftOn ? w.prefix(1).uppercased() + w.dropFirst() : w
        }
        // Backspace-undo sau auto-restore: chào dạng có dấu ở slot literal.
        if composed.isEmpty, undoOfferActive, let u = restoreUndo {
            set.literal = u.composed
        }
        // Ngữ cảnh email/domain: "phuc@" → gợi đuôi mail; "github." → gợi TLD.
        // Đọc proxy (XPC) chỉ khi phím vừa gõ là @/. — không phải mọi boundary.
        if composed.isEmpty, lastKeyWasEmailTrigger,
           let before = textDocumentProxy.documentContextBeforeInput,
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
            // Slot "nguyên văn" = phương án mà boundary SẼ KHÔNG cho ra —
            // lối thoát cho cả hai chiều collision (user chốt 2026-07-24):
            //   gõ l,o,s,s → boundary restore "loss"  → slot hiện "los" (composed)
            //   gõ l,o,s   → boundary giữ "ló"        → slot hiện "los" (raw)
            // Tap = chèn + reset engine nên boundary sau đó không restore nữa.
            let predicted = bridge.predictedCommit
            set.literal = predicted == composed ? bridge.rawWord : composed
            // Inline suggestion (research 2026-07-24): pool tương thích dấu từ
            // VNSuggest, re-rank = log(staticFreq) + λ₁·log(personal) +
            // λ₂·context-bonus + λ₃·chỉ-còn-thiếu-dấu.
            let pool = VNSuggest.matches(composed, poolLimit: 24,
                                         excluding: composed.lowercased())
            if !pool.isEmpty {
                // ctx chỉ đổi khi (lastWord, lastWord2) đổi — cache, khỏi gọi
                // nextWords mỗi keystroke trong lúc đang gõ dở một từ.
                let ctxKey = (lastWord ?? "") + "\u{1}" + (lastWord2 ?? "")
                if ctxKey != ctxCacheKey {
                    ctxCache = lastWord.map {
                        Set(langModel.nextWords(after: $0, prev2: lastWord2, limit: 24))
                    } ?? []
                    ctxCacheKey = ctxKey
                }
                let ctx = ctxCache
                let typedLen = composed.count
                func score(_ w: String, _ f: Int) -> Double {
                    log(Double(f) + 1)
                        + 2.5 * log(Double(langModel.count(of: w)) + 1)
                        + (ctx.contains(w) ? 4 : 0)
                        + (w.count == typedLen ? 1.5 : 0)
                }
                // score tính 1 lần/ứng viên rồi sort tuple — không gọi lại
                // trong comparator (2·n·log n lần).
                let scored = pool.map { ($0.word, score($0.word, $0.freq)) }
                let ranked = SensitiveWords.filter(
                    scored.sorted { $0.1 > $1.1 }.map { $0.0 },
                    enabled: filterSensitive)
                set.word = ranked.first.map { DisplayCase.apply($0, after: lastWord) }
                set.word2 = ranked.dropFirst().first.map { DisplayCase.apply($0, after: lastWord) }
            }
            // thử cụm 2 từ trước ("hoàn thành", "sinh nhật") rồi mới tới từ đơn.
            // Từ trigger nằm trong bộ lọc nhạy cảm (vcl…) → emoji cũng ẩn khi
            // filter bật, nhất quán với chính sách gợi ý từ.
            var emojis: [String] = []
            let cLow = composed.lowercased()
            let sensitiveTrigger = filterSensitive && SensitiveWords.set.contains(cLow)
            if !sensitiveTrigger {
                if let prev = lastWord {
                    emojis = EmojiSuggest.emojis(for: prev.lowercased() + " " + cLow)
                }
                if emojis.isEmpty { emojis = EmojiSuggest.emojis(for: composed) }
                if emojis.isEmpty { emojis = EmojiSuggest.emojis(for: bridge.rawWord.lowercased()) }
            }
            set.emojis = emojis
        } else if let prev = lastWord {
            // vừa space sau một từ → gợi từ KẾ TIẾP (trigram/bigram cá nhân
            // interpolate với seed)
            set.nextWords = SensitiveWords.filter(
                langModel.nextWords(after: prev, prev2: lastWord2, limit: 6),
                enabled: filterSensitive
            ).prefix(3).map { caseForContext(DisplayCase.apply($0, after: prev)) }
        } else {
            // field trống chưa gõ gì → từ user hay mở đầu nhất
            set.nextWords = SensitiveWords.filter(langModel.topWords(limit: 6),
                                                  enabled: filterSensitive)
                .prefix(3).map { caseForContext(DisplayCase.apply($0)) }
        }
        keyboard.showSuggestions(set)
    }

    /// Tap gợi ý (hành vi QuickType): emoji thay hẳn từ; từ tiếng Việt thay
    /// từ + thêm space để gõ tiếp luôn.
    private func acceptSuggestion(_ item: String) {
        applyingEdit = true
        defer { applyingEdit = false }
        // Undo auto-restore: caret đang đứng ngay sau từ raw đã chốt (space vừa
        // bị backspace) → thay cả từ raw bằng dạng có dấu + space.
        if undoOfferActive, let u = restoreUndo, item == u.composed,
           bridge.composedWord.isEmpty {
            for _ in 0..<u.raw.count { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(u.composed + " ")
            restoreUndo = nil; undoOfferActive = false
            bridge.reset()
            commitAndLearn(u.composed, accepted: true)
            KeyboardView.clickModifier()
            updateAutoShift()
            updateSuggestions()
            return
        }
        restoreUndo = nil; undoOfferActive = false
        let isFragment = item.contains(".") || item.contains("@")   // gmail.com, com…
        let isWord = !isFragment && item.first?.isLetter == true
        let n = bridge.composedWord.count
        for _ in 0..<n { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(isWord ? item + " " : item)
        bridge.reset()
        if isWord { commitAndLearn(item, accepted: true) } else { lastWord = nil; lastWord2 = nil }
        KeyboardView.clickModifier()
        updateAutoShift()
        updateSuggestions()
    }
}

extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
