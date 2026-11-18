// Thu gọn cài đặt (docs/SETTINGS-CLEANUP-SPEC.md §5): (a) bộ chọn hồ sơ vẫn áp đúng key sau khi
// mục đổi chỗ, (b) tìm kiếm cài đặt trỏ đúng chỗ mới, (c) không còn chuỗi nhắc bộ gõ khác,
// (d) nhãn bảng §3 khớp. Cấu trúc tab Tính Năng (§4) + Gỡ lỗi rời tab Giới Thiệu.
import XCTest

final class SettingsCleanupTests: XCTestCase {
    override func tearDown() {
        L10n.apply("vi")
        super.tearDown()
    }

    private static var iosRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: Self.iosRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    private func locations(_ q: String) -> [SettingsLocation] {
        SettingsIndex.search(q) { _ in true }.map(\.location)
    }

    // MARK: §4 cấu trúc

    func testFeaturePagesStructure() {
        XCTAssertEqual(FeaturePage.allCases.map(\.viTitle),
                       ["Sửa lỗi & gợi ý", "Gõ vuốt", "Gõ tắt & mẫu câu", "Phím & cử chỉ", "Giao diện",
                        "Riêng tư & sao lưu", "Nâng cao / Gỡ lỗi"])
        XCTAssertEqual(FeaturePage.groups.flatMap { $0 }, FeaturePage.allCases, "mọi trang hiện đúng một lần, theo thứ tự")
        XCTAssertEqual(FeaturePage.groups.last, [.nangCao], "Nâng cao / Gỡ lỗi ở cuối danh sách")
        for p in FeaturePage.allCases {
            XCTAssertNotNil(L10n.en[p.viTitle], p.viTitle)
            if let a = p.guideAnchor { XCTAssertNotNil(L10n.enAnchors[a], a) }
        }
    }

    /// Gỡ lỗi (log chạm phím) rời tab Giới Thiệu, chỉ còn ở "Nâng cao / Gỡ lỗi"; trang gộp đủ phần.
    func testPagesAssembledFromMergedSections() throws {
        let app = try source("App/VietTelexApp.swift")
        let pages = try source("App/FeaturePages.swift")
        XCTAssertFalse(app.contains("DebugSection()"), "Gỡ lỗi không còn ở tab Giới Thiệu")
        XCTAssertTrue(pages.contains("case .nangCao: FeaturePageList(page: .nangCao) { DebugSection() }"))
        XCTAssertTrue(pages.contains("case .riengTu: FeaturePageList(page: .riengTu) { RiengTuSection(); SaoLuuSection() }"))
        XCTAssertTrue(app.contains("NavigationLink { TypingAdvancedPage() }"), "Kiểu gõ › Nâng cao")
        XCTAssertTrue(pages.contains("NavigationLink { FeedbackPage() }"), "Phím & cử chỉ › Phản hồi khi chạm")
    }

    // MARK: (a) bộ chọn hồ sơ

    /// Mọi key bộ chọn hồ sơ đặt vẫn có đúng một dòng cài đặt, ở chỗ mới.
    func testProfileKeysPointToNewPlaces() {
        let expected: [String: SettingsLocation] = [
            "autoRestore": .mixedAdvanced(.autoRestore),
            "contextualEnglish": .mixedAdvanced(.contextualEnglish),
            RetroEnglishUI.autoKey: .mixedAdvanced(.retroEnglish),
            RetroEnglishUI.frequencyKey: .mixedAdvanced(.englishByFrequency),
            "spaceSwipeLanguage": .mixed(.spaceSwipeLanguage),
            "swipeEnglish": .page(.goVuot),
        ]
        XCTAssertEqual(Set(OnboardingSettings.keys), Set(expected.keys))
        for k in OnboardingSettings.keys {
            XCTAssertEqual(SettingsIndex.all.filter { $0.key == k }.count, 1, k)
            XCTAssertEqual(SettingsIndex.entry(forKey: k)?.location, expected[k], k)
            XCTAssertNotNil(BackupSettings.byKey[k], "key \(k) phải còn trong sao lưu")
        }
    }

    /// Áp hồ sơ ghi đúng các key (kể cả "Vuốt từ tiếng Anh" giờ ở trang Gõ vuốt).
    func testApplyingProfileStillWritesMovedKeys() {
        let name = "vt-test-settings-cleanup"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        defer { d.removePersistentDomain(forName: name) }
        for p in OnboardingProfile.allCases {
            OnboardingSettings.apply(p, to: d)
            for (k, v) in p.values { XCTAssertEqual(d.object(forKey: k) as? Bool, v, "\(p) \(k)") }
            XCTAssertEqual(OnboardingSettings.match(OnboardingSettings.current(d), lastChosen: p), p)
        }
    }

    // MARK: (b) tìm kiếm

