import os
import sys
import tempfile
import os
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from viettelex_settings import config  # noqa: E402

CONTRACT_EXAMPLE = '''
[typing]
input_method = "telex"              # "telex" | "vni"
simple_telex = false                # w đứng một mình không thành ư
free_marking = true
[general]
display_mode = "preedit"            # comment
toggle_hotkey = "Ctrl+space"
[app_modes]
# key = định danh app
"org.gnome.texteditor" = "surrounding"
"kitty" = "preedit"
'''


class ParseTests(unittest.TestCase):
    def test_contract_example(self):
        d = config.parse(CONTRACT_EXAMPLE)
        self.assertEqual(d["typing"]["input_method"], "telex")
        self.assertIs(d["typing"]["simple_telex"], False)
        self.assertEqual(d["general"]["toggle_hotkey"], "Ctrl+space")
        self.assertEqual(d["app_modes"], {"org.gnome.texteditor": "surrounding", "kitty": "preedit"})

    def test_retro_english_keys_parse(self):
        # Điều kiện làm mờ (cần Quyết định theo ngữ cảnh) nằm ở layout.py — test_layout.py.
        d = config.parse("[typing]\nretroactive_english = true\n")
        self.assertIs(config.normalize(d)["typing"]["retroactive_english"], True)
        d = config.parse("[typing]\nenglish_by_frequency = true\n")
        self.assertIs(config.normalize(d)["typing"]["english_by_frequency"], True)

    def test_defaults_match_contract(self):
        n = config.normalize({})
        self.assertEqual(n["typing"]["input_method"], "telex")
        self.assertTrue(n["typing"]["free_marking"])
        self.assertFalse(n["typing"]["modern_tone"])
        self.assertTrue(n["typing"]["contextual_english"])
        self.assertIs(n["typing"]["retroactive_english"], False)  # thử nghiệm: mặc định tắt
        self.assertIs(n["typing"]["english_by_frequency"], False)  # thử nghiệm: mặc định tắt
        self.assertTrue(n["typing"]["collision_prefers_vietnamese"])
        self.assertFalse(n["typing"]["teencode"])
        self.assertFalse(n["typing"]["auto_circumflex"])   # "Tự thêm dấu mũ": mặc định tắt
        self.assertEqual(n["general"]["display_mode"], "preedit")
        self.assertEqual(n["general"]["toggle_hotkey"], "Ctrl+space")
        self.assertFalse(n["general"]["preedit_underline"])  # "Hiện gạch chân chữ đang gõ" off
        self.assertIs(n["general"]["underline_misspelled"], False)  # gạch đỏ: opt-in
        self.assertTrue(n["general"]["terminal_direct"])
        # Gợi ý cạnh con trỏ = macOS 1.8.2: bật hết trừ Thêm dấu cho câu không dấu.
        for k in ("math_results", "number_chips", "typo_hints", "date_hints"):
            self.assertIs(n["general"][k], True, k)
        self.assertIs(n["general"]["tone_hints"], False)

    def test_auto_text_defaults_off_and_roundtrip(self):
        # Linux: VietTelex switches (macOS follows its system settings) — all OFF by default.
        n = config.normalize({})
        for k in ("double_space_period", "auto_capitalize", "smart_punctuation", "word_prediction"):
            self.assertIs(n["general"][k], False, k)
        self.assertEqual(n["general"]["quote_style"], "curly")
        self.assertIs(n["general"]["filter_sensitive"], True, "Lọc từ nhạy cảm: bật như iOS/macOS")
        off = config.normalize(config.parse("[general]\nfilter_sensitive = false\n"))
        self.assertIs(off["general"]["filter_sensitive"], False)
        out = config.update_text("[general]\nmath_results = true\n",
                                 {("general", "word_prediction"): True, ("general", "quote_style"): "low9"})
        self.assertIn("word_prediction = true", out)
        self.assertIn('quote_style = "low9"', out)
        m = config.normalize(config.parse(out))
        self.assertIs(m["general"]["word_prediction"], True)
        self.assertEqual(m["general"]["quote_style"], "low9")
        bad = config.normalize(config.parse('[general]\nquote_style = "fancy"\nauto_capitalize = "yes"\n'))
        self.assertEqual(bad["general"]["quote_style"], "curly")
        self.assertIs(bad["general"]["auto_capitalize"], False)

    def test_learn_words_default_and_clear(self):
        # "Học từ bạn gõ": bật như iOS/macOS; "Xoá từ đã học" ghi kho VTL2 RỖNG hợp lệ (đúng byte
        # mà AppTests/LearnedWordsTests đọc lại bằng UserLMCodec).
        n = config.normalize({})
        self.assertIs(n["general"]["learn_words"], True)
        off = config.normalize(config.parse("[general]\nlearn_words = false\n"))
        self.assertIs(off["general"]["learn_words"], False)
        self.assertEqual(config.empty_learned_store(0).hex(),
                         "56544c3201000000000000000000000000000000000000000000000000000000" "3a3b26a4")
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "viettelex", "learned-words.bin")
            with open(os.path.join(d, "x"), "w"):
                pass
            os.makedirs(os.path.dirname(p))
            with open(p, "wb") as f:
                f.write(b"old data")
            config.clear_learned_words(p)
            with open(p, "rb") as f:
                data = f.read()
            self.assertEqual(len(data), 36)
            self.assertEqual(data[:4], b"VTL2")
            self.assertFalse(os.path.exists(p + ".tmp"))
            self.assertEqual(os.stat(p).st_mode & 0o777, 0o600)   # dữ liệu gõ: chỉ chủ đọc

    def test_underline_misspelled_roundtrip(self):
        out = config.update_text("[general]\npreedit_underline = false\n",
                                 {("general", "underline_misspelled"): True})
        self.assertIs(config.normalize(config.parse(out))["general"]["underline_misspelled"], True)
        self.assertIn("underline_misspelled = true", out)

    def test_caret_hint_keys_roundtrip(self):
        n = config.normalize(config.parse('[general]\nmath_results = false\ntone_hints = true\n'
                                          'typo_hints = "no"\n'))
        self.assertIs(n["general"]["math_results"], False)
        self.assertIs(n["general"]["tone_hints"], True)
        self.assertIs(n["general"]["typo_hints"], True)  # sai kiểu → mặc định
        text = config.dump(n)
        self.assertIn("math_results = false", text)
        self.assertIn("tone_hints = true", text)

    def test_wrong_type_falls_back_to_default(self):
        n = config.normalize(config.parse('[typing]\nfree_marking = "yes"\ninput_method = "abc"\n'
                                          '[app_modes]\n"x" = "bogus"\n"y" = "off"\n'))
        self.assertTrue(n["typing"]["free_marking"])
        self.assertEqual(n["typing"]["input_method"], "telex")
        self.assertEqual(n["app_modes"], {"y": "off"})
        n = config.normalize(config.parse('[app_modes]\n"kitty" = "direct"\n'))
        self.assertEqual(n["app_modes"], {"kitty": "direct"})

    def test_escapes_roundtrip(self):
        d = config.normalize({})
        d["app_modes"]['we"ird\\app'] = "off"
        back = config.normalize(config.parse(config.dump(d)))
        self.assertEqual(back, d)

    def test_unknown_keys_preserved(self):
        d = config.normalize(config.parse('[typing]\nfuture_flag = 3\n[future]\na = true\n'))
        text = config.dump(d)
        self.assertIn("future_flag = 3", text)
        self.assertIn("[future]", text)

    def test_dump_is_contract_subset(self):
        text = config.dump(config.normalize({}))
        for line in text.splitlines():
            s = line.strip()
            self.assertTrue(not s or s.startswith(("#", "[")) or " = " in s, line)
        self.assertNotIn("\r", text)

    def test_atomic_write_no_tmp_left(self):
        with tempfile.TemporaryDirectory() as d:
            c = config.Config(os.path.join(d, "viettelex", "config.toml"))
            c.set("typing", "quick_telex", True)
            self.assertEqual(os.listdir(os.path.join(d, "viettelex")), ["config.toml"])
            self.assertTrue(config.Config(c.path).get("typing", "quick_telex"))

    def test_atomic_write_keeps_symlink_and_mode(self):
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "dotfiles", "config.toml")
            os.makedirs(os.path.dirname(real))
            with open(real, "w") as f:
                f.write("[typing]\n")
            os.chmod(real, 0o640)
            link = os.path.join(d, "viettelex", "config.toml")
            os.makedirs(os.path.dirname(link))
            os.symlink(real, link)
            c = config.Config(link)
            c.set("typing", "quick_telex", True)
            self.assertTrue(os.path.islink(link))
            self.assertEqual(os.stat(real).st_mode & 0o777, 0o640)
            self.assertTrue(config.Config(real).get("typing", "quick_telex"))
            self.assertEqual(sorted(os.listdir(os.path.dirname(real))), ["config.toml"])

    def test_atomic_write_unique_tmp_names(self):
        seen = []
        real_mkstemp = tempfile.mkstemp

        def spy(*a, **k):
            fd, p = real_mkstemp(*a, **k)
            seen.append(p)
            return fd, p
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "config.toml")
            config.tempfile.mkstemp = spy
            try:
                config.atomic_write(p, "a\n")
                config.atomic_write(p, "b\n")
            finally:
                config.tempfile.mkstemp = real_mkstemp
            self.assertEqual(len(set(seen)), 2)
            self.assertTrue(all(os.path.basename(s).startswith("config.toml.") for s in seen))
            self.assertNotIn(p + ".tmp", seen)       # tên cố định cũ, đụng hộp Fcitx5

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root bỏ qua quyền thư mục")
    def test_read_only_config_raises_and_keeps_disk_state(self):
        with tempfile.TemporaryDirectory() as d:
            vd = os.path.join(d, "viettelex")
            c = config.Config(os.path.join(vd, "config.toml"))
            c.set("typing", "quick_telex", True)
            os.chmod(vd, 0o500)
            try:
                with self.assertRaises(OSError):
                    c.set("typing", "quick_telex", False)
                # Mô hình trong bộ nhớ = đĩa (giao diện vẽ lại theo nó), không file tạm sót.
                self.assertTrue(c.get("typing", "quick_telex"))
                self.assertEqual(os.listdir(vd), ["config.toml"])
            finally:
                os.chmod(vd, 0o700)

    def test_app_mode_auto_removes_and_lowercases(self):
        with tempfile.TemporaryDirectory() as d:
            c = config.Config(os.path.join(d, "config.toml"))
            c.set_app_mode("Kitty", "surrounding")
            self.assertEqual(c.data["app_modes"], {"kitty": "surrounding"})
            c.set_app_mode("kitty", "auto")
            self.assertEqual(c.data["app_modes"], {})


