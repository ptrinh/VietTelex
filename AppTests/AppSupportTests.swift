import XCTest
import Carbon.HIToolbox
import TelexCore
@testable import VietTelex

// Support-layer coverage: DebugLog ring semantics, Updater version logic +
// stubbed network paths, the Accessibility trust cache, and the safe (non-posting)
// SyntheticKeyboard state helpers. Detector getters are smoke-read only — their
// values depend on live system state (windows, AX), so asserting them would flake.
final class AppSupportTests: XCTestCase {

    override func tearDown() {
        Accessibility.testTrustOverride = nil
        AppState.shared.debugLogging = false
        super.tearDown()
    }

    // MARK: DebugLog

    func testDebugLogRing() {
        let wasOn = AppState.shared.debugLogging
        defer { AppState.shared.debugLogging = wasOn }
        AppState.shared.debugLogging = false
        DebugLog.clear()
        DebugLog.log("must NOT be recorded")
        XCTAssertFalse(DebugLog.snapshot(header: []).contains("must NOT be recorded"))
        AppState.shared.debugLogging = true
        DebugLog.log("recorded line")
        let snap = DebugLog.snapshot(header: ["HEADER"])
        XCTAssertTrue(snap.contains("HEADER"))
        XCTAssertTrue(snap.contains("recorded line"))
        // Ring caps at 2000 (400 held only ~35s of debug-logged typing — testers'
        // incident had always scrolled out, 2026-07-30): oldest line evicted, never a crash.
        for i in 0..<2050 { DebugLog.log("filler \(i)") }
        let full = DebugLog.snapshot(header: [])
        XCTAssertFalse(full.contains("recorded line"))
        XCTAssertFalse(full.contains("filler 49\n"))  // \n-anchored: "filler 490" must not match
        XCTAssertTrue(full.contains("filler 50\n"))   // 2050 logged − 2000 cap = first kept
        XCTAssertTrue(full.contains("filler 2049"))
        DebugLog.clear()
        XCTAssertTrue(DebugLog.snapshot(header: []).contains("log empty"))
    }

    /// Ring wraps several times: snapshot stays oldest→newest, exactly `capacity` lines.
    func testDebugLogRingOrderAfterWrapping() {
        let wasOn = AppState.shared.debugLogging
        defer { AppState.shared.debugLogging = wasOn; DebugLog.clear() }
        AppState.shared.debugLogging = true
        DebugLog.clear()
        for i in 0..<4_321 { DebugLog.log("w \(i)") }
        let nums: [Int] = DebugLog.snapshot(header: []).split(separator: "\n").compactMap { line in
            guard let r = line.range(of: "  w ") else { return nil }
            return Int(line[r.upperBound...])
        }
        XCTAssertEqual(nums, Array(2_321..<4_321))
    }

    // MARK: Updater — pure logic

    func testVersionCompare() {
        XCTAssertTrue(UpdateCheck.isNewer("1.3.1", than: "1.3.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.9"))   // numeric, not lexical
        XCTAssertTrue(UpdateCheck.isNewer("1.3.0.1", than: "1.3.0"))  // length mismatch
        XCTAssertFalse(UpdateCheck.isNewer("1.3.0", than: "1.3.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2.9", than: "1.3.0"))
        XCTAssertFalse(UpdateCheck.isNewer("garbage", than: "1.0"))   // non-numeric → 0
        XCTAssertFalse(UpdateCheck.currentVersion().isEmpty)
    }

    /// Remote version strings reach a download URL and (formerly) a temp-dir path before
    /// the signature gate — only plain dotted digits may pass the parse boundary.
    func testRemoteVersionValidation() {
        for ok in ["1", "1.8", "1.8.4", "1.8.4.1", "10.20.300"] {
            XCTAssertTrue(UpdateCheck.isValidVersion(ok), ok)
        }
        for bad in ["", ".", "1.", ".1", "1..2", "1.2.3.4.5", "v1.8.4", "1.8.4-beta",
                    "9.0/../../../../tmp/x", "1.8 4", "1.8.4\n", "１.８", "1.2.3456789",
                    String(repeating: "1.", count: 20) + "1"] {
            XCTAssertFalse(UpdateCheck.isValidVersion(bad), bad.debugDescription)
        }
    }

    func testReleaseNotesSanitizing() {
        XCTAssertNil(UpdateCheck.sanitizeNotes(nil))
        XCTAssertNil(UpdateCheck.sanitizeNotes(""))
        XCTAssertNil(UpdateCheck.sanitizeNotes("\n\n  \n"))          // blank-only → nothing to show

        // Git trailers are commit plumbing; the release body carries them verbatim, and
        // stripping one must not leave a hole at the end (v1.6.3 shipped with exactly this).
        let body = "## Tính năng mới\n\n- Phím ngoặc `[` ra ơ\n\nCảm ơn bạn Tuấn Linh\n\n" +
                   "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>\n"
        let clean = UpdateCheck.sanitizeNotes(body)
        XCTAssertNotNil(clean)
        XCTAssertFalse(clean!.contains("Co-Authored-By"))
        XCTAssertFalse(clean!.hasSuffix("\n"))
        XCTAssertTrue(clean!.contains("Cảm ơn bạn Tuấn Linh"))
        XCTAssertFalse(clean!.contains("\n\n\n"))                    // blank runs collapsed
        XCTAssertTrue(UpdateCheck.isTrailer("Signed-off-by: A B"))
        XCTAssertTrue(UpdateCheck.isTrailer("Reviewed-By: A B"))
        XCTAssertFalse(UpdateCheck.isTrailer("Ví dụ: th[ → thơ"))    // a colon alone isn't a trailer
        XCTAssertFalse(UpdateCheck.isTrailer("- Bật ở Cài đặt: Thử nghiệm"))

        // Long bodies are truncated, not rendered whole into a 640pt window.
        let huge = UpdateCheck.sanitizeNotes(String(repeating: "x", count: 9000))
        XCTAssertEqual(huge?.count, UpdateCheck.notesCharacterCap + 1)   // + the ellipsis
    }

    // MARK: Default ngôn ngữ UI — chốt để không ai lật ngược (maintainer 15/08/2026)

    func testUILanguageDefaultsToVietnamese() {
        // "system" cho UI tiếng Anh trên máy để macOS tiếng Anh, trong khi gần như
        // toàn bộ user là người Việt → default thẳng "vi" (1.6.6). Xoá key trong
        // suite TEST (không phải suite thật — xem AppState.settingsSuiteName) để đọc
        // đúng giá trị mặc định của code, rồi trả lại nguyên trạng.
        let s = AppState.shared
        let saved = s.defaults.object(forKey: "uiLanguage")
        s.defaults.removeObject(forKey: "uiLanguage")
        XCTAssertEqual(s.uiLanguage, "vi", "default ngôn ngữ UI phải là tiếng Việt")
        // Và VTLocalized phải THẬT SỰ ra tiếng Việt ở default đó, không chỉ trả về key.
        XCTAssertEqual(VTLocalized("General"), "Chung")
        if let saved { s.defaults.set(saved, forKey: "uiLanguage") }
    }

    // MARK: Field report 14/08/2026 — "VietTelex tự nhiên bị mờ" = secure input

    func testSecureInputPIDExtraction() {
        // Shape thật của IOConsoleUsers: mảng session dict, chỉ session đang giữ
        // secure input mới mang key kCGSSessionSecureInputPID.
        let users: [[String: Any]] = [
            ["kCGSSessionUserNameKey": "loginwindow", "kCGSSessionOnConsoleKey": false],
            ["kCGSSessionUserNameKey": "ptrinh", "kCGSSessionSecureInputPID": 4242],
        ]
        XCTAssertEqual(SecureInputMonitor.extractSecureInputPID(consoleUsers: users), 4242)
        XCTAssertNil(SecureInputMonitor.extractSecureInputPID(consoleUsers: []))
        XCTAssertNil(SecureInputMonitor.extractSecureInputPID(consoleUsers: [["a": 1]]))
        // PID 0 nghĩa là "không ai giữ" trong một số bản macOS — không được coi là thủ phạm.
        XCTAssertNil(SecureInputMonitor.extractSecureInputPID(
            consoleUsers: [["kCGSSessionSecureInputPID": 0]]))
    }

