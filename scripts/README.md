# Scripts

Four scripts: three that back this printer up into this repository, and one
that updates the MCU firmware.

| Script | Runs on | Touches | Commits / pushes |
|---|---|---|---|
| [`backup-printer.sh`](backup-printer.sh) | PC (WSL) | printer via Moonraker API, read-only | yes / yes |
| [`backup-spoolman.sh`](backup-spoolman.sh) | PC (WSL) | Spoolman REST API, read-only | no (called by `backup-printer.sh`) |
| [`backup-orca.sh`](backup-orca.sh) | PC (WSL) | OrcaSlicer profiles in `%APPDATA%` | yes / yes (only `orca/`) |
| [`flash-mcus.sh`](flash-mcus.sh) | the Pi, over SSH | builds Kalico, flashes both MCUs | no |

None of them is scheduled. The printer is not on 24/7, so the backups are
run by hand when something changed.

## Backups

The backups are *pull*: they run on the PC and read from the printer.
They still work when the Pi is half broken, and no GitHub credential ever
lives on the printer's SD card.

This repository is **public**. Every backup redacts secrets before
committing and keeps the real values in `~/voron-backup-private/` on the
PC, outside the git tree (see [Secrets](../README.md#secrets)).

### `backup-printer.sh`

```bash
./scripts/backup-printer.sh             # pull, commit and push
./scripts/backup-printer.sh --no-push   # pull and commit
./scripts/backup-printer.sh --dry-run   # pull and show the diff, no commit
```

What it pulls, using only `GET` on the Moonraker API at `192.168.1.14:7125`:

1. **Every file in `~/printer_data/config`** → the repository root. This
   includes the `SAVE_CONFIG` block of `printer.cfg` (mesh, PID,
   `z_offset`), which is what hurts to lose. Stale symlinks left from the
   old BTT CB1 host are replaced by real files.
2. **Secrets.** `telegram.conf` (and any `moonraker.secrets` or `*.secret`)
   is archived in clear to `~/voron-backup-private/secrets-<date>.tar.gz`
   (the last 30 are kept), then `bot_token`, `chat_id`, `api_key`,
   `password` and similar keys are replaced with `REDACTED_VER_SECRETS_DIR`.
   What was redacted is listed in `state/secrets-redacted.txt`.
   **The key list is fixed — a new secret key in a config file would leak.**
   Read the diff when a new config file shows up.
3. **Moonraker state** that the config files do not cover →
   `state/database/` (the `moonraker`, `mainsail`, `webcams`, `maintenance`
   and `update_manager` namespaces), `state/print-history.json` and
   `state/print-totals.json`.
4. **Versions and hardware** → `state/system-snapshot.md`: Pi, SD card,
   services, installed vs available version of each component.
5. **Spoolman** through `backup-spoolman.sh`.
6. **Commit** of everything that changed (`git add -A`), then push.

If the printer is off, it skips steps 1–4 and still backs up Spoolman,
which runs on another host. It aborts only when neither answers. It
commits only when something changed.

### `backup-spoolman.sh`

Called by `backup-printer.sh`, which does the commit. Run alone, it only
updates the files. It exports vendors, filaments, spools (including
archived ones, which carry the usage history) and settings from
`192.168.1.218:7912` to `state/spoolman/`.

**This is a logical dump, not a copy of the database.** Restoring means
re-POSTing the records, and Spoolman assigns new IDs, so the active spool
Moonraker remembers by ID is lost. A faithful restore needs
`~/.local/share/spoolman/spoolman.db` from the Spoolman host.

### `backup-orca.sh`

```bash
./scripts/backup-orca.sh             # copy, commit and push
./scripts/backup-orca.sh --no-push   # copy and commit
./scripts/backup-orca.sh --dry-run   # copy and show the diff, no commit
```

Mirrors the OrcaSlicer user presets from
`%APPDATA%\OrcaSlicer\user\<account>\{machine,filament,process}` into
[`orca/`](../orca), `.json` and `.info` files only. A preset deleted in Orca
disappears from the backup too. `OrcaSlicer.conf` is left out: it is UI
state and recent-file paths, and it changes every time Orca opens.

A printer preset can hold the print host API key or password. Any key that
looks like a credential is redacted, and the real values go to
`~/voron-backup-private/orca-secrets-<date>.json`.

Only `orca/` is committed, never the rest of the working tree, so it can
run with other edits pending. Before pushing it does
`git pull --rebase --autostash`.

**Restore:** with Orca closed, copy `orca/default/` back to
`%APPDATA%\OrcaSlicer\user\default\`.

## Firmware: `flash-mcus.sh`

Builds [Kalico](https://github.com/KalicoCrew/kalico) and flashes both
MCUs through Katapult. It is
[`docs/updating-kalico-firmware.md`](../docs/updating-kalico-firmware.md)
turned into a script, with the runbook's pitfalls checked instead of
remembered. It runs **on the Pi**. The printer backup puts a copy in
`~/printer_data/config/scripts/`.

Update the host first (Mainsail → Update Manager → Klipper), then:

```bash
bash ~/printer_data/config/scripts/flash-mcus.sh --check
```

`--check` builds both firmwares and runs every check. It does not stop
klipper and does not talk to the boards, so it is safe while the printer
is idle. Read its output. Only then:

```bash
tmux new -s flash
bash ~/printer_data/config/scripts/flash-mcus.sh --flash      # both boards
bash ~/printer_data/config/scripts/flash-mcus.sh --flash --only ebb   # or one
```

`--flash` refuses to run outside tmux or screen. If the SSH link drops,
the flash carries on; reattach with `tmux attach -t flash`.

### What it checks, in order

1. **Preconditions.** The printer is not printing (in `--flash`, an unknown
   state is also fatal). The saved `.config` files in `~/klipper` are
   identical to the versioned copies in `klipper-config/`.
2. **Build, per board**, each in its own temporary output directory, from a
   temporary copy of the saved `.config`. `out/klipper.bin` is never shared
   and the saved configs are never rewritten.
   - `olddefconfig` fills in options the new version added. If a saved
     option **changed value**, or was set and is **now hidden** by a
     dependency, the build is rejected. Saved options that no longer exist
     in Kalico at all only produce a warning.
   - Required options must be present: MCU, Katapult offset, CAN or USB
     pins, crystal, USB serial from the chip ID.
   - The built firmware must target the right MCU (`stm32g0b1xx` for the
     EBB, `stm32f446xx` for the Spider). Its version is compared with the
     host's.
3. **Stop klipper**, after a second printer-state check, since the build
   takes minutes. It is confirmed stopped before anything is written.
4. **Ask Katapult before writing.** Each board is sent to Katapult and
   asked for its real MCU type and application start address (`0x8002000`
   for the EBB, `0x8008000` for the Spider). Both must match, or nothing
   is written. Katapult also refuses writes over itself, so the bootloader
   cannot be overwritten.
5. **Flash**: EBB over CAN (`can0`, UUID `7f0f5f137d50`), then the Spider
   over USB. Each flash must exit 0 and report `Programming Complete`.
   Hangup, Ctrl-C and TERM are ignored while writing.
6. **Start klipper** and print host, `mcu` and `mcu EBBCan` versions,
   which should all read `ok`. Klipper is restarted on **any** exit,
   through the Moonraker API first, which needs no terminal.

### If something fails

- **A board stopped in Katapult** (a check failed, or a write failed and
  was reported): **do not power-cycle it.** Rerun
  `--flash --only <board>`; it picks the board up from Katapult.
  Katapult has no timeout, so the board waits.
- **Worst case:** a write cut off half-way *and then* a reset or
  power-cycle. That leaves a partial app that Katapult jumps into. It
  needs a double-tap of the board's reset button to get back to Katapult;
  for the EBB, that means reaching the toolhead. This is why the answer to
  any failure is to rerun, not to power-cycle.
- **After any Kalico host update**, the EBB is left in shutdown until a
  `FIRMWARE_RESTART`. That is expected, not a fault.

After flashing, run `QUERY_ENDSTOPS` and a supervised homing before
printing.
