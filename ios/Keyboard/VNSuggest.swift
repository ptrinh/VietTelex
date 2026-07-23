// VNSuggest — inline suggestion cho từ tiếng Việt đang gõ dở, theo thiết kế
// research 2026-07-24: binary search range trên foldedKey (loại 99% lexicon)
// rồi post-filter TƯƠNG THÍCH DẤU từng ký tự:
//   gõ "to" → tôi, tớ, toàn…   (chưa dấu: khớp mọi biến thể)
//   gõ "tô" → tôi, tội, tồi…   (đã gõ ô: quality phải trùng, "toàn" bị loại)
//   gõ "tò" → tò, tòa…         (đã có huyền: tone phải trùng)
// Prefix 1 ký tự đi qua bucket top-32 precomputed (hot path). Toàn bộ dữ liệu
// là static blob trong binary — zero cold-start, ~90KB. <50µs mỗi keystroke.
import Foundation

enum VNSuggest {

    // MARK: bảng decompose runtime (~190 ký tự Việt) — O(1)/char, không alloc

    /// char → (base ascii, attr = quality<<3 | tone). Build một lần.
    private static let decomposeTable: [Character: (base: UInt8, attr: UInt8)] = {
        var m: [Character: (UInt8, UInt8)] = [:]
        let bases: [(Character, [Character?])] = [
            // (base, [none, circumflex, horn/breve]) — mỗi slot là ký tự KHÔNG tone
            ("a", ["a", "â", "ă"]),
            ("e", ["e", "ê", nil]),
            ("o", ["o", "ô", "ơ"]),
            ("u", ["u", nil, "ư"]),
            ("i", ["i", nil, nil]),
            ("y", ["y", nil, nil]),
        ]
        // tone marks theo thứ tự id 1..5 (sắc huyền hỏi ngã nặng) — combining
        let tones: [Character] = ["\u{301}", "\u{300}", "\u{309}", "\u{303}", "\u{323}"]
        for (base, variants) in bases {
            for (q, v) in variants.enumerated() {
                guard let v else { continue }
                m[v] = (UInt8(base.asciiValue!), UInt8(q << 3))
                for (t, mark) in tones.enumerated() {
                    let composed = String(v) + String(mark)
                    let nfc = composed.precomposedStringWithCanonicalMapping
                    if let ch = nfc.count == 1 ? nfc.first : nil {
                        m[ch] = (UInt8(base.asciiValue!), UInt8(q << 3 | (t + 1)))
                    }
                }
            }
        }
        m["đ"] = (UInt8(ascii: "d"), UInt8(3 << 3))
        for scalar in UInt8(ascii: "a")...UInt8(ascii: "z") {
            let ch = Character(UnicodeScalar(scalar))
            if m[ch] == nil { m[ch] = (scalar, 0) }
        }
        return m
    }()

    // MARK: dữ liệu từ Resources/vnlexicon.bin (mmap) — offsets decode một lần

    private static let offsets: [UInt32] = VNLexicon2Data.offsets
    private static let dispOffsets: [UInt32] = VNLexicon2Data.dispOffsets

    private static func foldedEntry(_ id: Int) -> Data {
        VNLexicon2Data.foldedSlice(Int(offsets[id]), Int(offsets[id + 1]))
    }

    static func display(_ id: Int) -> String {
        let lo = Int(id == 0 ? 0 : dispOffsets[id])
        let hi = Int(dispOffsets[id + 1])
        return String(decoding: VNLexicon2Data.displaySlice(lo, hi), as: UTF8.self)
    }

    // MARK: lookup

    /// Decompose chuỗi đang gõ; nil nếu chứa ký tự ngoài chữ Việt/Latin.
    private static func decompose(_ s: String) -> [(base: UInt8, attr: UInt8)]? {
        var out: [(UInt8, UInt8)] = []
        out.reserveCapacity(s.count)
        for ch in s.precomposedStringWithCanonicalMapping.lowercased() {
            guard let d = decomposeTable[ch] else { return nil }
            out.append(d)
        }
        return out.isEmpty ? nil : out
    }

    /// Ứng viên tương thích với chuỗi đang gõ, kèm tần suất tĩnh (0-255),
    /// sắp theo tần suất giảm dần, tối đa `poolLimit` (caller re-rank với
    /// điểm cá nhân/ngữ cảnh rồi lấy top-n).
    static func matches(_ typed: String, poolLimit: Int = 24,
                        excluding: String = "") -> [(word: String, freq: Int)] {
        guard let dec = decompose(typed) else { return [] }
        let prefix = dec.map { $0.base }
        let excludingLower = excluding.lowercased()

        // Ứng viên id: bucket top-32 cho 1 phím, binary-search range còn lại
        let ids: [Int]
        if prefix.count == 1 {
            ids = VNLexicon2Data.firstCharTop[Character(UnicodeScalar(prefix[0]))] ?? []
        } else {
            ids = Array(range(ofFoldedPrefix: prefix))
        }

        var pool: [(Int, Int)] = []   // (freq, id)
        for id in ids {
            let f = foldedEntry(id)
            guard f.count >= prefix.count else { continue }
            // base đã khớp với range/bucket từ ký tự đầu; check phần còn lại + attr
            var ok = true
            let attrBase = Int(offsets[id])
            for (i, (b, a)) in dec.enumerated() {
                let fi = f.index(f.startIndex, offsetBy: i)
                if f[fi] != b { ok = false; break }
                let cand = VNLexicon2Data.attr(attrBase + i)
                let q = a >> 3, t = a & 7
                if q != 0 && q != cand >> 3 { ok = false; break }
                if t != 0 && t != cand & 7 { ok = false; break }
            }
            guard ok else { continue }
            pool.append((Int(VNLexicon2Data.freq(id)), id))
        }
        pool.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        var out: [(String, Int)] = []
        for (f, id) in pool {
            let w = display(id)
            if w == excludingLower { continue }
            out.append((w, f))
            if out.count >= poolLimit { break }
        }
        return out
    }

    /// Có phải âm tiết trong lexicon không (binary search, zero RAM phụ) —
    /// dùng cho learning-vs-suggesting của UserLangModel.
    static func contains(_ word: String) -> Bool {
        guard let dec = decompose(word) else { return false }
        let prefix = dec.map { $0.base }
        for id in range(ofFoldedPrefix: prefix) {
            let f = foldedEntry(id)
            guard f.count == prefix.count else { continue }
            if display(id) == word.lowercased() { return true }
        }
        return false
    }

    /// Range [lo, hi) các entry có foldedKey bắt đầu bằng `prefix`.
    private static func range(ofFoldedPrefix prefix: [UInt8]) -> Range<Int> {
        // so sánh folded[id] với prefix: -1 <, 0 = có prefix này, 1 >
        func cmp(_ id: Int) -> Int {
            let f = foldedEntry(id)
            var i = f.startIndex
            for p in prefix {
                if i == f.endIndex { return -1 }          // entry ngắn hơn prefix
                if f[i] != p { return f[i] < p ? -1 : 1 }
                i = f.index(after: i)
            }
            return 0
        }
        var lo = 0, hi = VNLexicon2Data.count
        while lo < hi {                                   // lower bound
            let mid = (lo + hi) / 2
            if cmp(mid) < 0 { lo = mid + 1 } else { hi = mid }
        }
        let start = lo
        hi = VNLexicon2Data.count
        while lo < hi {                                   // upper bound
            let mid = (lo + hi) / 2
            if cmp(mid) <= 0 { lo = mid + 1 } else { hi = mid }
        }
        return start..<lo
    }
}
