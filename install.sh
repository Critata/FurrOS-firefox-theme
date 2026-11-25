#!/usr/bin/env bash
# Installs the FurrOS theme into the active Firefox profile.
# Usage: ./install.sh [--profile /path/to/profile] [--uninstall]

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PROFILE=""
UNINSTALL=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --profile PATH   Use this Firefox profile instead of detecting it
  --uninstall      Remove the theme files (backups are kept)
  -h, --help       Show this message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { echo "Error: --profile requires a path." >&2; exit 1; }
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
      echo "Unknown option: $1" >&2
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
  echo "Error: Firefox profile not found." >&2
  echo "Specify it with: ./install.sh --profile /path/to/profile" >&2
  exit 1
fi

CHROME="$PROFILE/chrome"
mkdir -p "$CHROME"

if [[ "$UNINSTALL" -eq 1 ]]; then
  rm -f "$CHROME/userChrome.css" "$CHROME/userContent.css" "$PROFILE/user.js"
  echo "FurrOS theme removed from: $PROFILE"
  echo "Restart Firefox to apply the change."
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

echo "FurrOS theme installed in: $PROFILE"
echo "Previous files backed up with suffix .bak-$TS"
echo "Restart Firefox to see the theme."
