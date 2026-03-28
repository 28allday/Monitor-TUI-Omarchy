#!/bin/bash
# ==============================================================================
# Uninstaller for Monitor Configuration TUI
#
# Removes the monitor-tui script, keybinding, and window rules cleanly.
# Does NOT modify your monitor configuration — only removes the TUI tool itself.
# ==============================================================================

BINDINGS_FILE="$HOME/.config/hypr/bindings.conf"
INSTALLED_MARKER="$HOME/.config/hypr/.monitor-tui-installed"
INSTALL_PATH="$HOME/.local/bin/monitor-tui"

echo "Removing monitor-tui..."

# Remove the keybind and Hyprland window rules from bindings.conf.
# The installer adds these in a marked block (# Monitor Configuration TUI ...
# # End Monitor Configuration TUI) so we can remove the whole block cleanly.
# Fallback sed patterns catch any legacy or stray entries that might have been
# added by older versions of the installer.
if [ -f "$BINDINGS_FILE" ]; then
    sed -i '/# Monitor Configuration TUI/,/# End Monitor Configuration TUI/d' "$BINDINGS_FILE"
    sed -i '/monitor-tui\.sh/d' "$BINDINGS_FILE"
    sed -i '/title:\^Monitor Settings\$/d' "$BINDINGS_FILE"
    sed -i '/class:monitor-tui/d' "$BINDINGS_FILE"
    echo "Keybinding and window rules removed."
fi

# Remove the installed script and the marker file that tracks installation state.
rm -f "$INSTALL_PATH"
rm -f "$INSTALLED_MARKER"

echo "Uninstall complete."

# Remove the keybind from the running Hyprland session immediately, so the user
# doesn't need to restart Hyprland. We use hyprctl keyword unbind rather than
# a full reload because reloading can break multi-monitor workspace switching.
if hyprctl monitors -j &>/dev/null; then
    echo "Removing keybinding from Hyprland..."
    hyprctl keyword unbind "SUPER ALT, M" >/dev/null 2>&1
fi

read -r -p "Press Enter to close..."
