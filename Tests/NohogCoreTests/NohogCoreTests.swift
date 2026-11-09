import Foundation
import Testing
@testable import NohogCore

/// A throwaway directory tree; paths are relative to `root`. Entries ending in "/" are directories.
final class Fixture {
    let root: String

    init(_ entries: [String]) throws {
        let base = canonicalPath(NSTemporaryDirectory()) + "/nohog-test-\(UUID().uuidString)"
        root = base
        for entry in entries {
            let path = base + "/" + entry
            if entry.hasSuffix("/") {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: Data())
            }
        }
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    deinit { try? FileManager.default.removeItem(atPath: root) }
}

func scanner(skip: [String] = [], depth: Int = 8) -> JunkScanner {
    JunkScanner(rules: Rule.defaults, skipPaths: skip, maxDepth: depth)
}

@Suite struct RuleTests {
    @Test func exactSentinel() {
        let rule = Rule("node_modules", ["package.json"])
        #expect(rule.matches(siblings: ["package.json", "src"]))
        #expect(!rule.matches(siblings: ["src"]))
    }

    @Test func prefixSentinel() {
        let rule = Rule("build", ["build.gradle*"])
        #expect(rule.matches(siblings: ["build.gradle.kts"]))
        #expect(!rule.matches(siblings: ["gradle.properties"]))
    }

    @Test func suffixSentinel() {
        let rule = Rule("obj", ["*.csproj"])
        #expect(rule.matches(siblings: ["App.csproj", "Program.cs"]))
        #expect(!rule.matches(siblings: ["csproj.md"]))
    }

    @Test func emptySentinelsAlwaysMatch() {
        #expect(Rule("junk", []).matches(siblings: []))
    }
}

@Suite struct ScannerTests {
    @Test func findsJunkOnlyWithSentinels() throws {
        let fx = try Fixture([
            "js/package.json", "js/node_modules/a/node_modules/", "js/src/",
            "rs/Cargo.toml", "rs/target/debug/",
            "notrust/target/",
            "gradle/build.gradle.kts", "gradle/build/",
            "cmake/CMakeLists.txt", "cmake/build/",
            "plain/build/",
            "py/requirements.txt", "py/venv/",
            "ios/Podfile", "ios/Pods/",
            "net/App.csproj", "net/bin/", "net/obj/",
            "shellscripts/bin/",
            "game/ProjectSettings/", "game/Library/",
            "flutter/pubspec.yaml", "flutter/build/",
            "gomod/go.mod", "gomod/vendor/",
        ])
        let result = scanner().scan(roots: [fx.root])
        #expect(result.found == [
            fx.path("cmake/build"), fx.path("flutter/build"), fx.path("game/Library"), fx.path("gomod/vendor"),
            fx.path("gradle/build"), fx.path("ios/Pods"), fx.path("js/node_modules"),
            fx.path("net/bin"), fx.path("net/obj"), fx.path("py/venv"), fx.path("rs/target"),
        ]) // shellscripts/bin has no project file next to it, so it stays searchable
        #expect(result.scannedRoots == [fx.root])
    }

    @Test func skipsDotFoldersNoindexAndSymlinks() throws {
        let fx = try Fixture([
            ".hidden/app/package.json", ".hidden/app/node_modules/",
            "x.noindex/package.json", "x.noindex/node_modules/",
            "real/package.json", "real/node_modules/",
        ])
        try FileManager.default.createSymbolicLink(atPath: fx.path("link"), withDestinationPath: fx.path("real"))
        #expect(scanner().scan(roots: [fx.root]).found == [fx.path("real/node_modules")])
    }

    @Test func honorsSkipPathsAndDepth() throws {
        let fx = try Fixture(["a/package.json", "a/node_modules/", "b/c/d/package.json", "b/c/d/node_modules/"])
        #expect(scanner(skip: [fx.path("a")]).scan(roots: [fx.root]).found == [fx.path("b/c/d/node_modules")])
        // the root is listed at depth 0, so finding b/c/d/node_modules means listing b/c/d at depth 3 (needs maxDepth 4)
        #expect(scanner(depth: 3).scan(roots: [fx.root]).found == [fx.path("a/node_modules")])
        #expect(scanner(depth: 4).scan(roots: [fx.root]).found.count == 2)
    }

    @Test func reportsUnreadableDirectories() throws {
        let fx = try Fixture(["ok/package.json", "ok/node_modules/", "locked/app/", "lockedroot/"])
        chmod(fx.path("locked"), 0)
        chmod(fx.path("lockedroot"), 0)
        defer { chmod(fx.path("locked"), 0o755); chmod(fx.path("lockedroot"), 0o755) }
        let result = scanner().scan(roots: [fx.root, fx.path("lockedroot")])
        #expect(result.found == [fx.path("ok/node_modules")])
        #expect(result.unreadable == [fx.path("locked"), fx.path("lockedroot")])
        #expect(result.scannedRoots == [fx.root])
    }

    @Test func missingRootsAreNotScanned() throws {
        let fx = try Fixture(["p/package.json", "p/node_modules/"])
        let result = scanner().scan(roots: [fx.root, fx.path("nope")])
        #expect(result.scannedRoots == [fx.root])
        #expect(result.found == [fx.path("p/node_modules")])
    }

    @Test func expandsGlobRoots() throws {
        let fx = try Fixture(["vols/A/Developer/", "vols/B/Developer/", "vols/C/other/"])
        #expect(expandGlob(fx.path("vols/*/Developer")) == [fx.path("vols/A/Developer"), fx.path("vols/B/Developer")])
    }
}

