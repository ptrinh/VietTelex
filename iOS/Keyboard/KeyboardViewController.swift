// VietTelex iOS keyboard — M1: working QWERTY that types Vietnamese via
// TelexEngine diff-edits. UI is programmatic UIKit, laid out to Apple's stock
// metrics (fidelity pass = M2). No Full Access, no network, no timers at idle.
import UIKit
import os.log
import TelexCore

final class KeyboardViewController: UIInputViewController {

    /// LƯỜI: init controller KHÔNG đọc cài đặt (~45 key App Group). configureForAppearance gán
    /// EngineBridge(settings:) với lần đọc DUY NHẤT của lần hiện; getter chỉ tự nạp nếu có gì chạm
    /// bridge trước đó (willAppear bị nuốt…) — vẫn đúng, chỉ đọc thêm một lần.
    private lazy var bridge = EngineBridge()
    private var keyboard: KeyboardView!
    /// Lấp dải container hệ thống lộ phía trên view (checkHostFill) + dedupe log hình học.
    fileprivate var hostFill = HostFill()
    fileprivate var hostFillRecheckScheduled = false
    /// Lần hiện mới (iPhone iOS 26+, nền đục): nội dung alpha 0 tới khi chiều cao host ổn định
    /// (HeightSettleGuard, trần 0,3 s) — không hiện rồi mới cao thêm.
    fileprivate var settleGuard = HeightSettleGuard()
    /// Host giữ khung cao hơn hẳn mức xin (#151): xin đo lại, tối đa HostOversize.maxNudges lần mỗi lần hiện.
    fileprivate var hostOversize = HostOversize()
    fileprivate var settleArmedAt: CFTimeInterval = 0
    fileprivate var lastHostGeomKey = ""
    /// Model học từ cá nhân — tạo LƯỜI khi tính năng cần (thanh gợi ý / gõ vuốt / Thêm dấu).
    /// Tắt hết ⇒ không đọc userlm.plist, không seed, không giữ bảng trong RAM.
    private var langModelStorage: UserLangModel?
    private var langModel: UserLangModel {
        if let m = langModelStorage { return m }
        let m = Self.hermetic ? UserLangModel(appGroup: nil) : UserLangModel()
        m.isKnownWord = { VNSuggest.contains($0) }
        // Datastore trống (lần đầu / vừa reset) → mồi bằng seed corpus để
        // ngày đầu tiên đã có gợi ý hợp lý; dữ liệu học thật vượt seed sau
        // vài ngày (weight seed ≤50, gõ thật +1/lần, decay tuần).
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        // Load plist chạy nền — bar mở-đầu refresh khi dữ liệu sẵn sàng.
        m.onReady = { [weak self] in self?.updateSuggestions() }
        langModelStorage = m
        return m
    }
    private var lastWord: String?         // từ liền trước trong câu (context bigram)
    private var lastWord2: String?        // từ trước nữa (context trigram)
    private var learnEnabled = true
    /// Vuốt ⌫: context + từ đang soạn chụp lúc chạm ⌫ (trước lần xoá của chạm đó).
    private var wordSwipeSnapshot: (context: String?, composed: String)?
    /// Chuỗi vừa vuốt xoá + đuôi phần còn lại → ô "Khôi phục" (một lượt).
    private var wordSwipeRestore: (text: String, tail: String)?
    /// Công cụ văn bản vừa áp → ô "↩︎ Hoàn tác" / ⌫ ngay sau (một lượt).
    private var textToolUndo: TextTools.Undo?
    /// Dịch trên máy: chip thông báo ở slot đầu (tới phím kế) + lượt dịch đang chờ.
    private var translateNotice: (text: String, opensApp: Bool)?
    private var translateTask: Task<Void, Never>?
    /// "Sửa lỗi bằng Apple Intelligence" (Plus, AIAssist.swift): nil khi công tắc tắt ⇒ 0 chi phí.
    private var ai: AIAssist?
    // Log gỡ lỗi: ảnh chụp ô nhập (probeField) — chỉ dùng khi Debug mode bật.
    fileprivate var probeReady = false
    fileprivate var probeKeys = 0
    fileprivate var probeHostEvents = 0
    fileprivate var probePrev: TouchLogAlerts.Probe?
    private var filterSensitive = true
    /// Gõ vuốt (thử nghiệm): công tắc trong app; `swipe` chỉ tạo khi bật (0 RAM khi tắt).
    private var swipeSetting = false
    private var swipe: SwipeTyping?
    /// Từ vuốt đang mở + phương án cho thanh gợi ý (hết hiệu lực khi từ đổi / chốt).
    /// `english` = các phương án tiếng Anh (chọn ⇒ chèn nguyên văn).
    private var swipeSuggest: (current: String, alts: [String], english: Set<String>)?
    /// Từ vuốt Việt vừa chèn + ứng viên đã chấm — cú vuốt kế sửa lại được (SwipeRevise).
    private var swipeRevisable: SwipeTyping.Revisable?
    /// Cú vuốt vừa sửa lại từ trước → chip "↩︎ từ cũ" (sống khi từ vuốt mới còn mở).
    private var swipeReviseUndo: SwipeTyping.Revision?
    fileprivate typealias Learned = (word: String, receipt: UserLangModel.Learned?, prev1: String?, prev2: String?)
    /// Từ vuốt Việt còn nguyên vừa được phím chữ (dấu cách treo) / dấu cách chốt ⇒ chờ từ GÕ
    /// PHÍM kế: ranh giới chốt từ đó thì chấm lại từ vuốt (SwipeRevise.reviseTyped). `learned` =
    /// lượt học của từ vuốt (rút khi thay). Sống qua phím chữ / ⌫ trong từ gõ; khác ⇒ bỏ.
    private var swipeTyped: (rev: SwipeRevise.Typed, learned: Learned?)?
    /// Vừa sửa lại từ vuốt theo từ gõ → chip "↩︎ từ cũ" (sống tới phím kế).
    private var swipeTypedUndo: (edit: SwipeRevise.TypedEdit, newLearned: Learned?, sentenceBreak: Bool)?
    /// Công tắc con "Vuốt từ tiếng Anh" (giai đoạn 3).
    private var swipeEnglishSetting = true
    private var swipeFutoSetting = false
    /// Chọn phím theo ngữ cảnh lúc chạm (thử nghiệm, mặc định BẬT) — TouchTarget.
    private var smartTouchSetting = true
    /// Tự sửa từ gõ sai (thử nghiệm, mặc định TẮT; VNI không sửa) — AutoCorrect.
    private var autoCorrectSetting = false
    /// Tự sửa đang chạy ở ô này (công tắc + AutoCorrect.fieldAllows) — tắt ⇒ 0 việc mỗi phím.
    private var autoCorrectActive = false
    /// ONBOARDING-SPEC §8 — tô nền gợi ý sửa: thanh gợi ý chữ đang bật ở ô tự sửa được (không VNI).
    /// Bật cả khi công tắc tự sửa TẮT (ô tô nền chỉ là gợi ý); thanh tắt ⇒ false, 0 việc mỗi phím.
    private var correctionHintActive = false
    /// Quyết định tự sửa của từ đang soạn (phím thô → bản sửa) — ô tô nền và dấu cách dùng CHUNG.
    private var acMemo: (raw: String, fix: String?)?
    /// Điểm chạm từng phím của từ đang gõ; hỏng (ok = false) khi có phím không kèm điểm
    /// chạm, ⌫ giữa từ, từ nạp lại… ⇒ từ đó không tự sửa.
    private var wordTouches: [AutoCorrect.Touch] = []
    private var wordTouchesOk = false
    private var pendingTouch: AutoCorrect.Touch?
    /// Từ từng hoàn tác tự sửa — không bao giờ sửa lại (UserDefaults của bàn phím, không sao lưu).
    private static let rejectedKey = "autoCorrectRejected"
    private lazy var autoCorrectRejected = AutoCorrect.Rejected.decode(
        Self.hermetic ? nil : UserDefaults.standard.string(forKey: Self.rejectedKey))
    /// ONBOARDING-SPEC §8 — thanh gợi ý vừa hiện gì cho từ đang soạn `raw`: `fix` = ô tô nền (nil =
    /// không tô). Dấu cách dùng ĐÚNG cái này khi thanh đã vẽ cho từ này (autoCorrection) ⇒ không bao
    /// giờ sửa khác ô tô nền, không tô ⇒ không sửa. Phím chữ mới / đổi ô ⇒ nil.
    private var shownCorrection: (raw: String, fix: String?)?
    /// Thay thế văn bản + tên danh bạ của người dùng (requestSupplementaryLexicon, nạp một
    /// lần mỗi lần hiện khi tự sửa bật) — coi là từ hợp lệ, không sửa.
    private var lexiconWords: Set<String> = []
    /// UILexicon nạp MỘT lần mỗi phiên controller (tự sửa + Thay thế văn bản iOS dùng chung).
    private lazy var supplementaryLexicon = SupplementaryLexiconCache { [weak self] done in
        guard let self else { return }
        self.requestSupplementaryLexicon { lex in
            done(lex.entries.prefix(5000).map { (input: $0.userInput, text: $0.documentText) })
        }
    }
    /// Thay thế văn bản iOS làm gõ tắt (cache theo phiên).
    private lazy var systemReplacements = SystemTextReplacementLoader(cache: supplementaryLexicon)
    /// Biên nhận học của từ vừa chốt — hoàn tác tự sửa rút lại đúng lượt học từ đã sửa.
    private var lastLearned: Learned?
    /// Vài từ tiếng Anh vừa vuốt ra (chữ thường) — ngữ cảnh ngôn ngữ cho cú vuốt kế
    /// (từ trùng chuỗi như "the" vuốt ra dạng Anh vẫn mở mạch Anh).
    private var recentEnglish: [String] = []
    /// ≤ 3 từ vừa chốt (cũ → mới) cho tiền nghiệm liên tục ngôn ngữ của gõ vuốt — KHÔNG xoá ở
    /// dấu câu (đang viết đoạn tiếng Anh thì câu sau vẫn tiếng Anh), chỉ xoá khi hiện lại bàn
    /// phím / chữ trước con trỏ đổi từ ngoài. Chỉ ghi khi bật vuốt + vuốt tiếng Anh.
    private var langRecent: [String] = []
    /// Lịch sử clipboard + chip tách số + ẩn danh (ClipboardFeature.swift).
    private let clip = ClipboardFeature()
    private var clipPanel: ClipboardPanel?
    /// Thêm dấu (AddTones): kế hoạch vừa áp — chip "Hoàn tác" / ⌫ ngay sau (tới phím kế);
    /// đoạn vừa hoàn tác (không mời lại); cache kế hoạch theo văn bản trước con trỏ.
    private var addTonesUndo: AddTones.Plan?
    /// Gợi ý vừa nhận đã chèn chuỗi này ("từ "): phím kế là . , ? ! ) hay nháy đóng ⇒ xoá dấu
    /// cách đó (AutoSpace.snapsSuggestionSpace). Mọi phím / đổi con trỏ khác bỏ.
    private var suggestionSnap: String?
    private var addTonesDismissed: String?
    private var addTonesCache: (before: String, plan: AddTones.Plan?)?
    /// Vuốt phím cách đổi Tiếng Việt ↔ Tiếng Anh (công tắc trong app; tắt ⇒ luôn .vi).
    private var spaceFlickSetting = false
    /// "Vuốt phím để sao chép/dán" (Phím & cử chỉ, mặc định TẮT) — KeyCommandGesture.
    private var keyCommandsSetting = false
    private var language: KeyboardLanguage = .vi

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        FrameTrace.controllersCreated += 1
        if FrameTrace.isEnabled { beginAppearTrace(FrameTrace.controllersCreated == 1 ? .cold : .warm) }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    // MARK: signpost hiện bàn phím (FrameTrace, StartupTrace.swift) — chỉ chạy khi Instruments ghi.
    private var appearTrace: OSSignpostIntervalState?
    private var tracedHeight: CGFloat = -1
    private enum AppearKind { case cold, warm, reshow }
    private func beginAppearTrace(_ kind: AppearKind) {
        let s = FrameTrace.signposter
        switch kind {
        case .cold: appearTrace = s.beginInterval("appear", id: s.makeSignpostID(), "cold")
        case .warm: appearTrace = s.beginInterval("appear", id: s.makeSignpostID(), "warm")
        case .reshow: appearTrace = s.beginInterval("appear", id: s.makeSignpostID(), "reshow")
        }
        s.emitEvent("vc.init")
    }
    /// viewDidLayoutSubviews: mốc mỗi lần chiều cao đổi; khung đầu có phím ⇒ đóng `appear` ở commit.
    private func traceLayout() {
        let s = FrameTrace.signposter
        let h = view.bounds.height
        if h != tracedHeight {
            tracedHeight = h
            let w = Int(view.bounds.width), hh = Int(h)
            s.emitEvent("height", "\(w)x\(hh)")
        }
        if let st = appearTrace, h > 0, let kb = keyboard, !kb.isTornDown, kb.firstFrameReady {   // phím hoặc ảnh lưới phím
            appearTrace = nil
            FrameTrace.endAtCommit("appear", st)
        }
    }

