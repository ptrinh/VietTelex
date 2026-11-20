#include "direct_verify.h"

#include <uiautomation.h>

#include <atomic>
#include <mutex>
#include <vector>

#include "app_policy.h"
#include "direct_policy.h"
#include "foreground.h"
#include "hook_fallback.h"

namespace vtx::app {

namespace {

struct Job {
    HWND fg = nullptr;
    DWORD tid = 0;
    std::u16string expected;
    uint64_t seq = 0;
};

std::mutex g_mu;
Job g_job;
bool g_pending = false;
bool g_focusChanged = false;
std::atomic<uint64_t> g_latestSeq{0};
HANDLE g_wake = nullptr;
HANDLE g_thread = nullptr;
std::atomic<bool> g_quit{false};

const char* g_path = "";

// While attached to the user's console, a Ctrl+C / Ctrl+Break typed there is delivered to
// THIS process too, and the default handler is ExitProcess: VietTelex.exe vanished. Ours
// says "handled" for those. (A console CLOSED during the few milliseconds we are attached
// still ends every attached process — Windows does not let a handler refuse that.)
BOOL WINAPI ignoreConsoleCtrl(DWORD type) {
    return type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT ? TRUE : FALSE;
}

Echo readConsole(HWND fg, const std::u16string& expected) {
    g_path = "console";
    static bool handlerSet = false;  // verifier thread only
    if (!handlerSet) handlerSet = SetConsoleCtrlHandler(ignoreConsoleCtrl, TRUE) != FALSE;
    if (!handlerSet) {  // never attach without it
        g_path = "console (no ctrl handler)";
        return Echo::Unverifiable;
    }
    DWORD pid = 0;
    GetWindowThreadProcessId(fg, &pid);
    if (!pid || !AttachConsole(pid)) {
        g_path = "console (AttachConsole failed)";
        return Echo::Unverifiable;
    }
    Echo result = Echo::Unverifiable;
    HANDLE out = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                             OPEN_EXISTING, 0, nullptr);
    if (out != INVALID_HANDLE_VALUE) {
        CONSOLE_SCREEN_BUFFER_INFO bi;
        if (GetConsoleScreenBufferInfo(out, &bi) && bi.dwCursorPosition.X > 0) {
            std::vector<wchar_t> row(static_cast<size_t>(bi.dwCursorPosition.X));
            DWORD got = 0;
            COORD from = {0, bi.dwCursorPosition.Y};
            if (ReadConsoleOutputCharacterW(out, row.data(), static_cast<DWORD>(row.size()), from, &got)) {
                std::u16string before(reinterpret_cast<const char16_t*>(row.data()), got);
                result = echoMatches(before, expected) ? Echo::Match : Echo::Mismatch;
            }
        }
        CloseHandle(out);
    }
    FreeConsole();
    return result;
}

IUIAutomation* uia() {
    static IUIAutomation* a = nullptr;
    static bool configured = false;
    if (!a && FAILED(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_IUIAutomation,
                                      reinterpret_cast<void**>(&a))))
        a = nullptr;
    if (a && !configured) {
        configured = true;
        // The defaults (20 s connection / 20 s transaction) would let one hung app park this
        // verify worker for 20 s. IUIAutomation2 (Windows 8+) lets us cap them; without it
        // (older UIA) the defaults stay — verification is best-effort anyway.
        IUIAutomation2* a2 = nullptr;
        if (SUCCEEDED(a->QueryInterface(IID_PPV_ARGS(&a2))) && a2) {
            a2->put_ConnectionTimeout(kUiaConnectionTimeoutMs);
            a2->put_TransactionTimeout(kUiaTransactionTimeoutMs);
            a2->Release();
        }
    }
    return a;
}

