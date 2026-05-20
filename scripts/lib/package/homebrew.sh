#!/bin/bash

resolve_brew_bin() {
    if command -v brew >/dev/null 2>&1; then
        command -v brew
        return 0
    fi
    if [[ -x /opt/homebrew/bin/brew ]]; then
        echo "/opt/homebrew/bin/brew"
        return 0
    fi
    if [[ -x /usr/local/bin/brew ]]; then
        echo "/usr/local/bin/brew"
        return 0
    fi
    return 1
}

ensure_brew_in_path() {
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
}

network_stage_update() {
    local label="$1"
    local speed="${2:---}"
    local eta="${3:---}"
    local extra="${4:-}"

    if [[ -n "${ACID_STAGE_FILE:-}" ]]; then
        if [[ -n "$extra" ]]; then
            echo "NET | ${label} | speed=${speed} | eta=${eta} | ${extra}" > "$ACID_STAGE_FILE" 2>/dev/null || true
        else
            echo "NET | ${label} | speed=${speed} | eta=${eta}" > "$ACID_STAGE_FILE" 2>/dev/null || true
        fi
    fi
}

get_remote_file_size_http() {
    local url="$1"
    local content_length=""

    content_length="$(curl -fsI -L "$url" 2>/dev/null | awk -F': ' 'tolower($1)=="content-length" {print $2}' | tr -d '\r' | tail -n 1)"
    if [[ -n "$content_length" && "$content_length" =~ ^[0-9]+$ ]]; then
        echo "$content_length"
        return 0
    fi

    echo "0"
    return 1
}

monitor_net_download_progress() {
    local file_path="$1"
    local label="$2"
    local total_size="$3"
    local last_size=0
    local current_size=0
    local last_time=0
    local current_time=0
    local elapsed=0
    local speed_bps=0
    local speed_display="--"
    local eta_display="--"
    local progress_display="--"
    local downloaded_mb=0
    local no_growth_count=0

    last_time=$(date +%s)

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
                downloaded_mb=$(( current_size / 1048576 ))

                if [[ $speed_bps -ge 1048576 ]]; then
                    speed_display="$((speed_bps / 1048576))MB/s"
                elif [[ $speed_bps -gt 0 ]]; then
                    speed_display="$((speed_bps / 1024))KB/s"
                else
                    speed_display="--"
                fi

                eta_display="--"
                progress_display="--"
                if [[ -n "$total_size" && "$total_size" =~ ^[0-9]+$ && $total_size -gt 0 ]]; then
                    local progress=$(( (current_size * 100) / total_size ))
                    progress_display="${progress}%"
                    if [[ $speed_bps -gt 0 ]]; then
                        local remaining_bytes=$(( total_size - current_size ))
                        if [[ $remaining_bytes -gt 0 ]]; then
                            local eta_seconds=$(( remaining_bytes / speed_bps ))
                            if [[ $eta_seconds -gt 3600 ]]; then
                                eta_display="$((eta_seconds / 3600))h $(((eta_seconds % 3600) / 60))m"
                            elif [[ $eta_seconds -gt 60 ]]; then
                                eta_display="$((eta_seconds / 60))m $((eta_seconds % 60))s"
                            else
                                eta_display="${eta_seconds}s"
                            fi
                        else
                            eta_display="0s"
                        fi
                    fi
                fi

                network_stage_update "$label" "$speed_display" "$eta_display" "progress=${progress_display} | downloaded=${downloaded_mb}MB"
            fi

            last_size=$current_size
            last_time=$current_time
        fi

        sleep 1
    done
}

resolve_go_pkg_url() {
    local arch="$1"
    local json=""
    local filename=""

    json="$(curl -fsSL 'https://go.dev/dl/?mode=json' 2>/dev/null || true)"
    if [[ -z "$json" ]]; then
        return 1
    fi

    filename="$(printf '%s' "$json" | tr ',' '\n' | grep '"filename":"go' | grep "darwin-${arch}.pkg" | head -n 1 | cut -d '"' -f4)"
    if [[ -z "$filename" ]]; then
        return 1
    fi

    echo "https://go.dev/dl/${filename}"
    return 0
}

