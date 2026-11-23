import XCTest
import UIKit

/// "Sửa lỗi bằng Apple Intelligence" — phần thuần (AIProofread.swift): chọn chế độ, prompt,
/// kiểm đầu ra model, so khác theo từ, hạn giờ; + công tắc tắt ⇒ controller không giữ AIAssist.
/// Model thật (FoundationModels) không chạy ở đây — simulator thường không có Apple Intelligence.
final class AIProofreadTests: XCTestCase {

    // MARK: chế độ theo vùng chọn

    func testModeDecision() {
        XCTAssertEqual(AIText.mode(selected: nil), .none)
        XCTAssertEqual(AIText.mode(selected: ""), .none)
        XCTAssertEqual(AIText.mode(selected: "   "), .none)
        XCTAssertEqual(AIText.mode(selected: "123 456"), .none, "không có chữ cái")
        XCTAssertEqual(AIText.mode(selected: "😀"), .none)
        XCTAssertEqual(AIText.mode(selected: "toi di hoc"), .proofread("toi di hoc"))
        XCTAssertEqual(AIText.mode(selected: "hello world"), .proofread("hello world"))
        XCTAssertEqual(AIText.mode(selected: "bạn 😀 ơi"), .proofread("bạn 😀 ơi"))
        XCTAssertEqual(AIText.mode(selected: "dòng một\ndòng hai"), .proofread("dòng một\ndòng hai"))
        // một từ (kể cả dấu câu / khoảng trắng dính) ⇒ từ thay thế, bỏ dấu câu hai đầu
        XCTAssertEqual(AIText.mode(selected: "đẹp"), .alternatives("đẹp"))
        XCTAssertEqual(AIText.mode(selected: " đẹp "), .alternatives("đẹp"))
        XCTAssertEqual(AIText.mode(selected: "bạn,"), .alternatives("bạn"))
        XCTAssertEqual(AIText.mode(selected: "don't"), .alternatives("don't"))
        // "1 từ" kèm số / ký hiệu lẻ (12km) vẫn có chữ là chính? 12km: 2 chữ / 4 ⇒ được
        XCTAssertEqual(AIText.mode(selected: "12km"), .alternatives("12km"))
        XCTAssertEqual(AIText.mode(selected: "a1234567"), .none, "chủ yếu là số")
        XCTAssertEqual(AIText.mode(selected: String(repeating: "a", count: 40)), .none, "quá dài cho một từ")
        // đoạn quá dài ⇒ không mời
        let long = String(repeating: "chữ ", count: 300)
        XCTAssertEqual(AIText.mode(selected: long), .none)
        let ok = String(repeating: "chữ ", count: 200)
        XCTAssertEqual(AIText.mode(selected: ok), .proofread(ok))
    }

    // MARK: prompt

    func testPromptsContainTextAndRules() {
        let p = AIText.proofreadPrompt("toi di hoc")
        XCTAssertTrue(p.hasSuffix("toi di hoc"))
        XCTAssertTrue(AIText.proofreadInstructions.contains("tone marks"))
        XCTAssertTrue(AIText.proofreadInstructions.contains("line breaks"))
        XCTAssertTrue(AIText.proofreadInstructions.contains("do not translate"))
        let a = AIText.alternativesPrompt(word: "đẹp", before: "Hôm nay trời ", after: " quá nhỉ")
        XCTAssertTrue(a.contains("Hôm nay trời ⟦đẹp⟧ quá nhỉ"), a)
        XCTAssertTrue(a.contains("Selected word: đẹp\n"), a)
    }

    func testContextClipping() {
        XCTAssertEqual(AIText.clipBefore(nil), "")
        XCTAssertEqual(AIText.clipBefore("Đoạn trước\nCâu này "), "Câu này ", "chỉ đoạn hiện tại")
        XCTAssertEqual(AIText.clipAfter(" tiếp\nđoạn sau"), " tiếp")
        let before = String(repeating: "abcdefg ", count: 50)   // 400 ký tự
        let b = AIText.clipBefore(before, limit: 30)
        XCTAssertLessThanOrEqual(b.count, 30)
        XCTAssertTrue(b.hasPrefix("abcdefg"), "bỏ mẩu từ cắt dở ở đầu: \(b)")
        let a = AIText.clipAfter(before, limit: 30)
        XCTAssertLessThanOrEqual(a.count, 30)
        XCTAssertTrue(a.hasSuffix("abcdefg"), "bỏ mẩu từ cắt dở ở cuối: \(a)")
        let prompt = AIText.alternativesPrompt(word: "x", before: before, after: before)
        XCTAssertLessThan(prompt.count, 2 * AIText.contextChars + 300, "ngữ cảnh có giới hạn")
    }

