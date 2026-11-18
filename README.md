# Shallot

RomM save-sync client for Onion OS on the Miyoo Mini+ — your handheld becomes a first-class RomM device: saves sync both ways over WiFi, and ROMs queued from the RomM web UI download themselves onto the SD card.

Made with <3 by [Wyliam](https://wyliam.dev) — GPL-friendly MIT for Shallot itself; runs on top of the fantastic [Onion OS](https://github.com/OnionUI/Onion) and talks to a self-hosted [RomM](https://github.com/rommapp/romm) server.

## Why

RomM already ships a **Device Sync Protocol** (save negotiation with hash-based change detection, conflict tracking, per-device baselines) and a **device installs** queue (queue a ROM from the web UI → a registered device pulls it). Shallot is the missing client side for Onion OS: a small POSIX shell app that uses the tools already shipped on the firmware (`curl`, `jq`, `md5sum`, `7z`).

No Onion fork needed. Shallot installs into `/mnt/SDCARD/App/Shallot/` and hooks the existing network-check script so every boot with WiFi ends with saves synced — before you even pick a game.

## What it does

- **Save sync (the core feature)** — scans the SD for save files (`.srm`, `.sav`, …), builds an inventory with MD5 hashes, calls `POST /api/sync/negotiate` and applies the server's verdict: upload new local saves, download newer server saves, resolve conflicts by policy (local wins by default, server version history keeps nothing lost).
- **ROM install queue** — claims ROMs you queued in RomM's device view, downloads them into the right `Roms/<system>` folder, reports `done`/`already_installed`/`failed` back.
- **Auto-sync hook** — one marked block appended to `.tmp_update/script/network/update_networking.sh`: whenever Onion checks the network (boot, WiFi reconnect, returning to the menu), Shallot runs a silent sync in the background.
- **Onion app UI** — a `Shallot` entry in the Apps menu: run a manual sync, see the last sync report, toggle auto-sync.

## Quick start

Full guides in [`docs/`](docs/):

- [`docs/install.md`](docs/install.md) — getting Shallot onto the SD card and hooking auto-sync
- [`docs/romm-setup.md`](docs/romm-setup.md) — creating a Client API token + registering the device in RomM
- [`docs/configuration.md`](docs/configuration.md) — every `shallot.conf` key
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — WiFi, TLS, conflicts, logs

The short version, once your Miyoo is on WiFi with SSH enabled:

```sh
# from your computer, over SSH/SFTP/FTP
scp -r shallot/ root@<miyoo-ip>:/mnt/SDCARD/App/     # or use FTP/FileZilla
ssh root@<miyoo-ip> /mnt/SDCARD/App/Shallot/install.sh
```

Then edit `/mnt/SDCARD/App/Shallot/shallot.conf` (server URL + token) and run the app once from the Apps menu — first sync happens on the next boot.

## How it works (one breath)

`shallot.sh` → builds a save inventory (`md5sum` + `stat`) → maps save files to RomM ROM ids by filename stem (paginated `GET /api/roms`, cached) → negotiates (`POST /api/sync/negotiate`) → executes the returned operations (upload `POST /api/saves`, download `GET /api/saves/{id}/content`) with backups to `App/Shallot/data/backups/` → writes a machine-readable report to `data/status.json` and a human log to `data/last-sync.log`.

## Repo map

| Path | What it is |
|---|---|
| `shallot.sh` | The sync engine (POSIX sh, runs on the Miyoo and on any Linux box for testing) |
| `shallot-ui.sh` | Onion Apps menu entry (interactive terminal UI) |
| `install.sh` / `uninstall.sh` | Wire / unwire the app and the auto-sync hook |
| `shallot.conf.example` | Annotated configuration template |
| `docs/` | Setup, configuration, troubleshooting |
| `test/` | A mock RomM server + POSIX test suite (no hardware needed) |

## Contributing / agents

Clone, read `INSTRUCTIONS.md`. The test suite runs against a local mock RomM — you can develop the whole sync engine without ever touching a Miyoo.

```sh
sh test/run-tests.sh
```

## License

MIT — see [LICENSE](LICENSE).
