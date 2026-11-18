// Nhóm thu gọn "Gõ lẫn tiếng Anh" (Shared/MixedTypingUI.swift, docs/ONBOARDING-SPEC.md §4,
// docs/SETTINGS-CLEANUP-SPEC.md §1): key lưu không đổi (sao lưu giữ nguyên), chỗ đặt cấp 1 / Nâng
// cao, tìm kiếm Việt/Anh ra đúng mục, mục phụ thuộc "Quyết định theo ngữ cảnh" ẩn khi nó tắt.
import XCTest

final class MixedTypingUITests: XCTestCase {
    override func tearDown() {
        L10n.apply("vi")
        super.tearDown()
    }

    private func hits(_ q: String) -> Set<MixedTypingItem> {
        let w = SettingsSearch.words(q)
        return Set(MixedTypingItem.allCases.filter {
            SettingsSearch.matches(viTitle: $0.viTitle, keywords: $0.keywords, words: w)
        })
    }

    func testStorageKeysUnchangedAndBackedUp() {
        let expected: [MixedTypingItem: String] = [
            .autoRestore: "autoRestore", .contextualEnglish: "contextualEnglish",
            .retroEnglish: "retroactiveEnglish", .englishByFrequency: "englishByFrequency",
            .spaceSwipeLanguage: "spaceSwipeLanguage",
        ]
        for item in MixedTypingItem.allCases {
            XCTAssertEqual(item.storageKey, expected[item], "\(item)")
            if let k = item.storageKey {
                XCTAssertNotNil(BackupSettings.byKey[k], "key \(k) phải còn trong sao lưu")
            }
        }
    }

    /// SETTINGS-CLEANUP-SPEC §1: cấp 1 = tiêu đề, vuốt phím cách, Từ điển cá nhân; "Nâng cao" = bốn
    /// công tắc nhận diện tiếng Anh, hai mục thử nghiệm ngay dưới "Quyết định theo ngữ cảnh".
    func testPlacementFollowsSpec() {
        XCTAssertEqual(MixedTypingItem.allCases.filter { $0.placement == .top }, [.section, .spaceSwipeLanguage, .userDictionary])
        XCTAssertEqual(MixedTypingUI.advancedItems, [.autoRestore, .contextualEnglish, .retroEnglish, .englishByFrequency])
        XCTAssertEqual(MixedTypingUI.advancedSubtitleKey, "Khôi phục từ tiếng Anh, ngữ cảnh, khi trùng từ, sửa từ phía trước…")
        XCTAssertEqual(MixedTypingUI.titleKey, "Gõ lẫn tiếng Anh")
        XCTAssertEqual(MixedTypingItem.spaceSwipeLanguage.viTitle, "Vuốt phím cách đổi Tiếng Việt / Tiếng Anh")
    }

    func testSearchFindsItemsInBothLanguages() {
        for lang in ["vi", "en"] {
            L10n.apply(lang)
            XCTAssertTrue(hits("go lan tieng anh").contains(.section), lang)
            XCTAssertTrue(hits("go mixed").contains(.section), lang)
            XCTAssertTrue(hits("mixed vietnamese").contains(.section), lang)
            XCTAssertTrue(hits("tan suat").contains(.englishByFrequency), lang)
            XCTAssertTrue(hits("frequency").contains(.englishByFrequency), lang)
            XCTAssertTrue(hits("vuot phim cach").contains(.spaceSwipeLanguage), lang)
            XCTAssertTrue(hits("space").contains(.spaceSwipeLanguage), lang)
            XCTAssertTrue(hits("ngu canh").contains(.contextualEnglish), lang)
            XCTAssertTrue(hits("context").contains(.contextualEnglish), lang)
            XCTAssertTrue(hits("khoi phuc tieng anh").contains(.autoRestore), lang)
            XCTAssertTrue(hits("fix earlier").contains(.retroEnglish), lang)
            XCTAssertTrue(hits("nang cao").contains(.retroEnglish), lang)
        }
        XCTAssertTrue(hits("").isEmpty)
    }

