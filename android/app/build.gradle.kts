import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "com.viettelex.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.viettelex.android"
        minSdk = 26; targetSdk = 36
        versionCode = 63; versionName = "1.6.24"
    }
    // Upload key: keystore.properties (gitignored, ~/keystores/viettelex.jks). Thiếu file → release unsigned.
    val keystoreProps = Properties().apply {
        val f = rootProject.file("keystore.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    if (keystoreProps.isNotEmpty()) {
        signingConfigs {
            create("upload") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = System.getenv("VIETTELEX_STORE_PASSWORD") ?: keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = System.getenv("VIETTELEX_KEY_PASSWORD") ?: keystoreProps.getProperty("keyPassword")
            }
        }
    }
    buildTypes { release {
        if (keystoreProps.isNotEmpty()) signingConfig = signingConfigs.getByName("upload")
        isMinifyEnabled = true; isShrinkResources = true
        proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro") }
        // Đo hiệu năng (docs/PERF-IME-SHOW.md): y như release (R8, không debuggable) nhưng ký khoá
        // debug ⇒ cài được lên emulator mà không cần keystore. KHÔNG phát hành bản này.
        create("benchmark") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release")
            isDebuggable = false
        }
        // Sinh Baseline Profile (benchmark/ImeBaselineProfile): như "benchmark" nhưng KHÔNG R8 ⇒ luật
        // profile mang tên lớp/hàm gốc (R8 tự đổi tên khi đóng bản release).
        create("benchmarkProfile") {
            initWith(getByName("benchmark"))
            isMinifyEnabled = false
            isShrinkResources = false
            matchingFallbacks += listOf("release")
        }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions {
        jvmTarget = "17"
        // genai-prompt (Gemini Nano) biên dịch bằng Kotlin metadata 2.2, project 2.0 ⇒ bỏ kiểm phiên bản.
        // Code Kotlin KHÔNG chạm class của SDK (chỉ ai/GeminiNanoBridge.java) — nâng Kotlin ≥ 2.2 thì gỡ.
        freeCompilerArgs += "-Xskip-metadata-version-check"
    }
    buildFeatures { compose = true; buildConfig = true }
    androidResources { noCompress += listOf("bin") }
    // Phông điểm ảnh NHÚNG (theme Pixel 8-bit, KeyLabelFont.PIXEL) + giấy phép OFL: MỘT bản ở fonts/ gốc repo, dùng chung
    // iOS (project.yml). Vào assets gốc: Tiny5-Regular.ttf + OFL-Tiny5-Regular.txt + README.txt (nguồn / giấy phép).
    sourceSets["main"].assets.srcDir(rootProject.file("../fonts"))
    testOptions { unitTests { isIncludeAndroidResources = true } }
}
dependencies {
    implementation(project(":telexcore")); implementation(project(":keyboard"))
    implementation("androidx.core:core-ktx:1.13.1")
    // Mốc Perfetto "VT.*" (ImeTrace) — gần 0 chi phí khi không ghi trace.
    implementation("androidx.tracing:tracing:1.2.0")
    // Cài Baseline Profile (app/src/main/baseline-prof.txt) cho bản APK ngoài Play. Bản kéo theo qua
    // Compose (1.3.1) không hỗ trợ API 34+ ⇒ Android 14+ cài từ APK không bao giờ được biên dịch trước.
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")
    // ExploreByTouchHelper (TalkBack cho từng phím) — đã có sẵn qua phụ thuộc bắc cầu, khai rõ.
    implementation("androidx.customview:customview:1.0.0")
    // Process ":settings" tự khởi tạo EmojiCompat (androidx.startup chỉ chạy ở process chính) —
    // cùng bản đã có sẵn qua Compose, chỉ khai rõ để gọi được.
    implementation("androidx.startup:startup-runtime:1.1.1")
    implementation("androidx.emoji2:emoji2:1.3.0")
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-tooling-preview")   // không có @Preview trong main ⇒ chỉ bản debug
    // VietTelex Plus + ủng hộ: Google Play Billing (thư viện chính chủ của Google).
    implementation("com.android.billingclient:billing:8.0.0")
    // Dịch trên máy (Plus): ML Kit Translation nằm thẳng trong app (bỏ module Play Feature Delivery
    // từ #162 — SplitInstall báo APP_NOT_OWNED cả với bản cài từ Play). Gói ngôn ngữ (~30 MB/thứ tiếng)
    // vẫn tải khi người dùng bấm, qua RemoteModelManager của ML Kit. ML Kit mang sẵn consumer R8 rules.
    implementation("com.google.mlkit:translate:17.0.3")
    // Gemini Nano (AICore) trích địa chỉ ở ô địa chỉ — ai/GeminiNanoAddress.kt. beta2: bản sau cần Kotlin ≥ 2.3.
    implementation("com.google.mlkit:genai-prompt:1.0.0-beta2")
    // Đồng bộ Google Drive App Data (sync/DriveSync.kt): Authorization API, quyền drive.appdata.
    implementation("com.google.android.gms:play-services-auth:22.0.0")
    // Billing kéo vài androidx cũ (livedata 2.8.3, fragment 1.1.0) — nâng lên bản mới hơn
    // (đã có sẵn trong cache Gradle) để build --offline chạy được; chỉ là ràng buộc
    // phiên bản, không thêm thư viện mới.
    constraints {
        implementation("androidx.lifecycle:lifecycle-livedata:2.8.7")
        implementation("androidx.fragment:fragment:1.5.4")
    }
    testImplementation("junit:junit:4.13.2")
    // Test chi phí hiện bàn phím (ImeRenderBudgetTest): chạy VietTelexIME thật trên JVM.
    testImplementation("org.robolectric:robolectric:4.16")
    testImplementation("androidx.test:core:1.6.1")
}
// Bộ test chậm (benchmark ImePerfBenchTest): VT_SLOW_TESTS=1 bật; là input để đổi giá trị thì chạy lại.
tasks.withType<Test>().configureEach {
    inputs.property("vtSlowTests", System.getenv("VT_SLOW_TESTS") ?: "")
}
