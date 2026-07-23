// DisplayCase — case chuẩn cho proper noun khi HIỂN THỊ gợi ý. Datastore
// case-fold toàn bộ để đếm ("senprints"), nhưng nút gợi ý và chữ được chèn
// phải ra "SenPrints". CHỈ chứa token không-nhập-nhằng: brand/sản phẩm/OS,
// địa danh nước ngoài, họ Việt an toàn. Token nhập nhằng (văn ↔ văn bản,
// pháp ↔ phương pháp, trần ↔ trần nhà) KHÔNG đưa vào — thà hiện thường còn
// hơn viết hoa sai giữa câu.
import Foundation

enum DisplayCase {
    /// Trả về dạng hiển thị chuẩn; từ không có trong bảng giữ nguyên.
    /// `after`: từ đứng ngay trước — token nhập nhằng được viết hoa THEO NGỮ
    /// CẢNH chuỗi tên riêng ("hà"→"nội" hiện "Nội", nhưng "nội" đơn lẻ giữ
    /// thường vì còn là "nội bộ").
    static func apply(_ w: String, after prev: String? = nil) -> String {
        if let p = prev?.lowercased(), chains[p]?.contains(w) == true {
            return w.prefix(1).uppercased() + w.dropFirst()
        }
        return proper[w] ?? w
    }

    /// Chuỗi tên riêng: prev → các next chỉ-proper-khi-đứng-sau-prev.
    static let chains: [String: Set<String>] = [
        // địa danh VN
        "hà": ["nội", "nam", "tĩnh", "giang"],
        "đà": ["nẵng", "lạt"],
        "nha": ["trang"],
        "phú": ["quốc", "thọ", "yên"],
        "sài": ["gòn"],
        "hồ": ["chí"], "chí": ["minh"],
        "việt": ["nam"],
        "cần": ["thơ"],
        "hải": ["phòng", "dương"],
        "hạ": ["long"],
        "quy": ["nhơn"],
        "vũng": ["tàu"],
        "biên": ["hòa"],
        "bình": ["dương", "định", "thuận"],
        "thanh": ["hóa"],
        "hội": ["an"],
        "quảng": ["ninh", "nam", "ngãi", "bình", "trị"],
        "nghệ": ["an"],
        "lâm": ["đồng"],
        "đồng": ["nai", "tháp"],
        "long": ["an"],
        "tây": ["ninh"],
        "new": ["york"], "san": ["francisco"], "hong": ["kong"],
        // họ → đệm (chuỗi tên người)
        "nguyễn": ["văn", "thị", "đức", "minh", "ngọc", "hữu", "xuân", "thùy", "kim", "hồng", "quốc", "đình"],
        "trần": ["văn", "thị", "đức", "minh", "ngọc", "quốc"],
        "lê": ["văn", "thị", "đức", "minh", "ngọc", "hữu"],
        "phạm": ["văn", "thị", "minh", "ngọc"],
        "hoàng": ["văn", "thị", "minh", "anh"],
        "vũ": ["văn", "thị", "minh"],
        "đặng": ["văn", "thị"],
        "bùi": ["văn", "thị"],
        "đỗ": ["văn", "thị"],
        "ngô": ["văn", "thị"],
        "dương": ["văn", "thị"],
        "trịnh": ["văn", "thị", "xuân"],
        // đệm → tên
        "văn": ["hùng", "tuấn", "dũng", "sơn", "nam", "long", "hải", "minh"],
        "thị": ["hương", "lan", "thu", "ngọc", "hồng", "phương", "hà", "linh"],
    ]

    static let proper: [String: String] = [
        // thương hiệu / sản phẩm
        "senprints": "SenPrints", "printik": "Printik",
        "apple": "Apple", "iphone": "iPhone", "ipad": "iPad", "macbook": "MacBook",
        "samsung": "Samsung", "google": "Google", "facebook": "Facebook",
        "youtube": "YouTube", "tiktok": "TikTok", "zalo": "Zalo",
        "shopee": "Shopee", "lazada": "Lazada", "grab": "Grab",
        "momo": "MoMo", "vnpay": "VNPay", "vietcombank": "Vietcombank",
        "techcombank": "Techcombank", "viettel": "Viettel", "vingroup": "Vingroup",
        "vinfast": "VinFast", "vietjet": "Vietjet", "fpt": "FPT",
        "arsenal": "Arsenal", "liverpool": "Liverpool", "chelsea": "Chelsea",
        "manchester": "Manchester", "bitcoin": "Bitcoin", "ethereum": "Ethereum",
        "binance": "Binance", "netflix": "Netflix", "spotify": "Spotify",
        "github": "GitHub", "claude": "Claude", "chatgpt": "ChatGPT",
        "tesla": "Tesla", "openai": "OpenAI", "anthropic": "Anthropic",
        "yahoo": "Yahoo", "hotmail": "Hotmail",
        // OS / phần mềm
        "windows": "Windows", "macos": "macOS", "ios": "iOS",
        "android": "Android", "linux": "Linux", "chrome": "Chrome",
        "safari": "Safari", "excel": "Excel", "word": "Word",
        "wifi": "WiFi", "gmail": "Gmail", "outlook": "Outlook",
        // địa danh nước ngoài (token đơn, không nhập nhằng)
        "singapore": "Singapore", "dubai": "Dubai", "london": "London",
        "tokyo": "Tokyo", "sydney": "Sydney", "canada": "Canada",
        "houston": "Houston", "seattle": "Seattle", "miami": "Miami",
        "dallas": "Dallas", "austin": "Austin", "texas": "Texas",
        "california": "California", "washington": "Washington",
        "york": "York", "francisco": "Francisco", "paris": "Paris",
        "bangkok": "Bangkok", "seoul": "Seoul",
        // họ Việt an toàn (gần như luôn là tên riêng khi đứng một mình).
        // CÁC TOKEN NHẬP NHẰNG bị loại có chủ ý: vũ (vũ khí), đỗ (đỗ xe),
        // ngô (bắp ngô), dương (đại dương), trang (trang web), nội (nội bộ),
        // quốc (tổ quốc) — hiện thường an toàn hơn hoa sai.
        "nguyễn": "Nguyễn", "trịnh": "Trịnh", "đặng": "Đặng", "bùi": "Bùi",
    ]
}
