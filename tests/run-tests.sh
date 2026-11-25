#!/usr/bin/env bash
# Regression tests for the FurrOS theme installers.
# No network access and no real Firefox profile is touched.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }

bash -n "$ROOT/install.sh" || fail "install.sh has a syntax error"
pass "install.sh syntax"

if command -v python3 >/dev/null 2>&1; then
  python3 -B -c "import ast, pathlib; ast.parse(pathlib.Path('$ROOT/install.py').read_text(encoding='utf-8'))" \
    || fail "install.py has a syntax error"
  pass "install.py syntax"
fi

grep -Fq 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' "$ROOT/user.js" \
  || fail "user.js is missing the required stylesheet preference"
pass "user.js stylesheet preference"

# Stub pgrep so the installer believes Firefox is closed.
BIN="$TMP/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\nexit 1\n' > "$BIN/pgrep"
chmod +x "$BIN/pgrep"

HOME_DIR="$TMP/home"
BASE="$HOME_DIR/.config/mozilla/firefox"
DEFAULT_PROFILE="$BASE/j9l0uwbk.default-release"
OTHER_PROFILE="$BASE/q1bvv26u.default"
mkdir -p "$DEFAULT_PROFILE" "$OTHER_PROFILE"

# This mirrors a real Linux profiles.ini: [Install] points to default-release,
# while an unrelated [Profile] carries the legacy Default=1 flag.
cat > "$BASE/profiles.ini" <<'EOF'
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=default-release
IsRelative=1
Path=j9l0uwbk.default-release

[Install4F96D1932A9F858E]
Default=j9l0uwbk.default-release
Locked=1

[Profile1]
Name=default
IsRelative=1
Path=q1bvv26u.default
Default=1
EOF

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/install.sh" > "$TMP/install.out" 2>&1 \
  || { cat "$TMP/install.out" >&2; fail "installer exited with an error"; }

EXPECTED="$(cd "$DEFAULT_PROFILE" && pwd -P)"
grep -Fq "Selected profile: $EXPECTED" "$TMP/install.out" \
  || { cat "$TMP/install.out" >&2; fail "installer did not select the [Install] default profile"; }
pass "installer selects the [Install] default profile"

for file in userChrome.css userContent.css; do
  [[ -f "$DEFAULT_PROFILE/chrome/$file" ]] || fail "missing $file in the selected profile"
  cmp -s "$ROOT/$file" "$DEFAULT_PROFILE/chrome/$file" || fail "$file was not copied byte-for-byte"
done
[[ -f "$DEFAULT_PROFILE/user.js" ]] || fail "missing user.js in the selected profile"
cmp -s "$ROOT/user.js" "$DEFAULT_PROFILE/user.js" || fail "user.js was not copied byte-for-byte"
pass "theme files installed byte-for-byte"

[[ ! -e "$OTHER_PROFILE/chrome" && ! -e "$OTHER_PROFILE/user.js" ]] \
  || fail "theme was installed into the wrong profile"
pass "legacy Default=1 profile untouched"

[[ ! -d "$HOME_DIR/.mozilla" ]] || fail "installer created a stray ~/.mozilla profile"
pass "no duplicate profile created"

if command -v python3 >/dev/null 2>&1; then
  PYTHONPATH="$ROOT" HOME="$HOME_DIR" python3 -B - <<'PY' || fail "Python installer chose the wrong profile"
import os
from pathlib import Path
import install

home = Path(os.environ["HOME"])
base = home / ".config/mozilla/firefox"
expected = base / "j9l0uwbk.default-release"
chosen = install.choose_profile(None)
assert chosen == expected, (chosen, expected)
install.create_firefox_profile()
assert not (home / ".mozilla").exists(), "Python installer created a stray ~/.mozilla profile"
PY
  pass "Python installer agrees with the shell installer"
fi

grep -Fq "installs.ini" "$ROOT/install.ps1" \
  || fail "PowerShell installer does not read installs.ini"
grep -Fq "Join-Path \$firefoxDir 'profiles.ini'" "$ROOT/install.ps1" \
  || fail "PowerShell installer does not read profiles.ini from %APPDATA%\\Mozilla\\Firefox"
pass "PowerShell installer uses the real Windows profile locations"

if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$TMP/winroot"
  WINROOT="$TMP/winroot" PYTHONPATH="$ROOT" python3 -B - <<'PY' || fail "Windows profile detection failed"
import os
from pathlib import Path
import install

root = Path(os.environ["WINROOT"])
appdata = root / "AppData" / "Roaming"
local = root / "AppData" / "Local"
firefox = appdata / "Mozilla" / "Firefox"
profiles = firefox / "Profiles"
default = profiles / "abcd.default-release"
other = profiles / "efgh.default"
default.mkdir(parents=True, exist_ok=True)
other.mkdir(parents=True, exist_ok=True)

(firefox / "profiles.ini").write_text(
    "[General]\nStartWithLastProfile=1\nVersion=2\n\n"
    "[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abcd.default-release\n\n"
    "[Profile1]\nName=default\nIsRelative=1\nPath=Profiles/efgh.default\nDefault=1\n",
    encoding="utf-8",
)
(firefox / "installs.ini").write_text(
    "[Install12345678]\nDefault=Profiles/abcd.default-release\nLocked=1\n",
    encoding="utf-8",
)

os.environ["APPDATA"] = str(appdata)
os.environ["LOCALAPPDATA"] = str(local)
original_system = install.platform.system
install.platform.system = lambda: "Windows"
try:
    inis = install.candidate_ini_files()
    assert firefox / "profiles.ini" in inis, inis
    assert firefox / "installs.ini" in inis, inis
    chosen = install.choose_profile(None)
    assert chosen == default, (chosen, default)
    install.create_firefox_profile()
    assert len(list(profiles.iterdir())) == 2, "create_firefox_profile created a duplicate profile"
finally:
    install.platform.system = original_system
PY
  pass "Windows profiles.ini + installs.ini point to the real default profile"
fi

echo
echo "All tests passed."
