# VietTelex engine — C ABI (for the TSF TIP)

Status: **done** — port 1:1 of `TelexCore/Sources/TelexCore/TelexEngine.swift` (+ SyllableValidator,
Tables, EnglishCollisions, EnglishContextWords). Golden corpus 358,017/358,017 (100%), 727 ported
Swift assertions + invariants green; ~45 ns/keystroke with app defaults (target < 200 ns).

- Pure C++17, no Windows headers, no exceptions across the ABI, no RTTI needed.
- Build: static lib `viettelex_engine` (CMake target). Link it into the TIP DLL and
  include `viettelex/vtx_engine.h` (C) — or `viettelex/telex_engine.hpp` (C++ class).
- Text is **UTF-16** (`uint16_t`, same layout as `wchar_t`/`WCHAR` on Windows).
  Every character the engine emits is a precomposed (NFC) BMP code point, so
  **1 UTF-16 unit == 1 on-screen character** and `backspaces` counts units.
- Thread-safety: one engine per text context/thread; no globals mutated.
- Hot path (`vtx_feed`, `vtx_backspace`, `vtx_commit_boundary`) allocates nothing.

## Header (`include/viettelex/vtx_engine.h`)

```c
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct vtx_engine vtx_engine;          /* opaque */

/* Action kinds (mirror Swift TelexAction). */
enum {
    VTX_PASSTHROUGH = 0,   /* engine did not handle it: let the app insert the key  */
    VTX_REPLACE     = 1,   /* delete `backspaces` chars before caret, insert `insert` */
    VTX_NONE        = 2    /* nothing to do                                          */
};

#define VTX_MAX_TEXT 64    /* max UTF-16 units any engine string can have (+NUL fits) */

typedef struct vtx_action {
    int32_t  kind;                     /* VTX_PASSTHROUGH / VTX_REPLACE / VTX_NONE */
    int32_t  backspaces;               /* REPLACE only */
    int32_t  insert_len;               /* REPLACE only, UTF-16 units */
    uint16_t insert[VTX_MAX_TEXT];     /* REPLACE only, NUL-terminated */
} vtx_action;

/* Settings bitmask (names = Swift properties). */
enum {
    VTX_FREE_MARKING        = 1u << 0,   /* freeMarking            (app default ON)  */
    VTX_MODERN_TONE         = 1u << 1,   /* modernTone (hoà/thuý)  (app default OFF) */
    VTX_LIVE_SPELL_CHECK    = 1u << 2,   /* liveSpellCheck         (app default ON)  */
    VTX_SIMPLE_TELEX        = 1u << 3,   /* simpleTelex            (OFF) */
    VTX_TEENCODE            = 1u << 4,   /* teencode               (engine ON, app default OFF) */
    VTX_QUICK_TELEX         = 1u << 5,   /* quickTelex             (OFF) */
    VTX_BRACKET_VOWELS      = 1u << 6,   /* bracketVowels [ ] -> ơ ư (OFF) */
    VTX_VNI                 = 1u << 7,   /* vniMode                (OFF = Telex) */
    VTX_CONTEXTUAL_ENGLISH  = 1u << 8,   /* contextualEnglish      (app default ON) */
    VTX_ENGLISH_WORD_RESTORE= 1u << 9,   /* englishWordRestore     (ON; keep ON) */
    VTX_COLLISION_PREFERS_VI= 1u << 10,  /* collisionPrefersVietnamese (app default ON) */
    VTX_EAGER_ENGLISH_RESTORE=1u << 11,  /* eagerEnglishRestore (app: = autoRestore)    */
    VTX_RETRO_ENGLISH       = 1u << 12,  /* retroactiveEnglish (EXPERIMENTAL, OFF)          */
    VTX_ENGLISH_BY_FREQUENCY= 1u << 13,  /* englishByFrequency (EXPERIMENTAL, OFF)          */
    VTX_AUTO_CIRCUMFLEX     = 1u << 14   /* autoCircumflex (OFF)                            */
};
/* Engine defaults (== Swift TelexEngine()): TEENCODE | ENGLISH_WORD_RESTORE. */
#define VTX_ENGINE_DEFAULT_FLAGS (VTX_TEENCODE | VTX_ENGLISH_WORD_RESTORE)

vtx_engine* vtx_create(void);                    /* NULL on OOM */
vtx_engine* vtx_clone(const vtx_engine* e);      /* independent snapshot */
void        vtx_destroy(vtx_engine* e);

void     vtx_set_flags(vtx_engine* e, uint32_t flags);   /* safe mid-word */
uint32_t vtx_get_flags(const vtx_engine* e);

/* Keystrokes. `ch` is a UTF-32 code point (the typed character, case preserved).
   Only ASCII letters compose (+ digits in VNI, + [ ] { } with BRACKET_VOWELS);
   anything else returns VTX_PASSTHROUGH and the caller should treat it as a word
   boundary (call vtx_commit_boundary first, then insert the char itself). */
void vtx_feed(vtx_engine* e, uint32_t ch, vtx_action* out);
void vtx_backspace(vtx_engine* e, vtx_action* out);  /* PASSTHROUGH = let app delete */

/* Word boundary: applies auto-restore, resets the word. Caller inserts the boundary
   char afterwards. `auto_restore` = settings autoRestore (app default ON). */
void vtx_commit_boundary(vtx_engine* e, int auto_restore, vtx_action* out);
/* Same, with the character that ends the word (UTF-32; 0 = unknown). An apostrophe
   (' or U+2019) keeps an English contraction stem as typed ("doesn" 't, "there" 's). */
void vtx_commit_boundary_before(vtx_engine* e, int auto_restore, uint32_t boundary, vtx_action* out);

/* Composition-mode commit: returns the final text (restore applied), resets word.
   Return value = length in UTF-16 units (buf is NUL-terminated; cap >= VTX_MAX_TEXT
   is always enough). */
int32_t vtx_commit_text(vtx_engine* e, int auto_restore, uint16_t* buf, int32_t cap);
int32_t vtx_commit_text_before(vtx_engine* e, int auto_restore, uint32_t boundary, uint16_t* buf, int32_t cap);
/* Same text commit_text would produce, without changing any state. */
int32_t vtx_peek_commit_text(const vtx_engine* e, int auto_restore, uint16_t* buf, int32_t cap);

int32_t vtx_composed(const vtx_engine* e, uint16_t* buf, int32_t cap);       /* current word on screen */
int32_t vtx_raw_keystrokes(const vtx_engine* e, uint16_t* buf, int32_t cap); /* raw keys of word */
int     vtx_is_empty(const vtx_engine* e);
/* Word exceeded 32 keys: a PASSTHROUGH from feed/backspace then means "key NOT recorded,
   app renders/deletes natively" (Swift isOverflowed). */
int     vtx_is_overflowed(const vtx_engine* e);

void vtx_reset(vtx_engine* e);            /* drop current word (caret moved etc.) */
void vtx_reset_context(vtx_engine* e);    /* also forget English context (focus/app switch) */
int  vtx_previous_word_english(const vtx_engine* e);

/* Re-open: ⌫ right after a boundary. If vtx_can_reopen_last_commit(), the caller
   deletes the boundary char, calls vtx_reopen_last_commit(); on success (>= 0) the
   word (returned in buf) is back in the buffer and editable. -1 = nothing/ mismatch. */
int     vtx_can_reopen_last_commit(const vtx_engine* e);
int32_t vtx_reopen_last_commit(vtx_engine* e, uint16_t* buf, int32_t cap);
void    vtx_forget_last_commit(vtx_engine* e);  /* boundary char no longer what ⌫ deletes */

/* reEditWord: rebuild state from a word already on screen (read via ITfRange::GetText).
   Returns 1 only if the word round-trips exactly; else 0 and engine is reset. */
int vtx_seed(vtx_engine* e, const uint16_t* word, int32_t len);

/* Opt-in "underline misspelled syllables": 1 when the composed word is Vietnamese the
   engine produced (not raw keys, not restored at the boundary) that no further letters
   can turn into a valid syllable ("đc", "hópng", "tòc"). Call only when the setting is on. */
int vtx_has_spelling_error(const vtx_engine* e, int auto_restore);

#ifdef __cplusplus
}
#endif
```

