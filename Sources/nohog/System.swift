import Foundation
import NohogCore

enum Paths {
    /// The real user's home, also under `sudo` (needed by `top`, which runs as root).
    static let home: String = {
        if getuid() == 0, let user = ProcessInfo.processInfo.environment["SUDO_USER"], let entry = getpwnam(user) {
            return String(cString: entry.pointee.pw_dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }()
    static let config = URL(fileURLWithPath: home + "/.config/nohog/config.json")
    static let state = URL(fileURLWithPath: home + "/Library/Application Support/nohog/state.json")
    static let log = home + "/Library/Logs/nohog.log"
    static let agentLabel = "dev.nohog.agent"
    /// Labels the agent may run under, in precedence order: `brew services start nohog` wins over
    /// `nohog install`, so if both start at login exactly one keeps running.
    static let agentLabels = [homebrewLabel, agentLabel]
    static let agentPlist = home + "/Library/LaunchAgents/\(agentLabel).plist"
    static let installedBinary = home + "/.local/bin/nohog"
}

/// macOS build, e.g. "26B123". A change means an OS update happened.
func osBuild() -> String {
    var size = 0
    sysctlbyname("kern.osversion", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Runs a tool to completion and returns (exit status, stdout).
@discardableResult
func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func notify(_ message: String) {
    let text = message.replacingOccurrences(of: "\"", with: "'")
    run("/usr/bin/osascript", ["-e", "display notification \"\(text)\" with title \"nohog\""])
}

// MARK: - selftest

/// "27.2" or "26.4.1".
func macOSVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
}

/// The hardware, not the slice we run as: Apple Silicon reports hw.optional.arm64 = 1 even under Rosetta.
func chipName() -> String {
    var arm64: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let found = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0
    return found && arm64 == 1 ? "Apple Silicon" : "Intel"
}

func selftest(store: ExclusionStore) -> SelftestResult {
    runSelftest(store: store, parent: canonicalPath(Paths.home)) { token, dir in
        run("/usr/bin/mdfind", ["-onlyin", dir, token]).output.split(separator: "\n").map(String.init)
    }
}

/// Items Spotlight still has indexed below `path`. Scoped to an excluded folder itself, mdfind reports
/// 0 even while its old content is still indexed, so this queries the parent and filters by prefix.
/// `kMDItemFSName == "*"` matches nothing; every item's content-type tree includes public.item.
/// mdfind prints firmlinked paths (`/Users/…`), so a `/System/Volumes/Data/…` entry is mapped first.
func indexedCount(_ path: String) -> Int {
    let data = "/System/Volumes/Data"
    let path = path.hasPrefix(data + "/") ? String(path.dropFirst(data.count)) : path
    let prefix = path + "/"
    let parent = (path as NSString).deletingLastPathComponent
    return run("/usr/bin/mdfind", ["-onlyin", parent, "kMDItemContentTypeTree == \"public.item\""]).output
        .split(separator: "\n").filter { $0.hasPrefix(prefix) }.count
}

func selftestIfNeeded(store: ExclusionStore) -> SelftestResult? {
    selftestIfNeeded(stateURL: Paths.state, build: osBuild()) { selftest(store: store) }
}

// MARK: - install / uninstall

func launchAgentPlist(binary: String) -> [String: Any] {
    [
        "Label": Paths.agentLabel,
        "ProgramArguments": [binary, "watch"],
        "RunAtLoad": true,
        // Restart after a crash, but not after a deliberate clean exit (e.g. the API is gone).
        "KeepAlive": ["SuccessfulExit": false],
        "ProcessType": "Background",
        "LowPriorityIO": true,
        "Nice": 10,
        "StandardOutPath": Paths.log,
        "StandardErrorPath": Paths.log,
    ]
}

func isLoaded(_ label: String) -> Bool {
    run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
}

let homebrewLabel = "homebrew.mxcl.nohog"

func install(store: ExclusionStore) throws {
    // Resolve symlinks: Homebrew runs us as /opt/homebrew/bin/nohog -> ../Cellar/nohog/<v>/bin/nohog.
    if Bundle.main.executablePath.map(canonicalPath)?.contains("/Cellar/") == true || isLoaded(homebrewLabel) {
        fail("installed with Homebrew: use `brew services start nohog` (it keeps the agent updated on upgrade)")
    }
    print("checking that Spotlight honors exclusions on this macOS (10-35s)…")
    switch selftestIfNeeded(store: store) {
    case .fail(let why)?:
        fail("not installing: \(why). This macOS may not support the exclusion API nohog relies on.")
    case .inconclusive(let why)?:
        print("warning: \(why); the agent will re-check at its next start")
    case .pass?, nil:
        break
    }
    let fm = FileManager.default
    guard let source = Bundle.main.executablePath.map(canonicalPath) else { fail("cannot locate own executable") }
    if source != canonicalPath(Paths.installedBinary) {
        try fm.createDirectory(atPath: (Paths.installedBinary as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: Paths.installedBinary)
        try fm.copyItem(atPath: source, toPath: Paths.installedBinary)
    }
    try fm.createDirectory(atPath: (Paths.agentPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: launchAgentPlist(binary: Paths.installedBinary), format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: Paths.agentPlist), options: .atomic)

    let domain = "gui/\(getuid())"
    run("/bin/launchctl", ["bootout", "\(domain)/\(Paths.agentLabel)"]) // fine if not loaded
    let (status, _) = run("/bin/launchctl", ["bootstrap", domain, Paths.agentPlist])
    guard status == 0 else { fail("launchctl bootstrap failed (\(status))") }
    print("""
    installed \(Paths.installedBinary)
    agent \(Paths.agentLabel) running: at login, on dev-folder changes, on drive mounts, hourly
    log: \(Paths.log)
    If macOS asks whether nohog may access a removable volume, click Allow.
    """)
}

func uninstall(store: ExclusionStore) throws {
    if isLoaded(homebrewLabel) { fail("run `brew services stop nohog` first, or it will re-add the exclusions") }
    run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Paths.agentLabel)"])
    try? FileManager.default.removeItem(atPath: Paths.agentPlist)

    let state = try State.load(from: Paths.state)
    let after = try applyExclusions(add: [], remove: state.managed, current: try store.list(), store: store)
    let remaining = Set(after).intersection(state.managed)
    if remaining.isEmpty {
        try? FileManager.default.removeItem(at: Paths.state)
    } else {
        try State(managed: remaining.sorted(), lastOSBuild: state.lastOSBuild).save(to: Paths.state)
    }
    try? FileManager.default.removeItem(atPath: Paths.installedBinary)
    print("removed agent and \(state.managed.count - remaining.count) nohog exclusions; your own exclusions are untouched")
    if !remaining.isEmpty { fail("could not remove: \(remaining.sorted().joined(separator: ", "))") }
}

// MARK: - top

/// Records Spotlight's file activity with fs_usage for `seconds`, then ranks folders by events.
func top(seconds: Int, depth: Int) throws {
    guard getuid() == 0 else { fail("top reads kernel file events and needs root: sudo nohog top \(seconds)") }
    let config = try Config.load(from: Paths.config, home: Paths.home)
    let roots = expandRoots(config.roots)
    let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("nohog-fs_usage-\(getpid()).txt")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: logURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/fs_usage")
    process.arguments = ["-w", "-f", "filesys"]
    process.standardOutput = try FileHandle(forWritingTo: logURL)
    process.standardError = FileHandle.nullDevice
    try process.run()
    print("recording Spotlight file activity for \(seconds)s…")
    Thread.sleep(forTimeInterval: TimeInterval(seconds))
    process.interrupt()
    process.waitUntilExit()

    let ranked = rankSpotlightActivity(try String(contentsOf: logURL, encoding: .utf8), ruleNames: Set(config.rules.map(\.name)), roots: roots, depthBelowRoot: depth)
    let total = ranked.reduce(0) { $0 + $1.events }
    print("\(total) file events by mds/mds_stores/mdworker in \(seconds)s")
    for (bucket, events) in ranked.prefix(15) {
        print(String(format: "%8d  %@", events, bucket))
    }
    if total == 0 { print("Spotlight is idle.") }
}