    override func viewDidLoad() {
        FrameTrace.event("viewDidLoad")
        StartupPrewarm.start()   // nền: SF Symbols / phông của phím — song song với dựng UIKit
        super.viewDidLoad()
        if #available(iOS 17.0, *) {
            // traitCollectionDidChange không còn được gọi tin cậy trên iOS 17+.
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: Self, _: UITraitCollection) in
                vc.keyboard?.updateDark(vc.presentationDark)
            }
        }
        registerObservers()
        StartupTrace.span("installKeyboard") { installKeyboard() }
    }

    /// Dựng KeyboardView + nối callback. Gọi ở viewDidLoad, và ở viewWillAppear khi CÙNG
    /// controller hiện lại sau khi viewDidDisappear đã xé cây view (RAM-AUDIT.md #1). Mọi cấu
    /// hình còn lại (trait ô, theme, một tay, gợi ý, vuốt…) viewWillAppear áp lại như với
    /// controller mới — iOS vốn tạo controller mới gần như mỗi lần hiện.
    private func installKeyboard() {
        // needsInputModeSwitchKey ở viewDidLoad CHƯA đáng tin (host chưa nối,
        // iOS còn in warning) — khởi tạo false, viewWillAppear set giá trị thật.
        keyboard = KeyboardView(
            needsGlobe: false,
            inputController: self,     // globe key addTarget thẳng vào handleInputModeList
            deferInitialBuild: true,   // configureForAppearance dựng MỘT lần với kiểu cuối
            onKey: { [weak self] key in self?.handle(key) }
        )
        keyboard.primesLastHeight = true
        keyboard.primedScreen = UIScreen.main.bounds.size
        keyboard.applyPrimedHeight()
        keyboard.onDeleteWord = { [weak self] in self?.deleteWordBackward() }
        wireWordSwipe()
        wireSwipeTyping()
        // Đập chuột (theme "mole"): chữ đang soạn — chỉ đọc lúc thả chuột (vài giây một lần), không mỗi phím.
        keyboard.moleWordPrefix = { [weak self] in self?.bridge.composedWord ?? "" }
        #if DEBUG
        Self.debugKeyboardInstalls += 1
        #endif
        keyboard.onTemplate = { [weak self] in self?.insertTemplate($0) }
        keyboard.onOpenTemplates = { [weak self] in self?.openTemplatesInApp() }
        keyboard.onTextTool = { [weak self] in self?.applyTextTool($0) }
        keyboard.onTranslate = { [weak self] in self?.applyTranslate() }
        keyboard.onAddTones = { [weak self] in self?.applyAddTonesTool() }
        keyboard.onOneHandChange = { side in
            // Bàn phím tự lưu (không Full Access thì không ghi được App Group).
            UserDefaults.standard.set(side.rawValue, forKey: OneHand.key)
            if side != .off { UserDefaults.standard.set(side.rawValue, forKey: OneHand.lastSideKey) }
        }
        keyboard.onOpenClipboard = { [weak self] in self?.toggleClipboardPanel() }
        keyboard.onKeypadPaste = { [weak self] in self?.pasteIntoKeypad() }
        keyboard.onPasteOfferVisible = { [weak self] on in
            guard let self else { return }
            if on { self.pasteOnce.displayed(self.pasteSeenChange) } else { self.pasteOnce.ended() }
        }
        keyboard.onSpaceFlick = { [weak self] in self?.toggleLanguage() }
        wireKeyCommands()
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        // Như KeyboardView: nền trong suốt = touch xuyên sang app host (rớt phím).
        view.backgroundColor = KeyboardView.touchableClear
        view.addSubview(keyboard)
        keyboardEdges = [
            keyboard.leftAnchor.constraint(equalTo: view.leftAnchor),
            keyboard.rightAnchor.constraint(equalTo: view.rightAnchor),
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(keyboardEdges)
    }
    /// 4 cạnh KeyboardView ↔ view gốc. Xé phải TỰ gỡ: removeFromSuperview không bỏ chúng
    /// khỏi mảng constraint của UIInputView (leaks --traceTree: UIInputView → constraint →
    /// anchor → KeyboardView cũ sống tiếp).
    private var keyboardEdges: [NSLayoutConstraint] = []

    /// Proxy cho MỌI lần đọc/sửa văn bản của bàn phím: chuyển thẳng tới textDocumentProxy, kèm
    /// bản sao chữ trước con trỏ (HostMirror) để bù tiếng vọng trễ của host — xem MirroredProxy.
    private lazy var mirrored = MirroredProxy { [unowned self] in self.textDocumentProxy }
    /// Kiểu existential (không phải MirroredProxy) để đọc được trait optional (keyboardType…).
    private var textProxy: UITextDocumentProxy { mirrored }

    #if DEBUG
    /// Test/bench (KeyboardBenchTests, CompositionSync…): proxy giả thay host. Release không có.
    var debugProxy: UITextDocumentProxy?
    override var textDocumentProxy: UITextDocumentProxy { debugProxy ?? super.textDocumentProxy }
    var debugKeyboard: KeyboardView { keyboard }
    /// Test: không đọc/ghi dữ liệu người dùng thật — model học từ in-memory (không userlm.plist
    /// App Group), danh sách từ từ chối tự sửa trống, không nạp Thay thế văn bản / danh bạ.
    static var debugHermetic = false
    /// Test: trạng thái lấp dải container hệ thống (HostFill).
    var debugHostFill: HostFill { hostFill }
    /// Test: số lần dựng KeyboardView (viewDidLoad + mỗi lần hiện lại sau khi xé).
    static var debugKeyboardInstalls = 0
    /// Test: gửi thẳng một phím vào handle() (dấu câu, ⌫…) như KeyboardView gửi.
    func debugHandle(_ key: KeyboardView.Key) { handle(key) }
    /// Test: một cú vuốt đúng đường thật — chạm phím chữ đầu (chèn lúc touchDown), rồi vuốt `path`.
    func debugSwipe(first: Character, path: SwipePath) {
        handle(.letter(first))
        swipeBegan()
        swipeEnded(path, .lower)
    }
    /// Test: bố cục vuốt hiện tại của bàn phím (nil nếu chưa dựng / tắt vuốt).
    var debugSwipeLayout: SwipeLayout? { keyboard.swipeLayout() }
    /// Test: bấm 123 rồi về chữ, như người dùng (đổi plane thật của KeyboardView).
    func debugCycleThroughNumbers() { keyboard.debugCycleThroughNumbers() }
    /// Test: chạm một ô thanh gợi ý với payload này.
    func debugAcceptSuggestion(_ item: String) { acceptSuggestion(item) }
    /// Test: clipboard giả (thay UIPasteboard.general) + Toàn quyền giả.
    var debugPasteboard: PasteboardSource?
    var debugFullAccess: Bool?
    override var hasFullAccess: Bool { debugFullAccess ?? super.hasFullAccess }
    /// Test: loại máy + needsInputModeSwitchKey giả (đoán phím 🌐 trước khung đầu — GlobeMemory).
    nonisolated(unsafe) static var debugIdiom: UIUserInterfaceIdiom?
    nonisolated(unsafe) static var debugNeedsSwitchKey: Bool?
    #endif

    private var deviceIdiom: UIUserInterfaceIdiom {
        #if DEBUG
        if let i = Self.debugIdiom { return i }
        #endif
        return UIDevice.current.userInterfaceIdiom
    }
    /// needsInputModeSwitchKey — chỉ đọc ở didAppear (đọc sớm hơn iOS in warning, giá trị chưa đáng tin).
    private var realNeedsSwitchKey: Bool {
        #if DEBUG
        if let v = Self.debugNeedsSwitchKey { return v }
        #endif
        return needsInputModeSwitchKey
    }
    #if DEBUG
    /// Test: nội dung lịch sử clipboard hiện có.
    var debugClipTexts: [String] { clip.items(now: Date().timeIntervalSince1970).map(\.text) }
    func debugToggleClipboardPanel() { toggleClipboardPanel() }
    var debugClipboardPanelOpen: Bool { clipPanel != nil }
    /// Test: "Sửa lỗi bằng Apple Intelligence" đang có AIAssist (tắt ⇒ nil, 0 chi phí).
    var debugAIActive: Bool { ai != nil }
    /// Test: tính lại thanh gợi ý (đường thật của mỗi phím).
    func debugUpdateSuggestions() { updateSuggestions() }
    func debugViewDidAppear() { viewDidAppear(false) }
    /// Test: số lượt updateSuggestions (mỗi lượt = tính lại cả thanh gợi ý trên main).
    var debugSuggestionPasses = 0
    var debugClipboardButtonVisible: Bool { keyboard.debugClipboardButtonVisible }
    /// Test (KeyboardRenderBudgetTests): model cá nhân đã tạo / layout vuốt đã gửi xuống decoder.
    var debugLangModelLoaded: Bool { langModelStorage != nil }
    var debugSwipeLayoutPushed: Bool { swipe?.layout != nil }
    #endif

    /// Clipboard hệ thống (test thay bằng clipboard giả).
    fileprivate var pasteboard: PasteboardSource {
        #if DEBUG
        if let p = debugPasteboard { return p }
        #endif
        return UIPasteboard.general
    }
    /// Toàn quyền đã áp ở viewWillAppear (nút 📋, rung) — viewDidAppear đối chiếu lại.
    private var appliedFullAccess = false
    private var hapticSetting = false

    #if DEBUG
    // Đo chi phí hiện bàn phím (Console filter "VTKB perf"): thân viewWillAppear,
    // thân viewDidAppear, khoảng will→did (gồm animation hệ thống), số lần rebuild.
    private var perfWillStart: CFTimeInterval = 0
    #endif

    override func viewWillAppear(_ animated: Bool) {
        #if DEBUG
        perfWillStart = CACurrentMediaTime()
        KeyboardView.perfFullBuilds = 0; KeyboardView.perfCacheSwaps = 0
        defer {
            NSLog("VTKB perf willAppear body %.2f ms",
                  (CACurrentMediaTime() - perfWillStart) * 1000)
        }
        #endif
        super.viewWillAppear(animated)
        StartupTrace.event("viewWillAppear")
        if FrameTrace.isEnabled {
            if appearTrace == nil, keyboard?.isTornDown ?? true { beginAppearTrace(.reshow) }
            FrameTrace.event("viewWillAppear")
        }
        appearance.willAppear()
        StartupTrace.span("willAppear") { configureForAppearance() }
        armSettleGuard()
    }

    /// Chuỗi callback hiện/ẩn (AppearanceCycle): chặn xé muộn + bù willAppear bị nuốt.
    private var appearance = AppearanceCycle()

    /// Chạm vào bàn phím mà cây phím đã bị xé (AppearanceCycle.needsHeal): host gắn lại input view
    /// cũ mà không gọi willAppear/didAppear ⇒ bàn phím TRỐNG trên màn hình. Chạm rơi vào view gốc
    /// (nền touchableClear) rồi lên controller qua responder chain ⇒ dựng + cấu hình lại ngay —
    /// chạm là bằng chứng chắc chắn bàn phím đang hiện (layout/callback host thì không: host có thể
    /// gọi chúng cả lúc ẩn, dựng lại lúc ẩn là mất tác dụng xé chống rò RAM).
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        revealContent(force: true)   // chạm lúc còn giữ ẩn (chờ chiều cao): hiện ngay
        if healIfShownTornDown("touch") { return }
        super.touchesBegan(touches, with: event)
    }

    /// true ⇒ đã dựng lại.
    @discardableResult
    private func healIfShownTornDown(_ reason: String) -> Bool {
        guard isViewLoaded,
              AppearanceCycle.needsHeal(tornDown: keyboard?.isTornDown ?? true, inWindow: view.window != nil)
        else { return false }
        TouchLog.write("appear: touched while torn down (\(reason)) → rebuild")
        appearance.healed()
        configureForAppearance()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return true
    }
    #if DEBUG
    /// Test: chạm vào view gốc (đường responder chain khi cây phím đã xé).
    func debugTouchRoot() { healIfShownTornDown("touch") }
    #endif

    /// Việc của lần hiện không cần cho khung đầu — chạy ngay sau commit khung đầu (StartupTrace.swift).
    private let postFrame = PostFrameWork()
    /// Lần hiện đang chờ khung đầu commit: warm-up nền (template vuốt, mô hình chạm, âm phím…)
    /// xin lúc này dời ra sau khung đầu (PostFrameWork) — main + lõi CPU dành cho dựng phím.
    fileprivate(set) var warmupsDeferred = false
    /// Chạy `work` ngay, hoặc sau commit khung đầu nếu lần hiện này chưa tới khung đầu.
    fileprivate func afterFirstFrame(_ work: @escaping () -> Void) {
        if warmupsDeferred { postFrame.schedule(work) } else { work() }
    }
    #if DEBUG
    var debugPostFramePending: Bool { postFrame.isPending }
    #endif

    /// Bề ngang + màn hình cho hình học lúc KeyboardView chưa layout: view gốc nếu host đã đặt
    /// khung, không thì màn hình (UIScreen theo hướng hiện tại — như applyAppearance đọc).
    private func appearanceLayoutHint() -> KeyboardView.LayoutHint {
        let screen = view.window?.windowScene?.screen.bounds.size ?? UIScreen.main.bounds.size
        let w = view.bounds.width > 0 ? view.bounds.width : screen.width
        return KeyboardView.LayoutHint(width: w, screen: screen.width > 0 ? screen : nil)
    }

    /// Toàn bộ cấu hình của một lần hiện (đọc cài đặt, trait ô, thanh gợi ý…). Chạy ở
    /// viewWillAppear; viewDidAppear chạy lại nếu lần hiện này chưa được cấu hình (willAppear
    /// không tới) hoặc cây view đã bị xé (didDisappear muộn) — Zalo vừa mở lại sau khi kill.
    private func configureForAppearance() {
        // Cùng controller hiện lại sau viewDidDisappear (cây view đã xé) → dựng mới, rồi phần
        // dưới áp lại toàn bộ cấu hình như lần hiện đầu.
        if keyboard.isTornDown { installKeyboard() }
        // Warm-up nền xin từ đây tới khung đầu ⇒ chạy sau khung đầu (afterFirstFrame). Việc này
        // xếp ĐẦU hàng PostFrameWork: mọi warm-up xếp sau vẫn chạy trong cùng lượt flush.
        warmupsDeferred = true
        postFrame.schedule { [weak self] in self?.warmupsDeferred = false }
        // Mọi rebuild() tới hết trait ô / theme / một tay gom thành MỘT lần dựng phím (kiểu cuối).
        keyboard.beginBatch()
        // Chiều cao xin host phải là chiều cao CUỐI ngay từ đây (host đo trước lượt layout đầu;
        // Zalo không dời thanh nhập theo lần đổi sau — tester 29/10/2026): bề ngang/màn hình đoán
        // cho lúc KeyboardView chưa layout + đoán phím 🌐 (iPhone nút Home) — didAppear sửa nếu sai.
        let hint = appearanceLayoutHint()
        keyboard.layoutHint = hint
        // Giá trị thật lần trước (GlobeMemory) thắng trên mọi loại máy — iPad hết dựng lại cả plane ở didAppear.
        if let g = KeyLayout.preFrameGlobeGuess(remembered: GlobeMemory.remembered(),
                                                phone: deviceIdiom == .phone, screen: hint.screen) {
            keyboard.setNeedsGlobe(g)
        }
        L10n.reload()   // ngôn ngữ giao diện app (uiLanguage) — một lần mỗi lần hiện
        TouchLog.loadSetting()
        // Lần hiện mới: không mang phần xin thêm (HostFill) của lần trước sang.
        hostFill.reset(); keyboard.hostFillExtra = 0; lastHostGeomKey = ""
        hostOversize.reset(); keyboard.heightNudge = 0
        // Đọc settings MỘT lần mỗi lần hiện (trước đây EngineBridge() tự load lần hai).
        let settings = KeyboardSettings.load()
        bridge = EngineBridge(settings: settings)  // fresh settings + buffer
        externalChangePending = false
        mirrored.invalidateMirror()               // ô / host mới: chưa biết chữ trước con trỏ
        lastKeyWasEmailTrigger = false
        restoreUndo = nil; undoOfferActive = false
        textToolUndo = nil
        keyboard.textToolsEnabled = settings.textToolsActive()   // Plus + công tắc người dùng
        translateTask?.cancel(); translateTask = nil; translateNotice = nil
        ai?.close(); ai = settings.aiProofread && PlusGate.isUnlocked(.aiProofread) ? makeAIAssist() : nil
        // Chip Dịch nằm trong danh sách Công cụ ⇒ tắt Công cụ là ẩn luôn.
        keyboard.translateChipLabel = TranslateText.isSupportedOS && PlusGate.isUnlocked(.translate)
            ? L("Dịch ↔ %@", TranslatePrefs.displayName(TranslatePrefs.target(UserDefaultsProvider.shared)))
            : nil
        // App sửa Từ điển cá nhân: chỉ ảnh hưởng model cá nhân (tạo lười / nạp sau khung đầu) ⇒
        // đối chiếu sau khung đầu, TRƯỚC warmUpData (cùng hàng PostFrameWork, theo thứ tự).
        postFrame.schedule { [weak self] in self?.checkExternalDictEdit() }
        // Lịch sử clipboard: chỉ đọc công tắc; file JSON đọc lười lần đầu cần (ClipboardHistory.raw).
        clip.load(from: UserDefaultsProvider.shared)
        pasteOnce.reload(offeredID: Self.loadPasteOffered())
        // Ẩn danh (thủ công, trong app): không học từ, không lưu clipboard.
        learnWordsSetting = settings.learnWords
        learnEnabled = settings.learnWords && !clip.incognito   // refreshFieldTraits tinh chỉnh theo ô
        suggestAnywaySetting = settings.suggestInNoSuggestFields
        appliedFullAccess = hasFullAccess
        keyboard.setClipboardButton(visible: clip.historyEnabled && appliedFullAccess)
        keyboard.keypadPasteEnabled = appliedFullAccess
        filterSensitive = settings.filterSensitive
        SwipeVocab.filterSensitive = settings.filterSensitive   // gõ vuốt theo cùng công tắc
        SwipeVocab.teencode = settings.teencode && !settings.vniMode   // er → ẻ (nét Telex)
        // Gõ tắt vuốt được (khoá + từ của nội dung): bảng đổi ⇒ template dựng lại một lần (nền).
        if settings.swipeTyping {
            if SwipeVocab.setShortcuts(bridge.effectiveShortcuts) { swipe?.refreshVocab() }
            bridge.onShortcutsChanged = { [weak self] in   // + Thay thế văn bản iOS
                if SwipeVocab.setShortcuts($0) { self?.swipe?.refreshVocab() }
            }
        }
        showSuggestionsSetting = settings.showSuggestions
        autoCapitalizeSetting = settings.autoCapitalize
        autoSpaceSetting = settings.autoSpaceAfterPunct
        autoSpacePunct = nil; autoSpaceUnderLetter = nil
        swipeSetting = settings.swipeTyping
        swipeEnglishSetting = settings.swipeEnglish
        swipeFutoSetting = settings.swipeFuto
        smartTouchSetting = settings.smartTouch
        autoCorrectSetting = settings.autoCorrect && !settings.vniMode
        wordTouches.removeAll(); wordTouchesOk = false; pendingTouch = nil; shownCorrection = nil
        // Thay thế văn bản iOS / danh bạ (tự sửa): nạp bất đồng bộ — khởi động SAU khung đầu.
        let wantsLexicon = autoCorrectSetting
        postFrame.schedule { [weak self] in
            guard let self else { return }
            StartupTrace.span("lexicons") {
                if wantsLexicon { self.loadSupplementaryLexicon() }
                self.loadSystemTextReplacements(settings)
            }
        }
        // Tắt ⇒ router không gọi prior (không closure, không cấp phát ở vùng biên phím).
        keyboard.letterPrior = smartTouchSetting ? { [weak self] in self?.smartTouchPrior() } : nil
        if smartTouchSetting { afterFirstFrame { TelexKeyPrior.warmUpInBackground() } }
        if !swipeSetting { swipe = nil }              // tắt ⇒ bỏ template (RAM)
        addTonesSetting = settings.addTonesChip && PlusGate.isUnlocked(.sentenceDiacritics)
        numberChipsSetting = settings.numberChips
        mathResultsSetting = settings.mathResults
        mathArmed = false; mathChip = nil
        emojiSuggestSetting = settings.emojiSuggest
        slotWant = SuggestionCount.resolved(settings.suggestionCount)
        pasteButtonSetting = settings.pasteButton
        spaceFlickSetting = settings.spaceSwipeLanguage && AppFlavor.vietnameseInput
        keyCommandsSetting = settings.swipeKeyCommands
        // Hồ sơ vừa chọn trong app (ONBOARDING-SPEC §3, hồ sơ "Chủ yếu tiếng Anh") ⇒ đặt ngôn ngữ
        // khởi đầu MỘT lần; sau đó vuốt phím cách đổi như thường. Một lần đọc chuỗi App Group.
        if let req = UserDefaultsProvider.shared?.string(forKey: KeyboardLanguageRequest.key),
           let lang = KeyboardLanguageRequest.pending(
            request: req, applied: UserDefaults.standard.string(forKey: KeyboardLanguageRequest.appliedKey)) {
            UserDefaults.standard.set(lang, forKey: KeyboardLanguage.storageKey)
            UserDefaults.standard.set(req, forKey: KeyboardLanguageRequest.appliedKey)
        }
        language = KeyboardLanguage.effective(
            stored: UserDefaults.standard.string(forKey: KeyboardLanguage.storageKey),
            flickEnabled: spaceFlickSetting)
        if language == .en { bridge.setEnglish(true, proxy: Proxy(p: textProxy)); warmUpEnglish() }
        keyboard.configureSpaceFlick(enabled: spaceFlickSetting, language: language)
        keyboard.trackpadSpeed = settings.trackpadSpeed
        keyboard.configureKeyAlternates(numbers: settings.longPressNumbers, symbols: settings.longPressSymbols,
                                        holdShift: settings.holdShiftSymbols)
        // Model cá nhân + mô hình âm tiết: sau khung đầu (getter langModel vẫn tạo lười nếu phím
        // tới trước — gõ ngay không mất gì, chỉ gợi ý tới muộn vài chục ms).
        postFrame.schedule { [weak self] in StartupTrace.span("warmUpData") { self?.warmUpData() } }
        swipeSuggest = nil
        recentEnglish = []; langRecent = []
        addTonesUndo = nil; addTonesDismissed = nil; addTonesCache = nil
        suggestionSnap = nil
        // Trait ô (layout, return key, passthrough, bar) — force: mỗi lần hiện áp lại
        // appearance/mẫu câu dù trait y hệt (batchConfigure tự dedupe rebuild).
        StartupTrace.span("fieldTraits") { refreshFieldTraits(force: true) }
        applyOneHandSetting()
        StartupTrace.span("buildKeys") { keyboard.endBatch() }
        TouchLog.session(header: TouchLogFormat.liveHeader(settings: settings, fullAccess: hasFullAccess),
                         fullAccess: hasFullAccess, traits: fieldTraits?.logDescription ?? "")
        logHostGeometry("willAppear")
        // Rung phím: cần cả toggle trong app LẪN Toàn quyền Truy cập (iOS
        // vô hiệu haptics trong extension không có Full Access).
        hapticSetting = settings.hapticFeedback
        KeyboardView.hapticsEnabled = settings.hapticFeedback && appliedFullAccess
        KeyHaptics.log = { TouchLog.write($0) }
        KeyHaptics.shared.setStrength(settings.hapticStrength)
        KeyHaptics.shared.resetFailures()   // lần hiện mới: thử Core Haptics lại dù lần trước lỗi
        StartupTrace.span("keySound") { applyKeySound(settings) }
        applySwipeSound(settings)
        // Báo trạng thái Full Access cho app chứa (ẩn banner nhắc cấp quyền).
        // Không Full Access thì iOS chặn GHI App Group → cờ giữ nguyên/vắng,
        // banner vẫn hiện — đúng ý.
        postFrame.schedule { [weak self] in StartupTrace.span("reportStatus") { self?.reportStatusToApp() } }
        keyboard.onShiftChange = { [weak self] in self?.shiftChanged() }
        keyboard.onSuggestion = { [weak self] item in
            guard let self else { return }
            if let ai = self.ai, ai.handleTap(item) { return }
            if item == KeyboardView.toolUndoToken { self.undoTextTool(); return }
            if item == KeyboardView.translateNoticeToken { self.tapTranslateNotice(); return }
            if let c = self.emailChips.first(where: { $0.label == item }) { self.acceptEmailChip(c); return }
            if self.urlChips.contains(where: { $0.label == item }) { self.acceptURLChip(item); return }
            self.textToolUndo = nil
            if item == KeyboardView.restoreToken { self.restoreWordSwipe() }
            else if item.hasPrefix(KeyboardView.clipTokenPrefix) {
                self.insertClip(String(item.dropFirst(KeyboardView.clipTokenPrefix.count)), chip: true)
            }
            else if item == KeyboardView.addTonesToken { self.applyAddTones() }
            else if item == KeyboardView.undoTonesToken { self.undoAddTones() }
            else if item == KeyboardView.undoReviseToken { self.undoSwipeRevision() }
            else if item == KeyboardView.undoAutoCorrectToken { self.revertAutoCorrect() }
            else if item.hasPrefix(KeyboardView.keepTypedPrefix) {
                self.keepTyped(String(item.dropFirst(KeyboardView.keepTypedPrefix.count)))
            }
            else if item == KeyboardView.retroOfferToken { self.retroChip(apply: true) }
            else if item == KeyboardView.undoRetroToken { self.retroChip(apply: false) }
            else if self.acceptSwipeAlternative(item) { return }
            else { self.acceptSuggestion(item) }
        }
        // Chạm ABC: đọc context lúc đó (". " tự thêm ở plane 123 ⇒ viết hoa) — XPC hiếm, không mỗi phím.
        keyboard.autoShiftProbe = { [weak self] in
            guard let self else { return nil }
            return FieldPolicy.autoShift(
                enabled: self.autoCapitalizeSetting,
                autocap: vtSafe(nil) { self.textProxy.autocapitalizationType ?? nil },
                before: { self.textProxy.documentContextBeforeInput ?? "" })
        }
        // "." "," ":" ở plane 123: ngay sau chữ số thì ở lại plane số ("2.5") — chỉ đọc lúc chạm ba phím đó.
        keyboard.contextBeforeProbe = { [weak self] in self?.textProxy.documentContextBeforeInput?.last }
        updateAutoShift()
        // Thanh gợi ý mở đầu (field trống → gợi ý từ đầu câu, nút Dán): ngay SAU khung đầu —
        // phím hiện trước, chữ trên thanh tới trong lúc bàn phím còn đang trượt lên.
        postFrame.schedule { [weak self] in StartupTrace.span("suggestions") { self?.updateSuggestions() } }
        keyboard.showLanguageBadge()   // "ViệtTelex" thoáng trên spacebar như stock
        keyboard.markConfigured()
    }

    /// Ghi kbFullAccess CHỈ khi đổi; heartbeat kbLastSeen tối đa 1 lần/giờ (app
    /// chỉ kiểm tra kbLastSeen > 0). Trước đây mỗi lần hiện ghi 2 key + synchronize()
    /// trên main. Bỏ synchronize(): lý do cũ là "extension bị suspend ngay sau đó"
    /// nhưng set() đã giao giá trị cho cfprefsd (daemon lo ghi đĩa) — process bị
    /// suspend/kill không làm mất; Apple cũng ghi rõ synchronize() không cần gọi.
    /// Không Full Access thì iOS chặn ghi → giá trị đọc lại không khớp mãi; memo
    /// theo process để không thử ghi lại mỗi lần hiện.
    /// Mốc "userlmResetAt" (App Group) lần hiện trước. App sửa Từ điển cá nhân / "Xoá từ
    /// đã học" ⇒ mốc đổi ⇒ bỏ bảng trong RAM, nạp lại file app vừa ghi (không ghi đè nó).
    private var seenDictResetAt: Double?
    private func checkExternalDictEdit() {
        let v = UserDefaults(suiteName: AppFlavor.appGroup)?.double(forKey: "userlmResetAt") ?? 0
        if let seen = seenDictResetAt, seen != v {
            langModelStorage?.reloadAfterExternalEdit()
            ctxCacheKey = nil
        }
        seenDictResetAt = v
    }

    private static var reportedFullAccess: Bool?
    private static var lastHeartbeatAttempt: TimeInterval = 0
    private func reportStatusToApp() {
        let fa = hasFullAccess
        let now = Date().timeIntervalSince1970
        let heartbeatDue = now - Self.lastHeartbeatAttempt > 3600
        guard Self.reportedFullAccess != fa || heartbeatDue else { return }
        guard let group = UserDefaults(suiteName: AppFlavor.appGroup) else { return }
        if Self.reportedFullAccess != fa {
            if group.object(forKey: "kbFullAccess") as? Bool != fa {
                group.set(fa, forKey: "kbFullAccess")
            }
            Self.reportedFullAccess = fa
        }
        if heartbeatDue {
            Self.lastHeartbeatAttempt = now
            if now - group.double(forKey: "kbLastSeen") > 3600 {
                group.set(now, forKey: "kbLastSeen")
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        probeField("disappear")
        probeReady = false
        #if DEBUG
        let perfStart = CACurrentMediaTime()
        defer {
            NSLog("VTKB perf willDisappear body %.2f ms", (CACurrentMediaTime() - perfStart) * 1000)
        }
        #endif
        KeystrokeCounter.flush()                 // số phím đã gõ → App Group (tắt ⇒ không làm gì)
        super.viewWillDisappear(animated)
        appearance.willDisappear()
        postFrame.cancel(); warmupsDeferred = false
        revealContent(force: true)
        pasteOnce.ended()   // ẩn bàn phím: lời mời dán đang hiện coi như đã bỏ qua
        closeClipboardPanel()
        ai?.close()
        learnSettledSwipe()
        swipe?.releaseFuto()  // FUTO Swipe (thử nghiệm): nhả ~2.5 MB khi ẩn
        KeySound.shared.shutdown()   // âm phím riêng: dừng engine khi ẩn (dựng lại lần hiện sau)
        SwipeSound.existing?.shutdown() // âm thanh nét vuốt: nhả engine + vòng lặp khi ẩn
        langModelStorage?.saveNow()   // extension có thể bị kill ngay sau disappear
    }

    /// Âm thanh phím: BẬT + Full Access ⇒ tiếng riêng (engine dựng nền), không kèm click hệ
    /// thống. TẮT hoặc thiếu Full Access ⇒ click hệ thống như cũ, không dựng engine (0 chi phí).
    /// Âm lượng 0 % ⇒ im hẳn (không quay về click hệ thống). Kiểu "iOS" (`system`) ⇒ click hệ
    /// thống, không engine, không cần Full Access.
    static func customKeySoundActive(setting: Bool, style: String, fullAccess: Bool) -> Bool {
        setting && fullAccess && KeySoundStyle.needsEngine(style)
    }

    private func applyKeySound(_ settings: KeyboardSettings) {
        let on = Self.customKeySoundActive(setting: settings.keySound, style: settings.keySoundStyle, fullAccess: hasFullAccess)
        KeyboardView.customSoundEnabled = on
        // Piano / Đàn tranh / Ghi-ta: nốt theo phím (resolve một lần lúc hiện, không mỗi phím); pedal về trạng thái nhả.
        let instrument = KeyInstrument.of(settings.keySoundStyle)
        KeyboardView.pianoEnabled = on && instrument != nil
        KeyboardView.pianoMap = instrument?.map ?? .piano
        KeyboardView.pianoPedal = PianoPedal()
        KeyboardView.chordProgression = ChordProgression(count: instrument?.map.progression.count ?? 0)
        KeySound.shared.setVolume(percent: settings.keySoundVolume)
        KeySound.shared.setStyle(settings.keySoundStyle)
        // Engine âm dựng nền SAU khung đầu (phím tới trước đó: play() trả false — im một tiếng,
        // không chặn, không ảnh hưởng chữ).
        if on && settings.keySoundVolume > 0 { afterFirstFrame { KeySound.shared.prepare() } } else { KeySound.shared.shutdown() }
    }

    /// "Âm thanh nét vuốt" — kiểu thực phát (thuần, test): cần gõ vuốt bật + Full Access (thiếu ⇒ audio extension
    /// không ổn định, như âm phím riêng), rồi SwipeSoundPolicy (Plus, nguồn điện thấp, âm lượng Âm thanh phím 0 ⇒ Tắt).
    static func swipeSoundStyle(setting: SwipeSoundStyle, swipeOn: Bool, fullAccess: Bool, plus: Bool,
                                lowPower: Bool, volumePercent: Int) -> SwipeSoundStyle {
        guard swipeOn, fullAccess else { return .none }
        return SwipeSoundPolicy.active(setting: setting, plus: plus, lowPower: lowPower, volumePercent: volumePercent)
    }

    /// Đọc MỘT lần mỗi lần hiện. Tắt ⇒ KeyboardView.swipeSound = nil, engine/buffer nhả (0 chi phí). Bật ⇒ chỉ ghi
    /// cấu hình; engine + vòng lặp dựng LƯỜI ở cú vuốt đầu (nền, không chặn main).
    private func applySwipeSound(_ settings: KeyboardSettings) {
        let setting = SwipeSoundStyle.load(UserDefaultsProvider.shared)
        let style = Self.swipeSoundStyle(setting: setting, swipeOn: swipeSetting, fullAccess: hasFullAccess,
                                         plus: SwipeSoundGate.allows(setting),
                                         lowPower: setting.isPlus && ProcessInfo.processInfo.isLowPowerModeEnabled,
                                         volumePercent: settings.keySoundVolume)
        guard style != .none else {
            KeyboardView.swipeSound = nil
            SwipeSound.existing?.shutdown()
            return
        }
        KeyboardView.swipeSound = SwipeSound.shared
        // Nốt nhạc theo phím: nhạc cụ của Âm thanh phím (Piano / Đàn tranh / Ghi-ta), kiểu khác ⇒ Đàn tranh.
        SwipeSound.shared.configure(style: style, volumePercent: settings.keySoundVolume,
                                    instrument: KeyInstrument.of(settings.keySoundStyle) ?? .dantranh)
        if style.needsLayout, let l = keyboard?.swipeLayout() {
            SwipeSound.shared.setLayout(centers: l.centers, keyWidth: l.keyWidth)
        }
    }

    /// Nạp NỀN dữ liệu tính năng đang BẬT (tắt ⇒ không nạp gì): model cá nhân + mô hình âm
    /// tiết vnlm.bin (bigram cho thanh gợi ý, trigram cho gõ vuốt — cùng một mmap); dạng không
    /// dấu (SwipeLexicon) chỉ cho gõ vuốt. vnlm: lần chạm đầu hash vnlexicon (~150KB) — đừng để
    /// rơi vào main.
    private func warmUpData() {
        let wantsLM = showSuggestionsSetting || swipeSetting || addTonesSetting
        if wantsLM { _ = langModel }
        // Lexicon tiếng Anh (bảng offset trên mmap, ~0,1 MB — RAM-AUDIT.md §4f): main thread
        // chỉ hỏi bản đã nạp (containsIfLoaded) ⇒ nạp sẵn ở nền để gợi ý / tự sửa đúng ngay từ đầu.
        if showSuggestionsSetting || autoCorrectSetting || addTonesSetting { SwipeEnglish.warmUp() }
        let swipeOn = swipeSetting
        // Dữ liệu vuốt / âm tiết tiếng Việt: app chỉ tiếng Anh không nạp (có thể không đóng gói).
        if (showSuggestionsSetting || swipeOn) && AppFlavor.vietnameseInput {
            Self.suggestQueue.async {
                _ = SyllableLM.shared
                if swipeOn { _ = SwipeLexicon.forms }
            }
        }
    }

    /// Ẩn hẳn: bỏ cache/đề xuất tạm (template gõ vuốt GIỮ — dựng lại mỗi lần hiện tốn CPU
    /// hơn; nhả khi hệ thống báo thiếu RAM) và XÉ cây view (RAM-AUDIT.md #1: UIKit giữ
    /// UIInputView cũ mãi ⇒ không xé thì mỗi lần hiện rò ~1,8 MB).
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // didDisappear MUỘN của lần ẩn đã bị một lần hiện chen ngang ⇒ KHÔNG xé (bàn phím đang
        // hiện sẽ rỗng tới lần mở sau).
        guard appearance.didDisappear() else {
            TouchLog.write("appear: late didDisappear while showing → keep view")
            return
        }
        swipeSuggest = nil
        addTonesCache = nil
        tearDownKeyboard()
    }

    private func tearDownKeyboard() {
        postFrame.cancel(); warmupsDeferred = false
        revealContent(force: true)
        closeClipboardPanel()
        NSLayoutConstraint.deactivate(keyboardEdges)
        keyboardEdges = []
        keyboard?.tearDown()
        // Phòng hờ: thứ gì khác từng gắn vào view gốc cũng gỡ (view gốc là thứ UIKit níu).
        KeyboardView.stripSubviews(of: view)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        langModelStorage?.saveNow()
        closeClipboardPanel()
        addTonesCache = nil
        // Plane số/ký hiệu/chữ đang nằm cache (dựng lại khi cần), bảng emoji, ảnh nền đã giải
        // (view đang hiện vẫn giữ ảnh của nó — cache tĩnh chỉ để lần hiện sau khỏi giải lại).
        keyboard?.dropCaches()
        Wallpaper.queue.async { Wallpaper.dropCache() }
        let visible = view.window != nil
        Self.purgeStaticCaches(visible: visible, activeBuddy: keyboard?.buddy?.character)
        keyboard?.spotlight?.purgeAtlasIfOffscreen()
        if !visible { swipe = nil }
        if !visible { KeySound.shared.shutdown() }
        if visible { SwipeSound.existing?.releaseIfIdle() } else { SwipeSound.existing?.shutdown() }
    }

    /// Cache tĩnh thêm từ giữa 10/2026 (RAM-AUDIT.md, 10/11/2026). Ẩn ⇒ bỏ hết; đang hiện ⇒ chỉ bỏ thứ KHÔNG trên màn
    /// hình (không bao giờ làm trống thứ user đang nhìn): tệp theme tải về (một mục = theme đang dùng ⇒ giữ khi hiện),
    /// atlas Bạn đồng hành (giữ nhân vật đang hiện), từ vựng vuốt (giữ chế độ lọc đang dùng), bộ nốt ngân nhạc cụ
    /// (chỉ dùng khi đạp pedal — nốt kế phát bản thường rồi dựng lại). Tất cả nạp lại lười ở lần dùng sau.
    static func purgeStaticCaches(visible: Bool, activeBuddy: BuddyCharacter?) {
        if !visible { ThemeAssetLoader.dropCache() }
        BuddyView.purgeAtlasCache(keeping: visible ? activeBuddy : nil)
        SwipeVocab.purge(keepActive: visible)
        KeySound.shared.releaseSustainBank()
    }

    // Host truyền .default là thường — dark/light thật nằm ở trait hệ thống,
    // đổi giữa chừng (auto dark theo giờ…) phải áp lại appearance.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            keyboard?.updateDark(presentationDark)
        }
    }

    /// Apple behavior: shift turns on at sentence start when the field asks for
    /// .sentences autocapitalization (empty context, or after ".!?" + space).
    private func updateAutoShift(fromHost: Bool = false) {
        // Tắt viết hoa đầu câu: chỉ hạ shift do chính mình bật trước đó (shift tay giữ nguyên).
        if !autoCapitalizeSetting, autoShiftOn { autoShiftOn = false; keyboard.setAutoShift(false) }
        var ctx: String?
        guard let auto = FieldPolicy.autoShift(
            enabled: autoCapitalizeSetting,
            autocap: vtSafe(nil) { self.textProxy.autocapitalizationType ?? nil },
            before: { let b = textProxy.documentContextBeforeInput ?? ""; ctx = b; return b }) else {
            autoShiftContext = nil
            return
        }
        // Tiếng vọng host của chính phím mình (textDidChange sau dấu cách tới trễ) mà người dùng đã
        // kịp chạm ⇧: context y như lần quyết định trước ⇒ không đè lựa chọn tay.
        if fromHost, FieldPolicy.hostEchoKeepsHandShift(byHand: keyboard.shiftTouchedByHand,
                                                        before: ctx, decidedOn: autoShiftContext) { return }
        autoShiftContext = ctx
        autoShiftOn = auto
        keyboard.setAutoShift(auto)
    }
    /// Chữ trước con trỏ ở lần quyết định auto-shift gần nhất (nil = đã gõ phím khác từ đó).
    private var autoShiftContext: String?

    /// Trait ô hiện tại (nil = chưa đọc lần nào trong phiên).
    private var fieldTraits: FieldTraits?
    private var showSuggestionsSetting = true
    private var autoCapitalizeSetting = true
    /// "Tự thêm dấu cách sau dấu câu" (AutoSpace) — tắt ⇒ không đọc context, không state.
    private var autoSpaceSetting = false
    /// Dấu câu/ngoặc vừa được thêm dấu cách tự động (sống tới phím kế).
    private var autoSpacePunct: Character?
    /// Phím chữ gõ ngay sau dấu cách tự thêm — iPad vuốt xuống / giữ ra dấu câu huỷ phím
    /// chữ đó (replaceLastLetter) thì dấu cách tự thêm lại nằm ngay trước con trỏ.
    private var autoSpaceUnderLetter: Character?

    /// Dấu cách tự thêm sau `p` còn nằm ngay trước con trỏ (host/người dùng chưa đổi gì)?
    private func autoSpaceStillThere(_ p: Character) -> Bool {
        (textProxy.documentContextBeforeInput ?? "").hasSuffix(String(p) + " ")
    }

    private func removeAutoSpace() {
        let was = applyingEdit
        applyingEdit = true
        textProxy.deleteBackward()
        applyingEdit = was
    }

    /// Sau phím chèn `s` (dấu câu, ký hiệu): thêm dấu cách nếu công tắc bật + ô cho phép
    /// + AutoSpace.shouldAdd; `carry` = dời dấu cách tự thêm ra sau ngoặc đóng vừa gõ.
    private func applyAutoSpace(after s: String, carry: Bool) {
        guard autoSpaceSetting, s.count == 1, let c = s.first,
              carry || AutoSpace.triggers.contains(c) else { return }
        guard fieldTraits?.allowsAutoSpace ?? true, !bridge.passthrough,
              vtSafe(false, { (self.textProxy as UITextInputTraits).isSecureTextEntry == true }) != true else { return }
        if !carry {
            guard AutoSpace.shouldAdd(punct: s, before: textProxy.documentContextBeforeInput ?? "",
                                      after: textProxy.documentContextAfterInput) else { return }
        }
        textProxy.insertText(" ")
        autoSpacePunct = c
    }

    /// Đọc trait ô và cấu hình lại bàn phím CHỈ khi trait đổi (hoặc `force` ở
    /// viewWillAppear). Host đổi ô trong cùng app không gọi viewWillAppear → gọi
    /// thêm ở textDidChange / selectionDidChange. KHÔNG đọc documentIdentifier.
    private var traitsRetryPending = false
    private func refreshFieldTraits(force forced: Bool = false) {
        // View chưa được áp cấu hình ô (KeyboardView mới dựng: thanh tắt, trong khi cache
        // controller mặc định "bật") ⇒ áp đầy đủ như lần hiện. Trước đây lần áp bắt buộc bị lỡ
        // (willAppear không tới / đọc trait lỗi) thì trait y hệt ⇒ không bao giờ bật thanh gợi
        // ý lại — mất cả phiên (Zalo mở lại sau khi kill, 16/10/2026).
        let force = forced || (keyboard.map { $0.suggestionsShownState != suggestionsActive } ?? false)
        let p = textProxy
        // iOS 27.0: đọc trait lúc proxy chưa sẵn sàng làm UIKit NÉM NSException
        // (_controllerState unrecognized selector) → bàn phím chết. Bắt lỗi, giữ trait
        // cũ và đọc lại sau một nhịp (crash thật 28/09/2026, build 1.2(7)).
        var read: FieldTraits?
        if let e = VTCatchException({
            read = FieldTraits(
                keyboardType: p.keyboardType ?? .default,
                returnKeyType: p.returnKeyType ?? .default,
                appearance: p.keyboardAppearance ?? .default,
                autocorrection: p.autocorrectionType ?? .default,
                contentType: p.textContentType ?? nil,
                secure: (p as UITextInputTraits).isSecureTextEntry == true)
        }) {
            TouchLog.write("traits: UIKit exception \(e.name.rawValue) — thử lại sau")
            if !traitsRetryPending {
                traitsRetryPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.traitsRetryPending = false
                    self?.refreshFieldTraits(force: force)
                }
            }
            return
        }
        guard let t = read else { return }
        let old = fieldTraits
        guard force || FieldTraits.needsReconfigure(old: old, new: t) else { return }
        fieldTraits = t
        if !force { TouchLog.traits(t.logDescription); pasteOnce.ended() }   // đổi ô
        // Ô URL/username/OTP: gõ literal. KHÔNG dựa vào autocorrect == .no —
        // Safari/Chrome/Spotlight tắt autocorrect ở ô tìm kiếm (xem FieldPolicy).
        // Ô email: Telex BẬT (tìm người nhận theo tên) + bảo vệ địa chỉ (EmailTokenGuard).
        // Đổi chế độ giữa từ → bỏ từ đang gõ (engine không còn khớp cách chèn).
        if bridge.passthrough != t.telexLiteral || bridge.emailField != t.emailCompose {
            bridge.reset()
            bridge.passthrough = t.telexLiteral
            bridge.emailField = t.emailCompose
        }
        // Omnibox (inline autocomplete tự viết lại chữ) / ô email (app đổi chữ thành chip người
        // nhận): không với lại từ đã chốt, không gõ tắt.
        bridge.reachBackAllowed = t.keyboardType != .webSearch && !t.emailCompose
        bridge.shortcutsAllowed = t.keyboardType != .webSearch && !t.emailCompose
        // Tự sửa: công tắc + loại ô (mật khẩu/email/URL/số/omnibox/ô tên ⇒ không).
        let ac = autoCorrectSetting && AutoCorrect.fieldAllows(t)
        if force || ac != autoCorrectActive {
            autoCorrectActive = ac
            bridge.autoCorrector = ac ? { [weak self] raw in self?.autoCorrection(raw) } : nil
        }
        // Một lần rebuild cho cả 3 (và 0 lần nếu field giống lần trước).
        keyboard.batchConfigure {
            keyboard.configureReturnKey(type: t.returnKeyType)
            keyboard.applyAppearance(t.appearance, style: presentationStyle)
            // configureInputKind nhảy plane (số/chữ) — chỉ gọi khi loại ô thật sự đổi
            // (hoặc lúc hiện), kẻo đang ở plane ký hiệu thì bị kéo về.
            // Bàn số lớn (NumericKeypad): ô OTP kiểu mặc định giữ inputKind .normal ⇒ so cả kiểu bàn số.
            let pad = UIDevice.current.userInterfaceIdiom == .pad
            let keypad = t.keypadStyle(isPad: pad)
            if force || old?.inputKind != t.inputKind || old?.keypadStyle(isPad: pad) != keypad {
                keyboard.configureInputKind(t.inputKind, keypad: keypad)
            }
        }
        // Thanh gợi ý: gate qua toggle trong app. Ô từ chối gợi ý chữ (autocorrection = .no:
        // thanh địa chỉ Safari…) mà không nhạy cảm ⇒ thanh CÔNG CỤ (☰/📋 + Dán + chip URL)
        // thay vì dải trống; mật khẩu/OTP/ẩn danh/bàn số giữ dải trống (StripMode).
        // #113 "Gợi ý cả khi ứng dụng tắt gợi ý" (mặc định bật): ô .no không nhạy cảm ⇒ gợi ý
        // đầy đủ, nhưng tự sửa vẫn tắt (allowsSuggestions false ở trên) và không học từ.
        let mode = StripMode.of(showSuggestions: showSuggestionsSetting, traits: t,
                                incognito: clip.incognito, suggestAnyway: suggestAnywaySetting)
        learnEnabled = StripMode.learns(learnWords: learnWordsSetting, traits: t, incognito: clip.incognito)
        lowercaseSuggestions = t.lowercaseSuggestions
        let active = mode.shown
        let modeChanged = mode != stripMode
        stripMode = mode
        // Tô nền gợi ý sửa (§8): cần điểm chạm như tự sửa — thanh tắt / ô không tự sửa ⇒ không ghi gì.
        let hint = active && mode == .full && !bridge.vniMode && AutoCorrect.fieldAllows(t)
        if force || hint != correctionHintActive || (ac || hint) != (keyboard.onLetterTouch != nil) {
            correctionHintActive = hint
            keyboard.onLetterTouch = ac || hint
                ? { [weak self] dx, dy in self?.pendingTouch = AutoCorrect.Touch(dx: dx, dy: dy) } : nil
        }
        if force || active != suggestionsActive || modeChanged {
            suggestionsActive = active
            // Strip giữ theo công tắc toàn cục: đổi sang ô không gợi ý không làm bàn phím
            // thấp/cao lại (host không luôn cấp lại ⇒ phím bị ép — bug 1.2.x).
            keyboard.setSuggestionsEnabled(active, reserveStrip: showSuggestionsSetting)
            // Đổi ô giữa chừng (selectionDidChange không tự vẽ lại bar): nội dung theo chế độ mới.
            if !force, active { updateSuggestions() }
        }
        updateSwipeEnabled()
    }

    /// Host báo text/selection sắp đổi từ NGOÀI handle() — chưa kết luận ngay (lúc
    /// textWillChange context THÁO DỞ); đánh dấu, đối chiếu ở textDidChange / phím kế.
    private var externalChangePending = false

    /// Đối chiếu từ đang gõ với chữ thật trước con trỏ (CompositionSync.verdict):
    /// còn khớp → GIỮ (host gán lại text mỗi phím, textWillChange đến muộn); lệch /
    /// không biết (nil) → reset như trước.
    @discardableResult
    private func syncComposition(_ event: String) -> CompositionSync.Verdict {
        externalChangePending = false
        // Tiếng vọng TRỄ của chính mình (host web view): context là trạng thái cũ ⇒ HostMirror
        // trả chữ host sẽ có khi xử lý xong lệnh của mình.
        let ctx = mirrored.hostReported()
        if TouchLog.enabled, mirrored.hostLagging { TouchLog.write("echo: stale own state (\(event)) → keep") }
        let composed = bridge.composedWord
        var selected: String?
        if #available(iOS 16.0, *) { selected = textProxy.selectedText }
        let verdict = CompositionSync.verdict(context: ctx, composed: composed, selectedText: selected)
        if TouchLog.enabled {
            let d = CompositionSync.diagnostic(context: ctx, composed: composed)
            TouchLog.sync("\(event) \(verdict)", ctxLen: d.len, suffix: d.suffix,
                          composingLen: composed.count)
        }
        if verdict != .keep {
            bridge.reset(); lastWord = nil; lastWord2 = nil
            langRecent = []
            restoreUndo = nil; undoOfferActive = false
            swipeTyped = nil; swipeTypedUndo = nil
        }
        // Con trỏ rời chữ vừa thay ⇒ bỏ "⌫ = hoàn tác" (chạm quay lại không hồi sinh).
        if let u = addTonesUndo, !CompositionSync.keepsUndo(context: ctx, result: u.replacement, selectedText: selected) {
            addTonesUndo = nil
        }
        if let u = textToolUndo, !CompositionSync.keepsUndo(context: ctx, result: u.result, selectedText: selected) {
            textToolUndo = nil
        }
        // Con trỏ rời "từ " của gợi ý vừa nhận ⇒ không hút dấu cách nữa (tiếng vọng trễ thì giữ).
        if let s = suggestionSnap, !CompositionSync.keepsUndo(context: ctx, result: s, selectedText: selected) {
            suggestionSnap = nil
        }
        return verdict
    }

    /// Callback host ngoài handle() là TIẾNG VỌNG của edit chính mình? Host kiểu web view
    /// (Gmail, WKWebView) báo textWillChange/selectionDidChange/textDidChange MUỘN sau MỖI
    /// lệnh sửa của bàn phím. Còn đang gõ dở sau khi đối chiếu (syncComposition reset nếu
    /// lệch) ⇒ chữ trước con trỏ vẫn là từ của mình: không đổi ô, không đổi ngữ cảnh — trait,
    /// auto-shift và gợi ý đã được handle() lên lịch cho phím đó ⇒ 0 việc thêm.
    /// Trước đây mỗi tiếng vọng: đọc lại trait + context (auto-shift) + tính lại CẢ thanh gợi
    /// ý đồng bộ trên main (đo 16/10/2026: ctx 0.27 → 2.45, gợi ý 1.00 → 2.02 lượt mỗi phím).
    private var hostChangeIsOwnEcho: Bool { bridge.isComposing }

    /// Thay đổi host (không phải tiếng vọng giữa từ): auto-shift + gợi ý tính lại, GỘP vào
    /// cùng lượt hoãn với phím (gen mới bỏ lượt cũ) — nhiều callback liền nhau chỉ tính một lần,
    /// và không chạy đồng bộ chen giữa hai phím.
    private func scheduleContextRefresh() {
        suggestionGen += 1
        let gen = suggestionGen
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.suggestionGen else { return }
            self.updateAutoShift(fromHost: true)
        }
        guard suggestionsActive else { return }
        suggestDebounceGen = gen
        suggestDebounce.schedule(after: 0.03)
    }

    override func textWillChange(_ textInput: UITextInput?) {
        // Thay đổi từ NGOÀI edit của mình (tap chỗ khác, đổi ô, host tự gán lại
        // text…). Edit của mình không gọi lại hàm này trong lúc handle() chạy.
        TouchLog.host("textWillChange", applyingEdit: applyingEdit, composing: bridge.isComposing)
        if TouchLog.enabled { probeHostEvents += 1 }
        if !applyingEdit, !trackpadActive { externalChangePending = true }
    }

    // Selection/con trỏ vừa đổi từ NGOÀI (select-all rồi gõ đè, tap chỗ khác,
    // app tự sửa text): quyết định giữ/bỏ từ đang gõ, đọc lại trait ô, tính lại
    // auto-shift như stock — select-all thì documentContextBeforeInput rỗng → viết
    // hoa chữ đầu. Không tính ở textWillChange vì lúc đó context THÁO DỞ.
    override func textDidChange(_ textInput: UITextInput?) {
        TouchLog.host("textDidChange", applyingEdit: applyingEdit, composing: bridge.isComposing)
        if TouchLog.enabled { probeHostEvents += 1 }
        guard !applyingEdit, !trackpadActive else { return }
        if externalChangePending { syncComposition("textDidChange") }
        if hostChangeIsOwnEcho { return }
        refreshFieldTraits()
        scheduleContextRefresh()
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        if !applyingEdit, !trackpadActive { externalChangePending = true }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        TouchLog.host("selectionDidChange", applyingEdit: applyingEdit, composing: bridge.isComposing)
        if TouchLog.enabled { probeHostEvents += 1 }
        guard !applyingEdit, !trackpadActive else { return }
        if externalChangePending { syncComposition("selectionDidChange") }
        if hostChangeIsOwnEcho { return }
        refreshFieldTraits()
        if ai != nil { scheduleContextRefresh() }   // vùng chọn đổi ⇒ chip ✨ (chỉ khi bật)
    }

    // MARK: chế độ một tay

    /// App (App Group) vừa đổi lựa chọn ⇒ theo app; không thì theo trạng thái bàn phím tự lưu.
    private func applyOneHandSetting() {
        let std = UserDefaults.standard
        let group = UserDefaultsProvider.shared?.string(forKey: OneHand.key)
        let seen = std.string(forKey: OneHand.seenGroupKey)
        let side = OneHand.resolve(group: group, seenGroup: seen, local: std.string(forKey: OneHand.key))
        if group != seen {
            std.set(group, forKey: OneHand.seenGroupKey)
            std.set(side.rawValue, forKey: OneHand.key)
        }
        if let last = std.string(forKey: OneHand.lastSideKey).flatMap(OneHandSide.init(rawValue:)), last != .off {
            keyboard.lastOneHandSide = last
        }
        keyboard.configureOneHand(side)
    }

    private var applyingEdit = false

    private struct Proxy: TextProxyLike {
        let p: UITextDocumentProxy
        /// Phím "xuống dòng không gửi" (KeyboardView.Key.lineBreak): "\n" ranh giới chèn qua
        /// LineBreak (kèm ký tự trước con trỏ trong cùng một insertText). nil = phím thường.
        var lineBreak: LineBreakTap? = nil
        final class LineBreakTap {
            /// Chuỗi vừa chèn ngay trước trong phím này (đối chiếu context host); nil = không biết.
            var last: String?
        }
        func insertText(_ text: String) {
            if let lb = lineBreak {
                if text == "\n" {
                    var plain = self
                    plain.lineBreak = nil
                    let plan = LineBreak.insert(proxy: plain, justInserted: lb.last)
                    if case .carry(let c) = plan { TouchLog.write("lineBreak: kèm \(c.count) ký tự") }
                    else { TouchLog.write("lineBreak: \\n trơn") }
                    lb.last = nil
                    return
                }
                lb.last = text
            }
            p.insertText(text)
        }
        func deleteBackward() { lineBreak?.last = nil; p.deleteBackward() }
        var isSecure: Bool { vtSafe(false) { (p as UITextInputTraits).isSecureTextEntry == true } }
        var contextBeforeInput: String? { p.documentContextBeforeInput }
        var contextAfterInput: String? { p.documentContextAfterInput }
        var hasSelection: Bool {
            if #available(iOS 16.0, *) { return p.selectedText?.isEmpty == false }
            return false
        }
    }

    /// Được xoá `expected` (đang nằm ngay trước con trỏ) bằng deleteBackward × N?
    /// Lệch → false và ghi log (không nội dung).
    private func canDeleteBefore(_ expected: String, what: String) -> Bool {
        let ok = CompositionSync.canDelete(expected.count, expected: expected,
                                           context: { textProxy.documentContextBeforeInput })
        if !ok { TouchLog.write("failsafe: \(what) expectedLen=\(expected.count) → skip delete") }
        return ok
    }

    private func handle(_ key: KeyboardView.Key) {
        FrameTrace.untilCommit("key")      // Instruments: phím → commit khung có kết quả
        let touch = pendingTouch           // điểm chạm của phím chữ này (tự sửa), dùng một lần
        pendingTouch = nil
        // ⌫ NGAY SAU khi thêm dấu = hoàn tác (một lần); phím khác bỏ lời mời hoàn tác.
        if case .backspace = key, addTonesUndo != nil, !bridge.isComposing, swipeSuggest == nil {
            suggestionSnap = nil
            undoAddTones()
            return
        }
        addTonesUndo = nil
        ai?.keyPressed()
        var proxy = Proxy(p: textProxy)
        // textWillChange tới mà textDidChange chưa kịp → đối chiếu ngay trước phím.
        if externalChangePending, !trackpadActive { syncComposition("key") }
        let snap = suggestionSnap          // chỉ phím NGAY sau khi nhận gợi ý (sync đã bỏ nếu con trỏ dời)
        suggestionSnap = nil
        // Gợi ý vừa chèn "từ " + phím . , ? ! ) / nháy đóng ⇒ "từ." như bàn phím gốc: xoá THẲNG dấu
        // cách của gợi ý (không ⌫ qua engine — ⌫ là mở lại từ / hoàn tác), rồi quên lần chốt.
        if let ins = snap, case .text(let s) = key,
           AutoSpace.snapsSuggestionSpace(s, before: textProxy.documentContextBeforeInput, inserted: ins) {
            removeAutoSpace()
            bridge.forgetLastCommit()
            restoreUndo = nil; undoOfferActive = false
        }
        // Tự thêm dấu cách sau dấu câu: phím ngay sau quyết định số phận dấu cách đó.
        var autoSpaceCarry = false
        let underLetter = autoSpaceUnderLetter
        autoSpaceUnderLetter = nil
        if let p = autoSpacePunct {
            autoSpacePunct = nil
            if autoSpaceStillThere(p) {
                switch key {
                case .space, .doubleSpacePeriod:
                    return                                // đã có dấu cách: nuốt, không thành 2
                case .backspace:
                    removeAutoSpace()                     // ⌫ chỉ xoá dấu cách tự thêm
                    lastInsertWasSpace = false
                    suggestionGen += 1
                    let gen = suggestionGen
                    DispatchQueue.main.async { [weak self] in
                        guard let self, gen == self.suggestionGen else { return }
                        self.updateAutoShift()
                        if self.suggestionsActive { self.updateSuggestions() }
                    }
                    return
                case .newline, .lineBreak:
                    removeAutoSpace()
                case .text(let s):
                    switch AutoSpace.reaction(toText: s) {
                    case .keep: break
                    case .remove: removeAutoSpace()
                    case .carry: removeAutoSpace(); autoSpaceCarry = true
                    }
                case .letter:
                    autoSpaceUnderLetter = p
                default: break
                }
            }
        }
        if translateNotice != nil || translateTask != nil {   // phím kế: bỏ thông báo + lượt dịch đang chờ
            translateTask?.cancel(); translateTask = nil; translateNotice = nil
        }
        if textToolUndo != nil {               // ⌫ ngay sau công cụ văn bản = hoàn tác
            if case .backspace = key { undoTextTool(); return }
            textToolUndo = nil
        }
        wordSwipeRestore = nil                 // ô "Khôi phục" chỉ sống tới phím kế
        learnSettledSwipe()                    // từ vuốt chốt bởi phím trước — giờ mới chắc
        let openAccepted = bridge.openWordAccepted   // từ vuốt chọn trên bar → weight 2
        // Sửa lại từ vuốt khi từ kế GÕ PHÍM: phím chữ/dấu cách chốt từ vuốt còn nguyên ⇒ chờ;
        // đang chờ ⇒ phím chữ / ⌫ trong từ gõ giữ, ranh giới thử sửa, phím khác bỏ.
        var typedWait = swipeTyped
        swipeTyped = nil
        swipeTypedUndo = nil
        if let w = typedWait, w.learned == nil, let l = lastLearned, l.word == w.rev.word {
            typedWait = (w.rev, l)             // dấu cách treo: từ vuốt vừa được học ở trên
        }
        let typedArm = typedArmCandidate(key)
        let composingBefore = bridge.isComposing
        var typedCommit: (word: String, boundary: String)?
        applyingEdit = true
        let t0 = TouchLog.enabled ? CACurrentMediaTime() : 0
        defer {
            applyingEdit = false
            if TouchLog.enabled {
                let kind: String
                var char: String?
                switch key {
                case .letter(let c): kind = "letter"; char = String(c)
                case .text(let t): kind = "text"; char = t
                case .space: kind = "space"
                case .doubleSpacePeriod: kind = "doubleSpace"
                case .backspace: kind = "backspace"
                case .newline: kind = "newline"
                case .lineBreak: kind = "lineBreak"
                case .moveCursor: kind = "cursor"
                case .moveLine: kind = "line"
                case .clearField: kind = "clear"
                case .replaceLastLetter(let t): kind = "flick"; char = t
                }
                TouchLog.key(kind: kind, composing: bridge.isComposing,
                             lagMs: (CACurrentMediaTime() - t0) * 1000, char: char)
                // Sau edit: độ dài context + context có kết thúc bằng từ đang gõ
                // (bắt host gán lại text / nuốt edit). Chỉ khi Debug mode bật.
                let composed = bridge.composedWord
                let d = CompositionSync.diagnostic(
                    context: textProxy.documentContextBeforeInput, composed: composed)
                TouchLog.sync("after-\(kind)", ctxLen: d.len, suffix: d.suffix,
                              composingLen: composed.count)
                probeKeys += 1
                if probeKeys % 10 == 1 { probeField("keys=\(probeKeys)") }
            }
        }
        switch key {
        case .letter(let ch):
            let fresh = !bridge.isComposing
            let fxBefore = fxComposeBefore()
            bridge.letter(ch, proxy: proxy)
            if let fxBefore { fxComposeDiff(fxBefore, typed: String(ch)) }
            restoreUndo = nil; undoOfferActive = false
            if autoCorrectActive || correctionHintActive { noteTouch(fresh: fresh, touch) }
        case .replaceLastLetter(let s):
            // Huỷ đúng phím chữ vừa gõ (không được thì ⌫ như cũ) rồi chèn như ký hiệu.
            if !bridge.undoLastLetter(proxy: proxy) { bridge.backspace(proxy: proxy) }
            if let q = underLetter, autoSpaceSetting {
                let r = AutoSpace.reaction(toText: s)
                if r != .keep, autoSpaceStillThere(q) { removeAutoSpace(); autoSpaceCarry = r == .carry }
            }
            let fxBefore = fxComposeBefore()
            if let d = Self.singleDigit(s), bridge.vniDigit(d, proxy: proxy) {
                // VNI: số vuốt xuống (iPad) trong từ = phím dấu
                if let fxBefore { fxComposeDiff(fxBefore, typed: s) }
            } else {
                let sb = bridge.symbolBoundary(s, proxy: proxy)
                fxCheer(word: sb, symbol: s)
                commitAndLearn(sb, accepted: openAccepted)
                lastWord = nil; lastWord2 = nil
                applyAutoSpace(after: s, carry: autoSpaceCarry)
            }
            restoreUndo = nil; undoOfferActive = false
        case .text(let s):                            // numbers, symbols
            // Bàn số lớn: số chèn THẲNG (không phải phím dấu VNI của từ đang gõ — từ được chốt).
            // Giữ ⇧ + phím chữ (ShiftHold): người dùng muốn SỐ ⇒ nguyên văn, không phải phím dấu VNI.
            let fxBefore = fxComposeBefore()
            if !keyboard.keypadShown, !keyboard.literalTextInFlight,
               let d = Self.singleDigit(s), bridge.vniDigit(d, proxy: proxy) {
                // VNI: số trong lúc soạn từ (hàng số / plane 123) mang dấu — phím của từ
                if let fxBefore { fxComposeDiff(fxBefore, typed: s) }
            } else {
                let final = bridge.symbolBoundary(s, proxy: proxy)
                if let fxBefore { fxComposeDiff(fxBefore, typed: s) }
                fxWordBoundary(final, prev: lastWord)
                fxCheer(word: final, symbol: s)
                keyboard?.buddy?.emojiInserted(s)
                commitAndLearn(final, accepted: openAccepted)
                lastWord = nil; lastWord2 = nil            // dấu câu/ký hiệu = ngắt câu
                typedCommit = (final, s)
                applyAutoSpace(after: s, carry: autoSpaceCarry)
            }
            restoreUndo = nil; undoOfferActive = false
        case .space:
            let composedBefore = bridge.composedWord
            let committed = bridge.boundary(" ", proxy: proxy)
            // Auto-restore vừa ghi đè dạng có dấu → nhớ lại cho backspace-undo.
            // (Gõ tắt vừa bung thì không: ⌫ kế tiếp tự trả lại chữ tắt trong bridge.)
            restoreUndo = (!composedBefore.isEmpty && committed != composedBefore
                           && !bridge.expandedAtLastBoundary)
                ? (raw: committed, composed: composedBefore) : nil
            undoOfferActive = false
            fxWordBoundary(committed, prev: lastWord)
            fxCheer(word: committed, end: true)
            commitAndLearn(committed, accepted: openAccepted)
            typedCommit = (committed, " ")
        case .doubleSpacePeriod:
            // Apple: double-space biến space vừa gõ thành ". ". ĐỌC context thật
            // (không phải hot path — gesture hiếm): điều kiện = đang có đúng " "
            // ở cuối và trước nó là ký tự chữ/số. State cũ (lastSpaceAfterText)
            // sai khi từ đã commit sớm → "đôi lúc không ra dấu chấm" (user).
            let ctx = textProxy.documentContextBeforeInput ?? ""
            if TypingHeuristics.doubleSpaceMakesPeriod(context: ctx, lastWasSpace: lastInsertWasSpace) {
                textProxy.deleteBackward()
                textProxy.insertText(". ")
                bridge.forgetLastCommit()         // space đã thành ". " → ⌫ không mở lại từ
                lastWord = nil; lastWord2 = nil
                fxCheer(word: "", symbol: ".")
            } else {
                let w = bridge.boundary(" ", proxy: proxy)
                fxCheer(word: w, end: true)
                commitAndLearn(w, accepted: openAccepted)
            }
            restoreUndo = nil; undoOfferActive = false
        case .moveCursor(let delta):
            bridge.reset()                        // caret moved → composition gone
            cheer.reset()
            lastWord = nil; lastWord2 = nil
            restoreUndo = nil; undoOfferActive = false
            if trackpadActive {
                // Giữ view context khớp chỗ con trỏ cho bước dọc sau (host trả context trễ).
                _ = trackpadContext.resolve(before: textProxy.documentContextBeforeInput ?? "",
                                            after: textProxy.documentContextAfterInput ?? "")
                trackpadContext.moved(by: delta)
            }
            textProxy.adjustTextPosition(byCharacterOffset: delta)
        case .moveLine(let lines):
            // Gần đúng: proxy không biết bố cục host — VerticalMove dựng lại dòng hiển thị
            // (ngắt cứng + tự ngắt theo ký tự/dòng ước lượng), giữ cột grapheme.
            bridge.reset()
            lastWord = nil; lastWord2 = nil
            restoreUndo = nil; undoOfferActive = false
            let ctx = trackpadContext.resolve(before: textProxy.documentContextBeforeInput ?? "",
                                              after: textProxy.documentContextAfterInput ?? "")
            if trackpadCharsPerLine == 0 { trackpadCharsPerLine = estimateCharsPerLine() }
            if let off = VerticalMove.offset(before: ctx.before, after: ctx.after, lines: lines,
                                             charsPerLine: trackpadCharsPerLine), off != 0 {
                trackpadContext.moved(by: off)
                textProxy.adjustTextPosition(byCharacterOffset: off)
            }
            if !trackpadActive { trackpadContext.reset() }
        case .newline, .lineBreak:
            // .lineBreak: chốt từ y như Return; chỉ cách chèn "\n" khác (LineBreak — kèm ký tự
            // trước con trỏ để WebKit không coi là phím Enter = Gửi).
            if case .lineBreak = key { proxy.lineBreak = Proxy.LineBreakTap() }
            let final = bridge.boundary("\n", proxy: proxy)
            proxy.lineBreak = nil
            fxCheer(word: final, end: true)
            commitAndLearn(final, accepted: openAccepted)
            lastWord = nil; lastWord2 = nil
            typedCommit = (final, "\n")
            restoreUndo = nil; undoOfferActive = false
        case .clearField:
            clearAllText()
            bridge.reset(); lastWord = nil; lastWord2 = nil
            restoreUndo = nil; undoOfferActive = false
        case .backspace:
            // Backspace NGAY SAU space có restore → xoá space và chào lại dạng
            // có dấu ở slot literal (trust fix cho collision kiểu "his"≡"hí").
            if !bridge.isComposing, lastInsertWasSpace, restoreUndo != nil {
                undoOfferActive = true
            } else {
                restoreUndo = nil; undoOfferActive = false
            }
            wordTouchesOk = false
            let acUndo = bridge.autoCorrectUndo
            if bridge.backspace(proxy: proxy) {
                // ⌫ mở lại từ vừa chốt: từ đó không còn là "từ trước" trong câu.
                lastWord = lastWord2; lastWord2 = nil
            }
            if !bridge.isComposing { lastWord = nil; lastWord2 = nil }  // xoá lấn vào chữ cũ → context mờ
            if let orig = bridge.revertedAutoCorrect {
                bridge.revertedAutoCorrect = nil
                autoCorrectReverted(orig, fixed: acUndo?.fixed)
            }
            if bridge.revertedRetro {             // ⌫ ngay sau tự sửa ngược = "Khôi phục"
                bridge.revertedRetro = false
                restoreUndo = nil; undoOfferActive = false
            }
        }
        if let a = typedArm {
            // phím chữ: dấu cách treo đã chốt từ vuốt (từ gõ bắt đầu); dấu cách: chốt đúng từ vuốt
            if case .letter = key, !bridge.isSwipeWordOpen, bridge.isComposing { swipeTyped = (a, nil) }
            if case .space = key, typedCommit?.word == a.word {
                swipeTyped = (a, lastLearned.flatMap { $0.word == a.word ? $0 : nil })
            }
        } else if let w = typedWait {
            if let c = typedCommit {
                if composingBefore, !bridge.englishMode {
                    reviseTypedSwipe(w, typed: c.word, boundary: c.boundary, proxy: proxy)
                }
            } else if bridge.isComposing {
                switch key {
                case .letter: swipeTyped = w
                case .backspace where composingBefore: swipeTyped = w
                case .text: if composingBefore { swipeTyped = w }     // VNI: số mang dấu trong từ
                default: break
                }
            }
        }
        // Chip số: chỉ đọc context khi vừa có chữ số/phép tính trong token này hoặc
        // token ngay trước ("2 tỷ", "1250000 ") — không trả XPC cho mọi phím chữ.
        switch key {
        case .text(let s), .replaceLastLetter(let s):
            numberSpaces = s.first.map { $0.isNumber || "=+-*/×÷:%().,".contains($0) } == true ? 0 : 99
        case .space, .doubleSpacePeriod: numberSpaces += 1
        case .backspace: numberSpaces = 0
        case .letter: break
        default: numberSpaces = 99
        }
        switch key {
        case .space, .doubleSpacePeriod: lastInsertWasSpace = true
        default: lastInsertWasSpace = false
        }
        if case .text(let s) = key, s == "@" || s == "." {
            lastKeyWasEmailTrigger = true
        } else {
            lastKeyWasEmailTrigger = false
        }
        // Kết quả phép tính (ô mật khẩu/URL/email: không): ngay sau "=", hoặc chip ngầm khi
        // phím vừa ra chữ số / ")" / "%" hay ⌫ (biểu thức có thể kết thúc ở con trỏ). Phím
        // khác / công tắc tắt ⇒ không đọc context.
        mathArmed = false
        if mathResultsSetting, fieldTraits?.allowsMathResults != false {
            switch key {
            case .text(let s), .replaceLastLetter(let s): mathArmed = s.last.map { $0.isASCII && ($0.isNumber || "=)%".contains($0)) } == true
            case .backspace: mathArmed = true
            default: break
            }
        }
        // updateAutoShift đọc documentContextBeforeInput (XPC) → cùng khối
        // async với suggestions, coalesce theo generation: gõ nhanh chỉ tính
        // cho phím cuối, ký tự không bao giờ chờ. Sound đã phát ở touch-down.
        let needsAutoShift: Bool
        switch key {
        case .space, .newline, .lineBreak, .doubleSpacePeriod, .backspace, .moveCursor, .moveLine, .clearField: needsAutoShift = true
        default: needsAutoShift = autoSpacePunct != nil      // ". " tự thêm ⇒ viết hoa chữ kế
        }
        if !needsAutoShift { autoShiftContext = nil }       // chữ đã đổi mà không quyết định lại
        suggestionGen += 1
        let gen = suggestionGen
        // Trackpad đang kéo: auto-shift + gợi ý tính một lần lúc nhả tay (trackpadChanged).
        if trackpadActive { return }
        // Auto-shift TỨC THÌ (ảnh hưởng chữ hoa của phím kế tiếp — không debounce
        // được, kẻo gõ nhanh sau ". " không kịp viết hoa).
        if needsAutoShift {
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.suggestionGen else { return }
                self.updateAutoShift()
            }
        }
        // Gợi ý hoãn ~30ms (gen bỏ lượt cũ nếu phím mới tới trước). Thực tế phím
        // cách nhau 100–200ms nên hiếm khi gộp — phần nặng (VNSuggest + sửa chạm
        // trượt) giờ chạy nền trong updateSuggestions, main chỉ re-rank + vẽ bar.
        // Bar tắt ⇒ không lên lịch gì (0 closure, 0 timer mỗi phím).
        guard suggestionsActive else { return }
        suggestDebounceGen = gen
        suggestDebounce.schedule(after: 0.03)
    }

    // MARK: tự sửa (AutoCorrect)

    /// Ghi điểm chạm phím chữ vừa gõ; `fresh` = phím đầu của từ mới.
    private func noteTouch(fresh: Bool, _ touch: AutoCorrect.Touch?) {
        acMemo = nil; shownCorrection = nil
        if fresh { wordTouches.removeAll(keepingCapacity: true); wordTouchesOk = true }
        if let touch { if wordTouchesOk { wordTouches.append(touch) } } else { wordTouchesOk = false }
        if wordTouches.count != bridge.rawWord.count { wordTouchesOk = false }   // nạp lại từ cũ, phím ngoài engine…
    }

    /// `EngineBridge.autoCorrector`: chỉ khi có đủ điểm chạm cho đúng các phím của từ. Thanh gợi ý
    /// đã vẽ cho đúng từ này ⇒ áp ĐÚNG ô đã tô (không tô ⇒ không sửa); chưa vẽ / thanh tắt ⇒ tính.
    private func autoCorrection(_ raw: String) -> String? {
        guard wordTouchesOk, wordTouches.count == raw.count else { return nil }
        if suggestionsActive, correctionHintActive, let s = shownCorrection, s.raw == raw { return s.fix }
        return correctionDecision(raw, plan: nil)
    }

    /// Quyết định tự sửa cho từ đang soạn `raw` — MỘT nguồn cho ô tô nền (thanh gợi ý) và dấu cách
    /// (ONBOARDING-SPEC §8): tính một lần cho mỗi bộ (phím thô, điểm chạm), lần sau dùng lại ⇒ dấu
    /// cách không bao giờ ra chữ khác ô đã tô. `plan`: phần thuần thanh gợi ý đã tính ở hàng đợi nền.
    private func correctionDecision(_ raw: String, plan: AutoCorrect.Plan?) -> String? {
        guard wordTouchesOk, wordTouches.count == raw.count else { return nil }
        if let m = acMemo, m.raw == raw { return m.fix }
        let b = bridge
        let pl = plan.flatMap { $0.raw == raw ? $0 : nil }
            ?? AutoCorrect.plan(raw: raw, compose: { b.composeTrial($0) },
                                frequency: { VNSuggest.frequency(of: $0) },
                                hasCompletion: { !VNSuggest.matches($0, poolLimit: 1).isEmpty })
        let fix = pl.flatMap {
            AutoCorrect.decide($0, touches: wordTouches, isKnown: { [self] w in
                // Từ Anh (AutoCorrect.isEnglish) không chặn main: lexicon chưa nạp xong ⇒ coi là
                // đã biết (không sửa) — an toàn hơn sửa nhầm một từ Anh.
                autoCorrectRejected.contains(w) || lexiconWords.contains(w)
                    || langModel.isUserWord(w) || (SwipeEnglish.containsIfLoaded(w) ?? true)
                    || EnglishContextLookup.opensEnglishRun(w)
            })
        }
        acMemo = (raw, fix)
        return fix
    }

    /// Chạm ô ngoặc kép cạnh ô tô nền (§8): giữ chữ đã gõ + không bao giờ tự sửa lại từ này.
    private func keepTyped(_ typed: String) {
        if autoCorrectRejected.add(typed) {
            UserDefaults.standard.set(autoCorrectRejected.encode(), forKey: Self.rejectedKey)
        }
        acMemo = nil
        acceptSuggestion(typed)
    }

    /// Chip sửa ngược tiếng Anh: `apply` = áp phép sửa đang mời ("His car is"), không thì
    /// "↩︎ Khôi phục" trả lại chữ trước lần tự sửa. Bridge kiểm chữ trước con trỏ, lệch ⇒ không sửa.
    private func retroChip(apply: Bool) {
        applyingEdit = true
        let proxy = Proxy(p: textProxy)
        _ = apply ? bridge.applyRetroOffer(proxy: proxy) : bridge.revertRetro(proxy: proxy)
        applyingEdit = false
        bridge.revertedRetro = false
        restoreUndo = nil; undoOfferActive = false
        KeyboardView.clickModifier()
        updateAutoShift()
        updateSuggestions()
    }

    /// Chip "↩︎ chữ gốc".
    private func revertAutoCorrect() {
        let fixed = bridge.autoCorrectUndo?.fixed
        applyingEdit = true
        let ok = bridge.revertAutoCorrect(proxy: Proxy(p: textProxy))
        applyingEdit = false
        if ok, let orig = bridge.revertedAutoCorrect {
            bridge.revertedAutoCorrect = nil
            autoCorrectReverted(orig, fixed: fixed)
        }
        KeyboardView.clickModifier()
        updateAutoShift()
        updateSuggestions()
    }

    /// Vừa trả lại chữ gốc: nhớ để không sửa lại, rút lượt học từ đã sửa, học chữ gốc.
    private func autoCorrectReverted(_ original: String, fixed: String?) {
        if autoCorrectRejected.add(original) {
            UserDefaults.standard.set(autoCorrectRejected.encode(), forKey: Self.rejectedKey)
        }
        acMemo = nil
        if let l = lastLearned, l.word == fixed {
            if let r = l.receipt { langModel.retract(r) }
            lastWord = l.prev1; lastWord2 = l.prev2
        }
        lastLearned = nil
        commitAndLearn(original)
    }

    /// Test cô lập (debugHermetic): release luôn false.
    private static var hermetic: Bool {
        #if DEBUG
        debugHermetic
        #else
        false
        #endif
    }

    /// Thay thế văn bản (Cài đặt → Bàn phím) + tên danh bạ: không cần Toàn quyền truy cập;
    /// iOS trả bất đồng bộ — nạp một lần mỗi phiên, chỉ khi tự sửa bật.
    private func loadSupplementaryLexicon() {
        guard lexiconWords.isEmpty, !Self.hermetic else { return }
        supplementaryLexicon.get { [weak self] pairs in
            var words: Set<String> = []
            for e in pairs {
                for s in [e.input, e.text] {
                    for w in s.lowercased().split(whereSeparator: { !$0.isLetter }) where w.count >= 2 {
                        words.insert(String(w))
                    }
                }
            }
            self?.lexiconWords = words
        }
    }

    /// Thay thế văn bản iOS làm gõ tắt (SystemTextReplacement): bất đồng bộ, ngoài đường
    /// hiện bàn phím; gộp vào bridge hiện tại khi có. Ghi snapshot cho app (cần Toàn quyền).
    private func loadSystemTextReplacements(_ settings: KeyboardSettings) {
        systemReplacements.load(settings: settings, bridge: { [weak self] in self?.bridge }) { [weak self] entries in
            guard let self else { return }
            TouchLog.write("system text replacement: \(entries.count)")
            if self.hasFullAccess {
                SystemTextReplacement.writeSnapshot(.init(entries), to: UserDefaultsProvider.shared)
            }
        }
    }

    /// "0"…"9" đơn lẻ (phím số) — ứng viên phím dấu VNI; ký hiệu khác ⇒ nil.
    private static func singleDigit(_ s: String) -> Character? {
        guard s.count == 1, let c = s.first, c.isASCII, c.isNumber else { return nil }
        return c
    }

    private var suggestionGen = 0
    /// Gợi ý hoãn ~30 ms sau phím: MỘT timer dùng lại (không cấp phát block/timer mỗi phím).
    /// `suggestDebounceGen` = gen lúc hẹn — có gen mới hơn mà không hẹn lại ⇒ bỏ lượt (như cũ).
    private lazy var suggestDebounce: MainDebouncer = {
        let d = MainDebouncer()
        d.action = { [weak self] in
            guard let self, self.suggestDebounceGen == self.suggestionGen else { return }
            self.updateSuggestions()
        }
        return d
    }()
    private var suggestDebounceGen = 0
    /// Công tắc phụ của thanh gợi ý (KeyboardSettings) — đọc mỗi lần hiện.
    private var addTonesSetting = false
    private var numberChipsSetting = true
    /// "Hiện kết quả phép tính" (KeyboardSettings.mathResults).
    private var mathResultsSetting = true
    private var emojiSuggestSetting = true
    /// Số ứng viên xin cho thanh gợi ý ("Số từ gợi ý", Tự động = 3). Bar có thể hiện ít hơn
    /// khi chật (SuggestionCount.fit) — phần dư bỏ, không tốn thêm gì ngoài ≤ 5 ứng viên.
    private var slotWant = SuggestionCount.autoSlots
    private var pasteButtonSetting = true
    /// Đang giữ phím cách di con trỏ (KeyboardView.onTrackpad) — xem trackpadChanged.
    private var trackpadActive = false
    /// Context host đã dời theo lệnh trackpad của mình (host cập nhật bất đồng bộ).
    private var trackpadContext = TrackpadContext()
    /// Ký tự/dòng hiển thị ước lượng cho kéo dọc — tính lúc bắt đầu kéo (0 = chưa).
    private var trackpadCharsPerLine = 0
    /// Câu mẫu đo một lần theo cỡ chữ (Dynamic Type): (category, bề rộng ký tự TB).
    private var trackpadAdvance: (UIContentSizeCategory, Double)?
    /// Số lượt updateSuggestions — kết quả nền chỉ áp nếu là lượt mới nhất.
    private var suggestReq = 0
    private static let suggestQueue = DispatchQueue(label: "com.viettelex.suggest",
                                                    qos: .userInitiated)
    private var lastInsertWasSpace = false
    private var autoShiftOn = false
    private var suggestionsActive = true
    /// Dải gợi ý ở ô hiện tại (StripMode): .tools = chỉ thanh công cụ + Dán + chip URL.
    private var stripMode = StripMode.full
    /// Chip URL đang hiện (ô URL / thanh địa chỉ ở chế độ .tools — URLChips); rỗng ở ô khác.
    private var urlChips: [URLChips.Chip] = []
    /// Cài đặt "Gợi ý cả khi ứng dụng tắt gợi ý" (KeyboardSettings.suggestInNoSuggestFields).
    private var suggestAnywaySetting = true
    /// KeyboardSettings.learnWords — learnEnabled tính lại theo ô (StripMode.learns).
    private var learnWordsSetting = true
    /// Ô địa chỉ / tìm kiếm (FieldTraits.lowercaseSuggestions): gợi ý chữ thường.
    private var lowercaseSuggestions = false
    /// Phím vừa gõ là "@" hoặc "." → rule email/TLD mới có thể ăn; chỉ khi đó
    /// mới đáng trả giá XPC đọc documentContextBeforeInput.
    private var lastKeyWasEmailTrigger = false
    /// Số dấu cách kể từ chữ số/phép tính cuối (≤1 → đáng đọc context tìm chip số).
    private var numberSpaces = 99
    /// Chip số đang hiện (đuôi cần thay + chữ chèn) — payload KeyboardView.numberToken.
    private var numberChip: NumberChip?
    /// Phím vừa gõ là "=" / chữ số / ")" / "%" / ⌫ (công tắc bật, ô cho phép) — chỉ khi đó
    /// mới đọc context tìm kết quả phép tính (MathResults); phím khác ⇒ 0 việc.
    private var mathArmed = false
    /// Chip kết quả phép tính đang hiện — payload KeyboardView.mathToken.
    private var mathChip: NumberChip?
    /// Chip đuôi mail đang hiện (ô email — EmailDomains); rỗng ở ô khác.
    private var emailChips: [EmailDomains.Chip] = []
    /// (raw đã chốt, dạng có dấu) khi auto-restore ghi đè — backspace ngay sau đó
    /// mở lại lối thoát: slot literal hiện dạng có dấu để 1 tap đổi từ.
    private var restoreUndo: (raw: String, composed: String)?
    private var undoOfferActive = false
    private var ctxCacheKey: String?
    private var ctxCache: Set<String> = []

    /// iOS defer touch gần mép ~1s để phân xử system gesture. Xin quyền nhận touch trước ở
    /// MỌI mép (trước chỉ .bottom — phím mép trái/phải vẫn chậm). Cờ này một mình không đủ
    /// trong extension (A/B 25/09/2026 hàng dưới) — phần chính là tắt delaysTouchesBegan của
    /// recognizer cổng hệ thống, xem KeyboardView.releaseSystemTouchDelays.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // needsInputModeSwitchKey chỉ đáng tin sau khi nối host — gọi 1 LẦN ở
    // viewDidAppear (gọi mỗi layout pass làm iOS 26 spam warning; đã dính).
    // Kết luận điều tra khoảng trống 2026-07-24: window extension = đúng chiều
    // cao mình xin, view phủ từ y=0 — dải tối phía trên là chrome container
    // iOS 26 do HOST vẽ, mọi bàn phím bên thứ ba đều có, không can thiệp được.
    /// Sáng/tối của lần hiện này — MỘT nguồn (AppearancePolicy.presentationDark): appearance của ô
    /// (fieldTraits) + trait của view. Mọi chỗ (willAppear, didAppear, layout, đổi trait) dùng chung.
    private var presentationStyle: UIUserInterfaceStyle {
        let v = isViewLoaded ? view.traitCollection.userInterfaceStyle : .unspecified
        return v == .unspecified ? traitCollection.userInterfaceStyle : v
    }
    private var presentationDark: Bool {
        AppearancePolicy.presentationDark(fieldAppearance: fieldTraits?.appearance, viewStyle: presentationStyle,
                                          controllerStyle: traitCollection.userInterfaceStyle)
    }

    override func viewDidAppear(_ animated: Bool) {
        if TouchLog.enabled {
            // Sau khi viewDidAppear xong (phiên nhập đã lập) mới đọc proxy.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.probeReady = true; self.probeKeys = 0; self.probePrev = nil; self.probeHostEvents = 0
                self.probeField("appear")
            }
        }
        #if DEBUG
        let perfDidStart = CACurrentMediaTime()
        defer {
            let now = CACurrentMediaTime()
            NSLog("VTKB perf didAppear body %.2f ms, will→did %.1f ms, fullBuilds=%d cacheSwaps=%d",
                  (now - perfDidStart) * 1000, (now - perfWillStart) * 1000,
                  KeyboardView.perfFullBuilds, KeyboardView.perfCacheSwaps)
        }
        #endif
        super.viewDidAppear(animated)
        StartupTrace.event("viewDidAppear")
        FrameTrace.event("viewDidAppear")
        StartupTrace.span("didAppear") { didAppearBody() }
    }

    private func didAppearBody() {
        postFrame.flush()   // thường đã chạy (sau khung đầu); chưa thì chạy nốt trước khi đối chiếu
        // Recognizer cổng cử chỉ hệ thống có thể gắn vào window sau didMoveToWindow ⇒ tắt
        // trì hoãn lần nữa khi đã hiện hẳn (phím mép trái/phải ăn ngay như phím giữa).
        KeyboardView.releaseSystemTouchDelays(for: view)
        if appearance.didAppear(tornDown: keyboard?.isTornDown ?? true) {
            TouchLog.write("appear: didAppear without config (torn=\(keyboard?.isTornDown == true ? 1 : 0)) → configure")
            configureForAppearance()
        }
        // Host khởi động lạnh: trait ô lúc viewWillAppear có thể còn là mặc định / chưa đọc
        // được — đọc lại khi đã hiện hẳn (đổi mới cấu hình lại; y hệt thì 0 việc).
        refreshFieldTraits()
        // Trait host đã resolve khi view vào window — sửa sáng/tối nếu lúc
        // viewWillAppear đoán sai (phím sáng trên nền tối).
        keyboard?.updateDark(presentationDark)
        let globe = realNeedsSwitchKey
        keyboard?.setNeedsGlobe(globe)
        GlobeMemory.record(globe)        // đoán trước khung đầu của lần hiện sau
        refreshFullAccessIfChanged()
        pushSwipeLayout(prepare: true)   // frame phím đã thật → dựng template ở nền
        // Ảnh lưới phím cho lần mở sau (KeySnapshot): chụp khi đã yên, chỉ khi khoá đổi; tắt ⇒ không làm gì.
        keyboard?.scheduleSnapshotCapture()
        // Clipboard có thể vừa đổi trong lúc bàn phím ẩn: tính lại bar khi đã hiện
        // hẳn (cache 2s của pasteOffer bỏ qua để đọc trạng thái mới).
        // Chỉ tính lại cả bar khi kết quả nút Dán ĐỔI so với lúc viewWillAppear
        // (thường không đổi) — tránh chạy trùng toàn bộ updateSuggestions.
        let pasteBefore = pasteCached
        pasteCheckedAt = .distantPast
        if suggestionsActive,
           bridge.composedWord.isEmpty, pasteOffer() != pasteBefore {
            updateSuggestions()
        }
        if let mb = Self.memoryFootprintMB() {
            NSLog("VTKB mem: %.1f MB", mb)   // Console filter "VTKB mem"
        }
        #if DEBUG
        dumpGeometry("didAppear")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.dumpGeometry("didAppear+1.5s")
        }
        #endif
    }

    #if DEBUG
    /// Dò hình học iOS 27 (dải kính host phủ đỉnh bàn phím). Đọc bằng:
    /// xcrun simctl spawn <udid> log show --last 5m \
    ///   --predicate 'subsystem == "com.viettelex.ios.keyboard.geom"' --style compact
    private func dumpGeometry(_ tag: String) {
        let log = OSLog(subsystem: "com.viettelex.ios.keyboard.geom", category: "geom")
        let w = view.window
        let inWindow = w.map { view.convert(view.bounds, to: $0) } ?? .zero
        os_log("[%{public}@] view.bounds=%{public}@ inWindow=%{public}@ window.bounds=%{public}@",
               log: log, type: .default, tag,
               NSCoder.string(for: view.bounds), NSCoder.string(for: inWindow),
               NSCoder.string(for: w?.bounds ?? .zero))
        os_log("[%{public}@] safeArea=%{public}@ additional=%{public}@ kbFrame=%{public}@ kbSafe=%{public}@",
               log: log, type: .default, tag,
               NSCoder.string(for: view.safeAreaInsets), NSCoder.string(for: additionalSafeAreaInsets),
               NSCoder.string(for: keyboard?.frame ?? .zero),
               NSCoder.string(for: keyboard?.safeAreaInsets ?? .zero))
        var chain: [String] = []
        var v: UIView? = view
        while let cur = v {
            chain.append("\(type(of: cur))\(NSCoder.string(for: cur.frame)) sa=\(NSCoder.string(for: cur.safeAreaInsets))")
            v = cur.superview
        }
        os_log("[%{public}@] chain: %{public}@", log: log, type: .default, tag,
               chain.joined(separator: " > "))
    }
    #endif

    /// RAM thực của extension (phys_footprint — đúng con số jetsam so với
    /// limit ~60-70MB của keyboard extension).
    private static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Mẫu câu từ burger menu: chèn nguyên văn, KHÔNG học vào model (câu
    /// nhiều từ sẽ làm bẩn unigram), reset engine như một lần dán.
    /// Mẫu dạng https:// = "mẫu động": fetch NGAY LÚC TAP, chèn raw response
    /// (cắt 1000 bytes, UTF-8 — DynamicSnippets.body). HTTP ≠ 200 / timeout / body rỗng
    /// → chèn chính URL. LƯU Ý: không Full Access thì iOS chặn network của
    /// keyboard extension → fetch fail → fallback chèn chính URL.
    private func insertTemplate(_ s: String) {
        if s.hasPrefix("https://"), let url = URL(string: s) {
            let req = URLRequest(url: url, timeoutInterval: DynamicSnippets.fetchTimeout)
            URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
                let status = (resp as? HTTPURLResponse)?.statusCode
                let body = DynamicSnippets.body(data: data, statusCode: status)
                DispatchQueue.main.async { self?.rawInsert(body ?? s) }
            }.resume()
            return
        }
        rawInsert(s)
    }

    private func rawInsert(_ s: String) {
        addTonesUndo = nil
        suggestionSnap = nil
        applyingEdit = true
        defer { applyingEdit = false }
        // Lệch (con trỏ đã dời) → không xoá gì, chỉ chèn mẫu tại con trỏ.
        let composed = bridge.composedWord
        if canDeleteBefore(composed, what: "template") {
            for _ in 0..<composed.count { textProxy.deleteBackward() }
        }
        textProxy.insertText(s)
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        KeyboardView.clickModifier()
        updateAutoShift()
        updateSuggestions()
    }

    /// Nút 🗑 plane mẫu câu: xoá SẠCH ô nhập. Không có API "clear all" —
    /// đẩy con trỏ về cuối rồi deleteBackward tới khi rỗng. documentContext*
    /// chỉ trả CỬA SỔ quanh con trỏ nên phải lặp; safety chặn treo ở field lạ.
    /// Fail-safe (CompositionSync): lượt nào context không đổi sau khi xoá/dời
    /// (host không cập nhật đồng bộ) thì dừng — không xoá mù 20k lần.
    private func clearAllText() {
        let p = textProxy
        CompositionSync.moveToEnd(contextAfter: { p.documentContextAfterInput },
                                  adjust: { p.adjustTextPosition(byCharacterOffset: $0) })
        CompositionSync.clearBefore(context: { p.documentContextBeforeInput },
                                    deleteBackward: { p.deleteBackward() })
    }

    /// Bubble ⚙️: mở tab Mẫu Câu trong app qua URL scheme viettelex://maucau.
    /// Keyboard extension không có UIApplication — đi responder chain tìm
    /// openURL: (pattern chuẩn của keyboard bên thứ ba).
    /// LƯU Ý: mở app chứa từ keyboard extension CHỈ chạy khi đã cấp Toàn quyền
    /// Truy cập (Full Access) — iOS chặn hoàn toàn nếu chưa cấp.
    private func openTemplatesInApp(_ host: String = "maucau") {
        guard let url = URL(string: "\(AppFlavor.urlScheme)://\(host)") else { return }
        let sel = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            // UIApplication vẫn nằm trong responder chain của extension —
            // ưu tiên API hiện đại, fallback selector cũ (openURL:).
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            if r.responds(to: sel) {
                r.perform(sel, with: url)
                return
            }
            responder = r.next
        }
        extensionContext?.open(url)   // đường chính thống, một số iOS chấp nhận
    }

    /// Xoá theo TỪ khi giữ backspace lâu (>3s) — gesture giữ, không phải hot
    /// path nên đọc proxy (XPC) mỗi từ là chấp nhận được.
    private func deleteWordBackward() {
        applyingEdit = true
        defer { applyingEdit = false }
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        let before = textProxy.documentContextBeforeInput ?? ""
        guard !before.isEmpty else { return }
        let count = WordDelete.charsToDelete(context: before, words: 1)
        for _ in 0..<max(count, 1) { textProxy.deleteBackward() }
        updateAutoShift()
        updateSuggestions()
    }

    /// "Emoji theo chữ" (KeyEffects.swift) + thả tim của Bạn đồng hành: CHỈ ở ranh giới từ, bằng từ vừa chốt — tra bảng O(1).
    /// Kiểu khác / tắt ⇒ một phép so sánh, không tra gì. Emoji bắn ở lượt vẽ kế của phím ranh giới.
    /// Bộ so cụm cổ vũ của Sút! — chỉ được nạp khi kiểu đang chọn là Sút!.
    private var cheer = CheerWords.Matcher()

    private func fxWordBoundary(_ word: String, prev: String?) {
        // Bạn đồng hành: phản ứng theo từ vừa chốt (tắt ⇒ nil, một optional).
        if let b = keyboard?.buddy, !word.isEmpty { b.wordCommitted(word, prev: prev, prev2: lastWord2) }
        guard let fx = keyboard?.keyEffects, fx.wantsBoundaryWord, !word.isEmpty else { return }
        // Từ khoá tự tạo của theme (ThemeFx): nổ THÊM, cùng mọi hiệu ứng. Theme không có ⇒ nil, không tra.
        if let table = fx.themeFx?.keywords, let i = table.lookup(word: word, prev: prev) { fx.queueThemeKeyword(i) }
        guard fx.effect.needsBoundaryWord else { return }
        if fx.effect == .keyword {
            guard swipeCombo.boundary(word) else { return }   // từ vuốt đã nổ lúc vuốt: không nổ lần hai
            if let k = KeywordBursts.lookup(word: word, prev: prev) { fx.queueKeyword(k) }   // Từ khoá: pháo đỏ / lì xì…
            return
        }
        if fx.effect == .reps {   // Rep (Gym): "gym", "tập", "beast mode"… ⇒ BEAST MODE
            if RepsFx.isKeyword(word: word, prev: prev, prev2: lastWord2) { fx.queueBeastMode() }
            return
        }
        if fx.effect == .rainbowburst {   // Tự hào: "love is love", "tự hào", "pride", "yêu là yêu" ⇒ cờ + tim
            if PrideKeywords.matches(word: word, prev: prev, prev2: lastWord2) { fx.queuePride() }
            return
        }
        guard let e = EmojiWords.lookup(word: word, prev: prev) else { return }
        fx.queueEmoji(e)
    }

    /// "Từ khoá" cho từ vuốt: từ vừa vuốt (đang mở) khớp bảng ⇒ chùm nổ ngay ở chỗ nhấc tay; phím ranh giới chốt đúng
    /// từ đó sau thì không nổ lại (SwipeKeywordCombo). Kiểu khác ⇒ một phép so sánh.
    private var swipeCombo = SwipeKeywordCombo()

    private func fxSwipeKeyword(_ word: String, path: SwipePath) {
        guard let fx = keyboard?.keyEffects, fx.effect == .keyword, path.count > 0, bridge.isSwipeWordOpen else { return }
        guard let k = swipeCombo.swiped(word, prev: lastWord) else { return }
        fx.queueKeyword(k)
        let j = path.count - 1
        fx.emit(at: CGPoint(x: CGFloat(path.xs[j]), y: CGFloat(path.ys[j]) + TouchGeometry.yOffset))
    }

    /// Sút! (theme Bóng đá): cụm cổ vũ vừa gõ xong ("việt nam vô địch", "vn #1", "vào", "goal"…) ⇒ pháo sáng + cờ ở lượt vẽ
    /// kế. Kiểu khác ⇒ một phép so sánh, không đọc gì. Giữ ≤ 6 token gần nhất (CheerWords.Matcher) — O(1) mỗi ranh giới.
    private func fxCheer(word: String, symbol: String? = nil, end: Bool = false) {
        guard let fx = keyboard?.keyEffects, fx.effect == .goal else { return }
        if cheer.feed(word: word, symbol: symbol, end: end) { fx.queueCheer() }
    }

    /// "Dấu thanh" / "Chữ bay" / "Token AI": từ đang soạn TRƯỚC phím — chỉ khi chọn ba kiểu đó (kiểu khác: một phép so sánh, 0 đọc).
    private func fxComposeBefore() -> String? {
        guard let fx = keyboard?.keyEffects, fx.effect.needsComposeDiff else { return nil }
        return bridge.composedWord
    }

    /// So với từ SAU phím ⇒ dấu vừa bỏ (ToneMarks) / đúng chữ vừa ra (FlyingLetters) — bắn ở lượt vẽ kế của phím này.
    private func fxComposeDiff(_ before: String, typed: String) {
        guard let fx = keyboard?.keyEffects else { return }
        let after = bridge.composedWord
        switch fx.effect {
        case .tone: if let t = ToneMarks.detect(before: before, after: after) { fx.queueTone(t) }
        case .letters: if let g = FlyingLetters.glyph(before: before, after: after, typed: typed) { fx.queueLetter(g) }
        case .tokens: if let g = FlyingLetters.glyph(before: before, after: after, typed: typed) { fx.queueToken(g) }
        default: break
        }
    }

    /// Từ vừa chốt: nạp vào model cá nhân + trượt cửa sổ context (prev2, prev1).
    /// `accepted` = user bấm nhận suggestion → weight 2 (tín hiệu mạnh hơn).
    private func commitAndLearn(_ word: String, accepted: Bool = false) {
        guard !word.isEmpty else { return }
        swipeCombo.reset()
        // Nội dung gõ tắt nhiều từ ("mọi người"): học lần lượt từng từ (bigram trong cụm).
        let parts = ShortcutLearning.words(word)
        if parts.count != 1 || parts.first != word {
            for p in parts { commitAndLearn(p, accepted: accepted) }
            if parts.isEmpty { lastWord = nil; lastWord2 = nil }
            return
        }
        let receipt = learnEnabled ? langModel.record(word: word, after: lastWord, prev2: lastWord2,
                                                      weight: accepted ? 2 : 1,
                                                      caseEvidence: casingEvidence(word)) : nil
        lastLearned = (word, receipt, lastWord, lastWord2)
        if UserLangModel.learnable(word) {
            lastWord2 = lastWord
            lastWord = word
            if swipe != nil, swipeEnglishSetting {   // tắt vuốt / vuốt tiếng Anh ⇒ 0 chi phí
                langRecent.append(word)
                if langRecent.count > SwipeLangContext.window { langRecent.removeFirst() }
            }
        } else {
            lastWord = nil; lastWord2 = nil
        }
    }

    /// Hoa/thường của `word` có được dạy bảng hoa/thường đã học không (UserLangModel CaseTable):
    /// chỉ GIỮA CÂU (lastWord còn — đầu ô / sau dấu câu / xuống dòng / dời con trỏ đã cắt nó),
    /// không do chuỗi tên riêng, và — chỉ khi từ CÓ chữ hoa (hiếm) mới đọc trait — ô không tự
    /// hoa mỗi từ / mọi chữ (.words: ô tên; .allCharacters). 0 chi phí thêm cho từ chữ thường.
    private func casingEvidence(_ word: String) -> Bool {
        guard DisplayCase.casingEvidence(word, prev: lastWord) else { return false }
        guard word.contains(where: { $0.isUppercase }) else { return true }
        let autocap = vtSafe(nil) { self.textProxy.autocapitalizationType ?? nil }
        return autocap != .words && autocap != .allCharacters
    }

    /// Gợi ý cho từ đang gõ: emoji (khớp cả "yêu" lẫn "love" — bảng
    /// EmojiSuggest) + hoàn thiện từ tiếng Việt từ VNLexicon ("nguoi"/"ng" →
    /// "người"): ưu tiên ứng viên chỉ khác dấu, rồi completion dài hơn.
    /// Đuôi email/domain phổ biến — rule cứng theo ngữ cảnh, không qua datastore
    /// (token chứa @/. không phải "từ" học được).
    private static let emailSuffixes = ["gmail.com", "yahoo.com", "outlook.com"]
    private static let domainTLDs = ["com", "vn", "net"]

    /// Shift cho hoa/thường gợi ý. Ô địa chỉ / tìm kiếm: bỏ Shift một-lần (gợi ý chữ
    /// thường) — Caps Lock vẫn theo.
    private var suggestionShift: SuggestionCase.Shift {
        let s = keyboard?.suggestionShift ?? .off
        return lowercaseSuggestions && s == .once ? .off : s
    }
    /// Shift lúc vẽ bar lần cuối — đổi Shift mà bar đã đúng thì khỏi tính lại.
    private var barShift: SuggestionCase.Shift = .off
    private var shiftRefreshQueued = false

    /// Hoa/thường theo Shift + chữ đang gõ (SuggestionCase, như Gboard): Shift một-lần /
    /// đầu câu ⇒ "Em, Anh, Tôi"; Caps Lock ⇒ "EM"; đang gõ "Bê" ⇒ "Bên".
    private func caseForContext(_ w: String, typed: String = "") -> String {
        let base = lowercaseSuggestions ? w.lowercased() : w
        return SuggestionCase.display(base, shift: suggestionShift, typed: typed)
    }

    /// DisplayCase (tên riêng) + hoa/thường người dùng đã viết nhất quán (UserLangModel.learnedCase)
    /// — trừ ô địa chỉ / tìm kiếm: chữ thường (song sinh Android).
    private func displayCase(_ w: String, after prev: String? = nil) -> String {
        lowercaseSuggestions ? w.lowercased() : properCase(w, after: prev)
    }

    /// Dạng tên riêng của ứng viên: học được > DisplayCase; từ đã có chữ hoa (thêm tay) giữ nguyên.
    private func properCase(_ w: String, after prev: String? = nil) -> String {
        let lm = langModel
        return DisplayCase.resolve(w, after: prev, learned: { lm.learnedCase($0) })
    }

    /// Shift/Caps đổi (KeyboardView.onShiftChange): vẽ lại bar NGAY như Gboard — gộp
    /// về một lượt sau runloop; bỏ qua nếu bar đã vẽ với Shift này (phím chữ vừa nhả
    /// Shift thì lượt gợi ý của chính phím đó đã tính) hoặc đang gõ dở mà không dính
    /// Caps Lock (hoa/thường lúc đó theo chữ đã gõ).
    private func shiftChanged() {
        guard !shiftRefreshQueued else { return }
        shiftRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shiftRefreshQueued = false
            guard !self.applyingEdit, self.suggestionsActive else { return }
            let s = self.suggestionShift
            guard s != self.barShift else { return }
            if !self.bridge.composedWord.isEmpty, s != .capsLock, self.barShift != .capsLock {
                self.barShift = s
                return
            }
            self.updateSuggestions()
        }
    }

    /// Đệm danh sách gợi ý cho ĐỦ `need` phần tử bằng từ hay dùng nhất (loại
    /// trùng + từ đang gõ) — bar luôn đủ 3, không bao giờ trống/khuyết
    /// (user 2026-07-25). Model đã seed nên topWords luôn đủ.
    /// `afterWord` = ô "từ kế tiếp" sau `lastWord`: từ trước tiếng Anh ⇒ không đệm topWords mà lấp
    /// bằng bảng từ kế tiếp tiếng Anh `EnglishNext` (#146, `SuggestRank.padsWithTopWords` /
    /// `englishNextFill`).
    private func padWords(_ base: [String], need: Int, typed: String = "", afterWord: Bool = false) -> [String] {
        guard base.count < need else { return Array(base.prefix(need)) }
        // Main thread: không bao giờ nạp lexicon tiếng Anh ở đây — chưa nạp xong (vài ms đầu phiên,
        // warmUpData nạp nền) ⇒ coi như không phải từ Anh (đệm như sau âm tiết Việt).
        if afterWord, let prev = lastWord, !SuggestRank.padsWithTopWords(prev, english: bridge.englishMode,
                                                                         isEnglish: { SwipeEnglish.containsIfLoaded($0) ?? false }) {
            let p2 = lastWord2, fs = filterSensitive
            return SuggestRank.englishNextFill(base, table: EnglishNext.next(after: prev), need: need, typed: typed,
                                               filter: { SensitiveWords.filter($0, after: prev, prev2: p2, enabled: fs) },
                                               display: { caseForContext(properCase($0), typed: typed) })
        }
        let top = bridge.englishMode ? (SwipeEnglish.topIfLoaded ?? []) : langModel.topWords(limit: need + 12)
        let candidates = SensitiveWords.filter(top, after: lastWord, prev2: lastWord2, enabled: filterSensitive)
            .map { caseForContext(properCase($0), typed: typed) }
        return SuggestionFill.pad(base, with: candidates, need: need, excluding: typed)
    }

    private func updateSuggestions() {
        #if DEBUG
        debugSuggestionPasses += 1
        #endif
        // Bar tắt HOẶC đang thu gọn → khỏi tính toán gì hết (VNSuggest,
        // re-rank, emoji, nextWords) — tiết kiệm CPU/RAM theo đúng nghĩa.
        suggestReq += 1                  // lượt mới → kết quả nền cũ (nếu có) bỏ
        barShift = suggestionShift
        guard suggestionsActive else { return }
        let composed = bridge.composedWord
        var set = KeyboardView.SuggestionSet()
        numberChip = nil; mathChip = nil; emailChips = []; urlChips = []
        // Ô từ chối gợi ý chữ (không nhạy cảm): chỉ thanh công cụ — lời mời Dán + chip URL.
        if stripMode == .tools {
            showToolsOnly(composing: !composed.isEmpty)
            return
        }
        // Ô URL / tìm kiếm ở chế độ đầy đủ (gợi ý bất chấp app, #113): chip URL chỉ ở "vị trí
        // tên miền" (ô trống / token có "." hoặc "://"), còn lại gợi ý chữ.
        if fieldTraits?.wantsURLChips == true {
            let p = textProxy
            let before = p.documentContextBeforeInput ?? "", after = p.documentContextAfterInput ?? ""
            if StripMode.prefersURLChips(before: before, after: after),
               !URLChips.chips(before: before, after: after).isEmpty {
                showToolsOnly(composing: !composed.isEmpty)
                return
            }
        }
        // Ô email (literal): thanh chỉ hiện chip đuôi mail sau "@" ("@gmail.com" trước) —
        // đọc context mỗi phím CHỈ ở ô email; ô khác không qua nhánh này.
        if fieldTraits?.inputKind == .email {
            emailChips = textProxy.documentContextBeforeInput
                .map { EmailDomains.chips(before: $0) } ?? []
            keyboard.showSuggestions(.init(nextWords: emailChips.map(\.label)))
            return
        }
        // Ngay sau vuốt: phương án khác (biến thể dấu + dạng không dấu hạng 2/3) —
        // chỉ khi từ vuốt còn mở và chưa bị sửa.
        if let s = swipeSuggest {
            if bridge.isSwipeWordOpen, composed == s.current {
                keyboard.hidePasteCard()
                set.nextWords = s.alts
                if let u = swipeReviseUndo {
                    set.actionLabel = "\u{21A9}\u{FE0E} \(u.old)"
                    set.actionPayload = KeyboardView.undoReviseToken
                }
                keyboard.showSuggestions(set)
                return
            }
            swipeSuggest = nil
            swipeReviseUndo = nil
        }
        // Backspace-undo sau auto-restore: chào dạng có dấu ở slot literal.
        if composed.isEmpty, undoOfferActive, let u = restoreUndo {
            set.literal = u.composed
        }
        if composed.isEmpty, wordSwipeRestore != nil { set.restoreLabel = L("\u{21A9}\u{FE0E} Khôi phục") }
        if composed.isEmpty, textToolUndo != nil {
            set.restoreLabel = L("\u{21A9}\u{FE0E} Hoàn tác")
            set.restorePayload = KeyboardView.toolUndoToken
        }
        // Ngữ cảnh email/domain: "phuc@" → gợi đuôi mail; "github." → gợi TLD.
        // Đọc proxy (XPC) chỉ khi phím vừa gõ là @/. — không phải mọi boundary.
        if composed.isEmpty, lastKeyWasEmailTrigger,
           let before = textProxy.documentContextBeforeInput,
           let last = before.split(separator: " ").last {
            if last.hasSuffix("@"), last.count > 1 {
                keyboard.showSuggestions(.init(nextWords: Self.emailSuffixes))
                return
            }
            if last.hasSuffix("."), last.count > 1,
               last.dropLast().allSatisfy({ $0.isLetter || $0.isNumber }) {
                keyboard.showSuggestions(.init(nextWords: Self.domainTLDs))
                return
            }
        }
        if !composed.isEmpty {
            keyboard.hidePasteCard()   // có phím chữ → thẻ Dán biến mất ngay (user 25/09/2026)
            // VNSuggest + AdjacentKeyFixer chạy NỀN (fixer tới vài ms với từ lạ như
            // "keyboard"/"github"); main chỉ re-rank (model cá nhân) + vẽ bar. Kết
            // quả chỉ áp khi còn hiện hành: không có lượt updateSuggestions mới hơn,
            // không có phím mới (suggestionGen), cùng bridge + cùng từ đang gõ.
            let req = suggestReq, gen = suggestionGen, b = bridge
            let raw = b.rawWord, predicted = b.predictedCommit, wantFix = b.autoFixAdjacent
            let prev = lastWord, prev2 = lastWord2, english = b.englishMode
            // Tô nền gợi ý sửa (§8): từ không khớp gì ⇒ tính luôn phần thuần của tự sửa ở nền.
            let wantPlan = correctionHintActive && wordTouchesOk && !english
            Self.suggestQueue.async { [weak self] in
                // Chế độ Tiếng Anh: hoàn thành từ enlexicon, không sửa chạm trượt / bigram Việt.
                let pool = english ? SwipeEnglish.completions(composed, limit: 24)
                    : VNSuggest.matches(composed, poolLimit: 24, excluding: composed.lowercased())
                let fix = !english && pool.isEmpty && wantFix
                    ? AdjacentKeyFixer.lexiconCorrection(raw: raw, bridge: b) : nil
                // trượt vào phím thanh mà vẫn ra từ ("casn" → cán, ý là cân)
                let slip = fix == nil && wantFix ? AdjacentKeyFixer.lexiconToneSlip(raw: raw, bridge: b) : nil
                // trigram/bigram âm tiết tĩnh theo 1–2 từ trước (mmap dùng chung với gõ vuốt; tra ~µs)
                let pmi = english ? nil : SuggestRank.inlinePmi(pool, prev: prev, prev2: prev2)
                // Từ tiếng Anh giữa câu Việt (EnglishAssist): hoàn thành / sửa chính tả theo phím
                // thô; từ rõ là tiếng Việt ⇒ nil trước khi chạm lexicon tiếng Anh.
                let en = english || !EnglishAssist.eligible(raw: raw) ? nil
                    : EnglishAssist.suggest(raw: raw, composed: composed, pool: pool,
                                            typedFreq: VNSuggest.frequency(of: composed))
                let plan = wantPlan && pool.isEmpty
                    ? AutoCorrect.plan(raw: raw, compose: { b.composeTrial($0) },
                                       frequency: { VNSuggest.frequency(of: $0) },
                                       hasCompletion: { !VNSuggest.matches($0, poolLimit: 1).isEmpty })
                    : nil
                DispatchQueue.main.async {
                    guard let self, req == self.suggestReq, gen == self.suggestionGen,
                          self.bridge === b, b.composedWord == composed,
                          self.suggestionsActive
                    else { return }
                    self.showComposingSuggestions(composed: composed, raw: raw, predicted: predicted,
                                                  pool: pool, pmi: pmi, fix: fix, slip: slip, english: en,
                                                  plan: plan)
                }
            }
            return
        } else if bridge.englishMode {
            // Tiếng Anh: từ kế tiếp cá nhân chỉ giữ từ tiếng Anh; đầu ô đệm bằng từ Anh phổ biến,
            // sau một từ thì KHÔNG (#146: "they" → "the of and" là top unigram, không phải ngữ cảnh)
            let personal = lastWord.map { langModel.nextWords(after: $0, prev2: lastWord2, limit: 12) } ?? []
            let en = SensitiveWords.filter(personal.filter { SwipeEnglish.containsIfLoaded($0.lowercased()) ?? false },
                                           after: lastWord, prev2: lastWord2, enabled: filterSensitive).prefix(slotWant)
            set.nextWords = padWords(en.map { caseForContext($0) }, need: slotWant, afterWord: true)
        } else if let prev = lastWord {
            // vừa space sau một từ → gợi từ KẾ TIẾP (SuggestRank.nextFill): có trigram tĩnh
            // (prev2, prev) ⇒ bộ ba người dùng đã gõ, rồi trigram, rồi cá nhân/seed; không ⇒
            // cá nhân/seed trước, lấp bằng bigram tĩnh; rồi mới tới topWords
            let p2 = lastWord2, lm = langModel, fs = filterSensitive
            // + chuỗi seed ba từ (SensitiveWords.chain — "óc bã" → đậu; lọc bật bỏ bộ ba nhạy cảm)
            let personal = SensitiveWords.filter(lm.nextWords(after: prev, prev2: p2, limit: 6), after: prev, prev2: p2, enabled: fs)
            let chain = SensitiveWords.filter(SensitiveWords.chain(after: prev, prev2: p2), after: prev, prev2: p2, enabled: fs)
            let next = SuggestRank.nextFill(prev, prev2: p2, personal: personal,
                                            triCount: { w in p2.map { lm.trigramCount($0, prev, w) } ?? 0 },
                                            filter: { SensitiveWords.filter($0, after: prev, prev2: p2, enabled: fs) },
                                            need: slotWant, chain: chain)
            set.nextWords = padWords(next.map { caseForContext(properCase($0, after: prev)) }, need: slotWant, afterWord: true)
        } else {
            // field trống chưa gõ gì → từ user hay mở đầu nhất
            let top = SensitiveWords.filter(langModel.topWords(limit: max(6, slotWant + 3)),
                                            enabled: filterSensitive)
                .prefix(slotWant).map { caseForContext(properCase($0)) }
            set.nextWords = padWords(Array(top), need: slotWant)
        }
        set.number = refreshNumberChip(idle: composed.isEmpty)
        set.math = refreshMathChip()
        if composed.isEmpty, pasteOffer() {
            // Nút Dán tắt: vẫn ghi lịch sử + chip tách số (thuộc Lịch sử clipboard).
            set.paste = pasteButtonSetting; set.pasteIsImage = pasteIsImage
            let chips = fieldClipChips()
            // Chip tách số (≤2) + ô "Dán" nguyên văn ở cuối: SuggestionSlots.arrange.
            set.clipChips = chips.map { ($0.label, KeyboardView.clipTokenPrefix + $0.value) }
        }
        // Thêm dấu: "Hoàn tác" (vừa bấm) thắng thẻ Dán; "Thêm dấu" nhường thẻ Dán
        // (thứ tự slot: SuggestionSlots.arrange).
        if composed.isEmpty, set.literal == nil, !bridge.englishMode || addTonesUndo != nil {
            if addTonesUndo != nil {
                set.actionLabel = L("\u{21A9}\u{FE0E} Hoàn tác"); set.actionPayload = KeyboardView.undoTonesToken
                set.paste = false; set.clipChips = []
            } else if addTonesPlan() != nil {
                set.actionLabel = L("Thêm dấu"); set.actionPayload = KeyboardView.addTonesToken
            }
        }
        // Vừa tự sửa: chip "↩︎ chữ gốc" (một chạm trả lại) thắng mọi chip khác tới phím kế.
        if composed.isEmpty, let u = bridge.autoCorrectUndo {
            set.actionLabel = "\u{21A9}\u{FE0E} \(u.original)"; set.actionPayload = KeyboardView.undoAutoCorrectToken
            set.literal = nil; set.paste = false; set.clipChips = []
        }
        // Sửa ngược tiếng Anh (docs/DESIGN.md): công tắc tắt ⇒ chip mời "His car is"; bật và
        // vừa tự sửa ⇒ chip "↩︎ Khôi phục". Bridge xoá cả hai ở phím kế.
        if composed.isEmpty, let c = bridge.retroOffer {
            set.actionLabel = EngineBridge.retroLabel(c, context: textProxy.documentContextBeforeInput)
            set.actionPayload = KeyboardView.retroOfferToken
            set.literal = nil; set.paste = false; set.clipChips = []
        } else if composed.isEmpty, bridge.retroUndoAvailable {
            set.actionLabel = RetroEnglishUI.undoChipLabel; set.actionPayload = KeyboardView.undoRetroToken
            set.literal = nil; set.paste = false; set.clipChips = []
        }
        // Vừa sửa lại từ vuốt theo từ gõ: chip "↩︎ từ cũ" tới phím kế.
        if composed.isEmpty, let u = swipeTypedUndo {
            set.actionLabel = "\u{21A9}\u{FE0E} \(u.edit.old)"; set.actionPayload = KeyboardView.undoReviseToken
            set.literal = nil; set.paste = false; set.clipChips = []
        }
        // Dịch trên máy: thông báo ("Đang dịch…", thiếu gói…) thắng mọi chip tới phím kế.
        if composed.isEmpty, let n = translateNotice {
            set.actionLabel = n.text; set.actionPayload = KeyboardView.translateNoticeToken
            set.literal = nil; set.paste = false; set.clipChips = []
        }
        if composed.isEmpty, translateNotice == nil, let ai { ai.decorate(&set) }   // Apple Intelligence (tắt ⇒ nil)
        keyboard.showSuggestions(set)
    }

    /// Chip số cho token trước con trỏ (NumberChips — đọc chữ / định dạng tiền / máy tính).
    private func refreshNumberChip(idle: Bool = false) -> String? {
        numberChip = nil
        // Ngày âm lịch ("âm lịch" / "ngày âm" / "ÂL" vừa chốt): lọc bằng so chuỗi từ vừa chốt,
        // chỉ đọc context + tính ngày âm khi khớp (cache theo ngày) — dùng chung slot chip số.
        if idle, numberChipsSetting, LunarDate.mayTrigger(lastWord),
           let before = textProxy.documentContextBeforeInput,
           let c = LunarDate.chip(before: before) {
            numberChip = c
            return c.display
        }
        guard numberChipsSetting, numberSpaces <= 1,
              let before = textProxy.documentContextBeforeInput else { return nil }
        numberChip = NumberChips.chip(before: before)
        // Không còn chữ số gần con trỏ (vd ⌫ chỉ xoá chữ) ⇒ ngưng đọc context mỗi phím
        // tới khi gõ số / ký hiệu mới (trước đây: sau ⌫ mọi phím chữ tới 2 dấu cách).
        if numberChip == nil, !NumberChips.digitNearCaret(before) { numberSpaces = 99 }
        return numberChip?.display
    }

    /// Chip kết quả phép tính (MathResults) — chỉ đọc context khi phím vừa gõ là "=" (chip
    /// thường) hoặc chữ số / ")" / "%" / ⌫ (chip ngầm "= 36", không cần gõ "=").
    /// Đọc lại mỗi lượt (không cache) ⇒ con trỏ dời đi chỗ khác thì chip tự mất.
    private func refreshMathChip() -> String? {
        mathChip = nil
        guard mathArmed, let before = textProxy.documentContextBeforeInput else { return nil }
        mathChip = MathResults.chipAtCaret(before: before)
        return mathChip?.display
    }

    /// Phần main của gợi ý khi đang gõ dở: pool (VNSuggest) + fix đã tính nền.
    private func showComposingSuggestions(composed: String, raw: String, predicted: String,
                                          pool: [VNSuggest.Match], pmi: [Float]?, fix: String?,
                                          slip: String? = nil, english: EnglishAssist.Result? = nil,
                                          plan: AutoCorrect.Plan? = nil) {
        var set = KeyboardView.SuggestionSet()
        // Slot "nguyên văn" = phương án mà boundary SẼ KHÔNG cho ra —
        // lối thoát cho cả hai chiều collision (user chốt 2026-07-24):
        //   gõ l,o,s,s → boundary restore "loss"  → slot hiện "los" (composed)
        //   gõ l,o,s   → boundary giữ "ló"        → slot hiện "los" (raw)
        // Tap = chèn + reset engine nên boundary sau đó không restore nữa.
        set.literal = predicted == composed ? raw : composed
        // Inline suggestion (research 2026-07-24): pool tương thích dấu từ
        // VNSuggest, re-rank = log(staticFreq) + λ₁·log(personal) +
        // λ₂·context-bonus + λ₃·chỉ-còn-thiếu-dấu.
        // Từ thêm tay (Từ điển cá nhân) khớp tiền tố: đứng đầu pool với freq = trần lexicon
        // (255) — lexicon không có tên riêng/thuật ngữ nên VNSuggest không bao giờ đưa ra.
        let manualHits = langModel.manualCompletions(composed)
        let pool = manualHits.isEmpty ? pool : {
            let low = Set(manualHits.map { $0.lowercased() })
            return manualHits.map { VNSuggest.Match(word: $0, freq: 255) } + pool.filter { !low.contains($0.word.lowercased()) }
        }()
        if !pool.isEmpty {
            // ctx chỉ đổi khi (lastWord, lastWord2) đổi — cache, khỏi gọi
            // nextWords mỗi keystroke trong lúc đang gõ dở một từ.
            let ctxKey = (lastWord ?? "") + "\u{1}" + (lastWord2 ?? "") + (filterSensitive ? "\u{1}" : "")
            if ctxKey != ctxCacheKey {
                // + cặp chọn tay (CuratedPairs) — chỉ xếp gợi ý đang gõ dở, không thêm từ kế tiếp.
                // Lọc bật: cặp / bộ ba nhạy cảm (SensitiveWords.pairs / triples) không thưởng ngữ cảnh.
                // + chuỗi seed ba từ (SensitiveWords.chain) sau (lastWord2, lastWord).
                let fs = filterSensitive, p2 = lastWord2
                ctxCache = lastWord.map {
                    Set(CuratedPairs.withNext(
                        SensitiveWords.dropPairs(SensitiveWords.chain(after: $0, prev2: p2)
                                                    + langModel.nextWords(after: $0, prev2: p2, limit: 24),
                                                 after: $0, prev2: p2, enabled: fs),
                        after: $0, prev2: p2))
                } ?? []
                ctxCacheKey = ctxKey
            }
            // + bigram âm tiết tĩnh (SuggestRank — logic thuần, test đo trên heldout)
            let lm = langModel
            let ranked = SensitiveWords.filter(
                SuggestRank.rankInline(pool, pmi: pmi, typedLen: composed.count,
                                       count: { lm.count(of: $0) }, ctx: ctxCache),
                after: lastWord, prev2: lastWord2, enabled: filterSensitive)
            let words = EnglishAssist.merge(vietnamese: ranked, english: englishWords(english))
            set.word = words.first.map { caseForContext(displayCase($0, after: lastWord), typed: composed) }
            set.word2 = words.dropFirst().first.map { caseForContext(displayCase($0, after: lastWord), typed: composed) }
            // "Số từ gợi ý" 4–5: ứng viên hạng 3… (ô 1 = nguyên văn, ô 2–3 = word/word2)
            if slotWant > 3 {
                set.moreWords = words.dropFirst(2).prefix(slotWant - 3)
                    .map { caseForContext(displayCase($0, after: lastWord), typed: composed) }
            }
        } else if fix != nil || english != nil {
            // Thử nghiệm: không từ nào khớp → nghi chạm trượt phím kề; đưa bản sửa
            // lên slot chính (tap để thay, không tự thay). Từ tiếng Anh (EnglishAssist) sau nó.
            let words = EnglishAssist.merge(vietnamese: fix.map { [$0] } ?? [], english: englishWords(english))
            set.word = words.first.map { caseForContext(displayCase($0, after: lastWord), typed: composed) }
            set.word2 = words.dropFirst().first.map { caseForContext(displayCase($0, after: lastWord), typed: composed) }
            if slotWant > 3 {
                set.moreWords = words.dropFirst(2).prefix(slotWant - 3)
                    .map { caseForContext(displayCase($0, after: lastWord), typed: composed) }
            }
        }
        // Trượt vào phím thanh mà vẫn ra từ ("casn" → cán, ý là cân): bản sửa vào slot 3.
        let slip = slip.map { caseForContext($0, typed: composed) }
        if let slip, slip != set.word {
            if set.word == nil { set.word = slip } else { set.word2 = slip }
        }
        set.number = refreshNumberChip()
        set.math = refreshMathChip()
        // thử cụm 2 từ trước ("hoàn thành", "sinh nhật") rồi mới tới từ đơn.
        // Emoji KHÔNG bị lọc nhạy cảm (user 2026-07-24: gõ "cứt"/"shit"
        // phải ra 💩) — filter chỉ chặn gợi ý TỪ, emoji là cách nói giảm.
        var emojis: [String] = []
        if emojiSuggestSetting {
            if let prev = lastWord {
                emojis = EmojiSuggest.emojis(for: prev.lowercased() + " " + composed.lowercased())
            }
            if emojis.isEmpty { emojis = EmojiSuggest.emojis(for: composed) }
            // raw ≡ composed (từ không dấu) ⇒ tra lần ba là thừa.
            if emojis.isEmpty, raw != composed { emojis = EmojiSuggest.emojis(for: raw.lowercased()) }
            // Bảng biên soạn không có → từ khoá tiếng Anh CLDR ("japan", "pizza") + mã nước
            // IN HOA ("JP"). Từ có dấu / âm tiết Việt không dấu không bao giờ khớp (EmojiSearch.typing).
            if emojis.isEmpty { emojis = EmojiSearch.typing(prev: lastWord, composed: composed, raw: raw) }
        }
        set.emojis = emojis
        // Không có emoji lấp ô cuối → đệm cho đủ ô (literal + slotWant−1 từ). 1 ô: không đệm —
        // ô duy nhất hiện ứng viên thật, không có thì nguyên văn (SuggestionSlots.arrange).
        if emojis.isEmpty, slotWant > 1 {
            let words = padWords([set.word, set.word2].compactMap { $0 } + set.moreWords,
                                 need: slotWant - 1, typed: composed)
            set.word = words.first
            set.word2 = words.count > 1 ? words[1] : nil
            set.moreWords = Array(words.dropFirst(2))
        }
        // Tô nền gợi ý sửa (ONBOARDING-SPEC §8): từ gõ sai + bản sửa đủ chắc (CÙNG quyết định với
        // dấu cách — correctionDecision) + dấu cách lúc này áp được (autoCorrectPreview: chữ hoa đầu
        // câu, không dính URL, không gõ tắt…). Đọc context chỉ khi đã có bản sửa (hiếm).
        var shown: String?
        if let plan, let fix = correctionDecision(raw, plan: plan),
           let original = bridge.autoCorrectPreview(fix, context: textProxy.documentContextBeforeInput) {
            CorrectionHint.apply(&set, typed: original, fix: fix, need: slotWant - 1)
            if set.correction { shown = fix }
        }
        shownCorrection = (raw, shown)
        // Đang gõ đúng một chữ tắt: slot chính hiện nội dung sẽ bung (chạm = bung ngay).
        // (Nội dung nhiều dòng không lên bar — chạm sẽ chèn sai; gõ ranh giới vẫn bung.)
        if let preview = bridge.shortcutPreview, !preview.contains("\n"), set.word != preview {
            if set.word != nil, let w2 = set.word2, !set.moreWords.isEmpty { set.moreWords.insert(w2, at: 0) }
            set.word2 = set.word ?? set.word2
            set.word = preview
        }
        keyboard.showSuggestions(set)
    }

    /// Từ tiếng Anh (EnglishAssist) sau "Lọc từ nhạy cảm" — cùng bộ lọc như gợi ý tiếng Việt.
    private func englishWords(_ r: EnglishAssist.Result?) -> EnglishAssist.Result? {
        EnglishAssist.filtered(r, after: lastWord, prev2: lastWord2, enabled: filterSensitive)
    }

    // MARK: Nút Dán (maintainer 25/09/2026, như bàn phím stock/Gboard)
    // Chỉ khi có Full Access (không có thì extension không đọc được clipboard), không
    // gõ dở từ, và clipboard có nội dung MỚI trong 3 phút chưa dán. hasStrings không
    // bật hỏi quyền; nội dung chỉ đọc khi user CHẠM nút. Cache 2s: hasStrings là XPC.
    private var pasteSeenChange = -1
    /// Debug mode: dòng "paste:" chỉ ghi khi (cc, used, has, kết quả) đổi.
    private var pasteLogKey = ""
    private var pasteSeenAt = Date.distantPast
    private var pasteUsedChange = -1
    private var pasteCheckedAt = Date.distantPast
    private var pasteCached = false
    private var pasteIsImage = false
    /// Mời dán MỘT lần mỗi mục clipboard (PasteOfferOnce). Lưu changeCount + mốc khởi động
    /// máy (changeCount đếm lại sau reboot) vào defaults RIÊNG của bàn phím — không cần
    /// Full Access, không bao giờ lưu nội dung.
    private lazy var pasteOnce = PasteOfferOnce(offeredID: Self.loadPasteOffered()) { id in
        let d = UserDefaults.standard
        d.set(id, forKey: Self.pasteOfferedKey)
        d.set(Self.bootEpoch(), forKey: Self.pasteOfferedBootKey)
    }
    private static let pasteOfferedKey = "pasteOfferedChange"
    private static let pasteOfferedBootKey = "pasteOfferedBoot"
    private static func bootEpoch() -> Double {
        Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    }
    private static func loadPasteOffered() -> Int? {
        let d = UserDefaults.standard
        guard d.object(forKey: pasteOfferedKey) != nil,
              abs(d.double(forKey: pasteOfferedBootKey) - bootEpoch()) < 120 else { return nil }
        return d.integer(forKey: pasteOfferedKey)
    }
    private func pasteOffer() -> Bool {
        guard pasteButtonSetting || clip.historyEnabled else { return false }
        guard hasFullAccess else { TouchLog.write("paste: no Full Access"); return false }
        let now = Date()
        // Đọc changeCount (≤ 1 lần / 2 s) TRƯỚC điều kiện "đầu chỗ gõ": trước đây chỉ đọc khi
        // con trỏ đứng sau khoảng trắng ⇒ copy xong mà con trỏ ở sau chữ (thường gặp: chọn
        // chữ trong chính ô rồi Sao chép) thì lịch sử clipboard không bao giờ ghi (15/10/2026).
        if now.timeIntervalSince(pasteCheckedAt) >= 2 {
            pasteCheckedAt = now
            refreshPasteState(now: now)
        }
        // Chỉ MỜI dán ở "đầu chỗ gõ": ô trống, hoặc ngay trước con trỏ là khoảng trắng/xuống
        // dòng. Bàn phím vừa hiện lại sau "Đang viết" thì engine rỗng nhưng vẫn là gõ dở chữ
        // (user 25/09/2026). documentContextBeforeInput là bản host đẩy sẵn — đọc rẻ.
        if let last = textProxy.documentContextBeforeInput?.last,
           !last.isWhitespace { return false }
        return pasteCached && pasteOnce.canOffer(pasteSeenChange)
    }

    /// Đọc changeCount/hasStrings (không bật hỏi quyền dán), tự ghi lịch sử khi có mục mới,
    /// tính lại `pasteCached`.
    private func refreshPasteState(now: Date) {
        let pb = pasteboard
        let cc = pb.changeCount
        let has = pb.hasStrings
        if cc != pasteSeenChange {
            pasteSeenChange = cc; pasteSeenAt = now
            if has, cc != pasteUsedChange { autoCaptureClipboard(pb, change: cc) }
        }
        // Ảnh: KHÔNG báo (user 25/09/2026) — iOS không cho bàn phím chèn ảnh, thẻ
        // hướng dẫn trông như nút bấm được nên gây hiểu nhầm.
        pasteIsImage = false
        pasteCached = cc != pasteUsedChange && has
            && now.timeIntervalSince(pasteSeenAt) < 180
            && pasteOnce.canOffer(cc)
        // Chỉ khi trạng thái đổi: refresh bar chạy mỗi phím/đổi ô, dòng y hệt (trừ tuổi) là rác.
        if TouchLog.enabled {
            let key = "\(cc)/\(pasteUsedChange)/\(has ? 1 : 0)/\(pasteCached ? 1 : 0)"
            if key != pasteLogKey {
                pasteLogKey = key
                TouchLog.write(String(format: "paste: cc=%d used=%d has=%d age=%.0fs → %d",
                                      cc, pasteUsedChange, has ? 1 : 0,
                                      now.timeIntervalSince(pasteSeenAt), pasteCached ? 1 : 0))
            }
        }
    }

    /// `hasFullAccess` có thể chưa đúng ở viewWillAppear (extension chưa nối host xong) ⇒
    /// nút 📋 / rung bị tắt cả lần hiện đó (tester: "lắm lúc không hiện…"). Đối chiếu lại
    /// khi đã hiện hẳn; chỉ làm gì khi khác.
    private func refreshFullAccessIfChanged() {
        let fa = hasFullAccess
        guard fa != appliedFullAccess else { return }
        TouchLog.write("fullAccess willAppear=\(appliedFullAccess ? 1 : 0) didAppear=\(fa ? 1 : 0)")
        appliedFullAccess = fa
        keyboard?.setClipboardButton(visible: clip.historyEnabled && fa)
        keyboard?.keypadPasteEnabled = fa
        KeyboardView.hapticsEnabled = hapticSetting && fa
        if fa { reportStatusToApp() }
    }

    /// Dán chữ trong clipboard vào ô — nút Dán trên thanh gợi ý VÀ vuốt V lên (KeyCommand).
    /// Trả chữ đã chèn (nil = clipboard không có chữ). Gọi trong applyingEdit.
    @discardableResult
    fileprivate func pasteFromClipboard() -> String? {
        let pb = pasteboard
        // Không có API hỏi "đã cho phép dán chưa": khi iOS hiện "Allow Paste?",
        // lệnh đọc BỊ CHẶN tới lúc user chọn (≥ vài trăm ms); đã Cho phép thì gần
        // như tức thì. Ghi kết quả vào App Group để app ẩn hướng dẫn (user 25/09/2026).
        let t0 = CACurrentMediaTime()
        let str = pb.string
        let noPrompt = str != nil && CACurrentMediaTime() - t0 < 0.25
        UserDefaults(suiteName: AppFlavor.appGroup)?.set(noPrompt, forKey: "pasteNoPrompt")
        var pasted: String?
        if let s = str, !s.isEmpty {
            textProxy.insertText(s)
            clip.captured(s, change: pb.changeCount, now: Date().timeIntervalSince1970,
                          secureField: fieldTraits?.secure == true,
                          concealed: Self.isConcealed(pb))
            pasted = s
        }
        pasteUsedChange = pb.changeCount
        pasteOnce.used(pasteUsedChange)
        pasteCached = false
        bridge.reset(); lastWord = nil; lastWord2 = nil
        return pasted
    }

    /// 📋 bàn số lớn: dán clipboard đã lọc theo kiểu bàn số ("0903 389 710" → "0903389710").
    private func pasteIntoKeypad() {
        guard let style = fieldTraits?.keypadStyle(isPad: UIDevice.current.userInterfaceIdiom == .pad) else { return }
        applyingEdit = true
        defer { applyingEdit = false }
        let pb = pasteboard
        let s = NumericKeypad.cleanPaste(pb.string, style: style)
        if !s.isEmpty { textProxy.insertText(s) }
        if TouchLog.enabled { TouchLog.write("keypadPaste inserted=\(s.count)") }
        pasteUsedChange = pb.changeCount
        pasteOnce.used(pasteUsedChange)
        pasteCached = false
        bridge.reset(); lastWord = nil; lastWord2 = nil
        updateSuggestions()
    }

    /// Tap gợi ý (hành vi QuickType): emoji thay hẳn từ; từ tiếng Việt thay
    /// từ + thêm space để gõ tiếp luôn.
    private func acceptSuggestion(_ item: String) {
        applyingEdit = true
        defer { applyingEdit = false }
        learnSettledSwipe()
        addTonesUndo = nil
        suggestionSnap = nil
        swipeTyped = nil; swipeTypedUndo = nil
        if item == KeyboardView.pasteImageToken {       // chỉ hướng dẫn → ẩn thẻ
            pasteUsedChange = pasteboard.changeCount
            pasteOnce.used(pasteUsedChange)
            pasteCached = false
            KeyboardView.clickModifier()
            updateSuggestions()
            return
        }
        if item == KeyboardView.pasteToken {
            pasteFromClipboard()
            KeyboardView.clickModifier()
            updateSuggestions()
            return
        }
        if item == KeyboardView.numberToken {
            acceptNumberChip()
            return
        }
        if item == KeyboardView.mathToken {
            acceptMathChip()
            return
        }
        // Undo auto-restore: caret đang đứng ngay sau từ raw đã chốt (space vừa
        // bị backspace) → thay cả từ raw bằng dạng có dấu + space.
        if undoOfferActive, let u = restoreUndo, item == u.composed,
           bridge.composedWord.isEmpty {
            // Chữ trước con trỏ không còn là từ raw vừa chốt → bỏ thao tác (không xoá lan).
            guard canDeleteBefore(u.raw, what: "undo-restore") else {
                restoreUndo = nil; undoOfferActive = false
                bridge.reset(); lastWord = nil; lastWord2 = nil
                updateSuggestions()
                return
            }
            for _ in 0..<u.raw.count { textProxy.deleteBackward() }
            textProxy.insertText(u.composed + " ")
            suggestionSnap = u.composed + " "
            restoreUndo = nil; undoOfferActive = false
            bridge.reset()
            commitAndLearn(u.composed, accepted: true)
            KeyboardView.clickModifier()
            updateAutoShift()
            updateSuggestions()
            return
        }
        restoreUndo = nil; undoOfferActive = false
        let isFragment = item.contains(".") || item.contains("@")   // gmail.com, com…
        let isWord = !isFragment && item.first?.isLetter == true
        let composed = bridge.composedWord
        // Lệch: từ đang gõ không còn ngay trước con trỏ → bỏ lượt nhận gợi ý (thay
        // chữ khác là mất dữ liệu; chèn thêm cạnh từ lạ cũng sai) — reset, vẽ lại bar.
        guard canDeleteBefore(composed, what: "suggestion") else {
            bridge.reset(); lastWord = nil; lastWord2 = nil
            updateAutoShift()
            updateSuggestions()
            return
        }
        for _ in 0..<composed.count { textProxy.deleteBackward() }
        textProxy.insertText(isWord ? item + " " : item)
        if isWord { suggestionSnap = item + " " }
        keyboard?.buddy?.emojiInserted(item)
        bridge.reset()
        // Chèn đúng dạng đang hiện ("Bên" khi Shift); học dạng thường (record lowercased).
        if isWord { commitAndLearn(item, accepted: true) } else { lastWord = nil; lastWord2 = nil }
        keyboard.releaseOneShotShift()     // như gõ một chữ: Shift một-lần nhả, Caps giữ
        KeyboardView.clickModifier()
        updateAutoShift()
        updateSuggestions()
    }
}

