"""Thu gọn cài đặt (docs/SETTINGS-CLEANUP-SPEC.md): 5 trang, công tắc phụ thuộc ẩn theo mục cha,
nhãn chung §3, bộ chọn hồ sơ vẫn phủ đủ key, không nhắc tên bộ gõ khác.

app.py cần GTK nên đọc bằng ast (không import); phần logic nằm ở layout.py (thuần Python).
"""

import ast
import codecs
import io
import os
import re
import sys
import tokenize
import unicodedata
import unittest

HERE = os.path.dirname(__file__)
PKG = os.path.join(HERE, "..", "viettelex_settings")
sys.path.insert(0, os.path.join(HERE, ".."))
from viettelex_settings import config, i18n, layout, onboarding  # noqa: E402


def read(name):
    with open(os.path.join(PKG, name), encoding="utf-8") as f:
        return f.read()


APP = ast.parse(read("app.py"))


def const(node):
    """Literal str / bool / tuple các literal → giá trị Python; khác ⇒ None."""
    try:
        return ast.literal_eval(node)
    except ValueError:
        return None


def calls(tree, attr):
    """Mọi lời gọi self.<attr>(…) trong app.py."""
    return [n for n in ast.walk(tree) if isinstance(n, ast.Call)
            and isinstance(n.func, ast.Attribute) and n.func.attr == attr]


def method(name):
    for n in ast.walk(APP):
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError(name)


def getter(values):
    base = {(s, k): v for s, sec in config.DEFAULTS.items() if isinstance(sec, dict)
            for k, v in sec.items()}
    base.update(values)
    return lambda s, k: base[(s, k)]


class PageTests(unittest.TestCase):
    TITLES = ["Gõ phím", "Gợi ý & công cụ", "Gõ tắt", "Ứng dụng", "Chung"]

    def test_five_pages_in_order(self):
        init = method("__init__")
        order = [c.args[0].func.attr for c in calls(init, "add")
                 if c.args and isinstance(c.args[0], ast.Call)]
        self.assertEqual(order, ["_page_typing", "_page_suggestions", "_page_shortcuts",
                                 "_page_apps", "_page_general"])
        titles = []
        for name in order:
            page = [c for c in ast.walk(method(name)) if isinstance(c, ast.Call)
                    and isinstance(c.func, ast.Attribute) and c.func.attr == "PreferencesPage"]
            kw = {k.arg: k.value for k in page[0].keywords}
            titles.append(kw["title"].args[0].value)
        self.assertEqual(titles, self.TITLES)
        self.assertEqual(len(layout.PAGES), len(self.TITLES))

    def test_no_generic_options_page(self):
        self.assertNotIn("Tuỳ chỉnh", self.TITLES)
        self.assertNotIn("Tuỳ chỉnh", i18n.EN)        # chỉ còn C_("profile", …)

    def test_page_names_and_old_aliases(self):
        self.assertEqual([layout.page_index(p) for p in layout.PAGES], [0, 1, 2, 3, 4])
        self.assertEqual(layout.page_index("options"), 1)
        self.assertEqual(layout.page_index("modes"), 3)
        self.assertEqual(layout.page_index("compat"), 3)
        self.assertEqual(layout.page_index("about"), 4)
        self.assertIsNone(layout.page_index("xyz"))
        self.assertIsNone(layout.page_index(None))

    def test_typing_page_group_order(self):
        # Kiểu gõ · Gõ lẫn tiếng Anh · Chuyển Việt/Anh · Chính tả (§4).
        src = read("app.py")
        pos = [src.index(s) for s in ('PreferencesGroup(title=_("Kiểu gõ"))',
                                      'title=_("Gõ lẫn tiếng Anh")',
                                      'PreferencesGroup(title=_("Chuyển Việt/Anh"))',
                                      'PreferencesGroup(title=_("Chính tả"))')]
        self.assertEqual(pos, sorted(pos))


