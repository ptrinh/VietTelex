// EngineBridge — pure glue between TelexEngine and an abstract text proxy.
// No UIKit: fully unit-testable with a mock proxy. The keyboard view calls
// press(_:); the bridge feeds the engine and applies the minimal diff
// (deleteBackward × N + insertText) — the exact edit model iOS gives us.
import Foundation
import TelexCore

/// The slice of UITextDocumentProxy the bridge needs.
protocol TextProxyLike {
    func insertText(_ text: String)
    func deleteBackward()
    var isSecure: Bool { get }
}

/// Shared settings (App Group on device; in-memory defaults in tests).
struct KeyboardSettings {
    // Defaults iOS (user 2026-07-24): Telex đơn giản BẬT + bỏ dấu tự do BẬT +
    // tự khôi phục tiếng Anh BẬT. (Khác macOS: simpleTelex mặc định tắt.)
    var freeMarking = true
    var simpleTelex = true
    var liveSpellCheck = true
    var autoRestore = true
    var quickTelex = false
    var modernTone = false
    var showSuggestions = true
    var learnWords = true      // đi theo showSuggestions (không còn toggle riêng)
    var filterSensitive = true

    static func load() -> KeyboardSettings {
        var s = KeyboardSettings()
        guard let d = UserDefaultsProvider.shared else { return s }
        if d.object(forKey: "freeMarking") != nil { s.freeMarking = d.bool(forKey: "freeMarking") }
        if d.object(forKey: "simpleTelex") != nil { s.simpleTelex = d.bool(forKey: "simpleTelex") }
        if d.object(forKey: "liveSpellCheck") != nil { s.liveSpellCheck = d.bool(forKey: "liveSpellCheck") }
        if d.object(forKey: "autoRestore") != nil { s.autoRestore = d.bool(forKey: "autoRestore") }
        if d.object(forKey: "quickTelex") != nil { s.quickTelex = d.bool(forKey: "quickTelex") }
        if d.object(forKey: "modernTone") != nil { s.modernTone = d.bool(forKey: "modernTone") }
        if d.object(forKey: "showSuggestions") != nil { s.showSuggestions = d.bool(forKey: "showSuggestions") }
        if d.object(forKey: "filterSensitive") != nil { s.filterSensitive = d.bool(forKey: "filterSensitive") }
        s.learnWords = s.showSuggestions   // bật gợi ý = bật học (quyết định 2026-07-24)
        return s
    }
}

/// Indirection so tests never touch the real App Group.
enum UserDefaultsProvider {
    nonisolated(unsafe) static var shared: UserDefaults? =
        UserDefaults(suiteName: "group.com.viettelex")
}

final class EngineBridge {
    private var engine = TelexEngine()
    private let settings: KeyboardSettings

    init(settings: KeyboardSettings = .load()) {
        self.settings = settings
        engine.freeMarking = settings.freeMarking
        engine.simpleTelex = settings.simpleTelex
        engine.liveSpellCheck = settings.liveSpellCheck
        engine.quickTelex = settings.quickTelex
        engine.modernTone = settings.modernTone
    }

    /// A letter key ("a"…"z", already cased by the shift state).
    func letter(_ ch: Character, proxy: TextProxyLike) {
        guard !proxy.isSecure else { proxy.insertText(String(ch)); return }
        apply(engine.feed(ch), literal: String(ch), proxy: proxy)
    }

    /// Space / return / punctuation: word boundary → auto-restore, then the char.
    /// Returns the FINAL committed word (post auto-restore) — the
    /// personalization model must learn what actually landed on screen.
    @discardableResult
    func boundary(_ text: String, proxy: TextProxyLike) -> String {
        guard !proxy.isSecure else { proxy.insertText(text); return "" }
        let before = engine.composed
        let action = engine.commitBoundary(autoRestore: settings.autoRestore)
        var final = before
        if case let .replace(bs, insert) = action {
            final = String(before.dropLast(bs)) + insert
        }
        apply(action, literal: "", proxy: proxy)
        proxy.insertText(text)
        return final
    }

    /// Backspace. Returns true when the bridge handled it (composition edit);
    /// false → caller should also stop any repeat state it keeps.
    func backspace(proxy: TextProxyLike) {
        guard !proxy.isSecure, !engine.isEmpty else { proxy.deleteBackward(); return }
        switch engine.backspace() {
        case .replace(let bs, let insert):
            for _ in 0..<bs { proxy.deleteBackward() }
            if !insert.isEmpty { proxy.insertText(insert) }
        case .passthrough, .none:
            proxy.deleteBackward()
        }
    }

    /// Field switch / selection moved / keyboard dismissed → forget the word.
    func reset() { engine.reset() }

    var isComposing: Bool { !engine.isEmpty }

    /// Current word for the suggestion bar: on-screen composed form + raw keys.
    var composedWord: String { engine.composed }
    var rawWord: String { engine.rawKeystrokes }

    /// Từ mà boundary SẼ chốt (auto-restore tính sẵn) — peek non-mutating trực
    /// tiếp trên engine. KHÔNG copy struct: bản copy cũ kích hoạt COW copy ~10
    /// buffer cố định mỗi phím khi commitText mutate (reset + scratch).
    var predictedCommit: String {
        engine.peekCommitText(autoRestore: settings.autoRestore)
    }

    private func apply(_ action: TelexAction, literal: String, proxy: TextProxyLike) {
        switch action {
        case .replace(let bs, let insert):
            for _ in 0..<bs { proxy.deleteBackward() }
            if !insert.isEmpty { proxy.insertText(insert) }
        case .passthrough:
            if !literal.isEmpty { proxy.insertText(literal) }
        case .none:
            break
        }
    }
}
