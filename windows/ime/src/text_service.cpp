#include "text_service.h"

#include <atomic>
#include <cstdio>
#include <new>

#include "config.h"
#include "retro_english.h"
#include <viettelex/vtx_engine.h>
#include "ipc.h"
#include "text_tool_ipc.h"
#include "version.h"
#include "display_attribute.h"
#include "edit_session.h"
#include "tsf_sink.h"

namespace vtx::tip {

namespace {

// Keeps a COM object alive inside an async edit-session lambda.
template <class T>
class Ref {
public:
    explicit Ref(T* p) : p_(p) { if (p_) p_->AddRef(); }
    Ref(const Ref& o) : p_(o.p_) { if (p_) p_->AddRef(); }
    Ref& operator=(const Ref&) = delete;
    ~Ref() { if (p_) p_->Release(); }
    T* get() const { return p_; }
    T* operator->() const { return p_; }

private:
    T* p_;
};

template <class T>
void SafeRelease(T*& p) {
    if (p) {
        p->Release();
        p = nullptr;
    }
}

uint8_t modBit(uint32_t v) {
    switch (v) {
        case vk::Control: case vk::LControl: case vk::RControl: return kModCtrl;
        case vk::Shift: case vk::LShift: case vk::RShift: return kModShift;
        case vk::Menu: case vk::LMenu: case vk::RMenu: return kModAlt;
        case vk::LWin: case vk::RWin: return kModWin;
        default: return 0;
    }
}

bool keyDown(int vkey) { return (GetKeyState(vkey) & 0x8000) != 0; }

}  // namespace

// ---------------------------------------------------------------- lifetime

HRESULT TextService::CreateInstance(IUnknown* outer, REFIID riid, void** ppv) {
    if (!ppv) return E_INVALIDARG;
    *ppv = nullptr;
    if (outer) return CLASS_E_NOAGGREGATION;
    auto* s = new (std::nothrow) TextService();
    if (!s) return E_OUTOFMEMORY;
    if (!s->session_.ok()) {
        s->Release();
        return E_OUTOFMEMORY;
    }
    HRESULT hr = s->QueryInterface(riid, ppv);
    s->Release();
    return hr;
}

TextService::TextService() { DllAddRef(); }
TextService::~TextService() { DllRelease(); }

STDMETHODIMP TextService::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_INVALIDARG;
    *ppv = nullptr;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfTextInputProcessor) ||
        IsEqualIID(riid, IID_ITfTextInputProcessorEx))
        *ppv = static_cast<ITfTextInputProcessorEx*>(this);
    else if (IsEqualIID(riid, IID_ITfThreadMgrEventSink))
        *ppv = static_cast<ITfThreadMgrEventSink*>(this);
    else if (IsEqualIID(riid, IID_ITfTextEditSink))
        *ppv = static_cast<ITfTextEditSink*>(this);
    else if (IsEqualIID(riid, IID_ITfKeyEventSink))
        *ppv = static_cast<ITfKeyEventSink*>(this);
    else if (IsEqualIID(riid, IID_ITfCompositionSink))
        *ppv = static_cast<ITfCompositionSink*>(this);
    else if (IsEqualIID(riid, IID_ITfDisplayAttributeProvider))
        *ppv = static_cast<ITfDisplayAttributeProvider*>(this);
    if (!*ppv) return E_NOINTERFACE;
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) TextService::AddRef() { return static_cast<ULONG>(InterlockedIncrement(&ref_)); }
STDMETHODIMP_(ULONG) TextService::Release() {
    LONG r = InterlockedDecrement(&ref_);
    if (r == 0) delete this;
    return static_cast<ULONG>(r);
}

// ---------------------------------------------------------------- activation

STDMETHODIMP TextService::Activate(ITfThreadMgr* ptim, TfClientId tid) { return ActivateEx(ptim, tid, 0); }

STDMETHODIMP TextService::ActivateEx(ITfThreadMgr* ptim, TfClientId tid, DWORD flags) {
    if (!ptim) return E_INVALIDARG;
    threadMgr_ = ptim;
    threadMgr_->AddRef();
    clientId_ = tid;
    // Console hosts (conhost / OpenConsole / Windows Terminal) activate TSF with
    // TF_TMAE_CONSOLE: their document is only the composition (see app_policy.h HostText).
    consoleHost_ = (flags & TF_TMAE_CONSOLE) != 0;

    config::init((flags & TF_TMAE_SECUREMODE) != 0);
    applyConfig(true);
    publishLangProp();
    if (config::logging())
        config::log(std::string("activated in ") + config::exeName() + (consoleHost_ ? " (console)" : "") +
                    " rule " + std::to_string(static_cast<int>(config::appMode())));

    if (!initThreadMgrSink() || !initKeySink()) {
        Deactivate();
        return E_FAIL;
    }
    registerDisplayAtom();
    updatePreservedKey();
    createToolWindow();  // Công cụ văn bản: VietTelex.exe asks for the selection here

    // No language-bar item: the taskbar already shows the keyboard-profile icon (the one
    // chosen in Settings); a second, input-mode icon next to it was redundant (1.0.8).
    // Việt/Anh state is shown by the optional tray icon in VietTelex.exe.

    ITfDocumentMgr* dm = nullptr;
    if (SUCCEEDED(threadMgr_->GetFocus(&dm)) && dm) {
        hookTextEditSink(dm);
        dm->Release();
    }
    config::log("activated");
    return S_OK;
}

STDMETHODIMP TextService::Deactivate() {
    config::log("deactivated");  // a later "activated" = a new instance: per-app latches start over
    suspendPosted_ = 0;
    hideHint();
    dropHintWork();
    popup_.destroy();
    destroyToolWindow();
    clearLangProp();
    clearTypedWord();
    if (composition_ && compositionContext_) {
        // Best effort: close our composition so the app keeps plain text.
        ITfContext* ctx = compositionContext_;
        RunEditSession(ctx, clientId_, TF_ES_SYNC | TF_ES_READWRITE, [this, ctx](TfEditCookie ec) -> HRESULT {
            TsfTextSink sink(this, ctx, ec);
            session_.flush(sink);
            return S_OK;
        });
    }
    clearComposition();
    session_.resetContext();
    SafeRelease(targetCtx_);
    unhookTextEditSink();

    if (altZPreserved_ && threadMgr_) {
        ITfKeystrokeMgr* km = nullptr;
        if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&km))) && km) {
            TF_PRESERVEDKEY pk = {'Z', TF_MOD_ALT};
            km->UnpreserveKey(GUID_PreservedKeyToggle, &pk);
            km->Release();
        }
        altZPreserved_ = false;
    }
    uninitKeySink();
    uninitThreadMgrSink();
    SafeRelease(threadMgr_);
    clientId_ = TF_CLIENTID_NULL;
    return S_OK;
}

bool TextService::initThreadMgrSink() {
    ITfSource* src = nullptr;
    if (FAILED(threadMgr_->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&src))) || !src) return false;
    HRESULT hr = src->AdviseSink(IID_ITfThreadMgrEventSink, static_cast<ITfThreadMgrEventSink*>(this),
                                 &threadMgrCookie_);
    src->Release();
    if (FAILED(hr)) threadMgrCookie_ = TF_INVALID_COOKIE;
    return SUCCEEDED(hr);
}

void TextService::uninitThreadMgrSink() {
    if (threadMgrCookie_ == TF_INVALID_COOKIE || !threadMgr_) return;
    ITfSource* src = nullptr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&src))) && src) {
        src->UnadviseSink(threadMgrCookie_);
        src->Release();
    }
    threadMgrCookie_ = TF_INVALID_COOKIE;
}

bool TextService::initKeySink() {
    ITfKeystrokeMgr* km = nullptr;
    if (FAILED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&km))) || !km) return false;
    HRESULT hr = km->AdviseKeyEventSink(clientId_, static_cast<ITfKeyEventSink*>(this), TRUE);
    km->Release();
    keySinkAdvised_ = SUCCEEDED(hr);
    return keySinkAdvised_;
}

void TextService::uninitKeySink() {
    if (!keySinkAdvised_ || !threadMgr_) return;
    ITfKeystrokeMgr* km = nullptr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&km))) && km) {
        km->UnadviseKeyEventSink(clientId_);
        km->Release();
    }
    keySinkAdvised_ = false;
}

void TextService::updatePreservedKey() {
    if (!threadMgr_) return;
    const bool want = hotkey_ == SwitchHotkey::AltZ;
    if (want == altZPreserved_) return;
    ITfKeystrokeMgr* km = nullptr;
    if (FAILED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&km))) || !km) return;
    TF_PRESERVEDKEY pk = {'Z', TF_MOD_ALT};
    if (want) {
        static const wchar_t kDesc[] = L"VietTelex: Việt/Anh";
        altZPreserved_ = SUCCEEDED(km->PreserveKey(clientId_, GUID_PreservedKeyToggle, &pk, kDesc,
                                                   static_cast<ULONG>(lstrlenW(kDesc))));
    } else {
        km->UnpreserveKey(GUID_PreservedKeyToggle, &pk);
        altZPreserved_ = false;
    }
    km->Release();
}

void TextService::registerDisplayAtom() {
    // TF_CreateCategoryMgr works in COM-less hosts (TIPCAP_COMLESS); msctf.dll is
    // necessarily loaded already when TSF activates us.
    ITfCategoryMgr* cm = nullptr;
    using CreateFn = HRESULT(WINAPI*)(ITfCategoryMgr**);
    if (HMODULE msctf = GetModuleHandleW(L"msctf.dll")) {
        auto fn = reinterpret_cast<CreateFn>(reinterpret_cast<void*>(GetProcAddress(msctf, "TF_CreateCategoryMgr")));
        if (fn && FAILED(fn(&cm))) cm = nullptr;
    }
    if (!cm && FAILED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
                                       reinterpret_cast<void**>(&cm))))
        cm = nullptr;
    if (cm) {
        if (FAILED(cm->RegisterGUID(GUID_DisplayAttributeInput, &displayAtom_))) displayAtom_ = TF_INVALID_GUIDATOM;
        if (FAILED(cm->RegisterGUID(GUID_DisplayAttributeMisspelled, &misspelledAtom_)))
            misspelledAtom_ = TF_INVALID_GUIDATOM;
        cm->Release();
    }
}

void TextService::hookTextEditSink(ITfDocumentMgr* dm) {
    unhookTextEditSink();
    if (!dm) return;
    ITfContext* ctx = nullptr;
    if (FAILED(dm->GetTop(&ctx)) || !ctx) return;
    ITfSource* src = nullptr;
    if (SUCCEEDED(ctx->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&src))) && src) {
        if (SUCCEEDED(src->AdviseSink(IID_ITfTextEditSink, static_cast<ITfTextEditSink*>(this), &editSinkCookie_))) {
            editSinkContext_ = ctx;
            ctx = nullptr;
        } else {
            editSinkCookie_ = TF_INVALID_COOKIE;
        }
        src->Release();
    }
    SafeRelease(ctx);
}

void TextService::unhookTextEditSink() {
    if (editSinkContext_ && editSinkCookie_ != TF_INVALID_COOKIE) {
        ITfSource* src = nullptr;
        if (SUCCEEDED(editSinkContext_->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&src))) && src) {
            src->UnadviseSink(editSinkCookie_);
            src->Release();
        }
    }
    editSinkCookie_ = TF_INVALID_COOKIE;
    SafeRelease(editSinkContext_);
}

// ---------------------------------------------------------------- configuration

void TextService::applyConfig(bool force) {
    unsigned long gen = config::refresh();
    if (force || gen != settingsGen_ || !settings_) {
        settingsGen_ = gen;
        settings_ = config::snapshot();
        const Settings& s = *settings_;

        SessionOptions o;
        o.engineFlags = s.engineFlags();
        // "Tự sửa từ phía trước": never on the secure desktop, nor in terminals / remote
        // viewers / games (retro_english.h); the session also skips any field it cannot read.
        if (config::secureMode() || !retro::allowedForApp(config::exeName()))
            o.engineFlags &= ~static_cast<uint32_t>(VTX_RETRO_ENGLISH);
        // Switch off (contextualEnglish on): offer the correction as a caret hint instead.
        o.retroOffer = retro::modeFor(s.contextualEnglish, s.retroactiveEnglish) == retro::Mode::Offer;
        retroOfferOn_ = o.retroOffer && (o.engineFlags & VTX_RETRO_ENGLISH) != 0;
        o.autoRestore = s.autoRestore;
        o.reEditWord = s.reEditWord && !config::secureMode();
        o.underlineMisspelled = s.underlineMisspelled;
        o.shortcuts = config::secureMode() ? nullptr : &s.shortcuts;
        o.log = config::log;
        o.verboseLog = s.debugLogging;
        session_.configure(o);

        hintsOn_.math = s.mathResults;
        hintsOn_.number = s.numberChips;
        hintsOn_.typo = s.typoHints;
        hintsOn_.tones = s.toneHints;
        hintsOn_.date = s.dateHints;
        hintsAny_ = hintsOn_.any() && !config::secureMode();
        // Gợi ý từ: Windows' own setting, mirrored by VietTelex.exe into the snapshot.
        predictOn_ = s.systemTextPrediction && !config::secureMode();
        predictApp_ = hints::predictionAllowedForApp(config::exeName());
        learnOn_ = predictOn_ && predictApp_ && s.learnWords;
        if (!learnOn_) learn_.discard();
        if (!predictOn_) declinedPredict_.clear();
        if ((!hintsAny_ && !predictOn_ && !retroOfferOn_) ||
            (!predictOn_ && hint_ && (hint_->kind == hints::Kind::Predict || hint_->kind == hints::Kind::Email)) ||
            (!retroOfferOn_ && hint_ && hint_->kind == hints::Kind::Retro)) {
            hideHint();
            dropHintWork();
        }
        if (!hintsAny_) hintTracker_.reset();

        hotkey_ = parseSwitchHotkey(s.switchHotkey);
        chord_.disarm();
        updatePreservedKey();
        focusNotify_.reset();  // the tray may have been switched on or off
    }
    applyFocusState();
}

// Per focus / config change, cheap: the output mode of this app (WebView2: the owning
// app's rule) and Chế độ game.
void TextService::applyFocusState() {
    // Chế độ game is VietTelex.exe's runtime state (cleared at its start). If the app is
    // gone (crashed, autostart off), a stale "on" in the snapshot must not leave every
    // key passing through forever (FindWindow only while the snapshot says on).
    gameMode_ = effectiveGameMode(settings_->gameMode, [this] { return appRunning(); });

    const OutputMode want = config::appMode() == AppMode::InPlace ? OutputMode::InPlace : OutputMode::Composition;
    // (AppMode::Direct maps to Composition only for the case the app is not running.)
    if (want != session_.outputMode()) {
        if (composition_) endCompositionAsync();
        session_.setOutputMode(want);
    }
}

bool TextService::vietnamese() const { return config::vietnamese(); }

bool TextService::appRunning() const { return FindWindowW(kAppWindowClass, nullptr) != nullptr; }

namespace {
// Mandatory integrity RID of a process token (0x2000 medium, 0x3000 high).
bool tokenIntegrity(HANDLE process, DWORD& rid) {
    HANDLE tok = nullptr;
    if (!OpenProcessToken(process, TOKEN_QUERY, &tok)) return false;
    BYTE buf[128];
    DWORD len = 0;
    const bool ok = GetTokenInformation(tok, TokenIntegrityLevel, buf, sizeof buf, &len) != FALSE;
    if (ok) {
        auto* til = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buf);
        rid = *GetSidSubAuthority(til->Label.Sid, *GetSidSubAuthorityCount(til->Label.Sid) - 1);
    }
    CloseHandle(tok);
    return ok;
}
}  // namespace

