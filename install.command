#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
./install.sh "$@"
RESULT=$?
echo
read -rp "Press Enter to close..."
exit $RESULT
