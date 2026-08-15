#!/bin/sh
# Live integration suite — runs against the REAL Hyprland session.
# shellcheck disable=SC2015,SC2012  # ok/bad never fail; ls -t is the established sig lookup
#
#   RUN_LIVE=1 sh test/integration.sh
#
# ⚠ Displays will flicker: it changes mode/scale/position/rotation and
# disables/re-enables monitors (never the last one), then restores the
# exact starting layout and config. Requires >= 1 monitor; the
# multi-monitor cases self-skip on a single head. Do not run while
# something fullscreen/latency-sensitive is up.
#
# Everything here was first proven by hand on dual-head hardware
# (2026-08-15, laptop eDP + 4K external): see NOTES.md "Gotchas".

set -u
[ "${RUN_LIVE:-}" = "1" ] || { echo "refusing: set RUN_LIVE=1 (this flickers real displays)"; exit 2; }
command -v jq >/dev/null || { echo "needs jq"; exit 2; }
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1)
    export HYPRLAND_INSTANCE_SIGNATURE
fi
hyprctl monitors all -j >/dev/null 2>&1 || { echo "no live Hyprland session reachable"; exit 2; }

DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SH="$DIR/monitors.sh"
CONFIG="$HOME/.config/hypr/monitors.lua"
TMP=$(mktemp -d)

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

mon()   { hyprctl monitors all -j | jq -r ".[] | select(.name == \"$1\") | $2"; }
apply() { hyprctl eval "$1" >/dev/null 2>&1; sleep 0.8; }

# Full spec for a monitor from CURRENT live state (mirrors the panel's
# luaMonitorExpr; explicit disabled=false so restore also re-enables).
spec_of() {
    hyprctl monitors all -j | jq -r ".[] | select(.name == \"$1\") |
      \"hl.monitor({ output = \\\"\(.name)\\\", mode = \\\"\(.width)x\(.height)@\(.refreshRate | round)\\\", position = \\\"\(.x)x\(.y)\\\", scale = \((.scale * 1000000 | round) / 1000000), transform = \(.transform), vrr = \(if .vrr then 1 else 0 end), disabled = false })\""
}

# ---------- snapshot everything for restore ----------------------------------
BASELINE=$(hyprctl monitors all -j)
NAMES=$(printf '%s' "$BASELINE" | jq -r '.[] | select(.disabled | not) | .name')
FIRST=$(printf '%s' "$NAMES" | head -1)
SECOND=$(printf '%s' "$NAMES" | sed -n 2p)
RESTORE_SPECS=""
for n in $NAMES; do
    RESTORE_SPECS="$RESTORE_SPECS$(spec_of "$n"); "
done
[ -f "$CONFIG" ] && cp "$CONFIG" "$TMP/monitors.lua.orig"
[ -f "$CONFIG.bak" ] && cp "$CONFIG.bak" "$TMP/monitors.lua.bak.orig"

restore_all() {
    [ -n "$RESTORE_SPECS" ] && apply "${RESTORE_SPECS%; }"
    [ -f "$TMP/monitors.lua.orig" ] && cp "$TMP/monitors.lua.orig" "$CONFIG"
    [ -f "$TMP/monitors.lua.bak.orig" ] && cp "$TMP/monitors.lua.bak.orig" "$CONFIG.bak"
    rm -rf "$TMP"
}
trap restore_all EXIT INT TERM

echo "monitors under test: $(printf '%s' "$NAMES" | tr '\n' ' ')"

# ---------- live applies on FIRST (revert each) -------------------------------
F_MODE=$(mon "$FIRST" '"\(.width)x\(.height)@\(.refreshRate | round)"')
F_POS=$(mon "$FIRST" '"\(.x)x\(.y)"')
F_SCALE=$(mon "$FIRST" .scale)
F_SPEC=$(spec_of "$FIRST")

