// SelfTest.swift — `viettelex-text-tool --self-test <iOS/KeyboardTests/Fixtures>` (ctest
// caret_suggest): các ca của macOS AppTests/CaretSuggestionsTests.swift + MathHintTests.swift
// (fixture chung math-results.txt / number-chips.txt) chạy trên bản Linux của logic
// (CaretSuggest.swift) và giao thức --serve (Serve.swift). Trả số ca lệch.
import Foundation
import TelexCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func caretSelfTest(fixtures: String) -> Int {
    // Học từ bạn gõ: kho của --serve trong thư mục tạm — self-test KHÔNG BAO GIỜ đụng
    // ~/.local/share/viettelex (đặt TRƯỚC lần đầu chạm LearnStore.shared).
    let learnDir = "/tmp/viettelex-selftest-\(getpid())"
    setenv("VIETTELEX_LEARN_FILE", learnDir + "/" + LearnedModel.fileName, 1)
    defer { try? FileManager.default.removeItem(atPath: learnDir) }
    var bad = 0, n = 0
    func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        n += 1
        if !ok { bad += 1; print("LỆCH: \(what())") }
    }
    func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) { check(a == b, "\(what): «\(a)» ≠ «\(b)»") }
    func S(_ k: CaretSuggestion.Kind, _ d: String, _ r: String, _ i: String) -> CaretSuggestion {
        CaretSuggestion(kind: k, display: d, replace: r, insert: i)
    }
    func lines(_ name: String) -> [[String]] {
        readFixture(fixtures + "/" + name).map {
            $0.split(separator: "|", omittingEmptySubsequences: false).map { String($0).replacingOccurrences(of: "␣", with: " ") }
        }
    }

    // MARK: Phép tính (MathHintTests)
    var m = 0
    for c in lines("math-results.txt") where c.first == "chip" && c.count == 3 {
        eq(CaretHintLogic.mathResult(beforeCaret: c[1]) ?? "-", c[2], "math chip «\(c[1])»"); m += 1
    }
    check(m > 10, "math-results: chỉ \(m) ca chip")
    eq(CaretHintLogic.mathResult(beforeCaret: "12*3="), "36", "12*3=")
    eq(CaretHintLogic.mathResult(beforeCaret: "giá 200+10%="), "220", "200+10%=")
    eq(CaretHintLogic.mathResult(beforeCaret: "125 x (4 + 5.5) ="), "1187.5", "125 x (4 + 5.5) =")
    eq(CaretHintLogic.mathResult(beforeCaret: "a=b"), nil, "a=b")
    eq(CaretHintLogic.mathResult(beforeCaret: "x = 5"), nil, "x = 5")
    eq(CaretHintLogic.mathResult(beforeCaret: "12*3"), nil, "chưa có =")
    eq(CaretHintLogic.math(before: "12*3="), S(.math, "= 36", "", "36"), "math suggestion")

    // MARK: Chip số — chỉ dạng tiền (fixture chung, bỏ đọc chữ)
    var k = 0
    for c in lines("number-chips.txt") where c.first == "chip" && (c.count == 3 || c.count == 5) {
        var ctx = c[1], sp = ""
        if !ctx.hasSuffix(" ") { ctx += " "; sp = " " }
        let want: CaretSuggestion? = c.count == 5 && CaretHintLogic.isMoneyFormat(c[2])
            ? S(.number, c[2], c[3] + sp, c[4] + sp) : nil
        eq(CaretHintLogic.moneyChip(before: ctx), want, "money «\(ctx)»"); k += 1
    }
    check(k > 20, "number-chips: chỉ \(k) ca chip")
    eq(CaretHintLogic.moneyChip(before: "giá 1tr2 ")?.display, "1.200.000 ₫", "1tr2")
    eq(CaretHintLogic.moneyChip(before: "giá 1tr2"), nil, "chưa có dấu cách")
    eq(CaretHintLogic.moneyChip(before: "1250000 "), nil, "đọc chữ: bỏ")
    check(CaretHintLogic.numberWorthChecking(boundary: " ", run: "1tr2", prevRun: ""), "worth 1tr2")
    check(CaretHintLogic.numberWorthChecking(boundary: " ", run: "tỷ", prevRun: "2"), "worth 2 tỷ")
    check(!CaretHintLogic.numberWorthChecking(boundary: ",", run: "50k", prevRun: ""), "worth , ")
    check(!CaretHintLogic.numberWorthChecking(boundary: " ", run: "hello", prevRun: "word"), "worth chữ")

    // MARK: Sửa lỗi gõ sai (CaretSuggestionsTests)
    typealias T = TypoFixLogic
    check(T.worthChecking(boundary: " ", raw: "tpoi", word: "tpoi"), "gate space")
    check(T.worthChecking(boundary: ",", raw: "tpoi", word: "tpoi"), "gate ,")
    check(!T.worthChecking(boundary: ".", raw: "tpoi", word: "tpoi"), "gate .")
    check(!T.worthChecking(boundary: "'", raw: "tpoi", word: "tpoi"), "gate '")
    check(!T.worthChecking(boundary: "\n", raw: "tpoi", word: "tpoi"), "gate Enter")
    check(!T.worthChecking(boundary: " ", raw: "tooi", word: "tôi"), "gate âm tiết hợp lệ")
    check(!T.worthChecking(boundary: " ", raw: "kp", word: "kp"), "gate ngắn")
    check(!T.worthChecking(boundary: " ", raw: "tp1i", word: "tp1i"), "gate số")
    check(!T.worthChecking(boundary: " ", raw: "tpoi", word: "(tpoi"), "gate ký hiệu")

    let flags = T.EngineFlags()
    func fix(_ raw: String) -> String? { T.lexiconCorrection(raw: raw, flags: flags) }
    eq(fix("tpoi"), "tôi", "fix tpoi")
    eq(fix("Tpoi"), "Tôi", "fix Tpoi")
    eq(fix("khoong"), nil, "fix khoong")
    eq(fix("khpong"), "không", "fix khpong")
    eq(fix("nhuwng"), nil, "fix nhuwng")
    eq(fix("github"), nil, "fix github")
    eq(fix("hello"), nil, "fix hello")
    eq(fix("toi"), nil, "fix toi")
    eq(fix("tooi"), nil, "fix tooi")
    check(T.isKnown("the"), "known the")
    check(!T.isKnown("tpoi"), "known tpoi")
    eq(T.EngineFlags(bits: "1010000110"), T.EngineFlags(), "flags mặc định")
    check(T.EngineFlags(bits: "0000010000").vniMode, "flags vni")
    check(T.EngineFlags(bits: "00000000001").autoCircumflex, "flags autoCircumflex")
    eq(T.EngineFlags(bits: "10100001100"), T.EngineFlags(), "flags mặc định (11 chữ số)")

    typealias C = T.Cand
    let p = T.Params(minLen: 3, minFreq: 150, margin: 80, edits: [.sub, .swap], rivals: [.del, .ins])
    eq(T.pick([C(word: "tôi", freq: 255, edit: .sub)], p: p)?.word, "tôi", "pick một")
    eq(T.pick([C(word: "tôi", freq: 140, edit: .sub)], p: p), nil, "pick hiếm")
    eq(T.pick([C(word: "tôi", freq: 255, edit: .sub), C(word: "tới", freq: 200, edit: .sub)], p: p), nil, "pick sát nút")
    eq(T.pick([C(word: "tội", freq: 175, edit: .sub), C(word: "tôi", freq: 255, edit: .del)], p: p), nil, "pick đối thủ")
    eq(T.pick([C(word: "tôi", freq: 255, edit: .sub), C(word: "tối", freq: 150, edit: .ins)], p: p)?.word, "tôi", "pick margin")

    eq(T.suggestion(before: "anh tpoi,", word: "tpoi", boundary: ",", raw: "tpoi", fix: "tôi"),
       S(.typo, "tôi", "tpoi,", "tôi,"), "typo giữ ranh giới")
    eq(T.suggestion(before: "anh xtpoi ", word: "tpoi", boundary: " ", raw: "tpoi", fix: "tôi"), nil, "typo dính")
    eq(T.suggestion(before: "anh tpoi", word: "tpoi", boundary: " ", raw: "tpoi", fix: "tôi"), nil, "typo lệch")
    check(T.suggestion(before: "Xong. Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi") != nil, "typo hoa đầu câu")
    check(T.suggestion(before: "Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi") != nil, "typo đầu văn bản")
    eq(T.suggestion(before: "gặp Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi"), nil, "typo tên riêng")
    eq(T.suggestion(before: "\u{FFFC}Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi"), nil, "typo chưa neo")

    // MARK: Thêm dấu cho cụm không dấu
    func feed(_ t: inout ToneRunLogic.Tracker, _ text: String) -> [ToneRunLogic.Trigger?] {
        var out: [ToneRunLogic.Trigger?] = []
        var chunk = ""
        for ch in text {
            if ch.isLetter || ch.isNumber { chunk.append(ch); continue }
            out.append(t.feed(chunk: chunk, boundary: String(ch)))
            chunk = ch.isWhitespace ? "" : chunk + String(ch)
        }
        return out
    }
    var tr = ToneRunLogic.Tracker()
    eq(feed(&tr, "toi di hoc "), [nil, nil, .pause], "tracker 1")
    eq(feed(&tr, "hom nay "), [.pause, .pause], "tracker 2")
    tr.reset(); eq(feed(&tr, "toi di hoc."), [nil, nil, .sentenceEnd], "tracker .")
    eq(feed(&tr, " roi "), [nil, nil], "tracker câu mới")
    tr.reset(); eq(feed(&tr, "toi, di hoc "), [nil, nil, nil, .pause], "tracker ,")
    tr.reset(); eq(feed(&tr, "tôi di hoc "), [nil, nil, nil], "tracker có dấu")
    tr.reset(); eq(feed(&tr, "the cat is "), [nil, nil, nil], "tracker Anh")
    tr.reset(); eq(feed(&tr, "toi di\nhoc "), [nil, nil, nil], "tracker xuống dòng")
    tr.reset(); eq(feed(&tr, "a b "), [nil, nil], "tracker ngắn")
    for (c, want) in [("toi", true), ("hoc", true), ("toi,", true), ("Toi", true), ("TOI", true), ("tOi", false),
                      ("the", false), ("tôi", false), ("abcdefgh", false), ("", false), ("hoc.", true)] {
        eq(ToneRunLogic.isUnaccentedSyllable(Substring(c)), want, "unaccented «\(c)»")
    }

    eq(ToneRunLogic.run(before: "toi di hoc "), "toi di hoc ", "run 1")
    eq(ToneRunLogic.run(before: "Chiều nào toi di hoc hom nay "), "toi di hoc hom nay ", "run 2")
    eq(ToneRunLogic.run(before: "Xong. toi di hoc."), "toi di hoc.", "run 3")
    eq(ToneRunLogic.run(before: "xin chao ban. toi di hoc "), "toi di hoc ", "run câu trước")
    eq(ToneRunLogic.run(before: "dong 1\ntoi di hoc "), "toi di hoc ", "run dòng")
    eq(ToneRunLogic.run(before: "toi di "), nil, "run ngắn")
    eq(ToneRunLogic.run(before: "tôi đi học "), nil, "run có dấu")
    eq(ToneRunLogic.run(before: "open the file "), nil, "run Anh")

    let run = "toi di hoc "
    let restored = apply(.addTones, run)
    eq(restored, "tôi đi học ", "addTones")
    eq(ToneRunLogic.suggestion(run: run, restored: restored ?? ""), S(.tones, "tôi đi học", run, "tôi đi học "), "tones sugg")
    eq(ToneRunLogic.suggestion(run: run, restored: run), nil, "tones không đổi")
    eq(ToneRunLogic.suggestion(run: run, restored: "tôi"), nil, "tones lệch độ dài")

    // MARK: Ngày giờ
    let en: (String) -> Bool = T.isEnglish
    typealias D = DateHintLogic
    eq(D.detect(boundary: " ", prevRun: "hôm", run: "nay", isEnglish: en), .today, "date hôm nay")
    eq(D.detect(boundary: " ", prevRun: "Hôm", run: "qua", isEnglish: en), .yesterday, "date Hôm qua")
    eq(D.detect(boundary: " ", prevRun: "ngày", run: "mai", isEnglish: en), .tomorrow, "date ngày mai")
    eq(D.detect(boundary: " ", prevRun: "bây", run: "giờ", isEnglish: en), .now, "date bây giờ")
    eq(D.detect(boundary: " ", prevRun: "you", run: "tomorrow", isEnglish: en), .tomorrow, "date you tomorrow")
    eq(D.detect(boundary: " ", prevRun: "right", run: "now", isEnglish: en), .now, "date right now")
    eq(D.detect(boundary: " ", prevRun: "", run: "now", isEnglish: en), nil, "date now trơn")
    eq(D.detect(boundary: " ", prevRun: "gặp", run: "today", isEnglish: en), nil, "date gặp today")
    eq(D.detect(boundary: ",", prevRun: "hôm", run: "nay", isEnglish: en), nil, "date ,")
    eq(D.detect(boundary: " ", prevRun: "hom", run: "nay", isEnglish: en), nil, "date không dấu")
    eq(D.detect(boundary: " ", prevRun: "hôm", run: "sau", isEnglish: en), nil, "date hôm sau")

    let now = D.LocalTime(year: 2026, month: 9, day: 28, hour: 21, minute: 35)
    eq(D.format(.today, now: now), "28/09/2026", "format today")
    eq(D.format(.tomorrow, now: now), "29/09/2026", "format tomorrow")
    eq(D.format(.yesterday, now: now), "27/09/2026", "format yesterday")
    eq(D.format(.now, now: now), "21:35", "format now")
    eq(D.format(.tomorrow, now: .init(year: 2026, month: 12, day: 31, hour: 0, minute: 5)), "01/01/2027", "qua năm")
    eq(D.format(.yesterday, now: .init(year: 2028, month: 3, day: 1, hour: 9, minute: 0)), "29/02/2028", "năm nhuận")
    eq(D.format(.now, now: .init(year: 2026, month: 1, day: 1, hour: 7, minute: 4)), "07:04", "giờ 2 chữ số")

    eq(D.suggestion(before: "Hẹn hôm nay ", prevRun: "hôm", run: "nay", phrase: .today, now: now),
       S(.date, "28/09/2026", "hôm nay ", "28/09/2026 "), "date sugg")
    eq(D.suggestion(before: "bây giờ ", prevRun: "bây", run: "giờ", phrase: .now, now: now)?.insert, "21:35 ", "date giờ")
    eq(D.suggestion(before: "see you tomorrow ", prevRun: "you", run: "tomorrow", phrase: .tomorrow, now: now)?.replace,
       "tomorrow ", "date Anh")
    eq(D.suggestion(before: "xhôm nay ", prevRun: "hôm", run: "nay", phrase: .today, now: now), nil, "date dính")
    eq(D.suggestion(before: "hôm nay", prevRun: "hôm", run: "nay", phrase: .today, now: now), nil, "date lệch")

    // Âm lịch (lịch Việt Nam UTC+7): "âm lịch␣" / "ngày âm␣" / "ÂL␣"
    eq(D.detect(boundary: " ", prevRun: "âm", run: "lịch", isEnglish: en), .lunar, "lunar âm lịch")
    eq(D.detect(boundary: " ", prevRun: "Âm", run: "lịch", isEnglish: en), .lunar, "lunar Âm lịch")
    eq(D.detect(boundary: " ", prevRun: "ÂM", run: "LỊCH", isEnglish: en), .lunar, "lunar ÂM LỊCH")
    eq(D.detect(boundary: " ", prevRun: "a\u{0302}m", run: "li\u{0323}ch", isEnglish: en), .lunar, "lunar NFD")
    eq(D.detect(boundary: " ", prevRun: "ngày", run: "âm", isEnglish: en), .lunar, "lunar ngày âm")
    eq(D.detect(boundary: " ", prevRun: "ngày", run: "mai", isEnglish: en), .tomorrow, "ngày mai vẫn còn")
    eq(D.detect(boundary: " ", prevRun: "", run: "ÂL", isEnglish: en), .lunar, "lunar ÂL")
    eq(D.detect(boundary: " ", prevRun: "là", run: "âl", isEnglish: en), .lunar, "lunar là âl")
    eq(D.detect(boundary: ",", prevRun: "âm", run: "lịch", isEnglish: en), nil, "lunar ,")
    eq(D.detect(boundary: " ", prevRun: "am", run: "lich", isEnglish: en), nil, "lunar không dấu")
    eq(D.detect(boundary: " ", prevRun: "", run: "al", isEnglish: en), nil, "lunar al")
    let nov8 = D.LocalTime(year: 2026, month: 11, day: 8, hour: 9, minute: 0)
    eq(D.format(.lunar, now: nov8), "30/9 năm Bính Ngọ", "format lunar")
    eq(D.format(.lunar, now: .init(year: 2026, month: 2, day: 16, hour: 9, minute: 0)), "29/12 năm Ất Tỵ", "lunar trước Tết")
    eq(D.format(.lunar, now: .init(year: 2025, month: 7, day: 25, hour: 9, minute: 0)), "1/6 nhuận năm Ất Tỵ", "lunar nhuận")
    eq(D.suggestion(before: "Hôm nay âm lịch ", prevRun: "âm", run: "lịch", phrase: .lunar, now: nov8),
       S(.date, "30/9 năm Bính Ngọ", "âm lịch ", "30/9 năm Bính Ngọ "), "lunar sugg")
    eq(D.suggestion(before: "ngày âm ", prevRun: "ngày", run: "âm", phrase: .lunar, now: nov8)?.replace,
       "ngày âm ", "lunar ngày âm sugg")
    eq(D.suggestion(before: "Hôm nay ÂL ", prevRun: "nay", run: "ÂL", phrase: .lunar, now: nov8),
       S(.date, "30/9 năm Bính Ngọ", "ÂL ", "30/9 năm Bính Ngọ "), "lunar ÂL sugg")
    eq(D.suggestion(before: "ngày ÂL ", prevRun: "ngày", run: "ÂL", phrase: .lunar, now: nov8)?.replace,
       "ÂL ", "lunar ngày ÂL chỉ thay ÂL")
    eq(D.suggestion(before: "xâm lịch ", prevRun: "âm", run: "lịch", phrase: .lunar, now: nov8), nil, "lunar dính")
    eq(HintProtocol.handle("date\tâm lịch \tâm\tlịch\t \t2026\t11\t8\t9\t0"),
       "date\t30/9 năm Bính Ngọ\tâm lịch \t30/9 năm Bính Ngọ ", "serve lunar")
    eq(HintProtocol.handle("date\tÂL \t\tÂL\t \t2026\t11\t8\t9\t0"),
       "date\t30/9 năm Bính Ngọ\tÂL \t30/9 năm Bính Ngọ ", "serve lunar ÂL")

    // Tết kế tiếp: "Tết␣" ⇒ ngày dương mùng 1 Tết đầu tiên ≥ hôm nay; Tab giữ chữ Tết.
    eq(D.detect(boundary: " ", prevRun: "", run: "Tết", isEnglish: en), .tet, "tet Tết")
    eq(D.detect(boundary: " ", prevRun: "ăn", run: "tết", isEnglish: en), .tet, "tet ăn tết")
    eq(D.detect(boundary: " ", prevRun: "", run: "TẾT", isEnglish: en), .tet, "tet TẾT")
    eq(D.detect(boundary: " ", prevRun: "", run: "te\u{0302}\u{0301}t", isEnglish: en), .tet, "tet NFD")
    eq(D.detect(boundary: " ", prevRun: "", run: "tếtt", isEnglish: en), nil, "tet tếtt")
    eq(D.detect(boundary: " ", prevRun: "", run: "tet", isEnglish: en), nil, "tet không dấu")
    eq(D.detect(boundary: " ", prevRun: "", run: "tét", isEnglish: en), nil, "tet tét")
    eq(D.detect(boundary: ",", prevRun: "", run: "Tết", isEnglish: en), nil, "tet ,")
    eq(D.format(.tet, now: nov8), "06/02/2027", "tet 8/11/2026")
    eq(D.format(.tet, now: .init(year: 2027, month: 2, day: 5, hour: 9, minute: 0)), "06/02/2027", "tet hôm trước")
    eq(D.format(.tet, now: .init(year: 2027, month: 2, day: 6, hour: 9, minute: 0)), "06/02/2027", "tet đúng mùng 1")
    eq(D.format(.tet, now: .init(year: 2027, month: 2, day: 7, hour: 9, minute: 0)), "26/01/2028", "tet hôm sau")
    eq(D.format(.tet, now: .init(year: 2026, month: 1, day: 1, hour: 9, minute: 0)), "17/02/2026", "tet đầu năm")
    eq(D.suggestion(before: "Sắp Tết ", prevRun: "Sắp", run: "Tết", phrase: .tet, now: nov8),
       S(.date, "06/02/2027", "Tết ", "Tết 06/02/2027 "), "tet sugg")
    eq(D.suggestion(before: "TẾT ", prevRun: "", run: "TẾT", phrase: .tet, now: nov8)?.insert, "TẾT 06/02/2027 ", "tet giữ hoa")
    eq(D.suggestion(before: "ngày tết ", prevRun: "ngày", run: "tết", phrase: .tet, now: nov8)?.replace, "tết ", "tet chỉ thay Tết")
    eq(D.suggestion(before: "xTết ", prevRun: "", run: "Tết", phrase: .tet, now: nov8), nil, "tet dính")
    eq(HintProtocol.handle("date\tTết \t\tTết\t \t2026\t11\t8\t9\t0"),
       "date\t06/02/2027\tTết \tTết 06/02/2027 ", "serve tet")
    var tetBad = 0
    for y in 1901...2100 {
        let g = LunarCalendar.gregorian(LunarCalendar.tetDayNumber(lunarYear: y))
        if g.year != y || LunarCalendar.lunar(day: g.day, month: g.month, year: g.year)
            != .init(day: 1, month: 1, year: y, leap: false) { tetBad += 1 }
    }
    eq(tetBad, 0, "tet 1901–2100 = 1/1 âm")

    // Thuật toán âm lịch: Tết 2026–2035 (UTC+7; 2030 là 02/02 — lịch +8 là 03/02), Trung Thu,
    // tháng nhuận 2025 (6) / 2028 (5), và ngày lệch giữa +7 và +8.
    typealias LC = LunarCalendar
    for (y, m, d) in [(2026, 2, 17), (2027, 2, 6), (2028, 1, 26), (2029, 2, 13), (2030, 2, 2),
                      (2031, 1, 23), (2032, 2, 11), (2033, 1, 31), (2034, 2, 19), (2035, 2, 8)] {
        eq(LC.lunar(day: d, month: m, year: y), .init(day: 1, month: 1, year: y, leap: false), "Tết \(y)")
    }
    eq(LC.lunar(day: 3, month: 2, year: 2030, timeZone: 8).day, 1, "Tết 2030 lịch +8")
    for (y, m, d) in [(2026, 9, 25), (2027, 9, 15), (2028, 10, 3), (2029, 9, 22), (2030, 9, 12),
                      (2031, 10, 1), (2032, 9, 19), (2033, 9, 8), (2034, 9, 26), (2035, 9, 16)] {
        eq(LC.lunar(day: d, month: m, year: y), .init(day: 15, month: 8, year: y, leap: false), "Trung Thu \(y)")
    }
    eq(LC.lunar(day: 24, month: 7, year: 2025), .init(day: 30, month: 6, year: 2025, leap: false), "trước nhuận 6/2025")
    eq(LC.lunar(day: 25, month: 7, year: 2025), .init(day: 1, month: 6, year: 2025, leap: true), "nhuận 6/2025")
    eq(LC.lunar(day: 23, month: 8, year: 2025), .init(day: 1, month: 7, year: 2025, leap: false), "sau nhuận 2025")
    eq(LC.lunar(day: 23, month: 6, year: 2028), .init(day: 1, month: 5, year: 2028, leap: true), "nhuận 5/2028")
    eq(LC.lunar(day: 8, month: 11, year: 2026), .init(day: 30, month: 9, year: 2026, leap: false), "08/11/2026")
    eq(LC.lunar(day: 13, month: 8, year: 2026), .init(day: 1, month: 7, year: 2026, leap: false), "sóc 00:37 13/08/2026")
    eq(LC.lunar(day: 22, month: 3, year: 2023), .init(day: 1, month: 2, year: 2023, leap: true), "nhuận 2/2023")
    eq(LC.lunar(day: 21, month: 1, year: 1985), .init(day: 1, month: 1, year: 1985, leap: false), "Tết 1985")
    eq(LC.yearName(2025) + "|" + LC.yearName(2026) + "|" + LC.yearName(2027), "Ất Tỵ|Bính Ngọ|Đinh Mùi", "can chi")

    // MARK: Giao thức --serve
    eq(HintProtocol.unescape(Substring(HintProtocol.escape("a\tb\nc\\d\re"))), "a\tb\nc\\d\re", "escape")
    eq(HintProtocol.handle("ping"), "ok", "ping")
    eq(HintProtocol.handle("math\t12*3="), "math\t= 36\t\t36", "serve math")
    eq(HintProtocol.handle("math\tabc"), "-", "serve math không")
    eq(HintProtocol.handle("number\tgiá 1tr2 "), "number\t1.200.000 ₫\t1tr2 \t1.200.000 ₫ ", "serve number")
    eq(HintProtocol.handle("date\tHẹn hôm nay \thôm\tnay\t \t2026\t9\t28\t21\t35"),
       "date\t28/09/2026\thôm nay \t28/09/2026 ", "serve date")
    eq(HintProtocol.handle("date\tnay \t\tnay\t \t2026\t9\t28\t21\t35"), "-", "serve date không")
    eq(HintProtocol.handle("typo\tanh tpoi \ttpoi\t \ttpoi\t1010000110"), "typo\ttôi\ttpoi \ttôi ", "serve typo")
    eq(HintProtocol.handle("typo\tgithub \tgithub\t \tgithub\t1010000110"), "-", "serve typo Anh")
    eq(HintProtocol.handle("tones\txin chao ban. toi di hoc "), "tones\ttôi đi học\ttoi di hoc \ttôi đi học ", "serve tones")
    eq(HintProtocol.handle("tones\ttoi di "), "-", "serve tones ngắn")
    eq(HintProtocol.handle("tones\tdong 1\\ntoi di hoc "), "tones\ttôi đi học\ttoi di hoc \ttôi đi học ", "serve tones \\n")
    eq(HintProtocol.handle("lạ\tx"), "-", "serve lệnh lạ")
    eq(HintProtocol.handle(""), "-", "serve rỗng")

    // MARK: Gợi ý từ (macOS AppTests/WordPredictionTests — Predict.swift)
    typealias L = PredictionLogic
    typealias R = PredictionLogic.Request
    eq(L.request(before: "xin chào bạn đư", typed: "đư", english: false),
       R(typed: "đư", prev: "bạn", prev2: "chào", english: false), "request đang gõ")
    eq(L.request(before: "đư", typed: "đư", english: false), R(typed: "đư", prev: nil, prev2: nil, english: false),
       "request đầu văn bản")
    eq(L.request(before: "abc.đư", typed: "đư", english: false), nil, "request không đứng riêng")
    eq(L.request(before: "chào đ", typed: "đ", english: false), nil, "request 1 chữ")
    eq(L.request(before: "chào đư", typed: "đươ", english: false), nil, "request lệch")
    eq(L.request(before: "a1", typed: "a1", english: false), nil, "request số")
    eq(L.request(before: "\u{FFFC}đư", typed: "đư", english: false), nil, "request chưa neo")
    eq(L.request(before: "cảm ", typed: "", english: false), R(typed: "", prev: "cảm", prev2: nil, english: false),
       "request từ kế tiếp")
    eq(L.request(before: "Tôi Đang ", typed: "", english: false)?.prev, "đang", "request chữ thường")
    eq(L.request(before: "Tôi Đang ", typed: "", english: false)?.prev2, "tôi", "request prev2")
    eq(L.request(before: "xin chào, bạn ", typed: "", english: false),
       R(typed: "", prev: "bạn", prev2: nil, english: false), "request dấu phẩy cắt")
    eq(L.request(before: "dòng một\nđi ", typed: "", english: false)?.prev2, nil, "request xuống dòng cắt")
    for b in ["hai  ", "xong. ", " ", "", "a.b "] {
        eq(L.request(before: b, typed: "", english: false), nil, "request không «\(b)»")
    }
    check(L.muted(typed: "đươ", declined: "đư"), "muted tiền tố")
    check(L.muted(typed: "Đư", declined: "đư"), "muted hoa")
    check(!L.muted(typed: "đa", declined: "đư"), "muted khác")
    check(!L.muted(typed: "", declined: "đư"), "muted rỗng")
    check(!L.muted(typed: "đư", declined: nil), "muted nil")

    func cands(_ before: String, typed: String = "", raw: String = "", english: Bool = false,
               filter: Bool = true) -> [String] {
        guard let r = L.request(before: before, typed: typed, english: english) else { return [] }
        return PredictionModel.shared.candidates(r, raw: raw, filterSensitive: filter)
    }
    // Từ kế tiếp: dòng trigram 2 từ, hoặc seed iOS với một từ (= WordPredictionTests macOS).
    eq(cands("Tên "), [], "next một từ ngữ cảnh, không seed: không")
    eq(cands("cảm ").first, "ơn", "next seed cảm → ơn")
    eq(cands("xin ").first, "lỗi", "next seed xin → lỗi")
    eq(cands("zzqx cảm ").first, "ơn", "next seed không trigram")
    eq(cands("nguyễn ").first, "Văn", "next seed DisplayCase")
    eq(cands("good ", english: true).first, "morning", "next seed tiếng Anh")
    eq(cands("anh ", english: true), [], "next seed Việt trong ngữ cảnh Anh: không")
    eq(cands("xong, tên "), [], "next dấu phẩy cắt: không")
    eq(cands("zzqx tên "), [], "next cặp không trigram, không seed: không")
    eq(cands("vãi ").first, "cả", "lọc nhạy cảm bật")
    eq(cands("vãi ", filter: false).first, "lồn", "lọc nhạy cảm tắt")
    eq(cands("ngon "), [], "lọc bật: seed chỉ có từ nhạy cảm")
    eq(cands("ngon ", filter: false).first, "vl", "lọc tắt")
    // Tiếng Anh giữa câu Việt (prefersEnglish) — và nơi không được bật.
    eq(cands("tôi gặp pé", typed: "pé", raw: "pers").first, "person", "en override pers")
    eq(cands("ưởn", typed: "ưởn", raw: "wron").first, "wrong", "en override wron")
    for (t, raw) in [("toi", "toi"), ("duoc", "duoc"), ("cam", "cam"), ("thẻ", "ther"), ("thin", "thin"), ("chan", "chan")] {
        let c = cands("anh " + t, typed: t, raw: raw)
        check(!c.contains { SwipeEnglish.contains($0.lowercased()) && !VNSuggest.contains($0) }, "en override không «\(raw)»: \(c)")
    }
    // Sửa lỗi gõ tiếng Anh (= CaretSuggestionsTests macOS).
    let fx: (String) -> String? = { TypoFixLogic.lexiconCorrection(raw: $0, flags: .init()) }
    eq(fx("spellnig"), "spelling", "typo en spellnig")
    eq(fx("teh"), "the", "typo en teh")
    eq(fx("becuase"), "because", "typo en becuase")
    eq(fx("goverment"), "government", "typo en goverment")
    eq(fx("hte"), nil, "typo en hte (he sát nút)")
    eq(fx("tpoi"), "tôi", "typo vi vẫn trước")
    eq(TypoFixLogic.correction(raw: "shjt", compose: { $0 }, frequency: { _ in nil }, hasCompletion: { _ in false },
                               isKnown: { _ in false }, englishFrequency: { $0 == "shit" ? 200 : nil }), nil, "typo lọc bật")
    eq(TypoFixLogic.correction(raw: "shjt", compose: { $0 }, frequency: { _ in nil }, hasCompletion: { _ in false },
                               isKnown: { _ in false }, englishFrequency: { $0 == "shit" ? 200 : nil },
                               filterSensitive: false), "shit", "typo lọc tắt")
    check(!cands("cảm ơn ").isEmpty, "next cảm ơn: có")
    check(!cands("xin chào ").isEmpty, "next xin chào: có")
    check(cands("hôm nay ").count <= L.rankDepth, "next ≤ rankDepth")
    eq(cands("hello world ", english: true), [], "next tiếng Anh: không")
    eq(cands("zzqx zzqy "), [], "next từ lạ")
    let ho = cands("thành phố hồ ")
    check(!ho.contains("chí") && ho.first == "Chí", "display case hồ: \(ho)")
    let du = cands("tôi đư", typed: "đư", raw: "dduw")
    check(du.contains("được"), "complete đư: \(du)")
    check(du.count <= L.rankDepth && du.allSatisfy { $0.count > 2 }, "complete thật: \(du)")
    let up = cands("Đư", typed: "Đư", raw: "Dduw")
    check(!up.isEmpty && up.allSatisfy { $0.first?.isUppercase == true }, "complete hoa: \(up)")
    eq(cands("cảm ơ", typed: "ơ", raw: "ow"), [], "complete 1 chữ")
    eq(cands("xin ch", typed: "ch", raw: "ch").first, "chào", "complete xin ch")
    check(cands("my keyb", typed: "keyb", raw: "keyb").contains("keyboard"), "complete keyb")
    check(cands("this is beca", typed: "beca", raw: "beca", english: true).contains("because"), "complete beca")
    let thi = cands("thí", typed: "thí", raw: "this", english: true)
    check(thi.allSatisfy { $0.hasPrefix("this") && $0.count > 4 }, "complete phím thô: \(thi)")
    for (b, t) in [("đị", "đị"), ("đi", "đi"), ("fu", "fu"), ("sh", "sh"), ("vc", "vc")] {
        let c = cands(b, typed: t, raw: t)
        check(c.allSatisfy { !SensitiveWords.set.contains($0.lowercased()) }, "nhạy cảm «\(t)»: \(c)")
    }
    eq(L.answer(["được", "đường", "đưa", "đứng"], typed: "đư"), "predict\tđược\tđư\tđược ", "answer: chỉ hạng 1")
    eq(L.answer(["ơn"], typed: ""), "predict\tơn\t\tơn ", "answer từ kế tiếp")
    eq(L.answer([], typed: "x"), "-", "answer rỗng")
    eq(HintProtocol.handle("predict\tTên \t\t\t0"), "-", "serve predict một từ không seed: không")
    eq(HintProtocol.handle("predict\tcảm \t\t\t0"), "predict\tơn\t\tơn ", "serve predict seed")
    eq(HintProtocol.handle("predict\tvãi \t\t\t0\t0"), "predict\tlồn\t\tlồn ", "serve predict lọc tắt")
    eq(HintProtocol.handle("predict\tvãi \t\t\t0\t1"), "predict\tcả\t\tcả ", "serve predict lọc bật")
    eq(HintProtocol.handle("predict\tthành phố hồ \t\t\t0"), "predict\tChí\t\tChí ", "serve predict next")
    eq(HintProtocol.handle("predict\tabc.đư\tđư\tdduw\t0"), "-", "serve predict không")
    // Đo (in ra để báo cáo): thời gian một lượt đã nạp.
    let reqs: [(String, String, String)] = [("cảm ơn ", "", ""), ("xin chào ", "", ""), ("tôi đang ", "", ""), ("hôm nay ", "", ""),
                                            ("tôi đư", "đư", "dduw"), ("xin ch", "ch", "ch"), ("ng", "ng", "ng"),
                                            ("my keyb", "keyb", "keyb"), ("khô", "khô", "khoo")]
    let clock = ContinuousClock()
    var worst = Duration.zero
    let t0 = clock.now
    for _ in 0..<50 {
        for (b, t, raw) in reqs {
            let a = clock.now
            _ = cands(b, typed: t, raw: raw)
            worst = max(worst, clock.now - a)
        }
    }
    let total = clock.now - t0
    let avgUs = Double(total.components.attoseconds / 1_000_000_000_000 + total.components.seconds * 1_000_000)
        / Double(50 * reqs.count)
    let worstUs = worst.components.attoseconds / 1_000_000_000_000 + worst.components.seconds * 1_000_000
    print("PREDICT per-request avg \(Int(avgUs)) µs, worst \(worstUs) µs (\(50 * reqs.count) requests)")
    check(avgUs < 3000, "predict avg \(avgUs) µs")

    // MARK: Học từ bạn gõ (LearnedModel.swift + LearnStore.swift) — cùng ca AppTests/LearnedWordsTests
    func model() -> LearnedModel { LearnedModel(isKnownWord: { VNSuggest.contains($0) }) }
    func typeIn(_ m: LearnedModel, _ sentence: String, times: Int = 1) {
        for _ in 0..<times {
            var tr = LearnTracker()
            for w in sentence.split(separator: " ") {
                if let e = tr.commit(String(w), boundary: " ") { m.record(word: e.word, after: e.prev1, prev2: e.prev2, weight: e.weight) }
            }
            if let e = tr.breakContext() { m.record(word: e.word, after: e.prev1, prev2: e.prev2, weight: e.weight) }
        }
    }
    func next(_ b: String, _ m: LearnedModel?, filter: Bool = true) -> [String] {
        guard let r = L.request(before: b, typed: "", english: false) else { return [] }
        return PredictionModel.shared.candidates(r, raw: "", filterSensitive: filter, learned: m)
    }
    do {
        let m = model()
        typeIn(m, "ăn cơm", times: 3)
        eq(next("ăn ", m).first, "cơm", "học: ăn cơm ×3")
        let t = model()
        typeIn(t, "tên tôi")
        eq(next("Tên ", t), [], "học: một lần chưa đủ")
        typeIn(t, "tên tôi")
        eq(next("Tên ", t), ["tôi"], "học: hai lần")
        let c = model()
        typeIn(c, "cảm ơn anh", times: 3)
        eq(next("cảm ơn ", c).first, "anh", "học: bộ ba dẫn trigram tĩnh")
        let x = model()
        typeIn(x, "thằng cặc", times: 4)
        check(!next("thằng ", x).contains("cặc"), "học: lọc nhạy cảm")
        eq(next("thằng ", x, filter: false).first, "cặc", "học: lọc tắt")
        eq(next("cảm ", model()), next("cảm ", nil), "học: mô hình rỗng = seed")
    }
    // Golden chung Windows/macOS (cột learn).
    let golden = fixtures + "/../../../windows/app/tests/fixtures/word-prediction.tsv"
    var g = 0
    for line in readFixture(golden) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7 else { continue }
        var m: LearnedModel?
        if !f[5].isEmpty {
            let mm = model()
            for part in f[5].split(separator: "|") {
                var sen = String(part), times = 1
                if let star = sen.lastIndex(of: "*"), let k = Int(sen[sen.index(after: star)...]) { times = k; sen = String(sen[..<star]) }
                typeIn(mm, sen, times: times)
            }
            m = mm
        }
        let before = f[0].replacingOccurrences(of: "\\n", with: "\n")
        let got = L.request(before: before, typed: f[1], english: f[3] == "1").map {
            PredictionModel.shared.candidates($0, raw: f[2], filterSensitive: f[4] != "0", learned: m)
        } ?? []
        // Linux: tiếng Anh = SwipeEnglish (macOS EnglishLite — cùng kết quả, test macOS chứng minh).
        eq(got.joined(separator: "|"), f[6], "golden «\(f[0])» «\(f[1])» learn «\(f[5])»")
        g += 1
    }
    check(g >= 140, "golden: chỉ \(g) dòng")
    // Lưu file: round trip, hỏng ⇒ rỗng.
    do {
        let url = URL(fileURLWithPath: learnDir + "/rt/" + LearnedModel.fileName)
        let m = model()
        typeIn(m, "cảm ơn anh", times: 3)
        check(LearnedModel.write(m.snapshot().encoded(), to: url), "học: ghi file")
        let back = LearnedModel.load(from: url, isKnownWord: { VNSuggest.contains($0) }, now: m.lastDecay)
        check(!back.recovered && back.model.t.uniDict() == m.t.uniDict() && back.model.t.triDict() == m.t.triDict(),
              "học: round trip")
        var data = m.snapshot().encoded()
        data[data.count / 2] ^= 0xFF
        _ = LearnedModel.write(data, to: url)
        let bad1 = LearnedModel.load(from: url)
        check(bad1.recovered && bad1.model.isEmpty, "học: file hỏng ⇒ rỗng")
    }
    // Giao thức --serve: learn → predict learn=1; learn=0 không dùng; learnclear; file bị xoá từ ngoài.
    do {
        for _ in 0..<2 { eq(HintProtocol.handle("learn\ttôi\ttên\t\t1"), "ok", "serve learn") }
        eq(HintProtocol.handle("learn\t\t\t\t1"), "-", "serve learn rỗng")
        eq(HintProtocol.handle("learn\ttôi\ttên\t\t9"), "-", "serve learn trọng số lạ")
        eq(HintProtocol.handle("predict\tTên \t\t\t0\t1\t1"), "predict\ttôi\t\ttôi ", "serve predict học")
        eq(HintProtocol.handle("predict\tTên \t\t\t0\t1"), "-", "serve predict không học ⇒ như cũ")
        check(!LearnStore.shared.isLoaded, "learn = 0 ⇒ bỏ khỏi RAM")
        check(FileManager.default.fileExists(atPath: LearnStore.shared.url.path), "bỏ khỏi RAM ⇒ đã ghi nốt")
        eq(HintProtocol.handle("predict\tTên \t\t\t0\t1\t1"), "predict\ttôi\t\ttôi ", "serve: nạp lại từ file")
        eq(HintProtocol.handle("learnclear"), "ok", "serve learnclear")
        eq(HintProtocol.handle("predict\tTên \t\t\t0\t1\t1"), "-", "serve: sau khi xoá")
        // Hẹn lưu: có lượt chờ ⇒ msUntilSave; tới hẹn ⇒ ghi.
        _ = HintProtocol.handle("learn\tphở\t\t\t1")
        check(LearnStore.shared.msUntilSave() != nil, "hẹn lưu")
        LearnStore.shared.saveIfDue(now: LearnStore.now() + LearnStore.saveDelay + 1)
        check(LearnStore.shared.msUntilSave() == nil, "đã lưu")
        // Dữ liệu gõ của người dùng: chỉ chủ đọc được (0600), dù umask là 022.
        do {
            let old = umask(0o022)
            defer { umask(old) }
            _ = HintProtocol.handle("learn\tphở\t\t\t1")
            LearnStore.shared.saveIfDue(force: true)
            var st = stat()
            check(stat(LearnStore.shared.url.path, &st) == 0 && (st.st_mode & 0o777) == 0o600,
                  "học: learned-words.bin 0600")
            check(!FileManager.default.fileExists(atPath: LearnStore.shared.url.path + ".tmp\(getpid())"),
                  "học: không sót file tạm")
        }
        // App Cài đặt "Xoá từ đã học": ghi kho rỗng ⇒ process con thấy file đổi ⇒ nạp lại rỗng.
        _ = HintProtocol.handle("learn\tphở\t\t\t1")
        _ = LearnedModel.write(model().snapshot().encoded(), to: LearnStore.shared.url)
        LearnStore.shared.saveIfDue(force: true)
        let reread = LearnedModel.load(from: LearnStore.shared.url).model
        eq(reread.count("phở"), 0, "xoá từ ngoài: không ghi đè lại dữ liệu cũ")
        // Đo: một lượt học + RAM mô hình 5k từ (in ra cho báo cáo).
        let big = model()
        let clockL = ContinuousClock()
        let words = (0..<5000).map { i -> String in
            var s = "", v = i
            for _ in 0..<3 { s.append(Character(UnicodeScalar(97 + v % 26)!)); v /= 26 }
            return "w" + s
        }
        let tl0 = clockL.now
        for i in 0..<20000 { big.record(word: words[i % 5000], after: words[(i * 7) % 5000], prev2: words[(i * 13) % 5000]) }
        let per = (clockL.now - tl0) / 20000
        print("LEARN per-record \(per) (20000 records, \(big.wordCount) words, \(big.pairCount) pairs, \(big.tripleCount) triples)")
        print("LEARN file size \(big.snapshot().encoded().count) bytes")
    }

    print("caret-suggest: \(n) ca, lệch: \(bad)")
    return bad
}
