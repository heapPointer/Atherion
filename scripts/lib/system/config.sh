#!/bin/bash

configure_firmware_password() {
    local answer

    if [[ "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)" != *"Intel"* ]]; then
        print_warn "Firmware password tool is not supported on this Mac type. Skipping."
        return 0
    fi

    if [[ ! -x /usr/sbin/firmwarepasswd ]]; then
        print_warn "firmwarepasswd tool not found. Skipping firmware password step."
        return 0
    fi

    read -r -p "Change firmware password now? (y/N): " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        print_info "Firmware password change skipped by user."
        return 0
    fi

    print_info "Current firmware password status:"
    sudo /usr/sbin/firmwarepasswd -check || print_warn "Could not read current firmware password status."

    print_info "You will now be prompted for password input by firmwarepasswd."
    print_info "If a firmware password already exists, provide current password first."

    if ! sudo /usr/sbin/firmwarepasswd -setpasswd; then
        print_warn "Firmware password change did not complete."
        return 1
    fi

    FIRMWARE_PASSWORD_CHANGED=1
    print_ok "Firmware password change completed."
    return 0
}

configure_power_management() {
    local had_error=0

    print_info "Applying power management settings..."

    if ! sudo pmset repeat cancel; then
        print_warn "Failed to clear existing pmset repeat schedule."
        had_error=1
    fi

    # Clear any one-time scheduled events (pmset schedule) left by previous tools.
    sudo pmset schedule cancelall 2>/dev/null || true

    if ! sudo pmset repeat wakeorpoweron MTWRFS 07:00:00 shutdown MTWRFS 21:30:00; then
        print_warn "Failed to set wake/shutdown schedule."
        had_error=1
    fi

    if ! sudo pmset -a acwake 1; then
        print_warn "Failed to enable AC wake."
        had_error=1
    fi

    if ! sudo pmset -a powernap 0; then
        print_warn "Failed to disable Power Nap."
        had_error=1
    fi

    # Disable inactivity sleep so the lab machine stays on between scheduled
    # power-down windows. 0 = never. -a applies to all power sources (battery,
    # AC, UPS) — the iMacs only have AC anyway, but -a is the right verb.
    if ! sudo pmset -a displaysleep 0; then
        print_warn "Failed to disable display sleep."
        had_error=1
    fi
    if ! sudo pmset -a sleep 0; then
        print_warn "Failed to disable system sleep."
        had_error=1
    fi
    if ! sudo pmset -a disksleep 0; then
        print_warn "Failed to disable disk sleep."
        had_error=1
    fi

    # Restart automatically after a power failure.
    if ! sudo pmset -a autorestart 1; then
        print_warn "Failed to enable autorestart after power failure."
        had_error=1
    fi

    # Disable wake for network access (WoL / WoMP).
    if ! sudo pmset -a womp 0; then
        print_warn "Failed to disable wake for network access."
        had_error=1
    fi

    # Prevent automatic sleep / hibernation when display is off.
    if ! sudo pmset -a autopoweroff 0; then
        print_warn "Failed to disable autopoweroff."
        had_error=1
    fi

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    print_ok "Power schedule set for Mon-Sat: on at 07:00, off at 21:30."
    print_ok "AC wake enabled; Power Nap, hard disk sleep, WoL, autopoweroff disabled."
    print_ok "Autorestart after power failure enabled."
    return 0
}

optimize_login_and_background_items() {
    local current_user
    local current_uid
    local removed_login_items=0
    local disabled_agents=0

    current_user="${SUDO_USER:-$(stat -f%Su /dev/console 2>/dev/null || whoami)}"
    if [[ -z "$current_user" || "$current_user" == "root" ]]; then
        print_info "No non-root console user detected; skipping login item optimization."
        return 0
    fi

    current_uid="$(id -u "$current_user" 2>/dev/null || true)"
    if [[ -z "$current_uid" ]]; then
        print_warn "Could not determine UID for $current_user; skipping login item optimization."
        return 0
    fi

    print_info "Optimizing login/background items for $current_user..."

    # Remove user login items from the GUI session.
    if launchctl asuser "$current_uid" sudo -u "$current_user" osascript \
        -e 'tell application "System Events" to delete every login item' >/dev/null 2>&1; then
        removed_login_items=1
    fi

    # Disable known heavy user updaters/helpers if present.
    local user_agent_dir="/Users/$current_user/Library/LaunchAgents"
    local patterns=(
        "com.google.keystone*.plist"
        "com.adobe*.plist"
        "com.microsoft.update*.plist"
        "com.microsoft.OneDrive*.plist"
        "com.dropbox*.plist"
        "com.spotify*.plist"
    )

    local pattern
    for pattern in "${patterns[@]}"; do
        local plist
        for plist in "$user_agent_dir"/$pattern; do
            [[ -e "$plist" ]] || continue
            local label
            label="$(basename "$plist" .plist)"
            launchctl bootout "gui/$current_uid" "$plist" >/dev/null 2>&1 || true
            launchctl disable "gui/$current_uid/$label" >/dev/null 2>&1 || true
            disabled_agents=$((disabled_agents + 1))
        done
    done

    if [[ "$removed_login_items" -eq 1 ]]; then
        print_ok "Cleared login items for user: $current_user"
    else
        print_info "Login items were not modified (likely no permission or no items)."
    fi

    if [[ "$disabled_agents" -gt 0 ]]; then
        print_ok "Disabled $disabled_agents known background updater/helper agents"
    else
        print_info "No known heavy background updater/helper agents found"
    fi

    return 0
}