    func testTitlesTranslated() {
        L10n.apply("en")
        XCTAssertEqual(L(MixedTypingUI.titleKey), "Mixed Vietnamese/English typing")
        XCTAssertEqual(L(MixedTypingUI.advancedTitleKey), "Advanced")
        XCTAssertNotEqual(L(MixedTypingUI.advancedSubtitleKey), MixedTypingUI.advancedSubtitleKey)
        for item in MixedTypingItem.allCases {
            XCTAssertNotNil(L10n.en[item.viTitle], item.viTitle)
        }
    }

    /// §0.4/§6 (06/11/2026): hai mục thử nghiệm ngay dưới "Quyết định theo ngữ cảnh" ⇒ ẨN khi nó
    /// tắt; VNI ⇒ trang chỉ còn dòng ghi chú. Cùng điều kiện với RetroEnglishUI.switchVisible.
    func testContextChildrenHiddenWhenContextOff() {
        XCTAssertEqual(MixedTypingUI.advancedRows(contextualEnglish: true, vniMode: false),
                       [.autoRestore, .contextualEnglish, .retroEnglish, .englishByFrequency])
        XCTAssertEqual(MixedTypingUI.advancedRows(contextualEnglish: false, vniMode: false),
                       [.autoRestore, .contextualEnglish])
        XCTAssertEqual(MixedTypingUI.advancedRows(contextualEnglish: true, vniMode: true), [])
        for item in [MixedTypingItem.retroEnglish, .englishByFrequency] {
            for c in [false, true] { for v in [false, true] {
                XCTAssertEqual(MixedTypingUI.advancedRows(contextualEnglish: c, vniMode: v).contains(item),
                               RetroEnglishUI.switchVisible(contextualEnglish: c, vniMode: v))
            } }
        }
    }
}

/// SETTINGS-CLEANUP-SPEC §0.4 + bảng §6 (06/11/2026): mục con cùng nhóm ngay dưới cha ⇒ ẩn; cha ở
/// trang/nhóm khác ⇒ mờ + lý do. Chỉ hiển thị — không đổi key/giá trị.
final class SettingsDepsTests: XCTestCase {

    func testVniHidesTelexOnlyTypingOptions() {
        XCTAssertEqual(SettingsDeps.typingAdvancedRows(vniMode: false),
                       [.simpleTelex, .freeMarking, .quickTelex, .modernTone, .teencode, .autoCircumflex])
        XCTAssertEqual(SettingsDeps.typingAdvancedRows(vniMode: true), [.modernTone, .teencode, .autoCircumflex])
    }

    /// Teencode chạy cả ở VNI (trước đây làm mờ nhầm "Chỉ áp dụng cho Telex").
    func testTeencodeAlwaysShown() {
        for v in [false, true] {
            XCTAssertTrue(SettingsDeps.typingAdvancedRows(vniMode: v).contains(.teencode))
        }
    }

    func testSwipeOffHidesEverySwipeChild() {
        XCTAssertEqual(SettingsDeps.swipeRows(swipeTyping: true),
                       [.swipeEnglish, .neuralModel, .trailEffect, .trailSound, .practice])
        XCTAssertEqual(SettingsDeps.swipeRows(swipeTyping: false), [])
    }

    /// Tự sửa từ gõ sai / Chọn phím thông minh: bàn phím tắt ngầm ở VNI, trang khác ⇒ mờ + lý do.
    func testTelexOnlyReasonOnOtherPage() {
        XCTAssertNil(SettingsDeps.telexOnlyReason(vniMode: false))
        XCTAssertEqual(SettingsDeps.telexOnlyReason(vniMode: true), "Chỉ áp dụng cho Telex")
    }

    func testAutoFixAdjacentNeedsSuggestionBar() {
        XCTAssertNil(SettingsDeps.autoFixAdjacentReason(showSuggestions: true))
        XCTAssertEqual(SettingsDeps.autoFixAdjacentReason(showSuggestions: false), "Cần bật Thanh gợi ý")
    }

    func testReasonsTranslatedAndShort() {
        for k in [TelexOnly.reasonKey, SettingsDeps.needsSuggestionsKey] {
            let en = L10n.en[k]
            XCTAssertNotNil(en, k)
            XCTAssertLessThanOrEqual(k.count, 95, k)
            XCTAssertLessThanOrEqual(en?.count ?? 0, 95, k)
        }
        XCTAssertEqual(L10n.en[SettingsDeps.needsSuggestionsKey], "Needs Suggestion bar")
    }
}
