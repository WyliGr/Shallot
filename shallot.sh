#!/bin/sh
# Shallot - RomM save-sync client for Onion OS (Miyoo Mini+).
# POSIX sh. Uses only tools shipped by Onion: curl, jq, md5sum, 7z.
#
# Subcommands:
#   sync [--auto]         bidirectional save sync against RomM (negotiate protocol)
#   roms claim            claim + download ROMs queued for this device in the RomM web UI
#   status                print the last sync report
#   register <name>       register this device in RomM (prints the device id)
#   check-config          validate configuration and connectivity, print a summary
#
# All paths are overridable through env vars so the engine can run/test on any
# Linux box without a Miyoo: SHALLOT_SDCARD, SHALLOT_CONF, SHALLOT_STATE.

set -u

VERSION="0.1.0"

# ---------------------------------------------------------------- paths ------
SDCARD="${SHALLOT_SDCARD:-/mnt/SDCARD}"
APPDIR="${SDCARD}/App/Shallot"
CONF="${SHALLOT_CONF:-${APPDIR}/shallot.conf}"
STATE="${SHALLOT_STATE:-${APPDIR}/data}"
LOG="${STATE}/last-sync.log"
STATUS_FILE="${STATE}/status.json"
LOCKDIR="${STATE}/lock"
TMPDIR_SH="${STATE}/tmp"
SYSBIN="/mnt/SDCARD/.tmp_update/bin"

# Onion ships curl + jq in its own bin dir; tests may point CURL/JQ elsewhere.
PATH="${SYSBIN}:${PATH}"
CURL="${SHALLOT_CURL:-curl}"
JQ="${SHALLOT_JQ:-jq}"

# ------------------------------------------------------------- defaults ------
ROMM_URL="${ROMM_URL:-}"
ROMM_TOKEN="${ROMM_TOKEN:-}"
DEVICE_ID="${DEVICE_ID:-}"
ROMS_DIR="${ROMS_DIR:-${SDCARD}/Roms}"
SAVE_EXTS="${SAVE_EXTS:-srm sav}"
SAVE_SLOT="${SAVE_SLOT:-autosave}"
CONFLICT_POLICY="${CONFLICT_POLICY:-local}"   # local | remote
BACKUPS="${BACKUPS:-1}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
AUTOCLEANUP_LIMIT="${AUTOCLEANUP_LIMIT:-10}"
ROMMAP_TTL="${ROMMAP_TTL:-86400}"
CURL_TIMEOUT="${CURL_TIMEOUT:-20}"
DOWNLOAD_PATH="${DOWNLOAD_PATH:-/api/roms/%id%/download}"
AUTOSYNC_FLAG="${STATE}/autosync.enabled"

if [ -f "${CONF}" ]; then
    . "${CONF}"
fi

# ---------------------------------------------------------------- utils ------
NOW_EPOCH() { date +%s; }
ISO_FROM_EPOCH() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "@$1"; }

say() { [ "${AUTO:-0}" = "1" ] || printf '%s\n' "$*"; }

logline() {
    mkdir -p "${STATE}" 2>/dev/null
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "${LOG}"
}

die() { logline "ERROR: $*"; say "Error: $*"; exit 1; }