// Can VietTelex.exe's hook type into THIS process's focused field? No when the app is not
// running, when this process has HIGHER integrity than the app (UIPI drops its
// SendInput — e.g. an elevated cmd.exe), or when the app marked the field NoDirect
// (echo mismatches / SendInput refused there).
bool TextService::directServesHere() const {
    HWND app = FindWindowW(kAppWindowClass, nullptr);
    if (!app) return false;
    HWND f = GetFocus();
    HWND root = f ? GetAncestor(f, GA_ROOT) : nullptr;
    if (f && GetPropW(f, kNoDirectProp)) return false;
    if (root && GetPropW(root, kNoDirectProp)) return false;
    // Handover ack (1.1.5): the hook confirmed it types in this window. Without it the TIP
    // composes (no underline) — a rule or a request alone left words raw (cmd, 1.1.4).
    // Its value is the app window that set it: a killed app's ack types nothing (2026-11).
    if (!root || !propFromLiveApp(reinterpret_cast<uintptr_t>(GetPropW(root, kDirectOnProp)),
                                  reinterpret_cast<uintptr_t>(app)))
        return false;
    return hookReachesHere(app);
}

// A classic Edit / RichEdit read through its own messages, around the transitory-extension
// parent store (Win10 Notepad with text in it: that store read nothing before the caret
// while the letters were on screen). The TIP runs on the window's own thread: SendMessage
// is a direct call. Logs the numbers once per focus (never the text) for the next report.
AppView TextService::focusEditEndsWith(ITfContext* ctx, const std::u16string& tail) const {
    if (host_ != HostText::NormalViaParent || !targetCtx_ || ctx != targetCtx_ || !focusEdit_ || tail.empty())
        return AppView::Unknown;
    HWND f = GetFocus();
    if (f != focusEdit_ || GetWindowThreadProcessId(f, nullptr) != GetCurrentThreadId()) return AppView::Unknown;
    DWORD selStart = 0, selEnd = 0;
    SendMessageW(f, EM_GETSEL, reinterpret_cast<WPARAM>(&selStart), reinterpret_cast<LPARAM>(&selEnd));
    if (selStart != selEnd) return AppView::Unknown;
    const LRESULT line = SendMessageW(f, EM_LINEFROMCHAR, static_cast<WPARAM>(selStart), 0);
    const LRESULT lineStart = line < 0 ? -1 : SendMessageW(f, EM_LINEINDEX, static_cast<WPARAM>(line), 0);
    if (lineStart < 0 || static_cast<DWORD>(lineStart) > selStart) return AppView::Unknown;
    const size_t col = selStart - static_cast<DWORD>(lineStart);
    if (col < tail.size() || col > 0xFFFE) return AppView::Unknown;
    std::vector<WCHAR> buf(col + 2, 0);
    *reinterpret_cast<WORD*>(buf.data()) = static_cast<WORD>(buf.size());  // EM_GETLINE: size in the first WORD
    const LRESULT copied = SendMessageW(f, EM_GETLINE, static_cast<WPARAM>(line), reinterpret_cast<LPARAM>(buf.data()));
    if (copied <= 0) return AppView::Unknown;
    const size_t n = static_cast<size_t>(copied) < buf.size() ? static_cast<size_t>(copied) : buf.size();
    const AppView v = editLineEndsWith(std::u16string(reinterpret_cast<const char16_t*>(buf.data()), n), col, tail);
    if (v == AppView::Shows && !session_.storeMisreads())
        config::log("Edit: caret " + std::to_string(selStart) + ", line " + std::to_string(line) + ", column " +
                    std::to_string(col) + ", length " + std::to_string(GetWindowTextLengthW(f)) +
                    " -> the typed word is there");
    return v;
}

// UIPI: VietTelex.exe's SendInput cannot reach this process when it runs at a HIGHER
// integrity than the app (started "as administrator") or the app's token is unreadable.
// Asked per key in a Direct field: this process's integrity is read once, the app's once per
// focus and app process (tip_caches.h HookReachCache).
bool TextService::hookReachesHere(HWND app) const {
    DWORD appPid = 0, theirs = 0;
    GetWindowThreadProcessId(app, &appPid);
    bool reaches = false;
    if (reachCache_.lookup(reinterpret_cast<uintptr_t>(app), appPid, reaches)) return reaches;
    static std::atomic<DWORD> ownRid{0};
    DWORD own = ownRid.load(std::memory_order_relaxed);
    if (!own) {
        own = 0x2000;
        tokenIntegrity(GetCurrentProcess(), own);
        ownRid.store(own, std::memory_order_relaxed);
    }
    bool known = false;
    if (HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, appPid)) {
        known = tokenIntegrity(p, theirs);
        CloseHandle(p);
    }
    reaches = hookReachesThisProcess(known, theirs, own);
    reachCache_.store(reinterpret_cast<uintptr_t>(app), appPid, reaches);
    return reaches;
}

bool TextService::typingEnabled() const {
    if (suspended()) return false;  // game / fullscreen: every key passes through
    if (!config::vietnamese()) return false;
    // A word this TIP started stays this TIP's even if the hook's ack appears mid-word
    // (the hook waits for a boundary too): one word, one typist.
    if (session_.wordActive()) return true;
    if (directActive_ || directWanted_) return !directServesHere();  // not (yet) typed by the hook: compose
    AppMode m = config::appMode();
    if (m == AppMode::Direct) return !directServesHere();  // the hook types; else compose
    return m == AppMode::Composition || m == AppMode::InPlace;
}

// Hand this field to VietTelex.exe's hook (Direct mode: backspaces + Unicode, no
// underline) instead of composing. Only when the app runs; else composition stays.
// Asks; the TIP only stays out once the hook's ack (kDirectOnProp) is on the window —
// until then this word (and any before the ack) is composed here. Returns true when the
// hook already types here.
bool TextService::requestDirect(const char* why, bool adoptTyped, bool inlineAutocomplete) {
    if (directActive_) return true;
    HWND app = FindWindowW(kAppWindowClass, nullptr);
    if (!app) return false;
    HWND f = GetFocus();
    if (f && GetPropW(f, kNoDirectProp)) return false;  // proved unusable here: compose
    // #134 (MISA SME run as administrator): the hook can never type in an elevated app.
    // Asking anyway only left the field "composing until the hook acks" with the app
    // logging "no hook (UIPI)". Compose here and do not ask.
    if (!directWanted_ && !hookReachesHere(app)) {
        if (!directBlockedLogged_) {
            directBlockedLogged_ = true;
            config::log(std::string(why) + " -> not requested: this app runs above VietTelex.exe (UIPI), composition");
        }
        return false;
    }
    if (!directWanted_) {
        directWanted_ = true;
        directFocus_ = f;
        directInWpf_ = focusWpf_;
        directAdopt_ = adoptTyped;
        directInlineAc_ = inlineAutocomplete;
        directAskTick_ = GetTickCount64();
        PostMessageW(app, kAppCommandMsg, static_cast<WPARAM>(AppCommand::DirectMode),
                     kDirectOn | (adoptTyped ? kDirectAdoptTyped : 0) |
                         (inlineAutocomplete ? kDirectInlineAutocomplete : 0));
        config::log(std::string(why) + " (requested; composing until the hook acks)");
    }
    if (!directServesHere()) return false;
    directActive_ = true;
    session_.reset();
    config::log("handover acked: the hook types in this field");
    return true;
}

DirectAsk TextService::askDirectForAddressBar() {
    if (requestDirect("browser address bar (IS_URL) -> direct (hook): no composition underline", true, true))
        return DirectAsk::Acked;
    if (!directWanted_) return DirectAsk::Refused;  // no app, UIPI, the field marked NoDirect
    HWND f = GetFocus();
    HWND root = f ? GetAncestor(f, GA_ROOT) : nullptr;
    if ((f && GetPropW(f, kNoDirectProp)) || (root && GetPropW(root, kNoDirectProp))) return DirectAsk::Refused;
    HWND app = FindWindowW(kAppWindowClass, nullptr);
    if (!app || !hookReachesHere(app)) return DirectAsk::Refused;
    return DirectAsk::Pending;
}

void TextService::publishLangProp() {
    HWND f = GetFocus();
    HWND root = f ? GetAncestor(f, GA_ROOT) : nullptr;
    if (root != langPropWnd_) clearLangProp();
    if (!root || config::secureMode()) return;
    SetPropW(root, kTipLangProp, reinterpret_cast<HANDLE>(static_cast<INT_PTR>(vietnamese() ? 1 : 2)));
    langPropWnd_ = root;
}

void TextService::clearLangProp() {
    if (langPropWnd_ && IsWindow(langPropWnd_)) RemovePropW(langPropWnd_, kTipLangProp);
    langPropWnd_ = nullptr;
}

// WPF's default store (1.3.16): the raw keys of the word in progress, for the hook to adopt
// at its first key (typed_word.h). Kept current for as long as the context lets keys pass as
// typed — also after the ack: a key typed before the hook was in may reach this TIP only
// after it (the hook reads the record at ITS first key). No syscall unless it changes.
void TextService::publishTypedWord() {
    const uint32_t v = typedWordToPublish(keysPassAsTyped_, typedWord_);
    if (!v && !typedWordWnd_) return;
    HWND f = GetFocus();
    HWND root = f ? GetAncestor(f, GA_ROOT) : nullptr;
    if (v == typedWordPublished_ && root == typedWordWnd_) return;
    if (root != typedWordWnd_ || !v) clearTypedWord();
    if (!v || !root) return;
    SetPropW(root, kTypedWordProp, reinterpret_cast<HANDLE>(static_cast<uintptr_t>(v)));
    typedWordWnd_ = root;
    typedWordPublished_ = v;
}

void TextService::clearTypedWord() {
    if (typedWordWnd_ && IsWindow(typedWordWnd_)) RemovePropW(typedWordWnd_, kTypedWordProp);
    typedWordWnd_ = nullptr;
    typedWordPublished_ = 0;
}

// Switch hotkey (Ctrl+Shift chord, Alt+Z). Besides the state, tell VietTelex.exe that the
// USER switched (AppCommand::UserSwitched: the floating V/E indicator) — a focus change
// only sends StateChanged.
void TextService::toggleVietnamese() {
    const bool on = !vietnamese();
    setVietnamese(on);
    if (HWND h = FindWindowW(kAppWindowClass, nullptr))
        PostMessageW(h, kAppCommandMsg, static_cast<WPARAM>(AppCommand::UserSwitched), on ? 1 : 0);
}

// VietTelex.exe (game_mode.cpp): stand aside in this thread / stop standing aside. Also
// re-reads the snapshot at once (Chế độ game is a setting). A word in progress is
// committed as typed, so the game never sees a half composition.
void TextService::setSuspendBits(uint32_t bits) {
    const bool was = suspended();
    suspendPosted_ = bits & kSuspendFullscreen;
    applyConfig(false);
    if (suspended() && !was) {
        flushAsync(composition_ ? compositionContext_ : nullptr);
        session_.resetContext();
        chord_.disarm();
        hideHint();
        dropHintWork();
        config::log("suspended: every key passes through (game / fullscreen / Che do game)");
    } else if (!suspended() && was) {
        session_.resetContext();
        config::log("resumed after game / fullscreen");
    }
}

void TextService::readSuspendProp() {
    HWND f = GetFocus();
    if (!f) f = GetForegroundWindow();
    HWND root = f ? GetAncestor(f, GA_ROOT) : nullptr;
    const uintptr_t v = root ? reinterpret_cast<uintptr_t>(GetPropW(root, kSuspendProp)) : 0;
    // Only from the live app (a killed app's property would pass every key here forever).
    suspendPosted_ =
        v && propFromLiveApp(v, reinterpret_cast<uintptr_t>(FindWindowW(kAppWindowClass, nullptr))) ? kSuspendFullscreen
                                                                                                     : 0;
}

void TextService::setVietnamese(bool on) {
    if (on != vietnamese()) {
        if (!on) {
            flushAsync(composition_ ? compositionContext_ : nullptr);
        } else {
            session_.resetContext();
        }
        config::setVietnamese(on);
        publishLangProp();
        config::log(on ? "mode: vietnamese" : "mode: english");
        notifyAppState(on);
    }
}

// The optional tray icon in VietTelex.exe is the only Việt/Anh indicator (1.0.8): tell it.
void TextService::notifyAppState(bool on) {
    focusNotify_.notePosted(on, reinterpret_cast<uintptr_t>(langPropWnd_));
    if (HWND h = FindWindowW(kAppWindowClass, nullptr))
        PostMessageW(h, kAppCommandMsg, static_cast<WPARAM>(AppCommand::StateChanged), on ? 1 : 0);
}

void TextService::flushAsync(ITfContext* ctx) {
    if (!ctx || !composition_) {
        session_.reset();
        return;
    }
    Ref<TextService> self(this);
    Ref<ITfContext> c(ctx);
    Ref<ITfComposition> comp(composition_);
    HRESULT hr = RunEditSession(ctx, clientId_, TF_ES_ASYNCDONTCARE | TF_ES_READWRITE,
                                [self, c, comp](TfEditCookie ec) -> HRESULT {
                                    // An async session may run after later keys: if a NEW
                                    // word composes by now, it is not ours to flush.
                                    if (self->composition() != comp.get()) return S_OK;
                                    TsfTextSink sink(self.get(), c.get(), ec);
                                    self->session_.flush(sink);
                                    return S_OK;
                                });
    if (FAILED(hr)) session_.reset();
}

void TextService::endCompositionAsync() {
    if (!composition_ || !compositionContext_) return;
    Ref<TextService> self(this);
    Ref<ITfContext> c(compositionContext_);
    Ref<ITfComposition> comp(composition_);
    HRESULT hr = RunEditSession(compositionContext_, clientId_, TF_ES_ASYNCDONTCARE | TF_ES_READWRITE,
                                [self, c, comp](TfEditCookie ec) -> HRESULT {
                                    // Only the composition this was asked for: by the time an
                                    // async session runs, the next key may have started a new
                                    // word, and ending THAT one cut it short.
                                    if (self->composition() != comp.get()) return S_OK;
                                    TsfTextSink sink(self.get(), c.get(), ec);
                                    sink.endCompositionAsIs();
                                    return S_OK;
                                });
    if (FAILED(hr)) clearComposition();
}

void TextService::setComposition(ITfComposition* c, ITfContext* ctx) {
    clearComposition();
    composition_ = c;
    if (composition_) composition_->AddRef();
    compositionContext_ = ctx;
    if (compositionContext_) compositionContext_->AddRef();
}

void TextService::clearComposition() {
    SafeRelease(composition_);
    SafeRelease(compositionContext_);
}

namespace {
// {A94C5FD2-C471-4031-9546-709C17300CB9}: set by CUAS on the document manager of an
// IMM32 app whose focused field is not an Edit/RichEdit (Mozc IsTsfEmulatedDocumentMgr).
const GUID kCompartmentTsfEmulated = {0xa94c5fd2, 0xc471, 0x4031, {0x95, 0x46, 0x70, 0x9c, 0x17, 0x30, 0x0c, 0xb9}};
// GUID_COMPARTMENT_TRANSITORYEXTENSION_PARENT {8BE347F8-C7A0-11D7-B408-00065B84435C}
// (defined locally: not every SDK/mingw header set declares it).
const GUID kCompartmentTransitoryParent = {0x8be347f8, 0xc7a0, 0x11d7, {0xb4, 0x08, 0x00, 0x06, 0x5b, 0x84, 0x43, 0x5c}};

bool compartmentVariant(IUnknown* owner, REFGUID guid, VARIANT& out) {
    VariantInit(&out);
    if (!owner) return false;
    ITfCompartmentMgr* mgr = nullptr;
    if (FAILED(owner->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&mgr))) || !mgr) return false;
    ITfCompartment* c = nullptr;
    bool ok = SUCCEEDED(mgr->GetCompartment(guid, &c)) && c && SUCCEEDED(c->GetValue(&out));
    if (c) c->Release();
    mgr->Release();
    return ok;
}

bool compartmentFlag(IUnknown* owner, REFGUID guid, LONG mask) {
    VARIANT v;
    const bool set = compartmentVariant(owner, guid, v) && v.vt == VT_I4 && (v.lVal & mask) != 0;
    VariantClear(&v);
    return set;
}

