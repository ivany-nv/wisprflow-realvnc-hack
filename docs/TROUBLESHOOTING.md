# Troubleshooting

Start with `./install.sh --status`. Then turn on logs with
`hs -c 'require("wispr_vnc_paste").debug = true'`, ask the user to dictate once, and read:

```bash
hs -c 'print(hs.console.getConsole())' | grep wispr-vnc-paste | tail -30
```

To change an option, edit the `start({...})` call between the `>>> wispr-vnc-paste` markers in
the Hammerspoon config file (normally `~/.hammerspoon/init.lua`). Then run `./install.sh`
again; it restarts Hammerspoon.

| symptom | likely cause | fix |
|---|---|---|
| Linux gets a lone `v`, nothing in the logs | Module not intercepting | Check the status: `accessibility: true` and both taps `enabled`. Check that the app names in `vncApps` / `dictationApps` match the running apps exactly (see AGENTS.md, Step 4). After granting Accessibility, re-run `./install.sh`. |
| Linux gets a lone `v` and logs show `pasted … chars` | Ctrl isn't reaching Linux on this setup | **HUMAN-assisted.** Load `extras/debug.lua` (see the bottom of this page). Have the user run `xev -event keyboard` on Linux. Then run `hs -c 'testA(1)'` … `testA(4)` one at a time. After each, the user has 5 s to click into the VNC window, then reports what `xev` showed. If only A4 (F19) arrives, use `pasteMethod = "f19"` and bind F19 on Linux to `extras/linux/vnc-paste.sh`. |
| Old Linux clipboard content gets pasted instead of the dictation | The pull-back arrived after the text was written, or the push hadn't finished | Raise `pullbackMax` (e.g. 1.0) and/or `syncWait` (e.g. 0.35). A log line `no clipboard pull-back within …` points to `pullbackMax`. |
| Alert "the VNC window was not in front" | Something else took focus during the bounce | Retry. If it keeps happening, raise `syncWait`, or set `bounceApp` to another always-running app. |
| Wispr ignores the Fn key for 10–15 s after dictating | Focus moved before Wispr finished its paste | Raise `postDictationWait` (e.g. 0.5). |
| Works in browsers and editors but not in a Linux terminal | Terminals paste with Ctrl+Shift+V | `pasteMethod = "ctrl+shift+v"` (experimental), or the F19 fallback. That script picks the right keys per window. |
| Nothing reaches Linux even with a manual ⌘C on the Mac and Ctrl+V on Linux | Clipboard sharing is off in RealVNC | Turn on clipboard sharing in the Viewer's options for that connection, and on the RealVNC Server side. Then retest manually before retesting dictation. |
| `previous paste still running; this one was dropped` | Two dictations within about 0.75 s | Expected. Dictate again. |
| `hs: command not found` | CLI not on PATH | `install.sh` also finds it in `/opt/homebrew/bin`, `/usr/local/bin` and inside `Hammerspoon.app`. Otherwise ask the user to run `hs.ipc.cliInstall()` in the Hammerspoon console. |
| Taps `enabled`, accessibility `true`, but no log lines when dictating | Missing Input Monitoring permission (some macOS versions) | System Settings → Privacy & Security → Input Monitoring → turn on Hammerspoon. Then re-run `./install.sh`. |
| `hs -c` hangs | You chained a call after `hs.reload()` | Kill it. Run the reload by itself, wait 2 s, reconnect. |
| Stopped working after sleep or heavy load | macOS disabled the event tap | The module re-enables it within 5 s; the log says `event tap was disabled`. If it persists, re-run `./install.sh`. |

Still stuck? Load the verbose diagnostics (they stop the main module until the next reload):

```bash
hs -c 'dofile("'"$PWD"'/extras/debug.lua")'
```

Then read the `B v …` lines. They show, for every `v` event: the frontmost app, the cmd/ctrl
flags, whether a physical Cmd key was held, and the source process.

- **No `B` lines at all:** Wispr's events bypass the tap.
- **`cmd=false`:** Wispr sends something other than ⌘V on this machine.
- **`realCmdHeld=true`:** Cmd-state tracking is confused.

Run `hs -c 'hs.reload()'` to return to the normal module.
