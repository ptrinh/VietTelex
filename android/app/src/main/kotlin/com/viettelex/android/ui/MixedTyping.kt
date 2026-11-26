package com.viettelex.android.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.OnboardingFlow
import com.viettelex.keyboard.OnboardingProfile
import com.viettelex.keyboard.OnboardingSettings
import androidx.compose.ui.semantics.selected
import com.viettelex.keyboard.RetroEnglishUI
import com.viettelex.keyboard.tr

// Nhóm thu gọn "Gõ lẫn tiếng Anh" ngay dưới mục Kiểu gõ (tab Kiểu Gõ) — docs/ONBOARDING-SPEC.md §4,
// thu gọn theo docs/SETTINGS-CLEANUP-SPEC.md §1: cấp 1 chỉ còn bộ chọn hồ sơ + Vuốt phím cách +
// Từ điển cá nhân + dòng "Nâng cao" (trang con: công tắc nhận diện tiếng Anh). "Vuốt từ tiếng Anh"
// về trang Gõ vuốt. Key SharedPreferences KHÔNG đổi ⇒ hành vi + sao lưu/khôi phục giữ nguyên.
// Song sinh iOS Shared/MixedTypingUI.swift + App/MixedTypingSection.swift.

/** Mục của nhóm — [viTitle] = khoá dịch = chữ trên dòng; [prefKey] = key lưu (null: không phải công tắc). */
internal enum class MixedTypingItem(val viTitle: String, val keywords: String, val prefKey: String?, val placement: Placement) {
    Section(MIXED_TITLE, "mixed gõ mixed việt/anh trộn song ngữ bilingual tiếng anh english việt anh", null, Placement.Group), // l10n-skip: từ khoá tìm kiếm
    SpaceSwipeLanguage("Vuốt phím cách đổi Tiếng Việt / Tiếng Anh", "space ngôn ngữ english language vuốt phím cách", Keys.SPACE_SWIPE_LANGUAGE, Placement.Group), // l10n-key
    UserDictionary("Từ điển cá nhân", "dictionary tên riêng thuật ngữ từ tiếng anh", null, Placement.Group), // l10n-key
    AutoRestore("Tự khôi phục từ tiếng Anh", "english google restore khôi phục nâng cao advanced", Keys.AUTO_RESTORE, Placement.Advanced), // l10n-key
    ContextualEnglish("Quyết định theo ngữ cảnh", "context ngữ cảnh english he is nâng cao advanced", Keys.CONTEXTUAL_ENGLISH, Placement.Advanced), // l10n-key
    RetroEnglish("Tự sửa từ phía trước", "sửa ngược retro english thử nghiệm experimental", Keys.RETRO_ENGLISH_AUTO, Placement.Advanced), // l10n-key
    EnglishByFrequency("Đoán từ trùng theo tần suất", "tần suất frequency his hí từ trùng collision thử nghiệm experimental", Keys.ENGLISH_BY_FREQUENCY, Placement.Advanced); // l10n-key

    val title: String get() = tr(viTitle)

    /** Chỗ của dòng: ngay trong nhóm (cấp 1) hay trang con "Nâng cao" của nhóm. */
    enum class Placement { Group, Advanced }

    /** Đích của ô tìm cài đặt: trang chứa dòng (null = trang chính tab Kiểu Gõ) + có mở nhóm không. */
    val target: KieuGoTarget
        get() = KieuGoTarget("mixed:$name", if (placement == Placement.Advanced) KieuGoPage.MixedAdvanced else null,
            expandMixed = placement == Placement.Group)
}

/** Tên nhóm — cùng tên/thứ tự trên iOS và Android. */
internal const val MIXED_TITLE = "Gõ lẫn tiếng Anh" // l10n-key

/** Dòng phụ của mục "Nâng cao" trong nhóm — liệt kê những gì bên trong (SETTINGS-CLEANUP-SPEC §0.3). */
internal const val MIXED_ADVANCED_SUMMARY = "Khôi phục từ tiếng Anh, ngữ cảnh, khi trùng từ, sửa từ phía trước…" // l10n-key

internal object MixedTypingUI {
    /** Tuỳ chọn chỉ-Telex khi đang chọn VNI (SETTINGS-CLEANUP-SPEC §0.4). */
    const val TELEX_ONLY = "Chỉ áp dụng cho Telex" // l10n-key

