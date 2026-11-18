// caret_hints_tests — the pure logic of the caret hints (caret_hints.h), mirroring macOS
// AppTests/CaretSuggestionsTests.swift + CaretHintTests.swift + MathHintTests.swift and the
// shared fixtures math-results.txt / number-chips.txt (same results as iOS/Android/macOS).
// The typo-fix lexicon part (and its precision eval) lives in the app tests (typo_fix.h).
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include "caret_hint_ipc.h"
#include "caret_hints.h"
#include "fake_document.h"
#include "session.h"
#include "settings.h"
#include "test.h"

using namespace vtx;
using namespace vtx::hints;

namespace {

std::u32string U(const char* s) { return toU32(utf8ToUtf16(s)); }
std::string S(const std::u32string& s) { return utf16ToUtf8(toU16(s)); }
std::string S(const std::u16string& s) { return utf16ToUtf8(s); }
std::string S(const std::optional<std::u32string>& s) { return s ? S(*s) : std::string("-"); }

std::vector<std::string> fixtureLines(const char* name) {
    std::vector<std::string> out;
    std::ifstream f(std::string(VTX_FIXTURES) + "/" + name);
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        out.push_back(line);
    }
    return out;
}

std::vector<std::string> split(const std::string& s) {
    std::vector<std::string> p;
    size_t a = 0;
    while (true) {
        size_t b = s.find('|', a);
        p.push_back(s.substr(a, b == std::string::npos ? std::string::npos : b - a));
        if (b == std::string::npos) break;
        a = b + 1;
    }
    return p;
}

std::string unmark(std::string s) {  // "␣" = one space in the fixtures
    const std::string mark = "\xE2\x90\xA3";
    for (size_t i; (i = s.find(mark)) != std::string::npos;) s.replace(i, mark.size(), " ");
    return s;
}

bool englishForTest(const std::u32string& w) { return opensEnglishRun(w); }

const LocalTime kNow{2026, 9, 28, 21, 35};  // 28/09/2026 21:35 (a Monday)

}  // namespace

// ---------------------------------------------------------------- shared fixtures

TEST(hints_math_results_fixture) {
    const auto lines = fixtureLines("math-results.txt");
    CHECK(lines.size() > 80);
    int n = 0;
    for (const std::string& l : lines) {
        const auto p = split(l);
        if (p.size() != 3) continue;
        // "implicit|…" = chip kết quả KHÔNG cần "=" — chỉ iOS/Android (thanh gợi ý); Windows dùng đường "=".
        if (p[0] != "eval" && p[0] != "chip") continue;
        const std::u32string in = U(unmark(p[1]).c_str());
        const std::string got = p[0] == "eval" ? S(mathResult(in)) : S(mathChip(in));
        if (got != p[2]) std::printf("  math %s|%s: got [%s] want [%s]\n", p[0].c_str(), p[1].c_str(), got.c_str(), p[2].c_str());
        CHECK_EQ(got, p[2]);
        ++n;
    }
    CHECK(n > 80);
}

TEST(hints_number_chips_fixture) {
    const auto lines = fixtureLines("number-chips.txt");
    CHECK(lines.size() > 100);
    for (const std::string& l : lines) {
        const auto p = split(l);
        if (p[0] == "spell" || p[0] == "spellLe") {
            CHECK_EQ(S(spellNumber(U(p[1].c_str()), p[0] == "spellLe")), p[2]);
        } else if (p[0] == "chip") {
            const auto c = numberChip(U(unmark(p[1]).c_str()));
            if (p.size() == 3) {
                if (c) std::printf("  chip %s: unexpected [%s]\n", p[1].c_str(), S(c->display).c_str());
                CHECK(!c);
            } else {
                CHECK(c.has_value());
                if (!c) continue;
                CHECK_EQ(S(c->display), unmark(p[2]));
                CHECK_EQ(S(c->replace), unmark(p[3]));
                CHECK_EQ(S(c->insert), unmark(p[4]));
            }
        }
    }
}

// ---------------------------------------------------------------- math / money (CaretHintTests)

TEST(hints_math_label_and_chip) {
    CHECK_EQ(S(mathLabel(U("36"))), std::string("= 36"));
    CHECK_EQ(S(mathChip(U("125 x (4 + 5.5) ="))), std::string("1187.5"));
    CHECK_EQ(S(mathChip(U("200+10%="))), std::string("220"));
    CHECK(!mathChip(U("12*3")));
}

TEST(hints_money_chip_only_money_formats) {
    auto a = moneyChip(U("giá 1tr2 "));
    CHECK(a.has_value());
    if (a) {
        CHECK(a->kind == Kind::Number);
        CHECK_EQ(S(a->display), std::string("1.200.000 ₫"));
        CHECK_EQ(S(a->replace), std::string("1tr2 "));
        CHECK_EQ(S(a->insert), std::string("1.200.000 ₫ "));
    }
    CHECK(moneyChip(U("nợ 2 tỷ ")).has_value());
    CHECK(moneyChip(U("50k ")).has_value());
    CHECK(!moneyChip(U("giá 1250000 ")));   // words, not money: not on Windows/macOS
    CHECK(!moneyChip(U("giá 1tr2")));       // needs the space just typed
    CHECK(!moneyChip(U("giá 1.250.000đ ")));
    CHECK(isMoneyFormat(U("-50.000 ₫")) && !isMoneyFormat(U("năm")));
}

// ---------------------------------------------------------------- keys (only Tab; Enter for math)

TEST(hints_key_actions) {
    for (Kind k : {Kind::Typo, Kind::Tones, Kind::Date, Kind::Number}) {
        CHECK(action(k, kVkTab, true) == KeyAction::Accept);
        CHECK(action(k, kVkReturn, true) == KeyAction::DismissPass);
        CHECK(action(k, kVkEscape, true) == KeyAction::DismissConsume);
        CHECK(action(k, 0x20, true) == KeyAction::DismissPass);
        CHECK(action(k, '1', true) == KeyAction::DismissPass);  // digits never pick
    }
    CHECK(action(Kind::Math, kVkReturn, true) == KeyAction::Accept);
    CHECK(action(Kind::Math, kVkTab, false) == KeyAction::DismissPass);    // Shift+Tab etc.
    CHECK(action(Kind::Math, kVkEscape, false) == KeyAction::DismissPass);
}

// ---------------------------------------------------------------- 3. typo gate (CaretSuggestionsTests)