    func testSearchPointsToNewLocations() {
        for lang in ["vi", "en"] {
            L10n.apply(lang)
            XCTAssertTrue(locations("vuot tu tieng anh").contains(.page(.goVuot)), lang)
            XCTAssertTrue(locations("swipe english").contains(.page(.goVuot)), lang)
            XCTAssertEqual(SettingsIndex.search("vuot tu tieng anh") { _ in true }
                .filter { $0.viTitle == SettingLabel.swipeEnglish }.map(\.location), [.page(.goVuot)], lang)
            XCTAssertTrue(locations("rung").contains(.feedback), lang)
            XCTAssertTrue(locations("haptic").contains(.feedback), lang)
            XCTAssertTrue(locations("am thanh phim").contains(.feedback), lang)
            XCTAssertTrue(locations("phan hoi").contains(.feedback), lang)
            XCTAssertTrue(locations("debug").contains(.page(.nangCao)), lang)
            XCTAssertTrue(locations("go loi").contains(.page(.nangCao)), lang)
            XCTAssertTrue(locations("teencode").contains(.typingAdvanced), lang)
            XCTAssertTrue(locations("telex don gian").contains(.typingAdvanced), lang)
            XCTAssertTrue(locations("quick telex").contains(.typingAdvanced), lang)
            XCTAssertTrue(locations("kieu moi").contains(.typingAdvanced), lang)
            XCTAssertTrue(locations("tan suat").contains(.mixedAdvanced(.englishByFrequency)), lang)
            XCTAssertTrue(locations("sua tu phia truoc").contains(.mixedAdvanced(.retroEnglish)), lang)
            XCTAssertTrue(locations("vuot phim cach").contains(.mixed(.spaceSwipeLanguage)), lang)
            XCTAssertTrue(locations("so tien").contains(.page(.suaLoi)), lang)
            XCTAssertTrue(locations("chip so").contains(.page(.suaLoi)), lang)
            XCTAssertTrue(locations("spell").contains(.page(.suaLoi)), lang)
            XCTAssertTrue(locations("emoji").contains(.page(.suaLoi)), lang)
            XCTAssertTrue(locations("clipboard").contains(.page(.riengTu)), lang)
            XCTAssertTrue(locations("backup").contains(.page(.riengTu)), lang)
            XCTAssertTrue(locations("icloud").contains(.page(.riengTu)), lang)
            XCTAssertTrue(locations("them dau").contains(.page(.suaLoi)), lang)
        }
        XCTAssertTrue(locations("").isEmpty)
        // Điều kiện (Plus / iPhone) lọc kết quả.
        XCTAssertFalse(SettingsIndex.search("icloud") { $0 == .always }.contains { $0.condition == .iCloud })
    }

    /// Đường dẫn dưới kết quả: mọi phần có bản dịch.
    func testLocationPathsTranslated() {
        let locs: [SettingsLocation] = [.feedback, .typingAdvanced, .mixed(.section), .mixedAdvanced(.autoRestore)]
            + FeaturePage.allCases.map { .page($0) }
        for l in locs {
            for k in l.pathKeys { XCTAssertNotNil(L10n.en[k], k) }
        }
        XCTAssertEqual(SettingsLocation.mixedAdvanced(.autoRestore).pathKeys, ["Kiểu Gõ", "Gõ lẫn tiếng Anh", "Nâng cao"])
        XCTAssertEqual(SettingsLocation.feedback.pathKeys, ["Phím & cử chỉ", "Phản hồi khi chạm"])
        for e in SettingsIndex.all { XCTAssertNotNil(L10n.en[e.viTitle], e.viTitle) }
    }

    // MARK: (c) không nhắc bộ gõ khác

    /// Tên viết ngược để chính file test không chứa tên.
    private static let otherInputMethods = ["yekinu", "yekve", "yeknepo", "teivgneitog", "nabal", "yekiv",
                                            "yekteiv", "yekx", "oobmab-subi"].map { String($0.reversed()) }