    /** Dòng của nhóm khi mở (thứ tự hiển thị). */
    enum class Row { VniNote, ProfilePicker, SpaceSwipeLanguage, UserDictionary, Advanced }

    /** id cuộn tới / tô sáng của dòng ghi chú VNI. */
    const val VNI_NOTE_ID = "mixed:VniNote"

    /**
     * Dòng hiện trong nhóm (SETTINGS-CLEANUP-SPEC §1, 06/11/2026). VNI đặt dấu bằng số nên từ tiếng Anh
     * gõ ra nguyên vẹn ⇒ ẩn bộ chọn hồ sơ + "Nâng cao", thay bằng MỘT dòng ghi chú. Giữ Vuốt phím cách
     * (cách chuyển ngôn ngữ) + Từ điển cá nhân (từ đã học phục vụ cả gợi ý, không chỉ khôi phục).
     * Chỉ là hiển thị: key/giá trị đã lưu giữ nguyên, đổi lại Telex thấy y như cũ.
     */
    fun rows(vniMode: Boolean): List<Row> =
        if (vniMode) listOf(Row.VniNote, Row.SpaceSwipeLanguage, Row.UserDictionary)
        else listOf(Row.ProfilePicker, Row.SpaceSwipeLanguage, Row.UserDictionary, Row.Advanced)

    /**
     * Mục bị ẩn: VNI ⇒ mọi mục của trang "Nâng cao" nhóm; "Quyết định theo ngữ cảnh" tắt ⇒ hai công
     * tắc con ngay dưới nó (Tự sửa từ phía trước, Đoán từ trùng theo tần suất — SETTINGS-CLEANUP-SPEC §6,
     * [RetroEnglishUI.switchVisible]). Giá trị đã lưu giữ nguyên.
     */
    fun hidden(item: MixedTypingItem, vniMode: Boolean, contextualEnglish: Boolean = true): Boolean = when {
        vniMode && item.placement == MixedTypingItem.Placement.Advanced -> true
        item == MixedTypingItem.RetroEnglish || item == MixedTypingItem.EnglishByFrequency ->
            !RetroEnglishUI.switchVisible(contextualEnglish, vniMode)
        else -> false
    }

    /**
     * Đích tìm kiếm thực sự: mục bị ẩn khi VNI ⇒ mở nhóm, cuộn tới dòng ghi chú; công tắc con bị ẩn vì
     * ngữ cảnh tắt ⇒ tô sáng "Quyết định theo ngữ cảnh" (nơi bật lại).
     */
    fun resolve(target: KieuGoTarget, vniMode: Boolean, contextualEnglish: Boolean = true): KieuGoTarget = when {
        vniMode && target.page == KieuGoPage.MixedAdvanced -> KieuGoTarget(VNI_NOTE_ID, null, expandMixed = true)
        MixedTypingItem.entries.any { it.target == target && hidden(it, vniMode, contextualEnglish) } ->
            MixedTypingItem.ContextualEnglish.target
        else -> target
    }

    /** Trang con được phép mở: trang "Nâng cao" của nhóm không mở được khi VNI. */
    fun page(page: KieuGoPage?, vniMode: Boolean): KieuGoPage? =
        if (vniMode && page == KieuGoPage.MixedAdvanced) null else page

    /** Phần (khoá dịch) của dòng tóm tắt khi thu gọn — VNI bỏ hai mục nhận diện tiếng Anh đã ẩn. */
    fun summaryParts(vniMode: Boolean, autoRestore: Boolean, contextual: Boolean, spaceSwipe: Boolean,
                     swipeEnglish: Boolean): List<String> = buildList {
        if (!vniMode && autoRestore) add("Khôi phục tiếng Anh") // l10n-key
        if (!vniMode && contextual) add("Ngữ cảnh") // l10n-key
        if (spaceSwipe) add("Vuốt phím cách") // l10n-key
        if (swipeEnglish) add("Vuốt từ tiếng Anh") // l10n-key — ở trang Gõ vuốt, không bị ẩn
    }
}

/**
 * Trạng thái mở/thu nhóm trong phiên chạy app (KHÔNG lưu): mở app là thu gọn. Ô tìm cài đặt mở
 * nhóm qua [KieuGoNav.request] (`target.expandMixed`).
 */
internal object MixedTypingFocus {
    val expanded = mutableStateOf(false)
}

