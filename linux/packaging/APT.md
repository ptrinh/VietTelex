# Kho APT của VietTelex / VietTelex APT repository

Kho: `https://ptrinh.github.io/viettelex-apt/` — Ubuntu 22.04 (jammy), 24.04 (noble),
26.04 (resolute), Debian 12 (bookworm), 13 (trixie); amd64 + arm64. Được ký bằng GPG; `apt` tự
kiểm chữ ký. Bản phái sinh dùng series gốc: Mint/Pop!_OS/Zorin/elementary → `UBUNTU_CODENAME`,
LMDE → `DEBIAN_CODENAME`, MX/Raspberry Pi OS 64-bit → `VERSION_CODENAME`, Kali rolling → trixie
(thử nghiệm). Fedora / RHEL / Fedora Atomic: [RPM.md](RPM.md). Arch Linux: [ARCH.md](ARCH.md).

## Cài bằng một lệnh / One-line install

```sh
curl -fsSL https://viettelex.com/install.sh | bash
```

Script (`docs/install.sh`) làm đúng các bước bên dưới: kiểm `InRelease` được ký bởi khoá
`43ADE236BCC43900B8F146B4F57C885055149990` (vân tay ghim trong script), thêm khoá + file
`viettelex.sources`, rồi `apt-get install viettelex` (metapackage; Fcitx5 mặc định, hỏi nếu máy
chỉ có IBus/GNOME) và `im-config -n fcitx5`. Tuỳ chọn: `--ibus`, `--fcitx5`, `--yes`,
`--uninstall`, `--dry-run`. Chạy lại = cập nhật. Cùng script cài bản macOS (Homebrew hoặc .pkg
đã kiểm chữ ký). / The script performs the steps below, pins the repository key fingerprint,
installs the `viettelex` metapackage and supports `--ibus`, `--uninstall` and `--dry-run`.

## Tiếng Việt — cài đặt từng bước

```sh
# 1. Khoá ký của kho
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://ptrinh.github.io/viettelex-apt/viettelex-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/viettelex.gpg >/dev/null

# 2. Khai báo kho (định dạng deb822)
sudo tee /etc/apt/sources.list.d/viettelex.sources >/dev/null <<EOF
Types: deb
URIs: https://ptrinh.github.io/viettelex-apt/
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-${DEBIAN_CODENAME:-$VERSION_CODENAME}}")
Components: main
Signed-By: /etc/apt/keyrings/viettelex.gpg
EOF

# 3. Cài — chọn MỘT bộ khung gõ
sudo apt update
sudo apt install viettelex            # metapackage: engine + app cài đặt + Fcitx5 (khuyên dùng)
# hoặc: sudo apt install viettelex viettelex-ibus   (giữ IBus, mặc định Ubuntu/GNOME)
# (kho cũ chưa có metapackage: sudo apt install viettelex-fcitx5 viettelex-settings)
```

Sau khi cài: mở **VietTelex** trong menu ứng dụng (hoặc `viettelex-settings --onboarding`)
và làm theo hướng dẫn bật bộ gõ. Cập nhật về sau: `sudo apt update && sudo apt upgrade`.

Nút **Giới thiệu → Kiểm tra cập nhật** trong app cũng cập nhật được (một chạm, hỏi mật khẩu qua
polkit): máy có kho APT thì chạy `apt-get install --only-upgrade` các gói VietTelex; cài bằng
.deb thì tải đúng bộ .deb, kiểm SHA256 theo `stable.json` rồi cài.

Gỡ: `curl -fsSL https://viettelex.com/install.sh | bash -s -- --uninstall`, hoặc
`sudo apt remove viettelex viettelex-fcitx5 viettelex-ibus viettelex-text-tools viettelex-settings libviettelex-core`,
rồi xoá `/etc/apt/sources.list.d/viettelex.sources` và `/etc/apt/keyrings/viettelex.gpg`.

## English — install

Run the three steps above (add the key to `/etc/apt/keyrings/viettelex.gpg`, add the
`viettelex.sources` file, then `sudo apt update && sudo apt install viettelex-fcitx5`, or
`viettelex-ibus` for IBus). Then open **VietTelex** from the app menu, or run
`viettelex-settings --onboarding`, and follow the setup guide. `apt upgrade` delivers updates.

## Không dùng kho: tải .deb / Without the repository: download the .deb

Mỗi bản phát hành trên GitHub Releases (`https://github.com/ptrinh/viettelex/releases`) có
các file `.deb` theo series và kiến trúc. Tải đúng bộ (vd Ubuntu 24.04, máy Intel/AMD:
các file `~noble1_amd64.deb` + `viettelex-settings_…~noble1_all.deb`) rồi cài một lệnh:

Each GitHub release ships `.deb` files per series and architecture. Download the matching
set, then install it with one command:

```sh
sudo apt install ./libviettelex-core_*_amd64.deb ./viettelex-fcitx5_*_amd64.deb \
                 ./viettelex-text-tools_*_amd64.deb ./viettelex-settings_*_all.deb

```

Cách này không tự cập nhật qua apt; nút *Kiểm tra cập nhật* trong app tải + kiểm SHA256 +
cài bản mới. This route does not update through apt; the app's *Kiểm tra cập nhật* button
downloads the new .debs, checks their SHA256 against `stable.json` and installs them.

---

## Dành cho người phát hành / For maintainers

```sh
linux/packaging/build-all.sh     # linux/dist/{jammy,noble,resolute,bookworm,trixie}/*.deb, lintian + smoke test
VT_APT_KEY=<fingerprint> linux/packaging/apt-repo.sh --out ../viettelex-apt
```

Build đủ 5 series × 2 arch trên máy local tốn ~6 GB ảnh Docker mỗi series × arch (swift:<series>)
và nhiều giờ qua Rosetta cho amd64 — **đường chính là build trên CI** (mục "Phát hành qua CI"
bên dưới); `build-all.sh` local vẫn dùng được (`--series`/`--arch` để build một phần).

- `apt-repo.sh` sinh `pool/main/v/viettelex/`, `dists/<series>/main/binary-{amd64,arm64}/Packages(.gz)`
  và `Release` bằng `apt-ftparchive` (trong container `ubuntu:24.04` nếu host không có). Script ký
  `InRelease` (clearsign) và `Release.gpg` (detached) bằng `gpg` **trên host**, rồi xuất khoá công khai
  ra `viettelex-archive-keyring.gpg` (binary). Khoá bí mật không bao giờ vào container hay repo.
- Mỗi series có phiên bản riêng (`1.0.0~jammy1`, `1.0.0~noble1`, `1.0.0~bookworm1`…), nên pool
  dùng chung được. Thứ tự chữ cái của tên series trùng thứ tự phát hành (jammy < noble <
  resolute; bookworm < trixie) ⇒ nâng cấp distro thì `apt` cũng nâng gói.
  Gói `_all` lấy từ bản build đầu tiên của series để mọi arch cùng trỏ vào một file.
- Đẩy thư mục output lên repo GitHub Pages `viettelex-apt` (có sẵn `.nojekyll`).
- Đổi/xoay khoá: xuất bản khoá mới cùng lúc với khoá cũ trong một thời gian, và báo người dùng
  tải lại `viettelex-archive-keyring.gpg`. **Nhớ sửa `APT_KEY_FPR` trong `docs/install.sh`** —
  script từ chối kho ký bằng khoá khác. Khoá hiện tại hết hạn 2031-09.
- Gói `viettelex` (metapackage, `_all`) build cùng các gói khác; phụ thuộc
  `libviettelex-core`, `viettelex-settings (=)` và `viettelex-fcitx5 | viettelex-ibus`;
  Recommends `viettelex-text-tools`.
- `viettelex-settings` mang helper `/usr/libexec/viettelex/viettelex-update` + polkit action
  `org.viettelex.update` (`/usr/share/polkit-1/actions/org.viettelex.update.policy`) cho nút
  cập nhật một chạm; helper chỉ nhận các gói VietTelex (danh sách trắng).

### Phát hành qua CI (khuyên dùng)

`.github/workflows/linux-release.yml` (chạy tay) build mọi series × arch bằng đúng
`build-all.sh` (build + ctest + test app cài đặt + lintian + cài thử), sinh `SHA256SUMS` và
**build provenance attestation** (Sigstore) cho từng .deb. CI **không** ký kho APT và không
phát hành gì: khoá GPG chỉ nằm trên máy người phát hành.