    // MARK: kiểm đầu ra sửa lỗi

    func testValidateProofreadAcceptsToneFixes() {
        XCTAssertEqual(AIText.validateProofread(original: "toi di hoc", output: "tôi đi học"), "tôi đi học")
        // giữ khoảng trắng hai đầu của chữ gốc, bỏ khoảng trắng / ngoặc kép model tự thêm
        XCTAssertEqual(AIText.validateProofread(original: " toi di hoc\n", output: "\"tôi đi học\"  "), " tôi đi học\n")
        XCTAssertEqual(AIText.validateProofread(original: "ok ban oi 😀", output: "ok bạn ơi 😀"), "ok bạn ơi 😀")
        // không đổi ⇒ trả y nguyên chữ gốc
        XCTAssertEqual(AIText.validateProofread(original: "Xin chào bạn", output: "Xin chào bạn"), "Xin chào bạn")
        // NFD từ model ⇒ NFC
        let nfd = "tôi đi học".decomposedStringWithCanonicalMapping
        let r = AIText.validateProofread(original: "toi di hoc", output: nfd)
        XCTAssertEqual(r.map { Array($0.unicodeScalars) }, Array("tôi đi học".precomposedStringWithCanonicalMapping.unicodeScalars))
        // ngoặc kép có sẵn trong chữ gốc ⇒ giữ
        XCTAssertEqual(AIText.validateProofread(original: "\"xin chao\"", output: "\"xin chào\""), "\"xin chào\"")
    }

    func testValidateProofreadRejectsWildOutputs() {
        XCTAssertNil(AIText.validateProofread(original: "toi di hoc", output: ""))
        XCTAssertNil(AIText.validateProofread(original: "   ", output: "x"))
        // dài gấp mấy lần (model giải thích / viết lại)
        XCTAssertNil(AIText.validateProofread(original: "toi di hoc",
                                              output: "Here is the corrected text: tôi đi học. I fixed the tone marks."))
        // cụt hẳn
        XCTAssertNil(AIText.validateProofread(original: "hôm nay trời đẹp quá đi chơi thôi các bạn ơi", output: "hôm nay"))
        // mất xuống dòng
        XCTAssertNil(AIText.validateProofread(original: "dong mot\ndong hai", output: "dòng một dòng hai"))
        // mất / thêm emoji
        XCTAssertNil(AIText.validateProofread(original: "vui qua 😀", output: "vui quá"))
        XCTAssertNil(AIText.validateProofread(original: "vui qua", output: "vui quá 😀"))
        // dịch sang tiếng Anh (số từ lệch nhiều) — "bạn có khỏe không" (4) → 2 từ
        XCTAssertNil(AIText.validateProofread(original: "ban co khoe khong vay", output: "How?"))
    }

    // MARK: nhiều dòng — gửi từng dòng, ráp lại đúng xuống dòng gốc

