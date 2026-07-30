# MapleStory (TMS) Download via cmsdl + Shared Disk Guard Design

Date: 2026-07-30

## Goal

Add App-driven download of **新楓之谷**（非經典版）using pinned [cmsdl](https://github.com/HikariCalyx/cmsdl) (`cmsdl_darwin tms --download <dir>`), with the same progress UX as classic nxdl downloads.

Before any client download (cmsdl **and** classic nxdl), run the tool’s `--check --json`, compare `total_size` against free space on the destination volume, and:

| Condition | Behavior |
| --- | --- |
| `free ≥ total_size × 1.05` | Proceed with download; **no** warning |
| `total_size + 1 GiB ≤ free < total_size × 1.05` | Warning alert with **「仍要下載」** (and cancel) |
| `free < total_size + 1 GiB` | **Block** download; error only (no continue) |

Apply to **Modern and Legacy**.

## Background

Classic already downloads via `NxdlDownloader` (`nxdl_darwin tms_cw --download`), PTY + indicatif TUI parsing, SHA-256 pin, quarantine clear, and Windows-`\` basename normalization.

Non-classic MapleStory (`GameDefinition.mapleStory`, exe `MapleStory.exe`) today only documents a manual browser download. [cmsdl](https://github.com/HikariCalyx/cmsdl) is the TMS counterpart:

```bash
cmsdl_darwin tms --check --json    # size probe
cmsdl_darwin tms --download <dir>  # full client
```

cmsdl `tms.rs` joins paths with `/` components and often normalizes `\`, but does not guarantee normalization before every write; keep a defensive post-download path restore (same as classic; usually a no-op).

cmsdl TMS progress templates match nxdl/indicatif closely enough to reuse the existing TUI parser + progress dialogs.

### Version pin (cmsdl)

| Item | Value |
| --- | --- |
| Tag | `v0.2.5`（正式 release 標籤） |
| Binary | `cmsdl_darwin`（universal x86_64 + arm64） |
| SHA-256 | `706efcf17608a807c884e1eb8e0c8b97084f67dfbec29f7664e9aba77d0a0b78` |
| Why not `v0.2.6-prerelease7` | TMS download core (`src/tms.rs`) unchanged; 0.2.5 is the newest non-prerelease |

nxdl pin for classic remains unchanged (`v0.1.2-prerelease2`).

## Non-Goals

- CMS / `cms_cw` regions, `--download-wz-only`, patch, torrent, maintenance GUI.
- Discounting `total_size` by files already present in the destination (first version uses full manifest total).
- Auto-install of Cyder / Wine / MapleStory Launcher.
- Renaming progress types away from `Nxdl*` in the first implementation if costly; shared module may keep nxdl-origin names internally until a clean rename pass.
- Changing classic auth / NexonPlug / Cyder `-b` launch behavior.

## Decisions

| Topic | Decision |
| --- | --- |
| Architecture | **A**: shared game-client downloader core + per-tool config (nxdl / cmsdl) |
| Tracks | Modern + Legacy |
| cmsdl pin | `v0.2.5` + SHA-256 above |
| CLI download | `cmsdl_darwin tms --download <dest>` |
| CLI size probe | `cmsdl_darwin tms --check --json` / `nxdl_darwin tms_cw --check --json` |
| Size field | JSON key `total_size` (bytes); both tools expose it |
| Comfortable free | `total_size * 1.05` → no warning |
| Minimum free | `total_size + 1 GiB` → below this: hard block |
| Warning band | `[minimum, comfortable)` → alert + 「仍要下載」 |
| Small clients | When `total_size < 20 GiB`, `×1.05` &lt; `+1 GiB`; warning band empty; only block vs silent proceed |
| Free space API | Destination URL’s volume capacity (prefer important-usage key when available; Legacy 10.12-compatible fallback) |
| Progress UI | Reuse classic progress sheet / Legacy window (overall + speed + 預估剩餘時間 + current file text) |
| Post-download | Defensive `\` path normalize; find `MapleStory.exe` / `Maplestory_Classic.exe`; set executable path |
| Cache dirs | Separate under Application Support: `…/nxdl/` and `…/cmsdl/` |
| UI placement | Classic: existing button; MapleStory: welcome / executable area 「下載客戶端」 |

## Shared downloader shape

```text
GameClientToolConfig
  releaseTag, binaryURL, sha256Hex
  cacheFolderName, binaryFileName
  checkArguments(dest unused) → e.g. ["tms", "--check", "--json"]
  downloadArguments(dest) → e.g. ["tms", "--download", dest]
  primaryExecutableName

Shared pipeline
  ensureBinary (download + SHA-256 + quarantine + chmod)
  probeTotalSize (--check --json → total_size)
  evaluateDiskSpace(free, total) → .ok | .warn | .blocked
  runDownload (PTY + existing progress stream parser)
  normalizeWindowsPathFilenames (defensive)
  findExecutable
```

Classic and TMS entry points call the same pipeline with different configs. Existing `NxdlDownloader` API used by AppModel / AppController should keep working (thin wrapper or rename with typealiases) so call sites stay small.

### Disk evaluation (pure function)

```text
comfortable = total_size * 1.05
minimum     = total_size + 1 GiB   // 1 GiB = 1024^3

if free >= comfortable           → .ok
else if free >= minimum          → .warn(needed: total_size, free, comfortable, minimum)
else                             → .blocked(...)
```

Alert copy (Traditional Chinese) must show human-readable needed / free / thresholds. Blocked path must not start download. Warn path starts download only after 「仍要下載」.

### Check JSON examples

cmsdl:

```json
{"region":"tms","build":0,"version":"V280","files":1234,"total_size":13245678901}
```

nxdl (`tms_cw`):

```json
{"appid":"2982@2141","game_name":"新楓之谷：經典版",...,"total_size":2962637533}
```

Parser: require `total_size` as non-negative number; on parse / process failure, surface error and do not download.

## Flow

```text
User taps download (MapleStory or Classic)
  → guard game id + not already downloading
  → NSOpenPanel destination
  → ensureBinary for tool
  → run --check --json → total_size
  → read free space for destination volume
  → disk gate:
        blocked → error alert; stop
        warn    → confirm; cancel stops; continue → download
        ok      → download
  → PTY download + progress UI
  → path normalize
  → find exe → set executablePath / Legacy save
  → close progress UI
```

## UI details

### Modern

- MapleStory (`.welcome` / exe section when `selectedGame.id == maplestory`): button 「下載客戶端」 (or 「下載新楓之谷客戶端」 for clarity).
- Classic: keep 「下載經典版客戶端」; insert disk gate before existing download.
- Progress: existing `ClassicDownloadProgressView` sheet may be generalized in name later; behavior unchanged.
- Disk warn/block: `NSAlert` (AppKit) from AppModel is acceptable for parity with Legacy.

### Legacy

- MapleStory screen: download button mirroring Modern.
- Classic: existing button + shared disk gate.
- Progress: existing `ClassicDownloadProgressWindowController` (or shared naming later).

### Concurrency

- One client download at a time app-wide (classic or TMS); disable both download buttons while busy.

## Docs & tests

- New maintainer doc `docs/cmsdl-maplestory-download.md` (pin, check, disk rules, path restore) + links from README / `macos-player-guide.md`.
- Update classic nxdl doc with disk-gate section.
- Unit tests: disk evaluation tiers (including `total_size < 20 GiB`); JSON `total_size` parse for both sample shapes; cmsdl SHA constant; existing nxdl parser tests remain.

## Success criteria

1. Modern + Legacy can download TMS client via pinned cmsdl `v0.2.5` with progress UI.
2. Both TMS and classic run `--check --json` and apply the three-way disk gate before download.
3. Blocked when `free < total_size + 1 GiB`; warn+continue only in the middle band; silent when `free ≥ total_size × 1.05`.
4. Legacy remains macOS 10.12+ (no new APIs that raise the floor).
5. After success, `MapleStory.exe` / `Maplestory_Classic.exe` path is set when found.
6. Tests cover disk math and check JSON parsing; builds include new sources in `build-legacy.sh` / `test.sh` as needed.

## Open implementation notes (not blockers)

- Prefer refactoring `NxdlDownloader.swift` into shared + configs in one PR series; if diff is huge, first extract disk/check helpers then add cmsdl config.
- Exact button label copy can be finalized in implementation to match surrounding UI tone.
- If volume capacity API returns `nil` on rare volumes, treat as check failure (do not silently skip the gate).
