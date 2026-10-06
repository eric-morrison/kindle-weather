#!/bin/sh
BASE=${WEATHER_BASE:-/mnt/us/weather}
. "$BASE/common.sh" || exit 1
load_settings
if [ "${1:-}" = --setup ]; then
    while ! valid_zip "$ZIP"; do
        printf '\033[2J\033[HWEATHER SETUP\n\n'
        printf 'Connect to Wi-Fi in Kindle Settings first.\n\n'
        printf 'Enter your five-digit US ZIP code.\nQ + Enter cancels setup.\n\n%s\nZIP: ' "$NOTICE"
        IFS= read -r candidate || exit 0
        case "$candidate" in q|Q) exit 0 ;; esac
        set_zip "$candidate"
    done
    exit 0
fi
while :; do
    printf '\033[2J\033[HWEATHER SETTINGS\n\n'
    printf 'ZIP: %s\n' "$ZIP"
    printf '\n1  Change ZIP\nQ  Save and close\n\n%s\n> ' "$NOTICE"
    IFS= read -r choice || exit 0
    NOTICE=
    case "$choice" in
        1)
            printf 'New five-digit ZIP: '
            IFS= read -r candidate || exit 0
            set_zip "$candidate"
            ;;
        q|Q)
            printf '%s settings closed\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STATE/settings-events.txt"
            exit 0 ;;
        *) NOTICE='Choose 1 or Q, then press Enter.' ;;
    esac
done