    func testSecureInputHolderLabelIsGreppable() {
        // Label đi vào unified log + bug report: phải chứa cả tên lẫn PID, và không
        // vỡ khi không resolve được tên (process đã chết giữa chừng).
        XCTAssertEqual(SecureInputMonitor.Holder(pid: 123, name: "iTerm2", alive: true).label,
                       "iTerm2 (PID 123)")
        XCTAssertEqual(SecureInputMonitor.Holder(pid: 123, name: nil, alive: true).label, "PID 123")
        // Khoá mồ côi (field case 18/08: Lark chết không nhả): label phải nói rõ —
        // và alive nằm trong Equatable nên sống→chết tự thành transition được log.
        XCTAssertEqual(SecureInputMonitor.Holder(pid: 123, name: nil, alive: false).label,
                       "PID 123, exited")
        XCTAssertTrue(SecureInputMonitor.processIsAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(SecureInputMonitor.processIsAlive(99_999_999))   // PID không tồn tại
        XCTAssertTrue(SecureInputMonitor.processIsAlive(0))             // không rõ ai giữ → đừng khuyên láo
        // Tên process của chính test host phải resolve được (đường NSRunningApplication).
        XCTAssertNotNil(SecureInputMonitor.processName(ProcessInfo.processInfo.processIdentifier))
    }

    /// Maintainer 24/09/2026: Chrome on a login page showed "Không gõ được tiếng Việt —
    /// Google Chrome", which reads like a VietTelex failure. When the holder is the
    /// app in FRONT it's just a password field — say that. Specific diagnoses win.
    func testFrontAppPasswordFieldIsNotReportedAsAFault() {
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Google Chrome", holderAlive: true,
                                            runningPasswordManagers: [], holderIsFrontmost: true),
            .passwordFieldInFrontApp("Google Chrome"))
        // Not in front → still the generic "an app is holding it" diagnosis.
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Google Chrome", holderAlive: true,
                                            runningPasswordManagers: [], holderIsFrontmost: false),
            .generic)
        // Specific causes keep their own fix even when in front.
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "iTerm2", holderAlive: true,
                                            runningPasswordManagers: [], holderIsFrontmost: true),
            .terminal)
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "1Password", holderAlive: true,
                                            runningPasswordManagers: [], holderIsFrontmost: true),
            .passwordManager("1Password"))
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Chrome", holderAlive: false,
                                            runningPasswordManagers: [], holderIsFrontmost: true),
            .orphan)
        let k = SecureInputMonitor.HintKind.passwordFieldInFrontApp("Google Chrome")
        XCTAssertFalse(SecureInputMonitor.wantsLockScreen(k))
        XCTAssertNil(SecureInputMonitor.revealTarget(k))
        XCTAssertTrue(SecureInputMonitor.menuHeadline(k, holderName: "Google Chrome").contains("Google Chrome"))
    }

    /// Issue #100 (Edge, github.com): after the login submit navigated away, Edge kept
    /// Secure Input on while NO password field was focused (reproduced in Chrome
    /// 28/09/2026: ~22s). "X is on a password field — normal" was wrong there.
    func testFrontAppHoldingSecureInputOffPasswordFieldIsReportedAsStuck() {
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Microsoft Edge", holderAlive: true,
                                            runningPasswordManagers: [], holderIsFrontmost: true,
                                            focusedFieldIsSecure: false),
            .heldAfterPasswordField("Microsoft Edge"))
        // Still ON the password field → the benign reading.
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Microsoft Edge", holderAlive: true,
                                            runningPasswordManagers: [], holderIsFrontmost: true,
                                            focusedFieldIsSecure: true),
            .passwordFieldInFrontApp("Microsoft Edge"))
        // AX unknown → benign reading (never accuse on no evidence).
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Microsoft Edge", holderAlive: true,
                                            runningPasswordManagers: [], holderIsFrontmost: true,
                                            focusedFieldIsSecure: nil),
            .passwordFieldInFrontApp("Microsoft Edge"))
        // Not in front → generic, whatever AX says.
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Microsoft Edge", holderAlive: true,
                                            runningPasswordManagers: [], holderIsFrontmost: false,
                                            focusedFieldIsSecure: false),
            .generic)
        let k = SecureInputMonitor.HintKind.heldAfterPasswordField("Microsoft Edge")
        XCTAssertTrue(SecureInputMonitor.menuHeadline(k, holderName: "Microsoft Edge").contains("Microsoft Edge"))
        XCTAssertFalse(SecureInputMonitor.wantsLockScreen(k))
        XCTAssertNil(SecureInputMonitor.revealTarget(k))
        XCTAssertFalse(SecureInputMonitor.hintText(k).isEmpty)
        // Focus verdict: nothing focused but the app answered → not a password field;
        // timeout / failure → unknown.
        XCTAssertEqual(SecureFieldDetector.focusVerdict(subrole: "AXSecureTextField", hasFocus: true, appError: .success), true)
        XCTAssertEqual(SecureFieldDetector.focusVerdict(subrole: nil, hasFocus: true, appError: .success), false)
        XCTAssertEqual(SecureFieldDetector.focusVerdict(subrole: nil, hasFocus: false, appError: .noValue), false)
        XCTAssertNil(SecureFieldDetector.focusVerdict(subrole: nil, hasFocus: false, appError: .cannotComplete))
        // Return / Enter / Tab leave the password field → drop the cached verdict.
        XCTAssertTrue(SecureFieldDetector.leavesField(keyCode: kVK_Return))
        XCTAssertTrue(SecureFieldDetector.leavesField(keyCode: kVK_ANSI_KeypadEnter))
        XCTAssertTrue(SecureFieldDetector.leavesField(keyCode: kVK_Tab))
        XCTAssertFalse(SecureFieldDetector.leavesField(keyCode: kVK_ANSI_A))
    }

    /// Issue #100 race: the password field made macOS switch VietTelex → ABC and the
    /// input-source-changed check ran BEFORE IsSecureEventInputEnabled() turned true
    /// (the log caught ON only at the next poll, 3s later) — the calm branch latched
    /// "VietTelex was not selected", so nothing re-selected it when the lock cleared.
    func testPreBlockSelectionSurvivesSourceSwitchBeforeOnsetDetection() {
        typealias P = SecureInputMonitor.PreBlockSelection
        let s: UInt64 = 1_000_000_000
        var p = P()
        p.noteCalm(isVietTelex: true, nowNs: 10 * s, userGesture: false)
        p.noteCalm(isVietTelex: false, nowNs: 100 * s, userGesture: false)   // macOS → ABC
        XCTAssertTrue(p.wasSelected(onsetNs: 103 * s))                        // ON at poll
        XCTAssertFalse(p.wasSelected(onsetNs: 100 * s + P.onsetGraceNs + 1)) // too late: unrelated
        // The user switched away themselves (hotkey / menu bar) → never reclaim.
        var u = P()
        u.noteCalm(isVietTelex: true, nowNs: 10 * s, userGesture: false)
        u.noteCalm(isVietTelex: false, nowNs: 100 * s, userGesture: true)
        XCTAssertFalse(u.wasSelected(onsetNs: 101 * s))
        // Never selected → never reclaim.
        var n = P()
        n.noteCalm(isVietTelex: false, nowNs: 100 * s, userGesture: false)
        XCTAssertFalse(n.wasSelected(onsetNs: 101 * s))
        // Still selected at onset (the old fast path) → reclaim.
        var y = P()
        y.noteCalm(isVietTelex: true, nowNs: 100 * s, userGesture: false)
        XCTAssertTrue(y.wasSelected(onsetNs: 101 * s))
        // Re-selected afterwards clears the loss stamp.
        p.noteCalm(isVietTelex: true, nowNs: 120 * s, userGesture: false)
        XCTAssertEqual(p.lostAtNs, 0)
        // Gesture windows shared with StickyInputSource.
        XCTAssertTrue(StickyInputSource.isUserGesture(nowNs: 10 * s, lastChordNs: 10 * s - 1, lastMenuBarClickNs: 0))
        XCTAssertTrue(StickyInputSource.isUserGesture(nowNs: 10 * s, lastChordNs: 0, lastMenuBarClickNs: 6 * s))
        XCTAssertFalse(StickyInputSource.isUserGesture(nowNs: 10 * s, lastChordNs: 0, lastMenuBarClickNs: 0))
        XCTAssertFalse(StickyInputSource.isUserGesture(nowNs: 10 * s, lastChordNs: 8 * s, lastMenuBarClickNs: 4 * s))
    }

    func testSecureInputHintClassifiesPasswordManagerAfterSleep() {
        // Field case 09/2026: wake from sleep with 1Password open → Telex dead
        // until 1Password is quit. ioreg often NAMES loginwindow (false
        // attribution, 1Password Community #25015) while 1Password is the
        // EnableSecureEventInput caller. Hint must not say "turn off Terminal
        // Secure Keyboard Entry".
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "1Password", holderAlive: true,
                                            runningPasswordManagers: ["1Password"]),
            .passwordManager("1Password"))
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "1Password Browser Helper", holderAlive: true,
                                            runningPasswordManagers: []),
            .passwordManager("1Password"))
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "loginwindow", holderAlive: true,
                                            runningPasswordManagers: ["1Password"]),
            .loginwindowWithPasswordManager("1Password"))
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "loginwindow", holderAlive: true,
                                            runningPasswordManagers: []),
            .loginwindowStuck)
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "iTerm2", holderAlive: true,
                                            runningPasswordManagers: ["1Password"]),
            .terminal)
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Lark", holderAlive: false,
                                            runningPasswordManagers: []),
            .orphan)
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Safari", holderAlive: true,
                                            runningPasswordManagers: []),
            .generic)
        XCTAssertEqual(
            SecureInputMonitor.revealTarget(.loginwindowWithPasswordManager("1Password")),
            "1Password")
        XCTAssertNil(SecureInputMonitor.revealTarget(.terminal))
        let sleepHint = SecureInputMonitor.hintText(.loginwindowWithPasswordManager("1Password"))
        XCTAssertTrue(sleepHint.contains("1Password"))
        XCTAssertFalse(sleepHint.localizedCaseInsensitiveContains("loginwindow"),
                       "user-facing 1Password hint must not say loginwindow")
        XCTAssertFalse(sleepHint.localizedCaseInsensitiveContains("Terminal"),
                       "sleep+1Password must not be diagnosed as Secure Keyboard Entry")
        let terminalHint = SecureInputMonitor.hintText(.terminal)
        XCTAssertTrue(terminalHint.contains("Terminal") || terminalHint.contains("iTerm"),
                      "iTerm/Terminal Secure Keyboard Entry hint must stay")
        XCTAssertTrue(SecureInputMonitor.wantsLockScreen(.loginwindowStuck))
        XCTAssertTrue(SecureInputMonitor.wantsLockScreen(.orphan))
        XCTAssertFalse(SecureInputMonitor.wantsLockScreen(.loginwindowWithPasswordManager("1Password")),
                       "locking the screen can make 1Password SI worse")
        XCTAssertFalse(SecureInputMonitor.wantsLockScreen(.terminal))
        XCTAssertFalse(SecureInputMonitor.wantsLockScreen(.generic))
        // Trình duyệt giữ SI sau ô mật khẩu (Chrome, 14/10/2026): mục "thử" khoá màn hình.
        XCTAssertTrue(SecureInputMonitor.wantsTryLockScreen(.generic))
        XCTAssertTrue(SecureInputMonitor.wantsTryLockScreen(.heldAfterPasswordField("Google Chrome")))
        XCTAssertFalse(SecureInputMonitor.wantsTryLockScreen(.passwordFieldInFrontApp("Google Chrome")),
                       "a focused password field blocks IMEs on purpose")
        XCTAssertFalse(SecureInputMonitor.wantsTryLockScreen(.terminal))
        XCTAssertFalse(SecureInputMonitor.wantsTryLockScreen(.passwordManager("1Password")))
        XCTAssertFalse(SecureInputMonitor.wantsTryLockScreen(.loginwindowStuck),
                       "already gets the plain Lock Screen item")
        if let path = Bundle.main.path(forResource: "vi", ofType: "lproj"), let vi = Bundle(path: path) {
            XCTAssertEqual(vi.localizedString(forKey: "Lock Screen to try clearing it", value: nil, table: nil),
                           "Khóa màn hình để thử gỡ")
        } else { XCTFail("vi.lproj missing") }
        // KHÔNG assert trạng thái khoá thật của máy: bản đầu của test này đỏ ngay
        // khi maintainer rời máy lúc suite đang chạy (18/09/2026). Test cái parser.
        XCTAssertFalse(SecureInputMonitor.screenIsLocked(session: nil))
        XCTAssertFalse(SecureInputMonitor.screenIsLocked(session: [:]),
                       "khoá vắng mặt = màn hình đang mở")
        XCTAssertTrue(SecureInputMonitor.screenIsLocked(
            session: ["CGSSessionScreenIsLocked": true]))
        XCTAssertTrue(SecureInputMonitor.screenIsLocked(
            session: ["CGSSessionScreenIsLocked": NSNumber(value: 1)]),
                      "macOS có bản trả NSNumber")
        XCTAssertFalse(SecureInputMonitor.screenIsLocked(
            session: ["CGSSessionScreenIsLocked": NSNumber(value: 0)]))
    }

    func testSecureInputPasswordManagerNameMatching() {
        XCTAssertTrue(SecureInputMonitor.looksLikePasswordManager("1Password"))
        XCTAssertTrue(SecureInputMonitor.looksLikePasswordManager("com.agilebits.onepassword7"))
        XCTAssertTrue(SecureInputMonitor.looksLikePasswordManager("Bitwarden"))
        XCTAssertFalse(SecureInputMonitor.looksLikePasswordManager("Safari"))
        XCTAssertFalse(SecureInputMonitor.looksLikePasswordManager("Password Manager Settings"))
        XCTAssertFalse(SecureInputMonitor.looksLikePasswordManager(nil))
        XCTAssertTrue(SecureInputMonitor.looksLikeLoginwindow("loginwindow"))
        XCTAssertTrue(SecureInputMonitor.looksLikeLoginwindow("Login Window"))
        XCTAssertTrue(SecureInputMonitor.looksLikeLoginwindow("Cửa sổ đăng nhập"))
        XCTAssertFalse(SecureInputMonitor.looksLikeLoginwindow("1Password"))
        XCTAssertTrue(SecureInputMonitor.looksLikeTerminal("Terminal"))
        XCTAssertTrue(SecureInputMonitor.looksLikeTerminal("iTerm2"))
        XCTAssertFalse(SecureInputMonitor.looksLikeTerminal("1Password"))
        XCTAssertEqual(SecureInputMonitor.canonicalPasswordManagerName("1Password for Safari"),
                       "1Password")
        // Localized "Login Window" used to miss looksLikeLoginwindow → Terminal hint
        // while the banner still said loginwindow via proc_name. Prefer unix name.
        XCTAssertEqual(
            SecureInputMonitor.preferredHolderName(localized: "Cửa sổ đăng nhập",
                                                   proc: "loginwindow"),
            "loginwindow")
        XCTAssertEqual(
            SecureInputMonitor.preferredHolderName(localized: "Login Window",
                                                   proc: "loginwindow"),
            "loginwindow")
        XCTAssertEqual(
            SecureInputMonitor.preferredHolderName(localized: "1Password", proc: nil),
            "1Password")
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(holderName: "Cửa sổ đăng nhập", holderAlive: true,
                                            runningPasswordManagers: []),
            .loginwindowStuck)
        XCTAssertEqual(
            SecureInputMonitor.classifyHint(
                holderName: SecureInputMonitor.preferredHolderName(
                    localized: "Cửa sổ đăng nhập", proc: "loginwindow"),
                holderAlive: true, runningPasswordManagers: []),
            .loginwindowStuck)
        let loginHint = SecureInputMonitor.hintText(.loginwindowStuck)
        XCTAssertFalse(loginHint.localizedCaseInsensitiveContains("Terminal"),
                       "loginwindow stuck must not be diagnosed as Secure Keyboard Entry")
        XCTAssertFalse(loginHint.localizedCaseInsensitiveContains("loginwindow"),
                       "user-facing copy must not say loginwindow")
        XCTAssertTrue(loginHint.contains("⌃⌘Q")
                        || loginHint.localizedCaseInsensitiveContains("lock")
                        || loginHint.localizedCaseInsensitiveContains("khoá"),
                      "hint must tell the user to lock the screen")
        let headline = SecureInputMonitor.menuHeadline(.loginwindowStuck, holderName: "loginwindow")
        XCTAssertFalse(headline.localizedCaseInsensitiveContains("loginwindow"))
        XCTAssertFalse(headline.contains("PID"))
        XCTAssertFalse(SecureInputMonitor.menuHeadline(.orphan, holderName: "Lark")
            .localizedCaseInsensitiveContains("loginwindow"))
        XCTAssertTrue(SecureInputMonitor.menuHeadline(.passwordManager("1Password"), holderName: nil)
            .contains("1Password"))
    }

    func testBoundedDataEnforcesByteCap() async {
        // data: URLs keep the test off the network; the cap must apply while streaming.
        let small = URLRequest(url: URL(string: "data:text/plain,hello")!)
        let got = await UpdateCheck.boundedData(for: small, cap: 16)
        XCTAssertEqual(got.flatMap { String(data: $0, encoding: .utf8) }, "hello")

        let big = URLRequest(url: URL(string: "data:text/plain," +
                                      String(repeating: "x", count: 100))!)
        let over = await UpdateCheck.boundedData(for: big, cap: 16)
        XCTAssertNil(over)                                    // over cap → abandoned, not truncated

        let exact = await UpdateCheck.boundedData(for: small, cap: 5)
        XCTAssertEqual(exact.map { $0.count }, 5)             // cap boundary is inclusive
    }

    func testReleaseNoteBlockParsing() {
        let blocks = UpdateCheck.noteBlocks("## Tính năng mới\n\n- **Phím ngoặc**\n* second\nplain line")
        XCTAssertEqual(blocks.count, 4)                      // blank line dropped
        XCTAssertEqual(blocks[0].kind, .heading)
        XCTAssertEqual(blocks[0].text, "Tính năng mới")      // marker stripped, not rendered as "##"
        XCTAssertEqual(blocks[1].kind, .bullet)
        XCTAssertEqual(blocks[1].text, "**Phím ngoặc**")     // inline markdown left for Text
        XCTAssertEqual(blocks[2].kind, .bullet)              // "*" bullets too
        XCTAssertEqual(blocks[3].kind, .paragraph)
        XCTAssertEqual(UpdateCheck.noteBlocks("").count, 0)
        XCTAssertEqual(UpdateCheck.noteBlocks("###\n-  ").count, 0)   // markers with no text

        // ATX headings need a space after the hashes. An issue reference opening a line is
        // NOT a heading — treating it as one ate the "#" and bolded the rest.
        let issueRef = UpdateCheck.noteBlocks("#42 sửa lỗi gõ tắt")
        XCTAssertEqual(issueRef.first?.kind, .paragraph)
        XCTAssertEqual(issueRef.first?.text, "#42 sửa lỗi gõ tắt")
        XCTAssertTrue(UpdateCheck.isHeading("## Heading"))
        XCTAssertFalse(UpdateCheck.isHeading("#42"))

        XCTAssertEqual(UpdateCheck.releasePageURL(forVersion: "1.6.3")?.absoluteString,
                       "https://github.com/\(UpdateCheck.repo)/releases/tag/v1.6.3")
    }

    // MARK: Updater — network paths via a URLProtocol stub

    func testCheckPathsAgainstStubbedNetwork() async {
        URLProtocol.registerClass(StubURLProtocol.self)
        defer { URLProtocol.unregisterClass(StubURLProtocol.self) }

        // Stable manifest newer than current → .update with the manifest URL. The stable
        // channel has no changelog of its own, so it must go on to ask for the TAG's
        // release body (`releases/tags/v99.0.0`) — that's what gives both channels notes.
        StubURLProtocol.responder = { url in
            if url.absoluteString.contains("stable.json") {
                return (200, #"{"version":"99.0.0","url":"https://example.com/rel"}"#)
            }
            if url.absoluteString.contains("releases/tags/v99.0.0") {
                // ##"…"## delimiters, and the body starts with \n: a literal `"##` inside a
                // #"…"# raw string would close it early. The leading blank line also proves
                // sanitizeNotes trims it off the front.
                return (200, ##"{"tag_name":"v99.0.0","body":"\n## Heading\n- from the tag"}"##)
            }
            return (200, #"{"tag_name":"v99.0.0","html_url":"https://example.com/gh","body":"- from latest"}"#)
        }
        if case let .update(latest, url, notes) = await UpdateCheck.checkStable() {
            XCTAssertEqual(latest, "99.0.0")
            XCTAssertEqual(url.absoluteString, "https://example.com/rel")
            XCTAssertEqual(notes, "## Heading\n- from the tag")
        } else { XCTFail("expected .update from stable") }
        if case let .update(latest, _, notes) = await UpdateCheck.check() {
            XCTAssertEqual(latest, "99.0.0")
            XCTAssertEqual(notes, "- from latest")   // free: same response as the tag lookup
        } else { XCTFail("expected .update from latest") }

        // A release with no body is still an update — just without the notes box.
        StubURLProtocol.responder = { url in
            url.absoluteString.contains("stable.json")
                ? (200, #"{"version":"99.0.0","url":"https://example.com/rel"}"#)
                : (200, #"{"tag_name":"v99.0.0"}"#)
        }
        if case let .update(_, _, notes) = await UpdateCheck.checkStable() {
            XCTAssertNil(notes)
        } else { XCTFail("bodyless release must still be .update") }

        // The load-bearing invariant of the whole feature: the CHANGELOG lookup is
        // best-effort, so a tag endpoint that 404s (tag named differently, release deleted,
        // rate limit) must still yield .update — the version is the news, notes are extra.
        StubURLProtocol.responder = { url in
            url.absoluteString.contains("stable.json")
                ? (200, #"{"version":"99.0.0","url":"https://example.com/rel"}"#)
                : (404, #"{"message":"Not Found"}"#)
        }
        if case let .update(latest, _, notes) = await UpdateCheck.checkStable() {
            XCTAssertEqual(latest, "99.0.0")
            XCTAssertNil(notes)
        } else { XCTFail("a failed notes fetch must not fail the update check") }

        // Same version → upToDate.
        let cur = UpdateCheck.currentVersion()
        StubURLProtocol.responder = { url in
            url.absoluteString.contains("stable.json")
                ? (200, #"{"version":"\#(cur)"}"#)
                : (200, #"{"tag_name":"v\#(cur)"}"#)
        }
        if case .upToDate = await UpdateCheck.checkStable() {} else { XCTFail("stable upToDate") }
        if case .upToDate = await UpdateCheck.check() {} else { XCTFail("latest upToDate") }

        // HTTP error and junk payload → .failed, never a crash.
        StubURLProtocol.responder = { _ in (500, "boom") }
        if case .failed = await UpdateCheck.checkStable() {} else { XCTFail("stable failed") }
        if case .failed = await UpdateCheck.check() {} else { XCTFail("latest failed") }
        StubURLProtocol.responder = { _ in (200, "not json at all") }
        if case .failed = await UpdateCheck.checkStable() {} else { XCTFail("stable junk") }
        if case .failed = await UpdateCheck.check() {} else { XCTFail("latest junk") }
    }

    func testMaybeAutoCheckGuards() {
        let s = AppState.shared
        let savedOptIn = s.autoUpdateCheck
        let savedAt = s.lastAutoUpdateCheckAt
        defer { s.autoUpdateCheck = savedOptIn; s.lastAutoUpdateCheckAt = savedAt }
        // Opt-out: returns without touching the throttle timestamp.
        s.autoUpdateCheck = false
        s.lastAutoUpdateCheckAt = 0
        UpdateCheck.maybeAutoCheck(bundleIdentifier: AppState.stableBundleIdentifier)
        XCTAssertEqual(s.lastAutoUpdateCheckAt, 0)
        // Opted in but checked recently: throttle holds.
        s.autoUpdateCheck = true
        let now = Date().timeIntervalSince1970
        s.lastAutoUpdateCheckAt = now
        UpdateCheck.maybeAutoCheck(bundleIdentifier: AppState.stableBundleIdentifier)
        XCTAssertEqual(s.lastAutoUpdateCheckAt, now)
    }

    // MARK: Updater — issue #120 (weekly check never notified a 1.7.8 user)

    func testAutoCheckScheduleRetriesAfterFailure() {
        let day: TimeInterval = 24 * 3600
        let now: TimeInterval = 1_800_000_000
        // Never checked → due.
        XCTAssertTrue(UpdateCheck.shouldAutoCheck(now: now, lastSuccessAt: 0, lastAttemptAt: 0))
        // Succeeded 3 days ago → not due, whatever the attempt stamp says.
        XCTAssertFalse(UpdateCheck.shouldAutoCheck(now: now, lastSuccessAt: now - 3 * day,
                                                   lastAttemptAt: now - 3 * day))
        // Succeeded 8 days ago → due.
        XCTAssertTrue(UpdateCheck.shouldAutoCheck(now: now, lastSuccessAt: now - 8 * day,
                                                  lastAttemptAt: now - 8 * day))
        // THE BUG: a failed attempt 1 hour ago used to count as "checked this week".
        // Now it only holds off for the retry interval…
        XCTAssertFalse(UpdateCheck.shouldAutoCheck(now: now, lastSuccessAt: now - 30 * day,
                                                   lastAttemptAt: now - 3600))
        // …and the next activateServer after that retries, instead of waiting a week.
        XCTAssertTrue(UpdateCheck.shouldAutoCheck(now: now, lastSuccessAt: now - 30 * day,
                                                  lastAttemptAt: now - UpdateCheck.autoCheckRetryInterval))
        XCTAssertLessThan(UpdateCheck.autoCheckRetryInterval, UpdateCheck.autoCheckInterval)
        // A stamp in the future (clock moved back) must not block for good.
        XCTAssertTrue(UpdateCheck.shouldAutoCheck(now: now, lastSuccessAt: now + 365 * day,
                                                  lastAttemptAt: now + 365 * day))
    }

    func testAutoCheckFailureDoesNotConsumeTheWeek() async {
        URLProtocol.registerClass(StubURLProtocol.self)
        defer { URLProtocol.unregisterClass(StubURLProtocol.self) }
        let s = AppState.shared
        let saved = (s.autoUpdateCheck, s.lastAutoUpdateCheckAt, s.lastAutoUpdateAttemptAt)
        defer { (s.autoUpdateCheck, s.lastAutoUpdateCheckAt, s.lastAutoUpdateAttemptAt) = saved }
        StubURLProtocol.responder = { _ in (500, "down") }
        s.autoUpdateCheck = true
        s.lastAutoUpdateCheckAt = 0
        s.lastAutoUpdateAttemptAt = 0
        UpdateCheck.maybeAutoCheck(bundleIdentifier: AppState.stableBundleIdentifier)
        XCTAssertGreaterThan(s.lastAutoUpdateAttemptAt, 0)          // back-off stamped
        // Let the detached check finish against the stub (both manifest URLs 500).
        for _ in 0..<50 { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(s.lastAutoUpdateCheckAt, 0, "a failed check must not reset the weekly clock")
    }

    func testDevBuildDoesNotStartStableAutoCheck() {
        let s = AppState.shared
        let saved = (s.autoUpdateCheck, s.lastAutoUpdateCheckAt, s.lastAutoUpdateAttemptAt)
        defer { (s.autoUpdateCheck, s.lastAutoUpdateCheckAt, s.lastAutoUpdateAttemptAt) = saved }
        s.autoUpdateCheck = true
        s.lastAutoUpdateCheckAt = 0
        s.lastAutoUpdateAttemptAt = 0

        UpdateCheck.maybeAutoCheck(bundleIdentifier: AppState.developmentBundleIdentifier)

        XCTAssertEqual(s.lastAutoUpdateCheckAt, 0)
        XCTAssertEqual(s.lastAutoUpdateAttemptAt, 0)
    }

    func testStableManifestFallsBackPastABrokenHost() async {
        URLProtocol.registerClass(StubURLProtocol.self)
        defer { URLProtocol.unregisterClass(StubURLProtocol.self) }
        // Every manifest URL is https (ATS refuses http, redirects included) and none is
        // the github.io address whose 301 goes through http:// — the 1.7.8 failure.
        XCTAssertGreaterThanOrEqual(UpdateCheck.stableManifestURLs.count, 2)
        for u in UpdateCheck.stableManifestURLs {
            XCTAssertTrue(u.hasPrefix("https://"), u)
            XCTAssertFalse(u.contains("github.io"), u)
        }
        let primary = UpdateCheck.stableManifestURLs[0]
        StubURLProtocol.responder = { url in
            if url.absoluteString == primary { return (503, "cdn down") }
            if url.absoluteString.contains("stable.json") {
                return (200, #"{"version":"99.0.0","url":"https://example.com/rel"}"#)
            }
            return (404, "{}")
        }
        if case let .update(latest, _, _) = await UpdateCheck.checkStable() {
            XCTAssertEqual(latest, "99.0.0")
        } else { XCTFail("fallback manifest must be used when the primary host fails") }
    }

    func testLiveManifestShapeIsNewerThan178() {
        // Today's stable.json carries windows/linux/android objects next to the macOS
        // keys; the decode reads only "version"/"url" and must not care. 1.8.15 is newer
        // than 1.7.8 numerically (not lexically: "1.10" > "1.9").
        let json = #"{"version":"1.8.15","url":"https://github.com/ptrinh/viettelex/releases/tag/v1.8.15","build":124,"windows":{"version":"1.1.5"},"linux":{"version":"1.0.11","series":["noble"]},"android":{"version":"1.5.3"}}"#
        let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let v = obj?["version"] as? String
        XCTAssertEqual(v, "1.8.15")
        XCTAssertTrue(UpdateCheck.isValidVersion(v ?? ""))
        XCTAssertTrue(UpdateCheck.isNewer("1.8.15", than: "1.7.8"))
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(UpdateCheck.isNewer("1.8.15", than: "1.8.15"))
    }

    func testOutstandingUpdateHidesOnceInstalled() {
        XCTAssertEqual(UpdateCheck.outstandingUpdate(pending: "1.8.15", current: "1.7.8"), "1.8.15")
        // Installed manually (pkg/brew) — the stale pending value must not keep nagging.
        XCTAssertNil(UpdateCheck.outstandingUpdate(pending: "1.8.15", current: "1.8.15"))
        XCTAssertNil(UpdateCheck.outstandingUpdate(pending: "1.8.15", current: "1.9.0"))
        XCTAssertNil(UpdateCheck.outstandingUpdate(pending: nil, current: "1.7.8"))
        XCTAssertNil(UpdateCheck.outstandingUpdate(pending: "9.0/../x", current: "1.7.8"))
    }

    func testReleaseNotesFencesAndInstallSection() {
        // The v1.8.15 release body, abridged — the issue #120 screenshot showed the
        // install section's fence printed literally.
        let body = """
        ## Sửa lỗi
        - **Từ tiếng Anh chen trong câu** không còn làm mất dấu.
        - "been" chỉ giữ nguyên sau have/has.

        ## Cài đặt
        Tải `VietTelex-1.8.15.pkg` và chạy, hoặc:
        ```
        brew install ptrinh/viettelex/viettelex
        ```
        """
        let blocks = UpdateCheck.noteBlocks(UpdateCheck.sanitizeNotes(body)!)
        XCTAssertEqual(blocks.map(\.kind), [.heading, .bullet, .bullet])
        XCTAssertFalse(blocks.contains { $0.text.contains("```") })
        XCTAssertFalse(blocks.contains { $0.text.contains("brew") })   // install section dropped

        // A fence elsewhere: markers gone, content kept as inline code.
        let code = UpdateCheck.noteBlocks("## Mẹo\n```\nviettelex --reset\n```\n- tiếp")
        XCTAssertEqual(code.map(\.kind), [.heading, .paragraph, .bullet])
        XCTAssertEqual(code[1].text, "`viettelex --reset`")
        // A heading-looking line INSIDE a fence is code, not a section boundary.
        let fencedHash = UpdateCheck.noteBlocks("```\n## Cài đặt\n```\n- vẫn hiện")
        XCTAssertEqual(fencedHash.map(\.kind), [.paragraph, .bullet])
        // The section after "Cài đặt" shows again.
        let after = UpdateCheck.noteBlocks("## Cài đặt\nbrew …\n## Ghi chú\n- hiện")
        XCTAssertEqual(after.map(\.text), ["Ghi chú", "hiện"])
    }

    // MARK: Updater — bundle install (the "permission stuck after update" fix)

    // installBundle must swap in the new bundle WHOLESALE. The old `ditto newApp dest`
    // merged — it overwrote same-named files but left orphans from resources a new
    // version dropped/renamed, breaking the code seal so tccd refused the event tap.
    // These build throwaway directory trees (not real .app bundles) and assert the
    // on-disk result is byte-identical to the source, with no merge residue.
    private func writeTree(_ files: [String: String], at root: URL) throws {
        for (rel, body) in files {
            let f = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    private func readTree(at root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = root.standardizedFileURL.path
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return out }
        for case let url as URL in en {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            out[rel] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<binary>"
        }
        return out
    }

    func testInstallBundleFreshInstall() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-install-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("staging/VietTelex.app")
        let dest = tmp.appendingPathComponent("Input Methods/VietTelex.app")
        let payload = ["Contents/MacOS/VietTelex": "v2-binary",
                       "Contents/Info.plist": "v2-plist"]
        try writeTree(payload, at: src)

        try SelfUpdater.installBundle(from: src, to: dest)   // no existing dest → move

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(readTree(at: dest), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "source should be consumed")
    }

    func testInstallBundleReplacesWholesaleAndDropsOrphans() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-install-replace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("staging/VietTelex.app")
        let dest = tmp.appendingPathComponent("Input Methods/VietTelex.app")

        // Old installed bundle: has a resource the new version renames away.
        try writeTree(["Contents/MacOS/VietTelex": "v1-binary",
                       "Contents/Info.plist": "v1-plist",
                       "Contents/Resources/old-lexicon.dat": "STALE",       // orphan-to-be
                       "Contents/CodeResources": "v1-seal"], at: dest)
        // New bundle: binary changed, lexicon renamed, no old-lexicon.dat.
        let payload = ["Contents/MacOS/VietTelex": "v2-binary",
                       "Contents/Info.plist": "v2-plist",
                       "Contents/Resources/lexicon-v2.dat": "FRESH",
                       "Contents/CodeResources": "v2-seal"]
        try writeTree(payload, at: src)

        try SelfUpdater.installBundle(from: src, to: dest)

        // Wholesale: dest is byte-identical to the new artifact — the orphan is GONE
        // (a merge would have kept old-lexicon.dat and broken the seal).
        XCTAssertEqual(readTree(at: dest), payload)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("Contents/Resources/old-lexicon.dat").path),
            "orphaned file from the old version must be removed (no merge)")
        // No leftover backup dir beside the installed bundle.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.deletingLastPathComponent().appendingPathComponent("VietTelex.app.bak").path),
            "backup must not linger after a successful replace")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "source should be consumed")
    }

    // MARK: SelfUpdater — designated-requirement signature gate (security-scan
    // finding 2026-08-11, medium): the old gate substring-matched the team ID out
    // of `codesign -dv` text, which any app signed by the same Apple Developer Team
    // would satisfy. verifyDesignatedRequirement uses SecStaticCodeCheckValidity
    // against the FULL requirement (identifier + anchor + cert fields + team OU).

    /// The two ends of the release pipeline (Scripts/make-release.sh's DR guard and
    /// SelfUpdater's install-time gate) hand-carry the same requirement string
    /// because it can't be `import`ed across a shell script and a Swift app — this
    /// pins them byte-identical so the two can't silently drift apart.
    func testExpectedRequirementStringMatchesReleaseScript() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/make-release.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        guard let line = script.split(separator: "\n").first(where: { $0.hasPrefix("EXPECTED_DR=") })
        else { return XCTFail("EXPECTED_DR line not found in make-release.sh") }
        // EXPECTED_DR='designated => identifier "..." and ...' — strip the
        // `designated => ` prefix codesign -d -r- prints that make-release.sh
        // matches against verbatim, and the surrounding single quotes.
        var value = String(line.dropFirst("EXPECTED_DR=".count))
        XCTAssertTrue(value.hasPrefix("'") && value.hasSuffix("'"), "unexpected quoting in \(line)")
        value = String(value.dropFirst().dropLast())
        XCTAssertTrue(value.hasPrefix("designated => "))
        value = String(value.dropFirst("designated => ".count))
        XCTAssertEqual(SelfUpdater.expectedRequirementString, value)
    }

    /// The requirement must at minimum be a well-formed, parseable Designated
    /// Requirement string — a typo here would silently make every update fail
    /// (worse: if malformed in a way SecRequirementCreateWithString still accepts,
    /// it could accept MORE than intended). Doesn't need code-signing entitlements
    /// to run: this only exercises the requirement-language parser.
    func testExpectedRequirementStringParses() {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            SelfUpdater.expectedRequirementString as CFString, [], &requirement)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(requirement)
    }

    /// The gate must REJECT an artifact that doesn't satisfy the requirement — the
    /// exact failure mode the old substring-match gate couldn't produce (any team
    /// member's signed app passed). The test bundle's own Contents/MacOS/xctest
    /// binary is signed by Apple, not by us, so it must fail our identifier+OU check.
    func testVerifyDesignatedRequirementRejectsWrongIdentity() {
        let xctestBinary = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        XCTAssertThrowsError(try SelfUpdater.verifyDesignatedRequirement(at: xctestBinary))
    }

    /// The positive case: a REAL Developer ID-signed VietTelex.app must pass. Skips
    /// gracefully where none is installed (CI, a fresh checkout) — this only proves
    /// the gate isn't so strict it rejects the app's OWN legitimate signature.
    func testVerifyDesignatedRequirementAcceptsOurOwnSignedApp() throws {
        let installed = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Input Methods/VietTelex.app")
        guard FileManager.default.fileExists(atPath: installed.path) else {
            throw XCTSkip("no installed VietTelex.app on this machine")
        }
        try SelfUpdater.verifyDesignatedRequirement(at: installed)   // must not throw
    }

    // MARK: Accessibility trust cache

    func testTrustOverrideAndCache() {
        Accessibility.testTrustOverride = true
        XCTAssertTrue(Accessibility.isTrusted)
        Accessibility.testTrustOverride = false
        XCTAssertFalse(Accessibility.isTrusted)
        Accessibility.testTrustOverride = nil
        Accessibility.invalidateCache()
        let real = Accessibility.isTrusted     // whatever TCC says on this machine…
        XCTAssertEqual(Accessibility.isTrusted, real)   // …the cache answers the same
    }

    /// PR #41's UI reader: sync, cache-bypassing — but it must still honor the
    /// DEBUG override BOTH ways, or every test that forces a trust state would
    /// leak the build machine's real TCC answer into the banner logic.
    func testReadTrustNowHonorsOverrideBothWays() {
        Accessibility.testTrustOverride = true
        XCTAssertTrue(Accessibility.readTrustNow())
        Accessibility.testTrustOverride = false
        XCTAssertFalse(Accessibility.readTrustNow())
        Accessibility.testTrustOverride = nil
        // No override: agrees with the machine's real TCC answer, and — since it
        // refreshes the shared cache on the way — a subsequent cached read agrees too.
        let real = Accessibility.readTrustNow()
        XCTAssertEqual(Accessibility.isTrusted, real)
    }

    // MARK: SyntheticKeyboard state helpers (safe: nothing is posted)

    func testSyntheticKeyboardStateHelpers() {
        SyntheticKeyboard.resetBreaker()
        XCTAssertFalse(SyntheticKeyboard.tripped)
        XCTAssertTrue(SyntheticKeyboard.queueDrained())
        SyntheticKeyboard.noteObservedSynthetic()   // underflow-safe at zero
        XCTAssertTrue(SyntheticKeyboard.queueDrained())
    }

    // MARK: Detector getters — smoke reads (values are live system state)

    func testDetectorSmokeReads() {
        _ = SpotlightDetector.isVisible
        _ = FocusedFieldDetector.wantsSelection
        _ = FocusedFieldDetector.isTextInput
    }
}

/// Minimal URLProtocol stub: answers every request from `responder` without
/// touching the network. Registered per-test; URLSession.shared consults
/// registered protocol classes for its default configuration.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URL) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let (code, body) = Self.responder?(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// Settings accessors round-trip: every UserDefaults-backed property reads back
// what it stores, and the explicit value is restored afterwards.
extension AppSupportTests {
    func testSettingsAccessorRoundTrips() {
        let s = AppState.shared
        // Bool accessors (save → flip → assert → restore).
        let bools: [(get: () -> Bool, set: (Bool) -> Void)] = [
            ({ s.autoRestore }, { s.autoRestore = $0 }),
            ({ s.freeMarking }, { s.freeMarking = $0 }),
            ({ s.modernOrthography }, { s.modernOrthography = $0 }),
            ({ s.liveSpellCheck }, { s.liveSpellCheck = $0 }),
            ({ s.simpleTelex }, { s.simpleTelex = $0 }),
            ({ s.quickTelex }, { s.quickTelex = $0 }),
            ({ s.vniMode }, { s.vniMode = $0 }),
            ({ s.contextualEnglish }, { s.contextualEnglish = $0 }),
            ({ s.retroactiveEnglish }, { s.retroactiveEnglish = $0 }),
            ({ s.englishByFrequency }, { s.englishByFrequency = $0 }),
            ({ s.bracketVowels }, { s.bracketVowels = $0 }),
            ({ s.autoCircumflex }, { s.autoCircumflex = $0 }),
            ({ s.syncedSetting("autoCircumflex") ?? false }, { s.setSyncedSetting("autoCircumflex", $0) }),
            ({ s.tapModifyEventInPlace }, { s.tapModifyEventInPlace = $0 }),
            ({ s.tapSkipSyntheticKeyUp }, { s.tapSkipSyntheticKeyUp = $0 }),
            ({ s.axSelectionReplace }, { s.axSelectionReplace = $0 }),
            ({ s.tapCascadeBreaker }, { s.tapCascadeBreaker = $0 }),
            ({ s.debugLogging }, { s.debugLogging = $0 }),
            ({ s.autoUpdateCheck }, { s.autoUpdateCheck = $0 }),
            ({ s.axPromptShown }, { s.axPromptShown = $0 }),
            // Cache trong bộ nhớ (tap đọc ở mỗi phím chữ) — ghi phải tới cả cache lẫn đĩa.
            ({ s.reEditWord }, { s.reEditWord = $0 }),
            ({ s.syncedSetting("reEditWord") ?? false }, { s.setSyncedSetting("reEditWord", $0) }),
        ]
        for accessor in bools {
            let saved = accessor.get()
            accessor.set(!saved)
            XCTAssertEqual(accessor.get(), !saved)
            accessor.set(saved)
            XCTAssertEqual(accessor.get(), saved)
        }
        // String/scalar accessors.
        let lang = s.uiLanguage
        s.uiLanguage = "vi"; XCTAssertEqual(s.uiLanguage, "vi")
        s.uiLanguage = lang
        let v = s.lastNotifiedUpdateVersion
        s.lastNotifiedUpdateVersion = "9.9.9"
        XCTAssertEqual(s.lastNotifiedUpdateVersion, "9.9.9")
        s.lastNotifiedUpdateVersion = v
        XCTAssertFalse(VTLocalized("Close").isEmpty)   // localization lookup path
        _ = s.tapNativeFastPath
    }

    /// Toggles bỏ UI (tab Thử nghiệm gỡ 14/10/2026) nằm trong graduatedKeys: giá trị OFF
    /// cũ của tester bị xoá lúc khởi động ⇒ hành vi luôn bật (default true).
    func testGraduatedKeysClearOldOffValues() throws {
        for key in ["tapSkipSyntheticKeyUp", "axSelectionReplace",
                    "tapCascadeBreaker", "tapModifyEventInPlace"] {
            XCTAssertTrue(AppState.graduatedKeys.contains(key), key)
        }
        // 11/2026: "Sửa dấu từ đã gõ" có công tắc + đồng bộ iCloud lại — TẮT phải sống qua
        // lần khởi động sau (không thì Mac còn đẩy "bật" lên iCloud đè iPhone).
        XCTAssertFalse(AppState.graduatedKeys.contains("reEditWord"))
        let suite = "test.viettelex.graduated.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        for key in AppState.graduatedKeys { d.set(false, forKey: key) }
        d.set(false, forKey: "safeUnknownApps")              // không tốt nghiệp: giữ nguyên
        AppState.clearGraduatedKeys(in: d)
        for key in AppState.graduatedKeys {
            XCTAssertNil(d.object(forKey: key), key)
            // Cùng biểu thức đọc như AppState.init ⇒ mặc định bật.
            XCTAssertTrue((d.object(forKey: key) as? Bool) ?? true, key)
        }
        XCTAssertEqual(d.object(forKey: "safeUnknownApps") as? Bool, false)
    }

    /// Issue #40 (Discord): the markActive AX poke fires only when a reach-back
    /// feature can use the tree AND the app's keys go through the tap — axDetect
    /// browsers are poked by field scans already, and an opted-out machine must not
    /// touch other processes' AX at all.
    func testLazyAXPokeGate() {
        XCTAssertTrue(FocusedFieldDetector.lazyAXPokeWanted(reEditEnabled: true, routesTap: true))
        XCTAssertFalse(FocusedFieldDetector.lazyAXPokeWanted(reEditEnabled: false, routesTap: true))
        XCTAssertFalse(FocusedFieldDetector.lazyAXPokeWanted(reEditEnabled: true, routesTap: false))
        XCTAssertFalse(FocusedFieldDetector.lazyAXPokeWanted(reEditEnabled: false, routesTap: false))
    }

    /// reEditWord gates TWO reach-back behaviors — re-edit ("toan"+s→toán) and the ⌫
    /// re-open of PR #42 ("tháy ␣"+⌫+a→thấy, issue #40). Default flipped ON 14/08/2026
    /// after PR #42 replaced the GUESS that caused the 04/08 revert with a verified
    /// snapshot (see the AppState doc for the full history). Pinned in both directions:
    /// a fresh install has it on, and an explicit OFF must survive the ON default —
    /// that opt-out is the escape hatch if the 04/08 class ever resurfaces.
    func testReEditGateDefaultsOn() throws {
        // The value is cached in memory now (tap hot path), so the launch-time read is
        // tested on a private suite instead of deleting the live key mid-session.
        let suite = "test.viettelex.reedit.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AppState.storedReEditWord(d), "fresh install: reach-back behaviors on by default")
        d.set(false, forKey: "reEditWord")
        XCTAssertFalse(AppState.storedReEditWord(d), "explicit OFF must survive the ON default")
        AppState.clearGraduatedKeys(in: d)
        XCTAssertFalse(AppState.storedReEditWord(d), "…and survive the launch-time graduated-key sweep")
        let s = AppState.shared
        let saved = s.reEditWord
        defer { s.reEditWord = saved }
        s.reEditWord = false
        XCTAssertFalse(s.reEditWord)
    }
}

// The key-ROUTING predicate shared by the IMKit controller and the terminal tap:
// which keys belong to the word (→ engine.feed) vs end it (→ boundary commit).
// Issue #28 (2026-07-27): VNI shipped working at the engine level but did nothing in
// the app because BOTH key paths gated on letters only, so every VNI digit was eaten
// as a word boundary ("a1" stayed "a1"). Pin the rule here.
final class WordKeyRoutingTests: XCTestCase {

    func testLettersAreAlwaysWordKeys() {
        for c in "abzABZ".utf8 {
            XCTAssertTrue(isWordKey(c, vniMode: false), "'\(Character(UnicodeScalar(c)))' must compose")
            XCTAssertTrue(isWordKey(c, vniMode: true))
        }
    }

    func testDigitsAreWordKeysOnlyInVNI() {
        for c in "0123456789".utf8 {
            XCTAssertFalse(isWordKey(c, vniMode: false), "a digit ends the word in Telex")
            XCTAssertTrue(isWordKey(c, vniMode: true), "a digit carries the diacritic in VNI")
        }
    }

    // #124: numpad digits are never VNI marks (common IME behavior) — they end the word; the number
    // row keeps marking.
    func testKeypadDigitsAreBoundariesEvenInVNI() {
        for c in "0123456789".utf8 {
            XCTAssertFalse(isWordKey(c, vniMode: true, keypad: true))
            XCTAssertFalse(isWordKey(c, vniMode: false, keypad: true))
        }
        let keypad = [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
                      kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7,
                      kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        for k in keypad { XCTAssertTrue(isKeypadDigitKeyCode(k), "keycode \(k)") }
        for k in [kVK_ANSI_1, kVK_ANSI_0, kVK_ANSI_9, kVK_F20, kVK_ANSI_KeypadDecimal,
                  kVK_ANSI_KeypadEnter, kVK_ANSI_A] {
            XCTAssertFalse(isKeypadDigitKeyCode(k), "keycode \(k)")
        }
    }

    func testEverythingElseIsABoundaryInBothModes() {
        for c in " \t.,;:!?-_/\\[]{}()'\"@#$%^&*+=<>|~`".utf8 {
            XCTAssertFalse(isWordKey(c, vniMode: false))
            XCTAssertFalse(isWordKey(c, vniMode: true))
        }
    }
}

// Re-edit the word before the caret (experimental, opt-in): the two PURE pieces of the
// decision — which keys may trigger a read-back, and which trailing text counts as a
// re-editable word. The seeding itself is engine-side (TelexEngine.seed, round-trip
// checked there); the IMKit wiring needs a live client and is covered by hand.
final class ReEditWordTests: XCTestCase {

    func testOnlyModifierKeysTrigger() {
        for c in "sfrxjzwSFRXJZW".utf8 {
            XCTAssertTrue(TelexInputController.isDiacriticOnlyKey(c, vni: false),
                          "'\(Character(UnicodeScalar(c)))' is a Telex modifier")
        }
        // Ordinary letters — including the doublers a/e/o/d — must NOT trigger a read-back.
        for c in "abcdeghiklmnopqtuvy".utf8 {
            XCTAssertFalse(TelexInputController.isDiacriticOnlyKey(c, vni: false),
                           "'\(Character(UnicodeScalar(c)))' is a letter, not a modifier")
        }
        // VNI: the digits carry the diacritics, letters never do.
        for c in "0123456789".utf8 {
            XCTAssertTrue(TelexInputController.isDiacriticOnlyKey(c, vni: true))
        }
        for c in "sfrxjw".utf8 {
            XCTAssertFalse(TelexInputController.isDiacriticOnlyKey(c, vni: true),
                           "in VNI a letter is always literal")
        }
    }

    func testTrailingWordExtraction() {
        XCTAssertEqual(TelexInputController.trailingWord("xin chao toan"), "toan")
        XCTAssertEqual(TelexInputController.trailingWord("toan"), "toan")
        XCTAssertEqual(TelexInputController.trailingWord("Đường"), "Đường")
        XCTAssertEqual(TelexInputController.trailingWord("(hoa"), "hoa")
        // Stops at anything that is not a letter — no re-editable tail at all.
        XCTAssertNil(TelexInputController.trailingWord("mp3"))
        XCTAssertNil(TelexInputController.trailingWord("a-b-"))
        XCTAssertNil(TelexInputController.trailingWord("done "))
        XCTAssertNil(TelexInputController.trailingWord(""))
        XCTAssertNil(TelexInputController.trailingWord("x)"))
        // Longer than any syllable → not worth reading (the engine would refuse it).
        XCTAssertNil(TelexInputController.trailingWord("abcdefghijklmnop"))
    }
}

// TAP-path port of the same feature (2026-08-07 field report: worked in TextMate —
// in-place — but not in Google Chrome page content, which the 06/08 axDetect policy
// moved onto the tap). Only the PURE gate is unit-testable here — the AX read-back
// itself needs a live focused element, same limitation as the IMKit version above.
final class ReEditWordTapGateTests: XCTestCase {

    /// Issue #111 (Zalo, 02/10/2026): click sang hội thoại khác → activateServer →
    /// phím "w" đầu tiên seed chữ CŨ ("dà") từ AX → "ằ", "word␣" ra "dafword".
    /// Chuỗi thật: phím trong ô A, click (tap thấy TRƯỚC khi app đổi focus),
    /// activateServer, rồi phím đầu tiên trong ô B — phím đó không được tin AX.
    func testFirstKeyAfterFocusChangeIsNotStable() {
        var a = FocusAnchor()
        var epoch: UInt64 = 7
        _ = a.observe(epoch)                    // gõ trong ô A
        XCTAssertTrue(a.observe(epoch))         // phím tiếp theo, cùng ô
        _ = a.observe(epoch)                    // click vào danh sách hội thoại
        epoch += 1                              // Zalo đổi focus → activateServer
        XCTAssertFalse(a.observe(epoch), "phím đầu trong ô mới: AX có thể còn là ô cũ")
        XCTAssertTrue(a.observe(epoch), "từ phím thứ hai trong ô mới: như cũ")
    }

    /// Ca chính của re-edit giữ nguyên: click ở cuối một từ TRONG ô đang focus
    /// (không activateServer) rồi gõ dấu.
    func testClickInsideSameFieldStaysStable() {
        var a = FocusAnchor()
        _ = a.observe(3)                        // phím trước
        _ = a.observe(3)                        // click cuối từ, không đổi focus
        XCTAssertTrue(a.observe(3))
    }

    /// Click sang ô khác (activateServer tới SAU click) rồi click lần nữa trong ô
    /// đó: click sau neo lại → re-edit mở.
    func testSecondClickAfterFocusChangeReArms() {
        var a = FocusAnchor()
        _ = a.observe(1)                        // click đổi ô
        _ = a.observe(2)                        // click lại trong ô mới (sau activate)
        XCTAssertTrue(a.observe(2))
    }

    /// Chưa từng neo (phím đầu tiên từ khi chạy tap) → không tin.
    func testNeverAnchoredIsNotStable() {
        var a = FocusAnchor()
        XCTAssertFalse(a.observe(0))
    }

    func testClientFocusEpochAdvancesOnEveryActivation() {
        let e0 = ClientFocus.epoch
        ClientFocus.noteActivated(client: "com.vng.zalo")
        ClientFocus.noteActivated(client: "com.vng.zalo")
        XCTAssertEqual(ClientFocus.epoch, e0 &+ 2, "re-activate cùng app vẫn là đổi focus")
    }

    /// Issue #62 (Zalo, 26/08/2026): ⌫ nhanh rồi gõ "s" → seed AX cũ → "asa".
    /// Seed bị cấm trong cooldown sau ⌫ vật lý và khi queue synthetic chưa drain.
    func testNoSeedRightAfterPhysicalDelete() {
        // Trong cooldown 500ms sau ⌫ → đóng gate (chuỗi lỗi của #62).
        XCTAssertFalse(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: true, emitMode: .backspace,
            lastKeyWasBoundary: false, queueDrained: true, msSinceDelete: 80))
        XCTAssertFalse(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: true, emitMode: .backspace,
            lastKeyWasBoundary: false, queueDrained: true,
            msSinceDelete: TerminalTapController.reEditDeleteCooldownMs - 1))
        // Hết cooldown → mở lại.
        XCTAssertTrue(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: true, emitMode: .backspace,
            lastKeyWasBoundary: false, queueDrained: true,
            msSinceDelete: TerminalTapController.reEditDeleteCooldownMs))
    }

    func testNoSeedWhileSyntheticQueueInFlight() {
        XCTAssertFalse(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: true, emitMode: .backspace,
            lastKeyWasBoundary: false, queueDrained: false, msSinceDelete: .max))
    }

    func testOpensOnlyInBackspaceEmitMode() {
        XCTAssertTrue(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: true, emitMode: .backspace,
            lastKeyWasBoundary: false))
        // The omnibox/search-bar's inline autocomplete is exactly what re-edit must
        // avoid — .selection and .emptyReset are the per-field browser modes for it.
        XCTAssertFalse(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: true, emitMode: .selection,
            lastKeyWasBoundary: false))
        XCTAssertFalse(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: true, emitMode: .emptyReset,
            lastKeyWasBoundary: false))
    }

    /// Issue #135 (Zalo, 28/10/2026): bấm "Trả lời" tin nhắn cũ (nút NGOÀI ô soạn, không
    /// activateServer) rồi gõ "w" → re-edit seed chữ cũ "dung" từ AX → ⌫×3 + "ưng" vào ô
    /// trống. Click ngoài khung ô đang focus không được re-arm re-edit.
    func testClickOutsideFocusedFieldDoesNotArmReEdit() {
        let composer = CGRect(x: 300, y: 800, width: 600, height: 40)   // CG, gốc trên-trái
        let replyButton = CGPoint(x: 700, y: 420)                        // trên bong bóng tin nhắn
        XCTAssertFalse(ReEditClickCheck.allows(click: replyButton, fieldFrame: composer))
        let sendButton = CGPoint(x: 930, y: 820)                         // nút Gửi bên phải ô
        XCTAssertFalse(ReEditClickCheck.allows(click: sendButton, fieldFrame: composer))
    }

    /// Ca chính của re-edit giữ nguyên: click ở cuối một từ TRONG ô rồi gõ dấu.
    func testClickInsideFocusedFieldStillArmsReEdit() {
        let composer = CGRect(x: 300, y: 800, width: 600, height: 40)
        XCTAssertTrue(ReEditClickCheck.allows(click: CGPoint(x: 420, y: 815), fieldFrame: composer))
        // Mép ô (caret sát viền) vẫn tính là trong ô.
        XCTAssertTrue(ReEditClickCheck.allows(click: CGPoint(x: 298, y: 801), fieldFrame: composer))
    }

    /// Không có click kể từ phím trước ⇒ luật không áp dụng (gõ ⌫ rồi thêm dấu như cũ).
    func testNoClickMeansNoClickRestriction() {
        XCTAssertTrue(ReEditClickCheck.allows(click: nil, fieldFrame: nil))
    }

    /// Có click nhưng không đọc được khung ô (AX mù/timeout) ⇒ fail-closed: không seed.
    func testUnknownFieldFrameAfterClickFailsClosed() {
        XCTAssertFalse(ReEditClickCheck.allows(click: CGPoint(x: 10, y: 10), fieldFrame: nil))
        XCTAssertFalse(ReEditClickCheck.allows(click: CGPoint(x: 0, y: 0), fieldFrame: .zero))
    }

    /// Cơ chế ra "ưng" của #135: seed "dung" (chữ cũ AX báo trước con trỏ) rồi "w" ⇒
    /// engine thay 3 ký tự cuối bằng "ưng". Ô thật đang trống nên 3 ⌫ không xoá gì và
    /// màn hình còn đúng "ưng". Engine trống thì "w" ra "ư" — cái user mong.
    func testStaleSeedExplainsUngSymptom() {
        var seeded = TelexEngine()
        seeded.freeMarking = true   // mặc định của app (AppState.freeMarking)
        XCTAssertTrue(seeded.seed("dung"))
        let action = seeded.feed("w")
        guard case let .replace(bs, insert) = action else {
            return XCTFail("seed + w phải là một phép thay, được \(action)")
        }
        XCTAssertEqual(bs, 3)
        XCTAssertEqual(insert, "ưng")
        var fresh = TelexEngine()
        fresh.freeMarking = true
        _ = fresh.feed("w")
        XCTAssertEqual(fresh.composed, "ư")
    }

    func testRequiresEmptyEngineEnabledSettingAndDiacriticKey() {
        XCTAssertTrue(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: true, emitMode: .backspace,
            lastKeyWasBoundary: false))
        // Mid-word (engine not empty): a plain tone edit, not a re-edit — never seed.
        XCTAssertFalse(TerminalTapController.reEditGateOpen(
            engineIsEmpty: false, reEditEnabled: true, isDiacriticKey: true, emitMode: .backspace,
            lastKeyWasBoundary: false))
        // Feature off.
        XCTAssertFalse(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: false, isDiacriticKey: true, emitMode: .backspace,
            lastKeyWasBoundary: false))
        // A plain letter never triggers the read-back, same as the IMKit gate.
        XCTAssertFalse(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: false, emitMode: .backspace,
            lastKeyWasBoundary: false))
    }

    /// Issue #38 (2026-08-12): `git st` in PhpStorm's terminal — the space committed
    /// "git", but JetBrains' laggy AX tree still showed the text WITHOUT the space,
    /// so the tap re-edit seeded "git" across the boundary and the `s` of "st"
    /// became sắc ("gít"). A tone key whose PREVIOUS key was a boundary must never
    /// re-edit, whatever the AX text claims — the keystream can't be stale.
    func testToneKeyRightAfterBoundaryNeverReEdits() {
        XCTAssertFalse(TerminalTapController.reEditGateOpen(
            engineIsEmpty: true, reEditEnabled: true, isDiacriticKey: true, emitMode: .backspace,
            lastKeyWasBoundary: true))
    }
}

