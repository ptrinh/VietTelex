// "Sửa lỗi bằng Apple Intelligence" (Plus, iOS 26+, mặc định TẮT) — glue bàn phím.
// Controller chỉ giữ `ai: AIAssist?` (nil khi tắt ⇒ 0 chi phí: không đọc selectedText, không
// dlopen, không prewarm) và gọi 4 điểm: `decorate` (cuối updateSuggestions), `handleTap`
// (đầu onSuggestion), `keyPressed` (đầu handle), `close` (ẩn bàn phím).
//
// Luồng:
//  - Chọn ≥ 2 từ ⇒ chip "✨ Sửa lỗi" ở slot đầu. Chạm ⇒ chạy NỀN (chip "✨ Đang sửa…", chạm để
//    huỷ; gõ tiếp không bị chặn), hạn AIText.timeout. Xong và vùng chọn còn y nguyên ⇒ bảng xem
//    trước phủ vùng phím (không đổi chiều cao) — Áp dụng / Huỷ. Áp dụng: vùng chọn phải còn ĐÚNG
//    chữ gốc (selectedText == original) mới thay; sau đó chip "↩︎ Hoàn tác" tới phím kế.
//  - KHÔNG chọn gì ⇒ cùng chip, sửa CẢ Ô (trước + sau con trỏ, ≤ AIField.maxChars, ≥ 2 từ) — chỉ
//    hiện sau khi ngừng gõ một chút và khi ô đã đổi so với lần sửa trước; model chỉ chạy khi
//    chạm. Áp dụng: dời con trỏ về cuối/đầu/cuối để CHẮC ô đúng y bản gốc (AIField), xoá hết rồi
//    chèn bản sửa, đọc lại kiểm; lệch ở bất kỳ bước nào ⇒ lặng lẽ bỏ. Hoàn tác đi đúng đường đó.
//  - Chọn đúng 1 từ ⇒ (chờ 0,35 s cho vùng chọn đứng yên) hỏi tối đa 3 từ thay thế theo ngữ cảnh
//    quanh từ (documentContextBefore/After, cắt ngắn); hiện trên thanh gợi ý, chạm = thay.
//  - Lỗi / quá hạn ⇒ chip thông báo ngắn tới phím kế (không hộp thoại).
// Logic thuần: AIProofread.swift. Gọi model: AIAssistLoader → VTIntelligence.framework.
import UIKit

@MainActor
final class AIAssist {
    struct Host {
        let proxy: () -> UITextDocumentProxy
        let keyboard: () -> KeyboardView?
        /// Chạy thay chữ: controller bật applyingEdit + reset engine (từ đang soạn, ngữ cảnh).
        let edit: (() -> Void) -> Void
        /// SAU KHI THAY CHỮ: tính lại auto-shift + vẽ lại thanh gợi ý.
        let refresh: () -> Void
        /// Chữ KHÔNG đổi (hẹn giờ ngừng gõ, model trả lời, chạm chip thông báo…): chỉ vẽ lại thanh.
        /// Tính lại auto-shift ở đây sẽ hạ ⇧ người dùng vừa chạm trong lúc chờ.
        let redraw: () -> Void
    }

    private static let proofreadToken = AITokens.proofread
    private static let busyToken = AITokens.busy
    private static let undoToken = AITokens.undo
    private static let noticeToken = AITokens.notice

    private let host: Host
    init(host: Host) { self.host = host }

    private var status: AIModelState?
    private var prewarmed = false
    private var task: Task<Void, Never>?
    private var notice: String?
    private enum Undo {
        case selection(TextTools.Undo)
        /// Cả ô: ô đang là `result`, hoàn tác = thay cả ô về `original`.
        case field(original: String, result: String)
    }
    private var undo: Undo?
    private var panel: AIProofreadPanel?
    private var pending: (original: String, corrected: String, field: Bool)?
    /// Sửa cả ô: lần sửa gần nhất (gốc / bản đã áp) — ô vẫn y vậy thì không mời lại.
    private var lastFieldOriginal: String?
    private var lastFieldResult: String?
    /// Đang dời con trỏ / thay cả ô (bất đồng bộ); phím mới ⇒ huỷ trước khi xoá.
    private var fieldBusy = false
    private var fieldCancelled = false
    /// Chip sửa cả ô chỉ hiện sau khi ngừng gõ `typingPause` giây.
    static let typingPause: CFTimeInterval = 0.8
    private var lastKeyAt: CFTimeInterval = 0
    private var pauseRefresh: DispatchWorkItem?
    private var alts: (key: String, word: String, items: [String])?
    private var altsKeyInFlight: String?
    private var altsDebounce: DispatchWorkItem?