// MARK: chọn phím theo ngữ cảnh (thử nghiệm) — TouchTarget
extension KeyboardViewController {
    /// Gọi lúc chạm phím chữ (main): P(phím | từ đang gõ), nil ⇒ router gần-nhất như cũ.
    /// Ô literal (email/URL/username/mật khẩu), layout số/email/URL: tắt.
    fileprivate func smartTouchPrior() -> ((Character) -> Float?)? {
        guard smartTouchSetting, let t = fieldTraits, !t.passthrough, !t.secure,
              t.inputKind.isFreeText, !bridge.passthrough else { return nil }
        return TelexKeyPrior.sharedIfReady?.forTyping(bridge.rawWord, vniMode: bridge.vniMode)
    }
}

extension KeyboardViewController {
    /// Chạm chip số: thay đúng đuôi đã tính (kiểm lại context trước khi xoá — lệch thì bỏ).
    /// Chạm chip đuôi mail: chèn phần còn thiếu — tính lại từ context lúc chạm, lệch thì bỏ.
    fileprivate func acceptEmailChip(_ c: EmailDomains.Chip) {
        applyingEdit = true
        defer {
            applyingEdit = false
            KeyboardView.clickModifier()
            updateSuggestions()
        }
        let before = textProxy.documentContextBeforeInput ?? ""
        guard EmailDomains.chips(before: before, limit: EmailDomains.providers.count).contains(c) else {
            TouchLog.write("failsafe: email chip context mismatch → skip")
            return
        }
        // Qua bridge: ô email đang soạn ("dduc") ⇒ trả về phím thô trước khi chèn "@gmail.com".
        _ = bridge.boundary(c.insert, proxy: Proxy(p: textProxy))
        bridge.reset()
        lastWord = nil; lastWord2 = nil
    }

