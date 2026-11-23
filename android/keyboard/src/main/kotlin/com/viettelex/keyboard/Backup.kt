package com.viettelex.keyboard

import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/**
 * File sao lưu một tệp khi đổi máy — định dạng JSON GIỐNG HỆT iOS
 * (iOS/App/Backup/BackupFormat.swift). Fixture chung iOS/KeyboardTests/Fixtures/backup-*.json
 * được test ở cả hai nền tảng.
 *
 * ```
 * { "format": "viettelex-backup", "version": 1, "minReaderVersion": 1,
 *   "createdAt": "2026-09-27T08:00:00Z", "platform": "android",
 *   "settings": {"simpleTelex": true, …, "rowHeightAdjust": 0},
 *   "shortcuts": {"ko": "không"},                          // gõ tắt
 *   "templates": [{"label": "👋", "text": "Chào buổi sáng"}],
 *   "learnedWords": {"uni": {…}, "bi": {…}, "tri": {…}} }  // tuỳ chọn
 * ```
 * Thiếu mục = không đụng khi nhập; key/trường lạ bỏ qua; setting sai kiểu bỏ qua;
 * `minReaderVersion` > [BackupCodec.VERSION] ⇒ từ chối.
 */
sealed class SettingKind {
    data class Bool(val default: Boolean) : SettingKind()
    data class IntRange(val default: Int, val range: kotlin.ranges.IntRange) : SettingKind()
    /** Chuỗi thuộc tập [allowed] (vd uiLanguage "vi"/"en"); giá trị lạ bỏ qua. */
    data class Choice(val default: String, val allowed: Set<String>) : SettingKind()
    object BuddyName : SettingKind()
    /** Chuỗi JSON "Tuỳ chỉnh nâng cao" theo theme ([KeyStyleStore]) — chuẩn hoá khi đọc/ghi, mặc định "{}". */
    object StyleMap : SettingKind()
    /** Chuỗi JSON kho theme tự tạo ([CustomThemeStore]) — chuẩn hoá (kiểm chặt) khi đọc/ghi, mặc định "{}". */
    object ThemeMap : SettingKind()
}