file_hash() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
file_size() { stat -c '%s' "$1" 2>/dev/null || wc -c < "$1" | tr -d ' '; }
file_mtime() { stat -c '%Y' "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null || echo 0; }

stem_of() {
    base=$(basename "$1")
    printf '%s' "${base%.*}"
}

need_tools() {
    for bin in "${CURL}" "${JQ}" md5sum; do
        command -v "$bin" >/dev/null 2>&1 || die "missing tool: $bin (on a Miyoo, Onion's .tmp_update/bin must be reachable)"
    done
}

# ------------------------------------------------------------- http ----------
HTTP_CODE_FILE=""
HTTP_RESP_FILE=""

http_req() { # http_req METHOD PATH [BODY_FILE] [extra curl args...]
    method=$1; path=$2; body=${3:-}
    if [ $# -ge 3 ]; then shift 3; else shift 2; fi
    url="${ROMM_URL%/}${path}"
    hdr="Authorization: Bearer ${ROMM_TOKEN}"
    if [ -n "${body}" ]; then
        code=$("$CURL" -sS -m "${CURL_TIMEOUT}" -o "${HTTP_RESP_FILE}" -w '%{http_code}' \
            -H "${hdr}" -H 'Content-Type: application/json' \
            --data-binary "@${body}" -X "${method}" "$@" "${url}")
    elif [ "${method}" = "GET" ]; then
        code=$("$CURL" -sS -m "${CURL_TIMEOUT}" -o "${HTTP_RESP_FILE}" -w '%{http_code}' \
            -H "${hdr}" "$@" "${url}")
    else
        code=$("$CURL" -sS -m "${CURL_TIMEOUT}" -o "${HTTP_RESP_FILE}" -w '%{http_code}' \
            -H "${hdr}" -X "${method}" "$@" "${url}")
    fi
    printf '%s' "$code"
}

http_get()  { http_req GET  "$1"; }
http_post() { http_req POST "$1" "${2:-}"; }
http_put()  { http_req PUT  "$1" "${2:-}"; }

net_ready() {
    code=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "${ROMM_URL%/}/api/heartbeat" 2>/dev/null)
    [ "${code:-000}" != "000" ] || return 1
    return 0
}

# ------------------------------------------------------------- rom map -------
# Maps a save filename stem to a RomM rom id. Cache: STATE/rommap.tsv
rommap_fresh() {
    [ -f "${STATE}/rommap.tsv" ] || return 1
    [ -f "${STATE}/rommap.meta" ] || return 1
    fetched=$(cat "${STATE}/rommap.meta" 2>/dev/null || echo 0)
    [ $(( $(NOW_EPOCH) - fetched )) -lt "${ROMMAP_TTL}" ]
}

build_rommap() {
    # Paginate GET /api/roms and emit "rom_id<TAB>stem<TAB>fs_name" lines.
    tsv_tmp="${TMPDIR_SH}/rommap.tsv.$$"
    : > "${tsv_tmp}"
    offset=0
    page=500
    while :; do
        code=$(http_get "/api/roms?limit=${page}&offset=${offset}")
        [ "${code:-000}" = "200" ] || { rm -f "${tsv_tmp}"; die "RomM roms fetch failed (HTTP ${code})"; }
        count=$("${JQ}" 'length' "${HTTP_RESP_FILE}" 2>/dev/null || echo 0)
        [ "${count}" -gt 0 ] 2>/dev/null || break
        "${JQ}" -r '.[] | [.id, ((.fs_name // .name) | sub("\\.[^.]*$";"")), (.fs_name // .name)] | @tsv' \
            "${HTTP_RESP_FILE}" >> "${tsv_tmp}" 2>/dev/null
        [ "${count}" -lt "${page}" ] && break
        offset=$(( offset + page ))
    done
    mv "${tsv_tmp}" "${STATE}/rommap.tsv"
    NOW_EPOCH > "${STATE}/rommap.meta"
    echo "${STATE}/rommap.tsv"
}

rommap_path() {
    rommap_fresh || build_rommap >/dev/null
    printf '%s' "${STATE}/rommap.tsv"
}

rom_id_for_stem() {
    # rom_id_for_stem <stem> -> id (exact match first, then case-insensitive)
    map_file=$(rommap_path)
    id=$(awk -F'\t' -v s="$1" '$2 == s { print $1; exit }' "${map_file}")
    if [ -z "${id}" ]; then
        id=$(awk -F'\t' -v s="$1" 'tolower($2) == tolower(s) { print $1; exit }' "${map_file}")
    fi
    printf '%s' "${id}"
}

# ------------------------------------------------------------- sync ----------
init_state() {
    mkdir -p "${STATE}" "${TMPDIR_SH}" "${STATE}/backups"
    HTTP_RESP_FILE="${TMPDIR_SH}/resp.$$"
    HTTP_CODE_FILE="${TMPDIR_SH}/code.$$"
}

cleanup_state() { rm -f "${HTTP_RESP_FILE}" "${HTTP_CODE_FILE}" 2>/dev/null; }

acquire_lock() {
    if ! mkdir "${LOCKDIR}" 2>/dev/null; then
        # stale lock older than 15 min? take over.
        if [ -f "${LOCKDIR}/ts" ]; then
            age=$(( $(NOW_EPOCH) - $(cat "${LOCKDIR}/ts" 2>/dev/null || echo 0) ))
            [ "${age}" -gt 900 ] && { rm -rf "${LOCKDIR}"; mkdir "${LOCKDIR}" 2>/dev/null || die "another sync is running"; }
        fi
        return 1
    fi
    NOW_EPOCH > "${LOCKDIR}/ts"
    return 0
}

release_lock() { rm -rf "${LOCKDIR}" 2>/dev/null; }

# inventory: lines "hash<TAB>mtime<TAB>size<TAB>path" for every save file
build_inventory() {
    inv_tmp="${TMPDIR_SH}/inventory.$$"
    : > "${inv_tmp}"
    find_expr=""
    for ext in ${SAVE_EXTS}; do
        [ -n "${find_expr}" ] && find_expr="${find_expr} -o"
        find_expr="${find_expr} -name '*.${ext}'"
    done
    eval "find \"\${ROMS_DIR}\" -type f \\( ${find_expr} \\) 2>/dev/null" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '%s\t%s\t%s\t%s\n' \
            "$(file_hash "$f")" "$(file_mtime "$f")" "$(file_size "$f")" "$f"
    done > "${inv_tmp}"
    printf '%s' "${inv_tmp}"
}

backup_save() {
    [ "${BACKUPS}" = "1" ] || return 0
    bdir="${STATE}/backups/$(date '+%Y%m%d')"
    mkdir -p "${bdir}"
    cp -p "$1" "${bdir}/$(basename "$1").$(NOW_EPOCH).bak"
    # prune: keep only KEEP_BACKUPS newest per filename
    ls -t "${bdir}/$(basename "$1")."*.bak 2>/dev/null | tail -n +$(( KEEP_BACKUPS + 1 )) | while IFS= read -r old; do
        rm -f "${old}"
    done
}

do_download() { # do_download save_id target_path server_hash
    save_id=$1; target=$2; want_hash=$3
    url="/api/saves/${save_id}/content?device_id=${DEVICE_ID}&session_id=${SESSION_ID}&optimistic=true"
    code=$(http_get "${url}")
    if [ "${code:-000}" != "200" ]; then
        logline "download failed for save ${save_id} (HTTP ${code})"
        ERRORS=$(( ERRORS + 1 )); return 1
    fi
    got_hash=$(file_hash "${HTTP_RESP_FILE}")
    if [ -n "${want_hash}" ] && [ "${want_hash}" != "null" ] && [ "${got_hash}" != "${want_hash}" ]; then
        logline "hash mismatch on downloaded save ${save_id}, keeping local copy"
        ERRORS=$(( ERRORS + 1 )); return 1
    fi
    [ -f "${target}" ] && backup_save "${target}"
    cp "${HTTP_RESP_FILE}" "${target}" 2>/dev/null || { logline "write failed: ${target}"; ERRORS=$(( ERRORS + 1 )); return 1; }
    DOWNLOADED=$(( DOWNLOADED + 1 ))
    logline "downloaded: $(basename "${target}") (from save ${save_id})"
    return 0
}

do_upload() { # do_upload rom_id path content_hash overwrite
    rom_id=$1; path=$2; hash=$3; ow=$4
    url="/api/saves?rom_id=${rom_id}&slot=${SAVE_SLOT}&device_id=${DEVICE_ID}&session_id=${SESSION_ID}&content_hash=${hash}&overwrite=${ow}&autocleanup=true&autocleanup_limit=${AUTOCLEANUP_LIMIT}"
    code=$(http_req POST "${url}" "" -F "saveFile=@${path}")
    case "${code:-000}" in
        200|201)
            UPLOADED=$(( UPLOADED + 1 ))
            logline "uploaded: $(basename "${path}") (rom ${rom_id}, overwrite=${ow})"
            ;;
        409)
            if [ "${ow}" = "false" ]; then
                # slot changed server-side since our baseline -> resolve by policy
                resolve_conflict "${rom_id}" "${path}" "${hash}"
            else
                logline "upload rejected (409) even with overwrite for $(basename "${path}")"
                ERRORS=$(( ERRORS + 1 ))
            fi
            ;;
        *)
            logline "upload failed for $(basename "${path}") (HTTP ${code})"
            ERRORS=$(( ERRORS + 1 ))
            ;;
    esac
}