    /// StripMode.tools: không gợi ý chữ — chỉ lời mời Dán (cùng luật mời một lần / Full
    /// Access / chip tách số = Plus như dải đầy đủ) và chip URL ở ô địa chỉ. ☰/📋 do
    /// KeyboardView vẽ sẵn khi dải bật.
    fileprivate func showToolsOnly(composing: Bool) {
        var set = KeyboardView.SuggestionSet()
        if composing {
            keyboard.hidePasteCard()
        } else if pasteOffer() {
            set.paste = pasteButtonSetting; set.pasteIsImage = pasteIsImage
            let chips = fieldClipChips()
            set.clipChips = chips.map { ($0.label, KeyboardView.clipTokenPrefix + $0.value) }
        }
        if fieldTraits?.wantsURLChips == true {
            let p = textProxy
            urlChips = URLChips.chips(before: p.documentContextBeforeInput ?? "",
                                      after: p.documentContextAfterInput ?? "")
            set.nextWords = urlChips.map(\.label)
        }
        keyboard.showSuggestions(set)
    }

    /// Chạm chip URL: tính lại từ context lúc chạm (con trỏ có thể đã dời) — không còn chip
    /// cùng nhãn thì bỏ (không chèn mù). Chữ đang gõ (omnibox gõ Telex) đã nằm sẵn trong ô ⇒
    /// chỉ chốt engine rồi chèn tại con trỏ.
    fileprivate func acceptURLChip(_ label: String) {
        applyingEdit = true
        defer {
            applyingEdit = false
            KeyboardView.clickModifier()
            updateSuggestions()
        }
        let p = textProxy
        let now = URLChips.chips(before: p.documentContextBeforeInput ?? "",
                                 after: p.documentContextAfterInput ?? "")
        guard let c = now.first(where: { $0.label == label }) else {
            TouchLog.write("failsafe: url chip context mismatch → skip")
            return
        }
        p.insertText(c.insert)
        bridge.reset()
        lastWord = nil; lastWord2 = nil
    }