object BackupSettings {
    class Spec(val key: String, val kind: SettingKind)
    val all: List<Spec> = listOf(
        Spec(Keys.SIMPLE_TELEX, SettingKind.Bool(true)),
        Spec(Keys.FREE_MARKING, SettingKind.Bool(true)),
        Spec(Keys.QUICK_TELEX, SettingKind.Bool(false)),
        Spec(Keys.MODERN_TONE, SettingKind.Bool(false)),
        Spec(Keys.CONTEXTUAL_ENGLISH, SettingKind.Bool(true)),
        Spec(Keys.RETRO_ENGLISH_AUTO, SettingKind.Bool(false)),
        Spec(Keys.ENGLISH_BY_FREQUENCY, SettingKind.Bool(false)),
        Spec(Keys.RE_EDIT_WORDS, SettingKind.Bool(true)),
        Spec(Keys.AUTO_CIRCUMFLEX, SettingKind.Bool(false)),
        Spec(Keys.AUTO_FIX_ADJACENT, SettingKind.Bool(true)),
        Spec(Keys.TEENCODE, SettingKind.Bool(false)),
        Spec(Keys.AUTO_RESTORE, SettingKind.Bool(true)),
        Spec(Keys.LIVE_SPELL_CHECK, SettingKind.Bool(true)),
        Spec(Keys.SWIPE_TYPING, SettingKind.Bool(false)),
        Spec(Keys.SWIPE_ENGLISH, SettingKind.Bool(true)),
        Spec(Keys.HARDWARE_TELEX, SettingKind.Bool(true)),
        Spec(Keys.SHOW_SUGGESTIONS, SettingKind.Bool(true)),
        Spec(Keys.FILTER_SENSITIVE, SettingKind.Bool(true)),
        Spec(Keys.TEMPLATES_ENABLED, SettingKind.Bool(true)),
        Spec(Keys.SHOW_SPACE_LOGO, SettingKind.Bool(true)),
        Spec(Keys.HAPTIC_FEEDBACK, SettingKind.Bool(false)),
        Spec(Keys.HAPTIC_STRENGTH, SettingKind.IntRange(HapticStrength.DEFAULT, HapticStrength.RANGE)),
        Spec(Keys.KEY_SOUND, SettingKind.Bool(false)),
        Spec(Keys.KEY_SOUND_VOLUME, SettingKind.IntRange(50, 0..100)),
        // Kiểu âm; "custom" đi theo nhưng FILE âm không — máy mới thiếu file ⇒ IME dùng mặc định.
        Spec(Keys.KEY_SOUND_STYLE, SettingKind.Choice(KeySoundStyle.DEFAULT.id, KeySoundStyle.IDS)),
        Spec(Keys.NUMBER_ROW, SettingKind.Bool(false)),
        Spec(Keys.NUMBER_ROW_FULL_HEIGHT, SettingKind.Bool(false)),
        Spec(Keys.SPACE_SIDE_KEY, SettingKind.Choice(SpaceSideKey.DEFAULT.id, SpaceSideKey.IDS)),
        Spec(Keys.SYMBOL_RETURN, SettingKind.Choice(SymbolReturn.DEFAULT.id, SymbolReturn.IDS)),   // "Về bàn chữ sau ký hiệu"
        Spec(Keys.EMOJI_KEY_PLACEMENT, SettingKind.Choice(EmojiKeyPlacement.DEFAULT.id, EmojiKeyPlacement.IDS)),
        Spec(Keys.LARGE_KEYS, SettingKind.Bool(false)),   // "Phím to" — cùng khoá iOS
        Spec(Keys.CLIPBOARD_TTL, SettingKind.Choice(ClipboardTTL.DEFAULT.id, ClipboardTTL.IDS)),   // "Giữ lịch sử clipboard"
        Spec(Keys.KEY_LABEL_SIZE, SettingKind.Choice(KeyLabelSize.DEFAULT.id, KeyLabelSize.IDS)),
        Spec(Keys.ROW_HEIGHT_ADJUST, SettingKind.IntRange(0, KeyboardSettings.ROW_HEIGHT_MIN..KeyboardSettings.ROW_HEIGHT_MAX)),
        Spec(Keys.KEYBOARD_RAISE, SettingKind.IntRange(0, 0..KeyboardSettings.KEYBOARD_RAISE_MAX)),
        // "Chiều cao thanh gợi ý" ([SuggestionBarHeight]) — cùng khoá + id iOS.
        Spec(Keys.SUGGESTION_BAR_HEIGHT, SettingKind.Choice(SuggestionBarHeight.DEFAULT.id, SuggestionBarHeight.IDS)),
        // "Màu chữ gợi ý" ([SuggestionInk]) — cùng khoá + id iOS.
        Spec(Keys.SUGGESTION_INK, SettingKind.Choice(SuggestionInk.DEFAULT.id, SuggestionInk.IDS)),
        Spec(Keys.FLOATING_KEYBOARD, SettingKind.Bool(false)),
        Spec(Keys.SPLIT_KEYBOARD, SettingKind.Bool(false)),
        Spec(Keys.SHORTCUTS_ENABLED, SettingKind.Bool(true)),
        Spec(Keys.ADD_TONES_CHIP, SettingKind.Bool(false)),
        Spec(Keys.NUMBER_CHIPS, SettingKind.Bool(true)),
        // "Số từ gợi ý" ([SuggestionCount]): 0 = Tự động, 1…5 — cùng khoá iOS.
        Spec(Keys.SUGGESTION_COUNT, SettingKind.IntRange(SuggestionCount.AUTO, SuggestionCount.RANGE)),
        Spec(Keys.KEYBOARD_DISMISS_BUTTON, SettingKind.Bool(false)),   // "Nút ẩn bàn phím" — cùng khoá iOS
        Spec(Keys.MATH_RESULTS, SettingKind.Bool(true)),
        Spec(Keys.TEXT_TOOLS_ENABLED, SettingKind.Bool(true)),
        Spec(Keys.SUGGEST_IN_NO_SUGGEST_FIELDS, SettingKind.Bool(true)),
        Spec(Keys.SMART_TOUCH, SettingKind.Bool(true)),
        Spec(Keys.AUTO_CORRECT, SettingKind.Bool(false)),
        Spec(Keys.AUTO_CAPITALIZE, SettingKind.Bool(true)),
        Spec(Keys.SPACE_SWIPE_LANGUAGE, SettingKind.Bool(false)),
        // "Độ nhạy con trỏ" ([TrackpadSpeed]) — cùng khoá + id iOS.
        Spec(Keys.TRACKPAD_SPEED, SettingKind.Choice(TrackpadSpeed.DEFAULT.id, TrackpadSpeed.IDS)),
        Spec(Keys.SWIPE_KEY_COMMANDS, SettingKind.Bool(false)),
        Spec(Keys.LONG_PRESS_NUMBERS, SettingKind.Bool(true)),
        Spec(Keys.LONG_PRESS_SYMBOLS, SettingKind.Bool(false)),
        Spec(Keys.HOLD_SHIFT_SYMBOLS, SettingKind.Bool(true)),
        Spec(Keys.FLICK_DOWN_ALTERNATES, SettingKind.Bool(false)),
        Spec(Keys.AUTO_SPACE_AFTER_PUNCT, SettingKind.Bool(false)),
        Spec(Keys.KEYBOARD_TRANSPARENCY, SettingKind.IntRange(0, 0..100)),
        Spec(Keys.KEY_LABEL_TRANSPARENCY, SettingKind.IntRange(0, 0..100)),
        // Hệ thống: "Dùng màu hình nền (Material You)" — chỉ Android dùng ([SystemColors]).
        Spec(Keys.SYSTEM_MATERIAL_YOU, SettingKind.Bool(true)),
        // "Hiệu ứng khi bấm phím" (Plus, [KeyEffect]) — cùng khoá + id iOS; lạ ⇒ bỏ qua (máy giữ Không).
        Spec(Keys.KEY_EFFECT, SettingKind.Choice(KeyEffect.DEFAULT.id, KeyEffect.IDS)),
        // "Bạn đồng hành" (Plus, [BuddyCharacter]) — cùng khoá + id iOS; lạ ⇒ bỏ qua (máy giữ Tắt).
        Spec(Keys.KEYBOARD_BUDDY, SettingKind.Choice(BuddyCharacter.DEFAULT.id, BuddyCharacter.IDS)),
        Spec(BuddyBirthday.MONTH_KEY, SettingKind.IntRange(0, 0..12)),
        Spec(BuddyBirthday.DAY_KEY, SettingKind.IntRange(0, 0..31)),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.GIRL), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.BOY), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.CAT), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.CHICK), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.SHIBA), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.KOI), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.PANDA), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.PIG), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.DRAGON), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.EAGLE), SettingKind.BuddyName),
        Spec(com.viettelex.keyboard.BuddyName.key(BuddyCharacter.ROBOT), SettingKind.BuddyName),
        // Kiểu vẽ riêng từng nhân vật ([BuddyStyle]: Hoạt hình / Vẽ nét) — cùng khoá + id iOS; lạ ⇒ bỏ qua.
        Spec(BuddyStyle.key(BuddyCharacter.GIRL), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.BOY), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.CAT), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.CHICK), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.SHIBA), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.KOI), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.PANDA), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.PIG), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.DRAGON), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.EAGLE), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        Spec(BuddyStyle.key(BuddyCharacter.ROBOT), SettingKind.Choice(BuddyStyle.DEFAULT.id, BuddyStyle.IDS)),
        // Vị trí & cỡ ([BuddyPlacement], chung mọi nhân vật) — cùng khoá + miền iOS.
        Spec(Keys.BUDDY_SIZE, SettingKind.IntRange(BuddyPlacement.DEFAULT_SIZE, BuddyPlacement.SIZE_RANGE)),
        Spec(Keys.BUDDY_PAD_RIGHT, SettingKind.IntRange(0, BuddyPlacement.PAD_RANGE)),
        Spec(Keys.BUDDY_PAD_TOP, SettingKind.IntRange(0, BuddyPlacement.PAD_RANGE)),
        // "Hiệu ứng nét vuốt" ([SwipeTrailStyle]) — cùng khoá + id iOS; lạ ⇒ bỏ qua (máy giữ Đơn giản).
        Spec(Keys.SWIPE_TRAIL, SettingKind.Choice(SwipeTrailStyle.DEFAULT.id, SwipeTrailStyle.IDS)),
        // "Âm thanh nét vuốt" ([SwipeSoundStyle]) — cùng khoá + id iOS; lạ ⇒ bỏ qua (máy giữ Tắt).
        Spec(Keys.SWIPE_SOUND, SettingKind.Choice(SwipeSoundStyle.DEFAULT.id, SwipeSoundStyle.IDS)),
        // Cung hoàng đạo (theme "zodiac", "variant") — CHỈ id cung, cùng khoá + id iOS; lạ ⇒ bỏ qua (máy giữ Bạch Dương).
        Spec(ZodiacSign.KEY, SettingKind.Choice(ZodiacSign.DEFAULT.id, ZodiacSign.IDS)),
        // Lá cờ của theme Tự hào ("variant":"pride") — CHỈ id cờ, cùng khoá + id iOS; lạ ⇒ bỏ qua (máy giữ Cầu vồng).
        Spec(PrideFlag.KEY, SettingKind.Choice(PrideFlag.DEFAULT.id, PrideFlag.IDS)),
        // "Tuỳ chỉnh nâng cao" (Plus) RIÊNG từng theme — MỘT chuỗi JSON chuẩn ([KeyStyleStore]), cùng khoá +
        // định dạng iOS. Khoá chung cũ (keyLabelColor…) không còn sao lưu: file cũ có chúng ⇒ bỏ qua như
        // key lạ. "rounded" (chỉ iOS) vẫn giữ để khứ hồi; bàn phím Android vẽ như mặc định.
        Spec(Keys.KEY_STYLES, SettingKind.StyleMap),
        // "Giao diện JSON" — theme tự tạo / dán (Plus): {"id": đặc tả, …}, cùng định dạng iOS.
        Spec(Keys.CUSTOM_THEMES, SettingKind.ThemeMap),
        Spec(Keys.UI_LANGUAGE, SettingKind.Choice(L10n.DEFAULT, L10n.supported)),
        // Ngôn ngữ đích của Dịch trên máy (gói model KHÔNG đi theo — máy mới tải lại trong app).
        Spec(Keys.TRANSLATE_TARGET, SettingKind.Choice(TranslateLangs.DEFAULT_TARGET, TranslateLangs.TARGETS)),
    )
    /**
     * Chỉ để NHẬN (file sao lưu từ bản cũ ≤ Android 1.5.12 / iOS 1.2.17): bộ "Tuỳ chỉnh nâng cao" CHUNG cũ —
     * không xuất; nhập ⇒ chuyển vào theme đang chọn ([migrateLegacyStyle]). iOS giữ y hệt (importOnly).
     */
    val IMPORT_ONLY: List<Spec> = listOf(
        Spec(Keys.KEY_LABEL_COLOR, SettingKind.IntRange(-1, -1..0xFFFFFF)),
        Spec(Keys.KEY_FILL_COLOR, SettingKind.IntRange(-1, -1..0xFFFFFF)),
        Spec(Keys.KEY_CORNER_RADIUS, SettingKind.IntRange(-1, -1..100)),
        Spec(Keys.KEY_FONT_SCALE, SettingKind.IntRange(0, 0..150)),
        Spec(Keys.KEY_LABEL_FONT, SettingKind.Choice(KeyLabelFont.DEFAULT.id, KeyLabelFont.IDS)),
        Spec(Keys.KEY_LABEL_WEIGHT, SettingKind.Choice(KeyLabelWeight.REGULAR.id, KeyLabelWeight.IDS)),
    )
    val byKey: Map<String, Spec> = (all + IMPORT_ONLY).associateBy { it.key }

    /**
     * Nhập bộ chung cũ: có khoá cũ mà KHÔNG có `keyStyles` ⇒ chuyển vào theme đang chọn trên máy này (chỉ khi
     * theme đó chưa có mục riêng) thành `keyStyles`; khoá cũ luôn bị bỏ (không ghi lại).
     */
    fun migrateLegacyStyle(s: Map<String, Any>, theme: String?, styles: Map<String, KeyStyle>): Map<String, Any> {
        val legacyKeys = IMPORT_ONLY.map { it.key }
        if (legacyKeys.none { s.containsKey(it) }) return s
        val out = LinkedHashMap(s)
        legacyKeys.forEach { out.remove(it) }
        if (s.containsKey(Keys.KEY_STYLES)) return out
        val legacy = KeyStyle.loadLegacy { s[it] }
        if (legacy.isDefault) return out
        out[Keys.KEY_STYLES] = KeyStyleStore.serialize(KeyStyleStore.migrate(theme, styles, legacy).styles)
        return out
    }
}

