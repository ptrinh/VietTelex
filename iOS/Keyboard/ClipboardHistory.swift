// Lịch sử clipboard — model THUẦN (không UIKit, không đọc UIPasteboard).
// Lưu CHỈ trên máy: file JSON trong container riêng của extension (không App
// Group, không mạng). Hợp đồng chung với Android keyboard/ClipboardHistory.kt:
// tối đa 100 mục và 200.000 ký tự tổng (vượt ⇒ bỏ mục không ghim cũ nhất), mục không ghim hết hạn sau 1 giờ / 24 giờ / 7 ngày (ClipboardTTL, mặc
// định 1 giờ), mục "giống bí mật" LUÔN sau 2 phút, ghim không hết hạn, trùng text → đưa
// lên đầu (giữ ghim).
import Foundation

/// "Giữ lịch sử clipboard": 1 giờ (mặc định) / 24 giờ / 7 ngày. App ghi chuỗi id vào App
/// Group key `clipboardTTL` (cùng key + id với Android `ClipboardTTL`); bàn phím đọc khi hiện.
/// Chỉ áp cho mục không ghim, không "giống bí mật" (mục bí mật giữ 2 phút).
enum ClipboardTTL: String, CaseIterable {
    case hour1 = "1h", hours24 = "24h", days7 = "7d"

    static let key = "clipboardTTL"
    static let `default`: ClipboardTTL = .hour1
    static var ids: [String] { allCases.map(\.rawValue) }

    /// Giá trị lạ / thiếu → 1 giờ.
    static func parse(_ raw: String?) -> ClipboardTTL { raw.flatMap(ClipboardTTL.init(rawValue:)) ?? .default }

    var seconds: TimeInterval {
        switch self {
        case .hour1: return 3600
        case .hours24: return 24 * 3600
        case .days7: return 7 * 24 * 3600
        }
    }
}

struct ClipItem: Codable, Equatable {
    var text: String
    var at: TimeInterval          // giây (timeIntervalSince1970)
    var pinned: Bool
    var sensitive: Bool
}

final class ClipboardHistory {
    let maxItems: Int
    /// Hạn mục thường — đổi được lúc chạy (ClipboardFeature.load đọc `clipboardTTL`);
    /// áp ở lần prune kế tiếp.
    var ttl: TimeInterval
    let sensitiveTTL: TimeInterval
    /// Mục dài hơn bị bỏ qua. 4000 cũ làm văn bản nhiều đoạn copy xong "không được lưu"
    /// (tester Plus 15/10/2026).
    static let maxTextLength = 10_000
    /// Trần số mục (20 → 100 theo phản hồi người dùng 22/11/2026).
    static let defaultMaxItems = 100
    /// Trần TỔNG ký tự (UTF-16, cả mục ghim) — 100 mục × 10k ký tự sẽ là ~2 MB RAM + file ghi lại
    /// mỗi lần copy, quá nặng cho extension. Vượt ⇒ bỏ mục KHÔNG ghim cũ nhất; mục vừa thêm
    /// và mục ghim luôn được giữ.
    static let defaultMaxTotalChars = 200_000
    let maxTotalChars: Int
    static let freshWindow: TimeInterval = 180

    /// Mới nhất trước. Đọc + giải JSON LƯỜI ở lần dùng đầu (không nằm trong khung hình đầu của
    /// bàn phím — lần hiện chỉ tạo object; file đọc khi bar / panel / chip cần tới lịch sử).
    private(set) lazy var raw: [ClipItem] = { loadedFlag = true; return Self.read(fileURL) }()
    private let fileURL: URL?

    init(fileURL: URL?, maxItems: Int = ClipboardHistory.defaultMaxItems, ttl: TimeInterval = 3600,
         sensitiveTTL: TimeInterval = 120, maxTotalChars: Int = ClipboardHistory.defaultMaxTotalChars) {
        self.fileURL = fileURL
        self.maxItems = maxItems
        self.maxTotalChars = maxTotalChars
        self.ttl = ttl
        self.sensitiveTTL = sensitiveTTL
    }

