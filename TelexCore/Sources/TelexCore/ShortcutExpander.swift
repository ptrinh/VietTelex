// ShortcutExpander.swift
// Word-boundary lookup for the "gõ tắt" table with auto-capitalization:
//   "vn" → "việt nam"     (exact entry, as stored)
//   "Vn" → "Việt nam"     (first letter of the typed shortcut uppercase → expansion's
//                          first letter uppercased)
//   "VN" → "VIỆT NAM"     (all-caps shortcut, ≥2 letters → expansion fully uppercased)
// An exact-case entry in the table always wins over the derived forms, so users can
// still define "VN" → something specific. Runs only at a word boundary, so the
// String allocations here are acceptable (never on the per-keystroke hot path).

public enum ShortcutExpander {

    /// Expansion for `word`, or nil when the table has no matching shortcut.
    public static func expansion(for word: String, table: [String: String]) -> String? {
        if let exact = table[word] { return exact }
        guard let first = word.first, first.isUppercase else { return nil }

        let lower = word.lowercased()
        guard lower != word, let exp = table[lower] else { return nil }

        // All-caps shortcut (≥2 letters, no lowercase anywhere) → shout the expansion.
        if word.count >= 2, !word.contains(where: { $0.isLowercase }) {
            return exp.uppercased()
        }

        // Capitalized shortcut → capitalize the expansion's first letter only.
        guard let f = exp.first else { return exp }
        return String(f).uppercased() + exp.dropFirst()
    }
}
