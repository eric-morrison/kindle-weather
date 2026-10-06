#!/bin/sh
# Kindle-only suspend/resume loop. No system services are changed on the Mac.
BASE=${WEATHER_BASE:-/mnt/us/weather}
. "$BASE/common.sh" || exit 1
load_settings
RTC=/sys/class/rtc/rtc0/wakealarm
POWER=/sys/power/state
PIDFILE=$STATE/runtime.pid

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$STATE/runtime.log"; }
setup_error() {
    log "$*"
    printf '%s\n' "$*" > '/mnt/us/documents/Weather setup error.txt'
    return 1
}

find_fbink() {
    FBINK=
    for binary in /var/local/kmc/bin/fbink /mnt/us/libkh/bin/fbink /usr/bin/fbink; do
        if [ -x "$binary" ]; then FBINK=$binary; return 0; fi
    done
    return 1
}

preflight() {
    [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = armv7l ] || return 1
    [ -f /etc/prettyversion.txt ] || return 1
    grep -q '5.16.2.1.1' /etc/prettyversion.txt || return 1
    [ -w "$RTC" ] && [ -w "$POWER" ] && [ -r /dev/input/event0 ] || return 1
    grep -q 'mem' "$POWER" || return 1
    find_fbink || return 1
    "$FBINK" --help >/dev/null 2>&1 || return 1
    [ -s "$BASE/fonts/LiberationSans-Regular.ttf" ] && [ -s "$BASE/fonts/LiberationSans-Bold.ttf" ] || return 1
    [ -s "$BASE/fonts/NotoSansSymbols2-Regular.ttf" ] || return 1
    for tool in setsid nohup stop start lipc-get-prop lipc-set-prop dd od curl awk; do
        command -v "$tool" >/dev/null 2>&1 || return 1
    done
    # Installing files alone does not certify this individual device's wake cycle.
    [ -f "$STATE/hardware-verified" ] || return 1
    next_wake "$(date +%s)" >/dev/null || return 1
}

owned_pid() {
    [ -s "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE")
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] && [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/$pid/cmdline" | grep -Fq "$BASE/runtime.sh loop" || return 1
}

restore() {
    # One cleanup owns restoration, including when the input watcher and resume
    # path both request an exit. Never start the framework twice concurrently.
    mkdir "$STATE/restoring" 2>/dev/null || return 0
    log 'Restoring Library interface.'
    printf '0\n' > "$RTC" 2>/dev/null
    if [ -f "$STATE/framework-stopped" ]; then
        find_fbink && "$FBINK" -q -c -m -M -t "regular=$BASE/fonts/LiberationSans-Regular.ttf,px=60" \
            'Returning to Library…' >/dev/null 2>&1
        log 'Starting Kindle framework.'
        if start framework >/dev/null 2>&1; then
            rm -f "$STATE/framework-stopped"
            log 'Kindle framework start completed.'
        else
            log 'Kindle framework start failed; restoration marker retained.'
        fi
    fi
    # Restore network access after starting the interface, so a slow radio
    # change cannot hold up the first visible exit response.
    if [ -s "$STATE/old-wireless" ]; then
        old=$(cat "$STATE/old-wireless")
        case "$old" in 0|1) lipc-set-prop com.lab126.cmd wirelessEnable "$old" >/dev/null 2>&1 ;; esac
    fi
    if [ -s "$STATE/old-light" ]; then
        old=$(cat "$STATE/old-light")
        case "$old" in ''|*[!0-9]*) ;; *)
            [ "$old" -gt 24 ] || lipc-set-prop com.lab126.powerd flIntensity "$old" >/dev/null 2>&1 ;;
        esac
    fi
    old=$(cat "$STATE/old-screensaver" 2>/dev/null)
    case "$old" in 0|1) lipc-set-prop com.lab126.powerd preventScreenSaver "$old" >/dev/null 2>&1 ;; esac
    rm -f "$PIDFILE"
    rmdir "$STATE/restoring" 2>/dev/null
    rm -f "$STATE/stopping"
    log 'Weather cleanup completed.'
}

