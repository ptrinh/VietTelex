// text_service.h — the VietTelex TSF text input processor (one instance per thread
// manager, i.e. per UI thread that has text input).
#pragma once
#include "globals.h"
#include "app_policy.h"
#include "caret_hints.h"
#include "game_ipc.h"
#include "hint_popup.h"
#include "hotkey.h"
#include "session.h"
#include "settings.h"
#include "text_tool_ipc.h"
#include "tip_caches.h"
#include "caret_hint_ipc.h"
#include "tsf_compat.h"
#include "typed_word.h"

#include <memory>
#include <string>
#include <vector>

namespace vtx::tip {

// DllCanUnloadNow: unregister the text-tool window class of this module load.
void UnregisterToolWindowClass();

class TextService final : public ITfTextInputProcessorEx,
                          public ITfThreadMgrEventSink,
                          public ITfTextEditSink,
                          public ITfKeyEventSink,
                          public ITfCompositionSink,
                          public ITfDisplayAttributeProvider {
public:
    static HRESULT CreateInstance(IUnknown* outer, REFIID riid, void** ppv);

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfTextInputProcessor(Ex)
    STDMETHODIMP Activate(ITfThreadMgr* ptim, TfClientId tid) override;
    STDMETHODIMP ActivateEx(ITfThreadMgr* ptim, TfClientId tid, DWORD flags) override;
    STDMETHODIMP Deactivate() override;

    // ITfThreadMgrEventSink
    STDMETHODIMP OnInitDocumentMgr(ITfDocumentMgr*) override { return S_OK; }
    STDMETHODIMP OnUninitDocumentMgr(ITfDocumentMgr*) override { return S_OK; }
    STDMETHODIMP OnSetFocus(ITfDocumentMgr* focus, ITfDocumentMgr* prev) override;
    STDMETHODIMP OnPushContext(ITfContext* ctx) override;
    STDMETHODIMP OnPopContext(ITfContext* ctx) override;

    // ITfTextEditSink
    STDMETHODIMP OnEndEdit(ITfContext* ctx, TfEditCookie ecReadOnly, ITfEditRecord* record) override;

    // ITfKeyEventSink
    STDMETHODIMP OnSetFocus(BOOL foreground) override;
    STDMETHODIMP OnTestKeyDown(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) override;
    STDMETHODIMP OnKeyDown(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) override;
    STDMETHODIMP OnTestKeyUp(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) override;
    STDMETHODIMP OnKeyUp(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) override;
    STDMETHODIMP OnPreservedKey(ITfContext* ctx, REFGUID guid, BOOL* eaten) override;

    // ITfCompositionSink
    STDMETHODIMP OnCompositionTerminated(TfEditCookie ecWrite, ITfComposition* comp) override;

    // ITfDisplayAttributeProvider
    STDMETHODIMP EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** ppEnum) override;
    STDMETHODIMP GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** ppInfo) override;

    // --- used by TsfTextSink ---
    ITfComposition* composition() const { return composition_; }
    void setComposition(ITfComposition* c, ITfContext* ctx);  // takes a reference
    void clearComposition();
    TfGuidAtom displayAtom() const { return displayAtom_; }
    TfGuidAtom misspelledAtom() const { return misspelledAtom_; }
    TfClientId clientId() const { return clientId_; }
    ITfCompositionSink* compositionSink() { return this; }
    // TextSink::appTextEndsWith for `ctx`: answers only for the transitory-extension parent
    // of a classic Edit / RichEdit (NormalViaParent), from the focus window itself.
    AppView focusEditEndsWith(ITfContext* ctx, const std::u16string& tail) const;

    bool vietnamese() const;
    void toggleVietnamese();                 // switch hotkey
    void setVietnamese(bool on);
    const Settings& settings() const { return *settings_; }  // after ActivateEx

