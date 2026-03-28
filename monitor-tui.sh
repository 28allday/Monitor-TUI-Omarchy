#!/bin/bash
# ==============================================================================
# Monitor Configuration TUI for Hyprland (Omarchy)
#
# A terminal user interface for managing monitor settings in Hyprland without
# manually editing config files. Provides a visual menu for:
#
#   - Viewing connected monitors and their current settings
#   - Changing resolution and refresh rate (from available modes)
#   - Adjusting display scaling (1x, 1.25x, 1.5x, 2x, custom)
#   - Positioning monitors in multi-display setups
#   - Setting rotation/transform
#   - Enabling/disabling VRR (Variable Refresh Rate / FreeSync / G-Sync)
#   - Live preview of changes before saving to config
#   - Backup and restore of monitor configuration
#
# The TUI reads live monitor data from hyprctl (Hyprland's CLI tool) and
# writes changes to ~/.config/hypr/monitors.conf. Changes are applied
# instantly via hyprctl keyword — no restart needed.
#
# Installation:
#   Running this script for the first time installs it to ~/.local/bin/
#   and adds a keybind (SUPER+ALT+M) to ~/.config/hypr/bindings.conf.
#
# Dependencies:
#   - hyprctl:  Hyprland's CLI (comes with Hyprland)
#   - jq:       JSON parser (reads monitor data from hyprctl)
#   - bc:       Calculator (optional, for scale/position math)
# ==============================================================================

CONFIG_FILE="$HOME/.config/hypr/monitors.conf"
BACKUP_FILE="$HOME/.config/hypr/monitors.conf.bak"
BINDINGS_FILE="$HOME/.config/hypr/bindings.conf"
INSTALLED_MARKER="$HOME/.config/hypr/.monitor-tui-installed"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/monitor-tui"

