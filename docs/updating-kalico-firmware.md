# Updating Kalico — printer (mainsailos)

> Revised 2026-08-22, after the update to `v2026.08.00-1-gae261624`.
> Replaces the old procedure, which used `make flash` (the DFU route) and
> **no longer works reliably on this printer**.

## Current setup

| Item | Detail |
|---|---|
| Host | `pi@mainsailos` — 192.168.1.14 — MainsailOS 1.3.2 (Raspbian 11, armv7l) |
| Main MCU | **Fysetc Spider 2.3** — `stm32f446xx` — USB CDC — Katapult 32 KiB (app `0x8008000`) |
| Toolhead MCU | **SB2209 (`EBBCan`)** — `stm32g0b1xx` — CAN `can0`, UUID `7f0f5f137d50` — Katapult 8 KiB (app `0x8002000`) |
| CAN adapter | gs_usb `1d50:606f` — **separate** from the Spider |
| Repos | `~/klipper` (Kalico) and `~/katapult` |
| Saved configs | `~/klipper/.config-esoterical-usb-spider` and `~/klipper/.config-sb2209` — versioned copies in `klipper-config/` in this repo (see pitfall 6) |

## Rule of thumb

**Both boards run Katapult.** Always flash with Katapult's `flashtool.py`.

**Do not use `make flash FLASH_DEVICE=<by-id>`.** It works sometimes — which
is exactly what makes it treacherous. See the diagnosis at the end.

---

## 0. Update the host

Mainsail → **Machine → Update Manager → Klipper**. Or by hand:

```bash
cd ~/klipper && git pull
sudo service klipper restart
```

Note the target version (`make` prints it as `Version: …`). From here the
host is new and the MCUs are old — the *version mismatch* warning is
**expected** until steps 2 and 3 are done.

## 1. Back up

```bash
cp ~/printer_data/config/printer.cfg ~/printer.cfg.bak
```

## 2. Flash the SB2209 / EBBCan (CAN)

```bash
cd ~/klipper
make clean
cp .config-sb2209 .config
make menuconfig          # just confirm and save (Q → Y)
make

sudo service klipper stop
python3 ~/katapult/scripts/flashtool.py -i can0 -u 7f0f5f137d50 -f ~/klipper/out/klipper.bin
sudo service klipper start
```

In CAN mode `flashtool.py` jumps to the bootloader on its own — no separate
`-r` needed.

To rediscover the UUID:

```bash
python3 ~/katapult/scripts/flashtool.py -i can0 -q
```

Expected at the end: `Verification Complete: SHA = …` and
`Programming Complete`.

## 3. Flash the Spider (USB)

### 3.1 Build

```bash
cd ~/klipper
make clean
cp .config-esoterical-usb-spider .config
make menuconfig          # just confirm and save (Q → Y)
make
```

### 3.2 Check the config BEFORE writing

```bash
grep -E 'CONFIG_(MACH_STM32F446|STM32_FLASH_START|USBSERIAL)' ~/klipper/.config
```

Expected output — the last two lines are noise from `grep` itself; what
matters is that only `_8000` is set to `=y`:

```
CONFIG_USBSERIAL=y
CONFIG_MACH_STM32F446=y
CONFIG_STM32_FLASH_START_8000=y
# CONFIG_STM32_FLASH_START_10000 is not set
# CONFIG_STM32_FLASH_START_0000 is not set
```

`FLASH_START_8000` is the space Katapult occupies. Writing at a different
offset, on top of Katapult, is the **only** way to brick the board —
recovery would then need BOOT0.

### 3.3 Enter Katapult

```bash
sudo service klipper stop     # CONFIRM it worked, no "Sorry, try again"

python3 ~/katapult/scripts/flashtool.py \
  -d /dev/serial/by-id/usb-Klipper_stm32f446xx_2C003F001351303530323539-if00 -r
```

Expected:

```
Detected USB device running Klipper
Requesting USB bootloader for …
Waiting for USB Reconnect...done
Detected new USB Device: 1d50:6177 katapult stm32f446xx
Bootloader Request Complete
```

