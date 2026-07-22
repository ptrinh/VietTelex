import XCTest
@testable import VietTelex

final class ShortcutImporterTests: XCTestCase {

    private func parse(_ s: String) -> [String: String]? {
        ShortcutImporter.parse(Data(s.utf8))
    }

    func testGonhanhTxtFormat() {
        let txt = """
        ;Gõ Nhanh - Bảng gõ tắt
        vn:Việt Nam
        tphcm:Thành phố Hồ Chí Minh
        đc:được
        camp:campaign
        """
        let d = parse(txt)
        XCTAssertEqual(d?["vn"], "Việt Nam")
        XCTAssertEqual(d?["tphcm"], "Thành phố Hồ Chí Minh")
        XCTAssertEqual(d?["đc"], "được")     // Unicode keys survive
        XCTAssertEqual(d?.count, 4)          // comment line skipped
    }

    func testFlatYaml() {
        let yaml = """
        # bảng gõ tắt
        vn: Việt Nam
        hn: 'Hà Nội'
        hcm: "Hồ Chí Minh"
        """
        let d = parse(yaml)
        XCTAssertEqual(d?["vn"], "Việt Nam")
        XCTAssertEqual(d?["hn"], "Hà Nội")   // quotes stripped
        XCTAssertEqual(d?["hcm"], "Hồ Chí Minh")
    }

    func testPlistAndJson() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>vn</key><string>Việt Nam</string></dict></plist>
        """
        XCTAssertEqual(parse(plist)?["vn"], "Việt Nam")
        XCTAssertEqual(parse(#"{"vn": "Việt Nam"}"#)?["vn"], "Việt Nam")
    }

    func testValueWithColonsAndJunk() {
        // only the FIRST colon splits — URLs in values survive
        let d = parse("web:https://ptrinh.github.io/viettelex\n:no-key\nnovalue:\nplain line")
        XCTAssertEqual(d?["web"], "https://ptrinh.github.io/viettelex")
        XCTAssertEqual(d?.count, 1)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("just some prose without any pairs"))
    }
}