    func testMultilinePromptAndAssemble() {
        let text = "Gui chi Lan:\n\n- bao cao thang 10\n- hoa don dien"
        let p = AIText.proofreadPrompt(text)
        XCTAssertTrue(p.contains("exactly 3 corrected lines"), p)
        XCTAssertTrue(p.contains("Line 1: Gui chi Lan:\nLine 2: - bao cao thang 10\nLine 3: - hoa don dien"), p)
        XCTAssertTrue(AIText.proofreadPrompt("mot dong").contains("exactly 1 corrected line"))
        // mảng đúng số dòng (ngăn \u{1E})
        XCTAssertEqual(AIText.assembleProofread(original: text, output: "Gửi chị Lan:\u{1E}- báo cáo tháng 10\u{1E}- hóa đơn điện"),
                       "Gửi chị Lan:\n\n- báo cáo tháng 10\n- hóa đơn điện", "dòng trống gốc được giữ")
        // model gộp cả đoạn vào MỘT mục (đo thật trên simulator) — vẫn ráp được, dòng trống gốc giữ
        XCTAssertEqual(AIText.assembleProofread(original: text, output: "Gửi chị Lan:\n- báo cáo tháng 10\n- hóa đơn điện"),
                       "Gửi chị Lan:\n\n- báo cáo tháng 10\n- hóa đơn điện")
        // chép lại nhãn "Line N:"
        XCTAssertEqual(AIText.assembleProofread(original: "toi di\nban oi", output: "Line 1: tôi đi\u{1E}Line 2: bạn ơi"), "tôi đi\nbạn ơi")
        // gộp dòng (mất một dòng) / lộ khung JSON thêm dòng ⇒ bỏ
        XCTAssertNil(AIText.assembleProofread(original: "Chào anh,\nem gui file\nThanks!", output: "Chào anh, em gửi file\nThanks!"))
        XCTAssertNil(AIText.assembleProofread(original: "Chào anh,\nem gui file\nThanks!",
                                              output: "Chào anh,\nem gửi file\nThanks!\n\nRespond using the following JSON format: {"))
        // khoảng trắng đầu dòng gốc giữ nguyên
        XCTAssertEqual(AIText.assembleProofread(original: "  toi di hoc", output: "tôi đi học"), "  tôi đi học")
        XCTAssertNil(AIText.assembleProofread(original: "   ", output: "x"))
        XCTAssertEqual(AIText.stripLinePrefix("Line 12:  abc"), " abc")
        XCTAssertEqual(AIText.stripLinePrefix("Lines are"), "Lines are")
    }

    func testLanguageHint() {
        XCTAssertTrue(AIText.languageHint("đẹp").contains("Vietnamese words only"))
        XCTAssertTrue(AIText.languageHint("quick", context: "Can we have a  call tomorrow?").contains("English words only"))
        XCTAssertTrue(AIText.languageHint("meeting", context: "Chiều nay có  với khách hàng").contains("If the selected word is English"))
        XCTAssertTrue(AIText.alternativesPrompt(word: "đẹp", before: "Trời ", after: "").contains("Vietnamese words only"))
    }

    // MARK: sửa cả ô (không vùng chọn)

    func testFieldGating() {
        XCTAssertEqual(AIField.eligible(before: "toi di ", after: "hoc"), "toi di hoc")
        XCTAssertEqual(AIField.eligible(before: nil, after: "ban oi"), "ban oi")
        XCTAssertNil(AIField.eligible(before: "xinchao", after: nil), "< 2 từ")
        XCTAssertNil(AIField.eligible(before: "", after: ""))
        XCTAssertNil(AIField.eligible(before: "12 34", after: ""), "không có chữ")
        let max = String(repeating: "ab ", count: AIField.maxChars / 3) + "cd"   // 500 ký tự
        XCTAssertEqual(max.count, AIField.maxChars)
        XCTAssertNotNil(AIField.eligible(before: max, after: ""))
        XCTAssertNil(AIField.eligible(before: max, after: "x"), "quá maxChars")
    }

    func testFieldFullContextChecks() {
        let t = "Chào bạn 👨‍👩‍👧 nhé"
        // đọc quanh con trỏ bất kỳ
        XCTAssertTrue(AIField.matches(before: "Chào ", after: "bạn 👨‍👩‍👧 nhé", expected: t))
        XCTAssertFalse(AIField.matches(before: "Chào ", after: "bạn", expected: t), "host cắt context sau")
        // cuối / đầu ô
        XCTAssertTrue(AIField.atEnd(before: t, after: "", expected: t))
        XCTAssertTrue(AIField.atEnd(before: t, after: nil, expected: t))
        XCTAssertFalse(AIField.atEnd(before: t, after: "x", expected: t))
        XCTAssertFalse(AIField.atEnd(before: "bạn 👨‍👩‍👧 nhé", after: "", expected: t), "host cắt context trước (theo đoạn)")
        XCTAssertTrue(AIField.atStart(before: "", after: t, expected: t))
        XCTAssertFalse(AIField.atStart(before: "Đoạn trước\n", after: t, expected: t), "còn chữ phía trước ⇒ không phải cả ô")
        // so từng scalar: NFD ≠ NFC (xoá theo scalar phải đúng y chữ)
        let nfd = "việt".decomposedStringWithCanonicalMapping
        XCTAssertFalse(AIField.same(nfd, "việt"))
        XCTAssertTrue(AIField.same("việt", "việt"))
    }

