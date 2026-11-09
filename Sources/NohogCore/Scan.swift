import Foundation

/// A junk directory name plus the sibling entries that prove what it is.
/// Folders whose names start with "." need no rule: Spotlight already skips them.
public struct Rule: Codable, Equatable, Sendable {
    public var name: String
    /// Sibling names: `build.gradle*` is a prefix match, `*.csproj` a suffix match. Empty means "always".
    public var sentinels: [String]

    public init(_ name: String, _ sentinels: [String]) {
        self.name = name
        self.sentinels = sentinels
    }

    public func matches(siblings: Set<String>) -> Bool {
        if sentinels.isEmpty { return true }
        return sentinels.contains { sentinel in
            if sentinel.hasSuffix("*") { return siblings.contains { $0.hasPrefix(sentinel.dropLast()) } }
            if sentinel.hasPrefix("*") { return siblings.contains { $0.hasSuffix(sentinel.dropFirst()) } }
            return siblings.contains(sentinel)
        }
    }

    public static let defaults: [Rule] = [
        // JavaScript
        Rule("node_modules", ["package.json"]),
        Rule("bower_components", ["bower.json"]),
        // Rust, Maven
        Rule("target", ["Cargo.toml", "pom.xml"]),
        // Python
        Rule("venv", ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"]),
        // Apple
        Rule("Pods", ["Podfile"]),
        Rule("Carthage", ["Cartfile"]),
        // Gradle/Android, CMake, Flutter
        Rule("build", ["build.gradle*", "settings.gradle*", "CMakeLists.txt", "pubspec.yaml"]),
        // PHP, Go
        Rule("vendor", ["composer.json", "go.mod"]),
        // Elixir
        Rule("_build", ["mix.exs"]),
        Rule("deps", ["mix.exs"]),
        // .NET
        Rule("bin", ["*.csproj", "*.fsproj"]),
        Rule("obj", ["*.csproj", "*.fsproj"]),
        // Haskell, Elm, Zig
        Rule("dist-newstyle", ["cabal.project", "*.cabal"]),
        Rule("elm-stuff", ["elm.json"]),
        Rule("zig-out", ["build.zig"]),
        Rule("zig-cache", ["build.zig"]),
        // Unity
        Rule("Library", ["ProjectSettings"]),
    ]
}

public struct Config: Equatable, Sendable {
    /// Directories to scan. May contain `*` path components, e.g. `/Volumes/*/Developer`.
    public var roots: [String]
    /// Paths excluded as-is (when they exist), no scanning or sentinel needed.
    public var extraPaths: [String]
    public var rules: [Rule]
    /// Never exclude these paths or anything below them.
    public var skipPaths: [String]
    public var maxDepth: Int

    public static func defaults(home: String) -> Config {
        Config(
            // Common places people keep code. Missing ones are ignored. ~/Documents is left out on
            // purpose: it is privacy-protected, so watching it would trigger a macOS permission prompt.
            roots: [
                "~/Developer", "~/Projects", "~/Code", "~/src", "~/dev", "~/git", "~/repos",
                "~/workspace", "~/GitHub", "/Volumes/*/Developer",
            ].map { expandTilde($0, home: home) },
            // Tool caches outside any project.
            extraPaths: ["~/Library/Developer/Xcode/DerivedData", "~/go/pkg/mod"].map { expandTilde($0, home: home) },
            rules: Rule.defaults,
            skipPaths: [],
            maxDepth: 8
        )
    }

    /// On-disk format: every field optional; `extraRules` are appended to the defaults.
    private struct File: Codable {
        var roots: [String]?
        var extraPaths: [String]?
        var extraRules: [Rule]?
        var skipPaths: [String]?
        var maxDepth: Int?
    }

    /// Defaults, overridden by whatever the JSON file at `url` sets. A missing file means defaults.
    public static func load(from url: URL, home: String) throws -> Config {
        var config = defaults(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return config }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        if let roots = file.roots { config.roots = roots.map { expandTilde($0, home: home) } }
        if let extra = file.extraPaths { config.extraPaths = extra.map { expandTilde($0, home: home) } }
        if let rules = file.extraRules { config.rules += rules }
        if let skip = file.skipPaths { config.skipPaths = skip.map { expandTilde($0, home: home) } }
        if let depth = file.maxDepth { config.maxDepth = depth }
        return config
    }
}

public func expandTilde(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst() }
    return path
}

