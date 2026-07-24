# MapleStory Classic Integration Design

Date: 2026-07-24

## Goal

Add **楓之谷：經典版** to **Beanfun OTP (Modern)**. This game does not use Beanfun QR / OTP. The user picks `Maplestory_Classic.exe`, opens the official web login, and Beanfun OTP receives `NexonPlug://` with launch arguments, then starts the client via:

```text
open -n '/path/to/Maplestory_Classic.exe' --args <passarg…>
```

(Default handler for `.exe` is expected to be Cyder, same as other Modern launch paths.)

## Non-Goals

- Do not implement Classic in **Beanfun OTP Legacy** in this iteration (see Follow-up).
- Do not use MapleStory Launcher OEM Wine as the default launch path (OEM `advapi32` lacks `EventWriteEx`; Unity IL2CPP fails). Document Cyder / newer Wine as the workable path if needed for ops notes only.
- Do not change QR / Beanfun protocol for other games.
- Do not require the diagnostic `NXL Interceptor` app at runtime (it may remain for debugging).
- Do not add Classic to advanced-mode Nexon Wine command builder in this iteration unless it falls out naturally; launch is `open` only.

## Decisions

| Topic | Decision |
| --- | --- |
| Product track | Modern only (macOS 13+) |
| Auth | Web login only — no QR, no Beanfun OTP fetch |
| URL scheme | Register `NexonPlug` on Beanfun OTP |
| Classic match | `game` query param gameCode (substring before `@`) equals `2982` |
| Other Plug games | Forward full original URL to official `NexonPlug.app` |
| Missing exe | Immediate file picker; after selection, launch with **this** URL’s `passarg` |
| Launch | `/usr/bin/open` `-n` executable `--args` + split `passarg` tokens |
| Default scheme handler | Prefer in-app one-shot `LSSetDefaultHandlerForURLScheme` for `NexonPlug` → Beanfun OTP bundle id, with copy that other games still forward to official Plug; document restore to `com.nexon.plug` |
| Legacy | Explicit follow-up (same product behavior later) |

## Background (verified)

Captured web launch shape:

```text
nexonplug://?game=2982@2141&passarg=4554314%20sess…%202373%20944
```

| Piece | Meaning |
| --- | --- |
| `game=2982@2141` | gameCode `2982` = 新楓之谷：經典版; `2141` = obdTag |
| `passarg` | Whitespace-separated argv for `Maplestory_Classic.exe` (`command_line_info` = `%ARG%` in Nexon game-info) |

Official Plug lives at:

`/Library/Application Support/Nexon/Plug/NexonPlug.app`  
Bundle id: `com.nexon.plug`

Web login:

`https://maplestoryclassic.beanfun.com/Main`

## Game definition

| Field | Value |
| --- | --- |
| Display name | 楓之谷：經典版 |
| `id` | `maplestory-classic` |
| Executable name | `Maplestory_Classic.exe` |
| Login URL | `https://maplestoryclassic.beanfun.com/Main` |
| Beanfun `serviceCode` / QR | Not used |
| Image | Add a tile image under `Resources/GameImages/` (name TBD in implementation; placeholder OK if asset pending) |

Represent Classic as a `GameDefinition` with a new flow kind (e.g. `webNexonPlug`) distinct from Beanfun QR games, so UI and URL handling never enter the QR / OTP path for this title.

## UI (Modern)

From the games list, selecting Classic opens a **dedicated screen** (not QR):

1. Remembered / choosable path to `Maplestory_Classic.exe` (same UserDefaults pattern as other games’ executable paths).
2. Primary action: **開啟登入網頁** → `NSWorkspace.shared.open(loginURL)`.
3. Short Traditional Chinese copy: after web login, the site opens `NexonPlug://…`; this app handles Classic and launches the client.
4. Optional: button or checkbox-style control to **將 NexonPlug 設為由 Beanfun OTP 處理** (calls `LSSetDefaultHandlerForURLScheme`).
5. Status line for last launch / errors (path missing, forward failure, `open` non-zero).

No account list, no OTP countdown, no “取得 QR Code” for this game.

Menus: Classic appears in the existing「遊戲」menu like other titles; choosing it switches to the Classic screen.

## URL handling

### Registration

`Resources/Info.plist` `CFBundleURLTypes` includes scheme `NexonPlug` (match official casing). Keep Beanfun OTP bundle id `local.ogom.beanfunotp`.

