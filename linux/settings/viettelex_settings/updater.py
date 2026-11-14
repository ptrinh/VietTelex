"""Cập nhật một chạm cho bản Linux — phần logic thuần (không GTK, test được).

stable.json (https://viettelex.com/stable.json) có mục riêng cho Linux; khoá gốc
"version"/"url" là của macOS, "windows" của Windows — Linux KHÔNG đọc chúng:

    "linux": {
      "version": "1.0.4",
      "url": "https://github.com/ptrinh/viettelex/releases/tag/linux-v1.0.4",
      "download": "https://github.com/ptrinh/viettelex/releases/download/linux-v1.0.4/",
      "series": ["jammy", "noble"],
      "sha256": {"libviettelex-core_1.0.4.noble1_amd64.deb": "<hex>", ...},
      "notes": "…"
    }

Tên file .deb trên GitHub Releases: GitHub đổi "~" thành ".", nên gói phiên bản
1.0.4~noble1 có asset tên libviettelex-core_1.0.4.noble1_amd64.deb.

Hai đường cập nhật (quyết định bởi plan()):
  - "apt": máy đã thêm kho APT VietTelex → helper root chạy apt-get update (chỉ kho
    VietTelex) + apt-get install --only-upgrade các gói đang cài.
  - "deb": cài từ .deb tải tay → app tải đúng bộ .deb (series + arch), kiểm SHA256,
    rồi helper root TỰ kiểm lại SHA256 với stable.json nó tự tải (không tin app — xem
    "Mô hình đe doạ" trong viettelex-update) và cài bằng apt-get install ./….deb.
Helper chạy qua pkexec (polkit action org.viettelex.update).

Gói RPM (Fedora/EL), Fedora Atomic (rpm-ostree) và Arch (pacman) không có helper: gói ghi
/usr/share/viettelex-settings/install-method ("rpm" / "pacman") và app chỉ báo lệnh cập nhật
của trình quản lý gói đó (install_method() / manual_update_hint()).
"""

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import urllib.request

from . import VERSION
from .i18n import _

# User-Agent riêng: Cloudflare (Browser Integrity Check của viettelex.com) trả 403 cho
# "Python-urllib/x.y" mặc định ⇒ "Không kết nối được máy chủ cập nhật".
USER_AGENT = "VietTelex-Linux/%s" % VERSION


def urlopen(url, timeout):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}),
                                  timeout=timeout)


HELPER = "/usr/libexec/viettelex/viettelex-update"
POLKIT_ACTION = "org.viettelex.update"
RELEASES_URL = "https://github.com/ptrinh/viettelex/releases"
PACKAGES = ("libviettelex-core", "viettelex-fcitx5", "viettelex-ibus", "viettelex-text-tools",
            "viettelex-settings", "viettelex")
ARCH_ALL = ("viettelex-settings", "viettelex")
SUPPORTED_ARCHES = ("amd64", "arm64")
APT_SOURCE_FILES = ("/etc/apt/sources.list.d/viettelex.sources",
                    "/etc/apt/sources.list.d/viettelex.list")
APT_REPO_HOST = "ptrinh.github.io/viettelex-apt"
ALLOWED_DOWNLOAD_PREFIX = "https://github.com/ptrinh/viettelex/releases/download/"
# Do gói RPM / Arch ghi (linux/packaging/rpm/viettelex.spec, aur/…/PKGBUILD); .deb không có.
INSTALL_METHOD_FILE = "/usr/share/viettelex-settings/install-method"
OSTREE_BOOTED = "/run/ostree-booted"

# Mã thoát của helper (khớp linux/settings/viettelex-update).
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_LOCK = 3
EXIT_APT = 4
EXIT_VERIFY = 5   # helper tự kiểm: .deb không khớp SHA256 của stable.json nó tự tải
# pkexec: 126 = người dùng bấm Huỷ / không được phép, 127 = không xác thực được.
EXIT_PKEXEC_DISMISSED = 126
EXIT_PKEXEC_NOAUTH = 127


