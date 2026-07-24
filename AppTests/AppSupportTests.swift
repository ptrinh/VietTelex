import XCTest
@testable import VietTelex

// Support-layer coverage: DebugLog ring semantics, Updater version logic +
// stubbed network paths, the Accessibility trust cache, and the safe (non-posting)
// SyntheticKeyboard state helpers. Detector getters are smoke-read only — their
// values depend on live system state (windows, AX), so asserting them would flake.
final class AppSupportTests: XCTestCase {

    override func tearDown() {
        Accessibility.testTrustOverride = nil
        AppState.shared.debugLogging = false
        super.tearDown()
    }

    // MARK: DebugLog

    func testDebugLogRing() {
        let wasOn = AppState.shared.debugLogging
        defer { AppState.shared.debugLogging = wasOn }
        AppState.shared.debugLogging = false
        DebugLog.clear()
        DebugLog.log("must NOT be recorded")
        XCTAssertFalse(DebugLog.snapshot(header: []).contains("must NOT be recorded"))
        AppState.shared.debugLogging = true
        DebugLog.log("recorded line")
        let snap = DebugLog.snapshot(header: ["HEADER"])
        XCTAssertTrue(snap.contains("HEADER"))
        XCTAssertTrue(snap.contains("recorded line"))
        // Ring caps at 400: the oldest line is evicted, never a crash.
        for i in 0..<450 { DebugLog.log("filler \(i)") }
        let full = DebugLog.snapshot(header: [])
        XCTAssertFalse(full.contains("recorded line"))
        XCTAssertTrue(full.contains("filler 449"))
        DebugLog.clear()
        XCTAssertTrue(DebugLog.snapshot(header: []).contains("log empty"))
    }

    // MARK: Updater — pure logic

    func testVersionCompare() {
        XCTAssertTrue(UpdateCheck.isNewer("1.3.1", than: "1.3.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.9"))   // numeric, not lexical
        XCTAssertTrue(UpdateCheck.isNewer("1.3.0.1", than: "1.3.0"))  // length mismatch
        XCTAssertFalse(UpdateCheck.isNewer("1.3.0", than: "1.3.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2.9", than: "1.3.0"))
        XCTAssertFalse(UpdateCheck.isNewer("garbage", than: "1.0"))   // non-numeric → 0
        XCTAssertFalse(UpdateCheck.currentVersion().isEmpty)
    }

    // MARK: Updater — network paths via a URLProtocol stub

