# Dev notes — Monitor Settings plugin

## Status (parked 2026-08-15 — awaiting hardware test pass)

Everything below shipped on 2026-08-15, dual-pushed, manifest at
**0.3.1**, no release tag yet (waiting on the hardware pass):

- `905e44c` — bash TUI replaced by native omarchy-shell plugin
  (bar widget 󰍹 + panel + monitors.sh). Old TUI preserved at tag
  `v0.1-tui`.
- Absorbed the stock Display panel: brightness (backlight/DDC, async
  probe), text size, per-display enable/disable. First open now ASKS
  before retiring the stock icon (`deae2ab`, chooser dialog, recorded
  once).
- Two O4 landmines found and fixed along the way: persistence must
  target **monitors.lua** (the .conf chain is never read), and live
  applies must use **hyprctl eval hl.monitor** (`keyword` is rejected).
  Details under Gotchas.
- `36cc38d` — main-monitor switch (moves the pick to 0,0, shifts the
  rest) and the drag-to-arrange mini-map editor with edge snapping.
- `028667b` — 14 fixes from a full QML review (brightness write queue,
  probe-clobber guard, stale arrange state on close, chooser hover
  gate, row-identity selection across rebuilds, and smaller ones).

Verified on one physical monitor plus a `hyprctl output create
headless` second display, driven with wtype. **Not yet verified on
real hardware:** everything in the test checklist at the bottom —
especially mouse-dragging in the arrange editor, set-main on physical
dual-head, brightness on a laptop backlight, and the first-open dialog
on a fresh install.

## What this is

v0.2.0 replaced the bash TUI (`monitor-tui.sh`, still in git history ≤ v0.1)
with a native omarchy-shell plugin: `manifest.json` + `BarWidget.qml` +
`Panel.qml` + `monitors.sh`. Same job, same config file, no terminal.

It then absorbed the first-party Display panel (`omarchy.monitor`):
brightness, text size, and per-display enable/disable now live here too.
The first open ASKS whether to retire the stock bar icon (chooser dialog:
replace / keep both — there is no plugin install hook, so first-open is
the earliest we can ask). The answer lands once in
`~/.local/state/nosignal-monitor-settings/takeover-done`; Esc postpones;
re-enabling the stock plugin later sticks. The stock SUPER+CTRL+D bind
targets the dead first-party id after a replace — README documents the
bindings.lua re-point.

## Architecture

- **Panel.qml** — all UI and the live-apply path. Picking a value builds a
  full `hl.monitor()` spec (run via `hyprctl eval` — `keyword` is dead under the O4 Lua config) with ONE field overridden (so a scale
  change never resets rotation, etc.) and runs specs one at a time through a
  Process so hyprctl's refusal reasons land on the status line. After any
  apply, a 450 ms timer re-reads state — the panel never trusts its own idea
  of the layout.
- **monitors.sh** — `state` (one JSON blob: live monitors + config/backup
  flags), `brightness` (slow async probe), `save` (serializes the LIVE
  hyprctl state into a marker-bracketed block of `hl.monitor()` lines in
  **monitors.lua**, backup first, refuses an empty block), `restore`
  (backup back + `hyprctl reload`).
- Live changes are deliberately un-saved until the user picks "Save current
  layout" — a bad mode change is undone by re-picking or `hyprctl reload`.
- `ensureSelfReference()` (copied from the sibling plugins) claims a
  `plugins[]` entry in shell.json on first open so the keybinding survives
  the bar icon being removed. See omarchy PR #6510 — harmless no-op once
  that lands.

## Dev workflow

```bash
ln -sfn "$PWD" ~/.config/omarchy/plugins/nosignal.monitor-settings
omarchy-shell shell rescanPlugins
omarchy plugin enable nosignal.monitor-settings right
omarchy-shell shell toggle nosignal.monitor-settings
```

Edits to the QML hot-reload (the shell watches local plugins). QML errors go
to `/run/user/$UID/quickshell/by-pid/*/log.log`, not the terminal.

Checks before shipping:

```bash
shellcheck monitors.sh
omarchy plugin validate .
```

