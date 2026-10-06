#!/bin/sh
# Text and TrueType layout share the same cached values. No network access here.
BASE=${WEATHER_BASE:-/mnt/us/weather}
. "$BASE/common.sh" || exit 1
load_settings

load_display() {
    CITY=$(sed -n '3p' "$STATE/location.txt" 2>/dev/null)
    [ -n "$CITY" ] || CITY='Weather unavailable'
    HIGH=$(sed -n 's/^High: *\([-0-9]*\) F$/\1/p' "$STATE/forecast.txt" 2>/dev/null)
    LOW=$(sed -n 's/^Low: *\([-0-9]*\) F$/\1/p' "$STATE/forecast.txt" 2>/dev/null)
    # Also format older cached descriptions before the next successful download.
    CONDITIONS=$(sed -n 's/^Conditions: //p' "$STATE/current.txt" 2>/dev/null | awk '
        { for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }')
    [ -n "$CONDITIONS" ] || CONDITIONS='Unavailable'
    [ -n "$HIGH" ] || HIGH='--'
    [ -n "$LOW" ] || LOW='--'
    NOW=
    if [ "$HOURLY" = 1 ]; then
        NOW=$(sed -n 's/^Now: *\([-0-9]*\) F$/\1/p' "$STATE/current.txt" 2>/dev/null)
    fi
    [ -n "$NOW" ] || NOW='--'
    ALERTS=
    if [ -s "$STATE/alerts.txt" ] && ! grep -qx 'No active weather alerts' "$STATE/alerts.txt"; then
        ALERTS=$(cat "$STATE/alerts.txt")
    fi
    NOTICE=
    [ ! -s "$STATE/notice" ] || NOTICE=$(cat "$STATE/notice")
    BATTERY_STATUS=
    percent=$(cat "$STATE/battery-percent" 2>/dev/null)
    case "$percent" in
        ''|*[!0-9]*) ;;
        *) if [ "$percent" -lt 20 ]; then
               BATTERY_STATUS="Low battery — $percent%"
           elif [ "$percent" = 100 ] && [ "$(cat "$STATE/battery-charging" 2>/dev/null)" = 1 ]; then
               BATTERY_STATUS='Charged'
           fi ;;
    esac
}

text_screen() {
    printf '%s\nCurrently %s\n%s\n\nLOW     HIGH\n%s      %s\n' "$CITY" "$CONDITIONS" "$NOW" "$LOW" "$HIGH"
    [ ! -s "$STATE/hourly.txt" ] || { printf '\n'; cat "$STATE/hourly.txt"; }
    [ -z "$ALERTS" ] || printf '\n%s\n' "$ALERTS"
    [ -z "$NOTICE" ] || printf '\n%s\n' "$NOTICE"
    [ -z "$BATTERY_STATUS" ] || printf '\n%s\n' "$BATTERY_STATUS"
}

band() {
    # FBInk margins are distances from the four edges, in pixels.
    # Batch all text in the framebuffer, then flash the complete frame once.
    px=$1; top=$2; left=$3; width=$4; height=$5; face=$6; content=$7
    [ -n "$content" ] || return 0
    "$FBINK" -q -b -m -t "regular=$BASE/fonts/LiberationSans-$face.ttf,px=$px,top=$top,bottom=$((1448-top-height)),left=$left,right=$((1072-left-width)),notrunc" "$content"
}

symbol_band() {
    "$FBINK" -q -b -m -t "regular=$BASE/fonts/NotoSansSymbols2-Regular.ttf,px=$1,top=$2,bottom=$((1448-$2-$5)),left=$3,right=$((1072-$3-$4)),notrunc" "$6"
}

paint() {
    "$FBINK" -q -b -k || return 1
    # A long city name may wrap; its header has room for two lines.
    band 68 90 48 976 150 Regular "$CITY" || return 1
    band 54 260 48 976 85 Regular "Currently $CONDITIONS" || return 1
    band 256 365 48 976 280 Bold "$NOW" || return 1
    band 44 655 48 464 65 Regular 'LOW' || return 1
    band 44 655 560 464 65 Regular 'HIGH' || return 1
    # Keep both temperatures equally large; shrink only for unusually long values.
    digits=${#HIGH}
    [ "${#LOW}" -le "$digits" ] || digits=${#LOW}
    number_px=184
    [ "$digits" -lt 4 ] || number_px=164
    band "$number_px" 720 48 464 200 Bold "$LOW" || return 1
    band "$number_px" 720 560 464 200 Bold "$HIGH" || return 1
    hourly_strip || return 1
    # Alerts are exceptional, and only occupy space when active.
    # Collapse the parser's narrow bitmap-era wrapping before proportional type.
    alerts_wide=$(printf '%s\n' "$ALERTS" | tr '\n' ' ')
    band 24 1240 48 976 84 Bold "$alerts_wide" || return 1
    # Keep a failed connection visible instead of presenting old data as fresh.
    band 28 1330 32 1008 38 Regular "$NOTICE" || return 1
    band 34 1380 32 1008 48 Regular "$BATTERY_STATUS" || return 1
    "$FBINK" -q -f -w -s
}

hourly_strip() {
    [ -s "$STATE/hourly.txt" ] || return 0
    # Use more breathing room on ordinary days; retain the alert band's space.
    shift_down=40
    [ -z "$ALERTS" ] || shift_down=0
    column=0
    while IFS='|' read -r hour temp icon rain; do
        [ "$column" -lt 6 ] || break
        left=$((44 + column * 164))
        band 32 "$((1000+shift_down))" "$left" 164 40 Regular "$hour" || return 1
        symbol_band 90 "$((1042+shift_down))" "$left" 164 90 "$icon" || return 1
        band 46 "$((1140+shift_down))" "$left" 164 55 Bold "$temp" || return 1
        # Center the drop and percentage together, including three-digit rain chances.
        rain_width=$((12 + ${#rain} * 15))
        rain_left=$((left + (164-30-rain_width)/2))
        symbol_band 28 "$((1196+shift_down))" "$rain_left" 24 38 '🌢' || return 1
        band 30 "$((1195+shift_down))" "$((rain_left+30))" "$rain_width" 40 Regular "$rain" || return 1
        column=$((column+1))
    done < "$STATE/hourly.txt"
}

load_display
case "${1:-}" in
    --text) text_screen ;;
    --paint) FBINK=$2; [ -x "$FBINK" ] || exit 1; paint ;;
    *) exit 2 ;;
esac
