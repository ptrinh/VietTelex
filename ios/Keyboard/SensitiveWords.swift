// SensitiveWords — bộ lọc từ tục/nhạy cảm khỏi THANH GỢI Ý (chuẩn ngành:
// Gboard/SwiftKey đều chặn mặc định). Từ vẫn nằm trong datastore và vẫn được
// HỌC bình thường — chỉ không chủ động gợi ý khi bộ lọc bật. Từ bạo lực phổ
// thông (cướp, giết, trộm — từ vựng báo chí/đời thường) KHÔNG nằm trong lọc.
import Foundation

enum SensitiveWords {
    static func filter(_ words: [String], enabled: Bool) -> [String] {
        enabled ? words.filter { !set.contains($0.lowercased()) } : words
    }

    static let set: Set<String> = [
        "đcm", "đm", "dm", "dcm", "vcl", "vkl", "vl", "cl", "clgt", "cmnr",
        "cứt", "lồn", "cặc", "buồi", "đĩ", "điếm", "đụ", "địt",
        "tml", "sml", "dâm",
        "fuck", "shit", "bitch", "wtf",
    ]
}