    fileprivate func acceptNumberChip() {
        defer {
            KeyboardView.clickModifier()
            updateAutoShift()
            updateSuggestions()
        }
        guard let c = numberChip else { return }
        numberChip = nil
        let before = textProxy.documentContextBeforeInput ?? ""
        guard before.hasSuffix(c.replace) else {
            TouchLog.write("failsafe: number chip context mismatch → skip")
            return
        }
        for _ in 0..<c.replace.count { textProxy.deleteBackward() }
        textProxy.insertText(c.insert)
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        numberSpaces = 0            // kết quả mới cũng là số → chip kế trong chuỗi (tiền → chữ)
    }
}

extension KeyboardViewController {
    /// Chạm chip kết quả phép tính: chèn kết quả sau "=" — tính lại từ context lúc chạm,
    /// khác chip đang hiện (con trỏ đã dời / chữ đã đổi) thì bỏ.
    fileprivate func acceptMathChip() {
        defer {
            KeyboardView.clickModifier()
            updateAutoShift()
            updateSuggestions()
        }
        guard let c = mathChip else { return }
        mathChip = nil; mathArmed = false
        let before = textProxy.documentContextBeforeInput ?? ""
        guard MathResults.chipAtCaret(before: before) == c else {
            TouchLog.write("failsafe: math chip context mismatch → skip")
            return
        }
        textProxy.insertText(c.insert)
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        numberSpaces = 0            // kết quả là số → chip số (đọc chữ) có thể theo sau
    }
}

