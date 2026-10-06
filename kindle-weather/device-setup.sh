#!/bin/sh
# One-time, bounded hardware check. Does not change root firmware or install services.
BASE=${WEATHER_BASE:-/mnt/us/weather}
. "$BASE/common.sh" || exit 1
RESULT=$STATE/setup-result.txt
RTC=/sys/class/rtc/rtc0/wakealarm
POWER=/sys/power/state
FBINK=/mnt/us/libkh/bin/fbink

paint() {
    "$FBINK" -c -f -w -S 3 -x 1 -y 1 "$1" >> "$STATE/setup.log" 2>&1
}

cleanup() {
    [ -z "$INPUT_PID" ] || kill -TERM -- "-$INPUT_PID" 2>/dev/null
    if [ "$CHANGED_POWER" = 1 ]; then
        printf '0\n' > "$RTC" 2>/dev/null
        case "$OLD_WIRELESS" in 0|1) lipc-set-prop com.lab126.cmd wirelessEnable "$OLD_WIRELESS" >/dev/null 2>&1 ;; esac
        case "$OLD_LIGHT" in ''|*[!0-9]*) ;; *)
            [ "$OLD_LIGHT" -gt 24 ] || lipc-set-prop com.lab126.powerd flIntensity "$OLD_LIGHT" >/dev/null 2>&1 ;;
        esac
        case "$OLD_SAVER" in 0|1) lipc-set-prop com.lab126.powerd preventScreenSaver "$OLD_SAVER" >/dev/null 2>&1 ;; esac
    fi
    if [ "$STOPPED" = 1 ]; then start framework >/dev/null 2>&1; fi
    rmdir "$STATE/setup-running" 2>/dev/null
}

fail() {
    printf 'result=failed\nreason=%s\n' "$1" >> "$RESULT"
    printf 'Weather setup check: %s\nReconnect USB so setup can be completed.\n' "$1" \
        > '/mnt/us/documents/Weather setup error.txt'
    paint "WEATHER SETUP

$1

Reconnect USB for setup."
    sleep 4
    exit 1
}

read_power() {
    exec 4< /dev/input/event0 || exit 1
    while :; do
        words=$(dd bs=16 count=1 <&4 2>/dev/null | od -An -v -t u2)
        set -- $words
        [ "$#" -eq 8 ] || exit 1
        printf '%s\n' "$words" >> "$STATE/setup-input.txt"
        if [ "$5" = 1 ] && [ "$6" = 116 ] && [ "$7" = 1 ]; then
            printf 'power=passed\n' > "$STATE/setup-power.txt"
            exit 0
        fi
    done
}

run() {
    [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = armv7l ] || exit 1
    [ -f "$STATE/hardware-verified" ] && exit 0
    mkdir "$STATE/setup-running" 2>/dev/null || exit 0
    CHANGED_POWER=0; STOPPED=0; INPUT_PID=
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    # Let the scriptlet launcher finish before taking over the screen.
    sleep 3
    : > "$RESULT"
    /bin/sh "$BASE/Weather Device Check.sh"
    [ "$(id -u)" = 0 ] || fail 'The scriptlet did not get root access.'
    grep -q '5.16.2.1.1' /etc/prettyversion.txt || fail 'Firmware differs from the prepared version.'
    [ -x "$FBINK" ] && "$FBINK" --help >/dev/null 2>&1 || fail 'FBInk cannot run.'
    for tool in setsid stop start lipc-get-prop lipc-set-prop dd od curl awk; do
        command -v "$tool" >/dev/null 2>&1 || fail "Missing tool: $tool"
    done
    [ -w "$RTC" ] && [ -w "$POWER" ] && [ -r /dev/input/event0 ] || fail 'Sleep or power-button access is unavailable.'
    grep -q 'mem' "$POWER" || fail 'Timed suspend is unavailable.'
    grep -q 'max77696-onkey' /proc/bus/input/devices || fail 'Power-button hardware differs.'
    printf 'platform=passed\n' >> "$RESULT"

    # Retain the temporary USB filler unless the actual updater rename is visible.
    if [ ! -e /usr/bin/otaupd ] && [ -f /usr/bin/otaupd.bck ] &&
       [ ! -e /usr/bin/otav3 ]; then
        printf 'ota=blocked\n' >> "$RESULT"
    else fail 'The firmware update block needs inspection.'; fi

    epoch=$(date +%s)
    rtc_epoch=$(cat /sys/class/rtc/rtc0/since_epoch)
    case "$rtc_epoch" in ''|*[!0-9]*) fail 'RTC clock could not be read.' ;; esac
    delta=$((epoch - rtc_epoch))
    [ "$delta" -ge -5 ] && [ "$delta" -le 5 ] || fail 'The RTC and system clocks disagree.'
    printf 'rtc_clock=passed\n' >> "$RESULT"

    load_settings
    OLD_LIGHT=$(lipc-get-prop com.lab126.powerd flIntensity 2>/dev/null)
    OLD_SAVER=$(lipc-get-prop com.lab126.powerd preventScreenSaver 2>/dev/null)
    OLD_WIRELESS=$(lipc-get-prop com.lab126.cmd wirelessEnable 2>/dev/null)
    case "$OLD_WIRELESS" in 0|1) ;; *) OLD_WIRELESS=1 ;; esac
    CHANGED_POWER=1
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1 || fail 'Screensaver control failed.'
    lipc-set-prop com.lab126.powerd flIntensity 0 >/dev/null 2>&1 || fail 'Frontlight control failed.'
    STOPPED=1
    stop framework >/dev/null 2>&1 || fail 'Could not enter weather display mode.'
    sleep 2
    paint 'WEATHER SETUP