# Associative arrays to store multi-monitor config
declare -A MONITOR_MODES
declare -A MONITOR_SCALES
declare -A MONITOR_POSITIONS

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Fixed UI width for alignment (matches header line length)
HEADER_LINE="╔════════════════════════════════════════════════════════════╗"
UI_BLOCK_WIDTH=${#HEADER_LINE}

# Centering helpers for all UI output.
strip_ansi() {
    printf "%b" "$1" | sed -E 's/\x1B\[[0-9;]*[mK]//g'
}

center_line() {
    local line="$1"
    local cols pad plain
    cols=$(tput cols 2>/dev/null || echo 80)
    plain=$(strip_ansi "$line")
    pad=$(( (cols - ${#plain}) / 2 ))
    [ "$pad" -lt 0 ] && pad=0
    printf "%*s%b\n" "$pad" "" "$line"
}

c_echo() {
    center_line "$*"
}

u_echo() {
    echo -e "$*"
}

center_block() {
    local block="$1"
    local width_override="$2"
    local pad_override="$3"
    local cols max_len=0 pad
    local -a lines=()
    cols=$(tput cols 2>/dev/null || echo 80)
    while IFS= read -r line; do
        lines+=("$line")
        local plain
        plain=$(strip_ansi "$line")
        [ "${#plain}" -gt "$max_len" ] && max_len="${#plain}"
    done <<< "$(printf "%b" "$block")"
    local block_width="${width_override:-$max_len}"
    if [ -n "$pad_override" ]; then
        pad="$pad_override"
    else
        pad=$(( (cols - block_width) / 2 ))
    fi
    [ "$pad" -lt 0 ] && pad=0
    for line in "${lines[@]}"; do
        printf "%*s%b\n" "$pad" "" "$line"
    done
}

get_block_pad() {
    local block="$1"
    local cols max_len=0
    cols=$(tput cols 2>/dev/null || echo 80)
    while IFS= read -r line; do
        local plain
        plain=$(strip_ansi "$line")
        [ "${#plain}" -gt "$max_len" ] && max_len="${#plain}"
    done <<< "$(printf "%b" "$block")"
    echo $(( (cols - max_len) / 2 ))
}

prompt_centered() {
    local prompt="$1"
    local __var="$2"
    local cols pad plain
    cols=$(tput cols 2>/dev/null || echo 80)
    plain=$(strip_ansi "$prompt")
    pad=$(( (cols - ${#plain}) / 2 ))
    [ "$pad" -lt 0 ] && pad=0
    printf "%*s%b" "$pad" "" "$prompt"
    IFS= read -r "$__var"
}

# Clear screen and show header
show_header() {
    clear
    c_echo "${BLUE}${HEADER_LINE}${NC}"
    c_echo "${BLUE}║${NC}${BOLD}          Hyprland Monitor Configuration TUI              ${NC}${BLUE}║${NC}"
    c_echo "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    c_echo ""
}

# Get list of connected monitors
get_monitors() {
    hyprctl monitors -j 2>/dev/null | jq -r '.[].name' 2>/dev/null
}

# Get monitor count
get_monitor_count() {
    local count
    count=$(hyprctl monitors -j 2>/dev/null | jq -r 'length' 2>/dev/null)
    echo "${count:-0}"
}

# Get monitor details
get_monitor_info() {
    local monitor="$1"
    hyprctl monitors -j 2>/dev/null | jq -r ".[] | select(.name == \"$monitor\")" 2>/dev/null
}

# Get available modes for a monitor
get_available_modes() {
    local monitor="$1"
    hyprctl monitors -j 2>/dev/null | jq -r ".[] | select(.name == \"$monitor\") | .availableModes[]" 2>/dev/null
}

# Normalize mode string for Hyprland config (e.g., "1920x1080@60.00Hz" -> "1920x1080@60")
normalize_mode() {
    local mode="$1"
    # Remove Hz suffix, then round refresh rate to integer
    mode="${mode%Hz}"

    # Check if mode contains @ (refresh rate)
    if [[ "$mode" != *"@"* ]]; then
        # No refresh rate specified, return as-is
        echo "$mode"
        return
    fi

    # Extract resolution and refresh rate
    local resolution refresh
    resolution="${mode%@*}"
    refresh="${mode#*@}"
    # Round refresh rate to nearest integer
    refresh=$(printf "%.0f" "$refresh" 2>/dev/null || echo "$refresh")
    echo "${resolution}@${refresh}"
}

# Show current monitor status
show_monitor_status() {
    c_echo "${CYAN}Current Monitor Status:${NC}"
    c_echo "${YELLOW}────────────────────────────────────────${NC}"

    if ! is_hyprland_running; then
        c_echo "${RED}Hyprland is not running. Start Hyprland to detect monitors.${NC}"
        c_echo ""
        return 1
    fi

    local mon_count
    mon_count=$(get_monitor_count)
    if [ "$mon_count" -eq 0 ]; then
        c_echo "${RED}No monitors detected.${NC}"
        return 1
    fi

    local monitors
    monitors=$(get_monitors)
    local menu_pad="${LAST_MENU_PAD:-}"
    while IFS= read -r mon; do
        [ -z "$mon" ] && continue
        local info
        info=$(get_monitor_info "$mon")

        # Basic info
        local width height refresh scale x y
        width=$(echo "$info" | jq -r '.width')
        height=$(echo "$info" | jq -r '.height')
        refresh=$(echo "$info" | jq -r '.refreshRate')
        scale=$(echo "$info" | jq -r '.scale')
        x=$(echo "$info" | jq -r '.x')
        y=$(echo "$info" | jq -r '.y')

        # Additional details
        local transform dpms vrr model make
        transform=$(echo "$info" | jq -r '.transform')
        dpms=$(echo "$info" | jq -r '.dpmsStatus')
        vrr=$(echo "$info" | jq -r '.vrr')
        make=$(echo "$info" | jq -r '.make // empty')
        model=$(echo "$info" | jq -r '.model // empty')

        # Format refresh rate nicely
        local refresh_int
        refresh_int=$(printf "%.0f" "$refresh" 2>/dev/null || echo "$refresh")

        # Transform to human readable
        local transform_str=""
        case $transform in
            0) transform_str="" ;;
            1) transform_str="90°" ;;
            2) transform_str="180°" ;;
            3) transform_str="270°" ;;
            4) transform_str="flipped" ;;
            5) transform_str="flipped-90°" ;;
            6) transform_str="flipped-180°" ;;
            7) transform_str="flipped-270°" ;;
        esac

        # VRR to human readable
        local vrr_str=""
        if [ "$vrr" = "true" ] || [ "$vrr" = "1" ]; then
            vrr_str=" VRR"
        fi

        local status_lines=""
        status_lines+=$'  '"${GREEN}${mon}${NC}:"$'\n'

        # Show make/model if available
        if [ -n "$make" ] && [ "$make" != "null" ]; then
            status_lines+=$'  '"${CYAN}Device:${NC} $make $model"$'\n'
        fi

        status_lines+=$'  '"${CYAN}Resolution:${NC} ${width}x${height}@${refresh_int}Hz${vrr_str}"$'\n'
        # Calculate logical resolution safely
        local logical_w logical_h
        if command -v bc &>/dev/null && [ -n "$scale" ] && [ "$scale" != "0" ]; then
            logical_w=$(echo "scale=0; $width / $scale" | bc 2>/dev/null) || logical_w="$width"
            logical_h=$(echo "scale=0; $height / $scale" | bc 2>/dev/null) || logical_h="$height"
        else
            logical_w="$width"
            logical_h="$height"
        fi
        status_lines+=$'  '"${CYAN}Scale:${NC} ${scale}x (logical: ${logical_w}x${logical_h})"$'\n'
        status_lines+=$'  '"${CYAN}Position:${NC} ${x},${y}"$'\n'

        if [ -n "$transform_str" ]; then
            status_lines+=$'  '"${CYAN}Rotation:${NC} $transform_str"$'\n'
        fi

        if [ "$dpms" = "false" ] || [ "$dpms" = "0" ]; then
            status_lines+=$'  '"${CYAN}DPMS:${NC} ${RED}Off${NC}"$'\n'
        fi

        if [ -n "$menu_pad" ]; then
            center_block "$status_lines" "$UI_BLOCK_WIDTH" "$menu_pad"
        else
            center_block "$status_lines" "$UI_BLOCK_WIDTH"
        fi
        c_echo ""
    done <<< "$monitors"
}

# Show current config file contents
show_config() {
    c_echo "${CYAN}Current Config File ($CONFIG_FILE):${NC}"
    c_echo "${YELLOW}────────────────────────────────────────${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        local config_lines
        config_lines=$(grep -v "^#" "$CONFIG_FILE" | grep -v "^$" | head -20)
        center_block "$config_lines" "$UI_BLOCK_WIDTH"
    else
        c_echo "${RED}Config file not found!${NC}"
    fi
    c_echo ""
}

# Select a monitor
select_monitor() {
    local mon_count
    mon_count=$(get_monitor_count)
    if [ "$mon_count" -eq 0 ]; then
        c_echo "${RED}No monitors detected!${NC}"
        return 1
    fi

    local monitors
    monitors=$(get_monitors)

    c_echo "${CYAN}Select Monitor:${NC}"
    c_echo "${YELLOW}────────────────────────────────────────${NC}"

    local i=1
    local mon_array=()
    local mon_lines=""
    while IFS= read -r mon; do
        [ -z "$mon" ] && continue
        mon_array+=("$mon")
        local info width height
        info=$(get_monitor_info "$mon")
        width=$(echo "$info" | jq -r '.width')
        height=$(echo "$info" | jq -r '.height')
        mon_lines+=$'  '"${GREEN}$i)${NC} $mon (${width}x${height})"$'\n'
        ((i++))
    done <<< "$monitors"

    center_block "$mon_lines" "$UI_BLOCK_WIDTH"
    c_echo ""
    local choice
    prompt_centered "Enter choice [1-$((i-1))]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#mon_array[@]}" ]; then
        SELECTED_MONITOR="${mon_array[$((choice-1))]}"
        return 0
    else
        c_echo "${RED}Invalid choice!${NC}"
        return 1
    fi
}

