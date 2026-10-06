#!/bin/sh
# The fresh-install path: ZIP keyboard, hardware check, then wall display.
BASE=${WEATHER_BASE:-/mnt/us/weather}
. "$BASE/common.sh" || exit 1
load_settings
KTERM=/mnt/us/extensions/kterm
if ! valid_zip "$ZIP"; then
    [ -x "$KTERM/bin/kterm" ] || exit 1
    export TERM=xterm TERMINFO="$KTERM/vte/terminfo"
    "$KTERM/bin/kterm" -l "$KTERM/layouts/keyboard-300dpi.xml" \
        -c 0 -k 1 -s 20 -e '/bin/sh /mnt/us/weather/settings.sh --setup' \
        2>> "$STATE/settings.log"
    load_settings
    valid_zip "$ZIP" || exit 0
fi
if [ ! -f "$STATE/hardware-verified" ]; then
    /bin/sh "$BASE/device-setup.sh" run >> "$STATE/setup.log" 2>&1 || exit 1
    [ -f "$STATE/hardware-verified" ] || exit 1
fi
exec /bin/sh "$BASE/runtime.sh" start