def version_tuple(v):
    """'1.0.3' / '1.0.3~noble1' → (1, 0, 3). Hậu tố ~series bị bỏ."""
    v = str(v).split("~", 1)[0]
    out = []
    for p in v.split("."):
        digits = "".join(c for c in p if c.isdigit())
        out.append(int(digits) if digits else 0)
    while len(out) > 1 and out[-1] == 0:
        out.pop()
    return tuple(out)


def linux_info(info):
    """Mục "linux" hợp lệ của stable.json, hoặc None."""
    lin = info.get("linux") if isinstance(info, dict) else None
    if not isinstance(lin, dict) or not isinstance(lin.get("version"), str):
        return None
    return lin


def state(info, current):
    """('noinfo'|'latest'|'available', linux_info_or_None)."""
    lin = linux_info(info)
    if lin is None:
        return "noinfo", None
    if version_tuple(lin["version"]) > version_tuple(current):
        return "available", lin
    return "latest", lin


def update_message(info, current):
    """(chữ hiển thị, url mở trang tải hoặc None) — giữ API cũ cho nút Kiểm tra."""
    st, lin = state(info, current)
    if st == "noinfo":
        return (_("Chưa có thông tin bản Linux trên kênh ổn định — xem trang phát hành."),
                RELEASES_URL)
    if st == "available":
        return (_("Có bản mới: %s") % lin["version"], lin.get("url") or RELEASES_URL)
    return (_("Bạn đang dùng bản mới nhất (%s).") % current, None)


# --- môi trường máy -------------------------------------------------------------------

def parse_os_release(text):
    out = {}
    for line in text.splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def series_from_version(version):
    """'1.0.3~noble1' → 'noble'; None nếu không có hậu tố."""
    m = re.search(r"~([a-z]+)\d+$", version or "")
    return m.group(1) if m else None


def detect_series(installed, os_release):
    """Series của bộ gói: ưu tiên hậu tố phiên bản đang cài, rồi UBUNTU_CODENAME
    (Mint/Pop/elementary), DEBIAN_CODENAME (LMDE), rồi VERSION_CODENAME."""
    for p in PACKAGES:
        s = series_from_version(installed.get(p))
        if s:
            return s
    return (os_release.get("UBUNTU_CODENAME") or os_release.get("DEBIAN_CODENAME")
            or os_release.get("VERSION_CODENAME") or None)


def apt_repo_configured(read=None):
    """Kho APT VietTelex đã khai báo chưa (file .sources/.list có URI kho)."""
    read = read or _read
    for path in APT_SOURCE_FILES:
        text = read(path)
        if text and APT_REPO_HOST in text:
            for line in text.splitlines():
                s = line.strip()
                if s.startswith("#"):
                    continue
                if APT_REPO_HOST in s:
                    return path
    return None


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


def parse_dpkg_query(text):
    """Output `dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\\n'` → {pkg: ver}
    (chỉ gói đang cài: trạng thái 'ii'/'hi')."""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[2][1:2] == "i" and parts[0] in PACKAGES:
            out[parts[0]] = parts[1]
    return out


# --- cài bằng gì ----------------------------------------------------------------------

def install_method(read=None, exists=os.path.exists):
    """'deb' (mặc định, cập nhật một chạm) | 'rpm' (dnf) | 'rpm-ostree' (Fedora Atomic:
    Silverblue, Kinoite, Bazzite, Bluefin…) | 'pacman' (Arch)."""
    m = ((read or _read)(INSTALL_METHOD_FILE) or "").strip()
    if m == "rpm":
        return "rpm-ostree" if exists(OSTREE_BOOTED) else "rpm"
    if m == "pacman":
        return "pacman"
    return "deb"


def manual_update_hint(method):
    """Chữ báo cách cập nhật khi không cập nhật một chạm được; None với 'deb'."""
    if method == "rpm":
        return _("VietTelex được cài bằng dnf — cập nhật: sudo dnf upgrade --refresh 'viettelex*' "
                 "(hoặc Phần mềm / Discover).")
    if method == "rpm-ostree":
        return _("Fedora Atomic: VietTelex cập nhật cùng hệ thống — rpm-ostree upgrade rồi khởi động "
                 "lại (Bazzite/Bluefin/Aurora tự cập nhật).")
    if method == "pacman":
        return _("VietTelex được cài bằng pacman — cập nhật: sudo pacman -Syu.")
    return None


