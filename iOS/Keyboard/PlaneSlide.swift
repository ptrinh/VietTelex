// PlaneSlide — trượt từ phím 123 (#171), như bàn phím iOS gốc.
//
// Chạm phím "123" ở plane chữ: plane số hiện NGAY lúc chạm (như trước). Ngón còn đè mà trượt
// sang một phím ký tự của plane số rồi nhấc ⇒ chèn ký tự đó (đúng đường chạm thường của phím)
// và tự về plane chữ. Nhấc ở chỗ không chèn được (khe, phím ABC chỗ 123 cũ, #+=, ⇧, ⌫, ↵,
// space, ngoài vùng phím) hoặc touch bị huỷ / ngón thứ hai chạm ⇒ không chèn gì, ở lại plane số.
//
// Phần quyết định thuần (không UIKit) — pinned by PlaneSlideTests. `Key` = phím chèn được đang
// dưới ngón (nil = không có phím chèn được).
struct PlaneSlide<Key: Equatable> {
    /// Phím chèn được đang dưới ngón (đang sẫm + balloon xem trước).
    private(set) var over: Key?

    /// Ngón trượt tới chỗ có phím chèn được `k` (nil = không). Trả (rời, vào) khi đổi phím —
    /// để bỏ sẫm phím cũ / sẫm phím mới; nil = không đổi gì (không vẽ lại).
    mutating func move(over k: Key?) -> (leave: Key?, enter: Key?)? {
        guard k != over else { return nil }
        let leave = over
        over = k
        return (leave, k)
    }

    /// Nhấc tay trên `k`: phím sẽ chèn (rồi về plane chữ), nil = không chèn, ở lại plane số.
    static func lift(over k: Key?, cancelled: Bool) -> Key? {
        cancelled ? nil : k
    }
}