FCITX_WRITTEN = """# viết tay
[typing]
input_method = "telex"   # kiểu gõ
free_marking = true
future_flag = 7

[general]
toggle_hotkey = "Ctrl+space"

[app_modes]
"kitty" = "preedit"
"#weird" = "off"  # giữ

[future]
x = true
"""


class InPlaceTests(unittest.TestCase):
    def test_only_changed_line_differs(self):
        out = config.update_text(FCITX_WRITTEN, {("typing", "free_marking"): False})
        a, b = FCITX_WRITTEN.splitlines(), out.splitlines()
        self.assertEqual(len(a), len(b))
        self.assertEqual([i for i in range(len(a)) if a[i] != b[i]], [3])
        self.assertEqual(b[3], "free_marking = false")

    def test_comment_kept_on_changed_line(self):
        out = config.update_text(FCITX_WRITTEN, {("typing", "input_method"): "vni"})
        self.assertIn('input_method = "vni"  # kiểu gõ', out)

    def test_new_key_appended_to_its_section(self):
        out = config.update_text(FCITX_WRITTEN, {("typing", "re_edit_word"): False,
                                                 ("app_modes", "code"): "surrounding"})
        d = config.parse(out)
        self.assertIs(d["typing"]["re_edit_word"], False)
        self.assertEqual(d["typing"]["future_flag"], 7)
        self.assertEqual(d["app_modes"], {"kitty": "preedit", "#weird": "off", "code": "surrounding"})
        self.assertIn("[future]\nx = true", out)
        lines = out.splitlines()
        self.assertLess(lines.index("re_edit_word = false"), lines.index("[general]"))

    def test_delete_app_mode(self):
        out = config.update_text(FCITX_WRITTEN, {("app_modes", "kitty"): None})
        self.assertNotIn("kitty", out)
        self.assertIn('"#weird" = "off"  # giữ', out)

    def test_missing_section_and_empty_file(self):
        out = config.update_text("", {("general", "display_mode"): "surrounding"})
        self.assertEqual(config.parse(out), {"general": {"display_mode": "surrounding"}})
        out = config.update_text("[typing]\na = true\n", {("app_modes", "x"): "off"})
        self.assertEqual(config.parse(out)["app_modes"], {"x": "off"})

    def test_config_set_picks_up_external_edit(self):
        # Fcitx5 sửa file sau khi app đã nạp: lần ghi sau của app không được đè mất.
        with tempfile.TemporaryDirectory() as d:
            c = config.Config(os.path.join(d, "config.toml"))
            c.set("typing", "quick_telex", True)
            with open(c.path, "a") as f:
                f.write("[typing]\nteencode = true\n")
            c.set("typing", "simple_telex", True)
            with open(c.path) as f:
                d2 = config.normalize(config.parse(f.read()))
            self.assertTrue(d2["typing"]["teencode"])
            self.assertTrue(d2["typing"]["simple_telex"])
            self.assertTrue(d2["typing"]["quick_telex"])

    def test_re_edit_word_default_on(self):
        self.assertTrue(config.normalize({})["typing"]["re_edit_word"])


