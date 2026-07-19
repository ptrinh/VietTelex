#!/usr/bin/env swift
// keystroke-photon.swift — end-to-end keystroke→pixel latency, typometer-style.
//
// Posts a real key event ('a'), then polls a tiny screen rect until a pixel
// changes; the delta is the FULL pipeline latency (OS → IME → app → render →
// compositor) as the user experiences it — the number that matters, unlike
// engine microbenchmarks. Compare runs with VietTelex active vs ABC to isolate
// the IME's real contribution per app/strategy.
//
// Usage:
//   1. Open the target app, click into a text field, note the screen position
//      where the NEXT character will appear (use ⌘⇧4 crosshair to read coords).
//   2. swift Scripts/keystroke-photon.swift <x> <y> [samples=20]
//   3. Focus the target field during the 3s countdown.
//
// Requires: Accessibility (post events) + Screen Recording (read pixels) for
// the terminal running this script. Each sample types 'a' then Backspace.
// Capture uses ScreenCaptureKit one-shot screenshots of an 8×8 rect; the
// script reports its own sampling overhead so you can judge resolution.

import Cocoa
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 3, let px = Double(args[1]), let py = Double(args[2]) else {
    print("usage: swift keystroke-photon.swift <x> <y> [samples=20]")
    exit(1)
}
let samples = args.count > 3 ? Int(args[3]) ?? 20 : 20
let rect = CGRect(x: px - 2, y: py - 2, width: 8, height: 8)

func post(_ key: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
}

func run() async {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
          let display = content.displays.first else {
        print("Không đọc được màn hình — cấp quyền Screen Recording cho terminal này rồi chạy lại.")
        exit(1)
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.sourceRect = rect
    config.width = 8
    config.height = 8
    config.showsCursor = false

    func grab() async -> [UInt8]? {
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                    configuration: config),
              let data = img.dataProvider?.data else { return nil }
        return [UInt8]((data as Data).prefix(256))
    }

    // Measure the tool's own sampling cost (capture granularity).
    guard await grab() != nil else {
        print("Capture thất bại — kiểm tra quyền Screen Recording.")
        exit(1)
    }
    let probeT0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<10 { _ = await grab() }
    let grabMs = Double(DispatchTime.now().uptimeNanoseconds - probeT0) / 10 / 1_000_000
    print(String(format: "Độ phân giải lấy mẫu: ~%.1f ms/capture (sai số đo ≈ ±1 capture + 1 frame màn hình)", grabMs))

    print("Focus vào ô text của app cần đo... 3s")
    try? await Task.sleep(nanoseconds: 3_000_000_000)

    let kA: CGKeyCode = 0, kDelete: CGKeyCode = 51
    var results: [Double] = []

    for i in 1...samples {
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard let base = await grab() else { continue }
        let t0 = DispatchTime.now().uptimeNanoseconds
        post(kA)
        var latency: Double? = nil
        while DispatchTime.now().uptimeNanoseconds - t0 < 1_000_000_000 {   // 1s timeout
            if let now = await grab(), now != base {
                latency = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                break
            }
        }
        post(kDelete)
        if let ms = latency {
            results.append(ms)
            print(String(format: "  #%02d  %.1f ms", i, ms))
        } else {
            print("  #\(i)  timeout (pixel không đổi — kiểm tra tọa độ)")
        }
    }

    guard !results.isEmpty else { exit(1) }
    let sorted = results.sorted()
    let avg = results.reduce(0, +) / Double(results.count)
    print(String(format: "\nn=%d  min=%.1f  median=%.1f  avg=%.1f  max=%.1f (ms)",
                 results.count, sorted.first!, sorted[sorted.count / 2], avg, sorted.last!))
}

let sem = DispatchSemaphore(value: 0)
Task { await run(); sem.signal() }
sem.wait()
