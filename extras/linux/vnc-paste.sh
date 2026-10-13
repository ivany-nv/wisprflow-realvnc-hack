#!/bin/sh
# Linux side of the optional F19 fallback (pasteMethod = "f19").
# Only needed if Ctrl+V sent from the Mac never reaches Linux with Ctrl held (see docs/TROUBLESHOOTING.md).
#
# Bind F19 to this script on the Linux machine, e.g.:
#   GNOME:      Settings > Keyboard > Custom Shortcuts > command: /path/to/vnc-paste.sh, shortcut: F19
#   xbindkeys:  add to ~/.xbindkeysrc:   "/path/to/vnc-paste.sh"
#                                          F19
# Requires: xdotool (X11). Terminals get Ctrl+Shift+V, everything else gets Ctrl+V.
sleep 0.05
cls=$(xdotool getactivewindow getwindowclassname 2>/dev/null)
case "$cls" in
  *[Tt]erminal*|*[Kk]onsole*|*[Xx]term*|*kitty*|*Alacritty*|*[Tt]ilix*|*[Tt]erminator*|*wezterm*)
    xdotool key --clearmodifiers ctrl+shift+v ;;
  *)
    xdotool key --clearmodifiers ctrl+v ;;
esac