@Suite struct PlannerTests {
    let mounted: (String) -> Bool = { _ in true }

    @Test func volumeRoot() {
        #expect(Planner.volumeRoot(of: "/Volumes/T7 Shield/Developer/x") == "/Volumes/T7 Shield")
        #expect(Planner.volumeRoot(of: "/Users/me/x") == nil)
        #expect(Planner.volumeRoot(of: "/Volumes") == nil)
    }

    @Test func addsMissingAndNeverTouchesUserEntries() {
        let plan = Planner.plan(
            desired: ["/r/a/node_modules", "/r/b/node_modules"],
            current: ["/r/a/node_modules", "/r/mine"],
            managed: [], scannedRoots: ["/r"], unreadable: [])
        #expect(plan == Plan(add: ["/r/b/node_modules"], remove: []))
    }

    @Test func reAddsManagedEntriesDroppedByMacOS() {
        let plan = Planner.plan(
            desired: ["/r/a/node_modules"], current: [], managed: ["/r/a/node_modules"],
            scannedRoots: ["/r"], unreadable: [])
        #expect(plan.add == ["/r/a/node_modules"])
    }

    @Test func prunesManagedEntriesNoLongerFoundInsideScannedRoot() {
        // deleted project, or a folder that stopped matching (sentinel gone, skipPaths added)
        let plan = Planner.plan(
            desired: [], current: ["/r/gone/node_modules", "/r/mine"], managed: ["/r/gone/node_modules"],
            scannedRoots: ["/r"], unreadable: [])
        #expect(plan == Plan(add: [], remove: ["/r/gone/node_modules"]))
    }

    @Test func neverPrunesOutsideScannedRoots() {
        // unmounted drive, root missing from config: we did not look, so we do not touch
        let plan = Planner.plan(
            desired: [], current: ["/Volumes/T7/Developer/a/node_modules"], managed: ["/Volumes/T7/Developer/a/node_modules"],
            scannedRoots: ["/r"], unreadable: [])
        #expect(plan.isEmpty)
    }

    @Test func neverPrunesInsideUnreadableDirectories() {
        // e.g. macOS denied access to a removable volume: listings fail, folders look "gone"
        let plan = Planner.plan(
            desired: [], current: ["/r/locked/app/node_modules"], managed: ["/r/locked/app/node_modules"],
            scannedRoots: ["/r"], unreadable: ["/r/locked"])
        #expect(plan.isEmpty)
    }

    @Test func nextManagedKeepsEntriesOnUnmountedVolumes() {
        let path = "/Volumes/T7/Developer/a/node_modules"
        #expect(Planner.nextManaged(managed: [path], added: [], after: [], isMounted: { _ in false }) == [path])
    }

    @Test func nextManagedIsDerivedFromWhatSpotlightReports() {
        // /r/old was removed, /r/vanished disappeared, /r/failed was requested but not applied
        let next = Planner.nextManaged(
            managed: ["/r/old", "/r/kept", "/r/vanished"], added: ["/r/new", "/r/failed"],
            after: ["/r/kept", "/r/new", "/mine"], isMounted: mounted)
        #expect(next == ["/r/kept", "/r/new"])
    }
}

