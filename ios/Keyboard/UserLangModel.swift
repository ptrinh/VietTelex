// UserLangModel — datastore cá nhân hóa cho thanh gợi ý. Học từ user hay gõ
// (unigram), cặp từ (bigram) và bộ ba (trigram — tiếng Việt đơn âm tiết nên
// "cảm ơn → nhiều" chỉ trigram mới bắt được) để gợi ý từ ĐẦU CÂU và từ KẾ TIẾP.
//
// Thiết kế theo khảo cứu 2026-07-24 (Gboard/SwiftKey/Grammarly — cache n-gram
// model interpolate với static seed):
// - bi/tri là nested dict (prev → next → count): lookup O(1) mỗi phím, không
//   scan toàn bảng.
// - Ranking = linear interpolation với Bayesian shrinkage λ = n/(n+K): prev
//   mới gặp 1-2 lần thì tin seed tĩnh, gặp nhiều thì tin dữ liệu cá nhân —
//   một lần gõ nhầm không đè được seed curated.
// - "Learning vs suggesting" (Grammarly): từ NGOÀI lexicon phải đạt count ≥3
//   mới được gợi ý (vẫn đếm từ lần đầu) — chặn học typo.
// - Time decay: mỗi ≥7 ngày nhân mọi count với 0.7^tuần lúc load; kèm cap
//   cứng halve-when-full.
// - Persist binary plist (nhanh hơn JSON lúc cold-start), atomic, coalesce 5s.
//
// PRIVACY: chỉ đếm TẦN SUẤT (không câu, không thứ tự, không timestamp per-từ);
// ô mật khẩu không đi qua đây; toggle "Học từ hay dùng" + nút xóa trong app.
import Foundation

final class UserLangModel {
    private(set) var uni: [String: Int] = [:]
    private(set) var bi: [String: [String: Int]] = [:]    // prev1 → next → count
    private(set) var tri: [String: [String: Int]] = [:]   // "p2␁p1" → next → count
    private var lastDecay = Date()
    private var biPairs = 0
    private var triPairs = 0

    /// Lexicon tĩnh — controller nạp VNLexicon vào; từ trong lexicon được gợi ý
    /// ngay, từ lạ cần đạt ngưỡng. Mặc định false để tests kiểm soát được.
    var isKnownWord: (String) -> Bool = { _ in false }

    private let fileURL: URL?
    private var saveWork: DispatchWorkItem?

    private static let uniCap = 3000
    private static let biCap = 6000
    private static let triCap = 3000
    private static let unknownSuggestThreshold = 3
    static let sep = "\u{1}"