// Issue #40 — "tháy" ␣ ⌫ then `a` must give "thấy". The engine keeps the committed
// word (TelexEngine.reopenLastCommit, covered by ReopenTests) but may only put it back
// when the ⌫ is deleting a BOUNDARY CHARACTER: that is true only if the key that ended
// the word left exactly one character behind it. This is the pure half of that rule;
// the read-back that verifies the screen needs a live client/AX tree.
final class ReopenBoundaryKeyTests: XCTestCase {

    func testPrintableAsciiKeysInsertOneCharacter() {
        for s in [" ", ".", ",", "!", "-", "5", "(", "/", "~"] {
            XCTAssertTrue(TelexInputController.insertsOneCharacter(s),
                          "'\(s)' puts one character after the word")
        }
    }

    func testKeysThatInsertNothingOrSomethingElse() {
        // Arrow / function keys arrive as U+F700… — they move the caret, insert nothing.
        for scalar: UInt32 in [0xF700, 0xF701, 0xF702, 0xF703, 0xF729, 0xF72B] {
            XCTAssertFalse(TelexInputController.insertsOneCharacter(String(UnicodeScalar(scalar)!)),
                           "U+\(String(scalar, radix: 16)) is navigation, not text")
        }
        // Control characters (Return/Tab/Esc reach the keycode branch, but iTerm also
        // delivers arrows as 0x1C–0x1F) and DEL.
        for scalar: UInt32 in [0x00, 0x09, 0x0D, 0x1B, 0x1C, 0x1F, 0x7F] {
            XCTAssertFalse(TelexInputController.insertsOneCharacter(String(UnicodeScalar(scalar)!)))
        }
        // Non-ascii text and multi-character strings: not worth reasoning about.
        XCTAssertFalse(TelexInputController.insertsOneCharacter("–"))
        XCTAssertFalse(TelexInputController.insertsOneCharacter("ơ"))
        XCTAssertFalse(TelexInputController.insertsOneCharacter("ab"))
        XCTAssertFalse(TelexInputController.insertsOneCharacter(""))
        XCTAssertFalse(TelexInputController.insertsOneCharacter(nil))
    }
}

