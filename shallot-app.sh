#!/bin/sh
# Shallot - one-shot Onion app action (launched from the Apps menu).
# Runs a save sync, pulls queued ROM installs, and writes a human-readable
# report next to the app (Shallot/report.txt) - readable with File Explorer.
appdir=$(dirname "$0")
sdcard=$(dirname "$(dirname "$appdir")")

touch /tmp/stay_awake
export SHALLOT_SDCARD="${SHALLOT_SDCARD:-${sdcard}}"
export SHALLOT_CONF="${SHALLOT_CONF:-${appdir}/shallot.conf}"
export SHALLOT_STATE="${SHALLOT_STATE:-${appdir}/data}"

report="${appdir}/report.txt"
shallot="${appdir}/shallot.sh"

{
    echo "Shallot report - $(date '+%F %T')"
    echo "----------------------------------------"
    echo ""
    echo "[saves]"
    sh "${shallot}" sync 2>&1
    echo ""
    echo "[rom installs]"
    sh "${shallot}" roms claim 2>&1
    echo ""
    echo "[status]"
    sh "${shallot}" status 2>&1
} > "${report}" 2>&1

sync
rm -f /tmp/stay_awake
