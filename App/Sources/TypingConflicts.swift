import AppKit

/// Công cụ gõ tiếng Việt khác đang chạy nền (loại chặn phím bằng event tap). Hai công cụ cùng
/// sửa một lần gõ ⇒ dấu chồng, chữ nhảy, mất chữ — người dùng mới thường tưởng là lỗi của mình.
/// Windows đã có cùng kiểm tra (windows/app/src/conflicts.cpp). Chỉ đọc danh sách app đang chạy
/// khi Cài đặt mở / được chọn lại: không timer, không nằm trên đường xử lý phím.
enum TypingConflicts {
    /// Bundle id (chữ thường) của các công cụ đó — đối chiếu với metadata công khai của từng dự án.
    static let knownBundleIDs: Set<String> = [
        "com.tuyenmai.openkey",
        "com.lamquangminh.evkey",
        "com.trankynam.gotiengviet",
        "com.codetay.xkey",
        "org.gonhanh.gonhanh",
        "com.phamhungtien.phtv",
    ]

    static func isConflict(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return knownBundleIDs.contains(id)
    }

    /// Pure: tên hiển thị của các công cụ đang chạy, theo thứ tự gặp, không lặp. Tên lấy từ chính
    /// app đang chạy (không gắn cứng trong mã); thiếu tên thì dùng bundle id.
    static func names(running: [(bundleID: String?, name: String?)]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for app in running where isConflict(app.bundleID) {
            let id = app.bundleID!.lowercased()
            guard seen.insert(id).inserted else { continue }
            let name = app.name?.trimmingCharacters(in: .whitespaces) ?? ""
            out.append(name.isEmpty ? app.bundleID! : name)
        }
        return out
    }

    private static var runningConflicts: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { isConflict($0.bundleIdentifier) }
    }

    /// Main thread (NSWorkspace).
    static func current() -> [String] {
        names(running: runningConflicts.map { ($0.bundleIdentifier, $0.localizedName) })
    }

    /// Người dùng bấm "Thoát" trên banner: yêu cầu thoát lịch sự (không force).
    static func quitAll() {
        for app in runningConflicts { app.terminate() }
    }
}