install_go_official_pkg() {
    local arch
    local pkg_url
    local pkg_file="/tmp/atherion-go.pkg"
    local file_size="0"
    local monitor_pid=""

    arch="$(uname -m)"
    case "$arch" in
        arm64) arch="arm64" ;;
        x86_64) arch="amd64" ;;
        *)
            print_warn "Unsupported architecture for Go pkg install: $arch"
            return 1
            ;;
    esac

    pkg_url="$(resolve_go_pkg_url "$arch" 2>/dev/null || true)"
    if [[ -z "$pkg_url" ]]; then
        return 1
    fi

    rm -f "$pkg_file" >/dev/null 2>&1 || true
    network_stage_update "Golang" "--" "estimating" "phase=download"
    file_size="$(get_remote_file_size_http "$pkg_url" || echo 0)"
    monitor_net_download_progress "$pkg_file" "Golang" "$file_size" &
    monitor_pid=$!

    if ! curl --fail --location --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 15 --silent --show-error "$pkg_url" --output "$pkg_file"; then
        kill "$monitor_pid" >/dev/null 2>&1 || true
        wait "$monitor_pid" >/dev/null 2>&1 || true
        rm -f "$pkg_file" >/dev/null 2>&1 || true
        return 1
    fi

    kill "$monitor_pid" >/dev/null 2>&1 || true
    wait "$monitor_pid" >/dev/null 2>&1 || true

    network_stage_update "Golang" "--" "estimating" "phase=install-pkg"
    if ! sudo installer -pkg "$pkg_file" -target / >/dev/null 2>&1; then
        rm -f "$pkg_file" >/dev/null 2>&1 || true
        return 1
    fi

    rm -f "$pkg_file" >/dev/null 2>&1 || true
    return 0
}

resolve_target_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        printf '%s' "$SUDO_USER"
    else
        printf '%s' "$USER"
    fi
}

resolve_target_home() {
    local target_user
    local target_home

    target_user="$(resolve_target_user)"
    target_home="$(eval echo "~${target_user}" 2>/dev/null || true)"
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        target_home="$HOME"
    fi

    printf '%s' "$target_home"
}

resolve_go_tgz_url() {
    local arch="$1"
    local json=""
    local filename=""

    json="$(curl -fsSL 'https://go.dev/dl/?mode=json' 2>/dev/null || true)"
    if [[ -z "$json" ]]; then
        return 1
    fi

    filename="$(printf '%s' "$json" | tr ',' '\n' | grep '"filename":"go' | grep "darwin-${arch}.tar.gz" | head -n 1 | cut -d '"' -f4)"
    if [[ -z "$filename" ]]; then
        return 1
    fi

    echo "https://go.dev/dl/${filename}"
    return 0
}

persist_go_userland_env() {
    local target_user="$1"
    local target_home="$2"
    local profile_file="${target_home}/.zprofile"
    local marker="# atherion-go-env"

    if [[ -f "$profile_file" ]] && grep -q "$marker" "$profile_file" 2>/dev/null; then
        return 0
    fi

    cat >> "$profile_file" <<EOF

$marker
export GOROOT="${target_home}/Developer/Apps/go"
export GOPATH="${target_home}/go"
export PATH="\$GOROOT/bin:\$GOPATH/bin:\$PATH"
EOF

    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$target_user":"$(id -gn "$target_user" 2>/dev/null || echo staff)" "$profile_file" >/dev/null 2>&1 || true
    fi
}

