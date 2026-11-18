#!/bin/sh
# Shallot test suite: runs the sync engine against a local mock RomM.
# Usage: sh test/run-tests.sh   (runs under dash AND busybox sh for firmware parity)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "${HERE}")
REPO=${SHALLOT_REPO:-${ROOT}}
SH="${SHALLOT_SH:-sh}"
T=$(mktemp -d /tmp/shallot-test.XXXXXX)
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

SD="${T}/sd"
APPDIR="${SD}/App/Shallot"
STATE="${APPDIR}/data"
ROMS="${SD}/Roms"
CONF="${APPDIR}/shallot.conf"

export SHALLOT_SDCARD="${SD}"
export SHALLOT_CONF="${CONF}"
export SHALLOT_STATE="${STATE}"

PASS=0; FAIL=0
SHELLBIN="$REPO/shallot.sh"

mkdir -p "${ROMS}/SFC" "${ROMS}/GBA" "${STATE}"

# dummy ROM files so the rommap widener matches (fresh device, no saves yet)
printf 'ROM' > "${ROMS}/SFC/Zelda (USA).sfc"
printf 'ROM' > "${ROMS}/SFC/Mario.sfc"

write_conf() {
    cat > "${CONF}" <<EOF
ROMM_URL='http://127.0.0.1:${PORT}'
ROMM_TOKEN='rmm_testtoken123'
DEVICE_ID='${DEVICE_ID}'
ROMS_DIR='${ROMS}'
SAVE_EXTS='srm sav'
CONFLICT_POLICY='local'
BACKUPS='1'
KEEP_BACKUPS='3'
EOF
}

# helpers -------------------------------------------------------------------
ok()   { PASS=$(( PASS + 1 )); printf '  ok  - %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf '  FAIL - %s\n' "$1"; }
assert_eq() { # desc a b
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got: $2, want: $3)"; fi
}
assert_contains() {
    case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 (missing: $3)" ;; esac
}
mock_state_field() { # python path into /api/_state
    curl -s -H "Authorization: Bearer rmm_testtoken123" "http://127.0.0.1:${PORT}/api/_state" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# setup ---------------------------------------------------------------------
mkdir -p "${APPDIR}"
cat > "${STATE}/platforms.map" <<EOF
nes=NES
EOF
DEVICE_ID='dev-mock'
write_conf

python3 "${REPO}/test/mock-romm.py" "${PORT}" &
MOCK_PID=$!
trap 'kill ${MOCK_PID} 2>/dev/null; rm -rf "${T}"' EXIT INT TERM
i=0
while [ "${i}" -lt 50 ]; do
    if curl -s -o /dev/null -H "Authorization: Bearer rmm_testtoken123" \
        "http://127.0.0.1:${PORT}/api/heartbeat"; then break; fi
    i=$(( i + 1 )); sleep 0.2
done

printf '\n== Shallot test suite (shell: %s, mock port %s) ==\n' "${SH}" "${PORT}"

# 1. config check -----------------------------------------------------------
out=$("${SHELLBIN}" check-config 2>&1)
assert_contains "check-config reports reachable" "${out}" "reachable"

# 2. first sync: server save for rom 123 downloads to the platform dir ------
out=$("${SHELLBIN}" sync 2>&1)
assert_contains "first sync reports a download" "${out}" "1 downloaded"
assert_eq "downloaded save has server content" "$(cat "${ROMS}/SFC/Zelda (USA).srm")" "SERVER-SAVE-V1"
assert_eq "second sync is a no-op" "$("${SHELLBIN}" sync 2>&1)" \
    "Sync finished: 0 uploaded, 0 downloaded, 0 conflicts, 0 errors."

# 3. local new save uploads -------------------------------------------------
printf 'LOCAL-SAVE-MARIO' > "${ROMS}/SFC/Mario.srm"
out=$("${SHELLBIN}" sync 2>&1)
assert_contains "new local save uploads" "${out}" "1 uploaded"
assert_eq "mock stored mario save" "$(mock_state_field 'd["saves"].get("124/autosave", {}).get("content_hash")')" \
    "$(md5sum "${ROMS}/SFC/Mario.srm" | cut -d" " -f1)"
assert_eq "re-sync after upload is a no-op" "$("${SHELLBIN}" sync 2>&1)" \
    "Sync finished: 0 uploaded, 0 downloaded, 0 conflicts, 0 errors."

# 4. conflict (both sides changed): policy=local pushes the local copy -------
printf 'LOCAL-SAVE-ZELDA-V2' > "${ROMS}/SFC/Zelda (USA).srm"
# simulate: another device overwrote the server save while we were playing
python3 - "${PORT}" <<'EOF'
import sys, urllib.request
port = sys.argv[1]
content = b"SERVER-SAVE-V2"
boundary = "testbnd"
body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"saveFile\"; "
        f"filename=\"Zelda (USA).srm\"\r\n\r\n").encode() + content + f"\r\n--{boundary}--\r\n".encode()
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/api/saves?rom_id=123&slot=autosave&overwrite=true",
    data=body, method="POST",
    headers={"Authorization": "Bearer rmm_testtoken123",
             "Content-Type": f"multipart/form-data; boundary={boundary}"})
