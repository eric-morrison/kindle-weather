#!/bin/sh
# Name: Weather Device Check
# DontUseFBInk
# Author: PaperWhite
# Description: Save device capabilities and update-block status for setup.
BASE=/mnt/us/weather
REPORT='/mnt/us/documents/Weather device report.txt'
{
    date -u
    id
    uname -a
    cat /etc/prettyversion.txt
    printf '\nBATTERY / WIFI / POWER\n'
    lipc-get-prop com.lab126.powerd battLevel
    lipc-get-prop com.lab126.powerd flIntensity
    lipc-get-prop com.lab126.powerd preventScreenSaver
    lipc-get-prop com.lab126.cmd wirelessEnable
    lipc-get-prop com.lab126.wifid cmState
    cat /sys/power/state
    ls -l /sys/class/rtc/rtc0/wakealarm
    cat /sys/class/rtc/rtc0/since_epoch
    date +%s
    printf '\nINPUT DEVICES\n'
    cat /proc/bus/input/devices
    printf '\nFRAMEBUFFER / TOOLS\n'
    /usr/sbin/eips -i
    for tool in setsid nohup stop start lipc-get-prop lipc-set-prop dd od curl awk; do command -v "$tool"; done
    for binary in /var/local/kmc/bin/fbink /mnt/us/libkh/bin/fbink /usr/bin/fbink; do
        if [ -x "$binary" ]; then "$binary" --help | head -4; fi
    done
    printf '\nSERVICE STATUS\n'
    df -h /mnt/us /var/local
    initctl status framework
    initctl status otaupd
    printf '\nUPDATE BLOCKING\n'
    ls -l /usr/bin/otaupd*
    lsattr /usr/bin/otaupd* 2>/dev/null
    ls -ld /var/local/kmc
    printf '\nDAILY SCHEDULER\n'
    WEATHER_BASE="$BASE" /bin/sh "$BASE/runtime.sh" --schedule "$(date +%s)"
} > "$REPORT" 2>&1
/mnt/us/libkh/bin/fbink -m -y 8 'Device report saved. Reconnect USB for setup.' >/dev/null 2>&1