// The ⌫ guard: our tracked composition window may only be rewritten while the app's
// caret still agrees with it. Tester report 2026-07-27 (Chrome Web Store search box):
// the first ⌫ ate TWO characters and afterwards nothing typed showed up until a space —
// a React-controlled input had moved/re-rendered under the tracked range.
final class TrackedWindowFreshnessTests: XCTestCase {

    func testFreshWithinTheStaleCaretLagWindowNoSelection() {
        XCTAssertTrue(TelexInputController.trackedWindowIsFresh(caret: 12, selectionLength: 0, expected: 12))
        // A selection (inline autocomplete suffix) would be swallowed by the rewrite.
        XCTAssertFalse(TelexInputController.trackedWindowIsFresh(caret: 12, selectionLength: 3, expected: 12))
        // NỚI 05/08/2026: caret TRỄ trong lag window (Chromium trả selectedRange từ
        // cache một-edit-behind, cùng staleness InPlaceProbe.verdict đã khoan dung) —
        // Discord-web: caret=18 expected=19 ở ⌫ làm guard này drop composition và thả
        // ⌫ native, editor Lexical xóa nguyên text node → "đây" ⌫ 1 phát còn "đ".
        // Caret chỉ là nhân chứng độ tươi; range rewrite lấy từ bookkeeping của mình.
        XCTAssertTrue(TelexInputController.trackedWindowIsFresh(caret: 11, selectionLength: 0, expected: 12))
        XCTAssertTrue(TelexInputController.trackedWindowIsFresh(caret: 8, selectionLength: 0, expected: 12))   // lag 4 = biên
        XCTAssertFalse(TelexInputController.trackedWindowIsFresh(caret: 7, selectionLength: 0, expected: 12))  // quá lag window
        // Caret Ở TRƯỚC (ahead) vẫn là re-render/moved → drop như cũ (lớp Chrome Web
        // Store 2026-07-27: ⌫ đầu ăn 2 ký tự).
        XCTAssertFalse(TelexInputController.trackedWindowIsFresh(caret: 13, selectionLength: 0, expected: 12))
        // No caret at all → never rewrite blind.
        XCTAssertFalse(TelexInputController.trackedWindowIsFresh(caret: nil, selectionLength: 0, expected: 12))
        // Start of a field is a normal, fresh state.
        XCTAssertTrue(TelexInputController.trackedWindowIsFresh(caret: 0, selectionLength: 0, expected: 0))
    }

