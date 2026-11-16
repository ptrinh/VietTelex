package com.viettelex.android.ime

import com.viettelex.keyboard.KeyCommitQueue
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Hợp đồng thứ tự chốt khi gõ chồng ngón (spec §5, §13 "Gõ nhanh") — mô phỏng đúng
 * trình tự KeyboardView.down/up gọi: route bằng KeyLayout.hit, `commits.flush(k)` TRƯỚC
 * mọi hành động, phím chữ chèn lúc DOWN, space/dấu arm lúc DOWN – chốt lúc UP/CANCEL.
 */
class RollingTouchTest {
    private val keys = KeyLayout.build(LayoutConfig(Plane.LETTERS, 390f, 218f, 1f))
    private val out = StringBuilder()
    private val q = KeyCommitQueue()
    private val held = HashMap<Int, LaidKey>()

    private fun key(label: String) = keys.first { it.label == label && it.kind == KeyKind.LETTER }
    private val space get() = keys.first { it.kind == KeyKind.SPACE }
    private val comma get() = keys.first { it.kind == KeyKind.PUNCT }

    private fun down(pid: Int, k: LaidKey) {
        val hit = KeyLayout.hit(keys, Plane.LETTERS, k.centerX, k.centerY, 4f, 1f)!!
        q.flush(hit)
        held[pid] = hit
        when (hit.kind) {
            KeyKind.LETTER -> out.append(hit.label)
            KeyKind.SPACE -> q.arm(hit) { out.append(' ') }
            KeyKind.PUNCT -> q.arm(hit) { out.append(hit.insert) }
        }
    }

    private fun up(pid: Int) {
        val k = held.remove(pid)!!
        if (k.kind != KeyKind.LETTER) q.release(k)
    }

    @Test fun rollingEightFingersKeepsEveryKeyInOrder() {
        // mỗi ngón chạm xuống TRƯỚC khi ngón trước nhấc
        val word = "abcdefgh"
        down(0, key("a"))
        for (i in 1 until word.length) {
            down(i, key(word[i].toString()))
            up(i - 1)
        }
        up(word.length - 1)
        assertEquals("abcdefgh", out.toString())
    }

    @Test fun twoThumbsSpaceStillDownWhenNextLetterLands() {
        // "anh em": ngón cái phải còn đè space khi ngón trái chạm "e"
        for (c in "anh") { down(0, key(c.toString())); up(0) }
        down(1, space)
        down(0, key("e"))       // space phải chốt TRƯỚC "e"
        up(1)
        up(0)
        down(0, key("m")); up(0)
        assertEquals("anh em", out.toString())
    }

    @Test fun cancelledSpaceStillCommits() {
        down(0, key("a")); up(0)
        down(1, space)
        up(1)                   // ACTION_CANCEL đi cùng đường release
        assertEquals("a ", out.toString())
    }

    @Test fun punctuationThenSpaceOverlap() {
        down(0, key("a")); up(0)
        down(1, comma)
        down(2, space)
        up(1); up(2)
        assertEquals("a, ", out.toString())
    }

    @Test fun trackpadDisarmDropsSpace() {
        down(0, key("a")); up(0)
        down(1, space)
        q.disarm(held[1]!!)
        up(1)
        assertEquals("a", out.toString())
    }

    // ---- Chốt phím đang đè đổi plane (?123 → ABC) TRƯỚC khi chạm mới được tra phím ----
    // Mô phỏng KeyboardView.down: FlushRoute.resolve(hit, flush, layout) + emit đổi plane theo PlanePolicy.

    private inner class Planes {
        var plane = Plane.NUMBERS
        var typedInPlane = false
        val letters = KeyLayout.build(LayoutConfig(Plane.LETTERS, 390f, 218f, 1f))
        val numbers = KeyLayout.build(LayoutConfig(Plane.NUMBERS, 390f, 218f, 1f))
        val cur get() = if (plane == Plane.LETTERS) letters else numbers
        val text = StringBuilder()
        val queue = KeyCommitQueue()
        val held = HashMap<Int, LaidKey>()

        fun emitText(s: String) {
            val sym = plane == Plane.NUMBERS
            val before = text.lastOrNull()
            text.append(s)
            if (sym) typedInPlane = true
            if (sym && PlanePolicy.returnToLettersAfterSymbol(s, plane, false, before)) plane = Plane.LETTERS
            else if (s == " " && PlanePolicy.returnToLettersOnSpace(plane, typedInPlane, false)) plane = Plane.LETTERS
        }

        fun downAt(pid: Int, x: Float, y: Float) {
            val k = FlushRoute.resolve({ KeyLayout.hit(cur, plane, x, y, 4f, 1f) }, { queue.flush(it) }, { cur })!!
            held[pid] = k
            when (k.kind) {
                KeyKind.LETTER -> emitText(k.label)
                KeyKind.SPACE -> queue.arm(k) { emitText(" ") }
                KeyKind.CHAR, KeyKind.PUNCT -> queue.arm(k) { emitText(k.insert) }
            }
        }
        fun down(pid: Int, k: LaidKey) = downAt(pid, k.centerX, k.centerY)
        fun up(pid: Int) { val k = held.remove(pid)!!; if (k.kind != KeyKind.LETTER) queue.release(k) }
    }

    @Test fun spaceHeldOn123ThenFastLetterResolvesOnLetters() {
        val p = Planes()
        p.down(0, p.numbers.first { it.insert == "2" }); p.up(0)
        p.down(1, p.numbers.first { it.kind == KeyKind.SPACE })   // giữ space
        val n = p.letters.first { it.label == "n" && it.kind == KeyKind.LETTER }
        p.downAt(0, n.centerX, n.centerY)   // chạm chỗ "n" trước khi nhấc space
        p.up(1); p.up(0)
        assertEquals("2 n", p.text.toString())
        assertEquals(Plane.LETTERS, p.plane)
    }

    @Test fun commaHeldOn123ThenFastLetterResolvesOnLetters() {
        val p = Planes()
        val comma = p.numbers.firstOrNull { it.insert == "," } ?: p.numbers.first { it.insert == "!" }
        p.down(1, comma)                    // "Tự động": dấu kết vế về ABC lúc chốt
        val n = p.letters.first { it.label == "n" && it.kind == KeyKind.LETTER }
        p.downAt(0, n.centerX, n.centerY)
        p.up(1); p.up(0)
        assertEquals(comma.insert + "n", p.text.toString())
    }

    /** #165: chạm "$" (phím gốc bàn 123 như iOS) ra "$" — "Tự động": "$" là dấu kết vế ⇒ về ABC. */
    @Test fun tapDollarOn123TypesDollar() {
        val p = Planes()
        p.down(0, p.numbers.single { it.insert == "\$" && it.kind == KeyKind.CHAR }); p.up(0)
        assertEquals("\$", p.text.toString())
        assertEquals(Plane.LETTERS, p.plane)
    }

    @Test fun samePlaneFlushKeepsFirstHitAndSkipsSameKey() {
        val p = Planes()
        val two = p.numbers.first { it.insert == "2" }
        p.down(0, two)
        p.down(1, two)                      // cùng phím đè lần nữa: flush bỏ qua, arm chốt lần trước
        p.up(0); p.up(1)
        assertEquals("22", p.text.toString())
        assertEquals(Plane.NUMBERS, p.plane)
    }
}
