#!/usr/bin/env bash
#
# flash-mcus.sh — builds Kalico and flashes both MCUs through Katapult.
#
# Runs ON THE PI (pi@mainsailos). It is docs/updating-kalico-firmware.md
# turned into a script, with the runbook's pitfalls checked instead of
# remembered.
#
#   - each board is built in its own OUT dir from a temp copy of its saved
#     .config, so out/klipper.bin is never shared and the saved configs are
#     never rewritten (pitfall 1);
#   - the build is rejected if olddefconfig changed or dropped any saved
#     option, or if a required option (MCU, Katapult offset, CAN/USB pins,
#     crystal, USB serial) is missing;
#   - before writing, the board is put in Katapult and asked for its MCU type
#     and application start address; both must match the build;
#   - flashing always goes through Katapult's flashtool.py, never `make flash`;
#   - --flash must run inside tmux or screen: an SSH drop outside them kills
#     the terminal that sudo and the script's output depend on;
#   - klipper is confirmed stopped before flashing (pitfall 3) and started
#     again on any exit, through Moonraker first (needs no terminal);
#     hangup/Ctrl-C/TERM are ignored while firmware is written.
#
# What can go wrong, and what to do:
#   - A board that stopped IN Katapult (no firmware written, or a write that
#     failed and was reported) is fine: do NOT power-cycle it, rerun
#     `--flash --only <board>` and it is picked up from Katapult.
#   - A write cut off half-way AND followed by a reset/power-cycle leaves a
#     partial app that Katapult jumps into. That board needs a double-tap of
#     its reset button to get back to Katapult — for the EBB that means
#     reaching the toolhead. Hence: never power-cycle during or after a
#     failed flash, rerun instead.
#   - Katapult has no timeout: a board left in it stays there until flashed
#     or reset.
#
# Usage:
#   bash flash-mcus.sh --check     # build + all checks, touches no hardware (default)
#   tmux new -s flash              # then, inside tmux:
#   bash flash-mcus.sh --flash     # build, check, flash EBBCan then Spider
#   bash flash-mcus.sh --flash --only ebb|spider
#
set -euo pipefail

KLIPPER="${KLIPPER:-$HOME/klipper}"
KATAPULT="${KATAPULT:-$HOME/katapult}"
FLASHTOOL="$KATAPULT/scripts/flashtool.py"
VERSIONED_CONFIGS="$HOME/printer_data/config/klipper-config"
API="http://localhost:7125"
CURL=(curl -sf --max-time 10)

CAN_IF="can0"
EBB_UUID="7f0f5f137d50"
SPIDER_ID="stm32f446xx_2C003F001351303530323539"
SPIDER_KLIPPER="/dev/serial/by-id/usb-Klipper_${SPIDER_ID}-if00"
SPIDER_KATAPULT="/dev/serial/by-id/usb-katapult_${SPIDER_ID}-if00"

EBB_CONFIG="$KLIPPER/.config-sb2209"
EBB_MCU="stm32g0b1xx"
EBB_START="0x8002000"
EBB_REQUIRED=(CONFIG_MACH_STM32G0B1=y CONFIG_STM32_FLASH_START_2000=y
              CONFIG_FLASH_APPLICATION_ADDRESS=0x8002000 CONFIG_CANSERIAL=y
              CONFIG_STM32_CANBUS_PB0_PB1=y CONFIG_STM32_CLOCK_REF_8M=y
              CONFIG_CANBUS_FREQUENCY=1000000)
SPIDER_CONFIG="$KLIPPER/.config-esoterical-usb-spider"
SPIDER_MCU="stm32f446xx"
SPIDER_START="0x8008000"
SPIDER_REQUIRED=(CONFIG_MACH_STM32F446=y CONFIG_STM32_FLASH_START_8000=y
                 CONFIG_FLASH_APPLICATION_ADDRESS=0x8008000 CONFIG_USBSERIAL=y
                 CONFIG_STM32_USB_PA11_PA12=y CONFIG_STM32_CLOCK_REF_12M=y
                 CONFIG_USB_SERIAL_NUMBER_CHIPID=y)