```sh
# 0. VERSION + debian/changelog đã tăng và đã push lên main (workflow kiểm hai số khớp nhau).
V=X.Y.Z
gh workflow run linux-release.yml --ref main -f version=$V      # thêm -f draft_release=true để CI tạo release NHÁP
RUN=$(gh run list --workflow linux-release.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN" --exit-status

# 1. Tải về đúng chỗ apt-repo.sh / stable-linux.py đọc: linux/dist/<series>/*.deb
rm -rf linux/dist && gh run download "$RUN" -n "viettelex-linux-$V" -D linux/dist

# 2. Kiểm attestation: mỗi .deb phải được build bởi workflow này của repo này.
for f in linux/dist/*/*.deb; do
  gh attestation verify "$f" --repo ptrinh/VietTelex     --signer-workflow ptrinh/VietTelex/.github/workflows/linux-release.yml >/dev/null     && echo "ok  $f" || { echo "FAIL $f"; break; }
done

# 3. stable.json + SHA256SUMS sinh lại trên máy này — phải trùng bản CI
mv linux/dist/SHA256SUMS linux/dist/SHA256SUMS.ci && rm linux/dist/stable.json
linux/packaging/stable-linux.py --notes "…"
cmp linux/dist/SHA256SUMS.ci linux/dist/SHA256SUMS && rm linux/dist/SHA256SUMS.ci

# 4. GitHub Release: nếu đã chạy draft_release=true thì sửa ghi chú rồi publish bản nháp
#    (gh release edit linux-v$V --notes-file … --draft=false); không thì:
gh release create "linux-v$V" linux/dist/*/*.deb linux/dist/rpm/*/*.rpm linux/dist/arch/*.pkg.tar.zst \
  linux/dist/SHA256SUMS --notes-file …

# 5. Ký + dựng kho APT, DNF, pacman trên máy này, rồi push repo viettelex-apt
#    (CI đã build + attest .rpm / .pkg.tar.zst cùng artifact; kiểm attestation như bước 2:
#     linux/dist/rpm/*/*.rpm và linux/dist/arch/*.pkg.tar.zst)
VT_APT_KEY=<fingerprint> linux/packaging/apt-repo.sh --out ../viettelex-apt
VT_RPM_KEY=<fingerprint> linux/packaging/dnf-repo.sh --out ../viettelex-apt          # → rpm/  (RPM.md)
VT_PACMAN_KEY=<fingerprint> linux/packaging/pacman-repo.sh --out ../viettelex-apt    # → arch/ (ARCH.md)

# 6. Sau cùng: commit + push docs/stable.json; AUR: linux/packaging/aur/README.md
```

Người dùng tự kiểm được một .deb tải về: `gh attestation verify <file>.deb --repo ptrinh/VietTelex`.

### Checklist phát hành Linux (build local)

1. Tăng `VERSION` trong `linux/settings/viettelex_settings/__init__.py` + mục mới đầu
   `linux/packaging/debian/changelog` (cùng số).
2. `linux/packaging/build-all.sh` → `linux/dist/<series>/*.deb` (lintian + smoke test), hoặc tải
   từ CI như mục trên.
3. `linux/packaging/stable-linux.py --notes "…"` → ghi mục `"linux"` vào `docs/stable.json`
   (phiên bản, link, series, SHA256 từng .deb theo tên asset GitHub — `~` thành `.`) và
   `linux/dist/SHA256SUMS`. Khoá gốc (macOS) và `"windows"` giữ nguyên.
4. `gh release create linux-vX.Y.Z linux/dist/*/*.deb linux/dist/SHA256SUMS --notes-file …`
   (ghi chú theo mẫu dưới). **Tên asset phải đúng như stable.json** — kiểm bằng
   `sha256sum -c` sau khi tải lại vài file.
5. `VT_APT_KEY=… linux/packaging/apt-repo.sh --out ../viettelex-apt` rồi push repo
   `viettelex-apt` (Pages).
6. Commit + push `docs/stable.json` **sau cùng** (khi asset và kho đã có): app cài đặt Linux
   đọc `https://viettelex.com/stable.json` → mục `linux` để báo/cài bản mới.
7. AUR: `linux/packaging/aur/bump.py` rồi đẩy `viettelex-bin` (xem [aur/README.md](aur/README.md)).

`stable.json` — mục Linux (app bản ≥ 1.0.4 đọc; macOS/Windows bỏ qua):

```json
"linux": {
  "version": "1.0.4",
  "url": "https://github.com/ptrinh/viettelex/releases/tag/linux-v1.0.4",
  "download": "https://github.com/ptrinh/viettelex/releases/download/linux-v1.0.4/",
  "series": ["bookworm", "jammy", "noble", "resolute", "trixie"],
  "sha256": { "libviettelex-core_1.0.4.noble1_amd64.deb": "<sha256>", "…": "…" },
  "notes": "…"
}
```

### Mẫu ghi chú phát hành / Release notes template

```markdown
**Cài / cập nhật bằng một lệnh (Ubuntu 22.04/24.04/26.04, Debian 12/13, Fedora 43/44, RHEL/Rocky/Alma 9/10, Fedora Atomic, Arch):**

    curl -fsSL https://viettelex.com/install.sh | bash

Đã cài từ kho APT: `sudo apt update && sudo apt upgrade`, hoặc app VietTelex → Giới thiệu →
Kiểm tra cập nhật. Tải tay: chọn `.jammy1` (22.04) / `.noble1` (24.04) / `.resolute1` (26.04) /
`.bookworm1` (Debian 12) / `.trixie1` (Debian 13) + kiến trúc, rồi
`sudo apt install ./*.deb` — kiểm bằng `sha256sum -c SHA256SUMS --ignore-missing`.

### Thay đổi
- …

---
**One-line install / update:** `curl -fsSL https://viettelex.com/install.sh | bash`
(APT users: `sudo apt update && sudo apt upgrade`.)
```
