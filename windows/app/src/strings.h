// strings.h — UI strings, Vietnamese (default) and English (settings `uiLanguage`).
// Setting titles/descriptions reuse the macOS wording (App/Resources/*.lproj).
#pragma once
#include <string>

namespace vtx::app {

enum class S {
    // tray / app
    AppName,
    TrayTip,
    MenuSettings,
    MenuCheckUpdate,
    MenuAbout,
    MenuHideTray,  // "Ẩn biểu tượng khay": hides the icon, the app keeps running
    // navigation / page titles
    TabTyping,
    TabSpelling,
    TabShortcuts,
    TabApps,
    TabAbout,
    // section headers
    SecInputStyle,
    SecSwitch,
    SecAppearance,
    SecSpelling,
    SecShortcuts,
    SecApps,
    SecUpdates,
    SecDiagnostics,
    SecUninstall,
    // settings: title + description
    InputMethod, InputMethodDesc,
    Telex, Vni,
    SimpleTelex, SimpleTelexDesc,
    FreeMarking, FreeMarkingDesc,
    QuickTelex, QuickTelexDesc,
    ModernOrthography, ModernOrthographyDesc,
    BracketVowels, BracketVowelsDesc,
    AutoRestore, AutoRestoreDesc,
    LiveSpellCheck, LiveSpellCheckDesc,
    ContextualEnglish, ContextualEnglishDesc,
    CollisionPrefersVi, CollisionPrefersViDesc,
    Teencode, TeencodeDesc,
    ReEditWord, ReEditWordDesc,
    SwitchHotkey, SwitchHotkeyDesc,
    HotkeyCtrlShift, HotkeyWinSpace, HotkeyAltZ, HotkeyOff,
    MenuIcon, MenuIconDesc,
    IconVt, IconStar, IconFlag, IconLogo, IconVi,
    ShowTray, ShowTrayDesc,
    UiLanguage, UiLanguageDesc,
    AutoUpdateCheck, AutoUpdateCheckDesc,
    DebugLogging, DebugLoggingDesc,
    CheckNow, CheckNowDesc, CheckButton,
    Uninstall, UninstallDesc, UninstallButton, UninstallConfirm,
    // lists
    ShortcutsDesc,
    ShortcutKey, ShortcutValue,
    Add, Remove, Import, Export,
    AppsDesc,
    AppExe, AppModeLabel,
    ModeComposition, ModeInPlace, ModeHook, ModeOff, ModeDirect,
    EmptyShortcuts, EmptyApps,
    // about
    AboutText,
    Version,
    LinkWebsite, LinkSource, LinkLearn,
    On, Off,
    // messages
    UpToDate,
    UpdateAvailable,
    UpdateFailed,
    UpdateBadSignature,
    UpdateDownloadFailed,  // + "open the download page?" (Yes/No)
    UpdateUnverified,      // signature not checkable (offline / proxy) + "open the download page?"
    UpdateBusy,            // "Kiểm tra cập nhật" while the update is downloading
    ImportFailed,
    ElevatedHookNotice,
    // 1.1.5: per-app Việt/Anh — who remembers depends on how you switch
    HotkeyNoteWinPerApp, HotkeyNoteWinGlobal, HotkeyNoteWinUnknown,
    PerAppWin, PerAppWinOn, PerAppWinOff, PerAppWinUnknown, PerAppEnableButton, PerAppOpenButton,
    // Công cụ văn bản (tray submenu, Thêm dấu hotkey)
    SecTextTools,
    TextToolsInMenu, TextToolsInMenuDesc,
    AddTonesHotkey, AddTonesHotkeyDesc,
    MenuTextTools,
    ToolAddTones, ToolUpper, ToolLower, ToolTitle, ToolSentence, ToolStrip,
    // Text tools summary (collapsed section); caret hints (macOS 1.8.2) follow in their
    // own "Gợi ý" section (SecHints)
    TextToolsSummary,
    MathResults, MathResultsDesc,
    NumberChips, NumberChipsDesc,
    TypoHints, TypoHintsDesc,
    ToneHints, ToneHintsDesc,
    DateHints, DateHintsDesc,
    FilterSensitive, FilterSensitiveDesc,
    // opt-in red squiggle on the composition (Chính tả page)
    UnderlineMisspelled, UnderlineMisspelledDesc,
    // Games / fullscreen, floating V/E indicator (Kiểu gõ page)
    SecGames,
    AutoOffFullscreen, AutoOffFullscreenDesc,
    GameMode, GameModeDesc,
    GameModeHotkey, GameModeHotkeyDesc,
    SwitchIndicator, SwitchIndicatorDesc, IndicatorAuto,
    ToastGameOn, ToastGameOff,
    // Other Vietnamese input methods (welcome window + Kiểu gõ page)
    ConflictTitle, ConflictDesc, ConflictButton,
    ConflictDlgIntro, ConflictOpenLocation, ConflictHowToQuit, ConflictQuitHelp,
    ConflictRemoveMs, ConflictRemoveMsNote, ConflictOpenLangSettings, ConflictRemoved, ConflictRemoveFailed,
    ConflictNone,
    // Welcome (first run)
    WelcomeTitle, WelcomeIntro, WelcomeMethod, WelcomeSwitch, WelcomeTray, WelcomeTrayNote,
    WelcomeImport, WelcomeDone, WelcomeOpenSettings,
    // Shortcut import from another input method (import result)
    ImportResult, ImportSkipped, ImportViqr,
    // Ctrl+Shift needs VietTelex active: make it Windows' default input method (Kiểu gõ page)
    DefaultInputTitle, DefaultInputDesc, DefaultInputButton,
    // Spelling page: caret hints section; how to reach Text tools with the tray icon off
    SecHints, TextToolsNoTray,
    // Tray menu: Chế độ game toggle
    MenuGameMode,
    // Học từ bạn gõ (Chính tả page, Gợi ý section, next to Lọc từ nhạy cảm)
    LearnWords, LearnWordsDesc, ClearLearned, ClearLearnedDesc, ClearLearnedButton, ClearLearnedConfirm,
    // Gợi ý chữ khi gõ (Chính tả page, Gợi ý section): word prediction follows Windows'
    // "Show text suggestions when typing on the physical keyboard" — state + a button to it
    TextPrediction, TextPredictionOn, TextPredictionOff, TextPredictionCaption, TextPredictionButton,
    // Tray icon style (Kiểu gõ page, Appearance) + the tray tooltip's state line
    TrayStyle, TrayStyleDesc, TrayStyleLetter, TrayStyleKeyboard, TrayStateVi, TrayStateEn,
    // Welcome: how to start typing; "make VietTelex the default keyboard" checkbox
    WelcomeHowTo, WelcomeDefaultInput,
    // Windows' own Ctrl+Shift hotkey (conflict card / dialog)
    WinHotkeyName, WinHotkeyDesc, WinHotkeyFix, WinHotkeyFixNote, WinHotkeyFixed, WinHotkeyFixFailed,
    // Tự sửa từ phía trước (Chính tả page, right under Quyết định theo ngữ cảnh, shown only
    // while that is on; experimental)
    RetroEnglish, RetroEnglishDesc,
    // Đoán từ trùng theo tần suất (right under Tự sửa từ phía trước, same condition; experimental)
    EnglishByFrequency, EnglishByFrequencyDesc,
    // Onboarding (docs/ONBOARDING-SPEC.md): welcome pages "Bạn thường gõ thế nào?" + "Gõ thử",
    // the "Gõ lẫn tiếng Anh" section, "start new apps in English", the one-time upgrade card
    WelcomeNext, WelcomeSkip,
    ProfileTitle, ProfileIntro, ProfileVi, ProfileViEx, ProfileMixed, ProfileMixedEx, ProfileEn, ProfileEnEx,
    TryTitle, TryIntro, TrySamplesVi, TrySamplesMixed, TrySamplesEn, TryTurnedOn, TryHint,
    SecMixed, StartEnglish, StartEnglishDesc,
    MixedCardTitle, MixedCardDesc, MixedCardButton,
    // Quick profile picker at the top of "Gõ lẫn tiếng Anh" (ONBOARDING-SPEC §4)
    ProfilePickerIntro, ProfileCustom, ProfileCustomDesc, ProfileInUse, ProfileUse, ProfileConfirmTitle,
    ProfileConfirmBody,
    // Settings cleanup (docs/SETTINGS-CLEANUP-SPEC.md): "Nâng cao" expanders + their summaries,
    // the shortcut import's file type and format names
    Advanced, TypingAdvancedSummary, MixedAdvancedSummary, SwitchAdvancedSummary, GamesSummary, AppearanceSummary,
    MixedVniNote,  // VNI: replaces the whole "Gõ lẫn tiếng Anh" group (one line)
    ImportFilterName, ImportFmtOther, ImportFmtText,
    // App feel (docs/WINDOWS-APP-FEEL-SPEC.md): tray Thoát / off state, minimal welcome,
    // the portable build
    MenuExit, MenuAutostart, TrayStateOff, TrayStatePortableOff, TrayTipPortable,
    ReadyTitle, ReadySwitchLine, ReadyPortableNote, ResolveOtherIme, ResolveWindowsKb,
    PortableInstalledRunning, PortableUpdateAvailable,
    // Portable (no TIP): the line instead of the "Gợi ý cạnh con trỏ" group, and the caption of
    // "Sửa dấu từ đã gõ" (the hook reopens a word by ⌫ only)
    PortableHintsNote, ReEditWordPortableDesc,
    // Welcome: one button removes Windows' built-in Vietnamese keyboard (field report 1.3.14)
    RemoveBuiltInButton, RemovedBuiltIn,
    // Portable (báo lỗi 1.3.17): run from inside the zip; tray click with only Vietnamese
    // keyboards in the list
    RunFromArchive, PortableNoOtherKeyboard,
    // #159: a plain start stays in the tray
    StartHidden, StartHiddenDesc,
    // A tone when the user switches Việt/Anh
    SwitchSound, SwitchSoundDesc,
    // Tự thêm dấu mũ (#166): vietj -> việt when the plain rime is not a syllable
    AutoCircumflex, AutoCircumflexDesc,
    Count
};

const wchar_t* tr(S id);
void setEnglish(bool en);

// "Gợi ý chữ khi gõ" card: the state line for Windows' physical-keyboard text suggestions
// (`on` = readSystemTextPrediction()), then the caption saying VietTelex follows it.
S textPredictionState(bool on);
std::wstring textPredictionDesc(bool on);

}  // namespace vtx::app
