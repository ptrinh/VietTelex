// DisplayCase — case chuẩn cho proper noun khi HIỂN THỊ gợi ý. Datastore
// case-fold toàn bộ để đếm ("senprints"), nhưng nút gợi ý và chữ được chèn
// phải ra "SenPrints". CHỈ chứa token không-nhập-nhằng: brand/sản phẩm/OS,
// địa danh nước ngoài, họ Việt an toàn. Token nhập nhằng (văn ↔ văn bản,
// pháp ↔ phương pháp, trần ↔ trần nhà) KHÔNG đưa vào — thà hiện thường còn
// hơn viết hoa sai giữa câu.
import Foundation

enum DisplayCase {
    /// Trả về dạng hiển thị chuẩn; từ không có trong bảng giữ nguyên.
    static func apply(_ w: String) -> String { proper[w] ?? w }

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
