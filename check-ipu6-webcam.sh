#!/usr/bin/env bash
# Read-only diagnostics for an Intel IPU6/MIPI webcam routed through Intel's
# camera HAL and v4l2-relayd into a v4l2loopback device.
#
# Usage:
#   bash check-ipu6-webcam.sh
#   bash check-ipu6-webcam.sh --live-test  # briefly opens the virtual camera
#   bash check-ipu6-webcam.sh --run-fixes  # apply reversible runtime fixes

set -uo pipefail

OK=0
WARN=0
FAIL=0
LIVE_TEST=0
RUN_FIXES=0

for arg in "$@"; do
    case "$arg" in
        --live-test) LIVE_TEST=1 ;;
        --run-fixes) RUN_FIXES=1 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Diagnose an Intel IPU6/MIPI webcam that uses Intel's camera HAL, v4l2-relayd,
and a v4l2loopback virtual camera. The default run checks packages, kernel
modules, GStreamer elements, camera devices, the relay service, and Cheese
Snap camera access. It does not change system state.

Options:
  --live-test   After the checks, briefly open the relay camera and request
                30 frames through GStreamer. Close Cheese and other camera
                apps first. This opens the camera for up to 15 seconds.

  --run-fixes   Apply reversible runtime actions before the checks: load
                v4l2loopback if its module is available but not loaded, then
                reset and restart v4l2-relayd@default. This does not install
                packages or edit configuration files. Sudo access is needed
                unless the script is already running as root.

  -h, --help    Show this help and exit.

Flags may be combined. For example:
  $0 --run-fixes --live-test
EOF
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\nUsage: %s [--live-test] [--run-fixes]\n' "$arg" "$0" >&2
            exit 2
            ;;
    esac
done

ok() {
    printf '[ OK ] %s\n' "$*"
    ((OK += 1))
}

warn() {
    printf '[WARN] %s\n' "$*"
    ((WARN += 1))
}

fail() {
    printf '[FAIL] %s\n' "$*"
    ((FAIL += 1))
}

info() {
    printf '[INFO] %s\n' "$*"
}

section() {
    printf '\n== %s ==\n' "$*"
}

run_as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

if (( RUN_FIXES )); then
    section "Runtime fixes (no config files or packages will be changed)"
    can_apply_fixes=1
    if (( EUID != 0 )); then
        if command -v sudo >/dev/null 2>&1; then
            info "Sudo access is needed to load a kernel module and restart the system relay."
            if ! sudo -v; then
                warn "Could not obtain sudo access; runtime fixes will be skipped."
                can_apply_fixes=0
            fi
        else
            warn "sudo is unavailable and this script is not running as root; runtime fixes will be skipped."
            can_apply_fixes=0
        fi
    fi

    if (( can_apply_fixes )); then
        if command -v modinfo >/dev/null 2>&1 && modinfo v4l2loopback >/dev/null 2>&1; then
            if grep -qE '^v4l2loopback[[:space:]]' /proc/modules 2>/dev/null; then
                info "v4l2loopback is already loaded; leaving it in place."
            elif run_as_root modprobe v4l2loopback; then
                ok "Loaded v4l2loopback for the current session."
            else
                warn "Could not load v4l2loopback. Check the modprobe error and DKMS/Secure Boot status."
            fi
        else
            warn "v4l2loopback is unavailable for this kernel; it cannot be loaded without installing or repairing a module."
        fi

        if command -v systemctl >/dev/null 2>&1 && systemctl cat v4l2-relayd@default.service >/dev/null 2>&1; then
            if run_as_root systemctl reset-failed v4l2-relayd@default.service &&
                run_as_root systemctl restart v4l2-relayd@default.service; then
                ok "Reset and restarted v4l2-relayd@default.service."
            else
                warn "Could not restart v4l2-relayd@default.service; inspect its journal below."
            fi
        else
            warn "The v4l2-relayd@default.service unit is unavailable; nothing was restarted."
        fi
    fi
fi

package_installed() {
    local package="$1"
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" == "installed" ]]
}

section "System"
if [[ -r /etc/os-release ]]; then
    # os-release is a shell-compatible file supplied by the operating system.
    . /etc/os-release
    info "OS: ${PRETTY_NAME:-unknown}"
else
    warn "Cannot read /etc/os-release."
fi
info "Kernel: $(uname -r 2>/dev/null || printf 'unknown')"

if command -v lspci >/dev/null 2>&1; then
    ipu_line="$(lspci -nn 2>/dev/null | grep -iE 'image processing|imaging signal processor|IPU[0-9]' || true)"
    if [[ -n "$ipu_line" ]]; then
        ok "PCI camera processor detected: ${ipu_line//$'\n'/; }"
    else
        warn "No Intel IPU entry found in lspci. Some systems expose camera hardware differently."
    fi
else
    info "lspci is not installed; skipping PCI hardware identification."
fi