@Composable
internal fun MixedTypingSection() {
    val c = LocalVT.current
    var expanded by MixedTypingFocus.expanded

    val autoRestore by rememberBoolPref(Keys.AUTO_RESTORE, Prefs.D.autoRestore)
    val contextual by rememberBoolPref(Keys.CONTEXTUAL_ENGLISH, Prefs.D.contextualEnglish)
    val spaceSwipe by rememberBoolPref(Keys.SPACE_SWIPE_LANGUAGE, Prefs.D.spaceSwipeLanguage)
    val swipeOn by rememberBoolPref(Keys.SWIPE_TYPING, Prefs.D.swipeTyping)
    // "Vuốt từ tiếng Anh" ở trang Gõ vuốt, nhưng bộ chọn hồ sơ vẫn đặt + so giá trị của nó.
    val swipeEn by rememberBoolPref(Keys.SWIPE_ENGLISH, Prefs.D.swipeEnglish)
    val retro by rememberBoolPref(Keys.RETRO_ENGLISH_AUTO, Prefs.D.retroEnglishAuto)
    val freq by rememberBoolPref(Keys.ENGLISH_BY_FREQUENCY, Prefs.D.englishByFrequency)
    val currentValues = mapOf(Keys.AUTO_RESTORE to autoRestore, Keys.CONTEXTUAL_ENGLISH to contextual,
        Keys.RETRO_ENGLISH_AUTO to retro, Keys.ENGLISH_BY_FREQUENCY to freq,
        Keys.SPACE_SWIPE_LANGUAGE to spaceSwipe, Keys.SWIPE_ENGLISH to swipeEn)

    val vni by rememberBoolPref(Keys.VNI_MODE, Prefs.D.vniMode)
    val summary = MixedTypingUI.summaryParts(vni, autoRestore, contextual, spaceSwipe, swipeOn && swipeEn)
        .joinToString(" · ") { tr(it) }.ifEmpty { tr("Đang tắt") }

    VTSection(footer = if (expanded) APPLY_NOTE else null) {
        Highlightable(MixedTypingItem.Section.target.id) {
            val stateText = if (expanded) tr("Mở rộng") else tr("Thu gọn")
            VTRow(onClick = { expanded = !expanded }, modifier = Modifier.semantics { stateDescription = stateText }) {
                Box(Modifier.size(29.dp).background(Color(0xFF30B0C7), RoundedCornerShape(7.dp)), contentAlignment = Alignment.Center) {
                    GlyphIcon(Glyph.Globe, Color.White, 18.dp)
                }
                Column(Modifier.weight(1f).padding(start = 12.dp, end = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(tr(MIXED_TITLE), style = VTType.body, color = c.label)
                    Text(summary, style = VTType.footnote, color = c.secondary, maxLines = 1)
                }
                val angle by animateFloatAsState(if (expanded) 90f else 0f, label = "chev")
                Text("›", style = VTType.title3, color = c.tertiary, modifier = Modifier.rotate(angle))
            }
        }
        if (!expanded) return@VTSection

        MixedTypingUI.rows(vni).forEachIndexed { i, row ->
            if (i > 0) RowDivider()
            when (row) {
                // VNI: thay cả bộ chọn hồ sơ + Nâng cao bằng một dòng (SETTINGS-CLEANUP-SPEC §1).
                MixedTypingUI.Row.VniNote -> {
                    RowDivider()
                    Highlightable(MixedTypingUI.VNI_NOTE_ID) {
                        Text(tr(SettingCaption.vniMixedNote), style = VTType.footnote, color = c.secondary,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp))
                    }
                }
                MixedTypingUI.Row.ProfilePicker -> ProfilePicker(currentValues)
                // Cấp 1 vì là cách chuyển ngôn ngữ (SETTINGS-CLEANUP-SPEC §1).
                MixedTypingUI.Row.SpaceSwipeLanguage -> Highlightable(MixedTypingItem.SpaceSwipeLanguage.target.id) {
                    BoolToggle(Keys.SPACE_SWIPE_LANGUAGE, Prefs.D.spaceSwipeLanguage, tr("Vuốt phím cách đổi Tiếng Việt / Tiếng Anh"),
                        tr(SettingCaption.spaceSwipeLanguage))
                }
                MixedTypingUI.Row.UserDictionary -> Highlightable(MixedTypingItem.UserDictionary.target.id) { UserDictRow() }
                MixedTypingUI.Row.Advanced ->
                    NavRow(tr("Nâng cao"), tr(MIXED_ADVANCED_SUMMARY)) { KieuGoNav.page.value = KieuGoPage.MixedAdvanced }
            }
        }
    }
}

