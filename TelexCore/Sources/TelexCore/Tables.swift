// Tables.swift
// Static lookup tables for Telex composition. Built once, no per-keystroke heap use.

/// Diacritic mark carried by a base letter.
enum Mark: UInt8 {
    case none = 0
    case circumflex // â ê ô
    case breve      // ă
    case horn       // ơ ư
    case bar        // đ
}

/// Vietnamese tone. Raw values match the ordering used in the toned-form tables.
public enum Tone: UInt8 {
    case none = 0
    case acute      // ´ (sắc)   s
    case grave      // ` (huyền) f
    case hook       // ̉ (hỏi)   r
    case tilde      // ~ (ngã)   x
    case dot        // . (nặng)  j
}

enum Tables {

    // MARK: - Toned forms

    // Each group: [base(toneless), acute, grave, hook, tilde, dot]. Lower + upper.
    private static let tonedGroups: [String] = [
        "aáàảãạ", "ăắằẳẵặ", "âấầẩẫậ", "eéèẻẽẹ", "êếềểễệ", "iíìỉĩị",
        "oóòỏõọ", "ôốồổỗộ", "ơớờởỡợ", "uúùủũụ", "ưứừửữự", "yýỳỷỹỵ",
        "AÁÀẢÃẠ", "ĂẮẰẲẴẶ", "ÂẤẦẨẪẬ", "EÉÈẺẼẸ", "ÊẾỀỂỄỆ", "IÍÌỈĨỊ",
        "OÓÒỎÕỌ", "ÔỐỒỔỖỘ", "ƠỚỜỞỠỢ", "UÚÙỦŨỤ", "ƯỨỪỬỮỰ", "YÝỲỶỸỴ",
    ]

    /// toneless vowel scalar -> [6 toned scalar values] indexed by Tone.rawValue.
    static let tonedTable: [UInt32: [UInt32]] = {
        var map: [UInt32: [UInt32]] = [:]
        map.reserveCapacity(24)
        for group in tonedGroups {
            let scalars = Array(group.unicodeScalars)
            let key = scalars[0].value
            map[key] = scalars.map { $0.value }
        }
        return map
    }()

    /// reverse: toned scalar -> (toneless scalar, tone). Includes the toneless form itself.
    nonisolated(unsafe) static let detoneTable: [UInt32: (base: UInt32, tone: Tone)] = {
        var map: [UInt32: (UInt32, Tone)] = [:]
        map.reserveCapacity(144)
        for group in tonedGroups {
            let scalars = Array(group.unicodeScalars)
            let base = scalars[0].value
            for (i, s) in scalars.enumerated() {
                map[s.value] = (base, Tone(rawValue: UInt8(i))!)
            }
        }
        return map
    }()

    // MARK: - Base + mark -> toneless scalar

    /// Compose a base ascii letter (lowercase) + mark into a toneless scalar value.
    @inline(__always)
    static func markedScalar(base: UInt8, mark: Mark, upper: Bool) -> UInt32 {
        // ascii fast path for mark == none
        if mark == .none {
            let a = upper ? base &- 32 : base
            return UInt32(a)
        }
        let ch: Character
        switch (base, mark) {
        case (UInt8(ascii: "a"), .circumflex): ch = upper ? "Â" : "â"
        case (UInt8(ascii: "a"), .breve):      ch = upper ? "Ă" : "ă"
        case (UInt8(ascii: "e"), .circumflex): ch = upper ? "Ê" : "ê"
        case (UInt8(ascii: "o"), .circumflex): ch = upper ? "Ô" : "ô"
        case (UInt8(ascii: "o"), .horn):       ch = upper ? "Ơ" : "ơ"
        case (UInt8(ascii: "u"), .horn):       ch = upper ? "Ư" : "ư"
        case (UInt8(ascii: "d"), .bar):        ch = upper ? "Đ" : "đ"
        default:
            let a = upper ? base &- 32 : base
            return UInt32(a)
        }
        return ch.unicodeScalars.first!.value
    }

    /// Apply a tone to a toneless (possibly marked) vowel scalar. Returns input unchanged
    /// if the scalar is not a known vowel or tone is none.
    @inline(__always)
    static func applyTone(_ scalar: UInt32, _ tone: Tone) -> UInt32 {
        if tone == .none { return scalar }
        guard let forms = tonedTable[scalar] else { return scalar }
        return forms[Int(tone.rawValue)]
    }
}

// MARK: - Character classification

@inline(__always)
func isVowelAscii(_ c: UInt8) -> Bool {
    switch c {
    case UInt8(ascii: "a"), UInt8(ascii: "e"), UInt8(ascii: "i"),
         UInt8(ascii: "o"), UInt8(ascii: "u"), UInt8(ascii: "y"):
        return true
    default:
        return false
    }
}

@inline(__always)
func toneForKey(_ c: UInt8) -> Tone? {
    switch c {
    case UInt8(ascii: "s"): return .acute
    case UInt8(ascii: "f"): return .grave
    case UInt8(ascii: "r"): return .hook
    case UInt8(ascii: "x"): return .tilde
    case UInt8(ascii: "j"): return .dot
    default: return nil
    }
}
