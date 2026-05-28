#!/bin/bash

PY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/py"

# Check if installation should be skipped based on version matching
should_skip_direct_install() {
    local app_path="$1"
    local display_name="$2"
    local supported_ver="$3"
    local installed_ver=""

    if [[ ! -d "$app_path" ]]; then
        return 1
    fi

    installed_ver="$(get_app_version "$app_path")"

    if [[ "$installed_ver" == "unknown" ]]; then
        print_warn "$display_name installed but version unreadable. Skipping reinstall."
        return 0
    fi

    if [[ -z "$supported_ver" || "$supported_ver" == "unknown" ]]; then
        print_info "$display_name installed. Version: $installed_ver"
        print_ok "$display_name already installed. Skipping reinstall."
        return 0
    fi

    print_info "$display_name supported version for this macOS: $supported_ver"

    if versions_match_compatible "$installed_ver" "$supported_ver"; then
        print_ok "$display_name already at latest supported version ($installed_ver). Skipping reinstall."
        return 0
    fi

    print_info "$display_name installed version ($installed_ver) differs from supported ($supported_ver). Reinstalling."
    return 1
}

# Check if versions match exactly
versions_match_latest() {
    local installed_ver="$1"
    local supported_ver="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" match-exact "$installed_ver" "$supported_ver" >/dev/null 2>&1
        return $?
    fi

    return 1
}

# Check if versions are compatible (allows prefix matching)
versions_match_compatible() {
    local installed_ver="$1"
    local supported_ver="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" match-compatible "$installed_ver" "$supported_ver" >/dev/null 2>&1
        return $?
    fi

    return 1
}

# Extract version from URL
extract_version_from_url() {
    local url="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" extract-version "$url"
        return 0
    fi

    echo "unknown"
    return 0
}

# Normalize Packet Tracer version from build numbers
normalize_packet_tracer_version() {
    local raw="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" normalize-pt "$raw"
        return 0
    fi

    echo "$raw"
    return 0
}

# Check cache and validate existing file
validate_cached_download() {
    local url="$1"
    local out_file="$2"
    
    if [[ ! -f "$out_file" ]]; then
        return 1
    fi
    
    local file_size_bytes=$(stat -f%z "$out_file" 2>/dev/null || echo 0)
    if [[ $file_size_bytes -lt 1024 ]]; then
        return 1
    fi
    
    return 0
}

