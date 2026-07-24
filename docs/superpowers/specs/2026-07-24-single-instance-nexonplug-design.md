# Single-Instance + Cold-Start NexonPlug Quit Design

Date: 2026-07-24

## Goal

1. **Single instance:** Beanfun OTP (Modern) never runs as a second process / second main window when the browser opens `nexonplug://` (or `NexonPlug://`) while the app is already open. The existing instance receives and handles the URL.
2. **Cold-start quit:** If the app was **not** already running and was launched by that URL, then after a **successful** Classic Cyder/`open` launch, quit Beanfun OTP automatically.
3. **Cold-start failure stays open:** Missing exe, cancelled file picker, or failed `open` keep the app open with existing error / picker UX so the user can fix the path and retry. A later success in that same cold-start session still quits.

## Non-Goals

- Do not change Legacy.
- Do not auto-quit when the user launched the app interactively (Dock / Finder / Spotlight) and later receives a NexonPlug URL (warm handoff).
- Do not auto-quit after Cyder / Wine launches of **新楓之谷** or other non–URL-driven flows.
- Do not redesign Classic UI beyond what single-window + quit flag require.
- Non-Classic NexonPlug URLs continue to forward to official NexonPlug; cold-start auto-quit after forward is **out of scope** for this iteration (leave app open after forward unless we later decide otherwise).

## Decisions

| Topic | Decision |
| --- | --- |
| Approach | **A:** `LSMultipleInstancesProhibited` + single window scene |
| Second process | Prohibited via Info.plist |
| Second window | Avoid by replacing `WindowGroup` with a single `Window` (macOS 13+) |
| Warm URL while running | Deliver to existing instance; keep window; no quit |
| Cold-start success | Quit after Classic `open` terminates with status 0 |
| Cold-start failure | Stay open; show error / allow re-pick; keep quit-after-success flag for retry |
| Scope | Modern only |

## Behavior matrix

| Situation | Process / window | After Classic `open` |
| --- | --- | --- |
| App already running + browser opens NexonPlug | Same process, same window | Stay open (warm) |
| Cold start via NexonPlug + Classic + `open` OK | One process, one window | `NSApp.terminate` |
| Cold start + missing / invalid exe, cancel picker, or `open` ≠ 0 | Stay | Stay open with error / retry |
| User opens app normally (no URL) | Normal | Never auto-quit from this feature |
| Cold start + non-Classic → forward to official Plug | Single instance | Stay open (out of scope to quit) |

## Implementation sketch

### 1. Info.plist

Add:

```xml
<key>LSMultipleInstancesProhibited</key>
<true/>
```

Launch Services then activates the running app and delivers the URL instead of spawning another copy.

### 2. Single window

In `BeanfunOTPApp`, replace `WindowGroup` with a single `Window` (fixed id/title), keeping current size / style / commands. Goal: URL open events must not create an additional SwiftUI window.

Retain existing `AppDelegate` URL buffering + `handleOpenedURL` dedupe.

### 3. Cold-start flag

In `AppDelegate` / `AppModel`:

- Track whether the current session was **URL-cold-started**.
- Practical rule: if `application(_:open:)` (or pending buffered URLs) arrives **before** the app has finished its first interactive activation window (e.g. before/during launch, before `applicationDidBecomeActive` has completed for a user-initiated launch), set `quitAfterSuccessfulClassicLaunch = true`.
- Warm delivery (app already running, `open:` after launch settled) must **not** set the flag.

Exact signal (recommended):

- `AppDelegate` sets `isLaunching = true` until the first `applicationDidBecomeActive` (or a deferred main-queue mark after `didFinishLaunching`).
- Any NexonPlug URL handled while `isLaunching == true` (including flushed `pendingURLs`) sets `quitAfterSuccessfulClassicLaunch`.
- URLs handled after launch completes leave the flag unchanged (false for warm).

### 4. Quit hook

In `launchClassic`’s success path (`terminationStatus == 0`):

- If `quitAfterSuccessfulClassicLaunch`, call `NSApp.terminate(nil)` (after updating status/log as today).
- Do **not** quit on failure paths, cancelled picker, or invalid passarg.

If the user cancels the picker or launch fails, leave the flag **true** so a successful retry still quits (still a cold-start session). Clearing the flag only on interactive “I’m using the app now” is optional YAGNI for v1.

## Testing (manual)

1. App closed → Classic web login → one Beanfun OTP appears → game starts → app quits.
2. App closed → Classic URL but no exe → picker / error → app stays → pick exe → launch OK → app quits.
3. App already open (e.g. on 新楓之谷) → Classic web login → **no** second window/process → Classic handled in existing UI → app **does not** quit.
4. Forward non-Classic NexonPlug while running → still single instance; no second window.

## Risks

- `Window` vs `WindowGroup` API differences on macOS 13 — verify build target (already 13.0).
- Timing of `application(_:open:)` vs `didBecomeActive` on cold start must be validated manually; if Launch Services delivers URL slightly after become-active, widen the “launching” window slightly (e.g. mark launching false only after a short deferred settle) without treating warm URLs as cold.

## Spec coverage checklist

| Requirement | Covered |
| --- | --- |
| Single process | `LSMultipleInstancesProhibited` |
| Single window | `Window` instead of `WindowGroup` |
| Quit only on cold-start success | Flag + Classic `open` status 0 |
| Failure stays open | No terminate on error / cancel |
| Warm URL no quit | Flag not set after launch settled |
| Legacy untouched | Non-goal |
