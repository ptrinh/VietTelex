// Updater.swift
// Manual, opt-in update check. The ONLY code path in VietTelex that touches the
// network — and only when the user clicks "Kiểm tra cập nhật" in the About tab.
// It asks the GitHub Releases API for the latest tag, compares versions, and (if
// newer) offers to open the download page. No auto-download, no telemetry, no
// background polling — keeping the app's "no network unless you ask" stance.

import Foundation
import AppKit

enum UpdateCheck {
    /// Weekly auto-check — runs ONLY when the user opted in (Settings toggle,
    /// default OFF, so the no-network stance still holds: the toggle is the ask).
    /// Event-driven (called from activateServer, throttled by timestamp — no
    /// timers), and each new version is announced at most once.
    ///
    /// It follows the STABLE channel, not the newest GitHub release: users are only
    /// nudged toward versions the maintainer explicitly promoted by bumping
    /// docs/stable.json on the website (deployed by GitHub Pages). The manual
    /// About-tab button still checks releases/latest — that's the "I want it now"
    /// path.
    static func maybeAutoCheck() {
        guard AppState.shared.autoUpdateCheck else { return }
        let now = Date().timeIntervalSince1970
        guard now - AppState.shared.lastAutoUpdateCheckAt > 7 * 24 * 3600 else { return }
        AppState.shared.lastAutoUpdateCheckAt = now
        Task {
            guard case let .update(latest, url) = await checkStable() else { return }
            await MainActor.run {
                guard AppState.shared.lastNotifiedUpdateVersion != latest else { return }
                AppState.shared.lastNotifiedUpdateVersion = latest
                let alert = NSAlert()
                alert.messageText = String(format: VTLocalized("VietTelex %@ is available"), latest)
                alert.informativeText = VTLocalized("Update now body")
                alert.addButton(withTitle: VTLocalized("Update now"))
                alert.addButton(withTitle: VTLocalized("Later"))
                alert.addButton(withTitle: VTLocalized("Open releases page"))
                // Same accessory-app dance as the Accessibility alert: activate and
                // float, or the panel opens behind the frontmost app.
                NSApp.activate(ignoringOtherApps: true)
                alert.window.level = .floating
                alert.window.orderFrontRegardless()
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    SelfUpdater.run(version: latest)
                case .alertThirdButtonReturn:
                    NSWorkspace.shared.open(url)
                default: break
                }
            }
        }
    }
    /// Canonical repo (matches the git remote). GitHub redirects other casings.
    static let repo = "ptrinh/VietTelex"

    enum Outcome {
        case upToDate(String)                       // current == latest
        case update(latest: String, url: URL)       // a newer release exists
        case failed(String)                         // network / parse error
    }

    static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The STABLE channel: a tiny manifest the maintainer bumps BY HAND
    /// (docs/stable.json → GitHub Pages). Newest release ≠ stable — a fresh
    /// release soaks first; promoting it to every opted-in user is the explicit
    /// one-line edit of this file.
    static func checkStable() async -> Outcome {
        let current = currentVersion()
        guard let api = URL(string: "https://ptrinh.github.io/viettelex/stable.json") else {
            return .failed("URL")
        }
        var req = URLRequest(url: api, timeoutInterval: 12)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { return .failed("HTTP \(code)") }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stable = obj["version"] as? String else { return .failed("dữ liệu lạ") }
            let pageURL = (obj["url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(repo)/releases/latest")!
            return isNewer(stable, than: current) ? .update(latest: stable, url: pageURL)
                                                  : .upToDate(current)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Network happens ONLY here (and checkStable above). Called from the About
    /// tab's button — the manual path checks the NEWEST release, stable or not.
    static func check() async -> Outcome {
        let current = currentVersion()
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed("URL")
        }
        var req = URLRequest(url: api, timeoutInterval: 12)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("VietTelex/\(current)", forHTTPHeaderField: "User-Agent")   // GitHub requires a UA
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { return .failed("HTTP \(code)") }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return .failed("dữ liệu lạ") }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let pageURL = (obj["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(repo)/releases/latest")!
            return isNewer(latest, than: current) ? .update(latest: latest, url: pageURL)
                                                  : .upToDate(current)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Numeric, dot-separated compare: "1.1.2" > "1.1.1" > "1.1".
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}


/// In-place self-update. The bundle lives in USER-writable
/// ~/Library/Input Methods, so no admin rights are needed:
/// download the release app.zip → verify the Developer ID signature →
/// ditto over the installed bundle → exit (macOS relaunches the IME on the
/// next keystroke; already-open apps may need an input-source flip, same as
/// any IME restart).
enum SelfUpdater {
    static func run(version: String) {
        let zipURL = URL(string:
            "https://github.com/ptrinh/viettelex/releases/download/v\(version)/VietTelex-\(version).app.zip")!
        Task.detached {
            do {
                let (tmp, response) = try await URLSession.shared.download(from: zipURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "SelfUpdater", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
                }
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("viettelex-update-\(version)", isDirectory: true)
                try? FileManager.default.removeItem(at: work)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

                try runTool("/usr/bin/ditto", ["-xk", tmp.path, work.path])
                let newApp = work.appendingPathComponent("VietTelex.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else {
                    throw NSError(domain: "SelfUpdater", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "app missing in zip"])
                }
                // Signature gate: Developer ID, OUR team — refuse anything else.
                try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
                let info = try toolOutput("/usr/bin/codesign", ["-dv", "--verbose=2", newApp.path])
                guard info.contains("TeamIdentifier=84T567KMYD") else {
                    throw NSError(domain: "SelfUpdater", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "unexpected signing team"])
                }

                let dest = ("~/Library/Input Methods/VietTelex.app" as NSString).expandingTildeInPath
                try installBundle(from: newApp, to: URL(fileURLWithPath: dest))
                // Refresh the LaunchServices registration so the Text Input system relaunches
                // from the new bundle (mirrors notarize-install.sh).
                try? runTool("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", dest])
                try? FileManager.default.removeItem(at: work)

                await MainActor.run {
                    let done = NSAlert()
                    done.messageText = String(format: VTLocalized("Updated to %@"), version)
                    done.informativeText = VTLocalized("Update done body")
                    done.addButton(withTitle: VTLocalized("Restart input method"))
                    NSApp.activate(ignoringOtherApps: true)
                    done.window.level = .floating
                    done.window.orderFrontRegardless()
                    _ = done.runModal()
                    exit(0)   // macOS relaunches the IME (new binary) on demand
                }
            } catch {
                await MainActor.run {
                    let fail = NSAlert()
                    fail.messageText = VTLocalized("Update failed")
                    fail.informativeText = String(format: VTLocalized("Update failed body"), error.localizedDescription)
                    fail.addButton(withTitle: VTLocalized("Open releases page"))
                    fail.addButton(withTitle: VTLocalized("Close"))
                    NSApp.activate(ignoringOtherApps: true)
                    fail.window.level = .floating
                    fail.window.orderFrontRegardless()
                    if fail.runModal() == .alertFirstButtonReturn,
                       let u = URL(string: "https://github.com/ptrinh/viettelex/releases/latest") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
        }
    }

    /// Install `newApp` over `dest`, ATOMICALLY and WHOLESALE — never `ditto newApp dest`
    /// into an existing bundle. `ditto` MERGES: it overwrites same-named files but leaves
    /// behind any resource a new version dropped or renamed. Those orphans break the code
    /// seal, so tccd refuses the event tap even though the Accessibility row still shows
    /// "allowed" (the "permission stuck after update" bug). `replaceItemAt` swaps in exactly
    /// the signed/notarized artifact — no merge residue — so the seal stays intact and the
    /// identity-based grant re-validates cleanly. On a fresh install (no `dest`) it's a move.
    static func installBundle(from newApp: URL, to dest: URL) throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: newApp,
                                                      backupItemName: "VietTelex.app.bak")
        } else {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: newApp, to: dest)
        }
    }

    @discardableResult
    private static func runTool(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "SelfUpdater", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(path) exit \(p.terminationStatus)"])
        }
        return p.terminationStatus
    }

    private static func toolOutput(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe    // codesign -dv writes to stderr
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