### 3.4 Check the new path

```bash
ls -l /dev/serial/by-id/
```

The symlink changes from `usb-Klipper_…` to **`usb-katapult_…` — lowercase
`k`**. Same VID:PID (`1d50:6177`), different name.

### 3.5 Write

```bash
python3 ~/katapult/scripts/flashtool.py \
  -d /dev/serial/by-id/usb-katapult_stm32f446xx_2C003F001351303530323539-if00 \
  -f ~/klipper/out/klipper.bin

sudo service klipper start
```

Expected:

```
Detected USB device running Katapult
Detected Klipper binary version v2026.08.00-1-gae261624, MCU: stm32f446xx
Application Start: 0x8008000
Verification Complete: SHA = …
Programming Complete
```

Check the two middle lines: `MCU: stm32f446xx` (right board) and
`Application Start: 0x8008000` (right offset).

## 4. Verify

Mainsail → **System Loads**: `Host`, `mcu` and `mcu EBBCan` must all report
the **same version**.

In the console:

```
FIRMWARE_RESTART
QUERY_ENDSTOPS
```

Then a dry homing run before printing.

---

## Pitfalls (every one of these has cost time)

1. **`out/klipper.bin` is overwritten by every `make`.** Flash one board at
   a time and never rebuild between `make` and the flash. Building with the
   wrong `.config` and writing it means an STM32G0 firmware on an STM32F446.
2. **Symlink case:** `usb-Klipper_` (capital K, firmware) vs
   `usb-katapult_` (lowercase k, bootloader). Linux is case-sensitive.
3. **sudo password:** if `sudo service klipper stop` asks for a password and
   fails, the service did **not** stop and will fight for the serial port.
4. **Katapult timeout:** if too long passes between `-r` and `-f` it falls
   back to firmware. Just repeat the `-r`.
5. **Reflashing the Spider does not drop `can0`** — CAN comes from a
   separate USB adapter.
6. **The `.config` files exist in two places.** This runbook copies from
   `~/klipper/.config-*`, but the versioned copies in this repository come
   from `~/printer_data/config/klipper-config/.config-*` — different files,
   with nothing keeping them in sync. Editing the config in `~/klipper`
   without copying it back leaves the change on the printer only. After
   touching a `.config`, copy it to
   `~/printer_data/config/klipper-config/` before finishing. Values checked
   on 2026-08-22: Spider `FLASH_START_8000` (Katapult 32 KiB), SB2209
   `FLASH_START_2000` (Katapult 8 KiB).