MODE=check
ONLY=both
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --flash) MODE=flash ;;
    --only) shift; ONLY="${1:-}"; [[ "$ONLY" =~ ^(ebb|spider)$ ]] || { echo "--only takes ebb or spider" >&2; exit 2; } ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
do_ebb()    { [ "$ONLY" = both ] || [ "$ONLY" = ebb ]; }
do_spider() { [ "$ONLY" = both ] || [ "$ONLY" = spider ]; }

# Output is best-effort: a write to a dead terminal must never abort the
# script halfway through a flash.
log()  { printf '\033[36m==>\033[0m %s\n' "$*" 2>/dev/null || true; }
ok()   { printf '    \033[32mok\033[0m %s\n' "$*" 2>/dev/null || true; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2 2>/dev/null || true; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2 2>/dev/null || true; exit 1; }
show() { cat "$1" 2>/dev/null || true; }

WORK="$(mktemp -d /tmp/flash-mcus.XXXXXX)"
KLIPPER_STOPPED=0

klipper_active() { [ "$(systemctl is-active klipper 2>/dev/null || true)" = active ]; }
# Moonraker needs no terminal, so it works after an SSH drop; sudo is the
# fallback.
start_klipper() {
  "${CURL[@]}" -X POST "$API/machine/services/start?service=klipper" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do klipper_active && return 0; sleep 1; done
  sudo -n service klipper start >/dev/null 2>&1 || sudo service klipper start >/dev/null 2>&1 || true
  klipper_active
}

# The trap must never die before klipper is back: errexit off, signals
# ignored, the restart first.
cleanup() {
  local rc=$?
  set +e
  trap '' PIPE HUP INT TERM
  if [ "$KLIPPER_STOPPED" -eq 1 ]; then
    if start_klipper; then
      log "klipper started again"
    else
      printf 'ERROR: klipper is STOPPED — run: sudo service klipper start\n' >&2 2>/dev/null
    fi
  fi
  if [ $rc -ne 0 ]; then
    warn "stopped with an error. Logs kept in $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

printer_state() {
  "${CURL[@]}" "$API/printer/objects/query?print_stats=state" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' 2>/dev/null \
    || echo unknown
}
# Refuses to go on while printing; in --flash mode an unknown state is fatal
# too, because it may hide a running print.
check_idle() {
  local st; st="$(printer_state)"
  case "$st" in
    printing|paused) die "printer is $st — refusing to touch the MCUs" ;;
    unknown)
      [ "$MODE" = check ] && { warn "could not read the printer state from Moonraker"; return 0; }
      die "could not read the printer state from Moonraker — not flashing blind" ;;
  esac
  ok "printer state: $st"
}

# --- 0. preconditions -----------------------------------------------------
log "preconditions"
if [ "$MODE" = flash ] && [ -z "${TMUX:-}" ] && [ -z "${STY:-}" ]; then
  die "--flash must run inside tmux or screen (an SSH drop would otherwise
       kill the script mid-flash). Run: tmux new -s flash   — then rerun this."
fi
[ -d "$KLIPPER/.git" ] || die "$KLIPPER is not a git checkout"
[ -f "$FLASHTOOL" ] || die "flashtool.py not found at $FLASHTOOL"
HOST_VERSION="$(git -C "$KLIPPER" describe --always --tags --long --dirty)"
ok "host Kalico: $HOST_VERSION"
check_idle

