// TelexInputController.swift
// IMKInputController driving TelexCore. NO marked text: each transform is committed
// as real text in place via insertText(_:replacementRange:), so the composing word
// is never underlined and the caret always stays at the end — the behaviour
// Vietnamese typists expect. The engine emits a
// minimal (backspaces, insert) diff; we turn it into an in-place replacement using
// the client's real selection.

import Cocoa
import InputMethodKit
import TelexCore
import Carbon.HIToolbox

private let kNoRange = NSRange(location: NSNotFound, length: 0)

// No explicit @objc name: the class is exposed to the Objective-C runtime as
// "VietTelex.TelexInputController" (module-qualified), which is exactly the string
// Info.plist's InputMethodServerControllerClass declares and what IMK resolves via
// NSClassFromString. An explicit @objc(TelexInputController) renamed it to a bare
// "TelexInputController", so the lookup returned nil and macOS never registered the
// input method.
final class TelexInputController: IMKInputController {

    private var engine = TelexEngine()

    // Virtual keycodes we treat as word boundaries (besides punctuation chars).
    private let kDelete: UInt16 = 51
    private let kReturn: UInt16 = 36
    private let kEnter: UInt16 = 76
    private let kTab: UInt16 = 48
    private let kEscape: UInt16 = 53

    // In-place editing without marked text needs to know where the composed word
    // lives. We track it locally — the composition occupies [anchor, anchor+onLen),
    // caret at the end — and read selectedRange() only ONCE per word (its first
    // key). Reading it after every insert is stale under fast typing and corrupts
    // words ("được" -> "đựoc").
    private var anchor = 0        // document offset where the composition starts
    /// Phím ngay trước từ hiện tại là CHỮ SỐ (issue #82): "5h" là một token (5h30,
    /// 5k, 10k) — gõ tắt `h→giờ` không được nở ở đó, chỉ nở khi từ đứng riêng
    /// ("5 h"). Digit là boundary trong Telex nên từ "h" không tự biết nó dính số.
    private var wordGluedToDigit = false
    /// Gõ tắt khoá ký hiệu/số ("->", "√√", "k2"): cụm đã chốt liền trước từ hiện tại,
    /// dựng từ phím mình thấy (không đọc màn hình mỗi phím). Chỉ là bộ lọc rẻ — trước
    /// khi thay, màn hình LUÔN được đọc lại (tryTokenShortcut). Reset ở mọi sự kiện có
    /// thể dời con trỏ.
    private var shortcutTail = ShortcutTail()
    /// Cụm (shortcutTail.run) trước dấu cách gần nhất — chip số "2 tỷ" cần biết cụm số trước.
    private var numberPrevRun = ""
    /// Phím thô của từ vừa chốt ở ranh giới gần nhất ("" = không có) — gợi ý sửa lỗi gõ.
    private var lastCommitRaw = ""
    /// Từ bộ gõ vừa chốt ở ranh giới (boundary(); "" = không có / nở gõ tắt) — "Học từ bạn gõ".
    private var lastCommitWord = ""
    /// "Học từ bạn gõ" (LearnedWords.swift): lượt học chờ + ngữ cảnh của ô này.
    private var learn = LearnTracker()
    private var learnGen = 0
    private var learnClicks: UInt64 = 0
    /// Đếm âm tiết không dấu liên tiếp (gợi ý Thêm dấu) — chỉ cập nhật ở ranh giới khi bật.
    private var toneRun = ToneRunLogic.Tracker()
    /// Controller vừa activate (main) — CaretHint mượn client của nó để lấy firstRect cho ô nổi.
    private(set) static weak var activeController: TelexInputController?
    /// Số hiệu duy nhất của controller này (#156, ClientFocus.controller): IMK tạo một
    /// controller cho mỗi client/ô nhập — tap so số này để biết phím có sang ô khác không.
    let focusSerial: UInt64 = ClientFocus.newControllerSerial()
    /// ⌫ ngay sau khi nở gõ tắt → trả lại chữ đã gõ (một lần, chỉ in-place, verify màn
    /// hình). Bị tiêu thụ bởi BẤT KỲ phím thật nào tới sau.
    private var shortcutUndo: ShortcutUndo?
    /// "Tự sửa từ phía trước": ⌫ ngay sau lần sửa ngược → trả lại đúng văn bản cũ (một
    /// lần, verify màn hình — RetroEnglishApply.swift). Phím thật nào tới cũng tiêu thụ.
    private var retroUndo: RetroUndo?
    /// Cài đặt Nhập văn bản của macOS (SystemAutoText.swift): uptime ns của dấu cách vừa
    /// đi qua (0 = phím trước không phải dấu cách) — dấu chấm khi nhấn đúp phím cách;
    /// "—" vừa đổi từ "--" (gõ "-" tiếp ⇒ trả "---"); chữ đầu từ vừa được viết hoa tự
    /// động (⌫ nó ⇒ chữ đầu kế tiếp không viết hoa — user đã từ chối). Mọi phím thật
    /// tiêu thụ hai cờ đầu.
    private var periodSpaceNs: UInt64 = 0
    private var lastEmDashOurs = false
    private var autoCappedWord = false
    private var suppressAutoCap = false
    /// boundary() vừa nở gõ tắt: (chữ trên màn hình trước khi nở, nội dung). Caller
    /// biết ký tự ranh giới nên là nơi dựng shortcutUndo.
    private var expandedAtBoundary: (typed: String, expansion: String)?
    private var onLen = 0         // UTF-16 length of the composition on screen
    private var tracking = false  // is anchor/onLen valid for the current word?
    private var selToClear = 0    // selection length to overwrite on the first insert
    private var anchorVerified = false  // one-shot re-anchor done for this word?
    /// Consecutive catch-up waits that hit the budget (async-apply clients only) —
    /// see awaitAsyncClient. Reset on any catch-up and on activateServer.
    private var catchUpTimeouts = 0
    /// Timestamp of the last activateServer(Spotlight) — set on EVERY Spotlight
    /// activation, whatever the client was before it. Distinct from
    /// SpotlightDetector's visibility cache, which answers "is the overlay open
    /// right now"; this answers "did Spotlight's IMK session just get torn down
    /// and recreated" (field report 2026-08-11: Esc appears to reset the query
    /// without closing the overlay, cycling activateServer(iTerm)→
    /// activateServer(Spotlight) within ~1ms — the fresh session's
    /// client.selectedRange() then reported a stale huge caret (start=6632 in an
    /// emptied field), garbling the next word: "được" → "dđuưoựoược").
    private var lastSpotlightActivateNs: UInt64 = 0
    /// One-shot: set when the CURRENT activateServer(Spotlight) followed a
    /// PRIOR one closely enough that the fresh client's selectedRange() cannot be
    /// trusted as a real caret. Consumed by the very next word-start anchor.
    private var distrustNextAnchor = false
    /// Issue #110 vòng 2: phiên này là một overlay launcher (Raycast) vừa được activate
    /// — phím từ đầu tiên thử nhận lại từ mà tap đã chèn trước activateServer
    /// (TapHandoff). Một lần mỗi activation; mọi client khác: false, không tốn gì.
    private var pendingTapHandoff = false

    /// Pure so the 5s window is pinned by a test without mocking IMKTextInput.
    /// lastActivateNs == 0 means "never activated before" — never distrust the
    /// very first Spotlight session of the process's life.
    static func spotlightReactivatedTooSoon(now: UInt64, lastActivateNs: UInt64,
                                            thresholdNs: UInt64 = 5_000_000_000) -> Bool {
        lastActivateNs != 0 && now &- lastActivateNs < thresholdNs
    }
    /// EDGE-TAP (06/08/2026): the current word is anchored at field offset 0 in an
    /// app the user pinned to In-place, so its edits run on the synthetic-key
    /// channel instead of insertText. Web editors (Discord/Slate) ignore a
    /// replacementRange that starts at a block boundary and APPEND instead
    /// ("cos" đầu message → "coó" — field 06/08); synthetic ⌫-retype is the one
    /// channel they honor there. The WHOLE word stays on the CGEvent channel
    /// (letters pass native, replaces go synthetic) — mixing insertText with
    /// native/synthetic keys races under fast typing (same rule as the
    /// .passthrough comment below). Manual In-place pins only: native apps'
    /// offset-0 in-place is honored, and pinned apps get no verify probes, so
    /// this is the only guard their first word has.
    private var edgeTapWord = false
    /// Machine-speed key burst in THIS client (#118: OpenClaw types ~1 key/ms) — those
    /// keys pass through verbatim, no composition, no calls into the client.
    private var machineTyping = MachineTypingDetector()
    /// Echo budget of the edge word's synthetic bursts. macOS 26 strips the magic
    /// userData before events reach IMKit (measured: our own burst arrives
    /// "magic=false" even in TextEdit), so echoes are recognized by CONTENT:
    /// keycode 51 spends a backspace, characters==chunk spends a chunk. Whether
    /// a unicode chunk re-enters handle at all is app-dependent (Electron yes,
    /// native no — AppKit inserts it directly), which is exactly why a blind
    /// total count is wrong.
    private var edgeEchoBackspaces = 0
    private var edgeEchoChunks: [String] = []
    private var edgeEchoStampNs: UInt64 = 0
    /// Return/Tab/Esc mình nuốt + re-post sau khi chốt từ, và phím thật vượt lên trước
    /// bản sao đó — xem RepostOrder (field 18/10/2026: "- abc" ⏎ "- def" → "- abc- " ⏎ "def").
    private var repostOrder = RepostOrder()
    /// ≠ nil: bản re-post đầu hàng còn chờ hẹn giờ (web editor marked, 60ms) — phím vượt
    /// xếp ở đây và chỉ được post SAU khi Return/Tab đó đã post.
    private var repostHeld: [(key: CGKeyCode, flags: CGEventFlags)]?

    // Consecutive failed in-place read-back probes per bundleID. A single failure is
    // usually the app being busy during the probe, not a real incompatibility, so we
    // require TWO in a row before condemning an app to marked text forever. In-memory
    // only (no persistence): a fresh launch re-probes from scratch, which is fine.
    private var probeFailures: [String: Int] = [:]

    // Pending SELF-REPORTED honored confirmations per bundleID: in-place is committed
    // only after honored probes at two DISTINCT expected-caret offsets (a constant
    // garbage caret — Lark reports 1, always — can coincide with one offset but never
    // two). AX-backed honored verdicts skip this and commit immediately. In-memory
    // only, like probeFailures.
    private var probeHonors: [String: InPlaceProbe.HonorTracker] = [:]

    // (Session-field probation was tried here and REMOVED by decision 2026-07-21:
    // without Accessibility there is no field identity, so every focus change
    // re-probed at the cost of 1-2 glitched words — field-tested as "không ổn".
    // The no-AX policy is now simply: known-good in-place apps stay in-place,
    // everything else is marked text, no probing. See AppState.usesMarkedText.)

    // Last per-key routing decision logged (deduped): the strategy chosen in handle()
    // is logged only when it changes, so the debug log shows one line per app/mode
    // transition instead of one per keystroke.
    private var lastDecisionLog = ""
    private var lastEntryLog = ""
    private func logDecision(_ message: @autoclosure () -> String) {
        // @autoclosure: the interpolated string must NOT be built per keystroke when
        // logging is off — these sit on the hot path (an eager String parameter was
        // allocating+formatting on every key).
        guard AppState.shared.debugLogging else { return }
        let s = message()
        // Dedup keeps the ring readable in normal use, but hides the per-key picture
        // during diagnosis — while the debug flag is on, log EVERY decision (400
        // ring lines is plenty for a short repro).
        lastDecisionLog = s
        DebugLog.log(s)
    }

    // Observes the mouse tap's reset signal: a click moved the caret, so drop any
    // composition (the tap can't reach this controller's private engine directly).
    private var resetObserver: NSObjectProtocol?

    // One-shot dump of every TSM hilite style's attribute dict (experiment 3).
    private static var dumpedHiliteDicts = false

    // EXPERIMENT (log-only, gated on debugLogging): deferred re-probe context.
    // Chromium-class apps (Lark) serve AX from an ASYNC browser-side cache that is
    // built lazily on first query — the synchronous read inside probeInPlace can race
    // a stale/optimistic tree, which is the suspected cause of Lark "faking" every
    // probe signal. On the NEXT keyDown (hundreds of ms later, tree settled) re-read
    // the same region + the field length and log whether the verdict would change.
    // Never alters classification — data gathering for a future deferred verdict.
    private var pendingReprobe: (id: String?, start: Int, len: Int, bs: Int,
                                 inserted: String, verdict: InPlaceProbe.Verdict)?

    // Per-FOCUS re-verification of learned-in-place apps (tester log 2026-07-23).
    // Classification is per APP, but Chromium-class apps host many editors: one
    // site honors replacementRange, the next (EditContext-style) APPENDS — and a
    // learned-good app was never probed again, so that field stayed broken until
    // a reload ("gõ không ra gì / tự bôi đen rồi replace"). One verify probe per
    // focus; a failure demotes to marked text for THIS focus only (the global
    // per-app classification is untouched). Both reset on activateServer and on
    // the click/⌘-combo reset notification — the focus anchors we actually get
    // from Chromium, which reports the whole window as one IMK client.
    private var fieldVerified = false
    private var fieldForcedMarked = false
    /// Last shadow probe (seconds, reference date) — see `shadowProbeInterval`.
    private var lastShadowProbe: TimeInterval = 0
    private static let shadowProbeInterval: TimeInterval = 1.0

    private var fieldVerifyStrikes = 0
    /// Probes whose self-report was IMPOSSIBLE (caret before our anchor) in this focus.
    /// They teach nothing, but a field that only ever produces them must still land in a
    /// mode that renders, so they are bounded (see the `.inconclusive` branch).
    private var fieldInconclusive = 0
    private static let maxInconclusive = 4

    /// Effective marked-text decision for the CURRENT field: a per-focus demotion
    /// (verify probe failed here) wins over the per-app classification, and so does
    /// a canvas-editor field verdict (Google Docs — its hidden input self-reports a
    /// consistent caret, so the verify probe never fires there while the canvas
    /// renders appended garbage; field report 2026-07-30 "Quoocs" → "Quoôcốc").
    /// Gated on usesAxDetect so a browser field verdict can never leak into other apps.
    /// Panel web view trong Excel/Word/PowerPoint (M365 Copilot — issue #141) cũng ép
    /// marked: rule per-app của lưới/thân văn bản không áp vào editor web (xem
    /// AppState.officeWebPanelHosts).
    private func usesMarkedNow(_ id: String?) -> Bool {
        fieldForcedMarked || AppState.shared.usesMarkedText(id)
            || (AppState.shared.usesAxDetect(id) && FocusedFieldDetector.wantsMarkedField)
            || AppState.shared.isOfficeWebPanel(id)
    }

    #if DEBUG
    /// `handle()` resolves this ONCE per key and reuses it — a test pins that the
    /// decision is a pure read of state (no side effect that a second call would see).
    func _testUsesMarkedNow(_ id: String?) -> Bool { usesMarkedNow(id) }
    #endif

    /// Hoãn bao nhiêu ms trước khi re-post phím boundary (Enter/Tab/Esc), hay post
    /// ngay (nil). Chỉ hoãn cho web editor ở lớp marked: commit của chúng áp vào
    /// model JS bất đồng bộ nên Enter đồng bộ "gửi" trước khi từ cuối vào DOM (field
    /// 19/08: "thử xem"+Enter → TikTok post ra mỗi "thử"). 60ms: dư cho một vòng
    /// render của React/Lexical, vẫn dưới ngưỡng người dùng cảm nhận được độ trễ khi
    /// bấm gửi. Native app KHÔNG hoãn — insertText ở đó đã đồng bộ.
    static func boundaryRepostDelayMs(markedWebField: Bool) -> Int? {
        markedWebField ? 60 : nil
    }

    struct MarkedBoundaryHandling: Equatable {
        let commitSuffix: String
        let swallowPhysicalKey: Bool
    }

    /// Resolve the degraded no-Accessibility boundary behavior before committing.
    /// Send-on-Enter hosts must receive plain Return so their editor can choose
    /// between send and newline; only Shift+Enter is folded into the marked commit.
    /// Native multiline fields keep the one-press newline fallback, and terminals
    /// continue swallowing boundary keys because they discard control text.
    static func forwardPlainReturn(bundleID: String?, untrustedChromiumPage: Bool) -> Bool {
        untrustedChromiumPage || bundleID == "com.openai.codex"
    }

    static func markedBoundaryHandling(newlineKey: Bool, shifted: Bool, marked: Bool,
                                       trusted: Bool, forwardPlainReturn: Bool)
        -> MarkedBoundaryHandling {
        guard marked && !trusted else {
            return MarkedBoundaryHandling(commitSuffix: "", swallowPhysicalKey: false)
        }
        guard newlineKey else {
            return MarkedBoundaryHandling(commitSuffix: "", swallowPhysicalKey: true)
        }
        if forwardPlainReturn && !shifted {
            return MarkedBoundaryHandling(commitSuffix: "", swallowPhysicalKey: false)
        }
        return MarkedBoundaryHandling(commitSuffix: "\n", swallowPhysicalKey: true)
    }

    /// SPLIT-BRAIN → marked (lớp bug issue #55). Fire khi: client id routes họ tap,
    /// KHÁC app với frontmost, mà routing theo frontmost (góc nhìn của TAP — tap
    /// quyết mỗi phím bằng FrontmostApp) lại KHÔNG thuộc họ tap → tap sẽ pass và
    /// tap-defer của IMK thành chữ thô. `frontDefersToTap` là @autoclosure vì đó là
    /// cả một lần giải routing — chỉ được trả khi các điều kiện rẻ phía trước đã lọc
    /// (đường thường: sameApp=true, thoát ngay). KHÔNG kéo tap vào thay vì marked:
    /// tap thấy phím TRƯỚC IMK nên không thể biết IMK sắp nhường, còn cho tap route
    /// theo client id là dựa vào thứ tự activate/deactivate vốn flaky (client thiu
    /// → backspace-retype bắn nhầm vào app in-place, tệ hơn chữ thô).
    static func splitBrainToMarked(clientDefersToTap: Bool, sameApp: Bool,
                                   spotlightDefer: Bool, alreadyMarked: Bool,
                                   frontDefersToTap: @autoclosure () -> Bool) -> Bool {
        guard clientDefersToTap, !sameApp, !spotlightDefer, !alreadyMarked else { return false }
        return !frontDefersToTap()
    }

    // MARK: - Event handling (hot path)

    /// Also receive flagsChanged (default is keyDown only): the composition is
    /// committed the moment a ⌘/⌃/⌥ MODIFIER is pressed — see handle() below.
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.union(.flagsChanged).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event else { return false }
        guard event.type == .keyDown, let client = sender as? IMKTextInput else {
            return handleKey(event, client: sender)
        }

        // #161: dead key (' " trên U.S. International – PC, ´ ¨ trên layout Đức/Pháp)
        // tới với characters rỗng — ghi lại để effectiveCharacters gõ ra ký tự của chính
        // phím đó và đọc phím kế như phím thường. Dead key kèm ⌘⌃⌥ không tính (⌥e có
        // đường riêng, xem optionDeadState). Tính TRƯỚC mọi nhánh (cả stall breaker) để
        // lastKeyWasDead luôn đúng cho phím kế.
        // Spotlight (com.apple.campo) không đưa dead key tới dưới dạng characters rỗng ⇒
        // hỏi chính layout (bảng cache, chỉ cho phím không phải chữ/số).
        keyFollowsDeadKey = lastKeyWasDead
        let plainKey = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let mayBeDead = plainKey && DeadKeyLiteral.mayBeDeadKey(event.characters)
        if mayBeDead { KeyboardLayoutOverride.ensureLiveTable() }   // một lần đọc bool sau lần đầu
        keyIsLayoutDead = mayBeDead
            && KeyboardLayoutOverride.liveIsDeadKey(keyCode: event.keyCode,
                                                    shift: event.modifierFlags.contains(.shift),
                                                    capsLock: event.modifierFlags.contains(.capsLock))
        lastKeyWasDead = plainKey && (DeadKeyLiteral.isDeadKeyEvent(event.characters) || keyIsLayoutDead)
        deadRescueKeepRaw = false
        let handled = handleKey(event, client: sender)
        // Phím thường: một phép thử bool, không gì thêm.
        guard lastKeyWasDead else { return handled }
        logDecision("dead key: client=\(AppState.shared.currentBundleID ?? "nil") keyCode=\(event.keyCode) "
            + "chars=\((event.characters ?? "nil").unicodeScalars.map { String(format: "U+%04X", $0.value) }) "
            + "layoutDead=\(keyIsLayoutDead) live=\(KeyboardLayoutOverride.liveTable?.layoutID ?? "nil") "
            + "handled=\(handled) keepRaw=\(deadRescueKeepRaw)")
        // BẤT BIẾN dead key (DeadKeyLiteral.rescue): nhánh nào cũng vậy (ô mật khẩu,
        // tap-defer khi tap chết, app Tắt, stall, machine typing…) — dead key nhường cho
        // app là MẤT, nên chèn đúng một ký tự ở đây và nuốt phím.
        guard let text = DeadKeyLiteral.rescue(
            handled: handled, deadKey: true, keepRaw: deadRescueKeepRaw,
            tapOwned: event.cgEvent.map {
                DeadKeyHandoff.consumeTapOwned(keyCode: event.keyCode, timestamp: $0.timestamp)
            } ?? false,
            literal: { self.effectiveCharacters(event) })
        else { return handled }
        client.insertText(text, replacementRange: kNoRange)
        logDecision("dead key rescue → inserted \(text.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
        return true
    }

