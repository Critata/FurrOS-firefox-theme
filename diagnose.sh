#!/usr/bin/env bash
# Prints system/profile information to debug a failed theme installation.

set -uo pipefail
cd "$(dirname "$0")"
echo "===================================================="
echo "FurrOS Firefox theme — diagnostic"
echo "===================================================="
echo "Date:  $(date)"
echo "User:  $USER"
echo "Home:  $HOME"
echo "OS:    $(uname -a)"
echo
python3 install.py --help 2>&1 | head -3
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
echo "Report from last install (if any):"
if [[ -f "$HOME/FurrOS-install-report.txt" ]]; then
  cat "$HOME/FurrOS-install-report.txt"
else
  echo "  none"
fi
echo
echo "If the install still fails, copy the full output above and send it."
read -rp "Press Enter to close..."