extension UIPasteboard: PasteboardSource {}

// MARK: Lịch sử clipboard — glue ClipboardFeature ↔ UIPasteboard ↔ panel
extension KeyboardViewController {
    /// Trình quản lý mật khẩu đánh dấu clipboard "concealed" (quy ước nspasteboard.org,
    /// 1Password) — đọc `types` không bật hỏi quyền dán.
    fileprivate static func isConcealed(_ pb: PasteboardSource) -> Bool {
        pb.types.contains { $0 == "org.nspasteboard.ConcealedType" || $0.hasPrefix("com.agilebits") }
    }

    /// changeCount mới lúc bàn phím đang hiện: tự đọc + ghi CHỈ khi user bật "Tự lưu khi
    /// sao chép" (mặc định TẮT — mỗi lần đọc iOS hiện banner "VietTelex đã dán từ…") VÀ đã
    /// chọn "Cho phép dán" (pasteNoPrompt) — nếu iOS vẫn hỏi (đọc chậm) thì ghi nhận lại
    /// pasteNoPrompt=false để lần sau không tự đọc nữa. Tắt ⇒ không đụng `string` ở đây.
    fileprivate func autoCaptureClipboard(_ pb: PasteboardSource, change: Int) {
        guard clip.autoSave else { return }
        let group = UserDefaultsProvider.shared
        let secure = fieldTraits?.secure == true
        let concealed = clip.historyEnabled ? Self.isConcealed(pb) : false
        guard clip.shouldAutoRead(fullAccess: hasFullAccess,
                                  noPrompt: group?.bool(forKey: "pasteNoPrompt") == true,
                                  secureField: secure, concealed: concealed) else { return }
        let t0 = CACurrentMediaTime()
        let str = pb.string
        if CACurrentMediaTime() - t0 >= 0.25 {
            UserDefaults(suiteName: AppFlavor.appGroup)?.set(false, forKey: "pasteNoPrompt")
        }
        guard let s = str else { return }
        clip.captured(s, change: change, now: Date().timeIntervalSince1970,
                      secureField: secure, concealed: concealed)
        if clipPanel != nil { reloadClipboardPanel() }
    }