def install_cmd(pkg, method=None):
    """Lệnh cài gói `pkg` theo trình quản lý gói của máy (hiện trong hướng dẫn bật bộ gõ)."""
    method = method or install_method()
    if method == "rpm":
        return "sudo dnf install %s" % pkg
    if method == "rpm-ostree":
        return "sudo rpm-ostree install %s" % pkg
    if method == "pacman":
        return "sudo pacman -S viettelex"   # một gói Arch chứa cả Fcitx5 lẫn IBus
    return "sudo apt install %s" % pkg


# --- kế hoạch ---------------------------------------------------------------------------

def deb_asset_name(pkg, version, series, arch):
    a = "all" if pkg in ARCH_ALL else arch
    return "%s_%s.%s1_%s.deb" % (pkg, version, series, a)


def plan(lin, installed, series, arch, repo_path, allowed_prefix=None):
    """Chọn đường cập nhật.

    Trả về dict {"kind": "apt", "packages": [...]} | {"kind": "deb", "files": [(name, url,
    sha256)], "packages": [...]} | {"kind": "unsupported", "reason": "…"}.
    """
    pkgs = [p for p in PACKAGES if p in installed]
    if not pkgs:
        return {"kind": "unsupported",
                "reason": _("Không thấy gói VietTelex nào được cài bằng dpkg/apt.")}
    if repo_path:
        return {"kind": "apt", "packages": pkgs}
    if arch not in SUPPORTED_ARCHES:
        return {"kind": "unsupported", "reason": _("Chưa có bản cho kiến trúc %s.") % arch}
    have = lin.get("series") or []
    if not series or series not in have:
        return {"kind": "unsupported",
                "reason": _("Chưa có bản cho %s (hỗ trợ: %s).") % (
                    series or _("hệ điều hành này"), ", ".join(have) or "—")}
    base = lin.get("download") or ""
    if not base.startswith(allowed_prefix or ALLOWED_DOWNLOAD_PREFIX):
        return {"kind": "unsupported", "reason": _("Địa chỉ tải không hợp lệ trong stable.json.")}
    if not base.endswith("/"):
        base += "/"
    sums = lin.get("sha256") or {}
    files = []
    for p in pkgs:
        name = deb_asset_name(p, lin["version"], series, arch)
        sha = sums.get(name)
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
            return {"kind": "unsupported", "reason": _("Thiếu mã kiểm tra SHA256 cho %s.") % name}
        files.append((name, base + name, sha))
    return {"kind": "deb", "files": files, "packages": pkgs}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_sha256(path, expected):
    try:
        return sha256_file(path) == expected.lower()
    except OSError:
        return False


def helper_argv(p, deb_dir=None):
    if p["kind"] == "apt":
        return ["pkexec", HELPER, "apt"] + list(p["packages"])
    if p["kind"] == "deb":
        return ["pkexec", HELPER, "deb", deb_dir]
    raise ValueError(p["kind"])


def tail(text, n=8):
    lines = [ln for ln in (text or "").splitlines() if ln.strip()]
    return "\n".join(lines[-n:])


def result_message(code, output, version):
    """(ok, chữ hiển thị) từ mã thoát helper/pkexec."""
    if code == EXIT_OK:
        return True, (_("Đã cập nhật lên %s. Khởi động lại bộ gõ và mở lại ứng dụng này "
                        "để dùng bản mới.") % version)
    if code in (EXIT_PKEXEC_DISMISSED, EXIT_PKEXEC_NOAUTH):
        return False, _("Đã huỷ — chưa cập nhật (cần mật khẩu quản trị).")
    if code == EXIT_LOCK or "Could not get lock" in (output or "") \
            or "Unable to acquire the dpkg frontend lock" in (output or ""):
        return False, _("Trình quản lý gói đang bận (Software Updater/apt khác đang chạy). "
                         "Đợi xong rồi thử lại.")
    if code == EXIT_VERIFY:
        return False, _("Không xác minh được gói tải về với bản phát hành chính thức — đã huỷ, "
                        "không cài.")
    return False, _("Cập nhật lỗi (mã %d):\n%s") % (code, tail(output) or _("không có thông báo"))


