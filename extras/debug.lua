-- extras/debug.lua — diagnostics for when the main module does not work on a new machine.
--
-- Load it (this stops the main module until the next Hammerspoon reload):
--   hs -c 'dofile("/ABSOLUTE/PATH/TO/repo/extras/debug.lua")'
-- Then:
--   * Watch the Hammerspoon console (or: hs -c 'print(hs.console.getConsole())').
--   * Section B logs every "v" key event: frontmost app, cmd/ctrl flags, whether a physical Cmd
--     is held, and the source process. Dictate once with Wispr into the VNC window and read it.
--   * Section A sends test keystrokes 5 s after you call it, so the user can click back into the
--     VNC window. On Linux, run `xev -event keyboard` to see what actually arrives:
--       hs -c 'testA(1)' ... hs -c 'testA(4)'
--   * MODE: hs -c 'MODE = "off"'  -- "off" (log only) | "ctrl" (Ctrl+V) | "f19" (F19, see extras/linux)
-- Undo: hs -c 'hs.reload()'  (run it on its own; a second hs call in the same shell line can hang)

require("hs.ipc")
pcall(function() require("wispr_vnc_paste").stop() end)
if WVP_DEBUG then for _, t in pairs(WVP_DEBUG) do pcall(function() t:stop() end) end end
WVP_DEBUG = {}

local VNC_APPS = { ["RealVNC Viewer"] = true, ["VNC Viewer"] = true }
local T  = hs.eventtap.event.types
local P  = hs.eventtap.event.properties
local KC = hs.keycodes.map

MODE = "ctrl"
PULLBACK_MAX    = 0.6
PULLBACK_SETTLE = 0.05
POST_WISPR_WAIT = 0.3
SYNC_WAIT       = 0.2
BOUNCE_APP      = "Finder"

local realCmdHeld = false
local swallowVUp  = false
local pendingText = nil

local function frontName()
  local f = hs.application.frontmostApplication(); return f and f:name() or "?"
end

local function srcInfo(e)
  local pid = e:getProperty(P.eventSourceUnixProcessID) or -1
  local a = hs.application.applicationForPID(pid)
  return string.format("pid=%s(%s)", pid, a and a:name() or "?")
end

local function preview(s) return s and string.format("%q", s:sub(1, 30)) or "nil" end
local function mk(mods, key, down) return hs.eventtap.event.newKeyEvent(mods, key, down) end

----------------------------------------------------------------
-- A. Sender tests: call testA(n), then click into the VNC window within 5 s and watch xev.
----------------------------------------------------------------
local tests = {
  -- 1: modifier built from the string "ctrl" (FAILED on the original setup: Ctrl dropped)
  [1] = function()
    mk({}, "ctrl", true):post(); mk({ "ctrl" }, "v", true):post()
    mk({ "ctrl" }, "v", false):post(); mk({}, "ctrl", false):post()
  end,
  -- 2: keycode + explicit flagsChanged + setFlags (WORKED; this is what the module uses)
  [2] = function()
    local d = mk({}, KC.ctrl, true); d:setType(T.flagsChanged); d:setFlags({ ctrl = true }); d:post()
    hs.timer.usleep(20000)
    local vd = mk({}, "v", true);  vd:setFlags({ ctrl = true }); vd:post()
    local vu = mk({}, "v", false); vu:setFlags({ ctrl = true }); vu:post()
    hs.timer.usleep(20000)
    local u = mk({}, KC.ctrl, false); u:setType(T.flagsChanged); u:setFlags({}); u:post()
  end,
  -- 3: via System Events (AppleScript)
  [3] = function()
    local ok, res = hs.osascript.applescript('tell application "System Events" to key code 9 using control down')
    hs.printf("A3 applescript ok=%s res=%s", ok, hs.inspect(res))
  end,
  -- 4: a lone F19 (checks whether a modifier-free special key reaches Linux, for MODE="f19")
  [4] = function()
    mk({}, "f19", true):post(); mk({}, "f19", false):post()
  end,
}

function testA(n, delay)
  delay = delay or 5
  hs.printf("testA(%d) fires in %ds; click into the VNC window now", n, delay)
  WVP_DEBUG.testTimer = hs.timer.doAfter(delay, function()
    hs.printf("testA(%d) firing, frontmost=%s", n, frontName())
    tests[n]()
  end)
end

----------------------------------------------------------------
-- B. Interceptor with verbose logging
----------------------------------------------------------------
WVP_DEBUG.cmdWatcher = hs.eventtap.new({ T.flagsChanged }, function(e)
  realCmdHeld = e:getFlags().cmd == true
  if e:getKeyCode() == 63 then -- Fn / Globe (Wispr's default push-to-talk key)
    hs.printf("F fn %s front=%s", e:getFlags().fn and "DOWN" or "UP", frontName())
  end
  return false
end):start()

local function sendFix()
  if MODE == "ctrl" then tests[2]()
  elseif MODE == "f19" then tests[4]() end
end

local function waitForPullback(cb)
  local cc = hs.pasteboard.changeCount()
  local t0 = hs.timer.secondsSinceEpoch()
  local poll
  poll = hs.timer.doEvery(0.02, function()
    local dt = hs.timer.secondsSinceEpoch() - t0
    local changed = hs.pasteboard.changeCount() ~= cc
    if changed or dt > PULLBACK_MAX then
      poll:stop()
      hs.printf("C pull-back %s after %.0f ms", changed and "seen" or "TIMEOUT", dt * 1000)
      WVP_DEBUG.settle = hs.timer.doAfter(changed and PULLBACK_SETTLE or 0, cb)
    end
  end)
  WVP_DEBUG.poll = poll
end

local function pasteViaFocusBounce(text, vncApp)
  hs.printf("C captured %s", preview(text))
  hs.application.get(BOUNCE_APP):activate()
  waitForPullback(function()
    hs.pasteboard.setContents(text)
    vncApp:activate()
    WVP_DEBUG.sync = hs.timer.doAfter(SYNC_WAIT, function()
      hs.printf("C sending %s, front=%s clipboard=%s", MODE, frontName(), preview(hs.pasteboard.getContents()))
      sendFix()
    end)
  end)
end

WVP_DEBUG.pasteFix = hs.eventtap.new({ T.keyDown, T.keyUp }, function(e)
  if e:getKeyCode() ~= KC["v"] then return false end
  local isDown = e:getType() == T.keyDown
  local app = hs.application.frontmostApplication()
  local appName = app and app:name() or "?"
  local f = e:getFlags()
  hs.printf("B v %s front=%s cmd=%s ctrl=%s realCmdHeld=%s %s",
    isDown and "DOWN" or "UP", appName, tostring(f.cmd), tostring(f.ctrl), tostring(realCmdHeld), srcInfo(e))

  if MODE == "off" or not VNC_APPS[appName] then return false end
  if isDown and f.cmd and not realCmdHeld then
    swallowVUp = true
    pendingText = hs.pasteboard.getContents()
    return true
  end
  if not isDown and swallowVUp then
    swallowVUp = false
    local text = pendingText
    WVP_DEBUG.fire = hs.timer.doAfter(POST_WISPR_WAIT, function() pasteViaFocusBounce(text, app) end)
    return true
  end
  return false
end):start()

hs.printf("wispr-vnc-paste DEBUG loaded, MODE=%s (main module stopped until reload)", MODE)