    func testCheckPathsAgainstStubbedNetwork() async {
        URLProtocol.registerClass(StubURLProtocol.self)
        defer { URLProtocol.unregisterClass(StubURLProtocol.self) }

        // Stable manifest newer than current → .update with the manifest URL.
        StubURLProtocol.responder = { url in
            if url.absoluteString.contains("stable.json") {
                return (200, #"{"version":"99.0.0","url":"https://example.com/rel"}"#)
            }
            return (200, #"{"tag_name":"v99.0.0","html_url":"https://example.com/gh"}"#)
        }
        if case let .update(latest, url) = await UpdateCheck.checkStable() {
            XCTAssertEqual(latest, "99.0.0")
            XCTAssertEqual(url.absoluteString, "https://example.com/rel")
        } else { XCTFail("expected .update from stable") }
        if case let .update(latest, _) = await UpdateCheck.check() {
            XCTAssertEqual(latest, "99.0.0")
        } else { XCTFail("expected .update from latest") }

        // Same version → upToDate.
        let cur = UpdateCheck.currentVersion()
        StubURLProtocol.responder = { url in
            url.absoluteString.contains("stable.json")
                ? (200, #"{"version":"\#(cur)"}"#)
                : (200, #"{"tag_name":"v\#(cur)"}"#)
        }
        if case .upToDate = await UpdateCheck.checkStable() {} else { XCTFail("stable upToDate") }
        if case .upToDate = await UpdateCheck.check() {} else { XCTFail("latest upToDate") }

        // HTTP error and junk payload → .failed, never a crash.
        StubURLProtocol.responder = { _ in (500, "boom") }
        if case .failed = await UpdateCheck.checkStable() {} else { XCTFail("stable failed") }
        if case .failed = await UpdateCheck.check() {} else { XCTFail("latest failed") }
        StubURLProtocol.responder = { _ in (200, "not json at all") }
        if case .failed = await UpdateCheck.checkStable() {} else { XCTFail("stable junk") }
        if case .failed = await UpdateCheck.check() {} else { XCTFail("latest junk") }
    }

    func testMaybeAutoCheckGuards() {
        let s = AppState.shared
        let savedOptIn = s.autoUpdateCheck
        let savedAt = s.lastAutoUpdateCheckAt
        defer { s.autoUpdateCheck = savedOptIn; s.lastAutoUpdateCheckAt = savedAt }
        // Opt-out: returns without touching the throttle timestamp.
        s.autoUpdateCheck = false
        s.lastAutoUpdateCheckAt = 0
        UpdateCheck.maybeAutoCheck()
        XCTAssertEqual(s.lastAutoUpdateCheckAt, 0)
        // Opted in but checked recently: throttle holds.
        s.autoUpdateCheck = true
        let now = Date().timeIntervalSince1970
        s.lastAutoUpdateCheckAt = now
        UpdateCheck.maybeAutoCheck()
        XCTAssertEqual(s.lastAutoUpdateCheckAt, now)
    }

    // MARK: Updater — bundle install (the "permission stuck after update" fix)

    // installBundle must swap in the new bundle WHOLESALE. The old `ditto newApp dest`
    // merged — it overwrote same-named files but left orphans from resources a new
    // version dropped/renamed, breaking the code seal so tccd refused the event tap.
    // These build throwaway directory trees (not real .app bundles) and assert the
    // on-disk result is byte-identical to the source, with no merge residue.
    private func writeTree(_ files: [String: String], at root: URL) throws {
        for (rel, body) in files {
            let f = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    private func readTree(at root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = root.standardizedFileURL.path
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return out }
        for case let url as URL in en {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            out[rel] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<binary>"
        }
        return out
    }

    func testInstallBundleFreshInstall() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-install-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("staging/VietTelex.app")
        let dest = tmp.appendingPathComponent("Input Methods/VietTelex.app")
        let payload = ["Contents/MacOS/VietTelex": "v2-binary",
                       "Contents/Info.plist": "v2-plist"]
        try writeTree(payload, at: src)

        try SelfUpdater.installBundle(from: src, to: dest)   // no existing dest → move

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(readTree(at: dest), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "source should be consumed")
    }

    func testInstallBundleReplacesWholesaleAndDropsOrphans() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-install-replace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("staging/VietTelex.app")
        let dest = tmp.appendingPathComponent("Input Methods/VietTelex.app")

        // Old installed bundle: has a resource the new version renames away.
        try writeTree(["Contents/MacOS/VietTelex": "v1-binary",
                       "Contents/Info.plist": "v1-plist",
                       "Contents/Resources/old-lexicon.dat": "STALE",       // orphan-to-be
                       "Contents/CodeResources": "v1-seal"], at: dest)
        // New bundle: binary changed, lexicon renamed, no old-lexicon.dat.
        let payload = ["Contents/MacOS/VietTelex": "v2-binary",
                       "Contents/Info.plist": "v2-plist",
                       "Contents/Resources/lexicon-v2.dat": "FRESH",
                       "Contents/CodeResources": "v2-seal"]
        try writeTree(payload, at: src)

        try SelfUpdater.installBundle(from: src, to: dest)

        // Wholesale: dest is byte-identical to the new artifact — the orphan is GONE
        // (a merge would have kept old-lexicon.dat and broken the seal).
        XCTAssertEqual(readTree(at: dest), payload)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("Contents/Resources/old-lexicon.dat").path),
            "orphaned file from the old version must be removed (no merge)")
        // No leftover backup dir beside the installed bundle.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.deletingLastPathComponent().appendingPathComponent("VietTelex.app.bak").path),
            "backup must not linger after a successful replace")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "source should be consumed")
    }

    // MARK: Accessibility trust cache

    func testTrustOverrideAndCache() {
        Accessibility.testTrustOverride = true
        XCTAssertTrue(Accessibility.isTrusted)
        Accessibility.testTrustOverride = false
        XCTAssertFalse(Accessibility.isTrusted)
        Accessibility.testTrustOverride = nil
        Accessibility.invalidateCache()
        let real = Accessibility.isTrusted     // whatever TCC says on this machine…
        XCTAssertEqual(Accessibility.isTrusted, real)   // …the cache answers the same
    }

    // MARK: SyntheticKeyboard state helpers (safe: nothing is posted)

    func testSyntheticKeyboardStateHelpers() {
        SyntheticKeyboard.resetBreaker()
        XCTAssertFalse(SyntheticKeyboard.tripped)
        XCTAssertTrue(SyntheticKeyboard.queueDrained())
        SyntheticKeyboard.noteObservedSynthetic()   // underflow-safe at zero
        XCTAssertTrue(SyntheticKeyboard.queueDrained())
    }

    // MARK: Detector getters — smoke reads (values are live system state)

    func testDetectorSmokeReads() {
        _ = SpotlightDetector.isVisible
        _ = FocusedFieldDetector.wantsSelection
        _ = FocusedFieldDetector.isTextInput
    }
}