class DependentTests(unittest.TestCase):
    """§0.4 + bảng §6: dòng con ngay dưới dòng cha cùng nhóm ⇒ ẨN khi cha làm nó vô tác dụng."""

    def test_learn_words_hidden_without_word_prediction(self):
        key = ("general", "learn_words")
        self.assertFalse(layout.row_visible(key, getter({("general", "word_prediction"): False})))
        self.assertTrue(layout.row_visible(key, getter({("general", "word_prediction"): True})))
        # Mặc định: Gợi ý từ tắt ⇒ Học từ bạn gõ ẩn (giá trị key không đổi: vẫn bật).
        self.assertFalse(layout.row_visible(key, getter({})))
        self.assertIs(config.DEFAULTS["general"]["learn_words"], True)

    def test_learn_words_right_under_word_prediction(self):
        keys = [k for k, _t, _s in ast.literal_eval(_assigned("PREDICTION_SWITCHES"))]
        self.assertEqual(keys[:2], ["word_prediction", "learn_words"])

    def test_quote_style_hidden_without_smart_punctuation(self):
        key = ("general", "quote_style")
        self.assertFalse(layout.row_visible(key, getter({("general", "smart_punctuation"): False})))
        self.assertTrue(layout.row_visible(key, getter({("general", "smart_punctuation"): True})))
        # Ngay dưới công tắc cha: smart_punctuation là dòng cuối của AUTO_TEXT_SWITCHES.
        keys = [k for k, _t, _s in ast.literal_eval(_assigned("AUTO_TEXT_SWITCHES"))]
        self.assertEqual(keys[-1], "smart_punctuation")

    def test_retro_hidden_without_context(self):
        key = ("typing", "retroactive_english")
        self.assertFalse(layout.row_visible(key, getter({("typing", "contextual_english"): False})))
        self.assertTrue(layout.row_visible(key, getter({("typing", "contextual_english"): True})))

    def test_collision_and_frequency_hidden_without_auto_restore(self):
        off = getter({("typing", "auto_restore"): False, ("typing", "contextual_english"): True})
        on = getter({("typing", "auto_restore"): True, ("typing", "contextual_english"): True})
        for k in ("collision_prefers_vietnamese", "english_by_frequency"):
            self.assertFalse(layout.row_visible(("typing", k), off), k)
            self.assertTrue(layout.row_visible(("typing", k), on), k)
        # Tần suất cần CẢ hai cha.
        self.assertFalse(layout.row_visible(("typing", "english_by_frequency"), getter(
            {("typing", "auto_restore"): True, ("typing", "contextual_english"): False})))
        # Tắt ngữ cảnh không ẩn "Khi từ vừa Anh vừa Việt".
        self.assertTrue(layout.row_visible(("typing", "collision_prefers_vietnamese"), getter(
            {("typing", "auto_restore"): True, ("typing", "contextual_english"): False})))

    def test_telex_only_hidden_under_vni(self):
        vni = getter({("typing", "input_method"): "vni"})
        telex = getter({("typing", "input_method"): "telex"})
        for k in ("simple_telex", "free_marking", "quick_telex"):
            self.assertFalse(layout.row_visible(("typing", k), vni), k)
            self.assertTrue(layout.row_visible(("typing", k), telex), k)
        # Teencode, phím ngoặc (chạy cả ở VNI) và Bỏ dấu kiểu mới: luôn hiện.
        for k in ("teencode", "auto_circumflex", "bracket_vowels", "modern_tone"):
            self.assertNotIn(("typing", k), layout.VISIBLE_WHEN)
            self.assertTrue(layout.row_visible(("typing", k), vni), k)

    def test_mixed_card_hidden_under_vni_flag_kept(self):
        vni = getter({("typing", "input_method"): "vni"})
        telex = getter({("typing", "input_method"): "telex"})
        self.assertFalse(layout.mixed_card_visible(True, vni))
        self.assertTrue(layout.mixed_card_visible(True, telex))
        self.assertFalse(layout.mixed_card_visible(False, telex))
        # Ẩn vì VNI không xoá cờ: chỉ "Xem"/"Đóng" mới gọi dismiss_card.
        src = ast.unparse(method("_mixed_card"))
        self.assertEqual(src.count("dismiss_card"), 1)
        self.assertIn("mixed_card_visible", ast.unparse(method("_apply_mixed_visibility")))

    def test_parent_change_refreshes_layout_live(self):
        for name in ("switch", "combo"):
            self.assertIn("self.refresh_dependents()", ast.unparse(method(name)), name)
        dep = ast.unparse(method("dependent"))
        self.assertIn("set_visible", dep)
        self.assertNotIn("set_sensitive", dep)
        self.assertNotIn(".set(", dep)

    def test_vni_hides_mixed_group(self):
        """VNI: cả nhóm "Gõ lẫn tiếng Anh" (bộ chọn hồ sơ + Nâng cao) ẩn, thay bằng MỘT dòng
        (SETTINGS-CLEANUP-SPEC §1); Telex hiện lại y như cũ; "Chuyển Việt/Anh" vẫn hiện."""
        vni = getter({("typing", "input_method"): "vni"})
        telex = getter({("typing", "input_method"): "telex"})
        self.assertTrue(layout.mixed_group_hidden(vni))
        self.assertFalse(layout.mixed_group_hidden(telex))
        self.assertFalse(layout.mixed_group_hidden(getter({})))       # mặc định Telex
        self.assertEqual(layout.mixed_group_description(vni), layout.MIXED_VNI_NOTE)
        self.assertEqual(layout.mixed_group_description(telex), layout.MIXED_DESCRIPTION)
        self.assertEqual(layout.MIXED_VNI_NOTE,
                         "Gõ VNI không làm đổi từ tiếng Anh nên không cần chỉnh phần này.")
        self.assertEqual(i18n.EN[layout.MIXED_VNI_NOTE],
                         "VNI leaves English words as typed, so there is nothing to set here.")
        # Chỉ đổi hiển thị: không ghi config.
        src = ast.unparse(method("_apply_mixed_visibility"))
        self.assertNotIn(".set(", src)
        self.assertIn("mixed_group_hidden", src)
        # Bộ chọn hồ sơ và Nâng cao của nhóm đều đi qua bộ ghi dòng (ẩn được); nhóm Chuyển
        # Việt/Anh thì không.
        mixed = ast.unparse(method("_mixed_groups"))
        self.assertIn("self._profile_picker(rec)", mixed)
        self.assertIn("self.advanced(rec,", mixed)
        self.assertEqual(mixed.count("(rec"), 2)
        # Đổi Telex/VNI trong cửa sổ ⇒ bố cục cập nhật ngay.
        self.assertIn("self._apply_mixed_visibility()", ast.unparse(method("_apply_vni_visibility")))
        # "Tuỳ chỉnh" không lộ ra khi nhóm đang ẩn.
        self.assertIn("mixed_group_hidden", ast.unparse(method("_refresh_picker")))

    def test_every_rule_is_wired(self):
        wired = {const(c.args[1]) for c in calls(APP, "dependent") if len(c.args) == 2}
        wired.discard(None)
        # learn_words đi qua vòng lặp PREDICTION_SWITCHES (khoá ("general", key)).
        wired.add(("general", "learn_words"))
        self.assertEqual(set(layout.VISIBLE_WHEN), wired)
        src = read("app.py")
        self.assertFalse("self.telex_only" in src)
        self.assertFalse("set_sensitive(ok)" in src)


