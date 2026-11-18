// CAPI.swift — @_cdecl shim exporting TelexEngine through the C ABI in
// include/telexcore.h. Pure glue: every decision stays in TelexEngine.
//
// Handles are an Unmanaged box around the engine struct. `vt_action` is written
// through raw offsets that mirror the C layout (int32 kind @0, int32 backspaces @4,
// int32 insert_len @8, char insert[128] @12) — pinned by the golden replay test.

import TelexCoreEngine

final class EngineBox {
    var e = TelexEngine()
}

@inline(__always)
private func box(_ h: OpaquePointer) -> EngineBox {
    Unmanaged<EngineBox>.fromOpaque(UnsafeRawPointer(h)).takeUnretainedValue()
}

private let insertCap = 128
private let kindPassthrough: Int32 = 0
private let kindReplace: Int32 = 1
private let kindNone: Int32 = 2

@inline(__always)
private func write(_ a: TelexAction, _ out: UnsafeMutableRawPointer?) {
    guard let out else { return }
    switch a {
    case .passthrough:
        out.storeBytes(of: kindPassthrough, toByteOffset: 0, as: Int32.self)
        out.storeBytes(of: 0, toByteOffset: 4, as: Int32.self)
        out.storeBytes(of: 0, toByteOffset: 8, as: Int32.self)
        out.storeBytes(of: 0, toByteOffset: 12, as: UInt8.self)
    case .none:
        out.storeBytes(of: kindNone, toByteOffset: 0, as: Int32.self)
        out.storeBytes(of: 0, toByteOffset: 4, as: Int32.self)
        out.storeBytes(of: 0, toByteOffset: 8, as: Int32.self)
        out.storeBytes(of: 0, toByteOffset: 12, as: UInt8.self)
    case let .replace(bs, insert):
        out.storeBytes(of: kindReplace, toByteOffset: 0, as: Int32.self)
        out.storeBytes(of: Int32(bs), toByteOffset: 4, as: Int32.self)
        var n = 0
        for b in insert.utf8 {
            if n >= insertCap - 1 { break }
            out.storeBytes(of: b, toByteOffset: 12 + n, as: UInt8.self)
            n += 1
        }
        out.storeBytes(of: 0, toByteOffset: 12 + n, as: UInt8.self)
        out.storeBytes(of: Int32(n), toByteOffset: 8, as: Int32.self)
    }
}

/// snprintf-style copy: writes ≤ cap-1 bytes + NUL, returns the full byte length.
@inline(__always)
private func copyOut(_ s: String, _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int) -> Int {
    var total = 0
    if let buf, cap > 0 {
        var n = 0
        for b in s.utf8 {
            if n < cap - 1 { buf[n] = CChar(bitPattern: b); n += 1 }
            total += 1
        }
        buf[n] = 0
    } else {
        total = s.utf8.count
    }
    return total
}

private func cString(_ p: UnsafePointer<CChar>) -> String {
    var len = 0
    while p[len] != 0 { len += 1 }
    return p.withMemoryRebound(to: UInt8.self, capacity: len) {
        String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
    }
}

// MARK: - Lifecycle

@_cdecl("vt_engine_new")
public func vt_engine_new() -> OpaquePointer {
    OpaquePointer(Unmanaged.passRetained(EngineBox()).toOpaque())
}

@_cdecl("vt_engine_free")
public func vt_engine_free(_ h: OpaquePointer?) {
    guard let h else { return }
    Unmanaged<EngineBox>.fromOpaque(UnsafeRawPointer(h)).release()
}

@_cdecl("vt_abi_version")
public func vt_abi_version() -> Int32 { 2 }

// MARK: - Flags

@_cdecl("vt_engine_set_flag")
public func vt_engine_set_flag(_ h: OpaquePointer, _ flag: Int32, _ on: Bool) {
    let b = box(h)
    switch flag {
    case 0: b.e.freeMarking = on
    case 1: b.e.modernTone = on
    case 2: b.e.liveSpellCheck = on
    case 3: b.e.simpleTelex = on
    case 4: b.e.teencode = on
    case 5: b.e.quickTelex = on
    case 6: b.e.bracketVowels = on
    case 7: b.e.vniMode = on
    case 8: b.e.contextualEnglish = on
    case 9: b.e.englishWordRestore = on
    case 10: b.e.collisionPrefersVietnamese = on
    case 11: b.e.eagerEnglishRestore = on
    case 12: b.e.retroactiveEnglish = on
    case 13: b.e.englishByFrequency = on
    case 14: b.e.autoCircumflex = on
    default: break
    }
}