TEST(hints_typo_gate_only_invalid_letter_words_at_boundary) {
    CHECK(typoWorthChecking(U' ', U("tpoi"), U("tpoi")));
    CHECK(typoWorthChecking(U',', U("tpoi"), U("tpoi")));
    CHECK(!typoWorthChecking(U'.', U("tpoi"), U("tpoi")));   // domains, times
    CHECK(!typoWorthChecking(U'\'', U("tpoi"), U("tpoi")));
    CHECK(!typoWorthChecking(U'\n', U("tpoi"), U("tpoi")));  // Enter may have sent it
    CHECK(!typoWorthChecking(U' ', U("tooi"), U("tôi")));    // valid syllable
    CHECK(!typoWorthChecking(U' ', U("kp"), U("kp")));       // too short
    CHECK(!typoWorthChecking(U' ', U("tp1i"), U("tp1i")));   // digit
    CHECK(!typoWorthChecking(U' ', U("tpoi"), U("(tpoi")));  // glued symbol
}

TEST(hints_typo_suggestion_keeps_boundary_and_case) {
    auto t = typoSuggestion(U("anh tpoi,"), U("tpoi"), U',', U("tpoi"), U("tôi"));
    CHECK(t.has_value());
    if (t) CHECK(*t == (Suggestion{Kind::Typo, u"tôi", u"tpoi,", u"tôi,"}));
    CHECK(!typoSuggestion(U("anh xtpoi "), U("tpoi"), U' ', U("tpoi"), U("tôi")));
    CHECK(!typoSuggestion(U("anh tpoi"), U("tpoi"), U' ', U("tpoi"), U("tôi")));
    CHECK(typoSuggestion(U("Xong. Tpoi "), U("Tpoi"), U' ', U("Tpoi"), U("Tôi")).has_value());
    CHECK(typoSuggestion(U("Tpoi "), U("Tpoi"), U' ', U("Tpoi"), U("Tôi")).has_value());
    CHECK(!typoSuggestion(U("gặp Tpoi "), U("Tpoi"), U' ', U("Tpoi"), U("Tôi")));  // a name mid-sentence
    CHECK(!typoSuggestion(U("anh tpoi "), U("tpoi"), U' ', U("tpoi"), U("tpoi")));  // no change
}

TEST(hints_rejected_words_case_insensitive_and_capped) {
    Rejected r(3);
    CHECK(r.add(U("Tpoi")));
    CHECK(!r.add(U("tpoi")));
    CHECK(r.contains(U("TPOI")));
    r.add(U("a1"));
    r.add(U("a2"));
    r.add(U("a3"));
    CHECK(!r.contains(U("tpoi")));  // oldest dropped
    CHECK(r.size() == 3);
}

// ---------------------------------------------------------------- 4. tones

namespace {
std::vector<ToneTrigger> feed(ToneTracker& t, const char* text) {
    // Key stream: each boundary reports the chunk committed right before it.
    std::vector<ToneTrigger> out;
    std::u32string chunk;
    for (char32_t ch : U(text)) {
        if (isLetter(ch) || isDigit(ch)) {
            chunk.push_back(ch);
            continue;
        }
        out.push_back(t.feed(chunk, ch));
        if (isWhitespace(ch)) chunk.clear();
        else chunk.push_back(ch);
    }
    return out;
}
using TT = ToneTrigger;
}  // namespace

TEST(hints_tone_tracker_triggers) {
    ToneTracker t;
    CHECK(feed(t, "toi di hoc ") == (std::vector<TT>{TT::None, TT::None, TT::Pause}));
    CHECK(feed(t, "hom nay ") == (std::vector<TT>{TT::Pause, TT::Pause}));
    t.reset();
    CHECK(feed(t, "toi di hoc.") == (std::vector<TT>{TT::None, TT::None, TT::SentenceEnd}));
    CHECK(feed(t, " roi ") == (std::vector<TT>{TT::None, TT::None}));  // new sentence
    t.reset();
    CHECK(feed(t, "toi, di hoc ") == (std::vector<TT>{TT::None, TT::None, TT::None, TT::Pause}));
    t.reset();
    CHECK(feed(t, "tôi di hoc ") == (std::vector<TT>{TT::None, TT::None, TT::None}));  // accented
    t.reset();
    CHECK(feed(t, "the cat is ") == (std::vector<TT>{TT::None, TT::None, TT::None}));  // English
    t.reset();
    CHECK(feed(t, "toi di\nhoc ") == (std::vector<TT>{TT::None, TT::None, TT::None}));  // newline
    t.reset();
    CHECK(feed(t, "a b ") == (std::vector<TT>{TT::None, TT::None}));
}

TEST(hints_tone_run_from_screen) {
    CHECK_EQ(S(toneRun(U("toi di hoc "))), std::string("toi di hoc "));
    CHECK_EQ(S(toneRun(U("Chiều nào toi di hoc hom nay "))), std::string("toi di hoc hom nay "));
    CHECK_EQ(S(toneRun(U("Xong. toi di hoc."))), std::string("toi di hoc."));
    CHECK_EQ(S(toneRun(U("xin chao ban. toi di hoc "))), std::string("toi di hoc "));  // not the previous sentence
    CHECK_EQ(S(toneRun(U("dong 1\ntoi di hoc "))), std::string("toi di hoc "));
    CHECK(!toneRun(U("toi di ")));
    CHECK(!toneRun(U("tôi đi học ")));
    CHECK(!toneRun(U("open the file ")));
}

TEST(hints_tone_suggestion) {
    const std::u32string run = U("toi di hoc ");
    auto s = toneSuggestion(run, U("tôi đi học "));
    CHECK(s.has_value());
    if (s) CHECK(*s == (Suggestion{Kind::Tones, u"tôi đi học", u"toi di hoc ", u"tôi đi học "}));
    CHECK(!toneSuggestion(run, run));         // unchanged
    CHECK(!toneSuggestion(run, U("tôi")));    // length differs
    std::u32string longRun, longOut;
    for (int i = 0; i < 20; ++i) {
        longRun += U("toi di ");
        longOut += U("tôi đi ");
    }
    auto l = toneSuggestion(longRun, longOut);
    CHECK(l && toU32(l->display).size() == 60 && l->display[0] == u'…');
}

TEST(hints_unaccented_syllables) {
    CHECK(isUnaccentedSyllable(U("hoc")));    // stop rime: only sắc/nặng
    CHECK(isUnaccentedSyllable(U("Toi,")));
    CHECK(isUnaccentedSyllable(U("TOI")));
    CHECK(!isUnaccentedSyllable(U("tOi")));
    CHECK(!isUnaccentedSyllable(U("the")));
    CHECK(!isUnaccentedSyllable(U("tôi")));
    CHECK(!isUnaccentedSyllable(U("xyzw")));
}

// ---------------------------------------------------------------- 5. date / time

