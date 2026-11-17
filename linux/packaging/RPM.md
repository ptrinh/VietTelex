# Gói RPM + kho DNF của VietTelex / VietTelex RPM packages and DNF repository

Kho: `https://ptrinh.github.io/viettelex-apt/rpm/` (cùng trang GitHub Pages với kho APT), ký bằng
cùng khoá GPG `43ADE236BCC43900B8F146B4F57C885055149990`.

## Hỗ trợ / Support matrix

| Distro | Kho | x86_64 | aarch64 | Fcitx5 | IBus | App cài đặt |
|---|---|---|---|---|---|---|
| Fedora 43, 44 (Workstation, KDE, spin…) | `rpm/fedora/<NN>/` | ✓ | ✓ | ✓ | ✓ | ✓ (libadwaita 1.8 / 1.9) |
| Fedora Atomic 43, 44 (Silverblue, Kinoite, Bazzite, Bluefin, Aurora…) | cùng kho Fedora, qua rpm-ostree | ✓ | ✓ | ✓ | ✓ | ✓ |
| RHEL / Rocky / Alma / CentOS Stream / Oracle 10 | `rpm/el/10/` | ✓ | ✓ | ✗ | ✓ | ✓ (libadwaita 1.6) |
| RHEL / Rocky / Alma / CentOS Stream / Oracle 9 | `rpm/el/9/` | ✓ | ✓ | ✗ | ✓ | ✓ (libadwaita 1.4) |

- **Enterprise Linux chỉ có IBus**: EPEL 9 và EPEL 10 không có gói `fcitx5` (kiểm 10/2026), nên
  không build `viettelex-fcitx5` cho EL. IBus, GTK4, libadwaita, PyGObject đều ở BaseOS/AppStream —
  **không cần EPEL**. / *EL ships the IBus engine only: EPEL 9/10 have no fcitx5. Every dependency
  is in BaseOS/AppStream, EPEL is not needed.*
- EL9 dùng IBus 1.5.25: gõ đủ, nhưng chưa có `focus_in_id` (IBus ≥ 1.5.28) nên chế độ theo app và
  nhớ Việt/Anh theo app dùng "default" (như Ubuntu 22.04). / *EL9's IBus 1.5.25 has no per-app
  identity, so per-app modes fall back to "default".*
- Gói giống bản .deb: `libviettelex-core` (engine, `/usr/lib64/viettelex/`), `viettelex-fcitx5`
  (`/usr/lib64/fcitx5/viettelex.so` + `/usr/share/fcitx5/{addon,inputmethod}/viettelex.conf`),
  `viettelex-ibus` (`/usr/libexec/ibus-engine-viettelex` + `/usr/share/ibus/component/viettelex.xml`),
  `viettelex-text-tools`, `viettelex-settings` (noarch) và metapackage `viettelex`.
- Không có nút cập nhật một chạm (helper apt + polkit không được cài): app báo
  `sudo dnf upgrade --refresh 'viettelex*'` (Fedora Atomic: `rpm-ostree upgrade`).

## Tiếng Việt — cài đặt

**Một lệnh** (tự nhận Fedora / EL / Fedora Atomic; chạy lại = cập nhật; `--ibus`, `--uninstall`,
`--dry-run`):

```sh
curl -fsSL https://viettelex.com/install.sh | bash
```

**Fedora — kho thủ công:**

```sh
sudo curl -fsSLo /etc/pki/rpm-gpg/RPM-GPG-KEY-viettelex \
  https://ptrinh.github.io/viettelex-apt/rpm/RPM-GPG-KEY-viettelex
sudo curl -fsSLo /etc/yum.repos.d/viettelex.repo \
  https://ptrinh.github.io/viettelex-apt/rpm/viettelex-fedora.repo
sudo dnf install viettelex viettelex-fcitx5      # GNOME giữ IBus: sudo dnf install viettelex viettelex-ibus
```

(Hoặc dnf5: `sudo dnf config-manager addrepo --from-repofile=https://ptrinh.github.io/viettelex-apt/rpm/viettelex-fedora.repo`.)
Lần đầu dnf hỏi nhập khoá — kiểm vân tay là `43AD E236 BCC4 3900 B8F1  46B4 F57C 8850 5514 9990`.

