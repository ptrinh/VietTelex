// EnglishCollisions.swift — SINH TỰ ĐỘNG bởi gen-english, ĐỪNG SỬA TAY.
// Từ tiếng Anh phổ biến (top-4000) mà Telex mặc định biến thành âm tiết
// Việt hợp lệ (validator không cứu được) — force-restore ở word boundary.
// Đã loại các từ mà tiếng Việt thắng (sẽ=sex, ơn=own… — xem gen-english).
// Regenerate:  swift run gen-english google-10000-english.txt 4000 //              Sources/TelexCore/EnglishCollisions.swift
enum EnglishCollisions {
    /// Sorted ascii, lowercase. ~131 từ, tra Set ở boundary (không trên hot path).
    static let words: Set<String> = [        "arm", "arms", "arts", "ask", "bars", "best", "bits", "boots",
        "born", "boxes", "cars", "cast", "chair", "char", "charts", "chosen",
        "coast", "core", "cost", "days", "did", "does", "door", "doors",
        "down", "gary", "gas", "gene", "genre", "gets", "gifts", "goes",
        "guys", "hair", "has", "her", "here", "his", "hits", "horse",
        "host", "if", "is", "kits", "last", "law", "laws", "lens",
        "les", "list", "loans", "lose", "lost", "lots", "major", "maps",
        "marks", "mary", "meets", "mens", "mix", "more", "most", "must",
        "nasa", "nor", "of", "or", "pair", "para", "paris", "parks",
        "parts", "past", "peer", "per", "pets", "photos", "pieces", "poor",
        "porn", "porno", "ports", "post", "queen", "raw", "refer", "rest",
        "rooms", "rose", "runs", "saw", "says", "see", "seem", "seems",
        "sense", "sets", "sexo", "songs", "soon", "task", "teens", "term",
        "terms", "test", "theme", "themes", "there", "these", "this", "those",
        "thus", "tips", "tits", "town", "tree", "trees", "trust", "turn",
        "us", "usa", "vary", "virus", "visa", "war", "wars", "won",
        "wrong", "zero", "zoom",
    ]
}