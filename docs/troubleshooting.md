# Troubleshooting

## Nothing syncs on boot

1. `cat /mnt/SDCARD/App/Shallot/data/last-sync.log` - every run (including skipped ones) logs a line.
2. `auto-sync skipped: RomM unreachable` - WiFi was not up yet. Onion re-checks the network when it changes (menu return, WiFi reconnect); the next check syncs. You can also run `sh shallot.sh sync` by hand.
3. No log lines at all - the hook is gone (Onion update rewrote the networking script). Re-run `install.sh`.
4. `another sync is running` / lock stale: locks older than 15 minutes are reclaimed automatically; a fresh lock means two syncs raced (harmless, one skipped).

## `check-config` says UNREACHABLE

- Is RomM actually reachable from the console's network? `curl -m 8 ${ROMM_URL}/api/heartbeat` over SSH should answer 200.
- Self-signed certificate? Set `CURL_EXTRA='--no-check-certificate'` in `shallot.conf`, or better: expose RomM with a real certificate (e.g. behind Pangolin/Caddy) or add the CA to the card.
- Token rejected (`HTTP 401` in the log): the token was rotated in RomM - paste the new one into `shallot.conf`.

## Negotiate fails (`HTTP 4xx/5xx`)

The raw server answer is kept at `data/last-error.json`. Common causes:

- `404` on `/api/sync/negotiate` - your RomM predates the device sync protocol; update RomM.
- `403` on save endpoints - the token lacks the scopes listed in `romm-setup.md`.

## `no RomM match for save: ...`

The save's filename stem matches no ROM known to RomM. Rename the ROM in RomM so its filename stem matches the save, or remove the save. The sync never guesses and never touches unmatched saves.

## A ROM install stays `failed`

Check `data/last-sync.log` and `report.txt` for the reason. Zipped multi-file ROMs need `7z` (shipped by Onion at `.tmp_update/bin/7z`); if the platform folder mapping was wrong, add a line to `data/platforms.map` and re-queue the install.

## Manual reset (nuclear option)

- Forget device-side sync state only: delete `App/Shallot/data/` **except** `backups/` (the rom map, locks and logs regenerate on the next run).
- Full reset: uninstall `--purge`, delete the device in RomM, reinstall.

## Reporting a bug

Attach (redacting the token): `data/last-sync.log`, `data/status.json`, `data/last-error.json` if present, and your RomM version.
