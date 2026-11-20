// direct_verify.h — asynchronous echo verification for Direct mode (1.1.4).
//
// After an injected Direct edit the hook thread queues the expected word; a verifier
// thread (off the key path, ~80 ms later, only if no newer edit happened) reads what
// the host really shows before the caret:
//   * console windows (ConsoleWindowClass): AttachConsole(owner pid) +
//     GetConsoleScreenBufferInfo + ReadConsoleOutputCharacter on the cursor row;
//   * everything else: UI Automation — TextPattern (Windows Terminal, many apps) range
//     before the caret, else ValuePattern (Qt/Java/Adobe fields).
// Two mismatches in one field (focus hwnd + control id) -> that field is marked
// NoDirect (the TIP composes) and the hook stops for it. Unverifiable hosts keep
// Direct. See core/direct_policy.h for the pure rules.
#pragma once
#include <windows.h>

#include <cstdint>
#include <string>

namespace vtx::app {

void directVerifyAfterEdit(HWND foreground, DWORD guiThread, const std::u16string& expected, uint64_t seq);
void directVerifyFocusChanged();
void directVerifyShutdown();
void directSetLogging(bool on);
void directLog(const std::string& line);

}  // namespace vtx::app
