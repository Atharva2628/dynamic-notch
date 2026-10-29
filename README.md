# Dynamic Notch

A personal "dynamic island" for the MacBook notch, replacing Notchy. The plan and the
feature list are in `SPEC.md`, a local working doc that is not published.

Status: **every v1 feature is built and installed** (terminal, Claude Code agents, system
stats, calendar, clipboard, shelf, prompter, music, downloads, Quick Capture, Skim asks and
the `notch` command). `--selftest` passes 474 checks. Checked live through `notch state`:
the notch window's place and level on every Space, opening tabs and keyboard focus, the
menu bar terminal with a live shell, Claude Code hooks reaching the Agents tab, a
permission request showing and clearing, timed activities, and the login item. Hovering
and clicking by hand haven't been checked yet. Each state, rendered on a fake menu bar with
the cutout in red: [docs/snapshots](docs/snapshots).

To try the states before real activities exist, use the menu bar icon's Test Activities menu.

## Using it
- **Notch:** rest the pointer on it to peek at what's happening; click to open the panel.
  Esc or a click elsewhere closes it. Tabs: Home, Terminal, Agents, System, Calendar,
  Clipboard, Shelf, Prompter, Settings.
- **Terminal:** click the menu bar icon, or press Control and the backtick key (left of 1) anywhere.
  ⌘T new tab, ⌘W close, ⌘1–9 switch, ⌘K clear, ⌘+ and ⌘− font size, ⌘F find. The pin
  keeps it open when you click elsewhere. Right-click the icon for the menu.
- **Clipboard:** Control-Option-V opens the history with search focused. Arrows and Return
  copy; ⌘1–9 copy the Nth; ⌘P pins. The trash button by Pinned clears the history (click
  it twice); pinned items stay.
- **Calendar:** the button beside quick add lists your calendars; uncheck one (say, Holidays
  in India) to drop its events from the agenda, Home and meeting alerts. Saved as
  `hiddenCalendars`.
- **Quick Capture:** Control-Option-N, type, Return. It lands in `quickCaptureFile`.
- **Shelf:** drag files onto the notch. Each comes off the Shelf 24 hours after you added it
  (`shelfKeepHours`); only off the Shelf, the file itself stays where it is.
- **Music:** Spotify, Music, and anything else macOS shows under Now Playing: a YouTube or
  Suno tab in any browser, VLC, Podcasts. Hover for previous, play/pause and next.
- **Claude Code:** permission requests pop up with Allow, Deny and Open; the Allow button
  wakes up after a moment, so a click already on its way can't approve anything.
- **Settings:** the Settings tab has a switch for each feature.

```bash
notch post "Build done" --for 5
```

```bash
notch state
```
`notch help` lists every command. `notch state` prints the app's live state as JSON, for
troubleshooting.

## Requirements
- macOS 26 or later on a Mac with a notch (built and tested on a MacBook Air M4, macOS 27.2).
- Xcode Command Line Tools (`xcode-select --install`). No Xcode.

## Build and run

```bash
sh scripts/build.sh
```
Compiles into `~/Library/Application Support/DynamicNotch/DynamicNotch.app` (outside the
iCloud-synced Desktop). Build caches go to a temp folder that is deleted afterwards.

```bash
open "$HOME/Library/Application Support/DynamicNotch/DynamicNotch.app"
```
Runs it once, without a login item, hooks or the `notch` command. Quit from the menu bar
icon.

## Install

```bash
sh scripts/install.sh
```
Re-run it after changing the code; it replaces its own entries. It:

- Builds the app, as above.
- Adds hooks for 9 Claude Code events to `~/.claude/settings.json`, so the Agents tab
  sees your sessions. Notchy's and Agent Away's hooks are left alone.
- Backs that file up first, to `~/Library/Application Support/DynamicNotch/backups`. The
  first copy is kept for good as `settings.json.original`; of the rest, the last 10 stay.
  A re-run that changes nothing writes nothing and makes no backup.