    /// Ô giả: xoá mỗi lần một Character (đa số host) hoặc một scalar (ô NFD / vài web view);
    /// xoá ở đầu ô không làm gì. deleteCount phải luôn xoá sạch, kể cả emoji ghép, dấu tổ hợp.
    func testDeleteCountClearsFieldWithEmojiAndCombiningMarks() {
        final class FakeField {
            var scalars: [Unicode.Scalar]
            let perScalar: Bool
            init(_ s: String, perScalar: Bool) { scalars = Array(s.unicodeScalars); self.perScalar = perScalar }
            var text: String { var v = String.UnicodeScalarView(); v.append(contentsOf: scalars); return String(v) }
            func deleteBackward() {
                guard !scalars.isEmpty else { return }
                if perScalar { scalars.removeLast(); return }
                let last = text.last!
                scalars.removeLast(last.unicodeScalars.count)
            }
        }
        let samples = ["Chào bạn 👨‍👩‍👧 nhé", "việt".decomposedStringWithCanonicalMapping + " nam",
                       "🇻🇳 cờ 👍🏽 ok", "e\u{301}\u{323} x", "line1\r\nline2", "plain ascii"]
        for s in samples {
            for perScalar in [false, true] {
                let f = FakeField(s, perScalar: perScalar)
                for _ in 0..<AIField.deleteCount(s) { f.deleteBackward() }
                XCTAssertEqual(f.text, "", "\(s.debugDescription) perScalar=\(perScalar)")
            }
            XCTAssertGreaterThanOrEqual(AIField.deleteCount(s), s.count)
            XCTAssertGreaterThanOrEqual(AIField.caretOffset(s), s.count, "dời con trỏ đủ xa dù host đếm Character hay UTF-16")
        }
        XCTAssertEqual(AIField.deleteCount("👨‍👩‍👧"), 5)
        XCTAssertEqual(AIField.caretOffset("👨‍👩‍👧"), 8)
    }

    // MARK: công tắc trong app theo trạng thái model