# Select resolution and refresh rate
select_resolution() {
    local monitor="$1"
    local modes
    modes=$(get_available_modes "$monitor")

    if [ -z "$modes" ]; then
        c_echo "${RED}No available modes found for $monitor${NC}"
        return 1
    fi

    c_echo "${CYAN}Available Resolutions for $monitor:${NC}"
    c_echo "${YELLOW}────────────────────────────────────────${NC}"

    local i=1
    local mode_array=()
    local mode_lines=""
    while IFS= read -r mode; do
        [ -z "$mode" ] && continue
        mode_array+=("$mode")
        mode_lines+=$'  '"${GREEN}$i)${NC} $mode"$'\n'
        ((i++))
    done <<< "$modes"

    center_block "$mode_lines" "$UI_BLOCK_WIDTH"
    c_echo ""
    local choice
    prompt_centered "Enter choice [1-$((i-1))]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#mode_array[@]}" ]; then
        SELECTED_MODE=$(normalize_mode "${mode_array[$((choice-1))]}")
        return 0
    else
        c_echo "${RED}Invalid choice!${NC}"
        return 1
    fi
}

# Select scale factor
select_scale() {
    c_echo "${CYAN}Select Scale Factor:${NC}"
    c_echo "${YELLOW}────────────────────────────────────────${NC}"
    local scale_lines=""
    scale_lines+=$'  '"${GREEN}1)${NC} 1.0    (100% - No scaling)"$'\n'
    scale_lines+=$'  '"${GREEN}2)${NC} 1.25   (125%)"$'\n'
    scale_lines+=$'  '"${GREEN}3)${NC} 1.5    (150%)"$'\n'
    scale_lines+=$'  '"${GREEN}4)${NC} 1.666667 (166% - Good for 4K at 27\")"$'\n'
    scale_lines+=$'  '"${GREEN}5)${NC} 1.75   (175%)"$'\n'
    scale_lines+=$'  '"${GREEN}6)${NC} 2.0    (200% - Retina/HiDPI)"$'\n'
    scale_lines+=$'  '"${GREEN}7)${NC} Custom"$'\n'
    center_block "$scale_lines" "$UI_BLOCK_WIDTH"
    c_echo ""
    local choice
    prompt_centered "Enter choice [1-7]: " choice

    case $choice in
        1) SELECTED_SCALE="1" ;;
        2) SELECTED_SCALE="1.25" ;;
        3) SELECTED_SCALE="1.5" ;;
        4) SELECTED_SCALE="1.666667" ;;
        5) SELECTED_SCALE="1.75" ;;
        6) SELECTED_SCALE="2" ;;
        7)
            c_echo "${YELLOW}Note: Hyprland supports specific scales like 1, 1.25, 1.333333, 1.5, 1.666667, 1.75, 2${NC}"
            prompt_centered "Enter custom scale: " SELECTED_SCALE
            # Validate: must be a positive number > 0
            if ! [[ "$SELECTED_SCALE" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                c_echo "${RED}Invalid scale value!${NC}"
                return 1
            fi
            # Check scale is greater than 0
            if command -v bc &>/dev/null; then
                if [[ $(echo "$SELECTED_SCALE <= 0" | bc -l) -eq 1 ]]; then
                    c_echo "${RED}Scale must be greater than 0!${NC}"
                    return 1
                fi
            elif [[ "$SELECTED_SCALE" == "0" || "$SELECTED_SCALE" == ".0" || "$SELECTED_SCALE" == "0.0" ]]; then
                c_echo "${RED}Scale must be greater than 0!${NC}"
                return 1
            fi
            ;;
        *)
            c_echo "${RED}Invalid choice!${NC}"
            return 1
            ;;
    esac
    return 0
}

# Backup config file
backup_config() {
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$BACKUP_FILE"
        c_echo "${GREEN}Backup created: $BACKUP_FILE${NC}"
    fi
}

# Load current monitor settings into arrays
load_current_monitors() {
    MONITOR_MODES=()
    MONITOR_SCALES=()
    MONITOR_POSITIONS=()

    local mon_count
    mon_count=$(get_monitor_count)
    if [ "$mon_count" -eq 0 ]; then
        return
    fi

    local monitors
    monitors=$(get_monitors)
    while IFS= read -r mon; do
        [ -z "$mon" ] && continue
        local info width height refresh scale x y
        info=$(get_monitor_info "$mon")
        width=$(echo "$info" | jq -r '.width')
        height=$(echo "$info" | jq -r '.height')
        refresh=$(echo "$info" | jq -r '.refreshRate' | cut -d'.' -f1)
        scale=$(echo "$info" | jq -r '.scale')
        x=$(echo "$info" | jq -r '.x')
        y=$(echo "$info" | jq -r '.y')

        MONITOR_MODES["$mon"]="${width}x${height}@${refresh}"
        MONITOR_SCALES["$mon"]="$scale"
        MONITOR_POSITIONS["$mon"]="${x}x${y}"
    done <<< "$monitors"
}

