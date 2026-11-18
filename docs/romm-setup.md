# RomM-side setup

Shallot is a RomM **device client**: it talks to your self-hosted RomM server through the Device Sync Protocol and the device installs queue. Nothing special is required from RomM beyond a recent version (the device sync endpoints shipped in 2026 releases - update RomM if your instance predates them).

## 1. Create a Client API token

In RomM: **profile menu > Client API Tokens > new token**. Give it a name (`Shallot Miyoo`) and the scopes:

- `devices.write` and `devices.read` (device registration, installs, sync sessions)
- `assets.write` and `assets.read` (save upload/download)
- `roms.user.write` / `roms.user.read` (play sessions, rom lookup)

The token looks like `rmm_...` - paste it into `shallot.conf` (or give it to `install.sh --token`).

## 2. Register the Miyoo as a device

The installer does this automatically (`shallot.sh register Miyoo`); the resulting device appears in RomM under your devices. From there the RomM web UI can **queue a ROM install** for the device: the next `roms claim` (or app launch, or boot sync with `roms claim` enabled) downloads it into the right `Roms/<system>` folder and reports `done`.

Manual registration:

```sh
sh shallot.sh register Miyoo      # prints the device id
# put the id in shallot.conf: DEVICE_ID='dev-...'
```

## 3. How save matching works

Shallot maps a local save to a RomM ROM **by filename stem**: `Zelda (USA).sfc` (the ROM) produces `Zelda (USA).srm` (the RetroArch save) - both map to the RomM entry whose file is `Zelda (USA).sfc`. Unmatched saves are logged and skipped, never guessed.

If you renamed your ROMs after playing, tell RomM the new names and run one `sync` - unmatched saves on both sides pair back up on the next negotiation.

## 4. What to expect in the RomM UI

- Saves uploaded by Shallot appear in the game's **Saves** tab with the slot name (`autosave`) and the device as origin.
- Every overwrite keeps version history (retention configurable server-side; Shallot requests `autocleanup_limit=10` by default).
- The device's **installs** view shows queued ROMs and their status (`done` / `failed` with a reason in Shallot's log).