**RHEL / Rocky / Alma 9 hoặc 10:** như trên nhưng file `viettelex-el9.repo` (hoặc
`viettelex-el10.repo`), rồi `sudo dnf install viettelex` (tự kèm `viettelex-ibus`).

**Fedora Atomic (Silverblue, Kinoite, Bazzite, Bluefin, Aurora…):** `/etc` ghi được, `/usr` thì
không — gói được *xếp lớp* (layer) bằng rpm-ostree và có hiệu lực sau khi khởi động lại:

```sh
sudo curl -fsSLo /etc/pki/rpm-gpg/RPM-GPG-KEY-viettelex \
  https://ptrinh.github.io/viettelex-apt/rpm/RPM-GPG-KEY-viettelex
sudo curl -fsSLo /etc/yum.repos.d/viettelex.repo \
  https://ptrinh.github.io/viettelex-apt/rpm/viettelex-fedora.repo
sudo sed -i 's/^repo_gpgcheck=1/repo_gpgcheck=0/' /etc/yum.repos.d/viettelex.repo   # rpm-ostree không kiểm được chữ ký repomd
sudo rpm-ostree install viettelex viettelex-ibus       # Kinoite/KDE: viettelex-fcitx5
systemctl reboot
```

rpm-ostree vẫn kiểm chữ ký **từng gói** (`gpgcheck=1`). Fcitx5/IBus đã có trong ảnh hệ thống
(Silverblue có IBus; Bazzite/Bluefin/Aurora tuỳ bản) thì không bị xếp lớp lại. Cập nhật đi cùng
hệ thống: `rpm-ostree upgrade` rồi khởi động lại (Bazzite/Bluefin/Aurora tự cập nhật, hoặc
`ujust update`). Gỡ: `sudo rpm-ostree uninstall viettelex viettelex-ibus`, xoá
`/etc/yum.repos.d/viettelex.repo`, khởi động lại.

**Sau khi cài:** mở **VietTelex** trong menu ứng dụng (hoặc `viettelex-settings --onboarding`).
IBus: `ibus restart`, rồi Cài đặt → Bàn phím → Nguồn nhập → + → Tiếng Việt → VietTelex. Fcitx5
trên GNOME: nút *Dùng Fcitx5* trong app; KDE: Cài đặt hệ thống → Bàn phím → Bàn phím ảo → Fcitx 5.

**Cập nhật:** `sudo dnf upgrade --refresh` (hoặc chạy lại lệnh một dòng). **Gỡ:**
`curl -fsSL https://viettelex.com/install.sh | bash -s -- --uninstall`, hoặc
`sudo dnf remove 'viettelex*' libviettelex-core` rồi xoá `/etc/yum.repos.d/viettelex.repo` và
`/etc/pki/rpm-gpg/RPM-GPG-KEY-viettelex`.

## English — install

Run the one-line installer above (it detects Fedora, Enterprise Linux and Fedora Atomic), or add
the repository by hand: download `RPM-GPG-KEY-viettelex` to `/etc/pki/rpm-gpg/`, download
`viettelex-fedora.repo` (EL: `viettelex-el9.repo` / `viettelex-el10.repo`) to
`/etc/yum.repos.d/viettelex.repo`, then `sudo dnf install viettelex viettelex-fcitx5` (or
`viettelex-ibus`; EL always uses IBus). Packages and repository metadata are both signed
(`gpgcheck=1`, `repo_gpgcheck=1`). `sudo dnf upgrade` delivers updates.

**Fedora Atomic** (Silverblue, Kinoite, Bazzite, Bluefin, Aurora): put the same key and `.repo`
file in `/etc`, set `repo_gpgcheck=0` (rpm-ostree cannot verify a signed `repomd.xml`; it still
verifies every package signature), `sudo rpm-ostree install viettelex viettelex-ibus` (KDE:
`viettelex-fcitx5`) and reboot. Updates come with `rpm-ostree upgrade` (automatic on
Bazzite/Bluefin/Aurora). The settings app tells you to update through dnf or rpm-ostree; it has
no one-click updater on RPM systems.

---

## Dành cho người phát hành / For maintainers

### Build