resolve_conflict() { # rom_id path local_hash
    rom_id=$1; path=$2; lhash=$3
    CONFLICTS=$(( CONFLICTS + 1 ))
    case "${CONFLICT_POLICY}" in
        remote)
            logline "conflict on $(basename "${path}"): policy=remote, server copy wins"
            ;;
        *)
            logline "conflict on $(basename "${path}"): policy=local, pushing local copy (RomM keeps history)"
            do_upload "${rom_id}" "${path}" "${lhash}" true
            ;;
    esac
}

write_status() {
    mkdir -p "${STATE}"
    "${JQ}" -n \
        --arg finished "$(date '+%F %T')" \
        --argjson uploaded "${UPLOADED:-0}" \
        --argjson downloaded "${DOWNLOADED:-0}" \
        --argjson conflicts "${CONFLICTS:-0}" \
        --argjson errors "${ERRORS:-0}" \
        '{finished: $finished, uploaded: $uploaded, downloaded: $downloaded,
          conflicts: $conflicts, errors: $errors}' > "${STATUS_FILE}" 2>/dev/null
}

cmd_sync() {
    AUTO=0
    case "${1:-}" in --auto) AUTO=1; shift;; esac

    [ -n "${ROMM_URL}" ] || die "ROMM_URL is not set in ${CONF}"
    [ -n "${ROMM_TOKEN}" ] || die "ROMM_TOKEN is not set in ${CONF}"
    [ -n "${DEVICE_ID}" ] || die "DEVICE_ID is not set in ${CONF} (run: shallot.sh register <name>)"
    [ -d "${ROMS_DIR}" ] || die "ROMS_DIR not found: ${ROMS_DIR}"

    need_tools
    init_state

    if [ "${AUTO}" = "1" ]; then
        # silent mode: connectivity first, bail quietly when offline
        net_ready || { logline "auto-sync skipped: RomM unreachable"; release_lock 2>/dev/null; exit 0; }
    else
        net_ready || die "RomM not reachable at ${ROMM_URL}"
    fi

    if ! acquire_lock; then
        logline "sync skipped: another sync already running"
        exit 0
    fi
    trap 'release_lock; cleanup_state' EXIT INT TERM

    UPLOADED=0; DOWNLOADED=0; CONFLICTS=0; ERRORS=0
    logline "sync start (device ${DEVICE_ID}, policy ${CONFLICT_POLICY})"

    inv=$(build_inventory)
    map_file=$(rommap_path)

    # keep only saves that map to a known rom -> negotiate input (ndjson)
    ndjson="${TMPDIR_SH}/negotiate.ndjson.$$"
    : > "${ndjson}"
    rid_tmp="${TMPDIR_SH}/rids.$$"
    : > "${rid_tmp}"
    matched=0
    while IFS="$(printf '\t')" read -r hash mtime size path; do
        [ -n "${path}" ] || continue
        stem=$(stem_of "${path}")
        rom_id=$(rom_id_for_stem "${stem}")
        [ -n "${rom_id}" ] || { logline "no RomM match for save: $(basename "${path}")"; continue; }
        matched=$(( matched + 1 ))
        echo "${rom_id}" >> "${rid_tmp}"
        "${JQ}" -cn \
            --argjson rom_id "${rom_id}" \
            --arg file_name "$(basename "${path}")" \
            --arg slot "${SAVE_SLOT}" \
            --arg content_hash "${hash}" \
            --arg updated_at "$(ISO_FROM_EPOCH "${mtime}")" \
            --argjson file_size_bytes "${size:-0}" \
            '{rom_id: $rom_id, file_name: $file_name, slot: $slot,
              emulator: null, content_hash: $content_hash,
              updated_at: $updated_at, file_size_bytes: $file_size_bytes}' >> "${ndjson}"
        printf '%s\t%s\t%s\n' "${rom_id}" "${path}" "${hash}" >> "${TMPDIR_SH}/local.$$"
    done < "${inv}"

    # widen rom_ids: every mapped rom whose ROM file is present locally, so the
    # server can restore saves for roms that have no local save yet (fresh SD)
    while IFS="$(printf '\t')" read -r mid stem fs_name; do
        [ -n "${mid}" ] || continue
        grep -qx "${mid}" "${rid_tmp}" 2>/dev/null && continue
        if find "${ROMS_DIR}" -type f -name "${fs_name}" 2>/dev/null | grep -q .; then
            echo "${mid}" >> "${rid_tmp}"
        fi
    done < "${map_file}"

    rom_ids=$("${JQ}" -s 'unique' "${rid_tmp}" 2>/dev/null || echo '[]')
    saves_json=$("${JQ}" -s '.' "${ndjson}" 2>/dev/null || echo '[]')
    payload_file="${TMPDIR_SH}/payload.$$"
    "${JQ}" -n --arg device "${DEVICE_ID}" --argjson saves "${saves_json}" \
        --argjson rom_ids "${rom_ids}" \
        '{device_id: $device, saves: $saves, rom_ids: $rom_ids, restore_unlisted: false}' > "${payload_file}"

    code=$(http_post "/api/sync/negotiate" "${payload_file}")
    if [ "${code:-000}" != "200" ]; then
        logline "negotiate failed (HTTP ${code})"
        cp "${HTTP_RESP_FILE}" "${STATE}/last-error.json" 2>/dev/null
        die "negotiate failed (HTTP ${code}) - raw response kept in data/last-error.json"
    fi

    SESSION_ID=$("${JQ}" -r '.session_id // empty' "${HTTP_RESP_FILE}")
    ops_file="${TMPDIR_SH}/ops.$$"
    "${JQ}" -c '.operations[]?' "${HTTP_RESP_FILE}" > "${ops_file}" 2>/dev/null

    while IFS= read -r op; do
        [ -n "${op}" ] || continue
        action=$(printf '%s' "${op}" | "${JQ}" -r '.action')
        rom_id=$(printf '%s' "${op}" | "${JQ}" -r '.rom_id')
        save_id=$(printf '%s' "${op}" | "${JQ}" -r '.save_id // empty')
        srv_hash=$(printf '%s' "${op}" | "${JQ}" -r '.server_content_hash // empty')
        case "${action}" in
            upload|conflict)
                entry=$(awk -F'\t' -v r="${rom_id}" '$1 == r { print $2 "\t" $3 }' "${TMPDIR_SH}/local.$$" | head -n 1)
                path=${entry%%	*}
                lhash=${entry#*	}
                [ -n "${path}" ] && [ -f "${path}" ] || continue
                if [ "${action}" = "conflict" ]; then
                    resolve_conflict "${rom_id}" "${path}" "${lhash}"
                else
                    do_upload "${rom_id}" "${path}" "${lhash}" false
                fi
                ;;
            download)
                # resolve local path by save filename (create the platform dir if absent)
                fname=$(printf '%s' "${op}" | "${JQ}" -r '.file_name')
                target=$(save_target_for "${rom_id}" "${fname}")
                do_download "${save_id}" "${target}" "${srv_hash}"
                ;;
            no_op)
                ;;
            delete)
                logline "server asked deletion - not deleting local saves (safety)"
                ;;
            *)
                logline "unknown operation: ${action}"
                ;;
        esac
    done < "${ops_file}"

    logline "sync done: up=${UPLOADED} down=${DOWNLOADED} conflicts=${CONFLICTS} errors=${ERRORS}"
    write_status
    rm -f "${inv}" "${ndjson}" "${rid_tmp}" "${payload_file}" "${ops_file}" "${TMPDIR_SH}/local.$$"

    if [ "${AUTO}" != "1" ]; then
        say "Sync finished: ${UPLOADED} uploaded, ${DOWNLOADED} downloaded, ${CONFLICTS} conflicts, ${ERRORS} errors."
    fi
    return 0
}