stop_weather() {
    if owned_pid; then
        [ ! -f "$STATE/stopping" ] || return 0
        touch "$STATE/stopping"
        log 'Stop requested; terminating weather session.'
        kill -TERM -- "-$pid" 2>/dev/null
        # The loop owns normal cleanup. Only repair a failed cleanup after the
        # process exits; do not interrupt its framework start a second time.
        waited=0
        while owned_pid && [ "$waited" -lt 8 ]; do
            sleep 1; waited=$((waited + 1))
        done
        if ! owned_pid && [ -f "$STATE/framework-stopped" ]; then
            restore
        fi
    fi
}

power_button() {
    # PW3 kernel input_event: 16 bytes, little endian. Keep one descriptor open.
    exec 4< /dev/input/event0 || return 1
    while :; do
        words=$(dd bs=16 count=1 <&4 2>/dev/null | od -An -v -t u2)
        set -- $words
        [ "$#" -eq 8 ] || return 1
        if [ "$5" = 1 ] && [ "$6" = 116 ] && [ "$7" = 1 ]; then
            log "Power button received; event timestamp $(( $1 + $2 * 65536 ))."
            # The stop helper must survive termination of the weather session.
            nohup setsid /bin/sh "$BASE/runtime.sh" stop >> "$STATE/runtime.log" 2>&1 < /dev/null &
            return
        fi
    done
}

wifi_on() {
    lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1 || return 1
    waited=0
    while [ "$waited" -lt 25 ]; do
        status=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
        [ "$status" = CONNECTED ] && return 0
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

sample_battery() {
    battery=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    case "$battery" in
        ''|*[!0-9]*) rm -f "$STATE/battery-percent" ;;
        *) if [ "$battery" -le 100 ]; then
               printf '%s\n' "$battery" > "$STATE/battery-percent"
           else rm -f "$STATE/battery-percent"; fi ;;
    esac
    charging=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
    case "$charging" in
        0|1) printf '%s\n' "$charging" > "$STATE/battery-charging" ;;
        *) rm -f "$STATE/battery-charging" ;;
    esac
}

paint_sleep_screen() {
    # Radio changes can make the native status bar redraw its airplane icon.
    # Let that finish before clearing and painting the complete weather frame.
    lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1 || return 1
    sleep 2
    /bin/sh "$BASE/dashboard.sh" --cached > "$STATE/screen.txt" || return 1
    /bin/sh "$BASE/display.sh" --paint "$FBINK" >> "$STATE/runtime.log" 2>&1
}

cleanup_loop() {
    # Additional stop requests must not kill a framework start in progress.
    trap '' HUP INT TERM
    touch "$STATE/stopping"
    [ -z "$WATCHER" ] || kill -TERM -- "-$WATCHER" 2>/dev/null
    restore
}