@_cdecl("vt_engine_get_flag")
public func vt_engine_get_flag(_ h: OpaquePointer, _ flag: Int32) -> Bool {
    let e = box(h).e
    switch flag {
    case 0: return e.freeMarking
    case 1: return e.modernTone
    case 2: return e.liveSpellCheck
    case 3: return e.simpleTelex
    case 4: return e.teencode
    case 5: return e.quickTelex
    case 6: return e.bracketVowels
    case 7: return e.vniMode
    case 8: return e.contextualEnglish
    case 9: return e.englishWordRestore
    case 10: return e.collisionPrefersVietnamese
    case 11: return e.eagerEnglishRestore
    case 12: return e.retroactiveEnglish
    case 13: return e.englishByFrequency
    case 14: return e.autoCircumflex
    default: return false
    }
}

// MARK: - Editing

@_cdecl("vt_feed")
public func vt_feed(_ h: OpaquePointer, _ ch: UInt32, _ out: UnsafeMutableRawPointer?) {
    guard let scalar = Unicode.Scalar(ch) else { write(.passthrough, out); return }
    let b = box(h)
    write(b.e.feed(Character(scalar)), out)
}

@_cdecl("vt_backspace")
public func vt_backspace(_ h: OpaquePointer, _ out: UnsafeMutableRawPointer?) {
    let b = box(h)
    write(b.e.backspace(), out)
}

@_cdecl("vt_commit")
public func vt_commit(_ h: OpaquePointer, _ autoRestore: Bool, _ out: UnsafeMutableRawPointer?) {
    let b = box(h)
    write(b.e.commitBoundary(autoRestore: autoRestore), out)
}

@_cdecl("vt_commit_text")
public func vt_commit_text(_ h: OpaquePointer, _ autoRestore: Bool,
                           _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int) -> Int {
    let b = box(h)
    return copyOut(b.e.commitText(autoRestore: autoRestore), buf, cap)
}

@_cdecl("vt_peek")
public func vt_peek(_ h: OpaquePointer, _ autoRestore: Bool,
                    _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int) -> Int {
    copyOut(box(h).e.peekCommitText(autoRestore: autoRestore), buf, cap)
}

/// The word-ending character as a Character (0 / invalid = unknown).
private func boundaryChar(_ ch: UInt32) -> Character? {
    guard ch != 0, let s = Unicode.Scalar(ch) else { return nil }
    return Character(s)
}

@_cdecl("vt_commit_before")
public func vt_commit_before(_ h: OpaquePointer, _ autoRestore: Bool, _ ch: UInt32,
                             _ out: UnsafeMutableRawPointer?) {
    let b = box(h)
    write(b.e.commitBoundary(autoRestore: autoRestore, boundary: boundaryChar(ch)), out)
}

@_cdecl("vt_commit_text_before")
public func vt_commit_text_before(_ h: OpaquePointer, _ autoRestore: Bool, _ ch: UInt32,
                                  _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int) -> Int {
    let b = box(h)
    return copyOut(b.e.commitText(autoRestore: autoRestore, boundary: boundaryChar(ch)), buf, cap)
}

@_cdecl("vt_peek_before")
public func vt_peek_before(_ h: OpaquePointer, _ autoRestore: Bool, _ ch: UInt32,
                           _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int) -> Int {
    copyOut(box(h).e.peekCommitText(autoRestore: autoRestore, boundary: boundaryChar(ch)), buf, cap)
}

@_cdecl("vt_composed")
public func vt_composed(_ h: OpaquePointer, _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int) -> Int {
    copyOut(box(h).e.composed, buf, cap)
}

