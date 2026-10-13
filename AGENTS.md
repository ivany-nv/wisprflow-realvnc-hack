# Setup guide for AI agents

You are setting up **wispr-vnc-paste** on the user's Mac. When it works, text dictated with
**Wispr Flow** pastes straight into a **Linux** desktop shown in **RealVNC Viewer**. Without it,
Linux receives only a lone `v`.

Do every step you can yourself. Stop and ask the user **only** at the steps marked **HUMAN**.
Nothing needs to be installed or changed on the Linux machine for the default setup.

## Ground rules

- Run everything on the **Mac**, from the root of this repository.
- Never overwrite the user's Hammerspoon config. `install.sh` backs it up and only appends a
  marked block. If you edit the config by hand, back it up first.
- `hs -c '...'` runs Lua inside Hammerspoon. **Never** chain another `hs` call after
  `hs -c 'hs.reload()'` in the same shell command, because it can hang. Run the reload alone,
  wait about 2 s, then reconnect. Prefer `./install.sh` (it restarts Hammerspoon safely) or
  `./install.sh --status`.
- `./install.sh` **restarts Hammerspoon** every time it runs. If the user already uses
  Hammerspoon for other things, tell them their automations will blink off for a second.
- Read `docs/HOW_IT_WORKS.md` if you need to understand or tune the behavior.

## Step 1: Check prerequisites

```bash
sw_vers -productVersion
mdfind 'kMDItemContentType == "com.apple.application-bundle"' | grep -iE 'wispr|vnc|hammerspoon'
ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null; command -v git
```

You need macOS, Wispr Flow and RealVNC Viewer. If Wispr Flow or RealVNC Viewer is missing, stop
and tell the user. This fix is only for that combination.

Homebrew is optional: it is used to install Hammerspoon if Hammerspoon is missing.

If `git` is missing, macOS shows a "Command Line Tools" installer dialog. That is a **HUMAN**
step. Ask the user to finish it, or download the repo as a ZIP from GitHub instead.

## Step 2: Run the installer

```bash
chmod +x install.sh && ./install.sh; echo "exit=$?"
```

Use the exit code to decide what to do next:

