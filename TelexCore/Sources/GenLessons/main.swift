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
    "nguồn": "⛲", "chảy": "🌊", "tiếng": "🗣️", "cùng": "🤝", "quá": "😍",
    "rồng": "🐉", "rùa": "🐢", "voi": "🐘", "ngựa": "🐴", "lửa": "🔥",
    "gươm": "⚔️", "trứng": "🥚", "đất": "🌍", "tết": "🧧", "áo": "👕",
    "trẻ": "🧒", "tiên": "🧚", "hồ": "💧", "vua": "👑", "bay": "🕊️"
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
            w("muix", "mũi"), w("laox", "lão"), w("nghix", "nghĩ")
        ]),
        lesson("c3l5", "j → nặng (.)", "Phím j cho dấu nặng: maj → mạ.", en: ("j → heavy tone (.)", "The j key adds the heavy tone: maj → mạ."),
               newKeys: ["j"], [
            w("maj", "mạ"), w("hoj", "họ"), w("ddepj", "đẹp"),
            w("meetj", "mệt"), w("hocj", "học"), w("chuyeenj", "chuyện")
        ]),
        lesson("c3l7", "Đủ năm thanh", "Bài tổng hợp: ma má mà mả mã mạ — nghe thử từng từ nhé!", en: ("All five tones", "The full set: ma má mà mả mã mạ — try the 🔊 button on each!"), type: "test", [
            w("ma", "ma"), w("mas", "má"), w("maf", "mà"),
            w("mar", "mả"), w("max", "mã"), w("maj", "mạ"),
            w("vieetj", "việt"), w("hoas", "hóa"), w("dduwowcj", "được")
        ]),
    ]),

    // ───────────────────── Chương 4: Từ & câu ─────────────────────
    Chapter(id: "c4", icon: "💬", title: "Từ ghép & câu", titleEN: "Words & sentences", lessons: [
        lesson("c4l1", "Từ hai âm tiết", "Tên nước mình! Chữ hoa: giữ Shift rồi gõ chữ như thường.", en: ("Two-syllable words", "Our country's name! Capitals: hold Shift and type normally."), [
            w("Vieetj", "Việt"), w("Nam", "Nam"),
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
            sentence([w("Nghiax", "Nghĩa"), w("mej", "mẹ"), w("nhuw", "như"),
                      w("nuwowcs", "nước"), w("trong", "trong"), w("nguoonf", "nguồn"),
                      w("chayr", "chảy"), w("ra", "ra")], end: "."),
        ]),
    ]),

    // ───────────────────── Chương 5: Nâng cao ─────────────────────
    Chapter(id: "c5", icon: "🚀", title: "Nâng cao", titleEN: "Advanced", lessons: [
        lesson("c5l1", "Gõ chuẩn Telex", "Dấu mũ gõ LIỀN nguyên âm, thanh gõ cuối từ: daaus → dấu (aa liền nhau, s ở cuối).", en: ("Canonical Telex order", "Vowel marks go RIGHT AFTER the vowel, tones at the end: daaus → dấu."), [
            w("daaus", "dấu"), w("vieetj", "việt"), w("truwowngf", "trường"),
            w("hocj", "học"), w("dduwowngf", "đường")
        ]),
        sentenceLesson("c5l2", "Câu dài", "Câu đầy đủ dấu câu và chữ hoa.", art: "🌤️😄", en: ("Long sentences", "Full sentences with punctuation and capitals."), [
            sentence([w("Hoom", "Hôm"), w("nay", "nay"), w("trowif", "trời"),
                      w("ddepj", "đẹp"), w("quas", "quá")], end: "!"),
            sentence([w("Chungs", "Chúng"), w("ta", "ta"), w("cungf", "cùng"),
                      w("hocj", "học"), w("gox", "gõ"), w("nhes", "nhé")], end: "!"),
        ]),
        sentenceLesson("c5l3", "Thử thách cuối", "Boss cuối! Gõ trọn đoạn — đủ chữ đặc biệt, đủ năm thanh.", art: "🇻🇳⌨️", en: ("Final boss", "The final challenge — every special letter, all five tones."), [
            sentence([w("Tieengs", "Tiếng"), w("Vieetj", "Việt"), w("raats", "rất"),
                      w("hay", "hay"), w("vaf", "và"), w("ddepj", "đẹp")], end: "."),
            sentence([w("Em", "Em"), w("sex", "sẽ"), w("gox", "gõ"),
                      w("thaatj", "thật"), w("gioir", "giỏi")], end: "!"),
        ], type: "test"),
    ]),

    // ───────────────── Chương 6: Nâng cao 2 — Chuyện kể ─────────────────
    Chapter(id: "c6", icon: "📖", title: "Nâng cao 2: Chuyện kể", titleEN: "Advanced 2: Little stories", lessons: [
        sentenceLesson("c6l1", "Con Rồng cháu Tiên", "Truyền thuyết về nguồn gốc người Việt — gõ từng câu nhé.", art: "🐉🧚", en: ("Dragon and Fairy", "The legend of the Vietnamese origin — type it sentence by sentence."), [
            sentence([w("Mej", "Mẹ"), w("AAu", "Âu"), w("Cow", "Cơ"), w("sinh", "sinh"),
                      w("trawm", "trăm"), w("truwngs", "trứng")], end: "."),
            sentence([w("Nguwowif", "Người"), w("Vieetj", "Việt"), w("laf", "là"), w("con", "con"),
                      w("Roongf", "Rồng"), w("chaus", "cháu"), w("Tieen", "Tiên")], end: "."),
        ]),
        sentenceLesson("c6l2", "Sự tích bánh chưng", "Vì sao Tết có bánh chưng vuông?", art: "🎍🟩", en: ("Banh chung legend", "Why square banh chung at Tet?"), [
            sentence([w("Lang", "Lang"), w("Lieeu", "Liêu"), w("lamf", "làm"),
                      w("banhs", "bánh"), w("chuwng", "chưng"), w("vuoong", "vuông")], end: "."),
            sentence([w("Banhs", "Bánh"), w("tuwowngj", "tượng"), w("truwng", "trưng"),
                      w("cho", "cho"), w("ddaats", "đất")], end: "."),
            sentence([w("Vua", "Vua"), w("cha", "cha"), w("raats", "rất"),
                      w("haif", "hài"), w("longf", "lòng")], end: "."),
        ]),
        sentenceLesson("c6l3", "Sự tích Hồ Gươm", "Chuyện vua Lê và rùa vàng giữa lòng Hà Nội.", art: "🐢⚔️", en: ("Sword Lake legend", "King Le and the golden turtle in Hanoi."), [
            sentence([w("Vua", "Vua"), w("Lee", "Lê"), w("trar", "trả"), w("guwowm", "gươm"),
                      w("cho", "cho"), w("ruaf", "rùa"), w("vangf", "vàng")], end: "."),
            sentence([w("Hoof", "Hồ"), w("aays", "ấy"), w("teen", "tên"),
                      w("laf", "là"), w("Hoof", "Hồ"), w("Guwowm", "Gươm")], end: "."),
        ]),
    ]),

    // ─────────────── Chương 7: Nâng cao 3 — Truyện lịch sử ───────────────
    Chapter(id: "c7", icon: "🏯", title: "Nâng cao 3: Truyện lịch sử", titleEN: "Advanced 3: History tales", lessons: [
        sentenceLesson("c7l1", "Thánh Gióng", "Cậu bé làng Gióng vươn vai thành tráng sĩ.", art: "🐴🔥", en: ("Saint Giong", "The boy of Giong village who grew into a warrior."), [
            sentence([w("Giongs", "Gióng"), w("vuwown", "vươn"), w("vai", "vai"),
                      w("thanhf", "thành"), w("trangs", "tráng"), w("six", "sĩ")], end: "."),
            sentence([w("Nguwaj", "Ngựa"), w("sawts", "sắt"), w("phun", "phun"),
                      w("luwar", "lửa"), w("xoong", "xông"), w("ra", "ra"), w("traanj", "trận")], end: "."),
            sentence([w("DDanhs", "Đánh"), w("tan", "tan"), w("giawcj", "giặc"), w("Giongs", "Gióng"),
                      w("bay", "bay"), w("veef", "về"), w("trowif", "trời")], end: "."),
        ]),
        sentenceLesson("c7l2", "Hai Bà Trưng", "Hai nữ anh hùng đầu tiên của nước ta.", art: "🐘⚔️", en: ("The Trung Sisters", "Our first heroines."), [
            sentence([w("Hai", "Hai"), w("Baf", "Bà"), w("Truwng", "Trưng"), w("cuwowix", "cưỡi"),
                      w("voi", "voi"), w("ddanhs", "đánh"), w("giawcj", "giặc")], end: "."),
            sentence([w("Car", "Cả"), w("nuwowcs", "nước"), w("theo", "theo"), w("hai", "hai"),
                      w("baf", "bà"), w("dduwngs", "đứng"), w("leen", "lên")], end: "."),
            sentence([w("DDos", "Đó"), w("laf", "là"), w("nhuwngx", "những"), w("nuwx", "nữ"),
                      w("anh", "anh"), w("hungf", "hùng"), w("ddaauf", "đầu"), w("tieen", "tiên"),
                      w("cuar", "của"), w("nuwowcs", "nước"), w("ta", "ta")], end: "."),
        ]),
        sentenceLesson("c7l3", "Tết Việt Nam", "Boss cuối cùng: gõ trọn câu chuyện ngày Tết!", art: "🧧🎆", en: ("Vietnamese Tet", "The final boss: type the whole Tet story!"), [
            sentence([w("Teets", "Tết"), w("ddeens", "đến"), w("nhaf", "nhà"), w("nhaf", "nhà"),
                      w("gois", "gói"), w("banhs", "bánh"), w("chuwng", "chưng")], end: "."),
            sentence([w("Trer", "Trẻ"), w("em", "em"), w("mawcj", "mặc"), w("aos", "áo"),
                      w("mowis", "mới"), w("nhaanj", "nhận"), w("lif", "lì"), w("xif", "xì")], end: "."),
            sentence([w("Moij", "Mọi"), w("nguwowif", "người"), w("chucs", "chúc"), w("nhau", "nhau"),
                      w("nawm", "năm"), w("mowis", "mới"), w("an", "an"), w("lanhf", "lành")], end: "."),
        ], type: "test"),
    ]),
]