    private struct Proxy: TextProxyLike {
        let p: UITextDocumentProxy
        func insertText(_ text: String) { p.insertText(text) }
        func deleteBackward() { p.deleteBackward() }
        var isSecure: Bool { vtSafe(false) { (p as UITextInputTraits).isSecureTextEntry == true } }
        var contextBeforeInput: String? { p.documentContextBeforeInput }
        var contextAfterInput: String? { p.documentContextAfterInput }
        var hasSelection: Bool { selected?.isEmpty == false }
        var selected: String? {
            if #available(iOS 16.0, *) { return vtSafe(nil) { p.selectedText } }
            return nil
        }
    }
    private var proxy: Proxy { Proxy(p: host.proxy()) }

    // MARK: thanh gợi ý

    /// Gọi cuối updateSuggestions khi không gõ dở. Chỉ đọc selectedText (rẻ — host đẩy sẵn).
    func decorate(_ set: inout KeyboardView.SuggestionSet) {
        if let n = notice { lead(&set, n, Self.noticeToken); return }
        if undo != nil { lead(&set, L("\u{21A9}\u{FE0E} Hoàn tác"), Self.undoToken); return }
        if task != nil || fieldBusy { lead(&set, L("✨ Đang sửa…"), Self.busyToken); return }
        let sel = proxy.selected
        let mode = AIText.mode(selected: sel)
        guard mode != .none else {
            altsDebounce?.cancel()
            if (sel ?? "").isEmpty, fieldCandidate(scheduleIfTyping: true) != nil,
               ensureStatus() == .available {
                prewarmOnce()
                lead(&set, L("✨ Sửa lỗi"), Self.proofreadToken)
            }
            return
        }
        // Công tắc bật mà model không dùng được (tắt Apple Intelligence, đang tải, extension
        // không gọi được…) ⇒ đơn giản là không có chip ✨ — không báo lỗi.
        guard ensureStatus() == .available else { return }
        prewarmOnce()
        switch mode {
        case .proofread:
            lead(&set, L("✨ Sửa lỗi"), Self.proofreadToken)
        case .alternatives(let word):
            let key = altsKey(word)
            if let a = alts, a.key == key {
                if !a.items.isEmpty {
                    set.nextWords = a.items; set.literal = nil; set.word = nil; set.word2 = nil
                    set.moreWords = []; set.emojis = []; set.paste = false; set.clipChips = []
                }
            } else {
                if altsKeyInFlight == key { lead(&set, "✨ …", Self.busyToken) }
                scheduleAlternatives(word: word, key: key)
            }
        case .none: break
        }
    }

    private func lead(_ set: inout KeyboardView.SuggestionSet, _ label: String, _ token: String) {
        set.actionLabel = label; set.actionPayload = token
        set.literal = nil; set.paste = false; set.clipChips = []
    }

    /// Chạm chip trên thanh. true = đã xử lý.
    func handleTap(_ item: String) -> Bool {
        switch item {
        case Self.proofreadToken: startProofread(); return true
        case Self.busyToken: cancelRunning(); fieldCancelled = true; host.redraw(); return true
        case Self.undoToken: doUndo(); return true
        case Self.noticeToken: notice = nil; host.redraw(); return true
        default: break
        }
        if let a = alts, a.items.contains(item), case .alternatives(let w) = AIText.mode(selected: proxy.selected),
           w == a.word {
            replaceWord(a.word, with: item)
            return true
        }
        return false
    }

    /// Phím bất kỳ: thông báo / hoàn tác chỉ sống tới phím kế; bảng xem trước đóng.
    func keyPressed() {
        lastKeyAt = CACurrentMediaTime()
        notice = nil
        undo = nil
        if fieldBusy { fieldCancelled = true }
        if panel != nil { closePanel() }
    }

    /// Ẩn bàn phím / tắt: huỷ mọi việc đang chờ.
    func close() {
        cancelRunning()
        fieldCancelled = true
        altsDebounce?.cancel(); altsDebounce = nil
        pauseRefresh?.cancel(); pauseRefresh = nil
        lastFieldOriginal = nil; lastFieldResult = nil
        closePanel()
        notice = nil; undo = nil; alts = nil; altsKeyInFlight = nil
        status = nil; prewarmed = false
    }

    // MARK: trạng thái model

