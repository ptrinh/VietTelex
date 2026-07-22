// gen-english — sinh bảng TỐI GIẢN các từ tiếng Anh va chạm Telex.
//
// Nguyên liệu: danh sách tiếng Anh xếp theo tần suất (google-10000-english).
// Một từ vào bảng khi VÀ CHỈ KHI hôm nay engine (cài đặt mặc định) cho ra
// kết quả KHÁC raw ở boundary — tức đúng tập từ đang bị gõ sai ("his"→hí,
// "off"→of, "class"→clas). Từ nào validator đã restore đúng thì không cần.
//
// PROTECT LIST — từ tiếng Việt mà chuỗi phím raw TRÙNG từ tiếng Anh và
// KHÔNG có cách gõ thay thế (sẽ=sex, ơn=own, tên=teen…): tiếng Việt thắng,
// loại khỏi bảng. Người gõ tiếng Anh chấp nhận miss các từ này.
//
// Chạy:  swift run gen-english <wordlist.txt> <maxWords> ../Sources/TelexCore/EnglishCollisions.swift
import Foundation
import TelexCore

/// Từ Việt phổ biến bị trùng phím với English — không bao giờ steal.
/// (raw English → từ Việt bị mất nếu restore)
let protected: Set<String> = [
    "á",    // as
    "cả",   // car
    "sẽ",   // sex
    "bên",  // been
    "ơn",   // own   (cảm ơn — ơ chỉ gõ được bằng ow)
    "tên",  // teen
    "tô",   // too
    "ít",   // its
    "lơ",   // low   (làm lơ)
    "nơ",   // now
    "hơ",   // how
    "tê",   // tee
    "rôm",  // room  (rôm rả)
    "bõ",   // box   (bõ công)
    "ải",   // air
    "bả",   // bar
    "bể",   // beer
    "bú",   // bus
    "lê",   // lee   (quả lê, họ Lê)
    "mã",   // max   (mã số)
    "môn",  // moon  (môn học)
    "rơ",   // row   (chơi rơ)
    "đi",   // did   (user 2026-07-22: free-marking did→đi thắng English "did")
    "thêm", // theme (cùng đợt: theme→thêm)
    // Đợt audit 2026-07-23 (user báo thus→thus): raw tiếng Anh trùng ĐÚNG cách
    // gõ telex chuẩn của từ Việt phổ biến → tiếng Việt thắng.
    "thú",  // thus
    "quên", // queen
    "sóng", // songs
    "chả",  // char
    "chải", // chair
    "hải",  // hair  (tên riêng Hải, hải sản)
    "lén",  // lens
    "hít",  // hits  (hít thở)
    "sét",  // sets  (sấm sét)
    "tít",  // tits  (xa tít)
    "bốt",  // boots (giày bốt)
    "lót",  // lots, lost (lót đường)
    "sên",  // seen  (ốc sên)
    "sỉ",   // sir   (mua sỉ)
    "sĩ",   // six   (bác sĩ)
    "tã",   // tax
    "úp",   // ups   (úp mở)
    "rẽ",   // res   (rẽ trái)
]

/// Rác viết tắt trong corpus web (không phải từ tiếng Anh thật) — vào bảng sẽ
/// nuốt mất cách gõ tiếng Việt (sw = sư!). Từ 2 chữ chỉ nhận whitelist.
let junk: Set<String> = ["aa", "aaa", "ar", "ee", "es", "las", "los", "der",
    "des", "mar", "os", "res", "ref", "rw", "sw", "nw", "usr", "var", "wa",
    "wi", "www", "est", "ie", "il", "ny", "ok"]
let twoLetterWhitelist: Set<String> = ["of", "if", "is", "us", "or"]

/// Từ tiếng Anh phổ biến NGOÀI top-maxWords vẫn đáng cover (chủ yếu lớp
/// double-letter bị cancel ăn mất một chữ). Đuôi 4000-10000 của corpus là
/// bãi mìn từ Việt (cos=có, gif=gì, mas=má, cow=cơ, zoo=zô…) nên KHÔNG quét
/// tự động — chỉ nhận bổ sung tay, và vẫn đi qua đủ engine-check + protect.
let extraEnglish = ["mess", "boss", "kiss", "chess", "bless", "gross",
                    "grass", "brass", "cliff", "moss", "hiss", "fuss"]

let args = CommandLine.arguments
guard args.count >= 4,
      let content = try? String(contentsOfFile: args[1], encoding: .utf8),
      let maxWords = Int(args[2]) else {
    FileHandle.standardError.write("usage: gen-english <wordlist> <maxWords> <out.swift>\n".data(using: .utf8)!)
    exit(1)
}

func commitDefault(_ word: String) -> String {
    var e = TelexEngine()
    e.freeMarking = true          // app defaults (1.3.x)
    e.englishWordRestore = false  // đo hành vi validator-thuần, bảng không tự soi mình
    for ch in word { _ = e.feed(ch) }
    return e.commitText(autoRestore: true)
}

nonisolated(unsafe) var kept: [String] = []
nonisolated(unsafe) var excluded: [(String, String)] = []
nonisolated(unsafe) var seen = Set<String>()
@MainActor func consider(_ w: String) {
    guard !seen.contains(w) else { return }
    seen.insert(w)
    let out = commitDefault(w)
    guard out != w else { return }
    if junk.contains(w) { return }
    if w.count == 2, !twoLetterWhitelist.contains(w) { return }
    if protected.contains(out) { excluded.append((w, out)); return }
    kept.append(w)
}
var n = 0
for line in content.split(separator: "\n") {
    if n >= maxWords { break }
    let w = line.trimmingCharacters(in: .whitespaces).lowercased()
    guard w.count >= 2, w.count <= 12, w.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
    n += 1
    consider(w)
}
for w in extraEnglish { consider(w) }
kept.sort()

var src = """
// EnglishCollisions.swift — SINH TỰ ĐỘNG bởi gen-english, ĐỪNG SỬA TAY.
// Từ tiếng Anh phổ biến (top-\(maxWords)) mà Telex mặc định biến thành âm tiết
// Việt hợp lệ (validator không cứu được) — force-restore ở word boundary.
// Đã loại các từ mà tiếng Việt thắng (sẽ=sex, ơn=own… — xem gen-english).
// Regenerate:  swift run gen-english google-10000-english.txt \(maxWords) \
//              Sources/TelexCore/EnglishCollisions.swift
enum EnglishCollisions {
    /// Sorted ascii, lowercase. ~\(kept.count) từ, tra Set ở boundary (không trên hot path).
    static let words: Set<String> = [
"""
for chunk in stride(from: 0, to: kept.count, by: 8) {
    let row = kept[chunk..<min(chunk + 8, kept.count)].map { "\"\($0)\"" }.joined(separator: ", ")
    src += "        " + row + ",\n"
}
src += """
    ]
}
"""
try! src.write(toFile: args[3], atomically: true, encoding: .utf8)
print("scanned \(n)  kept \(kept.count)  protected-out \(excluded.count)")
for (w, o) in excluded { print("  VN wins: \(w) → \(o)") }
