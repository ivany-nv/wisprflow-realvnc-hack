-- wispr_vnc_paste.lua
-- Make Wispr Flow dictation paste into a Linux desktop viewed through RealVNC Viewer on macOS.
--
--   Repo:    https://github.com/ivany-nv/wisprflow-realvnc-hack
--   Install: put this file in ~/.hammerspoon/ and add to ~/.hammerspoon/init.lua:
--              require("wispr_vnc_paste").start()
--            (or with options: require("wispr_vnc_paste").start({ pasteMethod = "ctrl+shift+v" }))
--   Status:  hs -c 'print(require("wispr_vnc_paste").status())'
--   Logs:    hs -c 'require("wispr_vnc_paste").debug = true'   (resets to false on reload)
--
-- Why this exists (details in docs/HOW_IT_WORKS.md):
--   1. Wispr Flow pastes by posting a synthetic Cmd+V. RealVNC forwards modifiers from their own
--      press/release events, so Linux receives a bare "v".
--   2. RealVNC pushes the Mac clipboard to Linux only when the Viewer GAINS focus, and pulls the
--      Linux clipboard back to the Mac ~0.2 s after it LOSES focus.
-- So: swallow Wispr's Cmd+V, remember the text, bounce focus to Finder, wait for the pull-back,
-- put the text back on the clipboard, re-activate the Viewer (which pushes it to Linux), send Ctrl+V.

require("hs.ipc")
local _ = hs.application  -- trigger the lazy load now, so its "-- Loading extension" line isn't printed into status()

local M = {}
M.version = "1.0.1"

local defaults = {
  vncApps           = { "RealVNC Viewer", "VNC Viewer" }, -- older RealVNC builds are named "VNC Viewer"
  dictationApps     = { "Wispr Flow" },  -- only synthetic Cmd+V coming from these apps is intercepted
  bounceApp         = "Finder",          -- app that briefly takes focus during the bounce
  pasteMethod       = "ctrl+v",          -- "ctrl+v" | "ctrl+shift+v" (experimental, Linux terminals) | "f19" (needs extras/linux)
  postDictationWait = 0.3,   -- s after Wispr's v key-up before moving focus; shorter makes Wispr ignore Fn for ~10-15 s
  pullbackMax       = 0.6,   -- s to wait for RealVNC to overwrite the Mac clipboard after losing focus (measured ~0.2 s)
  pullbackSettle    = 0.05,  -- s extra after the pull-back is detected
  syncWait          = 0.2,   -- s after re-activating the Viewer before sending the paste keys
  keyUpTimeout      = 1.0,   -- s to wait for Wispr's v key-up before pasting anyway
  installCli        = true,  -- install the `hs` command-line tool if it is missing
  alertOnFailure    = true,  -- show an on-screen alert when a paste could not be delivered
}

M.debug  = false
M.config = nil
M.stats  = { ok = 0, failed = 0, last = "none" }

local T  = hs.eventtap.event.types
local P  = hs.eventtap.event.properties
local KC = hs.keycodes.map

local cfg         = defaults
local realCmdHeld = false   -- is a physical Cmd key down right now?
local pending     = nil     -- { text, app, timer } between Wispr's v key-down and key-up
local busySince   = nil     -- set while a focus bounce is in flight

local PASTE = {
  ["ctrl+v"]       = { mods = { "ctrl" },          key = "v" },
  ["ctrl+shift+v"] = { mods = { "ctrl", "shift" }, key = "v" },
  ["f19"]          = { mods = {},                  key = "f19" },
}

local function log(fmt, ...)  if M.debug then hs.printf("[wispr-vnc-paste] " .. fmt, ...) end end
local function warn(fmt, ...) hs.printf("[wispr-vnc-paste] WARN " .. fmt, ...) end

local function now() return hs.timer.secondsSinceEpoch() end

