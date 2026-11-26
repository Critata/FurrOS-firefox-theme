#!/usr/bin/env bash
# Prints system/profile information to debug a failed theme installation.
# No Python required.

set -uo pipefail

echo "===================================================="
echo "FurrOS Firefox theme — diagnostic"
echo "===================================================="
echo "Date:  $(date)"
echo "User:  ${USER:-unknown}"
echo "Home:  $HOME"
echo "OS:    $(uname -a)"
echo

echo "Firefox version:"
firefox --version 2>&1 || echo "  not found in PATH"
echo

echo "Profile lists found:"
SEEN_INIS=()
for INI in \
  "$HOME/.mozilla/firefox/profiles.ini" \
  "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox/profiles.ini" \
  "$HOME/.config/mozilla/firefox/profiles.ini" \
  "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini" \
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini" \
  "$HOME/Library/Application Support/Firefox/profiles.ini" \
  "$HOME/Library/Application Support/Firefox/installs.ini" \
  "$HOME/Library/Application Support/Firefox/Profiles/profiles.ini"; do
  [[ -f "$INI" ]] || continue
  DUPLICATE=0
  for SEEN in "${SEEN_INIS[@]}"; do
    [[ "$SEEN" == "$INI" ]] && DUPLICATE=1
  done
  [[ "$DUPLICATE" -eq 0 ]] || continue
  SEEN_INIS+=("$INI")
  echo "  $INI"
  grep -E '^\[(Profile|Install)|^(Path|Default|Name)=' "$INI" | sed 's/^/    /'
done
echo

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
pgrep -a -x firefox 2>&1 || echo "  none"
echo

echo "Report from last install (if any):"
if [[ -f "$HOME/FurrOS-install-report.txt" ]]; then
  cat "$HOME/FurrOS-install-report.txt"
else
  echo "  none"
fi
echo
echo "If the install still fails, copy the full output above and send it."
read -rp "Press Enter to close..."
