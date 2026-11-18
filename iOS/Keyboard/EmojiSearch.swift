// EmojiSearch — tìm emoji bằng tiếng Việt trong bàn phím emoji. Khoá (section SKEY
// của emoji.bin): từ khoá gợi ý emoji sẵn có (EmojiSuggest) + tên/từ khoá CLDR vi.
// Khớp TIỀN TỐ KHÔNG DẤU tại đầu một từ bất kỳ của khoá ("cuoi" → "mặt cười");
// xếp hạng: trùng nguyên khoá có dấu > trùng nguyên khoá không dấu > tiền tố có dấu
// > tiền tố đầu khoá > tiền tố ở từ sau; cùng hạng thì khoá ngắn trước.
// Quét tuyến tính ~6.5k khoá trên blob mmap (không dựng dictionary) — < 1 ms/phím.
// Khoá tiếng Anh (section SKEN, CLDR en) chỉ quét khi câu tìm KHÔNG dấu, và mọi hạng
// tiếng Anh đứng sau hạng tiếng Việt tương ứng (trùng nguyên khoá → hạng 1, tiền tố → 5/6)
// — thứ tự kết quả tiếng Việt không đổi. Gợi ý khi gõ: `typing` (khớp NGUYÊN khoá).
import Foundation
import TelexCore