/// Canonical form used for every path nohog stores or compares: absolute, symlinks resolved.
/// Uses realpath(3): URL.resolvingSymlinksInPath strips "/private", which would not match the
/// paths that directory listings return.
public func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else {
        return URL(fileURLWithPath: path).standardizedFileURL.path // nonexistent: best effort
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Expands `*` components (fnmatch) against the file system; returns existing directories only.
public func expandGlob(_ pattern: String) -> [String] {
    var candidates = ["/"]
    for component in pattern.split(separator: "/").map(String.init) {
        var next: [String] = []
        for base in candidates {
            if component.contains("*") {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                for name in names.sorted() where fnmatch(component, name, FNM_PERIOD) == 0 {
                    next.append((base as NSString).appendingPathComponent(name))
                }
            } else {
                next.append((base as NSString).appendingPathComponent(component))
            }
        }
        candidates = next
    }
    return candidates.filter(isDirectory)
}

/// Root patterns → existing, canonical, de-duplicated directories (a symlinked root counts once).
public func expandRoots(_ patterns: [String]) -> [String] {
    Array(Set(patterns.flatMap(expandGlob).map(canonicalPath))).sorted()
}

func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

/// True when `path` is `ancestor` or lies below it.
func isWithin(_ path: String, _ ancestor: String) -> Bool {
    path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
}

public struct ScanResult: Equatable, Sendable {
    /// Junk directories found, canonical and sorted.
    public var found: [String]
    /// Roots that were listed successfully. Prune decisions are only trusted inside these...
    public var scannedRoots: [String]
    /// ...and outside these: directories that could not be listed (e.g. macOS denied access).
    public var unreadable: [String] = []
}

public struct JunkScanner: Sendable {
    public var rules: [Rule]
    public var skipPaths: [String]
    public var maxDepth: Int

    public init(rules: [Rule], skipPaths: [String], maxDepth: Int) {
        self.rules = rules
        self.skipPaths = skipPaths.map(canonicalPath)
        self.maxDepth = maxDepth
    }

    public init(config: Config) {
        self.init(rules: config.rules, skipPaths: config.skipPaths, maxDepth: config.maxDepth)
    }

    public func scan(roots rootPatterns: [String]) -> ScanResult {
        let roots = expandRoots(rootPatterns)
        var found = Set<String>(), unreadable = Set<String>()
        for root in roots where !isSkipped(root) {
            walk(root, found: &found, unreadable: &unreadable)
        }
        return ScanResult(found: found.sorted(), scannedRoots: roots.filter { !unreadable.contains($0) }, unreadable: unreadable.sorted())
    }

    private func isSkipped(_ path: String) -> Bool {
        skipPaths.contains { isWithin(path, $0) }
    }

    private func walk(_ root: String, found: inout Set<String>, unreadable: inout Set<String>) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var stack: [(url: URL, depth: Int)] = [(URL(fileURLWithPath: root, isDirectory: true), 0)]
        while let (dir, depth) = stack.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else {
                unreadable.insert(dir.path)
                continue
            }
            let siblings = Set(entries.map(\.lastPathComponent))
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let name = entry.lastPathComponent
                let path = entry.path
                if isSkipped(path) { continue }
                if rules.contains(where: { $0.name == name && $0.matches(siblings: siblings) }) {
                    found.insert(path)
                    continue // never descend into junk
                }
                // Spotlight already ignores dot-folders and *.noindex; packages hold no projects.
                if name.hasPrefix(".") || name.hasSuffix(".noindex") || values.isPackage == true { continue }
                if depth + 1 < maxDepth { stack.append((entry, depth + 1)) }
            }
        }
    }
}

/// Directories to watch for root patterns: each pattern's literal prefix (up to the first `*`
/// component), canonicalized and existing, with nested duplicates dropped.
/// `/Volumes/*/Developer` → `/Volumes`, which also reports drive mounts.
public func watchRoots(for patterns: [String]) -> [String] {
    let prefixes = patterns.map { pattern in
        "/" + pattern.split(separator: "/").prefix { !$0.contains("*") }.joined(separator: "/")
    }
    let existing = Set(prefixes.filter(isDirectory).map(canonicalPath)).sorted()
    return existing.filter { path in !existing.contains { $0 != path && isWithin(path, $0) } }
}

/// A file-system event matters only if it is inside a scanned root and touches a junk-named folder
/// that is not excluded yet. Keeps git checkouts, editor saves, other drives and writes inside
/// already-excluded folders from waking us.
public func isJunkEvent(_ path: String, ruleNames: Set<String>, roots: [String], excluded: [String]) -> Bool {
    let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    guard roots.contains(where: { isWithin(trimmed, $0) }),
          trimmed.split(separator: "/").contains(where: { ruleNames.contains(String($0)) }) else { return false }
    return !excluded.contains { isWithin(trimmed, $0) }
}

/// The folders a change-triggered reconcile has to rescan, each mapped to the depth a full walk would
/// still have left there. For each event: the folder holding its first junk-named component (where
/// that folder's sentinels live), nested results collapsed. Rescanning only these instead of every
/// root keeps a busy `npm install` from costing a full scan per event batch.
/// A scoped pass must find exactly what a full pass finds, or the next full pass prunes what it added
/// and the two flip-flop. So folders a full walk never reaches (below a dot, `.noindex` or package
/// folder, or deeper than `maxDepth`) are dropped, and the rest get only the remaining depth.
public func rescanRoots(for paths: [String], ruleNames: Set<String>, roots: [String], maxDepth: Int) -> [String: Int] {
    var dirs: [String: Int] = [:]
    for path in paths {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let root = roots.filter({ isWithin(trimmed, $0) }).max(by: { $0.count < $1.count }) else { continue }
        var dir = root, depth = 0, reachable = true
        for part in trimmed.dropFirst(root.count).split(separator: "/").map(String.init) {
            if ruleNames.contains(part) { break }
            dir = (dir as NSString).appendingPathComponent(part)
            depth += 1
            let isPackage = (try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            if part.hasPrefix(".") || part.hasSuffix(".noindex") || isPackage { reachable = false; break }
        }
        if reachable && depth < maxDepth { dirs[dir] = maxDepth - depth }
    }
    return dirs.filter { dir, _ in !dirs.keys.contains { $0 != dir && isWithin(dir, $0) } }
}