    /// Chèn nội dung từ chip / panel: nguyên văn, KHÔNG thêm space, KHÔNG học từ.
    fileprivate func insertClip(_ text: String, chip: Bool) {
        guard !text.isEmpty else { return }
        applyingEdit = true
        defer { applyingEdit = false }
        learnSettledSwipe()
        textProxy.insertText(text)
        if chip { pasteUsedChange = pasteSeenChange; pasteOnce.used(pasteSeenChange); pasteCached = false }
        bridge.reset(); lastWord = nil; lastWord2 = nil
        KeyboardView.clickModifier()
        updateAutoShift()
        updateSuggestions()
    }

    fileprivate func toggleClipboardPanel() {
        if clipPanel != nil { closeClipboardPanel(); return }
        captureClipboardForPanel()
        let p = ClipboardPanel()
        p.onPaste = { [weak self] t in self?.insertClip(t, chip: false); self?.closeClipboardPanel() }
        p.onTogglePin = { [weak self] t in
            guard let self else { return }
            if self.clip.togglePin(t) { self.reloadClipboardPanel(); return }
            let limit = self.clip.pinLimit() ?? 0
            self.reloadClipboardPanel(notice: L("Tối đa %1$@ mục ghim — %2$@ Plus ghim không giới hạn.", limit, AppFlavor.displayName))
        }
        p.onDelete = { [weak self] t in self?.clip.remove(t); self?.reloadClipboardPanel() }
        p.onClearAll = { [weak self] in self?.clip.clearUnpinned(); self?.reloadClipboardPanel() }
        p.onClose = { [weak self] in self?.closeClipboardPanel() }
        p.frame = keyboard.keyAreaFrame   // KeyboardView.layoutOverlayPanel bám vùng phím mỗi lượt layout
        keyboard.addSubview(p)
        keyboard.overlayPanel = p
        clipPanel = p
        reloadClipboardPanel()
        keyboard.setNeedsLayout()
    }

    /// Mở panel = người dùng CHỦ ĐỘNG xem clipboard ⇒ đọc mục hiện tại nếu chưa ghi (kể cả
    /// khi iOS còn hỏi "Cho phép dán?" — như bấm Dán). Trước đây panel chỉ hiện những gì
    /// đã tự ghi được, mà tự ghi cần "Cho phép" + con trỏ sau khoảng trắng ⇒ mục vừa copy
    /// hay vắng (tester Plus 15/10/2026).
    private func captureClipboardForPanel() {
        guard clip.historyEnabled, hasFullAccess else { return }
        let pb = pasteboard
        let cc = pb.changeCount
        guard clip.known?.change != cc, pb.hasStrings else { return }
        let secure = fieldTraits?.secure == true
        let concealed = Self.isConcealed(pb)
        guard clip.canRecord(secureField: secure, concealed: concealed) else { return }
        let t0 = CACurrentMediaTime()
        let str = pb.string
        let noPrompt = str != nil && CACurrentMediaTime() - t0 < 0.25
        UserDefaults(suiteName: AppFlavor.appGroup)?.set(noPrompt, forKey: "pasteNoPrompt")
        guard let s = str else { return }
        clip.captured(s, change: cc, now: Date().timeIntervalSince1970, secureField: secure, concealed: concealed)
        pasteSeenChange = cc; pasteSeenAt = Date()
    }

    fileprivate func reloadClipboardPanel(notice: String? = nil) {
        guard let p = clipPanel else { return }
        p.frame = keyboard.keyAreaFrame
        p.reload(items: clip.items(now: Date().timeIntervalSince1970),
                 dark: keyboard.isDarkAppearance, incognito: clip.incognito, notice: notice)
    }

    fileprivate func closeClipboardPanel() {
        guard let p = clipPanel else { return }
        p.removeFromSuperview()
        clipPanel = nil
        keyboard?.overlayPanel = nil
        keyboard?.setNeedsLayout()
    }
}

// MARK: vuốt phím lên = sao chép / cắt / dán (KeyCommandGesture — mặc định TẮT)
extension KeyboardViewController {
    private final class CommandHost: KeyCommandHost {
        let p: UITextDocumentProxy
        init(_ p: UITextDocumentProxy) { self.p = p }
        var selectedText: String? { p.selectedText }
        func insertText(_ text: String) { p.insertText(text) }
        func deleteBackward() { p.deleteBackward() }
    }
    private final class SystemClipboard: KeyCommandClipboard {
        var string: String? {
            get { UIPasteboard.general.string }
            set { UIPasteboard.general.string = newValue }
        }
    }

    fileprivate func wireKeyCommands() {
        keyboard.keyCommandHasSelection = { [weak self] in
            guard let self else { return false }
            return self.textProxy.selectedText?.isEmpty == false
        }
        keyboard.keyCommandLabel = { [weak self] cmd in
            guard let self else { return L(cmd.viLabel) }
            let sel = cmd == .paste ? nil : self.textProxy.selectedText
            let blocked = KeyCommandRunner.precheck(cmd, selectedText: sel, fullAccess: self.hasFullAccess)
            return L(blocked.flatMap(KeyCommandRunner.hint) ?? cmd.viLabel)
        }
        keyboard.onKeyCommand = { [weak self] cmd, deferred in self?.runKeyCommand(cmd, letterDeferred: deferred) }
    }

    /// Nhấc tay sau vuốt lên: huỷ chữ phím vừa chèn (trừ khi đã hoãn), chốt từ đang gõ, chạy lệnh.
    fileprivate func runKeyCommand(_ cmd: KeyCommand, letterDeferred: Bool) {
        if externalChangePending { syncComposition("keycmd") }
        applyingEdit = true
        defer { applyingEdit = false }
        let proxy = Proxy(p: textProxy)
        if !letterDeferred, !bridge.undoLastLetter(proxy: proxy) { bridge.backspace(proxy: proxy) }
        // Chốt từ đang gõ như nút Dán / mục menu: chữ đã nằm trên màn hình, engine quên từ dở.
        learnSettledSwipe()
        bridge.reset(); lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        swipeTyped = nil; swipeTypedUndo = nil
        let outcome = KeyCommandRunner.run(cmd, host: CommandHost(textProxy), clipboard: SystemClipboard(),
                                           fullAccess: hasFullAccess,
                                           paste: { [weak self] in self?.pasteFromClipboard() })
        if TouchLog.enabled { TouchLog.write("keycmd \(cmd.rawValue) → \(KeyCommandRunner.logKind(outcome))") }   // không ghi nội dung
        switch outcome {
        case .copied:
            keyboard.flashKeyCommandHint(L("Đã sao chép"))
        case .cut, .pasted:
            break
        default:
            if let h = KeyCommandRunner.hint(outcome) { keyboard.flashKeyCommandHint(L(h)) }
        }
        KeyboardView.clickModifier()
        updateAutoShift()
        updateSuggestions()
    }
}

// MARK: gõ vuốt (thử nghiệm) — glue SwipeTyping ↔ bridge ↔ thanh gợi ý
extension KeyboardViewController {
    fileprivate func wireSwipeTyping() {
        keyboard.onSwipeBegan = { [weak self] in self?.swipeBegan() }
        keyboard.onSwipeEnded = { [weak self] path, sc in self?.swipeEnded(path, sc) }
    }

    /// Observer cấp controller — MỘT lần ở viewDidLoad (KeyboardView có thể dựng lại nhiều lần).
    fileprivate func registerObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(voiceOverChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(memoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    /// Áp lực bộ nhớ: nhả model FUTO Swipe (thử nghiệm) nếu đang giữ.
    @objc fileprivate func memoryWarning() { swipe?.releaseFuto() }

    @objc fileprivate func voiceOverChanged() { updateSwipeEnabled() }

    /// Bật/tắt theo công tắc + SwipePolicy (ô nhập, iPad, VoiceOver).
    fileprivate func updateSwipeEnabled() {
        guard let keyboard else { return }
        let on = SwipePolicy.enabled(setting: swipeSetting,
                                     isPad: UIDevice.current.userInterfaceIdiom == .pad,
                                     traits: fieldTraits,
                                     voiceOver: UIAccessibility.isVoiceOverRunning)
        keyboard.swipeEnabled = on
        keyboard.altAccessibility = UIAccessibility.isVoiceOverRunning
        // Vuốt phím lên = lệnh: không ở ô mật khẩu, không khi VoiceOver (router khác).
        let keyCmds = KeyCommandPolicy.enabled(setting: keyCommandsSetting, traits: fieldTraits,
                                               voiceOver: UIAccessibility.isVoiceOverRunning)
        keyboard.keyCommandsEnabled = keyCmds
        // Checkpoint huỷ phím chữ chỉ có người dùng khi iPad vuốt xuống / giữ phím ra ký tự phụ /
        // vuốt phím lên ra lệnh (gõ vuốt hoãn chữ đầu tới lúc nhấc — không cần huỷ).
        bridge.letterUndoEnabled = UIDevice.current.userInterfaceIdiom == .pad
            || keyboard.altHoldActive || keyCmds
        if on, swipe == nil { swipe = SwipeTyping() }
        // Template vuốt / từ điển Anh / FUTO / vnlm dựng NỀN — nhưng không tranh CPU với khung
        // đầu: xin trước khung đầu ⇒ dời ra sau commit (cú vuốt tới trước vẫn đúng: decode chờ
        // trên hàng đợi của SwipeTyping, template dựng lười).
        afterFirstFrame { [weak self] in
            guard let self, let swipe = self.swipe else { return }
            if on { self.pushSwipeLayout(prepare: true) }
            if on, self.swipeEnglishSetting { swipe.preloadEnglish() }
            if on || swipe.futoActive { swipe.setFuto(enabled: on && self.swipeFutoSetting) }
        }
    }



    /// Tâm phím thật → decoder (đổi layout khi xoay/đổi cỡ; trùng thì no-op).
    fileprivate func pushSwipeLayout(prepare: Bool) {
        guard keyboard?.swipeEnabled == true, let swipe,
              let l = keyboard.swipeLayout() else { return }
        swipe.setLayout(l, prepare: prepare)
        SwipeSound.existing?.setLayout(centers: l.centers, keyWidth: l.keyWidth)   // âm nét vuốt dò phím (trùng ⇒ no-op)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        StartupTrace.event("didLayout")
        if FrameTrace.isEnabled { traceLayout() }
        if !warmupsDeferred { pushSwipeLayout(prepare: true) }   // trước khung đầu: postFrame đẩy
        // Sáng/tối: iOS 27 đôi khi báo trait SÁNG lúc viewWillAppear/viewDidAppear dù máy
        // tối ⇒ phím trắng trên backdrop tối, chữ gợi ý đen khó đọc (Phil 28/09/2026). Mỗi
        // lần layout so lại với trait hiện tại (chỉ so 2 giá trị đã có — không đọc proxy);
        // updateDark tự bỏ qua khi không đổi.
        keyboard?.updateDark(presentationDark)
        checkHostOversize()
        checkHostFill()
    }

    /// #151: host giữ khung cao hơn hẳn mức xin (khung tạm lúc hiện / đổi bàn phím không được đo
    /// lại) ⇒ xin hệ thống đo lại chiều cao. Mọi máy, mọi theme; thường chỉ một phép so sánh.
    private func checkHostOversize() {
        guard let kb = keyboard, !kb.isTornDown else { return }
        // Chỉ khi đang hiện: trước viewWillAppear host đặt khung cả màn hình (812) cho controller
        // cũ, mức xin còn của lần trước — xin đo lại lúc đó làm host (WhatsApp) giữ khung kính sai
        // chiều cao tới khi app bị tắt hẳn (dải xám trên bàn phím, log máy Phil 07/11/2026).
        guard appearance.showing else { return }
        let animating = UIView.inheritedAnimationDuration > 0
            || !(view.layer.animationKeys()?.isEmpty ?? true)
        switch hostOversize.observe(requested: kb.requestedHeight, viewHeight: view.bounds.height,
                                    inWindow: view.window != nil, animating: animating) {
        case .none: break
        case .wait: scheduleHostFillRecheck()
        case .remeasure:
            TouchLog.write("oversize view=\(view.bounds.height) req=\(kb.requestedHeight) → remeasure")
            // Đúng lời báo UIKit gửi khi cỡ fitting đổi — cha đo lại view (mức xin) và đặt lại khung.
            parent?.systemLayoutFittingSizeDidChange(forChildContentContainer: self)
            view.setNeedsUpdateConstraints()
            scheduleHostFillRecheck()   // lượt sau: còn dư ⇒ .bump
        case .bump:
            TouchLog.write("oversize view=\(view.bounds.height) req=\(kb.requestedHeight) → bump")
            // Đổi cỡ thật (1 pixel) ⇒ UIKit tự báo cha; trả về ở lượt runloop sau (lại báo lần nữa).
            let px = 1 / max(view.traitCollection.displayScale, 1)
            kb.heightNudge = px
            DispatchQueue.main.async { [weak self] in
                guard let kb = self?.keyboard, !kb.isTornDown else { return }
                kb.heightNudge = 0
            }
        }
    }

    // MARK: Dải container hệ thống lộ phía trên view (HostFill — Phil 05/10/2026, iOS 27 thật)
    // (trạng thái hostFill / hostFillRecheckScheduled / lastHostGeomKey ở thân class)
    /// Chỉ iPhone iOS 26+ (khung kính) — chỗ khác không đo, không làm gì.
    private static let hostFillEligible = UIDevice.current.userInterfaceIdiom == .phone
        && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26

    /// Đỉnh container hệ thống → đáy view: superview và window, chỉ những cái view NEO ĐÁY và
    /// cao hơn view không quá trần (window cỡ màn hình / khung settle khổng lồ bị loại).
    private func hostAllocatedHeight() -> CGFloat? {
        guard let v = viewIfLoaded else { return nil }
        var candidates: [CGFloat] = []
        if let s = v.superview, let a = HostFill.allocated(viewFrame: v.frame, container: s.bounds) {
            candidates.append(a)
        }
        if let w = v.window,
           let a = HostFill.allocated(viewFrame: v.convert(v.bounds, to: w), container: w.bounds) {
            candidates.append(a)
        }
        return candidates.filter { $0 - v.bounds.height <= HostFill.maxExtra }.max()
    }

    /// Mỗi lượt layout: log hình học (Debug mode) + quyết định HostFill. Theme trong suốt /
    /// iPad / iOS < 26: chỉ một phép so sánh.
    private func checkHostFill() {
        guard let kb = keyboard, !kb.isTornDown else { return }
        if TouchLog.enabled { logHostGeometry("layout") }
        guard Self.hostFillEligible, kb.paintsBackdrop else { revealContent(force: true); return }
        let animating = UIView.inheritedAnimationDuration > 0
            || !(view.layer.animationKeys()?.isEmpty ?? true)
        let decision = hostFill.observe(base: kb.baseRequestedHeight, viewHeight: view.bounds.height,
                                        allocated: hostAllocatedHeight(), width: view.bounds.width,
                                        animating: animating)
        switch decision {
        case .none: break
        case .wait: scheduleHostFillRecheck()
        case .apply(let x):
            kb.hostFillExtra = x
            TouchLog.write("hostFill extra=\(x) locked=\(hostFill.locked)")
        }
        if settleGuard.shouldReveal(decision: decision, base: kb.baseRequestedHeight, extra: hostFill.extra,
                                    viewHeight: view.bounds.height, inWindow: view.window != nil,
                                    now: CACurrentMediaTime()) {
            showContent()
        }
    }

    /// willAppear: chỉ iPhone iOS 26+ với nền đục (nơi HostFill có thể đổi chiều cao) — giữ nội dung
    /// ẩn tới khi chiều cao ổn định; hẹn giờ trần luôn hiện lại (không bao giờ vô hình quá `cap`).
    private func armSettleGuard() {
        guard Self.hostFillEligible, let kb = keyboard, !kb.isTornDown, kb.paintsBackdrop else { return }
        let now = CACurrentMediaTime()
        settleGuard.arm(now: now)
        settleArmedAt = now
        kb.alpha = 0
        view.setNeedsLayout()   // chắc chắn có lượt layout đánh giá (controller hiện lại không xé)
        DispatchQueue.main.asyncAfter(deadline: .now() + HeightSettleGuard.cap) { [weak self] in
            guard let self, self.settleGuard.reveal(now: CACurrentMediaTime()) else { return }
            TouchLog.write("settle: cap reached → show")
            self.showContent()
        }
    }

    /// Hiện nội dung đang giữ ẩn (force: bỏ qua trần — chạm / ẩn / xé / không đủ điều kiện).
    private func revealContent(force: Bool) {
        if settleGuard.reveal(now: CACurrentMediaTime(), force: force) { showContent() }
    }

    private func showContent() {
        guard let kb = keyboard, kb.alpha < 1 else { return }
        // Còn trong lượt dựng khung đầu ⇒ hiện thẳng (chưa từng vẽ alpha 0); muộn hơn ⇒ mờ vào nhẹ.
        if CACurrentMediaTime() - settleArmedAt < 0.05 {
            kb.alpha = 1
        } else {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                kb.alpha = 1
            }
        }
    }
    #if DEBUG
    /// Test: nội dung đang giữ ẩn chờ chiều cao host.
    var debugContentHeld: Bool { settleGuard.hidden }
    #endif

    /// Xác nhận ở lượt layout SAU (không hành động trên khung tạm của cùng một pass).
    private func scheduleHostFillRecheck() {
        guard !hostFillRecheckScheduled else { return }
        hostFillRecheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.hostFillRecheckScheduled = false
            self.viewIfLoaded?.setNeedsLayout()
        }
    }

    /// Debug mode (Giới thiệu → Gỡ lỗi): hình học view ↔ superview ↔ window ↔ màn hình, mức xin
    /// chiều cao, safe area, trait — ghi khi ĐỔI (dedupe), để bắt dải kính hệ thống lộ phía trên.
    private func logHostGeometry(_ tag: String) {
        guard TouchLog.enabled, let v = viewIfLoaded, let kb = keyboard else { return }
        let r = NSCoder.string(for:) as (CGRect) -> String
        let ins = NSCoder.string(for:) as (UIEdgeInsets) -> String
        var chain: [String] = []
        var a = v.superview
        while let s = a, chain.count < 4 {
            chain.append("\(type(of: s)):\(r(s.bounds))")
            a = s.superview
        }
        let w = v.window
        let inWin = w.map { r(v.convert(v.bounds, to: $0)) } ?? "-"
        let winOnScreen = w.flatMap { win in
            win.windowScene.map { r(win.convert(win.bounds, to: $0.screen.coordinateSpace)) }
        } ?? "-"
        let screen = w?.windowScene.map { r($0.screen.bounds) } ?? "-"
        let t = v.traitCollection
        let alloc = hostAllocatedHeight()
        let band = alloc.map { String(format: "%.1f", $0 - v.bounds.height) } ?? "-"
        let body = "view=\(r(v.bounds)) inSuper=\(r(v.frame)) super=[\(chain.joined(separator: " > "))] "
            + "window=\(w.map { r($0.bounds) } ?? "-") inWin=\(inWin) winOnScreen=\(winOnScreen) screen=\(screen) "
            + "inputView=\(inputView.map { r($0.frame) } ?? "-") kb=\(r(kb.frame)) req=\(kb.heightRequestInfo) "
            + "safe=\(ins(v.safeAreaInsets)) winSafe=\(w.map { ins($0.safeAreaInsets) } ?? "-") "
            + "trait=style\(t.userInterfaceStyle.rawValue)/h\(t.horizontalSizeClass.rawValue)"
            + "/v\(t.verticalSizeClass.rawValue)/x\(t.displayScale) "
            + "alloc=\(alloc.map { "\($0)" } ?? "-") band=\(band) fillLocked=\(hostFill.locked) "
            + "backdrop=\(kb.paintsBackdrop) host=\(parent.map { String(describing: type(of: $0)) } ?? "-")"
        guard body != lastHostGeomKey else { return }
        lastHostGeomKey = body
        TouchLog.write("hostgeom[\(tag)] " + body)
    }

    private func isRecentEnglish(_ w: String?) -> Bool {
        guard let w else { return false }
        return recentEnglish.contains(w.lowercased())
    }

    private func noteRecentEnglish(_ w: String) {
        recentEnglish.append(w.lowercased())
        if recentEnglish.count > 4 { recentEnglish.removeFirst() }
    }

    /// Vuốt phím cách: đổi Tiếng Việt ↔ Tiếng Anh, lưu trạng thái cho lần hiện sau.
    /// KeyboardView đã rung + chạy hiệu ứng nhãn. Đang gõ dở một từ ở bảng chữ ⇒ CHUYỂN luôn
    /// từ đó sang ngôn ngữ đích, từ vẫn mở (ONBOARDING-SPEC §7, `EngineBridge.convertComposing`);
    /// bảng số/emoji, từ vuốt còn mở, hay không chuyển được ⇒ như cũ: chốt từ (học như ranh
    /// giới) rồi đổi.
    fileprivate func toggleLanguage() {
        guard spaceFlickSetting else { return }
        if externalChangePending { syncComposition("flick") }
        applyingEdit = true
        defer { applyingEdit = false }
        learnSettledSwipe()
        let accepted = bridge.openWordAccepted
        language = language.toggled
        UserDefaults.standard.set(language.rawValue, forKey: KeyboardLanguage.storageKey)
        commitAndLearn(bridge.flickLanguage(toEnglish: language == .en,
                                            convertWord: keyboard.spaceFlickConvertsWord,
                                            proxy: Proxy(p: textProxy)),
                       accepted: accepted)
        if language == .en { warmUpEnglish() }
        keyboard.spaceLanguage = language
        swipeSuggest = nil
        restoreUndo = nil; undoOfferActive = false
        suggestionGen += 1
        updateSuggestions()
    }

    /// Nạp enlexicon + bảng từ phổ biến ở nền (lần đầu vào Tiếng Anh), khỏi trễ phím đầu.
    fileprivate func warmUpEnglish() {
        SwipeEnglish.warmUp()
    }

    /// Từ vuốt được chốt bởi phím chữ trước (dấu cách treo) — học khi chắc chắn.
    fileprivate func learnSettledSwipe() {
        if let s = bridge.takeSettledCommit() { commitAndLearn(s.word, accepted: s.accepted) }
    }

    fileprivate func swipeBegan() {
        guard swipe != nil else { return }
        pushSwipeLayout(prepare: false)
        if externalChangePending { syncComposition("swipe") }
        // Chữ đầu cú vuốt chưa từng chèn (KeyboardView hoãn tới lúc nhấc, #172) ⇒ không gì để huỷ.
        restoreUndo = nil; undoOfferActive = false
        swipeSuggest = nil
        swipeReviseUndo = nil
        swipeTyped = nil; swipeTypedUndo = nil
    }

    fileprivate func swipeEnded(_ path: SwipePath, _ sc: SwipeCase) {
        guard let swipe else { return }
        if externalChangePending { syncComposition("swipe") }
        wordSwipeRestore = nil
        learnSettledSwipe()
        applyingEdit = true
        defer { applyingEdit = false }
        // Ngữ cảnh: từ đang gõ dở (sẽ được chốt trước từ vuốt) hoặc từ liền trước.
        let composing = bridge.isComposing
        let prev = composing ? bridge.predictedCommit : lastWord
        let prev2 = composing ? lastWord : lastWord2
        let ctx = prev.map { langModel.nextWords(after: $0, prev2: prev2, limit: 24) } ?? []
        let lm = langModel
        // Ngôn ngữ theo ≤ 3 từ trước (qua cả dấu câu — liên tục ngôn ngữ): từ Anh vừa vuốt (nhãn)
        // chắc nhất, rồi bảng từ của engine + từ điển; mặc định nghiêng tiếng Việt.
        let englishOnly = bridge.englishMode
        let english: SwipeEnglishPrior? = englishOnly ? SwipeLangContext.onlyEnglishPrior
            : swipeEnglishSetting ? SwipeLangContext.prior(SwipeLangContext.kinds(
                composing: composing, pending: prev,
                pendingEnglish: bridge.isLiteralSwipeWordOpen || isRecentEnglish(prev),
                recent: langRecent, english: { self.isRecentEnglish($0) })) : nil
        // Từ vuốt trước còn nguyên (mở, chưa sửa dấu, chưa chọn phương án) ⇒ cú này sửa lại được.
        let previous = swipeRevisable.flatMap { r -> SwipeTyping.Revisable? in
            bridge.isSwipeWordOpen && bridge.isFreshSwipeWord && !bridge.openWordAccepted
                && !bridge.isLiteralSwipeWordOpen && bridge.composedWord == r.word ? r : nil
        }
        // Từ TIẾNG ANH vừa vuốt còn nguyên (chèn nguyên văn, không sửa lại được) — chỉ để viết hoa
        // ngược chuỗi tên riêng ("new" + "york" → "New York").
        let previousLiteral = bridge.isLiteralSwipeWordOpen && bridge.isFreshSwipeWord && !bridge.openWordAccepted
            ? bridge.composedWord : nil
        swipeRevisable = nil
        swipeReviseUndo = nil
        let out = swipe.finish(path, case: sc, contextWords: ctx, count: { lm.count(of: $0) },
                               prev: prev, prev2: prev2, english: english, englishOnly: englishOnly,
                               previous: previous,
                               previousLiteral: previousLiteral,
                               nextWords: { lm.nextWords(after: $0, prev2: $1, limit: 24) },
                               learnedCase: { lm.learnedCase($0) }, properNouns: !lowercaseSuggestions,
                               bridge: bridge, proxy: Proxy(p: textProxy))
        if let out {
            if let c = out.committed { commitAndLearn(c.word, accepted: c.accepted) }
            keyboard.swipeCommitted()          // "Pháo hoa cuối nét" (kiểu khác: 0 việc)
            fxSwipeKeyword(out.word, path: path)   // "Từ khoá" theo từ vuốt (kiểu khác: một phép so sánh)
            swipeReviseUndo = out.revised
            if !out.scored.isEmpty, bridge.isSwipeWordOpen {
                swipeRevisable = SwipeTyping.Revisable(word: out.word, scored: out.scored, sc: sc)
            }
            if out.english { noteRecentEnglish(out.word) }
            let alts = SensitiveWords.filter(out.alternatives, after: prev, prev2: prev2, enabled: filterSensitive)
            swipeSuggest = alts.isEmpty || !bridge.isSwipeWordOpen ? nil
                : (out.word, alts, out.englishAlternatives)
            KeyboardView.clickLetter()
        }
        lastInsertWasSpace = false
        lastKeyWasEmailTrigger = false
        restoreUndo = nil; undoOfferActive = false
        suggestionGen += 1
        updateAutoShift()
        updateSuggestions()
    }

    /// Chạm phương án trên thanh gợi ý sau vuốt: thay từ, vẫn để mở (không thêm dấu
    /// cách). false = không phải phương án vuốt (caller xử lý như gợi ý thường).
    fileprivate func acceptSwipeAlternative(_ item: String) -> Bool {
        guard let s = swipeSuggest, s.alts.contains(item) else { return false }
        applyingEdit = true
        defer { applyingEdit = false }
        let wasEnglish = bridge.isLiteralSwipeWordOpen
        let itemEnglish = s.english.contains(item)
        guard bridge.replaceSwipeWord(with: item, literal: itemEnglish,
                                      proxy: Proxy(p: textProxy)) else {
            swipeSuggest = nil
            return false
        }
        if itemEnglish { noteRecentEnglish(item) }
        swipeRevisable = nil                  // user đã chọn: cú vuốt kế không sửa lại từ này
        var english = s.english
        english.remove(item)
        if wasEnglish { english.insert(s.current) }
        swipeSuggest = (item, [s.current] + s.alts.filter { $0 != item }, english)
        KeyboardView.clickModifier()
        suggestionGen += 1
        updateSuggestions()
        return true
    }
}

