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

-- Builds the `hl.monitor({...})` snippet for both live apply
-- (`hyprctl eval '<snippet>'`, via the service) and Copy-Lua.
local function buildSnippet(mon, draft)
  if not draft.enabled then
    return string.format('hl.monitor({ output = "%s", disabled = true })', mon.name)
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
    'hl.monitor({ output = "%s", mode = "%s", position = "%s", scale = %s, disabled = false })',
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
    ui.label({ text = noctalia.tr("mode"), fontSize = 12, color = "on_surface_variant" }),
    ui.select({
      options = opts,
      selectedIndex = draft.modeIdx,
      onChange = function(idx)
        drafts[name].modeIdx = tonumber(idx) or 0
        render()
      end,
    }),
    ui.label({ text = string.format("%s — %s", noctalia.tr("scale"), tostring(draft.scale)), fontSize = 12, color = "on_surface_variant" }),
    ui.slider({
      min = 0.5, max = 3, step = 0.05, value = draft.scale,
      onChange = function(v)
        drafts[name].scale = tonumber(v) or 1
        render()
      end,
    }),
    ui.label({ text = noctalia.tr("position"), fontSize = 12, color = "on_surface_variant" }),
    ui.select({
      options = posOpts,
      selectedIndex = draft.posIdx,
      onChange = function(idx)
        drafts[name].posIdx = tonumber(idx) or 0
        render()
      end,
    }),
  }
  if posExtra ~= nil then
    table.insert(cardChildren, posExtra)
  end
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
        sendCmd({ op = "apply", name = name, snippet = buildSnippet(mon, d) })
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
      table.insert(lines, buildSnippet(mon, draft))
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
  local snippets = {}
  for _, mon in ipairs(monitors) do
    local draft = drafts[mon.name]
    if draft ~= nil then
      table.insert(snippets, { name = mon.name, snippet = buildSnippet(mon, draft) })
    end
  end
  sendCmd({ op = "apply_all", snippets = snippets })
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
    syncDrafts()
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
