import XCTest
@testable import VietTelex

/// docs/SETTINGS-CLEANUP-SPEC.md (05/11/2026), phần macOS: thu gọn = đổi chỗ / đổi nhãn,
/// KHÔNG đổi key lưu, mặc định hay hành vi. Kiểm thử theo §5: (a) bộ chọn hồ sơ vẫn áp đúng
/// key, (c) không còn chuỗi nhắc bộ gõ khác, (d) nhãn bảng §3 khớp.
final class SettingsCleanupTests: XCTestCase {

    private func viBundle() throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "vi", ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func viTable() throws -> [String: String] {
        let table = try XCTUnwrap(viBundle().path(forResource: "Localizable", ofType: "strings"))
        return try XCTUnwrap(NSDictionary(contentsOfFile: table) as? [String: String])
    }

    // MARK: (a) bộ chọn hồ sơ

    /// macOS ẩn "Chủ yếu tiếng Anh" (≡ "Việt + Anh nhiều" trên Mac); onboarding vẫn đủ 3.
    func testSettingsPickerHidesMostlyEnglish() {
        XCTAssertEqual(OnboardingLogic.settingsProfiles, [.vi, .mixed])
        XCTAssertEqual(TypingProfile.allCases, [.vi, .mixed, .en])
        // en ghi đúng bộ công tắc của mixed ⇒ ẩn không làm mất lựa chọn nào.
        XCTAssertEqual(OnboardingLogic.dict(.en), OnboardingLogic.dict(.mixed))
    }

    func testSettingsMatchMapsEnglishToMixed() {
        let mixed = OnboardingLogic.dict(.mixed)
        let vi = OnboardingLogic.dict(.vi)
        XCTAssertEqual(OnboardingLogic.settingsMatch(mixed, lastChosen: .en), .mixed)
        XCTAssertEqual(OnboardingLogic.settingsMatch(mixed, lastChosen: nil), .mixed)
        XCTAssertEqual(OnboardingLogic.settingsMatch(vi, lastChosen: .en), .vi)
        var custom = mixed
        custom["autoRestore"] = false
        XCTAssertNil(OnboardingLogic.settingsMatch(custom, lastChosen: .en))
        // Mọi kết quả đều là một dòng thật của bộ chọn (hoặc nil = Tuỳ chỉnh).
        for p in TypingProfile.allCases {
            let m = OnboardingLogic.settingsMatch(OnboardingLogic.dict(p), lastChosen: p)
            XCTAssertTrue(m.map(OnboardingLogic.settingsProfiles.contains) ?? false, "\(p)")
        }
    }

    /// Các công tắc mixed nay nằm trong "Nâng cao": bộ chọn vẫn ghi đúng key AppState như cũ.
    func testPickerStillWritesSameKeys() {
        let s = AppState.shared
        let saved = OnboardingLogic.mixedKeys.map { ($0, s.mixedSetting($0)!) }
        let savedProfile = s.defaults.object(forKey: OnboardingLogic.profileKey)
        defer {
            for (k, v) in saved { s.setMixedSetting(k, v) }
            s.defaults.set(savedProfile, forKey: OnboardingLogic.profileKey)
        }
        OnboardingLogic.apply(.vi, defaults: s.defaults) { s.setMixedSetting($0, $1) }
        let model = SettingsModel(selected: .typing)
        model.pickProfile(.mixed)
        for (k, v) in OnboardingLogic.values(for: .mixed) {
            XCTAssertEqual(s.defaults.object(forKey: k) as? Bool, v, k)
        }
        model.pickProfile(.vi)
        for (k, v) in OnboardingLogic.values(for: .vi) {
            XCTAssertEqual(s.defaults.object(forKey: k) as? Bool, v, k)
        }
    }

    // MARK: không đổi key / mặc định