Checking Wi-Fi and weather...

Next: a one-minute sleep test.
Leave the Kindle unplugged.' || fail 'Text rendering failed.'
    lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1 || fail 'Wi-Fi control failed.'
    waited=0
    while [ "$waited" -lt 25 ]; do
        [ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = CONNECTED ] && break
        sleep 1; waited=$((waited + 1))
    done
    [ "$waited" -lt 25 ] || fail 'Wi-Fi did not connect. Check the saved network.'
    printf 'wifi=passed\n' >> "$RESULT"
    # Fetch forecast, current temperature and hourly strip to certify access.
    /bin/sh "$BASE/dashboard.sh" --refresh || fail 'Forecast download or parsing failed.'
    [ -s "$STATE/current.txt" ] || fail 'Hourly temperature data is missing.'
    printf 'weather=passed\n' >> "$RESULT"
    wake_daily=$(/bin/sh "$BASE/runtime.sh" --schedule "$(date +%s)") || fail 'Local midnight scheduling failed.'
    printf 'daily_wake=%s\n' "$wake_daily" >> "$RESULT"
    /bin/sh "$BASE/dashboard.sh" --cached > "$STATE/setup-screen.txt"
    paint "$(cat "$STATE/setup-screen.txt")

SETUP: sleeping for one minute.
Leave it untouched until it
asks you to press Power." || fail 'Forecast text rendering failed.'
    lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1 || fail 'Could not switch Wi-Fi off.'
    printf '0\n' > "$RTC" || fail 'Could not clear the RTC alarm.'
    before=$(date +%s); target=$((before + 60))
    printf '%s\n' "$target" > "$RTC" || fail 'Could not arm the RTC alarm.'
    printf 'sleep_start=%s\nsleep_target=%s\n' "$before" "$target" >> "$RESULT"
    sync
    printf 'mem\n' > "$POWER" || fail 'Suspend failed.'
    after=$(date +%s)
    printf 'sleep_end=%s\n' "$after" >> "$RESULT"
    elapsed=$((after - before))
    [ "$elapsed" -ge 55 ] && [ "$elapsed" -le 90 ] || fail 'The Kindle did not wake at the planned time.'
    printf 'sleep=passed\n' >> "$RESULT"
    # Test Wi-Fi reconnect after the timed wake, then turn it off again.
    lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1 || fail 'Wi-Fi could not be re-enabled after sleep.'
    waited=0
    while [ "$waited" -lt 25 ]; do
        [ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = CONNECTED ] && break
        sleep 1; waited=$((waited + 1))
    done
    [ "$waited" -lt 25 ] || fail 'Wi-Fi did not reconnect after sleep.'
    printf 'resume_wifi=passed\n' >> "$RESULT"
    lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
    rm -f "$STATE/setup-power.txt"
    : > "$STATE/setup-input.txt"
    setsid /bin/sh "$BASE/device-setup.sh" read-power & INPUT_PID=$!
    paint 'WEATHER: SLEEP CHECK PASSED

Press the power button ONCE
within the next 45 seconds.

This finishes the button test
and returns to the Library.

Then reconnect the USB cable.' || fail 'Wake text rendering failed.'
    waited=0
    while [ "$waited" -lt 45 ]; do
        [ -s "$STATE/setup-power.txt" ] && break
        sleep 1; waited=$((waited + 1))
    done
    [ -s "$STATE/setup-power.txt" ] || fail 'Power-button test was not completed.'
    cat "$STATE/setup-power.txt" >> "$RESULT"
    printf 'result=passed\n' >> "$RESULT"
    printf 'Weather hardware checks passed at %s\n' "$(date -u)" > "$STATE/hardware-verified"
    printf 'Weather setup checks passed.\nOpen Weather from the Library.\n' \
        > '/mnt/us/documents/Weather setup complete.txt'
}

case "${1:-}" in
    run) run ;;
    read-power) read_power ;;
    *) exit 2 ;;
esac