# Pitfall 6: the saved configs live in ~/klipper, the versioned copies in
# printer_data. They must be identical, or it is unclear which is right.
for pair in "$EBB_CONFIG:.config-sb2209" "$SPIDER_CONFIG:.config-esoterical-usb-spider"; do
  src="${pair%%:*}"; ver="$VERSIONED_CONFIGS/${pair##*:}"
  [ -f "$src" ] || die "saved config missing: $src"
  if [ ! -f "$ver" ]; then
    warn "no versioned copy of $(basename "$src") in $VERSIONED_CONFIGS"
  elif ! cmp -s "$src" "$ver"; then
    msg="$(basename "$src") differs from the versioned copy in $VERSIONED_CONFIGS (runbook pitfall 6)"
    [ "$MODE" = flash ] && die "$msg"
    warn "$msg"
  else
    ok "$(basename "$src") matches the versioned copy"
  fi
done

# --- 1. build + check -----------------------------------------------------
# Firmware built from a dirty tree carries a -<date>-<host> suffix; compare
# without it.
base_version() { sed -E 's/-[0-9]{8}_[0-9]{6}-[^-]+$//' <<<"$1"; }

# One NAME=value per option, "# CONFIG_X is not set" as CONFIG_X=n, so a
# switch between unset and set is seen as a change.
norm_config() {
  sed -nE -e 's/^# (CONFIG_[A-Za-z0-9_]+) is not set$/\1=n/p' -e '/^CONFIG_/p' "$1" | tr -d '\r' | sort -u
}

# build <name> <saved config> <expected mcu> <required lines...>
build() {
  local name="$1" saved="$2" mcu="$3"; shift 3
  local cfg="$WORK/$name.config" out="$WORK/out-$name/"
  log "building $name from $(basename "$saved")"
  cp "$saved" "$cfg"
  # Non-interactive stand-in for "make menuconfig, just save": fills in
  # options added by the new version with their defaults.
  make -C "$KLIPPER" -s KCONFIG_CONFIG="$cfg" OUT="$out" olddefconfig >/dev/null

  # A saved option that changed value, or that was set and is now hidden by
  # a dependency, means the build differs from what was saved — the board
  # could come up on the wrong pins or clock, so stop. Options no Kconfig in
  # this tree defines any more (stale leftovers, e.g. from mainline Klipper)
  # and options that were "not set" and vanished change nothing: warn only.
  local removed added changed="" stale="" line sym val
  removed="$(comm -23 <(norm_config "$saved") <(norm_config "$cfg"))"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sym="${line%%=*}"; val="${line#*=}"
    if grep -q "^${sym}=" <(norm_config "$cfg"); then
      changed+="$line (now $(grep "^${sym}=" <(norm_config "$cfg") | cut -d= -f2-))"$'\n'
    elif [ "$val" = n ]; then
      stale+="$line (not set, no longer shown)"$'\n'
    elif ! find "$KLIPPER/src" -name 'Kconfig*' -print0 \
           | xargs -0 grep -qE "^[[:space:]]*(menu)?config ${sym#CONFIG_}[[:space:]]*$"; then
      stale+="$line (not defined by this Kalico)"$'\n'
    else
      changed+="$line (now hidden by a dependency)"$'\n'
    fi
  done <<<"$removed"
  if [ -n "$stale" ]; then
    warn "$name: saved options that no longer exist — ignored, they change nothing:"
    printf '%s' "$stale" | sed 's/^/      /' >&2 2>/dev/null || true
  fi
  if [ -n "$changed" ]; then
    printf '%s' "$changed" | sed 's/^/      /' >&2 2>/dev/null || true
    die "$name: olddefconfig changed the saved options above — review with make menuconfig"
  fi
  added="$(comm -13 <(norm_config "$saved") <(norm_config "$cfg"))"
  if [ -n "$added" ]; then
    warn "$name: new options set to their defaults:"
    printf '%s\n' "$added" | sed 's/^/      /' >&2 2>/dev/null || true
  fi

  for line in "$@"; do
    grep -Fqx "$line" "$cfg" || die "$name: '$line' missing from the config — not flashing"
  done
  ok "config has: $*"

  make -C "$KLIPPER" -s KCONFIG_CONFIG="$cfg" OUT="$out" -j"$(nproc)" >"$WORK/$name.build.log" 2>&1 \
    || { tail -20 "$WORK/$name.build.log" >&2 2>/dev/null; die "$name: build failed (log: $WORK/$name.build.log)"; }
  [ -s "$out/klipper.bin" ] || die "$name: $out/klipper.bin was not produced"

  # The data dictionary baked into the build says which MCU it targets and
  # which version it is — checked here, before the board is touched.
  local info bin_mcu bin_ver
  info="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["config"]["MCU"], d["version"])' \
          "$out/klipper.dict" 2>/dev/null)" || die "$name: cannot read $out/klipper.dict"
  read -r bin_mcu bin_ver <<<"$info"
  [ "$bin_mcu" = "$mcu" ] || die "$name: firmware was built for $bin_mcu, expected $mcu — not flashing"
  [ "$(base_version "$bin_ver")" = "$HOST_VERSION" ] \
    || warn "$name: firmware version $bin_ver differs from host $HOST_VERSION"
  ok "firmware: MCU $bin_mcu, version $bin_ver, $(stat -c %s "$out/klipper.bin") bytes"
}