# Get logical width of a monitor (accounting for scale) - uses current hyprctl values
get_logical_width() {
    local monitor="$1"
    local info width scale result
    info=$(get_monitor_info "$monitor")
    width=$(echo "$info" | jq -r '.width' 2>/dev/null)
    scale=$(echo "$info" | jq -r '.scale' 2>/dev/null)
    # Handle null/empty values from jq
    [[ -z "$width" || "$width" == "null" ]] && width=1920
    [[ -z "$scale" || "$scale" == "null" || "$scale" == "0" ]] && scale=1
    # Use bc for floating point division, fallback to integer if bc unavailable
    if command -v bc &>/dev/null; then
        result=$(echo "scale=0; $width / $scale" | bc 2>/dev/null) || result="$width"
    else
        result="$width"
    fi
    echo "${result:-$width}"
}

# Get logical height of a monitor (accounting for scale) - uses current hyprctl values
get_logical_height() {
    local monitor="$1"
    local info height scale result
    info=$(get_monitor_info "$monitor")
    height=$(echo "$info" | jq -r '.height' 2>/dev/null)
    scale=$(echo "$info" | jq -r '.scale' 2>/dev/null)
    # Handle null/empty values from jq
    [[ -z "$height" || "$height" == "null" ]] && height=1080
    [[ -z "$scale" || "$scale" == "null" || "$scale" == "0" ]] && scale=1
    if command -v bc &>/dev/null; then
        result=$(echo "scale=0; $height / $scale" | bc 2>/dev/null) || result="$height"
    else
        result="$height"
    fi
    echo "${result:-$height}"
}

# Get logical width using pending mode/scale if set, otherwise current hyprctl values
get_pending_logical_width() {
    local monitor="$1"
    local width scale result

    # Check if we have pending values in MONITOR_MODES/MONITOR_SCALES
    if [[ -n "${MONITOR_MODES[$monitor]:-}" ]] && [[ -n "${MONITOR_SCALES[$monitor]:-}" ]]; then
        # Parse width from mode (e.g., "1920x1080@60" -> 1920)
        local mode="${MONITOR_MODES[$monitor]}"
        width="${mode%%x*}"
        scale="${MONITOR_SCALES[$monitor]}"
    else
        # Fall back to current hyprctl values
        get_logical_width "$monitor"
        return
    fi

    # Calculate logical width
    if command -v bc &>/dev/null && [ -n "$scale" ] && [ "$scale" != "0" ]; then
        result=$(echo "scale=0; $width / $scale" | bc 2>/dev/null) || result="$width"
    else
        result="$width"
    fi
    echo "${result:-$width}"
}

# Get logical height using pending mode/scale if set, otherwise current hyprctl values
get_pending_logical_height() {
    local monitor="$1"
    local height scale result

    # Check if we have pending values in MONITOR_MODES/MONITOR_SCALES
    if [[ -n "${MONITOR_MODES[$monitor]:-}" ]] && [[ -n "${MONITOR_SCALES[$monitor]:-}" ]]; then
        # Parse height from mode (e.g., "1920x1080@60" -> 1080)
        local mode="${MONITOR_MODES[$monitor]}"
        local resolution="${mode%@*}"
        height="${resolution#*x}"
        scale="${MONITOR_SCALES[$monitor]}"
    else
        # Fall back to current hyprctl values
        get_logical_height "$monitor"
        return
    fi

    # Calculate logical height
    if command -v bc &>/dev/null && [ -n "$scale" ] && [ "$scale" != "0" ]; then
        result=$(echo "scale=0; $height / $scale" | bc 2>/dev/null) || result="$height"
    else
        result="$height"
    fi
    echo "${result:-$height}"
}