7. **`ram: 100.00%` during `make` is normal** — Kalico allocates all
   remaining RAM to the dynamic pool. It is not an error. That line is
   **new** in this version window: it comes from commit `b83f73cf` ("Print
   memory usage data when building"), which added
   `-Wl,--print-memory-usage` to the link step. That is why it shows up now
   and did not on the previous update — new output, not a new problem.

## Known errors and what they mean

| Error | Cause |
|---|---|
| `dfu-util: No DFU capable USB device available` | You used `make flash` and it lost the race (see the diagnosis). The board went into Katapult, and `dfu-util` only talks to `0483:df11`. |
| `Unable to find tty device` | The board is sitting in Katapult; the `usb-Klipper_…` symlink does not exist at that moment. Run `ls /dev/serial/by-id/`. |
| `FlashError: No Serial Device found at …` | Wrong case in the path — it is `usb-katapult_`, lowercase. |
| `Unable to find tty device` immediately, with nothing in `lsusb` | That one really is a cable or board power problem. |

---

## Diagnosis: why `make flash` fails (2026-08-22)

**This is not a version regression** — that was verified exhaustively, not
by sampling.

The jump was from `v0.12.0-715-g91fd6480` (**2025-07-08**) to
`v2026.08.00-1-gae261624` (**2026-08-05**), thirteen months.
`git describe` confirms `91fd6480` is exactly the `v0.12.0-715` the Update
Manager was showing.

Across that entire range the whole flash path is **byte for byte
identical** (functions compared by AST, not by textual diff):

| | |
|---|---|
| `flash_dfuutil`, `wait_path`, `detect_canboot`, `enter_bootloader` | identical |
| `flash_stm32f4`, `call_dfuutil`, `call_flashcan`, `main` | identical |
| `translate_serial_to_tty`, `translate_serial_to_usb_path` | identical |
| the `flash:` target in `src/stm32/Makefile` | untouched |
| `src/stm32/dfu_reboot.c` | untouched |
| `src/stm32/Kconfig`, `FLASH_START`/`BOOTLOADER` lines | whitespace only |
| `src/stm32/stm32f4.c` | changed, but entirely under `#if CONFIG_MACH_STM32F411` |

`flash_usb.py` gained only three things in that period: reordered imports
(#767), STM32F411 support (#770) and INDX support (#904). Dispatch is by
prefix — `stm32f446xx` matches `stm32f4` and lands in `flash_stm32f4`,
which calls `flash_dfuutil`. None of that changed.

**Conclusion: the saved command never stopped working — it was never
reliable.** The defect below was always there; in March the board won the
coin toss, in August it lost. What changes the outcome is the environment
(how loaded the Pi is, which port the kernel re-enumerates on), not Kalico.

The cause is in `flash_dfuutil()`, and it is broader than a timing race.
Actual upstream code (`scripts/flash_usb.py`, checked 2026-08-22):

```python
def flash_dfuutil(device, binfile, extra_flags=None, sudo=True):
    ...
    buspath, devpath = translate_serial_to_usb_path(device)  # Klipper's sysfs
    enter_bootloader(device)
    pathname = wait_path(devpath)
    if detect_canboot(devpath):      # reads idVendor/idProduct from that same sysfs
        call_flashcan(serbypath, binfile)
    else:
        call_dfuutil(["-p", buspath] + extra_flags, binfile, sudo)

def wait_path(path, alt_path=None):
    time.sleep(0.100)
    start_alt_path = None
    end_time = time.time() + 4.0
    while 1:
        time.sleep(0.100)
        cur_time = time.time()
        if os.path.exists(path):
            sys.stderr.write("Device reconnect on %s\n" % (path,))
            time.sleep(0.100)
            return path
        ...
        if cur_time > end_time:
            return path          # <- gives up and returns the path anyway
```

`make flash` **does** know how to handle Katapult: `detect_canboot()`
compares the VID:PID against `1d50:6177`, exactly what Katapult presents.
The defect is that it reads that VID:PID from `devpath` — the sysfs path
resolved **before** the reboot, while the board was still Klipper. And
`flash_dfuutil` calls `wait_path(devpath)` with no `alt_path`, so there are
two ways to get it wrong:

1. **The old node has not been removed yet.** `os.path.exists()` is
   immediately true, `wait_path` returns in ~200 ms, and `detect_canboot`
   reads Klipper's stale VID:PID (`1d50:614e`). False negative.
2. **The board re-enumerates at a different sysfs path.** `devpath` never
   appears, the loop hits the 4 s timeout and **returns `path` regardless**.
   `detect_canboot` tries to open `idVendor` at a path that does not exist,
   hits the `except` and returns `False`. False negative again.

Either way the script falls through to `dfu-util` — which has nobody to
talk to, because the board is already in Katapult and `dfu-util` only
speaks to `0483:df11`.

So it was always a dice roll on this board. It passed in March and lost in
August. All it takes is a busier Pi, or the kernel re-enumerating on
another port. `flashtool.py` does not have this problem — it waits for the
actual reconnect and reports what it found.

The second error (`Unable to find tty device`) is a consequence: with
`dfu-util` failing, the board stays in Katapult, the `usb-Klipper_…`
symlink stops existing, and the script cannot resolve it to a `ttyACM*`.

> Confidence note: upstream `flash_usb.py` was downloaded and read on
> 2026-08-22 — the defect in both paths above is confirmed in the code.
> What was **not** done is reproducing the failure with instrumentation to
> say which of the two fired on this board. This is the explanation that
> fits all the evidence, not a direct proof.
