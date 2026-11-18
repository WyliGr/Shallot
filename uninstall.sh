#!/bin/sh
# Shallot uninstaller - removes the auto-sync hook and (optionally) the app.
#   sh uninstall.sh          # remove hook + app entry, keep data (saves/backups)
#   sh uninstall.sh --purge  # also delete /mnt/SDCARD/App/Shallot entirely

set -u
SDROOT="${SHALLOT_FAKE_SD:-/mnt/SDCARD}"
appdir="${SDROOT}/App/Shallot"
netscript="${SDROOT}/.tmp_update/script/network/update_networking.sh"
HOOK_BEGIN="# shallot:auto-sync (added by Shallot installer)"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

# 1. remove hook lines (marker block) from update_networking.sh
if [ -f "${netscript}" ] && grep -qF "${HOOK_BEGIN}" "${netscript}"; then
    sed -i "/^${HOOK_BEGIN}$/,/^# shallot:auto-sync (end)$/d" "${netscript}"
    sync
    echo "[shallot] auto-sync hook removed"
fi

# 2. remove app
if [ "${PURGE}" = "1" ]; then
    rm -rf "${appdir}"
    echo "[shallot] ${appdir} deleted (backups and config gone)"
else
    rm -f "${appdir}/config.json"
    echo "[shallot] app entry removed; kept ${appdir} (config + backups)"
fi

echo "[shallot] done. Your saves on the SD card were never touched."
