// SwipeTyping.swift — glue gõ vuốt giữa KeyboardView (đường vuốt) và EngineBridge
// (chèn/seed từ). Không UIKit: test được với MockProxy (SwipeTypingTests).
//
// Luồng: KeyboardView phân loại chạm→vuốt (GestureClassifier) → `begin` HUỶ chữ
// đầu đã chèn lúc chạm xuống (checkpoint engine, không ⌫) → nhấc tay → `finish`:
// decode top-5 dạng không dấu (ngữ cảnh = từ kế tiếp hay gặp sau từ trước, theo
// UserLangModel, + LM âm tiết tĩnh: trigram SyllableLM theo 2 âm tiết trước) → expand dạng thắng thành âm tiết có dấu → chèn top-1 (dấu cách
// treo + seed engine, xem EngineBridge.insertSwipeWord) → thanh gợi ý hiện biến thể.
//
// SwipeDecoder KHÔNG thread-safe: MỌI truy cập đi qua một hàng đợi serial (`queue`);
// prepare() chạy nền ở đó, decode gọi `queue.sync` từ main (lần vuốt đầu ngay sau khi
// hiện bàn phím có thể chờ prepare xong — vài chục ms, một lần).
import Foundation

final class SwipeTyping {
    struct Outcome: Equatable {
        /// Từ trước đó vừa được chốt (để caller học), nếu có.
        let committed: EngineBridge.SettledCommit?
        /// Từ đã chèn (đã áp chữ hoa).
        let word: String
        /// Phương án khác cho thanh gợi ý (đã áp chữ hoa), ≤ 3.
        let alternatives: [String]
        /// Từ chèn là tiếng Anh (nguyên văn) — giai đoạn 3.
        var english = false
        /// Các phương án tiếng Anh trong `alternatives` (chọn ⇒ chèn nguyên văn).
        var englishAlternatives: Set<String> = []
        /// Ứng viên Việt đã chấm của từ này — cú vuốt kế sửa lại được (SwipeRevise).
        var scored: [SwipeWord] = []
        /// Cú vuốt này đã sửa lại từ vuốt trước (`committed` là từ mới).
        var revised: Revision?
    }

    /// Từ vuốt vừa sửa lại: từ cũ → từ mới (đã theo chữ hoa của từ cũ).
    struct Revision: Equatable {
        let old: String
        let new: String
    }

    /// Từ vuốt Việt còn mở + ứng viên đã chấm — đưa cho cú vuốt NGAY SAU để sửa lại.
    struct Revisable: Equatable {
        let word: String
        let scored: [SwipeWord]
        let sc: SwipeCase
    }

    /// Kết quả thuần của pick/resolve.
    struct Choice: Equatable {
        let word: String
        let alternatives: [String]
        var english = false
        var englishAlternatives: Set<String> = []
        /// Từ thắng chỉ áp Shift (không tên riêng) — tra khoá gõ tắt như gõ tay.
        var shifted = ""
    }

    private let decoder = SwipeDecoder()
    private let queue = DispatchQueue(label: "com.viettelex.swipe", qos: .userInitiated)
    /// Layout lần cuối đã gửi xuống hàng đợi (chỉ đọc/ghi trên main).
    private(set) var layout: SwipeLayout?
    /// FUTO Swipe (thử nghiệm, FutoSwipe.swift) — CHỈ đụng trên `queue`; nil = tắt (mặc định):
    /// không tạo, không tải, decode SHARK2 y như cũ.
    private var futo: FutoSwipe?
    /// Công tắc FUTO đã bật (main).
    private(set) var futoActive = false

