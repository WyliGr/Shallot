# Shallot configuration reference

`shallot.conf` lives at `App/Shallot/shallot.conf` on the SD card. Values are single-quoted shell assignments (the file is sourced by a POSIX shell - keep quotes, no special characters outside quotes). See [`shallot.conf.example`](../shallot.conf.example) for the annotated template.

| Key | Default | Meaning |
|---|---|---|
| `ROMM_URL` | (required) | Your RomM base URL, e.g. `https://romm.example.com` |
| `ROMM_TOKEN` | (required) | Client API token (`rmm_...`), see `romm-setup.md` |
| `DEVICE_ID` | (required) | Device id from `shallot.sh register` - written by the installer |
| `ROMS_DIR` | `/mnt/SDCARD/Roms` | ROM tree root; saves are discovered under it |
| `SAVE_EXTS` | `srm sav` | Space-separated save extensions to sync |
| `SAVE_SLOT` | `autosave` | RomM slot name for all synced saves (stable slot = clean conflict pairing) |
| `CONFLICT_POLICY` | `local` | `local` = console copy wins on conflict; `remote` = server copy wins |
| `BACKUPS` | `1` | Local backup before any overwrite |
| `KEEP_BACKUPS` | `3` | Daily backups kept per save file (under `data/backups/<date>/`) |
| `AUTOCLEANUP_LIMIT` | `10` | Server-side versions kept per slot |
| `ROMMAP_TTL` | `86400` | Seconds the rom-id cache stays valid |
| `CURL_TIMEOUT` | `20` | HTTP timeout in seconds |
| `DOWNLOAD_PATH` | `/api/roms/%id%/download` | RomM download endpoint template |
| `CURL_EXTRA` | (empty) | Extra curl flags, e.g. `--no-check-certificate` for a self-signed cert |

## Platform folder mapping

When downloading queued ROMs, Shallot derives the destination folder from the RomM platform slug (`sfc`, `gba`, ...) upper-cased - except where Onion's folder names differ. Add a line per exception in `App/Shallot/data/platforms.map`:

```
# romm-slug=Onion folder
snes=SFC
nes=FC
megadrive=MD
psx=PS
```

Lines are `slug=Folder`; unknown slugs fall back to the upper-cased slug.

## Conflict policy, in detail

A conflict means the same save changed both on the console and on the server since the device last synced (played on two devices without syncing between). Shallot resolves by policy **and never deletes anything**: the losing copy stays as a RomM version and/or a local backup in `data/backups/`. `local` is the sane default for a handheld (the console has the most recent "real" play session); switch to `remote` only if another device is your primary.

## Testing locally (no Miyoo)

`shallot.sh` runs on any Linux/macOS box with `curl` + `jq`:

```sh
SHALLOT_SDCARD=/tmp/sd sh shallot.sh check-config
sh test/run-tests.sh            # spins a mock RomM, no server or hardware needed
busybox sh test/run-tests.sh    # same suite under busybox ash (firmware parity)
```
