#!/usr/bin/env swift
// pty-poster.swift — posts a fixed key script and logs the post timestamp of
// each key: "<CLOCK_UPTIME_RAW ns> <label>". Pair with pty-reader.py running
// in the target terminal; subtracting the logs gives OS→tap→synthetic→app
// text-arrival latency per key (everything but rendering — the part the IME
// actually influences), with both sides on mach_absolute_time.
//
// Per sample it types "a", then "s" (with VietTelex active the s becomes a
// tone: the terminal receives DEL + "á" — a synthetic burst), then Space
// (boundary). So each sample yields:
//   a      → pass-through path latency
//   s      → tone-edit burst latency (measure to the LAST byte that follows)
//   space  → boundary path latency
//
// Usage: swift pty-poster.swift /tmp/pty-posts.log [samples=30]
import Cocoa

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: pty-poster.swift <log> [samples]"); exit(1) }
let log = FileHandle(forWritingAtPath: args[1]) ?? {
    FileManager.default.createFile(atPath: args[1], contents: nil)
    return FileHandle(forWritingAtPath: args[1])!
}()
let samples = args.count > 2 ? Int(args[2]) ?? 30 : 30

// US-layout keycodes: a=0, s=1, space=49.
func post(_ key: CGKeyCode, _ label: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    let t = DispatchTime.now().uptimeNanoseconds   // mach clock, = CLOCK_UPTIME_RAW
    CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    log.write("\(t) \(label)\n".data(using: .utf8)!)
}

print("3s — focus the terminal running pty-reader.py…")
Thread.sleep(forTimeInterval: 3)
for i in 1...samples {
    post(0, "a-\(i)");  Thread.sleep(forTimeInterval: 0.25)
    post(1, "s-\(i)");  Thread.sleep(forTimeInterval: 0.25)
    post(49, "sp-\(i)"); Thread.sleep(forTimeInterval: 0.25)
}
print("done: \(samples) samples posted")