    private func ensureStatus() -> AIModelState {
        if let s = status { return s }
        let before = AIMemory.footprintMB()
        let s = AIAssistLoader.status()   // lần đầu: dlopen VTIntelligence
        status = s
        TouchLog.write("ai: status=\(s) mem \(AIMemory.describe(before)) → \(AIMemory.describe(AIMemory.footprintMB())) (dlopen)")
        return s
    }

    /// Nạp sẵn model — chỉ khi công tắc bật VÀ có vùng chọn (lần đầu mỗi lần hiện bàn phím).
    private func prewarmOnce() {
        guard !prewarmed else { return }
        prewarmed = true
        AIAssistLoader.prewarm(instructions: AIText.proofreadInstructions)
    }

    private func cancelRunning() {
        task?.cancel(); task = nil
    }

    // MARK: sửa cả ô — chọn mời

    /// Chữ cả ô nếu nên mời sửa (không chọn gì, đã ngừng gõ, đủ điều kiện độ dài/số từ, khác lần
    /// sửa trước). Đang gõ ⇒ hẹn vẽ lại thanh sau khi ngừng (`scheduleIfTyping`).
    private func fieldCandidate(scheduleIfTyping: Bool) -> String? {
        let since = CACurrentMediaTime() - lastKeyAt
        if since < Self.typingPause {
            if scheduleIfTyping {
                pauseRefresh?.cancel()
                let item = DispatchWorkItem { [weak self] in self?.host.redraw() }
                pauseRefresh = item
                DispatchQueue.main.asyncAfter(deadline: .now() + (Self.typingPause - since) + 0.02, execute: item)
            }
            return nil
        }
        let px = proxy
        guard let full = AIField.eligible(before: px.contextBeforeInput, after: px.contextAfterInput) else { return nil }
        if let o = lastFieldOriginal, AIField.same(o, full) { return nil }
        if let r = lastFieldResult, AIField.same(r, full) { return nil }
        return full
    }

    // MARK: sửa lỗi

    private func startProofread() {
        let text: String, field: Bool
        if case .proofread(let t) = AIText.mode(selected: proxy.selected) {
            text = t; field = false
        } else if (proxy.selected ?? "").isEmpty, let full = fieldCandidate(scheduleIfTyping: false) {
            text = full; field = true
            lastFieldOriginal = full   // không mời lại cùng nội dung (kể cả khi không thấy lỗi)
        } else { host.redraw(); return }
        guard ensureStatus() == .available else { host.redraw(); return }
        cancelRunning()
        let before = AIMemory.footprintMB()
        let t0 = CACurrentMediaTime()
        task = Task { @MainActor [weak self] in
            let r = await AIAssistLoader.run(kind: 0, instructions: AIText.proofreadInstructions,
                                             prompt: AIText.proofreadPrompt(text))
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            TouchLog.write(String(format: "ai: proofread %.0fms chars=%d mem %@ → %@", (CACurrentMediaTime() - t0) * 1000,
                                  text.count, AIMemory.describe(before), AIMemory.describe(AIMemory.footprintMB())))
            switch r {
            case .success(let out):
                guard let fixed = AIText.assembleProofread(original: text, output: out) else {
                    TouchLog.write("ai: proofread output rejected (len \(text.count) → \(out.count))")
                    self.notice = AIFailure.rejected.message
                    self.host.redraw(); return
                }
                // Người dùng đã đổi vùng chọn / ô trong lúc chờ ⇒ lặng lẽ bỏ.
                let px = self.proxy
                let still = field ? (px.selected ?? "").isEmpty
                    && AIField.matches(before: px.contextBeforeInput, after: px.contextAfterInput, expected: text)
                    : px.selected == text
                guard still else { self.host.redraw(); return }
                self.showPanel(original: text, corrected: fixed, field: field)
            case .failure(.unavailable):
                // Model vừa thành không dùng được ⇒ thôi mời (không báo lỗi) tới lần hiện sau.
                self.status = .notReady
            case .failure(let f):
                self.notice = f.message
            }
            self.host.redraw()
        }
        host.redraw()
    }

    private func showPanel(original: String, corrected: String, field: Bool) {
        guard let kb = host.keyboard() else { return }
        closePanel()
        pending = (original, corrected, field)
        let changed = corrected == original ? 0 : max(1, WordDiff.changedWordCount(original: original, corrected: corrected))
        let p = AIProofreadPanel()
        p.configure(segments: WordDiff.diff(original: original, corrected: corrected), changed: changed,
                    dark: kb.isDarkAppearance)
        p.onApply = { [weak self] in self?.applyPending() }
        p.onCancel = { [weak self] in self?.closePanel(); self?.host.redraw() }
        p.frame = kb.keyAreaFrame   // KeyboardView.layoutOverlayPanel bám vùng phím mỗi lượt layout
        kb.addSubview(p)
        kb.overlayPanel = p
        panel = p
        kb.setNeedsLayout()
    }

