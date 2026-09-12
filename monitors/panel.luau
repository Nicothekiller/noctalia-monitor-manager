--!nonstrict
-- nic/monitors panel - runtime monitor setup + workspace mover.
--
-- Top: one card per monitor (mode / scale / position / enable + Apply).
-- Bottom: workspace columns with drag-and-drop between monitors (move-only,
-- no focus change) plus a select-based fallback for keyboard users.
-- Open with: noctalia msg panel-toggle nic/monitors:board

local WS_DRAG = "nic-ws"
local POS_PRESETS = { "auto", "auto-right", "auto-left", "auto-up", "auto-down", "custom" }

local showSpecial = noctalia.getConfig("show_special")
if type(showSpecial) ~= "boolean" then
  showSpecial = false
end

local monitors = noctalia.state.get("monitors.list") or {}
local workspaces = noctalia.state.get("monitors.workspaces") or {}
local errMsg = noctalia.state.get("monitors.error")
local statusMsg = noctalia.state.get("monitors.status") or noctalia.tr("status_idle")

-- Per-monitor form state. Initialized from polled data, never overwritten
-- while the monitor stays connected, so polling can't clobber edits.
local drafts = {}
-- Set before a user-initiated apply/revert: the next poll then re-inits
-- those drafts from reality (converges e.g. a stale mirror select), while
-- routine polls leave in-progress edits alone. Narrowly scoped so a single
-- Apply doesn't wipe edits on other cards. (Tiny race: a routine poll
-- landing mid-apply consumes the pending resync early; worst case the
-- select stays stale until Refresh — the pre-existing behavior.)
local resyncNames = {}
local resyncAll = false
-- Fallback mover selections (0-based indices into the option lists).
local moveWsIdx = 0
local moveMonIdx = 0

local function sendCmd(cmd)
  noctalia.state.set("monitors.cmd", cmd)
end

local function modeOptions(mon)
  local opts = { "preferred", "highres", "highrr" }
  for _, m in ipairs(mon.modes or {}) do
    table.insert(opts, m)
  end
  return opts
end

local function currentModeString(mon)
  if mon.width > 0 and mon.height > 0 and mon.refreshRate > 0 then
    return string.format("%dx%d@%s", mon.width, mon.height, tostring(mon.refreshRate))
  end
  return "preferred"
end