/// Minimal URLProtocol stub: answers every request from `responder` without
/// touching the network. Registered per-test; URLSession.shared consults
/// registered protocol classes for its default configuration.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URL) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let (code, body) = Self.responder?(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// Settings accessors round-trip: every UserDefaults-backed property reads back
// what it stores, and the explicit value is restored afterwards.
extension AppSupportTests {
    func testSettingsAccessorRoundTrips() {
        let s = AppState.shared
        // Bool accessors (save → flip → assert → restore).
        let bools: [(get: () -> Bool, set: (Bool) -> Void)] = [
            ({ s.autoRestore }, { s.autoRestore = $0 }),
            ({ s.freeMarking }, { s.freeMarking = $0 }),
            ({ s.modernOrthography }, { s.modernOrthography = $0 }),
            ({ s.liveSpellCheck }, { s.liveSpellCheck = $0 }),
            ({ s.simpleTelex }, { s.simpleTelex = $0 }),
            ({ s.quickTelex }, { s.quickTelex = $0 }),
            ({ s.vniMode }, { s.vniMode = $0 }),
            ({ s.tapModifyEventInPlace }, { s.tapModifyEventInPlace = $0 }),
            ({ s.tapSkipSyntheticKeyUp }, { s.tapSkipSyntheticKeyUp = $0 }),
            ({ s.axSelectionReplace }, { s.axSelectionReplace = $0 }),
            ({ s.tapCascadeBreaker }, { s.tapCascadeBreaker = $0 }),
            ({ s.debugLogging }, { s.debugLogging = $0 }),
            ({ s.advancedFeatures }, { s.advancedFeatures = $0 }),
            ({ s.autoUpdateCheck }, { s.autoUpdateCheck = $0 }),
            ({ s.axPromptShown }, { s.axPromptShown = $0 }),
        ]
        for accessor in bools {
            let saved = accessor.get()
            accessor.set(!saved)
            XCTAssertEqual(accessor.get(), !saved)
            accessor.set(saved)
            XCTAssertEqual(accessor.get(), saved)
        }
        // String/scalar accessors.
        let lang = s.uiLanguage
        s.uiLanguage = "vi"; XCTAssertEqual(s.uiLanguage, "vi")
        s.uiLanguage = lang
        let v = s.lastNotifiedUpdateVersion
        s.lastNotifiedUpdateVersion = "9.9.9"
        XCTAssertEqual(s.lastNotifiedUpdateVersion, "9.9.9")
        s.lastNotifiedUpdateVersion = v
        XCTAssertFalse(VTLocalized("Close").isEmpty)   // localization lookup path
        _ = s.tapNativeFastPath
    }
}
