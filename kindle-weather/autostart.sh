#!/bin/sh
# Install a single reversible startup job on this verified Kindle.
BASE=${WEATHER_BASE:-/mnt/us/weather}
. "$BASE/common.sh" || exit 1
JOB=/etc/upstart/paperwhite-weather.conf
BOOT_ID_FILE=/proc/sys/kernel/random/boot_id

mark_boot() {
    boot_id=$(cat "$BOOT_ID_FILE" 2>/dev/null)
    case "$boot_id" in ''|*[!a-f0-9-]*) return 1 ;; esac
    printf '%s\n' "$boot_id" > "$STATE/boot-id.new" && mv "$STATE/boot-id.new" "$STATE/boot-id"
}

restore_root() {
    [ "$ROOT_CHANGED" != 1 ] || mntroot ro >/dev/null 2>&1
}

install_job() {
    [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = armv7l ] && [ "$(id -u)" = 0 ] || return 1
    grep -q '5.16.2.1.1' /etc/prettyversion.txt || return 1
    if [ -f "$JOB" ]; then
        cmp -s "$JOB" "$BASE/paperwhite-weather.conf" || {
            printf 'Startup job already exists with different contents; left intact.\n' > "$STATE/boot-install.txt"
            return 1
        }
        mark_boot
        return
    fi
    ROOT_CHANGED=0
    mode=$(awk '$2 == "/" {mode=$4} END {print mode}' /proc/mounts)
    case ",$mode," in
        *,ro,*) mntroot rw >/dev/null 2>&1 || return 1; ROOT_CHANGED=1 ;;
    esac
    trap restore_root EXIT
    trap 'exit 1' HUP INT TERM
    if cp "$BASE/paperwhite-weather.conf" "$JOB.new" && mv "$JOB.new" "$JOB"; then
        sync
        restore_root || return 1
        ROOT_CHANGED=0
        mark_boot || return 1
        printf 'Installed automatic weather startup; original root mount mode restored.\n' > "$STATE/boot-install.txt"
        return 0
    fi
    rm -f "$JOB.new"
    printf 'Automatic startup installation failed.\n' > "$STATE/boot-install.txt"
    return 1
}

boot() {
    boot_id=$(cat "$BOOT_ID_FILE" 2>/dev/null)
    case "$boot_id" in ''|*[!a-f0-9-]*) return 1 ;; esac
    [ "$(cat "$STATE/boot-id" 2>/dev/null)" != "$boot_id" ] || return 0
    # Restarting the framework to leave Weather also emits "started framework".
    # A kernel boot ID prevents that event from immediately reopening Weather.
    mark_boot || return 1
    sleep 20
    /bin/sh "$BASE/runtime.sh" start
}

case "${1:-}" in
    install) install_job ;;
    boot) boot ;;
    *) exit 2 ;;
esac
