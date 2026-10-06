#!/bin/sh
# Configuration is validated data; never source user-editable settings.
BASE=${WEATHER_BASE:-/mnt/us/weather}
STATE=$BASE/state
export LC_ALL=C
export PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin"
mkdir -p "$STATE" || exit 1
PARSER=$BASE/weather-json.awk
NOTICE=

valid_zip() {
    case "$1" in [0-9][0-9][0-9][0-9][0-9]) return 0 ;; *) return 1 ;; esac
}

load_settings() {
    ZIP=; HOURLY=1
    if [ -s "$STATE/zip" ]; then
        saved=$(cat "$STATE/zip"); valid_zip "$saved" && ZIP=$saved
    fi
    return 0
}

fetch() {
    curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 \
        --user-agent 'PaperWhite personal weather display' \
        "$1" -o "$2" 2>"$STATE/network-error.txt"
}

set_zip() {
    candidate=$1
    valid_zip "$candidate" || { NOTICE='Enter a five-digit US ZIP code.'; return 1; }
    if ! fetch "https://api.zippopotam.us/us/$candidate" "$STATE/location-new.json" ||
       ! awk -v mode=location -f "$PARSER" "$STATE/location-new.json" > "$STATE/location-new.txt"; then
        NOTICE='ZIP lookup failed. Check Wi-Fi or try another ZIP.'
        return 1
    fi
    mv "$STATE/location-new.txt" "$STATE/location.txt" || return 1
    printf '%s\n' "$candidate" > "$STATE/zip.new" || return 1
    mv "$STATE/zip.new" "$STATE/zip" || return 1
    rm -f "$STATE/forecast.txt" "$STATE/current.txt" "$STATE/hourly.txt" "$STATE/alerts.txt" \
        "$STATE/forecast-time" "$STATE/alerts-time" "$STATE/clock.txt" "$STATE/notice"
    ZIP=$candidate
    NOTICE='ZIP saved on this Kindle.'
    printf '%s ZIP=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$ZIP" >> "$STATE/settings-events.txt"
}

load_clock() {
    OFFSET=0; ZONE=
    if [ -s "$STATE/clock.txt" ]; then
        candidate=$(sed -n '1p' "$STATE/clock.txt")
        if printf '%s\n' "$candidate" | awk '/^-?[0-9]+$/ && $0 >= -43200 && $0 <= 50400 {ok=1} END {exit !ok}'; then
            OFFSET=$candidate
        fi
        candidate=$(sed -n '2p' "$STATE/clock.txt")
        case "$candidate" in
            *..*|*[!A-Za-z_/]*|'') ;;
            *) [ ! -f "$BASE/zoneinfo/$candidate" ] || ZONE=$candidate ;;
        esac
    fi
}

local_stamp() {
    stamp=$1
    case "$stamp" in ''|*[!0-9]*) printf 'unknown'; return ;; esac
    load_clock
    if [ -n "$ZONE" ]; then
        TZ=":$BASE/zoneinfo/$ZONE" date -d "@$stamp" '+%m-%d %H:%M' 2>/dev/null && return
        TZ=":$BASE/zoneinfo/$ZONE" date -r "$stamp" '+%m-%d %H:%M' 2>/dev/null && return
    fi
    printf 'epoch %s' "$stamp"
}

next_wake() {
    NOW=$1
    case "$NOW" in ''|*[!0-9]*) return 1 ;; esac
    # Every US ZIP's civil clock hour aligns with a UTC clock hour. Epoch
    # arithmetic also handles skipped/repeated civil hours at DST transitions.
    printf '%s\n' "$(( (NOW / 3600 + 1) * 3600 ))"
}
