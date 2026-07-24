# Standard Mode Launch UX Design

Date: 2026-07-24

## Goal

Improve **一般模式** launch UX for Beanfun OTP (Modern):

1. For **新楓之谷** only, offer two launch actions:
   - **以 Cyder 開啟** — existing `/usr/bin/open -n … --args …`
   - **以 MapleStory Launcher 開啟** — set Wine env and run MapleStory Launcher’s `wine` (not `open`)
2. After the user taps a launch button: keep the button(s) visible but **disabled**, show a nearby status (“啟動中…”, “已啟動”), then **re-enable after ~10 seconds** on success (or immediately on failure).

## Non-Goals

- Do **not** add MapleStory Launcher Wine launch for **楓之谷：經典版** (OEM Wine lacks `EventWriteEx`; Classic stays Cyder/`open` only).
- Do not change Legacy.
- Do not require changing advanced-mode layout in this iteration (advanced may keep current Cyder button + copyable Wine command; shared Wine launch helper may be reused later).
- Do not use MapleStory Launcher Wine for non–MapleStory games.

## Decisions

| Topic | Decision |
| --- | --- |
| Games with dual launch | 新楓之谷 only |
| Classic | Cyder / `open` only; same disable + status UX |
| Other Beanfun games | Single launch button; same disable + status UX |
| Cyder path | Dedicated launcher using `/usr/bin/open` |
| Wine path | Dedicated launcher: set env + exec `wine` (not `open`) |
| Wine defaults | Match player guide / `LaunchCommandBuilder`: `CX_ROOT`, `PATH`, `zh_TW.UTF-8`, bottle `maplestory`, `--workdir` = exe parent |
| Success cooldown | ~10 seconds after successful spawn, then re-enable |
| Failure | Re-enable immediately; surface error as today |
| UI (MapleStory standard) | Two buttons: 「以 Cyder 開啟」「以 MapleStory Launcher 開啟」 |

## Two launchers (separate)

Do **not** fold Wine into a single parameterized `launchGame(style:)`. Keep two clear entry points that share only small pure helpers (argv building, path checks, UI phase):

| Launcher | Mechanism |
| --- | --- |
| Cyder | `Process` → `/usr/bin/open` with `["-n", exe, "--args", …]` |
| MapleStory Launcher Wine | `Process` → Wine binary under `$CX_ROOT/MapleStory Launcher/wine`, with environment `CX_ROOT`, `PATH`, `LANG`/`LC_ALL`/`LC_CTYPE=zh_TW.UTF-8`, arguments `--bottle maplestory --workdir <dir> <exe> <game args…>` |

Wine command shape (logical):

```text
CX_ROOT=/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna
PATH=$CX_ROOT/MapleStory Launcher:$PATH
LANG=zh_TW.UTF-8 LC_ALL=zh_TW.UTF-8 LC_CTYPE=zh_TW.UTF-8

wine --bottle maplestory \
  --workdir '<parent of MapleStory.exe>' \
  '<path/to/MapleStory.exe>' \
  tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

Prefer setting `process.environment` and invoking the `wine` executable path directly (no `zsh -lc` wrapper) unless a measured issue requires a shell.

## Button / status UX (standard mode)

Replace the current pattern where a successful launch **removes** the play button and shows only a green “已啟動” label.

New pattern:

| Phase | Buttons | Nearby status |
| --- | --- | --- |
| Idle | Enabled | None (or existing secondary status) |
| Launching | All launch buttons on that screen disabled | 「啟動中…」 |
| Succeeded | Stay disabled | 「已啟動」 |
| ~10 s after success | Re-enabled | Status may clear or return to neutral |
| Failed | Re-enabled immediately | Error via existing `errorMessage` / alert |

Applies to:

- 新楓之谷: both Cyder and Launcher buttons (either press disables **both** during the cooldown)
- 經典版 and other games: their single launch control(s)

`launchedAccountID` may still be used for logging / secondary copy, but must not hide the launch buttons in standard mode.

## Data flow

### Cyder (any automatic-login game including MapleStory)

```text
User taps「以 Cyder 開啟」(or single「開啟遊戲」)
  → phase = launching
  → open -n <exe> --args <game args>
  → success → phase = launched → after 10s → idle
  → failure → idle + error
```

### MapleStory Launcher Wine (新楓之谷 only)

```text
User taps「以 MapleStory Launcher 開啟」
  → phase = launching
  → validate CX_ROOT / wine binary / exe
  → Process(wine) with env + bottle args + game args
  → success → phase = launched → after 10s → idle
  → failure (missing Launcher, wine exit on spawn, etc.) → idle + error
```

Note: “success” means the **Process was started successfully** (and, if used, `open` terminated with status 0). It does **not** mean the game finished loading or logged in. Wine may keep running after spawn; do not wait for wine exit before showing「已啟動」.

## Error cases (Wine)

| Condition | Behavior |
| --- | --- |
| MapleStory Launcher / `wine` missing | Clear Traditional Chinese error; re-enable buttons |
| Exe missing / invalid | Same as existing Cyder path |
| Process fails to start | Error + re-enable |

## Testing

- Unit-test pure Wine argv / env construction if extracted (paths with spaces, bottle, workdir, game args).
- UI / timer: manual smoke in standard mode (dual buttons, cooldown, failure path).
- Confirm Classic standard UI has no Launcher Wine button.

## Success criteria

- 新楓之谷 standard account screen shows two launch buttons with the agreed labels.
- Cyder path still uses `open`; Launcher path uses env + `wine`.
- Classic has no Launcher Wine launch option.
- After launch, buttons remain visible, disabled, with「啟動中…」/「已啟動」, then re-enable ~10 s on success.
- Other games’ QR / OTP flow unchanged aside from the button cooldown UX.
- Legacy unchanged.

## Follow-up (optional)

- Align advanced mode with dual launch buttons.
- Longer-lived “game still running” detection (out of scope).