    private func closePanel() {
        pending = nil
        guard let p = panel else { return }
        p.removeFromSuperview()
        panel = nil
        if let kb = host.keyboard() {
            if kb.overlayPanel === p { kb.overlayPanel = nil }
            kb.setNeedsLayout()
        }
    }

    private func applyPending() {
        guard let (original, corrected, field) = pending else { closePanel(); return }
        closePanel()
        if field {
            Task { @MainActor [weak self] in
                guard let self, await self.replaceField(original: original, with: corrected) else { return }
                self.undo = .field(original: original, result: corrected)
                self.lastFieldResult = corrected
                KeyboardView.clickModifier()
                self.host.refresh()
            }
        } else {
            replaceSelection(original: original, with: corrected)
        }
    }

    // MARK: thay cả ô (bất đồng bộ: dời con trỏ rồi chờ host cập nhật context)

    /// Chờ host đẩy context mới (sau adjustTextPosition / xoá / chèn) tới khi `cond` đúng.
    private func waitFor(timeout: TimeInterval = 0.6, _ cond: () -> Bool) async -> Bool {
        let end = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return cond()
    }

    private func readField() -> (before: String?, after: String?) {
        let p = host.proxy()
        return (p.documentContextBeforeInput, p.documentContextAfterInput)
    }

    /// Đưa con trỏ về CUỐI ô và chắc chắn ô CHỈ chứa `expected`: cuối (trước = cả ô, sau rỗng),
    /// đầu (trước rỗng, sau = cả ô), rồi về cuối. Sai bất kỳ bước nào ⇒ false.
    private func captureField(expected: String) async -> Bool {
        let p = host.proxy()
        var c = readField()
        guard AIField.matches(before: c.before, after: c.after, expected: expected) else { return false }
        if let a = c.after, !a.isEmpty {
            host.edit { p.adjustTextPosition(byCharacterOffset: AIField.caretOffset(a)) }
            guard await waitFor({ c = readField(); return AIField.atEnd(before: c.before, after: c.after, expected: expected) })
            else { return false }
        }
        guard !fieldCancelled else { return false }
        host.edit { p.adjustTextPosition(byCharacterOffset: -AIField.caretOffset(expected)) }
        let startOK = await waitFor { c = readField(); return AIField.atStart(before: c.before, after: c.after, expected: expected) }
        host.edit { p.adjustTextPosition(byCharacterOffset: AIField.caretOffset(expected)) }
        let endOK = await waitFor { c = readField(); return AIField.atEnd(before: c.before, after: c.after, expected: expected) }
        return startOK && endOK && !fieldCancelled
    }

    /// Thay cả ô `original` → `result`. false (không xoá gì) khi ô không chắc đúng y `original`
    /// hoặc người dùng gõ phím chen ngang; kết quả đọc lại lệch ⇒ false + ghi log.
    private func replaceField(original: String, with result: String) async -> Bool {
        guard !fieldBusy else { return false }
        fieldBusy = true; fieldCancelled = false
        host.refresh()
        defer { fieldBusy = false; host.refresh() }
        guard await captureField(expected: original) else {
            TouchLog.write("failsafe: ai field not fully known / changed → skip")
            return false
        }
        let p = host.proxy()
        host.edit {
            for _ in 0..<AIField.deleteCount(original) { p.deleteBackward() }
            p.insertText(result)
        }
        let ok = await waitFor(timeout: 1.0) { let c = readField(); return AIField.atEnd(before: c.before, after: c.after, expected: result) }
        if !ok { TouchLog.write("ai: field replace verify mismatch (len \(original.count) → \(result.count))") }
        return ok
    }

    /// Thay vùng chọn — CHỈ khi vùng chọn còn đúng `original` (so từng scalar).
    private func replaceSelection(original: String, with result: String) {
        var outcome: TextToolRunner.Outcome = .unchanged
        host.edit {
            let px = proxy
            outcome = TextToolRunner.replace(TextTools.Source(text: original, isSelection: true), with: result,
                                             proxy: px, strict: true, currentSelection: px.selected)
        }
        switch outcome {
        case .applied(let u):
            undo = .selection(u)
            KeyboardView.clickModifier()
        case .failsafe:
            TouchLog.write("failsafe: ai selection changed → skip")
            notice = L("✨ Vùng chọn đã đổi — chọn lại")
        case .unchanged, .noSource: break
        }
        host.refresh()
    }

