--!nonstrict
-- nic/monitors service - owns Hyprland monitor/workspace state.
--
-- Publishes (via noctalia.state):
--   monitors.list       array of { name, focused, disabled, width, height,
--                         refreshRate, x, y, scale, modes[], mirroredFrom }
--                         (`mirroredFrom` is the source output name or nil;
--                         hyprctl reports it as `mirrorOf`, which is "none"
--                         or a monitor *id* string, resolved via the id field.)
--   monitors.workspaces array of { id, name, monitor }
--   monitors.error      string or nil
-- Consumes:
--   monitors.cmd        { op = "apply", name, snippet }
--                       { op = "apply_all", snippets = { { name, snippet } } }
--                       { op = "revert" }
--                       { op = "move", ws, monitor }
--   monitors.status     last action result for the panel to display
-- IPC (target `all`): refresh | revert | move "<wsId> <monitor>"
--
-- Runtime-only by design: applies with `hyprctl eval 'hl.monitor({...})'`
-- (the Lua config provider rejects `hyprctl keyword`), never writes config
-- files. A snapshot of pre-apply snippets supports Revert.

local pollMs = noctalia.getConfig("poll_ms")
if type(pollMs) ~= "number" then
  pollMs = 2000
end
noctalia.setUpdateInterval(pollMs)

local lastMonitors = {}
local snapshot = nil -- array of { name, rule } or nil

local function setStatus(msg)
  noctalia.state.set("monitors.status", msg)
end

local function setError(msg)
  noctalia.state.set("monitors.error", msg)
end