    func testSettingUIByModelState() {
        XCTAssertEqual(AISettingUI.of(.available), .enabled)
        XCTAssertEqual(AISettingUI.of(.deviceNotEligible), .hidden)
        XCTAssertEqual(AISettingUI.of(.unsupportedOS), .hidden)
        XCTAssertEqual(AISettingUI.of(.notEnabled).hint, "Bật Apple Intelligence trong Cài đặt → Apple Intelligence & Siri")
        XCTAssertEqual(AISettingUI.of(.notReady).hint, "Mô hình đang tải, thử lại sau")
        XCTAssertTrue(AISettingUI.of(.notEnabled).isShown)
        XCTAssertFalse(AISettingUI.of(.notEnabled).isEnabled)
        XCTAssertFalse(AISettingUI.of(.deviceNotEligible).isShown)
        // mã IntelligenceStatus ↔ AIModelState
        XCTAssertEqual(AIModelState(rawValue: 2), .notEnabled)
        XCTAssertEqual(AIModelState(rawValue: 3), .notReady)
        let saved = AIAvailability.probe
        defer { AIAvailability.probe = saved }
        AIAvailability.probe = nil
        XCTAssertEqual(AIAvailability.state, .unsupportedOS)
        XCTAssertFalse(PlusFeature.aiProofread.isAvailableOnDevice)
        if #available(iOS 26.0, *) {
            AIAvailability.probe = { 2 }
            XCTAssertEqual(AISettingUI.current, AISettingUI.of(.notEnabled))
            XCTAssertTrue(PlusFeature.aiProofread.isAvailableOnDevice, "hiện (khoá) để người dùng biết bật ở đâu")
            AIAvailability.probe = { 1 }
            XCTAssertFalse(PlusFeature.aiProofread.isAvailableOnDevice)
            AIAvailability.probe = { 0 }
            XCTAssertTrue(AIAvailability.isAvailable)
        }
    }

    // MARK: từ thay thế

    func testValidateAlternatives() {
        XCTAssertEqual(AIText.validateAlternatives(word: "đẹp", outputs: ["xinh", " Đẹp ", "xinh", "tuyệt vời", "\"tươi\"", "x\ny"]),
                       ["xinh", "tuyệt vời", "tươi"])
        // tối đa 3, bỏ cụm quá dài
        XCTAssertEqual(AIText.validateAlternatives(word: "go", outputs: ["went to the market today", "move", "head", "travel", "walk"]),
                       ["move", "head", "travel"])
        // theo kiểu hoa của từ gốc
        XCTAssertEqual(AIText.validateAlternatives(word: "Đẹp", outputs: ["xinh"]), ["Xinh"])
        XCTAssertEqual(AIText.validateAlternatives(word: "OK", outputs: ["fine"]), ["FINE"])
        XCTAssertEqual(AIText.validateAlternatives(word: "dep", outputs: ["", "...", "đẹp."]), ["đẹp"])
        XCTAssertEqual(AIText.splitList("a\u{1E}b\u{1E}\u{1E}c"), ["a", "b", "c"])
    }

    func testReplaceWordKeepsPunctuationAndSpaces() {
        XCTAssertEqual(AIText.replaceWord(in: "bạn,", word: "bạn", with: "cậu"), "cậu,")
        XCTAssertEqual(AIText.replaceWord(in: " đẹp ", word: "đẹp", with: "xinh"), " xinh ")
        XCTAssertNil(AIText.replaceWord(in: "khác", word: "đẹp", with: "xinh"))
    }

    // MARK: so khác theo từ

    func testWordDiffMarksChangedWords() {
        let d = WordDiff.diff(original: "toi di hoc o truong", corrected: "tôi đi học ở trường")
        XCTAssertEqual(d.map(\.text).joined(), "tôi đi học ở trường", "ghép lại đúng bản sửa")
        XCTAssertEqual(d.filter(\.changed).map(\.text), ["tôi", "đi", "học", "ở", "trường"])
        XCTAssertEqual(WordDiff.changedWordCount(original: "toi di hoc o truong", corrected: "tôi đi học ở trường"), 5)

        let d2 = WordDiff.diff(original: "Hôm nay troi đẹp quá", corrected: "Hôm nay trời đẹp quá")
        XCTAssertEqual(d2, [WordDiffSegment(text: "Hôm nay ", changed: false),
                            WordDiffSegment(text: "trời", changed: true),
                            WordDiffSegment(text: " đẹp quá", changed: false)])
        XCTAssertEqual(WordDiff.changedWordCount(original: "Hôm nay troi đẹp quá", corrected: "Hôm nay trời đẹp quá"), 1)

        // không đổi ⇒ không đoạn nào bị tô; xuống dòng giữ nguyên
        let same = "dòng một\ndòng hai"
        XCTAssertEqual(WordDiff.diff(original: same, corrected: same), [WordDiffSegment(text: same, changed: false)])
        XCTAssertEqual(WordDiff.changedWordCount(original: same, corrected: same), 0)

        // thêm từ (ngữ pháp) ⇒ chỉ từ mới được tô
        let d3 = WordDiff.diff(original: "I going home", corrected: "I am going home")
        XCTAssertEqual(d3.filter(\.changed).map(\.text), ["am"])
        // bỏ từ ⇒ không có gì để tô trong bản sửa
        XCTAssertEqual(WordDiff.diff(original: "the the cat", corrected: "the cat").filter(\.changed), [])
        // rỗng
        XCTAssertEqual(WordDiff.diff(original: "", corrected: ""), [])
        XCTAssertEqual(WordDiff.diff(original: "", corrected: "mới"), [WordDiffSegment(text: "mới", changed: true)])
    }

    func testTokenizeKeepsEveryCharacter() {
        let s = "  a  b\nc😀 "
        XCTAssertEqual(WordDiff.tokenize(s).joined(), s)
        XCTAssertEqual(WordDiff.tokenize(s), ["  ", "a", "  ", "b", "\n", "c😀", " "])
    }

    // MARK: lỗi + hạn giờ

    func testEngineCodesAndMessages() {
        XCTAssertNil(AIFailure(engineCode: 0))
        XCTAssertEqual(AIFailure(engineCode: 1), .unavailable)
        XCTAssertEqual(AIFailure(engineCode: 2), .guardrail)
        XCTAssertEqual(AIFailure(engineCode: 3), .tooLong)
        XCTAssertEqual(AIFailure(engineCode: 4), .unsupportedLanguage)
        XCTAssertEqual(AIFailure(engineCode: 5), .timeout)
        XCTAssertEqual(AIFailure(engineCode: 99), .failed)
        for f in [AIFailure.unavailable, .guardrail, .tooLong, .unsupportedLanguage, .timeout, .failed, .rejected] {
            XCTAssertTrue(f.message.hasPrefix("✨"), "\(f)")
        }
        XCTAssertEqual(AIModelState(rawValue: 0), .available)
    }

    func testTimeoutRace() async {
        let fast = await AITimeout.race(seconds: 2) { () async -> Int in 7 }
        XCTAssertEqual(fast, 7)
        // việc KHÔNG biết huỷ (như callback C) — hạn giờ vẫn trả đúng hạn
        let t0 = Date()
        let slow = await AITimeout.race(seconds: 0.2) { () async -> Int in
            await withCheckedContinuation { c in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { c.resume(returning: 1) }
            }
        }
        XCTAssertNil(slow)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
    }

    // MARK: thanh gợi ý — chip dẫn đầu ở slot đầu

    func testAIChipsLeadTheBar() {
        for token in AITokens.lead {
            var set = KeyboardView.SuggestionSet()
            set.nextWords = ["a", "b", "c"]
            set.actionLabel = "✨ x"; set.actionPayload = token
            guard case .slots(let s, _) = SuggestionSlots.arrange(set) else { return XCTFail() }
            XCTAssertEqual(s.first??.payload, token)
            XCTAssertEqual(s.dropFirst().compactMap { $0?.label }, ["a", "b"])
        }
    }

    // MARK: công tắc — mặc định TẮT, tắt ⇒ không có AIAssist

    func testSettingDefaultsOffAndLoads() {
        XCTAssertFalse(KeyboardSettings().aiProofread)
        let d = UserDefaults(suiteName: "vt-ai-setting")!
        d.removePersistentDomain(forName: "vt-ai-setting")
        d.set(true, forKey: PlusFeature.aiProofreadKey)
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = d
        defer { UserDefaultsProvider.shared = saved }
        XCTAssertTrue(KeyboardSettings.load().aiProofread)
        XCTAssertEqual(PlusFeature.aiProofread.settingKey, "aiProofread")
        XCTAssertFalse(PlusFeature.aiProofread.settingDefault)
    }

    @MainActor func testControllerHoldsNothingWhenOff() {
        let savedPaywall = PlusGate.paywallEnabled
        PlusGate.paywallEnabled = false
        let saved = UserDefaultsProvider.shared
        defer { UserDefaultsProvider.shared = saved; PlusGate.paywallEnabled = savedPaywall }
        for on in [false, true] {
            let d = KeyboardBenchTests.makeDefaults("B")
            d.set(on, forKey: PlusFeature.aiProofreadKey)
            UserDefaultsProvider.shared = d
            let rig = KeyboardBenchTests.Rig()
            var want = on
            if #unavailable(iOS 26.0) { want = false }
            XCTAssertEqual(rig.vc.debugAIActive, want, "aiProofread=\(on)")
            XCTAssertFalse(AIAssistLoader.isLoaded && !on, "tắt ⇒ không dlopen")
            rig.close()
        }
    }

    /// Ngừng gõ ⇒ hẹn vẽ lại thanh để mời "✨ Sửa lỗi": chữ không đổi nên KHÔNG được tính lại
    /// auto-shift — trước đây lượt hẹn này hạ ⇧ người dùng vừa chạm (gõ "- ", bấm ⇧, chữ kế vẫn thường).
    @MainActor func testTypingPauseOnlyRedrawsTheBar() {
        guard #available(iOS 26.0, *) else { return }
        let proxy = KeyboardBenchTests.BenchProxy()
        proxy.text = "Test - "
        var refreshes = 0, redraws = 0
        let ai = AIAssist(host: .init(proxy: { proxy }, keyboard: { nil }, edit: { $0() },
                                      refresh: { refreshes += 1 }, redraw: { redraws += 1 }))
        ai.keyPressed()
        var set = KeyboardView.SuggestionSet()
        ai.decorate(&set)
        let done = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + AIAssist.typingPause + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(redraws, 1)
        XCTAssertEqual(refreshes, 0, "chữ không đổi ⇒ không đụng ⇧")
        ai.close()
    }

    /// Không có framework ở đường dẫn ⇒ coi như không dùng được (không crash).
    func testLoaderMissingFrameworkIsUnavailable() {
        AIAssistLoader.debugReset()
        XCTAssertNil(AIAssistLoader.entry(paths: ["/nonexistent/VTIntelligence.framework/VTIntelligence"]))
        AIAssistLoader.debugReset()
    }
}