    #if DEBUG
    /// Test: file đã được đọc chưa (lười).
    var debugLoaded: Bool { loadedFlag }
    #endif
    private var loadedFlag = false
    private static func read(_ url: URL?) -> [ClipItem] {
        guard let u = url, let data = try? Data(contentsOf: u),
              let items = try? JSONDecoder().decode([ClipItem].self, from: data) else { return [] }
        return items
    }

    /// File mặc định: Application Support của extension (container riêng).
    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("clipboard-history.json")
    }

    /// Thêm mục; trả về true nếu danh sách đổi. Rỗng / quá dài → bỏ qua.
    @discardableResult
    func add(_ text: String, now: TimeInterval, sensitive: Bool? = nil) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maxTextLength else { return false }
        let s = sensitive ?? ClipSensitivity.looksSecret(text)
        var pinned = false
        if let i = raw.firstIndex(where: { $0.text == text }) {
            pinned = raw[i].pinned
            raw.remove(at: i)
        }
        raw.insert(ClipItem(text: text, at: now, pinned: pinned, sensitive: s && !pinned), at: 0)
        while raw.count > maxItems, let i = raw.lastIndex(where: { !$0.pinned }) {
            raw.remove(at: i)
        }
        // Trần tổng ký tự: bỏ dần mục không ghim cũ nhất, trừ mục vừa thêm (vị trí 0).
        var total = totalChars
        while total > maxTotalChars, let i = raw.lastIndex(where: { !$0.pinned }), i > 0 {
            total -= raw[i].text.utf16.count
            raw.remove(at: i)
        }
        return true
    }

    /// Tổng ký tự UTF-16 đang giữ (đếm O(1) mỗi mục với chuỗi native).
    var totalChars: Int { raw.reduce(0) { $0 + $1.text.utf16.count } }

    /// Bỏ mục không ghim đã hết hạn; true nếu có mục bị bỏ.
    @discardableResult
    func prune(now: TimeInterval) -> Bool {
        let before = raw.count
        raw.removeAll { !$0.pinned && now - $0.at > ($0.sensitive ? sensitiveTTL : ttl) }
        return raw.count != before
    }

    /// Danh sách hiển thị: ghim lên trên, rồi mới nhất trước.
    func items(now: TimeInterval) -> [ClipItem] {
        prune(now: now)
        return raw.filter(\.pinned) + raw.filter { !$0.pinned }
    }

    /// Ghim/bỏ ghim. `limit` = số mục ghim tối đa (nil = không giới hạn —
    /// `PlusGate.pinnedClipLimit`); đầy thì KHÔNG ghim thêm, trả false (bỏ ghim luôn được).
    @discardableResult
    func togglePin(_ text: String, limit: Int? = nil) -> Bool {
        guard let i = raw.firstIndex(where: { $0.text == text }) else { return false }
        if !raw[i].pinned, let l = limit, pinnedCount >= l { return false }
        raw[i].pinned.toggle()
        if raw[i].pinned { raw[i].sensitive = false }   // user chủ động giữ
        return true
    }

    var pinnedCount: Int { raw.filter(\.pinned).count }

    func remove(_ text: String) { raw.removeAll { $0.text == text } }

    /// "Xoá hết": xoá mục KHÔNG ghim (ghim chỉ bỏ bằng nút riêng).
    func clearUnpinned() { raw.removeAll { !$0.pinned } }

    func removeAll() { raw.removeAll() }

    /// Mục mới nhất nếu vừa thêm trong 3 phút (nguồn cho chip STK/SĐT/OTP).
    func latestFresh(now: TimeInterval, window: TimeInterval = ClipboardHistory.freshWindow) -> ClipItem? {
        guard let first = raw.max(by: { $0.at < $1.at }), now - first.at <= window else { return nil }
        return first
    }

    func save() {
        guard let u = fileURL else { return }
        if raw.isEmpty { try? FileManager.default.removeItem(at: u); return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(raw) {
            try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Tắt tính năng → xoá sạch file (riêng tư).
    static func wipe(at url: URL?) {
        if let u = url { try? FileManager.default.removeItem(at: u) }
    }
}