// MARK: - Kite-game vocabulary (docs/learn/lessons/kite.html)

struct GameWord: Codable { var k: String; var d: String; var s: [String]; var a: String }

func gw(_ keys: String, _ expect: String, _ emoji: String) -> GameWord {
    let t = trace(keys)
    if t.final != expect { failures.append("game \(keys) → \(t.final) (expected \(expect))") }
    return GameWord(k: keys, d: t.final, s: t.states, a: emoji)
}

let gameWords: [GameWord] = [
    gw("meof", "mèo", "🐈"), gw("chos", "chó", "🐕"), gw("gaf", "gà", "🐔"),
    gw("vitj", "vịt", "🦆"), gw("cas", "cá", "🐟"), gw("bof", "bò", "🐄"),
    gw("voi", "voi", "🐘"), gw("hoor", "hổ", "🐯"), gw("gaaus", "gấu", "🐻"),
    gw("thor", "thỏ", "🐰"), gw("khir", "khỉ", "🐒"), gw("eechs", "ếch", "🐸"),
    gw("ruaf", "rùa", "🐢"), gw("ong", "ong", "🐝"), gw("buwowms", "bướm", "🦋"),
    gw("chim", "chim", "🐦"), gw("hoa", "hoa", "🌸"), gw("caay", "cây", "🌳"),
    gw("las", "lá", "🍃"), gw("nhaf", "nhà", "🏠"), gw("xe", "xe", "🚗"),
    gw("thuyeenf", "thuyền", "⛵"), gw("sachs", "sách", "📚"), gw("bongs", "bóng", "⚽"),
    gw("mux", "mũ", "👒"), gw("kem", "kem", "🍦"), gw("taos", "táo", "🍎"),
    gw("chuoois", "chuối", "🍌"), gw("duwa", "dưa", "🍉"), gw("sao", "sao", "⭐"),
    gw("trawng", "trăng", "🌙"), gw("muwa", "mưa", "🌧️"), gw("nawngs", "nắng", "☀️"),
    // gia đình & cơ thể
    gw("bes", "bé", "👶"), gw("mej", "mẹ", "👩"), gw("ba", "ba", "👨"),
    gw("oong", "ông", "👴"), gw("baf", "bà", "👵"), gw("em", "em", "🧒"),
    gw("tay", "tay", "✋"), gw("mawts", "mắt", "👀"), gw("tai", "tai", "👂"),
    gw("muix", "mũi", "👃"),
    // con vật thêm
    gw("heo", "heo", "🐷"), gw("dee", "dê", "🐐"), gw("nai", "nai", "🦌"),
    gw("cua", "cua", "🦀"), gw("toom", "tôm", "🦐"), gw("oocs", "ốc", "🐌"),
    gw("caos", "cáo", "🦊"), gw("vetj", "vẹt", "🦜"), gw("sois", "sói", "🐺"),
    // đồ vật
    gw("buts", "bút", "✏️"), gw("vowr", "vở", "📓"), gw("ghees", "ghế", "🪑"),
    gw("cuwar", "cửa", "🚪"), gw("ddenf", "đèn", "💡"), gw("nooif", "nồi", "🍲"),
    gw("bats", "bát", "🍚"), gw("keos", "kéo", "✂️"), gw("oo", "ô", "☂️"),
    gw("dao", "dao", "🔪"), gw("thiaf", "thìa", "🥄"), gw("quatj", "quạt", "🪭"),
    gw("dieeuf", "diều", "🪁"), gw("saos", "sáo", "🎶"), gw("cowf", "cờ", "🚩"),
    // thiên nhiên
    gw("gios", "gió", "💨"), gw("nuis", "núi", "⛰️"), gw("soong", "sông", "🏞️"),
    gw("bieenr", "biển", "🌊"), gw("ddaor", "đảo", "🏝️"), gw("sen", "sen", "🪷"),
    // đồ ăn
    gw("keoj", "kẹo", "🍬"), gw("suwax", "sữa", "🥛"), gw("phowr", "phở", "🍜"),
    gw("xooi", "xôi", "🍙"), gw("cowm", "cơm", "🍚"), gw("duwaf", "dừa", "🥥"),
    gw("ddaof", "đào", "🍑"), gw("mits", "mít", "🍈"), gw("ooir", "ổi", "🍐"),
    gw("khees", "khế", "⭐"), gw("chanh", "chanh", "🍋"), gw("traf", "trà", "🍵"),
    gw("banhs", "bánh", "🍰"), gw("xoaif", "xoài", "🥭")
]