    private func handleKey(_ event: NSEvent, client sender: Any!) -> Bool {
        // Stall breaker (#118): handle() runs on MAIN, the one queue every app's keys
        // share, and calls back into the client over synchronous XPC that has no
        // timeout we can set. A client that made recent keys stall is passthrough for
        // a cooldown — return false at once, never touch it — so its slowness cannot
        // queue every other app's keys behind it. Otherwise: time this key.
        let stallID = AppState.shared.currentBundleID ?? FrontmostApp.shared.bundleID
        if ClientStallBreaker.shared.isDegraded(stallID) {
            if !engine.isEmpty { dropComposition(cause: "client-stall") }
            optionDeadState = 0
            if lastKeyWasDead { deadRescueKeepRaw = SyntheticKeyboard.isSyntheticMagic(event) }
            return false
        }
        let stallT0 = DispatchTime.now().uptimeNanoseconds
        defer { ClientStallBreaker.shared.noteKeyHandled(stallID, path: .imk, startNs: stallT0) }

        // A ⌘/⌃/⌥ modifier just went DOWN: end any composition NOW, one event cycle
        // BEFORE the shortcut's letter arrives. Committing inside the same cycle as
        // the combo (the old approach) lost the first press — the app swallows a key
        // equivalent delivered while its IME session is open/closing (⌘A while
        // composing did nothing; after the fix for that, the FIRST ⌘A/⌥⌫ still
        // needed a second press). The modifier physically precedes the letter by
        // ~50-100ms, so by the time ⌘A is delivered the session has long been torn
        // down and the app handles it immediately. Side effect (accepted): tapping a
        // lone modifier mid-word finalizes the word.
        if event.type == .flagsChanged {
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               !engine.isEmpty, let client = sender as? IMKTextInput {
                logDecision("modifier down mid-composition → early commit")
                endComposition(client)
            }
            return false
        }

        guard event.type == .keyDown,
              let client = sender as? IMKTextInput else { return false }

        // Issue #156 (TapWordBreak): client vừa activate đã nhận phím ⇒ một
        // activateServer tới SAU phím đầu của ô mới (#110) không được làm tap bỏ từ.
        // Không lọc burst synthetic của mình: giữa activateServer và phím vật lý đầu
        // tiên ở ô mới tap không phát gì, và lọc tốn một bản sao CGEvent mỗi phím.
        ClientFocus.noteClientKey()

        // Phím thật tới khi bản re-post Return/Tab của mình chưa quay lại = app đã xếp nó
        // TRƯỚC Return ⇒ nuốt, post lại sau bản sao (RepostOrder). Trước MỌI xử lý khác:
        // phím này chưa được phép đụng tới văn bản / trạng thái (gợi ý, dấu cách vừa nhận…).
        var repostedUserKey = false
        if !repostOrder.isEmpty {
            let magic = SyntheticKeyboard.isSyntheticMagic(event)
            switch repostOrder.classify(keyCode: event.keyCode, synthetic: magic,
                                        nowNs: DispatchTime.now().uptimeNanoseconds) {
            case .overtook:
                if holdBehindRepost(event) { return true }
            case .userKeyEcho:
                repostedUserKey = magic      // bản sao nguồn riêng còn magic: vẫn là phím của user
            case .boundaryEcho, .normal:
                break
            }
        }

        // Bảng Công cụ đang mở mà phím vẫn tới IME ⇒ user gõ tiếp: đóng (một lần đọc
        // static khi không có panel).
        if TextToolsPanel.current != nil {
            TextToolsPanel.noteIMEKeyDown(keyCode: Int(event.keyCode), shift: event.modifierFlags.contains(.shift))
        }

        // Gợi ý cạnh con trỏ (CaretHint — MathHint.swift): kết quả phép tính "= 36" / chip
        // số "1.200.000 ₫" đang hiện (ô ứng viên hệ thống hoặc ô nổi) ⇒ Tab (phép tính:
        // cả Enter) áp dụng, Esc tắt + nuốt, phím khác tắt rồi xử lý như thường. Không hiện
        // gì thì chỉ là một lần đọc cờ dưới khoá.
        if let act = CaretHint.shared.keyAction(
            keyCode: Int(event.keyCode),
            plain: event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty) {
            switch act {
            case .accept:
                if let s = CaretHint.shared.take() {
                    applyCaretSuggestion(s, client)
                    return true
                }
            case .dismissConsume:
                CaretHint.shared.decline()
                return true
            case .dismissPass:
                CaretHint.shared.dismiss()
            }
        }
        // Dấu cách mình chèn khi nhận gợi ý từ: phím ngay sau quyết định số phận nó.
        if acceptedSpace != nil || carriedSpace != nil, let r = handleAcceptedSpace(event, client) { return r }
        // Vừa chèn NGUYÊN VĂN đuôi email: phím ngay sau không re-edit chữ đó ("com" + s ≠ "cóm").
        let afterRawInsert = rawInsertedTail
        rawInsertedTail = false
        let mathTrigger = CaretHint.shared.mathEnabled
            && MathHintLogic.isTrigger(characters: event.characters, modifiers: event.modifierFlags)
        defer { if mathTrigger { CaretHint.shared.afterEquals(client: client, controller: self) } }

        // Signpost the whole IMKit round trip; the end message names the strategy
        // that actually handled this key (see Instrumentation.swift).
        var spMode = "passthrough"
        let spState = Signposts.poster.beginInterval("imk.handle",
                                                     id: Signposts.poster.makeSignpostID())
        // privacy: .public — os_signpost redacts interpolated strings to "<private>"
        // by default, which collapses the per-strategy breakdown in xctrace exports.
        // The label is an internal strategy name, never user text.
        defer { Signposts.poster.endInterval("imk.handle", spState, "\(spMode, privacy: .public)") }

        // Our own terminal tap-mode output (synthetic Backspace / Unicode) loops back
        // through the input system. Pass it straight to the app WITHOUT re-feeding the
        // engine (a synthetic Backspace would otherwise re-enter as kDelete).
        // Confirm handle() is reached BEFORE the synthetic guard, and record whether
        // this real key is being mistaken for one of ours (isSynthetic) and why
        // (source pid vs our pid). Deduped per app so it's one line, not per-key.
        // Recognize OUR output by the magic userData only — NOT the posting pid.
        // Chromium/Electron (Slack, Lark) hand real keys to the IME stamped with our
        // pid, which the pid check dropped as synthetic (untypable Vietnamese).
        let synth = SyntheticKeyboard.isSyntheticMagic(event)
        let entryID = AppState.shared.currentBundleID ?? FrontmostApp.shared.bundleID ?? "?"
        if entryID != lastEntryLog || AppState.shared.debugLogging {   // no dedupe while debugging
            lastEntryLog = entryID
            let cg = event.cgEvent
            let srcPid = cg?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
            let ud = cg?.getIntegerValueField(.eventSourceUserData) ?? -1
            DebugLog.log("handle ENTER app=\(entryID) synthetic=\(synth) magic=\(ud == SyntheticKeyboard.magic) "
                + "srcPid=\(srcPid) myPid=\(getpid())")
        }

        if synth, !repostedUserKey {
            deadRescueKeepRaw = true   // our own output — never "rescue" it
            // An edge-burst echo that arrived with its magic INTACT (older macOS)
            // must still spend its slot, or the budget wedges and eats a real key.
            if event.keyCode == kDelete, edgeEchoBackspaces > 0 { edgeEchoBackspaces -= 1 }
            else if let chars = event.characters, chars == edgeEchoChunks.first { edgeEchoChunks.removeFirst() }
            return false
        }

        // Echo of an edge-tap burst (see edgeEchoBackspaces/Chunks): pass it to
        // the app untouched — the engine already holds the post-replace state.
        // Content match, not count: a real key mid-drain (physical 'r' between
        // our ⌫ and "ư") matches neither and composes normally. Self-heals like
        // queueDrained: a lost echo must not linger, so a stale budget (>1s
        // since the burst) is discarded.
        if edgeEchoBackspaces > 0 || !edgeEchoChunks.isEmpty {
            if DispatchTime.now().uptimeNanoseconds &- edgeEchoStampNs > 1_000_000_000 {
                edgeEchoBackspaces = 0
                edgeEchoChunks = []
            } else if event.keyCode == kDelete, edgeEchoBackspaces > 0 {
                edgeEchoBackspaces -= 1
                logDecision("edge-echo ⌫ swallowed, bs left=\(edgeEchoBackspaces)")
                return false
            } else if let chars = event.characters, chars == edgeEchoChunks.first {
                deadRescueKeepRaw = true
                edgeEchoChunks.removeFirst()
                logDecision("edge-echo chunk swallowed, chunks left=\(edgeEchoChunks.count)")
                return false
            }
        }

        // Machine typing (#118): a burst faster than any human (agent / text expander /
        // barcode scanner) passes through VERBATIM — composing it mangles the text the
        // sender chose, and an agent that re-reads and retypes turns that into an
        // endless stream of synchronous IMK round trips on MAIN. Our own echoes were
        // filtered above, so only foreign keys reach the detector.
        let machine = machineTyping.observe(
            eventNs: event.timestamp > 0 ? UInt64(event.timestamp * 1_000_000_000) : 0,
            arrivalNs: DispatchTime.now().uptimeNanoseconds,
            isRepeat: event.isARepeat)
        if machine.machine, AppState.shared.tapCascadeBreaker {
            if machine.began {
                MachineTypingLog.noteBurst(entryID, path: "imk")
                DebugLog.log("machine typing: \(entryID) — burst faster than human, keys pass verbatim")
                Signposts.log.notice("machine typing: \(entryID, privacy: .public) — passthrough")
                // Once per burst: a MARKED composition must be committed, or the
                // passed-through key would replace the still-marked word.
                endComposition(client)
            }
            discardComposition()
            spMode = "machine"
            return false
        }

        // Word-table class (maintainer repro 23/08/2026): the tap witnessed a
        // Tab/arrow that this client swallowed — handle() never saw it, so the word
        // this key would continue was in fact ended in another cell/position. Drop
        // BEFORE processing, so this key starts a fresh word anchored at the REAL
        // caret. Same recovery as the mouse-click .telexResetComposition path,
        // which is exactly why clicking into the next cell already worked.
        // Gõ tắt hoàn tác: chỉ ⌫ NGAY SAU lần nở mới được dùng — mọi phím thật tới đây
        // (sau khi đã lọc echo của chính mình ở trên) đều tiêu thụ nó.
        let pendingShortcutUndo = shortcutUndo
        shortcutUndo = nil
        let pendingRetroUndo = retroUndo
        retroUndo = nil
        let prevSpaceNs = periodSpaceNs
        let prevEmDashOurs = lastEmDashOurs
        periodSpaceNs = 0; lastEmDashOurs = false

        if NavKeyWitness.consume(keycode: Int64(event.keyCode)) {
            logDecision("nav key swallowed by app → composition dropped before this key")
            dropComposition(cause: "nav-key-swallowed")
            shortcutTail.reset()
            onLen = 0
        }

        // A real key reaching handle() proves VietTelex is the selected source —
        // un-latch a stale imeActive=false so tap-mode apps aren't left dormant
        // (see noteIMKKeyProvesSelected).
        TerminalTapController.shared.noteIMKKeyProvesSelected()

        // Secure input active (password field, or an app holding secure input like
        // some chat apps): DROP the pending composition without rewriting it, then
        // pass through untouched. We must NOT call boundary() here: boundary runs
        // shortcut expansion / auto-restore via applyInPlace, i.e. an insertText into
        // the CURRENT client — now a password field — using a stale anchor from the
        // previous field, which would leak the old word into the secure input. A plain
        // engine drop is the only safe teardown. (endComposition is also wrong: its
        // marked-text branch finalizes with insertText(engine.composed), the very
        // injection we must avoid in a secure field.)
        // A password field is off limits for composition. `IsSecureEventInputEnabled()`
        // catches native secure input; SecureFieldDetector catches the web
        // `<input type="password">` case, which does NOT switch secure input on and was
        // therefore composed into normally (field report 2026-07-27).
        if SecureFieldDetector.isSecure {
            engine.reset(); tracking = false; onLen = 0; shortcutTail.reset()
            logDecision("handle \(AppState.shared.currentBundleID ?? "?"): secure FIELD → passthrough (no compose)")
            return false
        }
        if IsSecureEventInputEnabled() {
            logDecision("handle \(AppState.shared.currentBundleID ?? "?"): secure-input → discard (raw passthrough)")
            discardComposition(); return false
        }

        // Passthrough resolution. Manual .passthrough = unconditional IME-off for the
        // app. Remote-desktop / VM / screen-share apps (built-in list) forward raw
        // scancodes for the SESSION canvas — but their OWN chrome (PC-name field,
        // search box) is ordinary text input, so with Accessibility we compose there:
        // only when the focused element's AX role is a real text input; unsure →
        // passthrough (composing into the canvas would type garbage into the guest
        // OS, while the reverse merely loses Vietnamese in a name field).
        // Same as the secure-input branch: drop, never boundary()/rewrite — the
        // anchor belongs to the previous field, and this window forwards raw keys.
        let earlyID = AppState.shared.currentBundleID
        let earlyManual = AppState.shared.manualMode(earlyID)
        if earlyManual == .passthrough {
            logDecision("handle \(earlyID ?? "?"): manual passthrough → discard (raw)")
            optionDeadState = 0
            if lastKeyWasDead { deadRescueKeepRaw = Self.deadKeyStaysRaw(earlyID) }
            discardComposition(); return false
        }
        if earlyManual == nil,
           ClientPolicy.isRemoteDesktop(earlyID)
               || earlyID.map({ AppState.isBuiltInPassthrough($0) }) == true,
           !(Accessibility.isTrusted && FocusedFieldDetector.isTextInput) {
            logDecision("handle \(earlyID ?? "?"): remote-desktop → discard (raw passthrough)")
            optionDeadState = 0
            if lastKeyWasDead { deadRescueKeepRaw = Self.deadKeyStaysRaw(earlyID) }
            discardComposition(); return false
        }

        // ⌥ dead key (⌥e ⌥u ⌥i ⌥n ⌥` trên ABC) đang chờ: phím này hoàn tất nó (é ü î ñ è).
        // Không chờ ⇒ một phép so UInt32.
        if optionDeadState != 0, let r = finishOptionDead(event, client) { return r }

        // EXPERIMENT (log-only): deferred re-probe of the previous keystroke's edit,
        // now that the app's AX tree has had time to settle. See `pendingReprobe`.
        if let p = pendingReprobe {
            pendingReprobe = nil
            reprobeDeferred(p, client)
        }

        // Modifier combos (⌘⌃⌥) are never Telex input: finish and pass through.
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty {
            // Modifier+Delete while a MARKED composition is open: committing and
            // passing the key loses the FIRST press — the just-closing composition
            // session swallows it (Terminal: "goo" → gô, Option+Delete needed two
            // presses to kill the word). The word those shortcuts delete backward IS
            // the composition, so consume the key and kill the composition directly:
            // same net effect, single press. In-place mode has no composition session
            // (text is already real), so it keeps the normal commit-and-pass path.
            if event.keyCode == kDelete, !engine.isEmpty,
               usesMarkedNow(AppState.shared.currentBundleID) {
                client.setMarkedText("", selectionRange: kNoRange, replacementRange: kNoRange)
                engine.reset()
                tracking = false
                spMode = "marked"
                logDecision("marked composition killed by modifier+Delete (single press)")
                shortcutTail.reset()
                return true
            }
            endComposition(client)
            learn.discard()   // Học từ bạn gõ: ⌘/⌃/⌥-tổ hợp có thể hoàn tác/xoá chữ (⌘Z) — bỏ lượt chờ
            // ⌥ dead key: phần ghép dead key của layout không chạy khi VietTelex là nguồn
            // nhập (cùng cơ chế #161) ⇒ ⌥e rồi e không ra é. Tự giữ trạng thái dead key
            // của layout và ghép ở phím kế (finishOptionDead). Chỉ tổ hợp ⌥ (±Shift).
            if mods == .option { KeyboardLayoutOverride.ensureLiveTable() }
            if mods == .option,
               let state = Self.optionDeadStart(
                   table: KeyboardLayoutOverride.liveTable, keyCode: event.keyCode,
                   shift: event.modifierFlags.contains(.shift),
                   capsLock: event.modifierFlags.contains(.capsLock)) {
                optionDeadState = state
                shortcutTail.reset()
                logDecision("option dead key keyCode=\(event.keyCode) → pending")
                return true
            }
            // ⌥+phím gõ ra KÝ TỰ ("√", "≠" — khoá gõ tắt như "√√") vẫn là chữ nằm trước
            // con trỏ; mọi tổ hợp khác (⌘/⌃, ⌥⌫, ⌥←) dời/xoá chữ ⇒ cụm không còn biết.
            if mods == .option, event.keyCode != kDelete,
               let s = ShortcutScreen.insertedText(event.characters) {
                shortcutTail.append(s)
            } else {
                shortcutTail.reset()
            }
            return false
        }

        // No internal enable/disable: if VietTelex is the active input source we always
        // compose. To type English, switch macOS input source (the OS remembers it
        // per app when "automatically switch" is on).

        // Decide tap-defer by the ACTUAL frontmost app — the SAME source the tap uses
        // (FrontmostApp cache) — not the IMK client id, which can be nil/stale. If the
        // client id is nil we'd otherwise think "unknown app → in-place" and wrongly
        // compose into a terminal the tap is handling; when the tap then leaks a
        // physical key (a brief tapDisabled window), IMKit composes it → intermittent
        // garbage in iTerm/Claude Code. Using the frontmost app keeps controller and
        // tap in sync.
        let frontID = FrontmostApp.shared.bundleID
        let id = AppState.shared.currentBundleID ?? frontID

        // Apps the CGEvent tap handles (terminals via Backspace, Chromium browsers &
        // Spotlight via Shift+Left selection-replace): the tap already intercepted and
        // synthesized these before the IME, so never compose here — let anything that
        // slipped through insert natively.
        // Spotlight types IN-PLACE by default (field-verified clean on macOS 26,
        // even with the gray inline suggestion — the historical autocomplete race
        // that forced tap selection-replace is gone; it's in builtInInPlaceApps).
        // Only an explicit tap-family manual pick still routes it to the tap.
        // ORDER MATTERS for CPU: consult the manual pin FIRST — isVisible kicks a
        // CGWindowList background scan every 200ms while typing, which nobody needs
        // unless Spotlight was explicitly pinned to a tap-family mode (rare).
        let spotlightManual = AppState.shared.spotlightManualMode()
        let spotlightDefersToTap = (spotlightManual == .selection
                || spotlightManual == .tap || spotlightManual == .emptyReset)
            && SpotlightDetector.isVisible
        // ONE lock + one trusted read + (at most) one detector read for the whole
        // decision — this used to be 6 separate calls, each re-locking AppState and
        // several re-reading Accessibility.isTrusted.
        let routing = AppState.shared.tapRouting(id, front: frontID)
        // Browser-hosted remote desktop (Chrome Remote Desktop in Chrome/Safari/Edge):
        // AFTER tapRouting so the field scan is kicked (wantsSelection). Checking
        // before that would return early forever on a stale CRD verdict — switching
        // to Gmail in the same Chrome window never calls activateServer, so the
        // cache would never refresh. Not gated on isTextInput: a hidden IME
        // <textarea> on the CRD canvas would look like a real field and re-enable
        // the local/guest fight.
        if (AppState.shared.usesAxDetect(id) || AppState.shared.usesAxDetect(frontID)),
           FocusedFieldDetector.wantsPassthroughField {
            deadRescueKeepRaw = true   // web remote desktop: the guest composes from the keycode
            logDecision("handle \(id ?? "?")/front=\(frontID ?? "?"): web remote-desktop → discard (raw passthrough)")
            discardComposition(); return false
        }
        // SPLIT-BRAIN GUARD (lớp bug issue #55): client id routes về họ tap (thường
        // là XPC service lạ rơi vào safe-unknown) nhưng TAP thì quyết theo FRONTMOST
        // — nếu frontmost không thuộc họ tap, tap sẽ pass nguyên phím: IMK nhường,
        // tap cũng nhường, chữ ra THÔ. Phát hiện tại đúng phím này (client id là bên
        // vừa đưa event — không thể thiu; frontmost đọc từ cache đáng tin) và rơi về
        // MARKED cho focus hiện tại: đúng chữ tuyệt đối, chỉ có gạch chân — đúng
        // tinh thần safe-unknown khi kênh tap không với tới. Ca nào field-verify
        // in-place tốt thì thêm rule vào typing-modes.yml như documentPopoverViewService.
        // Không đụng Spotlight (defer vô điều kiện là CHỦ ĐÍCH — đọc NOTE dưới).
        if Self.splitBrainToMarked(clientDefersToTap: routing.tapDefer,
                                   sameApp: id == frontID,
                                   spotlightDefer: spotlightDefersToTap,
                                   alreadyMarked: fieldForcedMarked,
                                   frontDefersToTap: AppState.shared.tapRouting(frontID).tapDefer) {
            fieldForcedMarked = true
            logDecision("split-brain: client \(id ?? "?") routes tap, front \(frontID ?? "?") won't engage → marked for this focus")
            Signposts.log.notice("split-brain → marked: client=\(id ?? "?", privacy: .public) front=\(frontID ?? "?", privacy: .public)")
        }
        // Accessibility off on a Chromium page: do not in-place (the editor drops
        // it and the user sees raw ASCII). Marked underline still composes.
        // Spotlight stays raw — see the note on the defer below.
        if routing.untrustedMarked, !spotlightDefersToTap, !fieldForcedMarked {
            fieldForcedMarked = true
            logDecision("untrusted chromium → marked (in-place would drop tones)")
        }
        if (routing.tapDefer && !fieldForcedMarked) || spotlightDefersToTap {
            // NOTE: SpotlightDetector.isVisible defers UNCONDITIONALLY, even when the
            // tap is dormant (Accessibility not trusted / sandboxed build). That means
            // Spotlight typing gets raw passthrough with NO composition at all. This is
            // INTENTIONAL, not a bug: IMKit composing into Spotlight's inline
            // autocomplete corrupts the text, so raw passthrough is the lesser evil.
            // Do not "fix" this by gating on Accessibility.isTrusted.
            spMode = "tap-defer"
            shortcutTail.reset()   // tap (hoặc không ai) xử lý phím này — mình không thấy chữ
            // tapAlive/quar/tripped: a tap-defer while the tap is dead is the "raw
            // ASCII, status OK" failure — without these three fields the log cannot
            // distinguish "tap composed this key" from "nobody did" (2026-07-30).
            // Only evaluated when debugLogging is on (autoclosure).
            logDecision("handle \(id ?? "?")/front=\(frontID ?? "?"): tap-defer "
                + "(tap=\(routing.tap) sel=\(routing.selection) empty=\(routing.emptyReset) "
                + "spotlight=\(SpotlightDetector.isVisible) "
                + "tapAlive=\(TerminalTapController.shared.isRunning) "
                + "quar=\(TerminalTapController.shared.isQuarantined) "
                + "tripped=\(SyntheticKeyboard.tripped))")
            return false
        }
        logDecision("handle \(id ?? "?")/front=\(frontID ?? "?"): "
            + "\(usesMarkedNow(id) ? "marked" : "in-place") "
            + "needsProbe=\(AppState.shared.needsProbe(id))")
        // Only resolve the label when something is actually recording. `usesMarkedNow`
        // is NOT cheap — it re-runs the whole per-app + per-field policy (≈50 set
        // ONE resolution of the marked decision for this key, reused by every branch
        // below. `usesMarkedNow` is NOT cheap — it re-runs the whole per-app + per-field
        // policy (≈50 set lookups + several lock trips), and it used to be called 3–4
        // times per keystroke. Safe to reuse within one call: the only thing that flips
        // it mid-key is a verify demotion inside probeInPlace, and every path that can
        // reach probeInPlace (⌫, boundary keys, replace) RETURNS before the reuse sites.
        // Perf audit 17/08/2026.
        let markedNow = usesMarkedNow(id)
        spMode = markedNow ? "marked"
               : (tracking || engine.isEmpty ? "in-place" : "in-place-per-op")

        // Reflect the current "bỏ dấu tự do" setting before any engine op (feed,
        // backspace and boundary all re-parse `raw` and honor this flag).
        engine.apply(AppState.shared.engineFlags())

        switch event.keyCode {
        case kDelete:
            wordGluedToDigit = false
            if engine.isEmpty {
                // ⌫ ngay sau khi nở gõ tắt: trả lại đúng chữ đã gõ + ranh giới — chỉ
                // khi màn hình khớp y hệt (đọc lại), ngược lại ⌫ thường.
                if let u = pendingShortcutUndo, !markedNow, tryUndoShortcut(u, client) {
                    spMode = "shortcut-undo"
                    return true
                }
                // ⌫ ngay sau "Tự sửa từ phía trước": trả lại văn bản cũ (verify màn hình).
                if let u = pendingRetroUndo, !markedNow, tryRetroUndo(u, client) {
                    spMode = "retro-undo"
                    return true
                }
                shortcutTail.backspace()
                // Học từ bạn gõ: ⌫ vào chữ đã chốt ⇒ từ chờ học có thể đang bị sửa — bỏ.
                learn.discard()
                // ⌫ on the boundary character the last word ended with puts the caret
                // back at that word's end, and the user is going to keep editing it
                // ("tháy" ␣ ⌫ then `a` → "thấy" — issue #40). Re-open it into the buffer
                // so the next key modifies the word instead of starting a new one.
                if tryReopenLastCommit(client, id: id) { return false }
                // Backspacing with an empty buffer deletes previously-committed text: the
                // "previous word" relationship is now unclear, so drop the English context
                // (undetermined → Vietnamese). In-word backspace (buffer non-empty) keeps it —
                // the preceding word hasn't changed.
                engine.resetContext()
                return false
            }
            // Our tracked window must still MATCH the field before we rewrite it. A
            // ⌫-rewrite is `insertText(composed, range(anchor, onLen))`: if the app has
            // meanwhile moved the caret, re-rendered (React-controlled inputs do), or
            // holds a SELECTION (inline autocomplete suffix), that range covers text we
            // never composed — the rewrite then eats an extra character, and every later
            // insert targets a range that no longer exists, so nothing shows up until a
            // space re-anchors the word. Tester report 2026-07-27 (Chrome Web Store search
            // box: "lần đầu xóa liền 2 ký tự, sau đó gõ không hiện gì nữa"). On any
            // disagreement, hand the key to the app and forget the composition: the user
            // loses a diacritic re-placement on that ⌫, never text.
            //
            // IN-PLACE ONLY (issue #37, 2026-08-13): this window arithmetic guards the
            // insertText(range) rewrite that marked mode never performs — a marked ⌫
            // goes engine.backspace() → setMarkedText, correct by the composition
            // session itself. `tracking` is still set at word-start in marked mode
            // while `onLen` never advances there, so `expected` stayed at the anchor
            // and Safari+Google-Docs (caret reported at the marked text's END) tripped
            // the guard on the FIRST mid-word ⌫: composition dropped, the underlined
            // text orphaned on screen, every later ⌫/space dead until a click —
            // reporter's "không thể xoá cũng như bấm space để thoát khỏi từ".
            if tracking, Self.backspaceFreshnessGuardApplies(marked: markedNow) {
                let expected = anchor + onLen
                // Async-apply client (WhatsApp): the ⌫-rewrite below is range-targeted,
                // and while our previous edits are still pending there it gets
                // APPENDED — the "letters jumped" after delete in the 03/11 report.
                // The Chromium lag tolerance in trackedWindowIsFresh is exactly the
                // window where that happens, so wait for the app first; if it never
                // catches up, the ⌫ goes native (ordered in the app's own queue).
                let caughtUp = awaitAsyncClient(client, expected: expected, why: "backspace")
                let sel = client.selectedRange()
                if !caughtUp || !Self.trackedWindowIsFresh(caret: sel.location == NSNotFound ? nil : sel.location,
                                              selectionLength: sel.length, expected: expected) {
                    // host: DIAGNOSTIC ONLY (FocusedFieldDetector.debugLastHost, never
                    // routing) — names the site for a future report on a lag this deep
                    // (field report 2026-08-06: caret behind by 6, past the Discord-class
                    // tolerance, on an unidentified Chrome tab).
                    DebugLog.log("backspace: tracked window stale "
                        + "(caret=\(sel.location == NSNotFound ? "NotFound" : String(sel.location))"
                        + " len=\(sel.length) expected=\(expected) host=\(FocusedFieldDetector.debugLastHost ?? "?")) "
                        + "→ pass through, drop composition")
                    dropComposition(cause: "backspace-window-stale")
                    onLen = 0
                    return false
                }
            }
            let action = engine.backspace()
            // ⌫ xoá đúng chữ hoa tự động ⇒ user từ chối: chữ đầu kế tiếp giữ nguyên.
            if autoCappedWord, engine.isEmpty { suppressAutoCap = true; autoCappedWord = false }
            // OVERFLOW (word longer than the engine's 32-char capacity): backspace()
            // returns .passthrough and the app must delete natively — the engine's view
            // is a stale 32-char prefix of what is on screen. Must be decided BEFORE
            // either the marked or the tracking branch: marked would re-set the same
            // prefix and swallow the key; the tracking rewrite would wipe every
            // overflow character on the first ⌫ and then rewrite identical text
            // forever (⌫ dead for the rest of the word).
            switch Self.passthroughPlan(overflowPassthrough: Self.isPassthrough(action) && engine.isOverflowed,
                                        marked: markedNow, isBackspace: true) {
            case .commitAndPassThrough:
                endComposition(client)
                return false
            case .shrinkWindowAndPassThrough:
                onLen = max(0, onLen - 1)
                return false
            case .honorEngineAction:
                break
            }
            if markedNow { updateMarked(client); return true }
            if edgeTapWord {
                // Edge word stays on the CGEvent channel: plain deletion passes the
                // physical ⌫ through; a tone re-place ("toán"->"tóa") goes synthetic.
                switch action {
                case let .replace(_, insert) where insert.isEmpty:
                    onLen = max(0, onLen - 1)
                    if engine.isEmpty { tracking = false; edgeTapWord = false }
                    return false
                case let .replace(bs, insert):
                    noteEdgeBurst(SyntheticKeyboard.applyForEdge(backspaces: bs, insert: insert))
                    onLen = (engine.composed as NSString).length
                    return true
                default:
                    return true
                }
            }
            if tracking {
                // Rewrite the whole composition via insertText (ordered, non-empty);
                // also handles tone re-placement on delete ("toán"->"tóa").
                let composed = engine.composed
                if composed.isEmpty {
                    // Last glyph gone: physical Backspace removes the remaining char
                    // (insertText("", range) is a no-op in some apps).
                    onLen = 0; tracking = false
                    return false
                }
                client.insertText(composed, replacementRange: NSRange(location: anchor, length: onLen))
                onLen = (composed as NSString).length
                return true
            }
            // Non-tracking (per-op selectedRange): apply the diff action.
            switch action {
            case let .replace(_, insert) where insert.isEmpty:
                return false                       // physical Backspace
            case let .replace(bs, insert):
                applyInPlace(bs: bs, insert: insert, client)   // tone re-place: "toán"->"tóa"
                return true
            default:
                return true
            }

        case kReturn, kEnter, kTab, kEscape:
            // A newline starts a fresh line/prompt with no preceding word ("is" → "í"):
            // reset AFTER boundary() commits + classifies the current word. The defer
            // must live at CASE scope — nested inside `if { defer {...} }` its scope is
            // that if-block and it fires IMMEDIATELY, wiping the context BEFORE
            // boundary() decides the restore ("early too⏎" sent "early tô" while
            // "early too␣" restored fine — field report 15/08/2026, WhatsApp).
            let newlineKey = event.keyCode == kReturn || event.keyCode == kEnter
            defer { if newlineKey { engine.resetContext() } }
            // KNOWN LIMITATION — while a MARKED composition is open in a terminal,
            // the first boundary press only commits; the second acts ("vậy⏎⏎").
            // Tried and closed (2026-07-21): delivering the key's byte through
            // insertText after the commit — Terminal STRIPS control characters
            // (\r, \n, \t, ESC) from IME-inserted text (paste-bracketing-style
            // sanitizing; branch fired in logs, nothing reached the pty). This
            // two-press behavior is also standard CJK composition UX. Single-press
            // Enter in terminals is what the TAP path provides — grant Accessibility.
            boundaryCommitInFlight = true
            let wasEdge = edgeTapWord
            let trustedNow = Accessibility.isTrusted
            let forwardPlainReturn = Self.forwardPlainReturn(
                bundleID: id, untrustedChromiumPage: routing.untrustedMarked)
            let handling = Self.markedBoundaryHandling(
                newlineKey: newlineKey, shifted: event.modifierFlags.contains(.shift),
                marked: markedNow, trusted: trustedNow,
                forwardPlainReturn: forwardPlainReturn)
            // Gõ tắt: Return/Enter ("\n") và Tab ("\t") nở cả khoá chữ lẫn khoá ký hiệu;
            // Esc chỉ khoá chữ (hành vi cũ). Không hoàn tác qua các phím này.
            let trigger: String? = newlineKey ? "\n" : (event.keyCode == kTab ? "\t" : nil)
            let allow = ShortcutMatch.triggers(boundary: trigger, glued: wordGluedToDigit)
            let committedRun = shortcutTail.run
            let rewrote = boundary(client, allowShortcuts: allow.word, allowTokenShortcuts: allow.token,
                                   allowAlnumShortcuts: allow.alnum, commitSuffix: handling.commitSuffix)
            // Lật lại ("Đoán từ trùng theo tần suất": "His hửng" → "hí hửng") áp cả ở Enter/Tab,
            // TRƯỚC khi phím đi tiếp (tin chưa gửi) — cùng kênh + đọc lại như sửa ngược.
            // Sửa ngược tiếng Anh thì không (Enter không bao giờ sửa/đề xuất).
            if engine.pendingRetroCorrection?.flipBack == true {
                _ = applyRetroCorrection(marked: markedNow, edge: wasEdge, client, id: id)
            }
            boundaryCommitInFlight = false
            // Học từ bạn gõ: Enter/Tab/Esc chốt từ rồi cắt ngữ cảnh (lượt chờ được học).
            learnAtBoundary(word: lastCommitWord, boundary: nil,
                            standsAlone: committedRun.isEmpty, id: id, edge: wasEdge)
            wordGluedToDigit = false
            // Enter: dòng mới — cụm bắt đầu lại sau xuống dòng. Tab/Esc: có thể dời
            // focus / không chèn gì ⇒ cụm không còn biết.
            // appendReturn: "\n" chưa chắc có thật (Enter chọn mention / gửi tin) — viết
            // hoa đầu câu sẽ đọc lại màn hình thay vì tin nó.
            if newlineKey { shortcutTail.appendReturn() } else { shortcutTail.reset() }
            toneRun.reset()
            // Return/Tab/Esc do not put ONE character after the word the way a space
            // does — Enter sends the message in a chat app, Tab moves focus, Esc
            // inserts nothing — so a following ⌫ is not deleting a boundary character
            // and must not re-open the word (see tryReopenLastCommit).
            engine.forgetLastCommit()
            logDecision("boundary-key code=\(event.keyCode) rewrote=\(rewrote)")
            // When the commit REWROTE the word (gõ tắt "ko"→"không", auto-restore
            // "thooiiii"), web-view editors (WhatsApp) apply that insertText
            // asynchronously — an immediately-delivered Return fires "send" on the
            // OLD text. With Accessibility we swallow the real key and re-post a
            // stamped COPY of it (HID source intact) so it lands AFTER the edit;
            // the copy re-enters handle() with an empty engine and passes through.
            // EDGE (Slate-class): burst async vừa post — Return PHẢI được nuốt và
            // re-post sau burst; Slate không tự chèn newline cho phím bị nuốt nên
            // không double (Discord verified). Check TRƯỚC nhánh pin bên dưới.
            if rewrote, wasEdge, Accessibility.isTrusted, let cg = event.cgEvent {
                SyntheticKeyboard.postBoundaryCopy(of: cg)
                return true
            }
            // MANUAL In-place pin (không phải built-in): expansion vừa áp SYNC qua
            // insertText ngay trong handle này, nên Return native theo sau là ĐÃ
            // đúng thứ tự — trả false, không nuốt, không re-post. Nuốt+re-post ở
            // đây nhân đôi newline trên Quill/ProseMirror (Slack/Claude): composer
            // các app đó tự chèn newline cho cả phím Return bị IME nuốt (field
            // 07/08: 'ko'+Shift+Enter → 'không' + 2 dòng). Built-in in-place
            // (WhatsApp) giữ nuốt+re-post: insertText của nó áp async, Return
            // native sẽ gửi tin nhắn với text CŨ (field 1.5.1).
            if rewrote, AppState.shared.manualMode(AppState.shared.currentBundleID) == .inPlace {
                return false
            }
            if rewrote, Accessibility.isTrusted, let cg = event.cgEvent {
                // Web editor ở lớp MARKED (Docs canvas, comment box TikTok): insertText
                // của commit áp BẤT ĐỒNG BỘ vào model JS, nên Enter re-post ngay lập
                // tức vẫn tới TRƯỚC khi DOM có từ cuối → app "gửi" với text CŨ (field
                // report 19/08: gõ "thử xem" + Enter → TikTok post ra mỗi "thử").
                // Hoãn một nhịp bằng asyncAfter — KHÁC hẳn vụ nhịp-trong-callback đã
                // revert cùng ngày: ở đây callback trả về NGAY, không giữ cửa phím nào.
                let key = CGKeyCode(cg.getIntegerValueField(.keyboardEventKeycode))
                let flags = cg.flags
                if let ms = Self.boundaryRepostDelayMs(markedWebField: markedNow
                                                        && (FocusedFieldDetector.wantsMarkedField
                                                            || AppState.shared.isOfficeWebPanel(id))) {
                    logDecision("boundary re-post hoãn \(ms)ms (marked web editor)")
                    repostOrder.expect(.boundary(event.keyCode), nowNs: DispatchTime.now().uptimeNanoseconds)
                    repostHeld = repostHeld ?? []
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                        SyntheticKeyboard.postBoundaryKey(key, flags: flags)
                        self?.flushHeldBehindRepost()
                    }
                } else {
                    SyntheticKeyboard.postBoundaryCopy(of: cg)
                    repostOrder.expect(.boundary(event.keyCode), nowNs: DispatchTime.now().uptimeNanoseconds)
                }
                return true
            }
            // No Accessibility → no synthetic re-post. Native multiline fields and
            // terminals keep the marked Return fallback (terminals strip control text
            // and keep the documented two-press behavior). Chromium page content and
            // the Codex prompt receive a real plain Return so their editors can choose
            // send vs newline. Shift+Return stays a committed newline.
            if rewrote, !trustedNow, markedNow {
                return handling.swallowPhysicalKey
            }
            return false

        default:
            break
        }