-- Snapshot/extend mode: resolve the live float geometry against the
-- reported availableModes (same 0.5 Hz tolerance the panel uses), because
-- raw floats like 120.003 rarely reproduce an exact mode string and a
-- non-existent mode would fail the revert apply.
local function resolveMode(mon)
  if (mon.width or 0) <= 0 or (mon.height or 0) <= 0 then
    return "preferred"
  end
  local prefix = string.format("%dx%d@", mon.width, mon.height)
  for _, mode in ipairs(mon.modes or {}) do
    if string.sub(mode, 1, #prefix) == prefix and (mon.refreshRate or 0) > 0 then
      local rate = tonumber(string.sub(mode, #prefix + 1))
      if rate ~= nil and math.abs(rate - mon.refreshRate) < 0.5 then
        return mode
      end
    end
  end
  return "preferred"
end

local function buildSnippetFromState(mon)
  if mon.disabled then
    return string.format('hl.monitor({ output = "%s", disabled = true })', mon.name)
  end
  if mon.mirroredFrom ~= nil and mon.mirroredFrom ~= "" then
    return string.format('hl.monitor({ output = "%s", mirror = "%s" })', mon.name, mon.mirroredFrom)
  end
  local mode = resolveMode(mon)
  -- Always send disabled = false: re-enabling a previously disabled output
  -- requires it explicitly, omitting the field is not enough.
  -- Always send mirror = "": a plain rule without the mirror field does NOT
  -- clear an active mirror (verified live), only mirror = "" unmirrors.
  return string.format(
    'hl.monitor({ output = "%s", mode = "%s", position = "%dx%d", scale = %s, mirror = "", disabled = false })',
    mon.name,
    mode,
    mon.x,
    mon.y,
    tostring(mon.scale)
  )
end

local function takeSnapshot()
  if snapshot ~= nil then
    return
  end
  snapshot = {}
  for _, mon in ipairs(lastMonitors) do
    table.insert(snapshot, { name = mon.name, snippet = buildSnippetFromState(mon) })
  end
end

local function fetchWorkspaces()
  local accepted = noctalia.runAsync("hyprctl workspaces -j", function(res)
    if res.exitCode ~= 0 then
      setError("hyprctl workspaces failed: " .. (res.stderr or ""))
      return
    end
    local data, err = noctalia.json.decode(res.stdout)
    if data == nil then
      setError("workspaces parse failed: " .. (err or "?"))
      return
    end
    local ws = {}
    for _, w in ipairs(data) do
      if type(w.id) == "number" then
        table.insert(ws, { id = w.id, name = w.name or tostring(w.id), monitor = w.monitor or "" })
      end
    end
    noctalia.state.set("monitors.workspaces", ws)
    setError(nil)
  end)
  if not accepted then
    setError(noctalia.tr("err_no_hyprctl"))
  end
end

local function fetch()
  local accepted = noctalia.runAsync("hyprctl monitors all -j", function(res)
    if res.exitCode ~= 0 then
      setError("hyprctl monitors failed: " .. (res.stderr or ""))
      return
    end
    local data, err = noctalia.json.decode(res.stdout)
    if data == nil then
      setError("monitors parse failed: " .. (err or "?"))
      return
    end
    local list = {}
    -- mirrorOf is "none" or a monitor id string: resolve ids to names first.
    local idToName = {}
    for _, m in ipairs(data) do
      if type(m.name) == "string" and m.id ~= nil then
        idToName[tostring(m.id)] = m.name
      end
    end
    for _, m in ipairs(data) do
      if type(m.name) == "string" then
        local modes = {}
        if type(m.availableModes) == "table" then
          for _, mode in ipairs(m.availableModes) do
            if type(mode) == "string" then
              -- hyprctl reports e.g. "1920x1080@60.00Hz"; rules take no Hz.
              -- (parens: gsub returns 2 values, insert must see 1).
              table.insert(modes, (string.gsub(mode, "Hz$", "")))
            end
          end
        end
        table.insert(list, {
          name = m.name,
          focused = m.focused == true,
          disabled = m.disabled == true,
          width = m.width or 0,
          height = m.height or 0,
          refreshRate = m.refreshRate or 0,
          x = m.x or 0,
          y = m.y or 0,
          scale = m.scale or 1,
          modes = modes,
          mirroredFrom = idToName[tostring(m.mirrorOf)],
        })
      end
    end
    lastMonitors = list
    noctalia.state.set("monitors.list", list)
    fetchWorkspaces()
  end)
  if not accepted then
    setError(noctalia.tr("err_no_hyprctl"))
  end
end

-- Applies under the Lua config provider via `hyprctl eval` (`keyword` only
-- works with the legacy hyprlang parser). Snippet fields are constrained-safe
-- (connector names, WxH@rate, XxY, numbers); the argv form of runAsync
-- (plugin_api 24) would remove even the theoretical quoting risk.
-- Defense in depth for the `hyprctl eval '<snippet>'` shell composition:
-- our snippets are built from fixed templates + validated names/numbers,
-- but reject anything with shell-active or control characters outright so
-- no path (apply, apply-all, snapshot revert) can ever execute surprises.
local function snippetSafe(s)
  return type(s) == "string" and string.find(s, "[\n\r`$\\]") == nil
end

local function applyOne(snippet, cb)
  if not snippetSafe(snippet) then
    cb(false, "unsafe snippet rejected")
    return
  end
  noctalia.runAsync("hyprctl eval '" .. snippet .. "'", function(res)
    if res.exitCode ~= 0 then
      local detail = res.stderr or ""
      if res.stdout ~= nil and res.stdout ~= "" then
        detail = detail .. " " .. res.stdout
      end
      cb(false, detail)
    else
      cb(true, nil)
    end
  end)
end

local function applyRules(rules, done, takeSnap)
  if takeSnap ~= false then
    takeSnapshot()
  end
  local i = 0
  local function next(err)
    i += 1
    if err ~= nil then
      done(false, err)
      return
    end
    if i > #rules then
      done(true, nil)
      return
    end
    applyOne(rules[i].snippet, function(ok, e)
      if not ok then
        done(false, e)
      else
        next(nil)
      end
    end)
  end
  next(nil)
end

local function revert()
  if snapshot == nil or #snapshot == 0 then
    setStatus(noctalia.tr("status_nothing_to_revert"))
    return
  end
  local rules = snapshot
  snapshot = nil
  applyRules(rules, function(ok, err)
    if ok then
      setStatus(noctalia.tr("status_reverted"))
    else
      setError("revert failed: " .. (err or ""))
    end
    fetch()
  end, false)
end

local function moveWorkspace(ws, monitor)
  local id = tonumber(ws)
  if id == nil or monitor == nil or monitor == "" then
    return
  end
  if string.find(monitor, "^[%w%-%._/]+$") == nil then
    setError("move failed: invalid monitor name")
    return
  end
  local cmd = string.format('hyprctl dispatch \'hl.dsp.workspace.move({ workspace = %d, monitor = "%s" })\'', id, monitor)
  noctalia.runAsync(cmd, function(res)
    if res.exitCode ~= 0 then
      setError("move failed: " .. (res.stderr or ""))
    else
      setStatus(noctalia.tr("status_moved", { ws = tostring(id), monitor = monitor }))
      fetch()
    end
  end)
end

noctalia.state.watch("monitors.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  -- Clear first so a handler crash can't replay the command.
  noctalia.state.set("monitors.cmd", nil)
  if cmd.op == "apply" and type(cmd.snippet) == "string" then
    applyRules({ { snippet = cmd.snippet } }, function(ok, err)
      if ok then
        setStatus(noctalia.tr("status_applied", { name = cmd.name or "" }))
        fetch()
      else
        setError("apply failed: " .. (err or ""))
      end
    end)
  elseif cmd.op == "apply_all" and type(cmd.snippets) == "table" then
    applyRules(cmd.snippets, function(ok, err)
      if ok then
        setStatus(noctalia.tr("status_applied", { name = "all" }))
        fetch()
      else
        setError("apply failed: " .. (err or ""))
      end
    end)
  elseif cmd.op == "revert" then
    revert()
  elseif cmd.op == "move" then
    moveWorkspace(cmd.ws, cmd.monitor)
  elseif cmd.op == "refresh" then
    fetch()
  end
end)

function onOutputsChanged()
  snapshot = nil
  fetch()
end

function onConfigChanged()
  local ms = noctalia.getConfig("poll_ms")
  if type(ms) == "number" then
    noctalia.setUpdateInterval(ms)
  end
end

function onIpc(event, payload)
  if event == "refresh" then
    fetch()
  elseif event == "revert" then
    revert()
  elseif event == "move" then
    local clean = string.gsub(payload or "", "^%s*(.-)%s*$", "%1")
    local ws, mon = string.match(clean, "^(%S+)%s+(.+)$")
    if ws ~= nil and mon ~= nil and mon ~= "" then
      moveWorkspace(ws, mon)
    end
  end
end

function update()
  fetch()
end

fetch()