local function initDraft(mon)
  local opts = modeOptions(mon)
  -- Match current mode by resolution + numeric rate: tostring(refreshRate)
  -- rarely reproduces the exact decimals hyprctl reports ("60" vs "60.00").
  local idx = 0
  if mon.width > 0 then
    local prefix = string.format("%dx%d@", mon.width, mon.height)
    for i, opt in ipairs(opts) do
      if string.sub(opt, 1, #prefix) == prefix and mon.refreshRate > 0 then
        local rate = tonumber(string.sub(opt, #prefix + 1))
        if rate ~= nil and math.abs(rate - mon.refreshRate) < 0.5 then
          idx = i - 1
          break
        end
      end
    end
  end
  local presetIdx = 0
  local cx, cy = "0", "0"
  if mon.x ~= 0 or mon.y ~= 0 then
    presetIdx = 5
    cx, cy = tostring(mon.x), tostring(mon.y)
  end
  drafts[mon.name] = {
    modeIdx = idx,
    scale = mon.scale or 1,
    posIdx = presetIdx,
    customX = cx,
    customY = cy,
    enabled = not mon.disabled,
    -- Source output name this monitor mirrors, or "" for extend.
    mirror = mon.mirroredFrom or "",
  }
end

local function syncDrafts()
  local seen = {}
  for _, mon in ipairs(monitors) do
    seen[mon.name] = true
    if drafts[mon.name] == nil then
      initDraft(mon)
    end
  end
  for name, _ in pairs(drafts) do
    if not seen[name] then
      drafts[name] = nil
    end
  end
end

-- Mirror target must be a connected, enabled output: mirroring a
-- missing/disabled source hits Hyprland's silent-fallback (applies as
-- unmirrored with no error), so validate before sending instead.
local function mirrorTargetValid(name)
  for _, other in ipairs(monitors) do
    if other.name == name and not other.disabled then
      return true
    end
  end
  return false
end

local function outputNameSafe(name)
  return type(name) == "string" and string.find(name, "^[%w%-%._/]+$") ~= nil
end

-- Builds the `hl.monitor({...})` snippet for both live apply
-- (`hyprctl eval '<snippet>'`, via the service) and Copy-Lua.
-- Mirror form is minimal (mode/pos/scale are inherited from the source);
-- the extend form always carries mirror = "" because a plain rule without
-- the mirror field does NOT clear an active mirror (verified live).
local function buildSnippet(mon, draft)
  local mirror = draft.mirror or ""
  if not outputNameSafe(mon.name) or (mirror ~= "" and not outputNameSafe(mirror)) then
    return nil
  end
  if not draft.enabled then
    return string.format('hl.monitor({ output = "%s", disabled = true })', mon.name)
  end
  if mirror ~= "" and mirrorTargetValid(mirror) then
    return string.format('hl.monitor({ output = "%s", mirror = "%s" })', mon.name, mirror)
  end
  local opts = modeOptions(mon)
  local mode = opts[draft.modeIdx + 1] or "preferred"
  local pos = POS_PRESETS[draft.posIdx + 1] or "auto"
  if pos == "custom" then
    local x = tonumber(draft.customX)
    local y = tonumber(draft.customY)
    if x == nil or y == nil then
      pos = "auto"
    else
      pos = string.format("%dx%d", math.floor(x), math.floor(y))
    end
  end
  local scale = math.floor((tonumber(draft.scale) or 1) * 100 + 0.5) / 100
  -- disabled = false is required explicitly when re-enabling.
  return string.format(
    'hl.monitor({ output = "%s", mode = "%s", position = "%s", scale = %s, mirror = "", disabled = false })',
    mon.name,
    mode,
    pos,
    tostring(scale)
  )
end

local function visibleWorkspaces()
  local out = {}
  for _, w in ipairs(workspaces) do
    if showSpecial or string.sub(w.name or "", 1, 8) ~= "special:" then
      table.insert(out, w)
    end
  end
  return out
end

local function wsChip(w)
  return ui.dragSource({
    key = "ws-" .. tostring(w.id),
    dragType = WS_DRAG,
    payload = tostring(w.id),
    previewAncestor = 1,
    liftFromLayout = true,
    tooltip = "Drag to another monitor",
  }, {
    ui.row({
      gap = 6,
      align = "center",
      padding = 6,
      fill = "surface_variant/0.4",
      radius = 10,
    }, {
      ui.glyph({ name = "drag-drop", size = 13, color = "on_surface_variant" }),
      ui.label({ text = w.name, flexGrow = 1 }),
    }),
  })
end

local function wsColumn(mon)
  local children = {
    ui.label({ text = mon.name, fontWeight = "bold", fontSize = 12, color = "on_surface_variant" }),
  }
  local count = 0
  for _, w in ipairs(visibleWorkspaces()) do
    if w.monitor == mon.name then
      table.insert(children, wsChip(w))
      count += 1
    end
  end
  if count == 0 then
    table.insert(children, ui.label({ text = noctalia.tr("empty_column"), fontSize = 12, color = "on_surface_variant" }))
  end
  return ui.dropZone({
    key = "ws-col-" .. mon.name,
    accepts = { WS_DRAG },
    value = mon.name,
    onDrop = "onWsDropped",
    gap = 6,
    padding = 8,
    radius = 12,
    fill = "surface_variant/0.15",
    flexGrow = 1,
  }, children)
end

local function monitorCard(mon)
  local name = mon.name
  local draft = drafts[name]
  if draft == nil then
    return ui.box({})
  end
  local opts = modeOptions(mon)
  local posOpts = POS_PRESETS
  local posIsCustom = posOpts[draft.posIdx + 1] == "custom"

  local posExtra = nil
  if posIsCustom then
    posExtra = ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("custom_x"), color = "on_surface_variant" }),
      ui.input({ key = "x-" .. name, value = draft.customX, placeholder = "0", onChange = function(v)
        drafts[name].customX = v
      end }),
      ui.label({ text = noctalia.tr("custom_y"), color = "on_surface_variant" }),
      ui.input({ key = "y-" .. name, value = draft.customY, placeholder = "0", onChange = function(v)
        drafts[name].customY = v
      end }),
    })
  end

  local badges = {}
  if mon.focused then
    table.insert(badges, ui.label({ text = "●", color = "primary", fontSize = 12 }))
  end
  if mon.disabled then
    table.insert(badges, ui.label({ text = "disabled", fontSize = 12, color = "error" }))
  end
  if mon.mirroredFrom ~= nil and mon.mirroredFrom ~= "" then
    table.insert(badges, ui.label({ text = noctalia.tr("mirroring_src", { src = mon.mirroredFrom }), fontSize = 12, color = "primary" }))
  end

  -- Mirror targets: every other *enabled* output. Index 0 is extend (off).
  local mirrorOpts = { noctalia.tr("mirror_off") }
  local mirrorIdx = 0
  for _, other in ipairs(monitors) do
    if other.name ~= name and not other.disabled then
      table.insert(mirrorOpts, other.name)
      if draft.mirror == other.name then
        mirrorIdx = #mirrorOpts - 1
      end
    end
  end
  -- Effective mirroring: a stale draft pointing at a now-missing/disabled
  -- target falls back to the extend form (see buildSnippet), so the
  -- controls must agree with what Apply would actually send.
  local isMirroring = draft.mirror ~= nil and draft.mirror ~= "" and mirrorTargetValid(draft.mirror)

  local cardChildren = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "device-desktop", size = 15, color = "primary" }),
      ui.label({ text = name, fontWeight = "bold", flexGrow = 1 }),
      ui.row({ gap = 6 }, badges),
    }),
    ui.label({
      text = string.format("%s: %s %dx%d s=%s", noctalia.tr("current"), currentModeString(mon), mon.x, mon.y, tostring(mon.scale)),
      fontSize = 12,
      color = "on_surface_variant",
    }),
    ui.label({ text = noctalia.tr("mirror"), fontSize = 12, color = "on_surface_variant" }),
    ui.select({
      options = mirrorOpts,
      selectedIndex = mirrorIdx,
      onChange = function(idx)
        local i = tonumber(idx) or 0
        if i == 0 then
          drafts[name].mirror = ""
        else
          drafts[name].mirror = mirrorOpts[i + 1] or ""
        end
        render()
      end,
    }),
  }
  -- While mirroring, mode/scale/position are inherited from the source.
  if not isMirroring then
    table.insert(cardChildren, ui.label({ text = noctalia.tr("mode"), fontSize = 12, color = "on_surface_variant" }))
    table.insert(cardChildren, ui.select({
      options = opts,
      selectedIndex = draft.modeIdx,
      onChange = function(idx)
        drafts[name].modeIdx = tonumber(idx) or 0
        render()
      end,
    }))
    table.insert(cardChildren, ui.label({ text = string.format("%s — %s", noctalia.tr("scale"), tostring(draft.scale)), fontSize = 12, color = "on_surface_variant" }))
    table.insert(cardChildren, ui.slider({
      min = 0.5, max = 3, step = 0.05, value = draft.scale,
      onChange = function(v)
        drafts[name].scale = tonumber(v) or 1
        render()
      end,
    }))
    table.insert(cardChildren, ui.label({ text = noctalia.tr("position"), fontSize = 12, color = "on_surface_variant" }))
    table.insert(cardChildren, ui.select({
      options = posOpts,
      selectedIndex = draft.posIdx,
      onChange = function(idx)
        drafts[name].posIdx = tonumber(idx) or 0
        render()
      end,
    }))
    if posExtra ~= nil then
      table.insert(cardChildren, posExtra)
    end
  end
  -- posExtra (custom X/Y) only exists inside the extend branch above;
  -- drafts are preserved while mirroring, so flipping Mirror back to Off
  -- restores the inputs.
  table.insert(cardChildren, ui.row({ gap = 12, align = "center" }, {
    ui.toggle({
      checked = draft.enabled,
      onChange = function(v)
        drafts[name].enabled = v == true or v == "true"
        render()
      end,
    }),
    ui.label({ text = noctalia.tr("enabled"), flexGrow = 1 }),
    ui.button({
      text = noctalia.tr("apply"),
      variant = "primary",
      onClick = function()
        local d = drafts[name]
        local snippet = buildSnippet(mon, d)
        if snippet == nil then
          statusMsg = noctalia.tr("err_bad_name")
          render()
          return
        end
        resyncNames[name] = true
        sendCmd({ op = "apply", name = name, snippet = snippet })
      end,
    }),
  }))

  return ui.column({
    key = "card-" .. name,
    gap = 10,
    padding = 12,
    radius = 14,
    fill = "surface_variant/0.15",
  }, cardChildren)
