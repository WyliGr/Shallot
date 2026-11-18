# Installing Shallot on the Miyoo Mini+

Prerequisites: **Miyoo Mini+** (the Mini v2/v4 has no WiFi), Onion OS installed, WiFi configured in Onion's Tweaks, and your RomM server reachable from that network.

## 1. Get Shallot onto the SD card

Pick whichever transfer method you already use (Onion has SSH, FTP and an HTTP file server built in - all in `Apps > Tweaks > Network`).

**With SSH (fastest):**

```sh
# from your computer
git clone https://github.com/WyliGr/Shallot.git
scp -r Shallot/{shallot.sh,shallot-app.sh,launch.sh,install.sh,shallot.conf.example} \
    root@<miyoo-ip>:/mnt/SDCARD/App/Shallot/
```

(Create the folder first: `ssh root@<miyoo-ip> 'mkdir -p /mnt/SDCARD/App/Shallot'`.)

**With FTP / the web file server:** copy the same five files into `App/Shallot/` on the card.

## 2. Run the installer

```sh
ssh root@<miyoo-ip>
sh /mnt/SDCARD/App/Shallot/install.sh \
    --url https://romm.example.com \
    --token rmm_XXXXXXXXXXXX
```

The installer:

1. finishes the app layout in `App/Shallot/` (launcher, `config.json` menu entry, data dirs)
2. writes `shallot.conf`
3. registers the device in RomM and stores the device id in the config
4. appends the marked auto-sync hook to `.tmp_update/script/network/update_networking.sh`
5. enables auto-sync (toggle later from the app entry)

If you leave out `--url`/`--token` it prompts for them interactively.

## 3. Verify

- Apps menu now shows **Shallot** - launch it once: it runs a sync and installs any ROM queued for the device, then writes `App/Shallot/report.txt` (open it with Onion's File Explorer / DinguxCommander).
- Or over SSH: `sh /mnt/SDCARD/App/Shallot/shallot.sh check-config`.
- Reboot: with WiFi up, `data/last-sync.log` gains a `sync done: ...` line within a minute.

## After an Onion firmware update

Onion's update rewrites `.tmp_update/script/network/update_networking.sh`, which wipes the hook. Just re-run the installer - it is idempotent and won't duplicate anything (your config and device id are kept).

## Removing Shallot

```sh
sh /mnt/SDCARD/App/Shallot/uninstall.sh          # unwire hook + menu entry, keeps config/backups
sh /mnt/SDCARD/App/Shallot/uninstall.sh --purge  # delete everything
```

Uninstalling never touches your save files on the card.

## Updating Shallot

Copy the new files over `App/Shallot/` and re-run `install.sh` (config preserved). Check the release notes for config changes.