check_disk_headroom() {
    local used_pct
    local free_pct

    used_pct="$(df -Pk / | tail -n 1 | awk '{gsub(/%/,"",$5); print $5}')"
    if [[ -z "$used_pct" || ! "$used_pct" =~ ^[0-9]+$ ]]; then
        print_warn "Could not read disk usage for root volume."
        return 0
    fi

    free_pct=$((100 - used_pct))
    print_info "Disk free space on /: ${free_pct}%"

    if [[ "$free_pct" -lt 20 ]]; then
        print_warn "Disk free space is below 20%. Performance will degrade on older iMacs."
        print_warn "Target is 20-25% free space."
    elif [[ "$free_pct" -lt 25 ]]; then
        print_warn "Disk free space is below preferred 25% headroom."
    else
        print_ok "Disk headroom is healthy (${free_pct}% free)."
    fi

    return 0
}

disable_known_updater_services() {
    local disabled=0
    local system_patterns=(
        "com.google.keystone*.plist"
        "com.adobe*.plist"
        "com.microsoft.update*.plist"
    )

    print_info "Disabling known non-critical updater services when found..."

    local base_dir
    for base_dir in "/Library/LaunchAgents" "/Library/LaunchDaemons"; do
        local pattern
        for pattern in "${system_patterns[@]}"; do
            local plist
            for plist in "$base_dir"/$pattern; do
                [[ -e "$plist" ]] || continue
                local label
                label="$(basename "$plist" .plist)"
                sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
                sudo launchctl disable "system/$label" >/dev/null 2>&1 || true
                disabled=$((disabled + 1))
            done
        done
    done

    if [[ "$disabled" -gt 0 ]]; then
        print_ok "Disabled $disabled system updater service entries"
    else
        print_info "No known system updater service entries found"
    fi

    return 0
}

check_oclp_patch_status() {
    local oclp_app=""

    # SIP status — always report, regardless of OCLP presence.
    local sip_status
    sip_status="$(csrutil status 2>/dev/null || true)"
    if [[ -n "$sip_status" ]]; then
        print_info "SIP: $sip_status"
    else
        print_info "SIP: (csrutil unavailable)"
    fi

    # NVRAM variables written by OCLP at boot — present only on OCLP-patched machines.
    local oclp_ver oc_ver
    oclp_ver="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:OCLP-Version 2>/dev/null || true)"
    oc_ver="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version 2>/dev/null || true)"
    if [[ -n "$oclp_ver" ]]; then
        print_info "OCLP nvram: $oclp_ver"
    else
        print_info "OCLP nvram: not set (non-OCLP machine or nvram cleared)"
    fi
    [[ -n "$oc_ver" ]] && print_info "OpenCore nvram: $oc_ver"

    if [[ -d "/Applications/OpenCore-Patcher.app" ]]; then
        oclp_app="/Applications/OpenCore-Patcher.app"
    elif [[ -d "/Library/Application Support/Dortania/OpenCore-Patcher/OpenCore-Patcher.app" ]]; then
        oclp_app="/Library/Application Support/Dortania/OpenCore-Patcher/OpenCore-Patcher.app"
    fi

    if [[ -z "$oclp_app" ]]; then
        print_info "OpenCore Legacy Patcher not detected; skipping OCLP status check."
        return 0
    fi

    print_info "OCLP detected: $oclp_app"
    print_warn "After macOS updates, re-run OCLP post-install root patching to keep graphics/Wi-Fi acceleration stable."
    print_info "Model: $(sysctl -n hw.model 2>/dev/null || echo unknown), macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
    return 0
}