def _assigned(name):
    for n in APP.body:
        if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == name:
            # N_("…") ⇒ "…" để literal_eval được.
            return re.sub(r'\bN_\(', "(", ast.unparse(n.value))
    raise AssertionError(name)


class LabelTests(unittest.TestCase):
    """Nhãn chung §3 + không thuật ngữ kỹ thuật ở nhãn."""

    def marked(self):
        sys.path.insert(0, HERE)
        import test_i18n
        return test_i18n.marked_strings()

    def test_shared_labels(self):
        m = self.marked()
        for label in ("Bỏ dấu tự do", "Bỏ dấu kiểu mới (oà, uý)", "Sửa dấu từ đã gõ",
                      "Gợi ý số tiền", "Tự khôi phục từ tiếng Anh", "Học từ bạn gõ",
                      "Gõ lẫn tiếng Anh", "Chuyển Việt/Anh", "Nâng cao",
                      "Gõ tắt phụ âm nhanh (cc→ch, gg→gi…)", "Hiện gạch chân chữ đang gõ"):
            self.assertIn(label, m, label)
        hints = {k: t for k, t, _s in ast.literal_eval(_assigned("HINT_SWITCHES"))}
        self.assertEqual(hints["number_chips"], "Gợi ý số tiền")
        self.assertNotIn("Gõ mixed Việt/Anh", m)
        self.assertEqual(i18n.EN["Gõ lẫn tiếng Anh"], "Mixed Vietnamese/English typing")

    def test_auto_restore_caption_has_examples(self):
        sw = [c for c in calls(APP, "switch") if const(c.args[2]) == "auto_restore"]
        self.assertEqual(len(sw), 1)
        sub = sw[0].args[4].args[0].value
        self.assertIn("google", sub)
        self.assertIn("github", sub)

    def test_no_jargon(self):
        jargon = re.compile(r"preedit|surrounding|composition|\bchips?\b", re.I)
        bad = [s for s in self.marked() if jargon.search(s)]
        bad += [v for v in i18n.EN.values() if jargon.search(v)]
        self.assertEqual(bad, [])

    def test_one_name_per_display_mode(self):
        """Mỗi chế độ hiển thị MỘT tên ở mọi nơi (app cài đặt, hộp Fcitx5, tài liệu): preedit =
        "Soạn từ rồi chèn" (đúng cả khi gạch chân tắt — mặc định), surrounding = "Sửa thẳng
        trong ô". Tên cũ ("Gạch chân chữ đang gõ" cho chế độ, "sửa trực tiếp", "Không gạch
        chân" cho chế độ) không quay lại."""
        src = read("app.py")
        self.assertNotIn('"Gạch chân chữ đang gõ"', src)
        self.assertIn('("preedit", N_("Soạn từ rồi chèn"))', src)
        self.assertIn('("preedit", _("Soạn từ rồi chèn")), ("surrounding", _("Sửa thẳng trong ô"))', src)
        self.assertEqual(i18n.EN["Soạn từ rồi chèn"], "Compose the word, then insert")
        self.assertEqual(i18n.EN["Sửa thẳng trong ô"], "Edit right in the field")
        root = os.path.join(HERE, "..", "..")
        with open(os.path.join(root, "fcitx5", "src", "viettelex.cpp"), encoding="utf-8") as f:
            fx = f.read()
        self.assertIn("Sửa thẳng trong ô", fx)
        self.assertIn("Soạn từ rồi chèn", fx)
        self.assertNotIn("sửa trực tiếp (surrounding)", fx)
        for doc in ("common/SETTINGS.md", "docs/LINUX-SPEC.md", "README.md"):
            with open(os.path.join(root, doc), encoding="utf-8") as f:
                text = f.read()
            self.assertNotIn("*Không gạch chân*", text, doc)
            self.assertNotIn("Sửa trực tiếp", text, doc)
            self.assertNotIn("(sửa trực tiếp)", text, doc)

    def test_captions_are_short(self):
        """Mỗi chú thích trong cửa sổ cài đặt là MỘT dòng ngắn (06/11/2026, cùng giới hạn macOS /
        Windows): mọi chuỗi _()/N_() của SettingsWindow và hằng cấp module ≤ 95 ký tự, vi lẫn en."""
        def literals(node):
            for n in ast.walk(node):
                if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in ("_", "N_") \
                        and n.args and isinstance(n.args[0], ast.Constant) and isinstance(n.args[0].value, str):
                    yield n.args[0].value
        long = []
        for node in APP.body:
            if isinstance(node, ast.Assign) or (isinstance(node, ast.ClassDef) and node.name == "SettingsWindow"):
                for s in literals(node):
                    for t in (s, i18n.EN.get(s, s)):
                        if len(t) > 95:
                            long.append("%d: %s" % (len(t), t))
        self.assertEqual(long, [])

    def test_collision_caption_follows_choice(self):
        """Như macOS: chú thích "Khi từ vừa Anh vừa Việt" chỉ cách lấy dạng kia, đổi theo lựa chọn."""
        m = self.marked()
        self.assertIn("Vd. list → lít. Muốn giữ tiếng Anh, gõ đúp phím dấu: lisst → list.", m)
        self.assertIn("Vd. list giữ nguyên. Muốn ra tiếng Việt, gõ dấu cuối từ: lits → lít.", m)