# ------------------------------------------------------------- status --------
cmd_status() {
    if [ -f "${STATUS_FILE}" ]; then
        cat "${STATUS_FILE}"
        echo
    else
        echo "No sync has run yet (no status.json in ${STATE})."
    fi
}

# ------------------------------------------------------------- register ------
cmd_register() {
    name=${1:-Shallot-Miyoo}
    [ -n "${ROMM_URL}" ] || die "ROMM_URL is not set in ${CONF}"
    [ -n "${ROMM_TOKEN}" ] || die "ROMM_TOKEN is not set in ${CONF}"
    need_tools
    init_state
    body="${TMPDIR_SH}/reg.$$"
    printf '{"name": "%s"}' "${name}" > "${body}"
    code=$(http_post "/api/devices" "${body}")
    [ "${code:-000}" = "200" ] || [ "${code:-000}" = "201" ] || die "device registration failed (HTTP ${code})"
    "${JQ}" -r '.id' "${HTTP_RESP_FILE}"
    rm -f "${body}"
    cleanup_state
}

# ------------------------------------------------------------- check-config --
cmd_check_config() {
    need_tools
    say "shallot.sh ${VERSION}"
    say "config:   ${CONF}"
    say "state:    ${STATE}"
    say "roms dir: ${ROMS_DIR} $([ -d "${ROMS_DIR}" ] && echo ok || echo MISSING)"
    say "romm url: ${ROMM_URL:-<unset>}"
    say "token:    $([ -n "${ROMM_TOKEN}" ] && echo set || echo '<unset>')"
    say "device:   ${DEVICE_ID:-<unset>}"
    if [ -n "${ROMM_URL}" ] && [ -n "${ROMM_TOKEN}" ]; then
        if net_ready; then say "romm:     reachable"; else say "romm:     UNREACHABLE"; fi
    fi
    if [ -f "${STATE}/rommap.tsv" ]; then
        say "rom map:  $(wc -l < "${STATE}/rommap.tsv") roms known"
    fi
}

