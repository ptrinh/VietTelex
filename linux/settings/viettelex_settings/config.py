"""config.toml — đọc/ghi đúng tập con TOML của linux/common/SETTINGS.md.

Không phụ thuộc thư viện ngoài (Ubuntu 22.04 có Python 3.10, chưa có tomllib).
Hàm thuần (parse/dump) tách riêng để test không cần GTK.

Ghi nguyên tử: file tạm tên duy nhất → rename() (frontend theo dõi thư mục bằng inotify).
Ghi TẠI CHỖ (SETTINGS.md "Ghi chung file"): hộp cấu hình Fcitx5 cũng ghi file này, nên mỗi
lần đổi chỉ nạp lại file rồi sửa đúng dòng của key vừa đổi — comment, thứ tự và key lạ
giữ nguyên (update_text).
"""

import os
import tempfile

# Mặc định chính xác theo SETTINGS.md §2 (= bản macOS 1.7.12).
DEFAULTS = {
    "typing": {
        "input_method": "telex",
        "simple_telex": False,
        "free_marking": True,
        "modern_tone": False,
        "quick_telex": False,
        "spell_check": True,
        "auto_restore": True,
        "teencode": False,
        # "Tự thêm dấu mũ" (issue #166): vietj → việt. Mặc định tắt.
        "auto_circumflex": False,
        "contextual_english": True,
        # "Tự sửa từ phía trước" (thử nghiệm): chỉ hiện / chỉ có tác dụng khi contextual_english bật.
        "retroactive_english": False,
        # "Đoán từ trùng theo tần suất" (thử nghiệm): cùng điều kiện hiện như retroactive_english.
        "english_by_frequency": False,
        "collision_prefers_vietnamese": True,
        "bracket_vowels": False,
        "re_edit_word": True,
        "shortcuts_enabled": True,
    },
    "general": {
        "display_mode": "preedit",
        "preedit_underline": False,
        # "Gạch đỏ âm tiết sai chính tả khi gõ" — chỉ ở chế độ chữ đang gõ (preedit).
        "underline_misspelled": False,
        "terminal_direct": True,
        "toggle_hotkey": "Ctrl+space",
        "per_app_state": True,
        "switch_sound": False,
        "default_vietnamese": True,
        # Ngôn ngữ giao diện app cài đặt + nhãn menu bộ gõ. Mặc định LUÔN tiếng Việt —
        # không theo locale của máy (quy ước chung các bản VietTelex).
        "ui_language": "vi",
        # Menu bộ gõ → "Công cụ…" (Thêm dấu, HOA, thường, Hoa Đầu Từ, Hoa đầu câu, Xoá dấu).
        "text_tools_menu": True,
        # Phím tắt "Thêm dấu cho vùng chọn"; "" = tắt (mặc định).
        "add_tones_hotkey": "",
        # Gợi ý cạnh con trỏ (như macOS 1.8.2) — Tab áp dụng, không bao giờ tự thay.
        "math_results": True,     # 12*3= → = 36
        "number_chips": True,     # 1tr2␣ → 1.200.000 ₫
        "typo_hints": True,       # tpoi␣ → tôi
        "tone_hints": False,      # toi di hoc. → tôi đi học.
        "date_hints": True,       # hôm nay␣ → 28/09/2026, bây giờ␣ → 21:35, âm lịch␣ → 30/9 năm Bính Ngọ, Tết␣ → Tết 06/02/2027
        # Văn bản tự động (SETTINGS.md §8b) — macOS theo cài đặt Nhập văn bản của hệ thống;
        # Linux không có ⇒ công tắc riêng, MẶC ĐỊNH TẮT HẾT (terminal / code).
        "double_space_period": False,   # chào␣␣ → "chào. "
        "auto_capitalize": False,       # viết hoa chữ đầu câu
        "smart_punctuation": False,     # " ' → “ ” ‘ ’, -- → —
        "quote_style": "curly",         # curly “”‘’ | low9 „“‚‘ | guillemets «»‹›
        "word_prediction": False,       # gợi ý từ: hoàn thành từ / từ kế tiếp (Tab)
        "filter_sensitive": True,       # "Lọc từ nhạy cảm": gợi ý từ / sửa lỗi gõ không đưa từ tục
        "learn_words": True,            # "Học từ bạn gõ": gợi ý từ học từ hay gõ (cần word_prediction)
    },
    # Thử nghiệm (SETTINGS.md §9): "forward-keys" = gõ không gạch chân ở Chrome/Electron.
    "experimental": {
        "no_underline": "off",
    },
    "app_modes": {},
}

