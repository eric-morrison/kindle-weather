#!/bin/sh
# Name: Weather Settings
# DontUseFBInk
# Author: PaperWhite
# Description: Change the weather ZIP on this Kindle.
KTERM=/mnt/us/extensions/kterm
if [ ! -x "$KTERM/bin/kterm" ] || [ ! -f /mnt/us/weather/settings.sh ]; then
    printf 'Weather files or kTerm are missing.\n' > '/mnt/us/documents/Weather setup error.txt'
    exit 1
fi
/bin/sh /mnt/us/weather/runtime.sh stop
export TERM=xterm TERMINFO="$KTERM/vte/terminfo"
exec "$KTERM/bin/kterm" -l "$KTERM/layouts/keyboard-300dpi.xml" \
    -c 0 -k 1 -s 20 -e '/bin/sh /mnt/us/weather/settings.sh' \
    2>> /mnt/us/weather/state/settings.log