// ── Auto-derive telex keys from a Vietnamese word ───────────────────────────
// Tone keys go at the word END (curriculum policy); marked vowels expand to
// their doubled/w forms. Returns nil for characters outside the table.
let toneKeyOf: [Int: Character] = [1: "s", 2: "f", 3: "r", 4: "x", 5: "j"]
// char → (base key string, tone index 0-5)
let charTable: [Character: (String, Int)] = {
    var t: [Character: (String, Int)] = [:]
    let groups: [(String, [Character])] = [
        ("a",  ["a","á","à","ả","ã","ạ"]), ("aw", ["ă","ắ","ằ","ẳ","ẵ","ặ"]),
        ("aa", ["â","ấ","ầ","ẩ","ẫ","ậ"]), ("e",  ["e","é","è","ẻ","ẽ","ẹ"]),
        ("ee", ["ê","ế","ề","ể","ễ","ệ"]), ("i",  ["i","í","ì","ỉ","ĩ","ị"]),
        ("o",  ["o","ó","ò","ỏ","õ","ọ"]), ("oo", ["ô","ố","ồ","ổ","ỗ","ộ"]),
        ("ow", ["ơ","ớ","ờ","ở","ỡ","ợ"]), ("u",  ["u","ú","ù","ủ","ũ","ụ"]),
        ("uw", ["ư","ứ","ừ","ử","ữ","ự"]), ("y",  ["y","ý","ỳ","ỷ","ỹ","ỵ"]),
    ]
    for (keys, chars) in groups {
        for (i, c) in chars.enumerated() { t[c] = (keys, i) }
    }
    t["đ"] = ("dd", 0)
    for c in "bcdghklmnpqrstvx" { t[c] = (String(c), 0) }
    return t
}()
func deriveKeys(_ word: String) -> String? {
    var keys = "", tone = 0
    for ch in word.lowercased() {
        guard let (k, t) = charTable[ch] else { return nil }
        keys += k
        if t != 0 { tone = t }
    }
    if tone != 0, let tk = toneKeyOf[tone] { keys.append(tk) }
    return keys
}