end

local function copyLua()
  local lines = {}
  for _, mon in ipairs(monitors) do
    local draft = drafts[mon.name]
    if draft ~= nil then
      local snippet = buildSnippet(mon, draft)
      if snippet ~= nil then
        table.insert(lines, snippet)
      end
    end
  end
  if noctalia.copyToClipboard(table.concat(lines, "\n"), "text/plain") then
    statusMsg = noctalia.tr("copied")
  else
    statusMsg = noctalia.tr("err_copy_failed")
  end
  render()
end

local function applyAll()
  -- Mirror rules only resolve when the target already exists as a monitor
  -- object: a mirror applied before its source silently falls back to
  -- unmirrored. Emit extend rules first, mirrors second.
  local plain, mirrors = {}, {}
  local skipped = {}
  for _, mon in ipairs(monitors) do
    local draft = drafts[mon.name]
    if draft ~= nil then
      local snippet = buildSnippet(mon, draft)
      if snippet == nil then
        table.insert(skipped, mon.name)
      elseif draft.enabled and draft.mirror ~= nil and draft.mirror ~= "" then
        if mirrorTargetValid(draft.mirror) then
          table.insert(mirrors, { name = mon.name, snippet = snippet })
        else
          table.insert(skipped, mon.name)
        end
      else
        table.insert(plain, { name = mon.name, snippet = snippet })
      end
    end
  end
  local snippets = {}
  for _, s in ipairs(plain) do
    table.insert(snippets, s)
  end
  for _, s in ipairs(mirrors) do
    table.insert(snippets, s)
  end
  if #skipped > 0 then
    statusMsg = noctalia.tr("warn_mirror_target", { target = table.concat(skipped, ", ") })
  end
  resyncAll = true
  sendCmd({ op = "apply_all", snippets = snippets })
  if #skipped > 0 then
    render()
  end
