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
// - PERF: decode/encode/IO chạy trên serial queue .utility — init trả về ngay,
//   bảng swap-in trên main khi decode xong (~50ms đầu gợi ý rỗng, chấp nhận);
//   record() trong cửa sổ chờ được buffer và phát lại sau swap-in.
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
    private var uniTotal = 0        // Σ uni.values — incremental, không reduce mỗi phím

    /// Lexicon tĩnh — controller nạp VNLexicon vào; từ trong lexicon được gợi ý
    /// ngay, từ lạ cần đạt ngưỡng. Mặc định false để tests kiểm soát được.
    var isKnownWord: (String) -> Bool = { _ in false } {
        didSet { knownCache.removeAll(); topCache = nil }
    }

    /// Gọi trên main sau khi bảng trên đĩa swap-in xong (controller có thể
    /// refresh thanh gợi ý). Không gọi ở chế độ in-memory (tests).
    var onReady: (() -> Void)?

    private let fileURL: URL?
    private var saveWork: DispatchWorkItem?

    // Encode/decode/IO nền — mọi đọc/ghi bảng vẫn ở main thread.
    private let ioQueue = DispatchQueue(label: "com.viettelex.userlm.io", qos: .utility)
    private var isLoaded = false
    private var loadGeneration = 0    // eraseAll() giữa chừng → bỏ kết quả load cũ
    private var pendingRecords: [(word: String, prev1: String?, prev2: String?, weight: Int)] = []
    private var pendingSeed: (uni: () -> [String: Int], bi: () -> [(String, String, Int)])?

    // Memo isKnownWord (VNSuggest.contains = binary search + alloc mỗi lần) —
    // tính hợp lệ của một từ không đổi trong đời keyboard.
    private var knownCache: [String: Bool] = [:]
    // Cache topWords — invalidate khi record/decay/prune/seed thay đổi uni.
    private var topCache: (k: Int, words: [String])?

    private static let uniCap = 3000
    private static let biCap = 6000
    private static let triCap = 3000
    private static let unknownSuggestThreshold = 3
    private static let pendingRecordCap = 128
    static let sep = "\u{1}"

    /// Store thật trong App Group; truyền nil cho tests (in-memory).
    init(appGroup: String? = "group.com.viettelex") {
        if let g = appGroup,
           let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) {
            fileURL = dir.appendingPathComponent("userlm.plist")
        } else {
            fileURL = nil
        }
        if let url = fileURL {
            loadAsync(from: url)
        } else {
            isLoaded = true          // in-memory: sẵn sàng ngay, tests đồng bộ
        }
    }

    private func loadAsync(from url: URL) {
        let gen = loadGeneration
        ioQueue.async { [weak self] in
            let t = Self.readTables(from: url)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == gen else { return }
                self.finishLoad(t)
            }
        }
    }

    private func finishLoad(_ t: LoadedTables?) {
        if let t {
            uni = t.uni; bi = t.bi; tri = t.tri; lastDecay = t.lastDecay
            biPairs = t.biPairs; triPairs = t.triPairs; uniTotal = t.uniTotal
        }
        isLoaded = true
        topCache = nil
        if uni.isEmpty, let seed = pendingSeed {
            applySeed(unigrams: seed.uni(), bigrams: seed.bi())
        }
        pendingSeed = nil
        let queued = pendingRecords
        pendingRecords = []
        for r in queued { record(word: r.word, after: r.prev1, prev2: r.prev2, weight: r.weight) }
        decayIfDue()
        onReady?()
    }

    // MARK: học

    /// Một từ vừa chốt. `prev1`/`prev2` = 1-2 từ đứng trước trong cùng câu.
    /// `weight`: 1 cho từ gõ thường, 2 cho suggestion được user bấm nhận
    /// (tín hiệu chất lượng cao hơn).
    func record(word: String, after prev1: String?, prev2: String? = nil, weight: Int = 1) {
        guard isLoaded else {
            if pendingRecords.count < Self.pendingRecordCap {
                pendingRecords.append((word, prev1, prev2, weight))
            }
            return
        }
        guard Self.learnable(word) else { return }
        let w = word.lowercased()
        uni[w, default: 0] += weight
        uniTotal += weight
        topCache = nil
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

    private func cachedKnown(_ w: String) -> Bool {
        if let v = knownCache[w] { return v }
        if knownCache.count > 4096 { knownCache.removeAll() }   // chặn phình vô hạn
        let v = isKnownWord(w)
        knownCache[w] = v
        return v
    }

    /// Được phép XUẤT HIỆN trong gợi ý chưa? (learning vs suggesting)
    private func suggestable(_ w: String) -> Bool {
        cachedKnown(w) || (uni[w] ?? 0) >= Self.unknownSuggestThreshold
    }

    // MARK: gợi ý

    /// Top từ user hay dùng nhất — cho field trống chưa gõ gì.
    /// Cached: chỉ tính lại sau record/decay/prune/seed; sort trước rồi mới
    /// chạy suggestable() (memoized) trên phần đầu bảng — không probe lexicon
    /// cho cả ~3000 từ.
    func topWords(limit: Int) -> [String] {
        if let c = topCache, c.k >= limit { return Array(c.words.prefix(limit)) }
        let sorted = uni.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var out: [String] = []
        out.reserveCapacity(limit)
        for (w, _) in sorted where suggestable(w) {
            out.append(w)
            if out.count >= limit { break }
        }
        topCache = (limit, out)
        return out
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
        let uniTotal = max(self.uniTotal, 1)
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
        // score() tính MỘT lần mỗi từ (comparator gọi score bên trong sorted{}
        // là 2·n·log n lượt) rồi sort tuple.
        return cands.map { ($0, score($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(limit).map { $0.0 }
    }

    /// Điểm cá nhân của một từ (re-rank completion của lexicon).
    /// Key trong uni đã lowercase sẵn — chỉ alloc lowercased khi lookup thô miss.
    func count(of word: String) -> Int { uni[word] ?? uni[word.lowercased()] ?? 0 }

    /// Seed ban đầu — chỉ khi datastore trống (lần đầu / sau reset).
    /// @autoclosure: literal seed (~1400 entries) KHÔNG được build khi store
    /// đã có dữ liệu; đang chờ load thì giữ closure lại, quyết sau swap-in.
    func seedIfEmpty(unigrams: @autoclosure @escaping () -> [String: Int],
                     bigrams: @autoclosure @escaping () -> [(String, String, Int)]) {
        guard isLoaded else {
            pendingSeed = (unigrams, bigrams)
            return
        }
        guard uni.isEmpty else { return }
        applySeed(unigrams: unigrams(), bigrams: bigrams())
    }

    private func applySeed(unigrams: [String: Int], bigrams: [(String, String, Int)]) {
        uni = unigrams
        uniTotal = unigrams.values.reduce(0, +)
        for (a, b, c) in bigrams {
            if bi[a]?[b] == nil { biPairs += 1 }
            bi[a, default: [:]][b] = c
        }
        topCache = nil
        save()
    }

    // MARK: persistence (binary plist — cold-start nhanh hơn JSON)

    // Layout trên đĩa TRÙNG với PropertyListEncoder(Snapshot) v2 cũ
    // {version, uni, bi, tri, lastDecay} — đọc/ghi qua PropertyListSerialization
    // (nhanh hơn Codable nhiều lần), user cũ đọc thẳng không cần migrate.
    private struct LoadedTables {
        var uni: [String: Int]
        var bi: [String: [String: Int]]
        var tri: [String: [String: Int]]
        var lastDecay: Date
        var biPairs: Int
        var triPairs: Int
        var uniTotal: Int
    }
    private struct LegacySnapshot: Codable { var uni: [String: Int]; var bi: [String: Int] }

    private static func readTables(from url: URL) -> LoadedTables? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var uni: [String: Int] = [:]
        var bi: [String: [String: Int]] = [:]
        var tri: [String: [String: Int]] = [:]
        var lastDecay = Date()
        if let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
           let u = dict["uni"] as? [String: Int] {
            uni = u
            bi = dict["bi"] as? [String: [String: Int]] ?? [:]
            tri = dict["tri"] as? [String: [String: Int]] ?? [:]
            lastDecay = dict["lastDecay"] as? Date ?? Date()
        } else if let old = try? JSONDecoder().decode(LegacySnapshot.self, from: data) {
            // v1 (userlm.json cùng nội dung): migrate bigram phẳng → nested
            uni = old.uni
            for (k, c) in old.bi {
                let parts = k.split(separator: Character(sep), maxSplits: 1)
                guard parts.count == 2 else { continue }
                bi[String(parts[0]), default: [:]][String(parts[1])] = c
            }
        } else {
            return nil
        }
        return LoadedTables(
            uni: uni, bi: bi, tri: tri, lastDecay: lastDecay,
            biPairs: bi.values.reduce(0) { $0 + $1.count },
            triPairs: tri.values.reduce(0) { $0 + $1.count },
            uniTotal: uni.values.reduce(0, +)
        )
    }

    /// Snapshot COW trên main (rẻ), encode + ghi atomic trên ioQueue.
    func save() {
        saveWork?.cancel(); saveWork = nil
        guard isLoaded, let url = fileURL else { return }
        let snap = snapshotPlist()
        ioQueue.async { Self.write(snap, to: url) }
    }

    /// Flush đồng bộ cho viewWillDisappear — extension có thể bị kill ngay sau.
    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        guard isLoaded, let url = fileURL else { return }
        let snap = snapshotPlist()
        ioQueue.sync { Self.write(snap, to: url) }
    }

    private func snapshotPlist() -> [String: Any] {
        ["version": 3, "uni": uni, "bi": bi, "tri": tri, "lastDecay": lastDecay]
    }

    private static func write(_ plist: [String: Any], to url: URL) {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)
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
        loadGeneration += 1              // load đang bay (nếu có) bị bỏ kết quả
        isLoaded = true
        saveWork?.cancel(); saveWork = nil
        uni = [:]; bi = [:]; tri = [:]; biPairs = 0; triPairs = 0; uniTotal = 0
        pendingRecords = []; pendingSeed = nil
        topCache = nil
        if let url = fileURL {
            ioQueue.async { try? FileManager.default.removeItem(at: url) }
        }
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
        uniTotal = uni.values.reduce(0, +)
        lastDecay = now
        topCache = nil
        save()
    }

    /// Quá trần cứng: chia đôi mọi count (từ hiếm rơi về 0 và bị loại).
    private func pruneIfNeeded() {
        if uni.count > Self.uniCap {
            uni = uni.compactMapValues { $0 / 2 == 0 ? nil : $0 / 2 }
            uniTotal = uni.values.reduce(0, +)
            topCache = nil
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
