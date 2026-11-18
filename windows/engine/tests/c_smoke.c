/* C ABI smoke test: compiles as C, drives the engine like the TIP would. */
#include <stdio.h>
#include <string.h>
#include "viettelex/vtx_engine.h"

static int fails = 0;
#define EXPECT(c) do { if (!(c)) { ++fails; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

static int eq16(const uint16_t* a, int n, const char* ascii_or_null, const uint16_t* w, int wn) {
    int i;
    if (ascii_or_null) { if ((int)strlen(ascii_or_null) != n) return 0; for (i = 0; i < n; ++i) if (a[i] != (uint16_t)ascii_or_null[i]) return 0; return 1; }
    if (n != wn) return 0;
    for (i = 0; i < n; ++i) if (a[i] != w[i]) return 0;
    return 1;
}

int main(void) {
    vtx_engine* e = vtx_create();
    vtx_engine* c;
    vtx_action a;
    uint16_t buf[VTX_MAX_TEXT];
    int32_t n;
    const char* keys = "vieetj";
    const uint16_t viet[] = {'v', 'i', 0x1EC7, 't'};      /* việt */
    const uint16_t thay[] = {'t', 'h', 0x1EA5, 'y'};      /* thấy */
    size_t i;

    EXPECT(e != NULL);
    EXPECT(vtx_get_flags(e) == VTX_ENGINE_DEFAULT_FLAGS);
    vtx_set_flags(e, VTX_FREE_MARKING | VTX_LIVE_SPELL_CHECK | VTX_CONTEXTUAL_ENGLISH |
                     VTX_COLLISION_PREFERS_VI | VTX_ENGLISH_WORD_RESTORE);
    EXPECT(vtx_get_flags(e) == (VTX_FREE_MARKING | VTX_LIVE_SPELL_CHECK | VTX_CONTEXTUAL_ENGLISH |
                                VTX_COLLISION_PREFERS_VI | VTX_ENGLISH_WORD_RESTORE));
    for (i = 0; i < strlen(keys); ++i) vtx_feed(e, (uint32_t)keys[i], &a);
    n = vtx_composed(e, buf, VTX_MAX_TEXT);
    EXPECT(eq16(buf, n, NULL, viet, 4));
    EXPECT(a.kind == VTX_REPLACE && a.backspaces == 2 && a.insert_len == 2 && a.insert[0] == 0x1EC7);

    c = vtx_clone(e);
    n = vtx_peek_commit_text(e, 1, buf, VTX_MAX_TEXT);
    EXPECT(eq16(buf, n, NULL, viet, 4));
    n = vtx_commit_text(c, 1, buf, VTX_MAX_TEXT);
    EXPECT(eq16(buf, n, NULL, viet, 4));
    EXPECT(vtx_is_empty(c));
    vtx_destroy(c);

    vtx_commit_boundary(e, 1, &a);
    EXPECT(a.kind == VTX_NONE);
    EXPECT(vtx_can_reopen_last_commit(e));
    n = vtx_reopen_last_commit(e, buf, VTX_MAX_TEXT);
    EXPECT(eq16(buf, n, NULL, viet, 4));
    vtx_reset(e);

    /* auto-restore: "google" -> boundary rewrites back to raw */
    for (i = 0; i < 6; ++i) vtx_feed(e, (uint32_t)"google"[i], &a);
    vtx_commit_boundary(e, 1, &a);
    EXPECT(a.kind == VTX_NONE || a.kind == VTX_REPLACE);
    vtx_backspace(e, &a);
    EXPECT(a.kind == VTX_PASSTHROUGH);

    EXPECT(vtx_seed(e, thay, 4) == 1);
    n = vtx_raw_keystrokes(e, buf, VTX_MAX_TEXT);
    EXPECT(eq16(buf, n, "thaays", NULL, 0));
    vtx_feed(e, 0x00E9, &a);
    EXPECT(a.kind == VTX_PASSTHROUGH);
    EXPECT(!vtx_is_overflowed(e));
    vtx_reset_context(e);
    EXPECT(!vtx_previous_word_english(e));

    /* opt-in red underline: "đc" is flagged, "việt" and an empty word are not */
    vtx_reset(e);
    EXPECT(!vtx_has_spelling_error(e, 1));
    for (i = 0; i < 3; ++i) vtx_feed(e, (uint32_t)"ddc"[i], &a);
    EXPECT(vtx_has_spelling_error(e, 1));
    vtx_reset(e);
    for (i = 0; i < strlen(keys); ++i) vtx_feed(e, (uint32_t)keys[i], &a);
    EXPECT(!vtx_has_spelling_error(e, 1));
    EXPECT(!vtx_has_spelling_error(NULL, 1));
    vtx_destroy(e);

    /* retroactive English: "His car is very " -> one edit back to the raw keys ("very" is a
       strong English word: it completes the run on its own) */
    {
        static const char* words[] = {"His", "car", "is", "very"};
        const uint16_t want[] = {0xED, ' ', 'c', 0x1EA3, ' ', 0xED, ' ', 'v', 'e', 'r', 'y', ' '};
        vtx_retro_correction r;
        int w, got = 0;
        e = vtx_create();
        vtx_set_flags(e, VTX_FREE_MARKING | VTX_LIVE_SPELL_CHECK | VTX_CONTEXTUAL_ENGLISH |
                         VTX_COLLISION_PREFERS_VI | VTX_ENGLISH_WORD_RESTORE | VTX_EAGER_ENGLISH_RESTORE |
                         VTX_RETRO_ENGLISH);
        EXPECT((vtx_get_flags(e) & VTX_RETRO_ENGLISH) != 0);
        EXPECT((vtx_get_flags(e) & VTX_ENGLISH_BY_FREQUENCY) == 0);
        for (w = 0; w < 4; ++w) {
            for (i = 0; i < strlen(words[w]); ++i) vtx_feed(e, (uint32_t)words[w][i], &a);
            vtx_commit_boundary(e, 1, &a);
            vtx_note_boundary(e, ' ');
            got = vtx_take_retro_correction(e, &r);
            EXPECT(got == (w == 3));
        }
        EXPECT(got && r.backspaces == 12 && r.words == 3 && r.flip_back == 0);
        EXPECT(eq16(r.expected, r.expected_len, NULL, want, 12));
        EXPECT(eq16(r.insert, r.insert_len, "is car is very ", NULL, 0));
        EXPECT(!vtx_take_retro_correction(e, &r));
        vtx_destroy(e);
    }
    /* englishByFrequency: "His " commits as English, "hửng " flips it back (flip_back = 1) */
    {
        static const char* words[] = {"His", "huwngr"};
        const uint16_t want[] = {'i', 's', ' ', 'h', 0x1EED, 'n', 'g', ' '};
        const uint16_t ins[] = {0xED, ' ', 'h', 0x1EED, 'n', 'g', ' '};
        vtx_retro_correction r;
        int w, got = 0;
        e = vtx_create();
        vtx_set_flags(e, VTX_FREE_MARKING | VTX_LIVE_SPELL_CHECK | VTX_CONTEXTUAL_ENGLISH |
                         VTX_COLLISION_PREFERS_VI | VTX_ENGLISH_WORD_RESTORE | VTX_EAGER_ENGLISH_RESTORE |
                         VTX_RETRO_ENGLISH | VTX_ENGLISH_BY_FREQUENCY);
        EXPECT((vtx_get_flags(e) & VTX_ENGLISH_BY_FREQUENCY) != 0);
        for (w = 0; w < 2; ++w) {
            for (i = 0; i < strlen(words[w]); ++i) vtx_feed(e, (uint32_t)words[w][i], &a);
            vtx_commit_boundary(e, 1, &a);
            vtx_note_boundary(e, ' ');
            got = vtx_take_retro_correction(e, &r);
            EXPECT(got == (w == 1));
        }
        EXPECT(got && r.backspaces == 8 && r.words == 1 && r.flip_back == 1);
        EXPECT(eq16(r.expected, r.expected_len, NULL, want, 8));
        EXPECT(eq16(r.insert, r.insert_len, NULL, ins, 7));
        vtx_destroy(e);
    }
    /* restore-undo: all-caps "NAS" restores to raw keys; the record hands back "NÁ" */
    {
        const uint16_t na[] = {'N', 0xC1};
        vtx_restore_undo u;
        e = vtx_create();
        vtx_feed(e, 'N', &a); vtx_feed(e, 'A', &a); vtx_feed(e, 'S', &a);
        vtx_commit_boundary(e, 1, &a);
        vtx_note_boundary(e, ' ');
        EXPECT(vtx_take_restore_undo(e, &u));
        EXPECT(eq16(u.restored, u.restored_len, "NAS", NULL, 0));
        EXPECT(eq16(u.vietnamese, u.vietnamese_len, NULL, na, 2));
        EXPECT(!vtx_take_restore_undo(e, &u));
        vtx_restore_undo_applied(e);
        EXPECT(vtx_is_empty(e));
        vtx_destroy(e);
    }
    /* autoCircumflex (off by default): "vietj" -> "việt" only with VTX_AUTO_CIRCUMFLEX */
    {
        const uint16_t viet[] = {'v', 'i', 0x1EC7, 't'};
        uint16_t buf[VTX_MAX_TEXT];
        int on;
        for (on = 0; on < 2; ++on) {
            e = vtx_create();
            EXPECT((vtx_get_flags(e) & VTX_AUTO_CIRCUMFLEX) == 0);
            vtx_set_flags(e, VTX_FREE_MARKING | VTX_LIVE_SPELL_CHECK | VTX_ENGLISH_WORD_RESTORE |
                             (on ? VTX_AUTO_CIRCUMFLEX : 0));
            EXPECT(((vtx_get_flags(e) & VTX_AUTO_CIRCUMFLEX) != 0) == on);
            for (i = 0; i < 5; ++i) vtx_feed(e, (uint32_t)"vietj"[i], &a);
            n = vtx_composed(e, buf, VTX_MAX_TEXT);
            if (on) EXPECT(eq16(buf, n, NULL, viet, 4));
            else EXPECT(!eq16(buf, n, NULL, viet, 4));
            vtx_destroy(e);
        }
    }
    printf("c abi smoke: %s\n", fails ? "FAIL" : "ok");
    return fails != 0;
}
