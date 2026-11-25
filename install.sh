#!/usr/bin/env bash
# Linux installer for the FurrOS Firefox theme.
# Runs install.py, which handles profile detection, backups and verification.

set -euo pipefail
cd "$(dirname "$0")"
exec python3 install.py "$@"