        // VNI: the DIGITS carry the diacritics ("a1"→á, "tie61ng"→tiếng), so in VNI mode
        // they must reach the engine instead of ending the word. In Telex a digit is a
        // boundary as before (field report issue #28, 2026-07-27: VNI did nothing in the
        // app because every digit was consumed here — engine-level VNI tests all passed).
        guard let chars = effectiveCharacters(event), var ch = chars.first, let ascii = ch.asciiValue,
              isWordKey(ascii, vniMode: engine.vniMode,
                        bracketVowels: engine.bracketVowels,
                        keypad: isKeypadDigitKeyCode(Int(event.keyCode))) else {
            // space / punctuation / any non-letter ends the word. Brackets signal a
            // code-ish context (arr[i], {json}, (x)); skip auto-restore there so a
            // token isn't "corrected" (auto-restore is off around [ ] { }).
            // The composed word itself is committed unchanged.
            let boundaryText = effectiveCharacters(event)
            let boundaryChar = boundaryText?.utf8.first
            let wasEdge = edgeTapWord
            autoCappedWord = false; suppressAutoCap = false
            // Dấu chấm khi nhấn đúp phím cách / "--" → "—" (cài đặt macOS): phím thứ hai
            // tới khi từ đã chốt (engine rỗng) — thay ký tự ĐÃ CHỐT qua replacementRange.
            if engine.isEmpty, !markedNow, !wasEdge,
               boundaryChar == UInt8(ascii: " ") || boundaryChar == UInt8(ascii: "-"),
               boundaryText?.count == 1,
               trySystemReplace(boundaryChar == UInt8(ascii: " "), prevSpaceNs: prevSpaceNs,
                                prevEmDashOurs: prevEmDashOurs, isRepeat: event.isARepeat, client, id: id) {
                spMode = "system-auto-text"
                learnFlush()   // Học từ bạn gõ: ". " / "—" vừa thay — câu (ngữ cảnh) kết thúc
                return true
            }
            // Gõ tắt (khớp iOS/Android): khoá chữ chỉ nở ở khoảng trắng / dấu câu kết thúc
            // từ ("ko1", "ko-", "ko@" giữ nguyên), khoá ký hiệu chỉ ở khoảng trắng; phím
            // không chèn ký tự (mũi tên, F-key) không nở. Từ dính sau số / . _ - / # @
            // (#82 #87) không nở khoá chữ.
            let inserted = ShortcutScreen.insertedText(boundaryText)
            let allow = ShortcutMatch.triggers(boundary: inserted ?? "", glued: wordGluedToDigit)
            let rewrote = boundary(client, suppressAutoRestore: boundaryChar.map(isBracket) ?? false,
                                   allowShortcuts: allow.word, allowTokenShortcuts: allow.token,
                                   allowAlnumShortcuts: allow.alnum, boundaryKey: boundaryText?.first)
            // "Tự sửa từ phía trước" (thử nghiệm): engine chỉ đặt phép sửa khi "Quyết định theo
            // ngữ cảnh" bật — không có ⇒ một phép so nil. Công tắc bật: áp TRƯỚC khi ký tự ranh
            // giới tới app (con trỏ ở cuối từ vừa chốt; `expected` chưa gồm ranh giới). Tắt:
            // đề xuất bằng gợi ý cạnh con trỏ sau ranh giới.
            // Đề xuất KHÔNG đọc màn hình trên đường phím (chỉ kiểm kênh); gợi ý tự xác nhận lúc
            // hiện. App từng đọc chậm ⇒ tự áp lùi về đề xuất (RetroApply.keyPathMode).
            let retroMode = engine.pendingRetroCorrection.map { pending in
                RetroApply.keyPathMode(RetroApply.mode(contextualEnglish: engine.contextualEnglish,
                                                       autoApply: AppState.shared.retroactiveEnglish,
                                                       flipBack: pending.flipBack),
                                       slowApp: RetroCost.isSlow(id))
            } ?? .none
            let retroApplied = retroMode == .autoApply
                ? applyRetroCorrection(marked: markedNow, edge: wasEdge, client, id: id) : nil
            let retroOffer = retroMode == .offer
                ? retroOfferAllowed(marked: markedNow, edge: wasEdge, id: id) : nil
            // Học từ bạn gõ: từ vừa chốt (đứng riêng = cụm đã chốt đúng bằng từ đó).
            learnAtBoundary(word: lastCommitWord, boundary: inserted,
                            standsAlone: shortcutTail.run == lastCommitWord, id: id, edge: wasEdge)
            wordGluedToDigit = Self.gluesShortcutToken(boundaryChar)   // #82 số, #87 / # @ . _ -
            // Chip số (chỉ dạng tiền): dấu cách ngay sau cụm có chữ số ⇒ đọc màn hình MỘT lần
            // sau khi dấu cách tới app. Chỉ app đã chứng minh in-place (thay chữ đã chốt bằng
            // replacementRange an toàn) và không đang marked.
            // Gợi ý ranh giới từ (CaretSuggestions.swift): sửa lỗi gõ / thêm dấu / ngày giờ.
            // Tắt hết ⇒ một lần đọc cờ. Bật: chỉ so chuỗi ở đây, việc nặng chạy nền.
            if let b = inserted, CaretHint.shared.wordHintsEnabled {
                let tones = CaretHint.shared.tonesEnabled
                    ? toneRun.feed(chunk: shortcutTail.run, boundary: b) : nil
                CaretHint.shared.afterWord(
                    .init(boundary: b, run: shortcutTail.run, prevRun: numberPrevRun,
                          raw: expandedAtBoundary == nil ? lastCommitRaw : "",
                          anchored: shortcutTail.anchored, tones: tones),
                    client: client, controller: self,
                    canReplace: !markedNow && Self.replacesCommittedText(id))
            } else if inserted == nil {
                toneRun.reset()
            }
            if inserted == " " {
                let run = shortcutTail.run
                if CaretHint.shared.numberEnabled,
                   CaretHintLogic.numberWorthChecking(boundary: inserted, run: run, prevRun: numberPrevRun) {
                    CaretHint.shared.afterNumberSpace(client: client, controller: self, keyStream: nil,
                                                      canReplace: !markedNow && Self.replacesCommittedText(id))
                }
                numberPrevRun = run
                // Gợi ý từ kế tiếp (WordPrediction.swift): cài đặt hệ thống tắt ⇒ một lần đọc cờ.
                if PredictionLogic.shouldSchedule(settingOn: SystemInlinePrediction.isOn,
                                                  canReplace: !markedNow && !wasEdge && Self.replacesCommittedText(id)) {
                    CaretHint.shared.schedulePrediction(typed: "", raw: "", english: engine.previousWordEnglish,
                                                        client: client, controller: self)
                }
            }
            // Đuôi email (EmailDomainPrediction): "user@" ⇒ mời gmail.com — cùng cổng gợi ý từ
            // (tắt ⇒ một lần so chuỗi + đọc cờ). Chữ gõ tiếp sau "@" đi đường predictAfterLetter.
            if inserted == "@", PredictionLogic.shouldSchedule(
                settingOn: SystemInlinePrediction.isOn,
                canReplace: !markedNow && !wasEdge && Self.replacesCommittedText(id)) {
                CaretHint.shared.schedulePrediction(typed: "", raw: "", english: false, client: client, controller: self)
            }
            // Ngoặc kép cong (cài đặt macOS): chèn “ ” ‘ ’ thay phím " ' sau khi từ đã chốt.
            let smartQuote = (boundaryChar == UInt8(ascii: "\"") || boundaryChar == UInt8(ascii: "'"))
                && !(rewrote && wasEdge) ? smartQuoteText(boundaryText, client, id: id) : nil
            if let s = smartQuote ?? inserted { shortcutTail.append(s) } else { shortcutTail.reset() }
            // Hợp đồng sửa ngược (DESIGN.md): báo MỌI ký tự ranh giới cho engine (tắt ⇒ no-op).
            if let c = RetroApply.boundaryCharacter(smartQuote ?? inserted) { engine.noteBoundaryCharacter(c) }
            if let r = retroApplied {
                retroUndo = RetroApply.undo(expected: r.expected, insert: r.insert, boundary: smartQuote ?? inserted)
            }
            // ⌫ ngay sau khi tự khôi phục tiếng Anh ("NÁ" → "NAS"): trả lại chữ Việt (như hoàn tác
            // tự sửa của macOS). Chỉ app in-place đã chứng minh thay được chữ đã chốt, không
            // terminal / app mã nguồn; sửa ngược đang giữ ⌫ thì nhường.
            if let u = engine.takeRestoreUndo(), retroUndo == nil, !markedNow, !wasEdge,
               SystemAutoText.appAllowed(id), Self.replacesCommittedText(id),
               let ru = RetroApply.restoreUndo(u, boundary: smartQuote ?? inserted) {
                retroUndo = ru
                DebugLog.noteRestoreUndoOffered()
            }
            if let c = retroOffer, let o = RetroApply.offer(expected: c.expected, insert: c.insert, boundary: smartQuote ?? inserted) {
                CaretHint.shared.offerRetro(o, client: client, controller: self)
            }
            if inserted == " ", SystemAutoTextSettings.shared.period {
                periodSpaceNs = DispatchTime.now().uptimeNanoseconds
            }
            if let x = expandedAtBoundary, !markedNow, !wasEdge {
                // Một ký tự in được vừa theo sau nội dung nở ⇒ ⌫ kế tiếp được hoàn tác.
                shortcutUndo = ShortcutUndo.make(typed: x.typed, expansion: x.expansion, boundary: inserted)
            }
            // Only a key that leaves exactly ONE character after the word may be
            // ⌫-ed back into it (issue #40). Arrow/function keys land here too — they
            // move the caret and insert nothing, so the word is no longer adjacent.
            if !Self.insertsOneCharacter(effectiveCharacters(event)) { engine.forgetLastCommit() }
            // Edge word rewritten at the boundary (shortcut/auto-restore): the
            // rewrite is a synthetic burst still in the session queue — a native
            // boundary key would overtake it. Same cure as Return below: swallow
            // and re-post so the key lands AFTER the burst.
            if rewrote, wasEdge, Accessibility.isTrusted, let cg = event.cgEvent {
                SyntheticKeyboard.postBoundaryCopy(of: cg)
                return true
            }
            if let q = smartQuote {
                client.insertText(q, replacementRange: kNoRange)
                spMode = "system-auto-text"
                return true
            }
            if let remapped = remappedInsert(event) {
                // Edge word (Slate class, manual In-place): the word's synthetic burst may
                // still be draining — insertText would overtake it. Same cure as the
                // rewrite case above: re-post the key so it lands after the burst; the
                // copy comes back here (engine empty, no edge word) and is inserted then.
                if wasEdge, lastKeyWasDead, !SyntheticKeyboard.queueDrained(),
                   Accessibility.isTrusted, let cg = event.cgEvent {
                    SyntheticKeyboard.postBoundaryCopy(of: cg)
                    return true
                }
                client.insertText(remapped, replacementRange: kNoRange)
                return true
            }
            return false
        }

        var capFirstKey = false
        // Gợi ý hoàn thành từ đang gõ (WordPrediction.swift) — chạy SAU khi phím đã xử lý
        // xong (mọi nhánh return bên dưới). Cài đặt hệ thống tắt ⇒ một lần đọc cờ.
        defer { predictAfterLetter(client, markedNow: markedNow, id: id) }

        // First key of a new word: anchor the caret once (never again mid-word).
        // If the app can't report a caret here (some Electron apps: Claude), fall
        // back to per-op selectedRange (still in-place, no underline) rather than
        // forcing marked text. Only a failed probe pushes an app to marked text.
        if engine.isEmpty {
            let sel = client.selectedRange()
            if distrustNextAnchor {
                // Spotlight's session just cycled (see lastSpotlightActivateNs) — the
                // caret it reports for this first key cannot be trusted (measured:
                // start=6632 in a field that was actually empty). Same safe path as
                // "no caret at all": skip tracking for this one word rather than
                // anchor on a number that will garble every insert after it.
                distrustNextAnchor = false
                tracking = false; selToClear = 0
                DebugLog.log("word-start anchor distrusted (post-Spotlight-cycle): reported loc=\(sel.location)")
            } else if sel.location != NSNotFound {
                // A non-empty selection (e.g. after ⌘A) must be OVERWRITTEN by the
                // first key, not inserted-before. Remember its length and fold it
                // into the first insert's replacementRange below.
                anchor = sel.location; onLen = 0; tracking = true
                anchorVerified = false
                selToClear = sel.length
                // Diagnostic (counts only, never text): field report 2026-08-06
                // ("bôi đen rồi gõ … thay vì replace thì viết thêm") has no log
                // evidence yet of WHERE the fold breaks — this pins whether a
                // selection was even seen at word-start, so a future capture can
                // show whether the re-anchor below (fresh caret further right)
                // shifted `anchor` out from under this `selToClear` extent.
                if sel.length > 0 {
                    DebugLog.log("selection at word-start: loc=\(sel.location) len=\(sel.length)")
                }
            } else {
                tracking = false; selToClear = 0
            }
            // Edge chỉ cho composer Slate-class (append ở offset 0). Đo 07/08:
            // Quill (Slack) honor offset-0 → đi insertText trực tiếp, và Return
            // với nó KHÔNG được nuốt/re-post (xem offset0AppendApps).
            edgeTapWord = AppState.offset0AppendApps.contains(id ?? "")
                && Self.edgeTapEligible(
                manualInPlace: AppState.shared.manualMode(id) == .inPlace,
                caret: (tracking && sel.location != NSNotFound) ? sel.location : nil,
                trusted: Accessibility.isTrusted)
            // Diagnostic: Discord/Slate reports a NONZERO caret in an EMPTY message
            // box (field 06/08: "cos" still → "coó" with the pin; probe start=2 ⇒
            // word anchored at 1). Pin the actual value per app before widening
            // the eligibility predicate. Pinned-app word starts only, counts only.
            if AppState.shared.manualMode(id) == .inPlace {
                logDecision("word-start pin-inPlace caret=\(sel.location == NSNotFound ? -1 : sel.location) selLen=\(sel.length) edge=\(edgeTapWord)")
            }
            // Viết hoa đầu câu (cài đặt macOS): quyết MỘT lần ở chữ đầu từ, bằng chữ đưa
            // vào engine (Telex vẫn ghép: "Dduwowcj" → "Được"), không sửa lại sau.
            capFirstKey = ascii >= 97 && ascii <= 122 && !edgeTapWord
                && shouldAutoCapitalize(caret: sel.location == NSNotFound ? nil : sel.location, client, id: id)
        }

        // Overlay launcher's first word key (#110): the tap may already have typed the
        // start of this word before IMK activated the panel — adopt it if the screen
        // proves it. One-shot per activation; a Bool test for every other client.
        if pendingTapHandoff {
            pendingTapHandoff = false
            if engine.isEmpty, tracking, selToClear == 0, !markedNow, !edgeTapWord {
                tryAdoptTapHandoff(caret: anchor, client, id: id)
            } else {
                TapHandoff.clear()
            }
        }

        // RE-EDIT ("Fix tones of typed words", default ON): a tone/mark key on an EMPTY engine right after a
        // word means "add this diacritic to that word" ("toan" + s → toán). Seed the
        // engine from the text on screen so the normal replace machinery does the edit.
        if engine.isEmpty, AppState.shared.reEditWord, Self.isDiacriticOnlyKey(ascii, vni: engine.vniMode) {
            if tracking, selToClear == 0, !afterRawInsert {
                tryReEditWord(caret: anchor, client, id: id)
            } else {
                // #163: name the exit (no caret / live selection / raw insert just before).
                DebugLog.log("re-edit \(id ?? "?"): skipped ("
                    + (!tracking ? "no caret at word start" : selToClear > 0 ? "live selection" : "after raw insert") + ")")
            }
        }

