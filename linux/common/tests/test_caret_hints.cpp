// test_caret_hints — gợi ý cạnh con trỏ phía bộ gõ (caret_hints.h + Session): cổng kích hoạt
// rẻ (mirror macOS AppTests/CaretSuggestionsTests + MathHintTests: chỉ Tab, Enter chỉ cho phép
// tính, Esc nhớ từ, bộ đếm âm tiết không dấu, tắt ⇒ không làm gì), đuôi văn bản theo dòng phím,
// thế hệ phím ("gõ tiếp là huỷ"), đọc lại màn hình trước khi thay, và HintService chạy
// `viettelex-text-tool --serve` thật (VIETTELEX_TEXT_TOOL, như test common). Logic tính gợi ý
// (Swift) có ca riêng: ctest caret_suggest (viettelex-text-tool --self-test).

#include "viettelex/caret_hints.h"
#include "viettelex/keys.h"
#include "viettelex/session.h"
#include "viettelex/settings.h"

#include "telexcore.h"

#include <atomic>
#include <csignal>
#include <sys/stat.h>
#include <unistd.h>
#include <cctype>
#include <chrono>
#include <mutex>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <string>
#include <thread>
#include <vector>

using namespace viettelex;
using Kind = CaretSuggestion::Kind;

static int g_fail = 0, g_pass = 0;
#define CHECK_EQ(a, b)                                                                         \
    do {                                                                                       \
        auto _a = (a);                                                                         \
        auto _b = (b);                                                                         \
        if (_a == _b) ++g_pass;                                                                \
        else {                                                                                 \
            ++g_fail;                                                                          \
            std::fprintf(stderr, "%s:%d: CHECK_EQ(%s, %s) failed\n", __FILE__, __LINE__, #a, #b); \
        }                                                                                      \
    } while (0)
#define CHECK(x) CHECK_EQ(bool(x), true)

namespace {

void popChars(std::string &s, int n) {
    while (n-- > 0 && !s.empty()) {
        size_t i = s.size() - 1;
        while (i > 0 && (static_cast<unsigned char>(s[i]) & 0xc0) == 0x80) --i;
        s.resize(i);
    }
}

struct Mock : InputContext {
    std::string doc, pre, shown;
    bool surrounding = true, selection = false;
    int hides = 0;
    int wholeReads = 0;  // textBeforeCursor (the whole paragraph) — the Session asks for tails
    void setPreedit(const std::string &s, bool) override { pre = s; }
    void commit(const std::string &s) override { doc += s; }
    void deleteBeforeCursor(int n) override { popChars(doc, n); }
    bool textBeforeCursor(std::string &out) override {
        if (!surrounding) return false;
        ++wholeReads;
        out = doc;
        return true;
    }
    bool textBeforeCursorTail(size_t maxChars, std::string &out) override {
        if (!surrounding) return false;
        size_t i = doc.size();
        for (size_t n = 0; i > 0 && n < maxChars; ++n) {
            --i;
            while (i > 0 && (static_cast<unsigned char>(doc[i]) & 0xc0) == 0x80) --i;
        }
        out = doc.substr(i);
        return true;
    }
    bool hasSelection() override { return selection; }
    void showHint(const std::string &l) override { shown = l; }
    void hideHint() override {
        shown.clear();
        ++hides;
    }
};

// Returns whether the IM consumed the key; otherwise does what the app would.
bool press(Session &s, Mock &m, uint32_t keysym, uint32_t unicode, uint32_t mods = 0) {
    KeyEvent ev;
    ev.keysym = keysym;
    ev.unicode = unicode;
    ev.mods = mods;
    bool consumed = s.processKey(ev, m);
    ev.release = true;
    s.processKey(ev, m);
    if (consumed || (mods & (VT_MOD_CTRL | VT_MOD_ALT | VT_MOD_SUPER))) return consumed;
    if (keysym == ks::BackSpace) popChars(m.doc, 1);
    else if (keysym == ks::Return) m.doc += "\n";
    else if (keysym == ks::Tab) m.doc += "\t";
    else if (unicode >= 0x20 && unicode != 0x7f) {
        std::string u;
        if (unicode < 0x80) u = char(unicode);
        m.doc += u;
    }
    return consumed;
}

// '<' BackSpace, '\n' Return, '\t' Tab, '>' Right arrow, '~' Escape.
void type(Session &s, Mock &m, const std::string &keys) {
    for (char c : keys) {
        switch (c) {
        case '<': press(s, m, ks::BackSpace, 0); break;
        case '\n': press(s, m, ks::Return, '\r'); break;
        case '\t': press(s, m, ks::Tab, '\t'); break;
        case '>': press(s, m, ks::Right, 0); break;
        case '~': press(s, m, ks::Escape, 0x1b); break;
        default: press(s, m, uint32_t((unsigned char)c), uint32_t((unsigned char)c));
        }
    }
}

bool tab(Session &s, Mock &m) { return press(s, m, ks::Tab, '\t'); }

std::string req(std::vector<std::string> f) { return hints::request(f); }

struct Rig {
    Session s;
    Mock m;
    std::vector<HintRequest> reqs;
    explicit Rig(Settings st = Settings(), DisplayMode mode = DisplayMode::Preedit, bool edits = true) {
        s.applySettings(st);
        s.setDisplayMode(mode, m);
        s.setSurroundingEdits(edits);
        s.setHintSink([this](const HintRequest &r) { reqs.push_back(r); });
    }
    std::string last() const { return reqs.empty() ? std::string() : reqs.back().line; }
    // The helper's answer for the last request.
    void answer(const CaretSuggestion &c) { s.deliverHint(reqs.back().gen, c, m); }
};

CaretSuggestion S(Kind k, std::string d, std::string r, std::string i) {
    CaretSuggestion c;
    c.kind = k;
    c.display = std::move(d);
    c.replace = std::move(r);
    c.insert = std::move(i);
    return c;
}

const std::string kUnknown = "\xef\xbf\xbc";

// MARK: pure gates

void testKeyRules() {
    using hints::KeyAction;
    for (Kind k : {Kind::Number, Kind::Typo, Kind::Tones, Kind::Date}) {
        CHECK(hints::keyAction(k, ks::Tab, 0) == KeyAction::Accept);
        CHECK(hints::keyAction(k, ks::Return, 0) == KeyAction::DismissPass);  // Enter = gửi tin / xuống dòng
        CHECK(hints::keyAction(k, ks::Escape, 0) == KeyAction::DismissConsume);
        CHECK(hints::keyAction(k, ks::space, 0) == KeyAction::DismissPass);
        CHECK(hints::keyAction(k, ks::Tab, VT_MOD_SHIFT) == KeyAction::DismissPass);  // Shift+Tab
        CHECK(hints::keyAction(k, ks::Escape, VT_MOD_CTRL) == KeyAction::DismissPass);
    }
    CHECK(hints::keyAction(Kind::Math, ks::Return, 0) == KeyAction::Accept);
    CHECK(hints::keyAction(Kind::Math, ks::KP_Enter, 0) == KeyAction::Accept);
    CHECK(hints::keyAction(Kind::Math, ks::Tab, 0) == KeyAction::Accept);
    CHECK(hints::keyAction(Kind::Math, '1', 0) == KeyAction::DismissPass);  // "5+5=" rồi tự gõ "10"
    CHECK_EQ(hints::label(S(Kind::Math, "= 36", "", "36")), std::string("= 36   Tab / Enter"));
    CHECK_EQ(hints::label(S(Kind::Typo, "tôi", "tpoi ", "tôi ")), std::string("tôi   Tab"));
}

void testProtocol() {
    CHECK_EQ(hints::escape("a\tb\nc\\d\re"), std::string("a\\tb\\nc\\\\d\\re"));
    CHECK_EQ(req({"math", "12*3="}), std::string("math\t12*3="));
    CaretSuggestion c;
    CHECK(hints::parseAnswer("number\t1.200.000 ₫\t1tr2 \t1.200.000 ₫ ", c));
    CHECK(c == S(Kind::Number, "1.200.000 ₫", "1tr2 ", "1.200.000 ₫ "));
    CHECK(hints::parseAnswer("math\t= 36\t\t36", c));
    CHECK(c == S(Kind::Math, "= 36", "", "36"));
    CHECK(hints::parseAnswer("tones\ttôi đi học\tdong\\n1\ttôi", c));
    CHECK_EQ(c.replace, std::string("dong\n1"));
    CHECK(!hints::parseAnswer("-", c));
    CHECK(!hints::parseAnswer("", c));
    CHECK(!hints::parseAnswer("lạ\ta\tb\tc", c));
    CHECK(!hints::parseAnswer("typo\ttôi\t\ttôi", c));    // sửa lỗi phải thay gì đó
    CHECK(!hints::parseAnswer("math\t= 3\tx\t3", c));     // phép tính chỉ chèn
    CHECK(!hints::parseAnswer("typo\ttôi\ttpoi", c));     // thiếu trường
}

void testGates() {
    CHECK(hints::numberWorthChecking(' ', "1tr2", ""));
    CHECK(hints::numberWorthChecking(' ', "tỷ", "2"));
    CHECK(hints::numberWorthChecking(' ', "triệu", "15"));
    CHECK(!hints::numberWorthChecking(' ', "hello", "word"));
    CHECK(!hints::numberWorthChecking(',', "50k", ""));
    CHECK(!hints::numberWorthChecking(' ', "", "5"));

    CHECK(hints::dateCandidate(' ', "hôm", "nay"));
    CHECK(hints::dateCandidate(' ', "Hôm", "qua"));
    CHECK(hints::dateCandidate(' ', "HÔM", "NAY"));
    CHECK(hints::dateCandidate(' ', "ngày", "mai"));
    CHECK(hints::dateCandidate(' ', "bây", "giờ"));
    CHECK(hints::dateCandidate(' ', "you", "tomorrow"));  // tiếng Anh: helper kiểm từ trước
    CHECK(!hints::dateCandidate(' ', "", "now"));
    CHECK(!hints::dateCandidate(' ', "gặp", "today"));
    CHECK(!hints::dateCandidate(',', "hôm", "nay"));
    CHECK(!hints::dateCandidate(' ', "hom", "nay"));
    CHECK(!hints::dateCandidate(' ', "hôm", "sau"));
    CHECK(hints::dateCandidate(' ', "âm", "lịch"));  // âm lịch
    CHECK(hints::dateCandidate(' ', "Âm", "lịch"));
    CHECK(hints::dateCandidate(' ', "ÂM", "LỊCH"));
    CHECK(hints::dateCandidate(' ', "ngày", "âm"));
    CHECK(hints::dateCandidate(' ', "", "ÂL"));
    CHECK(hints::dateCandidate(' ', "là", "âl"));
    CHECK(!hints::dateCandidate(',', "âm", "lịch"));
    CHECK(!hints::dateCandidate(' ', "am", "lich"));
    CHECK(!hints::dateCandidate(' ', "", "al"));
    CHECK(hints::dateCandidate(' ', "", "Tết"));  // Tết kế tiếp
    CHECK(hints::dateCandidate(' ', "ăn", "tết"));
    CHECK(hints::dateCandidate(' ', "", "TẾT"));
    CHECK(!hints::dateCandidate(' ', "", "tếtt"));
    CHECK(!hints::dateCandidate(' ', "", "tet"));
    CHECK(!hints::dateCandidate(',', "", "Tết"));

    // = TypoFixLogic.worthChecking (testTypoGateOnlyInvalidLetterWordsAtBoundary)
    CHECK(hints::typoWorthChecking(' ', "tpoi", "tpoi"));
    CHECK(hints::typoWorthChecking(',', "tpoi", "tpoi"));
    CHECK(!hints::typoWorthChecking('.', "tpoi", "tpoi"));
    CHECK(!hints::typoWorthChecking('\'', "tpoi", "tpoi"));
    CHECK(!hints::typoWorthChecking('\n', "tpoi", "tpoi"));
    CHECK(!hints::typoWorthChecking(' ', "tooi", "tôi"));
    CHECK(!hints::typoWorthChecking(' ', "kp", "kp"));
    CHECK(!hints::typoWorthChecking(' ', "tp1i", "tp1i"));
    CHECK(!hints::typoWorthChecking(' ', "tpoi", "(tpoi"));

    CHECK(vt_is_valid_syllable("tôi", true));
    CHECK(!vt_is_valid_syllable("tpoi", true));
    CHECK(vt_is_unaccented_syllable("toi"));
    CHECK(vt_is_unaccented_syllable("hoc"));  // vần tắc: học/hóc
    CHECK(vt_is_unaccented_syllable("toi,"));
    CHECK(vt_is_unaccented_syllable("TOI"));
    CHECK(!vt_is_unaccented_syllable("tOi"));
    CHECK(!vt_is_unaccented_syllable("the"));  // mở mạch tiếng Anh
    CHECK(!vt_is_unaccented_syllable("tôi"));
    CHECK(!vt_is_unaccented_syllable(""));

    CHECK_EQ(hints::lower("Tpoi ĐÂY Ờ"), std::string("tpoi đây ờ"));
    hints::Rejected r(2);
    r.add("Tpoi");
    CHECK(r.contains("tpoi") && r.contains("TPOI"));
    r.add("khpong");
    r.add("nhuq");
    CHECK(!r.contains("tpoi"));  // chỉ giữ `cap` từ gần nhất
    CHECK(r.contains("nhuq"));
}

// = testToneTrackerTriggers: mỗi ranh giới báo cụm đã chốt ngay trước nó.
std::vector<hints::ToneTrigger> feed(hints::ToneTracker &t, const std::string &text) {
    std::vector<hints::ToneTrigger> out;
    std::string chunk;
    for (size_t i = 0; i < text.size();) {
        unsigned char b = static_cast<unsigned char>(text[i]);
        size_t n = b < 0x80 ? 1 : (b >> 5) == 6 ? 2 : (b >> 4) == 14 ? 3 : 4;
        std::string ch = text.substr(i, n);
        i += n;
        bool letter = n > 1 || std::isalnum(b);
        if (letter) {
            chunk += ch;
            continue;
        }
        out.push_back(t.feed(chunk, b));
        chunk = (b == ' ' || b == '\n') ? std::string() : chunk + ch;
    }
    return out;
}

void testToneTracker() {
    using T = hints::ToneTrigger;
    using V = std::vector<T>;
    hints::ToneTracker t;
    CHECK(feed(t, "toi di hoc ") == V({T::None, T::None, T::Pause}));
    CHECK(feed(t, "hom nay ") == V({T::Pause, T::Pause}));
    t.reset();
    CHECK(feed(t, "toi di hoc.") == V({T::None, T::None, T::SentenceEnd}));
    CHECK(feed(t, " roi ") == V({T::None, T::None}));
    t.reset();
    CHECK(feed(t, "toi, di hoc ") == V({T::None, T::None, T::None, T::Pause}));
    t.reset();
    CHECK(feed(t, "tôi di hoc ") == V({T::None, T::None, T::None}));
    t.reset();
    CHECK(feed(t, "the cat is ") == V({T::None, T::None, T::None}));
    t.reset();
    CHECK(feed(t, "toi di\nhoc ") == V({T::None, T::None, T::None}));
    t.reset();
    CHECK(feed(t, "a b ") == V({T::None, T::None}));
}

// MARK: Session

void testOffMeansNoWork() {
    Settings off;
    off.mathResults = off.numberChips = off.typoHints = off.toneHints = off.dateHints = false;
    Rig r(off);
    type(r.s, r.m, "12*3= tpoi hoom nay 1tr2 ");
    CHECK(r.reqs.empty());
    CHECK_EQ(r.s.typedBefore(), kUnknown);  // không theo dõi gì
    // Không có helper (sink chưa đặt) ⇒ cũng không làm gì dù cài đặt bật.
    Session s;
    Mock m;
    s.applySettings(Settings());
    type(s, m, "12*3=");
    CHECK_EQ(s.typedBefore(), kUnknown);
    CHECK(!s.hint());
}

void testMathTabAndEnter() {
    Rig r;
    type(r.s, r.m, "12*3=");
    CHECK_EQ(r.last(), req({"math", "12*3="}));
    r.answer(S(Kind::Math, "= 36", "", "36"));
    CHECK(r.s.hint() != nullptr);
    CHECK_EQ(r.m.shown, std::string("= 36   Tab / Enter"));
    CHECK(tab(r.s, r.m));
    CHECK_EQ(r.m.doc, std::string("12*3=36"));
    CHECK(!r.s.hint());
    CHECK(r.m.shown.empty());

    Rig e;
    type(e.s, e.m, "125 x (4 + 5.5) =");
    CHECK_EQ(e.last(), req({"math", "125 x (4 + 5.5) ="}));
    e.answer(S(Kind::Math, "= 1187.5", "", "1187.5"));
    CHECK(press(e.s, e.m, ks::Return, '\r'));
    CHECK_EQ(e.m.doc, std::string("125 x (4 + 5.5) =1187.5"));

    // Phím khác: tắt gợi ý, phím đi tiếp như thường.
    Rig d;
    type(d.s, d.m, "5+5=");
    d.answer(S(Kind::Math, "= 10", "", "10"));
    type(d.s, d.m, "10");
    CHECK_EQ(d.m.doc, std::string("5+5=10"));
    CHECK(!d.s.hint());
    CHECK(d.m.hides == 1);

    // Tab khi không có gợi ý: không nuốt.
    Rig n;
    type(n.s, n.m, "ab");
    CHECK(!tab(n.s, n.m));
}

void testMathWithoutSurrounding() {
    // Chrome/Firefox (không được sửa chữ quanh con trỏ): phép tính vẫn được (chỉ chèn),
    // văn bản trước đuôi không biết (U+FFFC).
    Rig r(Settings(), DisplayMode::Preedit, false);
    type(r.s, r.m, "12*3=");
    CHECK_EQ(r.last(), req({"math", kUnknown + "12*3="}));
    Rig t(Settings(), DisplayMode::Preedit, false);
    type(t.s, t.m, "1tr2 hoom nay tpoi ");
    CHECK(t.reqs.empty());  // mọi loại thay chữ: không
}

void testNumberChip() {
    Rig r;
    r.m.doc = "giá ";
    type(r.s, r.m, "1tr2 ");
    CHECK_EQ(r.last(), req({"number", "giá 1tr2 "}));  // đuôi neo từ surrounding
    r.answer(S(Kind::Number, "1.200.000 ₫", "1tr2 ", "1.200.000 ₫ "));
    CHECK(tab(r.s, r.m));
    CHECK_EQ(r.m.doc, std::string("giá 1.200.000 ₫ "));
    CHECK_EQ(r.s.typedBefore(), std::string("giá 1.200.000 ₫ "));
    type(r.s, r.m, "2 tyr ");
    CHECK_EQ(r.last(), req({"number", "giá 1.200.000 ₫ 2 tỷ "}));
}

void testTypoFix() {
    Rig r;
    type(r.s, r.m, "anh tpoi ");
    CHECK_EQ(r.last(), req({"typo", "anh tpoi ", "tpoi", " ", "tpoi", "10100001100"}));
    r.answer(S(Kind::Typo, "tôi", "tpoi ", "tôi "));
    CHECK_EQ(r.m.shown, std::string("tôi   Tab"));
    CHECK(tab(r.s, r.m));
    CHECK_EQ(r.m.doc, std::string("anh tôi "));

    // Giữ ký tự ranh giới; Esc = không gợi ý lại từ đó (trong phiên).
    Rig e;
    type(e.s, e.m, "tpoi,");
    CHECK_EQ(e.last(), req({"typo", "tpoi,", "tpoi", ",", "tpoi", "10100001100"}));
    e.answer(S(Kind::Typo, "tôi", "tpoi,", "tôi,"));
    type(e.s, e.m, "~");
    CHECK(!e.s.hint());
    CHECK_EQ(e.m.doc, std::string("tpoi,"));  // Esc bị nuốt, không đổi gì
    size_t before = e.reqs.size();
    type(e.s, e.m, " Tpoi ");
    CHECK_EQ(e.reqs.size(), before);  // TPOI/tpoi đã bị từ chối

    // Âm tiết hợp lệ / sau dấu chấm: không hỏi helper.
    Rig v;
    type(v.s, v.m, "tooi tpoi.");
    CHECK(v.reqs.empty());
    // Âm tiết thiếu dấu ("hoc" = học/hóc) không phải lỗi gõ — không che mất Thêm dấu.
    Rig h;
    type(h.s, h.m, "hoc ");
    CHECK(h.reqs.empty());

    // VNI: cờ engine đi cùng yêu cầu.
    Settings vni;
    vni.vni = true;
    Rig n(vni);
    type(n.s, n.m, "tpoi ");
    CHECK_EQ(n.last(), req({"typo", "tpoi ", "tpoi", " ", "tpoi", "10100101100"}));
}

void testDateHint() {
    Rig r;
    r.m.doc = "Hẹn ";
    type(r.s, r.m, "hoom nay ");
    CHECK(!r.reqs.empty());
    std::string l = r.last();
    CHECK_EQ(l.substr(0, l.find("\t2")), req({"date", "Hẹn hôm nay ", "hôm", "nay", " "}));
    r.answer(S(Kind::Date, "28/09/2026", "hôm nay ", "28/09/2026 "));
    CHECK(tab(r.s, r.m));
    CHECK_EQ(r.m.doc, std::string("Hẹn 28/09/2026 "));

    // Âm lịch: "âm lịch " / "ngày âm " → helper; Tab thay cụm.
    Rig a;
    type(a.s, a.m, "aam lichj ");
    CHECK(!a.reqs.empty());
    l = a.last();
    CHECK_EQ(l.substr(0, l.find("\t2")), req({"date", "âm lịch ", "âm", "lịch", " "}));
    a.answer(S(Kind::Date, "30/9 năm Bính Ngọ", "âm lịch ", "30/9 năm Bính Ngọ "));
    CHECK(tab(a.s, a.m));
    CHECK_EQ(a.m.doc, std::string("30/9 năm Bính Ngọ "));
    Rig n;
    type(n.s, n.m, "ngayf aam ");
    CHECK(!n.reqs.empty());
    l = n.last();
    CHECK_EQ(l.substr(0, l.find("\t2")), req({"date", "ngày âm ", "ngày", "âm", " "}));

    // Tết kế tiếp: "Tết " → helper; Tab GIỮ chữ Tết, nối ngày.
    Rig t;
    type(t.s, t.m, "Teets ");
    CHECK(!t.reqs.empty());
    l = t.last();
    CHECK_EQ(l.substr(0, l.find("\t2")), req({"date", "Tết ", "", "Tết", " "}));
    t.answer(S(Kind::Date, "06/02/2027", "Tết ", "Tết 06/02/2027 "));
    CHECK(tab(t.s, t.m));
    CHECK_EQ(t.m.doc, std::string("Tết 06/02/2027 "));
}

void testToneRun() {
    Settings st;
    st.toneHints = true;
    Rig r(st);
    type(r.s, r.m, "toi di hoc ");
    CHECK_EQ(r.reqs.size(), size_t(1));
    CHECK_EQ(r.last(), req({"tones", "toi di hoc "}));
    CHECK_EQ(r.reqs.back().delayMs, 900);  // dừng gõ 0.9 s sau dấu cách
    Rig p(st);
    type(p.s, p.m, "toi di hoc.");
    CHECK_EQ(p.last(), req({"tones", "toi di hoc."}));
    CHECK_EQ(p.reqs.back().delayMs, 0);
    p.answer(S(Kind::Tones, "tôi đi học.", "toi di hoc.", "tôi đi học."));
    CHECK(tab(p.s, p.m));
    CHECK_EQ(p.m.doc, std::string("tôi đi học."));
    // Esc: không mời lại cụm bắt đầu bằng cụm vừa từ chối.
    Rig d(st);
    type(d.s, d.m, "toi di hoc ");
    d.answer(S(Kind::Tones, "tôi đi học", "toi di hoc ", "tôi đi học "));
    type(d.s, d.m, "~hom ");
    d.answer(S(Kind::Tones, "tôi đi học hôm", "toi di hoc hom ", "tôi đi học hôm "));
    CHECK(!d.s.hint());
    // Tắt (mặc định): không đếm, không hỏi.
    Rig off;
    type(off.s, off.m, "toi di hoc ban oi.");
    CHECK(off.reqs.empty());
}

void testGenerationAndScreenChecks() {
    // Gõ tiếp trước khi helper trả lời ⇒ bỏ kết quả.
    Rig r;
    type(r.s, r.m, "12*3=");
    uint64_t gen = r.reqs.back().gen;
    CHECK(r.reqs.back().liveGen && r.reqs.back().liveGen->load() == gen);
    type(r.s, r.m, " ");
    CHECK(r.reqs.back().liveGen->load() != gen);  // việc nền đang chờ biết là đã cũ
    r.s.deliverHint(gen, S(Kind::Math, "= 36", "", "36"), r.m);
    CHECK(!r.s.hint());

    // Đuôi không còn kết thúc bằng chữ sẽ thay ⇒ không hiện.
    Rig t;
    type(t.s, t.m, "tpoi ");
    t.answer(S(Kind::Typo, "tôi", "tpai ", "tôi "));
    CHECK(!t.s.hint());

    // Màn hình đổi dưới tay (app tự sửa) ⇒ Tab không thay, đi tiếp như Tab thường.
    Rig m;
    type(m.s, m.m, "tpoi ");
    m.answer(S(Kind::Typo, "tôi", "tpoi ", "tôi "));
    m.m.doc = "tpoi x";
    CHECK(!tab(m.s, m.m));
    CHECK_EQ(m.m.doc, std::string("tpoi x\t"));
    CHECK(!m.s.hint());

    // Có vùng chọn ⇒ không xoá.
    Rig sel;
    type(sel.s, sel.m, "1tr2 ");
    sel.answer(S(Kind::Number, "1.200.000 ₫", "1tr2 ", "1.200.000 ₫ "));
    sel.m.selection = true;
    CHECK(!tab(sel.s, sel.m));

    // Mất focus / click: ẩn ngay.
    Rig f;
    type(f.s, f.m, "12*3=");
    f.answer(S(Kind::Math, "= 36", "", "36"));
    f.s.finish(f.m);
    CHECK(!f.s.hint());
    CHECK(f.m.shown.empty());
}

void testTailFollowsKeys() {
    Rig r;
    type(r.s, r.m, "12*4<3=");
    CHECK_EQ(r.last(), req({"math", "12*3="}));
    type(r.s, r.m, "\nabc ");
    CHECK_EQ(r.s.typedBefore(), std::string("\nabc "));
    type(r.s, r.m, ">");  // mũi tên: con trỏ đi đâu không biết
    CHECK_EQ(r.s.typedBefore(), kUnknown);
    // Gõ tắt nở: đuôi là chữ nở ra.
    Settings sc;
    auto t = std::make_shared<ShortcutTable>();
    (*t)["vn"] = "Việt Nam";
    sc.shortcuts = t;
    Rig g(sc);
    type(g.s, g.m, "vn ");
    CHECK_EQ(g.s.typedBefore(), std::string("Việt Nam "));
    // Tiếng Anh tự khôi phục: đuôi là chữ trên màn hình.
    Rig a(Settings(), DisplayMode::Surrounding);
    type(a.s, a.m, "tesst ");
    CHECK_EQ(a.s.typedBefore(), a.m.doc);
}

// Seeding the typed tail and checking the screen before Tab read only the characters they
// need — a long paragraph before the caret is never copied whole on a key.
void testTailReadsOnlyWhatItNeeds() {
    Rig r(Settings(), DisplayMode::Surrounding);
    r.m.doc = std::string(1000, 'x') + " ";
    type(r.s, r.m, "12*3=");
    CHECK_EQ(r.last(), req({"math", kUnknown + std::string(319, 'x') + " 12*3="}));
    CHECK_EQ(r.m.wholeReads, 0);
    // Exactly 320 characters before the caret: all of it, known to start the text.
    Rig k(Settings(), DisplayMode::Surrounding);
    k.m.doc = std::string(319, 'y') + " ";
    type(k.s, k.m, "12*3=");
    CHECK_EQ(k.last(), req({"math", std::string(319, 'y') + " 12*3="}));
    // Tab on a typo fix after a long paragraph.
    Rig t(Settings(), DisplayMode::Surrounding);
    t.m.doc = std::string(1000, 'z') + " ";
    type(t.s, t.m, "anh tpoi ");
    t.answer(S(Kind::Typo, "tôi", "tpoi ", "tôi "));
    CHECK(tab(t.s, t.m));
    CHECK_EQ(t.m.doc, std::string(1000, 'z') + " anh tôi ");
    CHECK_EQ(t.m.wholeReads, 0);
}

// English words of the engine's list: the helper's TypoFixLogic.isKnown answers "no fix",
// so they are not sent at all (typing English used to wake the 13 MB helper on every word).
void testTypoSkipsKnownEnglish() {
    CHECK(hints::typoWorthChecking(' ', "with", "with"));  // would have been sent
    CHECK(vt_is_english_word("with"));
    CHECK(hints::typoKnownEnglish("With"));
    CHECK(hints::typoKnownEnglish("BECAUSE"));
    CHECK(!hints::typoKnownEnglish("tpoi"));
    CHECK(!hints::typoKnownEnglish("thoi"));
    CHECK(!hints::typoKnownEnglish(""));
    CHECK(!hints::typoKnownEnglish("wíth"));
    Rig r;
    type(r.s, r.m, "with through Because, ");
    CHECK(r.reqs.empty());
    type(r.s, r.m, "tpoi ");
    CHECK_EQ(r.reqs.size(), size_t(1));  // a real typo still goes to the helper
}

void testPasswordAndEnglish() {
    Rig r;
    r.s.setPassthrough(true, r.m);
    type(r.s, r.m, "12*3= tpoi ");
    CHECK(r.reqs.empty());
    Rig e;
    e.s.setVietnamese(false, e.m);
    type(e.s, e.m, "12*3=");
    CHECK(e.reqs.empty());
}

void testDirectMode() {
    // Terminal (Direct): không đọc màn hình — dòng phím sau khi neo (dấu cách) mới dùng được.
    Rig r(Settings(), DisplayMode::Direct, false);
    type(r.s, r.m, "echo 1tr2 ");
    CHECK_EQ(r.last(), req({"number", kUnknown + "echo 1tr2 "}));
    r.answer(S(Kind::Number, "1.200.000 ₫", "1tr2 ", "1.200.000 ₫ "));
    CHECK(tab(r.s, r.m));
    CHECK_EQ(r.m.doc, std::string("echo 1.200.000 ₫ "));
}

// MARK: HintService robustness (fake helpers, no Swift needed)

std::string fakeHelper(const std::string &dir, const std::string &name, const std::string &body) {
    std::string p = dir + "/" + name;
    FILE *f = std::fopen(p.c_str(), "w");
    std::fprintf(f, "#!/bin/sh\n%s\n", body.c_str());
    std::fclose(f);
    chmod(p.c_str(), 0755);
    return p;
}

int countLines(const std::string &path) {
    FILE *f = std::fopen(path.c_str(), "r");
    if (!f) return 0;
    int n = 0;
    for (int c; (c = std::fgetc(f)) != EOF;) n += c == '\n';
    std::fclose(f);
    return n;
}

// A helper that dies at start (broken install / missing data) was respawned twice per word
// forever; now spawning pauses after kMaxFailures deaths in a row.
void testHelperDyingAtStartBacksOff() {
    char tmpl[] = "/tmp/vt-hint-XXXXXX";
    const char *d = mkdtemp(tmpl);
    if (!d) { ++g_fail; return; }
    const std::string dir = d, log = dir + "/spawns";
    std::string helper = fakeHelper(dir, "dies", "echo x >> '" + log + "'; exit 3");
    HintService svc([](std::function<void()>) {}, helper);
    std::string ans;
    for (int i = 0; i < 10; ++i) CHECK(!svc.query("math 1+1=", ans, 2000));
    CHECK_EQ(countLines(log), HintService::kMaxFailures);
    CHECK_EQ(svc.helperPid(), -1);
    std::remove(log.c_str());
    std::remove(helper.c_str());
    rmdir(d);
}

// After its 2-minute idle exit nobody waited for the helper: a zombie until the next word.
void testExitedHelperIsReaped() {
    char tmpl[] = "/tmp/vt-hint-XXXXXX";
    const char *d = mkdtemp(tmpl);
    if (!d) { ++g_fail; return; }
    const std::string dir = d;
    // Answers once, then quits (like the idle exit).
    std::string helper = fakeHelper(dir, "once", "read l; echo none; exit 0");
    HintService svc([](std::function<void()>) {}, helper);
    std::string ans;
    CHECK(svc.query("math 1+1=", ans, 2000));
    CHECK_EQ(ans, std::string("none"));
    int pid = svc.helperPid();
    CHECK(pid > 0);
    bool reaped = false;
    for (int i = 0; i < 200 && !reaped; ++i) {  // ≤ 2 s for the shell to exit
        reaped = svc.reapExitedHelper();
        if (!reaped) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    CHECK(reaped);
    CHECK_EQ(svc.helperPid(), -1);
    CHECK(kill(pid, 0) != 0);  // gone for good, not a zombie
    // The next request simply spawns it again (not counted as a failure).
    CHECK(svc.query("math 1+1=", ans, 2000));
    std::remove(helper.c_str());
    rmdir(d);
}

// MARK: HintService + viettelex-text-tool --serve (real helper)

void testHintServiceEndToEnd() {
    const char *tool = std::getenv("VIETTELEX_TEXT_TOOL");
    if (!tool || !*tool) {
        std::printf("(skip HintService: VIETTELEX_TEXT_TOOL unset)\n");
        return;
    }
    std::mutex mu;
    std::deque<std::function<void()>> mainQueue;
    HintService svc([&](std::function<void()> f) {
        std::lock_guard<std::mutex> l(mu);
        mainQueue.push_back(std::move(f));
    });
    CHECK(svc.available());
    std::string ans;
    CHECK(svc.query("ping", ans));
    CHECK_EQ(ans, std::string("ok"));
    CHECK(svc.query(req({"math", "12*3="}), ans));
    CHECK_EQ(ans, std::string("math\t= 36\t\t36"));
    CHECK(svc.query(req({"typo", "anh tpoi ", "tpoi", " ", "tpoi", "1010000110"}), ans));
    CHECK_EQ(ans, std::string("typo\ttôi\ttpoi \ttôi "));
    CHECK(svc.query(req({"number", "hello "}), ans));
    CHECK_EQ(ans, std::string("-"));

    auto drain = [&](int ms) {
        auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        while (std::chrono::steady_clock::now() < until) {
            std::function<void()> f;
            {
                std::lock_guard<std::mutex> l(mu);
                if (!mainQueue.empty()) {
                    f = std::move(mainQueue.front());
                    mainQueue.pop_front();
                }
            }
            if (f) f();
            else std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    };

    // Session → HintService → helper → deliverHint → Tab.
    Session s;
    Mock m;
    s.applySettings(Settings());
    s.setSurroundingEdits(true);
    s.setHintSink([&](const HintRequest &r) {
        uint64_t gen = r.gen;
        svc.submit(r, [&, gen](bool ok, const CaretSuggestion &c) {
            if (ok) s.deliverHint(gen, c, m);
        });
    });
    type(s, m, "gias 50k ");
    drain(1500);
    CHECK(s.hint() != nullptr);
    CHECK_EQ(m.shown, std::string("50.000 ₫   Tab"));
    CHECK(tab(s, m));
    CHECK_EQ(m.doc, std::string("giá 50.000 ₫ "));

    // Latest wins; a request whose generation moved on is dropped.
    std::atomic<int> calls{0};
    auto gen = std::make_shared<std::atomic<uint64_t>>(1);
    HintRequest a;
    a.line = req({"math", "1+1="});
    a.gen = 1;
    a.liveGen = gen;
    a.delayMs = 300;
    svc.submit(a, [&](bool, const CaretSuggestion &) { ++calls; });
    gen->store(2);  // a key arrived
    drain(700);
    CHECK_EQ(calls.load(), 0);
    HintRequest b = a;
    b.gen = 2;
    b.delayMs = 0;
    CaretSuggestion got;
    svc.submit(b, [&](bool, const CaretSuggestion &c) {
        ++calls;
        got = c;
    });
    drain(800);
    CHECK_EQ(calls.load(), 1);
    CHECK_EQ(got.insert, std::string("2"));
}

}  // namespace

int main() {
    testKeyRules();
    testProtocol();
    testGates();
    testToneTracker();
    testOffMeansNoWork();
    testMathTabAndEnter();
    testMathWithoutSurrounding();
    testNumberChip();
    testTypoFix();
    testDateHint();
    testToneRun();
    testGenerationAndScreenChecks();
    testTailFollowsKeys();
    testTailReadsOnlyWhatItNeeds();
    testTypoSkipsKnownEnglish();
    testPasswordAndEnglish();
    testDirectMode();
    testHelperDyingAtStartBacksOff();
    testExitedHelperIsReaped();
    testHintServiceEndToEnd();
    std::printf("caret hint tests: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