/** Trang con "Nâng cao" của nhóm Gõ lẫn tiếng Anh: công tắc nhận diện tiếng Anh. */
@Composable
internal fun MixedAdvancedPage(onBack: () -> Unit) {
    var pickingApps by remember { mutableStateOf(false) }
    if (pickingApps) { EnglishAppsPage { pickingApps = false }; return }
    val contextual by rememberBoolPref(Keys.CONTEXTUAL_ENGLISH, Prefs.D.contextualEnglish)
    val vni by rememberBoolPref(Keys.VNI_MODE, Prefs.D.vniMode)
    SubPageHeader(tr("Nâng cao"), onBack, backTitle = "‹ " + AppTab.KieuGo.title)
    VTSection(header = tr(MIXED_TITLE), footer = APPLY_NOTE) {
        Highlightable(MixedTypingItem.AutoRestore.target.id) {
            BoolToggle(Keys.AUTO_RESTORE, Prefs.D.autoRestore, tr("Tự khôi phục từ tiếng Anh"), tr(SettingCaption.autoRestore))
        }
        RowDivider()
        Highlightable(MixedTypingItem.ContextualEnglish.target.id) {
            BoolToggle(Keys.CONTEXTUAL_ENGLISH, Prefs.D.contextualEnglish, tr("Quyết định theo ngữ cảnh"), tr(SettingCaption.contextualEnglish))
        }
        // Hai công tắc thử nghiệm phụ thuộc ngữ cảnh: ngay dưới công tắc cha, thụt vào; ngữ cảnh tắt ⇒
        // ẨN (SETTINGS-CLEANUP-SPEC §6), bật lại là hiện tại chỗ.
        for (item in listOf(MixedTypingItem.RetroEnglish, MixedTypingItem.EnglishByFrequency)) {
            if (MixedTypingUI.hidden(item, vni, contextual)) continue
            val (default, caption) = if (item == MixedTypingItem.RetroEnglish) Prefs.D.retroEnglishAuto to SettingCaption.retroEnglish
                else Prefs.D.englishByFrequency to SettingCaption.englishByFrequency
            RowDivider(32.dp)
            Highlightable(item.target.id) {
                DependentToggle(item.prefKey!!, default, tr(item.viTitle), tr(caption), null, experimental = true)
            }
        }
    }
    val englishApps by rememberStringPref(Keys.ENGLISH_APPS, "")
    VTSection {
        val n = com.viettelex.keyboard.EnglishApps.parse(englishApps).size
        NavRow(tr(ENGLISH_APPS_TITLE), if (n == 0) tr("Chưa chọn app nào") else tr("%d app").format(n)) { pickingApps = true }
    }
}

internal const val ENGLISH_APPS_TITLE = "Luôn gõ tiếng Anh trong app" // l10n-key

/** Danh sách app có biểu tượng trên màn hình chính; bật = bàn phím tự ở Tiếng Anh trong app đó ([EnglishApps]). */
@Composable
internal fun EnglishAppsPage(onBack: () -> Unit) {
    val ctx = LocalContext.current
    var raw by rememberStringPref(Keys.ENGLISH_APPS, "")
    val chosen = com.viettelex.keyboard.EnglishApps.parse(raw)
    SubPageHeader(tr(ENGLISH_APPS_TITLE), onBack, backTitle = "‹ " + tr("Nâng cao"))
    // Nhãn app đọc ở luồng nền (hàng trăm app); app đã chọn mà đã gỡ vẫn hiện để bỏ chọn được.
    val apps by androidx.compose.runtime.produceState<List<Pair<String, String>>?>(null) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val pm = ctx.packageManager
            val launch = android.content.Intent(android.content.Intent.ACTION_MAIN).addCategory(android.content.Intent.CATEGORY_LAUNCHER)
            pm.queryIntentActivities(launch, 0)
                .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
                .filter { it.first != ctx.packageName }
                .distinctBy { it.first }
                .sortedBy { it.second.lowercase() }
        }
    }
    val list = apps
    VTSection(footer = tr(SettingCaption.englishApps)) {
        if (list == null) {
            VTRow { Text(tr("Đang tải danh sách app…"), style = VTType.body, color = LocalVT.current.secondary) }
        } else {
            val known = list.map { it.first }.toSet()
            val rows = chosen.filter { it !in known }.sorted().map { it to it } +
                list.sortedByDescending { it.first in chosen }
            rows.forEachIndexed { i, (pkg, label) ->
                if (i > 0) RowDivider()
                SettingToggle(label, if (label == pkg) null else pkg, pkg in chosen) { on ->
                    raw = com.viettelex.keyboard.EnglishApps.serialize(com.viettelex.keyboard.EnglishApps.toggled(chosen, pkg, on))
                }
            }
        }
    }
}

