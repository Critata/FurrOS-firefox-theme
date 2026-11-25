#!/usr/bin/env bash
# Installs the FurrOS theme into the active Firefox profile.
# Firefox MUST be closed: user.js is read only at startup.
# Usage: ./install.sh [--profile /path/to/profile] [--force] [--uninstall]

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PROFILE=""
UNINSTALL=0
FORCE=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --profile PATH   Use this Firefox profile instead of detecting it
  --force          Install even if Firefox is running (not recommended)
  --uninstall      Remove the theme files (backups are kept)
  -h, --help       Show this message

Important: close Firefox completely before running this script.
The theme files are read only when Firefox starts.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { echo "Error: --profile requires a path." >&2; exit 1; }
      PROFILE="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
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

if [[ "$FORCE" -ne 1 ]] && { pgrep -x firefox >/dev/null 2>&1 || pgrep -f 'org.mozilla.firefox|firefox-bin' >/dev/null 2>&1; }; then
  echo "Error: Firefox is still running." >&2
  echo "Close every Firefox window completely, then run the installer again." >&2
  echo "The theme files are loaded only at startup." >&2
  echo "If you really know what you are doing: ./install.sh --force" >&2
  exit 1
fi

if [[ -z "$PROFILE" ]]; then
  PROFILES=()
  declare -A SEEN=()
  for INI in \
    "$HOME/.config/mozilla/firefox/profiles.ini" \
    "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini" \
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini" \
    "$HOME/Library/Application Support/Firefox/Profiles/profiles.ini"; do
    [[ -f "$INI" ]] || continue
    while IFS= read -r p; do
      [[ -n "$p" && -d "$p" ]] || continue
      [[ -n "${SEEN[$p]:-}" ]] && continue
      SEEN[$p]=1
      PROFILES+=("$p")
    done < <(python3 - "$INI" <<'PY'
import configparser, os, sys
ini = sys.argv[1]
c = configparser.ConfigParser()
c.read(ini)
base = os.path.dirname(ini)
def path(section):
    p = c.get(section, "Path", fallback="").strip()
    return p if os.path.isabs(p) else os.path.join(base, p)
sections = [s for s in c.sections() if s.startswith("Profile")]
default = [s for s in sections if c.get(s, "Default", fallback="0") == "1"]
ordered = default + [s for s in sections if s not in default]
for s in ordered:
    print(path(s))
PY
)
  done

  if [[ ${#PROFILES[@]} -eq 0 ]]; then
    echo "Error: Firefox profile not found." >&2
    echo "Specify it with: ./install.sh --profile /path/to/profile" >&2
    exit 1
  elif [[ ${#PROFILES[@]} -eq 1 ]]; then
    PROFILE="${PROFILES[0]}"
  else
    echo "Multiple Firefox profiles found:"
    PS3="Choose the profile number: "
    select p in "${PROFILES[@]}"; do
      [[ -n "$p" ]] || { echo "Invalid choice." >&2; exit 1; }
      PROFILE="$p"
      break
    done
  fi
fi

if [[ ! -d "$PROFILE" ]]; then
  echo "Error: profile directory does not exist: $PROFILE" >&2
  exit 1
fi

CHROME="$PROFILE/chrome"
mkdir -p "$CHROME"

if [[ "$UNINSTALL" -eq 1 ]]; then
  rm -f "$CHROME/userChrome.css" "$CHROME/userContent.css" "$PROFILE/user.js"
  echo "FurrOS theme removed from: $PROFILE"
  echo "Start Firefox again to apply the change."
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

for f in userChrome.css userContent.css; do
  cmp -s "$SRC/$f" "$CHROME/$f" || { echo "Error: copy failed for $f" >&2; exit 1; }
done
cmp -s "$SRC/user.js" "$PROFILE/user.js" || { echo "Error: copy failed for user.js" >&2; exit 1; }

echo
echo "FurrOS theme installed in: $PROFILE"
echo "Previous files backed up with suffix .bak-$TS"
echo "Verified: all three theme files match the repository."
echo
echo "Now start Firefox. If it was open, close it completely first."