do_ebb    && build ebb    "$EBB_CONFIG"    "$EBB_MCU"    "${EBB_REQUIRED[@]}"
do_spider && build spider "$SPIDER_CONFIG" "$SPIDER_MCU" "${SPIDER_REQUIRED[@]}"

if [ "$MODE" = check ]; then
  log "--check: everything built and checked, nothing was stopped or flashed"
  log "to write the firmware: tmux new -s flash, then rerun with --flash"
  exit 0
fi

# --- 2. stop klipper ------------------------------------------------------
sudo -v || die "sudo failed — klipper cannot be stopped"
check_idle   # again: the build takes minutes, a print may have started
# From here until klipper is back, a hangup, Ctrl-C or TERM must not kill
# flashtool halfway through a write. Children inherit the ignored signals.
trap '' HUP INT TERM
log "stopping klipper"
KLIPPER_STOPPED=1
sudo service klipper stop
! klipper_active || die "klipper is still running after stop"
ok "klipper stopped"

IN_KATAPULT_MSG="do NOT power-cycle the board; rerun with --flash --only"

# katapult_probe <name> <expected start> <expected mcu> <flashtool target args...>
# Asks the board, already in Katapult, for its real MCU and application start
# (-s writes nothing and leaves it in Katapult).
katapult_probe() {
  local name="$1" start="$2" mcu="$3"; shift 3
  local plog="$WORK/$name.probe.log"
  python3 "$FLASHTOOL" "$@" -s -f "$WORK/out-$name/klipper.bin" >"$plog" 2>&1 \
    || { show "$plog" >&2; die "$name: could not talk to Katapult — nothing was written. The board may be waiting in Katapult: $IN_KATAPULT_MSG $name"; }
  grep -qx "Application Start: $start" "$plog" \
    || { show "$plog" >&2; die "$name: Katapult's application start is not $start — nothing was written. The board is waiting in Katapult; power-cycle it to return to the old firmware"; }
  grep -qx "MCU type: $mcu" "$plog" \
    || { show "$plog" >&2; die "$name: Katapult reports a different MCU than $mcu — nothing was written. The board is waiting in Katapult; power-cycle it to return to the old firmware"; }
  ok "Katapult: MCU $mcu, application start $start"
}

# flash <name> <flashtool target args...> — fails unless flashtool exits 0 AND
# reports "Programming Complete". Output goes to a file first, then is shown,
# so a dead terminal cannot fail the write.
flash() {
  local name="$1"; shift
  local flog="$WORK/$name.flash.log" rc=0
  python3 "$FLASHTOOL" "$@" -f "$WORK/out-$name/klipper.bin" >"$flog" 2>&1 || rc=$?
  show "$flog"
  [ "$rc" -eq 0 ] || die "$name: flashtool failed (rc $rc, log: $flog) — $IN_KATAPULT_MSG $name"
  grep -q "Programming Complete" "$flog" \
    || die "$name: flashtool did not report 'Programming Complete' (log: $flog) — $IN_KATAPULT_MSG $name"
}