```sh
linux/packaging/build-rpm.sh                                  # fc43 fc44 el9 el10 × x86_64 aarch64
linux/packaging/build-rpm.sh --target "fc44 el9" --arch aarch64   # một phần (Mac Apple silicon: native)
linux/packaging/test-rpm.sh [--skip-build] [--target "fc44 el9 el10"]   # kho file:// + install.sh, khoá thử
```

- **Swift:** ảnh `swift:<series>` chỉ có cho Ubuntu/Debian; với Red Hat, swift.org phát hành
  `swift:rhel-ubi9` và `swift:rhel-ubi10` (ảnh `swift:fedora39` đã dừng ở Swift 6.0; Fedora có gói
  `swift-lang` 6.3 nhưng EL thì không). Vì vậy engine (`libtelexcore.so` + `viettelex-text-tool`,
  `--static-swift-stdlib`) build **một lần mỗi arch** trong `swift:rhel-ubi9` — glibc 2.34, thấp
  nhất trong các target ⇒ chạy được trên EL9, EL10, Fedora — bằng đúng target CMake
  `telexcore_swift` (`rpm/build-swift.sh`; `VT_SWIFT_TAG=6.4` ⇒ `swift:6.4-rhel-ubi9`). Frontend
  C++ (Fcitx5/IBus) và gói build **native trong từng distro** (`fedora:NN`,
  `rockylinux/rockylinux:N`) bằng `rpm/viettelex.spec` (`--define vt_swift_dir …`), nên đường dẫn
  và phụ thuộc (`/usr/lib64/fcitx5`, soname Fcitx5/IBus) đúng của distro đó.
- `%check`: desktop-file-validate, appstreamcli validate, test app cài đặt, ctest (golden corpus,
  text tool fixtures, Fcitx5 testfrontend, GnomeAppMonitor). `ibus_smoke` chỉ chạy trên EL9: IBus
  của Fedora/EL10 giữ context theo engine toàn cục nên harness `set_engine()` không gắn được engine
  — việc engine nạp được kiểm ở bước cài thử (`rpm/smoke-install.sh`: `ibus list-engine`, Fcitx5
  `AvailableInputMethods`, `rpm -V`, import app cài đặt, text tool).
- Kết quả: `linux/dist/rpm/<target>/*.rpm` (gitignored).

### Ký kho / Signing (`dnf-repo.sh`)

Hai lớp, cả hai bằng gpg **trên máy người phát hành**: (1) từng `.rpm` mang chữ ký v4 (`rpmsign`
chạy trong container `rockylinux:9`, nhưng `%__gpg` là một proxy: dữ liệu cần ký được ghi ra thư
mục chung, vòng lặp trên host ký bằng `gpg --detach-sign` rồi trả chữ ký — khoá bí mật không vào
container; chuyển socket gpg-agent vào container không chạy với OrbStack/Docker Desktop);
(2) `repodata/repomd.xml.asc` ký thẳng trên host. File `.repo` bật `gpgcheck=1` + `repo_gpgcheck=1`.

### Phát hành / Release (sau mục "Phát hành qua CI" của [APT.md](APT.md))

```sh
# CI linux-release.yml đã build + attest .rpm; artifact viettelex-linux-$V có linux/dist/rpm/<target>/
for f in linux/dist/rpm/*/*.rpm; do
  gh attestation verify "$f" --repo ptrinh/VietTelex --signer-workflow ptrinh/VietTelex/.github/workflows/linux-release.yml >/dev/null \
    && echo "ok  $f" || { echo "FAIL $f"; break; }
done
gh release upload "linux-v$V" linux/dist/rpm/*/*.rpm          # nếu release không tạo từ draft CI
VT_RPM_KEY=43ADE236BCC43900B8F146B4F57C885055149990 linux/packaging/dnf-repo.sh --out ../viettelex-apt
# (hoặc --download $V để lấy .rpm từ GitHub Release) → ../viettelex-apt/rpm/, rồi commit + push viettelex-apt
```

Thêm bản Fedora mới (vd 45): `image_of` trong `build-rpm.sh` + `test-rpm.sh`, matrix `target` trong
`linux-release.yml`, `RPM_SUPPORTED` trong `docs/install.sh` (+ `test-install-detect.sh`), bảng ở
đây. Bỏ bản hết hạn cũng ở các chỗ đó (kho giữ thư mục cũ tới lần `dnf-repo.sh` sau).
