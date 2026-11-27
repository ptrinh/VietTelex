package com.viettelex.telexcore

import org.junit.Assert.assertEquals
import org.junit.Test

// Twin of TelexCore HatInitialismTests.swift (08/11/2026): "AAL" → ÂL (âm lịch) is kept at
// the boundary instead of restoring the raw keys; the rule stays narrow (English words and
// acronyms of the same shape, 3+ letter forms, mixed case, the AAA cancel restore as before).
class HatInitialismTest {

    private val mac: TelexEngine.() -> Unit = {
        freeMarking = true; liveSpellCheck = true; contextualEnglish = true
        collisionPrefersVietnamese = true; teencode = false; eagerEnglishRestore = true
    }
    private val engines: List<Pair<String, TelexEngine.() -> Unit>> = listOf(
        "mac" to mac, "defaults" to {}, "defaults+liveSpell" to { liveSpellCheck = true },
    )

    private fun isLetter(c: Char) = c in 'a'..'z' || c in 'A'..'Z'

    /** (live composition, commitText at a space boundary); peek must agree. */
    private fun liveAndCommit(w: String, cfg: TelexEngine.() -> Unit): Pair<String, String> {
        val e = engineWith(cfg)
        for (ch in w) e.feed(ch)
        val live = e.composed
        val peek = e.peekCommitText(true, ' ')
        val c = e.commitText(true, ' ')
        assertEquals("$w: peek ≠ commit", peek, c)
        return live to c
    }

    private fun typed(s: String, cfg: TelexEngine.() -> Unit): String {
        val e = engineWith(cfg)
        val screen = StringBuilder()
        fun apply(a: TelexAction) {
            if (a is TelexAction.Replace) {
                screen.setLength(maxOf(0, screen.length - a.backspaces)); screen.append(a.insert)
            }
        }
        for (ch in s) {
            if (isLetter(ch)) {
                val r = e.feed(ch)
                if (r == TelexAction.Passthrough) screen.append(ch) else apply(r)
            } else {
                apply(e.commitBoundary(true, ch))
                screen.append(ch)
                e.noteBoundaryCharacter(ch)
            }
        }
        apply(e.commitBoundary(true))
        return screen.toString()
    }

    @Test fun hatInitialismKeepsComposition() {
        val kept = listOf("AAL" to "ÂL", "aal" to "âl", "UWD" to "ƯD", "uwd" to "ưd", "OWB" to "ƠB")
        for ((name, cfg) in engines) {
            for ((keys, want) in kept) {
                val (live, commit) = liveAndCommit(keys, cfg)
                assertEquals("$name $keys live", want, live)
                assertEquals("$name $keys commit", want, commit)
                assertEquals("$name $keys commitBoundary", want, typed(keys, cfg))
            }
            assertEquals(name, "ngày 15 ÂL", typed("ngayf 15 AAL", cfg))
            assertEquals(name, "BĐS ĐT", typed("BDDS DDT", cfg))
        }
    }

    @Test fun hatInitialismStaysNarrow() {
        val raw = listOf(
            "EEL", "eel", "OOH", "ooh", "EEK", "eek", "BOOK", "book", "COOL", "cool",
            "LOOK", "look", "FEED", "feed", "OOTD", "ootd", "AAPL", "aapl", "EEG", "eeg",
            "OOP", "oop", "AAC", "aac", "OWL", "owl", "AWL", "awl", "AAH", "aah",
            "UWB", "UWP", "AWK", "awk", "aat", "AAT", "eep", "eet", "oog", "uwk", "awt", "owp", "uwc", "Aal", "aAL", "AAl", "WL", "wl", "AAAL", "aaal",
        )
        for ((name, cfg) in engines) {
            for (w in raw) {
                val want = w.replace("AAA", "AA").replace("aaa", "aa")
                assertEquals("$name $w restores", want, liveAndCommit(w, cfg).second)
            }
            assertEquals(name, "Ồ", liveAndCommit("OOF", cfg).second)
            assertEquals(name, "ồ", liveAndCommit("oof", cfg).second)
            assertEquals(name, "ÂN", liveAndCommit("AAN", cfg).second)
            assertEquals(name, "ÔM", liveAndCommit("OOM", cfg).second)
        }
    }
}
