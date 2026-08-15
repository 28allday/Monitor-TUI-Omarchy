#!/bin/sh
# Unit suite for monitors.sh — runs anywhere with jq, no Hyprland needed.
# shellcheck disable=SC2016,SC2015  # single-quoted sh -c is deliberate; ok/bad never fail
# A mock hyprctl (test/mock/) serves fixture JSON and $HOME is redirected
# to a temp dir, so the real config is never touched.
#
#   sh test/run-tests.sh
#
# Covers the save/restore engine: block writing, wildcard preservation,
# idempotency, the lid-safe internal-panel rule, disabled externals,
# carry-over of unplugged outputs, refusal on bad input, and restore.

set -u
DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SH="$DIR/monitors.sh"
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

export HOME="$TESTDIR/home"
export PATH="$DIR/test/mock:$PATH"
export MOCK_LOG="$TESTDIR/mock.log"
mkdir -p "$HOME/.config/hypr"
CONFIG="$HOME/.config/hypr/monitors.lua"
BACKUP="$CONFIG.bak"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check <description> <command...>
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

fixture() { # fixture <name> <json>
    printf '%s' "$2" > "$TESTDIR/$1.json"
}

MON_EDP='{"name":"eDP-1","disabled":false,"width":1920,"height":1200,"refreshRate":120.0,"x":0,"y":0,"scale":2.0,"transform":0,"vrr":false,"focused":true}'
MON_EDP_OFF='{"name":"eDP-1","disabled":true,"width":1920,"height":1200,"refreshRate":120.0,"x":1920,"y":0,"scale":2.0,"transform":0,"vrr":false,"focused":false}'
MON_HDMI='{"name":"HDMI-A-1","disabled":false,"width":3840,"height":2160,"refreshRate":59.997,"x":960,"y":0,"scale":1.5,"transform":0,"vrr":false,"focused":false}'
MON_DP_OFF='{"name":"DP-3","disabled":true,"width":1920,"height":1080,"refreshRate":60.0,"x":0,"y":0,"scale":1.0,"transform":0,"vrr":false,"focused":false}'

fixture both      "[$MON_EDP,$MON_HDMI]"
fixture lidclosed "[$MON_EDP_OFF,$MON_HDMI]"
fixture edponly   "[$MON_EDP]"
fixture extoff    "[$MON_EDP,$MON_DP_OFF]"
fixture empty     "[]"

# Seed a config with user content and the stock wildcard, like a real box.
seed_config() {
    cat > "$CONFIG" <<'EOF'
-- user comment that must survive
local omarchy_monitor_scale = 2
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
EOF
}

block() { sed -n '/nosignal.monitor-settings begin/,/nosignal.monitor-settings end/p' "$CONFIG"; }

# ---- save: basic block ------------------------------------------------------
seed_config
export MOCK_MONITORS_JSON="$TESTDIR/both.json"
sh "$SH" save
check "save exits 0 with two monitors"          [ $? -eq 0 ]
check "block written"                            sh -c 'grep -q "nosignal.monitor-settings begin" "$0"' "$CONFIG"
check "eDP full spec saved"                      sh -c 'echo "$0" | grep -q "eDP-1\", mode = \"1920x1200@120\", position = \"0x0\", scale = 2"' "$(block)"
check "HDMI refresh rounded to @60"              sh -c 'echo "$0" | grep -q "HDMI-A-1\", mode = \"3840x2160@60\""' "$(block)"
check "user wildcard line preserved"             grep -q 'omarchy_monitor_scale })' "$CONFIG"
check "user comment preserved"                   grep -q 'user comment that must survive' "$CONFIG"
check "backup created"                           [ -f "$BACKUP" ]

# ---- save: idempotency ------------------------------------------------------
cp "$CONFIG" "$TESTDIR/first-save"
sh "$SH" save
check "double save is byte-identical"            cmp -s "$TESTDIR/first-save" "$CONFIG"

# ---- save: lid-safe internal panel ------------------------------------------
export MOCK_MONITORS_JSON="$TESTDIR/lidclosed.json"
sh "$SH" save
check "lid-closed save exits 0"                  [ $? -eq 0 ]
check "eDP never saved as disabled"              sh -c '! echo "$0" | grep -q "eDP-1\", disabled = true"' "$(block)"
check "eDP saved as full spec with auto pos"     sh -c 'echo "$0" | grep -q "eDP-1\", mode = \"1920x1200@120\", position = \"auto\""' "$(block)"

