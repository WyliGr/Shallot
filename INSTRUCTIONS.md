# INSTRUCTIONS.md - agent bootstrap

You are an agent working on Shallot. This file tells you how to work in this repo.

## What Shallot is

A RomM save-sync client for Onion OS (Miyoo Mini+). One POSIX shell engine
(`shallot.sh`) talks to a self-hosted RomM server through the Device Sync
Protocol; an installer wires it into Onion's boot networking script so saves
sync automatically whenever the console has WiFi. Read `README.md` for the
story and `docs/` for user-facing guides.

## Ground rules

1. **POSIX sh only.** The engine runs on the Miyoo's busybox ash. No bashisms:
   no arrays, no `[[ ]]`, no herestrings (`<<<`), no process substitution.
   Test with BOTH `sh test/run-tests.sh` (dash) and
   `busybox sh test/run-tests.sh` (firmware parity) before every push.
2. **Dependencies are what Onion ships**: curl, jq, md5sum, 7z. If you need a
   new tool, it must already be in `/mnt/SDCARD/.tmp_update/bin` on a real
   Onion install - verify against the Onion repo before adding it.
3. **Never touch the user's saves destructively.** Every overwrite goes through
   a local backup; unmatched saves are logged and skipped, never guessed.
4. **Conventions**: branches `feat/|fix/|docs/<change-name>`, conventional
   commits (`feat:`, `fix:`, `doc:`), small commits per concern, PRs target
   `dev`, only `dev` merges to `main`.
5. **Secrets never enter the repo.** The test token in `test/` is a fixture for
   the local mock; real tokens live in `shallot.conf` on the user's SD card
   (gitignored).

## How to verify changes

```sh
sh test/run-tests.sh            # 34 scenarios against a local mock RomM
busybox sh test/run-tests.sh
```

The mock (`test/mock-romm.py`) implements the slice of the RomM Device Sync
Protocol the engine uses. Extend it whenever you extend the engine - the mock
is the contract reference; mirror the real server's documented behavior.

## Where things live

| Path | Role |
|---|---|
| `shallot.sh` | engine: inventory, rom map, negotiate, upload/download, rom installs |
| `shallot-app.sh` + `launch.sh` | Apps-menu one-shot entry (sync + report.txt) |
| `install.sh` / `uninstall.sh` | idempotent wiring of app + auto-sync hook |
| `docs/` | install, RomM setup, configuration, troubleshooting |
| `test/` | mock RomM + POSIX suite |