/// Game word from (word, emoji) with AUTO-derived keys; nil (skipped, logged)
/// when derivation fails or the engine round-trip mismatches.
nonisolated(unsafe) var gameSkipped: [String] = []
func gwAuto(_ word: String, _ emoji: String) -> GameWord? {
    guard !word.contains(" ") else { gameSkipped.append(word + " (đa âm tiết)"); return nil }
    guard let keys = deriveKeys(word) else { gameSkipped.append(word + " (ký tự lạ)"); return nil }
    let t = trace(keys)
    guard t.final == word else { gameSkipped.append(word + " (round-trip \(t.final))"); return nil }
    return GameWord(k: keys, d: word, s: t.states, a: emoji)
}

/// Load extra (word, emoji) pairs from a JSON file (arg 2) — the kid-words
/// research list. Derives keys, validates, dedups against the curated list.
func loadExtraGameWords(_ path: String, existing: [GameWord]) -> [GameWord] {
    guard let data = FileManager.default.contents(atPath: path),
          let pairs = try? JSONSerialization.jsonObject(with: data) as? [[String]] else {
        FileHandle.standardError.write("cannot read kid-words JSON at \(path)\n".data(using: .utf8)!)
        return []
    }
    var seen = Set(existing.map(\.d))
    var out: [GameWord] = []
    for p in pairs where p.count >= 2 {
        let w = p[0].trimmingCharacters(in: .whitespaces).lowercased()
        guard !w.isEmpty, !seen.contains(w) else { continue }
        if let g = gwAuto(w, p[1]) { out.append(g); seen.insert(w) }
    }
    print("kid-words: +\(out.count) từ, bỏ \(gameSkipped.count) (\(gameSkipped.prefix(8).joined(separator: ", "))…)")
    return out
}

// MARK: - Emit

struct Root: Codable { var version: Int; var chapters: [Chapter]; var game: [GameWord] }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "lessons.json"
let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys]
var allGameWords = gameWords
if CommandLine.arguments.count > 2 {
    allGameWords += loadExtraGameWords(CommandLine.arguments[2], existing: gameWords)
}
let data = try enc.encode(Root(version: 1, chapters: chapters, game: allGameWords))

if !failures.isEmpty {
    FileHandle.standardError.write("MISMATCHES (\(failures.count)):\n".data(using: .utf8)!)
    for f in failures { FileHandle.standardError.write("  \(f)\n".data(using: .utf8)!) }
    exit(1)
}
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) — \(chapters.count) chapters, \(chapters.flatMap(\.lessons).count) lessons")