## Typical TIP flow (composition mode)

```
key letter  -> vtx_feed; PASSTHROUGH on a non-word key => boundary
               REPLACE => in composition: SetText(range, vtx_composed()) (simplest), or
               in-place: ShiftStart(-backspaces) + SetText(insert)
               PASSTHROUGH for a word key (engine handled it as plain insert): append ch
backspace   -> vtx_backspace; PASSTHROUGH => let app delete (or if word empty +
               vtx_can_reopen_last_commit => delete boundary char + vtx_reopen_last_commit)
space/punct -> vtx_commit_text(auto) -> EndComposition with that text, then insert punct
               (in-place: vtx_commit_boundary -> apply REPLACE, then insert punct)
caret moved -> vtx_reset ; focus/app switch -> vtx_reset_context
```

Notes for the TIP:
- `vtx_feed` PASSTHROUGH has two meanings: a non-word key (caller does the boundary), or a
  word key the engine recorded but that needs no rewrite (plain insert — just let the key
  through / append it to the composition). Test the char class yourself (letters; digits in
  VNI; `[ ] { }` with BRACKET_VOWELS) or check `vtx_is_empty` / `vtx_composed` afterwards.
- Composition mode: after any feed/backspace simply `SetText(range, vtx_composed())`;
  the `backspaces/insert` diff is for in-place mode.
- Settings may be changed any time (`vtx_set_flags`), even mid-word — the engine replays.
- `vtx_create` is the only heap allocation (one `malloc`-sized object, ~1.3 KB); the object
  can be cloned (`vtx_clone`) for speculative peeks, but `vtx_peek_commit_text` is already
  non-mutating.

## Defaults (macOS 1.7.12 `App/Sources/AppState.swift`)