@_cdecl("vt_raw")
public func vt_raw(_ h: OpaquePointer, _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int) -> Int {
    copyOut(box(h).e.rawKeystrokes, buf, cap)
}

@_cdecl("vt_reset")
public func vt_reset(_ h: OpaquePointer) { box(h).e.reset() }

@_cdecl("vt_reset_context")
public func vt_reset_context(_ h: OpaquePointer) { box(h).e.resetContext() }

@_cdecl("vt_forget_last_commit")
public func vt_forget_last_commit(_ h: OpaquePointer) { box(h).e.forgetLastCommit() }

@_cdecl("vt_seed")
public func vt_seed(_ h: OpaquePointer, _ word: UnsafePointer<CChar>?) -> Bool {
    guard let word else { return false }
    return box(h).e.seed(cString(word))
}

@_cdecl("vt_note_boundary")
public func vt_note_boundary(_ h: OpaquePointer, _ ch: UInt32) {
    guard let scalar = Unicode.Scalar(ch) else { box(h).e.reset(); return }
    box(h).e.noteBoundaryCharacter(Character(scalar))
}

/// vt_retro layout: int32 backspaces @0, words @4, expected_len @8, insert_len @12,
/// char expected[1024] @16, char insert[1024] @1040, int32 flip_back @2064.
@_cdecl("vt_take_retro")
public func vt_take_retro(_ h: OpaquePointer, _ out: UnsafeMutableRawPointer?) -> Bool {
    guard let out, let c = box(h).e.takeRetroCorrection() else { return false }
    let cap = 1024
    func put(_ s: String, _ at: Int) -> Int32? {
        var n = 0
        for b in s.utf8 {
            if n >= cap - 1 { return nil }
            out.storeBytes(of: b, toByteOffset: at + n, as: UInt8.self)
            n += 1
        }
        out.storeBytes(of: 0, toByteOffset: at + n, as: UInt8.self)
        return Int32(n)
    }
    guard let el = put(c.expected, 16), let il = put(c.insert, 16 + cap) else { return false }
    out.storeBytes(of: Int32(c.backspaces), toByteOffset: 0, as: Int32.self)
    out.storeBytes(of: Int32(c.words), toByteOffset: 4, as: Int32.self)
    out.storeBytes(of: el, toByteOffset: 8, as: Int32.self)
    out.storeBytes(of: il, toByteOffset: 12, as: Int32.self)
    out.storeBytes(of: Int32(c.flipBack ? 1 : 0), toByteOffset: 16 + 2 * cap, as: Int32.self)
    return true
}

/// vt_restore_undo layout: int32 restored_len @0, vietnamese_len @4,
/// char restored[160] @8, char vietnamese[160] @168.
@_cdecl("vt_take_restore_undo")
public func vt_take_restore_undo(_ h: OpaquePointer, _ out: UnsafeMutableRawPointer?) -> Bool {
    guard let out, let u = box(h).e.takeRestoreUndo() else { return false }
    let cap = 160
    func put(_ s: String, _ at: Int) -> Int32? {
        var n = 0
        for b in s.utf8 {
            if n >= cap - 1 { return nil }
            out.storeBytes(of: b, toByteOffset: at + n, as: UInt8.self)
            n += 1
        }
        out.storeBytes(of: 0, toByteOffset: at + n, as: UInt8.self)
        return Int32(n)
    }
    guard let rl = put(u.restored, 8), let vl = put(u.vietnamese, 8 + cap) else { return false }
    out.storeBytes(of: rl, toByteOffset: 0, as: Int32.self)
    out.storeBytes(of: vl, toByteOffset: 4, as: Int32.self)
    return true
}

@_cdecl("vt_restore_undo_applied")
public func vt_restore_undo_applied(_ h: OpaquePointer) { box(h).e.restoreUndoApplied() }

@_cdecl("vt_reopen")
public func vt_reopen(_ h: OpaquePointer, _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int) -> Int {
    guard let w = box(h).e.reopenLastCommit() else { return -1 }
    return copyOut(w, buf, cap)
}

// MARK: - State

@_cdecl("vt_is_empty")
public func vt_is_empty(_ h: OpaquePointer) -> Bool { box(h).e.isEmpty }