    /// "Sửa dấu từ đã gõ" có UI mới trên macOS — ghi đúng key cũ `reEditWord`, mặc định vẫn bật.
    func testReEditWordToggleUsesExistingKey() {
        let s = AppState.shared
        let saved = s.reEditWord
        defer { s.reEditWord = saved }
        // Giá trị nay cache trong bộ nhớ (đường phím): xoá key trên đĩa không còn đổi được
        // nó giữa phiên, nên đặt qua property thay vì removeObject.
        s.reEditWord = true
        XCTAssertTrue(s.reEditWord)
        let model = SettingsModel(selected: .typing)
        XCTAssertTrue(model.reEditWord)
        model.reEditWord = false
        XCTAssertEqual(s.defaults.object(forKey: "reEditWord") as? Bool, false)
        XCTAssertFalse(AppState.shared.reEditWord)
    }

    /// "Giữ VietTelex khi macOS tự đổi bộ gõ" chuyển tab nhưng vẫn ghi key `stickyInputSource`.
    func testMovedSwitchingSettingsKeepKeys() {
        let s = AppState.shared
        let sticky = s.defaults.object(forKey: "stickyInputSource")
        let hotkey = s.switchHotkey
        defer {
            s.defaults.set(sticky, forKey: "stickyInputSource")
            s.switchHotkey = hotkey
        }
        let model = SettingsModel(selected: .typing)
        model.stickyInputSource = true
        XCTAssertEqual(s.defaults.object(forKey: "stickyInputSource") as? Bool, true)
        model.switchHotkey = "opt-shift"
        XCTAssertEqual(s.defaults.string(forKey: "switchHotkey"), "opt-shift")
    }

    // MARK: (c) không nhắc tên bộ gõ khác

    /// Tên mã hoá base64 để chính repo không viết ra các tên đó. So khớp sau khi bỏ dấu + chữ hoa.
    private static let forbiddenEncoded = [
        "dW5pa2V5", "ZXZrZXk=", "b3BlbmtleQ==", "Z290aWVuZ3ZpZXQ=", "Z29uaGFuaA==", "Z28gbmhhbmg=",
        "dmlldGtleQ==", "dmlrZXk=", "bGFiYW5rZXk=", "bGFiYW4ga2V5", "eGtleQ==", "YmFtYm9v",
    ]

