/*
 * telexcore.h — C ABI of libtelexcore (the VietTelex TelexCore engine).
 *
 * One vt_engine per input context. Not thread-safe per handle (use a handle from one
 * thread at a time); distinct handles are independent. No allocation on the hot path:
 * results come back in caller-owned structs/buffers.
 *
 * String buffers (vt_peek, vt_composed, …) follow snprintf semantics: at most cap-1
 * bytes of UTF-8 plus a NUL are written, and the FULL byte length is returned, so a
 * return value >= cap means the output was truncated.
 */
#ifndef VIETTELEX_TELEXCORE_H
#define VIETTELEX_TELEXCORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VT_ABI_VERSION 2   /* 2: vt_retro.flip_back, VT_FLAG_ENGLISH_BY_FREQUENCY */

typedef struct vt_engine vt_engine;

/* TelexAction */
enum {
    VT_ACTION_PASSTHROUGH = 0, /* not handled: the caller/app inserts the key itself   */
    VT_ACTION_REPLACE = 1,     /* delete `backspaces` chars before the caret, insert … */
    VT_ACTION_NONE = 2         /* nothing to do                                         */
};

/* Longest possible insert: 32 composed scalars x 3 UTF-8 bytes = 96 (+NUL). */
#define VT_INSERT_CAP 128

typedef struct vt_action {
    int32_t kind;              /* VT_ACTION_*                                          */
    int32_t backspaces;        /* REPLACE only: characters (Unicode scalars) to delete */
    int32_t insert_len;        /* REPLACE only: bytes in `insert` (excluding NUL)      */
    char insert[VT_INSERT_CAP]; /* REPLACE only: UTF-8, NUL-terminated                 */
} vt_action;

/* Engine options (TelexEngine properties). Defaults are the ENGINE defaults, which
 * differ from the app defaults (see linux/common/SETTINGS.md): frontends set all. */
enum {
    VT_FLAG_FREE_MARKING = 0,                 /* default false */
    VT_FLAG_MODERN_TONE = 1,                  /* default false */
    VT_FLAG_LIVE_SPELL_CHECK = 2,             /* default false */
    VT_FLAG_SIMPLE_TELEX = 3,                 /* default false */
    VT_FLAG_TEENCODE = 4,                     /* default TRUE  */
    VT_FLAG_QUICK_TELEX = 5,                  /* default false */
    VT_FLAG_BRACKET_VOWELS = 6,               /* default false */
    VT_FLAG_VNI = 7,                          /* default false */
    VT_FLAG_CONTEXTUAL_ENGLISH = 8,           /* default false */
    VT_FLAG_ENGLISH_WORD_RESTORE = 9,         /* default TRUE  */
    VT_FLAG_COLLISION_PREFERS_VIETNAMESE = 10, /* default false */
    VT_FLAG_EAGER_ENGLISH_RESTORE = 11,       /* default false; frontends pass auto-restore */
    VT_FLAG_RETRO_ENGLISH = 12,               /* default false; EXPERIMENTAL retroactiveEnglish,
                                                 inert unless CONTEXTUAL_ENGLISH is on      */
    VT_FLAG_ENGLISH_BY_FREQUENCY = 13,        /* default false; EXPERIMENTAL englishByFrequency,
                                                 inert unless RETRO_ENGLISH is in effect    */
    VT_FLAG_AUTO_CIRCUMFLEX = 14              /* default false; autoCircumflex (issue #166):
                                                 vietj → việt when the plain rime is not a
                                                 syllable. Older libs ignore unknown flags. */
};

/* Lifecycle */
vt_engine *vt_engine_new(void);
void vt_engine_free(vt_engine *h);
int vt_abi_version(void);

/* Options; unknown flag ids are ignored / read false. */
void vt_engine_set_flag(vt_engine *h, int flag, bool on);
bool vt_engine_get_flag(const vt_engine *h, int flag);

/* Editing. `ch` is a Unicode scalar; non-composing characters return PASSTHROUGH
 * (route them through vt_commit first, as boundaries). */
void vt_feed(vt_engine *h, uint32_t ch, vt_action *out);
void vt_backspace(vt_engine *h, vt_action *out);
/* commitBoundary(autoRestore:) — resets the word; the caller inserts the boundary. */
void vt_commit(vt_engine *h, bool auto_restore, vt_action *out);
/* commitText(autoRestore:) — final text of the word (restore applied); resets. */
size_t vt_commit_text(vt_engine *h, bool auto_restore, char *buf, size_t cap);
/* peekCommitText(autoRestore:) — what vt_commit_text WOULD return; no state change. */
size_t vt_peek(const vt_engine *h, bool auto_restore, char *buf, size_t cap);
/* The same three with the character that ends the word (`ch`, a Unicode scalar; 0 =
 * unknown, identical to the calls above) — commitBoundary/commitText/peekCommitText
 * (autoRestore:boundary:). An apostrophe (' or U+2019) keeps an English contraction stem
 * typed right before it ("doesn" 't, "isn" 't, "there" 's) as typed. */
void vt_commit_before(vt_engine *h, bool auto_restore, uint32_t ch, vt_action *out);
size_t vt_commit_text_before(vt_engine *h, bool auto_restore, uint32_t ch, char *buf, size_t cap);
size_t vt_peek_before(const vt_engine *h, bool auto_restore, uint32_t ch, char *buf, size_t cap);

size_t vt_composed(const vt_engine *h, char *buf, size_t cap);
size_t vt_raw(const vt_engine *h, char *buf, size_t cap);

