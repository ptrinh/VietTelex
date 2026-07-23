// VNLexicon.swift — GENERATED: ~300 từ phổ biến (curated, xếp theo tần suất)
// + vocab bài học learn-site + kid-words. Thứ tự trong mảng = độ ưu tiên gợi ý.
import Foundation

enum VNLexicon {
    /// Bỏ dấu + thường hoá để so prefix ("người" → "nguoi").
    static func fold(_ s: String) -> String {
        let lower = s.lowercased()
            .replacingOccurrences(of: "đ", with: "d")
        return lower.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi"))
    }

    /// Gợi ý theo prefix đã fold: ưu tiên (1) từ trùng độ dài fold — tức chỉ
    /// khác dấu ("nguoi" → "người"), (2) thứ tự tần suất trong bảng.
    static func completions(forFolded prefix: String, limit: Int, excluding: String) -> [String] {
        guard prefix.count >= 2 else { return [] }
        var exact: [String] = []
        var longer: [String] = []
        for w in words {
            if exact.count + longer.count >= limit * 3 { break }
            let f = folded[w] ?? w
            guard f.hasPrefix(prefix), w != excluding else { continue }
            if f.count == prefix.count { exact.append(w) } else { longer.append(w) }
        }
        return Array((exact + longer).prefix(limit))
    }

    private static let folded: [String: String] = {
        var m: [String: String] = [:]
        m.reserveCapacity(words.count)
        for w in words { m[w] = fold(w) }
        return m
    }()

