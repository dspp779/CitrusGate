# NXL Interceptor Design

Date: 2026-07-24

## Goal

Ship a separate diagnostic companion app, `NXL Interceptor.app`, in the same BeanfunOTP repository. It registers the `nxl` URL scheme so that when a web page (or other client) opens `nxl:…` — as used for 楓之谷:經典版 / Nexon Launcher — the interceptor receives the call and shows the **full URL string** in a system alert. After the user dismisses the alert, the app quits.

This is a temporary investigation tool. Once the URL shape is confirmed, a later change may teach Beanfun OTP to handle `nxl` and launch MapleStory Classic; that integration is **out of scope** for this design.

## Non-Goals

- Do not parse, rewrite, or forward the URL to a real Nexon Launcher.
- Do not launch any game or Wine process.
- Do not stay resident or append to a log file.
- Do not change Beanfun OTP (Modern or Legacy) behavior or URL registration.
- Do not add a settings UI, copy button, or history list.

## Decisions

| Topic | Decision |
| --- | --- |
| Packaging | Independent app in-repo; `build-nxl-interceptor.sh` → `dist/NXL Interceptor.app` |
| Architecture | Minimal AppKit Swift stub only (no embedded shell script) |
| CPU / binary | arm64 only (local diagnostic machine; no universal / Intel build) |
| UI | `NSAlert` with the full URL (`url.absoluteString`) |
| Process lifetime | Show alert → user clicks OK → `NSApp.terminate(nil)` |
| Cold open (no URL) | Alert explaining the app waits for `nxl://` calls → OK → quit |
| Scheme | `nxl` via `CFBundleURLTypes` / `CFBundleURLSchemes` |
| Bundle ID | `local.ogom.nxlinterceptor` (distinct from Beanfun OTP) |

## Why a stub is required

macOS delivers custom URL scheme opens via Launch Services as an **Apple Event (GetURL)**, not as a reliable argv to a shell `CFBundleExecutable`. A bare `.sh` cannot intercept `nxl:` reliably. A thin AppKit executable that implements `application(_:open:)` (or the equivalent delegate path) is required, plus an `.app` bundle whose `Info.plist` declares the scheme.

## Data flow

```text
Web page / open "nxl://…"
  ↓
Launch Services → NXL Interceptor.app
  ↓
application(_:open:) receives [URL]
  ↓
NSAlert informationalText = firstURL.absoluteString
  ↓
User dismisses → terminate
```

If multiple URLs arrive in one open call, show only the first URL’s absolute string (diagnostic use; real launcher traffic is expected to be one URL per launch).

## Layout

```text
Interceptor/
  Sources/main.swift
  Resources/Info.plist
build-nxl-interceptor.sh
dist/NXL Interceptor.app   # build output
```

`main.swift` responsibilities:

1. Create `NSApplication` and set a delegate.
2. On URL open: present `NSAlert` with the full absolute string; on dismiss, terminate.
3. On finish launching with no pending URL: present a short “waiting for nxl://” alert; on dismiss, terminate.
4. Keep the implementation as small as practical (single file).

`Info.plist` must include at least:

- `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleName` / display name for **NXL Interceptor**
- `LSMinimumSystemVersion` aligned with Modern Beanfun OTP (`13.0`) unless build script chooses otherwise for simplicity
- `CFBundleURLTypes` with scheme `nxl` and a human-readable URL name (e.g. `Nexon Launcher` or `NXL Interceptor`)

## Build

`build-nxl-interceptor.sh` mirrors the spirit of `build.sh` but stays minimal:

- Compile `Interceptor/Sources/*.swift` with `swiftc` for **arm64 only** (`-target arm64-apple-macosx13.0`), sufficient for local diagnostic use on this machine
- Assemble `dist/NXL Interceptor.app/Contents/{MacOS,Info.plist}`
- No app icon required for this diagnostic tool
- No release signing / notarization required unless later requested
- No Intel / universal binary for this tool

## Launch Services conflict

If a real Nexon Launcher (or another app) already claims `nxl`, Launch Services may not deliver URLs to this interceptor after install. Verification steps:

1. Build and open `dist/NXL Interceptor.app` once (registers the bundle).
2. Run `open "nxl://test-from-terminal"`.
3. Expect an alert showing `nxl://test-from-terminal`.
4. If another app opens instead, temporarily relocate that app or re-register this interceptor as the handler before capturing production web launches.

Document this caveat briefly in the implementation plan / README note only if the user asks for README changes; default is not to expand the main Beanfun OTP README unless requested.

## Error handling

| Condition | Behavior |
| --- | --- |
| One or more `nxl` URLs | Alert with first URL absolute string; quit after OK |
| App opened with no URL | Alert: this app intercepts `nxl://` links; quit after OK |
| Malformed URL object | Should not occur from Launch Services; if absoluteString is empty, alert with a fixed fallback message and quit |

## Success criteria

- `./build-nxl-interceptor.sh` produces a runnable `dist/NXL Interceptor.app`
- `open "nxl://hello?foo=bar"` (with this app as handler) shows an alert containing that full string
- Dismissing the alert exits the process
- Beanfun OTP sources and build scripts remain unchanged

## Follow-up (explicitly later)

After capturing real Classic launch URLs, decide whether Beanfun OTP should:

- register `nxl` itself, and/or
- parse parameters and start MapleStory Classic via Cyder / Wine / other path

That work needs a separate design; this interceptor only reveals the payload.