- Links the `notch` command into `~/.local/bin` (`notch help` lists what it does).
- Writes the LaunchAgent `local.dynamicnotch` (starts at login, restarts after a crash)
  and restarts the app the normal way: if commands are running in its terminal, it asks
  first, and if you cancel, the new build waits for the next restart.

One of the hooks is `PermissionRequest`. While Notchy isn't running, Claude Code's
permission requests wait up to 110 s for Allow or Deny in the notch, then fall back to
Claude Code's own prompt. To keep answering them in Claude Code, turn off Approve Claude
requests here in the Settings tab (`agentApprovals` in `config.json`): the notch then only
shows that a request is waiting. Or install with `--no-hooks`, which adds no hooks at all
(the Agents tab stays empty):

```bash
sh scripts/install.sh --no-hooks
```

Running install.sh from a Dynamic Notch terminal tab works: the restart closes that tab,
and the rest of the output goes to `~/Library/Application Support/DynamicNotch/install.log`.

## Switch from Notchy
Install first, alongside Notchy. While Notchy runs, the notch shows requests but leaves
the answering to Notchy. On switch day:

```bash
sh scripts/switch-from-notchy.sh
```
In one write, it removes Notchy's hooks from `~/.claude/settings.json` and makes sure
Dynamic Notch's are in (even after `--no-hooks`). The settings from just before are kept
for good as `backups/settings.json.before-switch`. It doesn't touch Notchy itself: quit
Notchy, turn off its launch at login and move `Notchy.app` to the Trash by hand.

Your Notchy prompter scripts come over in the app: on first launch, and from Import
Notchy Scripts in the menu bar icon's menu. Import Notchy To-dos in the same menu adds
your Notchy to-dos to the Quick Capture file (done ones checked off; running it twice adds
nothing twice). Both only read Notchy's settings.

## Remove

```bash
sh scripts/uninstall.sh
```
Removes Dynamic Notch's hooks from `~/.claude/settings.json` (backed up first), moves the
`notch` link and the LaunchAgent to the Trash, then quits the app the normal way (the
terminal asks first if commands are running) and moves the app to the Trash. If you
cancel the quit, run it again after quitting from the menu bar icon.

Keeps `config.json`, your data and the backups in
`~/Library/Application Support/DynamicNotch`. Like install.sh, it can run from a Dynamic
Notch terminal tab; the rest of its output then goes to `uninstall.log` in that folder.

## Settings
`~/Library/Application Support/DynamicNotch/config.json`, created on first launch; keys
added by a newer version are written in with their defaults. The Settings tab switches the
on/off ones. For the rest, open the file from the menu bar icon or the Settings tab, then
choose Reload Settings.

