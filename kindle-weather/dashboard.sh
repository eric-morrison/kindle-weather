#!/bin/sh
# Network refresh and text layout; runtime.sh manages hardware power.
BASE=${WEATHER_BASE:-/mnt/us/weather}
. "$BASE/common.sh" || exit 1
load_settings

refresh() {
    NOTICE=
    if [ ! -s "$STATE/location.txt" ]; then set_zip "$ZIP" || return 1; fi
    LAT=$(sed -n '1p' "$STATE/location.txt")
    LON=$(sed -n '2p' "$STATE/location.txt")
    URL="https://api.open-meteo.com/v1/forecast?latitude=$LAT&longitude=$LON&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum&hourly=temperature_2m,weather_code,precipitation_probability,is_day&current=temperature_2m,weather_code&temperature_unit=fahrenheit&precipitation_unit=inch&timezone=auto&forecast_days=2&forecast_hours=7"
    weather_ok=0
    if fetch "$URL" "$STATE/forecast-new.json" &&
       awk -v mode=forecast -f "$PARSER" "$STATE/forecast-new.json" > "$STATE/forecast-new.txt" &&
       awk -v mode=clock -f "$PARSER" "$STATE/forecast-new.json" > "$STATE/clock-new.txt"; then
        if awk -v mode=current -f "$PARSER" "$STATE/forecast-new.json" > "$STATE/current-new.txt" &&
           awk -v mode=hourly -f "$PARSER" "$STATE/forecast-new.json" > "$STATE/hourly-new.txt"; then
            mv "$STATE/forecast-new.txt" "$STATE/forecast.txt"
            mv "$STATE/clock-new.txt" "$STATE/clock.txt"
            mv "$STATE/current-new.txt" "$STATE/current.txt"
            mv "$STATE/hourly-new.txt" "$STATE/hourly.txt"
            date +%s > "$STATE/forecast-time"
            weather_ok=1
        fi
    fi
    [ "$weather_ok" = 1 ] || NOTICE='Update failed; last data shown.'
    if fetch "https://api.weather.gov/alerts/active?point=$LAT,$LON" "$STATE/alerts-new.json" &&
       awk -v mode=alerts -f "$PARSER" "$STATE/alerts-new.json" > "$STATE/alerts-new.txt"; then
        mv "$STATE/alerts-new.txt" "$STATE/alerts.txt"
        date +%s > "$STATE/alerts-time"
        rm -f "$STATE/alerts-failed"
    else
        touch "$STATE/alerts-failed"
    fi
    printf '%s\n' "$NOTICE" > "$STATE/notice"
    [ "$weather_ok" = 1 ]
}

screen() {
    /bin/sh "$BASE/display.sh" --text
}

case "${1:-}" in
    --print) refresh; result=$?; screen; exit "$result" ;;
    --cached) screen ;;
    --refresh) refresh ;;
    *) exit 2 ;;
esac