/** Giá trị setting: Boolean, Int (đã kẹp phạm vi) hoặc String ([SettingKind.Choice]). */
typealias BackupSettingsMap = Map<String, Any>

/** Từ đã học — cùng cấu trúc [UserLangModel] (tri key = "p2\u0001p1"). */
data class LearnedWords(
    val uni: Map<String, Int> = emptyMap(),
    val bi: Map<String, Map<String, Int>> = emptyMap(),
    val tri: Map<String, Map<String, Int>> = emptyMap(),
    /** Từ thêm tay (Từ điển cá nhân), dạng hiển thị ("VietTelex"). JSON: "manual" (tuỳ chọn). */
    val manual: List<String> = emptyList(),
) {
    val isEmpty get() = uni.isEmpty() && bi.isEmpty() && tri.isEmpty() && manual.isEmpty()

    /** Gộp khi nhập: count lớn hơn mỗi mục (nhập lại cùng file không nhân đôi). */
    fun merged(o: LearnedWords): LearnedWords {
        fun m1(a: Map<String, Int>, b: Map<String, Int>) =
            HashMap(a).apply { for ((k, v) in b) merge(k, v) { x, y -> maxOf(x, y) } }
        fun m2(a: Map<String, Map<String, Int>>, b: Map<String, Map<String, Int>>): Map<String, Map<String, Int>> {
            val out = HashMap<String, Map<String, Int>>(a)
            for ((k, v) in b) out[k] = m1(out[k] ?: emptyMap(), v)
            return out
        }
        // Từ thêm tay: hợp theo lowercase, giữ dạng hiển thị đang có.
        val man = LinkedHashMap<String, String>()
        for (w in manual + o.manual) man.putIfAbsent(w.lowercase(), w)
        return LearnedWords(m1(uni, o.uni), m2(bi, o.bi), m2(tri, o.tri), man.values.toList())
    }
}