bool isTransitory(ITfContext* ctx) {
    TF_STATUS st = {};
    return ctx && SUCCEEDED(ctx->GetStatus(&st)) && (st.dwStaticFlags & TF_SS_TRANSITORY) != 0;
}
}  // namespace

// At a word start: classify the host, then settle a pending / lost Direct handover.
void TextService::evaluateHostAtWordStart(ITfContext* ctx) {
    evaluateHost(ctx);
    // A handed-over field the app since marked NoDirect (or elevated): compose.
    if (directActive_ && !directServesHere()) {
        directActive_ = false;
        config::log("direct mode unusable in this field -> composition");
        // A Chromium address bar falls back to its own rule (fieldPolicyAtWordStart:
        // composition, text still readable), exactly as before #173.
        if (!addressBarHandover_) session_.setCompositionOnlyContext(true);
    } else if (directWanted_ && !directActive_ && directServesHere()) {
        directActive_ = true;  // the hook acked since the request
        config::log("handover acked: the hook types in this field");
    }
}

// Classifies the context a word is about to start in (see app_policy.h ContextInfo) and,
// for classic Edit/RichEdit, finds the full transitory-extension PARENT context.
void TextService::evaluateHost(ITfContext* ctx) {
    SafeRelease(targetCtx_);
    ContextInfo c;
    WCHAR cls[128] = {};  // focus window class (also for the context log line)
    HWND focusWnd = nullptr;
    c.console = consoleHost_;
    c.hasContext = ctx != nullptr;
    ITfDocumentMgr* dm = nullptr;
    if (ctx && (FAILED(ctx->GetDocumentMgr(&dm)) || !dm)) c.hasContext = false;
    if (c.hasContext) {
        c.keyboardDisabled = compartmentFlag(ctx, GUID_COMPARTMENT_KEYBOARD_DISABLED, ~0) ||
                             compartmentFlag(ctx, GUID_COMPARTMENT_EMPTYCONTEXT, ~0);
        TF_STATUS st = {};
        if (SUCCEEDED(ctx->GetStatus(&st))) {
            c.transitory = (st.dwStaticFlags & TF_SS_TRANSITORY) != 0;
            c.readOnly = (st.dwDynamicFlags & TF_SD_READONLY) != 0;
        }
        if (c.transitory) {
            c.cuasEmulated = compartmentFlag(dm, kCompartmentTsfEmulated, 0x1);
            VARIANT v;
            VariantInit(&v);  // parentFailed_ skips compartmentVariant: never clear stack garbage
            if (!parentFailed_ && compartmentVariant(dm, kCompartmentTransitoryParent, v) &&
                v.vt == VT_UNKNOWN && v.punkVal) {
                ITfDocumentMgr* parent = nullptr;
                if (SUCCEEDED(v.punkVal->QueryInterface(IID_ITfDocumentMgr, reinterpret_cast<void**>(&parent))) &&
                    parent && parent != dm) {
                    c.hasParent = true;
                    ITfContext* top = nullptr;
                    if (SUCCEEDED(parent->GetTop(&top)) && top) {
                        c.parentTransitory = isTransitory(top);
                        if (!c.parentTransitory) targetCtx_ = top;  // keep the reference
                        else top->Release();
                    }
                }
                if (parent) parent->Release();
            }
            VariantClear(&v);
        }
        HWND focus = GetFocus();
        focusWnd = focus;
        c.unicodeWindow = !focus || IsWindowUnicode(focus);
        if (focus) {
            WCHAR real[64] = {};
            RealGetWindowClassW(focus, real, 64);
            GetClassNameW(focus, cls, 128);
            c.editControl = isEditControlClass(reinterpret_cast<const char16_t*>(real),
                                               reinterpret_cast<const char16_t*>(cls));
            c.wpf = isWpfWindowClass(reinterpret_cast<const char16_t*>(cls));
        }
    }
    if (dm) dm->Release();
    host_ = classifyContext(c);
    focusWpf_ = c.wpf;
    focusEdit_ = c.editControl ? focusWnd : nullptr;
    if (host_ != HostText::NormalViaParent) SafeRelease(targetCtx_);
    if (!contextLogged_ && config::logging()) {  // once per focus: the next report needs one log
        contextLogged_ = true;
        config::log(describeContext(c, host_, reinterpret_cast<const char16_t*>(cls)));
    }
    // IMM32 app through CUAS: a key claimed in OnTestKeyDown and let through is lost there
    // (#134) — the session eats boundaries into the result string, OnKeyDown retypes the rest.
    if (c.cuasEmulated && host_ == HostText::CompositionOnly) session_.setHostDropsPassedKeys(true);
    // Chromium & co (transitory, readable): the store mirrors the page asynchronously
    // (session.h setAsyncStore — 2026-10 Messenger/Facebook "mất chữ" report).
    session_.setAsyncStore(c.transitory && host_ == HostText::Normal);
    // A control kind of this app that already undid an in-place edit (app_policy.h
    // UnreliableControls): compose from the first letter. Sync stores only.
    focusClass_.assign(reinterpret_cast<const char16_t*>(cls));
    if (session_.outputMode() == OutputMode::InPlace && !session_.prefersComposition() && !session_.asyncStore() &&
        unreliable_.has(focusClass_)) {
        session_.setPreferComposition(true);
        config::log("control kind undid in-place edits before in this app -> composition from the first letter");
    }
    // Word's own UI text boxes (Navigation pane search, Ctrl+F: RICHEDIT60W): the search box
    // offers passed keys twice and re-sets its text (app_policy.h officeUiPrefersComposition).
    if (session_.outputMode() == OutputMode::InPlace && !session_.prefersComposition() &&
        officeUiPrefersComposition(config::exeName(), focusClass_, session_.asyncStore())) {
        session_.setPreferComposition(true);
        config::log("Word UI text box: composition from the first letter");
    }
    // Windows search on an async store: compose from the first letter — the first word of
    // every search lost its tone key in place (app_policy.h shellSearchPrefersComposition).
    if (session_.outputMode() == OutputMode::InPlace && !session_.prefersComposition() &&
        shellSearchPrefersComposition(config::activeApp(), session_.asyncStore())) {
        session_.setPreferComposition(true);
        config::log("Windows search box (async store): composition from the first letter");
    }
    // A store that never shows the keys the app got is no text field (a WPF file list with
    // type-to-filter): the session stops claiming keys there instead of composing into nothing.
    session_.setPassedKeysReachApp(passedKeysReachApp(c, host_));
    // WPF's default store (a list with type-to-filter): no text field, known from the context
    // alone (app_policy.h wpfDefaultStore). Keys pass as typed from the first one — a
    // composition there types nothing — and the hook is asked to type (backspaces + Unicode).
    // Also while a word passes as typed after a misreading Edit store (session.h
    // passingWord): the hook adopts that word, as in a WPF list.
    const bool wpfList = wpfDefaultStore(c, host_);
    // A Chromium address bar handed to the hook (#173): keys pass as typed (recorded for the
    // hook to adopt) until the ack, and the record stays current after it (as for WPF).
    keysPassAsTyped_ = wpfList || session_.passingWord() || addressBarHandover_;
    if (wpfList) {
        if (!session_.notTextField()) {
            session_.markNotTextField();
            config::log("WPF default store (no text field) -> keys pass through");
        }
        // The word so far (this key included) is on the root before the hook can ack.
        publishTypedWord();
        requestDirect("WPF default store -> direct (hook)", true);
        return;
    }
    // WPF TextBox & co: a claimed key let through never reaches the element (app_policy.h
    // wpfOwnsClaimedKeys). Compose from the first key; boundaries go out with the word,
    // any other claimed key is retyped (#134 path). The composition is read back in case
    // the element is no text field after all.
    if (wpfOwnsClaimedKeys(c, host_) && !session_.notTextField()) {
        session_.setHostDropsPassedKeys(true);
        session_.setCompositionMustShow(true);
        if (!session_.prefersComposition()) {
            session_.setPreferComposition(true);
            config::log("WPF text field: composition from the first key, claimed keys never let through");
        }
    }
    // No usable text store: prefer Direct (the hook types, no underline) over composition.
    if (host_ == HostText::CompositionOnly && requestDirect("context without surrounding text -> direct (hook)")) return;
    session_.setCompositionOnlyContext(host_ == HostText::CompositionOnly);
}

// At a word start: true = literal field (password, PIN, number, e-mail), let keys through.
// Also switches a Chromium address bar to composition (app_policy.h
// fieldPrefersComposition) — one input-scope read serves both.
//
// (#173) The browser underlines any composition in its address bar, so that field first goes
// to the hook (app_policy.h omniboxStepAtWordStart): the key passes (as typed until the ack,
// the hook adopts that word), and composition stays the fallback.
bool TextService::fieldPolicyAtWordStart(ITfContext* ctx, TfEditCookie ec) {
    int buf[32];
    const UINT n = inputScopesAtSelection(ctx, ec, buf, 32);
    if (n > 0 && classifyInputScopes(buf, n) == FieldPolicy::Literal) return true;
    if (omniboxOfferedToHook(fieldPrefersComposition(config::exeName(), buf, n), session_.inPlaceButForPreference(),
                             addressBarCompose_)) {
        const DirectAsk ask = askDirectForAddressBar();
        const OmniboxStep step = omniboxStepAtWordStart(ask, GetTickCount64() - directAskTick_);
        if (step == OmniboxStep::HookTypes || step == OmniboxStep::PassAsTyped) {
            const bool first = !addressBarHandover_;
            addressBarHandover_ = true;
            keysPassAsTyped_ = true;
            publishTypedWord();  // this key included (recorded in OnTestKeyDown, else in OnKeyDown)
            if (first && config::logging()) {
                const int len = typedWord_.length();
                config::log(std::string(step == OmniboxStep::HookTypes
                                            ? "browser address bar (IS_URL): the hook types here"
                                            : "browser address bar (IS_URL): keys pass as typed until the hook acks") +
                            " (word so far: " + (len < 0 ? std::string("unknown") : std::to_string(len) + " key(s)") +
                            ")");
            }
            return true;         // the key goes to the field untouched
        }
        if (step == OmniboxStep::GiveUp) {
            directWanted_ = false;
            directFocus_ = nullptr;
            directAdopt_ = false;
            directInlineAc_ = false;
            if (HWND app = FindWindowW(kAppWindowClass, nullptr))
                PostMessageW(app, kAppCommandMsg, static_cast<WPARAM>(AppCommand::DirectMode), 0);
            config::log("browser address bar: no ack from the hook in " + std::to_string(kOmniboxAckWaitMs) +
                        " ms -> request released");
        }
        if (addressBarHandover_) {
            addressBarHandover_ = false;
            keysPassAsTyped_ = false;
            clearTypedWord();
        }
        addressBarCompose_ = true;  // settled for this focus: not asked again at every word
        session_.setPreferComposition(true);
        config::log("browser address bar (IS_URL): composition for this field (in-place breaks on inline autocomplete)");
    }
    return false;
}

// Input scopes of the field at the selection (up to `cap`); 0 = none / unknown.
UINT TextService::inputScopesAtSelection(ITfContext* ctx, TfEditCookie ec, int* buf, UINT cap) {
    // Input scope is a text-store attribute (app property); some stores expose it as a
    // regular property instead.
    ITfReadOnlyProperty* prop = nullptr;
    if (FAILED(ctx->GetAppProperty(GUID_PROP_INPUTSCOPE, &prop)) || !prop) {
        prop = nullptr;
        ITfProperty* p = nullptr;
        if (FAILED(ctx->GetProperty(GUID_PROP_INPUTSCOPE, &p)) || !p) return 0;
        prop = p;
    }
    UINT found = 0;
    TF_SELECTION sel;
    ULONG fetched = 0;
    if (SUCCEEDED(ctx->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &fetched)) && fetched == 1) {
        VARIANT v;
        VariantInit(&v);
        if (SUCCEEDED(prop->GetValue(ec, sel.range, &v)) && v.vt == VT_UNKNOWN && v.punkVal) {
            ITfInputScope* is = nullptr;
            if (SUCCEEDED(v.punkVal->QueryInterface(IID_ITfInputScope, reinterpret_cast<void**>(&is))) && is) {
                InputScope* scopes = nullptr;
                UINT count = 0;
                if (SUCCEEDED(is->GetInputScopes(&scopes, &count)) && scopes) {
                    found = count < cap ? count : cap;
                    for (UINT i = 0; i < found; ++i) buf[i] = static_cast<int>(scopes[i]);
                    CoTaskMemFree(scopes);
                }
                is->Release();
            }
        }
        VariantClear(&v);
        sel.range->Release();
    }
    prop->Release();
    return found;
}

// ---------------------------------------------------------------- thread manager events

STDMETHODIMP TextService::OnSetFocus(ITfDocumentMgr* focus, ITfDocumentMgr*) {
    learnFlush();  // Học từ bạn gõ: the held word is final, a new field has no context
    learnResetKeys();
    dropTextToolPending();  // a text-tool request belongs to the field it was made in
    ++keyGen_;              // caret hints belong to the field too
    hideHint();
    dropHintWork();
    hintTracker_.reset();
    acceptedSpace_ = hints::AcceptedSpace();
    acceptAct_ = -1;
    {
        // Diagnostics: a focus change that ends a word mid-way (no text, only its length).
        HWND nf = GetFocus();
        if (session_.wordActive() && config::logging())
            config::log("focus changed mid-word -> word dropped (" + std::to_string(session_.rawKeys().size()) +
                        " keys, " + (nf == focusWnd_ ? "same window" : "other window") + ")");
        focusWnd_ = nf;
    }
    if (composition_) endCompositionAsync();
    session_.resetContext();
    chord_.disarm();
    altZLatch_.reset();
    parentFailed_ = false;
    SafeRelease(targetCtx_);
    host_ = HostText::Normal;
    directBlockedLogged_ = false;
    reachCache_.reset();
    retypeLogged_ = false;
    notTextFieldLogged_ = false;
    contextLogged_ = false;
    keyRepeat_.reset();
    keyRepeatLogged_ = false;
    noEdit_.clear();
    noEditLogged_ = false;
    typedWord_.clear();  // a new element: its word starts afresh
    clearTypedWord();
    bool keptPassAsTyped = false;  // a WPF list handover kept: keys still pass as typed there
    if (directActive_ || directWanted_) {
        // WPF moves TSF focus between its own documents inside one HwndSource (the filter bar
        // appearing, a list refresh): the handover asked for that window stays (app_policy.h
        // directSurvivesFocusChange). Any other change: the new field is evaluated afresh.
        HWND f = GetFocus();
        HWND root = f ? GetAncestor(f, GA_ROOT) : nullptr;
        const bool keep = directSurvivesFocusChange(reinterpret_cast<uintptr_t>(directFocus_), directInWpf_,
                                                    reinterpret_cast<uintptr_t>(f),
                                                    root && GetForegroundWindow() == root);
        HWND app = FindWindowW(kAppWindowClass, nullptr);
        directActive_ = false;  // keep: the ack is re-checked at the next word start
        if (keep) {
            // Re-ask in case the hook dropped it (a foreground event for this same window);
            // a repeat is a no-op there.
            if (app)
                PostMessageW(app, kAppCommandMsg, static_cast<WPARAM>(AppCommand::DirectMode),
                             kDirectOn | (directAdopt_ ? kDirectAdoptTyped : 0) |
                                 (directInlineAc_ ? kDirectInlineAutocomplete : 0));
            keptPassAsTyped = directAdopt_ && keysPassAsTyped_;
            config::log("focus moved inside the handed-over WPF window -> direct kept");
        } else {
            directWanted_ = false;
            directFocus_ = nullptr;
            directInWpf_ = false;
            directAdopt_ = false;
            directInlineAc_ = false;
            if (app) PostMessageW(app, kAppCommandMsg, static_cast<WPARAM>(AppCommand::DirectMode), 0);
        }
    }
    keysPassAsTyped_ = keptPassAsTyped;
    addressBarHandover_ = false;  // the next field is classified afresh (#173)
    addressBarCompose_ = false;
    typedNote_.reset();
    hostEval_.invalidate();
    resolveActiveApp();
    config::reloadVietnamese();
    applyConfig(false);  // settings copied only when settings.bin changed
    readSuspendProp();
    if (focus) {
        publishLangProp();
        // Only the optional tray icon listens; it is told only what changed.
        const bool on = vietnamese();
        if (focusNotify_.shouldPost(settings_->showTrayIcon && !config::secureMode(), on,
                                    reinterpret_cast<uintptr_t>(langPropWnd_)))
            if (HWND h = FindWindowW(kAppWindowClass, nullptr))
                PostMessageW(h, kAppCommandMsg, static_cast<WPARAM>(AppCommand::StateChanged), on ? 1 : 0);
    }
    hookTextEditSink(focus);
    return S_OK;
}