# Select position for monitor
select_position() {
    local monitor="$1"

    c_echo "${CYAN}Select Position for $monitor:${NC}"
    c_echo "${YELLOW}────────────────────────────────────────${NC}"
    local pos_lines=""
    pos_lines+=$'  '"${GREEN}1)${NC} Auto (let Hyprland decide)"$'\n'
    pos_lines+=$'  '"${GREEN}2)${NC} Left (0x0)"$'\n'
    pos_lines+=$'  '"${GREEN}3)${NC} Right of other monitors"$'\n'
    pos_lines+=$'  '"${GREEN}4)${NC} Above other monitors"$'\n'
    pos_lines+=$'  '"${GREEN}5)${NC} Below other monitors"$'\n'
    pos_lines+=$'  '"${GREEN}6)${NC} Custom coordinates"$'\n'
    center_block "$pos_lines" "$UI_BLOCK_WIDTH"
    c_echo ""
    local choice
    prompt_centered "Enter choice [1-6]: " choice

    case $choice in
        1) SELECTED_POSITION="auto" ;;
        2) SELECTED_POSITION="0x0" ;;
        3)
            # Calculate position to the right of all configured monitors
            local max_x=0
            for mon in "${!MONITOR_POSITIONS[@]}"; do
                if [ "$mon" != "$monitor" ]; then
                    local pos="${MONITOR_POSITIONS[$mon]}"
                    # Skip monitors with auto positioning
                    [[ "$pos" == "auto" ]] && continue
                    local pos_x logical_w
                    pos_x=$(echo "$pos" | cut -d'x' -f1)
                    # Validate numeric
                    [[ "$pos_x" =~ ^-?[0-9]+$ ]] || pos_x=0
                    # Use pending mode/scale if set, otherwise current from hyprctl
                    logical_w=$(get_pending_logical_width "$mon")
                    [[ "$logical_w" =~ ^[0-9]+$ ]] || logical_w=0
                    local right=$((pos_x + logical_w))
                    [ "$right" -gt "$max_x" ] && max_x=$right
                fi
            done
            SELECTED_POSITION="${max_x}x0"
            ;;
        4)
            # Above: find min Y and subtract this monitor's logical height
            local min_y=0
            for mon in "${!MONITOR_POSITIONS[@]}"; do
                if [ "$mon" != "$monitor" ]; then
                    local pos="${MONITOR_POSITIONS[$mon]}"
                    # Skip monitors with auto positioning
                    [[ "$pos" == "auto" ]] && continue
                    local pos_y
                    pos_y=$(echo "$pos" | cut -d'x' -f2)
                    # Validate numeric
                    [[ "$pos_y" =~ ^-?[0-9]+$ ]] || continue
                    [ "$pos_y" -lt "$min_y" ] && min_y=$pos_y
                fi
            done
            local logical_h
            logical_h=$(get_pending_logical_height "$monitor")
            [[ "$logical_h" =~ ^[0-9]+$ ]] || logical_h=1080
            SELECTED_POSITION="0x$((min_y - logical_h))"
            ;;
        5)
            # Below: find max Y + height of that monitor
            local max_bottom=0
            for mon in "${!MONITOR_POSITIONS[@]}"; do
                if [ "$mon" != "$monitor" ]; then
                    local pos="${MONITOR_POSITIONS[$mon]}"
                    # Skip monitors with auto positioning
                    [[ "$pos" == "auto" ]] && continue
                    local mon_pos_y mon_logical_h
                    mon_pos_y=$(echo "$pos" | cut -d'x' -f2)
                    mon_logical_h=$(get_pending_logical_height "$mon")
                    # Ensure we have valid numbers
                    [[ "$mon_pos_y" =~ ^-?[0-9]+$ ]] || mon_pos_y=0
                    [[ "$mon_logical_h" =~ ^[0-9]+$ ]] || mon_logical_h=0
                    local bottom=$((mon_pos_y + mon_logical_h))
                    [ "$bottom" -gt "$max_bottom" ] && max_bottom=$bottom
                fi
            done
            SELECTED_POSITION="0x${max_bottom}"
            ;;
        6)
            local pos_x pos_y
            prompt_centered "Enter X coordinate: " pos_x
            prompt_centered "Enter Y coordinate: " pos_y
            # Validate numeric input
            if ! [[ "$pos_x" =~ ^-?[0-9]+$ ]] || ! [[ "$pos_y" =~ ^-?[0-9]+$ ]]; then
                c_echo "${RED}Invalid coordinates! Must be integers.${NC}"
                return 1
            fi
            SELECTED_POSITION="${pos_x}x${pos_y}"
            ;;
        *)
            c_echo "${RED}Invalid choice!${NC}"
            return 1
            ;;
    esac
    return 0
}

# Write new configuration for all monitors
write_config() {
    # Ensure config directory exists
    local config_dir
    config_dir="$(dirname "$CONFIG_FILE")"
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir" || {
            c_echo "${RED}Failed to create config directory: $config_dir${NC}"
            return 1
        }
    fi

    backup_config

    # Create new config
    cat > "$CONFIG_FILE" << EOF
# See https://wiki.hyprland.org/Configuring/Monitors/
# List current monitors and resolutions possible: hyprctl monitors
# Format: monitor = [port], resolution@refresh, position, scale
# Generated by monitor-tui.sh on $(date)

EOF

    # Write each configured monitor
    for mon in "${!MONITOR_MODES[@]}"; do
        local mode="${MONITOR_MODES[$mon]}"
        local scale="${MONITOR_SCALES[$mon]}"
        local pos="${MONITOR_POSITIONS[$mon]}"

        echo "monitor = $mon, $mode, $pos, $scale" >> "$CONFIG_FILE"
    done

    # Add fallback for hot-plugged monitors
    {
        echo ""
        echo "# Fallback for other/hot-plugged monitors"
        echo "monitor = , preferred, auto, auto"
    } >> "$CONFIG_FILE"

    c_echo "${GREEN}Configuration written to $CONFIG_FILE${NC}"
}

# Apply monitor configuration dynamically (without full reload)
apply_monitors_dynamically() {
    if ! is_hyprland_running; then
        c_echo "${RED}Hyprland is not running. Config will apply on next start.${NC}"
        return 1
    fi
    c_echo "${YELLOW}Applying configuration...${NC}"

    local success=true
    for mon in "${!MONITOR_MODES[@]}"; do
        local mode="${MONITOR_MODES[$mon]}"
        local scale="${MONITOR_SCALES[$mon]}"
        local pos="${MONITOR_POSITIONS[$mon]}"

        if ! hyprctl keyword monitor "$mon, $mode, $pos, $scale" >/dev/null 2>&1; then
            c_echo "${RED}Failed to apply config for $mon${NC}"
            success=false
        fi
    done

    if $success; then
        c_echo "${GREEN}Configuration applied!${NC}"
    else
        c_echo "${YELLOW}Some monitors may not have been configured correctly.${NC}"
        return 1
    fi
}

# Apply a preset scale to all monitors dynamically
apply_preset_dynamically() {
    local scale="$1"
    if ! is_hyprland_running; then
        c_echo "${RED}Hyprland is not running. Config will apply on next start.${NC}"
        return 1
    fi
    c_echo "${YELLOW}Applying configuration...${NC}"

    local success=true
    local monitors
    monitors=$(get_monitors)
    while IFS= read -r mon; do
        [ -z "$mon" ] && continue
        if ! hyprctl keyword monitor "$mon, preferred, auto, $scale" >/dev/null 2>&1; then
            c_echo "${RED}Failed to apply config for $mon${NC}"
            success=false
        fi
    done <<< "$monitors"

    if $success; then
        c_echo "${GREEN}Configuration applied!${NC}"
    else
        c_echo "${YELLOW}Some monitors may not have been configured correctly.${NC}"
        return 1
    fi
}