# Download file with resilience (retries with exponential backoff) and caching
download_file_resilient() {
    local url="$1"
    local out_file="$2"
    local attempt=1
    local max_attempts=6
    
    if validate_cached_download "$url" "$out_file"; then
        print_info "Using cached $(basename "$out_file")"
        return 0
    fi

    while [[ "$attempt" -le "$max_attempts" ]]; do
        print_info "Downloading $(basename "$out_file") (attempt $attempt/$max_attempts)"
        if download_file_optimized "$url" "$out_file"; then
            return 0
        fi

        if [[ "$attempt" -lt "$max_attempts" ]]; then
            print_warn "Download attempt failed for $(basename "$out_file"). Retrying..."
            sleep $((attempt * 2))
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

# Normalize download URL — appends download=1 for SharePoint sharing links.
normalize_download_url() {
    local url="$1"
    if [[ "$url" == *"sharepoint.com"* ]] && [[ "$url" != *"download=1"* ]]; then
        if [[ "$url" == *"?"* ]]; then
            echo "${url}&download=1"
        else
            echo "${url}?download=1"
        fi
        return
    fi
    echo "$url"
}

# Optimized download using aria2c (parallel) if available, otherwise curl with connection pooling
download_file_optimized() {
    local url="$1"
    local out_file="$2"

    if command -v aria2c >/dev/null 2>&1; then
        aria2c \
            --quiet=true \
            --console-log-level=error \
            --file-allocation=none \
            --max-connection-per-server=16 \
            --split=16 \
            --continue=true \
            --retry-wait=3 \
            --max-tries=8 \
            --summary-interval=0 \
            --download-result=hide \
            --enable-mmap=true \
            --disk-cache=16M \
            -o "$(basename "$out_file")" \
            -d "$(dirname "$out_file")" \
            "$url"
        return $?
    fi

    # Enhanced curl with connection keep-alive and pooling
    curl \
        --fail \
        --location \
        --retry 8 \
        --retry-all-errors \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 3600 \
        --continue-at - \
        --compressed \
        --keepalive-time 60 \
        --silent \
        --show-error \
        "$url" \
        --output "$out_file"
}

# Get file size from URL via HEAD request
get_remote_file_size() {
    local url="$1"
    local content_length=""
    
    content_length="$(curl -fsI -L "$url" 2>/dev/null | grep -i "content-length:" | tail -1 | awk '{print $2}' | tr -d '\r')"
    if [[ -n "$content_length" && "$content_length" =~ ^[0-9]+$ ]]; then
        echo "$content_length"
        return 0
    fi
    
    echo "0"
    return 1
}

# Monitor download progress in background with ETA
monitor_download_progress() {
    local file_path="$1"
    local stage_file="$2"
    local app_name="$3"
    local total_size="$4"
    local start_time
    local last_size=0
    local current_size=0
    local last_time=0
    local current_time=0
    local elapsed=0
    local speed_bps=0
    local speed_display=""
    local size_mb=0
    local percent=0
    local percent_display="--"
    local remaining_bytes=0
    local eta_seconds=0
    local eta_display=""
    local no_growth_count=0

    start_time=$(date +%s)
    last_time=$start_time

    while true; do
        if [[ ! -f "$file_path" ]]; then
            sleep 0.5
            continue
        fi

        current_size=$(stat -f%z "$file_path" 2>/dev/null || echo 0)
        current_time=$(date +%s)
        elapsed=$((current_time - last_time))

        if [[ $elapsed -ge 2 ]]; then
            if [[ $current_size -eq $last_size ]]; then
                no_growth_count=$((no_growth_count + 1))
                if [[ $no_growth_count -ge 3 ]]; then
                    break
                fi
            else
                no_growth_count=0
                speed_bps=$(( (current_size - last_size) / elapsed ))
                size_mb=$(( current_size / 1048576 ))

                # Calculate speed display
                if [[ $speed_bps -ge 1048576 ]]; then
                    speed_display="$((speed_bps / 1048576))MB/s"
                else
                    speed_display="$((speed_bps / 1024))KB/s"
                fi

                # Calculate ETA if total size is known
                eta_display="--"
                percent_display="--"
                if [[ -n "$total_size" && "$total_size" != "0" && $total_size -gt 0 && $speed_bps -gt 0 ]]; then
                    percent=$(( (current_size * 100) / total_size ))
                    percent_display="${percent}%"
                    remaining_bytes=$(( total_size - current_size ))
                    if [[ $remaining_bytes -gt 0 ]]; then
                        eta_seconds=$(( remaining_bytes / speed_bps ))
                        
                        if [[ $eta_seconds -gt 3600 ]]; then
                            local eta_h=$(( eta_seconds / 3600 ))
                            local eta_m=$(( (eta_seconds % 3600) / 60 ))
                            eta_display="${eta_h}h ${eta_m}m"
                        elif [[ $eta_seconds -gt 60 ]]; then
                            local eta_m=$(( eta_seconds / 60 ))
                            local eta_s=$(( eta_seconds % 60 ))
                            eta_display="${eta_m}m ${eta_s}s"
                        else
                            eta_display="${eta_seconds}s"
                        fi
                    else
                        percent=100
                        percent_display="100%"
                        eta_display="0s"
                    fi
                fi

                echo "NET | ${app_name} | speed=${speed_display} | eta=${eta_display} | progress=${percent_display} | downloaded=${size_mb}MB" > "$stage_file" 2>/dev/null || true
            fi

            last_size=$current_size
            last_time=$current_time
        fi

        sleep 1
    done
}

# Check if an app bundle is an installer bundle
is_packet_tracer_installer_bundle() {
    local app_path="$1"
    local name_lc=""
    local plist="$app_path/Contents/Info.plist"
    local bundle_id=""

    [[ -d "$app_path" ]] || return 1

    name_lc="$(basename "$app_path" | tr '[:upper:]' '[:lower:]')"
    if [[ "$name_lc" == *installer* || "$name_lc" == *setup* ]]; then
        return 0
    fi

    if [[ -x "$app_path/Contents/MacOS/installbuilder.sh" || -f "$app_path/Contents/Resources/installbuilder.sh" ]]; then
        return 0
    fi

    if [[ -f "$plist" ]]; then
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
        bundle_id="$(printf '%s' "$bundle_id" | tr '[:upper:]' '[:lower:]')"
        if [[ "$bundle_id" == *installbuilder* || "$bundle_id" == *installer* ]]; then
            return 0
        fi
    fi

    return 1
}

# Find installed Packet Tracer app (excluding installer bundles)
find_installed_packet_tracer_app() {
    local candidate=""

    # Common direct app names in /Applications
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if is_packet_tracer_installer_bundle "$candidate"; then
            continue
        fi
        echo "$candidate"
        return 0
    done < <(find /Applications -maxdepth 2 -type d \( -name 'Packet Tracer.app' -o -name 'PacketTracer.app' -o -name 'Cisco Packet Tracer.app' -o -name 'Cisco Packet Tracer*.app' \) 2>/dev/null)

    # Some releases install into a versioned wrapper directory (e.g. /Applications/Cisco Packet Tracer 9.0.0/).
    # Prefer returning the nested .app bundle so get_app_version can read Info.plist.
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        local nested_app
        nested_app="$(find "$candidate" -maxdepth 2 -type d -name '*.app' 2>/dev/null | grep -v '/Contents/' | head -n 1)"
        if [[ -n "$nested_app" ]] && ! is_packet_tracer_installer_bundle "$nested_app"; then
            echo "$nested_app"
            return 0
        fi
        if [[ -x "$candidate/bin/PacketTracer" || -x "$candidate/PacketTracer" ]]; then
            echo "$candidate"
            return 0
        fi
    done < <(find /Applications -maxdepth 3 -type d -name 'Cisco Packet Tracer*' 2>/dev/null)

    # First try direct match in /Applications
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if is_packet_tracer_installer_bundle "$candidate"; then
            continue
        fi
        echo "$candidate"
        return 0
    done < <(find /Applications -maxdepth 1 -type d -name '*Packet*Tracer*.app' 2>/dev/null)

    # If not found, search recursively for nested app bundles
    # (e.g., /Applications/Cisco Packet Tracer 9.0.0/PacketTracer.app)
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if is_packet_tracer_installer_bundle "$candidate"; then
            continue
        fi
        echo "$candidate"
        return 0
    done < <(find /Applications -maxdepth 3 -type d -name '*Packet*Tracer*.app' 2>/dev/null | grep -v '/Contents/' | head -5)

    echo ""
    return 1
}

# Run Packet Tracer installer unattended
run_packet_tracer_installer_unattended() {
    local app_path="$1"
    local install_log="$2"
    local mount_point="$3"
    local app_name=""
    local installer_exec=""
    local version=""
    local install_dir=""

    app_name="$(basename "$app_path" .app)"
    version="$(printf '%s' "$app_name" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    if [[ -z "$version" ]]; then
        version="9.0.0"
    fi

    install_dir="/Applications/Cisco Packet Tracer $version"
    mkdir -p "$install_dir" || true

    if [[ -x "$app_path/Contents/MacOS/$app_name" ]]; then
        installer_exec="$app_path/Contents/MacOS/$app_name"
    else
        installer_exec="$(find "$app_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 2>/dev/null | head -n 1)"
    fi

    if [[ -z "$installer_exec" ]]; then
        echo "No executable installer binary found in $app_path/Contents/MacOS" >"$install_log"
        return 1
    fi

    if sudo -n "$installer_exec" install \
        --root "$install_dir" \
        --accept-licenses \
        --accept-messages \
        --confirm-command >"$install_log" 2>&1; then
        return 0
    fi

    if sudo "$installer_exec" install \
        --root "$install_dir" \
        --accept-licenses \
        --accept-messages \
        --confirm-command >>"$install_log" 2>&1; then
        return 0
    fi

    if sudo -n "$installer_exec" install --root "$install_dir" >>"$install_log" 2>&1; then
        return 0
    fi

    if sudo "$installer_exec" install --root "$install_dir" >>"$install_log" 2>&1; then
        return 0
    fi

    return 1
}

