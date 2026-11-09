# nohog

Every `npm install` hands Spotlight thousands of files you will never search for. One web app's `node_modules` on my Mac held 104,031 of them, enough to keep a CPU core busy for about 25 minutes while `mds_stores` indexed it all. nohog makes Spotlight skip dev junk (`node_modules`, `target`, `Pods`, `venv`, …) without turning search off, and keeps doing so as you clone, install and update macOS.

![nohog finding junk folders, then measuring Spotlight CPU with and without an exclusion](docs/demo.gif)

<sub>Recorded with `vhs docs/demo.tape`, sped up 5×. The numbers are measured live.</sub>

**20,000 new `node_modules` files cost Spotlight 299 s of CPU** (one core flat out for about 5 minutes) and all of them got indexed. **Excluded, the same files cost 0 s, and none were indexed.** See [Impact](#impact) for the method and how to run it yourself.

No sudo, no Full Disk Access. macOS 13 or later, Apple Silicon or Intel.

## Install

**Homebrew** (recommended; builds from source, and the agent keeps running across upgrades):

```
brew tap rohiitgit/nohog https://github.com/rohiitgit/nohog
brew trust rohiitgit/nohog     # Homebrew 7+ only loads third-party taps you approve
brew install nohog
brew services start nohog
```

**Prebuilt binary** (universal, Apple Silicon + Intel):

```
curl -fsSL https://github.com/rohiitgit/nohog/releases/latest/download/nohog-macos.zip -o /tmp/nohog.zip
unzip -o /tmp/nohog.zip -d /tmp && /tmp/nohog install    # copies itself to ~/.local/bin, starts the agent
```

Releases are built by GitHub Actions and ad-hoc signed, not notarized (no paid Apple account).
`curl` downloads run fine. If you download the zip **in a browser** instead, macOS blocks it until you
clear the quarantine flag: `xattr -d com.apple.quarantine nohog`.

**From source** (Command Line Tools with Swift 6 is enough):

```
git clone https://github.com/rohiitgit/nohog && cd nohog
swift build -c release && .build/release/nohog install
```

Before it starts anything, `install` runs a selftest that excludes a probe folder and checks that Spotlight really skips it. If your macOS doesn't honor exclusions, it refuses to install.

If macOS asks whether nohog may access a removable volume (for code on an external drive), click **Allow**. Because builds are ad-hoc signed, macOS may ask again after an upgrade.

## Impact

Measured with `nohog bench` on macOS 27.2 (26B123), Apple Silicon. Spotlight's background activity was subtracted (0.7 to 1.9 s of CPU per minute during the runs).

| | Without exclusion | Excluded |
|---|---|---|
| Spotlight CPU for 3,000 new `node_modules` files (the GIF) | 42.6 s | 0.0 s |
| Spotlight CPU for 5,000 new `node_modules` files | 80.7 s | 0.0 s |
| Spotlight CPU for 20,000 new `node_modules` files | 298.7 s (282 s wall-clock) | 0.0 s |
| Files that ended up in the index | 20,000 of 20,000 | 0 of 20,000 |

That works out to 14 to 16 ms of Spotlight CPU per file across the runs, and it scales linearly. On my dev machine, `nohog status --count` reports **183,045 files in 9 folders** that nohog keeps out of the index. That includes a 104,031-file `node_modules` and a 53,849-file Go module cache. The headline's "about 25 minutes" is that `node_modules` times the measured 14 to 16 ms per file (24 to 28 minutes of one core). It is an extrapolation from the benchmark, not a separate measurement.

**How `nohog bench` measures:**

1. It records Spotlight's background CPU for 20 s.
2. It writes N small JavaScript files (about 590 bytes each, with code and comment text) into a normal folder, then into an identical folder excluded exactly the way nohog excludes folders.
3. After each write, it adds up the CPU time of `mds`, `mds_stores` and `mdworker_shared`, sampled with `ps` every second, until Spotlight has been quiet for 8 s.
4. It counts how many of the files `mdfind` can find.

**Caveats:**

- **One machine.** Your numbers will differ; run `nohog bench` (about 2 to 6 minutes, cleans up after itself) and share them.
- **Synthetic files.** Real packages vary in size and type.
- **CPU a worker uses in the second before it exits is missed.** That makes both columns slightly low.
- **Real use has a short gap.** The agent excludes a brand-new folder about 3 s after it appears, so the first few seconds of an `npm install` still get indexed. The benchmark excludes before writing.

## Tested on

The exclusion API is private, so a version is listed only when someone has run `nohog selftest` on it. The selftest proves that an excluded folder stays out of the index while a control folder gets indexed.

| macOS | Build | Chip | Result | nohog |
|---|---|---|---|---|
| 27.2 | 26B123 | Apple Silicon | ✅ pass | 0.1.2 |

**Help fill this in:** run `nohog selftest`. On a pass or a fail it prints a link that opens a pre-filled GitHub issue (macOS version, build, chip, result), plus the table row. Intel Macs and macOS 13 to 26 are especially wanted. The Intel build has only been run under Rosetta so far.

## How it decides what to exclude

1. **It walks your dev folders**, up to 8 levels deep. It doesn't follow symlinks or enter app bundles. Default folders, where they exist:
   - `~/Developer`, `~/Projects`, `~/Code`, `~/src`, `~/dev`, `~/git`, `~/repos`, `~/workspace`, `~/GitHub`
   - `/Volumes/*/Developer` on any drive
2. **A folder is junk only if its name and a sibling file both match.** A `target` folder with no `Cargo.toml` or `pom.xml` next to it stays searchable:

   | folder | needs a sibling |
   |---|---|
   | `node_modules` | `package.json` |
   | `bower_components` | `bower.json` |
   | `target` | `Cargo.toml` or `pom.xml` |
   | `venv` | `pyproject.toml`, `requirements.txt`, `setup.py` or `Pipfile` |
   | `Pods` / `Carthage` | `Podfile` / `Cartfile` |
   | `build` | `build.gradle*`, `settings.gradle*`, `CMakeLists.txt` or `pubspec.yaml` |
   | `vendor` | `composer.json` or `go.mod` |
   | `_build`, `deps` | `mix.exs` |
   | `bin`, `obj` | `*.csproj` or `*.fsproj` |
   | `dist-newstyle` | `cabal.project` or `*.cabal` |
   | `elm-stuff` | `elm.json` |
   | `zig-out`, `zig-cache` | `build.zig` |
   | `Library` (Unity) | a `ProjectSettings` folder |

3. **It adds tool caches outside projects:** `~/Library/Developer/Xcode/DerivedData` and `~/go/pkg/mod`.
4. **It skips what Spotlight already ignores:** folders starting with `.` (`.venv`, `.next`, `.gradle`, `~/.m2`, `~/.npm`) and `*.noindex`.

Something that hogs Spotlight but isn't on this list? Run `sudo nohog top` to find it, then add it to the config (below).

## How it stays up to date

- **The exclusion list:** nohog writes to the same **Search Privacy** list as System Settings, using the private `_MDSetExclusion` / `_MDCopyExclusionList` calls in Metadata.framework.
  - Changes apply immediately, and content that was already indexed is purged.
  - On current macOS, `.metadata_never_index` files have no effect. Editing `VolumeConfiguration.plist` (as older scripts and dotfiles do) blocks new files once mds restarts, but never purges what was already indexed: run `nohog purge` to fix folders excluded that way.
- **The background agent reconciles:**
  - at login, which covers the reboot after a macOS update;
  - within ~3 s of a junk folder appearing (FSEvents);
  - when a drive mounts;
  - hourly.
- **After every macOS update** it re-runs the selftest. If exclusions ever stop working, it notifies you and pauses itself instead of guessing.

## Safety

- **Your own exclusions are never touched.** nohog only removes what it added (`~/Library/Application Support/nohog/state.json`). That record is derived from what Spotlight reports after each change, not from what nohog requested.
- **It only prunes what it actually looked at.** An unplugged drive, a denied permission or an unreadable folder never causes an un-exclude.
- **Every change is verified.** mds drops requests while it is busy purging a big folder, so missing changes are re-sent with backoff.

## Commands

```
nohog install / uninstall              start the agent / stop it and remove every exclusion nohog added
nohog status [--count]                 exclusions marked [nohog] or [yours] (with file counts), and whether the agent runs
nohog scan [--count] [root...]         list junk folders (with file counts)
nohog reconcile [--dry-run]            apply now / preview
nohog purge [path...]                  re-send exclusions whose old content is still indexed (default: whole list)
nohog selftest                         prove exclusions work on this macOS (10-35 s); prints a shareable result
nohog bench [files]                    measure Spotlight CPU with vs without an exclusion (default 20,000 files)
sudo nohog top [seconds] [--depth N]   which folders Spotlight is reading right now
nohog --version
```

Log: `~/Library/Logs/nohog.log`, one line per change.

Homebrew users stop with `brew services stop nohog && nohog uninstall`.

## Config (optional): `~/.config/nohog/config.json`

Re-read on every reconcile, so there's no restart needed. Every field is optional.

```json
{
  "roots": ["~/Developer", "~/Documents/GitHub", "/Volumes/*/Developer"],
  "extraPaths": ["~/Developer/myapp/data/cache"],
  "extraRules": [{ "name": "dist", "sentinels": ["package.json"] }],
  "skipPaths": ["~/Developer/keep-searchable"],
  "maxDepth": 8
}
```

- `roots` replaces the defaults.
- `extraRules` adds to the built-in rules.
- `~/Documents` is not a default root because macOS protects it. If you add it, approve the prompt once.

## Limits

- **It relies on a private API.** The selftest gates install and re-checks after every macOS update. See [Tested on](#tested-on) for verified versions, and add yours.
- **A brand-new `node_modules` is indexed for its first ~3 seconds** before it gets excluded.

## Development

```
swift test -Xswiftc -warnings-as-errors
./scripts/release.sh     # universal zip in dist/; see the script header for signing and notarization
vhs docs/demo.tape       # re-record the README GIF (brew install vhs; runs a live benchmark, ~3 min)
```

The tests use an in-memory exclusion store, so they never touch your Spotlight settings. Running the tests needs Xcode (Command Line Tools ships no test frameworks). Building does not.

Releasing:

1. Bump `version` in `Sources/nohog/main.swift`, commit, then tag and push: `git tag vX.Y.Z && git push --tags`.
2. The `release` workflow runs the tests, builds the universal zip and publishes the GitHub release.
3. Update `url` and `sha256` in `Formula/nohog.rb` (`shasum -a 256` of the tag's `.tar.gz`).

`scripts/release.sh` also accepts `NOHOG_SIGN_IDENTITY` / `NOHOG_NOTARY_PROFILE` if you ever get a Developer ID.

## License

MIT, see [LICENSE](LICENSE).