    /// Điểm ngữ cảnh (log-domain, GIỐNG bản Android SwipeSuggest.Context):
    ///  - cá nhân: +1.5 nếu là từ kế tiếp hay gặp sau từ trước (UserLangModel.nextWords);
    ///    +0.4·ln(1+count) cho từ hay gõ, trần 1.5;
    ///  - tĩnh: trigram âm tiết (vnlm.bin) — xem lmWeight; đã có nextWords thì nhân 0.5.
    ///    Không có vnlm.bin / âm tiết trước lạ ⇒ không có điểm tĩnh.
    static let nextBonus: Float = 1.5
    /// Cặp chọn tay (CuratedPairs.next sau prev2, prev — Scripts/curated-pairs.txt): thưởng riêng,
    /// lớn hơn từ kế tiếp cá nhân để phân định dấu cả khi cách đọc kia cũng nằm trong nextWords
    /// (tiếng Việt không dấu ≠ không đâu). = Android SwipeSuggest.CURATED_BONUS.
    static let curatedBonus: Float = 3.0
    static let personalWeight: Float = 0.4
    static let personalCap: Float = 1.5
    static let staticDamp: Float = 0.5
    private static let lambdaFreq = SwipeDecoder.Params().lambdaFreq
    /// Mô hình trigram (vnlm.bin, SyllableLM): điểm = s·lmWeight
    /// kẹp [lmFloor, lmCap] (có bằng chứng ÂM: "hiếm sau ngữ cảnh này"), và khi đó λ tần
    /// suất lúc chọn dạng/bung dấu hạ còn lmLambdaFreq (LM gánh phần tiên nghiệm). Chỉnh
    /// trên tập dev (Scripts/gen-syllable-lm.py, docs/DATA-SOURCES.md): heldout top-1
    /// 0.861 → 0.894, top-3 0.951 → 0.962 (decoder tầng 2).
    static let lmWeight: Float = 0.15
    static let lmCap: Float = 1.0
    static let lmFloor: Float = -1.0
    static let lmLambdaFreq: Float = 1.0

    /// Điểm ngữ cảnh cá nhân của một âm tiết có dấu.
    static func contextScore(_ w: String, next: Set<String>, count: (String) -> Int) -> Float {
        let c = count(w)
        let personal = c > 0 ? min(personalCap, personalWeight * log(1 + Float(c))) : 0
        return (next.contains(w) ? nextBonus : 0) + personal
    }

    /// Ngữ cảnh một cú vuốt: cá nhân + LM tĩnh theo âm tiết trước — trigram (`prev2`, `prev`)
    /// của SyllableLM.
    struct Context {
        let next: Set<String>
        let count: (String) -> Int
        private let lmContext: SyllableLM.Context?
        private let weight: Float
        /// Từ chọn tay sau (prev2, prev) — CuratedPairs.next.
        private let curated: Set<String>
        /// λ tần suất khi chọn dạng + bung dấu (hạ khi có trigram).
        let lambdaFreq: Float
        /// Từ liền trước (chuỗi tên riêng DisplayCase) + hoa/thường đã học (UserLangModel.learnedCase).
        let prev: String?
        let learnedCase: ((String) -> String?)?
        /// false = ô địa chỉ / tìm kiếm (thanh gợi ý chữ thường): không tên riêng, chỉ Shift.
        let properNouns: Bool

        init(next: Set<String>, count: @escaping (String) -> Int = { _ in 0 },
             prev: String? = nil, prev2: String? = nil, lm: SyllableLM? = nil, curated: Bool = true,
             learnedCase: ((String) -> String?)? = nil, properNouns: Bool = true) {
            self.next = next
            self.count = count
            self.prev = prev
            self.learnedCase = learnedCase
            self.properNouns = properNouns
            self.curated = curated ? prev.map { Set(CuratedPairs.next(after: $0, prev2: prev2)) } ?? [] : []
            let id1 = prev.flatMap { SyllableLM.id(of: $0) }
            if let lm, let id1 {
                lmContext = lm.context(prev2: prev2.flatMap { SyllableLM.id(of: $0) } ?? -1, prev1: id1)
            } else { lmContext = nil }
            let damp: Float = next.isEmpty ? 1 : SwipeTyping.staticDamp
            weight = SwipeTyping.lmWeight * damp
            lambdaFreq = lmContext != nil ? SwipeTyping.lmLambdaFreq : SwipeTyping.lambdaFreq
        }

        /// Điểm LM tĩnh của âm tiết có dấu `w` (0 nếu không có dữ liệu).
        func staticScore(_ w: String) -> Float {
            guard let lmContext, let id = SyllableLM.id(of: w) else { return 0 }
            let damp: Float = next.isEmpty ? 1 : SwipeTyping.staticDamp
            return max(SwipeTyping.lmFloor * damp, min(SwipeTyping.lmCap * damp, weight * lmContext.score(id)))
        }

        /// Dạng tên riêng của từ vuốt `w` (chữ thường) sau `prev` — trước khi áp Shift.
        func proper(_ w: String) -> String {
            properNouns ? DisplayCase.resolve(w, after: prev, learned: learnedCase) : w
        }

        func word(_ w: String) -> Float {
            SwipeTyping.contextScore(w, next: next, count: count) + staticScore(w)
                + (curated.contains(w) ? SwipeTyping.curatedBonus : 0)
        }