data class BackupPayload(
    val createdAt: Instant? = null,
    val platform: String? = null,
    /** null = file không có mục này (nhập thì không đụng). */
    val settings: BackupSettingsMap? = null,
    val shortcuts: Map<String, String>? = null,
    val templates: List<TemplateItem>? = null,
    val learnedWords: LearnedWords? = null,
    /** Mốc thêm/sửa gõ tắt (ms, [ShortcutOrder]) — null = file không có (bản cũ). */
    val shortcutsAdded: Map<String, Long>? = null,
)

class BackupException(val reason: Reason, val fileVersion: Int = 0) : Exception(reason.name) {
    enum class Reason { NOT_JSON, NOT_BACKUP, TOO_NEW }
    val userMessage: String get() = when (reason) {
        Reason.NOT_JSON -> tr("File không phải JSON hợp lệ.")
        Reason.NOT_BACKUP -> tr("Không phải file sao lưu VietTelex.")
        Reason.TOO_NEW -> tr("File sao lưu từ phiên bản mới hơn (định dạng %d) — hãy cập nhật VietTelex.", fileVersion)
    }
}

object BackupCodec {
    const val FORMAT = "viettelex-backup"
    const val VERSION = 1
    const val MAX_CHARS = 8 * 1024 * 1024

    fun encode(p: BackupPayload): String {
        val root = LinkedHashMap<String, Any?>()
        root["format"] = FORMAT; root["version"] = VERSION; root["minReaderVersion"] = 1
        p.createdAt?.let { root["createdAt"] = DateTimeFormatter.ISO_INSTANT.format(it.truncatedTo(ChronoUnit.SECONDS)) }
        p.platform?.let { root["platform"] = it }
        p.settings?.let { root["settings"] = it }
        p.shortcuts?.let { root["shortcuts"] = it }
        p.shortcutsAdded?.takeIf { it.isNotEmpty() }?.let { root["shortcutsAdded"] = it }
        p.templates?.let { t -> root["templates"] = t.map { mapOf("label" to it.label, "text" to it.text) } }
        p.learnedWords?.let {
            val lw = mutableMapOf<String, Any>("uni" to it.uni, "bi" to it.bi, "tri" to it.tri)
            if (it.manual.isNotEmpty()) lw["manual"] = it.manual
            root["learnedWords"] = lw
        }
        return MiniJson.write(root, pretty = true) + "\n"
    }