@Suite struct ConfigAndStateTests {
    @Test func missingConfigGivesDefaults() throws {
        let config = try Config.load(from: URL(fileURLWithPath: "/nonexistent/config.json"), home: "/Users/me")
        #expect(config == Config.defaults(home: "/Users/me"))
        #expect(config.roots.contains("/Users/me/Developer"))
    }

    @Test func partialConfigOverridesAndAppendsRules() throws {
        let fx = try Fixture(["config.json"])
        let json = #"{"roots": ["~/work"], "extraRules": [{"name": "dist", "sentinels": ["package.json"]}], "maxDepth": 3}"#
        try Data(json.utf8).write(to: URL(fileURLWithPath: fx.path("config.json")))
        let config = try Config.load(from: URL(fileURLWithPath: fx.path("config.json")), home: "/Users/me")
        #expect(config.roots == ["/Users/me/work"])
        #expect(config.maxDepth == 3)
        #expect(config.rules == Rule.defaults + [Rule("dist", ["package.json"])])
        #expect(config.extraPaths == Config.defaults(home: "/Users/me").extraPaths)
    }

    @Test func stateRoundTripsAndCorruptStateThrows() throws {
        let fx = try Fixture(["bad.json"])
        let url = URL(fileURLWithPath: fx.path("sub/state.json"))
        let state = State(managed: ["/a", "/b"], lastOSBuild: "26B123")
        try state.save(to: url)
        #expect(try State.load(from: url) == state)
        #expect(try State.load(from: URL(fileURLWithPath: fx.path("missing.json"))) == State())
        try Data("{nope".utf8).write(to: URL(fileURLWithPath: fx.path("bad.json")))
        #expect(throws: (any Error).self) { try State.load(from: URL(fileURLWithPath: fx.path("bad.json"))) }
    }

    @Test func desiredIncludesExistingExtraPathsMinusSkipped() throws {
        let fx = try Fixture(["root/p/package.json", "root/p/node_modules/", "dd/", "skipme/"])
        var config = Config.defaults(home: "/nonexistent")
        config.roots = [fx.path("root")]
        config.extraPaths = [fx.path("dd"), fx.path("missing"), fx.path("skipme")]
        config.skipPaths = [fx.path("skipme")]
        #expect(desiredExclusions(config: config).desired == [fx.path("dd"), fx.path("root/p/node_modules")])
    }
}

/// In-memory Privacy list. `ignore` simulates Spotlight never applying a path;
/// `dropOnce` simulates it dropping the first request for a path.
final class FakeStore: ExclusionStore {
    var entries: [String]
    var ignore: Set<String> = []
    var ignoreAll = false
    var dropOnce: Set<String> = []
    var calls = 0

    init(_ entries: [String] = []) { self.entries = entries }

    func list() throws -> [String] { entries }

    func setExcluded(_ path: String, _ excluded: Bool) throws {
        calls += 1
        if ignoreAll || ignore.contains(path) { return }
        if dropOnce.remove(path) != nil { return }
        entries.removeAll { $0 == path }
        if excluded { entries.append(path) }
    }
}

@Suite struct ReconcileTests {
    func config(_ fx: Fixture) -> Config {
        var config = Config.defaults(home: "/nonexistent")
        config.roots = [fx.root]
        config.extraPaths = []
        return config
    }

    @Test func appliesThenIsIdempotent() throws {
        let fx = try Fixture(["p/package.json", "p/node_modules/"])
        let store = FakeStore(["/mine"])
        let (first, state) = try reconcile(config: config(fx), state: State(), store: store, dryRun: false)
        #expect(first.plan.add == [fx.path("p/node_modules")])
        #expect(first.succeeded)
        #expect(state.managed == [fx.path("p/node_modules")])
        #expect(Set(store.entries) == ["/mine", fx.path("p/node_modules")])

        let (second, sameState) = try reconcile(config: config(fx), state: state, store: store, dryRun: false)
        #expect(second.plan.isEmpty)
        #expect(sameState == state)
    }

    @Test func dryRunChangesNothing() throws {
        let fx = try Fixture(["p/package.json", "p/node_modules/"])
        let store = FakeStore()
        let (outcome, state) = try reconcile(config: config(fx), state: State(), store: store, dryRun: true)
        #expect(outcome.plan.add == [fx.path("p/node_modules")])
        #expect(store.entries.isEmpty)
        #expect(state == State())
    }

