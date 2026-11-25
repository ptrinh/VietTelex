package com.viettelex.keyboard

/**
 * "Vuốt phím để sao chép/dán" ([Keys.SWIPE_KEY_COMMANDS], mặc định TẮT) — kiểu SwipeExtender:
 * chạm một phím chữ rồi vuốt THẲNG LÊN quá mép trên vùng phím (lên thanh gợi ý) và nhấc tay
 * ⇒ lệnh sửa văn bản. Ánh xạ theo VỊ TRÍ phím QWERTY (chữ gốc thường, không phụ thuộc
 * Telex/VNI): c sao chép, x cắt, v dán; riêng Android thêm a chọn hết, z hoàn tác, y làm lại.
 *
 * Ngưỡng (đơn vị tuỳ caller nhưng NHẤT QUÁN — KeyboardView truyền dp; GIỐNG bản iOS
 * KeyCommandGesture.swift, cùng hằng số):
 *  - dy = startY − y (đi lên là dương), dx = x − startX.
 *  - LOẠI vĩnh viễn khi |dx| > [LATERAL_KEYS]·pitch + [SLOPE]·max(dy, 0) (không còn "thẳng
 *    lên" — nhường gõ vuốt), hoặc dy < −[DOWN_KEYS]·pitch (kéo xuống), hoặc ngón thứ hai chạm /
 *    popup ký tự phụ bật ([reject]).
 *  - BẬT (armed) khi y ≤ keyAreaTop − [ARM_MARGIN] (ngón đã ra khỏi hàng phím trên cùng, kể cả
 *    hàng số) mà chưa bị loại; TẮT lại khi y > keyAreaTop (kéo ngón trở xuống — huỷ), bật lại được.
 *  - Nhấc tay lúc đang bật ⇒ [release] trả lệnh.
 *
 * Công tắc tắt ⇒ [start] trả null ⇒ không đối tượng, không theo dõi (một phép so bool mỗi chạm).
 * THUẦN — pinned by KeyCommandGestureTests.
 */
class KeyCommandGesture private constructor(
    /** null = cử chỉ vuốt-thẳng-lên không gắn lệnh (hàng chữ trên cùng → số, [startUp]). */
    val command: KeyCommand?,
    private val startX: Float,
    private val startY: Float,
    private val keyAreaTop: Float,
    private val pitch: Float,
    private val armMargin: Float,
) {
    enum class State { TRACKING, ARMED, REJECTED }
    enum class Event { NONE, ARMED, DISARMED, REJECTED }

    var state = State.TRACKING
        private set

    /** Còn là ứng viên (chưa bị loại) — trong lúc này gõ vuốt KHÔNG được quyết "vuốt". */
    val live: Boolean get() = state != State.REJECTED
    val armed: Boolean get() = state == State.ARMED

    fun move(x: Float, y: Float): Event {
        if (state == State.REJECTED) return Event.NONE
        val dy = startY - y
        val dx = kotlin.math.abs(x - startX)
        if (dx > LATERAL_KEYS * pitch + SLOPE * maxOf(dy, 0f) || dy < -DOWN_KEYS * pitch) return reject()
        return when {
            state == State.TRACKING && y <= keyAreaTop - armMargin -> { state = State.ARMED; Event.ARMED }
            state == State.ARMED && y > keyAreaTop -> { state = State.TRACKING; Event.DISARMED }
            else -> Event.NONE
        }
    }

    /** Ngón thứ hai chạm / popup ký tự phụ bật / huỷ hệ thống. */
    fun reject(): Event {
        if (state == State.REJECTED) return Event.NONE
        state = State.REJECTED
        return Event.REJECTED
    }

    /** Nhấc tay tại (x, y): lệnh nếu vẫn đang bật sau điểm cuối, null nếu không. */
    fun release(x: Float, y: Float): KeyCommand? {
        move(x, y)
        return if (state == State.ARMED) command else null
    }

    /** Nhấc tay tại (x, y): cử chỉ còn đang bật không (cho cử chỉ không gắn lệnh). */
    fun releaseArmed(x: Float, y: Float): Boolean {
        move(x, y)
        return state == State.ARMED
    }

    companion object {
        /**
         * Cùng cử chỉ, không gắn lệnh: phím hàng chữ trên cùng vuốt thẳng lên ra ký tự phụ (số).
         * KeyboardView tự giữ ký tự; nhấc tay hỏi [releaseArmed].
         */
        fun startUp(x: Float, y: Float, keyAreaTop: Float, keyPitch: Float,
                    armMargin: Float = ARM_MARGIN): KeyCommandGesture? =
            if (keyPitch <= 0f) null else KeyCommandGesture(null, x, y, keyAreaTop, keyPitch, armMargin)

        const val SLOPE = 0.45f
        const val LATERAL_KEYS = 0.5f
        const val DOWN_KEYS = 0.5f
        /** dp/pt trên mép vùng phím. */
        const val ARM_MARGIN = 4f

        /** Lệnh của phím (chữ gốc thường). [full] = Android (thêm a/z/y); iOS chỉ c/x/v. */
        fun commandFor(c: Char, full: Boolean = true): KeyCommand? = when (c.lowercaseChar()) {
            'c' -> KeyCommand.COPY
            'x' -> KeyCommand.CUT
            'v' -> KeyCommand.PASTE
            'a' -> if (full) KeyCommand.SELECT_ALL else null
            'z' -> if (full) KeyCommand.UNDO else null
            'y' -> if (full) KeyCommand.REDO else null
            else -> null
        }

        /**
         * Lúc nhấc tay chạy lệnh: chữ của phím CÒN chưa chèn? [deferredAtDown] = chữ được hoãn lúc
         * chạm (KeyCommitQueue); [armedNow] = còn nằm trong hàng chờ. Chữ hoãn đã bị chèn giữa
         * chừng (giữ lâu ra ký tự phụ, ngón khác chạm) ⇒ false: lệnh phải gỡ chữ đó (#179 — vuốt
         * V lên dán được mà chữ "v" còn lại).
         */
        fun letterStillDeferred(deferredAtDown: Boolean, armedNow: Boolean): Boolean = deferredAtDown && armedNow

        /** null khi công tắc tắt hoặc phím không có lệnh. */
        fun start(enabled: Boolean, key: Char, x: Float, y: Float, keyAreaTop: Float, keyPitch: Float,
                  armMargin: Float = ARM_MARGIN, full: Boolean = true): KeyCommandGesture? {
            if (!enabled) return null
            val cmd = commandFor(key, full) ?: return null
            return KeyCommandGesture(cmd, x, y, keyAreaTop, keyPitch, armMargin)
        }
    }
}

/** Lệnh của [KeyCommandGesture]; [label] là khoá L10n tiếng Việt (gọi tr() khi hiện). */
enum class KeyCommand(val label: String) {
    COPY("Sao chép"), CUT("Cắt"), PASTE("Dán"), SELECT_ALL("Chọn hết"), UNDO("Hoàn tác"), REDO("Làm lại");

    /** Cần vùng chọn mới có nghĩa (không có ⇒ hiện gợi ý "Chưa chọn chữ" thay vì nhãn). */
    val needsSelection: Boolean get() = this == COPY || this == CUT
}
