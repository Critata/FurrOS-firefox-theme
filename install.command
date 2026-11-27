#!/usr/bin/env bash
# macOS launcher. Finder starts .command files from the user's home folder,
# so resolve the folder that actually contains this script.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || {
  echo "Cannot find the installer folder." >&2
  exit 1
}
cd "$SCRIPT_DIR" || exit 1

# Run bash explicitly: archives extracted without the executable bit must
# still work when the launcher itself is double-clicked. Do not use exec:
# the Terminal window must stay open long enough to show the result.
FURR_NO_PAUSE=1 bash ./install.sh "$@"
status=$?

echo
if [[ "$status" -eq 0 ]]; then
  echo "FurrOS theme installed successfully."
else
  echo "FurrOS installation failed (exit $status)."
  echo "Review the messages above, then run ./install.sh from Terminal for details."
fi

# Finder closes the Terminal window as soon as the shell exits. Pause only
# when attached to a terminal, so scripted runs remain non-interactive.
if [[ -t 0 ]]; then
  read -rp "Press Enter to close this window..." _ || true
fi
exit "$status"