def restart_im_argv(framework):
    if framework == "fcitx5":
        return ["fcitx5", "-r", "-d"]
    if framework == "ibus":
        return ["ibus", "restart"]
    return None


def is_allowed_download(url, allowed_prefix=None):
    return isinstance(url, str) and url.startswith(allowed_prefix or ALLOWED_DOWNLOAD_PREFIX) \
        and os.path.basename(url).endswith(".deb")


# --- chạy (luồng nền của app; không GTK) -------------------------------------------------

def machine():
    """(installed, arch, series) của máy này qua dpkg-query / dpkg / os-release."""
    q = subprocess.run(["dpkg-query", "-W", "-f=${Package} ${Version} ${db:Status-Abbrev}\\n"]
                       + list(PACKAGES), capture_output=True, text=True, timeout=20)
    installed = parse_dpkg_query(q.stdout)
    arch = subprocess.run(["dpkg", "--print-architecture"], capture_output=True, text=True,
                          timeout=10).stdout.strip()
    series = detect_series(installed, parse_os_release(_read("/etc/os-release")))
    return installed, arch, series


def run_update(lin, progress=lambda _t: None, allowed_prefix=None, helper=None):
    """Cập nhật một chạm. Trả (ok, chữ hiển thị, nên mở trang tải thay thế?)."""
    helper = helper or HELPER
    hint = manual_update_hint(install_method())
    if hint:
        return False, hint, True
    try:
        installed, arch, series = machine()
    except (OSError, subprocess.SubprocessError):
        return False, _("Máy này không dùng dpkg/apt — cập nhật theo cách bạn đã cài."), True
    p = plan(lin, installed, series, arch, apt_repo_configured(), allowed_prefix)
    if p["kind"] == "unsupported":
        return False, p["reason"], True
    if not os.path.exists(helper) or not shutil.which("pkexec"):
        return False, _("Thiếu pkexec hoặc helper cập nhật — cài gói pkexec (22.04: policykit-1) "
                         "hoặc cập nhật bằng apt."), True
    tmp = None
    try:
        if p["kind"] == "deb":
            tmp = tempfile.mkdtemp(prefix="viettelex-upd-")
            for i, (name, url, sha) in enumerate(p["files"], 1):
                if not is_allowed_download(url, allowed_prefix):
                    return False, _("Địa chỉ tải không hợp lệ: %s") % url, True
                progress(_("Đang tải %d/%d: %s") % (i, len(p["files"]), name))
                dest = os.path.join(tmp, name)
                try:
                    with urlopen(url, timeout=30) as r, open(dest, "wb") as f:
                        shutil.copyfileobj(r, f)
                except OSError:
                    return False, _("Không tải được %s — kiểm tra mạng rồi thử lại.") % name, False
                if not verify_sha256(dest, sha):
                    return False, _("Sai mã SHA256 của %s — đã huỷ, không cài.") % name, True
            # mkdtemp tạo 0700; apt cài .deb bằng user sandbox "_apt" nên thư mục phải đọc được
            # (không thì apt cài "unsandboxed as root"). Chỉ mở ĐỌC, không ai khác ghi được; gói đã
            # qua kiểm SHA256 ở trên và vốn công khai trên GitHub Releases.
            os.chmod(tmp, 0o755)  # lgtm[py/overly-permissive-file]
        progress(_("Đang cài (cần mật khẩu quản trị)…"))
        argv = helper_argv(p, tmp)
        argv[1] = helper
        try:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=1800)
        except (OSError, subprocess.SubprocessError) as e:
            return False, _("Không chạy được pkexec: %s") % e, False
        ok, msg = result_message(r.returncode, r.stdout + r.stderr, lin["version"])
        return ok, msg, False
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
