#!/bin/sh
# Shallot installer - run ON the Miyoo (SSH console) or from the SD card itself.
#   sh install.sh [--token rmm_XXXX] [--url https://romm.example.com]
#
# What it does:
#   1. installs Shallot into /mnt/SDCARD/App/Shallot (this repo's files)
#   2. creates shallot.conf if missing (prompts or takes --url/--token)
#   3. registers the device in RomM and stores the device id
#   4. wires the auto-sync hook into Onion's update_networking.sh (idempotent)
#   5. creates the Apps menu entry
#
# Re-run this installer after each Onion firmware update (the update overwrites
# the networking script). Re-running is safe: everything is idempotent.

set -u

here=$(dirname "$0")
SDROOT="${SHALLOT_FAKE_SD:-/mnt/SDCARD}"
sysdir="${SDROOT}/.tmp_update"
appdir="${SDROOT}/App/Shallot"
netscript="${sysdir}/script/network/update_networking.sh"
HOOK_BEGIN="# shallot:auto-sync (added by Shallot installer)"
HOOK_END="# shallot:auto-sync (end)"

URL=""; TOKEN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --url)   URL="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

step() { printf '\n[shallot] %s\n' "$1"; }

# 1. files -------------------------------------------------------------------
step "installing Shallot to ${appdir}"
mkdir -p "${appdir}" "${appdir}/data" "${appdir}/data/backups" "${appdir}/data/tmp"
for f in shallot.sh shallot-app.sh launch.sh config.json; do
    [ -f "${here}/${f}" ] && cp -f "${here}/${f}" "${appdir}/${f}"
done
cp -f "${here}/launch.sh" "${appdir}/launch.sh" 2>/dev/null
chmod +x "${appdir}/shallot.sh" "${appdir}/shallot-app.sh" "${appdir}/launch.sh" 2>/dev/null
sync

# 2. config ------------------------------------------------------------------
if [ ! -f "${appdir}/shallot.conf" ]; then
    step "creating shallot.conf"
    if [ -z "${URL}" ]; then
        printf 'RomM URL (ex: https://romm.example.com): '
        read -r URL
    fi
    if [ -z "${TOKEN}" ]; then
        printf 'RomM Client API token (rmm_...): '
        read -r TOKEN
    fi
    cat > "${appdir}/shallot.conf" <<EOF
ROMM_URL='${URL}'
ROMM_TOKEN='${TOKEN}'
DEVICE_ID=''
ROMS_DIR='${SDROOT}/Roms'
SAVE_EXTS='srm sav'
SAVE_SLOT='autosave'
CONFLICT_POLICY='local'
BACKUPS='1'
KEEP_BACKUPS='3'
AUTOCLEANUP_LIMIT='10'
ROMMAP_TTL='86400'
CURL_TIMEOUT='20'
DOWNLOAD_PATH='/api/roms/%id%/download'
CURL_EXTRA=''
EOF
fi

# 3. register device ---------------------------------------------------------
if ! grep -q "^DEVICE_ID='..*'" "${appdir}/shallot.conf" 2>/dev/null; then
    step "registering device in RomM"
    devid=$(SHALLOT_SDCARD="${SDROOT}" SHALLOT_CONF="${appdir}/shallot.conf" \
        SHALLOT_STATE="${appdir}/data" sh "${appdir}/shallot.sh" register Miyoo 2>/dev/null | tail -n 1)
    if [ -n "${devid}" ] && [ "${devid}" != "" ]; then
        sed -i "s|^DEVICE_ID=.*|DEVICE_ID='${devid}'|" "${appdir}/shallot.conf"
        echo "[shallot] device id: ${devid}"
    else
        echo "[shallot] WARNING: registration failed - set DEVICE_ID by hand in shallot.conf"
    fi
fi

# 4. auto-sync hook ----------------------------------------------------------
if [ -f "${netscript}" ]; then
    if grep -qF "${HOOK_BEGIN}" "${netscript}" 2>/dev/null; then
        step "auto-sync hook already installed"
    else
        step "wiring auto-sync into update_networking.sh"
        cat >> "${netscript}" <<EOF

${HOOK_BEGIN}
if [ "\$1" = "check" ] && [ -f "${appdir}/data/autosync.enabled" ]; then
    "${appdir}/shallot.sh" sync --auto >/dev/null 2>&1 &
fi
${HOOK_END}
EOF
        sync
    fi
    # enable by default on first install
    [ -f "${appdir}/data/autosync.enabled" ] || touch "${appdir}/data/autosync.enabled"
else
    echo "[shallot] WARNING: ${netscript} not found - auto-sync not wired (manual app still works)"
fi

# 5. apps menu entry ---------------------------------------------------------
if [ ! -f "${appdir}/config.json" ]; then
    step "creating Apps menu entry"
    cat > "${appdir}/config.json" <<'EOF'
{
  "label": "Shallot",
  "icon": "../../Icons/Default/app/otaupdate.png",
  "iconsel": "../../Icons/Default/app/otaupdate.png",
  "launch": "launch.sh"
}
EOF
fi

printf '\n[shallot] done. Reboot the console: on next boot with WiFi the saves sync automatically.\n'
echo '[shallot] Manual run: Apps > Shallot, then open Shallot/report.txt in File Explorer.'