section "Required packages"
if command -v dpkg-query >/dev/null 2>&1; then
    required_packages=(
        "gstreamer1.0-icamera|Intel GStreamer camera source"
        "libcamhal0|Intel camera HAL"
        "libcamhal-ipu6ep|Intel IPU6EP camera HAL plugin"
        "v4l2-relayd|GStreamer-to-V4L2 camera relay"
        "v4l2loopback-dkms|virtual V4L2 camera kernel module"
        "v4l-utils|V4L2 device inspection tools"
    )
    for item in "${required_packages[@]}"; do
        package="${item%%|*}"
        description="${item#*|}"
        if package_installed "$package"; then
            ok "$package is installed ($description)."
        else
            fail "$package is missing ($description). Install with: sudo apt install $package"
        fi
    done
else
    warn "dpkg-query is unavailable; cannot check installed Debian/Ubuntu packages."
fi

section "Cheese installation and Snap camera access"
if command -v snap >/dev/null 2>&1 && snap list cheese >/dev/null 2>&1; then
    cheese_snap_version="$(snap list cheese 2>/dev/null | awk 'NR == 2 { print $2 }')"
    ok "Cheese is installed as a Snap${cheese_snap_version:+ (version $cheese_snap_version)}."
    if [[ "$(command -v cheese 2>/dev/null || true)" == /snap/bin/* ]]; then
        ok "The 'cheese' command resolves to the Snap launcher: $(command -v cheese)."
    else
        warn "A Cheese Snap is installed, but 'cheese' does not resolve to /snap/bin/cheese. Check which package your desktop launcher starts."
    fi

    camera_connections="$(snap connections cheese 2>&1 || true)"
    camera_slot="$(printf '%s\n' "$camera_connections" | awk '$1 == "camera" && $2 == "cheese:camera" { print $3; exit }')"
    if [[ -z "$camera_slot" ]]; then
        warn "The Cheese Snap does not show a camera interface connection. Check 'snap connections cheese' and the Snap's plugs."
    elif [[ "$camera_slot" == "-" ]]; then
        fail "The Cheese Snap's camera interface is disconnected. Connect it with: sudo snap connect cheese:camera :camera"
    else
        ok "The Cheese Snap camera interface is connected to '$camera_slot'."
    fi
elif package_installed cheese; then
    ok "Cheese is installed as a Debian/Ubuntu package."
elif command -v cheese >/dev/null 2>&1; then
    ok "Cheese command found at $(command -v cheese); package type could not be identified."
else
    fail "Cheese is not installed as a Snap or Debian/Ubuntu package."
fi

section "Kernel modules"
for module in intel_ipu6 v4l2loopback; do
    if command -v modinfo >/dev/null 2>&1 && modinfo "$module" >/dev/null 2>&1; then
        ok "Module $module is available for this kernel."
    else
        fail "Module $module is not available for kernel $(uname -r). Check its package/DKMS build."
    fi

    if grep -qE "^${module}[[:space:]]" /proc/modules 2>/dev/null; then
        ok "Module $module is loaded."
    else
        warn "Module $module is not currently loaded."
        if [[ "$module" == "v4l2loopback" ]]; then
            info "If its module is available, try: sudo modprobe v4l2loopback"
        fi
    fi
done

section "GStreamer camera elements"
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    for element in icamerasrc v4l2src videoconvert; do
        if gst-inspect-1.0 "$element" >/dev/null 2>&1; then
            ok "GStreamer element '$element' is available."
        else
            fail "GStreamer element '$element' is missing. Check the GStreamer/Intel camera packages."
        fi
    done
else
    fail "gst-inspect-1.0 is missing; install GStreamer tools to inspect camera support."
fi

section "V4L2 camera devices"
loopback_device=""
device_listing=""
virtual_video_sysfs=""
virtual_video_name=""
for name_file in /sys/devices/virtual/video4linux/video*/name; do
    [[ -r "$name_file" ]] || continue
    virtual_video_sysfs="/dev/$(basename "$(dirname "$name_file")")"
    virtual_video_name="$(cat "$name_file" 2>/dev/null || true)"
    break
done

if command -v v4l2-ctl >/dev/null 2>&1; then
    device_listing="$(v4l2-ctl --list-devices 2>&1 || true)"
    if [[ -n "$device_listing" ]]; then
        printf '%s\n' "$device_listing"
    else
        info "v4l2-ctl returned no device list in this execution environment."
    fi
    loopback_device="$(printf '%s\n' "$device_listing" | awk '
        /platform:v4l2loopback-/ { in_loopback = 1; next }
        /^[^[:space:]]/ { in_loopback = 0 }
        in_loopback && /\/dev\/video[0-9]+/ { print $1; exit }
    ')"
    if [[ -z "$loopback_device" && -n "$virtual_video_sysfs" ]]; then
        loopback_device="$virtual_video_sysfs"
        info "Sysfs reports a virtual video device named '$virtual_video_name' at $loopback_device."
    fi
    if [[ -n "$loopback_device" ]]; then
        if [[ -e "$loopback_device" ]]; then
            ok "Intel MIPI virtual camera is present at $loopback_device."
        else
            warn "Sysfs registers $virtual_video_name, but $loopback_device is not visible here. A restricted device namespace can hide /dev nodes; rerun from the laptop's desktop terminal to check access."
        fi
        if [[ -e "$loopback_device" && -r "$loopback_device" ]]; then
            ok "Current user can read $loopback_device."
        elif [[ -e "$loopback_device" ]]; then
            warn "Current user cannot read $loopback_device; app access may be blocked by permissions."
        fi
    else
        fail "No v4l2loopback virtual camera was found. Cheese needs the relay's virtual camera device."
        info "Check that v4l2loopback is loaded and that the relay's CARD_LABEL matches its configured camera name."
    fi
    if ! grep -qiE 'ipu6|mipi|camera' <<<"$device_listing" && [[ -z "$virtual_video_name" ]]; then
        warn "The V4L2 device list contains no obvious IPU6/MIPI camera entry."
    fi
else
    fail "v4l2-ctl is missing; install v4l-utils to inspect V4L2 devices."
fi

section "Relay service"
if command -v systemctl >/dev/null 2>&1; then
    relay_state="$(systemctl is-active v4l2-relayd@default.service 2>/dev/null || true)"
    if [[ "$relay_state" == "active" ]]; then
        ok "v4l2-relayd@default.service is active."
        relay_exec="$(systemctl status v4l2-relayd@default.service --no-pager -l 2>/dev/null | sed -n 's/.*\(\/usr\/bin\/v4l2-relayd .*$\)/\1/p' | tail -n 1)"
        if [[ -n "$relay_exec" ]]; then
            info "Relay command: $relay_exec"
            if [[ "$relay_exec" == *icamerasrc* ]]; then
                ok "Relay uses Intel's icamerasrc source."
            else
                warn "Relay command does not show icamerasrc; confirm VIDEOSRC uses the Intel HAL source."
            fi
            if [[ "$relay_exec" == *"sync=false"* ]]; then
                ok "Relay sink has sync=false."
            elif [[ "${VERSION_ID:-}" == "26.04" ]]; then
                warn "Relay command lacks sync=false. Ubuntu 26.04 has reports of black/slow relayed video with the default sink clock sync."
            fi
        else
            info "Could not read the running relay process command. systemd's ExecStart is a template and may not show the effective source settings."
        fi
    else
        fail "v4l2-relayd@default.service is '$relay_state', not active."
        info "Inspect with: systemctl status v4l2-relayd@default --no-pager -l"
    fi

    if command -v journalctl >/dev/null 2>&1; then
        relay_errors="$(journalctl -b -u v4l2-relayd@default.service --no-pager -n 30 2>/dev/null | grep -iE 'error|failed|no such file|not-negotiated|assertion' || true)"
        if [[ -n "$relay_errors" ]]; then
            warn "Recent relay journal contains error-like messages:"
            printf '%s\n' "$relay_errors"
        else
            ok "No matching relay errors found in the last 30 journal lines."
        fi
    fi
else
    warn "systemctl is unavailable; cannot inspect the relay service."
fi

section "Desktop camera services"
if command -v systemctl >/dev/null 2>&1 && [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    user_manager="$(systemctl --user is-system-running 2>/dev/null || true)"
    if [[ -n "$user_manager" ]]; then
        for service in pipewire.service wireplumber.service; do
            service_state="$(systemctl --user is-active "$service" 2>/dev/null || true)"
            if [[ "$service_state" == "active" ]]; then
                ok "User service $service is active."
            else
                warn "User service $service is '$service_state'. Cheese may not discover cameras through the desktop media session."
            fi
        done
    else
        info "No accessible systemd user manager; skipping PipeWire service checks."
    fi
else
    info "No graphical-session runtime directory is visible here; skipping PipeWire checks. Run the script from the desktop session for those checks."
fi

if (( LIVE_TEST )); then
    section "Optional live relay test"
    if [[ -z "$loopback_device" ]]; then
        fail "Cannot run the live test because no relay camera device was found."
    elif [[ ! -e "$loopback_device" ]]; then
        warn "Cannot access $loopback_device in this execution environment; skipping the live frame test."
    elif ! command -v gst-launch-1.0 >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        fail "The live test needs gst-launch-1.0 and timeout."
    else
        info "Opening $loopback_device briefly. Close Cheese and other camera apps first."
        if timeout 15s gst-launch-1.0 -q v4l2src "device=$loopback_device" num-buffers=30 '!' fakesink 2>&1; then
            ok "The relay delivered 30 frames from $loopback_device."
        else
            fail "The relay did not deliver 30 frames. Check the relay journal and camera source."
        fi
    fi
else
    info "For a brief frame-flow check, close Cheese and run: bash $0 --live-test"
fi

section "Summary"
printf 'Passed: %d  Warnings: %d  Missing/failed: %d\n' "$OK" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
    info "Resolve the [FAIL] items first. Then select 'Intel MIPI Camera' in Cheese and relaunch Cheese."
elif (( WARN > 0 )); then
    info "Required components appear present, but review the [WARN] items. If only Cheese is black, close and relaunch it; Cheese may need a fresh PipeWire/V4L2 negotiation."
else
    info "Static checks passed. Use --live-test to confirm frames flow; static checks cannot verify Cheese's preview negotiation."
fi

if (( FAIL > 0 )); then
    exit 1
fi
