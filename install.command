#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
python3 install.py "$@"
RESULT=$?
echo
read -rp "Press Enter to close..."
exit $RESULT
