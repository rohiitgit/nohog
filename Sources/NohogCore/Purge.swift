import Foundation

public struct PurgeResult: Equatable, Sendable {
    public var path: String
    /// Items Spotlight had indexed below `path` before and after the purge.
    public var before: Int
    public var after: Int

    public init(path: String, before: Int, after: Int) {
        self.path = path
        self.before = before
        self.after = after
    }
}

/// Re-sends exclusions that are already listed but still have content in the index, so mds purges it.
/// mds only purges when an exclusion arrives through `_MDSetExclusion`: entries written straight into
/// VolumeConfiguration.plist (older scripts, dotfiles) block new files after an mds restart, but keep
/// everything indexed before. Re-sending a listed path leaves the list unchanged, so `indexed` is the
/// only proof it worked. mds drops requests while busy purging, so each path is re-sent with backoff.
public func purgeStale(
    paths: [String],
    store: ExclusionStore,
    indexed: (String) -> Int,
    settle: TimeInterval = 5,
    polls: Int = 6,
    wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    progress: (PurgeResult) -> Void = { _ in }
) throws -> [PurgeResult] {
    var results: [PurgeResult] = []
    for path in paths {
        let before = indexed(path)
        guard before > 0 else { continue }
        var left = before
        attempts: for delay in [0, 1, 2, 4, 8] as [TimeInterval] {
            wait(delay)
            try store.setExcluded(path, true)
            for _ in 0..<polls {
                wait(settle)
                left = indexed(path)
                if left == 0 { break attempts }
            }
        }
        let result = PurgeResult(path: path, before: before, after: left)
        progress(result)
        results.append(result)
    }
    return results
}