/// AI trích địa chỉ (ô địa chỉ) — kiểm chống bịa.
final class AIAddressTests: XCTestCase {
    private let src = "Gửi giúp chị Lan 0987654321\nnhà mình ở số 5 ngõ 10 láng hạ, đống đa hn nha"

    func testAcceptsVerbatimAddress() {
        XCTAssertEqual(AIAddress.validate("số 5 ngõ 10 láng hạ, đống đa hn", source: src), "số 5 ngõ 10 láng hạ, đống đa hn")
        XCTAssertEqual(AIAddress.validate("  số 5  ngõ 10 láng hạ, đống đa hn. ", source: src), "số 5 ngõ 10 láng hạ, đống đa hn")
    }
    func testRejectsInventedWords() {
        XCTAssertNil(AIAddress.validate("Số 5 ngõ 10 Láng Hạ, Đống Đa, Hà Nội", source: src))   // "noi" không có trong gốc
        XCTAssertNil(AIAddress.validate("số 7 ngõ 10 láng hạ", source: src))                  // số nhà sai
    }
    func testRejectsPhoneEmptyAndTooShort() {
        XCTAssertNil(AIAddress.validate("chị Lan 0987654321", source: src))
        XCTAssertNil(AIAddress.validate("", source: src))
        XCTAssertNil(AIAddress.validate("hn", source: src))
    }
    func testPromptCapsLength() {
        XCTAssertLessThanOrEqual(AIAddress.prompt(String(repeating: "a", count: 2000)).count, ClipDetect.maxLength + 20)
    }
}