    private func doUndo() {
        guard let u = undo else { host.redraw(); return }
        undo = nil
        switch u {
        case .selection(let t):
            var ok = false
            host.edit { ok = TextToolRunner.undo(t, proxy: proxy) }
            if !ok { TouchLog.write("failsafe: ai undo context moved → skip") }
            else { KeyboardView.clickModifier() }
            host.refresh()
        case .field(let original, let result):
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.replaceField(original: result, with: original) {
                    self.lastFieldResult = nil   // ô về bản gốc = lastFieldOriginal ⇒ không mời lại
                    KeyboardView.clickModifier()
                }
            }
        }
    }

    // MARK: từ thay thế

    private func altsKey(_ word: String) -> String {
        word + "\u{1F}" + AIText.clipBefore(proxy.contextBeforeInput, limit: 40)
    }

    private func scheduleAlternatives(word: String, key: String) {
        guard altsKeyInFlight != key else { return }
        altsDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fetchAlternatives(word: word, key: key) }
        altsDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func fetchAlternatives(word: String, key: String) {
        // Vùng chọn còn đứng yên đúng từ đó?
        guard case .alternatives(let w) = AIText.mode(selected: proxy.selected), w == word,
              altsKey(word) == key else { return }
        altsKeyInFlight = key
        let prompt = AIText.alternativesPrompt(word: word, before: proxy.contextBeforeInput,
                                               after: proxy.contextAfterInput)
        let before = AIMemory.footprintMB()
        let t0 = CACurrentMediaTime()
        host.redraw()
        Task { @MainActor [weak self] in
            let r = await AIAssistLoader.run(kind: 1, instructions: AIText.alternativesInstructions, prompt: prompt)
            guard let self, self.altsKeyInFlight == key else { return }
            self.altsKeyInFlight = nil
            TouchLog.write(String(format: "ai: alternatives %.0fms mem %@ → %@", (CACurrentMediaTime() - t0) * 1000,
                                  AIMemory.describe(before), AIMemory.describe(AIMemory.footprintMB())))
            let items: [String]
            switch r {
            case .success(let s): items = AIText.validateAlternatives(word: word, outputs: AIText.splitList(s))
            case .failure(let f):
                items = []; TouchLog.write("ai: alternatives failed \(f)")
                if f == .unavailable { self.status = .notReady }
            }
            self.alts = (key, word, items)   // rỗng cũng nhớ ⇒ không hỏi lại cùng từ
            self.host.redraw()
        }
    }

    // MARK: địa chỉ từ clipboard (ô địa chỉ)

    /// Kết quả theo changeCount clipboard (nil value = model không tìm thấy / lỗi ⇒ không hỏi lại).
    private var clipAddr: (change: Int, value: String?)?
    private var clipAddrInFlight: Int?

    /// Địa chỉ model trích từ `text` (clipboard lần `change`). Chưa có ⇒ bắt đầu hỏi NỀN (một lần
    /// mỗi nội dung), trả nil ngay; xong ⇒ vẽ lại thanh. Model không dùng được ⇒ luôn nil.
    func clipAddress(text: String, change: Int) -> String? {
        if let c = clipAddr, c.change == change { return c.value }
        guard clipAddrInFlight != change, ensureStatus() == .available else { return nil }
        clipAddrInFlight = change
        let t0 = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            let r = await AIAssistLoader.run(kind: 2, instructions: AIAddress.instructions,
                                             prompt: AIAddress.prompt(text))
            guard let self, self.clipAddrInFlight == change else { return }
            self.clipAddrInFlight = nil
            var value: String?
            switch r {
            case .success(let s): value = AIAddress.validate(s, source: text)
            case .failure(let f):
                TouchLog.write("ai: address failed \(f)")
                if f == .unavailable { self.status = .notReady }
            }
            TouchLog.write(String(format: "ai: address %.0fms found=%d", (CACurrentMediaTime() - t0) * 1000, value == nil ? 0 : 1))
            self.clipAddr = (change, value)
            if value != nil { self.host.redraw() }
        }
        return nil
    }

    private func replaceWord(_ word: String, with alt: String) {
        guard let sel = proxy.selected, let result = AIText.replaceWord(in: sel, word: word, with: alt) else { return }
        alts = nil
        replaceSelection(original: sel, with: result)
    }
}
