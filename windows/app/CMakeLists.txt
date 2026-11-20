# windows/app — VietTelex.exe (Win32 tray + settings + updater + hook fallback) and its
# portable core (unit-tested on any OS).

add_library(vtx_app_core STATIC core/update_check.cpp core/uninstall.cpp core/setup_helper_logic.cpp core/direct_policy.cpp core/input_switch.cpp
            core/text_action_logic.cpp core/typo_fix.cpp core/word_prediction.cpp core/learned_words.cpp core/onboarding.cpp core/game_logic.cpp core/macro_import.cpp core/settings_pages.cpp
            core/app_feel.cpp core/portable.cpp core/hook_reopen.cpp core/word_adopt.cpp core/store_files.cpp core/switch_sound.cpp)
target_include_directories(vtx_app_core PUBLIC core)
target_link_libraries(vtx_app_core PUBLIC vtx_ime_core viettelex_text)
if(MSVC)
  # word_prediction.cpp / seed_unigrams.inc hold Vietnamese UTF-8 literals.
  target_compile_options(vtx_app_core PRIVATE /utf-8)
endif()

if(VTX_IME_TESTS)
  add_executable(vtx_app_tests ../ime/tests/test_main.cpp tests/app_tests.cpp tests/typo_fix_tests.cpp
                 tests/onboarding_game_tests.cpp tests/word_prediction_tests.cpp tests/settings_pages_tests.cpp
                 tests/app_feel_tests.cpp tests/hook_reopen_tests.cpp tests/word_adopt_tests.cpp tests/omnibox_direct_tests.cpp
                 tests/robustness_tests.cpp src/strings.cpp)  # strings.cpp: portable UI text
  target_include_directories(vtx_app_tests PRIVATE ../ime/tests src)
  target_link_libraries(vtx_app_tests PRIVATE vtx_app_core)
  target_compile_definitions(vtx_app_tests PRIVATE
                             VTX_KB_RESOURCES="${CMAKE_CURRENT_SOURCE_DIR}/../../iOS/Keyboard/Resources"
                             VTX_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/../../iOS/KeyboardTests/Fixtures"
                             VTX_APP_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
                             VTX_WXS_TEMPLATE="${CMAKE_CURRENT_SOURCE_DIR}/../installer/msi/viettelex.wxs.in"
                             VTX_DOCS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../docs")
  if(MSVC)
    target_compile_options(vtx_app_tests PRIVATE /utf-8)
  endif()
  add_test(NAME vtx_app_tests COMMAND vtx_app_tests)
  # Heap bytes of each language-data component + the start sequence per mode (budgets).
  add_executable(vtx_memory_report tests/memory_report.cpp)
  target_include_directories(vtx_memory_report PRIVATE src)
  target_link_libraries(vtx_memory_report PRIVATE vtx_app_core)
  target_compile_definitions(vtx_memory_report PRIVATE
                             VTX_KB_RESOURCES="${CMAKE_CURRENT_SOURCE_DIR}/../../iOS/Keyboard/Resources")
  if(MSVC)
    target_compile_options(vtx_memory_report PRIVATE /utf-8)
  endif()
  add_test(NAME memory_report COMMAND vtx_memory_report)
  # Portable zips (scripts/make-portable.sh, called by release.sh): needs bash + zip/unzip.
  find_program(VTX_BASH bash)
  find_program(VTX_ZIP zip)
  find_program(VTX_UNZIP unzip)
  if(VTX_BASH AND VTX_ZIP AND VTX_UNZIP AND NOT WIN32)
    add_test(NAME portable_zip_test
             COMMAND ${VTX_BASH} ${CMAKE_CURRENT_SOURCE_DIR}/tests/portable_zip_test.sh
                     ${CMAKE_CURRENT_SOURCE_DIR}/.. ${CMAKE_CURRENT_BINARY_DIR})
  endif()
endif()

if(WIN32)
  add_executable(VietTelex WIN32
    src/app_quit.cpp
    src/conflicts.cpp
    src/debug_context.cpp
    src/direct_verify.cpp
    ../ime/src/debug_file.cpp
    src/foreground.cpp
    src/game_mode.cpp
    src/hook_fallback.cpp
    ../ime/src/icons.cpp
    src/main.cpp
    src/settings_store.cpp
    src/settings_window.cpp
    src/strings.cpp
    src/switch_toast.cpp
    src/text_actions.cpp
    src/tip_control.cpp
    src/updater.cpp
    src/welcome.cpp
    res/VietTelex.rc)
  target_include_directories(VietTelex PRIVATE src ../ime/src)
  target_compile_definitions(VietTelex PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
                             _WIN32_WINNT=0x0A00 WINVER=0x0A00)
  # Pinned Authenticode publisher for the self-updater (src/updater.cpp). Empty = the
  # updater refuses every downloaded MSI (fail closed); release.sh always sets it.
  set(VTX_EXPECTED_PUBLISHER "" CACHE STRING "Expected signer CN of update MSIs (UTF-8)")
  if(NOT VTX_EXPECTED_PUBLISHER STREQUAL "")
    string(FIND "${VTX_EXPECTED_PUBLISHER}" "\"" _vtx_q)
    string(FIND "${VTX_EXPECTED_PUBLISHER}" "\\" _vtx_bs)
    if(NOT _vtx_q EQUAL -1 OR NOT _vtx_bs EQUAL -1)
      message(FATAL_ERROR "VTX_EXPECTED_PUBLISHER must not contain quotes or backslashes")
    endif()
    target_compile_definitions(VietTelex PRIVATE VTX_EXPECTED_PUBLISHER_UTF8="${VTX_EXPECTED_PUBLISHER}")
  else()
    message(STATUS "VTX_EXPECTED_PUBLISHER not set: this build's self-updater will refuse all MSIs")
  endif()
  target_link_libraries(VietTelex PRIVATE vtx_app_core comctl32 comdlg32 shell32 advapi32 user32 gdi32
                        dwmapi uxtheme winhttp wintrust crypt32 ole32 oleaut32 uuid gdiplus msi winmm)
  # MSI-only helper (Binary table): quit the app before files are replaced, move in-use
  # TIP DLLs aside. Tiny, windowless, no settings/engine code.
  add_executable(VietTelexSetupHelper WIN32 src/setup_helper.cpp src/app_quit.cpp)
  target_include_directories(VietTelexSetupHelper PRIVATE src)
  target_compile_definitions(VietTelexSetupHelper PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
                             _WIN32_WINNT=0x0A00 WINVER=0x0A00)
  target_link_libraries(VietTelexSetupHelper PRIVATE vtx_app_core shell32 user32)
  if(NOT MSVC)
    # no_demangle.cpp: keeps libc++abi's ~128 KB demangler out (see the file).
    target_sources(VietTelexSetupHelper PRIVATE ../ime/src/no_demangle.cpp)
    target_compile_options(VietTelexSetupHelper PRIVATE -Wall -Wextra -fno-exceptions -fno-rtti -Os)
    target_link_options(VietTelexSetupHelper PRIVATE -municode -static -static-libgcc -static-libstdc++
                        -Wl,--gc-sections -s)
  else()
    target_compile_options(VietTelexSetupHelper PRIVATE /W4 /permissive- /utf-8 /GR- /EHs-c- /D_HAS_EXCEPTIONS=0
                           /Gy /Gw)
    target_link_options(VietTelexSetupHelper PRIVATE /OPT:REF /OPT:ICF)
  endif()
  # DLLs only Settings (GDI+, DWM, MSI related-products, file picker) or the updater (WinHTTP,
  # Authenticode) call: loaded on first use, not at every start — a background start (autostart,
  # portable in the tray) never maps them (GitHub #153, memory). System DLLs, always present.
  set(VTX_APP_DELAYLOAD gdiplus.dll dwmapi.dll msi.dll comdlg32.dll winhttp.dll wintrust.dll crypt32.dll)
  if(MSVC)
    target_compile_options(VietTelex PRIVATE /W4 /permissive- /utf-8 /GR- /EHs-c- /D_HAS_EXCEPTIONS=0 /Gy /Gw)
    target_link_options(VietTelex PRIVATE /OPT:REF /OPT:ICF /MANIFEST:NO)
    foreach(dll ${VTX_APP_DELAYLOAD})
      target_link_options(VietTelex PRIVATE /DELAYLOAD:${dll})
    endforeach()
    target_link_libraries(VietTelex PRIVATE delayimp)
  else()
    target_sources(VietTelex PRIVATE ../ime/src/no_demangle.cpp)
    target_compile_options(VietTelex PRIVATE -Wall -Wextra -fno-exceptions -fno-rtti -Os)
    target_link_options(VietTelex PRIVATE -municode -static -static-libgcc -static-libstdc++ -Wl,--gc-sections -s)
    foreach(dll ${VTX_APP_DELAYLOAD})
      target_link_options(VietTelex PRIVATE -Wl,--delayload=${dll})
    endforeach()
  endif()
endif()
