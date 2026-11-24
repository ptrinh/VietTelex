// Góp ý tester 03/11/2026 (iPhone): "gõ nhanh chữ nhảy lung tung" — gõ, ⌫ vài chữ, gõ lại ⇒
// chữ nhảy sang chữ sai; "looix" gõ nhanh ra kiểu "loôiỗi"; đôi khi tuôn ra chuỗi chữ dài;
// hay gặp ở ô có gợi ý/tự sửa/autocomplete của host. Gõ chậm thì không.
//
// Mô hình host ở đây (LagHost): proxy của bàn phím cập nhật LẠC QUAN ngay khi gửi lệnh (context
// đọc lại thấy lệnh vừa gửi), host xử lý lệnh TRỄ `lag` phím rồi đẩy trạng thái của nó về —
// trạng thái đó đè lên bản lạc quan (thiếu các phím chưa xử lý). Gõ chậm = host kịp đẩy trước
// phím kế = lag 0. Sửa: HostMirror (CompositionSync.swift) + MirroredProxy (controller).
import XCTest
import UIKit

@MainActor
final class HostDesyncTests: XCTestCase {

    final class LagHost: NSObject, UITextDocumentProxy {
        enum Op { case ins(String), del }
        /// Văn bản thật của host.
        var real = ""
        /// Bản proxy cho bàn phím đọc (lạc quan, bị host đè khi đẩy trạng thái).
        var local = ""
        var batch: [Op] = []
        var queue: [[Op]] = []

        var documentContextBeforeInput: String? { local }
        var documentContextAfterInput: String? { "" }
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        var documentIdentifier: UUID = UUID()
        func adjustTextPosition(byCharacterOffset offset: Int) {}
        func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
        func unmarkText() {}
        var hasText: Bool { !local.isEmpty }
        func insertText(_ s: String) { local += s; batch.append(.ins(s)) }
        func deleteBackward() { if !local.isEmpty { local.removeLast() }; batch.append(.del) }
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var keyboardType: UIKeyboardType = .default
        var returnKeyType: UIReturnKeyType = .default
        var keyboardAppearance: UIKeyboardAppearance = .default
        var autocorrectionType: UITextAutocorrectionType = .default

        /// Host xử lý lô lệnh cũ nhất rồi đẩy trạng thái thật (đè bản lạc quan).
        func process(_ vc: KeyboardViewController) {
            guard !queue.isEmpty else { return }
            let ops = queue.removeFirst()
            guard !ops.isEmpty else { return }
            for op in ops {
                switch op {
                case .ins(let s): real += s
                case .del: if !real.isEmpty { real.removeLast() }
                }
            }
            local = real
            vc.textWillChange(nil); vc.selectionWillChange(nil)
            vc.selectionDidChange(nil); vc.textDidChange(nil)
        }
    }

    @MainActor final class Rig {
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let vc = KeyboardViewController()
        let host = LagHost()
        let saved = UserDefaultsProvider.shared

        init() {
            UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
            win.isHidden = false
            vc.debugProxy = host
            vc.loadViewIfNeeded()
            vc.view.frame = CGRect(x: 0, y: 874 - 290, width: 402, height: 290)
            win.addSubview(vc.view)
            vc.beginAppearanceTransition(true, animated: false)
            vc.view.layoutIfNeeded()
            vc.endAppearanceTransition()
            vc.view.layoutIfNeeded()
            KeyboardBenchTests.spin(0.02)
        }

        func close() {
            vc.beginAppearanceTransition(false, animated: false)
            vc.endAppearanceTransition()
            vc.view.removeFromSuperview()
            win.isHidden = true
            UserDefaultsProvider.shared = saved
        }

        /// Gõ `keys` ("⌫" = xoá, " " = cách). Host trễ `lag` phím (0 = đồng bộ, < 0 = thất thường
        /// 0…3 phím theo `rng`).
        func type<R: RandomNumberGenerator>(_ keys: String, lag: Int, rng: inout R) {
            for c in keys {
                switch c {
                case "⌫": vc.debugHandle(.backspace)
                case " ": vc.debugHandle(.space)
                default: vc.debugHandle(.letter(c))
                }
                host.queue.append(host.batch)
                host.batch = []
                if lag < 0 {
                    var n = Int.random(in: 0...2, using: &rng)
                    while n > 0 || host.queue.count > 3 { host.process(vc); n -= 1 }
                } else {
                    while host.queue.count > lag { host.process(vc) }
                }
                KeyboardBenchTests.spin(0.002)
            }
            while !host.queue.isEmpty { host.process(vc) }
        }
    }

    /// Bộ sinh số giả ngẫu nhiên có hạt giống (fuzz lặp lại được).
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func run(_ keys: String, lag: Int, seed: UInt64 = 1) -> String {
        let rig = Rig()
        defer { rig.close() }
        var rng = SplitMix(state: seed)
        rig.type(keys, lag: lag, rng: &rng)
        return rig.host.real
    }

    /// Hồi quy góp ý tester: trước sửa (host trễ 1–3 phím) "looix" ⇒ "looix"/"lôõ"/"lôix",
    /// "xin chaof ⌫⌫⌫aof banj" ⇒ "xin chaò baạ", "tooi ddi hocj" ⇒ "tooi ddi hoọ",
    /// "vieetj⌫⌫⌫eetj" ⇒ "viịt", "hello world vieetj" ⇒ "hello world vieịe".
    func testLateHostTypesSameAsSyncHost() {
        let cases: [(String, String)] = [
            ("looix ", "lỗi "),
            ("tooi ddi hocj ", "tôi đi học "),
            ("xin chaof ⌫⌫⌫aof banj ", "xin chào bạn "),
            ("vieetj⌫⌫⌫eetj nam ", "vệt nam "),
            ("hello world vieetj nam ", "hello world việt nam "),
            ("check mail ddi nhaf ", "check mail đi nhà "),
        ]
        for (keys, want) in cases {
            XCTAssertEqual(run(keys, lag: 0), want, "host đồng bộ: \(keys)")
            for lag in 1...3 {
                XCTAssertEqual(run(keys, lag: lag), want, "host trễ \(lag) phím: \(keys)")
            }
        }
    }

