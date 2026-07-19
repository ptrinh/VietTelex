// Updater.swift
// Manual, opt-in update check. The ONLY code path in VietTelex that touches the
// network — and only when the user clicks "Kiểm tra cập nhật" in the About tab.
// It asks the GitHub Releases API for the latest tag, compares versions, and (if
// newer) offers to open the download page. No auto-download, no telemetry, no
// background polling — keeping the app's "no network unless you ask" stance.

import Foundation

enum UpdateCheck {
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

    /// Network happens ONLY here. Called from the About tab's button.
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
