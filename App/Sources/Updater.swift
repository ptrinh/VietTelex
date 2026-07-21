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
                alert.informativeText = VTLocalized("You can download the update from the releases page. This check ran because weekly update checks are enabled in Settings.")
                alert.addButton(withTitle: VTLocalized("Download update…"))
                alert.addButton(withTitle: VTLocalized("Later"))
                // Same accessory-app dance as the Accessibility alert: activate and
                // float, or the panel opens behind the frontmost app.
                NSApp.activate(ignoringOtherApps: true)
                alert.window.level = .floating
                alert.window.orderFrontRegardless()
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(url)
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