**Testing multi-monitor UI on a single-monitor box:** Hyprland can fake a
display — `hyprctl output create headless TESTMON` (remove with
`hyprctl output remove TESTMON`). It shows up in `monitors all -j` like a
real 1920x1080 output, so Enabled/Position/Main rows and the arrange
editor all light up. `wtype -k <key>` drives the panel's exclusive-focus
keyboard for hands-off testing. Put the real monitor back at 0,0 before
removing the headless one if you tested "set main".

## Gotchas

- **Persistence MUST target `~/.config/hypr/monitors.lua`, never
  monitors.conf.** Omarchy 4 runs Hyprland from `hyprland.lua`
  (native Hyprland Lua config; `hyprctl plugin list` is empty — it's
  built in). The old `hyprland.conf` → `source = monitors.conf` chain
  still sits in ~/.config/hypr but is NEVER read. v0.2.0 originally
  saved to monitors.conf: save "worked", then any reload re-ran the
  stock wildcard `hl.monitor({ output = "", scale = "auto" })` from
  monitors.lua and stomped everything — "it's not saving my changes".
  Fixed by writing a marker block of specific `hl.monitor()` lines at
  the end of monitors.lua; specific outputs beat the catch-all, and
  the user's own lines are preserved (block is stripped/re-appended
  idempotently, trailing blanks trimmed). Full spec keys confirmed in
  `/usr/share/hypr/stubs/hl.meta.lua` (`HL.MonitorSpec`: mode,
  position, scale, transform, vrr, disabled, mirror, …).
- **Side effect to know:** once a specific hl.monitor line exists for a
  monitor, the stock SUPER scaling keys (omarchy-hyprland-monitor-scaling)
  still apply live but persist only to the wildcard line — which the
  specific line overrides. Scale changes should go through this panel
  (or the saved block re-saved) to stick.
- **`omarchy-restart-shell` after any QML change.** The inotify watcher on
  `~/.config/omarchy/plugins` does not follow the symlinked dev folder, and
  even `rescanPlugins` serves Qt's stale component cache. "My edit did
  nothing" is almost always this.
- **The brightness probe can take ~12 s.** `omarchy-brightness-display` on a
  monitor without working DDC/CI burns 12 seconds of i2c retries before
  giving up. That's why `monitors.sh state` never touches brightness — the
  probe is a separate `brightness` subcommand run async once per open, and
  the row appears only when a value lands.

- `omarchy plugin enable` right after symlinking fails with "not known" —
  run `omarchy-shell shell rescanPlugins` first.
- hyprctl reports refreshRate as a float ("59.997") and availableModes with
  "Hz" suffixes; everything is normalized to `WxH@INT` before display or
  apply, and modes are deduplicated after rounding.
- Position maths uses LOGICAL sizes (width/scale, swapped when transform is
  odd) — raw pixel sizes put monitors in the wrong place at fractional
  scale.
- `save` reads back from hyprctl rather than from panel state, so what lands
  in monitors.lua is always what is actually on screen.

## Test checklist (hardware pass)

- [ ] Resolution change applies live and shows in the row after refresh
- [ ] Scale presets apply; odd scale set outside presets still shows as current
- [ ] VRR toggles (monitor must support it)
- [ ] Rotation 90° → logical size swaps in the Scale row
- [ ] Save writes the marker block into monitors.lua (+ .bak); restore puts the old file back
- [ ] Multi-monitor: Position row appears, left/right/above/below coordinates sane
- [ ] Multi-monitor: "Set main" moves the picked monitor to 0,0 and shifts the
      rest (verified with a headless output; needs a real dual-head pass)
- [ ] Multi-monitor: arrange editor — real mouse DRAG + edge snap (only
      keyboard nudge was verifiable headless), apply → positions stick
- [ ] Multi-monitor: Enabled toggle disables/re-enables a display; last
      enabled one refuses with a status-line message; save writes `disable`
- [ ] Keybinding works with the bar icon removed (self-reference)
- [ ] Laptop with backlight: Brightness row appears, ←/→ adjusts, chooser picks work
- [ ] Text size ←/→ steps the shell font and the row tracks Style.font.baseSize
- [ ] Fresh install: first open removes the stock Display icon; `omarchy
      plugin enable omarchy.monitor` brings it back and it stays
