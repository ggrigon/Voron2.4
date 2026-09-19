#!/usr/bin/env bash
#
# backup-spoolman.sh — exporta o Spoolman para state/spoolman/.
#
# Só GET na API REST. Não escreve nada no Spoolman e não mexe no git —
# quem commita é o backup-printer.sh, que chama este script antes de
# fechar o commit. Rodando sozinho, ele só atualiza os arquivos.
#
# LIMITE IMPORTANTE: isto é um dump lógico, não uma cópia do SQLite.
# Restaurar significa re-POSTar os registros, e o Spoolman atribui IDs
# novos — o `spool_id` que o Moonraker guarda como bobina ativa não
# sobrevive. Para restauração fiel é preciso o arquivo
# ~/.local/share/spoolman/spoolman.db do host do Spoolman. Veja o README.
#
set -euo pipefail

SPOOLMAN_URL="${SPOOLMAN_URL:-http://192.168.1.218:7912}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/state/spoolman"
CURL=(curl -sf --connect-timeout 10 --max-time 60)

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merro:\033[0m %s\n' "$*" >&2; exit 1; }

log "contatando Spoolman em $SPOOLMAN_URL"
info="$("${CURL[@]}" "$SPOOLMAN_URL/api/v1/info")" || die "Spoolman não respondeu"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
ver, db, auto = d["version"], d["db_type"], d["automatic_backups"]
print("    Spoolman %s (%s), backups automaticos: %s" % (ver, db, auto))
' "$info"

mkdir -p "$OUT"
printf '%s' "$info" | python3 -m json.tool --sort-keys > "$OUT/info.json"

# `allow_archived=true` importa: sem ele o endpoint omite as bobinas
# arquivadas, que são justamente as que carregam o histórico de consumo.
fetch() {  # fetch <arquivo> <caminho-da-api>
  "${CURL[@]}" "$SPOOLMAN_URL/$2" | python3 -m json.tool --sort-keys > "$OUT/$1" \
    || die "falhou ao exportar $1"
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
n = len(d) if isinstance(d, list) else len(d.keys())
print("    %-12s %d registros" % (sys.argv[2], n))
' "$OUT/$1" "${1%.json}"
}

log "exportando"
fetch vendors.json   "api/v1/vendor"
fetch filaments.json "api/v1/filament"
fetch spools.json    "api/v1/spool?allow_archived=true"
fetch settings.json  "api/v1/setting/"

log "escrito em state/spoolman/"