private:
    TextService();
    ~TextService();

    bool typingEnabled() const;
    // Games / fullscreen (game_ipc.h): VietTelex.exe told this TIP to eat nothing, or
    // Chế độ game is on. One bool test per key; nothing else on the key path.
    bool suspended() const { return tipSuspended(suspendPosted_, gameMode_); }
    void setSuspendBits(uint32_t bits);  // from kTipSuspendMsg / kSuspendProp
    void readSuspendProp();              // focus change: a suspension set before we had focus
    bool appRunning() const;
    bool directServesHere() const;
    // `adoptTyped`: the keys of the word in progress pass to the app as typed and are on
    // the focus root (kTypedWordProp): the hook adopts that word (kDirectAdoptTyped).
    // `inlineAutocomplete` (#173): a Chromium address bar (kDirectInlineAutocomplete).
    bool requestDirect(const char* why, bool adoptTyped = false, bool inlineAutocomplete = false);
    // (#173) Ask the hook for a Chromium address bar: acked, waiting for the ack, or refused
    // (no app, UIPI, NoDirect) — app_policy.h omniboxStepAtWordStart.
    DirectAsk askDirectForAddressBar();
    void publishTypedWord();  // kTypedWordProp on the focus root (typed_word.h)
    void clearTypedWord();
    bool hookReachesHere(HWND app) const;  // UIPI: app integrity >= this process's
    bool retypeClaimedKey(const KeyInput& k, WPARAM wp, LPARAM lp);  // #134 IMM hosts
    void publishLangProp();  // kTipLangProp on the focus root (hook / tray read it)
    void clearLangProp();
    void notifyAppState(bool on);
    // Settings from the snapshot when it changed (`force`: always), then the per-focus
    // state (app mode, stale Chế độ game) — no copy, no lock held, when nothing changed.
    void applyConfig(bool force);
    void applyFocusState();
    bool prepareKey(WPARAM wp, bool down, KeyInput& out);
    // (#121) A key we are about to let through that the thread's (Vietnamese) layout would
    // NOT type like US (1 -> ă): true = eat it; with `inject`, also type the US character
    // (SendInput, Unicode) — false if that failed, so the key goes to the app as before.
    bool retypeAsUs(ITfContext* ctx, WPARAM wp, bool inject);
    uint8_t heldModifiers(uint32_t vk, bool down) const;
    void onModifierEvent(uint32_t vk, bool down);
    void flushAsync(ITfContext* ctx);
    void endCompositionAsync();
    bool fieldPolicyAtWordStart(ITfContext* ctx, TfEditCookie ec);
    UINT inputScopesAtSelection(ITfContext* ctx, TfEditCookie ec, int* buf, UINT cap);

    // Công cụ văn bản (text_tool_ipc.h): a message-only window per thread manager that
    // VietTelex.exe asks for the selection; one pending request at a time.
    static LRESULT CALLBACK toolWndProc(HWND h, UINT msg, WPARAM wp, LPARAM lp);
    void createToolWindow();
    void destroyToolWindow();
    void dropTextToolPending();
    ITfContext* textToolContext(TextToolStatus& why);
    void onTextToolRequest(unsigned tool, uint32_t request);
    int readToolSelection(ITfContext* ctx, TfEditCookie ec);
    void sendTextToolSelection();
    void applyTextToolResult();
    void evaluateHost(ITfContext* ctx);
    void evaluateHostAtWordStart(ITfContext* ctx);  // + Direct handover state
    void noteUnreliableField();                     // session.h takeFieldUnreliable -> unreliable_
    void resolveActiveApp();

    // Gợi ý cạnh con trỏ (ime/core/caret_hints.h). Keys feed a tracker only while a hint is
    // enabled; a trigger arms a timer on toolWnd_ (the app inserts the key first), then an
    // async READ session takes the text before the caret + the caret rectangle; typo fixes
    // and tones go through VietTelex.exe (caret_hint_ipc.h). Tab applies in OnKeyDown.
    // Gợi ý từ (word prediction, caret_hints.h §6): PredictWait (0.3 s idle timer) ->
    // PredictRead (read the screen) -> ask VietTelex.exe -> PredictShow (re-read, show).
    enum class HintStage : uint8_t { None, Show, TypoAsk, TypoShow, TonesRun, TonesShow, PredictWait, PredictRead,
                                     PredictShow };
    bool hintsUsable() const;
    ITfContext* keyTarget(ITfContext* ctx) const;  // context holding the text (parent for Edit)
    void noteHintKey(const KeyInput& k, ITfContext* target, bool handled);
    void scheduleHint(const hints::Trigger& t, ITfContext* target);
    void onHintTimer();
    void readForHint(HintStage stage, int window);
    void onHintRead();
    void askApp(HintJob job, const std::u16string& text);
    void onHintReply();
    void presentHint(const hints::Suggestion& s);
    void hideHint();
    void dropHintWork();
    // `sync` = inside a key handler (false: a click on a prediction).
    bool applyHint(ITfContext* ctx, bool sync = true);
    void declineHint();
    void missHint();  // a non-prediction hint found nothing: prediction for this key, if armed
    void notePredictKey(const KeyInput& k, ITfContext* target, bool otherScheduled);
    void schedulePredict(ITfContext* target, bool email = false);
    void pickHint();  // click on a shown prediction (= Tab)
    bool replaceForHint(ITfContext* c, TfEditCookie ec, const hints::Suggestion& s);
    void afterHintApplied(bool ok, ITfContext* c, const hints::Suggestion& s);
    bool hintKeyTest(WPARAM wp, BOOL* eaten);  // true = handled (eaten set)
    void notePassedBy(const KeyInput& k);      // session_.noteKeyPassedBy + passNoted_
    // Word start in a context suspected of having no editable text (NoEditableContext):
    // true = claim nothing there (a read-only probe found no caret again).
    bool noEditableHere(ITfContext* ctx);
    HRESULT testKeyDownBody(ITfContext* ctx, WPARAM wp, BOOL* eaten);         // OnTestKeyDown body
    HRESULT keyDownBody(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten);   // OnKeyDown body
    bool keyOfferedAgain(bool atTest, WPARAM wp, LPARAM lp);  // tip_caches.h KeyEventRepeat

    bool initThreadMgrSink();
    void uninitThreadMgrSink();
    bool initKeySink();
    void uninitKeySink();
    void updatePreservedKey();
    void hookTextEditSink(ITfDocumentMgr* dm);
    void unhookTextEditSink();
    void registerDisplayAtom();

    LONG ref_ = 1;
    ITfThreadMgr* threadMgr_ = nullptr;
    TfClientId clientId_ = TF_CLIENTID_NULL;
    DWORD threadMgrCookie_ = TF_INVALID_COOKIE;
    ITfContext* editSinkContext_ = nullptr;
    DWORD editSinkCookie_ = TF_INVALID_COOKIE;
    bool keySinkAdvised_ = false;
    bool altZPreserved_ = false;
    bool consoleHost_ = false;  // activated with TF_TMAE_CONSOLE
    HostText host_ = HostText::Normal;  // classification of the context of the current word
    ITfContext* targetCtx_ = nullptr;   // full transitory-extension parent (Edit/RichEdit)
    bool parentFailed_ = false;         // parent refused edit sessions / misreads, this focus
    HWND focusEdit_ = nullptr;          // last evaluateHost: focus window, if a classic Edit
    bool directActive_ = false;         // this field is typed by the app's hook (Direct)
    bool directWanted_ = false;         // this field asked the app's hook to type (1.1.5)
    HWND directFocus_ = nullptr;        // focus window the handover was asked for (1.3.16)
    bool directInWpf_ = false;          // ...a WPF HwndSource: survives TSF focus moves inside it
    bool focusWpf_ = false;             // last evaluateHost: focus window is WPF
    bool contextLogged_ = false;        // context classification logged for this focus (1.3.16)
    std::u16string focusClass_;         // last evaluateHost: focus window class (UnreliableControls)
    UnreliableControls unreliable_;     // control kinds where in-place was undone (2026-11)
    HWND focusWnd_ = nullptr;           // GetFocus() at the last OnSetFocus (debug log only)
    bool directAdopt_ = false;          // the request carried kDirectAdoptTyped (1.3.16)
    bool directInlineAc_ = false;       // ...and kDirectInlineAutocomplete (#173)
    uint64_t directAskTick_ = 0;        // GetTickCount64 when the request was posted
    bool addressBarHandover_ = false;   // (#173) Chromium address bar handed to the hook, this focus
    bool keysPassAsTyped_ = false;      // last evaluateHost: WPF default store, keys pass as typed
    TypedWord typedWord_;               // raw keys of the word in progress (typed_word.h)
    HWND typedWordWnd_ = nullptr;       // where kTypedWordProp is set
    uint32_t typedWordPublished_ = 0;   // ...its value
    bool directBlockedLogged_ = false;  // "not requested: UIPI" logged for this field (#134)
    bool retypeLogged_ = false;         // "claimed key retyped" logged for this field (#134)
    bool notTextFieldLogged_ = false;   // "not a text field" logged + Direct asked for this focus
    HWND langPropWnd_ = nullptr;        // where kTipLangProp is set
    uint32_t suspendPosted_ = 0;        // game_ipc.h kSuspendFullscreen (from VietTelex.exe)
    LayoutMatchCache layoutMatch_;      // retypeAsUs: what the thread's layout types per key
    uintptr_t layoutLogged_ = 0;        // HKL already logged as "not like US"

    ITfComposition* composition_ = nullptr;
    ITfContext* compositionContext_ = nullptr;
    TfGuidAtom displayAtom_ = TF_INVALID_GUIDATOM;
    TfGuidAtom misspelledAtom_ = TF_INVALID_GUIDATOM;  // red squiggle (underlineMisspelled)

    TypingSession session_;
    // Shared, immutable snapshot (config.h): one copy of the shortcuts map per process,
    // not one per thread manager. session_ points into it (SessionOptions::shortcuts).
    std::shared_ptr<const Settings> settings_;
    bool gameMode_ = false;             // settings_->gameMode, unless VietTelex.exe is gone
    unsigned long settingsGen_ = 0;
    FocusStateNotify focusNotify_;      // tray state posts at focus changes (tip_caches.h)
    PerKeyOnce hostEval_;               // evaluateHost once per key (tip_caches.h)
    NoEditableContext noEdit_;          // a page with no editable element (tip_caches.h)
    bool noEditLogged_ = false;         // logged once per focus
    KeyEventRepeat keyRepeat_;          // a key we let through, offered again (tip_caches.h)
    mutable HookReachCache reachCache_; // UIPI answer per focus + app process (tip_caches.h)
    bool keyRepeatLogged_ = false;      // once per focus
    bool ownKeyEdit_ = false;           // inside OnKeyDown's synchronous edit session
    SwitchHotkey hotkey_ = SwitchHotkey::CtrlShift;
    ModifierChord chord_;
    PressLatch altZLatch_;              // Alt+Z: one toggle per press, not per auto-repeat

    HWND toolWnd_ = nullptr;
    struct ToolPending {
        uint32_t request = 0;       // 0 = none
        unsigned tool = 0;
        int status = 0;             // read result: 0 = have text, else TextToolStatus
        ITfContext* ctx = nullptr;  // owned references
        ITfRange* range = nullptr;  // the selection that was read
        std::u16string text, result;
    } tool_;

    // caret hints
    hints::Enabled hintsOn_;
    bool hintsAny_ = false;
    hints::HintTracker hintTracker_;
    uint32_t keyGen_ = 0;               // +1 per key: background hint work shows only if unchanged
    hints::Trigger hintTrig_;           // armed trigger (timer)
    uint32_t hintGen_ = 0;              // keyGen_ when armed
    HintStage hintStage_ = HintStage::None;
    ITfContext* hintCtx_ = nullptr;     // owned: context to read
    struct HintRead {
        bool ok = false;
        std::u16string before;
        RECT caret = {0, 0, 0, 0};
        bool caretOk = false;
    } hintRead_;
    std::u32string hintAnswer_;         // from VietTelex.exe (typo fix / toned run)
    std::u32string hintRun_;            // tones: the run sent to the app
    bool hintAwaitingApp_ = false;
    std::optional<hints::Suggestion> hint_;  // shown
    std::u16string hintShownBefore_;    // tail of the screen when shown (caret moved -> hide)
    RECT hintCaret_ = {0, 0, 0, 0};
    int hintKeyAct_ = -1;               // hints::KeyAction decided in OnTestKeyDown
    hints::AcceptedSpace acceptedSpace_;  // after Tab on a prediction: the next key decides
    int acceptAct_ = -1;                // hints::AcceptSpaceAct decided in OnTestKeyDown
    std::u32string acceptExpect_, acceptRep_;
    bool acceptSpaceTest(const KeyInput& k);
    bool acceptSpaceApply(ITfContext* ctx);
    hints::Rejected rejectedTypos_;
    std::u32string declinedTones_;
    // "Tự sửa từ phía trước" offer mode (retro_english.h: contextualEnglish on, switch off):
    // the session's verified correction shown as a caret hint (Kind::Retro), Tab applies it.
    bool retroOfferOn_ = false;
    hints::Suggestion retroHint_;        // the offer of the armed Retro trigger
    // A key the session declined was already reported in OnTestKeyDown (noteKeyPassedBy):
    // OnKeyDown of that key (retyped as US) must not report it twice.
    bool passNoted_ = false;
    // word prediction (Settings::systemTextPrediction = Windows' setting; off: one bool read)
    bool predictOn_ = false;
    bool predictApp_ = true;             // not a code editor / terminal (caret_hints.h)
    std::u32string predTyped_;           // word being typed when armed ("" = next word)
    std::u16string predRaw_;             // its raw keys
    bool predEnglish_ = false;
    std::u16string predBefore_;          // screen sent to the app (must be unchanged to show)
    std::u16string predCand_;            // the app's top-ranked word (the one suggestion)
    std::u32string declinedPredict_;     // Esc: muted while the word starts with this
    bool predictAfter_ = false;          // another hint was armed at this key: predict if it misses
    ITfContext* predCtx_ = nullptr;      // owned, with predictAfter_
    // Email domains (caret_hints.h emailDomainSuggestion): the caret is inside "…@part" (keys
    // only, no screen read); the armed request is an email one (checked in the TIP, no app job).
    bool emailToken_ = false;
    bool predEmail_ = false;
    bool predAfterEmail_ = false;        // with predictAfter_
    bool declinedEmail_ = false;         // Esc: not again until this "@" token ends
    ITfContext* hintShownCtx_ = nullptr; // owned: where a shown prediction applies on click
    // "Học từ bạn gõ" (Settings::learnWords, only with word prediction on): committed words this
    // TIP composed → events, queued and sent to VietTelex.exe from a timer (HintJob::Learn) —
    // never inside a key handler. Off: one bool read per key.
    bool learnOn_ = false;
    hints::LearnTracker learn_;
    std::u16string learnQueue_;          // packed events (caret_hint_ipc.h appendLearnEvent)
    bool prevKeyLetter_ = false;         // the previous key added to a word in progress
    bool afterSpace_ = true;             // the previous character typed is whitespace / none
    bool wordAlone_ = true;              // the word in progress started after whitespace
    void noteLearnKey(const KeyInput& k, bool handled);
    void learnSend(const hints::LearnTracker::Event& e);
    void learnFlush();                   // breakContext + send
    void learnResetKeys() { prevKeyLetter_ = false; afterSpace_ = true; wordAlone_ = true; }
    void sendLearnQueue();               // kTimerLearn
    HintPopup popup_;

};

}  // namespace vtx::tip
