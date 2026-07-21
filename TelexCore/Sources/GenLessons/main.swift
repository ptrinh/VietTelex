// gen-lessons — sinh docs/learn/lessons.json từ TelexEngine THẬT.
//
// Mỗi item bài học được author bằng CHUỖI PHÍM telex; generator chạy engine
// để lấy trạng thái render sau từng phím + chữ cuối cùng, và FAIL CỨNG nếu
// chữ cuối không khớp kỳ vọng — bài học không bao giờ lệch hành vi bộ gõ.
//
// Chạy:  cd TelexCore && swift run gen-lessons ../docs/learn/lessons.json

import Foundation
import TelexCore

// MARK: - Engine driver

/// Render states after each key, using the app's default settings
/// (full Telex + free marking ON — the 1.3.3 defaults).
func trace(_ keys: String, free: Bool = true) -> (states: [String], final: String) {
    var e = TelexEngine()
    e.freeMarking = free
    var states: [String] = []
    for ch in keys {
        _ = e.feed(ch)
        states.append(e.composed)
    }
    return (states, e.composed)
}

// MARK: - Model

struct Item: Codable {
    var k: String          // key sequence to type
    var d: String          // final rendered word
    var s: [String]        // render state after each key
    var post: String?      // literal key(s) after the word (space, punctuation)
    var a: String?         // illustration emoji (vocabulary aid) — nil if ambiguous
}

struct Lesson: Codable {
    var id: String
    var title: String
    var intro: String      // one-line coaching text shown above the drill
    var type: String       // "info" | "drill" | "words" | "sentence" | "test"
    var items: [Item]
    var speak: String?     // full sentence for TTS (sentence lessons)
    var newKeys: [String]? // keys introduced (highlighted on the keyboard)
    var titleEN: String?   // English UI variant
    var introEN: String?
    var art: String?       // lesson-level illustration (sentence meaning)
}

struct Chapter: Codable {
    var id: String
    var icon: String
    var title: String
    var titleEN: String?
    var lessons: [Lesson]
}

// MARK: - Authoring helpers

/// Hình minh họa từ vựng (emoji) — chỉ những từ nghĩa rõ ràng, một nghĩa nổi trội.
let wordArt: [String: String] = [
    "đi": "🚶", "đo": "📏", "đen": "⚫", "đau": "🤕",
    "cân": "⚖️", "lâu": "⏳", "mây": "☁️",
    "tên": "🏷️", "đêm": "🌙", "cô": "👩‍🏫", "ông": "👴", "thôn": "🏘️", "không": "🚫",
    "ăn": "🍚", "năm": "🖐️", "trăng": "🌕", "bơ": "🧈", "thư": "✉️",
    "mưa": "🌧️", "thương": "❤️", "người": "🧑",
    "má": "👩", "lá": "🍃", "cá": "🐟", "sáng": "🌅", "núi": "⛰️", "bánh": "🍰",
    "bà": "👵", "làng": "🏘️", "nhà": "🏠", "trời": "☀️",
    "nhỏ": "🤏", "ngủ": "😴", "hỏi": "❓",
    "mũi": "👃", "nghĩ": "🤔", "ngã": "🤸",
    "mạ": "🌾", "đẹp": "🌸", "mệt": "😮‍💨", "học": "📚", "chuyện": "💬",
    "ma": "👻", "mả": "🪦",
    "việt": "🇻🇳", "chào": "👋", "ơn": "🙏",
    "em": "🧒", "con": "👶", "xanh": "💚",
    "mẹ": "👩", "ba": "👨", "cam": "🍊", "cơm": "🍚",
    "dấu": "✏️", "trường": "🏫", "đường": "🛣️",
    "yêu": "❤️", "vui": "😄", "giỏi": "🏆",
    "đa": "🌳", "mơ": "💭", "mã": "🐎", "lão": "👴", "họ": "👨‍👩‍👧‍👦", "được": "👍",
    "xin": "🙏", "sinh": "🧑‍🎓", "hai": "✌️", "im": "🤫", "an": "🕊️", "anh": "👦",
    "tư": "4️⃣", "thân": "🤗", "gõ": "⌨️", "thật": "💯", "ngày": "📅", "một": "1️⃣",
    "chúc": "🎉", "bạn": "🧑‍🤝‍🧑", "làm": "💼", "cha": "👨", "nước": "💧",
    "nguồn": "⛲", "chảy": "🌊", "tiếng": "🗣️", "cùng": "🤝", "quá": "😍"
]