    @Test func prunesDeletedProjectButKeepsUserEntries() throws {
        let fx = try Fixture(["p/package.json", "p/node_modules/"])
        let store = FakeStore()
        let (_, state) = try reconcile(config: config(fx), state: State(), store: store, dryRun: false)
        try FileManager.default.removeItem(atPath: fx.path("p"))
        store.entries.append("/mine")
        let (outcome, next) = try reconcile(config: config(fx), state: state, store: store, dryRun: false)
        #expect(outcome.plan.remove == [fx.path("p/node_modules")])
        #expect(store.entries == ["/mine"])
        #expect(next.managed.isEmpty)
    }

    @Test func reportsChangesSpotlightIgnored() throws {
        let fx = try Fixture(["p/package.json", "p/node_modules/"])
        let store = FakeStore()
        store.ignore = [fx.path("p/node_modules")]
        var waits: [TimeInterval] = []
        let (outcome, state) = try reconcile(config: config(fx), state: State(), store: store, dryRun: false, wait: { waits.append($0) })
        #expect(waits == [0, 1, 2, 4, 8]) // retried with backoff before giving up
        #expect(outcome.failedAdds == [fx.path("p/node_modules")])
        #expect(!outcome.succeeded)
        #expect(state.managed.isEmpty) // never claim what Spotlight did not record
    }
}

extension ReconcileTests {
    @Test func retriesRequestsSpotlightDropped() throws {
        let fx = try Fixture(["a/package.json", "a/node_modules/", "b/package.json", "b/node_modules/"])
        let store = FakeStore()
        store.dropOnce = [fx.path("b/node_modules")]
        var waits: [TimeInterval] = []
        let (outcome, state) = try reconcile(config: config(fx), state: State(), store: store, dryRun: false, wait: { waits.append($0) })
        #expect(outcome.succeeded)
        #expect(waits == [0, 1])
        #expect(store.calls == 3) // a, b, then b again; never re-sends what already landed
        #expect(state.managed == [fx.path("a/node_modules"), fx.path("b/node_modules")])
    }
}

@Suite struct ApplyTests {
    @Test func reissuesDroppedRemovalsOnly() throws {
        let store = FakeStore(["/a", "/b", "/c", "/mine"])
        store.dropOnce = ["/b", "/c"]
        var waits: [TimeInterval] = []
        let after = try applyExclusions(add: [], remove: ["/a", "/b", "/c", "/gone"], current: store.entries, store: store, wait: { waits.append($0) })
        #expect(after == ["/mine"])
        #expect(waits == [0, 1])
        #expect(store.calls == 5) // a, b, c, then b and c again; "/gone" was never present
    }

    @Test func nothingPendingMeansNoCalls() throws {
        let store = FakeStore(["/a"])
        let after = try applyExclusions(add: ["/a"], remove: ["/x"], current: store.entries, store: store, wait: { _ in Issue.record("should not wait") })
        #expect(after == ["/a"])
        #expect(store.calls == 0)
    }
}

@Suite struct WatchTests {
    let rules: Set<String> = ["node_modules", "target"]

    @Test func junkEventsInsideRootsOnly() {
        let roots = ["/dev"]
        #expect(isJunkEvent("/dev/app/node_modules/pkg/", ruleNames: rules, roots: roots, excluded: []))
        #expect(!isJunkEvent("/dev/app/src/", ruleNames: rules, roots: roots, excluded: []))
        #expect(!isJunkEvent("/other/app/node_modules/", ruleNames: rules, roots: roots, excluded: []))
        #expect(!isJunkEvent("/dev/app/node_modules/pkg/", ruleNames: rules, roots: roots, excluded: ["/dev/app/node_modules"]))
    }

