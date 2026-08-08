# Check Update Button + Integrity File Names Design

Date: 2026-08-08

## Goal

When a game already has a **valid main-program path**, replace the empty space left by the download button with a **「檢查更新」** control that:

1. Runs an App-side **quick check** (no download) on demand (no auto-check on enter).
2. Surfaces clear follow-up actions based on the result.
3. During cmsdl integrity verification in the progress sheet, shows **which file(s)** are being checked (not only 「檢查完整性中」).

Applies to **新楓之谷** (cmsdl) and **新楓之谷：經典版** (nxdl), in the same welcome / classic surfaces that currently show 「下載xxx」 when no valid executable is set. Modern UI is in scope; Legacy is optional follow-up unless cheap to keep in sync.

## Background

Today:

| Condition | UI |
| --- | --- |
| `!hasValidExecutable` | 「下載新楓之谷」 / 「下載經典版」 |
| `hasValidExecutable` | No check/update button in that slot (menu has 「更新主程式」) |

App already has:

- Shared download pipeline `startGameClientDownload` with incremental size gate (`IncrementalSizeCalculator`) and `isDeepUpdate` path.
- Up-to-date alert with 「確定」 / 「嘗試深度更新」.
- `ClassicUpdateStatus` + `checkClassicClientUpdate()` (classic-only, coarse directory-size heuristic) — unused in `ContentView`.
- Progress view that shows 「檢查完整性中」 when `isCheckingIntegrity` (overall speed contains `GB/s` / `GiB/s`), and 「正在檢查 {names}…」 only when `currentFileNames` is non-empty.

cmsdl `--download` on an existing tree performs **checksum verify / repair** (`already present and verified (skipping download)`). Current pinned nxdl does **not** offer an equivalent local verify-and-skip; re-running `--download` commonly re-fetches.

## Non-Goals

- Auto-check on screen enter or on a timer.
- Changing cmsdl / nxdl pins or tool CLI flags beyond what App already passes.
- Implementing true local checksum verify inside Beanfun OTP for classic (would require nxdl support or a custom verifier).
- Redesigning the full download progress sheet layout.
- Exposing check/update for games other than MapleStory + Classic.

## Decisions

| Topic | Decision |
| --- | --- |
| Placement | Same slot as 「下載xxx」: show download when invalid/missing exe; show check/update when valid |
| Trigger | Manual only — 「檢查更新」 |
| Quick check | Shared: `probeManifestInfo` + `IncrementalSizeCalculator` (replace classic-only size heuristic for this UI) |
| Status model | Generalize `ClassicUpdateStatus` → shared client update status (rename optional if costly; semantics shared) |
| Up to date + MapleStory | Show status + 「嘗試更新」 → deep update (`isDeepUpdate: true`, cmsdl checksum path) |
| Up to date + Classic | Show status + 「完整下載」 → deep update (`isDeepUpdate: true`, nxdl full re-download; honest label) |
| Update available | Status + 「更新」 only — **no** 「嘗試更新」 / 「完整下載」 |
| Error / maintenance | Message + 「再試一次」 + force button (「嘗試更新」 or 「完整下載」) |
| Alert copy | Rename 「嘗試深度更新」 to game-specific 「嘗試更新」 / 「完整下載」 |
| Integrity file names | Wire `destinationURL`; improve parser / UI so checking phase shows current file names |
| Auto-check | No |

## UI state machine

```text
hasValidExecutable == false
  → 「下載xxx」 (unchanged)

hasValidExecutable == true
  ├── .none              → 「檢查更新」
  ├── .checking          → Progress + 「正在檢查更新…」
  ├── .upToDate          → caption + force button
  │                         MapleStory: 「嘗試更新」
  │                         Classic:    「完整下載」
  ├── .updateAvailable   → caption + 「更新」
  └── .maintenanceOrError → caption + 「再試一次」 + force button
```

Reset status to `.none` when selected game changes or executable path changes. When a download/update session starts, set `.none` (or leave progress UI to own the busy state). On successful deep/non-deep update that finds nothing to download, the existing pipeline may set `.upToDate`; otherwise leave status as set by the last check.

