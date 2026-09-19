# Voron 2.4 — #6023

Fysetc Voron 2.4 kit, 350 mm, CoreXY, with the modifications listed below.
This repository is a configuration backup of the printer at `192.168.1.14`.
How the backups and the firmware update work: [`scripts/`](scripts/README.md).

- Serial request: https://www.reddit.com/r/voroncorexy/comments/165s76j/voron_serial_request_for_voron_24_by_ggrigon/
- Build kit: https://github.com/FYSETC/FYSETC-Voron-2

## Host and firmware

| | |
|---|---|
| Host | Raspberry Pi 3B — MainsailOS 1.3.2 (bullseye), user `pi` |
| Firmware | [Kalico](https://github.com/KalicoCrew/kalico) v2026.09.00-5 (host and both MCUs) |
| Main board | Fysetc Spider v2.3 — STM32F446, USB, Katapult 32 KiB (app `0x8008000`) |
| X/Y endstops | Sensorless (TMC2209 StallGuard), `driver_SGTHRS` 130 / 80 |

## Modifications

### Voron TAP

Nozzle probe. `endstop_pin: probe:z_virtual_endstop`, `z_offset: -0.800`.

### BTT EBB SB2209

Toolhead board. CAN at 1 Mbit/s, UUID `7f0f5f137d50`, Katapult 8 KiB
(app `0x8002000`). The `gs_usb` adapter is separate from the Spider.
Config in [`canbus.cfg`](canbus.cfg).

### Mod G5C

5:1 extruder, `gear_ratio: 50:10`, driven by the SB2209.
`rotation_distance: 22.33`, calibrated 2024-01-18 (Ellis method); Voron
stock value was 22.6789511.

### Hotend

Ceramic heater, Bambu Lab pattern. IdeaFormer kit, 2023-12-31.

- Heater `EBBCan: PB13`, fan `EBBCan: PA0`
- `sensor_type: EPCOS 100K B57560G104F`, `max_temp: 275`
- `max_extrude_cross_section: 5`, `max_extrude_only_distance: 101`

### Nevermore

Activated carbon filter. `fan_generic nevermore` on `PA14`, switched off
by `delayed_gcode`. Config in [`nevermore.cfg`](nevermore.cfg).

### Mellow Daylight

RGB LED bar, two-piece kit wired as a single chain. `neopixel caselight`
on `PD1`, `chain_count: 25`, `color_order: GRB`, white at 30 % on boot.
Declared in
[`stealthburner_led_effects_barf_fan.cfg`](stealthburner_led_effects_barf_fan.cfg).

### Funssor titanium backers

X/Y extrusion backers and gantry support plates. Mechanical only — no
configuration footprint.

### KNOMI V1

Toolhead display, a standalone ESP32 at `192.168.1.214`. Runs the
[DiverOfDark](https://github.com/DiverOfDark/KNOMI) firmware v2.5.0
(flashed 2026-09-19): GIFs are swapped from its web UI, no reflash needed.
The status animations come from [`KNOMI.cfg`](KNOMI.cfg). WiFi and the
Moonraker IP live on the device, so this repository cannot restore those.

### Also in the config

Fysetc Mini12864 display (`neopixel fysetc_mini12864`) and temperature
sensors for chamber, electronics, environment, Pi and Spider.

## Tuned values

| | |
|---|---|
| Motion | `max_velocity 450`, `max_accel 3200`, `max_z_velocity 15`, `max_z_accel 350`, `square_corner_velocity 5.0` |
| Travel | X 0–350, Y 0–355, Z -10–310 |
| Input shaper | X `mzv` 48.6 Hz, ζ 0.107 · Y `mzv` 34.2 Hz, ζ 0.128 |
| Extruder PID | 250 °C — `kp 36.152`, `ki 6.233`, `kd 52.423`, `control = pid_v` |
| Bed PID | 110 °C — `kp 31.199`, `ki 0.894`, `kd 272.215` |
| Bed mesh | 7×7 bicubic, `40,40` → `310,310` |

## Software addons

| Addon | Notes |
|---|---|
| [KAMP](https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging) | `KAMP_Settings.cfg`, `KAMP/Line_Purge.cfg` |
| [led_effect](https://github.com/julianschill/klipper-led_effect) | used by `stealthburner_led_effects_barf_fan.cfg` |
| [moonraker-telegram-bot](https://github.com/nlef/moonraker-telegram-bot) | `telegram.conf` |
| [moonraker-timelapse](https://github.com/mainsail-crew/moonraker-timelapse) | macros included; the `[timelapse]` block in `moonraker.conf` is commented out |
| [crowsnest](https://github.com/mainsail-crew/crowsnest) | `crowsnest.conf`, `cam 1` on `/dev/video0` |
| [sonar](https://github.com/mainsail-crew/sonar) | `sonar.conf`, `enable: false` |
| [Spoolman](https://github.com/Donkie/Spoolman) | off-printer at `192.168.1.218:7912` |

`stealthburner_leds.cfg` and `.moonraker.conf.bkp` still exist in
`~/printer_data/config` on the printer but are dead: the first was
superseded by the `led_effect` version, the second is a Moonraker
migration leftover. Both are gitignored here and pending deletion on the
printer.

## Secrets

`telegram.conf` carries `bot_token` and `chat_id` in clear text on the
printer. This repository is public, so both fields are stored here as
`REDACTED_VER_SECRETS_DIR`; the real values are kept outside the git
tree. Restoring that file needs them put back by hand.