local function contains(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

-- Exact-name lookup; hs.application.get() also matches partial names ("VNC Viewer" finds "RealVNC Viewer").
local function runningApp(name)
  for _, a in ipairs(hs.application.runningApplications()) do
    if a:name() == name then return a end
  end
  return nil
end

local function frontApp() return hs.application.frontmostApplication() end
local function frontName() local f = frontApp(); return f and f:name() or "?" end

local function record(ok, msg)
  if ok then M.stats.ok = M.stats.ok + 1 else M.stats.failed = M.stats.failed + 1 end
  M.stats.last = os.date("%Y-%m-%d %H:%M:%S ") .. (ok and "ok: " or "FAILED: ") .. msg
end

-- Wrap timer callbacks so an error can never leave the module stuck in "busy".
local function guarded(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      if M._pollTimer then M._pollTimer:stop() end
      busySince = nil
      record(false, "error: " .. tostring(err))
      warn("error: %s", tostring(err))
    end
  end
end

local function isBusy()
  if busySince and now() - busySince > 5 then
    warn("previous paste looked stuck; resetting")
    busySince = nil
  end
  return busySince ~= nil
end

local function keyEvent(key, down, flags)
  local e = hs.eventtap.event.newKeyEvent({}, key, down)
  e:setFlags(flags)
  return e
end

-- Modifier events must be flagsChanged events that themselves carry the modifier flag;
-- otherwise RealVNC drops the modifier (this is what made Ctrl+V work, see docs).
local function modifierEvent(mod, down, flags)
  local e = hs.eventtap.event.newKeyEvent({}, KC[mod], down)
  e:setType(T.flagsChanged)
  e:setFlags(flags)
  return e
end

local function sendPaste(method)
  local m = PASTE[method]
  local flags = {}
  for _, mod in ipairs(m.mods) do
    flags[mod] = true
    modifierEvent(mod, true, flags):post()
  end
  if #m.mods > 0 then hs.timer.usleep(20000) end
  keyEvent(m.key, true, flags):post()
  keyEvent(m.key, false, flags):post()
  if #m.mods > 0 then hs.timer.usleep(20000) end
  for i = #m.mods, 1, -1 do
    flags[m.mods[i]] = nil
    modifierEvent(m.mods[i], false, flags):post()
  end
end

local function activateBounceApp(name)
  local app = runningApp(name)
  if app then app:activate() else hs.application.launchOrFocus(name) end
end

-- After focus leaves the Viewer, poll the clipboard until RealVNC overwrites it with the
-- Linux clipboard (or until pullbackMax), then continue.
local function waitForPullback(cb)
  local cc = hs.pasteboard.changeCount()
  local t0 = now()
  local poll
  poll = hs.timer.doEvery(0.02, guarded(function()
    local dt = now() - t0
    local changed = hs.pasteboard.changeCount() ~= cc
    if changed or dt > cfg.pullbackMax then
      poll:stop()
      if changed then log("clipboard pull-back after %.0f ms", dt * 1000)
      else warn("no clipboard pull-back within %.0f ms", cfg.pullbackMax * 1000) end
      M._settleTimer = hs.timer.doAfter(changed and cfg.pullbackSettle or 0, cb)
    end
  end))
  M._pollTimer = poll
end

local function pasteViaFocusBounce(text, vncApp)
  busySince = now()
  activateBounceApp(cfg.bounceApp)
  waitForPullback(guarded(function()
    hs.pasteboard.setContents(text)
    vncApp:activate()
    M._syncTimer = hs.timer.doAfter(cfg.syncWait, guarded(function()
      busySince = nil
      if not contains(cfg.vncApps, frontName()) then
        warn("VNC viewer not frontmost (front=%s); paste skipped", frontName())
        record(false, "VNC viewer was not frontmost (front=" .. frontName() .. ")")
        if cfg.alertOnFailure then
          hs.alert.show("Wispr → VNC paste failed: the VNC window was not in front.\nThe text is on the clipboard.")
        end
        return
      end
      sendPaste(cfg.pasteMethod)
      local n = utf8.len(text) or #text
      record(true, string.format("pasted %d chars via %s", n, cfg.pasteMethod))
      log("pasted %d chars via %s", n, cfg.pasteMethod)
    end))
  end))
end

local function fromDictationApp(e)
  local pid = e:getProperty(P.eventSourceUnixProcessID)
  if not pid or pid <= 0 then return false end
  local app = hs.application.applicationForPID(pid)
  return app ~= nil and contains(cfg.dictationApps, app:name())
end

local function fire()
  local p = pending
  pending = nil
  if p.timer then p.timer:stop() end
  -- Let Wispr finish its own paste sequence before moving focus.
  M._fireTimer = hs.timer.doAfter(cfg.postDictationWait, guarded(function()
    pasteViaFocusBounce(p.text, p.app)
  end))
end

-- Intercept only a synthetic Cmd+V (no physical Cmd held) that comes from the dictation app
-- while the VNC viewer is frontmost. Everything else passes through untouched.
local function onKey(e)
  if e:getKeyCode() ~= KC["v"] then return false end

  if e:getType() == T.keyUp then
    if pending then fire(); return true end
    return false
  end

  if not e:getFlags().cmd or realCmdHeld then return false end
  local app = frontApp()
  if not app or not contains(cfg.vncApps, app:name()) or not fromDictationApp(e) then return false end
  if isBusy() or pending then
    warn("previous paste still running; this one was dropped")
    record(false, "dropped: previous paste still running")
    return true
  end

  local text = hs.pasteboard.getContents()
  if not text or text == "" then
    warn("clipboard has no text; letting Cmd+V through")
    return false
  end

  log("intercepted Cmd+V from dictation app (%d chars)", utf8.len(text) or #text)
  busySince = now()  -- covers the gap between fire() and the bounce, so a second dictation is dropped, not interleaved
  pending = { text = text, app = app }
  pending.timer = hs.timer.doAfter(cfg.keyUpTimeout, guarded(function()
    if pending then warn("no v key-up from dictation app; pasting anyway"); fire() end
  end))
  return true
end

local function ensureCli()
  if hs.ipc.cliStatus(nil, true) then return end
  if hs.fs.attributes("/opt/homebrew/bin") then
    if hs.ipc.cliStatus("/opt/homebrew", true) then return end
    if hs.ipc.cliInstall("/opt/homebrew", true) then
      hs.printf("[wispr-vnc-paste] installed the hs command-line tool into /opt/homebrew/bin")
      return
    end
  end
  if hs.ipc.cliInstall(nil, true) then
    hs.printf("[wispr-vnc-paste] installed the hs command-line tool into /usr/local/bin")
    return
  end
  warn("could not install the hs command-line tool; run hs.ipc.cliInstall() in the Hammerspoon console")
end

--- Start (or restart) the fix. `opts` overrides any key of the defaults table, plus `debug`.
function M.start(opts)
  M.stop()
  opts = opts or {}
  local c = {}
  for k, v in pairs(defaults) do c[k] = v end
  for k, v in pairs(opts) do
    if k == "debug" then M.debug = v
    elseif defaults[k] == nil then warn("unknown option %q ignored", tostring(k))
    else c[k] = v end
  end
  if not PASTE[c.pasteMethod] then
    warn("unknown pasteMethod %q; using ctrl+v", tostring(c.pasteMethod))
    c.pasteMethod = "ctrl+v"
  end
  cfg = c
  M.config = c

  if c.installCli then pcall(ensureCli) end

  M._flagTap = hs.eventtap.new({ T.flagsChanged }, function(e)
    realCmdHeld = e:getFlags().cmd == true
    return false
  end):start()

  M._keyTap = hs.eventtap.new({ T.keyDown, T.keyUp }, function(e)
    local ok, res = pcall(onKey, e)
    if not ok then warn("key handler error: %s", tostring(res)); return false end
    return res
  end):start()

  -- macOS disables event taps that time out (e.g. under heavy load); turn them back on.
  M._watchdog = hs.timer.doEvery(5, function()
    for _, tap in ipairs({ M._flagTap, M._keyTap }) do
      if tap and not tap:isEnabled() then
        warn("event tap was disabled by macOS; re-enabling")
        tap:start()
      end
    end
  end)

  if not hs.accessibilityState() then
    warn("Hammerspoon has no Accessibility permission; key interception will not work until it is granted")
  end
  hs.printf("[wispr-vnc-paste] loaded v%s (pasteMethod=%s)", M.version, c.pasteMethod)
  return M
end

--- Stop intercepting. Safe to call repeatedly.
function M.stop()
  for _, k in ipairs({ "_keyTap", "_flagTap", "_watchdog", "_pollTimer", "_settleTimer", "_syncTimer", "_fireTimer" }) do
    if M[k] then M[k]:stop(); M[k] = nil end
  end
  if pending and pending.timer then pending.timer:stop() end
  pending, busySince, realCmdHeld = nil, nil, false
end

--- Human/agent-readable health report.
function M.status()
  local c = M.config or defaults
  local function apps(names)
    local out = {}
    for _, n in ipairs(names) do
      out[#out + 1] = n .. (runningApp(n) and " (running)" or " (not running)")
    end
    return table.concat(out, ", ")
  end
  local function tapState(tap)
    if not tap then return "not started" end
    return tap:isEnabled() and "enabled" or "DISABLED"
  end
  local lines = {
    "wispr-vnc-paste v" .. M.version,
    "started: " .. tostring(M._keyTap ~= nil),
    "accessibility: " .. tostring(hs.accessibilityState()),
    "key tap: " .. tapState(M._keyTap) .. ", modifier tap: " .. tapState(M._flagTap),
    "vncApps: " .. apps(c.vncApps),
    "dictationApps: " .. apps(c.dictationApps),
    "bounceApp: " .. apps({ c.bounceApp }),
    "pasteMethod: " .. c.pasteMethod,
    "debug: " .. tostring(M.debug),
    string.format("pastes: ok=%d failed=%d last=%s", M.stats.ok, M.stats.failed, M.stats.last),
  }
  return table.concat(lines, "\n")
end

return M