## Actions

| Control | MapleStory | Classic |
| --- | --- | --- |
| 檢查更新 | Quick check only | Quick check only |
| 更新 | `updateMapleStoryClient()` non-deep | `updateClassicClient()` non-deep |
| 嘗試更新 | Deep update on exe parent dir | — |
| 完整下載 | — | Deep update on exe parent dir |
| 再試一次 | Re-run quick check | Re-run quick check |

「更新」 uses the existing non-deep path (may short-circuit to up-to-date alert if sizes still match after a race, or download deltas). Force buttons always pass `isDeepUpdate: true`.

## Quick check algorithm

For current selected game with valid exe path `P`, destination = parent of `P`:

1. Set status `.checking`.
2. `probeManifestInfo(config)` for the matching tool config.
3. `bytesNeeded = IncrementalSizeCalculator.calculateRequiredDownloadBytes(...)`.
4. If cancelled → leave or reset carefully; do not flash wrong result.
5. If `bytesNeeded == 0` → `.upToDate`; else → `.updateAvailable`.
6. On probe/network/parse failure → `.maintenanceOrError` with user-facing Traditional Chinese message (reuse classic maintenance heuristics where applicable).

Do not open the download progress sheet during quick check.

## Integrity progress: show file names

### Problem

During cmsdl verify, overall bar often reports disk-like speeds (`GB/s` / `GiB/s`), so `isCheckingIntegrity` becomes true and the sheet shows 「檢查完整性中」, but `currentFileNames` is often empty so the 「正在檢查 {檔名}」 line never appears. `destinationURL` on `NxdlDownloadProgressState` is unused.

### Fix

1. When starting a client download/update, set `progress.destinationURL` to the destination directory.
2. Ensure per-file TUI lines (and, if present, status lines such as `… already present and verified (skipping download)`) update `currentFileNames` / display text during verify.
3. Progress sheet copy when checking:
   - Prefer: 「正在檢查 {fileNames} 檔案完整性…」
   - Fallback if no names yet: 「檢查完整性中」

Keep download-phase copy 「正在下載 {fileNames}」 unchanged.

## Model / UI touch points

- `Sources/Models.swift` — shared update status enum (generalize or alias).
- `Sources/AppModel.swift` — `checkClientUpdate()`, wire force labels, rename deep-update alert buttons, reset status, set `destinationURL` on progress state.
- `Sources/ContentView.swift` — button slot for standard welcome, advanced welcome, classic view (and any duplicate MapleStory download gates).
- `Sources/ClassicDownloadProgressView.swift` — integrity caption prefers file names.
- `Sources/NxdlDownloader.swift` — parser / tracker improvements for verify file names; set destination on tracker if owned there.
- `Sources/BeanfunOTPApp.swift` — menu 「更新主程式」 may keep calling non-deep update; optional later alignment with UI wording (out of scope unless trivial).
- `Tests/CoreTests.swift` — quick-check status transitions; parser cases for integrity file names; alert/button label helpers if extracted.

## Error handling

- Quick check failures must not start a download.
- Busy / already-downloading: disable check and force buttons (same as download buttons today).
- Cancel during quick check: cancel the probe task and set status back to `.none` (do not imply up-to-date).

## Testing

- Unit: `IncrementalSizeCalculator` already covered; add tests for status mapping helpers if pure.
- Unit: progress parser / tracker — when overall speed is GiB/s and file lines (or verified status lines) are present, `currentFileNamesText` is non-nil and integrity UI string includes a file name.
- Manual: MapleStory with valid exe — check → up to date → 嘗試更新 shows file names while verifying; check → update available → only 「更新」.
- Manual: Classic with valid exe — check → up to date → 「完整下載」 label (not 「嘗試更新」).

## Out of scope follow-ups

- Legacy AppKit parity.
- nxdl native verify-and-skip if upstream adds it (then Classic force button could be renamed).
- Menu bar wording unification with on-screen buttons.