SECTION_ORDER = ["typing", "general", "experimental", "app_modes"]
NO_UNDERLINE_MODES = ("off", "forward-keys")
APP_MODES = ("preedit", "surrounding", "direct", "off")
INPUT_METHODS = ("telex", "vni")
DISPLAY_MODES = ("preedit", "surrounding")
UI_LANGUAGES = ("vi", "en")
QUOTE_STYLES = ("curly", "low9", "guillemets")


def config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "viettelex")


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "viettelex")


def learned_words_path():
    """Kho "Học từ bạn gõ" của viettelex-text-tool --serve (LearnStore.swift)."""
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(base, "viettelex", "learned-words.bin")


def empty_learned_store(last_decay_ms=0):
    """Kho VTL2 RỖNG hợp lệ (UserLMCodec — iOS/Keyboard/UserLMTables.swift): "VTL2", u16 version 1,
    u16 flags 0, i64 lastDecay (ms), u32 số từ / cặp / bộ ba / từ thêm tay = 0, u32 CRC32."""
    import struct
    import zlib
    body = b"VTL2" + struct.pack("<HHqIIII", 1, 0, last_decay_ms, 0, 0, 0, 0)
    return body + struct.pack("<I", zlib.crc32(body) & 0xFFFFFFFF)


def clear_learned_words(path=None):
    """"Xoá từ đã học": ghi đè kho bằng kho RỖNG hợp lệ (không chỉ xoá file) — process con đang
    chạy thấy file đổi và nạp lại rỗng, không ghi đè lại dữ liệu cũ đang giữ trong RAM."""
    import time
    path = path or learned_words_path()
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    try:
        os.unlink(tmp)
    except OSError:
        pass
    # Chỉ chủ đọc được (0600) như process con ghi (LearnStore.writePrivate).
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
        f.write(empty_learned_store(int(time.time() * 1000)))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


# ---------------------------------------------------------------- parsing