end

function onWsDropped(payload, value)
  sendCmd({ op = "move", ws = payload, monitor = value })
  statusMsg = noctalia.tr("status_moved", { ws = payload, monitor = value })
  render()
end

function onCloseClicked()
  panel.close()
end

function onRefreshClicked()
  for _, mon in ipairs(monitors) do
    initDraft(mon)
  end
  sendCmd({ op = "refresh" })
  render()
end

function onRevertClicked()
  resyncAll = true
  sendCmd({ op = "revert" })
end

function render()
  local cards = {}
  for _, mon in ipairs(monitors) do
    table.insert(cards, monitorCard(mon))
  end

  local wsCols = {}
  for _, mon in ipairs(monitors) do
    if not mon.disabled then
      table.insert(wsCols, wsColumn(mon))
    end
  end

  local visWs = visibleWorkspaces()
  local wsNames = {}
  local monNames = {}
  for _, w in ipairs(visWs) do
    table.insert(wsNames, w.name)
  end
  for _, mon in ipairs(monitors) do
    if not mon.disabled then
      table.insert(monNames, mon.name)
    end
  end
  if #wsNames == 0 then
    wsNames = { "—" }
  end
  if #monNames == 0 then
    monNames = { "—" }
  end
  moveWsIdx = math.min(moveWsIdx, #wsNames - 1)
  moveMonIdx = math.min(moveMonIdx, #monNames - 1)

  local errNode = nil
  if errMsg ~= nil and errMsg ~= "" then
    errNode = ui.label({ text = errMsg, fontSize = 12, color = "error" })
  end

  local body = {
    ui.label({ text = noctalia.tr("header.subtitle"), fontSize = 12, color = "on_surface_variant" }),
  }
  if errNode ~= nil then
    table.insert(body, errNode)
  end
  table.insert(body, ui.label({ text = statusMsg, fontSize = 12, color = "primary" }))
  for _, c in ipairs(cards) do
    table.insert(body, c)
  end
  table.insert(body, ui.label({ text = noctalia.tr("workspaces_title"), fontSize = 14, fontWeight = "bold" }))
  if #wsCols > 0 then
    table.insert(body, ui.row({ gap = 10, align = "stretch" }, wsCols))
  end
  table.insert(body, ui.row({ gap = 8, align = "center" }, {
    ui.column({ gap = 4, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("move_ws"), fontSize = 12, color = "on_surface_variant" }),
      ui.select({
        options = wsNames,
        selectedIndex = moveWsIdx,
        onChange = function(idx)
          moveWsIdx = tonumber(idx) or 0
          render()
        end,
      }),
    }),
    ui.column({ gap = 4, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("move_target"), fontSize = 12, color = "on_surface_variant" }),
      ui.select({
        options = monNames,
        selectedIndex = moveMonIdx,
        onChange = function(idx)
          moveMonIdx = tonumber(idx) or 0
          render()
        end,
      }),
    }),
    ui.button({
      text = noctalia.tr("move"),
      onClick = function()
        local w = visWs[moveWsIdx + 1]
        local target = monNames[moveMonIdx + 1]
        if w ~= nil and target ~= nil and target ~= "—" then
          sendCmd({ op = "move", ws = tostring(w.id), monitor = target })
          statusMsg = noctalia.tr("status_moved", { ws = w.name, monitor = target })
          render()
        end
      end,
    }),
  }))
  table.insert(body, ui.row({ gap = 8 }, {
    ui.button({ text = noctalia.tr("apply_all"), variant = "primary", onClick = "applyAllFromBtn" }),
    ui.button({ text = noctalia.tr("copy_lua"), onClick = "copyLuaFromBtn" }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", tooltip = noctalia.tr("refresh"), onClick = "onRefreshClicked" }),
      ui.button({ glyph = "history", tooltip = noctalia.tr("revert"), onClick = "onRevertClicked" }),
      ui.button({ glyph = "close", tooltip = noctalia.tr("close"), onClick = "onCloseClicked" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, body),
  }))
end

function applyAllFromBtn()
  applyAll()
end

function copyLuaFromBtn()
  copyLua()
end

function onOpen(_context)
  syncDrafts()
  render()
end

function onClose()
end

noctalia.state.watch("monitors.list", function(value)
  if type(value) == "table" then
    monitors = value
    if resyncAll then
      resyncAll = false
      resyncNames = {}
      for _, mon in ipairs(monitors) do
        initDraft(mon)
      end
    else
      for name, _ in pairs(resyncNames) do
        for _, mon in ipairs(monitors) do
          if mon.name == name then
            initDraft(mon)
            break
          end
        end
      end
      resyncNames = {}
      syncDrafts()
    end
    render()
  end
end)

noctalia.state.watch("monitors.workspaces", function(value)
  if type(value) == "table" then
    workspaces = value
    render()
  end
end)

noctalia.state.watch("monitors.error", function(value)
  errMsg = value
  render()
end)

noctalia.state.watch("monitors.status", function(value)
  if type(value) == "string" then
    statusMsg = value
    render()
  end
end)