    func testNoOtherInputMethodNamesInSources() throws {
        let re = try NSRegularExpression(pattern: "\\b(" + Self.otherInputMethods.joined(separator: "|") + ")\\b",
                                         options: [.caseInsensitive])
        var hits: [String] = []
        for dir in ["App", "Keyboard", "Shared"] {
            let base = Self.iosRoot.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(files.isEmpty, dir)
            for f in files {
                let src = try String(contentsOf: f, encoding: .utf8)
                if re.firstMatch(in: src, range: NSRange(location: 0, length: (src as NSString).length)) != nil {
                    hits.append(f.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(hits, [])
        for (vi, en) in L10n.en {
            let s = vi + " " + en
            XCTAssertNil(re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)), vi)
        }
    }

    // MARK: (d) nhãn §3

    func testSharedLabels() {
        XCTAssertEqual(SettingLabel.freeMarking, "Bỏ dấu tự do")
        XCTAssertEqual(SettingLabel.modernTone, "Bỏ dấu kiểu mới (oà, uý)")
        XCTAssertEqual(SettingLabel.reEditWord, "Sửa dấu từ đã gõ")
        XCTAssertEqual(SettingLabel.numberChips, "Gợi ý số tiền")
        XCTAssertEqual(SettingLabel.autoRestore, "Tự khôi phục từ tiếng Anh")
        XCTAssertEqual(SettingLabel.autoRestore, MixedTypingItem.autoRestore.viTitle)
        XCTAssertEqual(SettingLabel.addTones, "Thêm dấu")
        XCTAssertEqual(SettingLabel.typingAdvanced, "Nâng cao")
        XCTAssertEqual(SettingLabel.feedbackPage, "Phản hồi khi chạm")
        XCTAssertEqual(PlusFeature.sentenceDiacritics.title, "Thêm dấu")
        XCTAssertEqual(SettingsIndex.entry(forKey: "numberChips")?.viTitle, "Gợi ý số tiền")
        XCTAssertEqual(SettingsIndex.entry(forKey: "addTonesChip")?.viTitle, "Thêm dấu")
        XCTAssertEqual(SettingsIndex.entry(forKey: "freeMarking")?.location, .typingAdvanced)
        XCTAssertEqual(SettingsIndex.entry(forKey: "teencode")?.location, .typingAdvanced, "teencode ở Nâng cao kiểu gõ")
        XCTAssertEqual(SettingsIndex.entry(forKey: "autoCircumflex")?.location, .typingAdvanced, "Tự thêm dấu mũ ở Nâng cao kiểu gõ")
        XCTAssertEqual(SettingsIndex.entry(forKey: "reEditWord")?.location, .page(.suaLoi))
        // Sửa chạm trượt gom một chỗ: trang Sửa lỗi & gợi ý.
        for k in ["smartTouch", "autoCorrect", "autoFixAdjacent"] {
            XCTAssertEqual(SettingsIndex.entry(forKey: k)?.location, .page(.suaLoi), k)
        }
        for k in ["keyPreviewEnabled", "keyPressHighlight", "hapticFeedback", "keySound"] {
            XCTAssertEqual(SettingsIndex.entry(forKey: k)?.location, .feedback, k)
        }
    }

    /// Nhãn cũ / thuật ngữ không còn ở nhãn chính của giao diện.
    func testOldLabelsGone() throws {
        let ui = try ["App/FeaturePages.swift", "App/VietTelexApp.swift", "App/MixedTypingSection.swift",
                      "App/SettingsIndex.swift", "Shared/PlusConfig.swift"].map(source).joined()
        for old in ["(\"Chip số\")", "(\"Chip “Thêm dấu”\")", "(\"Đặt dấu tự do\")",
                    "(\"Bỏ dấu kiểu mới\")", "(\"Chính tả & sửa lỗi\")", "(\"Gợi ý & từ điển\")", "(\"Riêng tư & clipboard\")",
                    "(\"Thêm dấu cả câu\")", "Gõ mixed Việt/Anh"] {
            XCTAssertFalse(ui.contains(old), old)
        }
    }

    // MARK: chú thích một dòng (06/11/2026, cùng chữ với macOS + Android)

    /// Mỗi chú thích ≤ 95 ký tự (cả tiếng Việt lẫn tiếng Anh), có bản dịch, không trùng.
    func testCaptionsAreShort() {
        XCTAssertGreaterThan(SettingCaption.all.count, 60)
        XCTAssertEqual(Set(SettingCaption.all).count, SettingCaption.all.count, "trùng chú thích")
        for k in SettingCaption.all {
            XCTAssertLessThanOrEqual(k.count, 95, k)
            let en = L10n.en[k]
            XCTAssertNotNil(en, "thiếu bản dịch: \(k)")
            XCTAssertLessThanOrEqual(en?.count ?? 0, 95, en ?? k)
        }
    }

    /// Trang cài đặt không còn chú thích dài viết thẳng trong L("…") (phải đi qua SettingCaption).
    func testSettingsPagesUseCaptionTable() throws {
        let re = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\\n]|\\.)*)"\)"#)
        // Ngoại lệ có chủ đích: tab Mẫu Câu (không phải trang cài đặt), hộp thoại xác nhận, onboarding.
        let allowed = ["Bấm ☰ trên bàn phím để chèn nhanh", "Mẫu có nội dung bắt đầu bằng https://", "YAML phẳng",
                       "Gợi ý sẽ học lại từ đầu", "Toàn quyền Truy cập là tuỳ chọn", "%@ cần Toàn quyền Truy cập",
                       "Nếu đã bật rồi: mở bàn phím", "Chưa có log.", "Bấm 🌐 dưới bàn phím",
                       "Nếu chưa thấy mục 2", "Apple Intelligence trên máy này chưa hỗ trợ"]
        var long: [String] = []
        for rel in ["App/VietTelexApp.swift", "App/FeaturePages.swift", "App/MixedTypingSection.swift",
                    "App/RiengTuSection.swift", "App/Backup/BackupSection.swift", "App/ThemeSettingsView.swift"] {
            let src = try source(rel) as NSString
            for m in re.matches(in: src as String, range: NSRange(location: 0, length: src.length)) {
                let lit = src.substring(with: m.range(at: 1))
                if lit.count > 95 && !allowed.contains(where: { lit.hasPrefix($0) }) { long.append("\(rel): \(lit.prefix(60))…") }
            }
        }
        XCTAssertEqual(long, [], "chú thích dài ngoài bảng SettingCaption")
    }
}