def _unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(n, "\\" + n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _escape(s):
    return (s.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\n", "\\n").replace("\t", "\\t"))


def _read_string(text, i):
    """text[i] == '"'. Trả (chuỗi, vị trí sau dấu đóng) hoặc (None, i) nếu hỏng."""
    j = i + 1
    while j < len(text):
        if text[j] == "\\":
            j += 2
            continue
        if text[j] == '"':
            return _unescape(text[i + 1:j]), j + 1
        j += 1
    return None, i


def _parse_value(raw):
    raw = raw.strip()
    if raw.startswith('"'):
        val, end = _read_string(raw, 0)
        if val is None:
            return None
        rest = raw[end:].strip()
        if rest and not rest.startswith("#"):
            return None
        return val
    raw = raw.split("#", 1)[0].strip()
    if raw == "true":
        return True
    if raw == "false":
        return False
    try:
        return int(raw)
    except ValueError:
        return None


def parse(text):
    """Trả {section: {key: value}}. Dòng hỏng bị bỏ qua (không raise)."""
    data = {}
    section = ""
    for line in text.split("\n"):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("["):
            end = s.find("]")
            if end > 1:
                section = s[1:end].strip()
                data.setdefault(section, {})
            continue
        if s.startswith('"'):
            key, end = _read_string(s, 0)
            if key is None:
                continue
            rest = s[end:].lstrip()
        else:
            eq = s.find("=")
            if eq <= 0:
                continue
            key, rest = s[:eq].strip(), s[eq:]
        if not rest.startswith("="):
            continue
        val = _parse_value(rest[1:])
        if val is None or not key:
            continue
        data.setdefault(section, {})[key] = val
    return data


def _fmt(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return '"' + _escape(str(v)) + '"'


def dump(data):
    """Ghi theo thứ tự cố định; section/key lạ nối sau (giữ nguyên, không mất)."""
    out = ["# VietTelex — cài đặt (ghi bởi viettelex-settings; xem linux/common/SETTINGS.md)"]
    sections = [s for s in SECTION_ORDER if s in data or s in DEFAULTS]
    sections += sorted(s for s in data if s not in SECTION_ORDER and s)
    for sec in sections:
        values = data.get(sec, {})
        out.append("")
        out.append("[%s]" % sec)
        if sec == "app_modes":
            for k in sorted(values):
                out.append('"%s" = %s' % (_escape(k), _fmt(values[k])))
            continue
        order = list(DEFAULTS.get(sec, {}))
        order += sorted(k for k in values if k not in order)
        for k in order:
            if k in values:
                out.append("%s = %s" % (k, _fmt(values[k])))
    return "\n".join(out) + "\n"


def _line_key(s):
    """Dòng `key = value` (đã strip) → (key, phần sau '='), hoặc (None, None)."""
    if s.startswith('"'):
        key, end = _read_string(s, 0)
        rest = s[end:].lstrip() if key is not None else ""
    else:
        eq = s.find("=")
        key, rest = (s[:eq].strip(), s[eq:]) if eq > 0 else (None, "")
    if not key or not rest.startswith("="):
        return None, None
    return key, rest[1:]


def _trailing_comment(raw_value):
    """Phần `# …` sau giá trị (bỏ qua # nằm trong chuỗi)."""
    v = raw_value.lstrip()
    if v.startswith('"'):
        val, end = _read_string(v, 0)
        tail = v[end:] if val is not None else ""
    else:
        i = v.find("#")
        tail = v[i:] if i >= 0 else ""
    i = tail.find("#")
    return tail[i:] if i >= 0 else ""


def _key_text(section, key):
    return '"%s"' % _escape(key) if section == "app_modes" else key


def update_text(text, changes):
    """Áp `changes` {(section, key): value | None(xoá)} lên nội dung file, sửa tại chỗ.

    Dòng khác (comment, key lạ, section lạ) giữ nguyên từng byte. Key chưa có thì thêm
    vào cuối section của nó (tạo section ở cuối file nếu chưa có)."""
    lines = text.split("\n") if text else []
    if lines and lines[-1] == "":
        lines.pop()
    pending = dict(changes)
    out, section, sec_end = [], "", {}
    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.find("]") > 1:
            section = s[1:s.find("]")].strip()
            out.append(line)
            sec_end[section] = len(out)
            continue
        key, raw = (None, None) if not s or s.startswith("#") else _line_key(s)
        if key is not None and (section, key) in pending:
            v = pending.pop((section, key))
            if v is None:
                continue
            indent = line[:len(line) - len(line.lstrip())]
            comment = _trailing_comment(raw)
            newline = "%s%s = %s" % (indent, _key_text(section, key), _fmt(v))
            out.append(newline + ("  " + comment if comment else ""))
        else:
            out.append(line)
        if section in sec_end and s:
            sec_end[section] = len(out)
    # Key mới: chèn sau dòng không trống cuối cùng của section (giữ dòng trống ngăn cách).
    by_sec = {}
    for (sec, key), v in pending.items():
        if v is not None:
            by_sec.setdefault(sec, []).append((key, v))
    for sec in sorted(by_sec, key=lambda x: -sec_end.get(x, -1)):
        new = ["%s = %s" % (_key_text(sec, k), _fmt(v)) for k, v in sorted(by_sec[sec])]
        if sec in sec_end:
            at = sec_end[sec]
            out[at:at] = new
        else:
            if out and out[-1].strip():
                out.append("")
            out.append("[%s]" % sec)
            out += new
    return "\n".join(out) + "\n"


def normalize(data):
    """Điền mặc định + loại giá trị sai kiểu (giống frontend: sai kiểu → mặc định)."""
    out = {sec: dict(vals) for sec, vals in data.items() if isinstance(vals, dict)}
    for sec, vals in DEFAULTS.items():
        cur = out.setdefault(sec, {})
        for k, dv in vals.items():
            v = cur.get(k)
            if type(v) is not type(dv):
                cur[k] = dv
    t, g = out["typing"], out["general"]
    if t["input_method"] not in INPUT_METHODS:
        t["input_method"] = "telex"
    if g["display_mode"] not in DISPLAY_MODES:
        g["display_mode"] = "preedit"
    if g["ui_language"] not in UI_LANGUAGES:
        g["ui_language"] = "vi"
    if g["quote_style"] not in QUOTE_STYLES:
        g["quote_style"] = "curly"
    if out["experimental"]["no_underline"] not in NO_UNDERLINE_MODES:
        out["experimental"]["no_underline"] = "off"
    # Frontend không đọc được ⇒ nó không có phím nào: hiện đúng như vậy (tắt), đừng hiện phím ma.
    for k in ("toggle_hotkey", "add_tones_hotkey"):
        if g[k] and normalize_hotkey(g[k]) is None:
            g[k] = ""
    out["app_modes"] = {k: v for k, v in out["app_modes"].items()
                        if isinstance(v, str) and v in APP_MODES and k.strip()}
    return out


def atomic_write(path, text):
    """Ghi nguyên tử. File là symlink (dotfiles) ⇒ ghi vào đích, symlink giữ nguyên; tên tạm
    duy nhất (app này và hộp cấu hình Fcitx5 có thể ghi cùng lúc); giữ quyền file cũ. Lỗi
    (~/.config chỉ đọc / đầy) ⇒ OSError, không để lại file tạm."""
    path = os.path.realpath(path)
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    try:
        mode = os.stat(path).st_mode & 0o7777
    except OSError:
        um = os.umask(0)
        os.umask(um)
        mode = 0o666 & ~um
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        try:
            os.chmod(tmp, mode)
        except OSError:
            pass
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class Config:
    """Mô hình trong bộ nhớ + lưu ngay (frontend áp tức thì qua inotify)."""

    def __init__(self, path=None):
        self.path = path or os.path.join(config_dir(), "config.toml")
        self.data = normalize({})
        self.load()

    def load(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                self.data = normalize(parse(f.read()))
        except (OSError, UnicodeDecodeError):
            self.data = normalize({})

    def get(self, section, key):
        return self.data[section][key]

    def _read_text(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                return f.read()
        except (OSError, UnicodeDecodeError):
            return ""

    def apply(self, changes):
        """Nạp lại file (có thể vừa bị hộp cấu hình Fcitx5 sửa), sửa đúng các key đổi, ghi."""
        text = self._read_text()
        self.data = normalize(parse(text))
        atomic_write(self.path, update_text(text, changes))
        for (sec, key), v in changes.items():
            if v is None:
                self.data.setdefault(sec, {}).pop(key, None)
            else:
                self.data.setdefault(sec, {})[key] = v

    def set(self, section, key, value):
        if self.data.setdefault(section, {}).get(key) == value:
            return
        self.apply({(section, key): value})

    def set_app_mode(self, app, mode):
        self.set_app_modes({app: mode})

    def set_app_modes(self, modes):
        """{app: mode}; mode ngoài APP_MODES ("auto") = bỏ ghi đè."""
        changes = {}
        for app, mode in modes.items():
            app = app.strip().lower()
            if app:
                changes[("app_modes", app)] = mode if mode in APP_MODES else None
        if changes:
            self.apply(changes)


# ---------------------------------------------------------------- hotkey (§4)

MODIFIERS = ("Ctrl", "Alt", "Shift", "Super")

# Tên keysym X frontend hiểu — bản sao bảng `names` trong parseHotkey (common/src/settings.cpp;
# test_config so khớp hai bảng). Khoá viết thường → (cách viết lưu vào file, ký tự hiển thị).
# Lưu đúng keysym GTK báo khi bấm (= keysym frontend nhận): Ctrl+Shift+2 trên bàn phím US là
# "Ctrl+Shift+at" (hiện "Ctrl+Shift+@").
HOTKEY_NAMES = {
    "space": ("space", "Space"), "grave": ("grave", "`"), "tab": ("Tab", "Tab"),
    "return": ("Return", "Return"), "escape": ("Escape", "Escape"),
    "backspace": ("BackSpace", "BackSpace"), "comma": ("comma", ","), "period": ("period", "."),
    "slash": ("slash", "/"), "semicolon": ("semicolon", ";"), "apostrophe": ("apostrophe", "'"),
    "minus": ("minus", "-"), "equal": ("equal", "="), "bracketleft": ("bracketleft", "["),
    "bracketright": ("bracketright", "]"), "backslash": ("backslash", "\\"), "plus": ("plus", "+"),
    "exclam": ("exclam", "!"), "quotedbl": ("quotedbl", '"'), "numbersign": ("numbersign", "#"),
    "dollar": ("dollar", "$"), "percent": ("percent", "%"), "ampersand": ("ampersand", "&"),
    "parenleft": ("parenleft", "("), "parenright": ("parenright", ")"),
    "asterisk": ("asterisk", "*"), "colon": ("colon", ":"), "less": ("less", "<"),
    "greater": ("greater", ">"), "question": ("question", "?"), "at": ("at", "@"),
    "asciicircum": ("asciicircum", "^"), "underscore": ("underscore", "_"),
    "braceleft": ("braceleft", "{"), "bar": ("bar", "|"), "braceright": ("braceright", "}"),
    "asciitilde": ("asciitilde", "~"),
    "left": ("Left", "←"), "right": ("Right", "→"), "up": ("Up", "↑"), "down": ("Down", "↓"),
}
_PRINTABLE_NAMES = {k for k, (_n, label) in HOTKEY_NAMES.items()
                    if len(label) == 1 and label.isascii()} | {"space"}


def _hotkey_key(key):
    """Phím cuối → (cách viết chuẩn, in được?) hoặc None — đúng luật parseHotkey C++."""
    lk = key.lower()
    if lk in HOTKEY_NAMES:
        return HOTKEY_NAMES[lk][0], lk in _PRINTABLE_NAMES
    if len(key) == 1 and 0x20 < ord(key) < 0x7f:
        return key.lower(), True
    if 2 <= len(lk) <= 3 and lk[0] == "f" and lk[1:].isdigit() and lk[1:].isascii():
        n = int(lk[1:])
        if 1 <= n <= 24:
            return "F%d" % n, False
    return None


def normalize_hotkey(text):
    """'ctrl + Space' → 'Ctrl+space'. Trả None nếu frontend không đọc được; '' = tắt.

    Cùng luật parseHotkey (common/src/settings.cpp): modifier Ctrl/Control, Alt, Shift,
    Super/Meta; phím = tên trong HOTKEY_NAMES, một ký tự ASCII in được, hoặc F1–F24; phím in
    được cần Ctrl/Alt/Super (Shift+a sẽ nuốt chữ A); không modifier chỉ F1–F24; cấm Super+space."""
    text = text.strip()
    if not text:
        return ""
    # Tách ở "+" như C++: "Ctrl++" = phím "+".
    parts, start = [], 0
    for i, c in enumerate(text):
        if c == "+" and i > start:
            parts.append(text[start:i])
            start = i + 1
    parts.append(text[start:])
    parts = [p.strip() for p in parts]
    mods, key = parts[:-1], parts[-1]
    canon = []
    for m in mods:
        mm = {"ctrl": "Ctrl", "control": "Ctrl", "alt": "Alt", "shift": "Shift",
              "super": "Super", "meta": "Super"}.get(m.lower())
        if mm is None or mm in canon:
            return None
        canon.append(mm)
    canon.sort(key=MODIFIERS.index)
    k = _hotkey_key(key)
    if k is None:
        return None
    key, printable = k
    if canon == ["Super"] and key == "space":
        return None       # GNOME dùng Super+Space — hợp đồng cấm
    if printable and not any(m in ("Ctrl", "Alt", "Super") for m in canon):
        return None
    if not canon and not (key.startswith("F") and key[1:].isdigit()):
        return None
    return "+".join(canon + [key])


def captured_hotkey(mods, keyname):
    """Tổ hợp vừa bấm trong hộp bắt phím (modifier + tên keyval GTK) → (giá trị, lỗi).

    lỗi: None (dùng được), "modifier" (phím in được cần Ctrl/Alt/Super — Shift+a là gõ chữ
    A), "unsupported" (frontend không đọc được phím này: bàn phím số, ISO_Left_Tab…)."""
    value = normalize_hotkey("+".join(list(mods) + [keyname]))
    if value is not None:
        return value, None
    k = _hotkey_key(keyname)
    if k is not None and k[1] and not any(m in ("Ctrl", "Alt", "Super") for m in mods):
        return None, "modifier"
    return None, "unsupported"


def hotkey_display(value):
    """'Ctrl+Shift+at' → 'Ctrl+Shift+@', 'Ctrl+space' → 'Ctrl+Space' (chỉ để hiển thị)."""
    if not value:
        return ""
    plus = value.rfind("+", 0, len(value) - 1)
    mods, key = (value[:plus + 1], value[plus + 1:]) if plus >= 0 else ("", value)
    if key.lower() in HOTKEY_NAMES:
        key = HOTKEY_NAMES[key.lower()][1]
    elif len(key) == 1:
        key = key.upper()
    else:
        key = key[:1].upper() + key[1:]
    return mods + key


def action_hotkey_error(value, toggle_hotkey):
    """Phím tắt công cụ (Thêm dấu): None = dùng được / "" (tắt); "modifier" = thiếu
    Ctrl/Alt/Super (Shift+chữ là gõ chữ hoa); "toggle" = trùng phím chuyển Việt/Anh."""
    if not value:
        return None
    mods = value.split("+")[:-1]
    if not any(m in ("Ctrl", "Alt", "Super") for m in mods):
        return "modifier"
    if toggle_hotkey and normalize_hotkey(toggle_hotkey) == value:
        return "toggle"
    return None