# Apply configuration with full reload (fallback for restore)
apply_config() {
    if ! is_hyprland_running; then
        c_echo "${RED}Hyprland is not running. Config will apply on next start.${NC}"
        return 1
    fi
    c_echo "${YELLOW}Applying configuration (reload)...${NC}"
    c_echo "${YELLOW}Note: TUI will close during reload.${NC}"
    sleep 1
    if hyprctl reload >/dev/null 2>&1; then
        c_echo "${GREEN}Configuration applied!${NC}"
    else
        c_echo "${RED}Failed to apply configuration.${NC}"
        return 1
    fi
}

# Restore from backup
restore_backup() {
    if [ -f "$BACKUP_FILE" ]; then
        c_echo "${CYAN}Backup file contents:${NC}"
        c_echo "${YELLOW}────────────────────────────────────────${NC}"
        local backup_lines
        backup_lines=$(grep -v "^#" "$BACKUP_FILE" | grep -v "^$" | head -20)
        center_block "$backup_lines" "$UI_BLOCK_WIDTH"
        c_echo ""

        local confirm
        prompt_centered "Restore this configuration? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            cp "$BACKUP_FILE" "$CONFIG_FILE"
            c_echo "${GREEN}Restored from backup!${NC}"
            apply_config
        else
            c_echo "${YELLOW}Restore cancelled.${NC}"
        fi
    else
        c_echo "${RED}No backup file found!${NC}"
    fi
}

# Quick preset menu
quick_presets() {
    c_echo "${CYAN}Quick Presets:${NC}"
    c_echo "${YELLOW}────────────────────────────────────────${NC}"
    c_echo "${YELLOW}Note: Presets apply the same scale to ALL monitors.${NC}"
    c_echo "${YELLOW}For mixed monitor setups, use \"Configure specific monitor\" instead.${NC}"
    c_echo ""
    local preset_lines=""
    preset_lines+=$'  '"${GREEN}1)${NC} 2x HiDPI (Retina - 13\" 2.8K, 27\" 5K, 32\" 6K)"$'\n'
    preset_lines+=$'  '"${GREEN}2)${NC} 1.666x (Good for 27\"/32\" 4K)"$'\n'
    preset_lines+=$'  '"${GREEN}3)${NC} 1x Native (1080p, 1440p displays)"$'\n'
    preset_lines+=$'  '"${GREEN}4)${NC} Back to main menu"$'\n'
    center_block "$preset_lines" "$UI_BLOCK_WIDTH"
    c_echo ""
    local choice
    prompt_centered "Enter choice [1-4]: " choice

    local preset_name=""
    local preset_content=""
    local preset_scale=""

    case $choice in
        1)
            preset_name="2x HiDPI"
            preset_scale="2"
            preset_content='# See https://wiki.hyprland.org/Configuring/Monitors/
# Optimized for retina-class 2x displays, like 13" 2.8K, 27" 5K, 32" 6K.
monitor=,preferred,auto,2'
            ;;
        2)
            preset_name="4K"
            preset_scale="1.666667"
            preset_content='# See https://wiki.hyprland.org/Configuring/Monitors/
# Good compromise for 27" or 32" 4K monitors (fractional)
monitor=,preferred,auto,1.666667'
            ;;
        3)
            preset_name="1x native"
            preset_scale="1"
            preset_content='# See https://wiki.hyprland.org/Configuring/Monitors/
# Straight 1x setup for low-resolution displays like 1080p or 1440p
monitor=,preferred,auto,1'
            ;;
        4)
            return 0
            ;;
        *)
            c_echo "${RED}Invalid choice!${NC}"
            return 1
            ;;
    esac

    c_echo ""
    c_echo "${CYAN}Preset: ${GREEN}${preset_name}${NC}"
    c_echo "${YELLOW}────────────────────────────────────────${NC}"
    center_block "$preset_content" "$UI_BLOCK_WIDTH"
    c_echo ""

    local confirm
    prompt_centered "Write this configuration? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Ensure config directory exists
        local config_dir
        config_dir="$(dirname "$CONFIG_FILE")"
        if [ ! -d "$config_dir" ]; then
            mkdir -p "$config_dir" || {
                c_echo "${RED}Failed to create config directory: $config_dir${NC}"
                return 1
            }
        fi
        backup_config
        echo "$preset_content" > "$CONFIG_FILE"
        c_echo "${GREEN}Applied $preset_name preset!${NC}"
        c_echo ""
        apply_preset_dynamically "$preset_scale"
    else
        c_echo "${YELLOW}Configuration cancelled.${NC}"
    fi
}

# Configure specific monitor
configure_monitor() {
    show_header

    if ! is_hyprland_running; then
        c_echo "${RED}Hyprland is not running. Cannot detect monitors.${NC}"
        c_echo "${YELLOW}Use Quick Presets or Edit Config Manually instead.${NC}"
        prompt_centered "Press Enter to continue..." _
        return 1
    fi

    load_current_monitors

    if ! select_monitor; then
        prompt_centered "Press Enter to continue..." _
        return 1
    fi

    c_echo ""
    if ! select_resolution "$SELECTED_MONITOR"; then
        prompt_centered "Press Enter to continue..." _
        return 1
    fi

    c_echo ""
    if ! select_scale; then
        prompt_centered "Press Enter to continue..." _
        return 1
    fi

    # Only ask for position if multiple monitors
    local mon_count
    mon_count=$(get_monitor_count)
    if [ "$mon_count" -gt 1 ]; then
        c_echo ""
        if ! select_position "$SELECTED_MONITOR"; then
            prompt_centered "Press Enter to continue..." _
            return 1
        fi
    else
        SELECTED_POSITION="auto"
    fi

    c_echo ""
    c_echo "${CYAN}Configuration Summary:${NC}"
    c_echo "${YELLOW}────────────────────────────────────────${NC}"
    local summary_lines=""
    summary_lines+=$'  '"Monitor:   ${GREEN}$SELECTED_MONITOR${NC}"$'\n'
    summary_lines+=$'  '"Mode:      ${GREEN}$SELECTED_MODE${NC}"$'\n'
    summary_lines+=$'  '"Scale:     ${GREEN}$SELECTED_SCALE${NC}"$'\n'
    summary_lines+=$'  '"Position:  ${GREEN}$SELECTED_POSITION${NC}"$'\n'
    center_block "$summary_lines" "$UI_BLOCK_WIDTH"
    c_echo ""

    local confirm
    prompt_centered "Write this configuration? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        MONITOR_MODES["$SELECTED_MONITOR"]="$SELECTED_MODE"
        MONITOR_SCALES["$SELECTED_MONITOR"]="$SELECTED_SCALE"
        MONITOR_POSITIONS["$SELECTED_MONITOR"]="$SELECTED_POSITION"
        write_config
        c_echo ""
        apply_monitors_dynamically
    else
        c_echo "${YELLOW}Configuration cancelled.${NC}"
    fi

    prompt_centered "Press Enter to continue..." _
}

