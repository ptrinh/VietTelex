import Foundation

/// Ẩn theo mục cha (SETTINGS-CLEANUP-SPEC §0.4, bảng §6 — 06/11/2026). Mục con nằm NGAY DƯỚI mục cha
/// (cùng nhóm) ⇒ ẨN khi cha tắt / chọn giá trị làm nó vô tác dụng; bật lại cha là hiện ngay tại chỗ.
/// Chỉ hiển thị: không đổi key, không đổi giá trị đã lưu, engine không đổi. Song sinh iOS
/// `SettingsDeps` (iOS/Shared/MixedTypingUI.swift).
enum SettingsDeps {

    // MARK: Kiểu gõ › Nâng cao (ngay dưới bộ chọn Telex/VNI)

    enum StyleRow: CaseIterable, Equatable {
        case simpleTelex, freeMarking, quickTelex, modern, teencode, autoCircumflex, bracket, reEdit, layout
    }

    /// VNI ⇒ ẩn Telex đơn giản, Bỏ dấu tự do, Gõ nhanh (chỉ chạy trong parseStep của Telex).
    /// Teencode (bộ kiểm âm tiết không chặn VNI) và Phím ngoặc (kiểm trước nhánh VNI) chạy cả ở
    /// VNI ⇒ luôn hiện (trước đây làm mờ nhầm "Chỉ áp dụng cho Telex"). Tự thêm dấu mũ là bước
    /// hiển thị (render), không phụ thuộc kiểu gõ ⇒ cũng luôn hiện.
    static let telexOnlyStyleRows: Set<StyleRow> = [.simpleTelex, .freeMarking, .quickTelex]

    static func styleRows(vniMode: Bool) -> [StyleRow] {
        vniMode ? StyleRow.allCases.filter { !telexOnlyStyleRows.contains($0) } : StyleRow.allCases
    }

    // MARK: Gõ lẫn tiếng Anh › Nâng cao (VNI ⇒ cả nhóm ẩn: OnboardingLogic.mixedRows)

    enum MixedAdvancedRow: CaseIterable, Equatable {
        case autoRestore, collision, context, retro, frequency
    }

    /// Tắt Tự khôi phục ⇒ ẩn "Khi từ vừa Anh vừa Việt" và "Đoán từ trùng theo tần suất" (cả hai chỉ
    /// quyết định khôi phục hay không). Tắt Quyết định theo ngữ cảnh ⇒ ẩn "Tự sửa từ phía trước" và
    /// "Đoán từ trùng theo tần suất" (engine retroactiveEnglishActive cần ngữ cảnh).
    static func mixedAdvancedRows(autoRestore: Bool, contextualEnglish: Bool) -> [MixedAdvancedRow] {
        MixedAdvancedRow.allCases.filter {
            switch $0 {
            case .autoRestore, .context: return true
            case .collision: return autoRestore
            case .retro: return contextualEnglish
            case .frequency: return autoRestore && contextualEnglish
            }
        }
    }
}
