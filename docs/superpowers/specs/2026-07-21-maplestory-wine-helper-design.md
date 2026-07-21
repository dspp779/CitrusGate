# MapleStory Wine Helper Design

Date: 2026-07-21

## Goal

Ship a separate companion app, `MapleStory Wine Helper.app`, in the same BeanfunOTP repository. After the user sets that app as the “Open with” handler for their Taiwan `MapleStory.exe` (Finder → Get Info), BeanfunOTP’s existing `open -n <MapleStory.exe> --args …` launch path starts the game through Nexon’s US MapleStory Launcher Wine (CrossOver OEM), matching `docs/macos-player-guide.md` step 5.

## Non-Goals

- Do not change BeanfunOTP `launchGame()` / `open -n` behavior.
- Do not steal the system-wide default app for all `.exe` files; the user assigns the helper only for their MapleStory executable via Get Info.
- Do not add a settings UI for Wine path, bottle name, or locale.
- Do not support non–MapleStory games in this helper.
- Do not replace advanced-mode “copy Wine command” in BeanfunOTP; that remains a separate Terminal paste path.

## Decisions

| Topic | Decision |
| --- | --- |
| Packaging | Independent app in-repo; own `build-helper.sh` → `dist/MapleStory Wine Helper.app` |
| Architecture | Thin stub (Swift preferred) + embedded `launch-maplestory.sh` |
| UI | None on success; failures use a system alert (`osascript` from the script; `NSAlert` in the stub only if the script cannot be started) |
| Process lifetime | Stub waits for the script; script runs `wine` in the foreground (same as the player-guide Terminal flow) and exits when that `wine` process exits |
| Wine defaults | Fixed to player-guide values (not user-editable) |
| OTP / launch args | Passed through from `open --args`; helper does not fetch OTP |

## Why a stub is required

macOS does not pass the opened document path as argv to a shell `CFBundleExecutable`. Finder / Launch Services send an **open document** Apple Event. `open -n file --args …` puts `--args` on argv, but the `.exe` path still arrives via Apple Event.

Therefore:

| Layer | Role |
| --- | --- |
| Thin stub | Receive document URL(s) + argv game arguments; invoke the embedded script |
| `launch-maplestory.sh` | Locate Wine, set environment, run `wine`, surface failures |

A pure-bash main executable cannot reliably implement “Open with” for this flow.

## Data flow

```text
BeanfunOTP
  → open -n '/path/MapleStory.exe' --args <host> <port> BeanFun <ID> <OTP>
       ↓
Launch Services → MapleStory Wine Helper.app (stub)
       ↓
Contents/Resources/launch-maplestory.sh \
  '/path/MapleStory.exe' <host> <port> BeanFun <ID> <OTP>
       ↓
wine --bottle maplestory --workdir '<dir>' '<exe>' <args…>
       ↓
success: no UI  |  failure: system alert, then exit
```

### Script invocation contract

```text
launch-maplestory.sh <absolute-path-to-MapleStory.exe> [game-arguments…]
```

Rules:

- The first argument must be an existing `.exe` file path.
- If Launch Services delivers multiple documents, the stub uses the first `.exe` only and ignores the rest.
- Remaining arguments are forwarded unchanged to `wine` after the executable path.
- `--workdir` is always the parent directory of that `.exe`.
- The helper does not invent host / port / provider / account / OTP; BeanfunOTP (or the user) supplies them via `--args`.

## Wine discovery and environment

Align with `docs/macos-player-guide.md`:

| Setting | Value |
| --- | --- |
| `CX_ROOT` | `/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna` |
| Wine on `PATH` | `$CX_ROOT/MapleStory Launcher` (must contain `wine`) |
| Bottle | `maplestory` |
| Locale | `LANG`, `LC_ALL`, `LC_CTYPE` = `zh_TW.UTF-8` |

Command shape (after exports):

```bash
wine --bottle maplestory \
  --workdir '<parent-of-exe>' \
  '<path-to-MapleStory.exe>' \
  <game-arguments…>
```

Do not use bottle `default` or the older `…/bin/wine --wait-children --enable-alt-loader macdrv` form.

If Launcher, `wine`, or the required inputs are missing, fail with a clear alert that includes the expected path where helpful.

## Error handling

| Condition | Behavior |
| --- | --- |
| No `.exe` path (e.g. helper double-clicked alone) | Alert: open via Get Info / BeanfunOTP with `MapleStory.exe`; exit |
| `.exe` missing or not a file | Alert: game executable not found; exit |
| Launcher / `wine` not found | Alert with expected SharedSupport path; exit |
| `wine` non-zero exit | Alert with exit status (and a short stderr snippet if practical); exit |
| Success | No UI |

Process lifetime: no visible window. The stub blocks until `launch-maplestory.sh` returns; the script runs `wine` in the foreground (matching the player guide). When the user quits the game (or `wine` exits), the helper process exits. Do not background-detach in this iteration.

## App bundle layout

```text
MapleStory Wine Helper.app/
  Contents/
    Info.plist          # CFBundleDocumentTypes for .exe so it appears in Open with
    MacOS/
      MapleStoryWineHelper   # thin stub
    Resources/
      launch-maplestory.sh
      (optional AppIcon.icns)
```

Repo layout (suggested):

```text
Helper/
  Sources/…             # stub
  Info.plist
  Resources/launch-maplestory.sh
build-helper.sh
```

Signing: ad-hoc `codesign --force --sign -`, same approach as Beanfun OTP.

## Integration with BeanfunOTP

- No code change required to `launchGame()` for the happy path once the user has set Open with on that `MapleStory.exe`.
- Documentation updates only (README + `docs/macos-player-guide.md`):
  - Build/install Helper
  - Finder → Get Info on `MapleStory.exe` → Open with → MapleStory Wine Helper (optionally Change All only if the user accepts affecting that file type association)
  - Then use BeanfunOTP launch as today

Cyder remains relevant for other games; this helper is MapleStory-specific.

## Testing / verification

1. **Stub / script contract**: invoke the script with a missing exe / missing wine path and confirm alerts (or non-zero exit + message) without needing a full game install.
2. **Manual integration** (machine with US MapleStory Launcher + TW client):  
   `open -n '/path/to/MapleStory.exe' --args tw.login.maplestory.beanfun.com 8484 BeanFun <ID> <OTP>`  
   with Helper assigned as Open with; confirm Wine starts the client.
3. **Regression**: BeanfunOTP unit tests and Cyder-oriented launch for other games unchanged.

## Success criteria

- User can assign Helper as Open with for their `MapleStory.exe`.
- BeanfunOTP `open -n` with OTP args launches via Nexon Launcher Wine / bottle `maplestory` / `zh_TW.UTF-8`.
- Failures surface a system alert; success is silent.
- Helper builds independently via `build-helper.sh` into `dist/`.