    static let words: [String] = [
        "là", "và", "của", "có", "không", "được", "người", "trong", "một", "cho", "với", "các",
        "để", "anh", "em", "tôi", "bạn", "khi", "này", "đó", "rồi", "sẽ", "đã", "đang",
        "cũng", "thì", "mà", "nếu", "vì", "nên", "như", "thế", "nào", "gì", "ai", "đâu",
        "bao", "giờ", "hôm", "nay", "mai", "qua", "về", "đến", "từ", "trên", "dưới", "ngoài",
        "giữa", "sau", "trước", "ra", "vào", "lên", "xuống", "đi", "làm", "ăn", "uống", "ngủ",
        "học", "chơi", "nói", "biết", "thấy", "nghe", "nhìn", "hiểu", "nghĩ", "muốn", "cần", "phải",
        "nhớ", "quên", "yêu", "thương", "thích", "ghét", "vui", "buồn", "giận", "sợ", "mệt", "khỏe",
        "đẹp", "xấu", "tốt", "hay", "dở", "nhanh", "chậm", "lớn", "nhỏ", "cao", "thấp", "dài",
        "ngắn", "mới", "cũ", "nhiều", "ít", "rất", "quá", "lắm", "hơn", "nhất", "bằng", "cùng",
        "những", "mọi", "mỗi", "vài", "cả", "chỉ", "còn", "nữa", "lại", "vẫn", "đều", "thật",
        "đúng", "sai", "chưa", "xong", "hết", "luôn", "ngay", "liền", "vừa", "sáng", "trưa", "chiều",
        "tối", "đêm", "ngày", "tháng", "năm", "tuần", "phút", "giây", "thứ", "chủ", "nhật", "hai",
        "ba", "bốn", "sáu", "bảy", "tám", "chín", "mười", "trăm", "nghìn", "triệu", "tỷ", "đồng",
        "tiền", "nhà", "cửa", "xe", "đường", "phố", "chợ", "trường", "lớp", "sách", "vở", "bút",
        "thầy", "cô", "bố", "mẹ", "ông", "bà", "con", "cháu", "chị", "chồng", "vợ", "gia",
        "đình", "nước", "việt", "nam", "hà", "nội", "sài", "gòn", "thành", "quê", "hương", "đất",
        "trời", "mưa", "nắng", "gió", "mây", "sông", "núi", "biển", "đảo", "cây", "hoa", "lá",
        "quả", "chim", "cá", "chó", "mèo", "gà", "vịt", "heo", "bò", "trâu", "cơm", "phở",
        "bún", "bánh", "chè", "trà", "cà", "phê", "sữa", "bia", "rượu", "thịt", "rau", "củ",
        "trứng", "muối", "ớt", "tỏi", "hành", "gừng", "chanh", "cam", "chuối", "táo", "xoài", "dừa",
        "mít", "ổi", "nho", "điện", "thoại", "máy", "tính", "mạng", "phần", "mềm", "chương", "trình",
        "công", "việc", "ty", "văn", "phòng", "họp", "báo", "cáo", "khách", "hàng", "sản", "phẩm",
        "dịch", "vụ", "chất", "lượng", "giá", "bán", "mua", "thuê", "trả", "góp", "chuyện", "tình",
        "cảm", "hạnh", "phúc", "khó", "khăn", "thất", "bại", "cố", "gắng", "chúc", "mừng", "ơn",
        "xin", "lỗi", "tạm", "biệt", "chào", "hỏi", "thăm", "mạnh", "bình", "an", "may", "mắn",
        "cún", "dê", "cừu", "ngựa", "voi", "hổ", "gấu", "khỉ", "tôm", "cua", "mực", "ốc",
        "sò", "ếch", "rắn", "rùa", "quạ", "ong", "kiến", "ruồi", "muỗi", "bướm", "nhện", "sâu",
        "giun", "dế", "bọ", "sói", "thỏ", "chuột", "nai", "cú", "vẹt", "ngỗng", "dơi", "nhím",
        "sóc", "rồng", "tổ", "lông", "cánh", "lê", "đào", "dứa", "dâu", "bơ", "dưa", "bí",
        "ngô", "khoai", "nấm", "cải", "đậu", "lạc", "lúa", "xôi", "mì", "canh", "cháo", "kẹo",
        "kem", "mật", "bé", "vua", "lính", "ma", "tiên", "râu", "mắt", "mũi", "tai", "miệng",
        "răng", "lưỡi", "tay", "chân", "tim", "não", "xương", "máu", "móng", "đỏ", "vàng", "xanh",
        "tím", "hồng", "nâu", "đen", "trắng", "sao", "trăng", "sấm", "chớp", "tuyết", "băng", "bão",
        "lốc", "rừng", "cỏ", "tre", "lửa", "đá", "gỗ", "mầm", "ngọc", "tàu", "thuyền", "phà",
        "ga", "vé", "giường", "ghế", "đèn", "nến", "khóa", "tủ", "gương", "thang", "chổi", "xô",
        "giỏ", "kéo", "dao", "thìa", "đũa", "bát", "đĩa", "cốc", "ấm", "nồi", "chảo", "sổ",
        "truyện", "thơ", "thước", "cặp", "giấy", "ghim", "kẹp", "kính", "ô", "túi", "ví", "quà",
        "thư", "hộp", "quạt", "lược", "búa", "kim", "cưa", "pin", "chuông", "trống", "đàn", "sáo",
        "kèn", "cờ", "dây", "len", "loa", "đài", "cân", "thuốc", "gạch", "lịch", "chữ", "tên",
        "áo", "quần", "váy", "mũ", "nón", "giày", "dép", "ủng", "tất", "găng", "nơ", "nhẫn",
        "vòng", "bóng", "diều", "bài", "nhạc", "phim", "ảnh", "tranh", "xiếc", "bơi", "chạy", "leo",
        "võ", "cúp", "thi", "đua", "thắng", "khóc", "cười", "đọc", "viết", "vẽ", "hát", "nhảy",
        "múa", "bay", "tắm", "rửa", "gõ", "ôm", "hôn", "đứng", "nằm", "đếm", "mở", "tìm",
        "chụp", "gọi", "nhắn", "lau", "đợi", "dừng", "ho", "ngáp", "thở", "hét", "im", "cúi",
        "trồng", "trốn", "đùa", "mơ", "sơn", "rót", "chán", "ốm", "đau", "nóng", "lạnh", "ngon",
        "ngoan", "giỏi", "ướt", "tròn", "vuông", "cầu", "lều", "tháp", "vườn", "tết", "tiệc", "ff",
        "jj", "fj", "jf", "dd", "kk", "dk", "ss", "ll", "aa", "fad", "jak", "lads",
        "salad", "ee", "ii", "oo", "uu", "tt", "tie", "toe", "rot", "pie", "quit", "your",
        "vv", "nn", "mm", "cc", "bb", "van", "bam", "mixv", "ta", "me", "be", "bo",
        "ca", "ban", "minh", "thanh", "com", "đa", "đo", "đem", "ân", "lâu", "thân", "nhân",
        "ê", "bênh", "thôn", "tư", "ưa", "đương", "má", "làng", "hả", "mã", "ngã", "lão",
        "mạ", "họ", "mả", "hóa", "sinh", "cha", "thái", "nghĩa", "nguồn", "chảy", "dấu", "chúng",
        "nhé", "tiếng", "âu", "cơ", "lang", "liêu", "chưng", "tượng", "trưng", "hài", "lòng", "gươm",
        "hồ", "ấy", "gióng", "vươn", "vai", "tráng", "sĩ", "sắt", "phun", "xông", "trận", "đánh",
        "tan", "giặc", "cưỡi", "theo", "nữ", "hùng", "đầu", "gói", "trẻ", "mặc", "nhận", "lì",
        "xì", "nhau", "lành",
    ]
}