void vt_reset(vt_engine *h);          /* drop word + re-open snapshot              */
void vt_reset_context(vt_engine *h);  /* forget previous-word English context      */
void vt_forget_last_commit(vt_engine *h);

/* seed(word): rebuild state from on-screen text (re-edit). True if it round-trips. */
bool vt_seed(vt_engine *h, const char *utf8_word);
/* reopenLastCommit(): returns byte length of the reopened word written to buf, or -1
 * when there was nothing to reopen. */
long vt_reopen(vt_engine *h, char *buf, size_t cap);

bool vt_is_empty(const vt_engine *h);
bool vt_is_overflowed(const vt_engine *h);
bool vt_can_reopen(const vt_engine *h);
bool vt_previous_word_english(const vt_engine *h);

/* Caret suggestions (linux/common caret_hints): cheap word-boundary checks, no handle.
 * vt_is_valid_syllable: SyllableValidator.isValidSyllable (NFC UTF-8).
 * vt_is_unaccented_syllable: ToneRunLogic.isUnaccentedSyllable — a chunk (edge punctuation
 * allowed) that is an unaccented Vietnamese syllable in a–z ("toi", "hoc,", not "the"). */
bool vt_is_valid_syllable(const char *utf8_word, bool teencode);
bool vt_is_unaccented_syllable(const char *utf8_chunk);
/* vt_is_english_word: EnglishContextLookup.opensEnglishRun — the engine's English word list
 * (lowercase a–z, exact). Part of the helper's TypoFixLogic.isKnown: such a word never gets
 * a typo fix, so the frontend does not ask the helper. */
bool vt_is_english_word(const char *utf8_lower_word);

/* Opt-in "Gạch đỏ âm tiết sai chính tả khi gõ" (Settings::underlineMisspelled):
 * vt_has_spelling_error: TelexEngine.hasSpellingError(autoRestore:) — the word being
 * composed is Vietnamese the engine produced (not left as raw keys, not restored at the
 * boundary with this auto_restore) that no further letters can make a valid syllable
 * ("đc", "hópng", "tòc"). Ask only when the setting is on.
 * vt_is_spelling_error: SyllableValidator.isSpellingError on a word (NFC UTF-8). */
bool vt_has_spelling_error(const vt_engine *h, bool auto_restore);

/* Retroactive English correction (VT_FLAG_RETRO_ENGLISH; TelexEngine.retroactiveEnglish,
 * docs/DESIGN.md). Report EVERY boundary character the frontend inserts with
 * vt_note_boundary (spaces keep a phrase going, anything else starts a new one). Right
 * after each commit (before or after reporting its boundary char) call vt_take_retro:
 * true = `out` holds one edit — delete `backspaces` characters (Unicode scalars) before
 * the caret (they are exactly `expected`; skip if the surrounding text disagrees), then
 * insert `insert`. Any other engine call discards it. Caret moves / deletes into committed
 * text must go through vt_reset / vt_reset_context / vt_backspace as today. */
#define VT_RETRO_CAP 1024   /* bytes of UTF-8 incl. NUL (256 BMP chars x 3 + room) */
typedef struct vt_retro {
    int32_t backspaces;       /* characters (Unicode scalars) to delete */
    int32_t words;            /* words rewritten */
    int32_t expected_len;     /* bytes in `expected` (excluding NUL) */
    int32_t insert_len;       /* bytes in `insert` (excluding NUL) */
    char expected[VT_RETRO_CAP];
    char insert[VT_RETRO_CAP];
    /* RetroCorrection.flipBack (VT_FLAG_ENGLISH_BY_FREQUENCY): 1 = the edit puts a word the
     * frequency rule had turned English BACK to Vietnamese ("His hửng" -> "hí hửng"). It
     * undoes the engine's own guess: apply it AUTOMATICALLY even when retro edits are only
     * offered, and also when the boundary is Enter (before the Enter goes through) — after
     * the same surrounding-text check. */
    int32_t flip_back;
} vt_retro;
void vt_note_boundary(vt_engine *h, uint32_t ch);
bool vt_take_retro(vt_engine *h, vt_retro *out);

/* ⌫ right after a restore-to-English (TelexEngine.takeRestoreUndo / restoreUndoApplied).
 * vt_note_boundary is needed for EVERY boundary character even with retro English off:
 * the engine also uses it for glued separators ("my_var", "100W").
 * Right after a commit, vt_take_restore_undo: true = the commit restored `restored` (now on
 * screen, followed by the boundary char) although `vietnamese` was a real syllable. If the
 * very next key is ⌫ and the text before the caret is still restored + boundary, replace it
 * with vietnamese + boundary, then call vt_restore_undo_applied. Any other key drops it. */
#define VT_UNDO_CAP 160     /* bytes of UTF-8 incl. NUL (32 chars x 4 + room) */
typedef struct vt_restore_undo {
    int32_t restored_len;     /* bytes (excluding NUL) */
    int32_t vietnamese_len;
    char restored[VT_UNDO_CAP];
    char vietnamese[VT_UNDO_CAP];
} vt_restore_undo;
bool vt_take_restore_undo(vt_engine *h, vt_restore_undo *out);
void vt_restore_undo_applied(vt_engine *h);
bool vt_is_spelling_error(const char *utf8_word, bool teencode);

#ifdef __cplusplus
}
#endif

#endif /* VIETTELEX_TELEXCORE_H */