install_go_userland_tgz() {
    local arch
    local tgz_url
    local tgz_file="/tmp/atherion-go.tgz"
    local file_size="0"
    local monitor_pid=""
    local target_user
    local target_home
    local dev_apps
    local goroot
    local gopath

    arch="$(uname -m)"
    case "$arch" in
        arm64) arch="arm64" ;;
        x86_64) arch="amd64" ;;
        *)
            print_warn "Unsupported architecture for Go tarball install: $arch"
            return 1
            ;;
    esac

    target_user="$(resolve_target_user)"
    target_home="$(resolve_target_home)"
    dev_apps="${target_home}/Developer/Apps"
    goroot="${dev_apps}/go"
    gopath="${target_home}/go"

    tgz_url="$(resolve_go_tgz_url "$arch" 2>/dev/null || true)"
    if [[ -z "$tgz_url" ]]; then
        return 1
    fi

    rm -f "$tgz_file" >/dev/null 2>&1 || true
    network_stage_update "Golang" "--" "estimating" "phase=download-userland"
    file_size="$(get_remote_file_size_http "$tgz_url" || echo 0)"
    monitor_net_download_progress "$tgz_file" "Golang" "$file_size" &
    monitor_pid=$!

    if ! curl --fail --location --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 15 --silent --show-error "$tgz_url" --output "$tgz_file"; then
        kill "$monitor_pid" >/dev/null 2>&1 || true
        wait "$monitor_pid" >/dev/null 2>&1 || true
        rm -f "$tgz_file" >/dev/null 2>&1 || true
        return 1
    fi

    kill "$monitor_pid" >/dev/null 2>&1 || true
    wait "$monitor_pid" >/dev/null 2>&1 || true

    network_stage_update "Golang" "--" "estimating" "phase=extract-userland"
    mkdir -p "$dev_apps" "$gopath" >/dev/null 2>&1 || true
    rm -rf "$goroot" >/dev/null 2>&1 || true

    if ! tar -xzf "$tgz_file" -C "$dev_apps"; then
        rm -f "$tgz_file" >/dev/null 2>&1 || true
        return 1
    fi

    rm -f "$tgz_file" >/dev/null 2>&1 || true

    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$target_user":"$(id -gn "$target_user" 2>/dev/null || echo staff)" "$dev_apps" "$gopath" >/dev/null 2>&1 || true
    fi

    persist_go_userland_env "$target_user" "$target_home"

    export GOROOT="$goroot"
    export GOPATH="$gopath"
    export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"

    if [[ -x "$GOROOT/bin/go" ]]; then
        return 0
    fi

    return 1
}

