# Monitor TUI - Omarchy

A terminal user interface for managing monitor settings in [Omarchy](https://omarchy.com) (Hyprland). Change resolution, scaling, position, and refresh rate without editing config files.

## Quick Start

```bash
git clone https://github.com/28allday/Monitor-TUI-Omarchy.git
cd Monitor-TUI-Omarchy
chmod +x monitor-tui.sh
./monitor-tui.sh
```

On first run, the script installs itself to `~/.local/bin/monitor-tui` and adds a keybind (**SUPER+ALT+M**) so you can open it anytime.

## Features

| Feature | Description |
|---------|-------------|
| **Resolution** | Choose from all available modes reported by your monitor |
| **Refresh rate** | Select from supported rates (60Hz, 144Hz, 240Hz, etc.) |
| **Scaling** | Preset options (1x, 1.25x, 1.5x, 2x) or custom values |
| **Position** | Auto, left, right, above, below, or custom coordinates |
| **VRR** | Enable/disable Variable Refresh Rate (FreeSync/G-Sync) |
| **Multi-monitor** | Configure each display independently, auto-calculate positions |
| **Live preview** | Changes apply instantly — no restart needed |
| **Backup/restore** | Automatic backup before changes, easy restore |

## How It Works

1. Reads live monitor data from `hyprctl monitors -j`
2. Shows a menu with your current settings and available options
3. Applies changes instantly via `hyprctl keyword` (live, no restart)
4. Saves to `~/.config/hypr/monitors.conf` for persistence across reboots

## Keybind

After installation, press **SUPER+ALT+M** to open the monitor TUI from anywhere.

The keybind is added to `~/.config/hypr/bindings.conf` inside a marked block so it can be cleanly removed by the uninstaller.

## Dependencies

| Dependency | Purpose | Included in Omarchy? |
|-----------|---------|---------------------|
| `hyprctl` | Reads monitor info and applies changes | Yes (comes with Hyprland) |
| `jq` | Parses JSON output from hyprctl | Yes |
| `bc` | Floating-point math for scale calculations | Usually yes |

## Multi-Monitor Setup

When you have multiple monitors, the TUI:

1. Shows all connected displays with their current settings
2. Lets you configure each one independently
3. Auto-calculates position when you choose "Right of", "Above", or "Below"
4. Accounts for scaling when calculating positions (uses logical pixels)

### Position Calculation

The TUI calculates positions using logical (scaled) dimensions, not raw pixels. For example:
- A 4K monitor at 2x scale = 1920 logical pixels wide
- A 1080p monitor at 1x scale = 1920 logical pixels wide
- Placing the 1080p monitor to the right: position = 1920x0

## Files

| Path | Purpose |
|------|---------|
| `~/.local/bin/monitor-tui` | Installed script |
| `~/.config/hypr/monitors.conf` | Monitor configuration (edited by TUI) |
| `~/.config/hypr/monitors.conf.bak` | Automatic backup before changes |
| `~/.config/hypr/bindings.conf` | Keybind added here (SUPER+ALT+M) |
| `~/.config/hypr/.monitor-tui-installed` | Marker file tracking installation |

## Uninstalling

```bash
chmod +x monitor-tui-uninstall.sh
./monitor-tui-uninstall.sh
```

This removes:
- The installed script from `~/.local/bin/`
- The keybind from `~/.config/hypr/bindings.conf`
- The window rules from Hyprland config
- The installation marker

Your monitor configuration (`monitors.conf`) is **not** removed.

## Troubleshooting

### TUI shows "No monitors detected"

- Make sure you're running inside Hyprland: `echo $XDG_CURRENT_DESKTOP`
- Check hyprctl works: `hyprctl monitors`

### Changes don't persist after reboot

- Check the config file was written: `cat ~/.config/hypr/monitors.conf`
- Make sure `monitors.conf` is sourced in your main config:
  ```
  # In ~/.config/hypr/hyprland.conf
  source = ~/.config/hypr/monitors.conf
  ```

### Scale looks wrong

- Hyprland works best with specific scale values: 1, 1.25, 1.333333, 1.5, 1.666667, 1.75, 2
- Fractional scaling can cause blurry text in some XWayland apps

### SUPER+ALT+M doesn't work

- Check the keybind was added: `grep "monitor-tui" ~/.config/hypr/bindings.conf`
- Reload Hyprland: `hyprctl reload`

## Credits

- [Omarchy](https://omarchy.com) - The Arch Linux distribution this was built for
- [Hyprland](https://hyprland.org/) - Wayland compositor

## License

This project is provided as-is for the Omarchy community.
