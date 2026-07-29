# Classic `open` Prefer Cyder (`-b`) Design

Date: 2026-07-29

## Goal

For **楓之谷：經典版** (`NexonPlug://` → Beanfun OTP → `open` EXE), prefer launching via **Cyder 正式版** by passing `open -b local.cyder.app`, instead of relying on the user’s Finder “Open with” default for `.exe`.

When Cyder is not installed, show a **confirmation dialog** explaining that only Cyder reliably forwards `--args`, then allow the user to cancel or continue with the system default application.

Apply to **Modern and Legacy**.

## Background

Classic launch currently builds:

```text
open -n '<Maplestory_Classic.exe>' --args <passarg…>
```

via `NexonPlugURLParser.classicOpenArguments` with default `OpenLauncher.defaultApplication` (no `-b`). Many users leave `.exe` associated with CrossOver, Parallels, The Unarchiver, etc. Those handlers typically do **not** accept and forward `--args` the way Cyder does, so login fails even though Beanfun OTP received a valid `NexonPlug` URL.

The project already supports:

```text
open -n -b local.cyder.app '<exe>' --args …
```

(`OpenLauncher.cyder` / `openApplicationArguments`). Other games use this for 「以 Cyder 開啟」. Classic should use the same path by default.

Classic must use **Cyder 正式版** (`local.cyder.app`), **not** Cyder MapleStory OEM (`local.cyder.maplestory-oem25`), which lacks `EventWriteEx` needed by Classic.

## Non-Goals

- Do not change `NexonPlug` scheme claiming, forwarding of non-2982 URLs, or single-instance / cold-start quit behavior.
- Do not force Cyder for non-Classic Beanfun QR games’ default 「開啟」 button (those already expose an explicit Cyder action).
- Do not auto-install Cyder or download it.
- Do not treat “wrong Cyder variant installed” (OEM only) as a separate first-class check in this iteration; detection is presence of `local.cyder.app` only.
- Do not change MapleStory Launcher Wine launch paths.

## Decisions

| Topic | Decision |
| --- | --- |
| Tracks | Modern + Legacy |
| Preferred launcher | `OpenLauncher.cyder` → `-b local.cyder.app` |
| Detection | Resolve whether an app with bundle id `local.cyder.app` is installed (Launch Services / `NSWorkspace`) |
| Cyder present | Launch with `classicOpenArguments(..., launcher: .cyder)` |
| Cyder absent | Modal confirmation; do not call `open` until the user chooses |
| Confirm — cancel | Abort Classic launch; status may note cancelled |
| Confirm — continue | Launch with `OpenLauncher.defaultApplication` (existing behavior) |
| OEM bundle | Never use `local.cyder.maplestory-oem25` for Classic |
| Docs | Soften “must set Open with to Cyder”; state App prefers Cyder via `-b` |

## Flow

```text
NexonPlug:// (2982) + passarg
  → validate Maplestory_Classic.exe path (existing)
  → is Cyder (local.cyder.app) installed?
        yes → launcher = .cyder
        no  → alert (取消 | 仍要開啟)
              → 取消: stop (do not clear quarantine / do not open)
              → 仍要開啟: launcher = .defaultApplication
  → (only after launcher chosen) clear quarantine if needed (Modern existing)
  → open -n [ -b local.cyder.app ] <exe> --args <tokens>
```

## UI copy (Traditional Chinese)

Suggested alert:

| Element | Text |
| --- | --- |
| Title | 未偵測到 Cyder |
| Body | 經典版需透過 Cyder 才能可靠傳遞執行參數。請安裝 Cyder 正式版後再試。若仍要以系統預設的「打開方式」開啟，參數可能無法正確傳遞，遊戲可能無法登入。 |
| Cancel | 取消 |
| Continue | 仍要開啟 |

Keep existing success status 「已開啟新楓之谷：經典版」. Append log should note whether launch used `-b local.cyder.app` or default application. On cancel, set status to 「已取消」(or Legacy equivalent) and do not quit on cold-start.

## Implementation sketch

1. Add a small helper (shared pattern in Modern + Legacy, or duplicated thin wrappers) e.g. `CyderInstallation.isOfficialCyderInstalled` using bundle id `OpenLauncher.cyderBundleIdentifier`.
2. Change `launchClassic` in `Sources/AppModel.swift` and `Legacy/Sources/AppController.swift` to:
   - Branch on detection.
   - Present confirm UI (SwiftUI alert / `NSAlert`).
   - Pass `launcher: .cyder` or `.defaultApplication` into `classicOpenArguments`.
3. Update unit tests for `classicOpenArguments` with `launcher: .cyder` (expect `-n`, `-b`, `local.cyder.app`, path, `--args`, tokens).
4. Update `docs/macos-player-guide-classic.md` (and README Classic blurb if it still mandates Finder Open with as required).

Legacy (10.12): use APIs available on the deployment target for bundle-id lookup (e.g. deprecated `NSWorkspace` path-for-bundle-id if newer APIs are unavailable).

## Testing

| Case | Expected |
| --- | --- |
| Cyder installed | `open` argv includes `-b` `local.cyder.app` |
| Cyder missing + 取消 | No `open`; launch aborted |
| Cyder missing + 仍要開啟 | `open` argv has no `-b`; uses default handler |
| Unit: `classicOpenArguments` + `.cyder` | Matches `OpenLaunchArguments.build` with Cyder flags |
| Non-2982 forward | Unchanged |

Manual: with Cyder installed and `.exe` default set to another app, Classic URL launch still runs under Cyder and receives args.

## Follow-up (out of scope)

- Detect OEM-only install and warn that Classic needs the official Cyder build.
- Deep-link or button to Cyder release page from the alert.
- Persist “don’t warn again” for default-app fallback.
