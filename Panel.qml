import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// "Monitor Settings" panel. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle nosignal.monitor-settings
// The host calls open(payloadJson) / close() and reads `opened`; it also
// injects `shell` right after the Loader resolves (see onShellChanged).
//
// The panel is a flat list of setting rows grouped per monitor: resolution,
// scale, position (multi-monitor only), rotation and VRR. Picking a value
// applies it LIVE via `hyprctl eval "hl.monitor({…})"` — keyword is dead under
// the O4 Lua config — and nothing touches disk until the "Save layout" row writes a marked
// block of hl.monitor() lines in ~/.config/hypr/monitors.lua (backing the
// file up first). monitors.sh beside this file does the state read and the
// save/restore, so the file handling stays shellcheck-able and runnable by
// hand. monitors.lua — NOT monitors.conf — because Omarchy 4 runs Hyprland
// from hyprland.lua and never reads the old .conf chain.
//
// A live change that goes wrong is recoverable by design: nothing was saved,
// so picking the old value back — or `hyprctl reload` — undoes it.
Item {
  id: root

  property bool opened: false

  readonly property string selfId: "nosignal.monitor-settings"

  // Injected by the shell host after the Loader resolves. Used to keep the
  // host's open-flag honest on close(), and to self-restore if the host's
  // panel Instantiator rebuild destroys a visibly-open instance.
  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  // monitors.sh sits beside this file; strip the file:// scheme for argv.
  readonly property string scriptPath: String(Qt.resolvedUrl("monitors.sh")).replace(/^file:\/\//, "")

  // ------------------------------------------------------------------ state
  property var monitors: []          // hyprctl monitors -j, verbatim
  property bool haveConfig: false    // monitors.lua exists
  property bool haveBackup: false    // monitors.lua.bak exists
  property bool loaded: false
  property bool noJq: false
  // Live changes applied but not yet written to monitors.lua.
  property bool dirty: false
  property string lastError: ""

  // Backlight percent for the focused monitor; -1 = no controllable
  // backlight (the normal desktop case), which hides the row entirely.
  property int brightness: -1
  property string focusedName: ""

  // Same curated stops the first-party Display panel uses; the CLI
  // (omarchy-display-text-size) accepts any integer, the panel snaps.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]

  readonly property int enabledCount: {
    var n = 0
    for (var i = 0; i < root.monitors.length; i++)
      if (root.monitors[i].disabled !== true) n++
    return n
  }

  property var items: []             // flat rows: group captions + settings + actions
  property int selectedIndex: -1
  property bool cursorActive: true

  // Shares the [menu] surface tokens so themes that style the menu style this
  // panel too — same approach as the sibling nosignal.* panels.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color selBg: Color.menu.selectedBackground
  property color selText: Color.menu.selectedText
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.xxxl
  // Title line plus the status line beneath it.
  readonly property int titleRowH: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int statusH: Style.font.caption + Style.spacing.sm
  property int headerHeight: root.titleRowH + root.statusH

  // Row geometry — fixed heights so keyboard scrolling never has to probe
  // delegate positions.
  readonly property int rowPadV: Style.spacing.lg
  readonly property int rowPadH: Style.spacing.lg
  readonly property int rowGap: Style.spacing.xs
  readonly property int titleLineH: Style.font.title + Style.spacing.xs
  readonly property int rowH: root.rowPadV * 2 + root.titleLineH
  readonly property int groupRowH: Style.font.caption + Style.spacing.xxl

  function rowHeightOf(row) {
    if (!row) return 0
    return row.kind === "group" ? root.groupRowH : root.rowH
  }

  function rowsHeight(rows, from, to) {
    var t = 0
    for (var i = from; i < to && i < rows.length; i++) {
      t += root.rowHeightOf(rows[i])
      if (i > from) t += root.rowGap
    }
    return t
  }

  readonly property real listContentH: Math.max(root.rowH, root.rowsHeight(root.items, 0, root.items.length))

  // ------------------------------------------------------- self-registration

  // Keep the keyboard shortcut working with the bar on, off, or absent.
  //
  // `omarchy plugin enable` writes only the `bar.layout` entry for a plugin
  // that is both a panel and a bar widget: PluginRegistry.setEnabled picks the
  // bar branch of an if/else chain, so the `plugins[]` push below it is never
  // reached. The panel is then enabled only for as long as its icon sits in
  // the bar — take the icon out, or never want one, and the shell stops
  // instantiating the panel, so `omarchy-shell shell toggle` exits 0 and does
  // nothing. So the first time we open, claim a `plugins[]` reference of our
  // own. Idempotent, writes through a temp file, and inert once a shell that
  // writes both references itself has landed.
  //
  // Harness: sh -c <script> plugin-selfref <id> — $0 is the label, $1 the id.
  property bool selfRefEnsured: false
  readonly property string ensureSelfRefScript: [
    'id="$1"',
    'f="$HOME/.config/omarchy/shell.json"',
    '[ -f "$f" ] || exit 0',
    'jq -e --arg id "$id" \'any(.plugins[]?; (.id // empty) == $id)\' "$f" >/dev/null && exit 0',
    'tmp="$f.selfref.$$"',
    'jq --arg id "$id" \'.plugins = ((.plugins // []) + [{id: $id}])\' "$f" > "$tmp" || {',
    '  rm -f "$tmp"; exit 1;',
    '}',
    '[ -s "$tmp" ] || { rm -f "$tmp"; exit 1; }',
    'mv "$tmp" "$f"'
  ].join("\n")

  function ensureSelfReference() {
    if (root.selfRefEnsured) return
    root.selfRefEnsured = true
    Quickshell.execDetached(["sh", "-c", root.ensureSelfRefScript, "plugin-selfref", root.selfId])
  }

  // This panel is a superset of the first-party Display panel
  // (omarchy.monitor): brightness, text size, scale, and display on/off all
  // live here too. Running both means two icons doing overlapping jobs — but
  // retiring the stock icon is the USER'S call, so the first open ASKS
  // (replace / keep both) instead of doing it silently. The answer is
  // recorded once; Esc postpones, and re-enabling the stock plugin later
  // (`omarchy plugin enable omarchy.monitor`) sticks.
  function ensureTakeover() {
    if (!takeoverCheckProc.running) takeoverCheckProc.running = true
  }

  Process {
    id: takeoverCheckProc
    command: ["sh", root.scriptPath, "takeover", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() !== "ask") return
        // Don't shove a dialog over a chooser or an arrange session the
        // user already opened; the question keeps until the next open.
        if (!root.opened || root.chooser !== null || root.arranging) return
        root.openChooser("One display panel, not two",
                         "This panel does everything the stock Display panel does. Keep one icon, or both?",
                         "takeover", "", [
          { label: "Replace the stock Display icon   (recommended)", value: "replace", current: true },
          { label: "Keep both icons", value: "keep", current: false }
        ])
      }
    }
  }

  function resolveTakeover(choice) {
    Quickshell.execDetached(["sh", root.scriptPath, "takeover", String(choice)])
    if (choice === "replace")
      savedNote.show("stock Display icon retired")
  }

  // ------------------------------------------------------------- open/close

  function open(payloadJson) {
    root.opened = true
    root.ensureSelfReference()
    root.ensureTakeover()
    root.selectedIndex = -1
    root.lastError = ""
    root.arranging = false
    root.brightTouched = false
    root.refresh()
    if (!brightProbeProc.running) brightProbeProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    root.closeChooser()
    // Don't let an abandoned arrange session survive a close — reopening
    // would show (and Enter would APPLY) geometry captured before the close.
    root.cancelArrange()
    // Keep the host's openPanelIds in sync so an Esc-closed panel doesn't
    // wrongly self-restore on the next delegate rebuild.
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function refresh() {
    if (stateProc.running) return
    stateProc.running = true
  }

  // ------------------------------------------------------------ formatting

  // Hyprland wants "2560x1440@240"; hyprctl hands back floats and "Hz".
  function fmtScale(s) {
    var n = Number(s)
    var r = Math.round(n)
    if (Math.abs(n - r) < 0.0005) return String(r)
    return String(Math.round(n * 1000000) / 1000000)
  }

  function normalizeMode(m) {
    m = String(m).replace(/Hz$/, "")
    var at = m.indexOf("@")
    if (at < 0) return m
    return m.slice(0, at) + "@" + Math.round(parseFloat(m.slice(at + 1)))
  }

  function currentMode(m) {
    return m.width + "x" + m.height + "@" + Math.round(m.refreshRate)
  }

  function transformLabel(t) {
    switch (Number(t)) {
      case 1: return "90°"
      case 2: return "180°"
      case 3: return "270°"
      case 4: return "flipped"
      case 5: return "flipped 90°"
      case 6: return "flipped 180°"
      case 7: return "flipped 270°"
      default: return "Normal"
    }
  }

  // On-screen footprint after scale and rotation — what position maths needs.
  function logicalW(m) {
    var w = (Number(m.transform) % 2 === 1) ? m.height : m.width
    var s = Number(m.scale) > 0 ? Number(m.scale) : 1
    return Math.round(w / s)
  }

  function logicalH(m) {
    var h = (Number(m.transform) % 2 === 1) ? m.width : m.height
    var s = Number(m.scale) > 0 ? Number(m.scale) : 1
    return Math.round(h / s)
  }

  function findMon(name) {
    for (var i = 0; i < root.monitors.length; i++)
      if (root.monitors[i].name === name) return root.monitors[i]
    return null
  }

  // ------------------------------------------------------------ state fetch

  function parseState(raw) {
    var text = String(raw || "").trim()
    if (text.indexOf("##NOJQ") >= 0) {
      root.noJq = true
      root.loaded = true
      root.monitors = []
      root.rebuildItems()
      return
    }
    root.noJq = false
    try {
      var j = JSON.parse(text)
      root.monitors = j.monitors || []
      root.haveConfig = j.config === true
      root.haveBackup = j.backup === true
      root.focusedName = ""
      for (var i = 0; i < root.monitors.length; i++)
        if (root.monitors[i].focused === true) { root.focusedName = root.monitors[i].name; break }
    } catch (e) {
      root.monitors = []
      root.focusedName = ""
      root.lastError = "Couldn't read monitor state"
    }
    root.loaded = true
    root.rebuildItems()
  }

  Process {
    id: stateProc
    command: ["sh", root.scriptPath, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseState(text)
    }
  }

  // Brightness is probed separately and only once per open: on a monitor
  // without working DDC/CI the probe burns ~12 seconds of i2c retries before
  // giving up, which must never hold up the monitor list. The row simply
  // appears when — if — a value lands.
  Process {
    id: brightProbeProc
    command: ["sh", root.scriptPath, "brightness"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        // An empty/failed read never REMOVES an existing row — DDC reads are
        // flaky, and yanking the row would reshuffle every list index.
        if (!/^\d+$/.test(t)) return
        // The probe can land up to ~12s after open; if the user has adjusted
        // brightness since, the value they set is authoritative, not this
        // snapshot from before their keypresses.
        if (root.brightTouched) return
        var had = root.brightness >= 0
        root.brightness = Math.max(0, Math.min(100, parseInt(t, 10)))
        if (!had) root.rebuildItems()
      }
    }
  }

  // Mode/scale switches take Hyprland a beat to settle; re-read after.
  Timer {
    id: refreshDelay
    interval: 450
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------------- row model

  function rebuildItems() {
    // With nothing to configure (no jq, no monitors) the empty-state note is
    // the whole UI — config rows would render underneath it and still be
    // activatable.
    if (root.noJq || root.monitors.length === 0) {
      root.items = []
      root.selectedIndex = -1
      hoverGate.reset()
      return
    }

    var rows = []
    var multi = root.monitors.length > 1

    // Shell-wide controls first — the two things the first-party Display
    // panel offered that aren't per-monitor. Brightness only when a
    // controllable backlight exists.
    if (root.brightness >= 0 || root.monitors.length > 0) {
      rows.push({ kind: "group", label: "Display", note: "brightness · text size" })
      if (root.brightness >= 0)
        rows.push({ kind: "slider", key: "brightness", mon: root.focusedName,
                    label: "Brightness", value: "" })
      rows.push({ kind: "slider", key: "textsize", mon: "",
                  label: "Text size", value: "" })
    }

    for (var i = 0; i < root.monitors.length; i++) {
      var m = root.monitors[i]
      var isOff = m.disabled === true
      var model = [m.make, m.model].filter(function(s) { return s && s !== "null" }).join(" ")
      rows.push({ kind: "group", label: m.name + (isOff ? " · disabled" : ""), note: model })
      if (multi)
        rows.push({ kind: "setting", key: "enabled", mon: m.name,
                    label: "Enabled", value: isOff ? "Off" : "On" })
      // A disabled monitor gets only its Enabled toggle — mode/scale/position
      // are meaningless until it's back on.
      if (isOff) continue
      rows.push({ kind: "setting", key: "mode", mon: m.name,
                  label: "Resolution", value: root.currentMode(m) + "Hz" })
      rows.push({ kind: "setting", key: "scale", mon: m.name,
                  label: "Scale", value: root.fmtScale(m.scale) + "x   (" + root.logicalW(m) + "x" + root.logicalH(m) + " logical)" })
      if (root.enabledCount > 1) {
        rows.push({ kind: "setting", key: "position", mon: m.name,
                    label: "Position", value: m.x + "," + m.y })
        rows.push({ kind: "setting", key: "main", mon: m.name,
                    label: "Main monitor", value: root.isMain(m) ? "Yes" : "No" })
      }
      rows.push({ kind: "setting", key: "rotation", mon: m.name,
                  label: "Rotation", value: root.transformLabel(m.transform) })
      rows.push({ kind: "setting", key: "vrr", mon: m.name,
                  label: "VRR (adaptive sync)", value: m.vrr ? "On" : "Off" })
    }

    rows.push({ kind: "group", label: "Config", note: "~/.config/hypr/monitors.lua" })
    if (root.enabledCount > 1)
      rows.push({ kind: "action", act: "arrange",
                  label: "Arrange monitors — drag them into place", value: "" })
    if (root.monitors.length > 0)
      rows.push({ kind: "action", act: "preset",
                  label: "Quick preset — same scale on every monitor", value: "" })
    rows.push({ kind: "action", act: "save",
                label: "Save current layout to monitors.lua",
                value: root.dirty ? "unsaved changes" : "" })
    if (root.haveBackup)
      rows.push({ kind: "action", act: "restore",
                  label: "Restore previous monitors.lua", value: "" })

    // Re-find the selected ROW, not the selected index: a rebuild that adds
    // or removes rows (monitor disabled, brightness row appearing, hotplug)
    // would otherwise leave the cursor on whatever now occupies the old
    // index — and a queued Enter would activate the wrong row.
    var prev = root.isSelectable(root.selectedIndex) ? root.items[root.selectedIndex] : null
    root.items = rows
    hoverGate.reset()

    var idx = -1
    if (prev) {
      for (var k = 0; k < rows.length; k++) {
        var r = rows[k]
        if (r.kind === prev.kind && (r.key || "") === (prev.key || "")
            && (r.mon || "") === (prev.mon || "") && (r.act || "") === (prev.act || "")) {
          idx = k
          break
        }
      }
    }
    root.selectedIndex = idx >= 0 ? idx : root.firstSelectable()
    root.scrollTo(root.selectedIndex)
  }

  function statusLine() {
    if (root.noJq) return "jq is required for this panel"
    if (root.lastError !== "") return root.lastError
    if (!root.loaded) return "Reading monitors…"
    if (root.dirty) return "Changes are live but not saved — pick “Save current layout” to keep them"
    var n = root.monitors.length
    var off = n - root.enabledCount
    return n + (n === 1 ? " monitor" : " monitors")
           + (off > 0 ? " (" + off + " disabled)" : "") + "  ·  "
           + (root.haveConfig ? "saved layout in monitors.lua" : "no saved layout in monitors.lua yet")
  }

  // ------------------------------------------------------------- selection

  function isSelectable(i) {
    return i >= 0 && i < root.items.length && root.items[i].kind !== "group"
  }

  function firstSelectable() {
    for (var i = 0; i < root.items.length; i++) if (root.isSelectable(i)) return i
    return -1
  }

  function lastSelectable() {
    for (var i = root.items.length - 1; i >= 0; i--) if (root.isSelectable(i)) return i
    return -1
  }

  function beginNav() {
    hoverGate.reset()
    root.cursorActive = true
    if (!root.isSelectable(root.selectedIndex)) {
      root.selectedIndex = root.firstSelectable()
      root.scrollTo(root.selectedIndex)
      return false
    }
    return true
  }

  function move(dir) {
    if (!root.beginNav()) return
    var i = root.selectedIndex + dir
    while (i >= 0 && i < root.items.length && root.items[i].kind === "group") i += dir
    if (i < 0 || i >= root.items.length) return
    root.selectedIndex = i
    root.scrollTo(i)
  }

  function selectEdge(fromEnd) {
    hoverGate.reset()
    root.cursorActive = true
    root.selectedIndex = fromEnd ? root.lastSelectable() : root.firstSelectable()
    root.scrollTo(root.selectedIndex)
  }

  function rowOffset(i) {
    return root.rowsHeight(root.items, 0, i) + (i > 0 ? root.rowGap : 0)
  }

  function scrollTo(i) {
    var contentH = root.listContentH
    // Clamp first: content that shrank below the old scroll offset would
    // otherwise show dead space until the next manual scroll.
    if (list.contentY > Math.max(0, contentH - list.height))
      list.contentY = Math.max(0, contentH - list.height)
    if (!root.isSelectable(i)) return
    if (contentH <= list.height) { list.contentY = 0; return }

    var y = root.rowOffset(i)
    var h = root.rowHeightOf(root.items[i])
    var maxY = contentH - list.height

    // Bring the group caption above the row into view with it, so you can see
    // which monitor you've just stepped into.
    if (i > 0 && root.items[i - 1] && root.items[i - 1].kind === "group")
      y -= root.groupRowH + root.rowGap

    if (y < list.contentY)
      list.contentY = Math.max(0, y)
    else if (y + h > list.contentY + list.height)
      list.contentY = Math.min(maxY, y + h - list.height)
  }

  // ---------------------------------------------------------------- chooser

  // Value picker: null, or { title, subtitle, kind, mon, options }. Each
  // option is { label, value, current }.
  property var chooser: null
  property int chooserIndex: 0

  function closeChooser() {
    root.chooser = null
    root.chooserIndex = 0
  }

  function openChooser(title, subtitle, kind, mon, options) {
    var start = 0
    for (var i = 0; i < options.length; i++) if (options[i].current) { start = i; break }
    hoverGate.reset()
    root.chooser = { title: title, subtitle: subtitle, kind: kind, mon: mon, options: options }
    root.chooserIndex = start
    Qt.callLater(function() { root.chooserScrollTo(start) })
  }

  function moveChooser(dir) {
    if (!root.chooser || root.chooser.options.length === 0) return
    var n = root.chooser.options.length
    root.chooserIndex = (root.chooserIndex + dir + n) % n
    root.chooserScrollTo(root.chooserIndex)
  }

  readonly property int optRowH: root.titleLineH + Style.spacing.lg * 2

  function chooserScrollTo(i) {
    var y = i * (root.optRowH + Style.spacing.md)
    if (chooserList.contentHeight <= chooserList.height) { chooserList.contentY = 0; return }
    if (y < chooserList.contentY)
      chooserList.contentY = y
    else if (y + root.optRowH > chooserList.contentY + chooserList.height)
      chooserList.contentY = Math.min(chooserList.contentHeight - chooserList.height,
                                      y + root.optRowH - chooserList.height)
  }

  function pickChooser(opt) {
    if (!root.chooser || !opt) return
    var kind = root.chooser.kind
    var mon = root.chooser.mon
    root.closeChooser()

    if (kind === "mode") root.applyMonitor(mon, { mode: opt.value })
    else if (kind === "scale") root.applyMonitor(mon, { scale: opt.value })
    else if (kind === "position") root.applyMonitor(mon, { pos: opt.value })
    else if (kind === "rotation") root.applyMonitor(mon, { transform: opt.value })
    else if (kind === "preset") root.applyPresetAll(opt.value)
    else if (kind === "brightness") root.setBrightness(opt.value)
    else if (kind === "textsize") root.setTextSize(opt.value)
    else if (kind === "takeover") root.resolveTakeover(opt.value)
  }

  // ----------------------------------------------------------- option lists

  function modeOptions(m) {
    var cur = root.currentMode(m)
    var seen = {}
    var out = []
    var modes = m.availableModes || []
    for (var i = 0; i < modes.length; i++) {
      var nm = root.normalizeMode(modes[i])
      if (seen[nm]) continue
      seen[nm] = true
      out.push({ label: nm + "Hz" + (nm === cur ? "   — current" : ""), value: nm, current: nm === cur })
    }
    // Some outputs (headless test monitors included) report no modes at all;
    // a blank chooser with no exit but Esc is worse than showing the current
    // mode as the only choice.
    if (out.length === 0)
      out.push({ label: cur + "Hz   — current", value: cur, current: true })
    return out
  }

  readonly property var scalePresets: [
    { v: "1",        note: "100% — no scaling" },
    { v: "1.25",     note: "125%" },
    { v: "1.333333", note: "133%" },
    { v: "1.5",      note: "150%" },
    { v: "1.666667", note: "166% — good for 4K at 27\"" },
    { v: "1.75",     note: "175%" },
    { v: "2",        note: "200% — Retina / HiDPI" }
  ]

  // Presets are cleaned against this monitor's mode and deduplicated: on a
  // mode where 1.75 isn't achievable it becomes the nearest clean value, and
  // two presets collapsing to the same effective scale show up once — same
  // behaviour as the stock panel's pills.
  function scaleOptions(m) {
    var cur = root.fmtScale(root.cleanScale(m.scale, m.width, m.height))
    var out = []
    var seen = {}
    var found = false
    for (var i = 0; i < root.scalePresets.length; i++) {
      var p = root.scalePresets[i]
      var eff = root.fmtScale(root.cleanScale(p.v, m.width, m.height))
      if (seen[eff]) continue
      seen[eff] = true
      var isCur = eff === cur
      if (isCur) found = true
      var label = eff + "x   (" + p.note + ")"
      if (eff !== root.fmtScale(Number(p.v))) label = eff + "x   (nearest to " + p.v + "x — " + p.note + ")"
      out.push({ label: label + (isCur ? "   — current" : ""), value: eff, current: isCur })
    }
    // A scale set outside the presets still shows up, selected, rather than
    // pretending the monitor is somewhere it isn't.
    if (!found)
      out.unshift({ label: cur + "x   — current", value: cur, current: true })
    return out
  }

  function positionOptions(m) {
    var others = []
    for (var i = 0; i < root.monitors.length; i++)
      if (root.monitors[i].name !== m.name && root.monitors[i].disabled !== true)
        others.push(root.monitors[i])

    // Extents start at ±Infinity, not 0 — mid-session the other monitors can
    // all sit at positive (or all at negative) coordinates, and a 0 seed
    // would compute "left of"/"right of" against the origin instead of them.
    var maxRight = -Infinity, minX = Infinity, minY = Infinity, maxBottom = -Infinity
    for (var k = 0; k < others.length; k++) {
      var o = others[k]
      var r = o.x + root.logicalW(o)
      var b = o.y + root.logicalH(o)
      if (r > maxRight) maxRight = r
      if (o.x < minX) minX = o.x
      if (o.y < minY) minY = o.y
      if (b > maxBottom) maxBottom = b
    }
    if (others.length === 0) { maxRight = 0; minX = 0; minY = 0; maxBottom = 0 }

    var left = (minX - root.logicalW(m)) + "x0"
    var above = "0x" + (minY - root.logicalH(m))
    var below = "0x" + maxBottom
    var right = maxRight + "x0"
    var cur = m.x + "x" + m.y

    function opt(label, v) {
      return { label: label + "   (" + v + ")" + (v === cur ? "   — current" : ""), value: v, current: v === cur }
    }
    return [
      { label: "Auto — let Hyprland decide", value: "auto", current: false },
      opt("Left of the others", left),
      opt("Right of the others", right),
      opt("Above the others", above),
      opt("Below the others", below),
      opt("Origin", "0x0")
    ]
  }

  function rotationOptions(m) {
    var cur = Number(m.transform)
    var opts = [
      { label: "Normal", value: 0 },
      { label: "90°", value: 1 },
      { label: "180°", value: 2 },
      { label: "270°", value: 3 }
    ]
    for (var i = 0; i < opts.length; i++) {
      opts[i].current = opts[i].value === cur
      if (opts[i].current) opts[i].label += "   — current"
    }
    return opts
  }

  readonly property var presetChoices: [
    { label: "2x HiDPI   (13\" 2.8K, 27\" 5K, 32\" 6K)", value: "2", current: false },
    { label: "1.666667x   (27\"/32\" 4K)", value: "1.666667", current: false },
    { label: "1x native   (1080p, 1440p)", value: "1", current: false }
  ]

  function brightnessOptions() {
    var out = []
    for (var p = 100; p >= 10; p -= 10) {
      var isCur = Math.abs(root.brightness - p) < 5
      out.push({ label: p + "%" + (isCur ? "   — current" : ""), value: p, current: isCur })
    }
    return out
  }

  function nearestTextStop(px) {
    var best = 0, bestDist = 1e9
    for (var i = 0; i < root.textSizeStops.length; i++) {
      var d = Math.abs(root.textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  function textSizeOptions() {
    var cur = root.nearestTextStop(Style.font.baseSize)
    var out = []
    for (var i = 0; i < root.textSizeStops.length; i++) {
      var px = root.textSizeStops[i]
      out.push({ label: px + "px" + (i === cur ? "   — current" : ""), value: px, current: i === cur })
    }
    return out
  }

  // ←/→ (or h/l) on a slider row nudges the value without a chooser.
  function adjustSlider(dir) {
    if (!root.isSelectable(root.selectedIndex)) return
    var row = root.items[root.selectedIndex]
    if (!row || row.kind !== "slider") return
    if (row.key === "brightness") {
      root.setBrightness(root.brightness + dir * 5)
    } else if (row.key === "textsize") {
      var idx = root.nearestTextStop(Style.font.baseSize) + dir
      if (idx < 0) idx = 0
      if (idx > root.textSizeStops.length - 1) idx = root.textSizeStops.length - 1
      root.setTextSize(root.textSizeStops[idx])
    }
  }

  // Debounced so holding → doesn't stack brightnessctl calls; the panel's
  // local value is authoritative until the write lands. DDC writes can take
  // seconds, so a set arriving while one is in flight is QUEUED and re-run
  // with the latest value when the process exits — last write always wins.
  property bool brightTouched: false  // user adjusted since this open
  property bool brightQueued: false

  function setBrightness(v) {
    if (root.brightness < 0) return
    var p = Math.max(1, Math.min(100, Math.round(v)))
    root.brightness = p
    root.brightTouched = true
    brightDebounce.restart()
  }

  function startBrightWrite() {
    if (brightProc.running) { root.brightQueued = true; return }
    root.brightQueued = false
    brightProc.command = ["omarchy-brightness-display", "--no-osd",
                          "--monitor", root.focusedName, root.brightness + "%"]
    brightProc.running = true
  }

  Timer {
    id: brightDebounce
    interval: 180
    repeat: false
    onTriggered: root.startBrightWrite()
  }

  Process {
    id: brightProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (!running && root.brightQueued) root.startBrightWrite()
    }
  }

  // Style picks the new base size up through its own file watch — the whole
  // shell (this panel included) reflows on its own, nothing to refresh.
  function setTextSize(px) {
    Quickshell.execDetached(["omarchy-display-text-size", String(px)])
  }

  // ------------------------------------------------------------ arrangement

  // The mini-map arrangement editor. Works on a copy of the enabled
  // monitors' LOGICAL rects (scaled, rotation-swapped) — the same numbers
  // Hyprland lays surfaces out with — and applies nothing until ↵.
  property bool arranging: false
  property var arrangeRects: []    // [{ name, x, y, w, h }] logical px
  property int arrangeSel: 0
  property string arrangeWarn: ""

  // True when rect idx overlaps any other. Hyprland accepts overlapping
  // layouts but fires its "set up incorrectly" banner and misbehaves, so
  // apply is gated on this (drag/snap can legitimately pass through
  // overlapping states while editing — only committing one is an error).
  function rectOverlaps(idx) {
    var rs = root.arrangeRects
    if (idx < 0 || idx >= rs.length) return false
    var a = rs[idx]
    for (var i = 0; i < rs.length; i++) {
      if (i === idx) continue
      var b = rs[i]
      if (a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h)
        return true
    }
    return false
  }

  function anyArrangeOverlap() {
    for (var i = 0; i < root.arrangeRects.length; i++)
      if (root.rectOverlaps(i)) return true
    return false
  }

  // "Main" = the monitor at origin. That is the honest Hyprland meaning:
  // there is no primary-output flag, but 0,0 is where the first workspace
  // lands and where fullscreen games default to.
  function isMain(m) {
    return Number(m.x) === 0 && Number(m.y) === 0
  }

  // Move this monitor to 0,0 and shift every other enabled monitor by the
  // same amount, so the relative layout is preserved exactly.
  function setMain(name) {
    var m = root.findMon(name)
    if (!m || m.disabled === true) return
    var dx = -Number(m.x), dy = -Number(m.y)
    var specs = []
    for (var i = 0; i < root.monitors.length; i++) {
      var o = root.monitors[i]
      if (o.disabled === true) continue
      specs.push(root.luaMonitorExpr(o.name, root.currentMode(o),
                                     (Number(o.x) + dx) + "x" + (Number(o.y) + dy),
                                     root.fmtScale(o.scale), Number(o.transform), o.vrr === true))
    }
    // Batched into one eval — see applyArrange for why (transient overlap
    // mid-sequence trips Hyprland's layout banner).
    root.runApply([specs.join("; ")])
  }

  function openArrange() {
    var rects = []
    for (var i = 0; i < root.monitors.length; i++) {
      var m = root.monitors[i]
      if (m.disabled === true) continue
      rects.push({ name: m.name, x: Number(m.x), y: Number(m.y),
                   w: root.logicalW(m), h: root.logicalH(m) })
    }
    if (rects.length < 2) return
    root.arrangeRects = rects
    root.arrangeSel = 0
    root.arrangeWarn = ""
    root.arranging = true
  }

  function cancelArrange() {
    root.arranging = false
    root.arrangeRects = []
    root.arrangeWarn = ""
  }

  // Snap one edge pair per axis: align-left/right/top/bottom with, or butt
  // up against, any other rect — whichever is closest within the threshold.
  readonly property int snapDist: 60
  function snapRect(r, idx) {
    var bestDX = null, bestDY = null
    for (var i = 0; i < root.arrangeRects.length; i++) {
      if (i === idx) continue
      var o = root.arrangeRects[i]
      var xs = [o.x - r.x, (o.x + o.w) - r.x, o.x - (r.x + r.w), (o.x + o.w) - (r.x + r.w)]
      var ys = [o.y - r.y, (o.y + o.h) - r.y, o.y - (r.y + r.h), (o.y + o.h) - (r.y + r.h)]
      for (var k = 0; k < 4; k++) {
        if (Math.abs(xs[k]) <= root.snapDist && (bestDX === null || Math.abs(xs[k]) < Math.abs(bestDX))) bestDX = xs[k]
        if (Math.abs(ys[k]) <= root.snapDist && (bestDY === null || Math.abs(ys[k]) < Math.abs(bestDY))) bestDY = ys[k]
      }
    }
    if (bestDX !== null) r.x += bestDX
    if (bestDY !== null) r.y += bestDY
    return r
  }

  function commitArrangeRect(idx, lx, ly) {
    var rects = root.arrangeRects.slice()
    var r = { name: rects[idx].name, x: Math.round(lx), y: Math.round(ly),
              w: rects[idx].w, h: rects[idx].h }
    rects[idx] = root.snapRect(r, idx)
    root.arrangeRects = rects
    root.arrangeSel = idx
    root.arrangeWarn = ""
  }

  function nudgeArrange(dx, dy) {
    if (root.arrangeSel < 0 || root.arrangeSel >= root.arrangeRects.length) return
    var rects = root.arrangeRects.slice()
    var r = rects[root.arrangeSel]
    rects[root.arrangeSel] = { name: r.name, x: r.x + dx * 40, y: r.y + dy * 40, w: r.w, h: r.h }
    root.arrangeRects = rects
    root.arrangeWarn = ""
  }

  // Normalize so the top-left of the layout sits at 0,0 (negative
  // coordinates work in Hyprland but 0-based keeps monitors.lua readable),
  // then apply live — one hl.monitor eval per monitor.
  function applyArrange() {
    if (root.arrangeRects.length < 2) { root.cancelArrange(); return }
    // Refuse to commit an overlapping layout: Hyprland would take it but
    // fire its "monitor layout is set up incorrectly" banner at the user.
    if (root.anyArrangeOverlap()) {
      root.arrangeWarn = "Monitors overlap — drag them apart before applying"
      return
    }
    var minX = Infinity, minY = Infinity
    var i
    for (i = 0; i < root.arrangeRects.length; i++) {
      if (root.arrangeRects[i].x < minX) minX = root.arrangeRects[i].x
      if (root.arrangeRects[i].y < minY) minY = root.arrangeRects[i].y
    }
    var specs = []
    for (i = 0; i < root.arrangeRects.length; i++) {
      var r = root.arrangeRects[i]
      var m = root.findMon(r.name)
      if (!m) continue
      specs.push(root.luaMonitorExpr(m.name, root.currentMode(m),
                                     (r.x - minX) + "x" + (r.y - minY),
                                     root.fmtScale(m.scale), Number(m.transform), m.vrr === true))
    }
    root.cancelArrange()
    // One eval for the whole layout: sequential applies pass through
    // transient overlaps (monitor A moved, B not yet) and Hyprland fires
    // its overlap banner for those too. Batched, it never sees one.
    root.runApply([specs.join("; ")])
  }

  // ---------------------------------------------------------------- actions

  function activate(i) {
    if (!root.isSelectable(i)) return
    var row = root.items[i]

    if (row.kind === "action") {
      if (row.act === "save") { saveProc.running = true; return }
      if (row.act === "restore") { restoreProc.running = true; return }
      if (row.act === "arrange") { root.openArrange(); return }
      if (row.act === "preset") {
        root.openChooser("Quick preset", "Applies preferred resolution + this scale to every monitor",
                         "preset", "", root.presetChoices)
        return
      }
      return
    }

    if (row.kind === "slider") {
      if (row.key === "brightness")
        root.openChooser("Brightness", "Backlight level — ←/→ on the row also adjusts",
                         "brightness", row.mon, root.brightnessOptions())
      else if (row.key === "textsize")
        root.openChooser("Text size", "Shell and app base font size",
                         "textsize", "", root.textSizeOptions())
      return
    }

    var m = root.findMon(row.mon)
    if (!m) return

    if (row.key === "enabled") {
      if (m.disabled === true) {
        // "disabled = false" must be EXPLICIT: a spec that merely omits it
        // does not re-enable a runtime-disabled monitor (hyprctl says "ok"
        // and nothing happens — verified on hardware 2026-08-15).
        root.runApply(['hl.monitor({ output = "' + m.name
                       + '", mode = "preferred", position = "auto", scale = "auto", disabled = false })'])
      } else if (root.enabledCount <= 1) {
        root.lastError = "Not disabling your only enabled monitor"
      } else {
        root.runApply(['hl.monitor({ output = "' + m.name + '", disabled = true })'])
      }
      return
    }

    if (row.key === "main") {
      if (!root.isMain(m)) root.setMain(row.mon)
      return
    }

    if (row.key === "mode")
      root.openChooser(row.mon, "Resolution and refresh rate", "mode", row.mon, root.modeOptions(m))
    else if (row.key === "scale")
      root.openChooser(row.mon, "Scale factor", "scale", row.mon, root.scaleOptions(m))
    else if (row.key === "position")
      root.openChooser(row.mon, "Position relative to the other monitors", "position", row.mon, root.positionOptions(m))
    else if (row.key === "rotation")
      root.openChooser(row.mon, "Rotation", "rotation", row.mon, root.rotationOptions(m))
    else if (row.key === "vrr")
      root.applyMonitor(row.mon, { vrr: !m.vrr })
  }

  // Hyprland only accepts scales where the mode divides into whole logical
  // pixels (1/120 steps) — same maths as the stock scaling CLI and the
  // first-party panel's Model.js. Rounds the requested scale up to the
  // nearest clean value for the given mode.
  function cleanScale(scale, width, height) {
    function gcd(a, b) { while (b) { var t = a % b; a = b; b = t } return a }
    var w = Number(width), h = Number(height), s = Number(scale)
    if (!(s > 0) || !(w > 0) || !(h > 0)) return Number(scale)
    var divisor = gcd(Math.round(w * 120), Math.round(h * 120))
    var units = Math.round(s * 120)
    if (units > divisor) units = divisor
    while (divisor % units !== 0) units++
    return units / 120
  }

  // One hl.monitor() expression for hyprctl eval. Under the Omarchy 4 Lua
  // config `hyprctl keyword` is DEAD ("keyword can't work with non-legacy
  // parsers") — eval is the only live-apply path.
  function luaMonitorExpr(name, mode, pos, scale, transform, vrr) {
    return 'hl.monitor({ output = "' + name + '", mode = "' + mode
         + '", position = "' + pos + '", scale = ' + scale
         + ', transform = ' + Number(transform)
         + ', vrr = ' + (vrr ? 1 : 0) + ' })'
  }

  // Build the full monitor spec with one field overridden, so a scale change
  // never resets the rotation and a mode change never moves the monitor.
  function applyMonitor(name, o) {
    var m = root.findMon(name)
    if (!m) return
    var mode = o.mode !== undefined ? o.mode : root.currentMode(m)
    var pos = o.pos !== undefined ? o.pos : (m.x + "x" + m.y)
    var scaleN = o.scale !== undefined ? Number(o.scale) : Number(m.scale)
    var t = o.transform !== undefined ? o.transform : Number(m.transform)
    var vrr = o.vrr !== undefined ? o.vrr : (m.vrr === true)
    // Clean against the mode being applied, not the current one — a mode
    // change can make the old scale invalid.
    var mw = parseInt(mode, 10) || m.width
    var mh = parseInt(String(mode).split("x")[1], 10) || m.height
    scaleN = root.cleanScale(scaleN, mw, mh)
    var scale = root.fmtScale(scaleN)
    var specs = [root.luaMonitorExpr(name, mode, pos, scale, t, vrr)]

    // A mode/scale/rotation change resizes the monitor's logical footprint
    // in place, so neighbours laid out past its old right/bottom edge must
    // shift by the delta — otherwise growth overlaps them (Hyprland takes
    // the layout but fires its "set up incorrectly" banner) and shrink
    // leaves a dead gap. Applied as one batched eval so no intermediate
    // state overlaps either.
    if (o.pos === undefined) {
      var newW = Math.round(((Number(t) % 2 === 1) ? mh : mw) / scaleN)
      var newH = Math.round(((Number(t) % 2 === 1) ? mw : mh) / scaleN)
      var dw = newW - root.logicalW(m)
      var dh = newH - root.logicalH(m)
      if (dw !== 0 || dh !== 0) {
        var oldR = Number(m.x) + root.logicalW(m)
        var oldB = Number(m.y) + root.logicalH(m)
        for (var i = 0; i < root.monitors.length; i++) {
          var n = root.monitors[i]
          if (n.name === m.name || n.disabled === true) continue
          var nx = Number(n.x), ny = Number(n.y)
          var sx = nx >= oldR ? dw : 0
          var sy = ny >= oldB ? dh : 0
          if (sx === 0 && sy === 0) continue
          specs.push(root.luaMonitorExpr(n.name, root.currentMode(n),
                     (nx + sx) + "x" + (ny + sy),
                     root.fmtScale(n.scale), Number(n.transform), n.vrr === true))
        }
      }
    }
    root.runApply([specs.join("; ")])
  }

  function applyPresetAll(scale) {
    var specs = []
    for (var i = 0; i < root.monitors.length; i++) {
      var m = root.monitors[i]
      if (m.disabled === true) continue
      var s = root.fmtScale(root.cleanScale(scale, m.width, m.height))
      specs.push(root.luaMonitorExpr(m.name, "preferred", "auto", s,
                                     Number(m.transform), m.vrr === true))
    }
    // Batched into one eval — see applyArrange for why.
    root.runApply([specs.join("; ")])
  }

  // Specs run one at a time through applyProc so hyprctl's answer is read for
  // each — "ok" or the reason it refused, which lands on the status line.
  property var applyQueue: []

  // Appends rather than replaces: a multi-spec batch (preset, set-main,
  // arrange) mid-flight must not have its tail dropped by the next apply —
  // half of a set-main is an overlap nobody asked for.
  function runApply(specs) {
    root.lastError = ""
    root.applyQueue = root.applyQueue.concat(specs)
    root.applyNext()
  }

  // Set only by a confirmed "ok" from hyprctl, so a refused change doesn't
  // flag the session as having unsaved changes.
  property bool applySucceeded: false

  function applyNext() {
    if (root.applyQueue.length === 0) {
      if (root.applySucceeded) {
        root.applySucceeded = false
        root.dirty = true
      }
      refreshDelay.restart()
      return
    }
    if (applyProc.running) return
    var q = root.applyQueue
    var spec = q.shift()
    root.applyQueue = q
    applyProc.command = ["hyprctl", "eval", spec]
    applyProc.running = true
  }

  Process {
    id: applyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").trim()
        if (out !== "" && out.toLowerCase() !== "ok")
          root.lastError = out.split("\n")[0]
        else
          root.applySucceeded = true
        root.applyNext()
      }
    }
  }

  Process {
    id: saveProc
    command: ["sh", root.scriptPath, "save"]
    onExited: function(code, status) {
      if (code === 0) {
        root.dirty = false
        root.lastError = ""
        savedNote.show("saved to monitors.lua")
      } else {
        root.lastError = "Save failed — is jq installed?"
      }
      root.refresh()
    }
  }

  Process {
    id: restoreProc
    command: ["sh", root.scriptPath, "restore"]
    onExited: function(code, status) {
      if (code === 0) {
        root.dirty = false
        root.lastError = ""
        savedNote.show("previous config restored")
      } else {
        root.lastError = "Restore failed — no backup found"
      }
      refreshDelay.restart()
    }
  }

  // Only a genuine pointer move may steal the selection cursor — delegates
  // created or scrolled under a stationary mouse must not hijack keyboard
  // navigation.
  PointerMoveGate {
    id: hoverGate
    referenceItem: card
  }

  // ------------------------------------------------------------------- UI

  // Divider naming the monitor (or the Config section) above its rows.
  component GroupCaption: Item {
    id: capItem
    property var rowData: null

    width: parent ? parent.width : 0
    height: root.groupRowH

    Text {
      id: capLabel
      anchors.left: parent.left
      anchors.leftMargin: root.rowPadH
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.spacing.xxs
      text: capItem.rowData ? String(capItem.rowData.label).toUpperCase() : ""
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      id: capNote
      anchors.left: capLabel.right
      anchors.leftMargin: Style.spacing.md
      anchors.baseline: capLabel.baseline
      text: capItem.rowData ? String(capItem.rowData.note || "") : ""
      color: root.foreground
      opacity: 0.45
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      anchors.left: capNote.right
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.xxl
      anchors.rightMargin: root.rowPadH
      anchors.verticalCenter: capLabel.verticalCenter
      height: 1
      color: root.foreground
      opacity: 0.12
      visible: width > Style.space(20)
    }
  }

  component SettingRow: Item {
    id: rowItem

    property int flatIndex: -1
    property var rowData: null
    readonly property bool selected: root.cursorActive && rowItem.flatIndex === root.selectedIndex
    readonly property bool isAction: rowItem.rowData && rowItem.rowData.kind === "action"

    width: parent ? parent.width : 0
    height: root.rowH

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rowItem.selected ? root.selBg : "transparent"
    }

    Text {
      id: glyph
      anchors.left: parent.left
      anchors.leftMargin: root.rowPadH
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      text: {
        if (!rowItem.rowData) return ""
        if (rowItem.isAction) {
          if (rowItem.rowData.act === "save") return "󰆓"
          if (rowItem.rowData.act === "restore") return "󰦛"
          if (rowItem.rowData.act === "arrange") return "󰍺"
          return "󰓡"
        }
        switch (rowItem.rowData.key) {
          case "brightness": return "󰃠"
          case "textsize": return "󰛖"
          case "enabled": return "󰐥"
          case "main": return "󰓎"
          case "mode": return "󰍹"
          case "scale": return "󰍉"
          case "position": return "󰉺"
          case "rotation": return "󰑵"
          case "vrr": return "󰓅"
          default: return ""
        }
      }
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }

    Text {
      id: labelText
      anchors.left: glyph.right
      anchors.verticalCenter: parent.verticalCenter
      // Bounded so elide actually engages instead of squeezing the value.
      width: Math.min(implicitWidth, Math.max(0, rowItem.width * 0.6))
      text: rowItem.rowData ? String(rowItem.rowData.label) : ""
      color: rowItem.selected ? root.selText : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: rowItem.isAction
      elide: Text.ElideRight
    }

    Text {
      id: hintText2
      anchors.right: parent.right
      anchors.rightMargin: root.rowPadH
      anchors.verticalCenter: parent.verticalCenter
      text: {
        if (!rowItem.rowData) return ""
        if (rowItem.isAction) return "run"
        if (rowItem.rowData.kind === "slider") return "◂ ▸ adjust"
        if (rowItem.rowData.key === "vrr" || rowItem.rowData.key === "enabled") return "toggle"
        if (rowItem.rowData.key === "main") return rowItem.rowData.value === "Yes" ? "" : "set main"
        return "change…"
      }
      color: root.foreground
      opacity: rowItem.selected ? 0.6 : 0.3
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.right: hintText2.left
      anchors.rightMargin: Style.spacing.xl
      anchors.left: labelText.right
      anchors.leftMargin: Style.spacing.xl
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      // Slider rows bind to live state so ←/→ nudges repaint instantly,
      // without a rebuild of the whole row list.
      text: {
        if (!rowItem.rowData) return ""
        if (rowItem.rowData.key === "brightness") return root.brightness + "%"
        if (rowItem.rowData.key === "textsize") return Style.font.baseSize + "px"
        return String(rowItem.rowData.value || "")
      }
      color: rowItem.rowData && rowItem.rowData.kind === "action"
             && rowItem.rowData.value !== "" ? root.urgent : root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.cursorActive = true
        root.selectedIndex = rowItem.flatIndex
        root.activate(rowItem.flatIndex)
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onPositionChanged: function(mouse) {
        if (!hoverGate.moved(this, mouse)) return
        root.cursorActive = true
        root.selectedIndex = rowItem.flatIndex
      }
    }
  }

  // Slim overlay indicator — the only cue that a capped list has more below.
  component ScrollHint: Rectangle {
    id: hint
    property Flickable target: null

    readonly property bool overflowing: hint.target && hint.target.contentHeight > hint.target.height

    visible: hint.overflowing
    width: Style.space(3)
    radius: width / 2
    color: root.foreground
    opacity: 0.28
    x: parent ? parent.width - width : 0
    height: hint.overflowing
            ? Math.max(Style.space(18), hint.target.height * hint.target.height / hint.target.contentHeight)
            : 0
    y: hint.overflowing
       ? (hint.target.contentY / (hint.target.contentHeight - hint.target.height))
         * (hint.target.height - height)
       : 0
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-monitor-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
      height: Math.min(
        card.contentTopInset + card.contentBottomInset
          + root.headerHeight + root.contentSpacing + root.listContentH,
        Math.min(panel.height * 0.8, panel.height - Style.bar.sizeHorizontal - Style.gapsOut * 2))
      radius: root.cornerRadius
      // Top-right, tucked under the bar — same spot the first-party
      // network/bluetooth popups land.
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.bar.sizeHorizontal + Style.gapsOut
      anchors.rightMargin: Style.gapsOut
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          // The arrange editor owns the keyboard while it's up.
          if (root.arranging) {
            if (event.key === Qt.Key_Escape) root.cancelArrange()
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.applyArrange()
            else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
              root.arrangeSel = (root.arrangeSel + (event.key === Qt.Key_Backtab ? -1 : 1)
                                 + root.arrangeRects.length) % root.arrangeRects.length
            else if (event.key === Qt.Key_Left || event.key === Qt.Key_H) root.nudgeArrange(-1, 0)
            else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) root.nudgeArrange(1, 0)
            else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) root.nudgeArrange(0, -1)
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) root.nudgeArrange(0, 1)
            event.accepted = true
            return
          }

          // The chooser owns the keyboard while it's up, so Esc dismisses it
          // rather than the whole panel.
          if (root.chooser !== null) {
            if (event.key === Qt.Key_Escape) root.closeChooser()
            else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) root.moveChooser(-1)
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) root.moveChooser(1)
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
              root.pickChooser(root.chooser.options[root.chooserIndex])
            event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_R || event.key === Qt.Key_F5) {
            root.refresh()
            event.accepted = true
          } else if (event.key === Qt.Key_S) {
            saveProc.running = true
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.move(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.move(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
            root.adjustSlider(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
            root.adjustSlider(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectEdge(false)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectEdge(true)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.selectedIndex)
            event.accepted = true
          }
        }
      }

      // -------------------------------------------------------- value picker
      // Centred rather than anchored to the row: rows move as the list
      // scrolls, and a popup that has to track them is a lot of geometry for
      // no benefit.
      Item {
        id: chooserLayer
        anchors.fill: parent
        z: 10
        visible: root.chooser !== null

        Rectangle {
          anchors.fill: parent
          color: root.background
          opacity: 0.8
        }

        // hoverEnabled so the scrim eats hover too — list rows underneath
        // must not keep tracking the cursor while the chooser is up.
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.closeChooser()
        }

        Rectangle {
          id: chooserBox
          anchors.centerIn: parent
          width: Math.min(Style.space(470), card.width - Style.space(80))
          // Mode lists run to dozens of entries; the option list scrolls once
          // it would push the box past ~70% of the card.
          readonly property real headH: chooserHead.implicitHeight + Style.spacing.md
          readonly property real footH: chooserFoot.implicitHeight + Style.spacing.md
          readonly property real optsNaturalH: root.chooser
            ? root.chooser.options.length * (root.optRowH + Style.spacing.md) - Style.spacing.md
            : 0
          readonly property real optsH: Math.max(root.optRowH,
            Math.min(optsNaturalH, card.height * 0.7 - headH - footH))
          height: headH + optsH + footH + Style.spacing.xxxl * 2
          radius: root.cornerRadius
          color: root.background
          border.width: Math.max(1, Style.space(2))
          border.color: root.accent

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: chooserHead
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.spacing.xxxl
            anchors.rightMargin: Style.spacing.xxxl
            anchors.topMargin: Style.spacing.xxxl
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              text: root.chooser ? String(root.chooser.title) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.chooser ? String(root.chooser.subtitle) : ""
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Item {
            id: chooserListWrap
            anchors.top: chooserHead.bottom
            anchors.topMargin: Style.spacing.md
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.xxxl
            anchors.rightMargin: Style.spacing.xxxl
            height: chooserBox.optsH

          Flickable {
            id: chooserList
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: optCol.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: optCol
              width: chooserList.width
              spacing: Style.spacing.md

              Repeater {
                model: root.chooser ? root.chooser.options : []

                delegate: Rectangle {
                  id: optRow
                  required property int index
                  required property var modelData

                  readonly property bool current: optRow.index === root.chooserIndex

                  width: optCol.width
                  height: root.optRowH
                  radius: Style.cornerRadius
                  color: optRow.current ? root.selBg : "transparent"

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.lg
                    anchors.right: markText.left
                    anchors.rightMargin: Style.spacing.lg
                    anchors.verticalCenter: parent.verticalCenter
                    text: optRow.modelData.label
                    color: optRow.current ? root.selText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    id: markText
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.lg
                    anchors.verticalCenter: parent.verticalCenter
                    text: optRow.modelData.current ? "󰄬" : ""
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Gated like the main list: options scrolled under a
                    // stationary cursor by ↑↓ must not yank the selection.
                    onPositionChanged: function(mouse) {
                      if (hoverGate.moved(this, mouse)) root.chooserIndex = optRow.index
                    }
                    onClicked: root.pickChooser(optRow.modelData)
                  }
                }
              }
            }
          }

          ScrollHint { target: chooserList }
          }

          Text {
            id: chooserFoot
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.xxxl
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.xxxl
            text: "↑↓ choose · ↵ apply · esc cancel"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ---------------------------------------------------- arrange editor
      // A to-scale mini-map of the enabled monitors' logical rects. Drag a
      // box (or tab + arrows) to move it; edges snap to neighbours; nothing
      // is applied until ↵. The top-left of the layout becomes 0,0 on apply.
      Item {
        id: arrangeLayer
        anchors.fill: parent
        z: 11
        visible: root.arranging

        Rectangle {
          anchors.fill: parent
          color: root.background
          opacity: 0.85
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.cancelArrange()
        }

        Rectangle {
          id: arrangeBox
          anchors.centerIn: parent
          width: Math.min(Style.space(560), card.width - Style.space(60))
          height: arrHead.implicitHeight + arrCanvas.height + arrFoot.implicitHeight
                  + Style.spacing.xxxl * 2 + Style.spacing.md * 2
          radius: root.cornerRadius
          color: root.background
          border.width: Math.max(1, Style.space(2))
          border.color: root.accent

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: arrHead
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.spacing.xxxl
            anchors.rightMargin: Style.spacing.xxxl
            anchors.topMargin: Style.spacing.xxxl
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              text: "Arrange monitors"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              width: parent.width
              text: "Drag the boxes — edges snap to neighbours. 󰓎 marks the box at the layout's top-left corner; it lands at 0,0 (main) on apply."
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }

          Item {
            id: arrCanvas
            anchors.top: arrHead.bottom
            anchors.topMargin: Style.spacing.md
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.xxxl
            anchors.rightMargin: Style.spacing.xxxl
            height: Style.space(280)

            readonly property real pad: Style.space(16)
            readonly property real bMinX: { var v = Infinity, rs = root.arrangeRects; for (var i = 0; i < rs.length; i++) if (rs[i].x < v) v = rs[i].x; return rs.length ? v : 0 }
            readonly property real bMinY: { var v = Infinity, rs = root.arrangeRects; for (var i = 0; i < rs.length; i++) if (rs[i].y < v) v = rs[i].y; return rs.length ? v : 0 }
            readonly property real bMaxX: { var v = -Infinity, rs = root.arrangeRects; for (var i = 0; i < rs.length; i++) if (rs[i].x + rs[i].w > v) v = rs[i].x + rs[i].w; return rs.length ? v : 1 }
            readonly property real bMaxY: { var v = -Infinity, rs = root.arrangeRects; for (var i = 0; i < rs.length; i++) if (rs[i].y + rs[i].h > v) v = rs[i].y + rs[i].h; return rs.length ? v : 1 }
            readonly property real sc: Math.min(
              (width - pad * 2) / Math.max(1, bMaxX - bMinX),
              (height - pad * 2) / Math.max(1, bMaxY - bMinY))
            readonly property real offX: (width - (bMaxX - bMinX) * sc) / 2
            readonly property real offY: (height - (bMaxY - bMinY) * sc) / 2

            Repeater {
              model: root.arrangeRects

              delegate: Rectangle {
                id: monRect
                required property var modelData
                required property int index

                readonly property bool monSel: index === root.arrangeSel
                // Re-evaluated on every arrangeRects reassignment.
                readonly property bool clash: root.rectOverlaps(monRect.index)
                // Top-left of the layout — becomes 0,0 (main) on apply.
                readonly property bool atOrigin: modelData.x === arrCanvas.bMinX && modelData.y === arrCanvas.bMinY

                x: arrCanvas.offX + (modelData.x - arrCanvas.bMinX) * arrCanvas.sc
                y: arrCanvas.offY + (modelData.y - arrCanvas.bMinY) * arrCanvas.sc
                width: Math.max(Style.space(40), modelData.w * arrCanvas.sc)
                height: Math.max(Style.space(28), modelData.h * arrCanvas.sc)
                radius: Style.space(4)
                color: monRect.monSel ? root.selBg : root.background
                border.width: Math.max(1, Style.space(2))
                border.color: monRect.clash ? root.urgent
                              : monRect.monSel ? root.accent : Qt.alpha(root.foreground, 0.45)

                Column {
                  anchors.centerIn: parent
                  spacing: Style.spacing.xxs

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: (monRect.atOrigin ? "󰓎 " : "") + monRect.modelData.name
                    color: monRect.monSel ? root.selText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: monRect.modelData.w + "x" + monRect.modelData.h
                    color: monRect.monSel ? root.selText : root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  id: monDrag
                  anchors.fill: parent
                  cursorShape: Qt.SizeAllCursor
                  drag.target: monRect
                  property real pressX: 0
                  property real pressY: 0
                  onPressed: {
                    root.arrangeSel = monRect.index
                    monDrag.pressX = monRect.x
                    monDrag.pressY = monRect.y
                  }
                  // A plain click only selects — committing would run the
                  // snapper and "correct" a deliberate sub-threshold offset
                  // the user never touched.
                  onReleased: {
                    if (Math.abs(monRect.x - monDrag.pressX) < 3
                        && Math.abs(monRect.y - monDrag.pressY) < 3) return
                    root.commitArrangeRect(monRect.index,
                      (monRect.x - arrCanvas.offX) / arrCanvas.sc + arrCanvas.bMinX,
                      (monRect.y - arrCanvas.offY) / arrCanvas.sc + arrCanvas.bMinY)
                  }
                }
              }
            }
          }

          Text {
            id: arrFoot
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.xxxl
            anchors.rightMargin: Style.spacing.xxxl
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.xxxl
            text: root.arrangeWarn !== "" ? root.arrangeWarn
                  : "drag · tab select · ←↑↓→ nudge · ↵ apply · esc cancel"
            color: root.arrangeWarn !== "" ? root.urgent : root.foreground
            opacity: root.arrangeWarn !== "" ? 0.9 : 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: panelTitle
            anchors.left: parent.left
            anchors.top: parent.top
            height: root.titleRowH
            verticalAlignment: Text.AlignVCenter
            text: "󰍹  Monitor Settings"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Text {
            id: savedNote
            anchors.right: hintText.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: panelTitle.verticalCenter
            color: root.accent
            opacity: 0
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            function show(msg) {
              savedNote.text = msg
              savedNote.opacity = 0.9
              savedTimer.restart()
            }

            Behavior on opacity { NumberAnimation { duration: 150 } }

            Timer {
              id: savedTimer
              interval: 1800
              onTriggered: savedNote.opacity = 0
            }
          }

          Text {
            id: hintText
            anchors.right: parent.right
            anchors.verticalCenter: panelTitle.verticalCenter
            text: "esc close · r refresh · s save · ↵ change"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: panelTitle.bottom
            text: root.statusLine()
            color: root.lastError !== "" ? root.urgent : root.foreground
            opacity: root.lastError !== "" ? 0.9 : (root.dirty ? 0.85 : 0.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.italic: root.lastError === ""
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          Text {
            visible: root.items.length === 0 || root.monitors.length === 0
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.leftMargin: root.rowPadH
            text: root.noJq ? "jq is required for this panel"
                : !root.loaded ? "Reading monitors…"
                : "No monitors detected"
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }

          Flickable {
            id: list
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: listCol.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: listCol
              width: list.width
              spacing: root.rowGap

              Repeater {
                model: root.items

                // One delegate for both row kinds — a Loader swapping
                // components would make row heights depend on when the Loader
                // resolved, and the scroll maths needs them up front.
                delegate: Item {
                  id: slot
                  required property int index
                  required property var modelData

                  readonly property bool isGroup: slot.modelData.kind === "group"

                  width: listCol.width
                  height: root.rowHeightOf(slot.modelData)

                  GroupCaption {
                    visible: slot.isGroup
                    rowData: slot.modelData
                  }

                  SettingRow {
                    visible: !slot.isGroup
                    flatIndex: slot.index
                    // Null on a caption row: hidden items still evaluate
                    // their bindings, so don't hand them a row they can't read.
                    rowData: slot.isGroup ? null : slot.modelData
                  }
                }
              }
            }
          }

          ScrollHint { target: list }
        }
      }
    }
  }
}