# Resolve Homebrew cask download locks
resolve_brew_download_locks_for_token() {
    local token="$1"
    local brew_home="${HOME}"
    if [[ -n "${SUDO_USER:-}" ]]; then
        brew_home="$(eval echo "~${SUDO_USER}" 2>/dev/null || echo "/Users/${SUDO_USER}")"
    fi
    local lock_dir="${brew_home}/Library/Caches/Homebrew/downloads"
    local lockfile
    local holders
    local elapsed
    local wait_limit=45

    if [[ ! -d "$lock_dir" ]]; then
        return 0
    fi

    while IFS= read -r lockfile; do
        [[ -z "$lockfile" ]] && continue
        print_warn "Detected cask lock for $token: $(basename "$lockfile")"

        holders="$(lsof -t "$lockfile" 2>/dev/null | tr '\n' ' ')"
        if [[ -z "$holders" ]]; then
            rm -f "$lockfile" >/dev/null 2>&1 || true
            continue
        fi

        print_info "Lock held by process(es): $holders"
        elapsed=0
        while [[ "$elapsed" -lt "$wait_limit" ]]; do
            sleep 3
            elapsed=$((elapsed + 3))
            holders="$(lsof -t "$lockfile" 2>/dev/null | tr '\n' ' ')"
            [[ -z "$holders" ]] && break
        done

        holders="$(lsof -t "$lockfile" 2>/dev/null | tr '\n' ' ')"
        if [[ -n "$holders" ]]; then
            print_warn "Lock still active after wait. Terminating holder process(es): $holders"
            kill $holders >/dev/null 2>&1 || true
            sleep 2
            holders="$(lsof -t "$lockfile" 2>/dev/null | tr '\n' ' ')"
            if [[ -n "$holders" ]]; then
                kill -9 $holders >/dev/null 2>&1 || true
            fi
        fi

        rm -f "$lockfile" >/dev/null 2>&1 || true
    done < <(find "$lock_dir" -maxdepth 1 -type f -name "*${token}*.incomplete" 2>/dev/null)

    return 0
}