    @Test func rescanOnlyTheProjectsThatChanged() {
        let roots = ["/dev", "/dev/nested-root"]
        let paths = [
            "/dev/app/node_modules/pkg/",               // → /dev/app, 1 below the root
            "/dev/app/packages/ui/node_modules/x/",     // nested in /dev/app, collapsed
            "/dev/rust/target/debug/",                  // → /dev/rust
            "/dev/nested-root/svc/node_modules/",       // longest matching root wins → /dev/nested-root/svc
            "/dev/node_modules/",                       // junk right under the root → the root
            "/elsewhere/node_modules/",                 // outside every root, ignored
        ]
        #expect(rescanRoots(for: paths, ruleNames: rules, roots: roots, maxDepth: 8) == ["/dev": 8])
        #expect(rescanRoots(for: Array(paths.dropLast(2)), ruleNames: rules, roots: roots, maxDepth: 8)
            == ["/dev/app": 7, "/dev/nested-root/svc": 7, "/dev/rust": 7])
    }

    @Test func rescanSkipsWhatAFullWalkNeverReaches() {
        let paths = [
            "/dev/a/b/node_modules/x/",                 // 2 below the root: 1 level left
            "/dev/a/b/c/node_modules/x/",               // 3 below: beyond maxDepth
            "/dev/a/.cache/node_modules/x/",            // under a dot folder
            "/dev/a/out.noindex/node_modules/x/",       // under a .noindex folder
        ]
        #expect(rescanRoots(for: paths, ruleNames: rules, roots: ["/dev"], maxDepth: 3) == ["/dev/a/b": 1])
    }

    @Test func scopedScanFindsExactlyWhatAFullScanFinds() throws {
        // A scoped pass that found more than a full pass would be pruned by the next full pass, and
        // re-added by the next event: an endless exclude/include flip-flop.
        let fx = try Fixture(["a/package.json", "a/node_modules/", "a/b/c/package.json", "a/b/c/node_modules/"])
        let scanner = JunkScanner(rules: Rule.defaults, skipPaths: [], maxDepth: 3)
        let full = scanner.scan(roots: [fx.root]).found
        let events = [fx.path("a/node_modules/x"), fx.path("a/b/c/node_modules/x")]
        var scoped: [String] = []
        for (dir, depth) in rescanRoots(for: events, ruleNames: rules, roots: [fx.root], maxDepth: 3) {
            scoped += JunkScanner(rules: Rule.defaults, skipPaths: [], maxDepth: depth).scan(roots: [dir]).found
        }
        #expect(full == [fx.path("a/node_modules")]) // a/b/c/node_modules is 4 deep, past maxDepth
        #expect(scoped.sorted() == full)
    }

    @Test func rescanRootsSupportPruningOnlyWhatWasRescanned() throws {
        let fx = try Fixture(["a/package.json", "a/node_modules/", "b/package.json"])
        var config = Config.defaults(home: "/nonexistent")
        config.extraPaths = []
        let targets = rescanRoots(for: [fx.path("a/node_modules/x")], ruleNames: rules, roots: [fx.root], maxDepth: 8)
        config.roots = Array(targets.keys)
        // b's node_modules is gone, but b was not rescanned, so its managed entry must survive.
        let store = FakeStore([fx.path("b/node_modules")])
        let (outcome, state) = try reconcile(config: config, state: State(managed: [fx.path("b/node_modules")]), store: store, dryRun: false)
        #expect(outcome.plan == Plan(add: [fx.path("a/node_modules")], remove: []))
        #expect(state.managed == [fx.path("a/node_modules"), fx.path("b/node_modules")])
    }

    @Test func watchRootsUseLiteralPrefixAndDropNested() throws {
        let fx = try Fixture(["vols/A/Developer/", "home/"])
        try FileManager.default.createSymbolicLink(atPath: fx.path("home/Developer"), withDestinationPath: fx.path("vols/A/Developer"))
        let roots = watchRoots(for: [fx.path("home/Developer"), fx.path("vols/*/Developer"), fx.path("missing")])
        #expect(roots == [fx.path("vols")])
    }

    @Test func expandRootsDedupesSymlinkedRoots() throws {
        let fx = try Fixture(["real/"])
        try FileManager.default.createSymbolicLink(atPath: fx.path("link"), withDestinationPath: fx.path("real"))
        #expect(expandRoots([fx.path("link"), fx.path("real"), fx.path("missing")]) == [fx.path("real")])
    }
}

@Suite struct TopTests {
    @Test func parsesFsUsageLinesWithSpacesInPaths() throws {
        let line: Substring = "22:57:01.123456  open              F=5        (R_____)  /Volumes/T7 Shield/Dev/a b.js                0.000012   mdworker_shared.4242"
        let parsed = try #require(parseFsUsageLine(line))
        #expect(parsed.path == "/Volumes/T7 Shield/Dev/a b.js")
        #expect(parsed.process == "mdworker_shared")
        let waited: Substring = "22:57:01  getattrlist                            /Users/me/x        0.000016 W mds_stores.88"
        #expect(parseFsUsageLine(waited)?.process == "mds_stores")
        #expect(parseFsUsageLine("22:57:01  close  F=5   0.000003   mds.12") == nil)
    }

