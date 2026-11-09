import Foundation
import NohogCore

let version = "0.1.2"
let repository = "rohiitgit/nohog"

let usage = """
nohog \(version): keep Spotlight from indexing dev junk

usage: nohog <command>

  install                    start the background agent (runs at login; no sudo needed)
  uninstall                  stop the agent and remove every exclusion nohog added
  status [--count]           Spotlight exclusions, marked [nohog] or [yours] (with file counts)
  scan [--count] [root...]   list dev junk folders (default: configured roots)
  reconcile [--dry-run]      exclude junk folders now / show what would change
  purge [path...]            drop content indexed before a folder was excluded (default: whole list)
  selftest                   prove Spotlight honors exclusions on this macOS (~10-35s)
  bench [files]              measure Spotlight CPU with vs without an exclusion (~2-4 min)
  top [seconds] [--depth N]  which folders Spotlight is reading right now (needs sudo)
  watch                      run the agent in the foreground (what launchd runs)

config: ~/.config/nohog/config.json (optional)   log: ~/Library/Logs/nohog.log
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("nohog: \(message)\n".utf8))
    exit(1)
}

/// Regular files below `path` (folders and symlinks are not counted).
func fileCount(_ path: String) -> Int {
    let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey])
    var count = 0
    while let url = enumerator?.nextObject() as? URL {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
    }
    return count
}

func scan(_ args: [String], config: Config) {
    let withCount = args.contains("--count")
    let roots = args.filter { !$0.hasPrefix("--") }
    let started = Date()
    let result = roots.isEmpty
        ? desiredExclusions(config: config).scan
        : JunkScanner(config: config).scan(roots: roots)
    for path in result.found {
        print(withCount ? String(format: "%9d  %@", fileCount(path), path) : path)
    }
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "%d folders in %d roots (%.1fs)", result.found.count, result.scannedRoots.count, elapsed))
}

func status(_ args: [String], store: ExclusionStore, state: State) throws {
    let withCount = args.contains("--count")
    let managed = Set(state.managed)
    let current = try store.list()
    print("Spotlight exclusions (\(current.count)):")
    var keptOut = 0
    for path in current.sorted() {
        let owner = managed.contains(path) ? "[nohog]" : "[yours]"
        guard withCount else { print("  \(owner) \(path)"); continue }
        let count = fileCount(path)
        if managed.contains(path) { keptOut += count }
        print(String(format: "  %@ %9d  %@", owner, count, path))
    }
    if current.isEmpty { print("  (none)") }
    if withCount { print("nohog keeps \(keptOut) files out of Spotlight's index") }
    let loaded = Paths.agentLabels.first(where: isLoaded)
    print("agent: \(loaded.map { "running (\($0))" } ?? "not running (run `nohog install`)")")
}

func reconcileCommand(_ args: [String], config: Config, store: ExclusionStore) throws {
    let dryRun = args.contains("--dry-run")
    let state = try State.load(from: Paths.state)
    let (outcome, next) = try reconcile(config: config, state: state, store: store, dryRun: dryRun)
    if !dryRun && next != state { try next.save(to: Paths.state) }
    if outcome.plan.isEmpty { print("nothing to do (\(outcome.desiredCount) folders already excluded)") }
    for path in outcome.plan.add { print("+ \(path)") }
    for path in outcome.plan.remove { print("- \(path)") }
    let failed = outcome.failedAdds + outcome.failedRemoves
    if !failed.isEmpty { fail("Spotlight did not apply:\n  " + failed.joined(separator: "\n  ")) }
}

func purgeCommand(_ args: [String], store: ExclusionStore) throws {
    let listed = try store.list()
    let paths = args.isEmpty ? listed.sorted() : args.map(canonicalPath)
    let unlisted = paths.filter { !listed.contains($0) }
    if !unlisted.isEmpty { fail("not excluded, so nothing to purge:\n  " + unlisted.joined(separator: "\n  ")) }
    print("checking \(paths.count) exclusions for content indexed before they were added…")
    let results = try purgeStale(paths: paths, store: store, indexed: indexedCount, progress: { result in
        print(String(format: "%9d -> %-7d %@", result.before, result.after, result.path))
    })
    let stale = results.filter { $0.after > 0 }
    print("purged \(results.count - stale.count) of \(results.count) folders that still had indexed content")
    if !stale.isEmpty { fail("still indexed (Spotlight busy? run `nohog purge` again later):\n  " + stale.map(\.path).joined(separator: "\n  ")) }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
let rest = Array(args.dropFirst())

// Exclusions and the agent belong to the user; as root they would land in the wrong place.
if getuid() == 0 && !["top", "scan", "version", "--version", "help", "-h", "--help"].contains(command) {
    fail("run `nohog \(command)` without sudo (only `top` needs it)")
}

do {
    switch command {
    case "scan":
        scan(rest, config: try Config.load(from: Paths.config, home: Paths.home))
    case "status":
        try status(rest, store: try SpotlightExclusionStore(), state: try State.load(from: Paths.state))
    case "reconcile":
        try reconcileCommand(rest, config: try Config.load(from: Paths.config, home: Paths.home), store: try SpotlightExclusionStore())
    case "purge":
        try purgeCommand(rest, store: try SpotlightExclusionStore())
    case "selftest":
        print("checking (up to ~35s)…")
        let result = selftest(store: try SpotlightExclusionStore())
        print(result.summary)
        let report = SelftestReport(macOS: macOSVersion(), build: osBuild(), chip: chipName(), nohogVersion: version, result: result)
        if report.isShareable {
            print("""

            Help others know whether nohog works on their Mac: share this result (opens a pre-filled issue):
              \(report.issueURL(repository: repository).absoluteString)
            README row: \(report.markdownRow)
            """)
        } else {
            print("Spotlight was busy; run `nohog selftest` again in a few minutes.")
        }
        if case .fail = result { exit(1) }
    case "bench":
        try bench(files: rest.first.flatMap(Int.init) ?? 20_000, store: try SpotlightExclusionStore())
    case "install":
        try install(store: try SpotlightExclusionStore()) // throws where the API is missing
    case "uninstall":
        try uninstall(store: try SpotlightExclusionStore())
    case "top":
        let depth = rest.firstIndex(of: "--depth").flatMap { rest.indices.contains($0 + 1) ? Int(rest[$0 + 1]) : nil } ?? 4
        let seconds = rest.first.flatMap(Int.init) ?? 20
        try top(seconds: seconds, depth: depth)
    case "watch":
        // launchd sets XPC_SERVICE_NAME to the job's label; a foreground run has neither label.
        let me = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        let rank = Paths.agentLabels.firstIndex(of: me) ?? Paths.agentLabels.count
        if let other = Paths.agentLabels.prefix(rank).first(where: isLoaded) {
            print("another nohog agent is already running (\(other)); exiting")
            exit(0) // clean exit, so launchd does not restart this one
        }
        let store: SpotlightExclusionStore
        do { store = try SpotlightExclusionStore() } catch {
            print("\(error)")
            notify("nohog stopped: \(error)")
            exit(0) // clean exit, so launchd does not restart it in a loop
        }
        Agent(store: store).start()
    case "version", "--version":
        print(version)
    case "help", "-h", "--help":
        print(usage)
    default:
        fail("unknown command '\(command)'\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