nonisolated(unsafe) var failures: [String] = []

/// One word item: author the telex keys and the EXPECTED final render.
func w(_ keys: String, _ expect: String, post: String? = " ") -> Item {
    let t = trace(keys)
    if t.final != expect {
        failures.append("\(keys) → \(t.final) (expected \(expect))")
    }
    return Item(k: keys, d: t.final, s: t.states, post: post, a: wordArt[expect.lowercased()])
}

/// Raw drill item (no telex semantics — home-row practice etc.).
func raw(_ keys: String, post: String? = " ") -> Item {
    var states: [String] = []
    var acc = ""
    for ch in keys { acc.append(ch); states.append(acc) }
    return Item(k: keys, d: keys, s: states, post: post, a: nil)
}

/// A sentence: list of word items; the joined displays become the TTS text.
func sentence(_ words: [Item], end: String = "") -> ([Item], String) {
    var items = words
    if !end.isEmpty {
        items[items.count - 1].post = end + " "
    } else {
        items[items.count - 1].post = nil
    }
    let text = words.map(\.d).joined(separator: " ") + end
    return (items, text)
}

func lesson(_ id: String, _ title: String, _ intro: String, en: (String, String)? = nil,
            type: String = "words", newKeys: [String]? = nil, _ items: [Item]) -> Lesson {
    var its = items
    if let last = its.indices.last { its[last].post = nil }   // no trailing space
    return Lesson(id: id, title: title, intro: intro, type: type, items: its,
                  speak: nil, newKeys: newKeys, titleEN: en?.0, introEN: en?.1, art: nil)
}

func sentenceLesson(_ id: String, _ title: String, _ intro: String,
                    newKeys: [String]? = nil, art: String? = nil, en: (String, String)? = nil,
                    _ parts: [([Item], String)], type: String = "sentence") -> Lesson {
    var items: [Item] = []
    var texts: [String] = []
    for (i, p) in parts.enumerated() {
        var ws = p.0
        if i < parts.count - 1, ws[ws.count - 1].post == nil {
            ws[ws.count - 1].post = " "
        }
        items.append(contentsOf: ws)
        texts.append(p.1)
    }
    if let last = items.indices.last, items[last].post == " " { items[last].post = nil }
    return Lesson(id: id, title: title, intro: intro, type: type, items: items,
                  speak: texts.joined(separator: " "), newKeys: newKeys,
                  titleEN: en?.0, introEN: en?.1, art: art)
}

// MARK: - Curriculum