# ------------------------------------------------------------- roms ----------
cmd_roms_claim() {
    [ -n "${ROMM_URL}" ] && [ -n "${ROMM_TOKEN}" ] && [ -n "${DEVICE_ID}" ] || die "config incomplete for roms claim"
    need_tools
    init_state
    net_ready || die "RomM not reachable at ${ROMM_URL}"

    code=$(http_post "/api/devices/${DEVICE_ID}/installs/claim")
    if [ "${code:-000}" != "200" ] && [ "${code:-000}" != "201" ]; then
        die "installs claim failed (HTTP ${code})"
    fi
    count=$("${JQ}" 'length // 0' "${HTTP_RESP_FILE}" 2>/dev/null || echo 0)
    say "claimed ${count} install request(s)"
    i=0
    while [ "${i}" -lt "${count}" ]; do
        req=$("${JQ}" -c ".[${i}]" "${HTTP_RESP_FILE}")
        req_id=$(printf '%s' "${req}" | "${JQ}" -r '.id')
        rom_id=$(printf '%s' "${req}" | "${JQ}" -r '.rom_id')
        st=$(printf '%s' "${req}" | "${JQ}" -r '.status')
        if [ "${st}" = "pending" ] || [ "${st}" = "taken" ]; then
            say "installing rom ${rom_id} (request ${req_id})..."
            if rom_download "${rom_id}"; then
                put_install_status "${req_id}" done
            else
                put_install_status "${req_id}" failed
            fi
        else
            put_install_status "${req_id}" "${st}"
        fi
        i=$(( i + 1 ))
    done
    cleanup_state
}