class ProfilePickerTests(unittest.TestCase):
    """Bộ chọn hồ sơ vẫn phủ ĐỦ key sau khi công tắc dời vào Nâng cao."""

    def test_every_profile_key_has_a_control_that_refreshes_picker(self):
        controls = {}
        for c in calls(APP, "switch") + calls(APP, "combo"):
            key = (const(c.args[1]), const(c.args[2]))
            controls[key] = c
        for key in onboarding.profile_values("mixed"):
            self.assertIn(key, controls, key)
        src = ast.unparse(method("_mixed_groups"))
        for name in ("restore_row", "ctx_row", "retro_row", "freq_row", "start_row"):
            self.assertIn(name, src.split("for r in (")[1].split(")")[0])
        self.assertIn("collision_row.connect('notify::selected', lambda *_a: "
                      "self._refresh_picker())", src)

    def test_pick_profile_still_writes_keys(self):
        import tempfile
        cfg = config.Config(os.path.join(tempfile.mkdtemp(), "config.toml"))
        onboarding.apply_profile(cfg, "en")
        for key, v in onboarding.profile_values("en").items():
            self.assertEqual(cfg.get(*key), v, key)


# Tên các bộ gõ tiếng Việt khác — mã hoá rot13 để chính file test cũng không chứa tên.
_FORBIDDEN = [codecs.decode(p, "rot13") for p in (
    r"\ohavxrl\o", r"\orixrl\o", r"\oybghf\o", r"\oonzobb\o", r"\otb\f*aunau\o",
    r"\obcraxrl\o", r"\ivrgxrl\o", r"\okxrl\o", r"\oynona\f*xrl\o", r"\oivxrl\o")]
