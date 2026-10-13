# How it works

These notes come from the original debugging session (October 2026) on macOS 26, RealVNC
Viewer and an X11 Linux desktop. The RealVNC behavior described here was **observed** on that
setup; other versions may differ. Run `xev -event keyboard` on Linux to see exactly what
arrives.

## The two problems

### 1. Wispr's ⌘V reaches Linux as a bare `v`

Wispr Flow pastes by putting the text on the Mac clipboard and posting a **synthetic** ⌘V: one
`v` key event that has the Command flag set. No separate Command key press or release is sent.

RealVNC Viewer forwards modifiers based on the modifier keys' own down/up events, not on the
flags carried by the `v` event. So the Command flag is lost. In `xev`, Linux receives only `v`
(keycode 55, state 0x10).

RealVNC's own `LeftCmdKey` mapping can't help here. It only offers Alt_L, Alt_R, Super_L,
Super_R or ExtendedChars, never Control, and there is no Command press for it to map anyway.

### 2. The clipboard syncs at the wrong moment

RealVNC syncs the clipboard **on focus changes**, not continuously:

- When the Viewer **gains** focus, it pushes the Mac clipboard to Linux.
- About **0.2–0.5 s after it loses** focus, it pulls the Linux clipboard back and **overwrites**
  the Mac clipboard.
- While focus stays in the Viewer, nothing syncs.

Wispr dictates while the Viewer already has focus, so the new text never reaches Linux. Wispr
doesn't restore the previous clipboard, which doesn't matter here.

## The fix (`hammerspoon/wispr_vnc_paste.lua`)

1. An event tap watches `v` key-downs. It intercepts only when **all** of these are true:
   - the event has the Command flag,
   - no **physical** Command key is held (tracked from real flagsChanged events),
   - the frontmost app is the VNC viewer,
   - the event's source process is Wispr Flow (`eventSourceUnixProcessID`).

   It swallows the event and saves the clipboard text.
2. It waits for Wispr's `v` key-up (or 1 s), then another **0.3 s**. If focus moves before Wispr
   finishes its paste sequence, Wispr stops responding to the Fn key for 10–15 s.
3. It activates **Finder**, then polls the clipboard until RealVNC's pull-back overwrites it.
   That took a steady 180–200 ms in testing; the timeout is 0.6 s. It then waits another 0.05 s.
4. It writes the saved text back to the clipboard and re-activates the Viewer. The Viewer pushes
   the text to Linux.
5. After **0.2 s** it sends Ctrl+V, using the event recipe below. If the Viewer is not frontmost
   at that point, it skips the paste and shows an alert. The text stays on the clipboard.

Each paste takes about 0.75 s and the window flickers once.

## How to send a modifier that RealVNC will forward

Test results from the original session (`extras/debug.lua`, `testA(n)`):

| test | method | result |
|---|---|---|
| A1 | `newKeyEvent({}, "ctrl", true)` then `{"ctrl"}`+`v` | Ctrl dropped, failed |
| A2 | Ctrl keycode event, `setType(flagsChanged)` **and** `setFlags({ctrl=true})` on the Ctrl event itself, then `v` with ctrl flag | **works**, and the module uses it |
| A3 | AppleScript `System Events` `key code 9 using control down` | not needed |
| A4 | lone F19 | not needed; it is the basis for the F19 fallback |

The key point: the modifier's own flagsChanged event must carry its flag.

## Things that did not work or are not worth trying

- Triggering the focus bounce from an automated `hs -c` call. macOS won't let Hammerspoon
  activate the Viewer without real user input, and `hs.focus()` doesn't make the Viewer lose
  focus. Timing can only be tuned with real Wispr dictation.
- Calling `hs -c 'hs.reload()'` followed by another `hs` call in the same command hangs. Reload
  first, then reconnect separately.
- The F19 plus Linux `xdotool` plan (`extras/linux/vnc-paste.sh`) turned out to be unnecessary
  once A2 worked. It is kept as a fallback.