        /// Có trigram thì ứng viên Việt chấm tần suất bằng lmLambdaFreq thay vì λ decoder — hạ
        /// y như vậy cho từ tiếng Anh để cán cân Việt/Anh (bias, margin) giữ nguyên.
        func englishFreqShift(_ w: String) -> Float {
            guard lmContext != nil, let i = SwipeEnglish.index(of: w) else { return 0 }
            return -(SwipeTyping.lambdaFreq - SwipeTyping.lmLambdaFreq) * Float(SwipeEnglish.lexicon.freq[i]) / 255
        }

        /// Cho decoder: max(λ'·tần suất + ngữ cảnh) trên các âm tiết của dạng không dấu −
        /// phần tần suất decoder đã cộng ⇒ decode và expand chấm cùng một thước. Không có
        /// trigram: λ' = λ và kẹp ≥ 0 (như cũ); có trigram: λ' = lmLambdaFreq, không kẹp.
        func folded(_ f: String) -> Float {
            guard let i = SwipeLexicon.index(of: f),
                  let best = SwipeDecoder.expand(f, limit: 1, lambdaFreq: lambdaFreq, context: word).first
            else { return 0 }
            let d = best.score - SwipeTyping.lambdaFreq * Float(SwipeLexicon.forms.freq[i]) / 255
            return lmContext != nil ? d : max(0, d)
        }
    }

    /// Đặt layout (khác lần trước mới gửi); `prepare` = dựng template ngay ở nền.
    func setLayout(_ l: SwipeLayout, prepare: Bool) {
        guard l != layout else { return }
        layout = l
        let d = decoder
        queue.async { [weak self] in
            d.setLayout(l)
            if let f = self?.futo { f.setLayout(l); if prepare { f.load() } }
            if prepare {
                d.prepare()
                _ = SyllableLM.shared       // map mô hình trigram (vnlm.bin — thanh gợi ý dùng chung)
            }
        }
    }

    /// Từ vựng vuốt vừa đổi (bảng gõ tắt): dựng lại template ở nền nếu đã có layout — cú vuốt
    /// kế khỏi chờ. Không có layout ⇒ dựng lười như thường.
    func refreshVocab() {
        guard layout != nil else { return }
        let d = decoder
        queue.async { d.prepare() }
    }

    /// Bật/tắt decoder FUTO Swipe (main). Bật ⇒ tạo + tải model ở nền (đã bật mà model bị nhả
    /// lúc ẩn bàn phím ⇒ tải lại); tắt ⇒ bỏ hẳn (RAM trả lại).
    func setFuto(enabled: Bool) {
        let was = futoActive
        futoActive = enabled
        let l = layout
        queue.async { [weak self] in
            guard let self else { return }
            if !enabled { self.futo = nil; return }
            if !was || self.futo == nil { self.futo = FutoSwipe(source: FutoSwipe.bundledWeights) }
            if let f = self.futo, let l { f.setLayout(l); f.load() }
        }
    }

    /// Nhả model FUTO (ẩn bàn phím / cảnh báo bộ nhớ) — công tắc giữ nguyên, lần hiện sau tải lại.
    func releaseFuto() {
        guard futoActive else { return }
        queue.async { [weak self] in self?.futo?.release() }
    }

    /// Nạp từ điển tiếng Anh + bảng phím vuốt (chỉ vuốt tiếng Anh cần) ở nền — lần vuốt đầu khỏi
    /// chờ. An toàn gọi lại.
    func preloadEnglish() {
        queue.async { _ = SwipeEnglish.lexicon.swipe }
    }

    /// Giải mã (đồng bộ trên hàng đợi decoder) → dạng thắng + phương án.
    /// `contextWords` = từ hay theo sau từ trước (UserLangModel.nextWords), có dấu;
    /// `count` = số lần user đã gõ một âm tiết (UserLangModel.count);
    /// `prev` = âm tiết liền trước, `prev2` = âm tiết trước nữa (LM tĩnh).
    /// `english` (giai đoạn 3) = tham số tiếng Anh theo ngữ cảnh (SwipeLangContext.prior);
    /// nil = chỉ tiếng Việt (công tắc "Vuốt từ tiếng Anh" tắt).
    func resolve(_ path: SwipePath, contextWords: [String], count: @escaping (String) -> Int = { _ in 0 },
                 prev: String? = nil,
                 prev2: String? = nil, lm: SyllableLM? = SyllableLM.shared,
                 english: SwipeEnglishPrior? = nil, englishOnly: Bool = false,
                 learnedCase: ((String) -> String?)? = nil, properNouns: Bool = true,
                 case sc: SwipeCase) -> Choice? {
        resolveFull(path, contextWords: contextWords, count: count, prev: prev,
                    prev2: prev2, lm: lm, english: english, englishOnly: englishOnly,
                    learnedCase: learnedCase, properNouns: properNouns, case: sc)?.choice
    }

