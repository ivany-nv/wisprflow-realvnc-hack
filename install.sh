#!/bin/bash
# install.sh — install, upgrade, check or remove wispr-vnc-paste (runs on the Mac).
#
#   ./install.sh               install or upgrade (idempotent; safe to re-run; restarts Hammerspoon)
#   ./install.sh --status      print the module's health report
#   ./install.sh --uninstall   remove the module and its lines from the Hammerspoon config
#
# Exit codes (meant for AI agents driving the setup):
#    0  installed and healthy
#    1  error (message on stderr)
#    2  Hammerspoon is not installed and Homebrew is unavailable to install it
#    3  the Hammerspoon config already loads this fix outside the managed block (e.g. an older copy)
#   10  installed, but Hammerspoon still needs the Accessibility permission (human step)
#   11  Hammerspoon is not responding (human step: check for a macOS dialog)
#   12  Hammerspoon is running but the `hs` command-line tool could not be found or installed
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE="wispr_vnc_paste"
MARK_BEGIN=">>> wispr-vnc-paste"
MARK_END="<<< wispr-vnc-paste"
REPO_URL="https://github.com/ivany-nv/wisprflow-realvnc-hack"

say() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

[ "$(uname)" = "Darwin" ] || die "run this on the Mac (macOS), not on the Linux machine"

# Hammerspoon config file; respect a custom location if the user set one.
CONFIG_FILE="$(defaults read org.hammerspoon.Hammerspoon MJConfigFile 2>/dev/null || true)"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.hammerspoon/init.lua}"
CONFIG_FILE="${CONFIG_FILE/#\~/$HOME}"
HS_DIR="$(dirname "$CONFIG_FILE")"

find_brew() {
  local c
  for c in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

find_hs() {
  local c
  for c in "$(command -v hs 2>/dev/null || true)" /opt/homebrew/bin/hs /usr/local/bin/hs \
           /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs \
           "$HOME/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

# hs_run <timeout-seconds> <lua>  — run Lua inside Hammerspoon with a hard timeout.
hs_run() {
  local bin
  bin="$(find_hs)" || return 127
  perl -e 'alarm shift; exec @ARGV' "$1" "$bin" -c "$2"
}

app_installed() {
  [ -d /Applications/Hammerspoon.app ] || [ -d "$HOME/Applications/Hammerspoon.app" ] ||
    mdfind "kMDItemCFBundleIdentifier == 'org.hammerspoon.Hammerspoon'" 2>/dev/null | grep -q .
}

hs_running() { pgrep -x Hammerspoon >/dev/null 2>&1; }

# Quit with a signal rather than AppleScript, which would trigger a macOS Automation prompt.
restart_hammerspoon() {
  if hs_running; then
    pkill -x Hammerspoon || true
    for _ in $(seq 1 40); do hs_running || break; sleep 0.25; done
    if hs_running; then pkill -9 -x Hammerspoon || true; sleep 1; fi
  fi
  open -a Hammerspoon
}

wait_for_hammerspoon() {
  for _ in $(seq 1 30); do
    if hs_run 3 'return 1' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  if ! hs_running; then
    die "Hammerspoon is not running. Ask the user to check for a macOS dialog (\"downloaded from the Internet\" / first-launch window), click Open, then re-run ./install.sh." 11
  fi
  if ! find_hs >/dev/null; then
    die "Hammerspoon is running but the hs command-line tool was not found. Ask the user to open the Hammerspoon console (menu-bar icon > Console) and run: hs.ipc.cliInstall()  — then re-run ./install.sh." 12
  fi
  die "Hammerspoon is running but not answering on the hs CLI. Ask the user to check for a Hammerspoon dialog or error window, then re-run ./install.sh." 11
}

# Prints the status report. Returns non-zero (with the reason on stderr) if the module is not loaded.
get_status() {
  local out
  if ! out="$(hs_run 5 "print(require('$MODULE').status())" 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
  grep -q '^started: true' <<<"$out"
}

has_block() {
  [ -f "$CONFIG_FILE" ] && grep -qF -- "$MARK_BEGIN" "$CONFIG_FILE" && grep -qF -- "$MARK_END" "$CONFIG_FILE"
}

without_block() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" 'index($0,b){skip=1} !skip{print} index($0,e){skip=0}' "$CONFIG_FILE"
}

case "${1:-}" in
  --status)
    find_hs >/dev/null || die "the hs command-line tool was not found (is the module installed?)" 12
    hs_running || die "Hammerspoon is not running" 11
    get_status || die "the module is not loaded in Hammerspoon (see the output above); re-run ./install.sh"
    exit 0 ;;
  --uninstall)
    if [ -f "$CONFIG_FILE" ]; then
      cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
      if has_block; then
        tmp="$(mktemp)"
        without_block > "$tmp"
        cat "$tmp" > "$CONFIG_FILE"
        rm -f "$tmp"
      fi
    fi
    rm -f "$HS_DIR/$MODULE.lua"
    if hs_running; then restart_hammerspoon; fi
    say "uninstalled (config backed up next to $CONFIG_FILE)."
    say "Left in place: Hammerspoon itself, its launch-at-login setting, and the hs command-line tool."
    exit 0 ;;
  "") ;;
  *) die "unknown argument: $1 (use --status or --uninstall)" ;;