alt_mode=$(mon "$FIRST" '.availableModes[]' | sed 's/Hz$//' | awk -F'[x@.]' '{print $1"x"$2"@"int($3)}' | grep -v "^$F_MODE$" | head -1)
if [ -n "$alt_mode" ]; then
    apply "hl.monitor({ output = \"$FIRST\", mode = \"$alt_mode\", position = \"$F_POS\", scale = 1, transform = 0, vrr = 0 })"
    got=$(mon "$FIRST" '"\(.width)x\(.height)"')
    [ "$got" = "$(echo "$alt_mode" | cut -d@ -f1)" ] && ok "mode change applies ($alt_mode)" || bad "mode change: wanted $alt_mode got $got"
    apply "$F_SPEC"
else
    echo "SKIP mode change (single mode)"
fi

apply "hl.monitor({ output = \"$FIRST\", mode = \"$F_MODE\", position = \"100x50\", scale = $F_SCALE, transform = 0, vrr = 0 })"
[ "$(mon "$FIRST" .x)" = "100" ] && ok "position change applies" || bad "position change"
apply "$F_SPEC"

apply "hl.monitor({ output = \"$FIRST\", mode = \"$F_MODE\", position = \"$F_POS\", scale = $F_SCALE, transform = 1, vrr = 0 })"
[ "$(mon "$FIRST" .transform)" = "1" ] && ok "rotation applies" || bad "rotation"
apply "$F_SPEC"

# ---------- enable/disable (needs a second monitor) ---------------------------
if [ -n "$SECOND" ]; then
    S_SPEC=$(spec_of "$SECOND")
    apply "hl.monitor({ output = \"$SECOND\", disabled = true })"
    [ "$(mon "$SECOND" .disabled)" = "true" ] && ok "disable works" || bad "disable"
    # The regression that broke the Enabled toggle: a spec that merely
    # omits `disabled` must NOT re-enable — explicit false must.
    apply "$(echo "$S_SPEC" | sed 's/, disabled = false//')"
    [ "$(mon "$SECOND" .disabled)" = "true" ] && ok "spec without disabled=false does NOT re-enable (known Hyprland behavior)" || bad "eval semantics changed: implicit re-enable now works"
    apply "$S_SPEC"
    [ "$(mon "$SECOND" .disabled)" = "false" ] && ok "explicit disabled=false re-enables" || bad "explicit re-enable"

    # Batched two-monitor apply comes back to the exact same layout.
    apply "${RESTORE_SPECS%; }"
    [ "$(mon "$FIRST" '"\(.x)x\(.y)"')" = "$F_POS" ] && ok "batched multi-monitor apply" || bad "batched apply"
else
    echo "SKIP enable/disable + batch (single monitor)"
fi

# ---------- lid-safe save on live state ---------------------------------------
internal=$(printf '%s' "$NAMES" | grep -E '^(eDP|LVDS|DSI)' | head -1)
if [ -n "$internal" ] && [ -n "$SECOND" ]; then
    I_SPEC=$(spec_of "$internal")
    apply "hl.monitor({ output = \"$internal\", disabled = true })"
    sh "$SH" save
    if grep -q "\"$internal\", disabled = true" "$CONFIG"; then
        bad "LID BUG: internal panel persisted as disabled"
    else
        grep -q "output = \"$internal\", mode" "$CONFIG" \
            && ok "lid-safe save (internal panel kept as full spec)" \
            || bad "internal panel line missing from block"
    fi
    apply "$I_SPEC"
else
    echo "SKIP lid-safe save (no internal panel or single monitor)"
fi

# ---------- save/restore round-trip -------------------------------------------
sh "$SH" save && ok "save runs on live state" || bad "save on live state"
cp "$CONFIG" "$TMP/s1"
sh "$SH" save
cmp -s "$TMP/s1" "$CONFIG" && ok "live save idempotent" || bad "live save not idempotent"
sh "$SH" restore && ok "restore runs" || bad "restore"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
