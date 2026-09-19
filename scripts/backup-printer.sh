#!/usr/bin/env bash
#
# backup-printer.sh — puxa o estado da Voron 2.4 para este repositório.
#
# Roda a partir do PC, não da impressora: se o Pi estiver meio quebrado
# o backup ainda acontece, e nenhum token do GitHub precisa morar no SD.
# Usa exclusivamente a API HTTP do Moonraker, só GET. Nada é escrito na
# impressora.
#
# O que vem junto:
#   - todos os arquivos de ~/printer_data/config (inclui o SAVE_CONFIG
#     com mesh, PID e z_offset, que é o que dói perder)
#   - os namespaces do banco do Moonraker (histórico, spoolman, webcams)
#   - o histórico de jobs e o snapshot de versões dos componentes
#
# Segredos (bot_token do Telegram etc.) são redigidos antes do commit e
# gravados em claro em $SECRETS_DIR, fora da árvore do git. O repositório
# é público — essa separação não é opcional.
#
# Uso:
#   ./scripts/backup-printer.sh                 # puxa, commita e dá push
#   ./scripts/backup-printer.sh --no-push       # puxa e commita, sem push
#   ./scripts/backup-printer.sh --dry-run       # puxa e mostra o diff, sem commitar
#
set -euo pipefail

PRINTER_HOST="${PRINTER_HOST:-192.168.1.14}"
PRINTER_PORT="${PRINTER_PORT:-7125}"
API="http://${PRINTER_HOST}:${PRINTER_PORT}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-$HOME/voron-backup-private}"
SECRETS_KEEP="${SECRETS_KEEP:-30}"
CURL=(curl -sf --connect-timeout 10 --max-time 120)

DO_PUSH=1
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-push) DO_PUSH=0 ;;
    --dry-run) DRY_RUN=1; DO_PUSH=0 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merro:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. a impressora está de pé? -------------------------------------
# A impressora é desligada à noite; o Spoolman fica no ar. Um cron num
# host sempre ligado não pode perder o Spoolman só porque a Voron está
# fora — então aqui a impressora é opcional, e o que aborta de verdade é
# não conseguir falar com nada (ver o fim da seção 5).
PRINTER_OK=1
log "contatando ${PRINTER_HOST}"
if ! info="$("${CURL[@]}" "$API/printer/info")"; then
  printf '\033[33maviso:\033[0m Moonraker não respondeu em %s — pulando a impressora\n' "$API" >&2
  PRINTER_OK=0
  info=""
fi
if [ "$PRINTER_OK" -eq 1 ]; then
python3 - "$info" <<'PY'
import json, sys
r = json.loads(sys.argv[1])["result"]
print(f"    {r['app']} {r['software_version']} em {r['hostname']} — estado: {r['state']}")
PY
fi

if [ "$PRINTER_OK" -eq 1 ]; then
# ---- início do bloco que depende da impressora ----------------------

# --- 2. arquivos de config -------------------------------------------
# Symlinks herdados do host antigo (/home/biqu, quando a impressora
# rodava num BTT CB1) apontam para caminhos que não existem mais.
# Escrever através deles gravaria fora do repositório — e um symlink de
# diretório quebrado nem deixa o mkdir -p passar. Backup guarda conteúdo,
# não ponteiro: os quebrados vão embora.
broken=0
while IFS= read -r link; do
  [ -e "$link" ] && continue
  echo "    symlink quebrado removido: ${link#$REPO/} -> $(readlink "$link")"
  rm -f "$link"
  broken=$((broken + 1))
done < <(find "$REPO" -path "$REPO/.git" -prune -o -type l -print)
[ "$broken" -gt 0 ] && log "$broken symlink(s) obsoleto(s) substituído(s) por arquivos reais"

log "baixando ~/printer_data/config"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
"${CURL[@]}" "$API/server/files/list?root=config" \
  | python3 -c 'import json,sys; [print(f["path"]) for f in json.load(sys.stdin)["result"]]' \
  | sort > "$manifest"

[ -s "$manifest" ] || die "a listagem de config voltou vazia — abortando para não apagar nada"

count=0
while IFS= read -r path; do
  dest="$REPO/$path"
  mkdir -p "$(dirname "$dest")" || die "não consegui criar $(dirname "$path") — symlink no caminho?"
  [ -L "$dest" ] && rm -f "$dest"
  "${CURL[@]}" -o "$dest" "$API/server/files/config/$path" || { echo "    falhou: $path" >&2; continue; }
  count=$((count + 1))
done < "$manifest"
log "$count arquivos de config recebidos"

mkdir -p "$REPO/state"
cp "$manifest" "$REPO/state/config-manifest.txt"
chmod 644 "$REPO/state/config-manifest.txt"   # mktemp cria 600

# --- 3. segredos: guardar em claro fora do repo, redigir no repo ------
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
secret_files=()
while IFS= read -r path; do
  case "$path" in
    telegram.conf|*/telegram.conf|moonraker.secrets|*.secret) secret_files+=("$path") ;;
  esac
done < "$manifest"