| Setting | App default | Flag |
|---|---|---|
| autoRestore (arg of commit calls) | ON | — |
| freeMarking | ON | `VTX_FREE_MARKING` |
| modernOrthography | OFF | `VTX_MODERN_TONE` |
| liveSpellCheck | ON | `VTX_LIVE_SPELL_CHECK` |
| simpleTelex | OFF | `VTX_SIMPLE_TELEX` |
| teencode | OFF (engine default ON) | `VTX_TEENCODE` |
| quickTelex | OFF | `VTX_QUICK_TELEX` |
| vniMode | OFF | `VTX_VNI` |
| bracketVowels | OFF | `VTX_BRACKET_VOWELS` |
| contextualEnglish | ON | `VTX_CONTEXTUAL_ENGLISH` |
| collisionPrefersVietnamese | ON | `VTX_COLLISION_PREFERS_VI` |
| eagerEnglishRestore | = autoRestore | `VTX_EAGER_ENGLISH_RESTORE` ("goog" not "gôg" mid-word; needs liveSpellCheck) |
| retroactiveEnglish | OFF (experimental; shown only when contextualEnglish is ON) | `VTX_RETRO_ENGLISH` (inert without `VTX_CONTEXTUAL_ENGLISH`; needs `vtx_note_boundary` after every boundary char + `vtx_take_retro_correction` after every commit — see docs/DESIGN.md "Sửa ngược tiếng Anh") |
| englishByFrequency | OFF (experimental; needs retroactiveEnglish in effect) | `VTX_ENGLISH_BY_FREQUENCY` (inert unless `VTX_RETRO_ENGLISH` is in effect). A sentence-initial word that is both a common English word and a rare Vietnamese syllable commits as English ("His car…"); when the next word shows the phrase is Vietnamese ("hí hửng", "hí hí") the engine hands back a retro edit with `flip_back = 1` that puts the Vietnamese word back. Integrators apply `flip_back` edits AUTOMATICALLY — even when retro edits are only offered (chip mode) and also when the boundary is Enter (apply before the Enter goes through) — after the same `expected` check |
| autoCircumflex | OFF ("Tự thêm dấu mũ") | `VTX_AUTO_CIRCUMFLEX`. Render-only: once the word has a live tone and the plain rime is not a Vietnamese syllable while the circumflexed one is, the circumflex is shown ("vietj" -> việt, "nguyenx" -> nguyễn, "benhj" -> bệnh, "hues" -> huế, "luanj" -> luận; "quanr" -> quản stays). Parse state is untouched; keys with an English reading still restore at the boundary |
| englishWordRestore | ON (not user-facing) | `VTX_ENGLISH_WORD_RESTORE` |

App defaults as one mask:
`VTX_FREE_MARKING | VTX_LIVE_SPELL_CHECK | VTX_CONTEXTUAL_ENGLISH | VTX_COLLISION_PREFERS_VI | VTX_ENGLISH_WORD_RESTORE`.
Boundary contract (all builds, retro on or off): report EVERY boundary character with
`vtx_note_boundary` right after the commit — the engine uses it for glued separators
(`my_var`, `self.bar`, `100W` keep their raw keys). After each commit `vtx_take_restore_undo`
returns the ⌫-undo record of a restore-to-English whose Vietnamese reading was a real
syllable (`NAS` ← `NÁ`, `is` ← `í` in an English run): a ⌫ as the very next key may replace
`restored` + boundary with `vietnamese` + boundary (verify the document first), then call
`vtx_restore_undo_applied`. The TIP does this in `TypingSession::armRestoreUndo` /
`tryRetroUndo` (same one-key slot as the retro undo).

Not in the engine (TIP/app layer, as on macOS): shortcuts (gõ tắt), reEditWord policy
(use `vtx_seed`), per-app modes, hotkey.

## Build / test

```
cmake -S windows/engine -B build && cmake --build build && ctest --test-dir build
./build/vtx_bench
```
- Targets: `viettelex_engine` (static lib), `vtx_tests` (golden + ported + invariants,
  incl. a global `operator new` counter proving 0 allocations on feed/backspace/commit/peek),
  `vtx_c_smoke` (C ABI, compiled as C), `vtx_bench`.
- Golden corpus: `android/telexcore/src/test/resources/golden.tsv.gz` (read via zlib; without
  zlib pass a decompressed `.tsv`: `vtx_tests golden golden.tsv`). Regenerate with
  `swift run gen-golden` in `TelexCore/` after any Swift engine change.
- Generated sources (do not edit, regenerate): `src/generated_tables.hpp`
  (`tools/gen_tables.py`: validator tries + English word sets from the Swift sources, all
  `constexpr` data in .rdata) and `tests/ported_cases.inc` (`tools/port_tests.py`, from the
  Swift-derived `SwiftPortedTests.kt`).
- Verified: Apple clang (C++17 and C++20 `-Werror`), GCC 12, mingw-w64 (x86_64, C++20,
  `-Werror`) with the Windows binaries passing golden/unit/C tests under Wine. MSVC flags set
  in CMake (`/W4 /permissive- /utf-8 /GR- /EHs-c-`) but not yet built on MSVC.