    private func resolveFull(_ path: SwipePath, contextWords: [String], count: @escaping (String) -> Int,
                             prev: String?, prev2: String?, lm: SyllableLM?,
                             english: SwipeEnglishPrior?, englishOnly: Bool = false,
                             learnedCase: ((String) -> String?)? = nil, properNouns: Bool = true,
                             case sc: SwipeCase)
        -> (choice: Choice, cands: [SwipeCandidate], ctx: Context)? {
        guard layout != nil, path.count >= 2 else { return nil }
        let ctx = Context(next: Self.contextSet(contextWords, prev: prev, prev2: prev2), count: count,
                          prev: prev, prev2: prev2, lm: lm, learnedCase: learnedCase, properNouns: properNouns)
        let d = decoder
        // từ tiếng Anh: chỉ điểm cá nhân/từ kế tiếp (bigram tĩnh là của âm tiết Việt)
        let next = ctx.next
        let enCtx: ((String) -> Float)? = english == nil ? nil : { w in
            Self.contextScore(w, next: next, count: count) + ctx.englishFreqShift(w)
        }
        let cands = queue.sync { () -> [SwipeCandidate] in
            if let f = futo {
                if let r = f.decode(path, topK: 5, context: ctx.folded, english: english, englishContext: enCtx,
                                    shark: d) { return r }
                // model chưa sẵn/bị nhả ⇒ SHARK2 lần này, tải nền cho lần sau
                queue.async { f.load() }
            }
            return d.decode(path, topK: 5, context: ctx.folded, english: english, englishContext: enCtx)
        }
        let pool = englishOnly ? Self.englishOnly(cands) : cands
        return Self.pick(pool, context: ctx, case: sc).map { ($0, pool, ctx) }
    }

    /// Từ kế tiếp cá nhân/seed sau `prev` → tập ngữ cảnh (chữ thường) của cú vuốt. "Lọc từ nhạy cảm"
    /// bật (SwipeVocab.filterSensitive, cùng công tắc) ⇒ bỏ cặp nhạy cảm (SensitiveWords.pairs): seed
    /// "sờ chim" không thưởng "chim" sau "sờ"; bộ ba (SensitiveWords.triples, cần `prev2`): "ngu như" không
    /// thưởng "chó". + chuỗi seed ba từ (SensitiveWords.chain) sau (prev2, prev). Tắt lọc ⇒ nguyên văn.
    /// = Android SwipeSuggest.context.
    static func contextSet(_ words: [String], prev: String?, prev2: String? = nil,
                           filter: Bool = SwipeVocab.filterSensitive) -> Set<String> {
        Set(SensitiveWords.dropPairs(SensitiveWords.chain(after: prev, prev2: prev2) + words, after: prev, prev2: prev2,
                                     enabled: filter).map { $0.lowercased() })
    }

    /// Chế độ Tiếng Anh (vuốt phím cách): chỉ giữ ứng viên tiếng Anh — decode chạy với
    /// `SwipeLangContext.onlyEnglishPrior` để top-K không bị âm tiết Việt chiếm chỗ.
    static func englishOnly(_ cands: [SwipeCandidate]) -> [SwipeCandidate] {
        cands.filter { $0.lang == .en }
    }

    /// Phần thuần: từ top-K dạng không dấu → từ chèn + phương án. Phương án = các biến
    /// thể dấu khác của dạng thắng xen với top-1 có dấu của dạng không dấu hạng 2/3
    /// (vd. vuốt "cho": chó · co · chờ).
    static func pick(_ folded: [String], contextWords: Set<String>,
                     count: @escaping (String) -> Int = { _ in 0 }, case sc: SwipeCase) -> Choice? {
        pick(folded.map { SwipeCandidate(folded: $0, score: 0) },
             context: Context(next: contextWords, count: count), case: sc)
    }

    static func pick(_ folded: [String], context: Context, case sc: SwipeCase) -> Choice? {
        pick(folded.map { SwipeCandidate(folded: $0, score: 0) }, context: context, case: sc)
    }

