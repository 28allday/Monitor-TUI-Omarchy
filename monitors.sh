#!/bin/sh
# Helper for the Monitor Settings panel (nosignal.monitor-settings).
# Kept as a real script rather than a QML string so it stays shellcheck-able
# and runnable by hand when something looks wrong.
#
#   monitors.sh state       one JSON object: live monitors (incl. disabled)
#                           + config/backup flags — fast, no probes
#   monitors.sh brightness  backlight/DDC percent for the focused monitor,
#                           or nothing. SLOW on monitors without working
#                           DDC/CI (~12s of i2c probing before it gives up),
#                           which is why it is not part of `state`
#   monitors.sh save        serialize the LIVE monitor layout to monitors.lua
#   monitors.sh restore     put the backup back and hyprctl reload
#   monitors.sh takeover …  first-open ask/record for retiring the stock
#                           Display icon (status|replace|keep)
#
# Live changes are applied by the panel itself (hyprctl eval hl.monitor…);
# `save` deliberately reads the live state back from hyprctl rather than
# trusting the panel's idea of it, so what lands in the config is always what
# is actually on screen.
#
# WHY monitors.lua: on Omarchy 4 Hyprland runs ~/.config/hypr/hyprland.lua —
# the old hyprland.conf/monitors.conf chain is never read, so writing there
# saves nothing (learned the hard way). Persistence goes into a
# marker-bracketed block of hl.monitor() lines appended to monitors.lua.
# Specific-output rules beat the stock catch-all
# hl.monitor({ output = "" … }), so the user's own lines above stay intact.

CONFIG="$HOME/.config/hypr/monitors.lua"
BACKUP="$HOME/.config/hypr/monitors.lua.bak"
MARK_BEGIN="-- >>> nosignal.monitor-settings begin (generated - edits inside are overwritten on save)"
MARK_END="-- <<< nosignal.monitor-settings end"

case "${1:-}" in
state)
    command -v jq >/dev/null 2>&1 || { echo '##NOJQ'; exit 0; }
    # `all` so disabled monitors still show up with an Enabled toggle.
    mons=$(hyprctl monitors all -j 2>/dev/null)
    [ -n "$mons" ] || mons='[]'
    b=false; [ -f "$BACKUP" ] && b=true
    c=false; [ -f "$CONFIG" ] && c=true
    printf '%s' "$mons" | jq -c --argjson b "$b" --argjson c "$c" \
        '{monitors: ., backup: $b, config: $c}' 2>/dev/null \
        || printf '{"monitors":[],"backup":%s,"config":%s}\n' "$b" "$c"
    ;;

brightness)
    # Same source the first-party Display panel used: laptop backlight, or
    # DDC/CI for an external monitor. Prints an integer percent, or nothing
    # when there is no controllable brightness.
    focused=$(hyprctl monitors -j 2>/dev/null \
        | jq -r '[.[] | select(.focused == true)][0].name // ""' 2>/dev/null)
    [ -n "$focused" ] || exit 0
    bright=$(omarchy-brightness-display --monitor "$focused" 2>/dev/null | head -n 1)
    case "$bright" in
        ''|*[!0-9]*) exit 0 ;;
    esac
    printf '%s\n' "$bright"
    ;;