    fun decode(text: String): BackupPayload {
        if (text.length > MAX_CHARS) throw BackupException(BackupException.Reason.NOT_BACKUP)
        val root = try { MiniJson.parse(text.removePrefix("﻿")) } catch (e: IllegalArgumentException) { null }
            as? Map<*, *> ?: throw BackupException(BackupException.Reason.NOT_JSON)
        if (root["format"] != FORMAT) throw BackupException(BackupException.Reason.NOT_BACKUP)
        val min = intValue(root["minReaderVersion"])
        if (min != null && min > VERSION) {
            throw BackupException(BackupException.Reason.TOO_NEW, intValue(root["version"]) ?: min)
        }
        val settings = (root["settings"] as? Map<*, *>)?.let { s ->
            val out = LinkedHashMap<String, Any>()
            for ((k, raw) in s) {
                val spec = BackupSettings.byKey[k as String] ?: continue   // key lạ: bỏ
                when (val kind = spec.kind) {
                    is SettingKind.Bool -> (raw as? Boolean)?.let { out[k] = it }
                    is SettingKind.IntRange -> intValue(raw)?.let { out[k] = it.coerceIn(kind.range) }
                    is SettingKind.Choice -> (raw as? String)?.takeIf { it in kind.allowed }?.let { out[k] = it }
                    SettingKind.BuddyName -> (raw as? String)?.let { out[k] = com.viettelex.keyboard.BuddyName.clean(it) }
                    SettingKind.StyleMap -> (raw as? String)?.let(KeyStyleStore::normalize)?.let { out[k] = it }
                    SettingKind.ThemeMap -> (raw as? String)?.let(CustomThemeStore::normalize)?.let { out[k] = it }
                }
            }
            out
        }
        val shortcuts = (root["shortcuts"] as? Map<*, *>)?.let { m ->
            val out = LinkedHashMap<String, String>()
            for ((k, v) in m) {
                val key = (k as String).trim(' ', '\t')
                if (key.isNotEmpty() && v is String && v.isNotEmpty()) out[key] = v
            }
            out
        }
        val shortcutsAdded = (root["shortcutsAdded"] as? Map<*, *>)?.let { m ->
            val out = LinkedHashMap<String, Long>()
            for ((k, v) in m) {
                val t = when (v) { is Long -> v; is Double -> if (v.isFinite() && v == Math.rint(v)) v.toLong() else null; else -> null }
                if (t != null && t > 0 && (k as String).isNotEmpty()) out[k] = t
            }
            out
        }
        val templates = (root["templates"] as? List<*>)?.let { arr ->
            val out = ArrayList<TemplateItem>()
            for (e in arr) {
                val o = e as? Map<*, *> ?: continue
                val t = o["text"] as? String ?: continue
                if (t.isEmpty() || out.any { it.text == t }) continue
                out.add(TemplateItem(o["label"] as? String ?: "", t))
            }
            out
        }
        val learned = (root["learnedWords"] as? Map<*, *>)?.let {
            LearnedWords(counts(it["uni"]), nested(it["bi"]), nested(it["tri"]),
                (it["manual"] as? List<*>)?.mapNotNull { w -> (w as? String)?.let(UserLangModel::normalizeManual) } ?: emptyList())
        }
        val createdAt = (root["createdAt"] as? String)?.let { runCatching { Instant.parse(it) }.getOrNull() }
        return BackupPayload(createdAt, root["platform"] as? String, settings, shortcuts, templates, learned, shortcutsAdded)
    }