TEST(hints_date_detect) {
    auto en = &englishForTest;
    CHECK(detectDate(U' ', U("hôm"), U("nay"), en) == Phrase::Today);
    CHECK(detectDate(U' ', U("Hôm"), U("qua"), en) == Phrase::Yesterday);
    CHECK(detectDate(U' ', U("ngày"), U("mai"), en) == Phrase::Tomorrow);
    CHECK(detectDate(U' ', U("bây"), U("giờ"), en) == Phrase::Now);
    CHECK(detectDate(U' ', U("you"), U("tomorrow"), en) == Phrase::Tomorrow);
    CHECK(detectDate(U' ', U("right"), U("now"), en) == Phrase::Now);
    CHECK(!detectDate(U' ', U(""), U("now"), en));        // no English context
    CHECK(!detectDate(U' ', U("gặp"), U("today"), en));
    CHECK(!detectDate(U',', U("hôm"), U("nay"), en));     // space only
    CHECK(!detectDate(U' ', U("hom"), U("nay"), en));     // unaccented
    CHECK(!detectDate(U' ', U("hôm"), U("sau"), en));
    // Lunar: "âm lịch " / "ngày âm " / "ÂL "
    CHECK(detectDate(U' ', U("âm"), U("lịch"), en) == Phrase::Lunar);
    CHECK(detectDate(U' ', U("Âm"), U("lịch"), en) == Phrase::Lunar);
    CHECK(detectDate(U' ', U("ÂM"), U("LỊCH"), en) == Phrase::Lunar);
    CHECK(detectDate(U' ', U("ngày"), U("âm"), en) == Phrase::Lunar);
    CHECK(detectDate(U' ', U("ngày"), U("mai"), en) == Phrase::Tomorrow);
    CHECK(detectDate(U' ', U(""), U("ÂL"), en) == Phrase::Lunar);
    CHECK(detectDate(U' ', U("là"), U("âl"), en) == Phrase::Lunar);
    CHECK(!detectDate(U',', U("âm"), U("lịch"), en));
    CHECK(!detectDate(U' ', U("am"), U("lich"), en));
    CHECK(!detectDate(U' ', U(""), U("al"), en));
    // Next Tết: the word on its own (any word before), any case, NFC.
    CHECK(detectDate(U' ', U(""), U("Tết"), en) == Phrase::Tet);
    CHECK(detectDate(U' ', U("ăn"), U("tết"), en) == Phrase::Tet);
    CHECK(detectDate(U' ', U(""), U("TẾT"), en) == Phrase::Tet);
    CHECK(!detectDate(U' ', U(""), U("tếtt"), en));
    CHECK(!detectDate(U' ', U(""), U("tet"), en));
    CHECK(!detectDate(U' ', U(""), U("tét"), en));
    CHECK(!detectDate(U',', U(""), U("Tết"), en));
}

TEST(hints_lunar_calendar) {
    // Tết 2026-2035 (UTC+7; 2030 is 2 Feb in Vietnam, 3 Feb on the UTC+8 calendar).
    const int tet[][3] = {{2026, 2, 17}, {2027, 2, 6}, {2028, 1, 26}, {2029, 2, 13}, {2030, 2, 2},
                          {2031, 1, 23}, {2032, 2, 11}, {2033, 1, 31}, {2034, 2, 19}, {2035, 2, 8}};
    for (const auto& t : tet) CHECK(lunarDate(t[2], t[1], t[0]) == (LunarDate{1, 1, t[0], false}));
    CHECK(lunarDate(3, 2, 2030, 8).day == 1);
    CHECK(lunarDate(3, 2, 2030) == (LunarDate{2, 1, 2030, false}));
    // Trung Thu (15/8); 2034 is 26 Sep in Vietnam (27 Sep at UTC+8).
    const int mid[][3] = {{2026, 9, 25}, {2027, 9, 15}, {2028, 10, 3}, {2029, 9, 22}, {2030, 9, 12},
                          {2031, 10, 1}, {2032, 9, 19}, {2033, 9, 8},  {2034, 9, 26}, {2035, 9, 16}};
    for (const auto& t : mid) CHECK(lunarDate(t[2], t[1], t[0]) == (LunarDate{15, 8, t[0], false}));
    // Leap months: 6/2025, 5/2028.
    CHECK(lunarDate(24, 7, 2025) == (LunarDate{30, 6, 2025, false}));
    CHECK(lunarDate(25, 7, 2025) == (LunarDate{1, 6, 2025, true}));
    CHECK(lunarDate(23, 8, 2025) == (LunarDate{1, 7, 2025, false}));
    CHECK(lunarDate(23, 6, 2028) == (LunarDate{1, 5, 2028, true}));
    CHECK(lunarDate(8, 11, 2026) == (LunarDate{30, 9, 2026, false}));
    CHECK(lunarDate(13, 8, 2026) == (LunarDate{1, 7, 2026, false}));  // new moon 00:37 VN time
    CHECK(lunarDate(22, 3, 2023) == (LunarDate{1, 2, 2023, true}));   // leap 2nd month 2023
    CHECK(lunarDate(21, 1, 1985) == (LunarDate{1, 1, 1985, false}));  // Tết 1985 in Vietnam
    CHECK_EQ(S(lunarYearName(2025)), std::string("Ất Tỵ"));
    CHECK_EQ(S(lunarYearName(2026)), std::string("Bính Ngọ"));
    CHECK_EQ(S(lunarYearName(2027)), std::string("Đinh Mùi"));
    CHECK_EQ(S(lunarText(8, 11, 2026)), std::string("30/9 năm Bính Ngọ"));
    CHECK_EQ(S(lunarText(16, 2, 2026)), std::string("29/12 năm Ất Tỵ"));  // before Tết: previous year
    CHECK_EQ(S(lunarText(25, 7, 2025)), std::string("1/6 nhuận năm Ất Tỵ"));
    // Dates the short public algorithm (old mobile code) got wrong: day 0 / one day off.
    CHECK(lunarDate(7, 5, 2054) == (LunarDate{30, 3, 2054, false}));
    CHECK(lunarDate(9, 4, 2062) == (LunarDate{30, 2, 2062, false}));
    CHECK(lunarDate(9, 12, 2072) == (LunarDate{1, 11, 2072, false}));
    CHECK(lunarDate(15, 11, 2077) == (LunarDate{1, 10, 2077, false}));
}