    @Test func deviceColumnLines() throws {
        // seen in real output on macOS 27.2: paged I/O lines carry the device before the path
        let paged: Substring = "23:01:02.1  RdData[A]  D=0x0012abcd  B=0x1000  /dev/disk4s1  /Volumes/T7 Shield/Dev/a.db   0.000250 W mds_stores.123"
        #expect(parseFsUsageLine(paged)?.path == "/Volumes/T7 Shield/Dev/a.db")
        let deviceOnly: Substring = "23:01:02.1  RdMeta  D=0x0012abcd  B=0x1000  /dev/disk4s1   0.000250 W mds_stores.123"
        #expect(parseFsUsageLine(deviceOnly) == nil)
        let devNull: Substring = "23:01:02.1  open  F=3  (_W____)  /dev/null   0.000002   mdworker_shared.9"
        #expect(parseFsUsageLine(devNull)?.path == "/dev/null")
    }

    @Test func bucketsAtActionableLevel() {
        let rules: Set<String> = ["node_modules"]
        let roots = ["/dev"]
        #expect(bucket("/dev/org/app/node_modules/a/b.js", ruleNames: rules, roots: roots) == "/dev/org/app/node_modules")
        #expect(bucket("/dev/org/app/data/cache/x/y.bin", ruleNames: rules, roots: roots) == "/dev/org/app/data/cache")
        #expect(bucket("/dev/org/app/data/cache/x/y.bin", ruleNames: rules, roots: roots, depthBelowRoot: 2) == "/dev/org/app")
        #expect(bucket("/dev/org/app/README.md", ruleNames: rules, roots: roots) == "/dev/org/app/README.md")
        #expect(bucket("/Users/me/Library/Mail/V10/x", ruleNames: rules, roots: roots) == "/Users/me/Library/Mail")
    }

    @Test func ranksOnlySpotlightProcesses() {
        let log = """
        t  open  F=1  (R_____)  /dev/a/app/node_modules/x.js     0.000001   mdworker_shared.1
        t  open  F=1  (R_____)  /dev/a/app/node_modules/y.js     0.000001   mdworker_shared.2
        t  open  F=1  (R_____)  /dev/a/app/src/z.ts              0.000001   mds_stores.3
        t  open  F=1  (R_____)  /dev/a/app/node_modules/z.js     0.000001   node.4
        """
        let ranked = rankSpotlightActivity(log, ruleNames: ["node_modules"], roots: ["/dev"])
        #expect(ranked.map(\.bucket) == ["/dev/a/app/node_modules", "/dev/a/app/src/z.ts"])
        #expect(ranked.map(\.events) == [2, 1])
    }
}

@Suite struct SelftestTests {
    /// Pretends Spotlight indexes every probe file except those under the folder the store excludes
    /// (or every probe file, when `honorsExclusions` is false).
    func search(_ store: FakeStore, honorsExclusions: Bool = true) -> SpotlightSearch {
        { _, dir in
            let files = ["control", "excluded"].map { "\(dir)/\($0)/probe.txt" }
            return files.filter { file in !honorsExclusions || !store.entries.contains { isWithin(file, $0) } }
        }
    }

    @Test func passesAndCleansUp() throws {
        let fx = try Fixture(["work/"])
        let store = FakeStore(["/mine"])
        #expect(runSelftest(store: store, parent: fx.path("work"), search: search(store), wait: { _ in }) == .pass)
        #expect(store.entries == ["/mine"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.path("work")).isEmpty)
    }