    /// Issue #37 (Google Docs on Safari): the guard exists for the IN-PLACE
    /// insertText(range) rewrite; marked mode never performs one — its ⌫ goes
    /// engine.backspace() → setMarkedText, correct by the composition session.
    /// Running the guard there dropped the composition on the first mid-word ⌫
    /// (`onLen` never advances in marked mode, so `expected` stayed at the anchor)
    /// and orphaned the underlined word — every later ⌫/space dead until a click.
    func testFreshnessGuardIsInPlaceOnly() {
        XCTAssertTrue(TelexInputController.backspaceFreshnessGuardApplies(marked: false))
        XCTAssertFalse(TelexInputController.backspaceFreshnessGuardApplies(marked: true))
    }
}

// The engine answers `.passthrough` once a word passes its 32-key capacity: from then on
// its raw/composed view is a stale prefix of what the app has on screen, so the KEY must
// be handled by the app, never diffed. Two controller branches used to ignore that:
// a tracked in-place ⌫ rewrote the window (first ⌫ wiped every overflow character, then
// ⌫ went dead for the rest of the word because each rewrite produced identical text), and
// a marked-text app re-set its unchanged prefix while consuming the event (33rd+ letters
// vanished silently). Both are invisible in a log, hence pinned here.
final class EnginePassthroughContractTests: XCTestCase {

