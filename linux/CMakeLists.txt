# VietTelex for Linux — engine (libtelexcore, Swift → C ABI), shared frontend logic,
# Fcitx5 addon and IBus engine. See docs/LINUX-SPEC.md.
#
#   cmake -S linux -B build -DCMAKE_INSTALL_PREFIX=/usr && cmake --build build && ctest --test-dir build
#
# libtelexcore is built by SwiftPM (swift toolchain on PATH) unless VT_CORE_LIB points at a
# prebuilt libtelexcore.so.
cmake_minimum_required(VERSION 3.16)
project(viettelex-linux VERSION 1.0.30 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
include(GNUInstallDirs)

option(VT_BUILD_FCITX5 "Build the Fcitx5 addon" ON)
option(VT_BUILD_IBUS "Build the IBus engine" ON)
option(VT_BUILD_TESTS "Build unit tests + golden corpus replay" ON)
set(VT_CORE_LIB "" CACHE FILEPATH "Prebuilt libtelexcore.so (empty = build with SwiftPM)")
# viettelex-text-tool: text tools for the selection (Thêm dấu, HOA…), a child process of the
# frontends. Built by the same SwiftPM package; with a prebuilt VT_CORE_LIB it is looked
# for next to it unless VT_TEXT_TOOL points at it.
option(VT_BUILD_TEXT_TOOL "Install viettelex-text-tool + its data (vnlexicon/vnlm/enlexicon)" ON)
set(VT_TEXT_TOOL "" CACHE FILEPATH "Prebuilt viettelex-text-tool (empty = SwiftPM build / next to VT_CORE_LIB)")

# Private library dir: libtelexcore is an implementation detail of the two frontends.
set(VT_PRIVATE_LIBDIR "${CMAKE_INSTALL_LIBDIR}/viettelex")
set(VT_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")

# ---- libtelexcore -----------------------------------------------------------------
if(NOT VT_CORE_LIB)
  find_program(SWIFT_EXECUTABLE swift REQUIRED)
  set(VT_SWIFT_SCRATCH "${CMAKE_BINARY_DIR}/swift")
  set(VT_CORE_LIB "${VT_SWIFT_SCRATCH}/release/libtelexcore.so")
  if(NOT VT_TEXT_TOOL)
    set(VT_TEXT_TOOL "${VT_SWIFT_SCRATCH}/release/viettelex-text-tool")
  endif()
  file(GLOB VT_ENGINE_SOURCES CONFIGURE_DEPENDS
       "${VT_REPO_ROOT}/TelexCore/Sources/TelexCore/*.swift"
       "${CMAKE_CURRENT_SOURCE_DIR}/engine-capi/Sources/TelexCoreC/*.swift"
       "${CMAKE_CURRENT_SOURCE_DIR}/engine-capi/Sources/TextToolCLI/*.swift")
  # viettelex-text-tool links FoundationEssentials statically. The default SwiftPM backend
  # (swiftbuild, Swift ≥ 6.3) only autolinks the directly imported module, not the static
  # archives it depends on → name them (a group: they reference each other). Archives only
  # contribute the members something needs, so libtelexcore is unaffected.
  set(VT_SWIFT_STATIC_LINK "")
  get_filename_component(_vt_swift_real "${SWIFT_EXECUTABLE}" REALPATH)
  get_filename_component(_vt_swift_bin "${_vt_swift_real}" DIRECTORY)
  if(EXISTS "${_vt_swift_bin}/../lib/swift_static/linux/lib_FoundationCollections.a")
    foreach(_vt_l IN ITEMS FoundationEssentials _FoundationCollections _FoundationCShims swiftSynchronization)
      if(EXISTS "${_vt_swift_bin}/../lib/swift_static/linux/lib${_vt_l}.a")
        list(APPEND VT_SWIFT_STATIC_LINK -Xlinker "-l${_vt_l}")
      endif()
    endforeach()
    set(VT_SWIFT_STATIC_LINK -Xlinker --start-group ${VT_SWIFT_STATIC_LINK} -Xlinker --end-group)
  endif()
  add_custom_command(
    OUTPUT "${VT_CORE_LIB}" "${VT_SWIFT_SCRATCH}/release/viettelex-text-tool"
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/engine-capi/scripts/check-engine-links.sh"
    COMMAND "${SWIFT_EXECUTABLE}" build -c release --static-swift-stdlib ${VT_SWIFT_STATIC_LINK}
            --package-path "${CMAKE_CURRENT_SOURCE_DIR}/engine-capi"
            --scratch-path "${VT_SWIFT_SCRATCH}"
    DEPENDS ${VT_ENGINE_SOURCES} "${CMAKE_CURRENT_SOURCE_DIR}/engine-capi/Package.swift"
            "${CMAKE_CURRENT_SOURCE_DIR}/engine-capi/exports.map" "${VT_REPO_ROOT}/TelexCore/Package.swift"
    COMMENT "Building libtelexcore + viettelex-text-tool (SwiftPM, static Swift stdlib)"
    VERBATIM)
  add_custom_target(telexcore_swift ALL DEPENDS "${VT_CORE_LIB}")
endif()

add_library(telexcore SHARED IMPORTED GLOBAL)
set_target_properties(telexcore PROPERTIES
  IMPORTED_LOCATION "${VT_CORE_LIB}"
  IMPORTED_SONAME "libtelexcore.so"
  INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/engine-capi/include")
if(TARGET telexcore_swift)
  add_dependencies(telexcore telexcore_swift)
endif()
install(FILES "${VT_CORE_LIB}" DESTINATION "${VT_PRIVATE_LIBDIR}")

# ---- viettelex-text-tool + data -------------------------------------------------------
if(NOT VT_TEXT_TOOL)
  get_filename_component(_vt_core_dir "${VT_CORE_LIB}" DIRECTORY)
  if(EXISTS "${_vt_core_dir}/viettelex-text-tool")
    set(VT_TEXT_TOOL "${_vt_core_dir}/viettelex-text-tool")
  endif()
endif()
set(VT_TEXT_TOOL_INSTALLED "${CMAKE_INSTALL_FULL_LIBDIR}/viettelex/viettelex-text-tool")
set(VT_TEXT_DATA_SRC "${VT_REPO_ROOT}/iOS/Keyboard/Resources")
if(VT_BUILD_TEXT_TOOL AND VT_TEXT_TOOL)
  install(PROGRAMS "${VT_TEXT_TOOL}" DESTINATION "${VT_PRIVATE_LIBDIR}")
  install(FILES "${VT_TEXT_DATA_SRC}/vnlexicon.bin" "${VT_TEXT_DATA_SRC}/vnlm.bin" "${VT_TEXT_DATA_SRC}/enlexicon.bin"
          DESTINATION "${CMAKE_INSTALL_DATADIR}/viettelex")
elseif(VT_BUILD_TEXT_TOOL)
  message(WARNING "viettelex-text-tool not found (set VT_TEXT_TOOL): text tools will be hidden")
endif()

# Frontends find libtelexcore in the private dir (and next to themselves in the build tree).
set(CMAKE_INSTALL_RPATH "${CMAKE_INSTALL_FULL_LIBDIR}/viettelex")
set(CMAKE_BUILD_RPATH "${CMAKE_BINARY_DIR}/swift/release;${CMAKE_BINARY_DIR}")

# ---- shared frontend logic ----------------------------------------------------------
# GIO: GNOME Wayland focused-app monitor (common/src/gnome_monitor.cpp).
find_package(PkgConfig REQUIRED)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0>=2.56)
find_package(Threads REQUIRED)
add_library(viettelex-common STATIC
  common/src/session.cpp
  common/src/settings.cpp
  common/src/app.cpp
  common/src/watcher.cpp
  common/src/gnome.cpp
  common/src/gnome_monitor.cpp
  common/src/text_tools.cpp
  common/src/caret_hints.cpp
  common/src/retro_english.cpp
  common/src/auto_text.cpp
  common/src/debug_log.cpp
  common/src/switch_sound.cpp
  common/src/dead_keys.cpp)
target_include_directories(viettelex-common PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/common/include")
target_compile_definitions(viettelex-common PRIVATE VT_TEXT_TOOL_PATH="${VT_TEXT_TOOL_INSTALLED}")
# dead_keys.cpp dlopen()s libxkbcommon for the locale Compose table (no build dependency).
target_link_libraries(viettelex-common PUBLIC telexcore PkgConfig::GIO Threads::Threads ${CMAKE_DL_LIBS})
target_compile_options(viettelex-common PRIVATE -Wall -Wextra)

if(VT_BUILD_TESTS)
  enable_testing()
endif()
if(VT_BUILD_FCITX5)
  add_subdirectory(fcitx5)
endif()
if(VT_BUILD_IBUS)
  add_subdirectory(ibus)
endif()

if(VT_BUILD_TESTS)
  add_executable(golden_replay engine-capi/tests/golden_replay.cpp)
  target_link_libraries(golden_replay PRIVATE telexcore)
  add_test(NAME golden_corpus
           COMMAND sh -c "gzip -dc '${VT_REPO_ROOT}/android/telexcore/src/test/resources/golden.tsv.gz' | '$<TARGET_FILE:golden_replay>'")
  add_test(NAME engine_links COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/engine-capi/scripts/check-engine-links.sh")

  add_executable(test_common common/tests/test_common.cpp)
  target_link_libraries(test_common PRIVATE viettelex-common)
  target_compile_definitions(test_common PRIVATE VT_SOURCE_ROOT="${VT_REPO_ROOT}")
  add_test(NAME common COMMAND test_common)
  # Caret suggestions, IM side (caret_hints.h + Session) + HintService against the real
  # `viettelex-text-tool --serve` when it is built.
  add_executable(test_caret_hints common/tests/test_caret_hints.cpp)
  target_link_libraries(test_caret_hints PRIVATE viettelex-common)
  add_test(NAME caret_hints COMMAND test_caret_hints)
  # Auto text (auto_text.h + Session): double-space period, sentence capitals, smart quotes /
  # dashes, word prediction — macOS SystemAutoTextTests / WordPredictionTests cases.
  add_executable(test_auto_text common/tests/test_auto_text.cpp)
  target_link_libraries(test_auto_text PRIVATE viettelex-common)
  add_test(NAME auto_text COMMAND test_auto_text)
  # VIETTELEX_DEBUG log: header lines, settings snapshot, ×N collapse, no typed text.
  add_executable(test_debug_log common/tests/test_debug_log.cpp)
  target_link_libraries(test_debug_log PRIVATE viettelex-common)
  add_test(NAME debug_log COMMAND test_debug_log)
  # Dead keys / Compose key (#161): built-in table + the locale Compose table when present.
  add_executable(test_dead_keys common/tests/test_dead_keys.cpp)
  target_link_libraries(test_dead_keys PRIVATE viettelex-common)
  add_test(NAME dead_keys COMMAND test_dead_keys)
  add_executable(test_switch_sound common/tests/test_switch_sound.cpp)
  target_link_libraries(test_switch_sound PRIVATE viettelex-common)
  add_test(NAME switch_sound COMMAND test_switch_sound)
  if(VT_TEXT_TOOL)
    # test_common also runs the real helper end to end (runTextTool / TextToolRunner).
    set_tests_properties(common PROPERTIES ENVIRONMENT
      "VIETTELEX_TEXT_TOOL=${VT_TEXT_TOOL};VIETTELEX_DATA_DIR=${VT_TEXT_DATA_SRC}")
    # Shared iOS/Android fixtures, byte for byte, through the Linux build of the Swift sources.
    add_test(NAME text_tool_fixtures
             COMMAND "${VT_TEXT_TOOL}" --check-fixtures
                     "${VT_REPO_ROOT}/iOS/KeyboardTests/Fixtures/text-tools.txt"
                     "${VT_REPO_ROOT}/iOS/KeyboardTests/Fixtures/add-tones.txt")
    set_tests_properties(text_tool_fixtures PROPERTIES ENVIRONMENT "VIETTELEX_DATA_DIR=${VT_TEXT_DATA_SRC}")
    set_tests_properties(caret_hints PROPERTIES ENVIRONMENT
      "VIETTELEX_TEXT_TOOL=${VT_TEXT_TOOL};VIETTELEX_DATA_DIR=${VT_TEXT_DATA_SRC}")
    set_tests_properties(auto_text PROPERTIES ENVIRONMENT
      "VIETTELEX_TEXT_TOOL=${VT_TEXT_TOOL};VIETTELEX_DATA_DIR=${VT_TEXT_DATA_SRC}")
    # Caret suggestion logic (Swift, CaretSuggest.swift + Serve.swift): the macOS
    # CaretSuggestionsTests / MathHintTests cases + shared math/number fixtures.
    add_test(NAME caret_suggest
             COMMAND "${VT_TEXT_TOOL}" --self-test "${VT_REPO_ROOT}/iOS/KeyboardTests/Fixtures")
    set_tests_properties(caret_suggest PROPERTIES ENVIRONMENT "VIETTELEX_DATA_DIR=${VT_TEXT_DATA_SRC}")
  endif()


  # GnomeAppMonitor against a real dbus-daemon with a fake gnome-shell + portal
  # (BecomeMonitor, sender allow-list, pending/overview). Needs dbus-daemon.
  add_executable(test_gnome_monitor common/tests/test_gnome_monitor.cpp)
  target_link_libraries(test_gnome_monitor PRIVATE viettelex-common)
  find_program(VT_DBUS_RUN_SESSION_COMMON dbus-run-session)
  if(VT_DBUS_RUN_SESSION_COMMON)
    add_test(NAME gnome_monitor COMMAND "${VT_DBUS_RUN_SESSION_COMMON}" -- "$<TARGET_FILE:test_gnome_monitor>")
    set_tests_properties(gnome_monitor PROPERTIES TIMEOUT 60 SKIP_RETURN_CODE 77)
  endif()
endif()