| Key | Default | Meaning |
|---|---|---|
| **Notch** | | |
| `collapseDelay` | `0.1` | seconds after the pointer leaves before the notch closes |
| `hoverDelay` | `0.15` | seconds the pointer rests on the notch before it grows; clicks don't wait |
| `hoverToPeek` | `true` | hovering shows the top activity's details |
| `panelWidth`, `panelHeight` | `806`, `250` | open panel size in points; widened to fit the tab icons and shrunk to fit the screen |
| `tabs` | all | tab order |
| `hiddenTabs` | none | tabs to hide |
| **Terminal** | | |
| `terminalHotkey` | ``"ctrl+`"`` | shows and hides the menu bar terminal |
| `terminalFontSize` | `13` | points |
| `terminalScrollback` | `10000` | lines kept per tab |
| `terminalWidth`, `terminalHeight` | `720`, `420` | menu bar dropdown size; remembered when you resize it |
| **Agents (Claude Code)** | | |
| `agentApprovals` | `true` | Allow and Deny permission requests from the notch; `false` only shows that one is waiting |
| `agentSound` | `"Sosumi"` | sound when a session finishes; `""` for silent |
| `usageSource` | `"keychain"` | usage limits from Claude Code's sign-in; `"off"` hides them |
| `usageAlerts` | `[95, 80]` | alert at these percents of the 5-hour or weekly limit |
| `apiCostEstimate` | `true` | what your Claude Code tokens would cost at API prices (Agents tab, Home card, Usage tab) |
| `agentAwayStatus` | `true` | show Agent Away's status |
| **Clipboard and Shelf** | | |
| `clipboardHotkey` | `"ctrl+alt+v"` | opens the clipboard history |
| `clipboardLimit` | `40` | items kept |
| `clipboardAutoPaste` | `false` | also press ⌘V in the front app (needs Accessibility) |
| `shelfKeepHours` | `24` | hours a file stays on the Shelf after you add it; `0` keeps it until you remove it (the file itself is never touched) |
| **System** | | |
| `batteryAlerts` | `[20, 10]` | alert at these percents left |
| `diskAlertGB` | `10` | alert when free disk space drops below this; `0` turns it off |
| `statsInEars` | `false` | CPU and network speed beside an idle notch |
| **Calendar** | | |
| `calendarEnabled` | `true` | the Calendar tab and meeting alerts (asks for Calendar access) |
| `calendarDays` | `7` | days ahead to show |
| `meetingAlertMinutes` | `5` | minutes before a meeting to alert |
| **Status** | | |
| `capsLockHUD`, `cameraGuard`, `micGuard` | `true` | Caps Lock flash, camera and microphone indicators |
| `lockNotice`, `downloads`, `nowPlaying` | `true` | unlock animation, download progress, music (Spotify, Music and any app or browser tab) |
| `nowPlayingHideWhenPaused` | `true` | hide the music when it's paused |
| **Prompter** | | |
| `prompterFolder` | `""` | folder of `.md` scripts; empty is `Prompter` next to `config.json` |
| `prompterFontSize`, `prompterWidth` | `20`, `420` | points |
| `prompterSpeed` | `40` | scroll speed, points per second |
| `prompterWordsPerMinute` | `150` | reading pace for each script's length |
| `prompterVoiceFollow` | `false` | scroll as you speak (asks for the microphone and speech recognition) |
| **Extras** | | |
| `quickCaptureFile` | `"~/Documents/Quick Capture.md"` | where Quick Capture adds to-dos |
| `quickCaptureHotkey` | `"ctrl+alt+n"` | `""` turns it off |
| `skimFolders` | `[]` | folders whose open `[!ASK]` boxes the Drafts card counts; empty uses skim's recent folders |

## Keep permissions across rebuilds (one-time)
Each build is signed. Signed ad-hoc, every rebuild looks like a new app to macOS, which
then forgets permissions you granted (folders, Calendar, Automation, microphone). A
self-signed certificate fixes it:

1. Open Keychain Access, then Keychain Access menu > Certificate Assistant > Create a Certificate.
2. Name: `Dynamic Notch Dev`. Identity Type: Self Signed Root. Certificate Type: Code Signing. Create.
3. In the login keychain, double-click the new certificate, open Trust, and set Code Signing to Always Trust.
4. Run `sh scripts/build.sh`. It reports `signed Dynamic Notch Dev`.

Commands you run in the terminal count as Dynamic Notch for these permissions. A prompt
that names Dynamic Notch may come from such a command, and a permission granted to one
(the microphone, say) is granted to the other too.

## Checks without a screen

```bash
APP="$HOME/Library/Application Support/DynamicNotch/DynamicNotch.app/Contents/MacOS/DynamicNotch"
```

```bash
"$APP" --selftest
```

```bash
"$APP" --geometry
```

```bash
"$APP" --snapshot /tmp/notch-snaps
```
```bash
"$APP" --cost
```
`--cost` adds up your Claude Code transcripts at API prices and prints the totals (it saves
nothing).

`--selftest` checks geometry, sizes, the activity queue, settings parsing and each
feature's logic. `--geometry` prints what the app reads from each screen. `--snapshot`
renders every state to PNG files. While the app runs, `notch state` shows its live state.

Logs:

```bash
log stream --predicate 'subsystem == "local.dynamicnotch"'
```