// Shared fixture lunar-month-starts.txt (every lunar month start 1900-2100, generated from
// App/Sources/LunarCalendar.swift): walk every day and compare with the month that holds it.
TEST(hints_lunar_cross_port_fixture) {
    struct Start {
        long jd;
        int month, year;
        bool leap;
    };
    auto jdOf = [](int d, int m, int y) -> long {
        const long a = (14 - m) / 12, yy = y + 4800 - a, mm = m + 12 * a - 3;
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045;
    };
    std::vector<Start> starts;
    for (const auto& line : fixtureLines("lunar-month-starts.txt")) {
        int ymd = 0, month = 0, year = 0;
        char plus = 0;
        if (std::sscanf(line.c_str(), "%d\t%d%c", &ymd, &month, &plus) < 2) continue;
        const bool leap = plus == '+';
        const size_t tab = line.rfind('\t');
        year = std::atoi(line.c_str() + tab + 1);
        starts.push_back({jdOf(ymd % 100, ymd / 100 % 100, ymd / 10000), month, year, leap});
    }
    CHECK_EQ(starts.size(), size_t(2487));
    int bad = 0;
    long days = 0;
    for (size_t i = 0; i < starts.size(); ++i) {
        const long next = i + 1 < starts.size() ? starts[i + 1].jd : jdOf(31, 12, 2100) + 1;
        for (long jd = starts[i].jd; jd < next; ++jd) {
            const long a = jd + 32044, b = (4 * a + 3) / 146097, c = a - 146097 * b / 4;
            const long d4 = (4 * c + 3) / 1461, e = c - 1461 * d4 / 4, m5 = (5 * e + 2) / 153;
            const int day = static_cast<int>(e - (153 * m5 + 2) / 5 + 1);
            const int month = static_cast<int>(m5 + 3 - 12 * (m5 / 10));
            const int year = static_cast<int>(100 * b + d4 - 4800 + m5 / 10);
            const LunarDate want{static_cast<int>(jd - starts[i].jd + 1), starts[i].month, starts[i].year,
                                 starts[i].leap};
            if (!(lunarDate(day, month, year) == want) && ++bad <= 5)
                std::printf("  lunar mismatch %d/%d/%d\n", day, month, year);
            ++days;
        }
    }
    CHECK_EQ(bad, 0);
    CHECK(days > 73000);
}

TEST(hints_date_format) {
    CHECK_EQ(S(formatDate(Phrase::Today, kNow)), std::string("28/09/2026"));
    CHECK_EQ(S(formatDate(Phrase::Tomorrow, kNow)), std::string("29/09/2026"));
    CHECK_EQ(S(formatDate(Phrase::Yesterday, kNow)), std::string("27/09/2026"));
    CHECK_EQ(S(formatDate(Phrase::Now, kNow)), std::string("21:35"));
    CHECK_EQ(S(formatDate(Phrase::Tomorrow, LocalTime{2026, 12, 31, 8, 5})), std::string("01/01/2027"));
    CHECK_EQ(S(formatDate(Phrase::Yesterday, LocalTime{2028, 3, 1, 8, 5})), std::string("29/02/2028"));
    CHECK_EQ(S(formatDate(Phrase::Now, LocalTime{2028, 3, 1, 8, 5})), std::string("08:05"));
}

TEST(hints_date_suggestion_replaces_phrase) {
    auto a = dateSuggestion(U("Hẹn hôm nay "), U("hôm"), U("nay"), Phrase::Today, kNow);
    CHECK(a && *a == (Suggestion{Kind::Date, u"28/09/2026", u"hôm nay ", u"28/09/2026 "}));
    auto b = dateSuggestion(U("bây giờ "), U("bây"), U("giờ"), Phrase::Now, kNow);
    CHECK(b && b->insert == u"21:35 ");
    auto c = dateSuggestion(U("see you tomorrow "), U("you"), U("tomorrow"), Phrase::Tomorrow, kNow);
    CHECK(c && c->replace == u"tomorrow ");
    CHECK(!dateSuggestion(U("xhôm nay "), U("hôm"), U("nay"), Phrase::Today, kNow));  // not standing alone
    CHECK(!dateSuggestion(U("hôm nay"), U("hôm"), U("nay"), Phrase::Today, kNow));    // screen differs
    const LocalTime nov8{2026, 11, 8, 9, 0};
    CHECK_EQ(S(formatDate(Phrase::Lunar, nov8)), std::string("30/9 năm Bính Ngọ"));
    auto l = dateSuggestion(U("Hôm nay âm lịch "), U("âm"), U("lịch"), Phrase::Lunar, nov8);
    CHECK(l && *l == (Suggestion{Kind::Date, u"30/9 năm Bính Ngọ", u"âm lịch ", u"30/9 năm Bính Ngọ "}));
    auto n = dateSuggestion(U("ngày âm "), U("ngày"), U("âm"), Phrase::Lunar, nov8);
    CHECK(n && n->replace == u"ngày âm ");
    auto al = dateSuggestion(U("Hôm nay ÂL "), U("nay"), U("ÂL"), Phrase::Lunar, nov8);
    CHECK(al && *al == (Suggestion{Kind::Date, u"30/9 năm Bính Ngọ", u"ÂL ", u"30/9 năm Bính Ngọ "}));
    auto nal = dateSuggestion(U("ngày ÂL "), U("ngày"), U("ÂL"), Phrase::Lunar, nov8);
    CHECK(nal && nal->replace == u"ÂL ");  // only the word itself
    CHECK(!dateSuggestion(U("xâm lịch "), U("âm"), U("lịch"), Phrase::Lunar, nov8));
    // Tết: display the date, Tab keeps the typed word and appends the date.
    CHECK_EQ(S(formatDate(Phrase::Tet, nov8)), std::string("06/02/2027"));
    auto t = dateSuggestion(U("Sắp Tết "), U("Sắp"), U("Tết"), Phrase::Tet, nov8);
    CHECK(t && *t == (Suggestion{Kind::Date, u"06/02/2027", u"Tết ", u"Tết 06/02/2027 "}));
    auto tu = dateSuggestion(U("TẾT "), U(""), U("TẾT"), Phrase::Tet, nov8);
    CHECK(tu && tu->insert == u"TẾT 06/02/2027 ");
    auto tn = dateSuggestion(U("ngày tết "), U("ngày"), U("tết"), Phrase::Tet, nov8);
    CHECK(tn && tn->replace == u"tết ");
    CHECK(!dateSuggestion(U("xTết "), U(""), U("Tết"), Phrase::Tet, nov8));
}

TEST(hints_next_tet) {
    CHECK_EQ(S(nextTetText(8, 11, 2026)), std::string("06/02/2027"));
    CHECK_EQ(S(nextTetText(5, 2, 2027)), std::string("06/02/2027"));  // day before
    CHECK_EQ(S(nextTetText(6, 2, 2027)), std::string("06/02/2027"));  // mùng 1 itself
    CHECK_EQ(S(nextTetText(7, 2, 2027)), std::string("26/01/2028"));  // day after
    CHECK_EQ(S(nextTetText(1, 1, 2026)), std::string("17/02/2026"));
    CHECK_EQ(S(nextTetText(31, 12, 2029)), std::string("02/02/2030"));  // UTC+7 (UTC+8: 3 Feb)
    // Every Tết 1901-2100 is lunar 1/1 (not leap) of that year, and the day before is not.
    int bad = 0;
    for (int y = 1901; y <= 2100; ++y) {
        int d = 0, m = 0, yy = 0;
        gregorianFromJulianDay(tetDayNumber(y), d, m, yy);
        if (yy != y || !(lunarDate(d, m, yy) == LunarDate{1, 1, y, false})) ++bad;
        gregorianFromJulianDay(tetDayNumber(y) - 1, d, m, yy);
        if (lunarDate(d, m, yy).year != y - 1) ++bad;
    }
    CHECK_EQ(bad, 0);
}