    /** Số nguyên JSON (không nhận bool/chuỗi/số lẻ). */
    private fun intValue(v: Any?): Int? = when (v) {
        is Long -> if (v in Int.MIN_VALUE..Int.MAX_VALUE) v.toInt() else null
        is Double -> if (v.isFinite() && v == Math.rint(v) && kotlin.math.abs(v) < 1e9) v.toInt() else null
        else -> null
    }
    private fun counts(v: Any?): Map<String, Int> {
        val o = v as? Map<*, *> ?: return emptyMap()
        val out = HashMap<String, Int>()
        for ((k, raw) in o) { val c = intValue(raw); if (c != null && c > 0 && (k as String).isNotEmpty()) out[k] = c }
        return out
    }
    private fun nested(v: Any?): Map<String, Map<String, Int>> {
        val o = v as? Map<*, *> ?: return emptyMap()
        val out = HashMap<String, Map<String, Int>>()
        for ((k, raw) in o) { val c = counts(raw); if (c.isNotEmpty()) out[k as String] = c }
        return out
    }
}

/**
 * Chính sách nhập (giống iOS BackupMerge): settings theo file; gõ tắt gộp, cùng trigger
 * thì file thắng; mẫu câu gộp bỏ trùng theo câu; từ đã học lấy count lớn hơn.
 */
object BackupMerge {
    fun shortcuts(current: Map<String, String>, imported: Map<String, String>): Map<String, String> =
        LinkedHashMap(current).apply { putAll(imported) }

    fun templates(current: List<TemplateItem>, imported: List<TemplateItem>): List<TemplateItem> {
        val out = current.toMutableList()
        for (t in imported) if (out.none { it.text == t.text }) out.add(t)
        return out
    }

    fun summary(p: BackupPayload, templatesAdded: Int, shortcutsChanged: Int): String {
        val parts = ArrayList<String>()
        p.settings?.takeIf { it.isNotEmpty() }?.let { parts.add(tr("%d cài đặt", it.size)) }
        if (p.shortcuts != null) parts.add(tr("%d gõ tắt", shortcutsChanged))
        if (p.templates != null) parts.add(tr("%d mẫu câu mới", templatesAdded))
        p.learnedWords?.takeIf { !it.isEmpty }?.let { parts.add(tr("%d từ đã học", it.uni.size)) }
        return if (parts.isEmpty()) tr("File không có dữ liệu để nhập.") else tr("Đã nhập %s.", parts.joinToString(", "))
    }
}