    func testTrackedInPlaceBackspaceMustNotRewriteOnOverflow() {
        XCTAssertEqual(
            TelexInputController.passthroughPlan(overflowPassthrough: true, marked: false, isBackspace: true),
            .shrinkWindowAndPassThrough)
    }

    func testMarkedAppCommitsAndLetsTheKeyThroughOnOverflow() {
        // Both directions: the 33rd letter and a ⌫ on an overflowed word.
        XCTAssertEqual(
            TelexInputController.passthroughPlan(overflowPassthrough: true, marked: true, isBackspace: false),
            .commitAndPassThrough)
        XCTAssertEqual(
            TelexInputController.passthroughPlan(overflowPassthrough: true, marked: true, isBackspace: true),
            .commitAndPassThrough)
    }

    func testInPlaceLetterKeepsItsOwnOrderedInsert() {
        // In-place mode already inserts the overflow letter through our insertText
        // channel — it must NOT be diverted (a system passthrough-insert would race
        // our own edits and corrupt words).
        XCTAssertEqual(
            TelexInputController.passthroughPlan(overflowPassthrough: true, marked: false, isBackspace: false),
            .honorEngineAction)
    }

    func testNonPassthroughActionsAreLeftAlone() {
        for marked in [true, false] {
            for backspace in [true, false] {
                XCTAssertEqual(
                    TelexInputController.passthroughPlan(overflowPassthrough: false, marked: marked,
                                                         isBackspace: backspace),
                    .honorEngineAction)
            }
        }
    }

    func testPassthroughDetectionMatchesOnlyThePassthroughCase() {
        XCTAssertTrue(TelexInputController.isPassthrough(.passthrough))
        XCTAssertFalse(TelexInputController.isPassthrough(.none))
        XCTAssertFalse(TelexInputController.isPassthrough(.replace(backspaces: 0, insert: "a")))
        XCTAssertFalse(TelexInputController.isPassthrough(.replace(backspaces: 2, insert: "ế")))
    }

    /// The real overflow trigger, so the tests above stay tied to the engine contract
    /// rather than to an assumption about it. NOTE: `.passthrough` alone is NOT the
    /// overflow signal — ordinary literal letters (the very first "a") also answer
    /// `.passthrough` while being recorded. Overflow = `.passthrough` AND
    /// `engine.isOverflowed` (key NOT recorded, composed frozen).
    func testEngineOverflowContractPastCapacity() {
        var engine = TelexEngine()
        for _ in 0..<32 {
            _ = engine.feed("a")
            XCTAssertFalse(engine.isOverflowed)            // keys 1–32 are recorded
        }
        let frozen = engine.composed
        let a33 = engine.feed("a")                          // 33rd key: NOT recorded
        XCTAssertTrue(TelexInputController.isPassthrough(a33))
        XCTAssertTrue(engine.isOverflowed)
        XCTAssertEqual(engine.composed, frozen)             // stale prefix stays put
        XCTAssertTrue(TelexInputController.isPassthrough(engine.backspace())) // and every ⌫ after
        XCTAssertTrue(engine.isOverflowed)
        XCTAssertTrue(TelexInputController.isPassthrough(engine.backspace()))
    }