put_install_status() {
    body="${TMPDIR_SH}/inst.$$"
    printf '{"status": "%s"}' "$2" > "${body}"
    http_put "/api/devices/${DEVICE_ID}/installs/$1" "${body}" >/dev/null 2>&1
    rm -f "${body}"
}

platform_dir_for() { # platform_id -> Roms subfolder
    pid=$1
    pdir="${TMPDIR_SH}/platform.$$"
    code=$(http_get "/api/platforms/${pid}")
    slug=""
    if [ "${code:-000}" = "200" ]; then
        slug=$("${JQ}" -r '.slug // empty' "${HTTP_RESP_FILE}" 2>/dev/null)
    fi
    [ -n "${slug}" ] || slug="unknown"
    dir=$(awk -F= -v s="${slug}" '$1 == s { print $2 }' "${STATE}/platforms.map" 2>/dev/null)
    [ -n "${dir}" ] || dir=$(printf '%s' "${slug}" | tr '[:lower:]- ' '[:upper:]_')
    printf '%s' "${dir}"
}

save_target_for() { # save_target_for rom_id file_name -> absolute local save path
    rom_id=$1; fname=$2
    found=$(find "${ROMS_DIR}" -type f -name "${fname}" 2>/dev/null | head -n 1)
    if [ -z "${found}" ]; then
        code=$(http_get "/api/roms/${rom_id}")
        platform_id=""
        if [ "${code:-000}" = "200" ]; then
            platform_id=$("${JQ}" -r '.platform_id // empty' "${HTTP_RESP_FILE}" 2>/dev/null)
        fi
        if [ -n "${platform_id}" ]; then
            pdir=$(platform_dir_for "${platform_id}")
            mkdir -p "${ROMS_DIR}/${pdir}"
            found="${ROMS_DIR}/${pdir}/${fname}"
        else
            mkdir -p "${ROMS_DIR}"
            found="${ROMS_DIR}/${fname}"
        fi
    fi
    printf '%s' "${found}"
}