### Receive

Handle opens via AppKit / SwiftUI URL lifecycle (`application(_:open:)` and/or `onOpenURL`), including cold start.

### Parse

From the URL query:

- `game` — required for routing; split on first `@` → `gameCode` / optional `obdTag`.
- `passarg` — percent-decoded; split on ASCII whitespace into `[String]` argv (empty tokens dropped).

Invalid Classic URL (missing `passarg` when `gameCode == 2982`): show alert / status; do not launch.

### Route

```text
NexonPlug URL
    │
    ├─ gameCode == "2982" ──► Classic launch path
    │
    └─ otherwise ──► open official NexonPlug.app with the same URL
                     (e.g. open -a "…/NexonPlug.app" "<absoluteString>")
```

If official Plug is missing when forwarding: clear error asking the user to install Nexon Plug (or restore default handler).

### Classic launch path

1. Resolve stored executable path for `maplestory-classic`.
2. If missing / invalid: present `.exe` file picker immediately; on cancel, keep pending URL args only until cancel (drop pending on cancel); on success, save path then continue.
3. `Process`: `/usr/bin/open` with arguments  
   `["-n", executablePath, "--args"] + passargTokens`
4. On success: status「已透過 Cyder 啟動楓之谷：經典版」(same wording family as other games); switch UI to Classic screen if needed.
5. Do not require a prior “開啟登入網頁” click in the same session if a URL arrives while the app is already the handler.

### Pending args

When the picker is shown because of an incoming URL, retain that URL’s `passarg` tokens until launch succeeds or the user cancels the picker.

## Default handler UX

- First-run or Classic screen: explain that macOS must deliver `NexonPlug://` to Beanfun OTP.
- Prefer offering an explicit button that sets default handler to `local.ogom.beanfunotp`.
- Document restore:

```swift
LSSetDefaultHandlerForURLScheme("NexonPlug" as NSString, "com.nexon.plug" as NSString)
```

- Only one app can be the default; Legacy (later) will have a different bundle id and must not be assumed concurrent.

## Data flow

```text
User selects 楓之谷：經典版
  → (optional) choose Maplestory_Classic.exe
  → open https://maplestoryclassic.beanfun.com/Main
  → user logs in on web
  → browser opens nexonplug://?game=2982@…&passarg=…
  → Launch Services → Beanfun OTP
  → parse; if 2982: open -n <exe> --args <tokens>
       else: open official NexonPlug.app with full URL
```

## Error handling

| Condition | Behavior |
| --- | --- |
| Classic URL, no exe, user cancels picker | Status: 已取消；不啟動；discard pending passarg |
| Classic URL, exe missing after save race | Error with path |
| `open` non-zero | Surface stderr / exit code like existing `launchGame()` |
| Forward target missing | Error: 找不到 NexonPlug.app |
| Non-2982 URL while we are handler | Forward; on forward failure, show error |

## Testing notes

- Unit-test pure parsing: `game` / `passarg` decode and split (including `%20` and `+` if present).
- Manual: set handler → `open 'nexonplug://?game=2982@2141&passarg=a%20b%20c'` with a stub or real exe.
- Manual: `open 'nexonplug://?game=9999@1&passarg=x'` should open official Plug (or error if absent).
- Manual: Classic UI opens login URL in default browser.

## Success criteria

- Games list includes 楓之谷：經典版; selecting it shows path + web login UI, not QR.
- With Beanfun OTP as `NexonPlug` handler, a real or synthetic `2982` URL launches via `open -n … --args …`.
- Non-2982 `NexonPlug` URLs are forwarded to official Plug when installed.
- Other games’ QR flows unchanged.
- Legacy app unchanged in this iteration.

## Follow-up

### Legacy Classic (explicit next design / plan)

Port the same product behavior to `Beanfun OTP Legacy.app`:

- Games list entry, path picker, open login URL, register `NexonPlug`, route `2982` vs forward, pending passarg + picker.
- Bundle id `local.ogom.beanfunotp.legacy` — user chooses which app owns the default handler.
- Still no QR for Classic; still no expanding Legacy to Cyder-launch all Beanfun QR games.

### Optional later

- Advanced-mode pasteable Cyder Wine 11 command for Classic (separate from OEM Launcher Wine).
- Richer status when session/`passarg` rejected by the game client.
- Thumbnail asset polish for Classic tile.
