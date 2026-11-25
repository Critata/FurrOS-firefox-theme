#!/usr/bin/env bash
# Installs the FurrOS theme into the active Firefox profile.
# Firefox MUST be closed: user.js is read only at startup.
# Usage: ./install.sh [--profile /path/to/profile] [--force] [--uninstall]

set -euo pipefail

echo "FurrOS Firefox theme installer — starting..."

# If launched from a file manager without a terminal, reopen inside one.
if [[ ! -t 0 ]]; then
  for TERM_CMD in x-terminal-emulator gnome-terminal konsole xfce4-terminal tilix kitty alacritty xterm; do
    if command -v "$TERM_CMD" >/dev/null 2>&1; then
      exec "$TERM_CMD" -e bash "$0" "$@"
    fi
  done
fi

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE=""
UNINSTALL=0
FORCE=0
REPORT="$HOME/FurrOS-install-report.txt"

trap 'code=$?; if [[ $code -ne 0 ]]; then echo; echo "INSTALL FAILED (exit $code)."; echo "Report: $REPORT"; [[ -t 0 ]] && read -rp "Press Enter to close..." || true; fi' EXIT

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
    "$HOME/.mozilla/firefox/profiles.ini" \
    "$HOME/.config/mozilla/firefox/profiles.ini" \
    "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini" \
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini" \
    "$HOME/Library/Application Support/Firefox/Profiles/profiles.ini"; do
    [[ -f "$INI" ]] || continue
    echo "Found profile list: $INI"
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
  {
    echo "FurrOS uninstall report"
    echo "Profile: $PROFILE"
    echo "Removed: userChrome.css, userContent.css, user.js"
  } > "$REPORT"
  echo "Report saved: $REPORT"
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

cp "$SOURCE_DIR/userChrome.css" "$CHROME/userChrome.css"
cp "$SOURCE_DIR/userContent.css" "$CHROME/userContent.css"
cp "$SOURCE_DIR/user.js" "$PROFILE/user.js"

for f in userChrome.css userContent.css; do
  cmp -s "$SOURCE_DIR/$f" "$CHROME/$f" || { echo "Error: copy failed for $f" >&2; exit 1; }
done
cmp -s "$SOURCE_DIR/user.js" "$PROFILE/user.js" || { echo "Error: copy failed for user.js" >&2; exit 1; }

{
  echo "FurrOS Firefox theme installation report"
  echo "Date:        $(date)"
  echo "User:        $USER"
  echo "Home:        $HOME"
  echo "Source:      $SOURCE_DIR"
  echo "Profile:     $PROFILE"
  echo "Firefox:     $(firefox --version 2>/dev/null || echo 'firefox --version unavailable')"
  echo "Backup:      .bak-$TS"
  echo "Installed files:"
  ls -l "$CHROME/userChrome.css" "$CHROME/userContent.css" "$PROFILE/user.js"
} > "$REPORT"

echo
echo "FurrOS theme installed in: $PROFILE"
echo "Previous files backed up with suffix .bak-$TS"
echo "Verified: all three theme files match the repository."
echo "Report saved: $REPORT"
echo
echo "Now start Firefox. If it was open, close it completely first."