// WebView2 (new Teams, new Outlook…): the TIP runs in msedgewebview2.exe; per-app rules
// and Việt/Anh memory must follow the app that owns the root window.
void TextService::resolveActiveApp() {
    if (config::exeName() != "msedgewebview2.exe") return;
    HWND w = GetFocus();
    if (!w) w = GetForegroundWindow();
    HWND root = w ? GetAncestor(w, GA_ROOTOWNER) : nullptr;
    DWORD pid = 0;
    if (root) GetWindowThreadProcessId(root, &pid);
    std::wstring name;
    if (pid && pid != GetCurrentProcessId()) {
        if (HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)) {
            wchar_t buf[MAX_PATH];
            DWORD n = MAX_PATH;
            if (QueryFullProcessImageNameW(p, 0, buf, &n)) {
                std::wstring path(buf, n);
                name = path.substr(path.find_last_of(L"\\/") + 1);
            }
            CloseHandle(p);
        }
    }
    config::setActiveApp(name);
}

STDMETHODIMP TextService::OnPushContext(ITfContext*) {
    ITfDocumentMgr* dm = nullptr;
    if (threadMgr_ && SUCCEEDED(threadMgr_->GetFocus(&dm)) && dm) {
        hookTextEditSink(dm);
        dm->Release();
    }
    if (session_.wordActive()) config::log("context pushed / popped mid-word -> word dropped");
    session_.reset();
    return S_OK;
}

STDMETHODIMP TextService::OnPopContext(ITfContext* ctx) { return OnPushContext(ctx); }

// ---------------------------------------------------------------- text edit sink

STDMETHODIMP TextService::OnEndEdit(ITfContext* ctx, TfEditCookie ecReadOnly, ITfEditRecord* record) {
    if (!ctx || !record) return S_OK;
    if (noEdit_.suspects(ctx)) noEdit_.clear();  // the store reports an edit: it is alive
    if (composition_) {
        // The app emptied our composition (Excel cell autocomplete, app-side clear):
        // drop the word and end the composition (Mozc tip_edit_session_impl ~L565).
        ITfRange* cr = nullptr;
        if (SUCCEEDED(composition_->GetRange(&cr)) && cr) {
            BOOL empty = FALSE;
            cr->IsEmpty(ecReadOnly, &empty);
            cr->Release();
            if (empty && session_.wordActive()) {
                session_.reset();
                endCompositionAsync();
                return S_OK;
            }
        }
    }
    BOOL selChanged = FALSE;
    if (FAILED(record->GetSelectionStatus(&selChanged)) || !selChanged) return S_OK;
    chord_.disarm();  // a click between Ctrl+Shift press and release is not a toggle
    TsfTextSink ro(this, ctx, ecReadOnly);
    if (hint_ && host_ != HostText::NormalViaParent) {
        // A caret hint belongs to the text it was made for: a click / app-side move hides it.
        if (ro.hasSelection() ||
            ro.textBeforeCaret(static_cast<int>(hintShownBefore_.size())) != hintShownBefore_)
            hideHint();
    }
    if (composition_) {
        // Caret left our composition (click, app-side move): the word is done as is.
        if (!ro.selectionInsideComposition()) {
            session_.reset();
            endCompositionAsync();
        }
        return S_OK;
    }
    // (Via the transitory-extension parent, this context is not the one holding our word;
    // the session re-verifies against the parent at every key instead.)
    // Skipped for OUR key's edit session (ownKeyEdit_): it just verified the text before
    // the caret itself, and nothing else can edit while it holds the document.
    if (session_.wordActive() && session_.wordMode() == OutputMode::InPlace && host_ != HostText::NormalViaParent &&
        !ownKeyEdit_) {
        // Our own edits and the app inserting a key we passed keep the word right
        // before the caret; anything else (click, arrow, app rewrite) does not.
        // A forward selection (omnibox autocomplete suffix) is the app's, not a change.
        // An app that dropped the deletion of our replace moves the field to composition.
        session_.verifyScreen(ro);
        noteUnreliableField();
    }
    return S_OK;
}

// The session found this control undoing in-place edits (session.h takeFieldUnreliable):
// remember its kind for the rest of this app's life (one log line per kind).
void TextService::noteUnreliableField() {
    if (!session_.takeFieldUnreliable() || focusClass_.empty() || unreliable_.has(focusClass_)) return;
    unreliable_.remember(focusClass_);
    std::string c;
    for (char16_t ch : focusClass_) c += (ch >= 0x20 && ch < 0x7F) ? static_cast<char>(ch) : '?';
    config::log("in-place unreliable in this control kind (class " + c + ") -> it composes from now on in this app");
}

// ---------------------------------------------------------------- keys

uint8_t TextService::heldModifiers(uint32_t vkey, bool down) const {
    uint8_t h = 0;
    if (keyDown(VK_CONTROL)) h |= kModCtrl;
    if (keyDown(VK_SHIFT)) h |= kModShift;
    if (keyDown(VK_MENU)) h |= kModAlt;
    if (keyDown(VK_LWIN) || keyDown(VK_RWIN)) h |= kModWin;
    uint8_t b = modBit(vkey);
    if (down) h |= b;
    else h &= static_cast<uint8_t>(~b);
    return h;
}

void TextService::onModifierEvent(uint32_t vkey, bool down) {
    if (hotkey_ != SwitchHotkey::CtrlShift || suspended()) return;  // games bind Ctrl+Shift
    if (chord_.note(heldModifiers(vkey, down)) && !down) toggleVietnamese();
}

bool TextService::prepareKey(WPARAM wp, bool down, KeyInput& out) {
    const uint32_t vkey = static_cast<uint32_t>(wp);
    if (isModifierVk(vkey)) {
        onModifierEvent(vkey, down);
        return false;
    }
    if (down) chord_.disarm();
    if (!typingEnabled()) return false;
    Modifiers m;
    m.shift = keyDown(VK_SHIFT);
    m.ctrl = keyDown(VK_CONTROL);
    m.alt = keyDown(VK_MENU);
    m.win = keyDown(VK_LWIN) || keyDown(VK_RWIN);
    m.capsLock = (GetKeyState(VK_CAPITAL) & 1) != 0;
    out = classifyKey(vkey, m);
    return true;
}

// (#121) Keys we let through are typed by the app with the thread's keyboard layout. When
// that is the stock Vietnamese layout instead of the profile's US substitute, the number
// row types ă â ê ô ̀ ̉ ̃ ́ ̣ đ: eat such a key and type its US character ourselves.
// Nothing changes for a key the layout types like US (one cached lookup per key).
bool TextService::retypeAsUs(ITfContext* ctx, WPARAM wp, bool inject) {
    const uint32_t vkey = static_cast<uint32_t>(wp);
    if (!ctx || vkey > 0xFF || isModifierVk(vkey)) return false;
    Modifiers m;
    m.shift = keyDown(VK_SHIFT);
    m.ctrl = keyDown(VK_CONTROL);
    m.alt = keyDown(VK_MENU);
    m.win = keyDown(VK_LWIN) || keyDown(VK_RWIN);
    m.capsLock = (GetKeyState(VK_CAPITAL) & 1) != 0;
    const KeyInput k = classifyKey(vkey, m);
    if (k.kind != KeyKind::Char || k.ch > 0xFFFF) return false;
    const HKL hkl = GetKeyboardLayout(0);
    const uintptr_t h = reinterpret_cast<uintptr_t>(hkl);
    if (!isVietnameseHkl(h)) return false;
    LayoutMatch lm = layoutMatch_.get(h, vkey, m.shift, m.capsLock);
    if (lm == LayoutMatch::Unknown) {
        BYTE state[256] = {};
        if (m.shift) state[VK_SHIFT] = 0x80;
        if (m.capsLock) state[VK_CAPITAL] = 0x01;
        WCHAR buf[8] = {};
        // wFlags bit 2 (0x4): do not change the keyboard state (dead keys) — Win10 1607+.
        const int n = ToUnicodeEx(vkey, MapVirtualKeyExW(vkey, MAPVK_VK_TO_VSC, hkl), state, buf, 8, 0x4, hkl);
        lm = layoutTypesUs(k.ch, n, reinterpret_cast<const char16_t*>(buf)) ? LayoutMatch::Same
                                                                             : LayoutMatch::Differs;
        layoutMatch_.put(h, vkey, m.shift, m.capsLock, lm);
        if (lm == LayoutMatch::Differs && layoutLogged_ != h) {
            layoutLogged_ = h;
            char msg[160];
            snprintf(msg, sizeof msg, "keyboard layout %08llX does not type like US: keys let through are retyped (#121)",
                     static_cast<unsigned long long>(h));
            config::log(msg);
        }
    }
    if (!shouldRetypeAsUs(k, h, lm)) return false;
    // Games / fullscreen, apps set to "off" (games, remote desktop), the secure desktop:
    // keys stay exactly as pressed.
    if (suspended() || config::appMode() == AppMode::Off || config::secureMode()) return false;
    // Only into a field that takes text: not a game / canvas, not read-only.
    if (compartmentFlag(ctx, GUID_COMPARTMENT_KEYBOARD_DISABLED, ~0) ||
        compartmentFlag(ctx, GUID_COMPARTMENT_EMPTYCONTEXT, ~0))
        return false;
    TF_STATUS st = {};
    if (SUCCEEDED(ctx->GetStatus(&st)) && (st.dwDynamicFlags & TF_SD_READONLY) != 0) return false;
    if (!inject) return true;
    INPUT in[2] = {};
    for (int i = 0; i < 2; ++i) {
        in[i].type = INPUT_KEYBOARD;
        in[i].ki.wScan = static_cast<WORD>(k.ch);
        in[i].ki.dwFlags = KEYEVENTF_UNICODE | (i ? KEYEVENTF_KEYUP : 0);
        in[i].ki.dwExtraInfo = kInjectedMagic;  // the hook and this TIP let it through
    }
    return SendInput(2, in, sizeof(INPUT)) == 2;
}

// #134: type a key OnTestKeyDown claimed and the session let through, in a host that
// drops such keys (session.h hostDropsPassedKeys). Marked kInjectedMagic: this TIP and the
// hook let it through untouched. SendInput into our own process: UIPI never applies.
bool TextService::retypeClaimedKey(const KeyInput& k, WPARAM wp, LPARAM lp) {
    INPUT in[2] = {};
    switch (passedKeyRetype(k)) {
        case PassedKeyRetype::None:
            return false;
        case PassedKeyRetype::Unicode:
            for (int i = 0; i < 2; ++i) {
                in[i].type = INPUT_KEYBOARD;
                in[i].ki.wScan = static_cast<WORD>(k.ch);
                in[i].ki.dwFlags = KEYEVENTF_UNICODE | (i ? KEYEVENTF_KEYUP : 0);
                in[i].ki.dwExtraInfo = kInjectedMagic;
            }
            break;
        case PassedKeyRetype::VirtualKey: {
            const WORD vkey = static_cast<WORD>(wp);
            WORD scan = static_cast<WORD>((static_cast<uintptr_t>(lp) >> 16) & 0xFF);
            if (!scan) scan = static_cast<WORD>(MapVirtualKeyW(vkey, MAPVK_VK_TO_VSC));
            const DWORD ext = (static_cast<uintptr_t>(lp) & (1u << 24)) ? KEYEVENTF_EXTENDEDKEY : 0;
            for (int i = 0; i < 2; ++i) {
                in[i].type = INPUT_KEYBOARD;
                in[i].ki.wVk = vkey;
                in[i].ki.wScan = scan;
                in[i].ki.dwFlags = ext | (i ? KEYEVENTF_KEYUP : 0);
                in[i].ki.dwExtraInfo = kInjectedMagic;
            }
            break;
        }
    }
    const bool ok = SendInput(2, in, sizeof(INPUT)) == 2;
    if (!retypeLogged_) {
        retypeLogged_ = true;
        config::log(ok ? "IMM host: claimed key let through -> retyped (#134)"
                       : "IMM host: retyping a claimed key failed (SendInput)");
    }
    return ok;
}

STDMETHODIMP TextService::OnSetFocus(BOOL foreground) {
    if (!foreground) {
        ++keyGen_;
        hideHint();
    }
    return S_OK;
}

bool TextService::noEditableHere(ITfContext* ctx) {
    if (!ctx || !noEdit_.suspects(ctx)) return false;
    // One read-only probe per word start while suspected (never elsewhere): the page may
    // have focused a field inside the same document.
    bool caret = false;
    const HRESULT hr = RunEditSession(ctx, clientId_, TF_ES_SYNC | TF_ES_READ, [&](TfEditCookie ec) -> HRESULT {
        TsfTextSink sink(this, ctx, ec);
        caret = sink.hasCaret();
        return S_OK;
    });
    const bool claim = noEdit_.afterProbe(ctx, hr == S_OK && caret);
    if (claim && config::logging()) config::log("browser: a caret again -> typing resumes in this context");
    return !claim;
}

void TextService::notePassedBy(const KeyInput& k) {
    session_.noteKeyPassedBy(k);
    passNoted_ = true;
}

// The same key event offered again after we let it through (tip_caches.h KeyEventRepeat —
// Word's Navigation search box): it already went to the app, nobody handles it twice.
bool TextService::keyOfferedAgain(bool atTest, WPARAM wp, LPARAM lp) {
    const KeyEventRepeat::Id id{static_cast<uint64_t>(wp), static_cast<uint64_t>(lp),
                                static_cast<uint32_t>(GetMessageTime())};
    if (!(atTest ? keyRepeat_.atTest(id) : keyRepeat_.atKeyDown(id))) return false;
    if (!keyRepeatLogged_ && config::logging()) {
        keyRepeatLogged_ = true;
        config::log("the app offers a key we let through a second time -> second offer ignored");
    }
    return true;
}

STDMETHODIMP TextService::OnTestKeyDown(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) {
    if (!eaten) return E_INVALIDARG;
    *eaten = FALSE;
    if (keyOfferedAgain(true, wp, lp)) return S_OK;
    const KeyEventRepeat::Id id{static_cast<uint64_t>(wp), static_cast<uint64_t>(lp),
                                static_cast<uint32_t>(GetMessageTime())};
    keyRepeat_.begin(id);
    const HRESULT hr = testKeyDownBody(ctx, wp, eaten);
    if (!*eaten) keyRepeat_.testDeclined(id);
    return hr;
}