class HotkeyTests(unittest.TestCase):
    def test_normalize(self):
        self.assertEqual(config.normalize_hotkey("ctrl + Space"), "Ctrl+space")
        self.assertEqual(config.normalize_hotkey("Shift+Ctrl+Z"), "Ctrl+Shift+z")
        self.assertEqual(config.normalize_hotkey("Alt+F12"), "Alt+F12")
        self.assertEqual(config.normalize_hotkey(""), "")

    def test_rejects(self):
        self.assertIsNone(config.normalize_hotkey("Super+space"))   # GNOME
        self.assertIsNone(config.normalize_hotkey("space"))
        self.assertIsNone(config.normalize_hotkey("Hyper+a"))
        self.assertIsNone(config.normalize_hotkey("Ctrl+Ctrl+a"))
        self.assertIsNone(config.normalize_hotkey("Shift+a"))        # nuốt chữ A
        self.assertIsNone(config.normalize_hotkey("Shift+space"))
        self.assertIsNone(config.normalize_hotkey("Tab"))            # không modifier: chỉ F1–F24
        self.assertIsNone(config.normalize_hotkey("Ctrl+KP_1"))
        self.assertIsNone(config.normalize_hotkey("Ctrl+F25"))
        self.assertIsNone(config.normalize_hotkey("Ctrl+F1x"))
        self.assertIsNone(config.normalize_hotkey("Win+a"))          # C++ không biết "win"
        self.assertIsNone(config.normalize_hotkey("Ctrl+Shift+ISO_Left_Tab"))

    def test_keys_frontend_reads(self):
        # GTK báo keyval sau Shift: Ctrl+Shift+2 (US) = "at", Ctrl+Shift+. = "greater".
        self.assertEqual(config.normalize_hotkey("Ctrl+Shift+at"), "Ctrl+Shift+at")
        self.assertEqual(config.normalize_hotkey("Ctrl+Shift+greater"), "Ctrl+Shift+greater")
        self.assertEqual(config.normalize_hotkey("Alt+left"), "Alt+Left")
        self.assertEqual(config.normalize_hotkey("Ctrl+period"), "Ctrl+period")
        self.assertEqual(config.normalize_hotkey("Ctrl+2"), "Ctrl+2")
        self.assertEqual(config.normalize_hotkey("Ctrl++"), "Ctrl++")
        self.assertEqual(config.normalize_hotkey("F9"), "F9")
        self.assertEqual(config.normalize_hotkey("Shift+F9"), "Shift+F9")
        self.assertEqual(config.normalize_hotkey("Shift+Left"), "Shift+Left")
        self.assertEqual(config.normalize_hotkey("Control+Meta+x"), "Ctrl+Super+x")

    def test_display(self):
        self.assertEqual(config.hotkey_display("Ctrl+Shift+at"), "Ctrl+Shift+@")
        self.assertEqual(config.hotkey_display("Ctrl+space"), "Ctrl+Space")
        self.assertEqual(config.hotkey_display("Alt+Left"), "Alt+←")
        self.assertEqual(config.hotkey_display("Ctrl+z"), "Ctrl+Z")
        self.assertEqual(config.hotkey_display("Ctrl++"), "Ctrl++")
        self.assertEqual(config.hotkey_display("F9"), "F9")

    def test_captured(self):
        self.assertEqual(config.captured_hotkey(["Ctrl", "Shift"], "at"), ("Ctrl+Shift+at", None))
        self.assertEqual(config.captured_hotkey(["Shift"], "a"), (None, "modifier"))
        self.assertEqual(config.captured_hotkey(["Shift"], "exclam"), (None, "modifier"))
        self.assertEqual(config.captured_hotkey(["Ctrl"], "KP_Add"), (None, "unsupported"))
        self.assertEqual(config.captured_hotkey(["Super"], "space"), (None, "unsupported"))
        self.assertEqual(config.captured_hotkey(["Alt"], "Left"), ("Alt+Left", None))

    def test_normalize_resets_unreadable_stored_hotkeys(self):
        d = config.normalize({"general": {"toggle_hotkey": "Ctrl+Shift+KP_1",
                                          "add_tones_hotkey": "Shift+a"}})
        self.assertEqual(d["general"]["toggle_hotkey"], "")
        self.assertEqual(d["general"]["add_tones_hotkey"], "")
        d = config.normalize({"general": {"toggle_hotkey": "Ctrl+Shift+at"}})
        self.assertEqual(d["general"]["toggle_hotkey"], "Ctrl+Shift+at")

    def test_names_match_cpp_parse_hotkey(self):
        # Bảng tên keysym phải y hệt `names` trong parseHotkey (common/src/settings.cpp).
        import re
        with open(os.path.join(os.path.dirname(__file__), "..", "..", "common", "src",
                               "settings.cpp"), encoding="utf-8") as f:
            src = f.read()
        body = src[src.index("bool parseHotkey("):]
        table = body[body.index("names = {"):body.index("};", body.index("names = {"))]
        cpp = dict(re.findall(r"""\{"([a-z]+)",\s*('(?:\\.|[^'])'|[\w:]+)\}""", table))
        self.assertEqual(set(cpp), set(config.HOTKEY_NAMES))
        for name, sym in cpp.items():
            sym = sym.strip()
            label = config.HOTKEY_NAMES[name][1]
            if sym.startswith("'"):
                ch = sym[1:-1].encode().decode("unicode_escape")
                self.assertEqual(label, ch, name)
            elif sym == "0x20":
                self.assertEqual(name, "space")
            # tên chuẩn lưu vào file đọc lại được (C++ so không phân biệt hoa thường)
            self.assertEqual(config.HOTKEY_NAMES[name][0].lower(), name)


if __name__ == "__main__":
    unittest.main()