enum EmojiSearch {
    /// Luật fold PHẢI khớp Scripts/gen-emoji-data.py: chữ thường, bỏ dấu (đ→d),
    /// dấu câu → space, gộp space.
    static func fold(_ s: String) -> String {
        clean(s.lowercased().replacingOccurrences(of: "đ", with: "d")
            .decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) }
            .reduce(into: "") { $0.unicodeScalars.append($1) })
    }

    /// Chữ thường NFC, ký tự không phải chữ/số → space, gộp space.
    static func clean(_ s: String) -> String {
        let n = s.lowercased().precomposedStringWithCanonicalMapping
        var out = ""
        var pendingSpace = false
        for ch in n {
            if ch.isLetter || ch.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    private static let base = EmojiData.section("SKEY")
    static let keyCount = EmojiData.u32(base)
    private static var foldOffBase: Int { base + 4 }
    private static var origOffBase: Int { base + 4 + (keyCount + 1) * 4 }
    private static var idOffBase: Int { base + 4 + 2 * (keyCount + 1) * 4 }
    private static let foldBase = base + 4 + 3 * (keyCount + 1) * 4
    private static let origBase = foldBase + EmojiData.u32(base + 4 + keyCount * 4)
    private static let idBase = origBase + EmojiData.u32(base + 4 + (keyCount + 1) * 4 + keyCount * 4)

    // SKEN: u32 m | u16 foldOff[m+1] | u16 idOff[m+1] | fold utf8 | u16 ids
    private static let enBase = EmojiData.section("SKEN")
    static let enKeyCount = EmojiData.u32(enBase)
    private static let enFoldBase = enBase + 4 + 4 * (enKeyCount + 1)
    private static let enIdBase = enFoldBase + EmojiData.u16(enBase + 4 + enKeyCount * 2)
    @inline(__always) private static func enFoldOff(_ k: Int) -> Int { EmojiData.u16(enBase + 4 + k * 2) }
    @inline(__always) private static func enIdOff(_ k: Int) -> Int { EmojiData.u16(enBase + 4 + (enKeyCount + 1) * 2 + k * 2) }

    /// Emoji khớp `query` (đã theo thứ tự hạng, không trùng, chỉ emoji vẽ được). Câu tìm là
    /// emoticon ASCII (":)", "<3", "=))"…) ⇒ emoji tương ứng đứng đầu.
    static func search(_ query: String, limit: Int = 60,
                       supported: (Int) -> Bool = EmojiData.isSupported) -> [String] {
        let rest = ids(query, limit: limit, supported: supported).map(EmojiData.emoji)
        let emo = emoticon(query)
        guard !emo.isEmpty else { return rest }
        var seen = Set(emo)
        return Array((emo + rest.filter { seen.insert($0).inserted }).prefix(limit))
    }

    /// Emoticon ASCII → emoji (khoá viết thường; bảng thuần, song sinh Android
    /// EmojiSearch.EMOTICONS). Emoji đều thuộc Emoji ≤ 1.0 ⇒ máy nào cũng vẽ được.
    static let emoticons: [String: [String]] = [
        ":)": ["😊", "🙂", "☺️"], ":-)": ["😊", "🙂", "☺️"], "(:": ["🙂", "😊"],
        ":d": ["😄", "😃", "😁"], ":-d": ["😄", "😃", "😁"],
        ":(": ["☹️", "🙁", "😞"], ":-(": ["☹️", "🙁", "😞"],
        ";)": ["😉"], ";-)": ["😉"],
        ":p": ["😛", "😜", "😝"], ":-p": ["😛", "😜", "😝"],
        "<3": ["❤️", "😍", "💕"], "</3": ["💔"],
        "=))": ["😂", "🤣", "😆"], ":))": ["😆", "😂", "😄"], ":)))": ["😂", "🤣", "😆"],
        "^_^": ["😊", "😄"], "^^": ["😊", "😄"], "^.^": ["😊", "😄"],
        "-_-": ["😑", "😒"], "-.-": ["😑", "😒"],
        ":o": ["😮", "😲"], ":-o": ["😮", "😲"],
        "xd": ["😆", "😂"],
        ":'(": ["😢", "😭"], "t_t": ["😭", "😢"], "t.t": ["😭", "😢"], ";(": ["😢"],
        ":*": ["😘"], ":-*": ["😘"], ":|": ["😐"], ":-|": ["😐"], ":/": ["😕"], ":-/": ["😕"],
        ">:(": ["😠", "😡"], "o.o": ["😳", "😮"], "b)": ["😎"], "8)": ["😎"],
    ]

    /// Emoji cho câu tìm là MỘT emoticon (bỏ space hai đầu, không phân biệt hoa thường).
    static func emoticon(_ query: String) -> [String] {
        emoticons[query.trimmingCharacters(in: .whitespaces).lowercased()] ?? []
    }

    static func ids(_ query: String, limit: Int = 60,
                    supported: (Int) -> Bool = EmojiData.isSupported) -> [Int] {
        let q = clean(query)
        let qf = Array(fold(q).utf8)
        guard !qf.isEmpty else { return [] }
        let qo = Array(q.utf8)
        var hits: [(rank: Int, len: Int, key: Int)] = []
        EmojiData.blob.withUnsafeBytes { raw in
            func u32(_ o: Int) -> Int { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
            for k in 0..<keyCount {
                let fs = foldBase + u32(foldOffBase + k * 4)
                let fe = foldBase + u32(foldOffBase + k * 4 + 4)
                guard let pos = wordPrefix(raw, fs, fe, qf) else { continue }
                let os = origBase + u32(origOffBase + k * 4)
                let oe = origBase + u32(origOffBase + k * 4 + 4)
                let exactFold = pos == 0 && fe - fs == qf.count
                let rank: Int
                if exactFold && equal(raw, os, oe, qo) { rank = 0 }
                else if exactFold { rank = 1 }
                else if wordPrefix(raw, os, oe, qo) != nil { rank = 2 }
                else if pos == 0 { rank = 3 }
                else { rank = 4 }
                hits.append((rank, fe - fs, k))
            }
            // Tiếng Anh: chỉ khi câu tìm không dấu (gõ "cá" không kéo "cat"/"cake" vào).
            guard qo == qf else { return }
            func u16(_ o: Int) -> Int { Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))) }
            let offBase = enBase + 4
            for k in 0..<enKeyCount {
                let fs = enFoldBase + u16(offBase + k * 2)
                let fe = enFoldBase + u16(offBase + k * 2 + 2)
                guard let pos = wordPrefix(raw, fs, fe, qf) else { continue }
                let rank = pos == 0 && fe - fs == qf.count ? 1 : pos == 0 ? 5 : 6
                hits.append((rank, fe - fs, keyCount + k))
            }
        }
        hits.sort { ($0.rank, $0.len, $0.key) < ($1.rank, $1.len, $1.key) }
        var out: [Int] = []
        var seen = Set<Int>()
        for h in hits {
            let en = h.key >= keyCount
            let s = en ? enIdOff(h.key - keyCount) : EmojiData.u32(idOffBase + h.key * 4)
            let e = en ? enIdOff(h.key - keyCount + 1) : EmojiData.u32(idOffBase + h.key * 4 + 4)
            for j in s..<e {
                let id = EmojiData.u16((en ? enIdBase : idBase) + j * 2)
                if seen.insert(id).inserted, supported(id) {
                    out.append(id)
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    // MARK: gợi ý khi gõ (thanh gợi ý) — chỉ gọi khi bảng EmojiSuggest không có từ này

    /// Khoá tiếng Anh có nhiều emoji hơn mức này là quá chung ("face", "flag"…) — không gợi ý khi gõ.
    static let typingMaxIds = 24

    /// Emoji cho từ đang gõ từ khoá tiếng Anh (SKEN) + mã nước in hoa (FLG2).
    /// - "JP"/"VN"/"US" (đúng 2 chữ IN HOA, Telex không biến đổi) → cờ. Chữ thường/"Jp"
    ///   không tra: 65/259 mã trùng âm tiết Việt không dấu (la, ma, to, do, ca, co…).
    /// - Từ chỉ gồm chữ ASCII (tiếng Việt có dấu thì thôi): khớp NGUYÊN khoá, thử cụm
    ///   "từ trước + từ này" ("hot dog", "united states") rồi từ này, rồi raw. Khoá trùng âm
    ///   tiết Việt không dấu / ngắn < 3 chữ đã bị script lọc nên "an", "ban", "me" không ra.
    static func typing(prev: String?, composed: String, raw: String, limit: Int = 3,
                       supported: (Int) -> Bool = EmojiData.isSupported) -> [String] {
        let cu = Array(composed.utf8)
        if cu.count == 2, composed == raw, cu.allSatisfy({ $0 >= 0x41 && $0 <= 0x5A }) {
            return flag(cu).flatMap { supported($0) ? [EmojiData.emoji($0)] : nil } ?? []
        }
        guard isAsciiWord(cu) else { return [] }
        let c = composed.lowercased()
        if let prev, isAsciiWord(Array(prev.utf8)) {
            let r = exact(Array((prev.lowercased() + " " + c).utf8), limit: limit, supported: supported)
            if !r.isEmpty { return r }
        }
        if cu.count >= 3 {
            let r = exact(Array(c.utf8), limit: limit, supported: supported)
            if !r.isEmpty { return r }
        }
        let ru = Array(raw.lowercased().utf8)
        if raw != composed, ru.count >= 3, isAsciiWord(ru) {
            return exact(ru, limit: limit, supported: supported)
        }
        return []
    }

    private static func isAsciiWord(_ u: [UInt8]) -> Bool {
        !u.isEmpty && u.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }
    }

    /// Binary search khớp nguyên khoá trong SKEN (sort theo byte của fold).
    private static func exact(_ q: [UInt8], limit: Int, supported: (Int) -> Bool) -> [String] {
        var lo = 0, hi = enKeyCount
        let k: Int? = EmojiData.blob.withUnsafeBytes { raw in
            func off(_ k: Int) -> Int {
                Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: enBase + 4 + k * 2, as: UInt16.self)))
            }
            func cmp(_ k: Int) -> Int {
                let s = enFoldBase + off(k), e = enFoldBase + off(k + 1)
                var i = s, j = 0
                while i < e && j < q.count {
                    let a = raw[i], b = q[j]
                    if a != b { return a < b ? -1 : 1 }
                    i += 1; j += 1
                }
                return i < e ? 1 : j < q.count ? -1 : 0
            }
            while lo < hi {
                let mid = (lo + hi) / 2
                if cmp(mid) < 0 { lo = mid + 1 } else { hi = mid }
            }
            return lo < enKeyCount && cmp(lo) == 0 ? lo : nil
        }
        guard let k else { return [] }
        let s = enIdOff(k), e = enIdOff(k + 1)
        guard e - s <= typingMaxIds else { return [] }
        var out: [String] = []
        for j in s..<e {
            let id = EmojiData.u16(enIdBase + j * 2)
            if supported(id) {
                out.append(EmojiData.emoji(id))
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// FLG2: u32 n | n × 2B mã in hoa (sort) | u16 id[n] → id cờ.
    private static let flagBase = EmojiData.section("FLG2")
    private static func flag(_ code: [UInt8]) -> Int? {
        let n = EmojiData.u32(flagBase)
        var lo = 0, hi = n
        return EmojiData.blob.withUnsafeBytes { raw -> Int? in
            while lo < hi {
                let mid = (lo + hi) / 2
                let a = raw[flagBase + 4 + mid * 2], b = raw[flagBase + 5 + mid * 2]
                if a == code[0] && b == code[1] { return EmojiData.u16(flagBase + 4 + n * 2 + mid * 2) }
                if a < code[0] || (a == code[0] && b < code[1]) { lo = mid + 1 } else { hi = mid }
            }
            return nil
        }
    }

    /// Vị trí (byte) nơi `q` là tiền tố của một từ trong [s, e) — đầu khoá hoặc sau space.
    private static func wordPrefix(_ raw: UnsafeRawBufferPointer, _ s: Int, _ e: Int, _ q: [UInt8]) -> Int? {
        let n = q.count
        var i = s
        while i + n <= e {
            if i == s || raw[i - 1] == 0x20 {
                var j = 0
                while j < n && raw[i + j] == q[j] { j += 1 }
                if j == n { return i - s }
            }
            i += 1
        }
        return nil
    }

    private static func equal(_ raw: UnsafeRawBufferPointer, _ s: Int, _ e: Int, _ q: [UInt8]) -> Bool {
        guard e - s == q.count else { return false }
        for j in 0..<q.count where raw[s + j] != q[j] { return false }
        return true
    }
}

/// Ô tìm emoji tự vẽ: gõ bằng chính phím VietTelex, có Telex (engine riêng, không
/// đụng composition của ô nhập thật). Thuần logic — KeyboardView lo vẽ.
struct EmojiSearchSession {
    private var engine: TelexEngine
    private var committed = ""

    init() {
        var e = TelexEngine()
        let s = KeyboardSettings.load()
        e.freeMarking = s.freeMarking
        e.simpleTelex = s.simpleTelex
        e.quickTelex = s.quickTelex
        e.modernTone = s.modernTone
        e.liveSpellCheck = s.liveSpellCheck
        e.eagerEnglishRestore = s.autoRestore
        e.teencode = s.teencode
        e.autoCircumflex = s.autoCircumflex
        engine = e
    }

    /// Chuỗi đang hiện trong ô tìm.
    var query: String { committed + engine.peekCommitText(autoRestore: false) }

    mutating func type(_ ch: Character) {
        let c = Character(ch.lowercased())
        if c.isLetter, c.isASCII {
            _ = engine.feed(c)
        } else {
            commitWord()
            committed.append(c)
        }
    }

    mutating func insert(_ s: String) {
        for ch in s { type(ch) }
    }

    mutating func space() {
        commitWord()
        if !committed.isEmpty, committed.last != " " { committed.append(" ") }
    }

    mutating func backspace() {
        if !engine.isEmpty {
            _ = engine.backspace()
        } else if !committed.isEmpty {
            committed.removeLast()
        }
    }

    mutating func clear() {
        engine.reset()
        committed = ""
    }

    private mutating func commitWord() {
        guard !engine.isEmpty else { return }
        committed += engine.commitText(autoRestore: true)
    }
}