/** Dòng "Từ điển cá nhân" (mở hộp thoại từ điển) — ở nhóm mixed và trang Sửa lỗi & gợi ý. */
@Composable
internal fun UserDictRow() {
    val c = LocalVT.current
    var showDict by remember { mutableStateOf(false) }
    VTRow(onClick = { showDict = true }) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(tr("Từ điển cá nhân"), style = VTType.body, color = c.label)
            Text(tr(SettingCaption.userDictionary), style = VTType.footnote, color = c.secondary)
        }
        Text("›", style = VTType.title3, color = c.tertiary)
    }
    if (showDict) UserDictDialog { showDict = false }
}

/**
 * Bộ chọn hồ sơ ở đầu nhóm (ONBOARDING-SPEC §4): ba nút radio + "Tuỳ chỉnh" (chỉ hiện, đã chọn sẵn,
 * khi cài đặt không khớp hồ sơ nào). Đang Tuỳ chỉnh mà áp sẽ đổi công tắc ⇒ hỏi xác nhận. Như iOS.
 */
@Composable
private fun ProfilePicker(current: Map<String, Boolean>) {
    val c = LocalVT.current
    val ctx = LocalContext.current
    val lastProfile by rememberStringPref(OnboardingFlow.PROFILE_KEY, "")
    val last = OnboardingProfile.of(lastProfile)
    val matched = OnboardingSettings.match(current, last)
    var confirming by remember { mutableStateOf<OnboardingProfile?>(null) }

    RowDivider()
    // Câu hỏi + nút radio (chọn MỘT). Trước đây dấu ✓ bên phải ⇒ người dùng không nhận ra là chọn một.
    Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 8.dp).semantics { heading() },
        verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(tr("Bạn thường gõ thế nào?"), style = VTType.body, color = c.label)
        Text(tr(SettingCaption.profileHint), style = VTType.footnote, color = c.secondary)
    }
    @Composable
    fun Choice(title: String, caption: String, selected: Boolean, onClick: (() -> Unit)?) {
        VTRow(onClick = onClick, modifier = Modifier.semantics { this.selected = selected }) {
            Box(Modifier.padding(end = 12.dp).size(20.dp)
                .border(2.dp, if (selected) c.accent else c.secondary, CircleShape),
                contentAlignment = Alignment.Center) {
                if (selected) Box(Modifier.size(10.dp).background(c.accent, CircleShape))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = VTType.body, color = c.label)
                Text(caption, style = VTType.footnote, color = c.secondary, maxLines = 2)
            }
        }
    }
    for (p in OnboardingProfile.entries) {
        RowDivider()
        Choice(p.title, "“${p.example}”", matched == p) {
            if (OnboardingSettings.needsConfirmation(current, p, last)) confirming = p else OnboardingStore.apply(ctx, p)
        }
    }
    // "Tuỳ chỉnh" chỉ hiện (đã chọn, không bấm được) khi công tắc không khớp hồ sơ nào.
    if (matched == null) {
        RowDivider()
        Choice(tr("Tuỳ chỉnh"), tr(SettingCaption.customProfile), true, null)
    }
    confirming?.let { p ->
        val lines = OnboardingSettings.changes(current, p).joinToString("\n") { k ->
            "• " + tr(OnboardingSettings.viTitle(k)) + ": " + (if (p.values[k] == true) tr("bật") else tr("tắt"))
        }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirming = null },
            title = { Text(tr("Áp dụng “%s”?", p.title)) },
            text = { Text(tr("Các công tắc bạn đã tự chỉnh sẽ đổi:") + "\n" + lines) },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { confirming = null; OnboardingStore.apply(ctx, p) }) {
                    Text(tr("Áp dụng"), color = c.accent)
                }
            },
            dismissButton = { androidx.compose.material3.TextButton(onClick = { confirming = null }) { Text(tr("Huỷ"), color = c.accent) } },
        )
    }
}