urllib.request.urlopen(req)
EOF
out=$("${SHELLBIN}" sync 2>&1)
assert_contains "conflict detected" "${out}" "1 conflicts"
assert_contains "policy=local pushes local copy" "${out}" "1 uploaded"
assert_eq "local copy preserved by policy=local" "$(cat "${ROMS}/SFC/Zelda (USA).srm")" "LOCAL-SAVE-ZELDA-V2"
assert_eq "server now holds the local copy" "$(mock_state_field 'd["saves"].get("123/autosave", {}).get("content_hash")')" \
    "$(md5sum "${ROMS}/SFC/Zelda (USA).srm" | cut -d" " -f1)"

# 5. server-newer save downloads (device baseline current after the upload) --
python3 - "${PORT}" <<'EOF'
import sys, urllib.request
port = sys.argv[1]
content = b"SERVER-SAVE-V3"
boundary = "testbnd"
body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"saveFile\"; "
        f"filename=\"Zelda (USA).srm\"\r\n\r\n").encode() + content + f"\r\n--{boundary}--\r\n".encode()
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/api/saves?rom_id=123&slot=autosave&overwrite=true",
    data=body, method="POST",
    headers={"Authorization": "Bearer rmm_testtoken123",
             "Content-Type": f"multipart/form-data; boundary={boundary}"})
urllib.request.urlopen(req)
EOF
out=$("${SHELLBIN}" sync 2>&1)
assert_contains "server-newer save downloads" "${out}" "1 downloaded"
assert_eq "local now holds server v3" "$(cat "${ROMS}/SFC/Zelda (USA).srm")" "SERVER-SAVE-V3"
n_bak=$(ls "${STATE}/backups/"*/'Zelda (USA).srm'.*.bak 2>/dev/null | wc -l)
[ "${n_bak}" -ge 1 ] && ok "backup created before overwrite" || fail "no backup created"

# 6. status json ------------------------------------------------------------
status=$("${SHELLBIN}" status)
assert_contains "status carries counters" "${status}" '"errors"'

# 7. rom installs: queued rom 125 downloads into mapped folder ---------------
out=$("${SHELLBIN}" roms claim 2>&1)
assert_contains "install claimed and done" "${out}" "installed DK.nes -> Roms/NES"
[ -f "${ROMS}/NES/DK.nes" ] && ok "rom file present" || fail "rom file missing"
assert_eq "install marked done" "$(mock_state_field '[r["status"] for r in d["installs"]][0]')" "done"

# 8. auto mode: offline server exits quietly --------------------------------
cat > "${CONF}" <<EOF
ROMM_URL='http://127.0.0.1:9'
ROMM_TOKEN='rmm_testtoken123'
DEVICE_ID='${DEVICE_ID}'
ROMS_DIR='${ROMS}'
EOF
out=$("${SHELLBIN}" sync --auto 2>&1)
code=$?
assert_eq "auto mode offline exits 0 silently" "${code}" "0"
assert_eq "auto mode prints nothing" "${out}" ""

