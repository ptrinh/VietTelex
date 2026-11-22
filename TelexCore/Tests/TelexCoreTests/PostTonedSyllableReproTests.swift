import XCTest
@testable import TelexCore

/// Tái hiện lỗi: khi gõ xong một từ tiếng Việt đã hoàn chỉnh có dấu (ví dụ `được`),
/// sau đó nhập thêm ký tự `u`, trạng thái hiển thị bị biến đổi bất thường (mất dấu
/// thanh/dấu móc, lộ phím Telex thô `j`, hoặc nhảy thứ tự ký tự) thay vì giữ nguyên
/// phần chữ đã tạo dấu trước đó.
///
/// Đã sửa (PR #133): khi live spell-check đóng băng một từ ĐÃ có dấu chữ (đ ư ơ â ê
/// ô ă) và dấu thanh đang hiện, từ được giữ nguyên như đang hiển thị và phím mới
/// (cùng mọi phím sau) được gõ thẳng: "dduowcj"+"u" → "đượcu". Từ không có dấu chữ
/// vẫn gập dấu thanh về phím thô như trước ("installer").
final class PostTonedSyllableReproTests: XCTestCase {

    private func configuredEngine() -> TelexEngine {
        var e = TelexEngine()
        e.freeMarking = true
        e.liveSpellCheck = true
        e.teencode = false
        e.contextualEnglish = true
        e.collisionPrefersVietnamese = true
        e.modernTone = false
        return e
    }

    private func type(_ s: String, _ e: inout TelexEngine) {
        for ch in s { _ = e.feed(ch) }
    }

    /// What the screen shows after typing `keys` (single-line asserts below are ported
    /// to Kotlin/C++ by android/telexcore/scripts/port-swift-tests.py).
    private func screen(_ keys: String) -> String {
        var e = configuredEngine()
        type(keys, &e)
        return e.composed
    }

    private func vni(_ keys: String) -> String {
        var e = TelexEngine()
        e.vniMode = true
        e.liveSpellCheck = true
        type(keys, &e)
        return e.composed
    }

    /// Bảng kết quả màn hình (dùng chung cho Kotlin/C++ qua script port).
    func testKeptToneScreenTable() {
        XCTAssertEqual(screen("dduowcju"), "đượcu")
        XCTAssertEqual(screen("dduowjcu"), "đượcu")
        XCTAssertEqual(screen("ddujowcu"), "đượcu")
        XCTAssertEqual(screen("duowcjdu"), "đượcu")
        XCTAssertEqual(screen("dduowcjuj"), "đượcuj")
        XCTAssertEqual(screen("vieetjk"), "việtk")
        XCTAssertEqual(screen("tieengsk"), "tiếngk")
        XCTAssertEqual(screen("nguwowfiw"), "ngườiw")
        XCTAssertEqual(screen("ddeemfn"), "đềmn")
        XCTAssertEqual(screen("dduowcjf"), "đượcf")
        XCTAssertEqual(vni("d9u7o7c5u"), "đượcu")
        // Không đổi: không dấu chữ, dấu thanh bị đuôi tắc nuốt, hoặc phím là thao tác huỷ.
        XCTAssertEqual(screen("installer"), "installer")
        XCTAssertEqual(screen("tifw"), "tifw")
        XCTAssertEqual(screen("charact"), "chârct")
        XCTAssertEqual(screen("arkan"), "ârkn")
        XCTAssertEqual(screen("softwa"), "sơfta")
        XCTAssertEqual(screen("cheese"), "chese")
    }

    func testTypingUAfterCompletedDuocReproduction() {
        // Các thứ tự phím Telex hợp lệ đều cho ra "được" trước khi gõ thêm "u":
        // trước bản sửa lần lượt ra "đươcju", "đươjcu", "đujơcu", "đươcju".
        let sequences = ["dduowcj", "dduowjc", "ddujowc", "duowcjd"]

        for seq in sequences {
            var e = configuredEngine()
            type(seq, &e)
            XCTAssertEqual(e.composed, "được", "Tiền điều kiện: '\(seq)' phải tạo thành 'được'")

            let action = e.feed("u")
            XCTAssertEqual(e.composed, "đượcu", "Chuỗi '\(seq)u' bị biến đổi thành '\(e.composed)'")
            // Chỉ chèn thêm "u", không sửa lại phần "được" đã hiện.
            XCTAssertEqual(action, .passthrough, "\(seq)+u")
        }
    }

    /// Không bật gõ tự do: các thứ tự gõ thường vẫn giữ "được".
    func testTypingUAfterDuocWithoutFreeMarking() {
        for seq in ["dduowcj", "dduowjc", "ddujowc"] {
            var e = configuredEngine()
            e.freeMarking = false
            type(seq, &e)
            XCTAssertEqual(e.composed, "được", seq)
            XCTAssertEqual(e.feed("u"), .passthrough, seq)
            XCTAssertEqual(e.composed, "đượcu", seq)
        }
    }

    /// Các từ khác có dấu chữ + dấu thanh, gõ tiếp một phím làm từ hết hợp lệ: giữ
    /// nguyên từ đang hiện và chỉ chèn phím mới.
    func testMarkedWordKeepsToneOnInvalidContinuation() {
        let cases: [(String, String, String)] = [
            ("vieetj", "k", "việtk"),
            ("tieengs", "k", "tiếngk"),
            ("nguwowfi", "w", "ngườiw"),
            ("ddeemf", "n", "đềmn"),
            ("dduowcj", "f", "đượcf"),     // huyền bị đuôi c từ chối → chữ f thường
        ]
        for (word, key, expected) in cases {
            var e = configuredEngine()
            type(word, &e)
            let action = e.feed(Character(key))
            XCTAssertEqual(e.composed, expected, word + key)
            XCTAssertEqual(action, .passthrough, word + key)
        }
    }

    /// Sau khi đóng băng, phím dấu thanh gõ tiếp là chữ thường, dấu cũ không trôi
    /// sang đuôi; ⌫ bỏ phím vừa gõ và trả lại đúng từ cũ.
    func testKeptToneTailAndBackspace() {
        var e = configuredEngine()
        type("dduowcju", &e)
        XCTAssertEqual(e.feed("j"), .passthrough)
        XCTAssertEqual(e.composed, "đượcuj")
        _ = e.backspace()
        _ = e.backspace()
        XCTAssertEqual(e.composed, "được")
        // Gõ lại 'u' sau ⌫: cùng kết quả như gõ thẳng.
        XCTAssertEqual(e.feed("u"), .passthrough)
        XCTAssertEqual(e.composed, "đượcu")
    }

    /// VNI áp dụng cùng quy tắc: số dấu thanh không bị trả về chữ số thô.
    func testVNIKeepsToneOnMarkedWord() {
        var e = TelexEngine()
        e.vniMode = true
        e.liveSpellCheck = true
        type("d9u7o7c5", &e)
        XCTAssertEqual(e.composed, "được")
        XCTAssertEqual(e.feed("u"), .passthrough)
        XCTAssertEqual(e.composed, "đượcu")
    }
}
