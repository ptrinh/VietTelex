// tip_caches.h — small per-key / per-focus caches of the TSF text service (2026-10 perf
// audit M1/M3/M4). Pure, so the rules are unit-tested on any OS; text_service.cpp and
// tsf_sink.cpp hold one of each.
#pragma once
#include <cstdint>
#include <string>

namespace vtx {

// (M3) Text before the caret read earlier in the SAME edit session. Nothing else can
// change the document while our edit session holds it, so a later "verify these N
// units before the caret" needs no second GetText when the earlier read already ends
// with them. Any write of ours invalidates it.
class BeforeCaretCache {
public:
    // `exact`: the read returned exactly as many units as the range spans (no hidden
    // text / embedded objects in between) — only then do positions map 1:1 to units.
    void remember(const std::u16string& text, bool exact) {
        text_ = text;
        valid_ = exact;
    }
    void invalidate() { valid_ = false; }
    bool valid() const { return valid_; }
    // True = the remembered text ends with `expect` (so the units right before the caret
    // are known to be `expect`).
    bool proves(const std::u16string& expect) const {
        return valid_ && text_.size() >= expect.size() &&
               text_.compare(text_.size() - expect.size(), expect.size(), expect) == 0;
    }

private:
    std::u16string text_;
    bool valid_ = false;
};

// (M4) The host classification at a word start (compartments, status, parent context)
// runs once per key: OnTestKeyDown evaluates, OnKeyDown of the same key (same key
// generation, same context) reuses it. A host that calls OnKeyDown without
// OnTestKeyDown always evaluates there; a cached result is used at most once.
class PerKeyOnce {
public:
    void noteTest(uint32_t keyGen, const void* ctx) {
        gen_ = keyGen;
        ctx_ = ctx;
        valid_ = true;
    }
    // OnKeyDown: true = skip, the OnTestKeyDown of this key already did it.
    bool takeForKeyDown(uint32_t keyGen, const void* ctx) {
        const bool hit = valid_ && keyGen == gen_ && ctx == ctx_;
        valid_ = false;
        return hit;
    }
    void invalidate() { valid_ = false; }

private:
    uint32_t gen_ = 0;
    const void* ctx_ = nullptr;
    bool valid_ = false;
};

// (1.3.36, Excel cell — debug log of 1.3.33) A key the TIP claimed in OnTestKeyDown stays the
// TIP's in OnKeyDown of that same key. The hook's handover ack (kDirectOnProp) arrives a
// millisecond after the request made at a word start in OnTestKeyDown; in an IMM32 host the
// OnKeyDown of that key comes as a separate message, AFTER the ack. The TIP then read "the
// hook types here" and let the key through, the hook (engaged mid-focus) waited for a word
// boundary: nobody typed that word ("khoong", "YKTDD" in a cell, mostly when typing fast).
// The claim is per key generation: the next key is decided afresh (by then the word is
// active here, or it never started).
class TestClaim {
public:
    void claimed(uint32_t keyGen) {
        gen_ = keyGen;
        valid_ = true;
    }
    void reset() { valid_ = false; }
    bool holds(uint32_t keyGen) const { return valid_ && gen_ == keyGen; }

private:
    uint32_t gen_ = 0;
    bool valid_ = false;
};

// (2026-11, Word's Navigation search box — focus class RICHEDIT60W, debug log of 1.3.18–
// 1.3.20) One key event offered to the TIP TWICE: a key the TIP lets through is handed to
// the keystroke manager again before the app inserts it (Word's message loop, then the
// RichEdit itself). The second offer saw the word without that letter ("the store shows none
// of the typed keys", "no longer ends with the word") and dropped it — every word of the
// search came out wrong ("ddaauf moois" -> "đâù môí"). Only a key that was already let
// through is a repeat: same wParam, lParam and message time (a new press or an auto-repeat
// is a new message; a key-up ends the press). A claimed key is never offered again.
class KeyEventRepeat {
public:
    struct Id {
        uint64_t wp = 0;
        uint64_t lp = 0;
        uint32_t time = 0;  // GetMessageTime
        bool operator==(const Id& o) const { return wp == o.wp && lp == o.lp && time == o.time; }
    };
    // OnTestKeyDown: true = this event was already let through (by OnTestKeyDown or OnKeyDown).
    bool atTest(const Id& id) const { return state_ != State::None && id == id_; }
    // OnKeyDown: true = OnKeyDown already let this event through. (OnKeyDown right after an
    // OnTestKeyDown that declined the key is the same offer: it runs as before.)
    bool atKeyDown(const Id& id) const { return state_ == State::KeyDownPassed && id == id_; }
    void begin(const Id& id) {
        id_ = id;
        state_ = State::None;
    }
    void testDeclined(const Id& id) {
        id_ = id;
        state_ = State::TestDeclined;
    }
    void keyDownDone(const Id& id, bool eaten) {
        id_ = id;
        state_ = eaten ? State::None : State::KeyDownPassed;
    }
    void keyUp(uint64_t wp) {
        if (wp == id_.wp) state_ = State::None;
    }
    void reset() { state_ = State::None; }

private:
    enum class State : uint8_t { None, TestDeclined, KeyDownPassed };
    Id id_;
    State state_ = State::None;
};

// (M1) The Việt/Anh state VietTelex.exe is told at a FOCUS change (AppCommand::
// StateChanged) only feeds the optional tray icon. Post only when the tray is on and the
// state or the focus root window differs from what this thread last told it — the app's
// own foreground hook covers switches between windows. A user switch always posts
// (UserSwitched) and is recorded with notePosted.
class FocusStateNotify {
public:
    bool shouldPost(bool trayOn, bool vietnamese, uintptr_t root) {
        if (!trayOn) {
            reset();
            return false;
        }
        const int8_t st = vietnamese ? 1 : 0;
        if (st == posted_ && root == root_) return false;
        posted_ = st;
        root_ = root;
        return true;
    }
    void notePosted(bool vietnamese, uintptr_t root) {
        posted_ = vietnamese ? 1 : 0;
        root_ = root;
    }
    void reset() {
        posted_ = -1;
        root_ = 0;
    }

private:
    int8_t posted_ = -1;  // -1 = nothing posted yet
    uintptr_t root_ = 0;
};

// (2026-11 audit) Can the app's hook reach this process (UIPI)? In a Direct field the TIP
// asked on EVERY key: FindWindow, OpenProcessToken on itself, OpenProcess + token on the app.
// This process's integrity never changes; the app's only with a new app process. Kept per
// focus, keyed by (app window, app pid): a restarted app is asked again.
class HookReachCache {
public:
    // True with `reaches` set when this (window, pid) was answered since the last reset.
    bool lookup(uintptr_t appWindow, uint32_t appPid, bool& reaches) const {
        if (!valid_ || appWindow != wnd_ || appPid != pid_) return false;
        reaches = reaches_;
        return true;
    }
    void store(uintptr_t appWindow, uint32_t appPid, bool reaches) {
        wnd_ = appWindow;
        pid_ = appPid;
        reaches_ = reaches;
        valid_ = true;
    }
    void reset() { valid_ = false; }

private:
    uintptr_t wnd_ = 0;
    uint32_t pid_ = 0;
    bool reaches_ = false;
    bool valid_ = false;
};

// (2026-11, Gmail's "#" = delete did nothing in V mode) A web page with no editable element
// focused: Chromium's store refuses the edit session, or has no caret, at a word start. A
// key the TIP claims there still reaches the page, but not as the genuine key event its
// single-key shortcuts listen to (Gmail # j k x, GitHub / Jira ? / [ ]). While a context is
// suspected, no key is claimed in it unless a read-only probe at a word start finds a caret
// again (the page focused a field inside the same document). Forgotten at a focus change and
// whenever the store reports an edit (it is alive). Context identity only: never
// dereferenced.
class NoEditableContext {
public:
    // A word start found no edit session / no caret in `ctx`.
    void note(const void* ctx) { ctx_ = ctx; }
    bool suspects(const void* ctx) const { return ctx_ != nullptr && ctx == ctx_; }
    // Word start in a suspected context, after the probe: true = claim keys there again.
    bool afterProbe(const void* ctx, bool caretFound) {
        if (!suspects(ctx)) return true;
        if (caretFound) ctx_ = nullptr;
        return caretFound;
    }
    void clear() { ctx_ = nullptr; }

private:
    const void* ctx_ = nullptr;
};

// (M1) Chế độ game is VietTelex.exe's runtime state (cleared at its start). If the app is
// gone (crashed, autostart off), a stale "on" in the snapshot must not leave every key
// passing through forever. `appRunning` is only asked when the snapshot says on.
template <class AppRunning>
inline bool effectiveGameMode(bool snapshotGameMode, AppRunning&& appRunning) {
    return snapshotGameMode && appRunning();
}

}  // namespace vtx
