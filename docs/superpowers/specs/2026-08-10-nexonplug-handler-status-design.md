# NexonPlug Handler Status UI Design

Date: 2026-08-10

## Goal

On the Classic screen, **quickly reflect** whether `NexonPlug` / `nexonplug://` is already the default URL handler for **this** Beanfun OTP app:

- **Not bound to this app** → show the existing claim button.
- **Already bound to this app** → show static, non-interactive Traditional Chinese copy (no button).

Applies to **Modern** and **Legacy**.

## Background

Today both tracks always show 「將 NexonPlug 設為由 Beanfun OTP 處理」, which calls `LSSetDefaultHandlerForURLScheme` with:

| Track | Bundle ID |
| --- | --- |
| Modern | `local.ogom.beanfunotp` |
| Legacy | `local.ogom.beanfunotp.legacy` |

There is no read of the current default handler, so users who already claimed still see a claim control.

## Non-Goals

- Refresh on app activate / foreground, timers, or Launch Services change notifications.
- Treating the **other** OTP track’s bundle ID as “already bound” (Modern ≠ Legacy).
- Changing scheme registration, URL routing, Classic launch, or forward-to-official-Plug behavior.
- A control to restore `com.nexon.plug` (already documented elsewhere).

## Decisions

| Topic | Decision |
| --- | --- |
| Detection API | `LSCopyDefaultHandlerForURLScheme("NexonPlug")` compared to **this** app’s bundle ID |
| Scheme string | Same as claim path: `NexonPlug` |
| Unbound UI | Existing button: 「將 NexonPlug 設為由 Beanfun OTP 處理」 |
| Bound UI | Static text: 「NexonPlug 已由 Beanfun OTP 處理」 (not a button; not disabled control) |
| When to refresh | Entering Classic screen; again after successful `claim` |
| Failed claim | Keep button; existing error message unchanged |
| Other app is handler | Treat as unbound → show claim button |

## Behavior

```text
enter Classic screen
  → refreshNexonPlugHandlerStatus()
       LSCopyDefaultHandlerForURLScheme("NexonPlug")
       isBound = (handler Bundle ID == this app Bundle ID)

isBound == false → Button (claim)
isBound == true  → Text (static)

claim success → refresh (expect isBound == true) + existing success statusMessage
claim failure → leave isBound unchanged + existing errorMessage
```

## Touch points

### Modern

- `Sources/AppModel.swift` — published `isNexonPlugHandler` (or equivalent); `refreshNexonPlugHandlerStatus()`; call refresh when presenting Classic; update `claimNexonPlugHandler()` on success.
- `Sources/ContentView.swift` — in `classicView`, switch Button vs Text from model flag.

### Legacy

- `Legacy/Sources/AppController.swift` — same query/compare against `local.ogom.beanfunotp.legacy`; on Classic layout refresh / claim success, show either `claimNexonPlugButton` or a static label with 「NexonPlug 已由 Beanfun OTP 處理」.

## Testing

- Unit (optional / if cheap): pure helper that maps optional handler Bundle ID + self Bundle ID → bound bool (nil / other / self).
- Manual Modern: unset handler → button; claim → static text without relaunch; with handler already self → static on enter Classic.
- Manual Legacy: same with Legacy bundle ID; confirm Modern-as-handler still shows Legacy’s claim button.

## Out of scope follow-ups

- Foreground / system-settings re-check.
- One-click restore to official `com.nexon.plug`.
