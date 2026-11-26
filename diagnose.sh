#!/usr/bin/env bash
# Prints system/profile information to debug a failed theme installation.
# No Python required. This script never waits for interactive input.

set -uo pipefail

echo "===================================================="
echo "FurrOS Firefox theme - diagnostic"
echo "===================================================="
echo "Date:  $(date)"
echo "User:  ${USER:-unknown}"
echo "Home:  $HOME"
echo "OS:    $(uname -a)"
echo

version() {
  firefox --version 2>/dev/null \
    || firefox-esr --version 2>/dev/null \
    || flatpak run org.mozilla.firefox --version 2>/dev/null \
    || snap run firefox --version 2>/dev/null \
    || /Applications/Firefox.app/Contents/MacOS/firefox --version 2>/dev/null
}

echo "Firefox version:"
version || echo "  not found in PATH or standard install locations"
echo

WSL=0
if [[ "$(uname -s)" == "Linux" && "$(uname -r)" == *[Mm]icrosoft* ]]; then
  WSL=1
fi

echo "Profile lists found:"
SEEN_INIS=()
add_ini() {
  [[ -f "$1" ]] || return 0
  local seen
  for seen in "${SEEN_INIS[@]}"; do
    [[ "$seen" == "$1" ]] && return 0
  done
  SEEN_INIS+=("$1")
}

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
for INI in \
  "$HOME/.mozilla/firefox/profiles.ini" \
  "$HOME/.mozilla/firefox/installs.ini" \
  "$CONFIG/mozilla/firefox/profiles.ini" \
  "$CONFIG/mozilla/firefox/installs.ini" \
  "$HOME/.config/mozilla/firefox/profiles.ini" \
  "$HOME/.config/mozilla/firefox/installs.ini" \
  "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini" \
  "$HOME/snap/firefox/common/.mozilla/firefox/installs.ini" \
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini" \
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/installs.ini" \
  "$HOME/Library/Application Support/Firefox/profiles.ini" \
  "$HOME/Library/Application Support/Firefox/installs.ini"; do
  add_ini "$INI"
done

# Under WSL, Firefox may be installed on the Windows side.
if [[ "$WSL" -eq 1 ]] && command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
  RAW="$(cmd.exe /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r\n')"
  if [[ -n "$RAW" ]]; then
    DIR="$(wslpath -u "$RAW" 2>/dev/null)/Mozilla/Firefox"
    add_ini "$DIR/profiles.ini"
    add_ini "$DIR/installs.ini"
  fi
fi

for INI in "${SEEN_INIS[@]}"; do
  echo "  $INI"
  # Show every section: installs.ini uses bare [<hash>] names, profiles.ini
  # uses [Install<hash>], and both matter for profile selection.
  grep -E '^\[|^(Path|Default|Name)=' "$INI" | sed 's/^/    /'
done
[[ ${#SEEN_INIS[@]} -gt 0 ]] || echo "  none"
echo

# A profiles.ini inside Profiles/ is never read by Firefox and is excluded
# on purpose, exactly as in install.sh and install.py.

echo "Profile used by running Firefox (if any):"
FOUND=0
for LINK in /proc/[0-9]*/fd/*; do
  [[ -L "$LINK" ]] || continue
  TARGET="$(readlink "$LINK" 2>/dev/null)" || continue
  case "$TARGET" in
    */mozilla/firefox/*|*/Mozilla/Firefox/Profiles/*)
      case "$TARGET" in
        */.cache/*) continue ;;
      esac
      if [[ -f "${TARGET%/*}/prefs.js" ]]; then
        echo "  ${TARGET%/*}"
        FOUND=1
        break
      fi
      ;;
  esac
done
[[ "$FOUND" -eq 1 ]] || echo "  none"
echo

echo "Theme source files:"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ls -l "$SCRIPT_DIR/userChrome.css" "$SCRIPT_DIR/userContent.css" "$SCRIPT_DIR/user.js" "$SCRIPT_DIR/install.sh" 2>&1
echo

echo "Installer permissions:"
stat -c '%A %n' "$SCRIPT_DIR/install.sh" 2>/dev/null || ls -l "$SCRIPT_DIR/install.sh"
echo

echo "Running Firefox processes:"
FOUND=0
for name in firefox firefox-bin firefox-esr org.mozilla.firefox; do
  if pgrep -a -x "$name" 2>/dev/null; then
    FOUND=1
  fi
done
if [[ "$WSL" -eq 1 ]] && command -v tasklist.exe >/dev/null 2>&1; then
  if tasklist.exe 2>/dev/null | grep -qi 'firefox.exe'; then
    echo "  firefox.exe (Windows side, WSL)"
    FOUND=1
  fi
fi
[[ "$FOUND" -eq 1 ]] || echo "  none"
echo

echo "Report from last install (if any):"
if [[ -f "$HOME/FurrOS-install-report.txt" ]]; then
  cat "$HOME/FurrOS-install-report.txt"
else
  echo "  none"
fi
echo
echo "If the install still fails, copy the full output above and send it."
[[ -t 0 ]] && read -rp "Press Enter to close..." || true