    /// A plain first letter answers `.passthrough` too (recorded, composition live) —
    /// it must NOT be treated as overflow, or marked-text composition would be
    /// committed on the first key of every word.
    func testOrdinaryLiteralPassthroughIsNotOverflow() {
        var engine = TelexEngine()
        let a1 = engine.feed("a")
        XCTAssertTrue(TelexInputController.isPassthrough(a1))
        XCTAssertFalse(engine.isOverflowed)
        XCTAssertEqual(engine.composed, "a")                // the key WAS recorded
        XCTAssertEqual(
            TelexInputController.passthroughPlan(
                overflowPassthrough: TelexInputController.isPassthrough(a1) && engine.isOverflowed,
                marked: true, isBackspace: false),
            .honorEngineAction)                              // marked path stays live
    }
}

// Password fields must never be composed into. `IsSecureEventInputEnabled()` only covers
// apps that switch secure input on — a web <input type="password"> does not, and the
// `.emptyReset` strategy's U+202F placeholder then lands in the password as a stray
// character (field report 2026-07-27: "điền password thấy nó inject thêm 1-2 ký tự").
// The AX subrole is the signal; this pins its polarity, because a false POSITIVE would
// silently stop Vietnamese typing everywhere.
final class SecureFieldDetectionTests: XCTestCase {

    func testOnlyTheExplicitPasswordSubroleCounts() {
        XCTAssertTrue(SecureFieldDetector.isSecureSubrole("AXSecureTextField"))
        // Ordinary fields and every "we don't know" answer must read as NOT secure.
        for subrole in ["AXStandardWindow", "AXSearchField", "AXTextField", "", "AXUnknown"] {
            XCTAssertFalse(SecureFieldDetector.isSecureSubrole(subrole), "'\(subrole)' is not a password field")
        }
        XCTAssertFalse(SecureFieldDetector.isSecureSubrole(nil), "no subrole → compose as usual")
    }
}

// Multi-char unicode inserts must be posted one CHARACTER per event: Chromium routes
// a multi-char CGEvent string through a slower path than a plain 1-char keydown, so a
// following event can overtake it in the renderer — web terminal, 2026-08-01:
// "vim test." became "vim t.est" (the boundary "." passed the "est" restore burst).
final class UnicodeInsertChunkingTests: XCTestCase {
    func testSplitsPerCharacter() {
        XCTAssertEqual(SyntheticKeyboard.unicodeInsertChunks("est"), ["e", "s", "t"])
        XCTAssertEqual(SyntheticKeyboard.unicodeInsertChunks("."), ["."])
        XCTAssertEqual(SyntheticKeyboard.unicodeInsertChunks(""), [])
    }
    func testKeepsPrecomposedAndCombiningPairsWhole() {
        XCTAssertEqual(SyntheticKeyboard.unicodeInsertChunks("ệt"), ["ệ", "t"])
        // A decomposed pair (e + combining circumflex + dot below) must stay one chunk —
        // splitting scalars would post an orphan combining mark.
        let decomposed = "e\u{0302}\u{0323}t"
        XCTAssertEqual(SyntheticKeyboard.unicodeInsertChunks(decomposed).count, 2)
    }

    /// End-to-end invariant, not just the pure chunker: every chunk that reaches the
    /// POST SITE is exactly one Character. Pins postUnicode's routing through the
    /// chunker — a future "optimization" that batches the string into one event again
    /// would reintroduce the renderer reorder ("t.est") and turn this red. (The test
    /// host has no event source, so nothing is actually posted — the seam records
    /// sizes before the source guard.)
    func testPostSiteNeverSeesAMultiCharacterChunk() {
        SyntheticKeyboard._testPostUnicode("est")
        XCTAssertEqual(SyntheticKeyboard._testChunkSizes, [1, 1, 1])
        SyntheticKeyboard._testPostUnicode("ệt")
        XCTAssertEqual(SyntheticKeyboard._testChunkSizes, [1, 1])
        SyntheticKeyboard._testPostUnicode("")
        XCTAssertEqual(SyntheticKeyboard._testChunkSizes, [])
    }
}

// A verify probe whose replace was applied by a BOUNDARY key (Return/Enter/Tab/Esc)
// reads a field the app may have already consumed — Enter SENDS the message and the
// composer clears, so the async caret describes the reset field, not our edit.
// Tester log 2026-08-04: every "appended twice → marked" demotion took its deciding
// strike ~1ms after Enter → mọi app phải Enter 2 lần. Boundary probes are log-only.
final class BoundaryProbeDowngradeTests: XCTestCase {
    func testVerifyAtBoundaryBecomesShadow() {
        XCTAssertEqual(TelexInputController.effectiveProbeKind(.verify, boundaryCommit: true), .shadow)
    }
    func testEverythingElseUnchanged() {
        XCTAssertEqual(TelexInputController.effectiveProbeKind(.verify, boundaryCommit: false), .verify)
        XCTAssertEqual(TelexInputController.effectiveProbeKind(.real, boundaryCommit: true), .real)
        XCTAssertEqual(TelexInputController.effectiveProbeKind(.real, boundaryCommit: false), .real)
        XCTAssertEqual(TelexInputController.effectiveProbeKind(.shadow, boundaryCommit: true), .shadow)
    }
}

// Issue #156 (Ghostty, 10/11/2026): đổi focus sang split khác không bằng click / phím
// ranh giới ⇒ engine của tap còn giữ chữ của ô CŨ, từ đầu tiên ở ô mới dính vào nó
// ("m" ở split A, rồi "vieejt␣" ở split B ra "vieejt"). Và: TUI dùng j/k/i làm lệnh
// ⇒ engine "jkivieejt"; app cần một tín hiệu "kết thúc từ" (EndWordSignal).
// Mô phỏng đúng thứ tự trên đường phím của tap: neo FocusAnchor → TapWordBreak →
// (bỏ từ) → feed. Chính nhánh trong TerminalTapController.handle không unit-test được
// (CGEvent + post thật) nên quyết định được tách ra hàm thuần.
final class TapWordBreakTests: XCTestCase {

    /// Một phiên tap tối giản: cùng engine, cùng neo, controller IMK + cờ IMK do test
    /// điều khiển. Ranh giới (khoảng trắng, chữ số) đi như tap: tra gõ tắt với cờ
    /// dính-số + cụm (ShortcutTail), rồi nối vào cụm.
    private struct TapSession {
        var engine: TelexEngine = {
            var e = TelexEngine(); e.freeMarking = true; return e
        }()
        var anchor: FocusAnchor = { var a = FocusAnchor(); _ = a.observe(7); return a }()   // đã neo ở ô 7
        var epoch: UInt64 = 40
        var controller: UInt64 = 7       // serial controller IMK đang activate
        private var nextController: UInt64 = 100
        var clientKey = false            // IMK đã thấy phím trong client vừa activate
        var chromium: Bool? = false
        var endWordPending = false
        var breaks = 0
        var glued = false                // lastTapKeyWasDigit
        var tail = ShortcutTail()
        var table = ShortcutTable(["ko": "không"])
        var expansions: [String] = []

        /// activateServer của controller KHÁC (ô khác): epoch +1, serial mới, cờ IMK xoá.
        mutating func activate() { nextController &+= 1; activate(controller: nextController) }
        /// activateServer của một controller cụ thể (cùng serial = cùng ô activate lại).
        mutating func activate(controller id: UInt64) { epoch &+= 1; controller = id; clientKey = false }
        mutating func reactivateSameField() { activate(controller: controller) }

        mutating func key(_ ch: Character) {
            let stable = anchor.observe(controller)
            let ck = clientKey, chr = chromium
            if !stable, TapWordBreak.focusMoved(focusStable: stable,
                                                clientKeySinceActivation: { ck },
                                                chromiumFamily: { chr }) {
                // = abandonWordForNewContext
                engine.reset(); tail.caretMoved(); glued = false; breaks += 1
            }
            if TapWordBreak.endWord(signalPending: endWordPending,
                                    engineHoldsWord: !engine.isEmpty || engine.canReopenLastCommit) {
                engine.reset(); breaks += 1
            }
            endWordPending = false
            if ch.isLetter {
                _ = engine.feed(ch)
                return
            }
            let b = String(ch)
            let allow = ShortcutMatch.triggers(boundary: b, glued: glued)
            let m = ShortcutMatch.find(in: table, composed: engine.composed, raw: engine.rawKeystrokes,
                                       run: tail.run, allowWord: allow.word, allowToken: allow.token,
                                       allowAlnum: allow.alnum)
            if let m { expansions.append(m.expansion) }
            tail.append(m?.expansion ?? engine.composed)
            tail.append(b)
            engine.reset()
            glued = TelexInputController.gluesShortcutToken(ch.asciiValue)
        }

        mutating func type(_ s: String) { for c in s { key(c) } }
        /// Click: tap reset engine + neo lại (nhánh leftMouseDown).
        mutating func click() { engine.reset(); tail.caretMoved(); glued = false; _ = anchor.observe(controller) }
    }

    /// Ca của issue: "m" ở split A, AppleScript đổi focus (activateServer), "vieejt" ở B.
    func testFocusMoveWithoutClickStartsNewWord() {
        var s = TapSession()
        s.type("m")
        s.activate()                                  // split B được focus
        s.type("vieejt")
        XCTAssertEqual(s.engine.composed, "việt", "từ đầu tiên ở ô mới không dính chữ ô cũ")
        XCTAssertEqual(s.breaks, 1)
    }

    /// Follow-up #156: CÙNG ô activate lại giữa từ (WKWebView deactivate→activate ~250 ms,
    /// MACOS_IME_NOTES) — "viê" + activate lại + "tj" phải ra "việt", không "viêtj".
    func testSameControllerReactivationMidWordKeepsTheWord() {
        var s = TapSession()
        s.type("viee")
        s.reactivateSameField()
        s.type("tj")
        XCTAssertEqual(s.engine.composed, "việt")
        XCTAssertEqual(s.breaks, 0)
    }

    /// A → B → A không phím nào ở B: quay về đúng ô cũ, con trỏ không dời ⇒ giữ từ.
    func testReturningToTheSameControllerKeepsTheWord() {
        var s = TapSession()
        let a = s.controller
        s.type("viee")
        s.activate()                                  // B
        s.activate(controller: a)                     // lại A
        s.type("tj")
        XCTAssertEqual(s.engine.composed, "việt")
        XCTAssertEqual(s.breaks, 0)
    }

    /// Hành vi cũ (lỗi) để biết test trên thật sự bảo vệ điều gì.
    func testWithoutBreakTheWordGlues() {
        var e = TelexEngine(); e.freeMarking = true
        for c in "mvieejt" { _ = e.feed(c) }
        XCTAssertNotEqual(e.composed, "việt")
    }

    /// Không đổi focus ⇒ giữ từ, gõ liền một mạch.
    func testSameFocusKeepsTheWord() {
        var s = TapSession()
        s.type("vie")
        s.type("ejt")
        XCTAssertEqual(s.engine.composed, "việt")
        XCTAssertEqual(s.breaks, 0)
        XCTAssertFalse(TapWordBreak.focusMoved(focusStable: true,
                                               clientKeySinceActivation: { false },
                                               chromiumFamily: { false }))
    }

    /// Cuộc đua phím đầu (#110 — Raycast): activateServer tới SAU phím đầu tiên của ô
    /// mới, và IMK đã nhận phím đó trong client mới ⇒ KHÔNG reset, phím đầu không mất.
    func testLateActivationNeverDropsTheFirstKey() {
        var s = TapSession()
        s.type("d")                                   // phím đầu ở ô mới, engine rỗng trước đó
        s.activate()                                  // activateServer tới trễ…
        s.clientKey = true                            // …ngay trước handle(d) của client mới
        s.type("di")
        XCTAssertEqual(s.engine.composed, "đi", "phím đầu \"d\" phải còn trong từ")
        XCTAssertEqual(s.breaks, 0)
    }

    /// Follow-up #156: đổi ô khi engine RỖNG vẫn bỏ ngữ cảnh của ô cũ — "50" ở split A
    /// (cờ dính-số, cụm "50"), đổi focus, "ko␣" ở split B phải nở "không".
    func testNumberThenFocusMoveThenShortcutExpands() {
        XCTAssertTrue(TapWordBreak.focusMoved(focusStable: false,
                                              clientKeySinceActivation: { false },
                                              chromiumFamily: { false }),
                      "engine rỗng vẫn là đổi ô")
        var s = TapSession()
        s.type("50")
        XCTAssertTrue(s.engine.isEmpty)
        let before = s.breaks
        s.activate()                                  // split B
        s.type("ko ")
        XCTAssertEqual(s.expansions, ["không"])
        XCTAssertEqual(s.breaks, before + 1)
    }

    /// Đối chứng: cùng ô, "50ko␣" là từ dính số (#82) ⇒ không nở.
    func testNumberGluedWordInSameFieldDoesNotExpand() {
        var s = TapSession()
        s.type("50ko ")
        XCTAssertEqual(s.expansions, [])
    }

    /// Chromium/Electron: activateServer có thể tới giữa từ trong cùng ô ⇒ không áp
    /// luật; chưa dò xong họ app (nil) ⇒ cũng không (giữ hành vi cũ, fail-closed).
    func testChromiumAndElectronAreExcluded() {
        XCTAssertFalse(TapWordBreak.focusMoved(focusStable: false,
                                               clientKeySinceActivation: { false },
                                               chromiumFamily: { true }))
        XCTAssertFalse(TapWordBreak.focusMoved(focusStable: false,
                                               clientKeySinceActivation: { false },
                                               chromiumFamily: { nil }))
        var s = TapSession(); s.chromium = true
        s.type("vie"); s.activate(); s.type("ejt")    // popup gợi ý giữa từ: từ đi tiếp
        XCTAssertEqual(s.engine.composed, "việt")
        XCTAssertEqual(s.breaks, 0)
    }