    /// Bản có nhãn ngôn ngữ (giai đoạn 3): ứng viên tiếng Anh hiển thị nguyên văn; top-1
    /// tiếng Anh ⇒ chèn nguyên văn. Luôn giữ 1 phương án ngôn ngữ kia nếu decoder có
    /// (the ↔ thế) — thay phương án cuối. GIỐNG Android SwipeSuggest.choose. Ngữ cảnh
    /// (cá nhân + bigram tĩnh) chỉ dùng để bung dấu ứng viên tiếng Việt.
    static func pick(_ cands: [SwipeCandidate], context: Context, case sc: SwipeCase) -> Choice? {
        let ctx: (String) -> Float = context.word
        let lam = context.lambdaFreq
        func words(_ c: SwipeCandidate, _ limit: Int) -> [String] {
            c.lang == .en ? [c.folded]
                : SwipeDecoder.expand(c.folded, limit: limit, lambdaFreq: lam, context: ctx).map(\.word)
        }
        guard let top = cands.first else { return nil }
        let expanded = words(top, 6)
        guard let best = expanded.first else { return nil }
        var english: Set<String> = top.lang == .en ? [best] : []
        let variants = expanded.dropFirst()
        var others: [String] = []
        for c in cands.dropFirst().prefix(2) {
            guard let w = words(c, 1).first else { continue }
            others.append(w)
            if c.lang == .en { english.insert(w) }
        }
        var alts: [String] = []
        var vi = variants.makeIterator(), oi = others.makeIterator()
        while alts.count < 3 {
            var added = false
            for next in [vi.next(), oi.next()] {
                guard let w = next else { continue }
                added = true
                if w != best, !alts.contains(w), alts.count < 3 { alts.append(w) }
            }
            if !added { break }
        }
        let isOther: (String) -> Bool = { english.contains($0) != (top.lang == .en) }
        if !alts.contains(where: isOther),
           let c = cands.dropFirst().first(where: { $0.lang != top.lang && !words($0, 1).isEmpty }),
           let w = words(c, 1).first, w != best {
            if c.lang == .en { english.insert(w) } else { english.remove(w) }
            alts.removeAll { $0 == w }
            if alts.count >= 3 { alts.removeLast() }
            alts.append(w)
        }
        let cased: (String) -> String = { sc.apply($0, proper: context.proper) }
        return Choice(word: cased(best), alternatives: alts.map(cased), english: top.lang == .en,
                      englishAlternatives: Set(alts.filter { english.contains($0) }.map(cased)),
                      shifted: sc.apply(best))
    }