save)
    command -v jq >/dev/null 2>&1 || exit 1
    mkdir -p "$(dirname "$CONFIG")" || exit 1

    # One hl.monitor() line per monitor, from what is actually on screen.
    # transform/vrr are always written so the saved state is complete; a
    # disabled monitor is saved as disabled rather than coming back on boot.
    #
    # EXCEPT internal panels (eDP/LVDS/DSI): those go disabled whenever the
    # lid is closed, so a save taken while docked lid-closed would persist
    # "disabled = true" — and after unplugging the external the laptop wakes
    # to a black screen with no local way back in. The lid switch owns the
    # internal panel's on/off state at runtime; the config must never pin it
    # off. Persist its spec instead, with position "auto" since a disabled
    # monitor's reported offset is stale.
    mons=$(hyprctl monitors all -j)
    lines=$(printf '%s' "$mons" | jq -r '.[] |
        if .disabled and (.name | test("^(eDP|LVDS|DSI)")) then
          "hl.monitor({ output = \"\(.name)\", mode = \"\(.width)x\(.height)@\(.refreshRate | round)\", position = \"auto\", scale = \((.scale * 1000000 | round) / 1000000), transform = \(.transform), vrr = \(if .vrr then 1 else 0 end) })"
        elif .disabled then
          "hl.monitor({ output = \"\(.name)\", disabled = true })"
        else
          "hl.monitor({ output = \"\(.name)\", mode = \"\(.width)x\(.height)@\(.refreshRate | round)\", position = \"\(.x)x\(.y)\", scale = \((.scale * 1000000 | round) / 1000000), transform = \(.transform), vrr = \(if .vrr then 1 else 0 end) })"
        end')
    # A save that produced no monitor lines would persist nothing useful —
    # refuse rather than write an empty block.
    [ -n "$lines" ] || exit 1

    # Carry over previous-block lines for outputs that are not connected
    # right now (the docked HDMI while saving on the road, say) so a save
    # made elsewhere doesn't throw away their settings — hyprctl only
    # reports what is plugged in.
    if [ -f "$CONFIG" ]; then
        names=$(printf '%s' "$mons" | jq -r '.[].name')
        carried=$(sed -n "/^-- >>> nosignal\.monitor-settings begin/,/^-- <<< nosignal\.monitor-settings end/p" "$CONFIG" \
            | grep '^hl\.monitor' | while IFS= read -r old; do
                out=$(printf '%s' "$old" | sed -n 's/.*output = "\([^"]*\)".*/\1/p')
                [ -n "$out" ] || continue
                printf '%s\n' "$names" | grep -qxF "$out" || printf '%s\n' "$old"
            done)
        [ -n "$carried" ] && lines="$lines
$carried"
    fi

    [ -f "$CONFIG" ] && cp "$CONFIG" "$BACKUP"
    tmp="$CONFIG.new.$$"
    {
        # Everything of the user's, minus any previous block of ours and any
        # trailing blank lines (so repeated saves don't grow the file).
        if [ -f "$CONFIG" ]; then
            sed "/^-- >>> nosignal\.monitor-settings begin/,/^-- <<< nosignal\.monitor-settings end/d" "$CONFIG" \
                | awk '{ lines[++n] = $0; if (NF) last = n } END { for (i = 1; i <= last; i++) print lines[i] }'
        else
            echo "-- Generated by the Monitor Settings plugin (nosignal.monitor-settings)"
        fi
        echo ""
        echo "$MARK_BEGIN"
        printf '%s\n' "$lines"
        echo "$MARK_END"
    } > "$tmp" || { rm -f "$tmp"; exit 1; }
    grep -q "^hl\.monitor" "$tmp" || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$CONFIG"
    ;;

restore)
    [ -f "$BACKUP" ] || exit 1
    cp "$BACKUP" "$CONFIG"
    hyprctl reload >/dev/null 2>&1
    ;;

# This panel supersedes the stock Display panel (omarchy.monitor), but that
# is the USER'S call: on first open the panel asks. `status` prints "ask"
# exactly when the stock icon is still around and no decision is recorded;
# `replace`/`keep` record the answer (replace also retires the stock icon —
# reversible with: omarchy plugin enable omarchy.monitor).
takeover)
    marker="${XDG_STATE_HOME:-$HOME/.local/state}/nosignal-monitor-settings/takeover-done"
    shelljson="$HOME/.config/omarchy/shell.json"
    case "${2:-}" in
    status)
        [ -f "$marker" ] && { echo "done"; exit 0; }
        if [ -f "$shelljson" ] && grep -q '"omarchy.monitor"' "$shelljson"; then
            echo "ask"
        else
            # Nothing to take over — record that so we never ask later if
            # the user re-enables the stock icon on purpose.
            mkdir -p "${marker%/*}" && touch "$marker"
            echo "done"
        fi
        ;;
    replace)
        mkdir -p "${marker%/*}" || exit 1
        omarchy plugin disable omarchy.monitor >/dev/null 2>&1
        touch "$marker"
        ;;
    keep)
        mkdir -p "${marker%/*}" && touch "$marker"
        ;;
    *)
        echo "usage: monitors.sh takeover status|replace|keep" >&2
        exit 2
        ;;
    esac
    ;;

*)
    echo "usage: monitors.sh state|brightness|save|restore|takeover" >&2
    exit 2
    ;;
esac