HRESULT TextService::testKeyDownBody(ITfContext* ctx, WPARAM wp, BOOL* eaten) {
    if (isOwnInjected(static_cast<uintptr_t>(GetMessageExtraInfo()))) {  // typed by our hook
        // The hook's edits (or a key this TIP retyped): the raw record no longer says what
        // the screen shows (typed_word.h).
        if (!isModifierVk(static_cast<uint32_t>(wp))) typedWord_.invalidate();
        return S_OK;
    }
    altZLatch_.noteKey(static_cast<uint32_t>(wp), true);  // any key but a Z repeat re-arms Alt+Z
    if (!isModifierVk(static_cast<uint32_t>(wp))) ++keyGen_;  // background hint work: "typing on cancels"
    passNoted_ = false;
    if (hint_ && hintKeyTest(wp, eaten)) return S_OK;         // Tab / Esc while a caret hint shows
    KeyInput k;
    // Every key let through below asks retypeAsUs (#121): eaten here, retyped in OnKeyDown.
    const bool prepared = prepareKey(wp, true, k);
    // The raw keys of the word in progress (published only where keys pass as typed).
    // Once the hook acked, typing is off here (typingEnabled) yet the keys the hook passes on
    // still arrive as typed — one typed before the hook was in may arrive only now.
    typedNote_.fedAtTest(static_cast<uint64_t>(wp));
    if (prepared) {
        typedWord_.note(k);
    } else if (!isModifierVk(static_cast<uint32_t>(wp))) {
        if (keysPassAsTyped_) {
            Modifiers m;
            m.shift = keyDown(VK_SHIFT);
            m.ctrl = keyDown(VK_CONTROL);
            m.alt = keyDown(VK_MENU);
            m.win = keyDown(VK_LWIN) || keyDown(VK_RWIN);
            m.capsLock = (GetKeyState(VK_CAPITAL) & 1) != 0;
            typedWord_.note(classifyKey(static_cast<uint32_t>(wp), m));
        } else {
            typedWord_.invalidate();  // English, games...: not known to be this context's word
        }
    }
    if (!acceptedSpace_.empty() && !isModifierVk(static_cast<uint32_t>(wp))) {
        if (prepared && acceptSpaceTest(k)) {  // punctuation right after an accepted prediction
            *eaten = TRUE;
            return S_OK;
        }
        acceptedSpace_ = hints::AcceptedSpace();
    }
    if (!prepared) {  // English, modifiers, games...
        publishTypedWord();
        *eaten = retypeAsUs(ctx, wp, false) ? TRUE : FALSE;
        return S_OK;
    }
    if (!session_.wordActive()) {
        evaluateHostAtWordStart(ctx);
        hostEval_.noteTest(keyGen_, ctx);  // OnKeyDown of this key reuses it
    }
    publishTypedWord();
    if (directActive_) {  // the hook types in this field
        notePassedBy(k);
        noteHintKey(k, ctx, false);
        *eaten = retypeAsUs(ctx, wp, false) ? TRUE : FALSE;
        return S_OK;
    }
    // No focused context, keyboard disabled (games, canvases), read-only, ANSI window:
    // never eat a key there (SampleIME _IsKeyboardDisabled) — retypeAsUs only takes a
    // writable, keyboard-enabled context (password / PIN fields included).
    // A web page with no editable element focused (NoEditableContext): claim nothing — its
    // single-key shortcuts must get the genuine key event (Gmail "#", j / k / x).
    if (host_ == HostText::Ignore || host_ == HostText::Literal || (!session_.wordActive() && noEditableHere(ctx))) {
        notePassedBy(k);
        noteHintKey(k, ctx, false);
        *eaten = retypeAsUs(ctx, wp, false) ? TRUE : FALSE;
        return S_OK;
    }
    *eaten = session_.wantsKey(k) ? TRUE : FALSE;
    if (!*eaten) {
        notePassedBy(k);                        // retro English: one engine call, no edit session
        noteHintKey(k, keyTarget(ctx), false);  // OnKeyDown will not see this key...
        *eaten = retypeAsUs(ctx, wp, false) ? TRUE : FALSE;  // ...unless it retypes it
    }
    return S_OK;
}

// The raw record of the word (typed_word.h) is fed in OnTestKeyDown. A host that offers a
// key to OnKeyDown only (1.3.31, #173: the first letter typed in the address bar was not
// adopted by the hook, "onw" -> "onư") is fed here, exactly as there, and never twice.
void TextService::noteTypedKeyAtKeyDown(WPARAM wp) {
    const uint32_t vkey = static_cast<uint32_t>(wp);
    if (typedNote_.takeAtKeyDown(static_cast<uint64_t>(wp))) return;
    if (isModifierVk(vkey)) return;
    if (typingEnabled() || keysPassAsTyped_) {
        Modifiers m;
        m.shift = keyDown(VK_SHIFT);
        m.ctrl = keyDown(VK_CONTROL);
        m.alt = keyDown(VK_MENU);
        m.win = keyDown(VK_LWIN) || keyDown(VK_RWIN);
        m.capsLock = (GetKeyState(VK_CAPITAL) & 1) != 0;
        typedWord_.note(classifyKey(vkey, m));
    } else {
        typedWord_.invalidate();
    }
    publishTypedWord();
}

STDMETHODIMP TextService::OnKeyDown(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) {
    if (!eaten) return E_INVALIDARG;
    *eaten = FALSE;
    if (keyOfferedAgain(false, wp, lp)) return S_OK;
    const HRESULT hr = keyDownBody(ctx, wp, lp, eaten);
    keyRepeat_.keyDownDone({static_cast<uint64_t>(wp), static_cast<uint64_t>(lp),
                            static_cast<uint32_t>(GetMessageTime())},
                           *eaten != FALSE);
    return hr;
}

HRESULT TextService::keyDownBody(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) {
    if (isOwnInjected(static_cast<uintptr_t>(GetMessageExtraInfo()))) return S_OK;
    altZLatch_.noteKey(static_cast<uint32_t>(wp), true);  // hosts that skip OnTestKeyDown
    noteTypedKeyAtKeyDown(wp);                            // idem: the raw record of the word
    if (hintKeyAct_ >= 0 || hint_) {
        int act = hintKeyAct_;
        hintKeyAct_ = -1;
        if (act < 0) {  // a host that skipped OnTestKeyDown
            BOOL dummy = FALSE;
            if (hintKeyTest(wp, &dummy)) act = hintKeyAct_;
            hintKeyAct_ = -1;
        }
        if (act == static_cast<int>(hints::KeyAction::Accept)) {
            *eaten = applyHint(ctx) ? TRUE : FALSE;  // screen changed: Tab goes to the app
            return S_OK;
        }
        if (act == static_cast<int>(hints::KeyAction::DismissConsume)) {
            declineHint();
            *eaten = TRUE;
            return S_OK;
        }
    }
    KeyInput k;
    if (!ctx) return S_OK;
    if (acceptAct_ < 0 && !acceptedSpace_.empty() && !isModifierVk(static_cast<uint32_t>(wp))) {
        KeyInput a;  // a host that skipped OnTestKeyDown
        if (!(prepareKey(wp, false, a) && acceptSpaceTest(a))) acceptedSpace_ = hints::AcceptedSpace();
    }
    if (acceptAct_ >= 0 && acceptSpaceApply(ctx)) {
        *eaten = TRUE;
        return S_OK;
    }
    if (!prepareKey(wp, true, k)) {
        *eaten = retypeAsUs(ctx, wp, true) ? TRUE : FALSE;  // #121
        return S_OK;
    }
    const bool evaluatedInTest = hostEval_.takeForKeyDown(keyGen_, ctx);
    if (!session_.wordActive() && !evaluatedInTest) evaluateHostAtWordStart(ctx);
    if (directActive_ || host_ == HostText::Ignore || host_ == HostText::Literal || !session_.wantsKey(k) ||
        (!session_.wordActive() && noEditableHere(ctx))) {
        if (!passNoted_) session_.noteKeyPassedBy(k);  // a host that skipped OnTestKeyDown
        passNoted_ = false;
        *eaten = retypeAsUs(ctx, wp, true) ? TRUE : FALSE;  // #121; else the key goes to the app
        return S_OK;
    }
    passNoted_ = false;
    // Classic Edit/RichEdit: read and edit through the full transitory-extension parent.
    ITfContext* target = (host_ == HostText::NormalViaParent && targetCtx_) ? targetCtx_ : ctx;
    BOOL result = FALSE;
    // A browser store (async, keystroke context itself) at a word start: no edit session or
    // no caret there = a page with no editable element focused (NoEditableContext).
    const bool pageWordStart = !session_.wordActive() && k.kind == KeyKind::Char && host_ == HostText::Normal &&
                               session_.asyncStore() && target == ctx;
    bool noCaret = false;
    auto run = [&](ITfContext* tc) {
        return RunEditSession(tc, clientId_, TF_ES_SYNC | TF_ES_READWRITE, [&, tc](TfEditCookie ec) -> HRESULT {
            TsfTextSink sink(this, tc, ec);
            if (pageWordStart && !sink.hasCaret()) {
                noCaret = true;  // the key goes to the app as typed
                return S_OK;
            }
            // Literal fields (password, PIN, number, e-mail): checked where a word would
            // start, so a field switch inside one context is caught too.
            if (!session_.wordActive() && k.kind == KeyKind::Char && fieldPolicyAtWordStart(tc, ec)) return S_OK;
            result = session_.handleKey(k, sink) ? TRUE : FALSE;
            return S_OK;
        });
    };
    ownKeyEdit_ = true;  // OnEndEdit inside this synchronous session is our own edit
    HRESULT hr = run(target);
    if (hr != S_OK && target != ctx && !session_.wordActive()) {
        // Guard: the parent context refused a synchronous edit session. Stop using it
        // for this focus and compose in the keystroke context instead.
        config::log("transitory extension parent refused an edit session -> composition");
        parentFailed_ = true;
        SafeRelease(targetCtx_);
        host_ = HostText::CompositionOnly;
        session_.setCompositionOnlyContext(true);
        hr = run(ctx);
    }
    ownKeyEdit_ = false;
    if (pageWordStart && (noCaret || hr != S_OK)) {
        noEdit_.note(ctx);
        if (noCaret) session_.noteKeyPassedBy(k);  // the key goes to the app untouched
        if (!noEditLogged_) {
            noEditLogged_ = true;
            config::log(noCaret ? "browser: no caret at a word start (no editable element) -> keys pass through"
                                : "browser: edit session refused at a word start (no editable element) -> keys pass "
                                  "through");
        }
    }
    noteUnreliableField();
    if (hr != S_OK) {
        // The app refused a synchronous edit session: type literally, never guess.
        if (config::logging()) {
            char buf[96];
            std::snprintf(buf, sizeof buf, "edit session refused (hr 0x%08lx, host %d) -> key as typed, word dropped",
                          static_cast<unsigned long>(hr), static_cast<int>(host_));
            config::log(buf);
        }
        session_.reset();
        result = FALSE;
    }
    // In-place just proved impossible in this field (nothing readable, e.g. xterm.js):
    // hand it to the hook rather than composing with an underline.
    // Never in a browser / Electron field (async store): there a "failure" is the store
    // lagging the page, and the hook's blind backspace+retype loses letters in web editors.
    if (session_.contextFellBack() && !result && !session_.asyncStore())
        requestDirect("in-place failed in this field -> direct (hook)");
    // A classic Edit's parent store misreads the field (session.h storeMisreads — Win10
    // Notepad with text in it): the letters let through are on screen, the store shows none
    // and a composition there shows nowhere. Leave the parent for this focus: the word in
    // progress passes as typed and the hook adopts it; without the hook the next words
    // compose in the keystroke (CUAS) context, which the Edit displays itself.
    if (session_.storeMisreads() && !parentFailed_ && target != ctx) {
        config::log("Edit: the parent store misreads this field -> keystroke context, direct (hook) asked");
        parentFailed_ = true;
        SafeRelease(targetCtx_);
        host_ = HostText::CompositionOnly;
        session_.setCompositionOnlyContext(true);
        keysPassAsTyped_ = true;
        publishTypedWord();
        requestDirect("Edit store misreads -> direct (hook)", true);
    }
    // Not a text field (session.h notTextField): keys pass through untouched from now on;
    // the hook, if it can, types there with plain Unicode keys the element does take.
    if (session_.notTextField() && !notTextFieldLogged_) {
        notTextFieldLogged_ = true;
        config::log(std::string("not a text field (host ") + std::to_string(static_cast<int>(host_)) +
                    ") -> keys pass through");
        requestDirect("not a text field -> direct (hook)");
    }
    // A digit / punctuation that ended the word goes to the app: in US, not via the layout (#121).
    if (!result && retypeAsUs(ctx, wp, true)) result = TRUE;
    // #134: an IMM32 host (CUAS) already turned this claimed key into VK_PROCESSKEY: letting
    // it through loses it (Enter / Tab / arrows after a word, a key past an overflow).
    if (!result && session_.hostDropsPassedKeys() && retypeClaimedKey(k, wp, lp)) result = TRUE;
    *eaten = result;
    noteHintKey(k, keyTarget(ctx), hr == S_OK);  // (target may be released by the fallback)
    return S_OK;
}

STDMETHODIMP TextService::OnTestKeyUp(ITfContext*, WPARAM wp, LPARAM, BOOL* eaten) {
    if (!eaten) return E_INVALIDARG;
    *eaten = FALSE;
    const uint32_t vkey = static_cast<uint32_t>(wp);
    altZLatch_.noteKey(vkey, false);  // Z / Alt released: the next Alt+Z toggles again
    keyRepeat_.keyUp(static_cast<uint64_t>(wp));
    if (isModifierVk(vkey)) onModifierEvent(vkey, false);
    return S_OK;
}

STDMETHODIMP TextService::OnKeyUp(ITfContext*, WPARAM wp, LPARAM, BOOL* eaten) {
    if (!eaten) return E_INVALIDARG;
    *eaten = FALSE;
    altZLatch_.noteKey(static_cast<uint32_t>(wp), false);  // hosts that skip OnTestKeyUp
    keyRepeat_.keyUp(static_cast<uint64_t>(wp));
    return S_OK;
}

STDMETHODIMP TextService::OnPreservedKey(ITfContext*, REFGUID guid, BOOL* eaten) {
    if (!eaten) return E_INVALIDARG;
    *eaten = FALSE;
    if (IsEqualGUID(guid, GUID_PreservedKeyToggle)) {
        if (suspended()) return S_OK;  // Alt+Z goes to the game
        // Held Alt+Z auto-repeats: toggle on the first call only, still eat the repeats.
        if (altZLatch_.fire()) toggleVietnamese();
        *eaten = TRUE;
    }
    return S_OK;
}

// ---------------------------------------------------------------- composition sink

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie, ITfComposition* comp) {
    if (comp && comp == composition_) {
        if (session_.wordActive()) config::log("composition terminated by the app mid-word -> word dropped");
        clearComposition();
        session_.reset();
    }
    return S_OK;
}

// ---------------------------------------------------------------- display attributes

STDMETHODIMP TextService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** ppEnum) {
    return CreateEnumDisplayAttributeInfo(ppEnum);
}

STDMETHODIMP TextService::GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** ppInfo) {
    if (!ppInfo) return E_INVALIDARG;
    *ppInfo = nullptr;
    if (IsEqualGUID(guid, GUID_DisplayAttributeMisspelled)) return CreateDisplayAttributeInfo(ppInfo, true);
    if (!IsEqualGUID(guid, GUID_DisplayAttributeInput)) return E_INVALIDARG;
    return CreateDisplayAttributeInfo(ppInfo);
}

// ---------------------------------------------------------------- Công cụ văn bản
// VietTelex.exe asks this thread's TIP for the SELECTION (text_tool_ipc.h has the whole
// protocol). Only here, on request: nothing runs per keystroke, nothing is cached beyond
// one request, and the transform itself happens in VietTelex.exe.