# Main menu
main_menu() {
    while true; do
        show_header

        c_echo "${CYAN}Main Menu:${NC}"
        c_echo "${YELLOW}────────────────────────────────────────${NC}"
        local menu_lines=""
        menu_lines+=$'  '"${GREEN}1)${NC} Configure specific monitor"$'\n'
        menu_lines+=$'  '"${GREEN}2)${NC} Quick presets"$'\n'
        menu_lines+=$'  '"${GREEN}3)${NC} View current config file"$'\n'
        menu_lines+=$'  '"${GREEN}4)${NC} Apply current config (reload Hyprland)"$'\n'
        menu_lines+=$'  '"${GREEN}5)${NC} Restore from backup"$'\n'
        menu_lines+=$'  '"${GREEN}6)${NC} Edit config manually (opens \$EDITOR)"$'\n'
        menu_lines+=$'  '"${GREEN}q)${NC} Quit"$'\n'
        LAST_MENU_PAD=$(get_block_pad "$menu_lines")

        show_monitor_status

        center_block "$menu_lines" "$UI_BLOCK_WIDTH" "$LAST_MENU_PAD"
        c_echo ""
        local choice
        prompt_centered "Enter choice: " choice

        case $choice in
            1) configure_monitor ;;
            2)
                show_header
                quick_presets
                prompt_centered "Press Enter to continue..." _
                ;;
            3)
                show_header
                show_config
                prompt_centered "Press Enter to continue..." _
                ;;
            4)
                apply_config
                prompt_centered "Press Enter to continue..." _
                ;;
            5)
                show_header
                restore_backup
                prompt_centered "Press Enter to continue..." _
                ;;
            6)
                # Open editor in a new terminal window
                local editor_cmd="${EDITOR:-nano}"
                local terminal_cmd=""
                if command -v ghostty >/dev/null 2>&1; then
                    terminal_cmd="ghostty -e"
                elif command -v kitty >/dev/null 2>&1; then
                    terminal_cmd="kitty -e"
                elif command -v alacritty >/dev/null 2>&1; then
                    terminal_cmd="alacritty -e"
                elif command -v foot >/dev/null 2>&1; then
                    terminal_cmd="foot --"
                else
                    c_echo "${RED}No supported terminal found!${NC}"
                    prompt_centered "Press Enter to continue..." _
                    continue
                fi
                eval "$terminal_cmd $editor_cmd \"\$CONFIG_FILE\"" >/dev/null 2>&1 &
                disown 2>/dev/null
                ;;
            q|Q)
                c_echo "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                c_echo "${RED}Invalid choice!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Check if Hyprland is actually running and responsive
is_hyprland_running() {
    hyprctl monitors -j &>/dev/null
    return $?
}

# Check and install dependencies
check_deps() {
    # Install jq if missing
    if ! command -v jq &> /dev/null; then
        c_echo "${YELLOW}Installing jq...${NC}"
        sudo pacman -S --noconfirm --needed jq
        if ! command -v jq &> /dev/null; then
            c_echo "${RED}Failed to install jq${NC}"
            exit 1
        fi
        c_echo "${GREEN}jq installed!${NC}"
    fi

    # Install bc if missing (needed for logical resolution calculations)
    if ! command -v bc &> /dev/null; then
        c_echo "${YELLOW}Installing bc...${NC}"
        sudo pacman -S --noconfirm --needed bc
        if ! command -v bc &> /dev/null; then
            c_echo "${RED}Failed to install bc${NC}"
            exit 1
        fi
        c_echo "${GREEN}bc installed!${NC}"
    fi

    # Check for hyprctl binary
    if ! command -v hyprctl &> /dev/null; then
        c_echo "${RED}hyprctl not found. Is Hyprland installed?${NC}"
        exit 1
    fi
}

