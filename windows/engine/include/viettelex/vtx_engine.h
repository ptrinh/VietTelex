/* VietTelex engine — C ABI. Port of TelexCore (Swift) TelexEngine; see API.md.
 * Pure C, no platform headers. UTF-16 text (uint16_t, same layout as WCHAR).
 * Thread-safety: one vtx_engine per thread/context; the library has no mutable globals. */
#ifndef VIETTELEX_VTX_ENGINE_H
#define VIETTELEX_VTX_ENGINE_H
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
    VTX_RETRO_ENGLISH       = 1u << 12,  /* retroactiveEnglish (EXPERIMENTAL, OFF; needs
                                            CONTEXTUAL_ENGLISH, inert without it)        */
    VTX_ENGLISH_BY_FREQUENCY= 1u << 13,  /* englishByFrequency (EXPERIMENTAL, OFF; inert
                                            unless RETRO_ENGLISH is in effect)           */
    VTX_AUTO_CIRCUMFLEX     = 1u << 14   /* autoCircumflex (OFF): vietj -> việt, benhj ->
                                            bệnh when the plain rime is not a syllable   */
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
/* Same, when the caller knows the character that ends the word (`boundary`, UTF-32; 0 =
   unknown = vtx_commit_boundary). An apostrophe (' or U+2019) restores an English
   contraction stem typed right before it ("doesn" 't, "isn" 't, "there" 's). */
void vtx_commit_boundary_before(vtx_engine* e, int auto_restore, uint32_t boundary, vtx_action* out);

/* Composition-mode commit: returns the final text (restore applied), resets word.
   Return value = length in UTF-16 units (buf is NUL-terminated; cap >= VTX_MAX_TEXT
   is always enough). */
int32_t vtx_commit_text(vtx_engine* e, int auto_restore, uint16_t* buf, int32_t cap);
/* vtx_commit_text with the word-ending character (see vtx_commit_boundary_before). */
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

/* Opt-in "underline misspelled syllables" (Swift TelexEngine.hasSpellingError): 1 when
   the word being composed is Vietnamese the engine produced (not left as raw keys, not
   restored at the boundary with this auto_restore) that no further letters can turn
   into a valid syllable ("đc", "hópng", "tòc"). Call only when the setting is on. */
int vtx_has_spelling_error(const vtx_engine* e, int auto_restore);

/* Retroactive English correction (VTX_RETRO_ENGLISH; Swift TelexEngine.retroactiveEnglish,
   docs/DESIGN.md). After inserting EVERY boundary character the caller reports it with
   vtx_note_boundary (spaces keep a phrase going, anything else starts a new one). Right
   after each commit (before or after reporting its boundary char) the caller asks
   vtx_take_retro_correction: 1 = `out` holds one edit to apply like a REPLACE action —
   delete `backspaces` UTF-16 units before the caret (they are exactly `expected`; skip the
   edit if the document disagrees), insert `insert`. Any other engine call discards it.
   Edits the engine cannot see (caret moves, deletes into committed text, paste, undo)
   must go through vtx_reset / vtx_reset_context / vtx_backspace as today, which drop the
   word history. */
#define VTX_RETRO_MAX 256          /* UTF-16 units incl. NUL */
typedef struct vtx_retro_correction {
    int32_t  backspaces;
    int32_t  words;                    /* words rewritten */
    int32_t  expected_len;             /* UTF-16 units */
    int32_t  insert_len;               /* UTF-16 units */
    uint16_t expected[VTX_RETRO_MAX];  /* NUL-terminated */
    uint16_t insert[VTX_RETRO_MAX];    /* NUL-terminated */
    int32_t  flip_back;                /* 1 = the edit puts a word VTX_ENGLISH_BY_FREQUENCY
                                          had turned English BACK to Vietnamese ("His hửng"
                                          -> "hí hửng"): apply it AUTOMATICALLY even when
                                          retro edits are only offered, and also when the
                                          boundary is Enter (apply BEFORE the Enter goes
                                          through) — after the same `expected` check. */
} vtx_retro_correction;
void vtx_note_boundary(vtx_engine* e, uint32_t ch);
int  vtx_take_retro_correction(vtx_engine* e, vtx_retro_correction* out);

/* Undo of a boundary restore-to-English (Swift TelexEngine.takeRestoreUndo). Report EVERY
   boundary character with vtx_note_boundary even with VTX_RETRO_ENGLISH off: the engine
   also uses it for glued separators ("my_var", "os.path", "100W"). Right after a commit,
   vtx_take_restore_undo = 1 when the commit restored a word to its raw keys although its
   Vietnamese composition was a real syllable ("hí" -> "his", "NÁ" -> "NAS"): the screen
   now shows `restored` + the boundary char; an IMMEDIATE ⌫ may replace that with
   `vietnamese` + the boundary char (verify the document first), then call
   vtx_restore_undo_applied. Any other engine call drops the record. */
#define VTX_UNDO_MAX 64            /* UTF-16 units incl. NUL */
typedef struct vtx_restore_undo {
    int32_t  restored_len;               /* UTF-16 units */
    int32_t  vietnamese_len;             /* UTF-16 units */
    uint16_t restored[VTX_UNDO_MAX];     /* NUL-terminated */
    uint16_t vietnamese[VTX_UNDO_MAX];   /* NUL-terminated */
} vtx_restore_undo;
int  vtx_take_restore_undo(vtx_engine* e, vtx_restore_undo* out);
void vtx_restore_undo_applied(vtx_engine* e);

#ifdef __cplusplus
}
#endif

#endif /* VIETTELEX_VTX_ENGINE_H */
