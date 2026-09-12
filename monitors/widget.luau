--!nonstrict
-- nic/monitors bar widget - compact monitor summary, opens the board panel.
-- Click toggles nic/monitors:board; tooltip lists per-monitor details.

local monitors = noctalia.state.get("monitors.list") or {}
local workspaces = noctalia.state.get("monitors.workspaces") or {}

local function render()
  if #monitors == 0 then
    barWidget.setGlyph("device-desktop")
    barWidget.setText("…")
    barWidget.setTooltip(noctalia.tr("title"))
    return
  end
  local parts = {}
  local tips = {}
  for _, mon in ipairs(monitors) do
    local count = 0
    for _, w in ipairs(workspaces) do
      if w.monitor == mon.name then
        count += 1
      end
    end
    local mark = mon.focused and "●" or "○"
    if mon.disabled then
      mark = "✕"
    end
    table.insert(parts, string.format("%s%d", mark, count))
    table.insert(tips, string.format("%s: %dx%d s=%s (%d ws)", mon.name, mon.width, mon.height, tostring(mon.scale), count))
  end
  barWidget.setGlyph("device-desktop")
  barWidget.setText(table.concat(parts, " "))
  barWidget.setTooltip(table.concat(tips, "\n"))
end

noctalia.state.watch("monitors.list", function(value)
  if type(value) == "table" then
    monitors = value
    render()
  end
end)

noctalia.state.watch("monitors.workspaces", function(value)
  if type(value) == "table" then
    workspaces = value
    render()
  end
end)

function update()
  noctalia.setUpdateInterval(2000)
  render()
end

function onClick()
  noctalia.togglePanel("nic/monitors:board")
end

function onIpc(event, _payload)
  if event == "refresh" then
    noctalia.state.set("monitors.cmd", { op = "refresh" })
  end
end
