#!/usr/bin/env bash
#
# backup-orca.sh — copia os perfis do OrcaSlicer (Windows) para orca/ neste
# repositório e publica no GitHub.
#
# Roda à mão no WSL do PC onde o Orca está instalado, depois de mexer nos
# perfis. Sem agendamento: só publica quando algo mudou.
#
# O que vem junto: os perfis de usuário (machine, filament, process) de
# %APPDATA%\OrcaSlicer\user\<conta>\. O OrcaSlicer.conf fica de fora: é
# estado de interface (janelas, arquivos recentes com caminhos pessoais) e
# muda a cada abertura.
#
# Segredos: um perfil de impressora pode guardar a chave de API e a senha
# do host de impressão (printhost_apikey, printhost_password...). O repo é
# público, então esses valores são redigidos no que vai para o git e
# guardados em claro em $SECRETS_DIR.
#
# Só o caminho orca/ é commitado, nunca o resto da árvore de trabalho.
#
# Uso:
#   ./scripts/backup-orca.sh             # copia, commita e dá push
#   ./scripts/backup-orca.sh --no-push   # copia e commita, sem push
#   ./scripts/backup-orca.sh --dry-run   # copia e mostra o diff, sem commitar
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO/orca"
SECRETS_DIR="${SECRETS_DIR:-$HOME/voron-backup-private}"
SECRETS_KEEP="${SECRETS_KEEP:-30}"

DO_PUSH=1
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-push) DO_PUSH=0 ;;
    --dry-run) DRY_RUN=1; DO_PUSH=0 ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merro:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. achar a pasta do Orca no Windows -----------------------------
if [ -z "${ORCA_DIR:-}" ]; then
  appdata="$(cmd.exe /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r')" || true
  [ -n "$appdata" ] && ORCA_DIR="$(wslpath "$appdata")/OrcaSlicer"
fi
[ -n "${ORCA_DIR:-}" ] && [ -d "$ORCA_DIR/user" ] \
  || die "pasta do OrcaSlicer não encontrada (defina ORCA_DIR)"
log "perfis em $ORCA_DIR/user"

# --- 2. espelhar os perfis -------------------------------------------
# Um subdiretório por conta (default = sem login). --delete para que um
# perfil apagado no Orca também suma do backup.
accounts=0
for acc in "$ORCA_DIR"/user/*/; do
  acc="$(basename "$acc")"
  mkdir -p "$DEST/$acc"
  rsync -a --delete --include='*/' --include='*.json' --include='*.info' --exclude='*' \
    "$ORCA_DIR/user/$acc/" "$DEST/$acc/"
  accounts=$((accounts + 1))
done
[ "$accounts" -gt 0 ] || die "nenhuma conta em $ORCA_DIR/user — abortando para não apagar nada"
log "$(find "$DEST" -name '*.json' | wc -l) perfis copiados"

# --- 3. segredos: guardar em claro fora do repo, redigir no repo ------
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
secrets_file="$SECRETS_DIR/orca-secrets-$(date +%Y%m%d-%H%M%S).json"
python3 - "$DEST" "$secrets_file" <<'PY'
import json, os, re, sys
dest, out = sys.argv[1], sys.argv[2]
# Chaves conhecidas mais qualquer uma com cara de credencial.
pattern = re.compile(r"(apikey|api_key|password|passwd|secret|token|access_code|printhost_user)", re.I)
found = {}
for root, _, files in os.walk(dest):
    for name in files:
        if not name.endswith(".json"):
            continue
        path = os.path.join(root, name)
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        hits = {k: v for k, v in data.items() if pattern.search(k) and v not in ("", None, [], [""])}
        if not hits:
            continue
        found[os.path.relpath(path, dest)] = hits
        for k in hits:
            data[k] = "REDACTED_VER_SECRETS_DIR"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=4, ensure_ascii=False)
            f.write("\n")
if found:
    with open(out, "w", encoding="utf-8") as f:
        json.dump(found, f, indent=2, ensure_ascii=False)
    os.chmod(out, 0o600)
    for path, hits in found.items():
        print(f"    redigido: {path}: {', '.join(hits)}")
PY
# Sem nenhum arquivo ainda o ls falha, e o pipefail derrubaria o script.
ls -1t "$SECRETS_DIR"/orca-secrets-*.json 2>/dev/null | tail -n +$((SECRETS_KEEP + 1)) | xargs -r rm -f || true

# --- 4. commit só de orca/ -------------------------------------------
cd "$REPO"
if [ -z "$(git status --porcelain -- orca)" ]; then
  log "nada mudou desde o último backup"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "--dry-run: mudanças detectadas, nada commitado"
  git status --short -- orca
  exit 0
fi

git add -A -- orca
git commit -q -m "Backup dos perfis do OrcaSlicer $(date +'%Y-%m-%d %H:%M')" -- orca
log "commitado: $(git log -1 --oneline)"

if [ "$DO_PUSH" -eq 1 ]; then
  # Outro backup pode ter publicado antes; o autostash protege edições
  # locais que não fazem parte deste commit.
  git pull -q --rebase --autostash origin "$(git rev-parse --abbrev-ref HEAD)"
  git push -q origin "$(git rev-parse --abbrev-ref HEAD)"
  log "push concluído"
else
  log "push pulado (--no-push)"
fi