# detect.py phải biết tên gói/đường dẫn để phát hiện xung đột — dữ liệu dò, không hiện ra nhãn.
_SCANNED = ("app.py", "compat.py", "config.py", "i18n.py", "layout.py", "onboarding.py",
            "shortcuts.py", "updater.py", "gnome_fcitx5.py", "launchers.py")


def _fold(text):
    text = unicodedata.normalize("NFD", text.replace("đ", "d").replace("Đ", "D"))
    return "".join(ch for ch in text if not unicodedata.combining(ch)).lower()


class NoOtherInputMethodNamesTests(unittest.TestCase):
    def hits(self, text):
        t = _fold(text)
        return [p for p in _FORBIDDEN if re.search(p, t)]

    def test_scanner_works(self):
        self.assertTrue(self.hits(codecs.decode("Tõ Aunau", "rot13")))
        self.assertFalse(self.hits("Gõ tắt phụ âm nhanh, hotkey, max key"))

    def test_ui_strings(self):
        bad = [s[:60] for s in list(i18n.EN) + list(i18n.EN.values()) if self.hits(s)]
        self.assertEqual(bad, [])

    def test_source_strings_and_comments(self):
        bad = []
        for name in _SCANNED:
            for tok in tokenize.generate_tokens(io.StringIO(read(name)).readline):
                if tok.type in (tokenize.STRING, tokenize.COMMENT) and self.hits(tok.string):
                    bad.append("%s:%d %s" % (name, tok.start[0], tok.string[:50]))
        self.assertEqual(bad, [], "\n".join(bad))


if __name__ == "__main__":
    unittest.main()
