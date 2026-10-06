#!/bin/sh
# Name: Weather Setup
# DontUseFBInk
# Author: PaperWhite
# Description: Check weather access, test a one-minute sleep, and verify power-button exit.
BASE=/mnt/us/weather
nohup setsid /bin/sh "$BASE/device-setup.sh" run >> "$BASE/state/setup.log" 2>&1 < /dev/null &