namespace {
constexpr UINT kMsgToolRead = WM_APP + 0x59;   // read session finished (possibly async)
constexpr UINT kMsgToolApply = WM_APP + 0x5A;  // result arrived (WM_COPYDATA) -> replace
constexpr UINT kMsgHintRead = WM_APP + 0x5B;   // caret hint: read session done (wParam = key generation)
constexpr UINT kMsgHintReply = WM_APP + 0x5C;  // caret hint: VietTelex.exe answered (wParam = generation)
constexpr UINT kMsgHintPick = WM_APP + 0x5D;   // caret hint: the prediction popup was clicked
constexpr UINT_PTR kTimerHint = 0x5648;        // caret hint: read the screen now
constexpr UINT_PTR kTimerHintHide = 0x5649;    // caret hint: auto-hide
constexpr UINT_PTR kTimerLearn = 0x564A;       // Học từ bạn gõ: send queued events (off the key path)
constexpr UINT kLearnSendDelayMs = 50;

void postToolReply(uint32_t request, TextToolStatus s) {
    if (HWND app = FindWindowW(kAppWindowClass, nullptr))
        PostMessageW(app, kAppCommandMsg, static_cast<WPARAM>(AppCommand::TextToolReply),
                     static_cast<LPARAM>(textToolReplyParam(request, s)));
}

// Whole text of `r` (without moving it), false if longer than `cap` UTF-16 units.
bool rangeText(ITfRange* r, TfEditCookie ec, size_t cap, std::u16string& out) {
    out.clear();
    ITfRange* c = nullptr;
    if (FAILED(r->Clone(&c)) || !c) return false;
    WCHAR buf[1024];
    bool ok = true;
    while (true) {
        ULONG got = 0;
        if (FAILED(c->GetText(ec, TF_TF_MOVESTART, buf, 1024, &got)) || got == 0) break;
        out.append(reinterpret_cast<const char16_t*>(buf), got);
        if (out.size() > cap) {
            ok = false;
            break;
        }
    }
    c->Release();
    return ok;
}
}  // namespace

LRESULT CALLBACK TextService::toolWndProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    auto* self = reinterpret_cast<TextService*>(GetWindowLongPtrW(h, GWLP_USERDATA));
    if (msg == static_cast<UINT>(kTipTextToolMsg)) {
        if (self) self->onTextToolRequest(static_cast<unsigned>(wp), static_cast<uint32_t>(lp));
        return 0;
    }
    if (msg == static_cast<UINT>(kTipSuspendMsg)) {  // VietTelex.exe: game / fullscreen (game_ipc.h)
        if (self) self->setSuspendBits(static_cast<uint32_t>(wp));
        return 0;
    }
    switch (msg) {
        case WM_TIMER:
            if (!self) return 0;
            if (wp == kTimerHint) {
                self->onHintTimer();
            } else if (wp == kTimerHintHide) {
                KillTimer(h, kTimerHintHide);
                self->hideHint();
            } else if (wp == kTimerLearn) {
                KillTimer(h, kTimerLearn);
                self->sendLearnQueue();
            }
            return 0;
        case kMsgHintRead:
            if (self && static_cast<uint32_t>(wp) == self->keyGen_) self->onHintRead();
            else if (self) self->dropHintWork();
            return 0;
        case kMsgHintReply:
            if (self && static_cast<uint32_t>(wp) == self->keyGen_) self->onHintReply();
            else if (self) self->dropHintWork();
            return 0;
        case kMsgHintPick:
            if (self) self->pickHint();
            return 0;
        case kMsgToolRead:
            if (self) self->sendTextToolSelection();
            return 0;
        case kMsgToolApply:
            if (self) self->applyTextToolResult();
            return 0;
        case WM_COPYDATA: {
            const auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lp);
            if (self && cds && cds->dwData == kCopyHintReply) {
                // Only VietTelex.exe answers, only the job still pending (no key since).
                if (reinterpret_cast<HWND>(wp) != FindWindowW(kAppWindowClass, nullptr)) return FALSE;
                HintMessage m;
                if (!unpackHintMessage(cds->lpData, cds->cbData, m) || !self->hintAwaitingApp_ ||
                    m.request != self->hintGen_)
                    return FALSE;
                self->hintAnswer_ = hints::toU32(m.text);
                PostMessageW(h, kMsgHintReply, m.request, 0);  // continue outside the sent message
                return TRUE;
            }
            if (!self || !cds || cds->dwData != kCopyResult) return FALSE;
            // Only VietTelex.exe answers a request, and only the pending one.
            if (reinterpret_cast<HWND>(wp) != FindWindowW(kAppWindowClass, nullptr)) return FALSE;
            uint32_t request = 0, tool = 0;
            std::u16string text;
            if (!unpackTextToolData(cds->lpData, cds->cbData, request, tool, text)) return FALSE;
            if (request != self->tool_.request || !self->tool_.range) return FALSE;
            self->tool_.result = std::move(text);
            PostMessageW(h, kMsgToolApply, 0, 0);  // edit outside the sent message
            return TRUE;
        }
        default: break;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

namespace {
// Class name unique to this module load (address + build): a class that an unloaded TIP
// failed to unregister keeps a dangling window procedure, and must never match ours.
const wchar_t* toolClassName() {
    static const std::wstring name = [] {
        std::wstring n = std::wstring(L"VietTelexTip_") + VTX_VER_STRING_W + L"_";
        const uintptr_t v = reinterpret_cast<uintptr_t>(g_hInst);
        for (int s = static_cast<int>(sizeof v * 8) - 4; s >= 0; s -= 4) n.push_back(L"0123456789abcdef"[(v >> s) & 0xF]);
        return n;
    }();
    return name.c_str();
}
}  // namespace

void UnregisterToolWindowClass() { UnregisterClassW(toolClassName(), g_hInst); }

void TextService::createToolWindow() {
    if (toolWnd_ || config::secureMode()) return;
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = toolWndProc;
    wc.hInstance = g_hInst;
    wc.lpszClassName = toolClassName();
    RegisterClassExW(&wc);  // fails harmlessly when another thread of this module registered it
    const std::wstring title = textToolWindowTitle(GetCurrentThreadId());
    toolWnd_ = CreateWindowExW(0, toolClassName(), title.c_str(), 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, g_hInst,
                               nullptr);
    if (toolWnd_) SetWindowLongPtrW(toolWnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
}

void TextService::destroyToolWindow() {
    dropTextToolPending();
    if (!toolWnd_) return;
    if (learnOn_) {  // Học từ bạn gõ: what is held / queued goes now (the timer dies with the window)
        learnFlush();
        KillTimer(toolWnd_, kTimerLearn);
        sendLearnQueue();
    }
    SetWindowLongPtrW(toolWnd_, GWLP_USERDATA, 0);
    DestroyWindow(toolWnd_);
    toolWnd_ = nullptr;
}

void TextService::dropTextToolPending() {
    SafeRelease(tool_.range);
    SafeRelease(tool_.ctx);
    tool_.request = 0;
    tool_.tool = 0;
    tool_.status = 0;
    tool_.text.clear();
    tool_.result.clear();
}

// The context that holds the selection, or nullptr + the reason (Fallback: no usable TSF
// text here — console, IMM32/CUAS app, no focus; Failed: read-only).
ITfContext* TextService::textToolContext(TextToolStatus& why) {
    why = TextToolStatus::Fallback;
    if (consoleHost_ || !threadMgr_) return nullptr;
    ITfDocumentMgr* dm = nullptr;
    if (FAILED(threadMgr_->GetFocus(&dm)) || !dm) return nullptr;
    ITfContext* ctx = nullptr;
    if (FAILED(dm->GetTop(&ctx)) || !ctx) {
        dm->Release();
        return nullptr;
    }
    ITfContext* target = nullptr;
    TF_STATUS st = {};
    const bool haveStatus = SUCCEEDED(ctx->GetStatus(&st));
    if (compartmentFlag(ctx, GUID_COMPARTMENT_KEYBOARD_DISABLED, ~0) ||
        compartmentFlag(ctx, GUID_COMPARTMENT_EMPTYCONTEXT, ~0)) {
        // games / canvases: no text store
    } else if (haveStatus && (st.dwDynamicFlags & TF_SD_READONLY)) {
        why = TextToolStatus::Failed;
    } else if (haveStatus && (st.dwStaticFlags & TF_SS_TRANSITORY)) {
        // Same rule as evaluateHost (Mozc): classic Edit/RichEdit via the full parent,
        // CUAS-emulated IMM32 apps have nothing readable, Chromium & co are readable.
        VARIANT v;
        if (compartmentVariant(dm, kCompartmentTransitoryParent, v) && v.vt == VT_UNKNOWN && v.punkVal) {
            ITfDocumentMgr* parent = nullptr;
            if (SUCCEEDED(v.punkVal->QueryInterface(IID_ITfDocumentMgr, reinterpret_cast<void**>(&parent))) &&
                parent && parent != dm) {
                ITfContext* top = nullptr;
                if (SUCCEEDED(parent->GetTop(&top)) && top) {
                    if (!isTransitory(top)) target = top;
                    else top->Release();
                }
            }
            if (parent) parent->Release();
        } else if (!compartmentFlag(dm, kCompartmentTsfEmulated, 0x1)) {
            target = ctx;
            ctx->AddRef();
        }
        VariantClear(&v);
    } else {
        target = ctx;
        ctx->AddRef();
    }
    ctx->Release();
    dm->Release();
    return target;
}

void TextService::onTextToolRequest(unsigned tool, uint32_t request) {
    dropTextToolPending();
    // The hotkey's T never reaches us (RegisterHotKey eats it): without this, releasing
    // Ctrl+Shift after Ctrl+Shift+T would look like a clean Ctrl+Shift Việt/Anh switch.
    chord_.disarm();
    if (config::secureMode()) return postToolReply(request, TextToolStatus::Refused);
    TextToolStatus why;
    ITfContext* target = textToolContext(why);
    if (!target) {
        config::log(why == TextToolStatus::Fallback ? "text tool: no TSF selection here -> app clipboard fallback"
                                                    : "text tool: read-only field");
        return postToolReply(request, why);
    }
    if (composition_) {  // a word in progress: finish it as is before touching the text
        session_.reset();
        endCompositionAsync();
    }
    tool_.request = request;
    tool_.tool = tool;
    tool_.ctx = target;  // owns the reference
    Ref<TextService> self(this);
    Ref<ITfContext> c(target);
    const HRESULT hr = RunEditSession(target, clientId_, TF_ES_ASYNCDONTCARE | TF_ES_READ,
                                      [self, c, request](TfEditCookie ec) -> HRESULT {
                                          TextService* s = self.get();
                                          if (s->tool_.request != request) return S_OK;
                                          s->tool_.status = s->readToolSelection(c.get(), ec);
                                          if (s->toolWnd_) PostMessageW(s->toolWnd_, kMsgToolRead, 0, 0);
                                          return S_OK;
                                      });
    if (FAILED(hr)) {
        config::log("text tool: the app refused a read session -> app clipboard fallback");
        dropTextToolPending();
        postToolReply(request, TextToolStatus::Fallback);
    }
}

// In the read session: 0 = selection read into tool_ (range kept), else a TextToolStatus.
int TextService::readToolSelection(ITfContext* ctx, TfEditCookie ec) {
    int scopes[32];
    const UINT n = inputScopesAtSelection(ctx, ec, scopes, 32);
    for (UINT i = 0; i < n; ++i)
        if (isSecretInputScope(scopes[i])) return static_cast<int>(TextToolStatus::Refused);
    TF_SELECTION sel;
    ULONG fetched = 0;
    if (FAILED(ctx->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &fetched)) || fetched != 1 || !sel.range)
        return static_cast<int>(TextToolStatus::Fallback);
    BOOL empty = TRUE;
    sel.range->IsEmpty(ec, &empty);
    std::u16string text;
    int status = 0;
    // A readable store that says "nothing selected" is believed: Ctrl+C there would copy
    // something else (VS Code copies the whole line).
    if (empty) status = static_cast<int>(TextToolStatus::Failed);
    else if (!rangeText(sel.range, ec, kTextToolMaxLength, text)) status = static_cast<int>(TextToolStatus::Failed);
    else if (text.empty()) status = static_cast<int>(TextToolStatus::Fallback);  // embedded objects only
    if (status == 0) {
        tool_.range = sel.range;  // keep the reference
        tool_.text = std::move(text);
    } else {
        sel.range->Release();
    }
    return status;
}

void TextService::sendTextToolSelection() {
    const uint32_t request = tool_.request;
    if (!request) return;
    if (tool_.status != 0) {
        const auto st = static_cast<TextToolStatus>(tool_.status);
        config::log(st == TextToolStatus::Refused ? "text tool: password field -> refused"
                    : st == TextToolStatus::Fallback ? "text tool: selection unreadable -> app clipboard fallback"
                                                     : "text tool: nothing selected / too long");
        dropTextToolPending();
        return postToolReply(request, st);
    }
    HWND app = FindWindowW(kAppWindowClass, nullptr);
    if (!app) return dropTextToolPending();
    std::vector<uint8_t> b = packTextToolData(request, tool_.tool, tool_.text);
    COPYDATASTRUCT cds;
    cds.dwData = kCopySelection;
    cds.cbData = static_cast<DWORD>(b.size());
    cds.lpData = b.data();
    DWORD_PTR r = 0;
    if (!SendMessageTimeoutW(app, WM_COPYDATA, reinterpret_cast<WPARAM>(toolWnd_), reinterpret_cast<LPARAM>(&cds),
                             SMTO_ABORTIFHUNG, 1000, &r) ||
        !r) {
        config::log("text tool: VietTelex.exe did not take the selection");
        dropTextToolPending();
    }
    // else: wait for kCopyResult (or a newer request / focus change drops it)
}

void TextService::applyTextToolResult() {
    if (!tool_.request || !tool_.ctx || !tool_.range) return;
    const uint32_t request = tool_.request;
    session_.reset();  // the text around the caret is about to change under the engine
    Ref<TextService> self(this);
    Ref<ITfContext> c(tool_.ctx);
    Ref<ITfRange> range(tool_.range);
    const std::u16string orig = tool_.text, result = tool_.result;
    const HRESULT hr = RunEditSession(
        tool_.ctx, clientId_, TF_ES_ASYNCDONTCARE | TF_ES_READWRITE,
        [self, c, range, orig, result, request](TfEditCookie ec) -> HRESULT {
            TextToolStatus st = TextToolStatus::Failed;
            TF_SELECTION sel;
            ULONG fetched = 0;
            if (SUCCEEDED(c->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &fetched)) && fetched == 1 && sel.range) {
                LONG a = 1, b = 1;
                std::u16string now;
                // Replace only what was read: the selection must still be exactly that range
                // with exactly that text (the user may have typed or clicked meanwhile).
                if (SUCCEEDED(sel.range->CompareStart(ec, range.get(), TF_ANCHOR_START, &a)) &&
                    SUCCEEDED(sel.range->CompareEnd(ec, range.get(), TF_ANCHOR_END, &b)) && a == 0 && b == 0 &&
                    rangeText(range.get(), ec, kTextToolMaxLength, now) && now == orig &&
                    SUCCEEDED(range->SetText(ec, 0, reinterpret_cast<const WCHAR*>(result.data()),
                                             static_cast<LONG>(result.size())))) {
                    range->Collapse(ec, TF_ANCHOR_END);  // caret after the new text (= macOS insertText)
                    TF_SELECTION ts;
                    ts.range = range.get();
                    ts.style.ase = TF_AE_NONE;
                    ts.style.fInterimChar = FALSE;
                    c->SetSelection(ec, 1, &ts);
                    st = TextToolStatus::Replaced;
                }
                sel.range->Release();
            }
            self->session_.reset();
            if (self->tool_.request == request) self->dropTextToolPending();
            config::log(st == TextToolStatus::Replaced ? "text tool: selection replaced"
                                                       : "text tool: selection changed -> not replaced");
            postToolReply(request, st);
            return S_OK;
        });
    if (FAILED(hr)) {
        config::log("text tool: the app refused a write session");
        if (tool_.request == request) dropTextToolPending();
        postToolReply(request, TextToolStatus::Failed);
    }
}

// ---------------------------------------------------------------- Gợi ý cạnh con trỏ
// ime/core/caret_hints.h has the rules. Per key: one flag read (hintsAny_) and, when on, a
// few string operations on the chunk being typed. Only a trigger (= after a number, space
// after a word worth it, . ! ?) arms a 40 ms timer (0.9 s for the tones pause) — the app has
// inserted the key by then — and one async read session. Nothing is ever replaced without
// Tab, and the screen is re-checked right before replacing.