    /// ⌫ tới ô trống rồi gõ tiếp khi host trễ: ô trống do chính ⌫ của mình là tiếng vọng (trước
    /// sửa: bản sao mất dấu ⇒ cả câu sau ra rác "haf theé check theé mail looõ").
    func testEmptiedFieldThenTypeUnderLag() {
        let keys = "nhaf⌫⌫⌫haf thees check thees mail looix "
        let want = "hà thế check thế mail lỗi "
        XCTAssertEqual(run(keys, lag: 0), want)
        for lag in 1...3 { XCTAssertEqual(run(keys, lag: lag), want, "host trễ \(lag) phím") }
    }

    /// Fuzz: câu Việt/Anh trộn, có ⌫ giữa từ; host trễ cố định hoặc thất thường ⇒ chữ ra phải
    /// y hệt host đồng bộ. VT_FUZZ_N = số câu (mặc định 15).
    func testFuzzLateHost() {
        var rng = SplitMix(state: 20261103)
        let words = ["vieetj", "tooi", "ddi", "hocj", "looix", "chaof", "banj", "nguowif", "hello", "world",
                     "check", "mail", "file", "nhaf", "khoong", "dduowcj", "phair", "thees", "naof", "tieengs"]
        let n = Int(ProcessInfo.processInfo.environment["VT_FUZZ_N"] ?? "") ?? 15
        for t in 0..<n {
            var keys = t % 5 == 0 ? "nhaf⌫⌫⌫" : ""
            for _ in 0..<6 {
                var w = words.randomElement(using: &rng)!
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    let k = Int.random(in: 1...3, using: &rng)
                    w += String(repeating: "⌫", count: k) + String(w.suffix(k))
                }
                keys += w + " "
            }
            let ref = run(keys, lag: 0)
            for lag in [-1, 1, 2, 3] {
                XCTAssertEqual(run(keys, lag: lag, seed: UInt64(t + 1)), ref, "host trễ \(lag): \(keys)")
            }
        }
    }

    // MARK: HostMirror (thuần)

    /// Trạng thái lặp lại ("xin chào" trước dấu cách và sau ⌫ dấu cách): khớp ảnh mới nhất chưa
    /// chắc host đã đuổi kịp — ảnh SỚM nhất khớp thắng, các ảnh ở giữa còn giữ.
    func testMirrorRepeatedStateIsStillEcho() {
        var m = HostMirror()
        m.willEdit(read: { "xin cha" })
        m.deletedBackward(now: 0); m.inserted("ào", now: 0)      // "xin chào"
        m.inserted(" ", now: 0.05)                               // "xin chào "
        m.deletedBackward(now: 0.1)                              // ⌫ ⇒ "xin chào"
        XCTAssertEqual(m.hostReported("xin chào", now: 0.15), "xin chào")
        XCTAssertTrue(m.lagging, "khớp ảnh cũ hơn ⇒ còn trễ")
        XCTAssertEqual(m.hostReported("xin chào ", now: 0.2), "xin chào", "ảnh ở giữa vẫn nhận ra")
        XCTAssertTrue(m.lagging)
        XCTAssertEqual(m.hostReported("xin chào", now: 0.25), "xin chào")
        XCTAssertFalse(m.lagging, "đuổi kịp")
    }

    /// Ô trống: do chính ⌫ của mình ⇒ tiếng vọng; ô trống ban đầu (host báo) ⇒ host xoá ô là thật.
    func testMirrorEmptyFieldOwnDeleteVsHostClear() {
        var m = HostMirror()
        m.willEdit(read: { "ab" })
        m.deletedBackward(now: 0); m.deletedBackward(now: 0)
        m.inserted("h", now: 0.05)
        XCTAssertEqual(m.hostReported("", now: 0.1), "h", "ô trống do ⌫ của mình")
        XCTAssertTrue(m.lagging)

        var c = HostMirror()
        c.willEdit(read: { "" })
        c.inserted("o", now: 0); c.inserted("k", now: 0.05)
        XCTAssertEqual(c.hostReported("", now: 0.1), "", "host xoá ô (gửi tin)")
        XCTAssertFalse(c.lagging)
    }
}

/// Host trả `documentIdentifier` nil (khai báo non-null): đọc phải ra nil chứ không sập.
final class ProxyDocumentIDTests: XCTestCase {
    final class NilIDHost: NSObject {
        @objc var documentIdentifier: NSUUID? { nil }
    }
    final class NoIDHost: NSObject {}

    func testNilIdentifierReadsAsNil() {
        XCTAssertNil(ProxyDocumentID.read(NilIDHost()))
        XCTAssertNil(MirroredProxy { unsafeBitCast(NilIDHost(), to: UITextDocumentProxy.self) }.documentID)
    }

    func testMissingPropertyReadsAsNil() {
        XCTAssertNil(ProxyDocumentID.read(NoIDHost()), "KVC ném NSException ⇒ nil")
    }

    func testRealIdentifierPassesThrough() {
        let host = KeyboardBenchTests.BenchProxy()
        XCTAssertEqual(ProxyDocumentID.read(host), host.documentIdentifier)
        XCTAssertEqual(MirroredProxy { host }.documentIdentifier, host.documentIdentifier)
    }
}