| exit | meaning | what you do |
|---|---|---|
| 0 | installed and healthy | go to Step 4 |
| 1 | error | read the stderr message. If it's a Lua error, read the console with `hs -c 'print(hs.console.getConsole())' \| tail -40`. Fix it if it's clearly safe, otherwise report it to the user |
| 2 | no Hammerspoon and no Homebrew | ask the user to install Hammerspoon from <https://www.hammerspoon.org>, then re-run |
| 3 | another copy of this fix is in the config | see "Legacy copy" below, then re-run |
| 10 | Accessibility permission missing | Step 3 (**HUMAN**) |
| 11 | Hammerspoon not running or not responding | **HUMAN**: a macOS dialog is probably waiting ("downloaded from the Internet", Hammerspoon's first-launch window, or a config error window). Ask the user to click **Open** / dismiss it, then re-run |
| 12 | `hs` CLI could not be installed | **HUMAN**: ask the user to open Hammerspoon's menu-bar icon → **Console**, type `hs.ipc.cliInstall()` and press Enter, then re-run |

`./install.sh --status` returns 0 (healthy), 1 (module not loaded), 11 or 12, with the same
meanings as above.

**Legacy copy (exit 3).** The config file (normally `~/.hammerspoon/init.lua`) already loads
this fix outside the managed block. The installer printed the matching lines. It may be code from
the original single-file version (`pasteViaFocusBounce`, `[vnc-paste]`) or a hand-written
`require("wispr_vnc_paste")`.

Show the user those lines and **get a yes before changing anything**. Then back up the file and
remove only that code: if the file contains nothing else, empty it. Re-run `./install.sh`.

## Step 3 (HUMAN): Grant the Accessibility permission

The installer has already opened **System Settings → Privacy & Security → Accessibility**. Ask
the user to switch **Hammerspoon** on. macOS will ask for their password or Touch ID. If
Hammerspoon is not in the list, they should add it with the **+** button from `/Applications`.

When they confirm, run `./install.sh` again. It should exit 0.

If the same pane lists Hammerspoon under **Input Monitoring** and it is off, have the user turn
that on too. Hammerspoon normally needs only Accessibility.

## Step 4: Verify the install

```bash
./install.sh --status
```

All of these must hold:

- `started: true`
- `accessibility: true`
- `key tap: enabled, modifier tap: enabled`
- `dictationApps: Wispr Flow (running)`. If it shows `not running`, ask the user to open Wispr
  Flow and check again.
- `vncApps:` shows at least one name as `(running)` once the user has a VNC session open. The
  other default name showing `(not running)` is normal: names are matched exactly, and each
  RealVNC version uses only one of them.

If an app shows `not running` even though it is open, the app's name differs on this Mac. List
the real names:

```bash
hs -c 'for _,a in ipairs(hs.application.runningApplications()) do print(a:name()) end' | grep -iE 'vnc|wispr|flow'
```

Then pass the real names in the config block of the Hammerspoon config file (inside the
`>>> wispr-vnc-paste` markers):

```lua
require("wispr_vnc_paste").start({ vncApps = { "Exact VNC Name" }, dictationApps = { "Exact Wispr Name" } })
```

Then re-run `./install.sh`. It keeps an existing block and only restarts Hammerspoon.

## Step 5 (HUMAN): End-to-end test

First turn on logging and note the current `ok` count. The counter is cumulative, and logging
stays on until the next Hammerspoon reload.

```bash
hs -c 'require("wispr_vnc_paste").debug = true'
./install.sh --status | grep '^pastes:'
```

Then ask the user to:

1. Open the Linux desktop in RealVNC Viewer and click into a normal text field, such as a
   browser address bar or a text editor. Avoid terminals for this first test.
2. Dictate a short sentence with Wispr Flow as usual.
3. Expect the window to flicker once (focus briefly moves to Finder and back). The text should
   appear in Linux within about 1 second.

Then check what happened:

```bash
./install.sh --status                                      # look at "pastes: ok=… failed=…"
hs -c 'print(hs.console.getConsole())' | grep wispr-vnc-paste | tail -20
```

- `ok` went up and the user saw the text: **done**. Go to Step 6.
- Anything else: open `docs/TROUBLESHOOTING.md` and match the symptom.

## Step 6: Tell the user how it went

Report back to the user:

- That it's installed and that Hammerspoon now launches at login.
- The brief window flicker on each dictation into VNC is expected.
- **Terminals:** Linux terminals usually paste with Ctrl+Shift+V, so the default Ctrl+V won't
  paste there. If they dictate into terminals, offer
  `start({ pasteMethod = "ctrl+shift+v" })`. This setting is experimental. In browsers it
  pastes as plain text, which is fine, but some editors map Ctrl+Shift+V to something else.
- How to check status: `./install.sh --status`.
- How to remove it: `./install.sh --uninstall`.
- How to update: `git pull && ./install.sh`.

## Configuration reference

All options go into `start({...})`. The defaults are in `hammerspoon/wispr_vnc_paste.lua`.

| option | default | purpose |
|---|---|---|
| `vncApps` | `{"RealVNC Viewer","VNC Viewer"}` | frontmost app names that trigger the fix |
| `dictationApps` | `{"Wispr Flow"}` | apps whose synthetic Cmd+V is intercepted |
| `bounceApp` | `"Finder"` | app that briefly takes focus |
| `pasteMethod` | `"ctrl+v"` | `"ctrl+v"`, `"ctrl+shift+v"` (experimental) or `"f19"` (needs `extras/linux/vnc-paste.sh` bound to F19 on Linux) |
| `postDictationWait` | `0.3` | seconds to wait before moving focus. Too short makes Wispr ignore Fn for 10–15 s |
| `pullbackMax` | `0.6` | max seconds to wait for RealVNC to overwrite the Mac clipboard |
| `pullbackSettle` | `0.05` | extra seconds after that overwrite |
| `syncWait` | `0.2` | seconds after refocusing VNC before sending the paste keys |
| `keyUpTimeout` | `1.0` | paste anyway if Wispr's key-up never arrives |
| `installCli` | `true` | install the `hs` CLI if it is missing |
| `alertOnFailure` | `true` | show an on-screen alert when a paste fails |
| `debug` | `false` | verbose console logging |