/**
 * Nối file sao lưu với kho key-value của Android (SharedPreferences [Keys.PREFS]) mà
 * không phụ thuộc Android: [read] = giá trị thô của key (vd `prefs.all[key]`).
 */
object BackupPrefs {
    /** Gõ tắt: pref [Keys.SHORTCUTS] lưu CHUỖI YAML ([ShortcutFile]) — đúng chỗ IME đọc. */
    const val SHORTCUTS_KEY = Keys.SHORTCUTS
    /** Tuỳ chọn "Kèm từ đã học khi xuất file" (không sao lưu chính nó). */
    const val INCLUDE_LEARNED_KEY = "backupIncludeLearned"

    fun settings(read: (String) -> Any?): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        for (spec in BackupSettings.all) when (val k = spec.kind) {
            is SettingKind.Bool -> out[spec.key] = (read(spec.key) as? Boolean) ?: k.default
            is SettingKind.IntRange -> out[spec.key] = ((read(spec.key) as? Number)?.toInt() ?: k.default).coerceIn(k.range)
            is SettingKind.Choice -> out[spec.key] = (read(spec.key) as? String)?.takeIf { it in k.allowed } ?: k.default
            SettingKind.BuddyName -> out[spec.key] = com.viettelex.keyboard.BuddyName.clean((read(spec.key) as? String) ?: "")
            SettingKind.StyleMap -> out[spec.key] = (read(spec.key) as? String)?.let(KeyStyleStore::normalize) ?: KeyStyleStore.EMPTY
            SettingKind.ThemeMap -> out[spec.key] = (read(spec.key) as? String)?.let(CustomThemeStore::normalize) ?: "{}"
        }
        return out
    }

    fun shortcutsFromPref(raw: Any?): Map<String, String> = ShortcutFile.parse(raw as? String)
    fun shortcutsToPref(m: Map<String, String>): String = ShortcutFile.exportYAML(m)

    fun snapshot(read: (String) -> Any?, templates: List<TemplateItem>, learned: LearnedWords?, now: Instant = Instant.now()): BackupPayload {
        val sc = shortcutsFromPref(read(SHORTCUTS_KEY))
        return BackupPayload(now, "android", settings(read), sc, templates, learned,
            ShortcutOrder.fromPref(read(Keys.SHORTCUTS_ADDED)).filterKeys { it in sc })
    }

    /** Kết quả nhập: các pref cần ghi (Boolean/Int/String), danh sách mẫu câu mới, từ đã học để gộp. */
    class ImportPlan(val writes: Map<String, Any>, val templates: List<TemplateItem>?,
                     val learnedWords: LearnedWords?, val summary: String)

    fun plan(p: BackupPayload, read: (String) -> Any?, currentTemplates: List<TemplateItem>,
             now: Long = System.currentTimeMillis()): ImportPlan {
        val writes = LinkedHashMap<String, Any>()
        // File từ bản cũ: bộ "Tuỳ chỉnh nâng cao" chung ⇒ vào theme đang chọn trên máy này.
        p.settings?.let { writes.putAll(BackupSettings.migrateLegacyStyle(it, read(Keys.KEYBOARD_THEME) as? String,
            KeyStyleStore.parse(read(Keys.KEY_STYLES) as? String))) }   // bản lưu thô: bộ cũ trong file thắng bộ cũ trên máy
        var changed = 0
        p.shortcuts?.let { sc ->
            val cur = shortcutsFromPref(read(SHORTCUTS_KEY))
            changed = sc.count { cur[it.key] != it.value }
            val merged = BackupMerge.shortcuts(cur, sc)
            writes[SHORTCUTS_KEY] = shortcutsToPref(merged)
            writes[Keys.SHORTCUTS_ADDED] = ShortcutOrder.toPref(ShortcutOrder.imported(
                ShortcutOrder.fromPref(read(Keys.SHORTCUTS_ADDED)), p.shortcutsAdded, cur, sc, merged, now))
        }
        val tpl = p.templates?.let { BackupMerge.templates(currentTemplates, it) }
        val added = tpl?.let { it.size - currentTemplates.size } ?: 0
        val lw = p.learnedWords?.takeIf { !it.isEmpty }
        return ImportPlan(writes, tpl, lw, BackupMerge.summary(p, added, changed))
    }
}

/**
 * JSON tối giản không phụ thuộc thư viện (module JVM thuần, không có org.json).
 * parse ⇒ Map (LinkedHashMap) / List / String / Long / Double / Boolean / null.
 */
object MiniJson {
    fun parse(s: String): Any? {
        val p = P(s); p.ws(); val v = p.value(); p.ws()
        require(p.i == s.length) { "trailing data" }
        return v
    }

