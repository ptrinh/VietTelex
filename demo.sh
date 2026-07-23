#!/bin/bash
# demo.sh — gõ đoạn giới thiệu VietTelex vào TextEdit bằng chuỗi phím Telex THÔ,
# TỪNG PHÍM MỘT (CGEvent keyDown/keyUp thật, đi qua bộ gõ y như người bấm),
# canh để gõ hết toàn bộ trong ~3 giây. Chạy 2 lần để so sánh:
#   1) đang chọn VietTelex   → ra tiếng Việt chuẩn, từ tiếng Anh tự khôi phục
#   2) đang chọn Telex của Apple (hoặc bộ gõ khác) → so chất lượng
# Yêu cầu: cho phép Terminal điều khiển máy (Privacy → Accessibility).

KEY_DELAY_MS=6    # ~490 phím ≈ 3s (đo thực tế)

TEXT_P1="VietTelex laf booj gox Telex tieengs Vieetj cho macOS, xaay treen InputMethodKit ddeer tichs howpj saau: khoong gachj chaan tuwf ddang gox, daaus bor thawngr vaof chuwx, gox dduwowcj car trong Terminal. Tichs hopwj sawnx feature tuwj ddooir banf phims theo app/vawn banr cuar MacOS."
TEXT_P2="Gox tuwf tieengs Anh thif tuwj restore nhuw thuwowngf. Gox truwcj tieeps thay vif xoas rooif bowm laij neen chuwx khoong nhayr giaatj, khoong caanf quyeenf Accessibility vaanx chayj oonr. Wow!"
TEXT_P3="App chir toons 9.5MB RAM, CPU gaanf bawngf 0, installer chuwa towis 1MB. Thanks for supporting! From ptrinh with love <3"

TYPER=/tmp/vt-demo-typer
SRC=/tmp/vt-demo-typer.swift

if [ ! -x "$TYPER" ] || [ "$0" -nt "$TYPER" ]; then
  cat > "$SRC" <<'SWIFT'
import CoreGraphics
import Foundation

// US-ANSI keycode map; value = (keycode, needsShift)
let map: [Character: (CGKeyCode, Bool)] = {
    var m: [Character: (CGKeyCode, Bool)] = [:]
    let lower: [(Character, CGKeyCode)] = [
        ("a",0),("s",1),("d",2),("f",3),("h",4),("g",5),("z",6),("x",7),("c",8),("v",9),
        ("b",11),("q",12),("w",13),("e",14),("r",15),("y",16),("t",17),
        ("1",18),("2",19),("3",20),("4",21),("6",22),("5",23),("9",25),("7",26),("8",28),("0",29),
        ("o",31),("u",32),("i",34),("p",35),("l",37),("j",38),("k",40),
        (",",43),("/",44),("n",45),("m",46),(".",47),(" ",49),(";",41),("'",39),("-",27),("=",24),
    ]
    for (c, k) in lower { m[c] = (k, false) }
    for (c, k) in lower where c.isLetter {
        m[Character(c.uppercased())] = (k, true)
    }
    m["!"] = (18, true); m[":"] = (41, true); m["?"] = (44, true); m["\n"] = (36, false)
    m["<"] = (43, true); m[">"] = (47, true); m["("] = (25, true); m[")"] = (29, true)
    m["@"] = (19, true); m["\""] = (39, true); m["+"] = (24, true); m["_"] = (27, true)
    return m
}()

let args = CommandLine.arguments
guard args.count >= 3, let delayMs = Double(args[1]) else {
    FileHandle.standardError.write("usage: vt-demo-typer <delay-ms> <text>\n".data(using: .utf8)!)
    exit(1)
}
let text = args[2]
let gap = UInt32(delayMs * 1000)
let src = CGEventSource(stateID: .hidSystemState)

// Ký tự cần Shift phải được bọc bằng phím Shift THẬT (keycode 56): chuỗi
// unicode nhúng trong event được suy từ keycode + TRẠNG THÁI NGUỒN lúc tạo,
// nên phải cho nguồn "thấy" Shift đang giữ — set cờ suông thì chuỗi nhúng
// vẫn là bản không-shift ('!' thành '1' khi bộ gõ đọc qua event-tap), còn
// tự ghi đè chuỗi nhúng (keyboardSetUnicodeString) lại làm IMK bỏ qua bộ gõ.
let SHIFT = CGKeyCode(56)
func postShift(_ downState: Bool) {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: SHIFT, keyDown: downState) else { return }
    e.flags = downState ? .maskShift : []
    e.post(tap: .cghidEventTap)
}
// Prime: nhịp Shift đầu tiên sau khi process khởi động hay bị nuốt trạng
// thái — đạp một nhịp rỗng trước khi gõ thật.
postShift(true); usleep(20000); postShift(false); usleep(20000)
for ch in text {
    guard let (key, shift) = map[ch] else { continue }
    if shift { postShift(true); usleep(8000) }
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
          let up   = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { continue }
    if shift { down.flags = .maskShift; up.flags = .maskShift }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    if shift { usleep(2000); postShift(false) }
    usleep(gap)
}
SWIFT
  echo "Compiling typer (lần đầu)…"
  swiftc -O -o "$TYPER" "$SRC" || exit 1
fi

APP="${1:-TextEdit}"   # ./demo.sh TextMate → gõ vào TextMate
osascript -e "tell application \"$APP\" to activate" >/dev/null
sleep 1.2
front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
[ "$front" = "$APP" ] || { echo "$APP không ở foreground — thử lại."; exit 1; }
# TextEdit: mở document mới; app khác: bơm thẳng vào cửa sổ hiện tại
if [ "$APP" = "TextEdit" ]; then
  osascript -e 'tell application "System Events" to keystroke "n" using command down'
  sleep 0.8
fi

"$TYPER" "$KEY_DELAY_MS" "$TEXT_P1
"
"$TYPER" "$KEY_DELAY_MS" "
"
"$TYPER" "$KEY_DELAY_MS" "$TEXT_P2
"
"$TYPER" "$KEY_DELAY_MS" "
"
"$TYPER" "$KEY_DELAY_MS" "$TEXT_P3
"

echo "Xong. So sánh kết quả trong $APP."