if [ ${#secret_files[@]} -gt 0 ]; then
  tar -czf "$SECRETS_DIR/secrets-$stamp.tar.gz" -C "$REPO" "${secret_files[@]}"
  chmod 600 "$SECRETS_DIR/secrets-$stamp.tar.gz"
  log "valores reais dos segredos em $SECRETS_DIR/secrets-$stamp.tar.gz"
  # retenção
  ls -1t "$SECRETS_DIR"/secrets-*.tar.gz 2>/dev/null | tail -n +$((SECRETS_KEEP + 1)) | xargs -r rm -f
fi

# Redige no que vai para o git. A lista de chaves é conservadora: se uma
# chave nova aparecer no config, ela vaza — por isso o resumo abaixo.
redacted="$REPO/state/secrets-redacted.txt"
: > "$redacted"
for path in "${secret_files[@]}"; do
  f="$REPO/$path"
  [ -f "$f" ] || continue
  while IFS= read -r key; do
    if grep -qiE "^[[:space:]]*${key}[[:space:]]*[:=]" "$f"; then
      echo "$path: $key" >> "$redacted"
      sed -i -E "s|^([[:space:]]*${key}[[:space:]]*[:=]).*|\1 REDACTED_VER_SECRETS_DIR|I" "$f"
    fi
  done <<< $'bot_token\nchat_id\napi_key\napi_token\npassword\nsecret\naccess_token\nwebhook'
done
if [ -s "$redacted" ]; then
  log "redigido antes do commit:"
  sed 's/^/    /' "$redacted"
fi

# --- 4. estado do Moonraker (o que o git de config não cobre) ---------
log "exportando banco e histórico do Moonraker"
mkdir -p "$REPO/state/database"
for ns in moonraker mainsail webcams maintenance update_manager; do
  "${CURL[@]}" "$API/server/database/item?namespace=$ns" \
    | python3 -m json.tool --sort-keys > "$REPO/state/database/$ns.json" \
    || echo "    falhou: namespace $ns" >&2
done
# gcode_metadata fica de fora: é grande e o Moonraker reconstrói sozinho.

"${CURL[@]}" "$API/server/history/list?limit=5000&start=0" \
  | python3 -m json.tool --sort-keys > "$REPO/state/print-history.json" || true
"${CURL[@]}" "$API/server/history/totals" \
  | python3 -m json.tool --sort-keys > "$REPO/state/print-totals.json" || true

log "registrando versões dos componentes"
sysinfo="$("${CURL[@]}" "$API/machine/system_info")"
updinfo="$("${CURL[@]}" "$API/machine/update/status?refresh=false")"
# Os JSONs vão por argv, não por stdin: o heredoc que carrega o script
# Python já ocupa o stdin do interpretador.
python3 - "$sysinfo" "$updinfo" > "$REPO/state/system-snapshot.md" <<'PYSNAP'
import json, sys
si = json.loads(sys.argv[1])["result"]["system_info"]
up = json.loads(sys.argv[2])["result"]["version_info"]
cpu, sd, dist = si["cpu_info"], si.get("sd_info", {}), si["distribution"]
out = []
out.append("# Snapshot da impressora\n")
out.append("Gerado por `scripts/backup-printer.sh`. Nao editar a mao.\n")
out.append("## Hardware\n")
out.append(f"- {cpu['model']} - {cpu['cpu_count']} nucleos, {int(cpu['total_memory'])/1024:.0f} MB RAM")
if sd:
    out.append(f"- Cartao SD: {sd.get('manufacturer')} {sd.get('product_name')} "
               f"{sd.get('capacity')} - fabricado em {sd.get('manufacturer_date')}")
out.append(f"- {dist['release_info']['name']} {dist['release_info']['version_id']} "
           f"({dist['name']}), kernel {dist['kernel_version']}")
for name, cfg in si.get("canbus", {}).items():
    out.append(f"- CAN {name}: {int(cfg['bitrate'])/1000:.0f} kbit/s via {cfg['driver']}")
out.append("\n## Servicos\n")
for svc, st in sorted(si.get("service_state", {}).items()):
    mark = "ok" if st["active_state"] == "active" else f"**{st['active_state']}**"
    out.append(f"- {svc}: {mark}")
out.append("\n## Versoes\n")
out.append("| componente | instalado | disponivel |")
out.append("|---|---|---|")
for name, v in up.items():
    if name == "system":
        out.append(f"| pacotes APT | - | {v.get('package_count', 0)} pendentes |")
        continue
    cur, rem = v.get("version"), v.get("remote_version")
    flag = "" if cur == rem else " (!)"
    out.append(f"| {name} | {cur} | {rem}{flag} |")
print("\n".join(out))
PYSNAP

# ---- fim do bloco que depende da impressora -------------------------
fi

# --- 5. Spoolman (host separado, falha não aborta o backup) ----------
SPOOLMAN_OK=0
if [ -x "$REPO/scripts/backup-spoolman.sh" ]; then
  if "$REPO/scripts/backup-spoolman.sh"; then
    SPOOLMAN_OK=1
  else
    printf '\033[33maviso:\033[0m Spoolman não respondeu — seguindo sem ele\n' >&2
  fi
fi

if [ "$PRINTER_OK" -eq 0 ] && [ "$SPOOLMAN_OK" -eq 0 ]; then
  die "nem a impressora nem o Spoolman responderam — nada foi coletado"
fi

# --- 6. commit ---------------------------------------------------------
cd "$REPO"
if [ -z "$(git status --porcelain)" ]; then
  log "nada mudou desde o último backup"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "--dry-run: mudanças detectadas, nada commitado"
  git status --short
  exit 0
fi

git add -A
if [ "$PRINTER_OK" -eq 1 ]; then
  klipper_ver="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["result"]["software_version"])' "$info")"
  origem="impressora ${PRINTER_HOST} (Kalico $klipper_ver)"
else
  origem="impressora OFFLINE — não coletada"
fi
[ "$SPOOLMAN_OK" -eq 1 ] && origem="$origem + Spoolman" || origem="$origem; Spoolman offline"
git commit -q -m "Backup automático $(date +'%Y-%m-%d %H:%M')" -m "Origem: $origem"
log "commitado: $(git log -1 --oneline)"

if [ "$DO_PUSH" -eq 1 ]; then
  git push -q origin "$(git rev-parse --abbrev-ref HEAD)"
  log "push concluído"
else
  log "push pulado (--no-push)"
fi
