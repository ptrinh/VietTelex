#!/usr/bin/env python3
"""gen-vnlexicon.py — sinh ios/Keyboard/VNLexicon2.swift (data cho inline suggestion).

Nguồn:
  1. syllables.txt — 7.184 âm tiết tiếng Việt của hieuthi (đã xếp theo tần suất
     corpus báo chí): https://gist.github.com/hieuthi/1f5d80fca871f3642f61f7e3de883f3a
  2. vi50k.txt — tần suất hội thoại OpenSubtitles (hermitdave/FrequencyWords).

Layout (thiết kế theo research 2026-07-24): entries sort theo foldedKey rồi
freq desc; mỗi ký tự decompose (base, quality, tone) pack 1 byte
attr = quality<<3 | tone. Blob ASCII/UTF-8 làm String literal, attrs/offsets/freq
đóng base64 để không nổ compile-time với hàng vạn literal số.

Usage: python3 Scripts/gen-vnlexicon.py <syllables.txt> <vi50k.txt> <out.swift>
"""
import base64, math, struct, sys, unicodedata

QUALITY = {}  # char -> (base, quality)
TONE = {}     # combining tone -> tone id
for b, hat, horn in [("a","â","ă"), ("e","ê",None), ("o","ô","ơ"), ("u",None,"ư")]:
    QUALITY[b] = (b, 0)
    if hat: QUALITY[hat] = (b, 1)
    if horn: QUALITY[horn] = (b, 2)
QUALITY["đ"] = ("d", 3)
TONES = {"́": 1, "̀": 2, "̉": 3, "̃": 4, "̣": 5}

def decompose_char(ch):
    """→ (base_ascii, quality, tone) hoặc None nếu không phải chữ Việt/Latin."""
    d = unicodedata.normalize("NFD", ch)
    base_q, tone = d[0], 0
    quality = 0
    rest = d[1:]
    for c in rest:
        if c in TONES: tone = TONES[c]
        elif c == "̂": quality = 1          # circumflex
        elif c in ("̛", "̆"): quality = 2  # horn / breve
    if base_q in QUALITY and quality == 0:
        base, quality = QUALITY[base_q][0], QUALITY[base_q][1]
    else:
        base = QUALITY.get(base_q, (base_q, 0))[0]
    if ch == "đ": base, quality = "d", 3
    if not ("a" <= base <= "z"): return None
    return base, quality, tone

# Kiểu dấu CŨ (hòa, thủy — convention của VietTelex, engine modern=false):
# nguồn hieuthi dùng kiểu mới (toà, thuý) → chuyển về cũ. Riêng sau 'q' thì
# u là glide của 'qu' nên tone ở nguyên âm sau (quỳ giữ nguyên).
_OLD_STYLE = {
    "oà":"òa","oá":"óa","oả":"ỏa","oã":"õa","oạ":"ọa",
    "oè":"òe","oé":"óe","oẻ":"ỏe","oẽ":"õe","oẹ":"ọe",
    "uỳ":"ùy","uý":"úy","uỷ":"ủy","uỹ":"ũy","uỵ":"ụy",
}
def to_old_style(w):
    # chỉ âm tiết MỞ (cặp nguyên âm ở cuối từ): hòa/thủy; có coda giữ nguyên
    # (toàn, thuyền — hai kiểu giống nhau). Sau 'q' thì u là glide → giữ (quý).
    if len(w) >= 2:
        pair = w[-2:]
        if pair in _OLD_STYLE and not (pair[0] == "u" and len(w) >= 3 and w[-3] == "q"):
            return w[:-2] + _OLD_STYLE[pair]
    return w

def main():
    syl_path, freq_path, out_path = sys.argv[1:4]
    syllables = []
    seen = set()
    for line in open(syl_path, encoding="utf-8"):
        w = unicodedata.normalize("NFC", line.strip().lower())
        w = to_old_style(w)
        if w and w not in seen:
            seen.add(w); syllables.append(w)

    counts = {}
    for line in open(freq_path, encoding="utf-8"):
        parts = line.split()
        if len(parts) == 2:
            w = to_old_style(unicodedata.normalize("NFC", parts[0].lower()))
            counts[w] = max(counts.get(w, 0), int(parts[1]))

    # freq 0-255: log từ OpenSubtitles; thiếu thì theo rank hieuthi (đuôi thấp)
    maxlog = math.log(max(counts.values()))
    entries = []
    for rank, w in enumerate(syllables):
        c = counts.get(w)
        if c: f = max(1, int(255 * math.log(c) / maxlog))
        else: f = max(1, int(60 * (1 - rank / len(syllables))))
        dec = [decompose_char(ch) for ch in w]
        if any(d is None for d in dec): continue
        folded = "".join(d[0] for d in dec)
        attrs = bytes((d[1] << 3 | d[2]) for d in dec)
        entries.append((folded, 255 - f, w, attrs, f))   # sort key: folded, freq desc
    entries.sort()

    folded_blob, attr_blob, disp_blob = bytearray(), bytearray(), bytearray()
    offsets, disp_offsets, freqs = [0], [0], []
    for folded, _, w, attrs, f in entries:
        folded_blob += folded.encode()
        attr_blob += attrs
        disp_blob += w.encode("utf-8")
        offsets.append(len(folded_blob))
        disp_offsets.append(len(disp_blob))
        freqs.append(f)

    # bucket top-32 theo ký tự folded đầu (hot path prefix 1 phím)
    buckets = {}
    for i, (folded, _, w, attrs, f) in enumerate(entries):
        buckets.setdefault(folded[0], []).append((f, i))
    top = {}
    for ch, lst in buckets.items():
        lst.sort(reverse=True)
        top[ch] = [i for _, i in lst[:32]]

    def b64(data): return base64.b64encode(bytes(data)).decode()
    def u32le(vals): return b64(struct.pack("<%dI" % len(vals), *vals))

    top_lines = []
    for ch in sorted(top):
        ids = ", ".join(str(i) for i in top[ch])
        top_lines.append(f'        "{ch}": [{ids}],')

    swift = f'''// VNLexicon2.swift — GENERATED bởi Scripts/gen-vnlexicon.py. KHÔNG sửa tay.
// {len(entries)} âm tiết tiếng Việt (hieuthi 7184 + tần suất OpenSubtitles),
// sort theo foldedKey rồi tần suất giảm dần. attr mỗi ký tự = quality<<3|tone
// (quality: 0 none, 1 â/ê/ô, 2 ơ/ư/ă, 3 đ; tone: 0 ngang 1 sắc 2 huyền 3 hỏi
// 4 ngã 5 nặng). Blob nằm trong binary — zero cold-start.
import Foundation

enum VNLexicon2Data {{
    static let count = {len(entries)}
    static let foldedBlob = Array("{folded_blob.decode()}".utf8)
    static let displayBlob = Array("{disp_blob.decode()}".utf8)
    static let attrBlob: [UInt8] = Array(Data(base64Encoded: "{b64(attr_blob)}")!)
    static let offsetsRaw = "{u32le(offsets)}"
    static let dispOffsetsRaw = "{u32le(disp_offsets)}"
    static let freqRaw = "{b64(freqs)}"
    static let firstCharTop: [Character: [Int]] = [
{chr(10).join(top_lines)}
    ]
}}
'''
    open(out_path, "w", encoding="utf-8").write(swift)
    print(f"entries={len(entries)} folded={len(folded_blob)}B disp={len(disp_blob)}B attrs={len(attr_blob)}B")

if __name__ == "__main__":
    main()