esac

# 1. Hammerspoon
if ! app_installed; then
  if brew="$(find_brew)"; then
    say "installing Hammerspoon with Homebrew"
    "$brew" install --cask hammerspoon || die "brew install --cask hammerspoon failed (see above)"
  else
    die "Hammerspoon is not installed and Homebrew is not available. Install it from https://www.hammerspoon.org and re-run." 2
  fi
fi

# 2. Refuse to double-install next to another copy of this fix outside the managed block.
if [ -f "$CONFIG_FILE" ]; then
  if grep -qF -- "$MARK_BEGIN" "$CONFIG_FILE" && ! has_block; then
    die "$CONFIG_FILE has a '$MARK_BEGIN' line without the matching '$MARK_END' line. Fix or remove that block by hand, then re-run." 1
  fi
  legacy="$(without_block | grep -nE 'pasteViaFocusBounce|\[vnc-paste\]|wispr_vnc_paste' || true)"
  if [ -n "$legacy" ]; then
    printf '%s\n' "$legacy" >&2
    die "$CONFIG_FILE already contains another copy of this fix (lines above, outside the managed block). Remove that code first (back the file up), then re-run." 3
  fi
fi

# 3. Module + config block
mkdir -p "$HS_DIR"
cp "$REPO_DIR/hammerspoon/$MODULE.lua" "$HS_DIR/$MODULE.lua"
say "copied $MODULE.lua to $HS_DIR/"

if has_block; then
  say "$CONFIG_FILE already loads the module; left unchanged"
else
  if [ -f "$CONFIG_FILE" ]; then
    backup="$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_FILE" "$backup"
    say "backed up existing config to $backup"
  fi
  printf '\n-- %s (%s) — managed by install.sh\nrequire("%s").start()\n-- %s\n' \
    "$MARK_BEGIN" "$REPO_URL" "$MODULE" "$MARK_END" >> "$CONFIG_FILE"
  say "added the module to $CONFIG_FILE"
fi

# 4. (Re)start Hammerspoon so the config loads; the module installs the hs CLI on first start.
say "restarting Hammerspoon"
restart_hammerspoon
wait_for_hammerspoon

# 5. Start at login so the fix survives reboots.
hs_run 3 'hs.autoLaunch(true)' >/dev/null 2>&1 || say "warning: could not enable launch-at-login"

if ! status="$(get_status)"; then
  die "Hammerspoon is running but the module did not load. Check the Hammerspoon console for a Lua error (hs -c 'print(hs.console.getConsole())' | tail -40)." 1
fi
printf '%s\n' "$status"

if ! grep -q '^accessibility: true' <<<"$status"; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
  say "ACTION REQUIRED (human): System Settings > Privacy & Security > Accessibility — turn ON Hammerspoon."
  say "Then re-run ./install.sh (it restarts Hammerspoon and re-checks)."
  exit 10
fi

say "done. Next: the user dictates with Wispr Flow into a text field inside the RealVNC window (see AGENTS.md step 5)."
