#!/bin/sh
# Transactional file installation. Loaded by the bundled installer and tests.

installer_error() { printf '\nInstallation stopped: %s\n' "$*" >&2; }

rollback_install() {
    [ "$NEW_WEATHER" != 1 ] || rm -rf "$INSTALL_ROOT/weather"
    if [ -d "$BACKUP/weather" ]; then
        rm -rf "$INSTALL_ROOT/weather"
        mv "$BACKUP/weather" "$INSTALL_ROOT/weather"
    fi
    index=0
    for name in 'Weather.sh' 'Weather Settings.sh' 'Weather instructions.txt'; do
        index=$((index + 1))
        case "$(cat "$BACKUP/changed-$index" 2>/dev/null)" in
            old)
                if [ -f "$BACKUP/documents/$name" ]; then
                    rm -f "$INSTALL_ROOT/documents/$name"
                    mv "$BACKUP/documents/$name" "$INSTALL_ROOT/documents/$name"
                fi ;;
            new) rm -f "$INSTALL_ROOT/documents/$name" ;;
        esac
    done
}

perform_install() {
    if [ -d "$INSTALL_ROOT/weather/state" ]; then
        cp -R "$INSTALL_ROOT/weather/state" "$INSTALL_STAGE/weather/state" || return 1
    fi
    if [ -d "$INSTALL_ROOT/weather" ]; then
        mv "$INSTALL_ROOT/weather" "$BACKUP/weather" || return 1
        OLD_WEATHER=1
    fi
    NEW_WEATHER=1
    mv "$INSTALL_STAGE/weather" "$INSTALL_ROOT/weather" || return 1
    index=0
    for name in 'Weather.sh' 'Weather Settings.sh' 'Weather instructions.txt'; do
        index=$((index + 1))
        # Record intent before moving or writing, so interruption can roll back.
        if [ -f "$INSTALL_ROOT/documents/$name" ]; then
            printf 'old\n' > "$BACKUP/changed-$index" || return 1
            mv "$INSTALL_ROOT/documents/$name" "$BACKUP/documents/$name" || return 1
        else
            printf 'new\n' > "$BACKUP/changed-$index" || return 1
        fi
        cp "$INSTALL_STAGE/documents/$name" "$INSTALL_ROOT/documents/$name" || return 1
    done
    return 0
}

install_payload() {
    INSTALL_ROOT=$1
    INSTALL_STAGE=$2
    for path in weather weather/state documents extensions extensions/kterm weather-backups; do
        [ ! -L "$INSTALL_ROOT/$path" ] || { installer_error 'An installation path is a symbolic link; left unchanged.'; return 1; }
        [ ! -e "$INSTALL_ROOT/$path" ] || [ -d "$INSTALL_ROOT/$path" ] || \
            { installer_error 'An installation path is not a directory; left unchanged.'; return 1; }
    done
    for name in 'Weather.sh' 'Weather Settings.sh' 'Weather instructions.txt'; do
        [ ! -L "$INSTALL_ROOT/documents/$name" ] || { installer_error 'A Weather document is a symbolic link; left unchanged.'; return 1; }
        [ ! -e "$INSTALL_ROOT/documents/$name" ] || [ -f "$INSTALL_ROOT/documents/$name" ] || \
            { installer_error 'A Weather document is not a regular file; left unchanged.'; return 1; }
        [ -f "$INSTALL_STAGE/documents/$name" ] || return 1
    done
    [ -f "$INSTALL_STAGE/weather/runtime.sh" ] && [ ! -e "$INSTALL_STAGE/weather/state" ] || return 1
    [ -x "$INSTALL_ROOT/extensions/kterm/bin/kterm" ] && \
    [ -f "$INSTALL_ROOT/extensions/kterm/layouts/keyboard-300dpi.xml" ] && \
    [ -d "$INSTALL_ROOT/extensions/kterm/vte/terminfo" ] || \
        { installer_error 'Install official kTerm 2.6 first; no Weather files changed.'; return 1; }
    pid=$(cat "$INSTALL_ROOT/weather/state/runtime.pid" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) ;; *)
        if [ "$pid" -gt 1 ] && [ -r "/proc/$pid/cmdline" ] && \
           tr '\000' ' ' < "/proc/$pid/cmdline" | grep -Fq "$INSTALL_ROOT/weather/runtime.sh loop"; then
            installer_error 'Leave Weather with Power before installing.'; return 1
        fi ;;
    esac
    BACKUP="$INSTALL_ROOT/weather-backups/install-$(date -u '+%Y%m%d-%H%M%S')-$$"
    OLD_WEATHER=0; NEW_WEATHER=0
    mkdir -p "$BACKUP/documents" "$INSTALL_ROOT/documents" || return 1
    trap 'rollback_install; exit 1' HUP INT TERM
    if ! perform_install; then
        installer_error 'A file operation failed. Restoring the previous installation.'
        rollback_install
        trap - HUP INT TERM
        return 1
    fi
    trap - HUP INT TERM
    printf 'Installed. Previous Weather files: %s\n' "$BACKUP"
    return 0
}

confirm_install() {
    printf '\033[2J\033[HKINDLE WEATHER INSTALLER\n\n'
    printf 'For jailbroken Paperwhite 3, firmware 5.16.2.1.1.\n\n'
    printf 'Installs Weather and Weather Settings.\n'
    printf 'Preserves your saved ZIP and cached weather.\n'
    printf 'Backs up any previous Weather installation.\n'
    printf 'Enables automatic startup after device setup passes.\n\n'
    printf 'Weather connects hourly to Open-Meteo and NWS.\n'
    printf 'ZIP lookup uses Zippopotam.us.\n'
    printf 'Frontlight and Wi-Fi are off between updates.\n\n'
    printf 'This does not jailbreak or update the Kindle.\n'
    printf 'Use a saved Wi-Fi network and keep USB unplugged.\n\n'
    printf 'Type YES, then Enter to install. Anything else cancels.\n> '
    IFS= read -r answer || return 0
    case "$answer" in YES|Yes|yes) ;; *) printf '\nCancelled.\n'; return 0 ;; esac
    if install_payload "$1" "$2"; then
        printf 'installed\n' > "$2/result" || return 1
        printf '\nOpening Weather setup...\n'
        sleep 2
    else
        printf '\nPress Enter to close.\n'
        IFS= read -r answer
        return 1
    fi
}

case "${1:-}" in
    --confirm) confirm_install "$2" "$3" ;;
esac