namespace {
constexpr int kHintWindow = hints::kMathMaxLength + 2;
constexpr UINT kHintHideMs = 8000;

hints::LocalTime localNow() {
    SYSTEMTIME st;
    GetLocalTime(&st);
    return hints::LocalTime{st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute};
}

bool isEnglishForDates(const std::u32string& w) { return hints::opensEnglishRun(w); }

// Classic Edit with ES_PASSWORD (its TSF context may not carry IS_PASSWORD).
bool focusIsPasswordEdit() {
    HWND f = GetFocus();
    if (!f) return false;
    wchar_t cls[32] = {};
    GetClassNameW(f, cls, 32);
    return lstrcmpiW(cls, L"Edit") == 0 && (GetWindowLongW(f, GWL_STYLE) & ES_PASSWORD) != 0;
}

hints::Rect toRect(const RECT& r) { return hints::Rect{r.left, r.top, r.right, r.bottom}; }

bool plausible(const RECT& r) {
    const hints::Rect screen{GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
                             GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN),
                             GetSystemMetrics(SM_YVIRTUALSCREEN) + GetSystemMetrics(SM_CYVIRTUALSCREEN)};
    HDC dc = GetDC(nullptr);
    const int dpi = dc ? GetDeviceCaps(dc, LOGPIXELSY) : 96;
    if (dc) ReleaseDC(nullptr, dc);
    return hints::plausibleCaret(toRect(r), screen, dpi);
}

// Caret rectangle (screen coordinates) from the context's view: the empty selection, else
// the right edge of the character before it (hosts that report nothing for an empty range).
bool caretRectFromView(ITfContext* ctx, TfEditCookie ec, RECT& out) {
    ITfContextView* view = nullptr;
    if (FAILED(ctx->GetActiveView(&view)) || !view) return false;
    bool ok = false;
    TF_SELECTION sel;
    ULONG fetched = 0;
    if (SUCCEEDED(ctx->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &fetched)) && fetched == 1 && sel.range) {
        RECT rc = {};
        BOOL clipped = FALSE;
        if (SUCCEEDED(view->GetTextExt(ec, sel.range, &rc, &clipped)) && plausible(rc)) {
            out = rc;
            ok = true;
        } else {
            ITfRange* prev = nullptr;
            LONG shifted = 0;
            if (SUCCEEDED(sel.range->Clone(&prev)) && prev) {
                prev->Collapse(ec, TF_ANCHOR_START);
                if (SUCCEEDED(prev->ShiftStart(ec, -1, &shifted, nullptr)) && shifted == -1 &&
                    SUCCEEDED(view->GetTextExt(ec, prev, &rc, &clipped))) {
                    RECT edge = {rc.right, rc.top, rc.right, rc.bottom};
                    if (plausible(edge)) {
                        out = edge;
                        ok = true;
                    }
                }
                prev->Release();
            }
        }
        sel.range->Release();
    }
    view->Release();
    return ok;
}

// Fallback: the Win32 caret of this thread (GetGUIThreadInfo).
bool caretRectFromWin32(RECT& out) {
    GUITHREADINFO gi = {};
    gi.cbSize = sizeof gi;
    if (!GetGUIThreadInfo(GetCurrentThreadId(), &gi) || !gi.hwndCaret) return false;
    RECT r = gi.rcCaret;
    if (r.bottom <= r.top) return false;
    MapWindowPoints(gi.hwndCaret, nullptr, reinterpret_cast<POINT*>(&r), 2);
    if (!plausible(r)) return false;
    out = r;
    return true;
}

const char* hintKindName(hints::Kind k) {
    switch (k) {
        case hints::Kind::Math: return "math";
        case hints::Kind::Number: return "number";
        case hints::Kind::Typo: return "typo";
        case hints::Kind::Tones: return "tones";
        case hints::Kind::Date: return "date";
        case hints::Kind::Predict: return "predict";
        case hints::Kind::Email: return "email";
        case hints::Kind::Retro: return "retro";
    }
    return "?";
}
}  // namespace

bool TextService::hintsUsable() const {
    return (hintsAny_ || predictOn_ || retroOfferOn_) && toolWnd_ && !config::secureMode() && !consoleHost_ && !directActive_ &&
           !directWanted_ && host_ != HostText::Ignore && host_ != HostText::Literal && host_ != HostText::CompositionOnly &&
           !session_.contextFellBack();
}

ITfContext* TextService::keyTarget(ITfContext* ctx) const {
    return (host_ == HostText::NormalViaParent && targetCtx_) ? targetCtx_ : ctx;
}

// Once per key, after the session handled it (OnTestKeyDown for keys it passes on,
// OnKeyDown otherwise).
// `handled` = the session saw this key (its lastCommit*() describe THIS key).
void TextService::noteHintKey(const KeyInput& k, ITfContext* target, bool handled) {
    if (!hintsAny_ && !predictOn_ && !retroOfferOn_) return;  // all off: this one test per key
    if (!hintsUsable() || !target) {
        hintTracker_.reset();
        emailToken_ = false;
        if (learn_.hasPending() || !learn_.prev1().empty()) learn_.discard();
        return;
    }
    if (learnOn_) noteLearnKey(k, handled);
    switch (k.kind) {
        case KeyKind::Char: {
            bool scheduled = false;
            // Retro English offer: verified by the session at this key; wins over the rest.
            const bool retroOffered = retroOfferOn_ && handled && !session_.retroOffer().empty();
            hints::Trigger t;
            if (hintsAny_) {
                hints::Commit c;  // only read at a boundary (the hot path is a letter)
                if (handled && !hints::isLetter(k.ch) && !hints::isDigit(k.ch))
                    c = hints::Commit{hints::toU32(session_.lastCommitRaw()), hints::toU32(session_.lastCommitText())};
                t = hintTracker_.onChar(k.ch, c, hintsOn_);
            }
            t = hints::withRetro(t, retroOffered);
            if (retroOffered) {
                const retro::Offer& o = session_.retroOffer();
                retroHint_ = hints::retroHint(o.display, o.replace, o.insert);
            }
            if (t.kind != hints::TriggerKind::None) {
                scheduleHint(t, target);
                scheduled = hintStage_ != HintStage::None;
            }
            if (predictOn_) notePredictKey(k, target, scheduled);
            break;
        }
        case KeyKind::Backspace:
            if (hintsAny_) hintTracker_.onBackspace();
            if (predictOn_) notePredictKey(k, target, false);
            break;
        case KeyKind::Modifier:
        case KeyKind::Other: break;
        default:  // Enter, Tab, arrows, chords
            hintTracker_.reset();
            emailToken_ = false;
            break;
    }
}

void TextService::scheduleHint(const hints::Trigger& t, ITfContext* target) {
    if (t.kind == hints::TriggerKind::Typo && rejectedTypos_.contains(t.word)) return;
    dropHintWork();
    hintTrig_ = t;
    hintGen_ = keyGen_;
    hintCtx_ = target;
    hintCtx_->AddRef();
    hintStage_ = t.kind == hints::TriggerKind::Typo    ? HintStage::TypoAsk
                 : t.kind == hints::TriggerKind::Tones ? HintStage::TonesRun
                                                        : HintStage::Show;
    SetTimer(toolWnd_, kTimerHint, static_cast<UINT>(t.delayMs), nullptr);
}

void TextService::onHintTimer() {
    KillTimer(toolWnd_, kTimerHint);
    if (hintGen_ != keyGen_ || hintStage_ == HintStage::None || !hintCtx_ || focusIsPasswordEdit()) {
        dropHintWork();
        return;
    }
    switch (hintStage_) {
        case HintStage::TypoAsk: askApp(HintJob::Typo, hints::toU16(hintTrig_.raw)); break;
        case HintStage::TonesRun: readForHint(HintStage::TonesRun, hints::kToneWindow); break;
        case HintStage::PredictWait: readForHint(HintStage::PredictRead, hints::kPredictWindow); break;
        default:
            readForHint(HintStage::Show, hintTrig_.kind == hints::TriggerKind::Retro
                                             ? static_cast<int>(retroHint_.replace.size()) + 2
                                             : kHintWindow);
            break;
    }
}

void TextService::readForHint(HintStage stage, int window) {
    hintStage_ = stage;
    if (!hintCtx_) return dropHintWork();
    Ref<TextService> self(this);
    Ref<ITfContext> c(hintCtx_);
    const uint32_t gen = hintGen_;
    const HRESULT hr = RunEditSession(hintCtx_, clientId_, TF_ES_ASYNCDONTCARE | TF_ES_READ,
                                      [self, c, gen, window](TfEditCookie ec) -> HRESULT {
                                          TextService* s = self.get();
                                          if (s->hintGen_ != gen) return S_OK;
                                          HintRead r;
                                          int scopes[32];
                                          const UINT n = s->inputScopesAtSelection(c.get(), ec, scopes, 32);
                                          bool secret = false;
                                          for (UINT i = 0; i < n; ++i) secret = secret || isSecretInputScope(scopes[i]);
                                          TsfTextSink ro(s, c.get(), ec);
                                          if (!secret && !ro.hasSelection()) {
                                              r.before = ro.textBeforeCaret(window);
                                              r.ok = !r.before.empty();
                                              if (r.ok) r.caretOk = caretRectFromView(c.get(), ec, r.caret);
                                          }
                                          s->hintRead_ = r;
                                          if (s->toolWnd_) PostMessageW(s->toolWnd_, kMsgHintRead, gen, 0);
                                          return S_OK;
                                      });
    if (FAILED(hr)) dropHintWork();
}

void TextService::onHintRead() {
    if (hintGen_ != keyGen_ || !hintRead_.ok) return dropHintWork();
    const std::u32string before = hints::toU32(hintRead_.before);
    std::optional<hints::Suggestion> sug;
    switch (hintStage_) {
        case HintStage::Show:
            if (hintTrig_.kind == hints::TriggerKind::Retro) {
                sug = hints::retroSuggestion(before, retroHint_);
            } else if (hintTrig_.kind == hints::TriggerKind::Math) {
                if (auto r = hints::mathChip(before))
                    sug = hints::Suggestion{hints::Kind::Math, hints::toU16(hints::mathLabel(*r)), u"",
                                            hints::toU16(*r)};
            } else if (hintTrig_.kind == hints::TriggerKind::Number) {
                sug = hints::moneyChip(before);
            } else if (hintTrig_.kind == hints::TriggerKind::Date) {
                std::u32string prev, run;
                if (hints::lastRuns(before, prev, run)) {
                    if (auto ph = hints::detectDate(U' ', prev, run, &isEnglishForDates))
                        sug = hints::dateSuggestion(before, prev, run, *ph, localNow());
                }
            }
            break;
        case HintStage::TypoShow:
            sug = hints::typoSuggestion(before, hintTrig_.word, hintTrig_.boundary, hintTrig_.raw, hintAnswer_);
            break;
        case HintStage::TonesRun: {
            auto run = hints::toneRun(before);
            if (!run || (!declinedTones_.empty() && run->compare(0, declinedTones_.size(), declinedTones_) == 0))
                return missHint();
            hintRun_ = *run;
            askApp(HintJob::Tones, hints::toU16(*run));
            return;
        }
        case HintStage::TonesShow:
            if (hints::standsAlone(before, hintRun_)) sug = hints::toneSuggestion(hintRun_, hintAnswer_);
            break;
        case HintStage::PredictRead:
            if (predEmail_) {  // email domain: a string check here, no app job
                sug = hints::emailDomainSuggestion(before, predTyped_, hints::toU32(predRaw_));
                break;
            }
            // The app builds the request from the screen (word_prediction.h request()).
            predBefore_ = hintRead_.before;
            askApp(HintJob::Predict, packPredictText(hintRead_.before, hints::toU16(predTyped_), predRaw_));
            return;
        case HintStage::PredictShow:
            if (hintRead_.before == predBefore_) sug = hints::predictSuggestion(before, predTyped_, predCand_);
            break;
        default: break;
    }
    if (sug) {
        presentHint(*sug);
        dropHintWork();
    } else {
        missHint();
    }
}

void TextService::askApp(HintJob job, const std::u16string& text) {
    HWND app = FindWindowW(kAppWindowClass, nullptr);
    if (!app || !toolWnd_ || text.empty()) return dropHintWork();
    HintMessage m;
    m.request = hintGen_;
    m.job = static_cast<uint32_t>(job);
    m.flags = job == HintJob::Predict ? (predEnglish_ ? kPredictEnglish : 0u) : settings_->engineFlags();
    m.text = text;
    const std::vector<uint8_t> b = packHintMessage(m);
    COPYDATASTRUCT cds;
    cds.dwData = kCopyHintRequest;
    cds.cbData = static_cast<DWORD>(b.size());
    cds.lpData = const_cast<uint8_t*>(b.data());
    hintAwaitingApp_ = true;
    hintStage_ = job == HintJob::Typo    ? HintStage::TypoShow
                 : job == HintJob::Tones ? HintStage::TonesShow
                                         : HintStage::PredictShow;
    DWORD_PTR r = 0;
    // The app only queues the job; SMTO_ABORTIFHUNG: a hung app never stalls this thread.
    if (!SendMessageTimeoutW(app, WM_COPYDATA, reinterpret_cast<WPARAM>(toolWnd_), reinterpret_cast<LPARAM>(&cds),
                             SMTO_ABORTIFHUNG, 250, &r) ||
        !r) {
        config::log("caret hint: VietTelex.exe did not take the job");
        dropHintWork();
    }
}

void TextService::onHintReply() {
    if (hintGen_ != keyGen_ || !hintAwaitingApp_) return dropHintWork();
    hintAwaitingApp_ = false;
    if (hintAnswer_.empty()) return missHint();
    if (hintStage_ == HintStage::PredictShow) {
        predCand_ = hints::toU16(hintAnswer_);  // one suggestion: the app's top-ranked word
        return readForHint(HintStage::PredictShow, hints::kPredictWindow);  // re-read: screen unchanged?
    }
    readForHint(hintStage_, hintStage_ == HintStage::TonesShow ? hints::kToneWindow : kHintWindow);
}

void TextService::presentHint(const hints::Suggestion& s) {
    RECT caret = hintRead_.caret;
    const bool haveCaret = hintRead_.caretOk || caretRectFromWin32(caret);
    if (!haveCaret) {
        config::log(std::string("caret hint ") + hintKindName(s.kind) + ": no caret position -> not shown");
        return;
    }
    hideHint();
    const std::wstring text(s.display.begin(), s.display.end());
    const bool predict = s.kind == hints::Kind::Predict || s.kind == hints::Kind::Email;  // clickable (= Tab)
    if (!popup_.show(text, caret, predict ? toolWnd_ : nullptr, predict ? kMsgHintPick : 0)) return;
    if (predict) {
        SafeRelease(hintShownCtx_);
        hintShownCtx_ = hintCtx_;
        if (hintShownCtx_) hintShownCtx_->AddRef();
    }
    hint_ = s;
    hintCaret_ = caret;
    const std::u16string& b = hintRead_.before;
    hintShownBefore_ = b.size() > 32 ? b.substr(b.size() - 32) : b;
    SetTimer(toolWnd_, kTimerHintHide, kHintHideMs, nullptr);
    config::log(std::string("caret hint ") + hintKindName(s.kind) + ": shown, len=" + std::to_string(s.insert.size()) +
                (hintRead_.caretOk ? " (view)" : " (win32 caret)"));
}

void TextService::hideHint() {
    hintKeyAct_ = -1;
    if (!hint_) return;
    hint_.reset();
    hintShownBefore_.clear();
    SafeRelease(hintShownCtx_);
    popup_.hide();
    if (toolWnd_) KillTimer(toolWnd_, kTimerHintHide);
}

void TextService::dropHintWork() {
    if (toolWnd_) KillTimer(toolWnd_, kTimerHint);
    hintStage_ = HintStage::None;
    hintAwaitingApp_ = false;
    hintAnswer_.clear();
    hintRun_.clear();
    predCand_.clear();
    predictAfter_ = false;
    SafeRelease(predCtx_);
    SafeRelease(hintCtx_);
}

