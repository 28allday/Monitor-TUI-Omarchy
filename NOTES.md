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
shellcheck monitors.sh test/run-tests.sh test/integration.sh
omarchy plugin validate .
sh test/run-tests.sh              # unit suite — safe anywhere, no Hyprland
RUN_LIVE=1 sh test/integration.sh # live suite — FLICKERS REAL DISPLAYS
```

**Test suite (test/):**
- `run-tests.sh` — 22 unit checks on monitors.sh with a mock hyprctl
  (`test/mock/`) and a temp $HOME, so it runs anywhere jq exists and never
  touches real config: block writing, wildcard/user-line preservation,
  double-save idempotency, lid-safe internal-panel rule, disabled-external
  persistence, carry-over of unplugged outputs (incl. no-duplicate + its
  own idempotency), refusal on empty state, restore round-trip, state JSON.
- `integration.sh` — 11 live checks against the running session (guarded
  by RUN_LIVE=1; snapshots the full layout + config first and restores
  both via an EXIT trap): mode/position/rotation applies, disable,
  the implicit-vs-explicit `disabled = false` eval semantics (fails loudly
  if Hyprland ever changes it), batched multi-monitor apply, lid-safe save
  against real state, live save idempotency, restore. Multi-monitor cases
  self-skip on a single head. What it CANNOT see: Hyprland's overlap
  banner (screen-only) and everything mouse-driven — those stay on the
  manual checklist below.

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
- **Lid-save bug (hit 2026-08-15 on real hardware, FIXED same day):** because
  `save` snapshots hyprctl state, saving while the laptop lid was closed
  persisted `hl.monitor({ output = "eDP-1", disabled = true })`. Reopen the
  lid with the external unplugged and eDP-1 stayed disabled — Hyprland ran on
  a headless FALLBACK output, screen black, no local way in (recovered over
  SSH by editing the marker block; a live `hyprctl eval` re-enable
  is stomped by the persisted line).
  **Fix (in monitors.sh save):** internal panels (name matching
  `^(eDP|LVDS|DSI)`) are never persisted as `disabled = true` — the lid
  switch owns their runtime state; instead their full spec is saved with
  `position = "auto"` (a disabled monitor's reported offset is stale).
  Deliberately disabled *external* outputs still persist as disabled.
  Trade-off: an internal panel disabled by hand in the panel comes back on
  the next config reload — safe beats sticky for the built-in screen.
- **`hyprctl eval hl.monitor(…)` is NOT a reliable apply on O4 — the Lua
  config engine owns monitor state.** Seen live 2026-08-15: a scale change
  evaluated fine, held for ~800ms, then snapped back to the config-block
  values; re-evaluating didn't help, and nothing appears in any log (the
  revert is silent). Yet identical evals had stuck for minutes earlier in
  the same session — the stomping seems to arm at some point (likely after
  a config reload) and then reverts every subsequent eval. The config FILE
  is authoritative and live-reloads on write within ~2–6s. So the panel now
  applies through BOTH channels (`runApply`): `monitors.sh patch` writes
  the spec lines into the marker block (replace-or-append per output,
  backup first) for the state that actually holds, plus the batched eval
  for instant feedback when the engine allows it. Consequence: applies now
  persist immediately — "Save current layout" is reconciliation (it also
  captures drags done outside the panel), and "Restore previous" is the
  undo. Lid safety holds in both paths: an internal panel's
  `disabled = true` is evaluated live but never written to the block.
- **VRR has three gates and the panel only controls one.** The per-monitor
  `vrr` flag does nothing unless (a) the display link actually offers
  adaptive sync — check `edid-decode /sys/class/drm/<conn>/edid` for an
  Adaptive Sync block; FreeSync-over-HDMI is an AMD extension NVIDIA's
  driver won't do, so a FreeSync monitor on an NVIDIA HDMI port reads as
  no-VRR — and (b) Hyprland's global `misc.vrr` is enabled (default 0 =
  off; runtime: `hyprctl eval "hl.config({ [\"misc.vrr\"] = 1 })"`).
  With the global off the per-monitor toggle "works" (eval says ok) but
  `monitors all -j` keeps reporting the old state, and the reported value
  can lag a commit behind. The panel's VRR row is honest about state but
  can't explain WHY a toggle bounced — candidate future improvement.
- **Single-monitor mode/scale/rotation changes resize the logical footprint
  in place — neighbours must move with the delta.** Scaling the eDP from 2x
  to 1.6x grows it 960→1200 logical wide straight into an external parked
  at x=960 → overlap → Hyprland's banner (missed by the first hardware pass,
  which only tested a shrinking change). applyMonitor now shifts every
  enabled monitor past the old right/bottom edge by the width/height delta,
  batched into the same eval — growth stays adjacent, shrink closes the gap.
  Verified both directions on hardware (2x↔1.875x with the external at the
  eDP's right edge).
- **A gap between monitors strands the cursor** — it can only cross where
  edges touch exactly, so a drag that dropped a monitor 896px away from its
  neighbour (snap only reaches 60px) left the built-in panel unreachable by
  mouse and looked like "cursor invisible on the second screen" (hunted as
  a rendering bug for a while: hardware-cursor state, software cursors —
  all red herrings; `hyprctl cursorpos` pinned at the reachable monitor's
  far edge was the tell). applyArrange now refuses disconnected layouts
  (`rectsTouch`/`arrangeConnected` — exact edge contact with span overlap,
  flood fill for >2 monitors) with a footer warning, same pattern as the
  overlap refusal.
- **Hyprland accepts overlapping layouts but fires its "monitor layout is
  set up incorrectly" banner** (screen notification only — nothing in the
  log, nothing on hyprctl's stdout, so runApply can't catch it). Found
  2026-08-15: a drag in the arrange editor dropped a monitor 40 px into
  its neighbour — snap only helps within 60 px of an edge — and every
  apply after that flashed the banner. Two-part fix: applyArrange refuses
  an overlapping layout (footer warning + urgent borders on the clashing
  boxes, `rectOverlaps()`), and all multi-monitor applies (arrange,
  set-main, preset) are batched into ONE `hyprctl eval` — applied one at
  a time, even a valid target layout passes through a transient overlap
  (A moved, B not yet) and trips the banner; batched, Hyprland never sees
  one (verified on hardware).
- **Re-enabling a monitor needs an EXPLICIT `disabled = false`.** A spec
  that merely omits `disabled` does not clear a runtime disable — hyprctl
  eval answers "ok" and nothing changes (cost the Enabled toggle its
  re-enable half until 2026-08-15; found live when a replugged external
  came back listed-but-disabled). The config-reload path is different:
  there a plain spec does re-enable.
- **Save away from the dock no longer loses the dock's settings:** hyprctl
  only reports connected monitors, so a save used to rewrite the block with
  just what's plugged in (a road save dropped the HDMI line). `save` now
  carries over previous-block lines for outputs not currently connected.
  Verified idempotent (double save) on hardware 2026-08-15.

## Test checklist (hardware pass)

2026-08-15 remote pass on real dual-head hardware (laptop eDP 1920x1200@120
scale 2 + 4K external over HDMI): everything scriptable below verified by
driving `hyprctl eval` + monitors.sh over SSH. UI-interaction rows still
need a hands-on pass.

- [x] Resolution change applies live (4K↔1440p verified) — row refresh not yet eyeballed
- [x] Scale applies live (1.5 ↔ 1.666667 verified)
- [ ] VRR toggles (monitor must support it) — request on this 4K HDMI display
      came back `vrr: false`: link doesn't offer it, so still unverified
- [x] Rotation 90° applies live — logical-size swap in the row not yet eyeballed
- [x] Save writes the marker block into monitors.lua (+ .bak); restore puts
      the old file back; double save is byte-identical (idempotent)
- [x] Multi-monitor: coordinates sane on real dual-head (external 0,0 +
      eDP 2560,98 round-trips through save/restore exactly)
- [ ] Multi-monitor: "Set main" via the UI on real dual-head
- [x] Multi-monitor: arrange editor — keyboard path verified on hardware
      (open, tab-select, nudge, overlap refusal with footer warning + red
      borders, clean apply, positions stick); real mouse DRAG still needs
      a hands-on check
- [x] Multi-monitor: Enabled toggle disables/re-enables both external and
      internal (re-enable needs the explicit `disabled = false` fix); UI
      toggle verified on hardware for the external
- [x] Lid-safe save: with eDP runtime-disabled, save writes its full spec
      with `position = "auto"`, never `disabled = true`
- [ ] Keybinding works with the bar icon removed (self-reference)
- [x] Brightness: external DDC/CI (4K display) answers in ~0.3 s with a
      correct percent; laptop-backlight row (amdgpu_bl2) ←/→ still needs a
      hands-on check
- [ ] Text size ←/→ steps the shell font and the row tracks Style.font.baseSize
- [ ] Fresh install: first open removes the stock Display icon; `omarchy
      plugin enable omarchy.monitor` brings it back and it stays