TEST(hints_last_runs_from_screen) {
    std::u32string p, r;
    CHECK(lastRuns(U("Hẹn hôm nay "), p, r) && S(p) == "hôm" && S(r) == "nay");
    CHECK(lastRuns(U("nay "), p, r) && p.empty() && S(r) == "nay");
    CHECK(!lastRuns(U("hôm nay"), p, r));
    CHECK(!lastRuns(U("hôm nay  "), p, r));
}

// ---------------------------------------------------------------- key stream -> trigger

namespace {
Trigger typeInto(HintTracker& t, const char* keys, const Enabled& en, const Commit& atLast = {}) {
    Trigger last;
    const std::u32string k = U(keys);
    for (size_t i = 0; i < k.size(); ++i) last = t.onChar(k[i], i + 1 == k.size() ? atLast : Commit{}, en);
    return last;
}
}  // namespace

TEST(hints_tracker_triggers) {
    Enabled en;
    en.tones = true;
    HintTracker t;
    CHECK(typeInto(t, "12*3=", en).kind == TriggerKind::Math);
    t.reset();
    CHECK(typeInto(t, "gia 1tr2 ", en).kind == TriggerKind::Number);
    t.reset();
    CHECK(typeInto(t, "no 2 tyr ", en).kind == TriggerKind::Number);  // unit after the number
    t.reset();
    CHECK(typeInto(t, "hen hoom nay ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "see you tomorrow ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "aam lichj ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "AAL ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "an teets ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "TEETS ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "te6t1 ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "test ", en).kind != TriggerKind::Date);
    t.reset();
    // VNI lunar triggers hold digits: date must win over number (en.number is on)
    CHECK(typeInto(t, "a6m lich5 ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "A6L ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "nga2y a6m ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "gia 1tr2 ", en).kind == TriggerKind::Number);
    t.reset();
    Trigger ty = typeInto(t, "anh tpoi ", en, Commit{U("tpoi"), U("tpoi")});
    CHECK(ty.kind == TriggerKind::Typo && S(ty.raw) == "tpoi" && ty.boundary == U' ');
    t.reset();
    Trigger p = typeInto(t, "toi di hoc ", en);
    CHECK(p.kind == TriggerKind::Tones && p.delayMs == kTonePauseMs);
    t.reset();
    Trigger se = typeInto(t, "toi di hoc.", en);
    CHECK(se.kind == TriggerKind::Tones && se.delayMs < 100);
    t.reset();
    CHECK(typeInto(t, "xin chao ", en).kind == TriggerKind::None);
}

TEST(hints_tracker_respects_switches) {
    Enabled off;
    off.math = off.number = off.typo = off.tones = off.date = false;
    CHECK(!off.any());
    HintTracker t;
    CHECK(typeInto(t, "12*3=", off).kind == TriggerKind::None);
    CHECK(typeInto(t, "50k ", off).kind == TriggerKind::None);
    CHECK(typeInto(t, "hoom nay ", off).kind == TriggerKind::None);
    CHECK(typeInto(t, "toi di hoc.", off).kind == TriggerKind::None);
    Enabled def;  // defaults: tones OFF
    CHECK(!def.tones && def.math && def.number && def.typo && def.date);
    t.reset();
    CHECK(typeInto(t, "toi di hoc.", def).kind == TriggerKind::None);
}

TEST(hints_tracker_backspace) {
    Enabled en;
    HintTracker t;
    typeInto(t, "50", en);
    t.onBackspace();
    t.onBackspace();
    CHECK(t.chunk().empty());
    CHECK(typeInto(t, "k ", en).kind == TriggerKind::None);  // the digits are gone
}

TEST(hints_worth_checking_filters) {
    CHECK(numberWorthChecking(U("1tr2"), U("")));
    CHECK(numberWorthChecking(U("tyr"), U("2")));
    CHECK(!numberWorthChecking(U("nha"), U("anh")));
    CHECK(dateWorthReading(U("hoom"), U("nay")));
    CHECK(dateWorthReading(U("ngayf"), U("mai")));
    CHECK(dateWorthReading(U("baay"), U("giowf")));
    CHECK(dateWorthReading(U("you"), U("Tomorrow")));
    CHECK(!dateWorthReading(U(""), U("now")));
    CHECK(!dateWorthReading(U("xin"), U("chao")));
    CHECK(dateWorthReading(U("aam"), U("lichj")));
    CHECK(dateWorthReading(U("a6m"), U("lich5")));
    CHECK(dateWorthReading(U("ngayf"), U("aam")));
    CHECK(dateWorthReading(U(""), U("AAL")));
    CHECK(dateWorthReading(U("laf"), U("aal")));
    CHECK(!dateWorthReading(U(""), U("anh")));
    CHECK(!dateWorthReading(U("anh"), U("ddi")));
    // tết: any raw spelling, any word before; nothing wider.
    for (const char* r : {"teets", "tetes", "teest", "teste", "TEETS", "Teets", "te6t1", "tet61", "te61t", "teetss"})
        CHECK(dateWorthReading(U(""), U(r)));
    CHECK(dateWorthReading(U("an"), U("teets")));
    for (const char* r : {"test", "tet", "tees", "teet", "tests", "teetst", "texts", "eetst", "te6t", "tet1"})
        CHECK(!dateWorthReading(U(""), U(r)));
}

// ---------------------------------------------------------------- the session reports the commit

TEST(hints_session_reports_committed_word) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Settings st;
        TypingSession s;
        s.setOutputMode(m);
        SessionOptions o;
        o.engineFlags = st.engineFlags();
        o.autoRestore = st.autoRestore;
        o.shortcuts = &st.shortcuts;
        s.configure(o);
        test::FakeDocument doc;
        auto key = [&](char c) {
            KeyInput k;
            k.kind = KeyKind::Char;
            k.ch = static_cast<unsigned char>(c);
            const bool eaten = s.wantsKey(k) && s.handleKey(k, doc);
            if (!eaten) doc.appInsert(static_cast<char16_t>(c));
        };
        for (char c : std::string("tooi tpoi")) key(c);
        CHECK(s.lastCommitRaw().empty());
        key(' ');
        CHECK_EQ(S(s.lastCommitRaw()), std::string("tpoi"));
        CHECK_EQ(S(s.lastCommitText()), std::string("tpoi"));
        key('x');
        CHECK(s.lastCommitRaw().empty());
        for (char c : std::string("in,")) key(c);
        CHECK_EQ(S(s.lastCommitRaw()), std::string("xin"));
        CHECK(utf16ToUtf8(doc.text).rfind("tôi tpoi xin,", 0) == 0);
    }
}


// ---------------------------------------------------------------- Học từ bạn gõ (TIP side)
// LearnTracker / learnable = App/Sources/LearnedModel.swift (AppTests/LearnedWordsTests);
// the session's lastCommitWord; the Learn job payload.

TEST(learn_tracker_context_and_pending) {
    LearnTracker t;
    LearnTracker::Event e;
    CHECK(!t.commit(U"Ăn", U' ', true, 1, e));
    CHECK(t.hasPending() && t.pending().word == U"ăn");
    CHECK(t.commit(U"cơm", U',', true, 1, e) && e.word == U"ăn" && e.prev1.empty());
    CHECK(t.prev1().empty());  // punctuation cuts the context
    CHECK(t.commit(U"rồi", U' ', true, 1, e) && e.word == U"cơm" && e.prev1 == U"ăn");
    t.discard();
    CHECK(!t.hasPending() && !t.breakContext(e));
    CHECK(!t.commit(U"đi", U' ', true, 1, e));
    CHECK(t.commit(U"x1", U' ', true, 1, e) && e.word == U"đi");
    CHECK(!t.hasPending());
    CHECK(!t.commit(U"học", U' ', false, 1, e) && !t.hasPending());
    // learned casing: the event keeps the word as committed (the payload sends it), key lowercase
    LearnTracker k;
    k.commit(U"ở", U' ', true, 1, e);
    k.commit(U"SenPrints", U' ', true, 1, e);
    CHECK(k.pending().word == U"senprints" && k.pending().form == U"SenPrints" && k.pending().prev1 == U"ở");
    CHECK(k.commit(U"nhé", U'.', true, 1, e) && e.form == U"SenPrints");
    k.commit(U"Dii", U' ', true, 1, e);
    k.replacePending(U"Đi");
    CHECK(k.pending().word == U"đi" && k.pending().form == U"Đi");
    LearnTracker f;
    f.commit(U"tôi", U' ', true, 1, e);
    f.commit(U"dii", U' ', true, 1, e);
    f.replacePending(U"đi");  // accepted typo fix: the fixed form, same context
    CHECK(f.pending().word == U"đi" && f.pending().prev1 == U"tôi");
    CHECK(f.commit(U"học", U' ', true, 1, e) && e.word == U"đi");
    CHECK(f.pending().prev1 == U"đi");
    CHECK(learnable(U"cơm") && learnable(U"Phúc") && learnable(U"heey"));
    CHECK(!learnable(U"heeey") && !learnable(U"a1") && !learnable(U""));
    CHECK(learnable(U"abcdefghijkl") && !learnable(U"abcdefghijklm") && !learnable(U"e-mail"));
}

TEST(learn_event_payload_roundtrip) {
    std::u16string q;
    CHECK(appendLearnEvent(q, LearnEvent{u"cơm", u"ăn", u"", 1}));
    CHECK(appendLearnEvent(q, LearnEvent{u"được", u"tôi", u"anh", 2}));
    CHECK(appendLearnEvent(q, LearnEvent{u"x\x1f\x1ey", u"", u"", 1}));  // separators stripped
    const std::vector<LearnEvent> back = unpackLearnEvents(q);
    CHECK_EQ(back.size(), static_cast<size_t>(3));
    if (back.size() == 3) {
        CHECK(back[0] == (LearnEvent{u"cơm", u"ăn", u"", 1}));
        CHECK(back[1] == (LearnEvent{u"được", u"tôi", u"anh", 2}));
        CHECK(back[2].word == u"xy");
    }
    CHECK(unpackLearnEvents(u"").empty());
    CHECK(unpackLearnEvents(u"garbage").empty());
    CHECK(unpackLearnEvents(u"9\x1fw\x1f\x1f").empty());  // bad weight
    // Capped at kHintMaxLength: a full queue refuses (the TIP sends it, then queues again).
    std::u16string full;
    int n = 0;
    while (appendLearnEvent(full, LearnEvent{u"abcdefghijkl", u"abcdefghijkl", u"abcdefghijkl", 1})) ++n;
    CHECK(n > 5 && full.size() <= kHintMaxLength);
    HintMessage m;
    m.job = static_cast<uint32_t>(HintJob::Learn);
    m.text = q;
    const std::vector<uint8_t> b = packHintMessage(m);
    HintMessage back2;
    CHECK(unpackHintMessage(b.data(), b.size(), back2) && back2.job == 4 && back2.text == q);
}

TEST(learn_session_last_commit_word) {
    TypingSession s;
    Settings st;
    SessionOptions o;
    o.engineFlags = st.engineFlags();
    o.autoRestore = st.autoRestore;
    o.shortcuts = &st.shortcuts;
    s.configure(o);
    test::FakeDocument doc;
    auto key = [&](KeyKind kind, char c) {
        KeyInput k;
        k.kind = kind;
        k.ch = static_cast<unsigned char>(c);
        const bool eaten = s.wantsKey(k) && s.handleKey(k, doc);
        if (!eaten && kind == KeyKind::Char) doc.appInsert(static_cast<char16_t>(c));
    };
    for (char c : std::string("awn")) key(KeyKind::Char, c);
    CHECK(s.lastCommitWord().empty());
    key(KeyKind::Char, ' ');
    CHECK_EQ(utf16ToUtf8(s.lastCommitWord()), std::string("ăn"));
    for (char c : std::string("cowm")) key(KeyKind::Char, c);
    key(KeyKind::Boundary, 0);  // Enter: committed too (lastCommitText stays printable-only)
    CHECK_EQ(utf16ToUtf8(s.lastCommitWord()), std::string("cơm"));
    CHECK(s.lastCommitText().empty());
    for (char c : std::string("abc")) key(KeyKind::Char, c);
    key(KeyKind::Chord, 0);  // Ctrl+key: never
    CHECK(s.lastCommitWord().empty());
}

// ---------------------------------------------------------------- where to show

TEST(hints_caret_rect_plausibility) {
    const Rect screen{0, 0, 1920, 1080};
    CHECK(plausibleCaret(Rect{100, 200, 101, 220}, screen));
    CHECK(plausibleCaret(Rect{100, 200, 100, 220}, screen));    // zero width
    CHECK(!plausibleCaret(Rect{0, 0, 0, 0}, screen));           // nothing
    CHECK(!plausibleCaret(Rect{100, 200, 900, 240}, screen));   // the whole field
    CHECK(!plausibleCaret(Rect{100, 200, 101, 800}, screen));   // absurd height
    CHECK(!plausibleCaret(Rect{3000, 200, 3001, 220}, screen)); // off screen
    CHECK(plausibleCaret(Rect{100, 200, 101, 260}, screen, 192));  // 200% scale
}

TEST(hints_popup_below_or_above_caret) {
    const Rect work{0, 0, 1920, 1040};
    long x = 0, y = 0;
    popupOrigin(Rect{100, 200, 101, 220}, 120, 30, work, x, y);
    CHECK(x == 100 && y == 224);                         // below, left edge at the caret
    popupOrigin(Rect{100, 1010, 101, 1030}, 120, 30, work, x, y);
    CHECK(x == 100 && y == 1010 - 4 - 30);               // flipped above near the bottom
    popupOrigin(Rect{1900, 200, 1901, 220}, 120, 30, work, x, y);
    CHECK(x == 1920 - 6 - 120);                          // kept inside the work area
    popupOrigin(Rect{-50, 200, -49, 220}, 120, 30, work, x, y);
    CHECK(x == 6);
}

// ---------------------------------------------------------------- IPC + settings

TEST(hints_ipc_roundtrip_and_rejects_garbage) {
    HintMessage m;
    m.request = 0x12345678;
    m.job = static_cast<uint32_t>(HintJob::Tones);
    m.flags = 0x707;
    m.text = u"toi di hoc ";
    const auto b = packHintMessage(m);
    HintMessage r;
    CHECK(unpackHintMessage(b.data(), b.size(), r));
    CHECK(r.request == m.request && r.job == m.job && r.flags == m.flags && r.text == m.text);
    CHECK(!unpackHintMessage(b.data(), b.size() - 1, r));   // odd
    CHECK(!unpackHintMessage(b.data(), 8, r));              // short
    std::vector<uint8_t> bad = b;
    bad[4] = 9;                                             // unknown job
    CHECK(!unpackHintMessage(bad.data(), bad.size(), r));
    HintMessage big;
    big.job = 1;
    big.text.assign(kHintMaxLength + 50, u'a');
    const auto bb = packHintMessage(big);                    // truncated to the cap
    CHECK(unpackHintMessage(bb.data(), bb.size(), r) && r.text.size() == kHintMaxLength);
}

TEST(hints_settings_defaults_and_snapshot) {
    Settings s;
    CHECK(s.mathResults && s.numberChips && s.typoHints && s.dateHints);
    CHECK(!s.toneHints);  // macOS: tones default OFF
    s.mathResults = false;
    s.toneHints = true;
    s.dateHints = false;
    const auto b = serialize(s);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(!r.mathResults && r.numberChips && r.typoHints && r.toneHints && !r.dateHints);
    CHECK(r == s);
    // A snapshot from an older app (16 bools) leaves the new switches at their defaults.
    std::vector<uint8_t> old = serialize(Settings{});
    old[6] = 16;
    old[7] = 0;
    Settings o;
    CHECK(deserialize(old.data(), old.size(), o));
    CHECK(o.mathResults && !o.toneHints);
}

// ---------------------------------------------------------------- 6. word prediction (TIP side)

TEST(predict_keys_never_accept_on_enter_or_arrows) {
    CHECK(action(Kind::Predict, kVkTab, true) == KeyAction::Accept);
    CHECK(action(Kind::Predict, kVkReturn, true) == KeyAction::DismissPass);  // Enter never picks
    CHECK(action(Kind::Predict, 0x28 /* VK_DOWN */, true) == KeyAction::DismissPass);
    CHECK(action(Kind::Predict, 0x26 /* VK_UP */, true) == KeyAction::DismissPass);
    CHECK(action(Kind::Predict, kVkEscape, true) == KeyAction::DismissConsume);
    CHECK(action(Kind::Predict, kVkTab, false) == KeyAction::DismissPass);  // Shift+Tab etc.
    CHECK(action(Kind::Predict, '1', true) == KeyAction::DismissPass);      // no numbered picks
}

// One suggestion only (the app answers with its top-ranked word): Tab / click accept it.
TEST(predict_suggestion_from_candidate) {
    auto s = predictSuggestion(U"xin chào bạn đư", U"đư", u"được");
    CHECK(s.has_value());
    if (s) CHECK(*s == (Suggestion{Kind::Predict, u"được", u"đư", u"được "}));
    // the screen changed / the word is glued to something: nothing
    CHECK(!predictSuggestion(U"xin chào bạn đươ", U"đư", u"được"));
    CHECK(!predictSuggestion(U"abc.đư", U"đư", u"được"));
    CHECK(!predictSuggestion(U"đư", U"đư", u""));
    // next word: right after "word "
    auto n = predictSuggestion(U"cảm ơn ", U"", u"bạn");
    CHECK(n && n->replace.empty() && n->insert == u"bạn ");
    CHECK(!predictSuggestion(U"xong. ", U"", u"ơn"));
    CHECK(!predictSuggestion(U"cảm", U"", u"ơn"));
}

TEST(predict_still_valid_before_replacing) {
    auto s = predictSuggestion(U"tôi đư", U"đư", u"được");
    CHECK(s && hintStillValid(*s, U"tôi đư"));
    CHECK(s && !hintStillValid(*s, U"tôi đưa"));
    auto n = predictSuggestion(U"cảm ", U"", u"ơn");
    CHECK(n && hintStillValid(*n, U"cảm "));
    CHECK(n && !hintStillValid(*n, U"cảm  "));
    CHECK(n && !hintStillValid(*n, U"cảm"));
}

// ---------------------------------------------------------------- 6b. email domains
// Same cases as macOS / Linux (shared spec; mobile iOS EmailDomains): gmail first, prefix match
// after "@", only the missing part inserted, raw keys when Telex mangled the composing word.
TEST(email_domain_suggestion) {
    auto e = [](const std::u32string& b, const std::u32string& t = U"", const std::u32string& r = U"") {
        return emailDomainSuggestion(b, t, r);
    };
    auto s = e(U"user@");
    CHECK(s && *s == (Suggestion{Kind::Email, u"gmail.com", u"", u"gmail.com"}));
    s = e(U"user@ic", U"ic", U"ic");
    CHECK(s && *s == (Suggestion{Kind::Email, u"icloud.com", u"", u"loud.com"}));
    s = e(U"user@gm", U"gm", U"gm");
    CHECK(s && s->display == u"gmail.com" && s->insert == u"ail.com" && s->replace.empty());
    s = e(U"user@GM", U"GM", U"GM");
    CHECK(s && s->insert == u"ail.com");
    s = e(U"user@gmail.");  // "." ended the composing word
    CHECK(s && s->display == u"gmail.com" && s->insert == u"com");
    s = e(U"user@gmail.c", U"c", U"c");
    CHECK(s && s->insert == u"om");
    CHECK(!e(U"user@gmail.com"));            // already complete
    s = e(U"user@gmail", U"gmail", U"gmail");  // still a prefix of gmail.com
    CHECK(s && s->insert == u".com");
    CHECK(!e(U"user@x", U"x", U"x"));         // no provider
    CHECK(!e(U"@"));                          // empty local part
    CHECK(!e(U" @"));
    CHECK(!e(U"phúc@"));                      // not an email local part
    CHECK(!e(U"x@y@"));
    CHECK(!e(U"user"));                       // no "@"
    s = e(U"hello user@");
    CHECK(s && s->display == u"gmail.com");
    s = e(U"<user@");
    CHECK(s && s->display == u"gmail.com");
    s = e(U"to: first.last+tag@");
    CHECK(s && s->display == u"gmail.com");
    s = e(U"user@o", U"o", U"o");
    CHECK(s && s->display == u"outlook.com" && s->insert == u"utlook.com");
    s = e(U"user@y", U"y", U"y");
    CHECK(s && s->display == u"yahoo.com");
    // Telex turned "yahoo" into "yahô": match the raw keys, replace the composing word.
    s = e(U"user@yahô", U"yahô", U"yahoo");
    CHECK(s && *s == (Suggestion{Kind::Email, u"yahoo.com", u"yahô", u"yahoo.com"}));
    // Mangled word after a committed prefix ("outl" + "ôk"… raw "ook"): replace only that word.
    s = e(U"user@outlôk", U"outlôk", U"outlook");
    CHECK(s && s->replace == u"outlôk" && s->insert == u"outlook.com");
    CHECK(!e(U"user@gm", U"gx", U"gx"));      // screen does not end with the composing word
    CHECK(!e(U"user@abcdefghijkl"));          // too long
    CHECK(!e(U"user@g m"));                   // space in the domain part
}

TEST(email_domain_still_valid_and_keys) {
    auto s = emailDomainSuggestion(U"user@gm", U"gm", U"gm");
    CHECK(s && hintStillValid(*s, U"user@gm"));
    CHECK(s && hintStillValid(*s, U"user@GM"));
    CHECK(s && !hintStillValid(*s, U"user@gma"));
    CHECK(s && !hintStillValid(*s, U"user gm"));
    auto m = emailDomainSuggestion(U"user@yahô", U"yahô", U"yahoo");
    CHECK(m && hintStillValid(*m, U"user@yahô"));
    CHECK(m && !hintStillValid(*m, U"user@yahôo"));
    auto a = emailDomainSuggestion(U"user@", U"", U"");
    CHECK(a && hintStillValid(*a, U"user@"));
    CHECK(a && !hintStillValid(*a, U"user@ "));
    CHECK(action(Kind::Email, kVkTab, true) == KeyAction::Accept);
    CHECK(action(Kind::Email, kVkReturn, true) == KeyAction::DismissPass);  // Enter sends / new line
    CHECK(action(Kind::Email, kVkEscape, true) == KeyAction::DismissConsume);
    CHECK(emailTokenChar(U'g') && emailTokenChar(U'.') && emailTokenChar(U'-') && emailTokenChar(U'7'));
    CHECK(!emailTokenChar(U' ') && !emailTokenChar(U'@') && !emailTokenChar(U',') && !emailTokenChar(0x00F4));
}

TEST(predict_muting_and_apps) {
    CHECK(predictMuted(U"đươ", U"đư"));
    CHECK(predictMuted(U"ĐƯ", U"đư"));
    CHECK(!predictMuted(U"đa", U"đư"));
    CHECK(!predictMuted(U"", U"đư"));
    CHECK(!predictMuted(U"đư", U""));
    CHECK(predictionAllowedForApp("notepad.exe"));
    CHECK(predictionAllowedForApp("winword.exe"));
    CHECK(predictionAllowedForApp("chrome.exe"));
    CHECK(!predictionAllowedForApp("code.exe"));  // code editors: Tab indents
    CHECK(!predictionAllowedForApp("devenv.exe"));
    CHECK(!predictionAllowedForApp("idea64.exe"));
    CHECK(!predictionAllowedForApp("windowsterminal.exe"));  // terminals (built-in Direct rule)
    CHECK(!predictionAllowedForApp("conhost.exe"));
}

// Tab on a prediction inserts "word␣"; the very next key decides (= macOS ControllerHarnessTests).
TEST(predict_accepted_space_next_key) {
    CHECK(acceptSpaceReplacement(U'.') == U". ");
    CHECK(acceptSpaceReplacement(U',') == U", ");
    CHECK(acceptSpaceReplacement(0x201D) == std::u32string(1, 0x201D) + U" ");
    CHECK(acceptSpaceReplacement(U'/') == U"/");
    CHECK(acceptSpaceReplacement(U'"').empty() && acceptSpaceReplacement(U'a').empty() &&
          acceptSpaceReplacement(U' ').empty() && acceptSpaceReplacement(U'(').empty());
    AcceptedSpace st;
    st.inserted = U("được ");
    std::u32string expect, rep;
    CHECK(acceptSpaceKey(st, U'.', expect, rep) == AcceptSpaceAct::Replace);
    CHECK(expect == U("được ") && rep == U". " && st.empty());
    st.carried = U". ";
    CHECK(acceptSpaceKey(st, U' ', expect, rep) == AcceptSpaceAct::Swallow);
    CHECK(expect == U". " && st.empty());
    st.carried = U". ";
    CHECK(acceptSpaceKey(st, U'b', expect, rep) == AcceptSpaceAct::Pass);  // only the next key
    st.inserted = U("được ");
    CHECK(acceptSpaceKey(st, U'a', expect, rep) == AcceptSpaceAct::Pass);
    CHECK(st.empty());
    st.inserted = U("được ");
    CHECK(acceptSpaceKey(st, 0, expect, rep) == AcceptSpaceAct::Pass);   // Enter, arrows, ⌫…
    st.inserted = U("được ");
    CHECK(acceptSpaceKey(st, U' ', expect, rep) == AcceptSpaceAct::Pass);
}

TEST(predict_ipc_payload) {
    std::u16string b, t, r;
    CHECK(unpackPredictText(packPredictText(u"tôi đư", u"đư", u"dduw"), b, t, r));
    CHECK(b == u"tôi đư" && t == u"đư" && r == u"dduw");
    CHECK(unpackPredictText(packPredictText(u"cảm ", u"", u""), b, t, r) && t.empty() && r.empty());
    HintMessage m;
    m.request = 3;
    m.job = static_cast<uint32_t>(HintJob::Predict);
    m.flags = kPredictEnglish;
    m.text = packPredictText(u"my keyb", u"keyb", u"keyb");
    std::vector<uint8_t> bytes = packHintMessage(m);
    HintMessage back;
    CHECK(unpackHintMessage(bytes.data(), bytes.size(), back));
    CHECK(back.job == 3 && back.flags == kPredictEnglish && back.text == m.text);
}

TEST(predict_snapshot_mirror_bit) {
    size_t n = 0;
    const BoolKey* keys = boolKeys(&n);
    CHECK(n >= 25 && n <= 64);   // two snapshot words
    CHECK_EQ(std::string(keys[24].name), std::string("systemTextPrediction"));  // appended, never reordered
    CHECK(isSystemMirror(keys[24]));
    for (size_t i = 0; i < 24; ++i) CHECK(!isSystemMirror(keys[i]));
    Settings d;
    CHECK(!d.systemTextPrediction);  // Windows default: off
    Settings s;
    s.systemTextPrediction = true;
    std::vector<uint8_t> b = serialize(s);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(r.systemTextPrediction);
    b[6] = 24;  // a snapshot from before the bit: off
    b[7] = 0;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(!r.systemTextPrediction);
}
