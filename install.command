#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
# Call bash explicitly: archives extracted without the executable bit must
# still work when the launcher itself is double-clicked.
exec bash ./install.sh "$@"