    @Test func failsWhenExclusionIsIgnored() throws {
        let fx = try Fixture(["work/"])
        let store = FakeStore()
        #expect(runSelftest(store: store, parent: fx.path("work"), search: search(store, honorsExclusions: false), wait: { _ in })
            == .fail("a file inside an excluded folder was indexed"))
        #expect(store.entries.isEmpty)
    }

    @Test func failsWhenExclusionIsNotRecorded() throws {
        let fx = try Fixture(["work/"])
        let store = FakeStore()
        store.ignoreAll = true
        #expect(runSelftest(store: store, parent: fx.path("work"), search: search(store), wait: { _ in })
            == .fail("the exclusion was not recorded in Spotlight's list"))
    }

    @Test func inconclusiveWhenNothingGetsIndexed() throws {
        let fx = try Fixture(["work/"])
        var waits = 0
        let result = runSelftest(store: FakeStore(), parent: fx.path("work"), search: { _, _ in [] }, wait: { _ in waits += 1 }, attempts: 3)
        #expect(result == .inconclusive("Spotlight did not index the control file within 3s (indexing off or busy)"))
        #expect(waits == 4) // settle + 3 polls
    }

    @Test func recordsOnlyPassesPerBuild() throws {
        let fx = try Fixture(["x"])
        let url = URL(fileURLWithPath: fx.path("state.json"))
        var runs = 0
        #expect(selftestIfNeeded(stateURL: url, build: "A") { runs += 1; return .fail("x") } == .fail("x"))
        #expect(selftestIfNeeded(stateURL: url, build: "A") { runs += 1; return .inconclusive("y") } == .inconclusive("y"))
        #expect(selftestIfNeeded(stateURL: url, build: "A") { runs += 1; return .pass } == .pass)
        #expect(selftestIfNeeded(stateURL: url, build: "A") { runs += 1; return .pass } == nil) // already passed
        #expect(selftestIfNeeded(stateURL: url, build: "B") { runs += 1; return .pass } == .pass) // OS updated
        #expect(runs == 4)
        #expect(try State.load(from: url).lastOSBuild == "B")
    }
}

@Suite struct SelftestReportTests {
    let pass = SelftestReport(macOS: "27.2", build: "26B123", chip: "Apple Silicon", nohogVersion: "0.1.2", result: .pass)

    @Test func markdownRow() {
        #expect(pass.markdownRow == "| 27.2 | 26B123 | Apple Silicon | ✅ pass | 0.1.2 |")
        var failed = pass
        failed.result = .fail("a file inside an excluded folder was indexed")
        #expect(failed.markdownRow == "| 27.2 | 26B123 | Apple Silicon | ❌ fail | 0.1.2 |")
    }

    @Test func issueURLPrefillsTheForm() throws {
        var failed = pass
        failed.result = .fail("a file inside an excluded folder was indexed")
        let url = failed.issueURL(repository: "owner/nohog")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.absoluteString.hasPrefix("https://github.com/owner/nohog/issues/new?"))
        #expect(fields["template"] == "selftest.yml")
        #expect(fields["title"] == "Selftest: macOS 27.2 (26B123), Apple Silicon: fail")
        #expect(fields["macos"] == "27.2" && fields["build"] == "26B123" && fields["result"] == "fail")
        #expect(fields["details"] == "a file inside an excluded folder was indexed")
        #expect(!url.absoluteString.contains(" ")) // spaces are encoded
    }

    @Test func inconclusiveIsNotShareable() {
        var maybe = pass
        maybe.result = .inconclusive("busy")
        #expect(!maybe.isShareable)
        #expect(pass.isShareable)
    }
}

@Suite struct BenchTests {
    @Test func parsesPsTimes() {
        #expect(parseCPUTime("0:01.23") == 1.23)
        #expect(parseCPUTime("61:02.50") == 3662.5)
        #expect(parseCPUTime("1:02:03.45") == 3723.45)
        #expect(parseCPUTime("2-00:00:01.00") == 172_801)
        #expect(parseCPUTime("abc") == nil)
    }

    @Test func picksSpotlightProcessesFromPS() {
        let ps = """
          101   0:12.50 /System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds_stores
          102   0:00.40 /System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mdworker_shared
          103   9:59.00 /Applications/Safari.app/Contents/MacOS/Safari
          104   0:01.00 mds
        """
        #expect(spotlightCPU(fromPS: ps) == [101: 12.5, 102: 0.4, 104: 1.0])
    }

    @Test func meterCountsDeltasAndNewWorkers() {
        var meter = CPUMeter(start: [1: 10, 2: 5])
        meter.add([1: 12, 2: 5, 3: 0.5]) // worker 3 started during the window
        meter.add([1: 13, 3: 1.5])       // worker 2 exited
        #expect(meter.total == 3 + 0 + 1.5)
    }

    @Test func benchFilesCarryTheToken() {
        #expect(benchFileContents(index: 7, token: "tok123").contains("tok123"))
        #expect(benchFileContents(index: 7, token: "t") != benchFileContents(index: 8, token: "t"))
    }
}
