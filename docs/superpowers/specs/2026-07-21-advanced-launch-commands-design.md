# Advanced Mode Full Launch Commands Design

Date: 2026-07-21

## Goal

In advanced mode, show and copy a complete shell command that can be pasted into Terminal, instead of only the game argument fragment. Keep the existing Cyder/`open -n` launch button behavior unchanged. For 新楓之谷 only, also let the user choose a Nexon MapleStory Launcher Wine/Bottle command form.

## Non-Goals

- Do not change the actual 「啟動」 button / `launchGame()` behavior; it continues to use `/usr/bin/open -n`.
- Do not offer Wine commands for non–MapleStory games.
- Do not make Wine binary path, bottle name, or workdir user-editable in this iteration.
- Do not change standard mode UI.

## Current Behavior

- Advanced mode 「遊戲啟動參數」 shows `OTPResult.commandLine`, which is only the joined game arguments (for example `tw.login.maplestory.beanfun.com 8484 BeanFun <ID> <OTP>`).
- 「複製啟動參數」 copies that fragment.
- 「透過 Cyder 啟動遊戲」 runs `open -n <exe> [--args …]` via `Process`.

## Decisions

| Topic | Decision |
| --- | --- |
| Scope of display change | Advanced mode display + copy only |
| Wine availability | 新楓之谷 only |
| Defaults | Align with `docs/macos-player-guide.md`: Wine via MapleStory Launcher SharedSupport, bottle `maplestory`, locale `zh_TW.UTF-8`, `--workdir` = parent of selected `.exe` |
| Command generation | Computed live from `executablePath` + account + OTP + selected method |
| Launch button | Unchanged (`open -n`) |

## Command Formats

### `open` (all games)

Automatic-login games:

```bash
open -n '/path/to/Game.exe' --args <game arguments…>
```

Manual-login games (no verified CLI login args):

```bash
open -n '/path/to/Game.exe'
```

MapleStory example:

```bash
open -n '/path/to/MapleStory.exe' --args tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

### Wine (MapleStory only)

Match the verified manual launch form in `docs/macos-player-guide.md` (step 5): locale exports, Wine on `PATH` from MapleStory Launcher SharedSupport, bottle `maplestory`.

```bash
export CX_ROOT='/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna'
export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
export LC_CTYPE=zh_TW.UTF-8

wine --bottle maplestory --workdir '/path/to/MapleStoryFolder' '/path/to/MapleStory.exe' tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

Rules:

- Shell-quote every path (spaces and special characters).
- `--workdir` is the parent directory of the selected executable.
- `CX_ROOT`, Wine `PATH` entry, bottle `maplestory`, and locale exports are fixed defaults (not user-editable in this iteration).
- Do not use bottle `default` or the older `…/bin/wine --wait-children --enable-alt-loader macdrv` form; the player guide is the source of truth.
- Do not emit a half-built command when `.exe` or OTP is missing; show a prompt instead and disable copy.

## UI

Update the advanced-mode group (rename title to 「遊戲啟動指令」):

1. For 新楓之谷, show a segmented control:
   - `open`
   - `Nexon Launcher Wine`
   - Default selection: `open`
2. For other games, hide the segmented control and always show the full `open` command.
3. Main text area shows the currently selected **full terminal command** (selectable).
4. Rename copy button to 「複製啟動指令」; it copies the currently displayed full command.
5. Leave 「透過 Cyder 啟動遊戲」 as-is.

## Data Flow

- Add a small launch-method preference on `AppModel` (for example `advancedLaunchCommandStyle`), remembered across sessions.
- When the selected game is not MapleStory, Wine UI is hidden; the displayed command is always the `open` form. The remembered preference may stay so returning to MapleStory restores the last choice.
- Build the full command with a pure helper (in `Models.swift` or adjacent) from:
  - selected game / launch style
  - normalized executable path
  - account ID
  - OTP value
  - selected command style (`open` vs Wine)
- Stop treating `OTPResult.commandLine` as the advanced-mode display source of truth. Compute the display/copy string from current model state via the helper. Keep `OTPResult.commandLine` as the argument-only fragment for now (no need to remove it in this change).

## Error / Edge Cases

| Case | Behavior |
| --- | --- |
| No executable path | Prompt to select `.exe`; copy disabled |
| No OTP / no account | Prompt to retrieve OTP; copy disabled |
| Switch away from MapleStory | Hide Wine selector; show `open` command |
| Switch back to MapleStory | Restore remembered `open` / Wine preference |
| Path with spaces or quotes | Correct shell quoting in generated command |
| Actual launch / standard mode | Unchanged |

## Testing

Add unit tests for:

1. Full `open` MapleStory command with spaced path, `--args`, account ID, and OTP.
2. Full Wine MapleStory command with `CX_ROOT` / `PATH` exports, `zh_TW.UTF-8` locale, bottle `maplestory`, and `--workdir` = exe parent directory.
3. Manual game full command: `open -n '/path/to/Lineage.exe'` with no `--args`.
4. Shell quoting for paths containing spaces and single quotes.

Existing `openArguments` / `launchGame()` tests remain valid; this feature does not change launch execution.

## README

Update the advanced-mode section to document:

- Full terminal commands are shown/copied in advanced mode.
- MapleStory can switch between `open` and Nexon MapleStory Launcher Wine forms.
- In-app launch still uses Cyder via `open -n`.

## Out of Scope Follow-ups

- User-editable Wine path / bottle / workdir.
- Using Wine from the launch button.
- Wine commands for other games.