Echo readUia(HWND field, const std::u16string& expected) {
    g_path = "uia (no pattern)";
    IUIAutomation* a = uia();
    if (!a || !field) return Echo::Unverifiable;
    IUIAutomationElement* el = nullptr;
    if (FAILED(a->ElementFromHandle(field, &el)) || !el) return Echo::Unverifiable;
    Echo result = Echo::Unverifiable;
    IUIAutomationTextPattern* tp = nullptr;
    if (SUCCEEDED(el->GetCurrentPatternAs(UIA_TextPatternId, IID_IUIAutomationTextPattern,
                                          reinterpret_cast<void**>(&tp))) &&
        tp) {
        IUIAutomationTextRangeArray* sel = nullptr;
        int n = 0;
        if (SUCCEEDED(tp->GetSelection(&sel)) && sel && SUCCEEDED(sel->get_Length(&n)) && n > 0) {
            IUIAutomationTextRange* r = nullptr;
            if (SUCCEEDED(sel->GetElement(0, &r)) && r) {
                int moved = 0;
                r->MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character,
                                      -static_cast<int>(expected.size()), &moved);
                BSTR text = nullptr;
                if (SUCCEEDED(r->GetText(-1, &text)) && text) {
                    std::u16string before(reinterpret_cast<const char16_t*>(text), SysStringLen(text));
                    g_path = "uia TextPattern";
                    result = echoMatches(before, expected) ? Echo::Match : Echo::Mismatch;
                    SysFreeString(text);
                }
                r->Release();
            }
        }
        if (sel) sel->Release();
        tp->Release();
    }
    if (result == Echo::Unverifiable) {
        IUIAutomationValuePattern* vp = nullptr;
        if (SUCCEEDED(el->GetCurrentPatternAs(UIA_ValuePatternId, IID_IUIAutomationValuePattern,
                                              reinterpret_cast<void**>(&vp))) &&
            vp) {
            BSTR v = nullptr;
            if (SUCCEEDED(vp->get_CurrentValue(&v)) && v) {
                std::u16string value(reinterpret_cast<const char16_t*>(v), SysStringLen(v));
                g_path = "uia ValuePattern";
                if (!value.empty()) result = echoInValue(value, expected) ? Echo::Match : Echo::Mismatch;
                SysFreeString(v);
            }
            vp->Release();
        }
    }
    el->Release();
    return result;
}

DWORD WINAPI verifierMain(void*) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    EchoPolicy policy;
    std::vector<HWND> marked;
    while (!g_quit.load()) {
        WaitForSingleObject(g_wake, INFINITE);
        if (g_quit.load()) break;
        Sleep(80);  // let the host render; coalesce bursts (only the latest edit counts)
        Job job;
        bool focus = false;
        {
            std::lock_guard<std::mutex> lk(g_mu);
            if (g_focusChanged) {
                focus = true;
                g_focusChanged = false;
            }
            if (g_pending) {
                job = g_job;
                g_pending = false;
            }
        }
        if (focus) {  // "for the rest of the focus": a new focus starts clean
            policy.focusChanged();
            for (HWND w : marked) RemovePropW(w, kNoDirectProp);
            marked.clear();
        }
        if (!job.fg || !checkStillRelevant(job.seq, g_latestSeq.load())) continue;
        GUITHREADINFO gi = {};
        gi.cbSize = sizeof gi;
        HWND field = GetGUIThreadInfo(job.tid, &gi) ? gi.hwndFocus : nullptr;
        wchar_t cls[64] = {};
        GetClassNameW(job.fg, cls, 64);
        const Echo e = lstrcmpW(cls, L"ConsoleWindowClass") == 0 ? readConsole(job.fg, job.expected)
                                                                  : readUia(field ? field : job.fg, job.expected);
        const int control = field ? GetDlgCtrlID(field) : 0;
        if (appLogging())
            appLog("verify", std::string("echo ") +
                                 (e == Echo::Match ? "match" : e == Echo::Mismatch ? "MISMATCH" : "unverifiable") +
                                 " via " + g_path + ", class " + narrowAscii(cls) + ", word length " +
                                 std::to_string(job.expected.size()));
        if (policy.record(reinterpret_cast<uintptr_t>(field ? field : job.fg), control, e)) {
            HWND target = field ? field : job.fg;
            SetPropW(target, kNoDirectProp, reinterpret_cast<HANDLE>(1));
            marked.push_back(target);
            directLog("direct mode: 2 echo mismatches -> composition for this field");
            hookDisableCurrentField();
        }
    }
    CoUninitialize();
    return 0;
}

void ensureThread() {
    if (g_thread) return;
    g_wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_thread = CreateThread(nullptr, 0, verifierMain, nullptr, 0, nullptr);
    if (g_thread) SetThreadPriority(g_thread, THREAD_PRIORITY_BELOW_NORMAL);
}

}  // namespace

void directVerifyAfterEdit(HWND fg, DWORD tid, const std::u16string& expected, uint64_t seq) {
    ensureThread();
    g_latestSeq.store(seq);
    {
        std::lock_guard<std::mutex> lk(g_mu);
        g_job = Job{fg, tid, expected, seq};
        g_pending = true;
    }
    if (g_wake) SetEvent(g_wake);
}

void directVerifyFocusChanged() {
    if (!g_thread) return;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        g_focusChanged = true;
        g_pending = false;
    }
    SetEvent(g_wake);
}

void directVerifyShutdown() {
    if (!g_thread) return;
    g_quit.store(true);
    SetEvent(g_wake);
    WaitForSingleObject(g_thread, 2000);
    CloseHandle(g_thread);
    CloseHandle(g_wake);
    g_thread = g_wake = nullptr;
}

void directSetLogging(bool on) { appSetLogging(on); }

void directLog(const std::string& line) { appLog("direct", line); }

}  // namespace vtx::app