        // Re-edit/handoff vừa seed engine ⇒ phím này không còn là chữ đầu từ.
        if engine.isEmpty { autoCappedWord = false }
        if capFirstKey, engine.isEmpty {
            ch = SystemAutoText.capitalized(ch)
            autoCappedWord = true
        }
        // #181: chữ đầu từ ở lưới Google Sheets trong Safari phải tới trang như phím thật.
        let gridNativeLetter = Self.gridFirstLetterNative(
            wordStart: engine.isEmpty, marked: markedNow, edge: edgeTapWord,
            webKitBrowser: AppState.webKitBrowsers.contains(id ?? ""),
            sheetsGrid: FocusedFieldDetector.wantsEmptyResetField,
            layoutPinned: KeyboardLayoutOverride.translator != nil,
            afterDeadKey: keyFollowsDeadKey, autoCapped: autoCappedWord)
        let action = engine.feed(ch)
        // OVERFLOW in a MARKED app: feed() returned .passthrough WITHOUT recording the
        // key, so re-setting the marked text (unchanged 32-char prefix) while consuming
        // the event made the 33rd+ characters vanish. Mirror the tap's overflow
        // handling: finalize what is composed, then deliver the key through the SAME
        // ordered insertText channel (returning false would race the async marked
        // commit in terminals — see the Return-key note above). The
        // engine restarts on the next key, so the tail composes as a fresh syllable —
        // no diacritic re-placement across the 32-char break, but never lost text.
        // (In-place mode is unaffected: its .passthrough branch inserts the letter
        // itself, which is already correct.)
        if case .commitAndPassThrough = Self.passthroughPlan(overflowPassthrough: Self.isPassthrough(action) && engine.isOverflowed,
                                                            marked: markedNow, isBackspace: false) {
            endComposition(client)
            client.insertText(String(ch), replacementRange: kNoRange)
            return true
        }
        if markedNow { updateMarked(client); return true }
        switch action {
        case .passthrough:
            if edgeTapWord, KeyboardLayoutOverride.translator == nil, !keyFollowsDeadKey {
                // Edge word: the app inserts the raw key natively — same CGEvent
                // queue as the synthetic replaces below, so ordering holds. A
                // selection at offset 0 (⌘A) is overwritten by the native key.
                // (With a layout pinned, "natively" would type the WRONG letter —
                // fall through to the insertText path, which carries our character.
                // Same right after a dead key: native could arrive composed, #161.)
                selToClear = 0
                onLen += 1
                return false
            }
            if gridNativeLetter {
                // Chỉ chữ ĐẦU từ; các phím sau vẫn đi kênh insertText có thứ tự như cũ.
                logDecision("sheets grid (WebKit): first letter passes natively")
                selToClear = 0
                if tracking { onLen += 1 }
                return false
            }
            // Insert the letter ourselves (do NOT return false to let the system
            // insert it): mixing a system passthrough-insert with our insertText
            // transforms races under fast typing and corrupts words ("được"->"đựoc").
            // Every edit must go through the one ordered insertText channel.
            if tracking {
                if selToClear > 0 {
                    DebugLog.log("selection fold (letter) \(id ?? "?"): range=(\(anchor + onLen),\(selToClear))")
                }
                // Async-apply client (WhatsApp): our word-start anchor came from a
                // caret read that can predate edits still pending there (the previous
                // word, its space) — a ranged insert at that stale offset lands the
                // letter INSIDE earlier text ("letters jumped", 03/11/2026). A plain
                // letter (nothing to fold) goes to the app's own caret, which is
                // always right once it applies; the first replace re-anchors.
                let range = (selToClear == 0 && Self.insertsAtCaret(bundleID: id))
                    ? kNoRange : NSRange(location: anchor + onLen, length: selToClear)
                client.insertText(String(ch), replacementRange: range)
                selToClear = 0
                onLen += 1
            } else {
                client.insertText(String(ch), replacementRange: kNoRange)
            }
            return true
        case .none:
            return true
        case let .replace(bs, insert):
            if edgeTapWord {
                noteEdgeBurst(SyntheticKeyboard.applyForEdge(backspaces: bs, insert: insert))
                onLen = (engine.composed as NSString).length
                return true
            }
            applyInPlace(bs: bs, insert: insert, client)
            return true
        }
    }


    /// The ⌫ freshness guard protects the IN-PLACE rewrite only — marked mode edits
    /// through its composition session (engine.backspace → setMarkedText) and needs no
    /// window arithmetic; running the guard there is what orphaned Google-Docs-in-
    /// Safari compositions (issue #37: `onLen` never advances in marked mode, so the
    /// guard compared the caret against the ANCHOR and dropped the word on the first
    /// mid-word ⌫). Pure so the polarity is pinned by tests.
    static func backspaceFreshnessGuardApplies(marked: Bool) -> Bool { !marked }

    /// Does the app's caret still agree with our tracked composition window? Only then
    /// may a ⌫ rewrite the window blind. Three ways it can lie, all fatal to the
    /// arithmetic: no caret at all, a live SELECTION (an inline autocomplete suffix would
    /// be swallowed by our replacementRange), or a caret anywhere other than exactly the
    /// end of what we composed (the app re-rendered or moved it). Pure function so the
    /// rule is pinned by tests — the failure it prevents (an extra character eaten, then
    /// every later insert landing nowhere) is invisible in a log until it's too late.
    static func trackedWindowIsFresh(caret: Int?, selectionLength: Int, expected: Int) -> Bool {
        guard let caret else { return false }
        guard selectionLength == 0 else { return false }
        // Exact match OR within the Chromium stale-caret lag window: right after our
        // insertText, Chromium answers selectedRange from a cache that is one edit
        // behind (the SAME staleness InPlaceProbe.verdict tolerates — Discord-web
        // 2026-08-05: caret=18 expected=19 on ⌫ made this check drop the composition
        // and pass the delete natively → "xóa linh tinh, mất chữ đ"). The caret here
        // is only a FRESHNESS WITNESS — the rewrite range comes from our own
        // anchor/onLen bookkeeping, which the deferred AX reads confirmed correct in
        // every measured stale-answer case. A caret AHEAD of expected, any live
        // selection (inline autocomplete), or a lag beyond the window still drops —
        // that is the 2026-07-27 Chrome Web Store class this guard exists for.
        let lag = expected - caret
        return lag >= 0 && lag <= InPlaceProbe.maxCaretLag
    }

    // MARK: - Lưới Google Sheets trong Safari (#181)

    /// Ô lưới Sheets đang CHỌN (chưa vào chế độ sửa) chỉ bắt đầu sửa khi nhận phím thật
    /// (keydown/keypress). Chữ chèn bằng insertText (in-place) hay marked text đều không mở
    /// ô — số và dấu câu (vốn đi thẳng) thì gõ được, bộ gõ Telex của Apple cũng bị. Vì vậy
    /// chữ ĐẦU của từ, khi không cần biến đổi gì, được để trang nhận như phím thật; ô vào
    /// chế độ sửa, các phím sau đi in-place như thường. Không áp dụng khi ký tự mình chèn
    /// khác phím thật: layout ghim (translator), sau dead key, chữ đầu câu tự viết hoa.
    static func gridFirstLetterNative(wordStart: Bool, marked: Bool, edge: Bool, webKitBrowser: Bool,
                                      sheetsGrid: Bool, layoutPinned: Bool, afterDeadKey: Bool,
                                      autoCapped: Bool) -> Bool {
        wordStart && !marked && !edge && webKitBrowser && sheetsGrid
            && !layoutPinned && !afterDeadKey && !autoCapped
    }

    // MARK: - Engine .passthrough (32-char overflow) contract

    /// What the controller must do when the engine answers `.passthrough`.
    enum PassthroughPlan: Equatable {
        /// Not a passthrough (or a case the normal branches already handle correctly):
        /// carry on with the regular marked / in-place handling.
        case honorEngineAction
        /// Marked-text app: finalize the composition, then let the key act on real text.
        /// Re-setting the marked string here would re-render an unchanged stale prefix
        /// and swallow the key.
        case commitAndPassThrough
        /// Tracked in-place ⌫: the app deletes the character natively, so our tracked
        /// window shrinks by one and NOTHING may be rewritten.
        case shrinkWindowAndPassThrough
    }

    /// Once a word exceeds the engine's 32-key capacity it answers `.passthrough`
    /// WITHOUT recording the key: its `raw`/`composed` view is a stale prefix of what is
    /// on screen, so it refuses to diff and the APP must handle the key. The action
    /// alone is NOT the signal — an ordinary literal letter also answers `.passthrough`
    /// (recorded, composition live) — so callers must gate on `engine.isOverflowed` too;
    /// treating every passthrough as overflow committed the marked composition on the
    /// FIRST letter of every word. Pure function because both violations this pins were
    /// silent in logs: a tracked ⌫ that rewrote the window wiped every overflow
    /// character and then went dead for the rest of the word, and a marked-text app
    /// that re-set its unchanged prefix dropped the 33rd+ letters outright.
    static func passthroughPlan(overflowPassthrough: Bool, marked: Bool, isBackspace: Bool) -> PassthroughPlan {
        guard overflowPassthrough else { return .honorEngineAction }
        if marked { return .commitAndPassThrough }
        // In-place ⌫: never rewrite. In-place letter: the existing `.passthrough` branch
        // already inserts the character through our own ordered channel — leave it.
        return isBackspace ? .shrinkWindowAndPassThrough : .honorEngineAction
    }

    static func isPassthrough(_ action: TelexAction) -> Bool {
        if case .passthrough = action { return true }
        return false
    }

    // MARK: - Re-edit the word before the caret ("Fix tones of typed words", default ON)

    /// Does this key put exactly ONE printable character on screen after the word it
    /// just ended? Only then is the next ⌫ deleting a boundary character, which is the
    /// precondition for re-opening the word (issue #40, see `tryReopenLastCommit`).
    /// Printable ASCII only: a non-ascii scalar (arrow/function keys arrive as
    /// U+F700…, option-key symbols as real text) either isn't inserted at all or isn't
    /// something worth reasoning about. Pure so the rule is pinned by tests.
    /// What this key would type on the layout the user pinned. Falls back to
    /// `event.characters` — the pre-pin behaviour — whenever no remapping is in force,
    /// which is every case except "pinned a layout AND macOS is on a different one".
    /// Modifier combos never reach here: handle() passes ⌘⌃⌥ through before this.
    ///
    /// Dead key (#161): no remapping in force and macOS sent EMPTY characters ⇒ the
    /// key's own character on the live layout (' on U.S. International – PC), which
    /// the boundary path then inserts — see DeadKeyLiteral.
    private func effectiveCharacters(_ event: NSEvent) -> String? {
        let shift = event.modifierFlags.contains(.shift)
        let caps = event.modifierFlags.contains(.capsLock)
        guard let translator = KeyboardLayoutOverride.translator,
              let ch = translator.character(keyCode: event.keyCode, shift: shift, capsLock: caps)
        else {
            return DeadKeyLiteral.resolve(eventCharacters: event.characters,
                                          afterDeadKey: keyFollowsDeadKey,
                                          deadOnLayout: keyIsLayoutDead) {
                KeyboardLayoutOverride.liveCharacter(keyCode: event.keyCode, shift: shift, capsLock: caps)
            }
        }
        return String(ch)
    }

    /// Text to insert in place of the system's, for a key we would otherwise let
    /// macOS type. nil = pass through untouched, exactly as before.
    ///
    /// Returning false from handle() means "macOS, type this key" — and macOS types
    /// it with the layout we are overriding. So wherever a pass-through would now
    /// produce the wrong letter, we have to insert ours and swallow the key instead.
    ///
    /// Also the dead-key case (#161): the event carries no characters, so passing it
    /// through types nothing — insert the key's own character instead.
    private func remappedInsert(_ event: NSEvent) -> String? {
        guard KeyboardLayoutOverride.translator != nil || lastKeyWasDead || keyFollowsDeadKey
        else { return nil }
        return DeadKeyLiteral.insertion(ours: effectiveCharacters(event), eventCharacters: event.characters,
                                        deadOnLayout: keyIsLayoutDead)
    }

    /// Passthrough app where a dead key must stay a raw keycode (remote desktop / VM).
    static func deadKeyStaysRaw(_ id: String?) -> Bool {
        DeadKeyLiteral.passthroughKeepsRaw(
            remoteDesktop: ClientPolicy.isRemoteDesktop(id),
            builtInPassthrough: id.map { AppState.isBuiltInPassthrough($0) } ?? false,
            bundleID: id)
    }

    /// ⌥(+Shift)+key starts a dead key on the live layout? Its dead state, else nil.
    /// One array read for every other ⌥ chord.
    static func optionDeadStart(table: KeyboardLayoutTranslator?, keyCode: UInt16,
                                shift: Bool, capsLock: Bool) -> UInt32? {
        guard let t = table, t.isOptionDeadKey(keyCode: keyCode, shift: shift) else { return nil }
        let st = t.optionDeadState(keyCode: keyCode, shift: shift, capsLock: capsLock)
        return st == 0 ? nil : st
    }

    /// What finishing a pending ⌥ dead key with this key does. Pure — pinned by tests.
    enum OptionDeadOutcome: Equatable {
        /// Pending state dropped, key handled as usual (Esc, ⌘/⌃ chords).
        case cancel
        /// Pending state dropped and the key consumed (⌫ deletes the pending accent).
        case cancelConsume
        /// Insert `text`, consume the key; `state` ≠ 0 keeps a chained dead key pending.
        case insert(String, state: UInt32)
        /// Insert `text` (the spacing accent), then handle the key as usual (Return, Tab,
        /// arrows: the layout gives "´" + the key's own control output).
        case insertThenContinue(String)
    }

    static func optionDeadOutcome(keyCode: UInt16, commandOrControl: Bool,
                                  composed: () -> (text: String, state: UInt32)) -> OptionDeadOutcome {
        if commandOrControl || keyCode == 53 { return .cancel }          // Esc
        if keyCode == 51 { return .cancelConsume }                       // ⌫
        let (text, state) = composed()
        // Keep the printable head; a control / function-key tail is the key's own work.
        var head = ""
        for ch in text {
            guard DeadKeyLiteral.isLiteral(String(ch)) else {
                return head.isEmpty ? .cancel : .insertThenContinue(head)
            }
            head.append(ch)
        }
        if head.isEmpty { return state != 0 ? .insert("", state: state) : .cancel }
        return .insert(head, state: state)
    }

    /// Finish the pending ⌥ dead key with `event`. nil = carry on with the normal
    /// decision tree for this key; true/false = handled here.
    private func finishOptionDead(_ event: NSEvent, _ client: IMKTextInput) -> Bool? {
        let pending = optionDeadState
        optionDeadState = 0
        guard let table = KeyboardLayoutOverride.liveTable else { return nil }
        let flags = event.modifierFlags
        let outcome = Self.optionDeadOutcome(
            keyCode: event.keyCode,
            commandOrControl: !flags.intersection([.command, .control]).isEmpty) {
                table.compose(state: pending, keyCode: event.keyCode,
                              modifiers: KeyboardLayoutTranslator.carbonModifiers(
                                  shift: flags.contains(.shift), option: flags.contains(.option),
                                  capsLock: flags.contains(.capsLock)))
            }
        logDecision("option dead key finish keyCode=\(event.keyCode) → \(outcome)")
        switch outcome {
        case .cancel:
            return nil
        case .cancelConsume:
            return true
        case let .insert(text, state):
            optionDeadState = state
            if !text.isEmpty {
                // é/ü/ñ… là ký tự ngoài Telex: ranh giới từ, không ghép vào engine.
                if !engine.isEmpty { endComposition(client) }
                client.insertText(text, replacementRange: kNoRange)
                shortcutTail.reset()
                engine.forgetLastCommit()
            }
            return true
        case let .insertThenContinue(text):
            if !engine.isEmpty { endComposition(client) }
            client.insertText(text, replacementRange: kNoRange)
            shortcutTail.reset()
            engine.forgetLastCommit()
            return nil
        }
    }

    static func insertsOneCharacter(_ characters: String?) -> Bool {
        guard let characters, characters.count == 1,
              let ascii = characters.first?.asciiValue else { return false }
        return ascii >= 0x20 && ascii != 0x7F
    }

    /// Keys that can only ever ADD a diacritic, never a letter: the Telex tone keys
    /// (s f r x j), the tone remover (z) and the horn/breve modifier (w) — or, in VNI,
    /// the digits. The doubler letters (a e o d) are deliberately NOT here: they are
    /// ordinary letters too, so a plain "ca" + "a" keeps behaving exactly as before and
    /// re-edit costs a text read-back only on keys that are unambiguously modifiers.
    static func isDiacriticOnlyKey(_ ascii: UInt8, vni: Bool) -> Bool {
        if vni { return isAsciiDigit(ascii) }
        switch ascii | 0x20 {                     // fold case
        case UInt8(ascii: "s"), UInt8(ascii: "f"), UInt8(ascii: "r"), UInt8(ascii: "x"),
             UInt8(ascii: "j"), UInt8(ascii: "z"), UInt8(ascii: "w"):
            return true
        default:
            return false
        }
    }

    /// The trailing word in `text` (the characters just before the caret) that a
    /// diacritic key could still modify. Letters only — it stops at a space, digit,
    /// punctuation or symbol, so "mp3", "a-b" and "x)" have no re-editable tail. Returns
    /// nil when there is none, or when the run is longer than a syllable can be (the
    /// engine would refuse it anyway, and reading further is pointless).
    static func trailingWord(_ text: String, maxLength: Int = 12) -> String? {
        var word = ""
        for ch in text.reversed() {
            guard ch.isLetter else { break }
            word.insert(ch, at: word.startIndex)
            if word.count > maxLength { return nil }
        }
        return word.isEmpty ? nil : word
    }

    /// Seed the engine from the word already on screen so the key about to be fed edits
    /// IT instead of starting a new one. Silent no-op whenever anything is uncertain —
    /// the alternative is rewriting text the user never asked to change:
    ///  • only apps already PROVEN to honor in-place replacement (learned in-place),
    ///    never a marked-text field and never a per-field/omnibox browser field whose
    ///    inline autocomplete rewrites text underneath us;
    ///  • only a canonical (precomposed) read-back — an NFD field would make our UTF-16
    ///    arithmetic cut into combining marks;
    ///  • only when `engine.seed` ROUND-TRIPS the word, which is what rejects English
    ///    words, other tone-placement styles and anything untypable.
    ///  #163 RC4: "proven" now also covers apps the user pinned to In-place and WebKit
    ///  page content — see ReEditIMKAcceptance.appAllowed for why the edit channel
    ///  (insertText(replacementRange:)) is the trusted one there.
    private func tryReEditWord(caret: Int, _ client: IMKTextInput, id: String?) {
        guard caret > 0 else {
            DebugLog.log("re-edit \(id ?? "?"): skipped (caret at 0)")
            return
        }
        let manualInPlace = AppState.shared.manualMode(id) == .inPlace
        guard ReEditIMKAcceptance.appAllowed(learnedInPlace: AppState.shared.isLearnedInPlace(id),
                                             manualInPlace: manualInPlace,
                                             webKitPage: AppState.isWebKitPageClient(id)) else {
            DebugLog.log("re-edit \(id ?? "?"): skipped (app not learned/pinned in-place, not WebKit page)")
            return
        }
        guard !usesMarkedNow(id) else {
            DebugLog.log("re-edit \(id ?? "?"): skipped (marked-text field)")
            return
        }
        // Browsers are excluded PER FIELD, not per app: only the address/search bar has the
        // inline autocomplete that makes re-editing unsafe, and blanket-excluding every
        // browser turned the feature off exactly where people type most — inside the page
        // (report 2026-07-27: "đưa con trỏ về sau chữ 'toán', ấn 2 … không được", in Zen).
        if AppState.shared.usesAxDetect(id), FocusedFieldDetector.wantsSelection {
            DebugLog.log("re-edit \(id ?? "?"): skipped (field resolves to selection-replace)")
            return
        }
        let window = min(caret, 24)
        guard let sub = client.attributedSubstring(from: NSRange(location: caret - window,
                                                                 length: window)) else {
            DebugLog.log("re-edit \(id ?? "?"): skipped (client text unreadable)")
            return
        }
        let text = sub.string
        // Exact UTF-16 compare, NOT `==`: Swift String equality is canonical-equivalence,
        // so an NFD field ("ta\u{302}n") would pass `==` against its NFC form and the
        // later ⌫ counts would fall short of what is really on screen.
        guard text.utf16.elementsEqual(text.precomposedStringWithCanonicalMapping.utf16) else {
            DebugLog.log("re-edit \(id ?? "?"): skipped (field text is not precomposed)")
            return
        }
        guard let word = Self.trailingWord(text) else {
            DebugLog.log("re-edit \(id ?? "?"): skipped (no word right before caret)")
            return
        }
        let wordLen = (word as NSString).length
        if ReEditIMKAcceptance.edgeZoneBlocks(offset0AppendApp: AppState.offset0AppendApps.contains(id ?? ""),
                                              manualInPlace: manualInPlace, wordStart: caret - wordLen) {
            DebugLog.log("re-edit \(id ?? "?"): skipped (word at field start in an offset-0 append app)")
            return
        }
        guard wordLen <= caret, engine.seed(word) else {
            DebugLog.log("re-edit \(id ?? "?"): skipped (seed did not round-trip, \(wordLen) chars)")
            return
        }
        // The composition now IS that on-screen word: point the tracking window at it so
        // the next replace lands on the word's own characters. `anchorVerified` is set —
        // the anchor came from a caret read taken one line ago, not a stale word start.
        anchor = caret - wordLen
        onLen = wordLen
        anchorVerified = true
        DebugLog.log("re-edit \(id ?? "?"): seeded \(wordLen) chars before caret")
    }

    /// TapHandoff (#110 vòng 2): ô Raycast đang chứa chữ tap chèn cho phím đầu (vd "ư"
    /// từ "w") mà engine IMK mới không biết. Đọc lại chữ trước con trỏ; chỉ khi khớp
    /// CHÍNH XÁC chữ tap đã chèn (và các điều kiện của TapHandoff.adoptable) mới phát
    /// lại phím thô vào engine và trỏ cửa sổ soạn vào đúng chữ đó — giống hệt re-edit
    /// sau khi seed. Không khớp: im lặng, như bản 1.8.8.
    private func tryAdoptTapHandoff(caret: Int, _ client: IMKTextInput, id: String?) {
        guard let snap = TapHandoff.take() else { return }
        let len = (snap.composed as NSString).length
        guard len > 0, caret >= len else {
            DebugLog.log("tap-handoff \(id ?? "?"): skipped (caret=\(caret) len=\(len))")
            return
        }
        let window = min(caret, 24)
        let text = client.attributedSubstring(from: NSRange(location: caret - window, length: window))?.string ?? ""
        guard TapHandoff.adoptable(snap, nowNs: DispatchTime.now().uptimeNanoseconds,
                                   epochNow: ClientFocus.epoch,
                                   latchedLauncher: ClientFocus.overlayLauncher,
                                   clientID: id, textBeforeCaret: text) != nil else {
            DebugLog.log("tap-handoff \(id ?? "?"): skipped (screen/epoch/age mismatch, len=\(len))")
            return
        }
        guard TapHandoff.replay(&engine, raw: snap.raw, expect: snap.composed) else {
            DebugLog.log("tap-handoff \(id ?? "?"): skipped (replay mismatch)")
            return
        }
        anchor = caret - len
        onLen = len
        anchorVerified = true
        DebugLog.log("tap-handoff \(id ?? "?"): adopted \(len) chars typed by the tap before activateServer")
    }

    // MARK: - Re-open the last committed word on ⌫ (issue #40)

    /// The ⌫ about to be delivered deletes the boundary character that ended the last
    /// word — so put that word back in the buffer, the way every other Vietnamese IME
    /// does ("tháy" ␣ ⌫ `a` → "thấy" instead of "tháya").
    ///
    /// Unlike `tryReEditWord` this never guesses WHICH word: the engine kept the exact
    /// keystrokes it committed, and only while nothing else touched it since. What is
    /// still unknown is whether the SCREEN agrees — the app may have swallowed the
    /// boundary key, autocorrected the word, or moved the caret — so the characters the
    /// word should occupy are read back and compared before anything is re-opened. On
    /// any disagreement the composition is dropped and the ⌫ behaves exactly as before.
    /// Returns true iff the buffer now holds the word; the ⌫ itself always passes
    /// through and deletes the boundary character.
    private func tryReopenLastCommit(_ client: IMKTextInput, id: String?) -> Bool {
        // Gated behind the SAME experimental toggle as re-edit (maintainer decision
        // 13/08/2026): both features answer "may an empty-engine key reach back into
        // the word before the caret?", so one opt-in covers the pair. Default OFF —
        // the reEdit 1.4.28 default-ON revert is the standing lesson.
        guard AppState.shared.reEditWord else { return false }
        // Marked-text apps commit through setMarkedText/insertText, so the word on
        // screen is finalized text no composition can reclaim.
        guard engine.canReopenLastCommit else { return false }
        guard !usesMarkedNow(id) else {
            DebugLog.log("⌫ re-open \(id ?? "?"): skipped (marked-text field)")
            return false
        }
        // Same per-FIELD exclusion as `tryReEditWord`: an omnibox/search bar rewrites
        // text underneath us via inline autocomplete, so the replace that follows a
        // re-open would land in a field that is editing itself. (Reachable from here
        // whenever the tap is not running — no Accessibility — and IMKit handles the
        // browser in-place.)
        if AppState.shared.usesAxDetect(id), FocusedFieldDetector.wantsSelection {
            engine.forgetLastCommit()
            DebugLog.log("⌫ re-open \(id ?? "?"): skipped (field resolves to selection-replace)")
            return false
        }
        let sel = client.selectedRange()
        // A live SELECTION means this ⌫ deletes that instead of the boundary character,
        // and with no caret there is no anchor to re-open at. Either way: forget the
        // word — the boundary character is gone by the next key, so a later ⌫ must not
        // resurrect it.
        guard sel.location != NSNotFound, sel.length == 0 else {
            engine.forgetLastCommit()
            DebugLog.log("⌫ re-open \(id ?? "?"): skipped (" + (sel.location == NSNotFound ? "no caret" : "live selection") + ")")
            return false
        }
        guard let word = engine.reopenLastCommit() else {
            DebugLog.log("⌫ re-open \(id ?? "?"): skipped (replay mismatch)")
            return false
        }
        let wordLen = (word as NSString).length
        let start = sel.location - 1 - wordLen          // this ⌫ removes the boundary char
        guard start >= 0,
              let sub = client.attributedSubstring(from: NSRange(location: start, length: wordLen)),
              sub.string.utf16.elementsEqual(word.utf16) // exact, not `==` (canonical): NFD field ⇒ skip
        else {
            engine.reset()
            DebugLog.log("⌫ re-open \(id ?? "?"): skipped (screen disagrees)")
            return false
        }
        // The composition IS that on-screen word now: point the tracking window at it,
        // exactly like the re-edit path does after a successful seed.
        anchor = start
        onLen = wordLen
        tracking = true
        anchorVerified = true
        selToClear = 0
        edgeTapWord = false
        DebugLog.log("⌫ re-open \(id ?? "?"): \(wordLen) chars back in the buffer")
        return true
    }

    // MARK: - In-place mode (default: no marked text, caret stays at end)

    /// Replace `bs` chars before the caret with `insert`, using our locally tracked
    /// position (no per-key selectedRange()). Unclassified apps are probed on the
    /// first real replace (read-back at the target region); apps that ignore
    /// replacementRange (Terminal) flip to marked text.
    private func applyInPlace(bs: Int, insert: String, _ client: IMKTextInput) {
        let id = AppState.shared.currentBundleID
        let start: Int
        // A pending selection (e.g. after ⌘A) must be overwritten by this first
        // replacement, exactly as the .passthrough branch does. selToClear is only set
        // while tracking; fold it into the replacementRange so the selection is removed
        // by the same insert, then clear it (a later insert must not re-scope to it).
        // On a first-key replace bs == 0, so start == anchor and the range is
        // (anchor, selToClear) — the whole selection. onLen must NOT subtract
        // selToClear: the selection was never part of the composition length, so
        // `onLen += insert.length - bs` stays correct after the removal.
        var clear = 0
        if tracking {
            // Async-apply client (WhatsApp): a range-targeted rewrite sent while our
            // previous edits are still pending there is APPENDED, not applied as a
            // replace ("looix" → "loôiỗi"). Let it catch up first — BEFORE the
            // re-anchor read below, so that read sees the settled caret. A pure
            // insert (bs == 0, nothing to clear) lands at the caret either way.
            if bs + selToClear > 0 {
                awaitAsyncClient(client, expected: anchor + onLen, why: "replace")
            }
            // One-shot RE-ANCHOR at the word's first replace. Right after a newline
            // (Discord/Slate-class editors) the word-start selectedRange read is
            // STALE — it still reports the pre-newline caret, so the anchor is short
            // and the first tone edit writes into the wrong spot ("thử" typed on a
            // fresh line came out "thuử"). By the first replace the editor has
            // settled, so re-read once; trust the fresh caret ONLY when it is
            // FURTHER RIGHT than expected — a smaller read is the old fast-typing
            // staleness ("được"→"đựoc") that the once-per-word anchor exists to
            // ignore.
            if !anchorVerified {
                anchorVerified = true
                let fresh = client.selectedRange()
                let expected = anchor + onLen
                if fresh.location != NSNotFound, fresh.location > expected {
                    // selToClear (if any) was captured against the OLD anchor — a
                    // shift here moves `start` below but NOT the selection's own
                    // extent, so a pending selection at this exact moment is the
                    // scenario the 2026-08-06 "bôi đen … viết thêm thay vì replace"
                    // report needs to distinguish (see the word-start log).
                    DebugLog.log("re-anchor \(id ?? "?"): stale word-start caret, +\(fresh.location - expected)"
                        + (selToClear > 0 ? " (pending selToClear=\(selToClear))" : ""))
                    anchor += fresh.location - expected
                }
            }
            start = anchor + onLen - bs
            clear = selToClear
            selToClear = 0
            logDecision("applyInPlace \(id ?? "?"): start=\(start) bs=\(bs) insLen=\((insert as NSString).length) clear=\(clear) anchor=\(anchor) onLen=\(onLen)")
            if clear > 0 {
                DebugLog.log("selection fold \(id ?? "?"): range=(\(start),\(bs + clear)) bs=\(bs) clear=\(clear)")
            }
        } else {
            let sel = client.selectedRange()
            guard sel.location != NSNotFound, sel.location >= bs else {
                // The key is consumed with NOTHING inserted — if an app lands here on
                // every keystroke, typing shows nothing at all. Log it loudly.
                DebugLog.log("in-place ABORT \(id ?? "?"): selectedRange=\(sel.location == NSNotFound ? "NotFound" : String(sel.location)) bs=\(bs) → marked next word, key swallowed")
                inPlaceFailedHard(id); return
            }
            start = sel.location - bs
        }
        guard start >= 0 else {
            DebugLog.log("in-place ABORT \(id ?? "?"): start=\(start) < 0, key swallowed")
            inPlaceFailedHard(id); return
        }
        client.insertText(insert, replacementRange: NSRange(location: start, length: bs + clear))
        onLen += (insert as NSString).length - bs

        // Probe ONLY on a real, clean replacement (bs > 0, no pending selection).
        // A pure insert (bs == 0) lands identically whether or not the app honors
        // replacementRange, so it must never CONFIRM "in-place good" — that premature
        // confirm on a plain insert was the false-positive that locked iTerm2/WhatsApp
        // onto the broken in-place path. Only a replace distinguishes the two.
        let realProbe = InPlaceProbe.shouldProbe(insertLength: (insert as NSString).length,
                                                 bs: bs, clear: clear,
                                                 needsProbe: AppState.shared.needsProbe(id))
        // EXPERIMENT: with debugLogging on, also SHADOW-probe apps that are already
        // classified (or manually pinned to in-place) — same reads, same logs, but the
        // verdict is never acted on. This is how the deferred re-probe can be exercised
        // against Lark (pin it to In-place in Thử Nghiệm → App mode, enable Debug
        // logging, type a few tone edits, copy the log).
        // Per-focus VERIFY of a learned-in-place app: the first real replacement in
        // each focus re-checks that THIS field honors replacementRange (sites inside
        // one browser differ — see fieldVerified). Passive on good fields (read-only
        // probe of an edit that already happened); a failure demotes this focus to
        // marked text. This is NOT the removed 2026-07-21 session-field probation:
        // unknown apps aren't re-probed per focus — only apps already classified
        // in-place-good get a read-back check, so good fields never glitch.
        let verifyProbe = !realProbe && !fieldVerified
            && AppState.shared.isLearnedInPlace(id)
            && InPlaceProbe.shouldProbe(insertLength: (insert as NSString).length,
                                        bs: bs, clear: clear, needsProbe: true)
        // Throttled: the shadow probe costs an IMK read-back + an AX read PER EDIT, i.e.
        // per diacritic key. Unthrottled it made typing feel slow for every tester who
        // turned Debug logging on (issue #28, 2026-07-27) — and a sample every
        // `shadowProbeInterval` carries the same diagnostic signal.
        let shadowDue = Date.timeIntervalSinceReferenceDate - lastShadowProbe >= Self.shadowProbeInterval
        let shadowProbe = !realProbe && !verifyProbe && AppState.shared.debugLogging && shadowDue
            && InPlaceProbe.shouldProbe(insertLength: (insert as NSString).length,
                                        bs: bs, clear: clear, needsProbe: true)
        if shadowProbe { lastShadowProbe = Date.timeIntervalSinceReferenceDate }
        if realProbe || verifyProbe || shadowProbe {
            probeInPlace(inserted: insert, start: start, bs: bs, client,
                         kind: realProbe ? .real : (verifyProbe ? .verify : .shadow))
        }
    }


    // MARK: - Async-apply clients (WhatsApp)

    /// Upper bound on one catch-up wait. A fast typist's key gap is ~80–150 ms; the
    /// app normally settles within a few ms of its run loop turning over.
    static let catchUpBudgetNs: UInt64 = 40_000_000
    /// After this many CONSECUTIVE budget-exhausting waits the client is evidently
    /// not going to report a caret we can wait on (or is wedged) — stop paying the
    /// budget on every rewrite until it catches up once or focus changes.
    static let catchUpMaxTimeouts = 3

    #if DEBUG
    /// Test seam: called between catch-up polls INSTEAD of sleeping — the harness's
    /// async client applies its queued edits here (= its run loop turning over).
    static var _testCatchUpSettleHook: (() -> Void)?
    #endif

    /// Plain letter inserts go to the client's own caret (kNoRange), never to our
    /// tracked offset — async-apply clients only (see the .passthrough branch).
    static func insertsAtCaret(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return AppState.asyncApplyApps.contains(id)
    }

    /// Should a rewrite wait for this client to apply our pending edits first?
    static func shouldAwaitCatchUp(bundleID: String?, consecutiveTimeouts: Int) -> Bool {
        guard let id = bundleID, AppState.asyncApplyApps.contains(id) else { return false }
        return consecutiveTimeouts < catchUpMaxTimeouts
    }

    /// Poll the client's caret until it reaches `expected` (the end of what we have
    /// composed) or the budget runs out, calling `settle` between polls. A missing
    /// caret (NotFound) is no witness to wait on — returns at once, caughtUp=true,
    /// and the caller's own checks decide.
    ///
    /// `requireStable`: the word's anchor is still the word-start read, which can be
    /// STALE-SMALL on these clients (taken while the previous word/space was still
    /// pending) — then `expected` is too small and "caret ≥ expected" can fire while
    /// the app is half-way through its queue. Also demand the same caret on two
    /// consecutive polls (one settle apart) so the re-anchor read sees the settled
    /// end. If the budget runs out after reaching `expected` but before a stable
    /// pair, that still counts as caught up (no worse than not waiting).
    /// Pure (all I/O injected) so the loop's exits are pinned by tests.
    static func awaitClientCatchUp(expected: Int, budgetNs: UInt64, requireStable: Bool = false,
                                   readCaret: () -> Int?, settle: () -> Void,
                                   now: () -> UInt64) -> (caughtUp: Bool, polls: Int, caret: Int?) {
        let deadline = now() &+ budgetNs
        var polls = 0
        var previous: Int?
        while true {
            polls += 1
            guard let caret = readCaret() else { return (true, polls, nil) }
            if caret >= expected, !requireStable || caret == previous { return (true, polls, caret) }
            if now() >= deadline { return (caret >= expected, polls, caret) }
            previous = caret
            settle()
        }
    }

    /// Wait (bounded) for an async-apply client to catch up with our tracked window.
    /// No-op (true) for every other client. Returns false when the budget ran out
    /// with the client still behind.
    @discardableResult
    private func awaitAsyncClient(_ client: IMKTextInput, expected: Int, why: String) -> Bool {
        let id = AppState.shared.currentBundleID
        guard Self.shouldAwaitCatchUp(bundleID: id, consecutiveTimeouts: catchUpTimeouts) else { return true }
        let r = Self.awaitClientCatchUp(
            expected: expected, budgetNs: Self.catchUpBudgetNs, requireStable: !anchorVerified,
            readCaret: {
                let s = client.selectedRange()
                return s.location == NSNotFound ? nil : s.location
            },
            settle: {
                #if DEBUG
                if let hook = Self._testCatchUpSettleHook { hook(); return }
                #endif
                usleep(1000)
            },
            now: { DispatchTime.now().uptimeNanoseconds })
        if r.caughtUp {
            catchUpTimeouts = 0
            if r.polls > 1 { logDecision("async catch-up \(why) \(id ?? "?"): polls=\(r.polls) expected=\(expected)") }
        } else {
            catchUpTimeouts += 1
            DebugLog.log("async catch-up TIMEOUT \(why) \(id ?? "?"): caret=\(r.caret.map(String.init) ?? "NotFound") "
                + "expected=\(expected) polls=\(r.polls) strike=\(catchUpTimeouts)")
        }
        return r.caughtUp
    }

    /// EndWordSignal (#156, MAIN): app khác báo "kết thúc từ" — kết thúc cụm đang soạn
    /// của controller đang activate như một ranh giới KHÔNG phát gì (không nở gõ tắt,
    /// không khôi phục tiếng Anh). In-place/tap: chữ đã nằm trong ô, chỉ quên. Marked:
    /// chốt đúng chữ đang gạch chân (endComposition) — bỏ qua thì lần setMarkedText sau
    /// sẽ thay mất nó. Engine rỗng ⇒ không làm gì.
    static func endWordFromSignal() {
        guard let c = activeController, !c.engine.isEmpty || c.engine.canReopenLastCommit else { return }
        if !c.engine.isEmpty, let client = c.client() as? IMKTextInput { c.endComposition(client) }
        c.dropComposition(cause: "endWord-signal")
    }

    /// Drop the composition, LOGGING the cause when it wasn't empty. A silent mid-word
    /// drop is what turns a VNI word into its raw tail: the tone DIGIT then lands on an
    /// empty engine, where it has no vowel to mark and stays literal ("d9o65" → "đô5",
    /// report issue #28 2026-07-27). Telex hides the same fault better (a stray "s"),
    /// so the causes were never worth naming before — now they are.
    private func dropComposition(cause: String, keepShortcutTail: Bool = false) {
        wordGluedToDigit = false
        autoCappedWord = false; suppressAutoCap = false; lastEmDashOurs = false; periodSpaceNs = 0
        if !keepShortcutTail { shortcutTail.reset() }
        if !engine.isEmpty {
            DebugLog.log("composition dropped mid-word (cause=\(cause)) len=\((engine.composed as NSString).length)")
        }
        engine.reset()
        tracking = false
        edgeTapWord = false
        edgeEchoBackspaces = 0
        edgeEchoChunks = []
    }

    /// Book an edge burst's echo budget (see edgeEchoBackspaces/Chunks).
    private func noteEdgeBurst(_ posted: (backspaces: Int, chunks: [String])) {
        edgeEchoBackspaces += posted.backspaces
        edgeEchoChunks.append(contentsOf: posted.chunks)
        edgeEchoStampNs = DispatchTime.now().uptimeNanoseconds
        logDecision("edge-burst booked: bs=\(edgeEchoBackspaces) chunks=\(edgeEchoChunks.count)")
    }

    /// In-place aborted before inserting anything (bogus selectedRange): condemn the
    /// app to marked text (persisted) and abandon the composition.
    private func inPlaceFailedHard(_ id: String?) {
        AppState.shared.markUsesMarkedText(id)
        dropComposition(cause: "in-place-failed-hard")
    }

    /// After a real in-place REPLACE into an unknown app, verify the old characters
    /// were actually replaced (not appended). Read back the region we targeted,
    /// `[start, start+len)`: a compliant app now holds `inserted` there; an app that
    /// ignored `replacementRange` (Terminal, iTerm2's CJK IMKit path, Catalyst) still
    /// holds the OLD characters. Because the engine strips the common prefix, the
    /// first char of `inserted` is guaranteed to differ from the old char at `start`,
    /// so this discriminates even on a 1-char window — unlike the old probe, which
    /// read back the text before the CARET (present in BOTH cases → false-positive).
    /// A failure switches the app to marked-text mode.
    /// Serial queue for the probe's Accessibility ground-truth read. The AX call has
    /// a 50ms messaging timeout — running it synchronously inside probeInPlace put a
    /// potential 50ms stall on the keystroke that probes a new app. The verdict only
    /// affects FUTURE keystrokes, so the read is inherently deferrable. Deferring is
    /// also MORE accurate: Chromium-class apps build their AX tree lazily/async, so a
    /// T+0 read races a stale cache (measured — the Lark experiment) while a read a
    /// beat later sees the settled tree.
    private static let axProbeQueue = DispatchQueue(label: "com.viettelex.ax-probe", qos: .userInitiated)

    /// How a probe's verdict is applied: `.real` classifies the app (persisted),
    /// `.shadow` only logs (debugLogging experiment).
    enum ProbeKind { case real, verify, shadow }

    /// TRUE while handle() is committing because of a BOUNDARY key (Return/Enter/
    /// Tab/Escape). Main-thread confined (only handle() touches it).
    private var boundaryCommitInFlight = false

    /// A verify probe fired by a boundary commit is evidence-free: Enter typically
    /// SENDS the message and the app clears the field, so the async caret/region
    /// read describes the reset field, not our edit — the tester log 2026-08-04
    /// shows every "appended twice → marked" demotion taking its deciding strike
    /// from a probe ~1ms after Enter ("Enter 2 lần mới gửi được" class). Downgrade
    /// those to shadow (log-only, no strikes, no classification). Pure so the rule
    /// is pinned by tests.
    static func effectiveProbeKind(_ kind: ProbeKind, boundaryCommit: Bool) -> ProbeKind {
        (kind == .verify && boundaryCommit) ? .shadow : kind
    }

    private func probeInPlace(inserted: String, start: Int, bs: Int, _ client: IMKTextInput,
                              kind rawKind: ProbeKind) {
        let kind = Self.effectiveProbeKind(rawKind, boundaryCommit: boundaryCommitInFlight)
        if kind != rawKind { logDecision("probe: boundary commit → verify downgraded to shadow") }
        let len = (inserted as NSString).length
        // Primary signal: the post-edit caret (hard for an app to fake — it needs it
        // to place its candidate window). Fallback: the target-region read-back, used
        // only when the caret is unavailable (some apps echo it, so it must never
        // override a caret that says "appended").
        let sel = client.selectedRange()
        let caret: Int? = sel.location == NSNotFound ? nil : sel.location
        var region: String? = nil
        if start >= 0, let sub = client.attributedSubstring(from: NSRange(location: start, length: len)) {
            region = sub.string
        }
        // PRELIMINARY verdict from the self-reported signals only. The Accessibility
        // ground-truth read happens ASYNC below and can override this verdict when it
        // lands (axProbeQueue doc above) — it never blocks the keystroke.
        let verdict = InPlaceProbe.verdict(axRegion: nil, caret: caret, start: start, bs: bs,
                                           insertLength: len, regionReadback: region,
                                           inserted: inserted)
        // Structural diagnostics only — never the typed text itself. `regionMatch`
        // is a bool (did the read-back equal what we inserted), not the content.
        DebugLog.log("probe\(kind == .shadow ? "(shadow)" : (kind == .verify ? "(verify)" : "")) \(AppState.shared.currentBundleID ?? "?"): "
            + "start=\(start) bs=\(bs) len=\(len) "
            + "caret=\(caret.map(String.init) ?? "none") expReplace=\(start + len) expAppend=\(start + bs + len) "
            + "regionMatch=\(region.map { $0 == inserted ? "yes" : "no" } ?? "nil") → \(verdict)")
        let id = AppState.shared.currentBundleID
        // EXPERIMENT: arm the deferred re-read for the next keyDown (debugLogging only —
        // the extra AX calls must never run on a stock hot path).
        if AppState.shared.debugLogging {
            pendingReprobe = (id, start, len, bs, inserted, verdict)
        }

        // Async ground-truth read. Fired for shadow probes too (log-only there).
        // MANUAL In-place pin: skip every AX follow-up. The verdict can't be used
        // (a pin is never demoted), and the read itself is the suspect in the
        // Discord "mất focus giữa lúc gõ" report 07/08 — touching the AX tree of
        // an Electron app nudges Chromium's accessibility mode, which can blur/
        // re-render the composer. IMK self-report probes (XPC) stay for the
        // debug-log picture; only the AX churn goes.
        if AppState.shared.manualMode(AppState.shared.currentBundleID) == .inPlace { return }
        Self.axProbeQueue.async { [weak self] in
            let axRegion = AXTextEdit.readString(at: start, length: len)
            guard axRegion != nil else { return }   // AX unavailable → preliminary stands
            DispatchQueue.main.async {
                self?.applyAXVerdict(axRegion: axRegion, inserted: inserted, id: id, kind: kind)
            }
        }

        switch kind {
        case .shadow:
            // Data-gathering only: log + arm the re-read, never touch the
            // classification or the engine.
            return
        case .verify:
            // TWO consecutive appended verdicts before demoting (tester log #4:
            // Chrome's attributedSubstring right after insertText can be STALE —
            // regionMatch=no with an HONEST caret — and the one-shot demote reset
            // the engine mid-word, turning "lỗi lệch" into "lôxi lêjch"). A first
            // strike keeps fieldVerified=false so the NEXT replace re-probes; an
            // honored read or an AX exoneration clears the strike.
            switch verdict {
            case .appended:
                fieldVerifyStrikes += 1
                if fieldVerifyStrikes >= 2 {
                    fieldVerified = true
                    fieldForcedMarked = true
                    DebugLog.log("verify: appended twice → marked text for this focus")
                    dropComposition(cause: "verify-appended")
                } else {
                    DebugLog.log("verify: appended (strike 1/2) — will re-probe next replace")
                }
            case .inconclusive:
                // The caret landed BEFORE our anchor — impossible for either outcome, so
                // the app is self-reporting garbage (see InPlaceProbe.verdict). No strike,
                // no promotion: leave the field unverified so the next replace probes
                // again, and let the async AX read settle it if it can. Bound it though —
                // a field that never produces real evidence still has to end up somewhere
                // safe, so after `maxInconclusive` of them fall back to marked text.
                fieldInconclusive += 1
                if fieldInconclusive >= Self.maxInconclusive {
                    fieldVerified = true
                    fieldForcedMarked = true
                    DebugLog.log("verify: \(fieldInconclusive)× stale self-report → marked text for this focus")
                    dropComposition(cause: "verify-impossible-caret")
                } else {
                    DebugLog.log("verify: stale self-report (caret lags the edit) — no verdict "
                        + "(\(fieldInconclusive)/\(Self.maxInconclusive)), will re-probe")
                }
            case .honored:
                fieldVerifyStrikes = 0
                fieldInconclusive = 0
                fieldVerified = true
            }
        case .real:
            applyPreliminaryVerdict(verdict, id: id, expReplace: start + len)
        }
    }

    /// Classification from the SELF-REPORTED signals (caret / read-back) — the part
    /// that must never lock an app in on thin evidence. Honored commits only after two
    /// confirmations at DISTINCT offsets (Lark's constant garbage caret reads honored
    /// whenever expReplace coincides with it — see InPlaceProbe.HonorTracker); appended
    /// needs two in a row (a single failure may just be the app being busy).
    private func applyPreliminaryVerdict(_ verdict: InPlaceProbe.Verdict, id: String?, expReplace: Int) {
        switch verdict {
        case .inconclusive:
            // Impossible self-report (caret before the anchor): classify NOTHING. The app
            // keeps `needsProbe`, so the next real replace probes again; the async AX read
            // may also land and decide. Never persist a mode on garbage.
            DebugLog.log("probe: stale self-report (caret lags the edit) → no classification, keep probing")
            return
        case .honored:
            if let id {
                var tracker = probeHonors[id] ?? InPlaceProbe.HonorTracker()
                if tracker.recordHonored(expReplace: expReplace) {
                    AppState.shared.markInPlaceGood(id)
                    probeHonors[id] = nil
                } else {
                    probeHonors[id] = tracker   // keep probing until a distinct offset confirms
                }
                probeFailures[id] = nil         // a good read clears the streak
            }
        case .appended:
            // A failure also voids any half-collected honored confirmation: the next
            // honored (if any) must start the two-distinct-offsets count over.
            if let id {
                probeHonors[id] = nil
                let n = (probeFailures[id] ?? 0) + 1
                if n >= 2 {
                    probeFailures[id] = nil
                    AppState.shared.markUsesMarkedText(id)
                } else {
                    probeFailures[id] = n
                }
            } else {
                AppState.shared.markUsesMarkedText(id)
            }
            dropComposition(cause: "probe-appended")
        }
    }

    /// The deferred Accessibility ground truth landed (main thread). It is
    /// authoritative: it reports the field's REAL content independent of the app's
    /// IMKit self-report, and it read the tree after it settled. It overrides whatever
    /// the preliminary verdict did — including un-committing an in-place promotion.
    private func applyAXVerdict(axRegion: String?, inserted: String, id: String?, kind: ProbeKind) {
        let match = axRegion == inserted
        DebugLog.log("probe(ax\(kind == .shadow ? "·shadow" : (kind == .verify ? "·verify" : ""))) \(id ?? "?"): axMatch=\(match ? "yes" : "no")")
        guard kind != .shadow else { return }
        if kind == .verify {
            // axMatch=YES is strong evidence (the tree holds exactly what we
            // inserted — a stale cache would still show the OLD text): clear the
            // strikes and, if the self-report already demoted this focus, undo it
            // (only between words — never flip modes mid-composition).
            // axMatch=NO stays LOG ONLY: Chromium serves AX from an async cache and
            // a stale read false-alarms (the Lark lesson; acting on it demoted
            // healthy fields mid-word).
            if match {
                fieldVerifyStrikes = 0
                fieldInconclusive = 0
                fieldVerified = true
                if fieldForcedMarked, engine.isEmpty, AppState.shared.currentBundleID == id {
                    fieldForcedMarked = false
                    DebugLog.log("verify(ax): replace landed — exonerated, back to in-place for this focus")
                }
            }
            return
        }
        if match {
            AppState.shared.markInPlaceGood(id)
            if let id { probeFailures[id] = nil; probeHonors[id] = nil }
        } else {
            AppState.shared.unmarkInPlaceGood(id)   // reverse a self-report-based commit
            AppState.shared.markUsesMarkedText(id)
            if let id { probeFailures[id] = nil; probeHonors[id] = nil }
            // Abandon the composition ONLY if the user is still in the condemned app —
            // by the time the read lands, focus (and the engine) may belong elsewhere.
            if AppState.shared.currentBundleID == id {
                dropComposition(cause: "probe-ax-appended")
            }
        }
    }

    /// EXPERIMENT (log-only): re-read the previous probe's target region on the NEXT
    /// keyDown — after the app's (possibly lazily-built, async) AX tree has settled —
    /// and log whether each signal now agrees with the t0 verdict. Three outcomes we
    /// are looking for on Lark (pinned to In-place + Debug logging on):
    ///   • axMatch2=no while t0 said honored → the t0 AX read raced a stale cache;
    ///     a deferred verdict WOULD auto-detect Lark (no hardcode needed).
    ///   • axMatch2=yes → Lark's AX genuinely reports the inserted text; per-app /
    ///     per-framework pinning stays the only option.
    ///   • axMatch2=nil → AX unavailable until a real AT connects; same conclusion.
    /// `axLen` is the content-independent cross-check: append leaves the field
    /// longer than a replace by `bs` per edit. Logs carry match booleans and lengths
    /// only — never the typed text.
    private func reprobeDeferred(_ p: (id: String?, start: Int, len: Int, bs: Int,
                                       inserted: String, verdict: InPlaceProbe.Verdict),
                                 _ client: IMKTextInput) {
        let nowID = AppState.shared.currentBundleID ?? FrontmostApp.shared.bundleID
        guard nowID == p.id else {
            DebugLog.log("reprobe \(p.id ?? "?"): skipped (focus now \(nowID ?? "?"))")
            return
        }
        // The IMK reads must stay on the main thread; the AX ones must NOT run here.
        // Each AXTextEdit call can block for its 50ms messaging timeout, and this runs
        // INSIDE handle() on the key right after every diacritic edit — a log-only
        // experiment was stalling real typing whenever a tester enabled Debug logging
        // ("gõ đến ký tự có dấu bị chậm", issue #28 2026-07-27). Read AX on the probe
        // queue and log from there; the verdict was never acted on anyway.
        var imk2: String? = nil
        if let sub = client.attributedSubstring(from: NSRange(location: p.start, length: p.len)) {
            imk2 = sub.string
        }
        let sel = client.selectedRange()
        // Pin In-place: no AX touches (see the probeInPlace gate) — log the IMK
        // half only, from here, without the probe-queue AX round trip.
        if AppState.shared.manualMode(AppState.shared.currentBundleID) == .inPlace {
            DebugLog.log("reprobe \(p.id ?? "?"): t0=\(p.verdict) start=\(p.start) bs=\(p.bs) len=\(p.len) "
                + "ax=skipped(pin) imkMatch2=\(imk2.map { $0 == p.inserted ? "yes" : "no" } ?? "nil") "
                + "caret2=\(sel.location == NSNotFound ? "none" : String(sel.location))")
            return
        }
        Self.axProbeQueue.async {
            let ax2 = AXTextEdit.readString(at: p.start, length: p.len)
            let axLen = AXTextEdit.readLength()
            DebugLog.log("reprobe \(p.id ?? "?"): t0=\(p.verdict) start=\(p.start) bs=\(p.bs) len=\(p.len) "
                + "axMatch2=\(ax2.map { $0 == p.inserted ? "yes" : "no" } ?? "nil") "
                + "imkMatch2=\(imk2.map { $0 == p.inserted ? "yes" : "no" } ?? "nil") "
                + "axLen=\(axLen.map(String.init) ?? "nil") "
                + "caret2=\(sel.location == NSNotFound ? "none" : String(sel.location))")
        }
    }

    // MARK: - Marked-text mode (fallback for Terminal-like apps)

    /// Show the composed syllable as marked text, caret at the end. Reliable in apps
    /// that ignore in-place replacementRange; shows a brief underline while composing.
    /// Near-invisible underline colour — allocated ONCE (was a new NSColor per marked key).
    static let markedUnderlineColor = NSColor(calibratedWhite: 0, alpha: 0.004)
    /// Attributes for the marked span (see the formula notes in updateMarked). Pure.
    static func markedTextAttributes(base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attrs = base
        attrs[.underlineStyle] = 1
        attrs[.underlineColor] = markedUnderlineColor
        return attrs
    }

    private func updateMarked(_ client: IMKTextInput) {
        let s = engine.composed
        let caret = NSRange(location: (s as NSString).length, length: 0)
        // EXPERIMENT 3 — background instead of underline? TSM styles 6 (BlockFill)
        // and 8 (SelectedText) are BACKGROUND hilite styles; their mark(forStyle:)
        // dicts may carry more than style 9's bare clause segment. Log every style's
        // dict once, render with BlockFill.
        let len = (s as NSString).length
        let range = NSRange(location: 0, length: len)
        if AppState.shared.debugLogging, !Self.dumpedHiliteDicts {
            Self.dumpedHiliteDicts = true
            for style in 2...9 {
                let d = mark(forStyle: style, at: range) as? [NSAttributedString.Key: Any] ?? [:]
                DebugLog.log("markForStyle(\(style)) dict: \(d)")
            }
        }
        // Near-invisible composition underline — SHIPPED (field-accepted 2026-07-21).
        // The formula, derived the hard way: a VALID underline style (1 = thin) so
        // clients honor the span at all — style 0 reads as "unspecified" and falls
        // back to the default black underline (why every earlier attempt failed) —
        // plus a near-invisible color: alpha ≈ 1/255, NOT fully clear (Chromium
        // treats pure transparent as "use the text color"). Attribute transport was
        // proven by field-testing style 5 → visibly thicker underline. Base dict
        // from mark(forStyle:) keeps the clause segment the transport expects.
        // (No Excel special case: Excel paints its own thick composition underline
        // and ignores every attribute variant — field-tested exhaustively 2026-07-21.
        // Its clean path is empty-reset tap, i.e. real characters, not marked text.)
        let base = mark(forStyle: 2 /* kTSMHiliteRawText */, at: range)
            as? [NSAttributedString.Key: Any] ?? [:]
        let attributed = NSAttributedString(string: s, attributes: Self.markedTextAttributes(base: base))
        client.setMarkedText(attributed, selectionRange: caret, replacementRange: kNoRange)
        DebugLog.log("setMarked \(AppState.shared.currentBundleID ?? "?"): len=\((s as NSString).length)")
    }

    // MARK: - Word boundary (shortcuts + auto-restore), then reset

    /// Commit the pending word AND fully tear down the IME composition session
    /// before a shortcut is forwarded. In marked-text apps (Electron/Claude) a
    /// still-open composition swallows ⌘-shortcuts — ⌘A "select all" did nothing
    /// while a word was composing. Clearing the marked text explicitly after the
    /// commit ends the session so the shortcut reaches the app.
    /// A modifier combo (⌘A, ⌃…) arrived mid-word:
    /// drop the composition with NO auto-restore and NO shortcut expansion —
    /// leave the word EXACTLY as composed — then let the shortcut key pass through.
    /// In-place text is already on screen (we insert every key), so a reset suffices;
    /// marked text isn't real yet, so finalize it to the composed word first.
    private func endComposition(_ client: IMKTextInput) {
        if !engine.isEmpty { shortcutTail.append(engine.composed) }   // chữ ở lại màn hình
        if !engine.isEmpty, usesMarkedNow(AppState.shared.currentBundleID) {
            client.insertText(engine.composed, replacementRange: kNoRange)
            client.setMarkedText("", selectionRange: kNoRange, replacementRange: kNoRange)
        }
        engine.reset()
        tracking = false
        onLen = 0
    }

    /// Tear the composition down WITHOUT any rewrite, insertText, or setMarkedText —
    /// used at boundaries where touching the client is unsafe (secure input, remote
    /// desktop): the anchor may belong to a previous field and the target window must
    /// not receive injected text. Unlike endComposition this never finalizes marked
    /// text (no insertText(composed)); unlike boundary it never expands shortcuts or
    /// auto-restores. Whatever was already on screen stays as-is; the engine forgets it.
    private func discardComposition() {
        shortcutTail.reset()
        engine.reset()
        tracking = false
        onLen = 0
        wordGluedToDigit = false   // #82: từ bị bỏ giữa đường, ngữ cảnh "dính số" hết hiệu lực
    }

    @discardableResult
    /// EDGE-TAP eligibility, decided once per word at its first key. Pure — pinned
    /// by EdgeTapTests. Manual In-place pin ONLY (built-in in-place apps honor
    /// offset-0; the pin is the user's escape hatch on web editors where offset-0
    /// replacementRange gets APPENDED — "cos" → "coó" at message start). Untrusted
    /// can't post synthetic keys, so the word falls back to plain in-place.
    ///
    /// caret <= 1, not == 0: an EMPTY Slate box (Discord) reports caret=1 — the
    /// empty block holds a phantom placeholder the caret sits "after", removed
    /// once text lands (measured 06/08: empty box word-start caret=1 twice, but
    /// the word after "abc " starts at 4, not 5 ⇒ the 1 was a lie and text really
    /// occupies 0…). A GENUINE offset-1 word start (one leading char, no space) is
    /// rare, and the synthetic channel is position-independent — correct there
    /// too, at worst a flicker.
    static func edgeTapEligible(manualInPlace: Bool, caret: Int?, trusted: Bool) -> Bool {
        guard let caret else { return false }
        return manualInPlace && trusted && caret <= 1
    }

    private func boundary(_ client: IMKTextInput, suppressAutoRestore: Bool = false,
                          allowShortcuts: Bool = true, allowTokenShortcuts: Bool = false,
                          allowAlnumShortcuts: Bool = false,
                          commitSuffix: String = "", boundaryKey: Character? = nil) -> Bool {
        let wasEdge = edgeTapWord
        expandedAtBoundary = nil
        lastCommitRaw = ""
        lastCommitWord = ""
        defer { tracking = false; onLen = 0; edgeTapWord = false }
        let id = AppState.shared.currentBundleID
        let marked = usesMarkedNow(id)
        // Khoá ký hiệu/số (khoảng trắng/Enter) hoặc khoá chữ+số (#109: cả dấu câu).
        let anyToken = allowTokenShortcuts || allowAlnumShortcuts
        let table = (allowShortcuts || anyToken) ? AppState.shared.shortcutTable : ShortcutTable()
        guard !engine.isEmpty else {
            engine.reset()
            // Khoá ký hiệu/số trên chữ ĐÃ chốt ("->", "√√", "k2", "ad1"): không có từ đang soạn.
            if anyToken, !marked, table.hasTokenKeys,
               tryTokenShortcut(table: table, composed: "", allowToken: allowTokenShortcuts,
                                allowAlnum: allowAlnumShortcuts, client, id: id) {
                return true
            }
            return false
        }
        let word = engine.composed
        // Raw keystrokes must be read BEFORE engine.reset() clears them. A shortcut key
        // that contains Telex triggers (s f r x j w, doubled vowels) never survives
        // composition — "vn"→"vn" but "cf" composes away — so a shortcut whose key IS
        // the raw form could never match on `word` alone.
        let rawWord = engine.rawKeystrokes
        let onScreen = word.unicodeScalars.count

        // Shortcut expansion (bảng gõ tắt) takes precedence over the composed word.
        // Try the composed word first, then fall back to the raw keystrokes so a
        // shortcut key containing trigger letters still matches; case follows the
        // typing (ko → không, Ko → Không, KO → KHÔNG — ShortcutTable.expansion).
        // On-screen backspace count stays `onScreen` (the composed scalar count).
        // Khoá trùng Text Replacements của macOS ở app họ Chromium ⇒ để macOS nở (#117).
        if allowShortcuts, let expansion = table.wordExpansion(composed: word, raw: rawWord),
           !SystemReplacementGuard.shared.shouldDefer(onScreen: word, bundleID: id) {
            engine.reset()
            if marked { client.insertText(expansion + commitSuffix, replacementRange: kNoRange) }
            else if wasEdge { noteEdgeBurst(SyntheticKeyboard.applyForEdge(backspaces: onScreen, insert: expansion)) }
            else { applyInPlace(bs: onScreen, insert: expansion, client) }
            shortcutTail.append(expansion + (marked ? commitSuffix : ""))
            expandedAtBoundary = (word, expansion)
            return true
        }
        // Khoá ký hiệu/số kết thúc bằng từ đang soạn (":D", "1tr" = "1" đã chốt + "tr"):
        // chỉ in-place (chữ đang soạn đã thật trên màn hình), không edge.
        if anyToken, !marked, !wasEdge, table.hasTokenKeys,
           tryTokenShortcut(table: table, composed: word, allowToken: allowTokenShortcuts,
                            allowAlnum: allowAlnumShortcuts, client, id: id) {
            return true
        }

        // Auto-restore non-Vietnamese words to their raw keystrokes (resets engine).
        // Suppressed next to brackets (code context).
        let autoRestore = AppState.shared.autoRestore && !suppressAutoRestore
        lastCommitRaw = rawWord
        // The key that ends the word: an apostrophe keeps an English contraction stem ("doesn't").
        let restored = engine.commitText(autoRestore: autoRestore, boundary: boundaryKey)
        lastCommitWord = restored
        if marked {
            // Commit the marked text (replaces it with the final word). Optional
            // suffix is a newline folded in when Return cannot be re-posted.
            client.insertText(restored + commitSuffix, replacementRange: kNoRange)
            shortcutTail.append(restored + commitSuffix)
            return true
        }
        shortcutTail.append(restored)
        if restored != word {
            if wasEdge { noteEdgeBurst(SyntheticKeyboard.applyForEdge(backspaces: onScreen, insert: restored)) }
            else { applyInPlace(bs: onScreen, insert: restored, client) }
            return true
        }
        return false
    }

    /// Khoá ký hiệu/số ("->" → "→"): cụm = phần đã chốt liền trước (shortcutTail) +
    /// `composed` (từ đang soạn, đã nằm trên màn hình ở in-place). Cụm khớp khoá thì
    /// ĐỌC LẠI màn hình (một lần, chỉ lúc này) và chỉ thay khi chữ ngay trước con trỏ
    /// đúng là cụm đó và cụm đứng riêng (đầu ô / sau khoảng trắng) — "a->b" hay một
    /// cụm mình dựng sai đều không đụng. Chỉ in-place: app marked không bảo đảm tôn
    /// trọng replacementRange trên chữ đã chốt. Trả true = đã thay (engine đã reset).
    private func tryTokenShortcut(table: ShortcutTable, composed: String,
                                  allowToken: Bool, allowAlnum: Bool,
                                  _ client: IMKTextInput, id: String?) -> Bool {
        guard case let .token(token, expansion)? = ShortcutMatch.find(
            in: table, composed: composed, raw: composed, run: shortcutTail.run,
            allowWord: false, allowToken: allowToken, allowAlnum: allowAlnum) else { return false }
        if SystemReplacementGuard.shared.shouldDefer(onScreen: token, bundleID: id) { return false }   // #117
        guard Self.replacesCommittedText(id) else {
            DebugLog.log("shortcut token \(id ?? "?"): app not proven in-place → skip")
            return false
        }
        let sel = client.selectedRange()
        guard sel.location != NSNotFound, sel.length == 0,
              let window = ShortcutScreen.readWindow(caret: sel.location, text: token),
              let sub = client.attributedSubstring(from: window),
              let range = ShortcutScreen.tokenRange(caret: sel.location, token: token,
                                                    window: sub.string, windowStart: window.location)
        else {
            DebugLog.log("shortcut token \(id ?? "?"): screen disagrees → skip")
            return false
        }
        // Ô Slate-class ghim In-place: replacementRange ở offset 0 bị APPEND (xem
        // edgeTapEligible) — không đụng, thà để nguyên cụm.
        if AppState.shared.manualMode(id) == .inPlace, range.location <= 1 {
            DebugLog.log("shortcut token \(id ?? "?"): offset \(range.location) in pinned In-place → skip")
            return false
        }
        engine.reset()
        engine.noteExternalWord(english: false)
        client.insertText(expansion, replacementRange: range)
        shortcutTail.replaceRun(with: expansion)
        expandedAtBoundary = (token, expansion)
        logDecision("shortcut token \(id ?? "?"): -\(range.length) +\((expansion as NSString).length)")
        return true
    }

    /// Thay chữ ĐÃ CHỐT bằng insertText(replacementRange) chỉ ở app đã CHỨNG MINH tôn
    /// trọng replacementRange (built-in/learned in-place, hoặc user ghim In-place) —
    /// app chưa phân loại có thể APPEND ("->" thành "->→"). Cùng tinh thần re-edit.
    private static func replacesCommittedText(_ id: String?) -> Bool {
        AppState.shared.isLearnedInPlace(id) || AppState.shared.manualMode(id) == .inPlace
    }

    /// ⌫ ngay sau khi nở: màn hình phải kết thúc ĐÚNG bằng nội dung + ranh giới (đọc
    /// lại) → thay bằng chữ đã gõ + ranh giới. false ⇒ ⌫ thường. Chỉ gọi khi engine
    /// rỗng và không ở marked.
    private func tryUndoShortcut(_ u: ShortcutUndo, _ client: IMKTextInput) -> Bool {
        let id = AppState.shared.currentBundleID
        guard Self.replacesCommittedText(id) else { return false }
        let sel = client.selectedRange()
        guard sel.location != NSNotFound, sel.length == 0,
              let window = ShortcutScreen.readWindow(caret: sel.location, text: u.onScreen),
              let sub = client.attributedSubstring(from: window),
              let range = ShortcutScreen.undoRange(caret: sel.location, undo: u,
                                                   window: sub.string, windowStart: window.location)
        else {
            DebugLog.log("shortcut undo \(id ?? "?"): screen disagrees → plain ⌫")
            return false
        }
        if AppState.shared.manualMode(id) == .inPlace, range.location <= 1 { return false }
        client.insertText(u.restored, replacementRange: range)
        engine.reset()               // cũng xoá re-open snapshot: ⌫ sau đó là ⌫ thường
        tracking = false; onLen = 0
        shortcutTail.reset()
        shortcutTail.append(u.restored)
        logDecision("shortcut undo \(id ?? "?"): -\(range.length) +\((u.restored as NSString).length)")
        return true
    }

    // MARK: - "Tự sửa từ phía trước" (RetroEnglishApply.swift)

    /// Áp phép sửa ngược tiếng Anh đang chờ: chỉ app in-place đã chứng minh (không marked,
    /// không edge, không terminal/app mã nguồn), và chỉ khi văn bản ngay trước con trỏ
    /// đọc lại ĐÚNG `expected` — rồi MỘT insertText(replacementRange), không ⌫. Không xác
    /// nhận được ⇒ bỏ (phép sửa tự hết hạn ở lệnh engine kế tiếp). Trả về phép sửa đã áp.
    private func applyRetroCorrection(marked: Bool, edge: Bool, _ client: IMKTextInput,
                                      id: String?) -> RetroCorrection? {
        guard let c = engine.pendingRetroCorrection else { return nil }
        guard RetroApply.imkChannel(appAllowed: SystemAutoText.appAllowed(id), marked: marked, edge: edge,
                                    replacesCommittedText: Self.replacesCommittedText(id)) == .imkReplace else {
            DebugLog.log("retro english \(id ?? "?"): channel not allowed → skip")
            return nil
        }
        // Hai IPC đồng bộ (selectedRange + attributedSubstring đúng `expected`, không đọc cả
        // văn bản) — đo; vượt ngân sách ⇒ lần sau app này chỉ đề xuất (RetroCost).
        let range: NSRange? = RetroCost.verify(id, "imk-apply") {
            let sel = client.selectedRange()
            return RetroApply.verifiedRange(
                c.expected, caret: sel.location == NSNotFound ? nil : sel.location,
                selectionLength: sel.length,
                read: { client.attributedSubstring(from: $0)?.string })
        }
        guard let range else {
            DebugLog.log("retro english \(id ?? "?"): screen disagrees → skip")
            return nil
        }
        _ = engine.takeRetroCorrection()     // lấy = cam kết áp (lịch sử ghi các từ là tiếng Anh)
        client.insertText(c.insert, replacementRange: range)
        shortcutTail.replaceSuffix(c.expected, with: c.insert)
        logDecision("retro english \(id ?? "?"): \(c.words) word(s) -\(range.length) +\((c.insert as NSString).length)")
        return c
    }

    /// Đề xuất (công tắc tắt, hoặc app đọc chậm): CHỈ kiểm kênh — không IPC nào trước khi
    /// phím ranh giới tới app. Màn hình được xác nhận lúc hiện gợi ý (CaretHint.offerRetro
    /// đọc lại `expected + ranh giới`, 40ms sau, ngoài đường phím) và lần nữa khi Tab áp.
    private func retroOfferAllowed(marked: Bool, edge: Bool, id: String?) -> RetroCorrection? {
        guard let c = engine.pendingRetroCorrection,
              RetroApply.imkChannel(appAllowed: SystemAutoText.appAllowed(id), marked: marked, edge: edge,
                                    replacesCommittedText: Self.replacesCommittedText(id)) == .imkReplace else {
            return nil
        }
        return c
    }

    /// Tab trên đề xuất sửa ngược: đường an toàn như tự áp — kênh còn hợp lệ, đọc lại khớp
    /// ĐÚNG `replace` (gồm ký tự ranh giới) ngay trước con trỏ, rồi MỘT insertText(range).
    private func applyRetroOffer(_ s: CaretSuggestion, _ client: IMKTextInput) {
        let id = AppState.shared.currentBundleID
        guard engine.isEmpty,
              RetroApply.imkChannel(appAllowed: SystemAutoText.appAllowed(id), marked: false, edge: false,
                                    replacesCommittedText: Self.replacesCommittedText(id)) == .imkReplace else {
            DebugLog.log("retro offer \(id ?? "?"): channel not allowed → skip")
            return
        }
        let sel = client.selectedRange()
        guard let range = RetroApply.verifiedRange(
                s.replace, caret: sel.location == NSNotFound ? nil : sel.location, selectionLength: sel.length,
                read: { client.attributedSubstring(from: $0)?.string }) else {
            DebugLog.log("retro offer \(id ?? "?"): screen disagrees → skip")
            return
        }
        // Lịch sử engine ghi các từ là tiếng Anh (chỉ khi phép sửa vẫn là cái đang chờ).
        if engine.pendingRetroCorrection?.expected == s.replace { _ = engine.takeRetroCorrection() }
        client.insertText(s.insert, replacementRange: range)
        shortcutTail.replaceSuffix(s.replace, with: s.insert)
        learn.discard()
        logDecision("retro offer \(id ?? "?"): -\(range.length) +\((s.insert as NSString).length)")
    }

    /// ⌫ ngay sau lần sửa ngược: màn hình phải kết thúc ĐÚNG bằng chữ vừa chèn + ranh giới
    /// (đọc lại) → thay bằng văn bản cũ + ranh giới. false ⇒ ⌫ thường.
    private func tryRetroUndo(_ u: RetroUndo, _ client: IMKTextInput) -> Bool {
        let id = AppState.shared.currentBundleID
        guard Self.replacesCommittedText(id) else { return false }
        let sel = client.selectedRange()
        guard let range = RetroApply.revertRange(
                u, caret: sel.location == NSNotFound ? nil : sel.location, selectionLength: sel.length,
                read: { client.attributedSubstring(from: $0)?.string }) else {
            DebugLog.log("retro undo \(id ?? "?"): screen disagrees → plain ⌫")
            return false
        }
        client.insertText(u.previous, replacementRange: range)
        if u.restore {
            engine.restoreUndoApplied()   // từ vừa chốt lại là chữ Việt: hết mạch tiếng Anh
            DebugLog.noteRestoreUndoUsed()
        } else {
            engine.reset()               // xoá lịch sử sửa ngược + re-open: ⌫ sau đó là ⌫ thường
        }
        tracking = false; onLen = 0
        shortcutTail.replaceSuffix(u.current, with: u.previous)
        logDecision("\(u.restore ? "restore" : "retro") undo \(id ?? "?"): -\(range.length) +\((u.previous as NSString).length)")
        return true
    }

    // MARK: - Thứ tự phím quanh bản re-post Return/Tab (RepostOrder)

    /// Phím thật vượt bản re-post: nuốt và post lại SAU nó (hoặc xếp hàng nếu bản re-post
    /// còn chờ hẹn giờ). false = không post được (không Trợ năng) ⇒ xử lý phím như thường.
    private func holdBehindRepost(_ event: NSEvent) -> Bool {
        guard Accessibility.isTrusted else { repostOrder.reset(); repostHeld = nil; return false }
        let key = CGKeyCode(event.keyCode)
        // Cờ của NSEvent (cùng vị trí bit với CGEventFlags) hợp với cờ CGEvent: một trong hai
        // có thể thiếu Shift tuỳ nguồn sự kiện — mất Shift thì "*" thành "8".
        let nsFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags
            .intersection(.deviceIndependentFlagsMask).rawValue))
        let flags = (event.cgEvent?.flags ?? []).union(nsFlags)
        if repostHeld != nil {
            repostHeld?.append((key, flags))
        } else if !SyntheticKeyboard.postKeyCopy(key, flags: flags) {
            return false
        }
        repostOrder.expect(.userKey(event.keyCode), nowNs: DispatchTime.now().uptimeNanoseconds)
        logDecision("repost-order: key \(event.keyCode) overtook the boundary re-post → re-posted behind it")
        return true
    }

    /// Hẹn giờ re-post (web editor marked) vừa post Return/Tab: giờ mới tới các phím vượt.
    private func flushHeldBehindRepost() {
        let held = repostHeld ?? []
        repostHeld = nil
        for k in held { SyntheticKeyboard.postKeyCopy(k.key, flags: k.flags) }
    }

    // MARK: - Cài đặt Nhập văn bản của macOS (SystemAutoText.swift)

    /// Phím cách thứ hai (dấu chấm khi nhấn đúp) hoặc "-" thứ hai ("--" → "—") khi
    /// engine rỗng. Quyết bằng dòng phím mình đã thấy (không đọc màn hình); chỉ khi sẽ
    /// thay mới đọc lại đúng các ký tự sắp thay, lệch ⇒ phím thường. true = đã thay,
    /// phím bị nuốt.
    private func trySystemReplace(_ space: Bool, prevSpaceNs: UInt64, prevEmDashOurs: Bool,
                                  isRepeat: Bool, _ client: IMKTextInput, id: String?) -> Bool {
        let st = SystemAutoTextSettings.shared.current
        guard space ? st.period : st.dashes else { return false }
        let before = shortcutTail.recent
        var expect: String, replaceLen: Int, insert: String
        if space {
            guard prevSpaceNs > 0 else { return false }
            let gapNs = DispatchTime.now().uptimeNanoseconds &- prevSpaceNs
            var context = before
            // Dòng phím mất (không Trợ năng: commitComposition của AppKit sau dấu cách
            // native vẫn xoá cụm) nhưng phím ngay trước CHẮC là dấu cách mình thấy (dấu
            // thời gian chỉ sống tới phím kế / click) ⇒ đọc vài ký tự trước con trỏ. Chỉ
            // ở phím cách thứ hai trong cửa sổ — không bao giờ ở đường phím thường.
            if context.isEmpty, !isRepeat, gapNs <= SystemAutoText.doubleSpaceWindowNs,
               SystemAutoText.appAllowed(id), Self.replacesCommittedText(id) {
                let sel = client.selectedRange()
                if sel.location != NSNotFound, sel.length == 0, sel.location >= 2 {
                    let n = min(sel.location, 4)
                    context = client.attributedSubstring(from: NSRange(location: sel.location - n, length: n))?.string ?? ""
                }
            }
            guard let prev = SystemAutoText.doubleSpacePeriod(before: context, gapNs: gapNs,
                                                             isRepeat: isRepeat) else { return false }
            expect = String(prev) + " "; replaceLen = 1; insert = ". "
        } else {
            switch SystemAutoText.dash(before: before, lastWasOurEmDash: prevEmDashOurs) {
            case .none: return false
            case .emDash:
                expect = String(before.suffix(2)); replaceLen = 1; insert = "—"
            case .restore:
                expect = "—"; replaceLen = 1; insert = "---"
            }
        }
        guard SystemAutoText.appAllowed(id), Self.replacesCommittedText(id) else { return false }
        let sel = client.selectedRange()
        let n = (expect as NSString).length
        guard sel.location != NSNotFound, sel.length == 0, sel.location >= n,
              let sub = client.attributedSubstring(from: NSRange(location: sel.location - n, length: n)),
              sub.string == expect else {
            DebugLog.log("system auto-text \(id ?? "?"): screen disagrees → plain key")
            return false
        }
        let range = NSRange(location: sel.location - replaceLen, length: replaceLen)
        if AppState.shared.manualMode(id) == .inPlace, range.location <= 1 { return false }
        client.insertText(insert, replacementRange: range)
        shortcutTail.replaceSuffix(String(before.suffix(replaceLen)), with: insert)
        engine.forgetLastCommit()      // ⌫ kế tiếp xoá ký tự vừa chèn, không mở lại từ
        lastEmDashOurs = !space && insert == "—"
        logDecision("system auto-text \(id ?? "?"): \(space ? "period" : "dash") -\(replaceLen) +\(insert.count)")
        return true
    }

    /// Phím " / ' ⇒ ngoặc cong theo kiểu macOS, nil = giữ nguyên phím. Ký tự trước con
    /// trỏ lấy từ dòng phím; không biết thì đọc một ký tự (hiếm: ngay sau click/đổi ô).
    private func smartQuoteText(_ typed: String?, _ client: IMKTextInput, id: String?) -> String? {
        guard let t = typed, t.count == 1, let c = t.first else { return nil }
        let st = SystemAutoTextSettings.shared.current
        guard st.quotes, SystemAutoText.appAllowed(id) else { return nil }
        var prev: Character?
        if Accessibility.isTrusted, let last = shortcutTail.recent.last {
            prev = last
        } else {
            let sel = client.selectedRange()
            guard sel.location != NSNotFound else { return nil }
            if sel.location > 0 {
                guard let sub = client.attributedSubstring(from: NSRange(location: sel.location - 1, length: 1)),
                      let p = sub.string.last else { return nil }
                prev = p
            }
        }
        return SystemAutoText.smartQuote(c, prev: prev, quotes: st.quoteChars)
    }

    /// Chữ đầu từ: viết hoa không (cài đặt macOS "Tự động viết hoa từ"). Ngữ cảnh từ dòng
    /// phím; không biết ⇒ đọc tối đa 24 ký tự trước con trỏ (chỉ chữ đầu tiên sau click /
    /// đổi ô). Đầu văn bản chỉ viết hoa ở ô nhiều dòng (FocusedRole).
    private func shouldAutoCapitalize(caret: Int?, _ client: IMKTextInput, id: String?) -> Bool {
        guard SystemAutoTextSettings.shared.current.capitalize else { return false }
        if suppressAutoCap { suppressAutoCap = false; return false }
        guard SystemAutoText.appAllowed(id) else { return false }
        // Dòng phím chỉ đáng tin khi click được báo về (tap chạy ⇔ có quyền Trợ năng).
        // Sau Return chưa xác nhận ⇒ không biết ⇒ đọc màn hình (SystemAutoText.autoCapKnownText).
        let known = Accessibility.isTrusted ? shortcutTail.autoCapKnownText : nil
        let ctx = SystemAutoText.resolveCapitalization(
            known: known, caret: caret,
            readBefore: { n in
                guard let loc = caret else { return nil }
                return client.attributedSubstring(from: NSRange(location: loc - n, length: n))?.string
            },
            multiline: { FocusedRole.isMultilineText() })
        if AppState.shared.debugLogging {
            let line = "autocap \(id ?? "?"): known=\(known.map { "\($0.count)ch" } ?? "nil") caret=\(caret.map(String.init) ?? "nil") → \(ctx)"
            DebugLog.log(line)
            Signposts.log.notice("\(line, privacy: .public)")
        }
        return ctx == .capitalize
    }

    // MARK: - Gợi ý cạnh con trỏ (CaretHint)

    /// Áp dụng gợi ý đã chọn (Tab/Enter/click). Phép tính: chèn kết quả sau "=". Chip số:
    /// ĐỌC LẠI màn hình — chỉ thay khi chữ ngay trước con trỏ đúng là cụm số + dấu cách và
    /// cụm đứng riêng (như gõ tắt ký hiệu); lệch ⇒ không đụng gì.
    private func applyCaretSuggestion(_ s: CaretSuggestion, _ client: IMKTextInput) {
        if s.kind == .email { applyEmailSuggestion(s, client); return }
        if s.kind == .retro { applyRetroOffer(s, client); return }
        if !engine.isEmpty { endComposition(client) }
        guard !s.replace.isEmpty else {
            client.insertText(s.insert, replacementRange: kNoRange)
            shortcutTail.append(s.insert)
            logDecision("caret hint \(s.kind): insert")
            if s.kind == .predict { afterPredictionApplied(s, client) }
            return
        }
        let id = AppState.shared.currentBundleID
        let sel = client.selectedRange()
        guard Self.replacesCommittedText(id), sel.location != NSNotFound, sel.length == 0,
              let window = ShortcutScreen.readWindow(caret: sel.location, text: s.replace),
              let sub = client.attributedSubstring(from: window),
              let range = ShortcutScreen.tokenRange(caret: sel.location, token: s.replace,
                                                    window: sub.string, windowStart: window.location),
              !(AppState.shared.manualMode(id) == .inPlace && range.location <= 1)
        else {
            DebugLog.log("caret hint \(s.kind) \(id ?? "?"): screen disagrees → skip")
            return
        }
        engine.reset()
        engine.noteExternalWord(english: false)
        client.insertText(s.insert, replacementRange: range)
        shortcutTail.reset()
        shortcutTail.append(s.insert)
        numberPrevRun = ""
        logDecision("caret hint \(s.kind) \(id ?? "?"): -\(range.length) +\((s.insert as NSString).length)")
        switch s.kind {
        case .predict: afterPredictionApplied(s, client)
        case .typo: learn.replacePending(with: s.display)   // học dạng ĐÃ SỬA, không học lỗi gõ
        default: learn.discard()                            // chữ vừa chốt bị thay
        }
    }

    /// Đuôi email (EmailDomainPrediction): chèn NGUYÊN VĂN — không qua engine, không dấu cách, không
    /// học, không mời từ kế tiếp. `replace` rỗng ⇒ chốt từ đang soạn như đang hiện rồi chèn phần
    /// còn thiếu ("user@gm" + "ail.com"); không rỗng ⇒ Telex đã đổi từ đang soạn ("yahô"): ĐỌC LẠI
    /// màn hình, thay đúng từ đó (lệch ⇒ không đụng gì). Engine reset sau đó: chữ gõ tiếp không bị
    /// bỏ dấu ngược vào tên miền, ⌫ không mở lại từ cũ.
    private func applyEmailSuggestion(_ s: CaretSuggestion, _ client: IMKTextInput) {
        let id = AppState.shared.currentBundleID
        if !engine.isEmpty { endComposition(client) }
        if s.replace.isEmpty {
            client.insertText(s.insert, replacementRange: kNoRange)
        } else {
            let sel = client.selectedRange()
            let n = (s.replace as NSString).length
            guard Self.replacesCommittedText(id), sel.location != NSNotFound, sel.length == 0, sel.location > n,
                  client.attributedSubstring(from: NSRange(location: sel.location - n, length: n))?.string == s.replace,
                  !(AppState.shared.manualMode(id) == .inPlace && sel.location - n <= 1)
            else {
                DebugLog.log("caret hint email \(id ?? "?"): screen disagrees → skip")
                return
            }
            client.insertText(s.insert, replacementRange: NSRange(location: sel.location - n, length: n))
            shortcutTail.reset()
        }
        engine.reset()
        engine.resetContext()
        shortcutTail.append(s.insert)
        numberPrevRun = ""
        acceptedSpace = nil
        rawInsertedTail = true
        learn.discard()       // không học phần trước "@" / tên miền
        logDecision("caret hint email \(id ?? "?"): " + (s.replace.isEmpty ? "insert" : "replace -\((s.replace as NSString).length)"))
    }

    /// Chữ vừa chèn khi nhận gợi ý từ ("được ") — sống tới PHÍM KẾ (PredictionLogic.AcceptSpace).
    private var acceptedSpace: String?
    /// Vừa chèn nguyên văn đuôi email — phím KẾ không được re-edit (bỏ dấu ngược) chữ đó.
    private var rawInsertedTail = false
    /// Phím dead key (#161): phím VỪA RỒI là dead key / phím ĐANG xử lý đi ngay sau một
    /// dead key — xem DeadKeyLiteral.
    private var lastKeyWasDead = false
    private var keyFollowsDeadKey = false
    /// Phím ĐANG xử lý là dead key theo layout đang dùng (kể cả khi macOS đưa kèm ký tự
    /// — Spotlight, #161).
    private var keyIsLayoutDead = false
    /// Nhánh vừa nhường phím phải giữ phím THÔ (remote desktop/VM, echo của mình) —
    /// rescue dead key không được chèn. Đặt lại mỗi keyDown.
    private var deadRescueKeepRaw = false
    /// Trạng thái dead key của layout sau ⌥e/⌥u/… (UCKeyTranslate deadKeyState), 0 = không chờ.
    private var optionDeadState: UInt32 = 0
    /// Dấu câu vừa dời dấu cách ra sau ("." + " ") — phím cách kế bị nuốt (không thành 2 dấu cách).
    private var carriedSpace: String?

    /// Phím ngay sau khi nhận gợi ý từ. nil = xử lý phím như thường; true = đã xử lý (nuốt).
    /// ĐỌC LẠI màn hình trước khi gỡ dấu cách (lệch ⇒ không đụng gì).
    private func handleAcceptedSpace(_ event: NSEvent, _ client: IMKTextInput) -> Bool? {
        let inserted = acceptedSpace, carried = carriedSpace
        acceptedSpace = nil; carriedSpace = nil
        guard engine.isEmpty, event.modifierFlags.intersection([.command, .control]).isEmpty,
              let ch = event.characters, ch.count == 1 else { return nil }
        func screenEnds(with tail: String) -> Int? {
            let sel = client.selectedRange()
            let n = (tail as NSString).length
            guard sel.location != NSNotFound, sel.length == 0, sel.location >= n,
                  client.attributedSubstring(from: NSRange(location: sel.location - n, length: n))?.string == tail
            else { return nil }
            return sel.location
        }
        if let c = carried {
            guard ch == " ", screenEnds(with: c) != nil else { return nil }
            logDecision("accept-space: space after carried punctuation swallowed")
            return true
        }
        guard let ins = inserted, let out = PredictionLogic.acceptSpaceReplacement(ch),
              Self.replacesCommittedText(AppState.shared.currentBundleID) else { return nil }
        guard let caret = screenEnds(with: ins) else {
            logDecision("accept-space: screen disagrees → plain key")
            return nil
        }
        client.insertText(out, replacementRange: NSRange(location: caret - 1, length: 1))
        shortcutTail.backspace()
        shortcutTail.append(out)
        engine.reset()
        if out.hasSuffix(" ") { carriedSpace = String(out.prefix(1)) + " " }
        if let e = learn.breakContext() { LearnedWords.shared.record(e, generation: learnGen) }   // dấu câu cắt câu
        logDecision("accept-space: punctuation attached, space " + (out.hasSuffix(" ") ? "moved after it" : "removed"))
        return true
    }

    /// Gợi ý từ vừa áp dụng (từ + dấu cách): ngữ cảnh tiếng Anh theo từ vừa chèn, rồi mời từ
    /// kế tiếp như sau một dấu cách gõ tay.
    private func afterPredictionApplied(_ s: CaretSuggestion, _ client: IMKTextInput) {
        acceptedSpace = s.insert.hasSuffix(" ") ? s.insert : nil
        learnAccepted(s.display)
        // Dấu cách tự thêm tính là dấu cách thứ nhất của "chấm câu nhấn đúp" (cài đặt macOS).
        if acceptedSpace != nil, SystemAutoTextSettings.shared.period { periodSpaceNs = DispatchTime.now().uptimeNanoseconds }
        let w = s.display.lowercased()
        let english = !VNSuggest.contains(w) && TypoFixLogic.isEnglish(w)
        engine.noteExternalWord(w, english: english)
        numberPrevRun = s.display
        if SystemInlinePrediction.isOn {
            CaretHint.shared.schedulePrediction(typed: "", raw: "", english: english, client: client, controller: self)
        }
    }

    // MARK: Học từ bạn gõ (LearnedWords.swift / LearnedModel.swift)

    /// Cổng học — mỗi ranh giới, tắt ⇒ một lần đọc cờ: công tắc "Học từ bạn gõ", cài đặt hệ thống
    /// gợi ý từ, app không phải terminal / trình soạn mã (SystemAutoText.appAllowed). Ô mật khẩu /
    /// Secure Input / app passthrough không bao giờ tới đây (handle() trả sớm, không soạn).
    private func learnGate(_ id: String?) -> Bool {
        CaretHint.shared.flagsSnapshot.learn && SystemInlinePrediction.isOn && SystemAutoText.appAllowed(id)
    }

    /// Thế hệ dữ liệu (Xoá từ đã học) / click (con trỏ có thể dời) đổi ⇒ bỏ / cắt ngữ cảnh.
    private func syncLearnEpoch(ignoreClicks: Bool = false) {
        let g = LearnedWords.shared.generation, c = LearnedWords.shared.clickCount
        if g != learnGen { learn.discard(); learnGen = g }
        if c != learnClicks {
            learnClicks = c
            if !ignoreClicks, let e = learn.breakContext() { LearnedWords.shared.record(e, generation: learnGen) }
        }
    }

    /// Ranh giới (IMK): `word` = từ bộ gõ vừa soạn + chốt ("" = không có / gõ tắt nở — không học
    /// nội dung nở), `boundary` = ký tự vừa chèn (nil = Enter / Tab / Esc / phím không chèn chữ ⇒
    /// cắt ngữ cảnh). Edge (Slate — burst tổng hợp, chữ trên màn hình kém chắc) không học.
    private func learnAtBoundary(word: String, boundary: String?, standsAlone: Bool, id: String?, edge: Bool) {
        guard !edge, learnGate(id) else {
            if learn.pending != nil || learn.prev1 != nil { learn.discard() }
            return
        }
        syncLearnEpoch()
        var out: [LearnTracker.Event] = []
        if let b = boundary {
            if let e = learn.commit(word, boundary: b, standsAlone: standsAlone) { out.append(e) }
        } else {
            if !word.isEmpty, let e = learn.commit(word, boundary: "\n", standsAlone: standsAlone) { out.append(e) }
            if let e = learn.breakContext() { out.append(e) }
        }
        for e in out { LearnedWords.shared.record(e, generation: learnGen) }
    }

    /// Gợi ý từ vừa được nhận (Tab / click): học với trọng số 2 như iOS.
    private func learnAccepted(_ word: String) {
        guard learnGate(AppState.shared.currentBundleID) else { learn.discard(); return }
        syncLearnEpoch(ignoreClicks: true)    // click nhận gợi ý không phải dời con trỏ
        if let e = learn.commit(word, boundary: " ", standsAlone: true, weight: 2) {
            LearnedWords.shared.record(e, generation: learnGen)
        }
    }

    /// Đổi ô / app: lượt chờ được học, ngữ cảnh cắt.
    private func learnFlush() {
        if let e = learn.breakContext() { LearnedWords.shared.record(e, generation: learnGen) }
    }

    /// Sau một phím chữ (đã xử lý): hẹn gợi ý hoàn thành từ đang gõ. Chỉ app đã chứng minh
    /// thay được chữ đã chốt (in-place, không marked — cùng điều kiện gợi ý ranh giới từ).
    private func predictAfterLetter(_ client: IMKTextInput, markedNow: Bool, id: String?) {
        guard PredictionLogic.shouldSchedule(
                settingOn: SystemInlinePrediction.isOn,
                canReplace: !markedNow && !edgeTapWord && !engine.isEmpty && Self.replacesCommittedText(id))
        else { return }
        CaretHint.shared.schedulePrediction(typed: engine.composed, raw: engine.rawKeystrokes,
                                            english: engine.previousWordEnglish,
                                            client: client, controller: self)
    }

    /// Click ô nổi của CaretHint (gợi ý từ) — như Tab / click ô hệ thống.
    func applyCaretHintChoice() {
        guard let client = client() as IMKTextInput?, let s = CaretHint.shared.take() else { return }
        applyCaretSuggestion(s, client)
    }

    /// Ô ứng viên hệ thống hỏi danh sách (updateCandidates). Chỉ có khi CaretHint đang hiện.
    override func candidates(_ sender: Any!) -> [Any]! {
        CaretHint.shared.candidateStrings
    }

    /// Click vào ứng viên trong ô hệ thống.
    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let client = client() as IMKTextInput?, let s = CaretHint.shared.take() else { return }
        applyCaretSuggestion(s, client)
    }

    /// Client của controller đang active nếu nó thuộc app đang ở trước (MAIN) — để ô nổi
    /// của đường tap lấy firstRect (thường đúng hơn AX ở Chromium/Electron).
    static func activeClientForFrontApp() -> IMKTextInput? {
        guard let c = activeController?.client() as IMKTextInput?,
              let front = FrontmostApp.shared.bundleID, c.bundleIdentifier() == front else { return nil }
        return c
    }

    // MARK: - IMK lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.activeController = self
        optionDeadState = 0   // ⌥ dead key đang chờ không theo sang ô khác
        // Pin the layout Telex composes on BEFORE anything reads a key. Without this
        // the layout is whatever the previously selected input source happened to be
        // (ABC → QWERTY, Colemak → Colemak), so the same input method typed two
        // different keyboards depending on switch history — see KeyboardLayoutOverride.
        // Re-asserted every activation, not just once: macOS can drop the override
        // across an input-source cycle, and the call is a cached Carbon lookup.
        KeyboardLayoutOverride.apply(AppState.shared.keyboardLayoutID)
        // New field: both AX verdicts (is it a password field? does it want selection-
        // replace?) describe the PREVIOUS one until their scans re-run.
        SecureFieldDetector.invalidate()
        catchUpTimeouts = 0
        FocusedFieldDetector.invalidate()
        dropComposition(cause: "activateServer")
        // A nav-key stamp left by the previous client must not drop the first word
        // typed in this one (NavKeyWitness — the very key that moved focus here may
        // have been a swallowed Tab).
        NavKeyWitness.reset()
        engine.resetContext()   // new field/app: don't inherit the last word's English context
        learnFlush()            // Học từ bạn gõ: ô mới — ngữ cảnh không nối sang
        fieldVerified = false
        fieldForcedMarked = false
        fieldVerifyStrikes = 0
        fieldInconclusive = 0
        let activatedClient = sender as? IMKTextInput
        if let client = activatedClient {
            AppState.shared.currentBundleID = client.bundleIdentifier()
            // Qt 5 apps resolve ⌫/⌦ shortcuts through the input-method layout override
            // and break without one (DaVinci Media Pool, #131) — see QtKeymapFix.
            // Non-Qt apps: one cached dictionary lookup.
            QtKeymapFix.apply(client: client, bundleID: AppState.shared.currentBundleID)
        }
        // "Show inline predictive text" của macOS (gợi ý từ — WordPrediction.swift): đọc lại khi
        // đổi ô/app (≤ 1 lần / 2 giây), không bao giờ mỗi phím. Vừa tắt ⇒ bỏ dữ liệu đã nạp.
        let predictionWasOn = SystemInlinePrediction.isOn
        if !SystemInlinePrediction.refresh(), predictionWasOn { CaretHint.shared.predictionDisabled() }
        // Gõ tắt trùng Text Replacements của macOS (#117): làm mới bảng ≤ 1 lần/30 giây.
        SystemReplacementGuard.shared.activated(bundleID: AppState.shared.currentBundleID)
        // Dấu chấm đúp-cách / viết hoa đầu câu / ngoặc cong-gạch dài: đọc lại cài đặt macOS
        // (≤ 1 lần/giây) — đổi trong System Settings rồi quay lại app là có hiệu lực.
        SystemAutoTextSettings.shared.refresh()
        if SystemAutoTextSettings.shared.current.capitalize { FocusedRole.refreshAsync() }
        // Tap-side view of this activation: focus epoch for re-edit(tap) (#111) and
        // the overlay-launcher latch (#110). Before anything else reads the client.
        // Serial controller (#156): tap chỉ cắt từ khi controller KHÁC lần trước.
        let previousController = ClientFocus.snapshot.controller
        ClientFocus.noteActivated(client: activatedClient != nil ? AppState.shared.currentBundleID : nil,
                                  controller: focusSerial)
        pendingTapHandoff = activatedClient != nil && AppState.isOverlayLauncher(AppState.shared.currentBundleID)
        if activatedClient != nil {
            // Spotlight took focus: stamp the visibility cache NOW — the overlay-raw
            // gate in the tap must not wait for a CGWindowList scan that only lands
            // after the first keys have already been mis-composed (2026-07-31).
            if AppState.isSpotlight(AppState.shared.currentBundleID) {
                SpotlightDetector.noteFocused()
                let now = DispatchTime.now().uptimeNanoseconds
                // ASSIGN (not just set-true): an arm from a rapid cycle the user
                // never typed after must not survive into a fresh session opened
                // minutes later — every activation recomputes the verdict, so a
                // slow reopen clears any stale arm (review find 2026-08-12).
                distrustNextAnchor = Self.spotlightReactivatedTooSoon(now: now,
                                                                      lastActivateNs: lastSpotlightActivateNs)
                if distrustNextAnchor {
                    DebugLog.log("Spotlight re-activated within 5s (gapNs=\(now &- lastSpotlightActivateNs)) → distrust next word's anchor")
                }
                lastSpotlightActivateNs = now
            } else {
                // Any OTHER client activating is authoritative proof Spotlight no
                // longer owns the keyboard (macOS wouldn't route activateServer here
                // otherwise) — clear the visibility cache NOW rather than waiting on
                // the passive CGWindowList re-scan, whose backoff can leave it stale
                // for 500ms+ after a long-open Spotlight session (issue: Chrome
                // omnibox typed right after Esc got its first few keys raw-passed).
                SpotlightDetector.noteUnfocused()
                // Per-field browser: start the field-verdict scan NOW, not on the
                // first keystroke — issue #32 round 3 (see prefetch's doc): the
                // first word after refocus otherwise runs on the stale "page
                // content" default and a tone key bare-⌫'s the omnibox.
                // Office (issue #141): cùng lý do — Copilot panel vs lưới Excel phải
                // có verdict trước phím đầu tiên của ô mới.
                if AppState.shared.usesAxDetect(AppState.shared.currentBundleID)
                    || AppState.officeWebPanelHosts.contains(AppState.shared.currentBundleID ?? "") {
                    FocusedFieldDetector.prefetch()
                }
            }
            // What identifier does this client REPORT? (Catalyst/Electron apps may not
            // report what NSWorkspace says — a mismatch mis-routes every mode lookup.)
            // ctl=: serial controller (#156) — hai split / hai ô phải ra hai số khác nhau;
            // "same" = cùng ô activate lại (tap giữ từ đang soạn).
            DebugLog.log("activateServer client=\(AppState.shared.currentBundleID ?? "nil") front=\(FrontmostApp.shared.bundleID ?? "?") ctl=#\(focusSerial)\(previousController == focusSerial ? " same" : "")")
            maybePromptAccessibility(AppState.shared.currentBundleID)
            UpdateCheck.maybeAutoCheck()   // opt-in weekly; two cheap guards inside
        }
        // VietTelex is the active input source now: let the terminal tap act (it must
        // stay dormant when the user switches to ABC/US). ensureRunning() also revives
        // a tap that died (Accessibility toggled off/on invalidates the mach port), so
        // focusing a terminal / re-selecting the source self-heals it.
        TerminalTapController.shared.markActive()
        TerminalTapController.shared.ensureRunning()

        if resetObserver == nil {
            // queue: .main — the poster is the TAP thread now, and this block mutates
            // the controller's engine/tracking, which are MAIN-thread state. Ordering
            // is preserved: the click/⌘-combo that triggers the post physically
            // precedes the next keystroke, so its main-queue block is enqueued before
            // IMK delivers that key to handle() through the same main run loop.
            resetObserver = NotificationCenter.default.addObserver(
                forName: .telexResetComposition, object: nil, queue: .main) { [weak self] note in
                // ⌥+phím ra ký tự ("√") cũng bắn thông báo này từ tap — chữ vẫn nằm trước
                // con trỏ nên cụm gõ tắt được giữ (tap đánh dấu trong userInfo).
                let keepTail = (note.userInfo?[TerminalTapController.keepsShortcutTailKey] as? Bool) == true
                self?.dropComposition(cause: "resetComposition-notification", keepShortcutTail: keepTail)
                self?.acceptedSpace = nil; self?.carriedSpace = nil   // click / điều hướng: hết hiệu lực
                self?.fieldVerified = false
                self?.fieldForcedMarked = false
                self?.fieldVerifyStrikes = 0
                self?.fieldInconclusive = 0
                self?.onLen = 0
            }
        }
    }

    override func commitComposition(_ sender: Any!) {
        // EDGE-TAP: the app processing our own synthetic ⌫/insert echoes makes
        // AppKit ask the IME to commit — SILENTLY resetting the engine mid-word
        // (the "thưr" trace: echoes swallowed clean, then commitComposition, then
        // 'r' fed an empty engine). Within the echo window this commit is an
        // artifact of our own burst, not a user action: ignore it. Real session
        // ends still work — clicks go through the reset notification and focus
        // changes through deactivateServer/activateServer, both of which drop
        // the composition themselves.
        if edgeTapWord,
           DispatchTime.now().uptimeNanoseconds &- edgeEchoStampNs < 500_000_000 {
            logDecision("commitComposition ignored (edge echo window)")
            return
        }
        if let client = sender as? IMKTextInput {
            // NO shortcut expansion here (tester bug 2026-07-23): some apps
            // (omnibox/Spotlight-style fields) force-commit after every
            // keystroke, which expanded a single-letter shortcut ("r"→"rồi")
            // mid-word — "t","r" became "trồi". Expansion belongs to EXPLICIT
            // boundaries only (space/punctuation/Return/Tab).
            let hadWord = !engine.isEmpty
            boundary(client, allowShortcuts: false)
            // App tự chốt GIỮA TỪ (omnibox…): không biết chắc chữ trước con trỏ ⇒ bỏ cụm.
            // Engine rỗng thì không có gì để chốt: AppKit (NSTextView — TextEdit, đo
            // 1483053e) gọi commitComposition sau MỖI phím nó tự xử lý mà IME trả lại
            // (dấu cách, ".", "-", ⌫…) — reset ở đó xoá chính ký tự vừa thấy gõ, nên "từ␣␣"
            // không bao giờ ra ". " và "--" không ra "—" trên TextEdit (Phil 16/10/2026).
            // Có Trợ năng thì click / ⌘-tổ hợp / đổi ô đã reset cụm qua tap (thông báo
            // reset) và phím điều hướng qua handle() — commit rỗng không mang tin gì thêm.
            // Không Trợ năng: giữ reset cũ (có thể đó là dấu vết duy nhất của một click).
            if hadWord || !Accessibility.isTrusted { shortcutTail.reset() }
            // A FORCED commit, not a boundary key: nothing was inserted after the word,
            // so the next ⌫ is deleting the word's own last letter and must not re-open
            // it (see tryReopenLastCommit).
            engine.forgetLastCommit()
        } else {
            engine.reset()
            tracking = false
        }
    }

    override func deactivateServer(_ sender: Any!) {
        optionDeadState = 0
        dropComposition(cause: "deactivateServer")
        CaretHint.shared.dismiss()
        learnFlush()   // Học từ bạn gõ: rời ô — lượt chờ được học, ngữ cảnh cắt
        if Self.activeController === self { Self.activeController = nil }
        if let obs = resetObserver { NotificationCenter.default.removeObserver(obs); resetObserver = nil }
        acceptedSpace = nil; carriedSpace = nil
        // Input source switched away from VietTelex (or focus lost): the tap must not
        // transform keys, so the user really types English in terminals. BUT with
        // per-document input switching, IMK can call this on a stale client AFTER the
        // newly focused client's activateServer — so only turn the tap off if VietTelex
        // is genuinely no longer the OS-selected source (else we'd clobber the fresh
        // activate and typing would pass through until a focus cycle; see IMEActivation).
        TerminalTapController.shared.markInactive(stillSelected: Self.isVietTelexSelected())
        super.deactivateServer(sender)
    }

    /// True when the CURRENTLY selected keyboard input source is VietTelex — the single
    /// source of truth the flaky activate/deactivate ordering must defer to. Called
    /// only on lifecycle transitions / TIS notifications, never on the keystroke hot
    /// path, so the Carbon TIS copy is fine here. Matches only THIS build's exact
    /// bundle id or its `.vi` input mode (see `OwnBundle`), so Release cannot claim
    /// the sibling Debug input source.
    static func isVietTelexSelected() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return false }
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        return inputSourceIsOurs(id)
    }

    /// Does this input-source id belong to the RUNNING build? Split out of
    /// `isVietTelexSelected` so identity matching is testable without a live TIS —
    /// `own` is the seam a test uses to replay the dev-build id mismatch that put the
    /// tap dormant mid-word (see `OwnBundle`). An EMPTY `own` matches nothing; without
    /// the guard, an empty input-source id would compare equal and be mistaken for
    /// VietTelex. `OwnBundle` already refuses to produce an empty id, but this check
    /// keeps the comparison itself safe too.
    static func inputSourceIsOurs(_ id: String, own: String = OwnBundle.id) -> Bool {
        !own.isEmpty && (id == own || id == "\(own).vi")
    }

    // MARK: - Input-method menu (IMK-provided, no NSStatusItem)

    override func menu() -> NSMenu! {
        // Không còn dòng version trong menu (maintainer 12/09/2026: header "VietTelex"
        // do TextInputMenuAgent vẽ từ Info.plist là tĩnh, không nhúng version được;
        // hai dòng "VietTelex" + "VietTelex 1.6.x" thừa). Version vẫn ở Cài đặt →
        // Giới thiệu và dòng đầu của snapshot debug (bấm "Chế độ gõ").
        let menu = NSMenu(title: "VietTelex")
        // NO delegate / no stripping of the system "Edit Text Substitutions…" item any
        // more: macOS 27's TextInputMenuAgent builds its item views from the menu
        // BEFORE our delegate edits it, so removing items mid-open left the views off
        // by one — our section rendered as a "··········" placeholder while the
        // stripped item showed (log: "didChangeIndent: rep returned item view with
        // wrong item", 21/09/2026). A visible system item is the lesser evil.

        // Status first — nhưng CHỈ khi có chuyện (maintainer 15/08/2026): "Tình
        // trạng: OK" thường trực là nhiễu, ẨN đi khi mọi thứ ổn. Tính năng ẩn
        // "click status → copy debug snapshot" KHÔNG mất: nó chuyển xuống dòng
        // version bên dưới (click được ở mọi trạng thái).
        // Mở menu = lúc user nhìn trạng thái: hỏi lại quyền NGAY (macOS 27 có thể không
        // báo khi bật quyền). Một lần đọc lock khi tap đang chạy — không tốn gì lúc ổn.
        TerminalTapController.shared.recheckTrust(reason: "menu opened")
        let statusTitle: String?
        if SecureInputMonitor.shared.activeHolder != nil {
            // Hiếm khi tới được đây (secure input thường đá selection sang ABC nên
            // menu này không mở được), nhưng ca "secure input tạm thời trong ô
            // password mà VietTelex vẫn selected" thì thấy. Headline user-facing
            // (không PID / loginwindow); PID nằm ở icon Vᵀ⃠ tooltip + log.
            statusTitle = SecureInputMonitor.shared.blockedStatusTitle()
                ?? VTLocalized("Status: Blocked by Secure Input")
        } else if !Accessibility.isTrusted {
            statusTitle = VTLocalized("Status: Permission needed")
        } else if TerminalTapController.shared.trustLooksStale {
            statusTitle = VTLocalized("Status: Permission stale — click to fix")
        } else if TerminalTapController.shared.isQuarantined || SyntheticKeyboard.tripped {
            // The tap paused itself (probe-miss quarantine / cascade breaker). Without
            // this state the menu said "OK" while terminals typed raw ASCII and even an
            // input-source switch couldn't revive it (quarantine blocks ensureRunning) —
            // field report 2026-07-30. Click = retryNow(), the documented explicit
            // user action that outranks the backoff.
            statusTitle = VTLocalized("Status: Tap paused — click to retry")
        } else {
            statusTitle = nil                       // OK = im lặng, không chiếm dòng
        }
        if let statusTitle {
            let status = NSMenuItem(title: statusTitle,
                                    action: #selector(showStatus(_:)), keyEquivalent: "")
            status.target = self
            menu.addItem(status)
        }

        // Weekly check found a newer version that isn't installed yet. The notification
        // alone isn't enough: an IME's banner permission is often denied or never
        // answered, and then the news sat in Settings → About where nobody looks
        // (issue #120). One line here only while an update is actually outstanding.
        if let v = UpdateCheck.outstandingUpdate(pending: UpdateCheck.pendingUpdateVersion,
                                                 current: UpdateCheck.currentVersion()) {
            let update = NSMenuItem(title: String(format: VTLocalized("Update available: %@"), v),
                                    action: #selector(openAboutForUpdate(_:)), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }


        // Phần còn lại — PHẲNG, không menu con: macOS 27 TextInputMenuAgent vẽ menu con
        // nhưng không chuyển action của mục con về IME (thử d765295, revert fd8ef15).
        // Thứ tự (maintainer 14/10/2026): Công cụ… (dùng nhiều nhất) → Cơ chế gõ →
        // Cài đặt… → Nguồn nhập liệu… (Keyboard → Input Sources của macOS).
        // Phím tắt mở Công cụ KHÔNG gắn làm keyEquivalent: TextInputMenuAgent tự vẽ
        // menu từ bản sao, keyEquivalent ở đây không chắc hiện/chạy đúng — để Cài đặt nói.
        for key in Self.menuItemKeys(textToolsInMenu: AppState.shared.textToolsInMenu) {
            let item: NSMenuItem
            switch key {
            case Self.typingModeItemKey:
                // Chế độ gõ đang áp dụng + click = copy snapshot giải thích VÌ SAO chọn nó
                // (maintainer 19/08/2026) và mở Bảng cơ chế gõ (tab Ứng dụng).
                item = NSMenuItem(title: VTLocalized(key) + ": "
                                    + strategyLabel(AppState.shared.currentBundleID, localized: true),
                                  action: #selector(copyStrategySnapshot(_:)), keyEquivalent: "")
                item.toolTip = VTLocalized("Click: open the Typing modes table + copy debug info")
            case Self.settingsItemKey:
                item = NSMenuItem(title: VTLocalized(key), action: #selector(openSettings(_:)), keyEquivalent: "")
            case Self.inputSourcesItemKey:
                item = NSMenuItem(title: VTLocalized(key), action: #selector(openSystemKeyboardSettings(_:)),
                                  keyEquivalent: "")
            default:
                // Công cụ văn bản (TextActions.swift): MỘT mục mở bảng nổi cạnh con trỏ
                // (TextToolsPanel) thay cho 6 mục phẳng (maintainer 27/09).
                item = NSMenuItem(title: VTLocalized(key), action: #selector(openTextTools(_:)), keyEquivalent: "")
            }
            item.target = self
            menu.addItem(item)
        }

        return menu
    }

    /// Khoá chuỗi của mục menu mở bảng công cụ (vi: "Công cụ…").
    static let toolsItemKey = "Tools…"
    /// Dòng "Cơ chế gõ: …" (tiêu đề thật = khoá + ": " + cơ chế của app đang gõ).
    static let typingModeItemKey = "Typing mode"
    static let settingsItemKey = "Settings…"
    /// Mở Keyboard → Input Sources của macOS (trước 14/10/2026 tên "Cài đặt hệ thống…").
    static let inputSourcesItemKey = "Input Sources…"
    /// Thứ tự các mục sau dòng trạng thái / cập nhật — test giữ đúng vị trí.
    static func menuItemKeys(textToolsInMenu: Bool) -> [String] {
        (textToolsInMenu ? [toolsItemKey] : []) + [typingModeItemKey, settingsItemKey, inputSourcesItemKey]
    }

    @objc private func openSystemKeyboardSettings(_ sender: Any?) {
        Self.openKeyboardInputSources()
    }

    @objc private func openTextTools(_ sender: Any?) {
        let c = client()           // chụp client NGAY lúc bấm — runner cần đúng ô đang gõ
        // Async: menu input-method còn đang đóng (như showStatus).
        DispatchQueue.main.async { TextToolsPanel.show(client: c) }
    }

    /// Shared by the IME menu and the Settings window: open System Settings →
    /// Keyboard and (with Accessibility) press through to All Input Sources.
    static func openKeyboardInputSources() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        // No URL deep-links into the "All Input Sources" Edit… sheet, so with
        // Accessibility we press the button ourselves: in the Keyboard pane the
        // Input-Sources summary line mentions our own name ("… and ViệtTelex") —
        // a locale-independent anchor; the FIRST AXButton after it inside the
        // same row group is Edit… (verified via UI-tree dump on macOS 26; the
        // second is Text Replacements…, and Dictation's own Edit… lives in a
        // different group so it can never match). Without AX, or if the tree
        // changed, fall back to a how-to popup over the open pane.
        guard Accessibility.isTrusted else { showInputSourcesHowTo(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            for attempt in 0..<6 {
                Thread.sleep(forTimeInterval: attempt == 0 ? 1.2 : 0.5)
                if pressInputSourcesEdit() { return }
            }
            DispatchQueue.main.async { showInputSourcesHowTo() }
        }
    }

    /// Shared by the Settings window: open System Settings → Keyboard → Keyboard
    /// Shortcuts… → Input Sources — where the actual switch-input-source HOTKEY
    /// lives (distinct from openKeyboardInputSources() above, which reaches the
    /// Edit… sheet that adds/removes sources). Field request 2026-08-07.
    static func openInputSourceHotkeySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        // No URL reaches past the Keyboard pane here either. Two AX presses:
        // "Keyboard Shortcuts…" opens a sheet with a category sidebar (Dock,
        // Display, Mission Control, Window management, Keyboard, INPUT SOURCES,
        // Screenshots…); selecting that row shows the actual hotkey. Both anchors
        // are button/row DESCRIPTIONS, so they follow the system language — unlike
        // the "ViệtTelex"-name anchor above, there's no app-specific text to hang
        // onto here, so this only matches English or Vietnamese (the two this app
        // ships) and falls back to a how-to popup on any other system language,
        // exactly like the existing Edit… flow does when its tree doesn't match.
        // Verified live via UI-tree dump on macOS 26 (English) 2026-08-07.
        guard Accessibility.isTrusted else { showInputSourceHotkeyHowTo(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var opened = false
            for attempt in 0..<6 {
                Thread.sleep(forTimeInterval: attempt == 0 ? 1.2 : 0.5)
                if pressKeyboardShortcutsButton() { opened = true; break }
            }
            guard opened else {
                DispatchQueue.main.async { showInputSourceHotkeyHowTo() }
                return
            }
            for attempt in 0..<6 {
                Thread.sleep(forTimeInterval: attempt == 0 ? 0.6 : 0.4)
                if selectInputSourcesShortcutsRow() { return }
            }
            DispatchQueue.main.async { showInputSourceHotkeyHowTo() }
        }
    }

    private static func showInputSourceHotkeyHowTo() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = VTLocalized("Input source hotkey howto title")
        alert.informativeText = VTLocalized("Input source hotkey howto body")
        alert.addButton(withTitle: VTLocalized("OK"))
        alert.runModal()
    }

    /// Presses the "Keyboard Shortcuts…" button in the Keyboard pane's main
    /// window (NOT the Edit… button — a different button in the same pane).
    private static func pressKeyboardShortcutsButton() -> Bool {
        guard let settings = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        else { return false }
        let app = AXUIElementCreateApplication(settings.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &winRef) == .success,
              let window = winRef else { return false }
        // Sheet already up from an earlier attempt → nothing left to press here.
        var sheetsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window as! AXUIElement, "AXSheets" as CFString, &sheetsRef) == .success,
           let sheets = sheetsRef as? [AXUIElement], !sheets.isEmpty {
            return true
        }
        guard let button = findButtonByDescription(window as! AXUIElement,
                                                    matching: ["Keyboard Shortcuts", "Phím tắt bàn phím"],
                                                    depth: 0)
        else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// Selects the "Input Sources shortcuts" row in the Keyboard Shortcuts sheet's
    /// category sidebar (AXRow > … > description, not AXStaticText — a different
    /// shape than the Edit… anchor above).
    private static func selectInputSourcesShortcutsRow() -> Bool {
        guard let settings = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        else { return false }
        let app = AXUIElementCreateApplication(settings.processIdentifier)
        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef)
        guard let windows = winsRef as? [AXUIElement] else { return false }
        for window in windows {
            guard let row = findRowByDescendantDescription(window,
                                                            matching: ["Input Sources shortcuts", "Nguồn nhập"],
                                                            depth: 0)
            else { continue }
            return AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
        }
        return false
    }

    /// First AXButton (reading order) whose description matches one of `needles`.
    private static func findButtonByDescription(_ el: AXUIElement, matching needles: [String], depth: Int) -> AXUIElement? {
        if depth > 15 { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == kAXButtonRole as String {
            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef)
            if let d = descRef as? String, needles.contains(where: { d.contains($0) }) { return el }
        }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for k in kids {
            if let found = findButtonByDescription(k, matching: needles, depth: depth + 1) { return found }
        }
        return nil
    }

    /// First AXRow (reading order) with a descendant whose description matches one
    /// of `needles`. Used for sidebar category lists where the label lives one or
    /// two levels below the row, not on the row itself.
    private static func findRowByDescendantDescription(_ el: AXUIElement, matching needles: [String], depth: Int) -> AXUIElement? {
        if depth > 20 { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == "AXRow", descriptionExists(in: el, matching: needles, depth: 0) {
            return el
        }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for k in kids {
            if let found = findRowByDescendantDescription(k, matching: needles, depth: depth + 1) { return found }
        }
        return nil
    }

    /// True if any descendant (any role) of `el` has a description matching one of
    /// `needles` — used to test an AXRow's subtree without caring which role/depth
    /// carries the label (macOS 26's sidebar puts it on an AXUnknown two levels down).
    private static func descriptionExists(in el: AXUIElement, matching needles: [String], depth: Int) -> Bool {
        if depth > 5 { return false }
        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef)
        if let d = descRef as? String, needles.contains(where: { d.contains($0) }) { return true }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return false }
        for k in kids where descriptionExists(in: k, matching: needles, depth: depth + 1) { return true }
        return false
    }

    /// AX couldn't (or isn't allowed to) press Edit… — tell the user where it is.
    private static func showInputSourcesHowTo() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = VTLocalized("Input sources howto title")
        alert.informativeText = VTLocalized("Input sources howto body")
        alert.addButton(withTitle: VTLocalized("OK"))
        alert.runModal()
    }

    /// Find the Input-Sources row in System Settings' AX tree (anchored on our
    /// own source name, which is locale-independent) and press the single
    /// button inside that row — the Edit… sheet opener. Returns true when
    /// pressed or when the sheet is already up.
    private static func pressInputSourcesEdit() -> Bool {
        guard let settings = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        else { return false }
        let app = AXUIElementCreateApplication(settings.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &winRef) == .success,
              let window = winRef else { return false }

        // The Edit… press SUCCEEDED on an earlier attempt if a sheet is already
        // up — stop here. Walking again would anchor on the "ViệtTelex" row
        // INSIDE the sheet and press deeper into it (field bug 2026-07-23).
        var sheetsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window as! AXUIElement, "AXSheets" as CFString, &sheetsRef) == .success,
           let sheets = sheetsRef as? [AXUIElement], !sheets.isEmpty {
            return true
        }

        // Real tree (dumped on macOS 26, English + Vietnamese OS):
        //   AXGroup                       ← the Input-Sources row
        //     AXStaticText "Input Sources"
        //     AXStaticText "U.S. and ViệtTelex"   ← locale-independent anchor
        //     AXButton  desc="Edit…"              ← what we want
        //     AXButton  desc="Text Replacements…"
        // Rule: inside the anchor's OWN parent group only (never climb — the
        // Dictation row has its own Edit…), press the first button that comes
        // AFTER the anchor in child order. Anything unexpected → press nothing;
        // the caller then shows the how-to popup.
        guard let anchor = findAnchorText(window as! AXUIElement, depth: 0) else { return false }
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(anchor, kAXParentAttribute as CFString, &parentRef) == .success,
              let parent = parentRef else { return false }
        let row = parent as! AXUIElement
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(row, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return false }
        guard let anchorIdx = kids.firstIndex(where: { CFEqual($0, anchor) }) else { return false }
        for el in kids.dropFirst(anchorIdx + 1) {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            if roleRef as? String == kAXButtonRole as String {
                return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// First static text (reading order) whose value mentions our input source
    /// or the Input-Sources label. "Telex" comes from the enabled-sources
    /// summary ("U.S. and ViệtTelex"), which shows our name in every OS
    /// language; the label strings only help on English/Vietnamese systems.
    private static func findAnchorText(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 12 { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == kAXStaticTextRole as String {
            var valRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef)
            if let v = valRef as? String,
               v.contains("Telex") || v.contains("Input Sources") || v.contains("Nguồn nhập") {
                return el
            }
        }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for k in kids {
            if let found = findAnchorText(k, depth: depth + 1) { return found }
        }
        return nil
    }


    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(tab: .typing)
    }

    /// "Có bản cập nhật" → tab Chung, cuộn tới khối cập nhật (nút "Cập nhật ngay").
    @objc private func openAboutForUpdate(_ sender: Any?) {
        SettingsWindowController.shared.show(tab: .general, revealUpdate: true)
    }

    /// Trang giải thích các kiểu gõ (In-place/Tap/Marked…) — GitHub render sẵn
    /// docs/TYPING-STRATEGIES.md; GitHub Pages serve .md dạng raw nên không dùng
    /// viettelex.com cho file này.
    /// Trang hướng dẫn kiểu gõ cho user cuối — vẫn link từ Bảng cơ chế gõ / README.
    static let typingModesGuideURL = "https://ptrinh.github.io/viettelex/typing-modes"

    @objc private func copyStrategySnapshot(_ sender: Any?) {
        // Async: menu input-method còn đang đóng (cùng lý do đã ghi ở showStatus).
        // Click dòng "Cơ chế gõ": copy debug VÀ mở thẳng Bảng cơ chế gõ trong Cài đặt
        // (maintainer 12/09/2026 — thay cho trang web 23/08: user bấm vào là muốn
        // ĐỔI cơ chế cho app đang gõ, bảng hiện ra là feedback đủ rõ, không alert).
        DispatchQueue.main.async { [weak self] in
            self?.showDebugLog(alert: false)
            SettingsWindowController.shared.show(tab: .apps,
                                                 modeFilter: AppState.shared.currentBundleID)
        }
    }

    @objc private func showStatus(_ sender: Any?) {
        // Defer to the next runloop tick: the input-method menu is still dismissing
        // when this fires, and running an NSAlert modal synchronously from that context
        // in a background (accessory) agent doesn't surface the window. Async + activate
        // makes it appear reliably.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !Accessibility.isTrusted { self.grantAccessibility() }
            else if TerminalTapController.shared.trustLooksStale { self.showStaleTrustRepair() }
            else if TerminalTapController.shared.isQuarantined || SyntheticKeyboard.tripped {
                DebugLog.log("menu: user retry from tap-paused state")
                TerminalTapController.shared.retryNow()
            }
            else { self.showDebugLog() }
        }
    }

    /// Stale-grant repair: macOS lists VietTelex as allowed but refuses the tap — the
    /// stored TCC requirement no longer matches this binary, so the checkbox is a lie
    /// (see Accessibility.grantLooksStale). Removing the entry and adding it back is what
    /// fixes it, and `tccutil reset` does exactly that to our OWN row — so the primary
    /// button now does it for the user instead of walking them through four steps in
    /// System Settings. The manual route stays as the second button, because a row that
    /// macOS refuses to delete (MDM/system default) can only be fixed by hand.
    @objc private func showStaleTrustRepair() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = VTLocalized("Stale permission title")
        alert.informativeText = VTLocalized("Stale permission body")
        alert.addButton(withTitle: VTLocalized("Repair automatically"))
        alert.addButton(withTitle: VTLocalized("Open {PANE} Settings"))
        alert.addButton(withTitle: VTLocalized("Close"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            repairStaleTrust()
        case .alertSecondButtonReturn:
            PrivacyPane.openSettings()
            TerminalTapController.shared.retryNow()
        default:
            TerminalTapController.shared.retryNow()
        }
    }

    /// Delete our own TCC row, then ask for the permission again so macOS writes a fresh
    /// one against the CURRENT signature. The re-prompt must come from THIS process (it is
    /// the requesting code identity), so we do not exit; the grant toggle then fires the
    /// com.apple.accessibility.api notification and the tap starts on its own.
    private func repairStaleTrust() {
        let didReset = Accessibility.resetOwnGrant()
        DebugLog.log("stale-grant repair: tccutil reset \(didReset ? "ok" : "FAILED") "
            + "→ trusted=\(AXIsProcessTrusted()) canPost=\(Accessibility.canPostEvents)")
        // Ask again. When the row is gone this shows the system TCC dialog; when macOS
        // kept it (MDM-managed), nothing appears — hence the manual fallback below.
        Accessibility.requestIfNeeded()
        TerminalTapController.shared.retryNow()
        let done = NSAlert()
        done.messageText = VTLocalized(didReset ? "Repair started title" : "Repair failed title")
        done.informativeText = VTLocalized(didReset ? "Repair started body" : "Repair failed body")
        done.addButton(withTitle: VTLocalized("Open {PANE} Settings"))
        done.addButton(withTitle: VTLocalized("Close"))
        NSApp.activate(ignoringOtherApps: true)
        done.window.level = .floating
        done.window.orderFrontRegardless()
        if done.runModal() == .alertFirstButtonReturn {
            PrivacyPane.openSettings()
        }
        TerminalTapController.shared.retryNow()
    }

    /// One-time gentle prompt on the FIRST activation with the permission missing —
    /// no longer waiting for the user to focus a tap-needing app (they'd type happily
    /// in Notes, then hit Terminal days later and think the IME broke). Only signed
    /// Developer ID builds can receive a durable Accessibility grant; an ad-hoc Xcode
    /// build must not keep opening an impossible-to-resolve prompt. Shown once ever
    /// (axPromptShown); declining is remembered.
    private func maybePromptAccessibility(_ id: String?) {
        guard Self.shouldPromptAccessibility(trusted: Accessibility.isTrusted,
                                             alreadyPrompted: AppState.shared.axPromptShown,
                                             isOurSignedBuild: Accessibility.isOurSignedBuild) else { return }
        // Defer to a TYPING PAUSE: this fires on the first activateServer, i.e. exactly
        // while the user starts typing — a modal popping up mid-word swallowed the next
        // keys and a Return in flight hit "Open Settings". Wait until no key (IMK or tap,
        // CaretHint key generation) for `AXPromptPause.idleNs`, then show. Main only.
        guard Self.axPromptTimer == nil else { return }
        var pause = AXPromptPause()
        _ = pause.tick(gen: CaretHint.shared.keyGeneration, nowNs: DispatchTime.now().uptimeNanoseconds)
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard pause.tick(gen: CaretHint.shared.keyGeneration,
                             nowNs: DispatchTime.now().uptimeNanoseconds) else { return }
            timer.invalidate()
            Self.axPromptTimer = nil
            // Re-check: granted / prompted elsewhere while we waited.
            guard Self.shouldPromptAccessibility(trusted: Accessibility.isTrusted,
                                                 alreadyPrompted: AppState.shared.axPromptShown,
                                                 isOurSignedBuild: Accessibility.isOurSignedBuild) else { return }
            AppState.shared.axPromptShown = true
            self?.grantAccessibility(firstRun: true)
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        Self.axPromptTimer = t
    }
    private static var axPromptTimer: Timer?

    /// First-run Accessibility prompt waits for a typing pause. Feed the key generation
    /// each tick; true = no key for `idleNs` -> show now. Pure — pinned by AppSupportTests.
    struct AXPromptPause: Equatable {
        static let idleNs: UInt64 = 2_000_000_000
        private(set) var lastGen: UInt64?
        private(set) var lastChangeNs: UInt64 = 0
        mutating func tick(gen: UInt64, nowNs: UInt64) -> Bool {
            if lastGen != gen { lastGen = gen; lastChangeNs = nowNs; return false }
            return nowNs &- lastChangeNs >= Self.idleNs
        }
    }

    /// Key equivalents for the prompt's (Open Settings, Close) buttons. First-run (the
    /// prompt WE raised, user may still be typing): Return must NOT open Settings — no
    /// default button; Esc closes. nil = NSAlert defaults (user asked via the menu).
    static func axPromptKeyEquivalents(firstRun: Bool) -> (open: String, close: String)? {
        firstRun ? ("", "\u{1b}") : nil
    }

    static func shouldPromptAccessibility(trusted: Bool, alreadyPrompted: Bool,
                                          isOurSignedBuild: Bool) -> Bool {
        isOurSignedBuild && !trusted && !alreadyPrompted
    }

    /// Missing permission: show OUR explanatory popup. We deliberately do NOT call
    /// `AXIsProcessTrustedWithOptions(prompt:)` here — that fires the system TCC
    /// dialog too, so clicking the status opened Settings AND our popup at once. The
    /// popup's "Mở Cài đặt" button opens the Accessibility pane on demand instead.
    private func grantAccessibility(firstRun: Bool = false) {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = VTLocalized("{PANE} permission needed")
        // macOS 27 renamed the pane AND re-adding beats re-toggling a stale grant there.
        alert.informativeText = VTLocalized(PrivacyPane.pick(
            legacy: "VietTelex needs Accessibility to type Vietnamese in Terminal/iTerm and browsers.\n\nOpen System Settings → Privacy & Security → Accessibility and enable VietTelex (if it’s already there, untick then tick it again).",
            modern: "Permission alert body (macOS 27)"))
        alert.addButton(withTitle: VTLocalized("Open Settings"))
        alert.addButton(withTitle: VTLocalized("Close"))
        if let keys = Self.axPromptKeyEquivalents(firstRun: firstRun) {
            alert.buttons[0].keyEquivalent = keys.open
            alert.buttons[1].keyEquivalent = keys.close
        }
        // We're an accessory (agent) app, so a plain runModal() can open the alert
        // BEHIND the frontmost app — the user then has to click our Dock icon to find
        // it (the reported bug). Activate the app AND force the alert window frontmost
        // (float level + orderFrontRegardless) right before running it modally.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.window.orderFrontRegardless()
        alert.window.makeKeyAndOrderFront(nil)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            PrivacyPane.openSettings()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Permission OK: show a debug snapshot of the runtime state.
    /// Nhãn chế độ gõ ĐANG áp dụng cho app hiện tại — dùng cho cả dòng menu (tiếng
    /// Việt hoá) lẫn snapshot (giữ nguyên tiếng Anh để grep bug report). tapRouting,
    /// không phải các getter per-mode: page content trong browser routes sang tap BY
    /// POLICY (06/08) mà app không hề nằm trong set tap-mode nào.
    /// Issue #82: gõ tắt chỉ nở khi từ KHÔNG dính liền sau chữ số ("5h" giữ nguyên,
    /// "5 h" → "5 giờ"). Pure — pinned by ShortcutAfterDigitTests.
    static func shortcutExpansionAllowed(afterDigit: Bool) -> Bool { !afterDigit }
    static func isAsciiDigit(_ c: UInt8?) -> Bool {
        guard let c else { return false }
        return c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
    }
    /// Issue #87: "/h3" nở thành "/giờ3" — slash command (Lark, Slack, Notion, Discord)
    /// là cùng lớp token với "5h": từ dính liền sau ký tự MỞ TOKEN thì không phải một
    /// từ đứng riêng. Nhóm ký tự mở token = chữ số (#82) + `/` `#` `@` (`/cmd`,
    /// `#tag`, `@mention`). Pure — pinned by ShortcutAfterDigitTests.
    /// Mở rộng khớp iOS/Android ShortcutTable.isGlued: cả ký tự NỐI token `. _ - : \ ~
    /// & = + %` (URL, email, tên file, `a-ko`, `x.ko`) — từ dính sau chúng không nở.
    static func gluesShortcutToken(_ c: UInt8?) -> Bool {
        guard let c else { return false }
        return isAsciiDigit(c) || shortcutGlueBytes.contains(c)
    }
    private static let shortcutGlueBytes: Set<UInt8> = Set("/#@._-:\\~&=+%".utf8)

    func strategyLabel(_ id: String?, localized: Bool) -> String {
        // Remote-desktop canvas (native RDP / browser-hosted CRD): IME is off.
        // Checked before tapRouting so a Chrome tab on remotedesktop.google.com is
        // not labelled "tap · backspace" while we actually pass keys through.
        let remoteCanvas = AppState.shared.manualMode(id) == nil
            && (ClientPolicy.isRemoteDesktop(id)
                // isBuiltInPassthrough, không phải Set: rule wildcard
                // (com.valvesoftware.*: passthrough) cũng phải hiện nhãn đúng.
                || id.map { AppState.isBuiltInPassthrough($0) } == true)
            && !(Accessibility.isTrusted && FocusedFieldDetector.isTextInput)
        if remoteCanvas || (AppState.shared.usesAxDetect(id) && FocusedFieldDetector.wantsPassthroughField) {
            return localized ? VTLocalized(ModeNames.passthrough) : "passthrough · remote desktop"
        }
        let routing = AppState.shared.tapRouting(id)
        if routing.selection { return localized ? VTLocalized(ModeNames.selection) : "tap · selection-replace (Chromium)" }
        if routing.tap { return localized ? VTLocalized(ModeNames.tap) : "tap · backspace" }
        if routing.emptyReset { return localized ? VTLocalized(ModeNames.emptyReset) : "tap · emptyReset" }
        if usesMarkedNow(id) { return localized ? VTLocalized(ModeNames.marked) : "IMKit · marked text" }
        return localized ? VTLocalized(ModeNames.inPlace) : "IMKit · in-place"
    }

    private func showDebugLog(alert: Bool = true) {
        // Snapshot là lúc user đang thắc mắc "sao thế này" — re-check secure input
        // ngay thay vì đợi nhịp poll 5s.
        SecureInputMonitor.shared.check(reason: "snapshot")
        let id = AppState.shared.currentBundleID ?? "?"
        // tapRouting, not the per-mode getters: page content in browsers routes to
        // tap BY POLICY (2026-08-06) without the app ever being in a tap-mode set,
        // so the old usesTapMode-based label showed "in-place" for a key the tap
        // actually handled.
        let mode = strategyLabel(id, localized: false)
        let s = AppState.shared
        let bundle = Bundle(for: TelexInputController.self)
        let ver = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        // Log payload — deliberately ENGLISH (and NOT routed through VTLocalized) so a
        // pasted bug report is greppable regardless of the reporter's UI language.
        func onOff(_ v: Bool) -> String { v ? "on" : "off" }
        let lines = [
            "VietTelex \(ver) (build \(build))",
            "Accessibility: \(Accessibility.isTrusted ? "OK" : "missing")",
            "Terminal tap: \(TerminalTapController.shared.isRunning ? "running" : "off")"
                + (TerminalTapController.shared.isQuarantined ? " (quarantined)" : "")
                + (SyntheticKeyboard.tripped ? " (breaker tripped)" : ""),
            SecureInputMonitor.shared.snapshotLine,
            "Spotlight visible: \(SpotlightDetector.isVisible ? "yes" : "no")",
            "Current app: \(id)"
                + (FrontmostApp.shared.bundleID.map { $0 == id ? "" : "  (frontmost: \($0))" } ?? ""),
            "Strategy: \(mode)",
            "",
            "— why this strategy —",
            "Built-in rule: \(AppState.shared.autoResolvedMode(id).map { "\($0)" } ?? "none (unknown app)")",
            "Manual pin: \(AppState.shared.manualMode(id).map { "\($0)" } ?? "none")",
            "Learned: \(AppState.shared.isLearnedInPlace(id) ? "in-place OK" : "—")"
                + (AppState.shared.usesTapMode(id) ? " / tap-fallback" : ""),
            "Unknown apps → safe channel: \(onOff(s.safeUnknownApps))",
            "Field verdict: selection=\(FocusedFieldDetector.wantsSelection ? "yes" : "no")"
                + " marked=\(FocusedFieldDetector.wantsMarkedField ? "yes" : "no")"
                + " passthrough=\(FocusedFieldDetector.wantsPassthroughField ? "yes" : "no")"
                + " officeWebPanel=\(AppState.shared.isOfficeWebPanel(id) ? "yes" : "no")"
                + " forcedMarked=\(fieldForcedMarked ? "yes" : "no")",
            "Web host: \(FocusedFieldDetector.debugLastHost ?? "—")",
            "AX role chain: [\(FocusedFieldDetector.debugRoleChain())]",
            "",
            "Simple Telex: \(onOff(s.simpleTelex))",
            "Free marking: \(onOff(s.freeMarking))",
            "Modern tone placement: \(onOff(s.modernOrthography))",
            "Live spell check: \(onOff(s.liveSpellCheck))",
            "Auto restore: \(onOff(s.autoRestore))",
            "Collision priority: \(s.collisionPrefersVietnamese ? "Vietnamese" : "English")",
        ]
        // Copy vào clipboard để user dán thẳng vào báo lỗi (lúc có sự cố thì gõ lại
        // không đáng tin). CÓ alert xác nhận: đây là dòng menu TƯỜNG MINH ("Chế độ
        // gõ: …"), khác hidden feature click-dòng-version đã bỏ 15/08 — user bấm có
        // chủ đích thì phải biết chuyện gì vừa xảy ra.
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard alert else { return }   // đường mở-web: browser hiện ra là feedback đủ
        let box = NSAlert()
        box.messageText = VTLocalized("Debug info copied")
        box.informativeText = VTLocalized("Paste it into your bug report (⌘V).")
        box.addButton(withTitle: VTLocalized("OK"))
        box.runModal()
    }

}


@inline(__always)
func isAsciiDigit(_ c: UInt8) -> Bool {
    c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
}

@inline(__always)
func isAsciiLetter(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) ||
    (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
}

/// Does this key belong to the WORD (feed it to the engine) or end it (boundary)?
/// The ONE routing rule both key paths (IMKit controller + terminal tap) must agree on.
/// In VNI the digits carry the diacritics ("a1"→á), so they are word keys; in Telex a
/// digit ends the word. Extracted so AppTests can pin it — issue #28 (2026-07-27) was
/// exactly this predicate being letters-only while the engine happily accepted digits.
/// Numpad digits are NEVER VNI marks (common Vietnamese IME behavior): `keypad` = the key came from the
/// numeric keypad → it ends the word like punctuation and the digit reaches the app (#124).
@inline(__always)
func isWordKey(_ c: UInt8, vniMode: Bool, bracketVowels: Bool = false, keypad: Bool = false) -> Bool {
    isAsciiLetter(c) || (vniMode && !keypad && isAsciiDigit(c))
        || (bracketVowels && isBracketVowelKey(c))
}

/// kVK_ANSI_Keypad0…9 (82…89, 91, 92 — 90 is kVK_F20). Physical keycode, so it holds
/// whatever layout is active.
@inline(__always)
func isKeypadDigitKeyCode(_ k: Int) -> Bool {
    (k >= kVK_ANSI_Keypad0 && k <= kVK_ANSI_Keypad7) || k == kVK_ANSI_Keypad8 || k == kVK_ANSI_Keypad9
}

/// `[ ] { }` — the keys the bracket-vowel option turns into ơ/ư. They must be WORD
/// keys while it is on (a boundary would commit the word before the engine sees the
/// vowel) and plain boundaries while it is off — see AppState.bracketVowels.
@inline(__always)
func isBracketVowelKey(_ c: UInt8) -> Bool {
    c == UInt8(ascii: "[") || c == UInt8(ascii: "]")
        || c == UInt8(ascii: "{") || c == UInt8(ascii: "}")
}

@inline(__always)
private func isBracket(_ c: UInt8) -> Bool {
    switch c {
    case UInt8(ascii: "["), UInt8(ascii: "]"),
         UInt8(ascii: "{"), UInt8(ascii: "}"),
         UInt8(ascii: "("), UInt8(ascii: ")"):
        return true
    default:
        return false
    }
}

/// Thứ tự phím quanh một lần nuốt + re-post Return/Tab/Esc (TelexInputController, nhánh
/// `rewrote` của phím ranh giới). Field 18/10/2026: "- abc" ⏎ "- def" ra "- abc- " ⏎ "def"
/// (dấu cách cuối dòng 1 trước Enter thì không bị — khi đó engine rỗng, Enter không bị
/// nuốt). Bản sao đi vào CUỐI hàng sự kiện, nhưng phím user gõ tiếp có thể ĐÃ nằm trong
/// hàng của app (app đang chờ handle() của Enter trả lời; web editor marked còn hoãn 60ms)
/// ⇒ app nhận "-", " " rồi mới tới Return. Cách giữ thứ tự: mọi phím thật tới khi bản sao
/// còn chờ = "vượt" ⇒ nuốt và post lại sau nó; bản sao quay lại (đúng keycode đầu hàng)
/// đi tiếp như thường. Hàng tự xoá sau `staleNs` không thấy bản sao (bị hệ thống bỏ) —
/// không bao giờ kẹt bàn phím. Pure — AppTests ghim.
struct RepostOrder: Equatable {
    enum Entry: Equatable {
        case boundary(UInt16)   // Return/Tab/Esc mình re-post
        case userKey(UInt16)    // phím thật đã vượt, mình post lại sau bản sao
        var keyCode: UInt16 {
            switch self { case let .boundary(k), let .userKey(k): return k }
        }
    }
    enum Verdict: Equatable { case normal, boundaryEcho, userKeyEcho, overtook }

    /// Đầu hàng chờ quá lâu ⇒ bản sao đã mất: bỏ cả hàng (tính từ lúc ĐẦU hàng được post,
    /// không phải phím vượt gần nhất — phím vượt liên tục không được giữ hàng sống mãi).
    static let staleNs: UInt64 = 500_000_000
    /// Trần an toàn: hơn chừng này phím vượt thì chắc chắn có gì sai — buông, gõ như thường.
    static let maxAwaiting = 16
    private(set) var awaiting: [Entry] = []
    private var headNs: UInt64 = 0

    var isEmpty: Bool { awaiting.isEmpty }

    mutating func expect(_ e: Entry, nowNs: UInt64) {
        if awaiting.isEmpty { headNs = nowNs }
        awaiting.append(e)
    }

    mutating func reset() { awaiting.removeAll() }

    /// `synthetic` = phím mang magic (bản sao nguồn riêng còn nguyên magic — macOS cũ):
    /// chỉ khớp hàng mới tính, không bao giờ là "vượt" (echo burst của mình).
    mutating func classify(keyCode: UInt16, synthetic: Bool, nowNs: UInt64) -> Verdict {
        guard let head = awaiting.first else { return .normal }
        if nowNs &- headNs > Self.staleNs || awaiting.count >= Self.maxAwaiting {
            awaiting.removeAll()
            return .normal
        }
        if keyCode == head.keyCode {
            pop(nowNs)
            if case .userKey = head { return .userKeyEcho }
            return .boundaryEcho
        }
        // Bản sao phím vượt quay lại mà Return/Tab đầu hàng chưa thấy ⇒ bản sao đó đã
        // mất (hoặc app nhận nó theo đường khác): bỏ đầu hàng, KHÔNG post lại lần nữa
        // (macOS 26 xoá magic — không có cách nào khác nhận ra echo của chính mình; post
        // lại sẽ thành vòng lặp).
        if awaiting.count > 1, case .userKey(let k) = awaiting[1], k == keyCode {
            pop(nowNs); pop(nowNs)
            return .userKeyEcho
        }
        return synthetic ? .normal : .overtook
    }

    private mutating func pop(_ nowNs: UInt64) {
        awaiting.removeFirst()
        headNs = nowNs
    }
}