rom_download() {
    rom_id=$1
    code=$(http_get "/api/roms/${rom_id}")
    [ "${code:-000}" = "200" ] || { say "rom ${rom_id} fetch failed (HTTP ${code})"; return 1; }
    fs_name=$("${JQ}" -r '.fs_name // .name' "${HTTP_RESP_FILE}")
    platform_id=$("${JQ}" -r '.platform_id' "${HTTP_RESP_FILE}")
    pdir=$(platform_dir_for "${platform_id}")
    destdir="${ROMS_DIR}/${pdir}"
    mkdir -p "${destdir}"

    url=$(printf '%s' "${DOWNLOAD_PATH}" | sed "s/%id%/${rom_id}/g")
    ctype=$(curl -sS -m "${CURL_TIMEOUT}" -o "${HTTP_RESP_FILE}.dl" -D "${HTTP_RESP_FILE}.h" \
        -H "Authorization: Bearer ${ROMM_TOKEN}" "${ROMM_URL%/}${url}" >/dev/null 2>&1)
    if [ ! -s "${HTTP_RESP_FILE}.dl" ]; then say "download empty for rom ${rom_id}"; return 1; fi
    if grep -qi 'content-type:.*zip' "${HTTP_RESP_FILE}.h" 2>/dev/null; then
        zfile="${TMPDIR_SH}/rom_${rom_id}.zip"
        mv "${HTTP_RESP_FILE}.dl" "${zfile}"
        if command -v 7z >/dev/null 2>&1; then
            (cd "${destdir}" && 7z y x "${zfile}" >/dev/null 2>&1) || { say "7z extract failed"; return 1; }
            rm -f "${zfile}"
            say "installed (zip) ${fs_name} -> Roms/${pdir}"
        else
            say "zip rom downloaded but 7z unavailable; kept at ${zfile}"
        fi
    else
        mv "${HTTP_RESP_FILE}.dl" "${destdir}/${fs_name}"
        say "installed ${fs_name} -> Roms/${pdir}"
    fi
    rm -f "${HTTP_RESP_FILE}.h"
    return 0
}

# ------------------------------------------------------------- main ----------
usage() {
    cat <<EOF
shallot.sh ${VERSION} - RomM save-sync client for Onion OS

usage: shallot.sh <command>
  sync [--auto]      bidirectional save sync
  roms claim         pull ROMs queued for this device in RomM
  status             show last sync report
  register <name>    register device, prints device id
  check-config       validate config + connectivity
EOF
}

cmd=${1:-}
[ -n "${cmd}" ] || { usage; exit 0; }
shift

case "${cmd}" in
    sync)          cmd_sync "$@" ;;
    roms)          case "${1:-}" in claim) cmd_roms_claim;; *) usage; exit 1;; esac ;;
    status)        cmd_status ;;
    register)      cmd_register "$@" ;;
    check-config)  cmd_check_config ;;
    -h|--help)     usage ;;
    *)             usage; exit 1 ;;
esac