# 9. unmapped save is logged, not fatal -------------------------------------
write_conf
printf 'STRAY' > "${ROMS}/GBA/Unknown Game.srm"
out=$("${SHELLBIN}" sync 2>&1)
code=$?
assert_eq "unmapped save does not fail the sync" "${code}" "0"
assert_contains "unmapped save logged" "$(cat "${STATE}/last-sync.log")" "no RomM match"

# 10. path-with-spaces save round-trips (already covered) + bad auth ---------
cat > "${CONF}" <<EOF
ROMM_URL='http://127.0.0.1:${PORT}'
ROMM_TOKEN='rmm_wrong'
DEVICE_ID='${DEVICE_ID}'
ROMS_DIR='${ROMS}'
EOF
out=$("${SHELLBIN}" sync 2>&1)
code=$?
assert_eq "bad token fails loudly" "${code}" "1"
assert_contains "bad token message" "${out}" "negotiate failed"

# 11. installer wires app + hook on a fake SD --------------------------------
FAKE="${T}/fakesd"
mkdir -p "${FAKE}/.tmp_update/script/network" "${FAKE}/Roms"
printf '#!/bin/sh\nsysdir=/mnt/SDCARD/.tmp_update\nmain() { echo net "$1"; }\nmain "$@"\n' \
    > "${FAKE}/.tmp_update/script/network/update_networking.sh"
out=$(SHALLOT_FAKE_SD="${FAKE}" sh "${REPO}/install.sh" --url "http://127.0.0.1:${PORT}" --token rmm_testtoken123 2>&1)
[ -f "${FAKE}/App/Shallot/config.json" ] && ok "installer created Apps entry" || fail "no Apps entry"
[ -f "${FAKE}/App/Shallot/shallot.conf" ] && ok "installer created shallot.conf" || fail "no shallot.conf"
assert_contains "installer registered the device" \
    "$(grep '^DEVICE_ID' "${FAKE}/App/Shallot/shallot.conf")" "dev-miyoo"
n_hooks=$(grep -c "shallot:auto-sync (added by Shallot installer)" \
    "${FAKE}/.tmp_update/script/network/update_networking.sh")
assert_eq "hook installed exactly once" "${n_hooks}" "1"
[ -f "${FAKE}/App/Shallot/data/autosync.enabled" ] && ok "autosync enabled by default" || fail "autosync flag missing"

# 12. idempotent re-run -------------------------------------------------------
SHALLOT_FAKE_SD="${FAKE}" sh "${REPO}/install.sh" --url "http://127.0.0.1:${PORT}" --token rmm_testtoken123 >/dev/null 2>&1
n_hooks=$(grep -c "shallot:auto-sync (added by Shallot installer)" \
    "${FAKE}/.tmp_update/script/network/update_networking.sh")
assert_eq "re-run does not duplicate the hook" "${n_hooks}" "1"

# 13. uninstall removes the hook, keeps data; purge deletes everything -------
SHALLOT_FAKE_SD="${FAKE}" sh "${REPO}/uninstall.sh" >/dev/null 2>&1
n_hooks=$(grep -c "shallot:auto-sync" "${FAKE}/.tmp_update/script/network/update_networking.sh")
assert_eq "uninstall removed the hook" "${n_hooks}" "0"
[ ! -f "${FAKE}/App/Shallot/config.json" ] && ok "uninstall removed Apps entry" || fail "Apps entry still there"
[ -f "${FAKE}/App/Shallot/shallot.conf" ] && ok "uninstall kept config" || fail "config deleted without purge"
SHALLOT_FAKE_SD="${FAKE}" sh "${REPO}/uninstall.sh" --purge >/dev/null 2>&1
[ ! -d "${FAKE}/App/Shallot" ] && ok "purge deleted the app dir" || fail "app dir still present"

# ---------------------------------------------------------------------------
printf '\n== results: %d passed, %d failed ==\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