extension KeyboardViewController {
    /// Chip "↩︎ từ cũ": trả từ vuốt trước về như lúc vuốt; học lại từ cũ như user chọn
    /// (rút lượt học từ mới như Android — undoRevise).
    fileprivate func undoSwipeRevision() {
        if let t = swipeTypedUndo {
            swipeTypedUndo = nil
            undoTypedRevision(t)
            return
        }
        guard let u = swipeReviseUndo else { return }
        swipeReviseUndo = nil
        applyingEdit = true
        defer { applyingEdit = false }
        swipeRevisable = nil                  // như Android: ứng viên từ đang mở chấm theo từ mới
        if bridge.restoreRevisedWord(old: u.old, new: u.new, proxy: Proxy(p: textProxy)),
           lastWord == u.new {
            // rút lượt học từ mới (như Android KeyboardSession.undoRevise), học lại từ cũ
            if let l = lastLearned, l.word == u.new {
                if let r = l.receipt { langModel.retract(r) }
                lastWord = l.prev1; lastWord2 = l.prev2
            } else {
                lastWord = lastWord2; lastWord2 = nil
            }
            commitAndLearn(u.old, accepted: true)
            KeyboardView.clickModifier()
        }
        suggestionGen += 1
        updateSuggestions()
    }
}

extension KeyboardViewController {
    /// Phím này có thể chốt một từ vuốt Việt còn nguyên (mở, chưa sửa dấu, chưa chọn phương án)
    /// ⇒ ứng viên chờ từ gõ kế. nil khi gõ vuốt tắt (swipeRevisable luôn nil) — 0 việc.
    fileprivate func typedArmCandidate(_ key: KeyboardView.Key) -> SwipeRevise.Typed? {
        guard let r = swipeRevisable else { return nil }
        switch key {
        case .letter, .space: break
        default: return nil
        }
        guard bridge.isSwipeWordOpen, bridge.isFreshSwipeWord, !bridge.openWordAccepted,
              !bridge.isLiteralSwipeWordOpen, !bridge.englishMode, bridge.composedWord == r.word else { return nil }
        return SwipeRevise.Typed(word: r.word, scored: r.scored, sc: r.sc, prev: lastWord)
    }

    /// Từ gõ vừa được chốt ngay sau từ vuốt đang chờ: chấm lại từ vuốt; đổi thì thay đúng đuôi
    /// "từ vuốt ␠ từ gõ ranh giới" (đọc lại trước khi xoá) và học lại hai từ theo thứ tự mới.
    fileprivate func reviseTypedSwipe(_ w: (rev: SwipeRevise.Typed, learned: Learned?), typed: String,
                                      boundary: String, proxy: TextProxyLike) {
        let lm = langModel
        guard let e = SwipeRevise.reviseTyped(w.rev, typed: typed, boundary: boundary,
                                              before: proxy.contextBeforeInput,
                                              learnedCase: lowercaseSuggestions ? nil : { lm.learnedCase($0) }),
              SwipeRevise.apply(e, proxy: proxy) else { return }
        let sentenceBreak = boundary != " "
        let newLearned = relearnPair(before: w.learned, first: e.new, typed: typed)
        if sentenceBreak { lastWord = nil; lastWord2 = nil }
        swipeTypedUndo = (e, newLearned, sentenceBreak)
        TouchLog.write("swipe: sửa từ vuốt trước theo từ gõ (\(e.old.count)→\(e.new.count) ký tự)")
    }

    /// Rút lượt học của từ gõ vừa chốt (lastLearned) và của từ đứng trước nó (`before`), học lại
    /// `first` (cùng ngữ cảnh trái cũ) rồi `typed`. Trả lượt học của `first`.
    private func relearnPair(before: Learned?, first: String, typed: String, accepted: Bool = false) -> Learned? {
        if let l = lastLearned, l.word == typed, let r = l.receipt { langModel.retract(r) }
        if let b = before {
            if let r = b.receipt { langModel.retract(r) }
            lastWord = b.prev1; lastWord2 = b.prev2
        } else {
            lastWord = nil; lastWord2 = nil
        }
        commitAndLearn(first, accepted: accepted)
        let firstLearned = lastLearned
        commitAndLearn(typed)
        return firstLearned
    }

    /// Chip "↩︎ từ cũ" sau khi sửa theo từ gõ: trả từ vuốt về như lúc vuốt (đuôi phải khớp).
    fileprivate func undoTypedRevision(_ u: (edit: SwipeRevise.TypedEdit, newLearned: Learned?, sentenceBreak: Bool)) {
        applyingEdit = true
        defer { applyingEdit = false }
        if SwipeRevise.apply(u.edit, undo: true, proxy: Proxy(p: textProxy)) {
            _ = relearnPair(before: u.newLearned, first: u.edit.old, typed: u.edit.typed, accepted: true)
            if u.sentenceBreak { lastWord = nil; lastWord2 = nil }
            KeyboardView.clickModifier()
        }
        suggestionGen += 1
        updateSuggestions()
    }
}

extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

// MARK: vuốt trái trên ⌫ = xoá theo từ (kiểu Gboard) + ô "Khôi phục"
// Tách riêng để không đụng luồng backspace/engine: KeyboardView báo chạm xuống
// (chụp context TRƯỚC lần xoá của chạm), hỏi số từ tối đa khi bắt đầu vuốt, và
// báo số từ khi nhấc tay. Kế hoạch xoá là hàm thuần WordDelete.plan.
extension KeyboardViewController {
    fileprivate func wireWordSwipe() {
        keyboard.onBackspaceTouchDown = { [weak self] in
            guard let self else { return }
            // documentContextBeforeInput là bản host đẩy sẵn — đọc rẻ (xem pasteOffer).
            self.wordSwipeSnapshot = (self.textProxy.documentContextBeforeInput,
                                      self.bridge.composedWord)
        }
        keyboard.wordSwipeLimit = { [weak self] in
            guard let snap = self?.wordSwipeSnapshot, let ctx = snap.context else { return 0 }
            return WordDelete.availableWords(context: ctx)
        }
        keyboard.onWordSwipeEnd = { [weak self] n in self?.commitWordSwipe(n) }
        keyboard.onTrackpad = { [weak self] on in self?.trackpadChanged(on) }
    }

    /// Đang giữ phím cách di con trỏ: mỗi bước chỉ còn bridge.reset + adjustTextPosition.
    /// Auto-shift / gợi ý / đồng bộ composition (đọc context) / đọc lại trait ô do
    /// selectionDidChange của host — tất cả hoãn tới lúc nhả tay, chạy MỘT lần.
    fileprivate func trackpadChanged(_ on: Bool) {
        trackpadActive = on
        trackpadContext.reset()
        trackpadCharsPerLine = 0              // đo lại khi cần (xoay / đổi cỡ chữ)
        guard !on else { return }
        externalChangePending = false      // đổi selection trong lúc kéo là của mình
        updateAutoShift()
        updateSuggestions()
    }

    /// Ký tự/dòng hiển thị ước lượng của ô host (GẦN ĐÚNG — extension không thấy bố cục
    /// host): bề ngang bàn phím trừ lề ô, chia bề rộng TB một ký tự font thân bài theo cỡ
    /// chữ hệ thống. Chỉ chạy ở bước dọc đầu tiên của một lần kéo; đo câu mẫu một lần/cỡ.
    private func estimateCharsPerLine() -> Int {
        let category = traitCollection.preferredContentSizeCategory
        let advance: Double
        if let a = trackpadAdvance, a.0 == category { advance = a.1 }
        else {
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
            let w = (VerticalMove.sample as NSString).size(withAttributes: [.font: font]).width
            advance = VerticalMove.avgAdvance(sampleWidth: Double(w))
            trackpadAdvance = (category, advance)
        }
        return VerticalMove.charsPerLine(fieldWidth: Double(view.bounds.width) - VerticalMove.fieldInset,
                                         avgAdvance: advance)
    }

    fileprivate func commitWordSwipe(_ words: Int) {
        guard let snap = wordSwipeSnapshot else { return }
        wordSwipeSnapshot = nil
        addTonesUndo = nil
        applyingEdit = true
        defer { applyingEdit = false }
        let current = textProxy.documentContextBeforeInput
        guard let plan = WordDelete.plan(snapshot: snap.context, composed: snap.composed,
                                         current: current, words: words) else {
            TouchLog.write("failsafe: word-swipe words=\(words) ctx=\(current == nil ? "nil" : "mismatch") → skip")
            return
        }
        // Từ đang soạn (nếu có) là từ thứ nhất — engine bỏ nó như một lần dán.
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        for _ in 0..<plan.deleteNow { textProxy.deleteBackward() }
        if !plan.reinsert.isEmpty { textProxy.insertText(plan.reinsert) }
        wordSwipeRestore = plan.removed.isEmpty ? nil
            : (text: plan.removed, tail: WordDelete.restoreTail(plan.remaining))
        if TouchLog.enabled {
            TouchLog.write("word-swipe words=\(words) del=\(plan.deleteNow) reins=\(plan.reinsert.count) removed=\(plan.removed.count)")
        }
        updateAutoShift(); updateSuggestions()
    }

    fileprivate func restoreWordSwipe() {
        guard let r = wordSwipeRestore else { return }
        wordSwipeRestore = nil
        applyingEdit = true
        defer { applyingEdit = false }
        guard WordDelete.canRestore(context: textProxy.documentContextBeforeInput,
                                    tail: r.tail) else {
            TouchLog.write("failsafe: word-swipe restore context moved → skip")
            updateAutoShift(); updateSuggestions()
            return
        }
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        textProxy.insertText(r.text)
        KeyboardView.clickModifier()
        updateAutoShift(); updateSuggestions()
    }
}

// MARK: công cụ văn bản (Plus) — TextTools/TextToolRunner là logic thuần, đây chỉ là glue.
extension KeyboardViewController {
    /// Nguồn: selectedText (iOS 16+) nếu có, không thì đoạn trước con trỏ (tới xuống dòng).
    fileprivate func applyTextTool(_ tool: TextTool) {
        guard keyboard.textToolsEnabled else { return }   // Plus + công tắc (viewWillAppear)
        suggestionSnap = nil
        applyingEdit = true
        defer { applyingEdit = false }
        // Từ đang soạn đã nằm trong ô (iOS chèn thẳng) — engine bỏ nó như sau khi dán.
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        wordSwipeRestore = nil
        textToolUndo = nil
        var selected: String?
        if #available(iOS 16.0, *) { selected = textProxy.selectedText }
        let outcome = TextToolRunner.apply(tool, proxy: Proxy(p: textProxy), selectedText: selected)
        switch outcome {
        case .applied(let u): textToolUndo = u
        case .failsafe: TouchLog.write("failsafe: text tool \(tool.rawValue) context mismatch/NFD → skip")
        case .unchanged, .noSource: break
        }
        updateAutoShift(); updateSuggestions()
    }

    /// Nút "Thêm dấu" trong thẻ Công cụ (☰): thêm dấu cho vùng chọn / đoạn không dấu cuối trước
    /// con trỏ. Gate: nhóm công cụ văn bản (Plus + công tắc) + Plus .sentenceDiacritics; KHÔNG cần
    /// công tắc chip tự hiện (addTonesChip chỉ để tránh chạy AddTones mỗi dấu cách). Trên máy,
    /// không mạng. Hoàn tác như công cụ văn bản ("↩︎ Hoàn tác" / ⌫ ngay sau).
    fileprivate func applyAddTonesTool() {
        guard keyboard.textToolsEnabled, PlusGate.isUnlocked(.sentenceDiacritics) else { return }
        suggestionSnap = nil
        applyingEdit = true
        defer { applyingEdit = false }
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        wordSwipeRestore = nil
        textToolUndo = nil
        addTonesCache = nil
        var selected: String?
        if #available(iOS 16.0, *) { selected = textProxy.selectedText }
        let lm = langModel
        let fs = filterSensitive
        let personal = AddTones.Personal(count: { lm.count(of: $0) },
                                         pair: { fs && SensitiveWords.isPair($0, $1) ? 0 : lm.bigramCount($0, $1) })
        switch TextToolRunner.addTones(proxy: Proxy(p: textProxy), selectedText: selected, personal: personal) {
        case .applied(let u): textToolUndo = u
        case .failsafe: TouchLog.write("failsafe: add tones button context mismatch/NFD → skip")
        case .unchanged, .noSource: break
        }
        updateAutoShift(); updateSuggestions()
    }

    fileprivate func undoTextTool() {
        guard let u = textToolUndo else { return }
        textToolUndo = nil
        applyingEdit = true
        defer { applyingEdit = false }
        if !TextToolRunner.undo(u, proxy: Proxy(p: textProxy)) {
            TouchLog.write("failsafe: text tool undo context moved → skip")
        }
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        KeyboardView.clickModifier()
        updateAutoShift(); updateSuggestions()
    }
}

// MARK: dịch trên máy (Plus, iOS 26+) — logic thuần: Shared/TranslatePrefs.swift + Keyboard/Translate.swift.
extension KeyboardViewController {
    /// Bấm chip "Dịch ↔ …": nguồn như công cụ văn bản; dịch bất đồng bộ (Translation chạy
    /// ngoài tiến trình), xong mới thay chữ — chỉ khi ô còn y như lúc bấm.
    fileprivate func applyTranslate() {
        guard #available(iOS 26.0, *), PlusGate.isUnlocked(.translate) else { return }
        translateTask?.cancel(); translateTask = nil
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        wordSwipeRestore = nil
        textToolUndo = nil
        let selected = textProxy.selectedText
        let before = textProxy.documentContextBeforeInput
        guard let src = TextTools.source(selected: selected, before: before) else {
            showTranslateNotice(L("Chọn hoặc gõ chữ cần dịch"))
            return
        }
        // Không chọn ⇒ chỉ đoạn đang gõ (iOS không đưa bàn phím cả văn bản): ô còn chữ khác
        // thì nói rõ thay vì lặng lẽ dịch một phần (tester Plus 15/10/2026).
        let partial = TranslateText.coversOnlyPart(isSelection: src.isSelection, source: src.text, before: before,
                                                   after: src.isSelection ? nil : textProxy.documentContextAfterInput)
        let target = TranslatePrefs.target(UserDefaultsProvider.shared)
        showTranslateNotice(L("Đang dịch…"))
        translateTask = Task { @MainActor [weak self] in
            let core = TranslateText.splitWhitespace(src.text).core
            let result: Result<String, TranslateFailure>
            if let pair = TranslateDirection.resolve(detected: TranslateText.detect(core, target: target), target: target) {
                result = await Self.translateMaybeAI(core, pair: pair)
            } else {
                result = .failure(.unknownLanguage)
            }
            guard !Task.isCancelled, let self else { return }
            self.finishTranslate(result.map { TranslateText.rewrap(original: src.text, translated: $0) }, src: src,
                                 partial: partial)
        }
    }

    /// "Dịch bằng Apple Intelligence" (thử nghiệm) bật + model dùng được ⇒ hỏi model trước; lỗi /
    /// quá hạn / kết quả không qua AITranslate.validate / đoạn dài ⇒ Apple Translation như thường.
    /// Tắt ⇒ không dlopen VTIntelligence (0 chi phí).
    @available(iOS 26.0, *)
    private static func translateMaybeAI(_ text: String, pair: TranslateDirection.Pair) async -> Result<String, TranslateFailure> {
        if TranslatePrefs.useAI(UserDefaultsProvider.shared), text.count <= AITranslate.maxChars,
           AIAssistLoader.status() == .available {
            let t0 = CACurrentMediaTime()
            let r = await AIAssistLoader.run(kind: 3, instructions: AITranslate.instructions,
                                             prompt: AITranslate.prompt(text, source: pair.source, target: pair.target),
                                             timeout: AITranslate.timeout)
            if case .success(let s) = r, let ok = AITranslate.validate(s, source: text, target: pair.target) {
                TouchLog.write(String(format: "translate ai ok %.0fms", (CACurrentMediaTime() - t0) * 1000))
                return .success(ok)
            }
            TouchLog.write("translate ai → apple translation")
        }
        return await OnDeviceTranslator.translate(text, pair: pair)
    }

    private func finishTranslate(_ r: Result<String, TranslateFailure>, src: TextTools.Source, partial: Bool = false) {
        translateTask = nil
        translateNotice = nil
        switch r {
        case .success(let out):
            applyingEdit = true
            defer { applyingEdit = false }
            var selected: String?
            if #available(iOS 16.0, *) { selected = textProxy.selectedText }
            switch TextToolRunner.replace(src, with: out, proxy: Proxy(p: textProxy),
                                          strict: true, currentSelection: selected) {
            case .applied(let u):
                textToolUndo = u
                // ⌫ ngay sau vẫn hoàn tác (textToolUndo); chip nói rõ chỉ dịch một đoạn.
                if partial { showTranslateNotice(Self.translatePartialNotice, refresh: false) }
            case .failsafe:
                TouchLog.write("failsafe: translate context changed while waiting → skip")
                showTranslateNotice(L("Chữ đã đổi — bấm Dịch lại"), refresh: false)
            case .unchanged, .noSource: break
            }
            bridge.reset()
            lastWord = nil; lastWord2 = nil
        case .failure(.notInstalled):
            showTranslateNotice(L("Mở app %@ để tải gói dịch", AppFlavor.displayName), opensApp: true, refresh: false)
        case .failure(.unsupported):
            showTranslateNotice(L("Máy chưa dịch được cặp ngôn ngữ này"), opensApp: true, refresh: false)
        case .failure(.unknownLanguage):
            showTranslateNotice(L("Không nhận ra ngôn ngữ"), refresh: false)
        case .failure(.failed):
            showTranslateNotice(L("Không dịch được"), refresh: false)
        }
        updateAutoShift(); updateSuggestions()
    }

    static var translatePartialNotice: String { L("Chỉ dịch đoạn đang gõ — chọn hết văn bản để dịch toàn bộ") }

    private func showTranslateNotice(_ text: String, opensApp: Bool = false, refresh: Bool = true) {
        translateNotice = (text, opensApp)
        if refresh { updateSuggestions() }
    }

    fileprivate func tapTranslateNotice() {
        let opens = translateNotice?.opensApp == true
        translateNotice = nil
        if opens { openTemplatesInApp("dich") }   // app mở trang Dịch trên máy (cần Toàn quyền)
        updateSuggestions()
    }
}

// MARK: log gỡ lỗi — ảnh chụp ô nhập (TouchLogAlerts). CHỈ khi Debug mode bật.
extension KeyboardViewController {
    /// Ghi `probe …` (độ dài / cờ / ID ô rút gọn) + dòng ⚠︎ khi bất thường chắc chắn. Chỉ sau
    /// viewDidAppear: documentIdentifier đọc sớm (phiên nhập chưa lập) là bẫy crash — đọc trong vtSafe.
    fileprivate func probeField(_ event: String) {
        guard TouchLog.enabled, probeReady else { return }
        let p = textProxy
        var sel = 0
        if #available(iOS 16.0, *) { sel = vtSafe(0) { p.selectedText?.count ?? 0 } }
        let now = TouchLogAlerts.Probe(
            doc: vtSafe("?") { String(p.documentIdentifier.uuidString.prefix(4)) },
            ctxLen: vtSafe(-1) { p.documentContextBeforeInput?.count ?? -1 },
            afterLen: vtSafe(-1) { p.documentContextAfterInput?.count ?? -1 },
            hasText: vtSafe(false) { p.hasText },
            selLen: sel)
        TouchLog.write("probe \(event) " + TouchLogAlerts.describe(now) + " host=\(probeHostEvents)")
        for a in TouchLogAlerts.anomalies(prev: probePrev, now: now, hostEvents: probeHostEvents) {
            TouchLog.write(TouchLogAlerts.mark + " " + a)
        }
        probePrev = now; probeHostEvents = 0
    }
}

// MARK: Apple Intelligence (Plus, iOS 26+) — logic: AIAssist.swift / AIProofread.swift.
extension KeyboardViewController {
    /// Chip clipboard xếp theo ô. Ô địa chỉ mà luật không ra địa chỉ ⇒ hỏi Apple Intelligence
    /// (chỉ khi công tắc bật — `ai` nil thì 0 chi phí), nền, một lần mỗi nội dung clipboard.
    fileprivate func fieldClipChips() -> [ClipChip] {
        var chips = clip.chips(currentChange: pasteSeenChange, usedChange: pasteUsedChange)
        let pref = fieldTraits?.preferredClipKind
        if pref == .address, let ai, !chips.contains(where: { $0.kind == .address }),
           let text = clip.chipSource(currentChange: pasteSeenChange, usedChange: pasteUsedChange),
           let a = ai.clipAddress(text: text, change: pasteSeenChange) {
            chips.append(ClipChip(kind: .address, value: a, label: L("Dán địa chỉ")))
        }
        return ClipDetect.prioritize(chips, for: pref)
    }

    fileprivate func makeAIAssist() -> AIAssist? {
        guard #available(iOS 26.0, *) else { return nil }
        return AIAssist(host: .init(
            proxy: { [unowned self] in self.textProxy },
            keyboard: { [weak self] in self?.keyboard },
            edit: { [weak self] body in
                guard let self else { return }
                self.applyingEdit = true
                defer { self.applyingEdit = false }
                self.bridge.reset()
                self.lastWord = nil; self.lastWord2 = nil
                self.restoreUndo = nil; self.undoOfferActive = false
                self.wordSwipeRestore = nil; self.textToolUndo = nil
                body()
            },
            refresh: { [weak self] in
                guard let self else { return }
                self.updateAutoShift(); self.updateSuggestions()
            }))
    }
}

// MARK: thêm dấu cho câu không dấu — chỉ khi người dùng bấm chip (logic thuần: AddTones.swift)
extension KeyboardViewController {
    /// Kế hoạch thêm dấu cho chữ trước con trỏ (cache theo văn bản); nil = không mời.
    /// documentContextBeforeInput là bản host đẩy sẵn — đọc rẻ (xem pasteOffer).
    fileprivate func addTonesPlan() -> AddTones.Plan? {
        guard addTonesSetting, bridge.composedWord.isEmpty,
              let before = textProxy.documentContextBeforeInput, !before.isEmpty else { return nil }
        if let c = addTonesCache, c.before == before { return c.plan }
        let lm = langModel
        // Lọc bật: cặp nhạy cảm (SensitiveWords.pairs, có trong seed) không thưởng khi chọn dấu.
        let fs = filterSensitive
        let personal = AddTones.Personal(count: { lm.count(of: $0) },
                                         pair: { fs && SensitiveWords.isPair($0, $1) ? 0 : lm.bigramCount($0, $1) })
        var plan = AddTones.plan(before, personal: personal)
        if plan?.original == addTonesDismissed { plan = nil }
        addTonesCache = (before, plan)
        return plan
    }

    /// Chạm "Thêm dấu": thay đuôi không dấu bằng bản có dấu — fail-safe CompositionSync
    /// (chữ trước con trỏ phải đúng là bản gốc), không xoá mù.
    fileprivate func applyAddTones() {
        addTonesCache = nil
        suggestionSnap = nil
        guard let plan = addTonesPlan() else { updateSuggestions(); return }
        addTonesCache = nil
        applyingEdit = true
        defer { applyingEdit = false }
        guard canDeleteBefore(plan.original, what: "add-tones") else { updateSuggestions(); return }
        for _ in 0..<plan.original.count { textProxy.deleteBackward() }
        textProxy.insertText(plan.replacement)
        bridge.reset()
        lastWord = nil; lastWord2 = nil
        restoreUndo = nil; undoOfferActive = false
        addTonesUndo = plan
        KeyboardView.clickModifier()
        updateAutoShift(); updateSuggestions()
    }

    /// "Hoàn tác" / ⌫ ngay sau: trả bản gốc nếu chữ trước con trỏ vẫn là bản vừa thay.
    fileprivate func undoAddTones() {
        guard let u = addTonesUndo else { return }
        addTonesUndo = nil
        addTonesCache = nil
        applyingEdit = true
        defer { applyingEdit = false }
        // Luôn đối chiếu (kể cả đuôi 1 ký tự): lệch / không đọc được ⇒ bỏ, không xoá mù.
        if textProxy.documentContextBeforeInput?.hasSuffix(u.replacement) == true {
            for _ in 0..<u.replacement.count { textProxy.deleteBackward() }
            textProxy.insertText(u.original)
            addTonesDismissed = u.original
            bridge.reset()
            lastWord = nil; lastWord2 = nil
            restoreUndo = nil; undoOfferActive = false
            KeyboardView.clickModifier()
        }
        updateAutoShift(); updateSuggestions()
    }
}



/// Đọc một thuộc tính của textDocumentProxy mà UIKit có thể NÉM NSException (iOS 27.0,
/// proxy chưa sẵn sàng) — trả `fallback` thay vì để bàn phím crash.
@inline(__always)
func vtSafe<T>(_ fallback: T, _ read: () -> T) -> T {
    var value = fallback
    if VTCatchException({ value = read() }) != nil { return fallback }
    return value
}

/// textDocumentProxy + bản sao chữ trước con trỏ (HostMirror). Mọi lệnh sửa của bàn phím đi qua
/// đây ⇒ HostMirror biết chính xác chữ host SẼ có; host vọng trễ (đẩy trạng thái cũ của chính
/// mình, đè bản lạc quan của proxy) ⇒ đọc context trả bản đó thay vì chữ cũ. Host thường (đồng
/// bộ): đọc thẳng proxy như trước, không thêm lượt đọc nào mỗi phím (chỉ một lần đọc nền khi
/// chưa biết). Thuộc tính trait (keyboardType, isSecureTextEntry…) chuyển tiếp nguyên trạng.
final class MirroredProxy: NSObject, UITextDocumentProxy {
    private let base: () -> UITextDocumentProxy
    private(set) var mirror = HostMirror()
    /// Đồng hồ (test thay được).
    var now: () -> Double = { CACurrentMediaTime() }

    init(base: @escaping () -> UITextDocumentProxy) { self.base = base }

    /// Host đẩy trạng thái (callback ngoài edit của mình): đọc context THẬT, đối chiếu với bản
    /// sao — trả context hiệu lực (trạng thái cũ của mình ⇒ chữ host sẽ có).
    func hostReported() -> String? {
        mirror.hostReported(base().documentContextBeforeInput, now: now())
    }
    /// Lần đẩy gần nhất của host là trạng thái cũ của chính mình.
    var hostLagging: Bool { mirror.lagging }
    func invalidateMirror() { mirror.invalidate() }

    // MARK: UITextDocumentProxy

    var documentContextBeforeInput: String? {
        mirror.override(now: now()) ?? base().documentContextBeforeInput
    }
    var documentContextAfterInput: String? { base().documentContextAfterInput }
    var selectedText: String? { base().selectedText }
    var documentInputMode: UITextInputMode? { base().documentInputMode }
    var documentIdentifier: UUID { base().documentIdentifier }
    var hasText: Bool { base().hasText }

    func insertText(_ text: String) {
        let p = base()
        mirror.willEdit(read: { p.documentContextBeforeInput })
        p.insertText(text)
        mirror.inserted(text, now: now())
    }

    func deleteBackward() {
        let p = base()
        mirror.willEdit(read: { p.documentContextBeforeInput })
        p.deleteBackward()
        mirror.deletedBackward(now: now())
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        mirror.invalidate()
        base().adjustTextPosition(byCharacterOffset: offset)
    }

    func setMarkedText(_ markedText: String, selectedRange: NSRange) {
        mirror.invalidate()
        base().setMarkedText(markedText, selectedRange: selectedRange)
    }

    func unmarkText() {
        mirror.invalidate()
        base().unmarkText()
    }

    // Trait (thành viên optional của UITextInputTraits) + mọi selector khác: chuyển tiếp.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (base() as AnyObject).responds(to: aSelector)
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? { base() }
}
