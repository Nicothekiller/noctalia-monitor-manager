# noctalia-monitor-manager

Noctalia v5 plugin source: runtime monitor management for Hyprland.

- **Phase 1 (done):** per-monitor mode, scale, position, enable/disable — applied
  at runtime with `hyprctl keyword monitor`, never written to disk.
- **Phase 2 (done):** move workspaces between monitors — drag workspace chips
  onto another monitor column, or use the workspace/target selects + Move.
  Move-only, no focus change (`hl.dsp.workspace.move`).

## Layout

```
catalog.toml          source catalog (single plugin for now)
monitors/             the plugin (id `nic/monitors`)
  plugin.toml
  service.luau        polls hyprctl, owns snapshot/apply/revert/move
  panel.luau          board panel (id `nic/monitors:board`)
  widget.luau         bar widget summary, click opens the board
  translations/en.json
```

## Develop

Add as a path source (repo root acts as the source dir):

```
noctalia msg plugins source add monitors-dev path /home/nic/Documents/programacion/noctalia-monitor-manager
```

Then enable `nic/monitors` in Settings → Plugins (or
`noctalia msg plugins enable nic/monitors`), add the widget from the bar
picker, and open the board with:

```
noctalia msg panel-toggle nic/monitors:board
```

`.luau` edits hot-reload; `plugin.toml` edits need a config reload.

## Test

```
noctalia msg plugin nic/monitors:state all refresh
noctalia msg plugin nic/monitors:state all move "3 DP-1"
noctalia msg plugin nic/monitors:state all revert
```

## Notes

- Requires Hyprland 0.55+ with the **Lua config provider** (i.e. `hyprland.lua`).
  Applies go through `hyprctl eval 'hl.monitor({...})'` because `hyprctl keyword`
  is rejected by non-legacy parsers. Re-enables always send `disabled = false`
  explicitly (omitting it leaves the output off).
- Runtime-only: applied rules vanish on Hyprland restart (intended for a
  nomadic multi-machine setup). **Copy Lua** copies equivalent
  `hl.monitor({...})` lines for manual saving elsewhere.
- `hyprctl monitors all -j` is the source of modes/geometry; reported mode
  strings have any `Hz` suffix stripped before use in rules.
- Not affiliated with the Noctalia project.