brew_cmd() {
    local brew_bin
    ensure_brew_in_path
    brew_bin="$(resolve_brew_bin 2>/dev/null || true)"
    if [[ -z "$brew_bin" ]]; then
        return 127
    fi

    if [[ "$EUID" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        local target_home
        target_home="$(eval echo "~${SUDO_USER}" 2>/dev/null || echo "/Users/${SUDO_USER}")"
        sudo -u "$SUDO_USER" \
            env \
            HOME="$target_home" \
            HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-}" \
            HOMEBREW_NO_INSTALL_FROM_API="${HOMEBREW_NO_INSTALL_FROM_API:-}" \
            "$brew_bin" "$@"
    else
        "$brew_bin" "$@"
    fi
}

ensure_git_installed() {
    local clt_label

    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

    if command -v git >/dev/null 2>&1; then
        print_ok "git is already available: $(command -v git)"
        return 0
    fi

    if [[ -x /usr/bin/git ]]; then
        print_warn "git exists at /usr/bin/git but was missing from PATH. PATH corrected."
        return 0
    fi

    print_warn "git is not installed. Attempting to install Command Line Tools."
    network_stage_update "Command Line Tools" "--" "estimating" "phase=lookup"

    clt_label="$(softwareupdate -l 2>/dev/null | awk -F'* ' '/Command Line Tools/ {print $2}' | sed 's/^Label: //' | tail -n 1)"
    if [[ -n "$clt_label" ]]; then
        print_info "Installing: $clt_label"
        network_stage_update "Command Line Tools" "--" "estimating" "phase=install"
        if sudo softwareupdate -i "$clt_label" --verbose; then
            if command -v git >/dev/null 2>&1 || [[ -x /usr/bin/git ]]; then
                print_ok "git installed successfully via Command Line Tools."
                return 0
            fi
        fi
    fi

    print_warn "Automatic CLT install did not complete. Triggering interactive installer."
    network_stage_update "Command Line Tools" "--" "manual" "phase=interactive"
    xcode-select --install >/dev/null 2>&1 || true

    if command -v git >/dev/null 2>&1 || [[ -x /usr/bin/git ]]; then
        print_ok "git is now available."
        return 0
    fi

    print_err "git is still unavailable. Complete Command Line Tools installation, then rerun this script."
    return 1
}

brew_is_healthy() {
    ensure_brew_in_path
    if ! resolve_brew_bin >/dev/null 2>&1; then
        return 1
    fi

    if brew_cmd --version >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

repair_homebrew_shallow_clones() {
    local brew_repo
    local core_tap
    local cask_tap
    local had_error=0

    if ! resolve_brew_bin >/dev/null 2>&1; then
        print_warn "brew is unavailable; cannot repair shallow clones."
        return 1
    fi

    brew_repo="$(brew_cmd --repository 2>/dev/null || true)"
    if [[ -z "$brew_repo" ]]; then
        if [[ -d /opt/homebrew ]]; then
            brew_repo="/opt/homebrew"
        elif [[ -d /usr/local/Homebrew ]]; then
            brew_repo="/usr/local/Homebrew"
        fi
    fi

    if [[ -z "$brew_repo" || ! -d "$brew_repo" ]]; then
        print_warn "Could not resolve Homebrew repository path for shallow clone repair."
        return 1
    fi

    core_tap="$brew_repo/Library/Taps/homebrew/homebrew-core"
    cask_tap="$brew_repo/Library/Taps/homebrew/homebrew-cask"

    if [[ -d "$core_tap/.git" ]]; then
        print_info "Repairing shallow clone: homebrew-core"
        if ! git -C "$core_tap" fetch --unshallow >/dev/null 2>&1; then
            print_warn "Could not unshallow homebrew-core."
            had_error=1
        fi
    fi

    if [[ -d "$cask_tap/.git" ]]; then
        print_info "Repairing shallow clone: homebrew-cask"
        if ! git -C "$cask_tap" fetch --unshallow >/dev/null 2>&1; then
            print_warn "Could not unshallow homebrew-cask."
            had_error=1
        fi
    fi

    [[ "$had_error" -eq 0 ]]
}

repair_homebrew_permissions() {
    local had_error=0
    local owner_user="${SUDO_USER:-$USER}"
    local owner_group
    local zsh_dirs=(
        "/usr/local/share/zsh"
        "/usr/local/share/zsh/site-functions"
    )
    local d

    owner_group="$(id -gn "$owner_user" 2>/dev/null || echo staff)"

    for d in "${zsh_dirs[@]}"; do
        if [[ ! -d "$d" ]]; then
            sudo mkdir -p "$d" >/dev/null 2>&1 || {
                print_warn "Could not create directory: $d"
                had_error=1
                continue
            }
        fi

        # Check writability as the target user, not as root — root can always write,
        # so [[ ! -w "$d" ]] would never fire when running via sudo.
        if ! sudo -u "$owner_user" test -w "$d" 2>/dev/null; then
            print_info "Fixing write permissions for: $d"
            sudo chown "$owner_user":"$owner_group" "$d" >/dev/null 2>&1 || {
                print_warn "Could not change ownership for: $d"
                had_error=1
            }
            sudo chmod u+w "$d" >/dev/null 2>&1 || {
                print_warn "Could not set write permission for: $d"
                had_error=1
            }
        fi
    done

    [[ "$had_error" -eq 0 ]]
}

repair_homebrew_environment() {
    local had_error=0

    if resolve_brew_bin >/dev/null 2>&1; then
        print_info "Repairing Homebrew tap clone depth and permissions."
        repair_homebrew_shallow_clones || had_error=1
    fi

    repair_homebrew_permissions || had_error=1

    [[ "$had_error" -eq 0 ]]
}

install_homebrew() {
    ensure_brew_in_path

    if ! ensure_git_installed; then
        print_err "Cannot install Homebrew without git in PATH."
        return 1
    fi

    if brew_is_healthy; then
        print_ok "Homebrew is already installed."
        return 0
    fi

    if resolve_brew_bin >/dev/null 2>&1; then
        print_warn "Homebrew is installed but appears broken. Attempting reinstall."
    fi

    print_info "Installing Homebrew..."
    network_stage_update "Homebrew" "--" "estimating" "phase=bootstrap"
    repair_homebrew_environment || true

    # Download the installer as root, then run it as the original (sudo) user.
    # Homebrew's install.sh explicitly refuses to run as root — it must execute
    # under the user account that will own the Homebrew prefix.
    local brew_install_script="/tmp/atherion-homebrew-install.sh"
    local target_user target_home
    target_user="$(resolve_target_user)"
    target_home="$(resolve_target_home)"
    if ! curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$brew_install_script" 2>/dev/null; then
        print_err "Failed to download Homebrew install script."
        return 1
    fi
    chmod 755 "$brew_install_script"

    # Redirect Homebrew installer output to a log file. Otherwise its progress
    # lines (`==> Downloading…`, `==> Installing…`) interleave with our spinner
    # and produce visual chaos in the terminal and unreadable lines in tee'd logs.
    local brew_install_log="/var/log/atherion-brew-install.log"
    sudo touch "$brew_install_log" >/dev/null 2>&1 || true
    sudo chmod 644 "$brew_install_log" >/dev/null 2>&1 || true
    print_info "Homebrew installer output → $brew_install_log"

    local brew_ok=0
    if [[ "$EUID" -eq 0 && -n "$target_user" && "$target_user" != "root" ]]; then
        sudo -u "$target_user" env HOME="$target_home" NONINTERACTIVE=1 \
            /bin/bash "$brew_install_script" >>"$brew_install_log" 2>&1 \
            && brew_ok=1
    else
        NONINTERACTIVE=1 /bin/bash "$brew_install_script" >>"$brew_install_log" 2>&1 \
            && brew_ok=1
    fi
    rm -f "$brew_install_script"

    if [[ "$brew_ok" -ne 1 ]]; then
        if resolve_brew_bin >/dev/null 2>&1; then
            print_warn "Homebrew install/update failed. Attempting shallow clone repair and retry."
            repair_homebrew_environment || true
            network_stage_update "Homebrew" "--" "estimating" "phase=update"
            brew_cmd update --force --quiet >/dev/null 2>&1 || true
        fi

        if brew_is_healthy; then
            print_ok "Homebrew is healthy after repair/retry."
            return 0
        fi

        print_err "Homebrew installation failed."
        return 1
    fi

    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if ! brew_is_healthy; then
        print_err "Homebrew is still unavailable or unhealthy after reinstall attempt."
        return 1
    fi

    print_ok "Homebrew installed successfully."
    return 0
}

ensure_runtime_dependencies() {
    local had_error=0

    if ! command -v curl >/dev/null 2>&1; then
        print_warn "curl is missing. Attempting Command Line Tools install path."
        ensure_git_installed || had_error=1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        if brew_is_healthy; then
            print_info "Installing missing dependency: python3"
            network_stage_update "python3" "--" "estimating" "phase=brew-install"
            HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install python >/dev/null 2>&1 || had_error=1
        else
            print_warn "python3 is missing and Homebrew is unavailable right now."
            had_error=1
        fi
    fi

    # Install aria2 first so Homebrew uses it for parallel formula downloads.
    if brew_is_healthy; then
        if ! brew_cmd list --formula aria2 >/dev/null 2>&1; then
            print_info "Installing download accelerator: aria2"
            network_stage_update "aria2" "--" "estimating" "phase=brew-install"
            HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install aria2 >/dev/null 2>&1 || \
                print_warn "aria2 install failed; downloads will use single-connection curl"
        fi
    fi

    # Install monitoring stack used by sysmon wrapper (optional — failures are non-fatal).
    if brew_is_healthy; then
        if ! brew_cmd list --formula btop >/dev/null 2>&1; then
            print_info "Installing monitoring dependency: btop"
            network_stage_update "btop" "--" "estimating" "phase=brew-install"
            HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install btop >/dev/null 2>&1 || \
                print_warn "btop install failed; sysmon will fall back to built-in monitor"
        fi

        # osx-cpu-temp uses the Intel SMC interface — not available on Apple Silicon.
        if [[ "$(uname -m)" != "arm64" ]]; then
            if ! brew_cmd list --formula osx-cpu-temp >/dev/null 2>&1; then
                print_info "Installing monitoring dependency: osx-cpu-temp"
                network_stage_update "osx-cpu-temp" "--" "estimating" "phase=brew-install"
                HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install osx-cpu-temp >/dev/null 2>&1 || \
                    print_warn "osx-cpu-temp install failed; CPU temp will use powermetrics fallback"
            fi
        fi
        if ! brew_cmd list --formula desktoppr >/dev/null 2>&1; then
            print_info "Installing wallpaper utility: desktoppr"
            network_stage_update "desktoppr" "--" "estimating" "phase=brew-install"
            HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install desktoppr >/dev/null 2>&1 || \
                print_warn "desktoppr install failed; set_wallpaper_macos.sh will use legacy fallback"
        fi
    else
        print_warn "Homebrew unavailable, skipping btop/osx-cpu-temp/desktoppr install."
    fi

    [[ "$had_error" -eq 0 ]]
}

ensure_go_installed() {
    ensure_brew_in_path

    if command -v go >/dev/null 2>&1; then
        print_ok "go is already available: $(command -v go)"
        return 0
    fi

    print_info "Installing Golang (go) from official package..."
    if install_go_official_pkg; then
        hash -r
        if command -v go >/dev/null 2>&1; then
            print_ok "go installed successfully: $(command -v go)"
            return 0
        fi
        if [[ -x /usr/local/go/bin/go ]]; then
            print_ok "go installed successfully: /usr/local/go/bin/go"
            return 0
        fi
    fi

    print_warn "Official Go pkg install failed. Trying userland Go install (no admin)."
    if install_go_userland_tgz; then
        hash -r
        if command -v go >/dev/null 2>&1; then
            print_ok "go installed successfully: $(command -v go)"
            return 0
        fi
        if [[ -n "${GOROOT:-}" && -x "${GOROOT}/bin/go" ]]; then
            print_ok "go installed successfully: ${GOROOT}/bin/go"
            return 0
        fi
    fi

    print_warn "Userland Go install failed. Falling back to Homebrew."
    if ! brew_is_healthy; then
        print_warn "Homebrew is unavailable right now for fallback install."
        return 1
    fi

    repair_homebrew_environment || true
    network_stage_update "Golang" "--" "estimating" "phase=brew-install"
    if ! HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install go; then
        print_warn "Homebrew go install failed. Retrying after Homebrew repair/update."
        repair_homebrew_environment || true
        network_stage_update "Golang" "--" "estimating" "phase=brew-update"
        brew_cmd update --force --quiet >/dev/null 2>&1 || true
        network_stage_update "Golang" "--" "estimating" "phase=brew-install-retry"
        if ! HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install go; then
            print_err "go installation failed via official package and Homebrew fallback."
            return 1
        fi
    fi

    hash -r
    if command -v go >/dev/null 2>&1; then
        print_ok "go installed successfully: $(command -v go)"
        return 0
    fi

    if [[ -x /opt/homebrew/bin/go ]]; then
        print_ok "go installed successfully: /opt/homebrew/bin/go"
        return 0
    fi

    if [[ -x /usr/local/bin/go ]]; then
        print_ok "go installed successfully: /usr/local/bin/go"
        return 0
    fi

    print_err "go install completed but binary was not found in PATH."
    return 1
}

attempt_dependency_repair() {
    local log_file="$1"
    local repaired=0

    if grep -qiE 'command not found: python3|python3: command not found' "$log_file"; then
        if brew_is_healthy; then
            print_info "Auto-fix: installing python3"
            HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install python >/dev/null 2>&1 && repaired=1
        fi
    fi

    if grep -qiE 'command not found: go|go: command not found' "$log_file"; then
        print_info "Auto-fix: installing go"
        ensure_go_installed >/dev/null 2>&1 && repaired=1
    fi

    if grep -qiE 'command not found: git|git: command not found' "$log_file"; then
        print_info "Auto-fix: installing git via CLT path"
        ensure_git_installed && repaired=1
    fi

    if grep -qiE 'command not found: brew|brew: command not found' "$log_file"; then
        print_info "Auto-fix: attempting Homebrew install"
        install_homebrew && repaired=1
    fi

    if grep -qiE 'homebrew-core is a shallow clone|homebrew-cask is a shallow clone|not writable by your user' "$log_file"; then
        print_info "Auto-fix: repairing Homebrew environment"
        repair_homebrew_environment && repaired=1
    fi

    [[ "$repaired" -eq 1 ]]
}