# Record cask lock metadata
record_cask_lock() {
    local token="$1"
    local app_path="$2"
    local state_home="${HOME}"
    if [[ -n "${SUDO_USER:-}" ]]; then
        state_home="$(eval echo "~${SUDO_USER}" 2>/dev/null || echo "/Users/${SUDO_USER}")"
    fi
    local lock_dir="${state_home}/.labstate/cask-locks"
    local lock_file="$lock_dir/$token.lock"
    local macos_ver
    local installed_ver
    local brew_ver

    macos_ver="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    installed_ver="$(get_app_version "$app_path")"
    brew_ver="$(get_brew_cask_version "$token")"

    mkdir -p "$lock_dir" || return 1
    cat > "$lock_file" <<EOF
token=$token
macos=$macos_ver
installed_app_version=$installed_ver
brew_cask_version=$brew_ver
locked_at=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    print_info "Locked $token to current supported release metadata: $lock_file"
    return 0
}

# Get the download URL for a Homebrew cask from its JSON metadata.
get_brew_cask_download_url() {
    local token="$1"
    local json

    json="$(brew_cmd info --cask --json=v2 "$token" 2>/dev/null || true)"
    if [[ -z "$json" ]]; then
        echo ""
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        echo "$json" | python3 "$PY_LIB_DIR/brew_utils.py" cask-url
    else
        echo ""
    fi
}