/// Dịch bằng Apple Intelligence (thử nghiệm) — vector khớp Android AITranslateTests.
final class AITranslateTests: XCTestCase {
    func testAcceptsGoodTranslations() {
        XCTAssertEqual(AITranslate.validate("It's raining cats and dogs", source: "Mưa như trút nước", target: "en"), "It's raining cats and dogs")
        XCTAssertEqual(AITranslate.validate("Trời mưa như trút nước", source: "It's raining cats and dogs", target: "vi"), "Trời mưa như trút nước")
        XCTAssertEqual(AITranslate.validate("ありがとう", source: "Cảm ơn", target: "ja"), "ありがとう")
        XCTAssertEqual(AITranslate.validate("Translation:\nHello", source: "Xin chào", target: "en"), "Hello")
        XCTAssertEqual(AITranslate.validate("\"Hello\"", source: "Xin chào", target: "en"), "Hello")
        XCTAssertEqual(AITranslate.validate("Line one\nLine two", source: "Dòng một\nDòng hai", target: "en"), "Line one\nLine two")
    }
    func testRejectsSuspiciousOutput() {
        XCTAssertNil(AITranslate.validate("", source: "Xin chào", target: "en"))
        XCTAssertNil(AITranslate.validate("Xin chào bạn", source: "Xin chào bạn", target: "en"))
        XCTAssertNil(AITranslate.validate("Hello", source: "Hello", target: "vi"))
        XCTAssertNil(AITranslate.validate("Hello", source: "Xin chào", target: "ja"))
        XCTAssertNil(AITranslate.validate("Line one and two", source: "Dòng một\nDòng hai", target: "en"))
        XCTAssertNil(AITranslate.validate(String(repeating: "Hi. ", count: 40), source: "Chào", target: "en"))
    }
    func testPromptNamesLanguages() {
        let p = AITranslate.prompt("Xin chào", source: "vi", target: "en")
        XCTAssertTrue(p.contains("from Vietnamese to English"))
        XCTAssertTrue(p.hasSuffix("Xin chào"))
    }
}