wake_diagnostics() {
    # Read-only evidence for the power-button wake path on this exact Kindle.
    {
        date -u
        lipc-get-prop com.lab126.powerd state
        cat /proc/bus/input/devices
        node=$(readlink -f /sys/class/input/event0/device)
        while [ -n "$node" ] && [ "$node" != /sys ] && [ "$node" != / ]; do
            if [ -f "$node/power/wakeup" ]; then
                printf '%s: ' "$node/power/wakeup"
                cat "$node/power/wakeup"
            fi
            node=${node%/*}
        done
        cat /proc/interrupts
    } > "$STATE/wake-diagnostics.txt" 2>&1
}

loop() {
    preflight || { setup_error 'Weather needs a verified device sleep/wake test. Open Weather Device Check first.'; exit 1; }
    rm -f "$STATE/stopping"
    rmdir "$STATE/restoring" 2>/dev/null
    printf '%s\n' "$$" > "$PIDFILE"
    wake_diagnostics
    lipc-get-prop com.lab126.powerd flIntensity > "$STATE/old-light" 2>/dev/null
    lipc-get-prop com.lab126.powerd preventScreenSaver > "$STATE/old-screensaver" 2>/dev/null
    lipc-get-prop com.lab126.cmd wirelessEnable > "$STATE/old-wireless" 2>/dev/null
    # A saved network is required; restore Wi-Fi access when leaving weather mode.
    [ -s "$STATE/old-wireless" ] || printf '1\n' > "$STATE/old-wireless"
    WATCHER=
    trap cleanup_loop EXIT
    trap 'exit 0' HUP INT TERM
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1 || exit 1
    lipc-set-prop com.lab126.powerd flIntensity 0 >/dev/null 2>&1 || exit 1
    # Mark before stopping, so every failure path attempts to restore the GUI.
    touch "$STATE/framework-stopped"
    stop framework >/dev/null 2>&1 || exit 1
    sleep 2
    # Isolate the input reader so its blocked dd/od children can also be stopped.
    setsid /bin/sh "$BASE/runtime.sh" watch & WATCHER=$!
    while :; do
        load_settings
        if wifi_on; then
            /bin/sh "$BASE/dashboard.sh" --refresh || log 'Forecast fetch failed; retained cache.'
        else
            printf 'Wi-Fi unavailable; cached data.\n' > "$STATE/notice"
            touch "$STATE/alerts-failed"
        fi
        sample_battery
        paint_sleep_screen || exit 1
        # One bounded capture lets the USB follow-up verify the actual font
        # layout, rather than relying only on the Mac's rasterizer preview.
        if [ ! -f "$STATE/layout-v4-captured" ]; then
            dd if=/dev/fb0 of="$STATE/display-framebuffer.raw" bs=1088 count=1448 2>/dev/null && \
                touch "$STATE/layout-v4-captured"
        fi
        # Logs stay on the Kindle; rotate to avoid unbounded growth.
        [ ! -f "$STATE/battery.csv" ] || [ "$(wc -l < "$STATE/battery.csv")" -lt 2000 ] || \
            tail -1000 "$STATE/battery.csv" > "$STATE/battery.new"
        [ ! -f "$STATE/battery.new" ] || mv "$STATE/battery.new" "$STATE/battery.csv"
        printf '%s,%s,%s\n' "$(date +%s)" "$battery" "$HOURLY" >> "$STATE/battery.csv"
        wake=$(next_wake "$(date +%s)") || exit 1
        printf '0\n' > "$RTC" || exit 1
        printf '%s\n' "$wake" > "$RTC" || exit 1
        log "Sleeping until $wake; battery $battery; hourly $HOURLY."
        sync
        before=$(date +%s)
        printf 'mem\n' > "$POWER" || exit 1
        after=$(date +%s)
        # Wake by power button exits; RTC wakes refresh. Avoid an awake busy loop.
        if [ "$after" -lt "$((wake - 5))" ]; then
            log "Early wake after $((after - before)) seconds; returning to Library."
            exit 0
        fi
    done
}

case "${1:-}" in
    start)
        owned_pid && exit 0
        if ! valid_zip "$ZIP" || [ ! -f "$STATE/hardware-verified" ]; then
            exec /bin/sh "$BASE/first-run.sh"
        fi
        preflight || { setup_error 'Weather needs a verified device sleep/wake test. Open Weather Device Check first.'; exit 1; }
        /bin/sh "$BASE/autostart.sh" install >> "$STATE/runtime.log" 2>&1 || log 'Automatic startup installation needs inspection.'
        nohup setsid /bin/sh "$BASE/runtime.sh" loop >> "$STATE/runtime.log" 2>&1 < /dev/null &
        ;;
    loop) loop ;;
    watch) power_button ;;
    stop) stop_weather ;;
    --schedule) next_wake "$2" ;;
    *) exit 2 ;;
esac