// While a hint shows: Tab (Enter for math) applies, Esc declines — both eaten; any other
// key hides it and goes on. Modifiers alone change nothing.
bool TextService::hintKeyTest(WPARAM wp, BOOL* eaten) {
    const uint32_t vkey = static_cast<uint32_t>(wp);
    if (!hint_ || isModifierVk(vkey)) return false;
    const bool plain = !keyDown(VK_SHIFT) && !keyDown(VK_CONTROL) && !keyDown(VK_MENU) && !keyDown(VK_LWIN) &&
                       !keyDown(VK_RWIN);
    const hints::KeyAction a = hints::action(hint_->kind, vkey, plain);
    if (a == hints::KeyAction::DismissPass) {
        hideHint();
        return false;
    }
    hintKeyAct_ = static_cast<int>(a);
    *eaten = TRUE;
    return true;
}

// Tab: replace `replace` (just before the caret, re-read now) with `insert`. False = the
// screen no longer matches (nothing changed; the Tab goes to the app). A click on a shown
// prediction (`sync` false: no key handler is running) does the same in an async session.
bool TextService::applyHint(ITfContext* ctx, bool sync) {
    if (!hint_) return false;
    const hints::Suggestion s = *hint_;
    hideHint();
    ITfContext* target = ctx ? (sync ? keyTarget(ctx) : ctx) : nullptr;
    if (!target || composition_) return false;
    if (!sync) {
        Ref<TextService> self(this);
        Ref<ITfContext> c(target);
        return SUCCEEDED(RunEditSession(target, clientId_, TF_ES_ASYNCDONTCARE | TF_ES_READWRITE,
                                        [self, c, s](TfEditCookie ec) -> HRESULT {
                                            TextService* t = self.get();
                                            t->afterHintApplied(t->replaceForHint(c.get(), ec, s), c.get(), s);
                                            return S_OK;
                                        }));
    }
    bool ok = false;
    const HRESULT hr = RunEditSession(target, clientId_, TF_ES_SYNC | TF_ES_READWRITE, [&](TfEditCookie ec) -> HRESULT {
        ok = replaceForHint(target, ec, s);
        return S_OK;
    });
    afterHintApplied(ok && hr == S_OK, target, s);
    return ok && hr == S_OK;
}

bool TextService::replaceForHint(ITfContext* c, TfEditCookie ec, const hints::Suggestion& s) {
    TsfTextSink sink(this, c, ec);
    if (sink.hasSelection() || composition_) return false;
    // Email: the whole "@part" is checked (≤ 11 letters + the composing word).
    const int window = static_cast<int>(s.replace.size()) + (s.kind == hints::Kind::Email ? 16 : 2);
    const std::u16string before = sink.textBeforeCaret(window);
    return hints::hintStillValid(s, hints::toU32(before)) && sink.replaceBeforeCaret(s.replace, s.insert);
}

// The key right after Tab on a prediction ("được␣"): decide (OnTestKeyDown) …
bool TextService::acceptSpaceTest(const KeyInput& k) {
    acceptAct_ = -1;
    const hints::AcceptSpaceAct act = hints::acceptSpaceKey(acceptedSpace_, k.kind == KeyKind::Char ? k.ch : 0,
                                                            acceptExpect_, acceptRep_);
    if (act == hints::AcceptSpaceAct::Pass || directActive_ || composition_) return false;
    acceptAct_ = static_cast<int>(act);
    return true;
}

// … and do it (OnKeyDown): re-read the screen, then the punctuation replaces our space and
// the space moves after it (or the space after that is swallowed). False = the screen changed:
// the key goes to the app as typed.
bool TextService::acceptSpaceApply(ITfContext* ctx) {
    const int act = acceptAct_;
    acceptAct_ = -1;
    ITfContext* target = keyTarget(ctx);
    bool ok = false;
    const std::u16string expect = hints::toU16(acceptExpect_), rep = hints::toU16(acceptRep_);
    const HRESULT hr = RunEditSession(target, clientId_, TF_ES_SYNC | TF_ES_READWRITE, [&](TfEditCookie ec) -> HRESULT {
        TsfTextSink sink(this, target, ec);
        if (sink.hasSelection() || composition_) return S_OK;
        const std::u16string before = sink.textBeforeCaret(static_cast<int>(expect.size()) + 2);
        if (before.size() < expect.size() || before.compare(before.size() - expect.size(), expect.size(), expect) != 0)
            return S_OK;
        ok = act == static_cast<int>(hints::AcceptSpaceAct::Swallow) || sink.replaceBeforeCaret(u" ", rep);
        return S_OK;
    });
    if (hr != S_OK || !ok) {
        config::log("accept-space: screen changed -> plain key");
        return false;
    }
    session_.reset();
    hintTracker_.reset();
    learnFlush();  // the punctuation ends the sentence context
    if (act == static_cast<int>(hints::AcceptSpaceAct::Replace) && !acceptRep_.empty() && acceptRep_.back() == U' ')
        acceptedSpace_.carried = acceptRep_;
    config::log(act == static_cast<int>(hints::AcceptSpaceAct::Swallow) ? "accept-space: space swallowed"
                                                                        : "accept-space: punctuation attached");
    return true;
}

void TextService::afterHintApplied(bool ok, ITfContext* c, const hints::Suggestion& s) {
    // Email domain inserted raw: the engine forgets the composing word (no re-toning of what
    // follows, ⌫ does not reopen it); nothing learned (learn_.discard below), no next word.
    session_.reset();
    hintTracker_.reset();
    if (s.kind == hints::Kind::Email) emailToken_ = false;
    if (ok && learnOn_) {
        // Học từ bạn gõ: an accepted prediction counts double (iOS weight 2); an accepted typo
        // fix learns the fixed form; any other hint replaced committed text — dropped.
        hints::LearnTracker::Event e;
        if (s.kind == hints::Kind::Predict) {
            if (learn_.commit(hints::toU32(s.display), U' ', true, 2, e)) learnSend(e);
            afterSpace_ = true;
            prevKeyLetter_ = false;
        } else if (s.kind == hints::Kind::Typo) {
            learn_.replacePending(hints::toU32(s.display));
        } else {
            learn_.discard();
        }
    }
    acceptedSpace_ = hints::AcceptedSpace();
    if (ok && s.kind == hints::Kind::Predict && !s.insert.empty() && s.insert.back() == u' ')
        acceptedSpace_.inserted = hints::toU32(s.insert);
    config::log(std::string("caret hint ") + hintKindName(s.kind) + (ok ? ": applied" : ": screen changed -> not applied"));
    if (ok && s.kind == hints::Kind::Predict && predictOn_) {  // macOS: next word after an accepted one
        predTyped_.clear();
        predRaw_.clear();
        predEnglish_ = false;
        schedulePredict(c);
    }
}

// Esc: typo -> never suggest that word again (this session); tones -> not again for a run
// starting with the declined one (typing on in the same sentence).
void TextService::declineHint() {
    if (!hint_) return;
    if (hint_->kind == hints::Kind::Typo && !hint_->replace.empty())
        rejectedTypos_.add(hints::toU32(hint_->replace.substr(0, hint_->replace.size() - 1)));
    else if (hint_->kind == hints::Kind::Tones)
        declinedTones_ = hints::toU32(hint_->replace);
    else if (hint_->kind == hints::Kind::Predict && !hint_->replace.empty())
        declinedPredict_ = hints::toU32(hint_->replace);  // until the next word
    else if (hint_->kind == hints::Kind::Email)
        declinedEmail_ = true;  // until this "@" token ends
    hideHint();
}

// ---------------------------------------------------------------- Học từ bạn gõ
// Only words the typing session composed AND committed (lastCommitWord: printable boundary or
// Enter / Tab / Esc; never a shortcut expansion, never app-typed text). Gates: word prediction
// on (Windows' setting) + learnWords + not a code editor / terminal (learnOn_), hintsUsable()
// (not the secure desktop, console, Direct, literal/password input scopes — the session does
// not even compose there), not a classic ES_PASSWORD edit, Vietnamese on.

void TextService::noteLearnKey(const KeyInput& k, bool handled) {
    hints::LearnTracker::Event e;
    switch (k.kind) {
        case KeyKind::Char: {
            if (session_.wordActive()) {  // a letter (or VNI mark) of the word in progress
                if (!prevKeyLetter_) wordAlone_ = afterSpace_;
                prevKeyLetter_ = true;
                afterSpace_ = false;
                return;
            }
            const std::u32string word = handled ? hints::toU32(session_.lastCommitWord()) : std::u32string();
            const bool alone = wordAlone_;
            prevKeyLetter_ = false;
            afterSpace_ = hints::isWhitespace(k.ch);
            wordAlone_ = true;
            if (!vietnamese() || focusIsPasswordEdit()) return learn_.discard();
            if (learn_.commit(word, k.ch, alone, 1, e)) learnSend(e);
            return;
        }
        case KeyKind::Backspace:
            // ⌫ right after a boundary edits committed text: the held word may be changing.
            if (!prevKeyLetter_) learn_.discard();
            prevKeyLetter_ = session_.wordActive();
            return;
        case KeyKind::Boundary: {  // Enter / Tab / Esc: the word is final, the sentence ends
            const std::u32string word = handled ? hints::toU32(session_.lastCommitWord()) : std::u32string();
            const bool alone = wordAlone_;
            learnResetKeys();
            if (!vietnamese() || focusIsPasswordEdit()) return learn_.discard();
            if (!word.empty() && learn_.commit(word, U'\n', alone, 1, e)) learnSend(e);
            learnFlush();
            return;
        }
        case KeyKind::Navigation:
            learnResetKeys();
            learnFlush();
            return;
        case KeyKind::Chord:  // Ctrl+Z / Ctrl+Backspace may undo / delete it: never learned
            learnResetKeys();
            learn_.discard();
            return;
        case KeyKind::Modifier:
        case KeyKind::Other: return;
    }
}

void TextService::learnSend(const hints::LearnTracker::Event& e) {
    if (!learnOn_ || !toolWnd_) return;
    // word as committed (casing kept — learned casing); the app lowercases the key itself
    const LearnEvent le{hints::toU16(e.form.empty() ? e.word : e.form), hints::toU16(e.prev1), hints::toU16(e.prev2),
                        e.weight};
    if (!appendLearnEvent(learnQueue_, le)) {
        sendLearnQueue();  // full: send what is queued now (rare: ~20 words without a pause)
        if (!appendLearnEvent(learnQueue_, le)) return;
    }
    SetTimer(toolWnd_, kTimerLearn, kLearnSendDelayMs, nullptr);
}

void TextService::learnFlush() {
    hints::LearnTracker::Event e;
    if (learn_.breakContext(e)) learnSend(e);
}

// From the timer (or a full queue): one WM_COPYDATA, the app only queues it.
void TextService::sendLearnQueue() {
    if (learnQueue_.empty()) return;
    HintMessage m;
    m.job = static_cast<uint32_t>(HintJob::Learn);
    m.text.swap(learnQueue_);
    HWND app = FindWindowW(kAppWindowClass, nullptr);
    if (!app || !toolWnd_) return;
    const std::vector<uint8_t> b = packHintMessage(m);
    COPYDATASTRUCT cds;
    cds.dwData = kCopyHintRequest;
    cds.cbData = static_cast<DWORD>(b.size());
    cds.lpData = const_cast<uint8_t*>(b.data());
    DWORD_PTR r = 0;
    SendMessageTimeoutW(app, WM_COPYDATA, reinterpret_cast<WPARAM>(toolWnd_), reinterpret_cast<LPARAM>(&cds),
                        SMTO_ABORTIFHUNG, 250, &r);
}

// ---------------------------------------------------------------- Gợi ý từ (word prediction)
// Setting off: noteHintKey returns before reaching here (one bool test per key). On: per
// letter / space / backspace only a few string copies and a 0.3 s timer (re-armed by every
// key, so typing on reads nothing); when it fires, one async read session, one WM_COPYDATA
// to VietTelex.exe (which ranks with its embedded data), and a re-read before showing.

void TextService::notePredictKey(const KeyInput& k, ITfContext* target, bool otherScheduled) {
    // Email domains: track "…@part" from the keys alone ('@' arms, letters / digits / . - keep).
    if (k.kind == KeyKind::Char) {
        if (k.ch == U'@') {
            emailToken_ = true;
            declinedEmail_ = false;  // a new "@": the old Esc no longer applies
        } else if (!hints::emailTokenChar(k.ch)) {
            emailToken_ = false;
        }
    }
    if (!predictApp_ || !target) return;
    if (hint_ && hint_->kind != hints::Kind::Predict && hint_->kind != hints::Kind::Email) return;  // other hints win
    if (emailToken_ && k.kind == KeyKind::Char && (k.ch == U'@' || hints::isLetter(k.ch))) {
        // "user@" / "user@g": the domain suggestion (a string check in onHintRead, no app job).
        // The normal prediction would reject a word glued to "@" anyway.
        if (declinedEmail_) return;
        std::u32string typed;
        std::u16string raw;
        if (session_.wordActive()) {
            if (composition_ || session_.wordMode() != OutputMode::InPlace) return;
            typed = hints::toU32(session_.shown());
            raw = session_.rawKeys();
        } else if (k.ch != U'@') {
            return;
        }
        predTyped_ = std::move(typed);
        predRaw_ = std::move(raw);
        predEnglish_ = false;
        if (otherScheduled) {
            predictAfter_ = true;
            predAfterEmail_ = true;
            SafeRelease(predCtx_);
            predCtx_ = target;
            predCtx_->AddRef();
            return;
        }
        schedulePredict(target, true);
        return;
    }
    if (emailToken_) return;  // digits / . - inside the domain part: nothing to predict
    const bool space = k.kind == KeyKind::Char && k.ch == U' ';
    if (k.kind == KeyKind::Char && !space && !hints::isLetter(k.ch)) return;
    std::u32string typed;
    std::u16string raw;
    if (session_.wordActive()) {
        // Completion needs the word on screen (in-place); a composition is never replaced.
        if (composition_ || session_.wordMode() != OutputMode::InPlace) return;
        typed = hints::toU32(session_.shown());
        if (typed.size() < 2) return;  // completion from 2 letters (word_prediction.h kMinTyped)
        raw = session_.rawKeys();
    } else if (!space) {
        return;  // next word: only right after a space
    }
    if (typed.empty()) declinedPredict_.clear();                    // a new word
    else if (hints::predictMuted(typed, declinedPredict_)) return;  // Esc'd for this word
    predTyped_ = std::move(typed);
    predRaw_ = std::move(raw);
    predEnglish_ = session_.previousWordEnglish();
    if (otherScheduled) {  // that hint goes first; prediction only if it finds nothing
        predictAfter_ = true;
        predAfterEmail_ = false;
        SafeRelease(predCtx_);
        predCtx_ = target;
        predCtx_->AddRef();
        return;
    }
    schedulePredict(target);
}

void TextService::schedulePredict(ITfContext* target, bool email) {
    if (!target || !toolWnd_) return;
    target->AddRef();  // dropHintWork may release the caller's reference (predCtx_)
    dropHintWork();
    predEmail_ = email;
    hintTrig_ = hints::Trigger();
    hintGen_ = keyGen_;
    hintCtx_ = target;  // takes that reference
    hintStage_ = HintStage::PredictWait;
    SetTimer(toolWnd_, kTimerHint, static_cast<UINT>(hints::kPredictDelayMs), nullptr);
}

void TextService::missHint() {
    if (predictAfter_ && predCtx_ && hintGen_ == keyGen_ && predictOn_) {
        ITfContext* c = predCtx_;
        predCtx_ = nullptr;  // our reference now
        predictAfter_ = false;
        schedulePredict(c, predAfterEmail_);
        c->Release();
        return;
    }
    dropHintWork();
}

void TextService::pickHint() {
    if (!hint_ || (hint_->kind != hints::Kind::Predict && hint_->kind != hints::Kind::Email) || !hintShownCtx_)
        return;
    ITfContext* c = hintShownCtx_;
    c->AddRef();
    ++keyGen_;  // whatever was pending belongs to the text before the click
    dropHintWork();
    applyHint(c, false);
    c->Release();
}

}  // namespace vtx::tip
