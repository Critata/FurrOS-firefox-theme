#!/bin/sh
# macOS launcher. Finder starts .command files from the user's home folder,
# so resolve the folder that actually contains this script. Keep this file
# POSIX-compatible: Finder may open it with /bin/sh instead of bash.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || {
  echo "Cannot find the installer folder." >&2
  exit 1
}
cd "$SCRIPT_DIR" || exit 1

# Do not use exec: the Terminal window must stay open long enough to show the
# result. Run bash explicitly so an archive extracted without the executable
# bit on install.sh still works when this launcher is double-clicked.
FURR_NO_PAUSE=1 bash ./install.sh "$@"
status=$?

echo
if [ "$status" -ne 0 ]; then
  echo "FurrOS installation failed (exit $status)."
  echo "Review the messages above, then run ./install.sh from Terminal for details."
elif [ "$#" -eq 0 ]; then
  echo "FurrOS theme installed successfully."
elif [ "${1:-}" = "--uninstall" ]; then
  echo "FurrOS theme removed successfully."
elif [ "${1:-}" != "-h" ] && [ "${1:-}" != "--help" ]; then
  echo "FurrOS installer finished successfully."
fi

# Terminal.app sets TERM_SESSION_ID when it opens a .command file from Finder.
# Some Finder launches do not attach a readable stdin, so if the prompt gets
# EOF keep the window open briefly instead of closing over the error message.
if [ -t 0 ] || [ -n "${TERM_SESSION_ID:-}" ]; then
  printf 'Press Enter to close this window...'
  if ! read -r _; then
    [ -n "${TERM_SESSION_ID:-}" ] && sleep 20
  fi
  echo
fi
exit "$status"
