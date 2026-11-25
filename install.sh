#!/usr/bin/env bash
# Installa il tema FurrOS nel profilo Firefox attivo.
# Uso: ./install.sh [--profile /path/to/profile] [--uninstall]

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PROFILE=""
UNINSTALL=0

usage() {
  cat <<'EOF'
Uso: ./install.sh [opzioni]

Opzioni:
  --profile PATH   Usa questo profilo Firefox invece di rilevarlo
  --uninstall      Rimuove i file del tema (backup inclusi)
  -h, --help       Mostra questo messaggio
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { echo "Errore: --profile richiede un percorso." >&2; exit 1; }
      PROFILE="$2"
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Opzione sconosciuta: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PROFILE" ]]; then
  for INI in \
    "$HOME/.config/mozilla/firefox/profiles.ini" \
    "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini" \
    "$HOME/Library/Application Support/Firefox/Profiles/profiles.ini"; do
    [[ -f "$INI" ]] || continue
    PROFILE="$(python3 - "$INI" <<'PY'
import configparser, os, sys
ini = sys.argv[1]
c = configparser.ConfigParser()
c.read(ini)
base = os.path.dirname(ini)
def path(section):
    p = c.get(section, "Path", fallback="").strip()
    return p if os.path.isabs(p) else os.path.join(base, p)
for s in c.sections():
    if s.startswith("Profile") and c.get(s, "Default", fallback="0") == "1":
        print(path(s)); break
else:
    for s in c.sections():
        if s.startswith("Profile"):
            print(path(s)); break
PY
)"
    [[ -n "$PROFILE" ]] && break
  done
fi

if [[ -z "$PROFILE" || ! -d "$PROFILE" ]]; then
  echo "Errore: profilo Firefox non trovato." >&2
  echo "Indicalo con: ./install.sh --profile /percorso/del/profilo" >&2
  exit 1
fi

CHROME="$PROFILE/chrome"
mkdir -p "$CHROME"

if [[ "$UNINSTALL" -eq 1 ]]; then
  rm -f "$CHROME/userChrome.css" "$CHROME/userContent.css" "$PROFILE/user.js"
  echo "Tema FurrOS rimosso da: $PROFILE"
  echo "Riavvia Firefox per applicare la modifica."
  exit 0
fi

TS="$(date +%Y%m%d-%H%M%S)"
for f in userChrome.css userContent.css; do
  if [[ -f "$CHROME/$f" ]]; then
    cp "$CHROME/$f" "$CHROME/$f.bak-$TS"
  fi
done
if [[ -f "$PROFILE/user.js" ]]; then
  cp "$PROFILE/user.js" "$PROFILE/user.js.bak-$TS"
fi

cp "$SRC/userChrome.css" "$CHROME/userChrome.css"
cp "$SRC/userContent.css" "$CHROME/userContent.css"
cp "$SRC/user.js" "$PROFILE/user.js"

echo "Tema FurrOS installato in: $PROFILE"
echo "Backup dei vecchi file salvati con suffisso .bak-$TS"
echo "Riavvia Firefox per vedere il tema."