# --- 3. EBBCan over CAN ---------------------------------------------------
if do_ebb; then
  log "flashing EBBCan (CAN $CAN_IF, UUID $EBB_UUID)"
  # Klipper's reboot-to-bootloader request; Katapult ignores it if the board
  # is already there. -s below fails cleanly if the jump did not happen.
  python3 "$FLASHTOOL" -i "$CAN_IF" -u "$EBB_UUID" -r >"$WORK/ebb.request.log" 2>&1 || true
  katapult_probe ebb "$EBB_START" "$EBB_MCU" -i "$CAN_IF" -u "$EBB_UUID"
  flash ebb -i "$CAN_IF" -u "$EBB_UUID"
  ok "EBBCan flashed"
fi

# --- 4. Spider over USB ---------------------------------------------------
if do_spider; then
  log "flashing Spider (USB)"
  if [ -e "$SPIDER_KATAPULT" ]; then
    ok "Spider is already in Katapult"
  else
    [ -e "$SPIDER_KLIPPER" ] || die "Spider not found at $SPIDER_KLIPPER nor $SPIDER_KATAPULT (ls /dev/serial/by-id/)"
    python3 "$FLASHTOOL" -d "$SPIDER_KLIPPER" -r >"$WORK/spider.request.log" 2>&1 || true
    show "$WORK/spider.request.log"
    for _ in $(seq 1 75); do [ -e "$SPIDER_KATAPULT" ] && break; sleep 0.2; done
    [ -e "$SPIDER_KATAPULT" ] || die "Spider did not show up at $SPIDER_KATAPULT — nothing was written.
       Check 'ls /dev/serial/by-id/'. If it lists usb-katapult_..., the board is waiting
       in Katapult: $IN_KATAPULT_MSG spider"
    ok "Spider is in Katapult: $SPIDER_KATAPULT"
  fi
  katapult_probe spider "$SPIDER_START" "$SPIDER_MCU" -d "$SPIDER_KATAPULT"
  flash spider -d "$SPIDER_KATAPULT"
  ok "Spider flashed"
fi

# --- 5. start klipper and verify ------------------------------------------
log "starting klipper"
start_klipper || die "klipper did not start — run: sudo service klipper start"
KLIPPER_STOPPED=0
trap - HUP INT TERM

log "waiting for klipper to report the MCU versions"
query_state() {
  "${CURL[@]}" "$API/printer/info" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["state"])' 2>/dev/null || echo down
}
st=down
for i in $(seq 1 45); do
  st="$(query_state)"
  [ "$st" = ready ] && break
  # A board left in shutdown by the service stop needs a firmware restart.
  if { [ "$st" = error ] || [ "$st" = shutdown ]; } && [ $((i % 10)) -eq 0 ]; then
    warn "klipper is in $st — sending FIRMWARE_RESTART"
    "${CURL[@]}" -X POST "$API/printer/firmware_restart" >/dev/null 2>&1 || true
  fi
  sleep 2
done
[ "$st" = ready ] || die "klipper is not ready ($st) — check klippy.log"

# Report only: with --only, the other board legitimately keeps its old version.
"${CURL[@]}" "$API/printer/objects/query?mcu&mcu%20EBBCan" > "$WORK/mcu.json" \
  || die "could not query the MCU versions from Moonraker"
python3 - "$HOST_VERSION" "$WORK/mcu.json" <<'PY' 2>/dev/null || true
import json, re, sys
host = sys.argv[1]
status = json.load(open(sys.argv[2]))["result"]["status"]
for name, obj in status.items():
    ver = obj.get("mcu_version") or ""
    base = re.sub(r"-\d{8}_\d{6}-[^-]+$", "", ver)
    print(f"    {'ok' if base == host else 'MISMATCH':8} {name}: {ver}")
print(f"    {'':8} host: {host}")
PY
log "done — run QUERY_ENDSTOPS and a dry homing before printing"