    /// Store thật trong App Group; truyền nil cho tests (in-memory).
    init(appGroup: String? = "group.com.viettelex") {
        if let g = appGroup,
           let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) {
            fileURL = dir.appendingPathComponent("userlm.plist")
        } else {
            fileURL = nil
        }
        load()
        decayIfDue()
    }

    // MARK: học

    /// Một từ vừa chốt. `prev1`/`prev2` = 1-2 từ đứng trước trong cùng câu.
    /// `weight`: 1 cho từ gõ thường, 2 cho suggestion được user bấm nhận
    /// (tín hiệu chất lượng cao hơn).
    func record(word: String, after prev1: String?, prev2: String? = nil, weight: Int = 1) {
        guard Self.learnable(word) else { return }
        let w = word.lowercased()
        uni[w, default: 0] += weight
        if let p1 = prev1?.lowercased(), Self.learnable(p1) {
            if bi[p1]?[w] == nil { biPairs += 1 }
            bi[p1, default: [:]][w, default: 0] += weight
            // trigram chỉ ghi khi cặp (p2,p1) đã có nền — giảm noise/chỗ
            if let p2 = prev2?.lowercased(), Self.learnable(p2),
               (bi[p2]?[p1] ?? 0) >= 2 {
                let key = p2 + Self.sep + p1
                if tri[key]?[w] == nil { triPairs += 1 }
                tri[key, default: [:]][w, default: 0] += weight
            }
        }
        pruneIfNeeded()
        scheduleSave()
    }

    /// Từ "học được": chữ cái thuần, ngắn, không chuỗi lặp kiểu "heeeyyy".
    static func learnable(_ w: String) -> Bool {
        guard !w.isEmpty, w.count <= 12, w.allSatisfy({ $0.isLetter }) else { return false }
        var run = 1
        var prev: Character?
        for c in w {
            run = (c == prev) ? run + 1 : 1
            if run >= 3 { return false }
            prev = c
        }
        return true
    }

    /// Được phép XUẤT HIỆN trong gợi ý chưa? (learning vs suggesting)
    private func suggestable(_ w: String) -> Bool {
        isKnownWord(w) || (uni[w] ?? 0) >= Self.unknownSuggestThreshold
    }

    // MARK: gợi ý

    /// Top từ user hay dùng nhất — cho field trống chưa gõ gì.
    func topWords(limit: Int) -> [String] {
        uni.filter { suggestable($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { $0.key }
    }

    /// Từ kế tiếp sau (prev2, prev1): interpolation trigram ⊕ bigram ⊕ unigram
    /// ⊕ seed tĩnh, mỗi tầng có shrinkage riêng.
    func nextWords(after prev1: String, prev2: String? = nil, limit: Int) -> [String] {
        let p1 = prev1.lowercased()
        let biBucket = bi[p1] ?? [:]
        let triBucket = prev2.flatMap { tri[$0.lowercased() + Self.sep + p1] } ?? [:]
        let seeds = Self.seedNext[p1] ?? []

        let biTotal = biBucket.values.reduce(0, +)
        let triTotal = triBucket.values.reduce(0, +)
        let uniTotal = max(uni.values.reduce(0, +), 1)
        let lamTri = Double(triTotal) / (Double(triTotal) + 2)
        let lamBi = Double(biTotal) / (Double(biTotal) + 4)

        var cands = Set(biBucket.keys).union(triBucket.keys).union(seeds)
        cands = cands.filter { suggestable($0) || seeds.contains($0) }

        func score(_ w: String) -> Double {
            let pTri = triTotal > 0 ? Double(triBucket[w] ?? 0) / Double(triTotal) : 0
            let pBi = biTotal > 0 ? Double(biBucket[w] ?? 0) / Double(biTotal) : 0
            let pUni = Double(uni[w] ?? 0) / Double(uniTotal)
            let pSeed: Double = seeds.firstIndex(of: w).map { pow(0.5, Double($0)) } ?? 0
            return lamTri * pTri
                + lamBi * pBi
                + 0.1 * pUni
                + (1 - lamBi) * 0.9 * pSeed
        }
        return cands.sorted { (score($0), $1) > (score($1), $0) }
            .prefix(limit).map { $0 }
    }

    /// Điểm cá nhân của một từ (re-rank completion của lexicon).
    func count(of word: String) -> Int { uni[word.lowercased()] ?? 0 }

    /// Seed ban đầu — chỉ khi datastore trống (lần đầu / sau reset).
    func seedIfEmpty(unigrams: [String: Int], bigrams: [(String, String, Int)]) {
        guard uni.isEmpty else { return }
        uni = unigrams
        for (a, b, c) in bigrams {
            if bi[a]?[b] == nil { biPairs += 1 }
            bi[a, default: [:]][b] = c
        }
        save()
    }

    // MARK: persistence (binary plist — cold-start nhanh hơn JSON)

    private struct Snapshot: Codable {
        var version = 2
        var uni: [String: Int]
        var bi: [String: [String: Int]]
        var tri: [String: [String: Int]]
        var lastDecay: Date
    }

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let dec = PropertyListDecoder()
        if let s = try? dec.decode(Snapshot.self, from: data) {
            uni = s.uni; bi = s.bi; tri = s.tri; lastDecay = s.lastDecay
        } else if let old = try? JSONDecoder().decode(LegacySnapshot.self, from: data) {
            // v1 (userlm.json cùng nội dung): migrate bigram phẳng → nested
            uni = old.uni
            for (k, c) in old.bi {
                let parts = k.split(separator: Character(Self.sep), maxSplits: 1)
                guard parts.count == 2 else { continue }
                bi[String(parts[0]), default: [:]][String(parts[1])] = c
            }
        }
        biPairs = bi.values.reduce(0) { $0 + $1.count }
        triPairs = tri.values.reduce(0) { $0 + $1.count }
    }
    private struct LegacySnapshot: Codable { var uni: [String: Int]; var bi: [String: Int] }

    func save() {
        saveWork?.cancel(); saveWork = nil
        guard let url = fileURL else { return }
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(Snapshot(uni: uni, bi: bi, tri: tri, lastDecay: lastDecay))
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Extension bị kill không báo trước: coalesce 5s sau record cuối, mất tối
    /// đa vài count — đây là cache, không phải sổ cái.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func eraseAll() {
        uni = [:]; bi = [:]; tri = [:]; biPairs = 0; triPairs = 0
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: decay

    /// Hồ sơ phản ánh thói quen GẦN ĐÂY: mỗi ≥7 ngày, count *= 0.7^tuần
    /// (một timestamp toàn cục duy nhất — không lưu thời gian per-từ).
    private func decayIfDue(now: Date = Date()) {
        let weeks = Int(now.timeIntervalSince(lastDecay) / (7 * 86400))
        guard weeks >= 1 else { return }
        let f = pow(0.7, Double(weeks))
        func decayed(_ c: Int) -> Int? { let v = Int(Double(c) * f); return v > 0 ? v : nil }
        uni = uni.compactMapValues(decayed)
        bi = bi.compactMapValues { inner in
            let d = inner.compactMapValues(decayed); return d.isEmpty ? nil : d
        }
        tri = tri.compactMapValues { inner in
            let d = inner.compactMapValues(decayed); return d.isEmpty ? nil : d
        }
        biPairs = bi.values.reduce(0) { $0 + $1.count }
        triPairs = tri.values.reduce(0) { $0 + $1.count }
        lastDecay = now
        save()
    }

    /// Quá trần cứng: chia đôi mọi count (từ hiếm rơi về 0 và bị loại).
    private func pruneIfNeeded() {
        if uni.count > Self.uniCap {
            uni = uni.compactMapValues { $0 / 2 == 0 ? nil : $0 / 2 }
        }
        if biPairs > Self.biCap {
            bi = bi.compactMapValues { inner in
                let d = inner.compactMapValues { $0 / 2 == 0 ? nil : $0 / 2 }
                return d.isEmpty ? nil : d
            }
            biPairs = bi.values.reduce(0) { $0 + $1.count }
        }
        if triPairs > Self.triCap {
            tri = tri.compactMapValues { inner in
                let d = inner.compactMapValues { $0 / 2 == 0 ? nil : $0 / 2 }
                return d.isEmpty ? nil : d
            }
            triPairs = tri.values.reduce(0) { $0 + $1.count }
        }
    }

    // MARK: seed bigrams — mồi tĩnh khi chưa có dữ liệu cá nhân

    static let seedNext: [String: [String]] = [
        "anh": ["ơi", "đang", "có", "yêu"],
        "em": ["ơi", "yêu", "đang", "nhé"],
        "chị": ["ơi", "đang", "có"],
        "mẹ": ["ơi", "đang", "có"],
        "bạn": ["ơi", "có", "đang"],
        "mình": ["đang", "có", "sẽ", "nghĩ"],
        "tôi": ["đang", "có", "sẽ", "nghĩ"],
        "cảm": ["ơn"],
        "xin": ["chào", "lỗi", "phép"],
        "chúc": ["mừng", "ngủ", "sức"],
        "không": ["có", "phải", "biết", "sao"],
        "rất": ["vui", "đẹp", "ngon", "tốt"],
        "hôm": ["nay", "qua"],
        "ngày": ["mai", "mới", "nào"],
        "buổi": ["sáng", "trưa", "chiều", "tối"],
        "đi": ["làm", "học", "chơi", "ăn"],
        "ăn": ["cơm", "sáng", "trưa", "tối"],
        "đang": ["làm", "ăn", "đi", "ở"],
        "có": ["khỏe", "thể", "gì", "ai"],
        "làm": ["gì", "việc", "sao"],
        "yêu": ["em", "anh", "quá"],
        "ngủ": ["ngon", "sớm", "dậy"],
        "tạm": ["biệt"],
        "hẹn": ["gặp"],
        "gặp": ["lại", "nhau"],
        "vui": ["quá", "lắm", "vẻ"],
        "được": ["không", "rồi", "chưa"],
        "nhớ": ["em", "anh", "nhé"],
    ]
}
