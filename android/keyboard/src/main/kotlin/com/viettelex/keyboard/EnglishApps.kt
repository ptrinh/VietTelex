package com.viettelex.keyboard

/**
 * "Luôn gõ tiếng Anh trong app" (Android, [Keys.ENGLISH_APPS]): trong app thuộc danh sách, bàn phím
 * tự ở chế độ Tiếng Anh; sang app khác trở lại ngôn ngữ người dùng đang để ([Keys.KEYBOARD_LANGUAGE]
 * — không bị ghi đè). Vuốt phím cách trong app đó vẫn đổi được cho lần gõ ấy, nhưng KHÔNG lưu:
 * lần mở sau lại là Tiếng Anh, và app khác không bị kéo theo. THUẦN — EnglishAppsTests.
 * Lưu: tên gói cách nhau bằng xuống dòng (một chuỗi, đọc một lần mỗi lần hiện bàn phím).
 */
object EnglishApps {
    fun parse(raw: String?): Set<String> =
        raw?.split('\n')?.map { it.trim() }?.filter { it.isNotEmpty() }?.toSet() ?: emptySet()

    fun serialize(apps: Set<String>): String = apps.sorted().joinToString("\n")

    fun toggled(apps: Set<String>, pkg: String, on: Boolean): Set<String> = if (on) apps + pkg else apps - pkg

    /** App [pkg] đang gõ có thuộc danh sách không ([self] = gói của chính VietTelex: không bao giờ). */
    fun forces(pkg: String?, apps: Set<String>, self: String? = null): Boolean =
        !pkg.isNullOrEmpty() && pkg != self && pkg in apps
}
