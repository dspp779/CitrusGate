# Beanfun OTP Legacy（AppKit / macOS 10.12）Design

Date: 2026-07-22

## Goal

Ship a second, stripped-down macOS app so users on older systems (down to **macOS 10.12 Sierra**) can still complete Beanfun QR login and obtain an OTP. Keep the existing SwiftUI app as the full-featured track for **macOS 13+**.

## Non-Goals

- Feature parity with Modern (no game launch, no `.exe` picker, no advanced mode, no auto-refresh OTP, no launch-command builder, no Debug Log UI).
- Single installer that auto-selects Modern vs Legacy.
- Shared framework / package in the first iteration (copy-then-adapt is intentional).
- Menu-bar-only or CLI-only Legacy shell.
- Supporting below 10.12 (toolchain can go near 10.10 for trivial AppKit, but HTTPS/TLS risk rises with little UI benefit).

## Decisions

| Topic | Decision |
| --- | --- |
| Approach | Two apps in one repo (Approach 1) |
| Modern floor | macOS 13.0, Universal (arm64 + x86_64), unchanged product |
| Legacy floor | macOS 10.12, **x86_64 only** |
| Legacy UI | Pure AppKit |
| Legacy scope | Select game → QR login → select account → show / copy OTP (and account ID) |
| Protocol code | Copy from Modern into `Legacy/Sources`; rewrite networking to URLSession completions |
| Launch / Cyder / Wine | Not in Legacy |
| Distribution | Two separate `.app` (or zips); README documents which to download |

## Product Split

| | Modern | Legacy |
| --- | --- | --- |
| App name | `Beanfun OTP.app` | `Beanfun OTP Legacy.app` |
| Bundle ID | `local.ogom.beanfunotp` | `local.ogom.beanfunotp.legacy` |
| Minimum OS | 13.0 | 10.12 |
| Architectures | arm64 + x86_64 | x86_64 |
| UI | SwiftUI (current) | AppKit |
| Games | Existing 9 services | Same 9 (login/OTP only) |

Users on 10.12–12 use Legacy. Users on 13+ use Modern. Legacy may run on newer Intel Macs but is not the recommended primary path there.

## Repository Layout

```
BeanfunOTP/
  Sources/                 # Modern (unchanged track)
  Resources/               # Modern
  Tests/                   # Existing core tests (DES / models)
  Legacy/
    Sources/               # AppKit UI + completion-based Beanfun client
    Resources/
      Info.plist           # LSMinimumSystemVersion = 10.12
      AppIcon / GameImages # copy or build-time reference from Resources/
  build.sh                 # Modern only (current behavior)
  build-legacy.sh          # New: x86_64-apple-macosx10.12 → dist/Beanfun OTP Legacy.app
  dist/
    Beanfun OTP.app
    Beanfun OTP Legacy.app
```

## Build

- Modern: keep `./build.sh` (SwiftUI, macosx13.0, lipo Universal, ad-hoc codesign).
- Legacy: add `./build-legacy.sh`:
  - Target `x86_64-apple-macosx10.12`
  - Embed required Swift runtime dylibs under `Contents/Frameworks` and configure `@rpath` when the OS does not provide them
  - Ad-hoc codesign consistent with Modern
- Version strings may increment independently; document Legacy as a feature subset.

## Legacy UI Flow

Single window, linear flow:

1. **Game list** — name list (`NSTableView` or buttons); thumbnails optional (text-first OK for v1).
2. **QR** — image, status / countdown, regenerate.
3. **Accounts** — list; multi-account requires selection + 「取得 OTP」; single account may auto-fetch.
4. **OTP** — large OTP text, 「複製 OTP」, 「複製帳號」, path back to games / re-login.

Details:

- Errors via `NSAlert`
- Status label for current step
- Quit when last window closes (same idea as Modern)
- Optional: remember last selected game in `UserDefaults`
- Timers via `Timer` (no `Task.sleep` / Duration APIs)
- Native AppKit look; no requirement to match Modern visuals

## Protocol Strategy

- Port login / poll / account list / OTP fetch behavior from current `BeanfunClient`.
- Port game definitions needed for service codes / account flows (launch helpers unused).
- Port DES / parsing helpers as needed for OTP.
- Replace `async`/`await` with callback- or delegate-style URLSession.
- Cookie handling, redirects, and form fields should match Modern behavior as closely as practical.
- When Beanfun protocol changes, update **both** Modern and Legacy until a shared core is extracted later.

## Risks

| Risk | Mitigation |
| --- | --- |
| Old macOS fails modern HTTPS (TLS / certs) | Manual test on 10.12/10.13 (or VM); if needed raise Legacy `LSMinimumSystemVersion` and document |
| Missing Swift libs on old OS | Embed libswift* in the Legacy app bundle |
| Dual client drift | Spec/README callout; keep DES/pure parsing under existing tests where possible |
| Wrong download chosen | README: ≥13 → Modern; 10.12–12 → Legacy |

## Acceptance Criteria

1. `./build.sh` still produces a working Modern `Beanfun OTP.app` for macOS 13+.
2. `./build-legacy.sh` produces `Beanfun OTP Legacy.app` with min OS **10.12** and **x86_64**.
3. Legacy can: pick game → QR login → pick account → show and copy OTP.
4. Legacy has no game launch, advanced mode, or Debug Log UI.
5. README documents both apps, OS requirements, and feature subset.

## Out of Scope (Later)

- Extracting a shared Beanfun core library
- Lowering Modern below 13
- Automatic OS-based app selection
- Bringing Cyder/`open` launch into Legacy