@_cdecl("vt_is_overflowed")
public func vt_is_overflowed(_ h: OpaquePointer) -> Bool { box(h).e.isOverflowed }

@_cdecl("vt_can_reopen")
public func vt_can_reopen(_ h: OpaquePointer) -> Bool { box(h).e.canReopenLastCommit }

@_cdecl("vt_previous_word_english")
public func vt_previous_word_english(_ h: OpaquePointer) -> Bool { box(h).e.previousWordEnglish }

// MARK: - Gợi ý cạnh con trỏ (linux/common caret_hints): kiểm âm tiết rẻ ở ranh giới từ

/// SyllableValidator.isValidSyllable — cổng "Sửa lỗi gõ sai" (TypoFixLogic.worthChecking).
@_cdecl("vt_is_valid_syllable")
public func vt_is_valid_syllable(_ word: UnsafePointer<CChar>?, _ teencode: Bool) -> Bool {
    guard let word else { return false }
    return SyllableValidator.isValidSyllable(cString(word), teencode: teencode)
}

/// EnglishContextLookup.opensEnglishRun — the engine's English word list (lowercase a–z).
/// The helper's TypoFixLogic.isKnown includes it, so such a word never gets a typo fix:
/// the frontend skips the helper round trip for it.
@_cdecl("vt_is_english_word")
public func vt_is_english_word(_ word: UnsafePointer<CChar>?) -> Bool {
    guard let word else { return false }
    return EnglishContextLookup.opensEnglishRun(cString(word))
}

// MARK: - Gạch đỏ âm tiết sai chính tả khi gõ (opt-in, preedit only)

/// TelexEngine.hasSpellingError(autoRestore:) — asked per key only when the setting is on.
@_cdecl("vt_has_spelling_error")
public func vt_has_spelling_error(_ h: OpaquePointer, _ autoRestore: Bool) -> Bool {
    box(h).e.hasSpellingError(autoRestore: autoRestore)
}

/// SyllableValidator.isSpellingError (NFC UTF-8) — shared test vectors.
@_cdecl("vt_is_spelling_error")
public func vt_is_spelling_error(_ word: UnsafePointer<CChar>?, _ teencode: Bool) -> Bool {
    guard let word else { return false }
    return SyllableValidator.isSpellingError(cString(word), teencode: teencode)
}

/// ToneRunLogic.isUnaccentedSyllable (App/Sources/CaretSuggestions.swift) — không Foundation:
/// chữ a–z nên "thêm sắc vào nguyên âm đầu" là tra bảng thay cho NFC.
@_cdecl("vt_is_unaccented_syllable")
public func vt_is_unaccented_syllable(_ chunk: UnsafePointer<CChar>?) -> Bool {
    guard let chunk else { return false }
    return isUnaccentedSyllable(Substring(cString(chunk)))
}

private let edgePunct = Set(",;:\"'()[]…“”‘’.!?")
private let acuteVowel: [Character: Character] = ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý"]

func isUnaccentedSyllable(_ chunk: Substring) -> Bool {
    var c = chunk
    while let f = c.first, edgePunct.contains(f) { c = c.dropFirst() }
    while let l = c.last, edgePunct.contains(l) { c = c.dropLast() }
    guard !c.isEmpty, c.count <= 7,
          c.unicodeScalars.allSatisfy({ ($0.value >= 97 && $0.value <= 122) || ($0.value >= 65 && $0.value <= 90) }),
          !c.dropFirst().contains(where: \.isUppercase) || c.allSatisfy(\.isUppercase) else { return false }
    let w = c.lowercased()
    guard !EnglishContextLookup.opensEnglishRun(w) else { return false }
    if SyllableValidator.isValidSyllable(w, teencode: false) { return true }
    // Vần tắc (-c -ch -p -t) chỉ mang sắc/nặng: "hoc" là dạng không dấu của học/hóc.
    guard let i = w.firstIndex(where: { acuteVowel[$0] != nil }) else { return false }
    var acute = w
    acute.replaceSubrange(i...i, with: String(acuteVowel[w[i]]!))
    return SyllableValidator.isValidSyllable(acute, teencode: false)
}