    /// Ca thường (ổn định) không chạm cờ IMK hay đĩa: closure không được gọi.
    func testStableFocusReadsNothingElse() {
        var touched = false
        _ = TapWordBreak.focusMoved(focusStable: true,
                                    clientKeySinceActivation: { touched = true; return false },
                                    chromiumFamily: { touched = true; return false })
        XCTAssertFalse(touched)
    }

    /// Phần 2: TUI nuốt j/k/i làm lệnh rồi báo "kết thúc từ" ⇒ "vieejt" ra "việt".
    func testEndWordSignalStartsNewWord() {
        var s = TapSession()
        s.type("jki")
        let before = s.breaks
        s.endWordPending = true
        s.type("vieejt")
        XCTAssertEqual(s.engine.composed, "việt")
        XCTAssertEqual(s.breaks, before + 1)
    }

    /// Tín hiệu khi engine rỗng: không làm gì (không đếm là một lần bỏ từ).
    func testEndWordSignalOnEmptyEngineDoesNothing() {
        XCTAssertFalse(TapWordBreak.endWord(signalPending: true, engineHoldsWord: false))
        XCTAssertFalse(TapWordBreak.endWord(signalPending: false, engineHoldsWord: true))
        XCTAssertTrue(TapWordBreak.endWord(signalPending: true, engineHoldsWord: true))
        var s = TapSession()
        _ = s.anchor.observe(s.controller)
        s.endWordPending = true
        s.type("vieejt")
        XCTAssertEqual(s.engine.composed, "việt")
        XCTAssertEqual(s.breaks, 0)
    }

    /// ClientFocus: activateServer xoá cờ phím IMK, phím IMK đặt lại; ghi serial controller.
    func testClientFocusTracksIMKKeySinceActivation() {
        ClientFocus.noteActivated(client: "com.mitchellh.ghostty", controller: 11)
        XCTAssertFalse(ClientFocus.clientKeySinceActivation)
        XCTAssertEqual(ClientFocus.snapshot.controller, 11)
        ClientFocus.noteClientKey()
        XCTAssertTrue(ClientFocus.clientKeySinceActivation)
        ClientFocus.noteActivated(client: "com.mitchellh.ghostty", controller: 12)
        XCTAssertFalse(ClientFocus.clientKeySinceActivation, "split mới: chưa có phím nào")
        XCTAssertEqual(ClientFocus.snapshot.controller, 12)
    }

    /// Serial controller: duy nhất, khác 0, tăng dần (không tái dùng như địa chỉ object).
    func testControllerSerialsAreUniqueAndNonZero() {
        let a = ClientFocus.newControllerSerial(), b = ClientFocus.newControllerSerial()
        XCTAssertNotEqual(a, 0)
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThan(b, a)
    }

    /// Re-edit (#111) vẫn thấy MỌI activate (epoch), kể cả cùng controller.
    func testEpochStillAdvancesOnSameControllerReactivation() {
        ClientFocus.noteActivated(client: "com.apple.Safari", controller: 21)
        let e0 = ClientFocus.snapshot.epoch
        ClientFocus.noteActivated(client: "com.apple.Safari", controller: 21)
        XCTAssertEqual(ClientFocus.snapshot.epoch, e0 &+ 1)
        XCTAssertEqual(ClientFocus.snapshot.controller, 21)
    }

    /// Tên tín hiệu là hợp đồng công khai (tài liệu + app bên ngoài) — đừng đổi.
    func testEndWordSignalNameIsStable() {
        XCTAssertEqual(EndWordSignal.name, "com.viettelex.endWord")
        XCTAssertNotEqual(EndWordSignal.name, Notification.Name.telexResetComposition.rawValue)
    }

    /// Phiên thật (bài học #116): gõ, click, đổi focus, activate lại cùng ô, đua phím đầu,
    /// số rồi đổi ô, tín hiệu — xen kẽ trên CÙNG một phiên.
    func testRealisticSessionSequence() {
        var s = TapSession()
        s.type("xin ")
        s.type("m")                                   // split A
        s.activate()                                  // AppleScript → split B
        s.type("vieejt")
        XCTAssertEqual(s.engine.composed, "việt")
        s.type(" ")
        s.click(); s.activate()                       // click sang ô khác (activate sau click)
        s.type("ddee")
        s.reactivateSameField()                       // WebKit activate lại cùng ô giữa từ
        s.type("nf")
        XCTAssertEqual(s.engine.composed, "đền", "cùng ô activate lại: không cắt từ")
        s.type(" ")
        s.type("n"); s.activate(); s.clientKey = true // đua phím đầu: activate trễ sau "n"
        s.type("aay")
        XCTAssertEqual(s.engine.composed, "nây")
        s.type(" 50")
        s.activate()                                  // đổi split sau số
        s.type("ko ")
        XCTAssertEqual(s.expansions, ["không"])
        s.type("j"); s.endWordPending = true          // TUI: "j" là lệnh, app báo kết thúc từ
        s.type("tooi")
        XCTAssertEqual(s.engine.composed, "tôi")
    }
}

// Follow-up #156: tín hiệu com.viettelex.endWord — post dồn dập (script gửi cả hai kênh,
// vòng lặp) không được thành một hàng dài lần giao trên MAIN; công tắc tắt = không có
// observer nào (0 chi phí).
final class EndWordSignalTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    /// Một lần giao đang chờ ⇒ lần post mới bị gộp, dù đã quá 50 ms.
    func testCoalescesWhileDeliveryPending() {
        var g = EndWordSignal.Gate()
        XCTAssertTrue(g.accept(nowNs: 1_000 * ms))
        XCTAssertFalse(g.accept(nowNs: 1_200 * ms), "đang chờ giao: gộp")
        g.delivered()
        XCTAssertTrue(g.accept(nowNs: 1_300 * ms))
    }

    /// Hai post cách nhau < 50 ms (Darwin + distributed cùng lúc) ⇒ chỉ một lần.
    func testIgnoresPostsCloserThanMinInterval() {
        var g = EndWordSignal.Gate()
        XCTAssertTrue(g.accept(nowNs: 1_000 * ms)); g.delivered()
        XCTAssertFalse(g.accept(nowNs: 1_000 * ms + 10 * ms))
        XCTAssertFalse(g.accept(nowNs: 1_000 * ms + 49 * ms))
        XCTAssertTrue(g.accept(nowNs: 1_000 * ms + 50 * ms))
        XCTAssertEqual(EndWordSignal.minIntervalNs, 50 * ms)
    }

    /// Công tắc: tắt ⇒ không đăng ký kênh nào; bật lại ⇒ đăng ký; lặp lại không đăng ký trùng.
    func testSwitchOffMeansNotRegistered() {
        EndWordSignal.apply(enabled: false)
        XCTAssertFalse(EndWordSignal.isRegistered)
        EndWordSignal.apply(enabled: true)
        XCTAssertTrue(EndWordSignal.isRegistered)
        EndWordSignal.apply(enabled: true)
        XCTAssertTrue(EndWordSignal.isRegistered)
        EndWordSignal.apply(enabled: false)
        EndWordSignal.apply(enabled: false)
        XCTAssertFalse(EndWordSignal.isRegistered)
    }

    /// Nhãn công tắc có bản tiếng Việt (chú thích nằm trong GeneralTab.C.all — test chung).
    func testSwitchTitleTranslated() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "vi", ofType: "lproj"))
        let vi = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(vi.localizedString(forKey: DiagnosticsSection.endWordTitle, value: "∅", table: nil),
                       "Nhận tín hiệu “kết thúc từ” từ app khác")
    }
}

// Tự cập nhật: (1) swap thất bại sau khi đã dừng tap (cách ly 600 s) phải bật lại tap
// ngay — trước đây terminal gõ chữ thô 10 phút; (2) bản tải về phải đúng bản đã hỏi và
// mới hơn bản đang chạy (không hạ cấp, không cài lại chính nó).
final class SelfUpdaterSafetyTests: XCTestCase {
    private struct SwapFailed: Error {}

    func testFailedSwapResumesTheTap() async {
        var log: [String] = []
        do {
            try await SelfUpdater.installStoppingTap(
                stop: { log.append("stop") },
                install: { log.append("install"); throw SwapFailed() },
                resume: { log.append("resume") })
            XCTFail("lỗi swap phải được ném tiếp (onFailure + hộp thoại)")
        } catch {
            XCTAssertTrue(error is SwapFailed)
        }
        XCTAssertEqual(log, ["stop", "install", "resume"])
    }

    func testSuccessfulSwapDoesNotResume() async throws {
        var log: [String] = []
        try await SelfUpdater.installStoppingTap(
            stop: { log.append("stop") },
            install: { log.append("install") },
            resume: { log.append("resume") })
        XCTAssertEqual(log, ["stop", "install"], "thành công ⇒ exit(0) sau đó, tap giữ nguyên dừng")
    }

    func testVersionGate() {
        XCTAssertNil(SelfUpdater.versionRefusal(downloaded: "1.9.4", requested: "1.9.4", running: "1.9.3"))
        // Zip đặt nhầm tên / bản khác bản đã hỏi.
        XCTAssertNotNil(SelfUpdater.versionRefusal(downloaded: "1.9.5", requested: "1.9.4", running: "1.9.3"))
        // Hạ cấp và cài lại chính nó.
        XCTAssertNotNil(SelfUpdater.versionRefusal(downloaded: "1.9.2", requested: "1.9.2", running: "1.9.3"))
        XCTAssertNotNil(SelfUpdater.versionRefusal(downloaded: "1.9.3", requested: "1.9.3", running: "1.9.3"))
        // Không có / sai định dạng phiên bản.
        XCTAssertNotNil(SelfUpdater.versionRefusal(downloaded: nil, requested: "1.9.4", running: "1.9.3"))
        XCTAssertNotNil(SelfUpdater.versionRefusal(downloaded: "1.9.4-beta", requested: "1.9.4", running: "1.9.3"))
        // So số, không so chuỗi: 1.10.0 mới hơn 1.9.3.
        XCTAssertNil(SelfUpdater.versionRefusal(downloaded: "1.10.0", requested: "1.10.0", running: "1.9.3"))
        // Bản đang chạy không đọc được: chỉ còn luật "đúng bản đã hỏi".
        XCTAssertNil(SelfUpdater.versionRefusal(downloaded: "1.9.4", requested: "1.9.4", running: nil))
    }
}

// Bảng Ứng dụng: chú thích "cách gõ an toàn" dùng đúng tên cách gõ (Phím thật / Gạch chân),
// mỗi cách gõ có một dòng giải thích (tooltip picker) cả hai ngôn ngữ, nút Nhập… có bản Việt.
final class ModeTableStringsTests: XCTestCase {
    private func vi() throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "vi", ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func testSafeCaptionUsesModeNames() throws {
        let v = try vi().localizedString(forKey: ModeTableTab.C.safe, value: "∅", table: nil)
        let tap = try vi().localizedString(forKey: ModeNames.tap, value: "∅", table: nil)
        let marked = try vi().localizedString(forKey: ModeNames.marked, value: "∅", table: nil)
        XCTAssertTrue(v.contains(tap), v)
        XCTAssertTrue(v.contains(marked), v)
        XCTAssertFalse(v.contains("Backspace"), v)
        XCTAssertTrue(ModeTableTab.C.safe.contains(ModeNames.tap))
    }

    func testEveryModeHasOneLineHelpInBothLanguages() throws {
        let b = try vi()
        XCTAssertEqual(Set(ModeTableTab.modeHelp.keys), Set(AppState.AppMode.allCases.map(\.rawValue)))
        for (tag, key) in ModeTableTab.modeHelp {
            let v = b.localizedString(forKey: key, value: "∅", table: nil)
            XCTAssertNotEqual(v, "∅", key)
            XCTAssertLessThanOrEqual(key.count, 95, key)
            XCTAssertLessThanOrEqual(v.count, 95, v)
            XCTAssertFalse(v.contains("\n") || key.contains("\n"), tag)
        }
        // Tooltip bắt đầu bằng đúng tên cách gõ hiện trong picker.
        let tapName = b.localizedString(forKey: ModeNames.tap, value: "∅", table: nil)
        XCTAssertTrue(b.localizedString(forKey: ModeTableTab.modeHelp["tap"]!, value: "∅", table: nil).hasPrefix(tapName))
        XCTAssertTrue(ModeTableTab.modeHelp["tap"]!.hasPrefix(ModeNames.tap))
    }

    func testImportStringsTranslated() throws {
        let b = try vi()
        XCTAssertEqual(b.localizedString(forKey: "Import…", value: "∅", table: nil), "Nhập…")
        XCTAssertNotEqual(b.localizedString(forKey: "Supported formats: YAML, JSON, or one key:value per line.",
                                            value: "∅", table: nil), "∅")
    }
}