let chapters: [Chapter] = [

    // ───────────────────────── Chương 0: Làm quen ─────────────────────────
    Chapter(id: "c0", icon: "🖐️", title: "Làm quen bàn phím", titleEN: "Meet the keyboard", lessons: [
        Lesson(id: "c0l1", title: "Tư thế & đặt tay", intro: "info", type: "info",
               items: [], speak: nil, newKeys: nil,
               titleEN: "Posture & hand position", introEN: "info", art: nil),
        lesson("c0l2", "Hàng phím chính", "Đặt ngón trỏ lên F và J (có gờ nổi). Mỗi ngón một phím, gõ xong quay về chỗ cũ.", en: ("Home row", "Put your index fingers on F and J (feel the bumps). One finger per key, then return home."),
               type: "drill", newKeys: ["f","j","d","k","s","l","a",";"], [
            raw("ff"), raw("jj"), raw("fj"), raw("jf"),
            raw("dd"), raw("kk"), raw("dk"), raw("ss"), raw("ll"),
            raw("aa"), raw("fad"), raw("jak"), raw("lads"), raw("salad")
        ]),
        lesson("c0l3", "Hàng trên", "Ngón với lên hàng trên rồi QUAY VỀ hàng chính. Mắt nhìn màn hình, không nhìn phím.", en: ("Top row", "Reach up, then RETURN to the home row. Eyes on the screen, not the keys."),
               type: "drill", newKeys: ["q","w","e","r","t","y","u","i","o","p"], [
            raw("ee"), raw("ii"), raw("oo"), raw("uu"), raw("tt"),
            raw("tie"), raw("toe"), raw("rot"), raw("pie"), raw("quit"), raw("your")
        ]),
        lesson("c0l4", "Hàng dưới", "Hàng dưới dùng nhiều cho tiếng Việt: V, N, M, C. Gõ chậm mà đúng, tốc độ đến sau.", en: ("Bottom row", "Vietnamese uses V, N, M, C a lot. Slow and accurate first — speed comes later."),
               type: "drill", newKeys: ["z","x","c","v","b","n","m"], [
            raw("vv"), raw("nn"), raw("mm"), raw("cc"), raw("bb"),
            raw("van"), raw("cam"), raw("nam"), raw("bam"), raw("mixv", post: nil)
        ]),
    ]),

    // ───────────────────── Chương 1: Từ không dấu ─────────────────────
    Chapter(id: "c1", icon: "🌱", title: "Từ không dấu", titleEN: "Words without marks", lessons: [
        lesson("c1l1", "Từ hai chữ", "Từ tiếng Việt thật, chưa cần dấu. Gõ xong một từ, gõ DẤU CÁCH để sang từ tiếp.", en: ("Two-letter words", "Real Vietnamese words, no diacritics yet. Press SPACE to move to the next word."), [
            w("an", "an"), w("em", "em"), w("ai", "ai"), w("ta", "ta"),
            w("me", "me"), w("be", "be"), w("bo", "bo"), w("ca", "ca"), w("im", "im")
        ]),
        lesson("c1l2", "Từ ba, bốn chữ", "Vẫn chưa cần dấu — luyện cho tay quen đường đi giữa các phím.", en: ("Longer words", "Still no diacritics — build muscle memory between keys."), [
            w("con", "con"), w("ban", "ban"), w("nam", "nam"), w("anh", "anh"),
            w("minh", "minh"), w("thanh", "thanh"), w("trong", "trong"), w("xanh", "xanh")
        ]),
        sentenceLesson("c1l3", "Câu đầu tiên", "Câu hoàn chỉnh đầu tiên của bạn! Gõ từng từ, cách nhau bằng dấu cách.", art: "🍚🧒", en: ("Your first sentence", "A full sentence! Type each word, separated by spaces."), [
            sentence([w("em", "em"), w("an", "an"), w("com", "com")]),
            sentence([w("ba", "ba"), w("hai", "hai"), w("cam", "cam")]),
        ]),
    ]),

    // ──────────────────── Chương 2: Chữ đặc biệt ────────────────────
    Chapter(id: "c2", icon: "✨", title: "Chữ đặc biệt: â ê ô ă ơ ư đ", titleEN: "Special letters: â ê ô ă ơ ư đ", lessons: [
        lesson("c2l1", "dd → đ", "Gõ d HAI LẦN để ra chữ đ. Nhìn chữ biến đổi ngay khi bạn gõ!", en: ("dd → đ", "Type d TWICE to get đ. Watch the letter transform as you type!"),
               newKeys: ["d"], [
            w("ddi", "đi"), w("dda", "đa"), w("ddo", "đo"),
            w("dden", "đen"), w("ddem", "đem"), w("ddau", "đau")
        ]),
        lesson("c2l2", "aa → â", "Gõ a hai lần để ra â. Ví dụ: caan → cân.", en: ("aa → â", "Type a twice to get â. Example: caan → cân."),
               newKeys: ["a"], [
            w("aan", "ân"), w("caan", "cân"), w("laau", "lâu"),
            w("maay", "mây"), w("thaan", "thân"), w("nhaan", "nhân")
        ]),
        lesson("c2l3", "ee → ê, oo → ô", "Cùng một luật: gõ đôi nguyên âm. teen → tên, coo → cô.", en: ("ee → ê, oo → ô", "Same rule: double the vowel. teen → tên, coo → cô."),
               newKeys: ["e","o"], [
            w("ee", "ê"), w("teen", "tên"), w("ddeem", "đêm"), w("beenh", "bênh"),
            w("coo", "cô"), w("oong", "ông"), w("thoon", "thôn"), w("khoong", "không")
        ]),
        lesson("c2l4", "Phím w: ă ơ ư", "Phím w là phím thần kỳ: aw → ă, ow → ơ, uw → ư, và w một mình → ư.", en: ("The w key: ă ơ ư", "w is the magic key: aw → ă, ow → ơ, uw → ư, and w alone → ư."),
               newKeys: ["w"], [
            w("awn", "ăn"), w("nawm", "năm"), w("trawng", "trăng"),
            w("bow", "bơ"), w("mow", "mơ"), w("tuw", "tư"), w("thuw", "thư"), w("wa", "ưa")
        ]),
        lesson("c2l5", "Trộn tất cả", "Một từ có thể cần nhiều phép biến: thuwowng → thương (ư rồi ơ).", en: ("Mix it all", "One word can need several transforms: thuwowng → thương (ư then ơ)."), [
            w("ddeem", "đêm"), w("caan", "cân"), w("oong", "ông"), w("awn", "ăn"),
            w("muwa", "mưa"), w("thuwowng", "thương"), w("dduwowng", "đương"), w("nguwowif", "người")
        ]),
    ]),

    // ───────────────────── Chương 3: Thanh điệu ─────────────────────
    Chapter(id: "c3", icon: "🎵", title: "Thanh điệu: sắc huyền hỏi ngã nặng", titleEN: "The five tones", lessons: [
        lesson("c3l1", "s → sắc (´)", "Gõ hết chữ rồi gõ s để thêm dấu sắc: mas → má.", en: ("s → rising tone (´)", "Finish the word, then press s for the rising tone: mas → má."),
               newKeys: ["s"], [
            w("mas", "má"), w("las", "lá"), w("cas", "cá"),
            w("sangs", "sáng"), w("nuis", "núi"), w("banhs", "bánh")
        ]),
        lesson("c3l2", "f → huyền (`)", "Phím f cho dấu huyền: maf → mà.", en: ("f → falling tone (`)", "The f key adds the falling tone: maf → mà."),
               newKeys: ["f"], [
            w("maf", "mà"), w("laf", "là"), w("baf", "bà"),
            w("langf", "làng"), w("nhaf", "nhà"), w("trowif", "trời")
        ]),
        lesson("c3l3", "r → hỏi (ˀ)", "Phím r cho dấu hỏi: har → hả.", en: ("r → asking tone (ˀ)", "The r key adds the asking tone: har → hả."),
               newKeys: ["r"], [
            w("har", "hả"), w("car", "cả"), w("nhor", "nhỏ"),
            w("ngur", "ngủ"), w("hoir", "hỏi"), w("cuar", "của")
        ]),
        lesson("c3l4", "x → ngã (~)", "Phím x cho dấu ngã: max → mã.", en: ("x → tumbling tone (~)", "The x key adds the tumbling tone: max → mã."),
               newKeys: ["x"], [
            w("max", "mã"), w("cux", "cũ"), w("ngax", "ngã"),
            w("muxi", "mũi"), w("laxo", "lão"), w("nghix", "nghĩ")
        ]),
        lesson("c3l5", "j → nặng (.)", "Phím j cho dấu nặng: maj → mạ.", en: ("j → heavy tone (.)", "The j key adds the heavy tone: maj → mạ."),
               newKeys: ["j"], [
            w("maj", "mạ"), w("hoj", "họ"), w("ddepj", "đẹp"),
            w("meetj", "mệt"), w("hocj", "học"), w("chuyeenj", "chuyện")
        ]),
        lesson("c3l6", "Sửa dấu & xóa dấu", "Gõ thanh KHÁC để đổi dấu (más + f → mà), gõ z để xóa dấu.", en: ("Fix & remove tones", "Type a DIFFERENT tone key to change it (más + f → mà); press z to remove."),
               newKeys: ["z"], [
            w("masf", "mà"), w("lafs", "lá"), w("masz", "ma"),
            w("ngasx", "ngã"), w("hosj", "họ"), w("sangsz", "sang")
        ]),
        lesson("c3l7", "Đủ năm thanh", "Bài tổng hợp: ma má mà mả mã mạ — nghe thử từng từ nhé!", en: ("All five tones", "The full set: ma má mà mả mã mạ — try the 🔊 button on each!"), type: "test", [
            w("ma", "ma"), w("mas", "má"), w("maf", "mà"),
            w("mar", "mả"), w("max", "mã"), w("maj", "mạ"),
            w("vieejt", "việt"), w("hoas", "hóa"), w("dduwowcj", "được")
        ]),
    ]),

    // ───────────────────── Chương 4: Từ & câu ─────────────────────
    Chapter(id: "c4", icon: "💬", title: "Từ ghép & câu", titleEN: "Words & sentences", lessons: [
        lesson("c4l1", "Từ hai âm tiết", "Tên nước mình! Chữ hoa: giữ Shift rồi gõ chữ như thường.", en: ("Two-syllable words", "Our country's name! Capitals: hold Shift and type normally."), [
            w("Vieejt", "Việt"), w("Nam", "Nam"),
            w("camr", "cảm"), w("own", "ơn"),
            w("xin", "xin"), w("chaof", "chào"),
            w("hocj", "học"), w("sinh", "sinh")
        ]),
        sentenceLesson("c4l2", "Câu chào hỏi", "Gõ cả câu — bấm 🔊 để nghe trước khi gõ.", art: "👋😊", en: ("Greetings", "Type the whole sentence — press 🔊 to hear it first."), [
            sentence([w("Xin", "Xin"), w("chaof", "chào"), w("cacs", "các"), w("banj", "bạn")], end: "!"),
            sentence([w("Chucs", "Chúc"), w("mootj", "một"), w("ngayf", "ngày"), w("vui", "vui")], end: "."),
        ]),
        sentenceLesson("c4l3", "Em yêu gia đình", "Những câu về gia đình.", art: "👨‍👩‍👧", en: ("Family sentences", "Sentences about family."), [
            sentence([w("Em", "Em"), w("yeeu", "yêu"), w("mej", "mẹ")], end: "."),
            sentence([w("Ba", "Ba"), w("ddi", "đi"), w("lamf", "làm")], end: "."),
        ]),
        sentenceLesson("c4l4", "Ca dao", "Ca dao Việt Nam — vừa gõ vừa học tiếng Việt.", art: "👨⛰️ 👩🌊", en: ("Folk verse", "Vietnamese folk verse — type and learn the language at once."), [
            sentence([w("Coong", "Công"), w("cha", "cha"), w("nhuw", "như"),
                      w("nuis", "núi"), w("Thais", "Thái"), w("Sown", "Sơn")], end: ","),
            sentence([w("Nghixa", "Nghĩa"), w("mej", "mẹ"), w("nhuw", "như"),
                      w("nuwowcs", "nước"), w("trong", "trong"), w("nguoonf", "nguồn"),
                      w("chayr", "chảy"), w("ra", "ra")], end: "."),
        ]),
    ]),

    // ───────────────────── Chương 5: Nâng cao ─────────────────────
    Chapter(id: "c5", icon: "🚀", title: "Nâng cao", titleEN: "Advanced", lessons: [
        lesson("c5l1", "Bỏ dấu tự do", "Gõ dấu MUỘN cũng được — engine tự tìm đúng nguyên âm: dauas → dấu.", en: ("Free tone placement", "Type marks LATE and the engine finds the right vowel: dauas → dấu."), [
            w("dauas", "dấu"), w("vieetj", "việt"), w("truowngf", "trường"),
            w("hocj", "học"), w("dduongwf", "đường")
        ]),
        sentenceLesson("c5l2", "Câu dài", "Câu đầy đủ dấu câu và chữ hoa.", art: "🌤️😄", en: ("Long sentences", "Full sentences with punctuation and capitals."), [
            sentence([w("Hoom", "Hôm"), w("nay", "nay"), w("trowif", "trời"),
                      w("ddepj", "đẹp"), w("quas", "quá")], end: "!"),
            sentence([w("Chungs", "Chúng"), w("ta", "ta"), w("cungf", "cùng"),
                      w("hocj", "học"), w("gox", "gõ"), w("nhes", "nhé")], end: "!"),
        ]),
        sentenceLesson("c5l3", "Thử thách cuối", "Boss cuối! Gõ trọn đoạn — đủ chữ đặc biệt, đủ năm thanh.", art: "🇻🇳⌨️", en: ("Final boss", "The final challenge — every special letter, all five tones."), [
            sentence([w("Tieengs", "Tiếng"), w("Vieejt", "Việt"), w("raats", "rất"),
                      w("hay", "hay"), w("vaf", "và"), w("ddepj", "đẹp")], end: "."),
            sentence([w("Em", "Em"), w("sex", "sẽ"), w("gox", "gõ"),
                      w("thaajt", "thật"), w("gioir", "giỏi")], end: "!"),
        ], type: "test"),
    ]),
]

// MARK: - Emit

struct Root: Codable { var version: Int; var chapters: [Chapter] }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "lessons.json"
let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys]
let data = try enc.encode(Root(version: 1, chapters: chapters))

if !failures.isEmpty {
    FileHandle.standardError.write("MISMATCHES (\(failures.count)):\n".data(using: .utf8)!)
    for f in failures { FileHandle.standardError.write("  \(f)\n".data(using: .utf8)!) }
    exit(1)
}
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) — \(chapters.count) chapters, \(chapters.flatMap(\.lessons).count) lessons")
