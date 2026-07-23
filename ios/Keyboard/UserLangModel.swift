// UserLangModel — datastore cá nhân hóa cho thanh gợi ý. Học từ user hay gõ
// (unigram) và cặp từ liền nhau (bigram) để gợi ý từ ĐẦU CÂU và từ KẾ TIẾP
// ("Anh " → ơi / đang / có). Không UIKit, test được bằng store in-memory.
//
// PRIVACY: chỉ đếm TẦN SUẤT từ đơn + cặp từ (không lưu câu, không thứ tự gõ,
// không timestamp); ô mật khẩu không bao giờ đi qua đây (bridge chặn từ trước);
// dữ liệu nằm trong App Group container của máy, xóa được từ app.
import Foundation

final class UserLangModel {
    private(set) var uni: [String: Int] = [:]
    private(set) var bi: [String: Int] = [:]
    private let fileURL: URL?
    private var dirty = 0

    private static let uniCap = 2000
    private static let biCap = 4000
    private static let sep = "\u{1}"

    /// Store thật trong App Group; truyền nil cho tests (in-memory).
    init(appGroup: String? = "group.com.viettelex") {
        if let g = appGroup,
           let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) {
            fileURL = dir.appendingPathComponent("userlm.json")
        } else {
            fileURL = nil
        }
        load()
    }

    // MARK: học

    /// Một từ vừa commit. `after` = từ đứng ngay trước trong cùng câu (nil nếu
    /// đầu câu / sau dấu câu).
    func record(word: String, after prev: String?) {
        guard Self.learnable(word) else { return }
        let w = word.lowercased()
        uni[w, default: 0] += 1
        if let p = prev?.lowercased(), Self.learnable(p) {
            bi[p + Self.sep + w, default: 0] += 1
        }
        pruneIfNeeded()
        dirty += 1
        if dirty >= 10 { save() }
    }

    /// Từ "học được": chữ cái thuần (kể cả có dấu), ngắn, không phải mã/số.
    static func learnable(_ w: String) -> Bool {
        !w.isEmpty && w.count <= 12 && w.allSatisfy { $0.isLetter }
    }

    // MARK: gợi ý

    /// Top từ user hay dùng nhất — cho field trống chưa gõ gì.
    func topWords(limit: Int) -> [String] {
        uni.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    /// Từ kế tiếp sau `prev`: bigram cá nhân trước, thiếu thì lấp bằng seed.
    func nextWords(after prev: String, limit: Int) -> [String] {
        let p = prev.lowercased() + Self.sep
        var out = bi.filter { $0.key.hasPrefix(p) }
            .sorted { $0.value > $1.value }
            .map { String($0.key.dropFirst(p.count)) }
        for s in Self.seedNext[prev.lowercased()] ?? [] where !out.contains(s) {
            out.append(s)
        }
        return Array(out.prefix(limit))
    }

    /// Điểm cá nhân của một từ (re-rank completion của lexicon).
    func count(of word: String) -> Int { uni[word.lowercased()] ?? 0 }

    // MARK: persistence

    private struct Snapshot: Codable { var uni: [String: Int]; var bi: [String: Int] }

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        uni = s.uni; bi = s.bi
    }

    func save() {
        dirty = 0
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(Snapshot(uni: uni, bi: bi)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Nút "Xóa từ đã học" trong app gọi qua file marker; keyboard tự dọn.
    func eraseAll() {
        uni = [:]; bi = [:]
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Quá trần: chia đôi mọi count (từ hiếm rơi về 0 và bị loại) — giữ hồ sơ
    /// tươi theo thói quen gần đây, chặn phình vô hạn.
    private func pruneIfNeeded() {
        if uni.count > Self.uniCap {
            uni = uni.compactMapValues { $0 / 2 == 0 ? nil : $0 / 2 }
        }
        if bi.count > Self.biCap {
            bi = bi.compactMapValues { $0 / 2 == 0 ? nil : $0 / 2 }
        }
    }

    // MARK: seed bigrams — mồi tiếng Việt khi chưa có dữ liệu cá nhân

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
