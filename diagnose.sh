#!/usr/bin/env bash
# Collects information to debug a failed FurrOS theme installation.

set -uo pipefail

echo "===================================================="
echo "FurrOS Firefox theme — diagnostic"
echo "===================================================="
echo "Date:  $(date)"
echo "User:  $USER"
echo "Home:  $HOME"
echo "OS:    $(uname -a)"
echo "Shell: $SHELL"
echo
echo "Firefox version:"
firefox --version 2>&1 || echo "  not found in PATH"
echo "Flatpak Firefox version:"
flatpak run org.mozilla.firefox --version 2>&1 || echo "  not installed"
echo "Snap Firefox:"
snap list firefox 2>&1 || echo "  not installed"
echo

echo "Profile lists found:"
for INI in \
  "$HOME/.mozilla/firefox/profiles.ini" \
  "$HOME/.config/mozilla/firefox/profiles.ini" \
  "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini" \
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini" \
  "$HOME/Library/Application Support/Firefox/Profiles/profiles.ini"; do
  if [[ -f "$INI" ]]; then
    echo "  $INI"
    grep -E '^(Path|Default|Name)=' "$INI" | sed 's/^/    /'
  fi
done
echo

echo "Theme source files:"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ls -l "$SCRIPT_DIR/userChrome.css" "$SCRIPT_DIR/userContent.css" "$SCRIPT_DIR/user.js" "$SCRIPT_DIR/install.sh" 2>&1
echo

echo "Installer permissions:"
stat -c '%A %n' "$SCRIPT_DIR/install.sh" 2>/dev/null || ls -l "$SCRIPT_DIR/install.sh"
echo

echo "Running Firefox processes:"
pgrep -a firefox 2>&1 || echo "  none"
echo
echo "If the install still fails, copy the full output above and send it."
read -rp "Press Enter to close..."