# Install function - sets up keybinding and detects monitor
install_setup() {
    u_echo "${CYAN}Running first-time setup...${NC}"
    echo ""

    local bindings_ok=false

    # Install the script to a stable path so the installer can be deleted
    local script_path
    script_path="$(realpath "$0")"
    if [ "$script_path" != "$INSTALL_PATH" ]; then
        mkdir -p "$INSTALL_DIR"
        cp "$script_path" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        script_path="$INSTALL_PATH"
    fi

    # Detect preferred terminal (use --title for window rules matching)
    local terminal_cmd=""
    if command -v ghostty >/dev/null 2>&1; then
        terminal_cmd="ghostty --title='Monitor Settings' -e"
    elif command -v kitty >/dev/null 2>&1; then
        terminal_cmd="kitty --title='Monitor Settings' -e"
    elif command -v alacritty >/dev/null 2>&1; then
        terminal_cmd="alacritty --title='Monitor Settings' -e"
    elif command -v foot >/dev/null 2>&1; then
        terminal_cmd="foot --title='Monitor Settings' --"
    else
        u_echo "${RED}No supported terminal found (ghostty, kitty, alacritty, foot)${NC}"
        return 1
    fi

    # Add keybinding and window rules if not already present
    if [ -f "$BINDINGS_FILE" ]; then
        if ! grep -q "monitor-tui" "$BINDINGS_FILE"; then
            u_echo "${YELLOW}Adding keybinding (Super+Alt+M) to $BINDINGS_FILE${NC}"

            # Add window rules AND keybinding to bindings.conf (match on title)
            {
                echo ""
                echo "# Monitor Configuration TUI"
                echo "windowrule = match:title Monitor Settings, float on"
                echo "windowrule = match:title Monitor Settings, size 800 600"
                echo "windowrule = match:title Monitor Settings, center on"
                echo "windowrule = match:title Monitor Settings, pin on"
                echo "bindd = SUPER ALT, M, Monitor Settings, exec, $terminal_cmd \"$script_path\""
                echo "# End Monitor Configuration TUI"
            } >> "$BINDINGS_FILE"
            u_echo "${GREEN}Keybinding and window rules added!${NC}"
            bindings_ok=true
        else
            u_echo "${GREEN}Keybinding already exists in config.${NC}"
            bindings_ok=true
        fi
    else
        u_echo "${RED}Error: Bindings file not found at $BINDINGS_FILE${NC}"
        u_echo "${YELLOW}Please create the file or check your Hyprland config.${NC}"
        u_echo "${YELLOW}Installation incomplete - run again after fixing.${NC}"
        return 1
    fi

    # Detect and display current monitor
    echo ""
    u_echo "${CYAN}Detecting monitors...${NC}"

    if is_hyprland_running; then
        local mon_count
        mon_count=$(get_monitor_count)
        if [ "$mon_count" -gt 0 ]; then
            u_echo "${GREEN}Detected $mon_count monitor(s):${NC}"
            local monitors
            monitors=$(get_monitors)
            while IFS= read -r mon; do
                [ -z "$mon" ] && continue
                local info width height refresh scale
                info=$(get_monitor_info "$mon")
                width=$(echo "$info" | jq -r '.width')
                height=$(echo "$info" | jq -r '.height')
                refresh=$(echo "$info" | jq -r '.refreshRate' | cut -d'.' -f1)
                scale=$(echo "$info" | jq -r '.scale')
                u_echo "  ${GREEN}$mon${NC}: ${width}x${height}@${refresh}Hz (scale: ${scale})"
            done <<< "$monitors"
        fi

        # Add binding and window rules dynamically (avoid full reload which breaks multi-monitor workspace switching)
        # Unbind first to prevent duplicate bindings, then add fresh
        hyprctl keyword unbind "SUPER ALT, M" >/dev/null 2>&1
        hyprctl keyword windowrule "match:title Monitor Settings, float on" >/dev/null 2>&1
        hyprctl keyword windowrule "match:title Monitor Settings, size 800 600" >/dev/null 2>&1
        hyprctl keyword windowrule "match:title Monitor Settings, center on" >/dev/null 2>&1
        hyprctl keyword windowrule "match:title Monitor Settings, pin on" >/dev/null 2>&1
        hyprctl keyword bindd "SUPER ALT, M, Monitor Settings, exec, $terminal_cmd \"$script_path\"" >/dev/null 2>&1
        echo ""
        u_echo "${GREEN}Press Super+Alt+M to open this TUI.${NC}"
    else
        u_echo "${YELLOW}Hyprland is not running.${NC}"
        u_echo "${YELLOW}Keybinding will be available after you start Hyprland.${NC}"
    fi

    # Mark as installed only if bindings were set up successfully
    if $bindings_ok; then
        touch "$INSTALLED_MARKER"
        echo ""
        u_echo "${GREEN}Installation complete!${NC}"
    fi
    read -r -p "Press Enter to continue..." _
}

# Uninstall function
uninstall() {
    c_echo "${YELLOW}Removing monitor-tui...${NC}"

    # Remove keybinding and window rules from bindings.conf
    if [ -f "$BINDINGS_FILE" ]; then
        # Primary cleanup: remove the marked block
        sed -i '/# Monitor Configuration TUI/,/# End Monitor Configuration TUI/d' "$BINDINGS_FILE"
        # Fallback: remove any remaining monitor-tui.sh references only
        sed -i '/monitor-tui\.sh/d' "$BINDINGS_FILE"
        # Fallback: remove exact title match rules (be specific to avoid collateral damage)
        sed -i '/title:\^Monitor Settings\$/d' "$BINDINGS_FILE"
        sed -i '/match:title Monitor Settings/d' "$BINDINGS_FILE"
        c_echo "${GREEN}Keybinding and window rules removed.${NC}"
    fi

    # Remove installed script
    rm -f "$INSTALL_PATH"

    # Remove marker
    rm -f "$INSTALLED_MARKER"

    c_echo "${GREEN}Uninstall complete. You can delete this script manually.${NC}"

    # Remove the binding dynamically (avoid full reload which breaks multi-monitor workspace switching)
    if is_hyprland_running; then
        hyprctl keyword unbind "SUPER ALT, M" >/dev/null 2>&1
    fi
}

# Entry point
# Handle command line arguments - parse before deps so --uninstall works without hyprctl
case "${1:-}" in
    --uninstall)
        uninstall
        exit 0
        ;;
    --install)
        check_deps
        install_setup
        exit 0
        ;;
    *)
        check_deps
        # Check if first run - just install and exit
        if [ ! -f "$INSTALLED_MARKER" ]; then
            install_setup
            exit 0
        fi
        main_menu
        ;;
esac