# Pre-fetch a Homebrew cask DMG into Homebrew's downloads cache using aria2c.
# Homebrew computes its cache filename as sha256(url)--basename(url).
# When brew finds the file there it skips the download and goes straight to install.
prefetch_brew_cask() {
    local token="$1"
    local stage_file="${2:-}"
    local url url_hash base cache_dir cache_file tmp_file brew_home

    url="$(get_brew_cask_download_url "$token" 2>/dev/null || true)"
    if [[ -z "$url" || "$url" == "null" ]]; then
        return 1
    fi

    brew_home="${HOME}"
    if [[ -n "${SUDO_USER:-}" ]]; then
        brew_home="$(eval echo "~${SUDO_USER}" 2>/dev/null || echo "/Users/${SUDO_USER}")"
    fi
    cache_dir="${brew_home}/Library/Caches/Homebrew/downloads"
    mkdir -p "$cache_dir" 2>/dev/null || return 1

    url_hash="$(printf '%s' "$url" | shasum -a 256 | awk '{print $1}')"
    base="$(basename "$url")"
    cache_file="${cache_dir}/${url_hash}--${base}"

    if [[ -f "$cache_file" ]]; then
        print_info "$token DMG already in Homebrew cache — skipping prefetch"
        return 0
    fi

    # Remove any stale .incomplete file so aria2c starts fresh
    rm -f "${cache_dir}"/*"${token}"*.incomplete 2>/dev/null || true

    tmp_file="${cache_file}.prefetch-tmp"
    rm -f "$tmp_file" 2>/dev/null || true

    [[ -n "$stage_file" ]] && echo "Prefetching $token DMG" > "$stage_file"
    print_info "Prefetching $token DMG with aria2c (16 connections)..."

    local ok=0
    if command -v aria2c >/dev/null 2>&1; then
        aria2c \
            --quiet=true \
            --file-allocation=none \
            --max-connection-per-server=16 \
            --split=16 \
            --continue=false \
            --retry-wait=3 \
            --max-tries=6 \
            --summary-interval=0 \
            --download-result=hide \
            --enable-mmap=true \
            --disk-cache=32M \
            -o "$(basename "$tmp_file")" \
            -d "$(dirname "$tmp_file")" \
            "$url" >/dev/null 2>&1 && ok=1
    fi

    if [[ "$ok" -eq 0 ]]; then
        curl --fail --location --retry 6 --retry-all-errors --retry-delay 2 \
             --connect-timeout 15 --max-time 3600 --keepalive-time 60 \
             --silent --show-error "$url" --output "$tmp_file" && ok=1
    fi

    if [[ "$ok" -eq 1 && -f "$tmp_file" ]]; then
        local owner="${SUDO_USER:-$(whoami)}"
        mv "$tmp_file" "$cache_file"
        chown "$owner" "$cache_file" 2>/dev/null || true
        chmod 644 "$cache_file" 2>/dev/null || true
        print_ok "$token DMG prefetched into Homebrew cache"
        return 0
    fi

    rm -f "$tmp_file" 2>/dev/null || true
    print_warn "$token prefetch failed — Homebrew will download normally"
    return 1
}

# Get Homebrew cask version
get_brew_cask_version() {
    local token="$1"
    local json

    json="$(brew_cmd info --cask --json=v2 "$token" 2>/dev/null || true)"
    if [[ -z "$json" ]]; then
        echo "unknown"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        echo "$json" | python3 "$PY_LIB_DIR/brew_utils.py" cask-version
    else
        echo "unknown"
    fi
}

# Resolve installed app bundle path across common install locations.
resolve_installed_app_path() {
    local expected_path="$1"
    local base_name=""
    local stem_name=""
    local candidate=""

    if [[ -z "$expected_path" ]]; then
        echo ""
        return 1
    fi

    if [[ -d "$expected_path" ]]; then
        echo "$expected_path"
        return 0
    fi

    base_name="$(basename "$expected_path")"
    stem_name="${base_name%.app}"

    candidate="$HOME/Applications/$base_name"
    if [[ -d "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi

    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done < <(find /Applications "$HOME/Applications" -maxdepth 3 -type d -iname "${stem_name}*.app" 2>/dev/null | head -n 10)

    echo ""
    return 1
}

# Install or update a Homebrew cask
reinstall_cask_app() {
    local token="$1"
    local app_path="$2"
    local display_name="$3"
    local stage_file="${4:-}"
    local supported_ver="unknown"
    local installed_ver=""
    local installed_path=""
    local attempt=1
    local max_attempts=3

    # Initialize stage file with default value
    if [[ -n "$stage_file" ]]; then
        echo "Checking app" > "$stage_file"
    fi

    if ! brew_is_healthy; then
        print_warn "Homebrew unavailable; cannot install $display_name."
        return 1
    fi

    # Fast path tier 1: brew is authoritative — if it lists the cask as installed, trust it
    if brew_cask_is_installed "$token"; then
        echo "Checking installed version" > "$stage_file" 2>/dev/null || true
        installed_path="$(resolve_installed_app_path "$app_path")"
        installed_ver="$(get_app_version "${installed_path:-$app_path}")"
        echo "Checking supported version" > "$stage_file" 2>/dev/null || true
        supported_ver="$(get_brew_cask_version "$token")"
        if [[ "$installed_ver" == "unknown" || "$supported_ver" == "unknown" ]] \
            || versions_match_latest "$installed_ver" "$supported_ver"; then
            print_ok "$display_name already installed via Homebrew ($installed_ver). Skipping reinstall."
            [[ -n "$installed_path" ]] && record_cask_lock "$token" "$installed_path" || true
            return 0
        fi
        print_info "$display_name ($installed_ver) differs from supported ($supported_ver). Upgrading."
    fi

    # Fast path tier 2: filesystem fallback for sideloaded installs not known to brew
    if [[ -z "$installed_path" ]]; then
        installed_path="$(resolve_installed_app_path "$app_path")"
    fi
    if [[ -n "$installed_path" ]]; then
        echo "Checking installed version" > "$stage_file" 2>/dev/null || true
        installed_ver="$(get_app_version "$installed_path")"
        if [[ -z "$supported_ver" || "$supported_ver" == "unknown" ]]; then
            echo "Checking supported version" > "$stage_file" 2>/dev/null || true
            supported_ver="$(get_brew_cask_version "$token")"
        fi
        if [[ "$installed_ver" == "unknown" || "$supported_ver" == "unknown" ]] \
            || versions_match_latest "$installed_ver" "$supported_ver"; then
            print_ok "$display_name already installed ($installed_ver). Skipping reinstall."
            record_cask_lock "$token" "$installed_path" || true
            return 0
        fi
        print_info "$display_name ($installed_ver) differs from supported ($supported_ver). Reinstalling."
    fi

    # Slow path: App not found or version mismatch, need to install
    # Only fetch supported version again if we haven't already
    if [[ "$supported_ver" == "unknown" ]]; then
        echo "Checking supported version" > "$stage_file" 2>/dev/null || true
        supported_ver="$(get_brew_cask_version "$token")"
    fi
    
    if [[ "$supported_ver" == "unknown" ]]; then
        print_warn "$display_name cask metadata is unavailable for this Homebrew/macOS state."
    fi
    print_info "$display_name supported cask version for this macOS: $supported_ver"

    echo "Removing old version" > "$stage_file" 2>/dev/null || true
    print_info "Removing old $display_name version (if present)..."
    brew_cmd uninstall --cask --force "$token" >/dev/null 2>&1 || true
    if [[ -d "$app_path" ]]; then
        # Retry sudo with -n flag if keepalive is active
        if ! sudo -n rm -rf "$app_path" 2>/dev/null; then
            # Fall back to non-n flag if keepalive expired
            if ! sudo rm -rf "$app_path" 2>/dev/null; then
                print_warn "Could not remove old app bundle: $app_path"
            fi
        fi
    fi
    if [[ -n "$installed_path" && "$installed_path" != "$app_path" && -d "$installed_path" ]]; then
        if ! sudo -n rm -rf "$installed_path" 2>/dev/null; then
            sudo rm -rf "$installed_path" 2>/dev/null || true
        fi
    fi

    # Pre-fetch the cask DMG into Homebrew's cache with aria2c so the install step
    # finds it already downloaded and skips Homebrew's slow single-connection download.
    echo "Prefetching cask DMG" > "$stage_file" 2>/dev/null || true
    prefetch_brew_cask "$token" "$stage_file" || true

    while [[ "$attempt" -le "$max_attempts" ]]; do
        resolve_brew_download_locks_for_token "$token" || true
        echo "Installing ($attempt/$max_attempts)" > "$stage_file" 2>/dev/null || true
        print_info "Installing latest supported $display_name... (attempt $attempt/$max_attempts)"
        if HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install --cask "$token" >/dev/null 2>&1; then
            break
        fi

        if [[ "$attempt" -lt "$max_attempts" ]]; then
            echo "Repairing Homebrew" > "$stage_file" 2>/dev/null || true
            print_warn "Install attempt failed for $display_name. Repairing Homebrew and retrying once."
            resolve_brew_download_locks_for_token "$token" || true
            repair_homebrew_environment || true
            brew_cmd update --force --quiet >/dev/null 2>&1 || true
        fi

        attempt=$((attempt + 1))
    done

    if [[ "$attempt" -gt "$max_attempts" ]]; then
        print_warn "Failed to install $display_name via cask $token after retries."
        return 1
    fi

    echo "Verifying installation" > "$stage_file" 2>/dev/null || true
    installed_path="$(resolve_installed_app_path "$app_path")"
    if [[ -n "$installed_path" ]]; then
        print_ok "$display_name installed. Version: $(get_app_version "$installed_path")"
    else
        print_warn "$display_name install command completed but app bundle not found at $app_path"
    fi

    record_cask_lock "$token" "${installed_path:-$app_path}" || true
    return 0
}

# Verify all required software is installed
verify_required_software_present() {
    local had_error=0
    local blender_app="/Applications/Blender.app"
    local android_app="/Applications/Android Studio.app"
    local azure_app="/Applications/Azure Data Studio.app"
    local packet_tracer_app=""

    if [[ -n "$(resolve_installed_app_path "$blender_app")" ]]; then
        print_ok "Verified Blender installation."
    else
        print_warn "Blender is not installed at expected path: $blender_app"
        had_error=1
    fi

    if [[ -n "$(resolve_installed_app_path "$android_app")" ]]; then
        print_ok "Verified Android Studio installation."
    else
        print_warn "Android Studio is not installed at expected path: $android_app"
        had_error=1
    fi

    if [[ -n "$(resolve_installed_app_path "$azure_app")" ]]; then
        print_ok "Verified Azure Data Studio installation."
    else
        print_warn "Azure Data Studio is not installed at expected path: $azure_app"
        had_error=1
    fi

    packet_tracer_app="$(find_installed_packet_tracer_app)"
    if [[ -n "$packet_tracer_app" ]]; then
        print_ok "Verified Cisco Packet Tracer installation: $packet_tracer_app"
    else
        print_warn "Cisco Packet Tracer app bundle was not found in /Applications."
        had_error=1
    fi

    # Microsoft Office: probe Word as a sentinel for the meta-cask install.
    if [[ -n "$(resolve_installed_app_path "/Applications/Microsoft Word.app")" ]]; then
        print_ok "Verified Microsoft Office installation."
    else
        print_warn "Microsoft Office (Word) is not installed at expected path: /Applications/Microsoft Word.app"
        had_error=1
    fi

    if [[ -n "$(resolve_installed_app_path "/Applications/Microsoft Teams.app")" ]]; then
        print_ok "Verified Microsoft Teams installation."
    else
        print_warn "Microsoft Teams is not installed at expected path: /Applications/Microsoft Teams.app"
        had_error=1
    fi

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    return 0
}