    fun write(v: Any?, pretty: Boolean): String = StringBuilder().also { w(it, v, pretty, 0) }.toString()

    private fun w(sb: StringBuilder, v: Any?, pretty: Boolean, depth: Int) {
        fun nl(d: Int) { if (pretty) { sb.append('\n'); repeat(d) { sb.append("  ") } } }
        when (v) {
            null -> sb.append("null")
            is Boolean -> sb.append(v)
            is Int, is Long -> sb.append(v)
            is Number -> sb.append(v.toDouble())
            is String -> str(sb, v)
            is Map<*, *> -> {
                if (v.isEmpty()) { sb.append("{}"); return }
                sb.append('{')
                // Khoá sắp xếp (như iOS .sortedKeys) — file ổn định, dễ diff.
                v.entries.sortedBy { it.key as String }.forEachIndexed { i, (k, x) ->
                    if (i > 0) sb.append(',')
                    nl(depth + 1); str(sb, k as String); sb.append(if (pretty) ": " else ":"); w(sb, x, pretty, depth + 1)
                }
                nl(depth); sb.append('}')
            }
            is List<*> -> {
                if (v.isEmpty()) { sb.append("[]"); return }
                sb.append('[')
                v.forEachIndexed { i, x -> if (i > 0) sb.append(','); nl(depth + 1); w(sb, x, pretty, depth + 1) }
                nl(depth); sb.append(']')
            }
            else -> str(sb, v.toString())
        }
    }

    private fun str(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) when {
            c == '"' -> sb.append("\\\"")
            c == '\\' -> sb.append("\\\\")
            c == '\n' -> sb.append("\\n")
            c == '\r' -> sb.append("\\r")
            c == '\t' -> sb.append("\\t")
            c < ' ' -> sb.append(String.format("\\u%04x", c.code))
            else -> sb.append(c)
        }
        sb.append('"')
    }

    private class P(val s: String) {
        var i = 0
        fun ws() { while (i < s.length && s[i] in " \t\r\n") i++ }
        fun peek(): Char { require(i < s.length) { "eof" }; return s[i] }
        fun expect(c: Char) { require(peek() == c) { "expected $c at $i" }; i++ }
        fun value(): Any? = when (peek()) {
            '{' -> obj()
            '[' -> arr()
            '"' -> string()
            't' -> lit("true", true)
            'f' -> lit("false", false)
            'n' -> lit("null", null)
            else -> number()
        }
        fun lit(word: String, v: Any?): Any? { require(s.startsWith(word, i)) { "bad literal" }; i += word.length; return v }
        fun obj(): Map<String, Any?> {
            expect('{'); val m = LinkedHashMap<String, Any?>(); ws()
            if (peek() == '}') { i++; return m }
            while (true) {
                ws(); val k = string(); ws(); expect(':'); ws(); m[k] = value(); ws()
                if (peek() == ',') { i++; continue }
                expect('}'); return m
            }
        }
        fun arr(): List<Any?> {
            expect('['); val l = ArrayList<Any?>(); ws()
            if (peek() == ']') { i++; return l }
            while (true) {
                ws(); l.add(value()); ws()
                if (peek() == ',') { i++; continue }
                expect(']'); return l
            }
        }
        fun string(): String {
            expect('"'); val sb = StringBuilder()
            while (true) {
                require(i < s.length) { "unterminated string" }
                when (val c = s[i++]) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        require(i < s.length) { "bad escape" }
                        when (val e = s[i++]) {
                            'n' -> sb.append('\n'); 'r' -> sb.append('\r'); 't' -> sb.append('\t')
                            'b' -> sb.append('\b'); 'f' -> sb.append('\u000C')
                            '"', '\\', '/' -> sb.append(e)
                            'u' -> {
                                require(i + 4 <= s.length) { "bad \\u" }
                                sb.append(s.substring(i, i + 4).toIntOrNull(16)?.toChar() ?: throw IllegalArgumentException("bad \\u"))
                                i += 4
                            }
                            else -> throw IllegalArgumentException("bad escape \\$e")
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }
        fun number(): Any {
            val start = i
            if (i < s.length && s[i] == '-') i++
            while (i < s.length && (s[i].isDigit() || s[i] in ".eE+-")) i++
            val t = s.substring(start, i)
            require(t.isNotEmpty() && t != "-") { "bad value at $start" }
            return if (t.any { it in ".eE" }) t.toDoubleOrNull() ?: throw IllegalArgumentException("bad number")
            else t.toLongOrNull() ?: t.toDoubleOrNull() ?: throw IllegalArgumentException("bad number")
        }
    }
}