    /// Nhấc tay: giải mã rồi chèn. nil = không nhận ra gì (không đụng màn hình).
    /// `previous` = từ vuốt Việt đang mở ngay trước (caller đã kiểm còn nguyên, chưa chọn
    /// phương án): chấm lại theo ngữ cảnh hai phía, đổi thì thay trên màn hình (đuôi phải
    /// đọc được và khớp đúng) trước khi chốt, rồi chọn lại từ này theo ngữ cảnh trái mới.
    /// `nextWords` = UserLangModel.nextWords cho ngữ cảnh mới (nil ⇒ không có điểm cá nhân).
    func finish(_ path: SwipePath, case sc: SwipeCase, contextWords: [String],
                count: @escaping (String) -> Int = { _ in 0 }, prev: String? = nil,
                prev2: String? = nil, english: SwipeEnglishPrior? = nil, englishOnly: Bool = false,
                previous: Revisable? = nil, previousLiteral: String? = nil,
                nextWords: ((String, String?) -> [String])? = nil,
                lm: SyllableLM? = SyllableLM.shared, learnedCase: ((String) -> String?)? = nil,
                properNouns: Bool = true,
                bridge: EngineBridge, proxy: TextProxyLike) -> Outcome? {
        guard let full = resolveFull(path, contextWords: contextWords, count: count, prev: prev,
                                     prev2: prev2, lm: lm, english: english,
                                     englishOnly: englishOnly, learnedCase: learnedCase,
                                     properNouns: properNouns, case: sc) else {
            TouchLog.write("swipe: không có ứng viên (pts=\(path.count))")
            return nil
        }
        var r = full.choice
        var scored = r.english ? [] : SwipeRevise.scored(full.cands, context: full.ctx.word,
                                                        lambdaFreq: full.ctx.lambdaFreq)
        var revised: Revision?
        if let rec = previous, !r.english,
           // sửa chung cặp (từ vuốt trước, cú vuốt này) — ứng viên từ kế rộng hơn scored
           let new = SwipeRevise.revise(rec.scored, current: rec.word.lowercased(), prev: prev2,
                                        next: SwipeRevise.nextPool(full.cands, context: full.ctx.word,
                                                                   lambdaFreq: full.ctx.lambdaFreq),
                                        lm: lm) {
            let newCased = rec.sc.apply(new, proper: {
                properNouns ? DisplayCase.resolve($0, after: prev2, learned: learnedCase) : $0
            })
            if proxy.contextBeforeInput?.hasSuffix(rec.word) == true,
               bridge.replaceSwipeWord(with: newCased, accepted: false, proxy: proxy) {
                revised = Revision(old: rec.word, new: newCased)
                let nctx = Context(next: Self.contextSet(nextWords?(new, prev2) ?? [], prev: new, prev2: prev2),
                                   count: count, prev: new, prev2: prev2, lm: lm, learnedCase: learnedCase,
                                   properNouns: properNouns)
                let re = SwipeRevise.rerank(full.cands, old: full.ctx.word, oldLambda: full.ctx.lambdaFreq,
                                            new: nctx.word, newLambda: nctx.lambdaFreq)
                if let c = Self.pick(re, context: nctx, case: sc) {
                    r = c
                    scored = c.english ? [] : SwipeRevise.scored(re, context: nctx.word, lambdaFreq: nctx.lambdaFreq)
                }
                TouchLog.write("swipe: sửa từ trước (\(rec.word.count)→\(newCased.count) ký tự)")
            }
        }
        // Chuỗi tên riêng: từ này viết hoa vì từ vuốt trước ("việt" + "nam" → "Nam") ⇒ hoa luôn từ
        // trước khi nó còn mở, đúng như trên màn hình ("Việt Nam", không "việt Nam"). Caps Lock:
        // từ trước đã hoa sẵn.
        // Từ trước là từ TIẾNG ANH vừa vuốt (previousLiteral, "new" + "york") cũng vậy — thay nguyên văn.
        if properNouns, let base = previous?.word ?? previousLiteral, sc != .upper {
            let onScreen = revised?.new ?? base
            if let f = onScreen.first, !f.isUppercase,
               DisplayCase.chainCapitalizes(r.word.lowercased(), after: onScreen),
               proxy.contextBeforeInput?.hasSuffix(onScreen) == true {
                let cap = onScreen.prefix(1).uppercased() + onScreen.dropFirst()
                if bridge.replaceSwipeWord(with: cap, literal: previous == nil, accepted: false, proxy: proxy) {
                    revised = Revision(old: revised?.old ?? base, new: cap)
                }
            }
        }
        // Khoá gõ tắt ("vn", từ vựng vuốt SwipeVocab.shortcutEntries): chèn nội dung bung như gõ
        // khoá + dấu cách (⌫ đầu trả lại khoá). Khoá đứng đầu phương án — chạm để giữ nguyên khoá.
        if let e = bridge.swipeShortcutExpansion(for: r.shifted), e != r.shifted {
            let key = r.shifted
            r = Choice(word: e, alternatives: Array(([key] + r.alternatives.filter { $0 != key && $0 != e }).prefix(3)),
                       english: true, englishAlternatives: r.englishAlternatives.union([key]), shifted: key)
            let committed = bridge.insertSwipeWord(e, shortcutKey: key, proxy: proxy)
            TouchLog.write("swipe: khoá gõ tắt (\(key.count)→\(e.count) ký tự)")
            return Outcome(committed: committed, word: e, alternatives: r.alternatives, english: false,
                           englishAlternatives: r.englishAlternatives, scored: [], revised: revised)
        }
        let committed = bridge.insertSwipeWord(r.word, literal: r.english, proxy: proxy)
        if TouchLog.enabled {
            TouchLog.write(String(format: "swipe: pts=%d len=%.0f ms=%.0f alts=%d",
                                  path.count, path.length, path.duration * 1000, r.alternatives.count))
        }
        return Outcome(committed: committed, word: r.word, alternatives: r.alternatives,
                       english: r.english, englishAlternatives: r.englishAlternatives,
                       scored: scored, revised: revised)
    }

    /// Bỏ dấu tiếng Việt (đ → d), chữ thường — khoá so với dạng không dấu của lexicon.
    static func fold(_ w: String) -> String { SwipeLexicon.fold(w) }
}
