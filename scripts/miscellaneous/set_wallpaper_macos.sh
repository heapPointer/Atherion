#!/bin/bash

set -euo pipefail

WALLPAPER_URL="https://wall-r2.tasw.qzz.io/mac.png"
WALLPAPER_URL_FALLBACK="https://wall-r2.tasw.qzz.io/mac.png"

# Persistent on-disk location — desktoppr records this path, so it must not be deleted.
WALLPAPER_DEST="/Library/Desktop Pictures/atherion-wallpaper.png"

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)" || SCRIPT_DIR=""
if [[ -n "$SCRIPT_DIR" && -r "$SCRIPT_DIR/scripts/lib/core/ui.sh" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/scripts/lib/core/ui.sh"
else
    print_info() { printf '[INFO] %s\n' "$*"; }
    print_warn() { printf '[WARN] %s\n' "$*" >&2; }
    print_err()  { printf '[ERROR] %s\n' "$*" >&2; }
    print_ok()   { printf '[ OK ] %s\n' "$*"; }
fi

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        print_err "This script must be run as root. Use: sudo bash $0"
        exit 1
    fi
}

list_local_users() {
    local home name
    for home in /Users/*; do
        [[ -d "$home" ]] || continue
        name="$(basename "$home")"
        case "$name" in
            Shared|Guest|"Deleted Users") continue ;;
        esac
        /usr/bin/id "$name" >/dev/null 2>&1 && printf '%s\n' "$name" || true
    done
}

# Prints selected usernames to stdout one per line. All UI output goes to
# stderr so that stdout stays clean for the caller's capture.
prompt_target_users() {
    local all_count="$1"
    shift
    local all_users_str="$1"  # newline-separated list

    local -a all_users=()
    while IFS= read -r u; do
        all_users+=("$u")
    done <<< "$all_users_str"

    printf '\n' >&2
    printf '[INFO] Local user accounts found:\n' >&2
    local i
    for ((i = 0; i < all_count; i++)); do
        printf '  %d) %s\n' "$((i + 1))" "${all_users[$i]}" >&2
    done
    printf '\n' >&2

    local input idx valid
    local -a selected_users
    while true; do
        printf "Apply wallpaper to which users? (space-separated numbers, or 'all'): " >&2
        if ! IFS= read -r input </dev/tty; then
            printf '\n' >&2
            print_err "No input received." >&2
            exit 1
        fi

        input="$(printf '%s' "$input" | tr -s ' ' | sed 's/^ //;s/ $//')"
        [[ -z "$input" ]] && continue

        if [[ "$input" == "all" ]]; then
            printf '%s\n' "${all_users[@]}"
            return 0
        fi

        valid=1
        selected_users=()
        for idx in $input; do
            if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -lt 1 ]] || [[ "$idx" -gt "$all_count" ]]; then
                printf "[WARN] Invalid: '%s'. Enter numbers 1–%d, or 'all'.\n" "$idx" "$all_count" >&2
                valid=0
                break
            fi
            selected_users+=("${all_users[$((idx - 1))]}")
        done

        if [[ "$valid" -eq 1 ]] && [[ "${#selected_users[@]}" -gt 0 ]]; then
            printf '%s\n' "${selected_users[@]}"
            return 0
        fi
    done
}

apply_wallpaper_for_user() {
    local target_user="$1"
    local image_path="$2"
    local target_uid

    target_uid="$(id -u "$target_user" 2>/dev/null || true)"
    if [[ -z "$target_uid" ]]; then
        print_warn "Could not get UID for '$target_user'. Skipping."
        return 1
    fi

    local user_logged_in=0
    launchctl print "gui/$target_uid" >/dev/null 2>&1 && user_logged_in=1 || true

    if command -v desktoppr >/dev/null 2>&1; then
        if [[ "$user_logged_in" -eq 1 ]]; then
            launchctl asuser "$target_uid" desktoppr "$image_path" >/dev/null 2>&1 || {
                print_warn "desktoppr failed for logged-in user '$target_user'."
                return 1
            }
        else
            # Run desktoppr as the target user — writes their preferences without needing an active GUI
            # session on Ventura. May fail on Sonoma+ where WallpaperKit requires a running WindowManager.
            if sudo -u "$target_user" desktoppr "$image_path" >/dev/null 2>&1; then
                print_info "'$target_user' is not logged in — wallpaper preference written; applies at next login."
            else
                print_warn "'$target_user' is not logged in. Could not set wallpaper (Sonoma+ requires an active session). Log them in and re-run."
                return 1
            fi
        fi
        return 0
    fi

    # Fallback when desktoppr is not installed.
    print_warn "desktoppr not found — using legacy fallback (may fail on Sonoma+). Install: brew install desktoppr"

    if [[ "$user_logged_in" -eq 1 ]]; then
        # osascript works for logged-in users on pre-Mojave and sometimes later with TCC approval.
        launchctl asuser "$target_uid" sudo -u "$target_user" osascript \
            -e 'tell application "System Events"' \
            -e "tell every desktop to set picture to POSIX file \"$image_path\"" \
            -e 'end tell' >/dev/null 2>&1 || {
            print_warn "osascript failed for '$target_user'. TCC may be blocking root AppleEvents (Mojave+)."
            return 1
        }
    else
        # defaults write works only on Ventura and earlier (desktoppicture.db path deprecated in Sonoma+).
        sudo -u "$target_user" \
            defaults write com.apple.desktop Background \
            -dict default -dict ImageFilePath "$image_path" >/dev/null 2>&1 || {
            print_warn "defaults write failed for '$target_user'. Sonoma+ does not support this fallback for logged-out users."
            return 1
        }
        print_info "'$target_user' is not logged in — defaults written (effective on Ventura and earlier only)."
    fi
}

download_wallpaper() {
    local dest="$1"
    if curl -fsSL --max-time 30 "$WALLPAPER_URL" -o "$dest" 2>/dev/null; then
        return 0
    fi
    print_warn "Primary URL failed, trying fallback..."
    curl -fsSL --max-time 30 "$WALLPAPER_URL_FALLBACK" -o "$dest" 2>/dev/null
}

main() {
    require_root

    local tmp_image
    tmp_image="$(mktemp /tmp/atherion-wallpaper.XXXXXX.png)"
    trap 'rm -f "$tmp_image"' EXIT

    print_info "Downloading wallpaper..."
    if ! download_wallpaper "$tmp_image"; then
        print_err "Failed to download wallpaper from both URLs."
        exit 1
    fi

    cp "$tmp_image" "$WALLPAPER_DEST"
    chmod 644 "$WALLPAPER_DEST"
    print_ok "Wallpaper saved to $WALLPAPER_DEST."

    local users_list
    users_list="$(list_local_users)"
    if [[ -z "$users_list" ]]; then
        print_warn "No local user accounts found. Nothing to do."
        exit 0
    fi

    local user_count=0
    while IFS= read -r _; do user_count=$((user_count + 1)); done <<< "$users_list"

    local selected_list
    selected_list="$(prompt_target_users "$user_count" "$users_list")"

    if [[ -z "$selected_list" ]]; then
        print_warn "No users selected. Nothing to do."
        exit 0
    fi

    local failed=0
    while IFS= read -r target_user; do
        [[ -n "$target_user" ]] || continue
        if apply_wallpaper_for_user "$target_user" "$WALLPAPER_DEST"; then
            print_ok "Wallpaper set for: $target_user"
        else
            failed=1
        fi
    done <<< "$selected_list"

    if [[ "$failed" -eq 0 ]]; then
        print_ok "Wallpaper applied to all selected users."
    else
        print_warn "Wallpaper could not be applied to one or more users. See warnings above."
        exit 1
    fi
}

main "$@"