    static func forbiddenNames() -> [String] {
        forbiddenEncoded.compactMap { Data(base64Encoded: $0).flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
    }

    func testNoOtherInputMethodNamesInStrings() throws {
        let names = Self.forbiddenNames()
        XCTAssertEqual(names.count, Self.forbiddenEncoded.count)
        var texts: [String] = []
        for (k, v) in try viTable() { texts.append(k); texts.append(v) }
        // Khoá của nhãn dựng trong code (tiếng Anh hiện nguyên khoá).
        texts += [TypingTab.styleAdvancedSummary, TypingTab.mixedAdvancedSummary,
                  TypingTab.switchAdvancedSummary,
                  TypingTab.systemSettingsCaption] + Self.allCaptions + ModeNames.all
        for t in texts {
            let f = Self.fold(t)
            for n in names { XCTAssertFalse(f.contains(n), "chuỗi nhắc bộ gõ khác: \(t)") }
        }
    }

    func testFoldCatchesDiacriticVariants() {
        // Tự kiểm: dạng có dấu / viết hoa vẫn bị bắt (tên lấy từ danh sách mã hoá).
        let n = Self.forbiddenNames()[5]   // dạng có dấu cách
        let accented = n.replacingOccurrences(of: "o", with: "õ").uppercased()
        XCTAssertTrue(Self.fold("abc " + accented + " xyz").contains(n))
    }

    // MARK: (d) nhãn bảng §3 + tên nhóm

    func testSection3LabelsVietnamese() throws {
        let vi = try viBundle()
        let expect: [String: String] = [
            "Free tone placement": "Bỏ dấu tự do",
            "Modern tone placement (oà, uý)": "Bỏ dấu kiểu mới (oà, uý)",
            "Fix tones of typed words": "Sửa dấu từ đã gõ",
            "Money amount suggestions": "Gợi ý số tiền",
            "Auto-restore English words": "Tự khôi phục từ tiếng Anh",
            "Teencode spelling": "Chính tả teencode",
            "Auto-add circumflex": "Tự thêm dấu mũ",
            "Simple Telex": "Telex đơn giản",
            "Quick consonants (cc→ch, gg→gi…)": "Gõ tắt phụ âm nhanh (cc→ch, gg→gi…)",
            "Mixed Vietnamese/English typing": "Gõ lẫn tiếng Anh",
            "Switching Vietnamese/English": "Chuyển Việt/Anh",
            "Suggestions & tools": "Gợi ý & công cụ",
            "Advanced": "Nâng cao",
            DiagnosticsSection.headerKey: "Nâng cao / Gỡ lỗi",
            TypingTab.mixedAdvancedSummary: "Khôi phục từ tiếng Anh, ngữ cảnh, khi trùng từ, sửa từ phía trước…",
        ]
        for (k, v) in expect { XCTAssertEqual(vi.localizedString(forKey: k, value: nil, table: nil), v, k) }
        // Không còn chữ "chip" ở nhãn chính; ví dụ google/github ở chú thích tự khôi phục.
        XCTAssertFalse("Money amount suggestions".lowercased().contains("chip"))
        let restoreCaption = vi.localizedString(forKey: TypingTab.C.autoRestore, value: "∅", table: nil)
        XCTAssertTrue(restoreCaption.contains("google") && restoreCaption.contains("github"))
        // Mẹo gõ đúp phím dấu trong chú thích "khi trùng" (ưu tiên tiếng Việt).
        let collision = vi.localizedString(forKey: TypingTab.C.collisionVi, value: "∅", table: nil)
        XCTAssertTrue(collision.contains("gõ đúp phím dấu") && collision.contains("lisst → list"), collision)
        // Thẻ người dùng cũ + onboarding nhắc tên nhóm mới.
        let table = try viTable()
        XCTAssertFalse(table.values.contains { $0.contains("Gõ mixed") })
        XCTAssertTrue(table["Do you often mix English into Vietnamese? See the new Mixed Vietnamese/English typing group."]?
            .contains("Gõ lẫn tiếng Anh") ?? false)
    }

    /// Mọi khoá mới dùng trong Cài đặt đều có bản tiếng Việt.
    func testNewKeysTranslated() throws {
        let vi = try viBundle()
        for k in [TypingTab.styleAdvancedSummary, TypingTab.switchAdvancedSummary,
                  TypingTab.systemSettingsCaption, TypingTab.perDocumentTitle, TypingTab.perDocumentCaption, "Keyboard layout", "Open…", "Open Input Sources settings…",
                  "Word that is both English and Vietnamese", "macOS input source shortcut",
                  "Expanded", "Collapsed", ModeTableTab.safeTitle] + Self.allCaptions + ModeNames.all {
            XCTAssertNotEqual(vi.localizedString(forKey: k, value: "∅", table: nil), "∅", k)
        }
    }

    /// Mọi chú thích một dòng của MỌI tab Cài đặt (06/11/2026: Gõ phím trước, các tab còn lại sau).
    static var allCaptions: [String] {
        TypingTab.C.all + ToolsTab.C.all + ShortcutsTab.C.all + ModeTableTab.C.all + GeneralTab.C.all
    }

    /// Chú thích phải NGẮN (Phil 06/11/2026: "viết hơi dài, rối mắt"): ≤ 95 ký tự cả hai ngôn ngữ.
    func testCaptionsAreShort() throws {
        let vi = try viBundle()
        for k in Self.allCaptions + ModeNames.all {
            XCTAssertLessThanOrEqual(k.count, 95, k)
            let v = vi.localizedString(forKey: k, value: "∅", table: nil)
            XCTAssertLessThanOrEqual(v.count, 95, v)
        }
    }

    /// Tên cách gõ theo app: theo triệu chứng, không còn thuật ngữ (Tap, AX, Passthrough…).
    func testModeNamesHaveNoJargon() throws {
        let vi = try viBundle()
        for k in ModeNames.all {
            let v = vi.localizedString(forKey: k, value: "∅", table: nil)
            for t in [k, v] {
                for jargon in ["Tap", "AX", "Passthrough", "Marked", "In-place", "reset"] {
                    XCTAssertFalse(t.contains(jargon), t)
                }
            }
        }
        // Đoạn giới thiệu bảng Ứng dụng: một dòng.
        XCTAssertFalse(vi.localizedString(forKey: ModeTableTab.C.intro, value: "", table: nil).contains("\n"))
    }
}