# ---- save: disabled EXTERNAL persists as disabled ---------------------------
export MOCK_MONITORS_JSON="$TESTDIR/extoff.json"
sh "$SH" save
check "disabled external saved as disabled"      sh -c 'echo "$0" | grep -q "DP-3\", disabled = true"' "$(block)"

# ---- save: carry-over of unplugged outputs ----------------------------------
export MOCK_MONITORS_JSON="$TESTDIR/both.json"
sh "$SH" save                                   # block: eDP + HDMI
export MOCK_MONITORS_JSON="$TESTDIR/edponly.json"
sh "$SH" save                                   # HDMI unplugged now
check "unplugged HDMI line carried over"         sh -c 'echo "$0" | grep -q "HDMI-A-1"' "$(block)"
check "present eDP not duplicated"               sh -c '[ "$(echo "$0" | grep -c "eDP-1")" = 1 ]' "$(block)"
cp "$CONFIG" "$TESTDIR/carry-save"
sh "$SH" save
check "carry-over save also idempotent"          cmp -s "$TESTDIR/carry-save" "$CONFIG"

# ---- save: refusal on empty state -------------------------------------------
cp "$CONFIG" "$TESTDIR/pre-empty"
export MOCK_MONITORS_JSON="$TESTDIR/empty.json"
if sh "$SH" save; then bad "empty save should exit nonzero"; else ok "empty save refused"; fi
check "config untouched by refused save"         cmp -s "$TESTDIR/pre-empty" "$CONFIG"

# ---- restore ----------------------------------------------------------------
export MOCK_MONITORS_JSON="$TESTDIR/both.json"
seed_config
sh "$SH" save
cp "$CONFIG" "$TESTDIR/saved-state"
export MOCK_MONITORS_JSON="$TESTDIR/edponly.json"
sh "$SH" save                                   # changes the file, .bak = saved-state
sh "$SH" restore
check "restore exits 0"                          [ $? -eq 0 ]
check "restore puts backup back"                 cmp -s "$TESTDIR/saved-state" "$CONFIG"
check "restore triggers hyprctl reload"          grep -q '^reload$' "$MOCK_LOG"

# ---- patch ------------------------------------------------------------------
seed_config
export MOCK_MONITORS_JSON="$TESTDIR/both.json"
sh "$SH" save
sh "$SH" patch 'hl.monitor({ output = "eDP-1", mode = "1920x1200@120", position = "0x0", scale = 1.25, transform = 0, vrr = 0 })'
check "patch exits 0"                            [ $? -eq 0 ]
check "patch replaces the output line"           sh -c 'echo "$0" | grep -q "scale = 1.25"' "$(block)"
check "patch keeps one line per output"          sh -c '[ "$(echo "$0" | grep -c "eDP-1")" = 1 ]' "$(block)"
check "patch preserves other outputs"            sh -c 'echo "$0" | grep -q "HDMI-A-1"' "$(block)"
check "patch preserves user lines"               grep -q 'user comment that must survive' "$CONFIG"
sh "$SH" patch 'hl.monitor({ output = "DP-9", mode = "1920x1080@60", position = "auto", scale = 1, transform = 0, vrr = 0 })'
check "patch appends a new output"               sh -c 'echo "$0" | grep -q "DP-9"' "$(block)"
sh "$SH" patch \
    'hl.monitor({ output = "eDP-1", mode = "1920x1200@120", position = "0x0", scale = 2, transform = 0, vrr = 0 })' \
    'hl.monitor({ output = "DP-9", disabled = true })'
check "multi-arg patch rewrites both"            sh -c 'echo "$0" | grep -q "scale = 2" && echo "$0" | grep -q "DP-9\", disabled = true"' "$(block)"
rm -f "$CONFIG"
sh "$SH" patch 'hl.monitor({ output = "eDP-1", mode = "1920x1200@120", position = "0x0", scale = 2, transform = 0, vrr = 0 })'
check "patch creates block on fresh config"      sh -c 'grep -q "nosignal.monitor-settings begin" "$0" && grep -q "eDP-1" "$0"' "$CONFIG"
if sh "$SH" patch; then bad "argless patch should exit nonzero"; else ok "argless patch refused"; fi

# ---- state ------------------------------------------------------------------
export MOCK_MONITORS_JSON="$TESTDIR/both.json"
out=$(sh "$SH" state)
check "state emits monitor count"                sh -c 'echo "$0" | jq -e ".monitors | length == 2"' "$out"
check "state reports config+backup flags"        sh -c 'echo "$0" | jq -e ".config == true and .backup == true"' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
