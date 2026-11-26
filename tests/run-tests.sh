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
printf '#!/bin/sh\necho "Mozilla Firefox 161.0"\n' > "$BIN/fake-firefox"
chmod +x "$BIN/pgrep" "$BIN/fake-firefox"

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

# FURR_FIREFOX_BIN keeps the tests hermetic on machines without Firefox:
# no package manager, network access or real profile is touched.
PATH="$BIN:$PATH" HOME="$HOME_DIR" FURR_FIREFOX_BIN="$BIN/fake-firefox" \
  "$ROOT/install.sh" > "$TMP/install.out" 2>&1 \
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
grep -Fq 'Get-StoreFirefoxDir' "$ROOT/install.ps1" \
  || fail "PowerShell installer ignores Microsoft Store / MSIX profiles"
grep -Fq 'PROCESSOR_ARCHITECTURE' "$ROOT/install.ps1" \
  || fail "PowerShell installer does not select the Windows download architecture"
grep -Fq 'UTF8Encoding' "$ROOT/install.ps1" \
  || fail "PowerShell installer writes ini files with a legacy encoding"
grep -Fq '[Install$id]' "$ROOT/install.ps1" \
  || fail "PowerShell installer does not write the [Install] default"
grep -Fq 'CompareOrdinal' "$ROOT/install.ps1" \
  || fail "PowerShell installer tie-break is not deterministic"
pass "PowerShell installer uses real locations, Store profiles and deterministic selection"

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

if command -v python3 >/dev/null 2>&1; then
  STORE_ROOT="$TMP/winstore" PYTHONPATH="$ROOT" python3 -B - <<'PY' || fail "Microsoft Store profile detection failed"
import os
from pathlib import Path
import install

root = Path(os.environ["STORE_ROOT"])
local = root / "AppData" / "Local"
store = local / "Packages" / "Mozilla.Firefox_abc" / "LocalCache" / "Roaming" / "Mozilla"
store.mkdir(parents=True, exist_ok=True)
os.environ["LOCALAPPDATA"] = str(local)
os.environ["APPDATA"] = str(root / "AppData" / "Roaming")
original_system = install.platform.system
install.platform.system = lambda: "Windows"
try:
    chosen_dir = install.windows_store_firefox_dir()
    assert chosen_dir == store / "Firefox", chosen_dir
    install.create_firefox_profile()
    assert (store / "Firefox" / "profiles.ini").is_file(), "Store profiles.ini missing"
    assert (store / "Firefox" / "installs.ini").is_file(), "Store installs.ini missing"
    created = list((store / "Firefox" / "Profiles").iterdir())
    assert len(created) == 1 and created[0].is_dir(), created
    assert install.choose_profile(None).resolve() == created[0].resolve()

    os.environ["PROCESSOR_ARCHITECTURE"] = "X86"
    assert "os=win&" in install.firefox_windows_url()
    os.environ["PROCESSOR_ARCHITECTURE"] = "AMD64"
    assert "os=win64&" in install.firefox_windows_url()
    os.environ["PROCESSOR_ARCHITECTURE"] = "ARM64"
    assert "os=win64&" in install.firefox_windows_url()
finally:
    install.platform.system = original_system
PY
  pass "Store/MSIX profiles and Windows download architecture are handled"
fi

if grep -Fq 'Choose the profile number' "$ROOT/install.sh" \
  || grep -Fq 'select label' "$ROOT/install.sh" \
  || grep -Fq 'Choose the profile number' "$ROOT/install.py" \
  || grep -Fq 'Choose the profile number' "$ROOT/install.ps1" \
  || grep -Fq 'Read-Host' "$ROOT/install.ps1" \
  || grep -Eq '^pause[[:space:]]*$' "$ROOT/install.bat" \
  || grep -Fq 'Press Enter to close' "$ROOT/install.desktop" \
  || grep -Eq '^read[[:space:]]' "$ROOT/diagnose.sh" \
  || grep -Eq '^[[:space:]]*read[[:space:]]' "$ROOT/install.command"; then
  fail "an installer or launcher still asks for interactive input"
fi
grep -Fq 'if not "%EXITCODE%"=="0" (' "$ROOT/install.bat" \
  || fail "the CMD launcher must pause only after a failure"
grep -Fq 'FURR_INSTALL_DIR' "$ROOT/install.desktop" \
  || fail "the desktop launcher has no documented directory override"
pass "profile selection is fully automatic and launchers are non-interactive"

grep -Fq 'wslpath' "$ROOT/install.sh" || fail "install.sh ignores Windows profiles under WSL"
grep -Fq 'wsl_windows_firefox_dir' "$ROOT/install.py" || fail "install.py ignores Windows profiles under WSL"
grep -Fq 'interpolation=None' "$ROOT/install.py" \
  || fail "install.py cannot read ini paths containing a literal percent sign"
if grep -Fq 'Profiles/profiles.ini' "$ROOT/install.sh" \
  || grep -Fq 'Profiles/profiles.ini' "$ROOT/install.py"; then
  fail "an installer still reads the stale profiles.ini inside Profiles/"
fi
pass "WSL, percent paths and stale ini files are handled"

# Simulate macOS without touching a real Firefox profile.
MAC_BIN="$TMP/macbin"
mkdir -p "$MAC_BIN"
printf '#!/bin/sh\necho Darwin\n' > "$MAC_BIN/uname"
printf '#!/bin/sh\nexit 1\n' > "$MAC_BIN/pgrep"
printf '#!/bin/sh\necho "Mozilla Firefox 161.0"\n' > "$MAC_BIN/fake-firefox"
chmod +x "$MAC_BIN/uname" "$MAC_BIN/pgrep" "$MAC_BIN/fake-firefox"

MAC_HOME="$TMP/machome"
MAC_FIREFOX="$MAC_HOME/Library/Application Support/Firefox"
MAC_DEFAULT="$MAC_FIREFOX/Profiles/abcd.default-release"
MAC_OTHER="$MAC_FIREFOX/Profiles/efgh.default"
MAC_GHOST="$MAC_FIREFOX/Profiles/00000000.default-release"
mkdir -p "$MAC_DEFAULT" "$MAC_OTHER" "$MAC_GHOST"

# Simulate the leftovers of the old installer: a second profiles.ini inside
# Profiles pointing to a ghost profile that Firefox never uses.
cat > "$MAC_FIREFOX/Profiles/profiles.ini" <<'EOF'
[General]
Version=2

[Install00000000]
Default=00000000.default-release
Locked=1

[Profile0]
Name=default-release
IsRelative=1
Path=00000000.default-release
Default=1
EOF

# macOS keeps both real ini files one level above Profiles, and Firefox 62+
# remembers the actual default in installs.ini.
cat > "$MAC_FIREFOX/profiles.ini" <<'EOF'
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=default-release
IsRelative=1
Path=Profiles/abcd.default-release

[Profile1]
Name=default
IsRelative=1
Path=Profiles/efgh.default
Default=1
EOF
cat > "$MAC_FIREFOX/installs.ini" <<'EOF'
[InstallABCDEF12]
Default=Profiles/abcd.default-release
Locked=1
EOF

HOME="$MAC_HOME" PATH="$MAC_BIN:$PATH" FURR_FIREFOX_BIN="$MAC_BIN/fake-firefox" \
  "$ROOT/install.sh" </dev/null > "$TMP/mac-install.out" 2>&1 \
  || { cat "$TMP/mac-install.out" >&2; fail "macOS installer exited with an error"; }

MAC_EXPECTED="$(cd "$MAC_DEFAULT" && pwd -P)"
grep -Fq "Selected profile: $MAC_EXPECTED" "$TMP/mac-install.out" \
  || { cat "$TMP/mac-install.out" >&2; fail "macOS installer did not select the [Install] default"; }
if grep -Fq 'Choose the profile number' "$TMP/mac-install.out" \
  || grep -Fq 'Multiple Firefox profiles found' "$TMP/mac-install.out"; then
  cat "$TMP/mac-install.out" >&2
  fail "macOS installer asked for a profile"
fi
pass "macOS installer selects the real default without prompting"

for file in userChrome.css userContent.css; do
  [[ -f "$MAC_DEFAULT/chrome/$file" ]] || fail "missing $file in the macOS profile"
  cmp -s "$ROOT/$file" "$MAC_DEFAULT/chrome/$file" || fail "$file was not copied byte-for-byte on macOS"
done
[[ -f "$MAC_DEFAULT/user.js" ]] || fail "missing user.js in the macOS profile"
cmp -s "$ROOT/user.js" "$MAC_DEFAULT/user.js" || fail "user.js was not copied byte-for-byte on macOS"
[[ ! -e "$MAC_OTHER/chrome" && ! -e "$MAC_OTHER/user.js" ]] \
  || fail "macOS theme was installed into the legacy profile"
[[ ! -e "$MAC_GHOST/chrome" && ! -e "$MAC_GHOST/user.js" ]] \
  || fail "macOS theme was installed into the stale ghost profile"
if grep -Fq 'Profiles/profiles.ini' "$TMP/mac-install.out" \
  || grep -Fq "$MAC_GHOST" "$TMP/mac-install.out"; then
  cat "$TMP/mac-install.out" >&2
  fail "macOS installer considered the stale ghost profile list"
fi
pass "macOS theme files land only in the real profile"

# First run on a Mac with no profile yet: the ini files must be written
# where Firefox looks, so a second run is not needed.
MAC_FIRST="$TMP/macfirst"
HOME="$MAC_FIRST" PATH="$MAC_BIN:$PATH" FURR_FIREFOX_BIN="$MAC_BIN/fake-firefox" \
  "$ROOT/install.sh" </dev/null > "$TMP/mac-first.out" 2>&1 \
  || { cat "$TMP/mac-first.out" >&2; fail "first macOS install failed"; }

FIRST_FIREFOX="$MAC_FIRST/Library/Application Support/Firefox"
FIRST_PROFILES="$FIRST_FIREFOX/Profiles"
CREATED=""
for item in "$FIRST_PROFILES"/*.default-release; do
  [[ -d "$item" ]] || continue
  CREATED="$item"
done
[[ -n "$CREATED" ]] || { cat "$TMP/mac-first.out" >&2; fail "first macOS install created no profile"; }
CREATED_COUNT="$(find "$FIRST_PROFILES" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
[[ "$CREATED_COUNT" == "1" ]] || fail "first macOS install created duplicate profiles"
BASE_NAME="$(basename "$CREATED")"
grep -Fq "Path=Profiles/$BASE_NAME" "$FIRST_FIREFOX/profiles.ini" \
  || fail "macOS profiles.ini does not point to the created profile"
grep -Fq "Default=Profiles/$BASE_NAME" "$FIRST_FIREFOX/profiles.ini" \
  || fail "macOS profiles.ini has no [Install] default"
grep -Fq "Default=Profiles/$BASE_NAME" "$FIRST_FIREFOX/installs.ini" \
  || fail "macOS installs.ini has no default"
grep -Fq "Selected profile: $CREATED" "$TMP/mac-first.out" \
  || { cat "$TMP/mac-first.out" >&2; fail "first macOS install chose the wrong profile"; }
for file in userChrome.css userContent.css; do
  cmp -s "$ROOT/$file" "$CREATED/chrome/$file" || fail "missing $file after first macOS install"
done
cmp -s "$ROOT/user.js" "$CREATED/user.js" || fail "missing user.js after first macOS install"
[[ ! -e "$FIRST_PROFILES/profiles.ini" ]] || fail "first macOS install wrote profiles.ini inside Profiles"
[[ ! -e "$MAC_FIRST/.mozilla" && ! -e "$MAC_FIRST/.config/mozilla" ]] \
  || fail "first macOS install created a stray Linux profile"
pass "first macOS install works without a second run"

# Equal scores must not trigger the old profile-choice menu.
MAC_TIE_HOME="$TMP/mactie"
MAC_TIE_FIREFOX="$MAC_TIE_HOME/Library/Application Support/Firefox"
MAC_TIE_WORK="$MAC_TIE_FIREFOX/Profiles/zzzz.work"
MAC_TIE_RELEASE="$MAC_TIE_FIREFOX/Profiles/aaaa.default-release"
mkdir -p "$MAC_TIE_WORK" "$MAC_TIE_RELEASE"
: > "$MAC_TIE_WORK/prefs.js"
cat > "$MAC_TIE_FIREFOX/profiles.ini" <<'EOF'
[General]
Version=2

[Profile0]
Name=work
IsRelative=1
Path=Profiles/zzzz.work

[Profile1]
Name=default-release
IsRelative=1
Path=Profiles/aaaa.default-release
EOF
HOME="$MAC_TIE_HOME" PATH="$MAC_BIN:$PATH" FURR_FIREFOX_BIN="$MAC_BIN/fake-firefox" \
  "$ROOT/install.sh" </dev/null > "$TMP/mac-tie.out" 2>&1 \
  || { cat "$TMP/mac-tie.out" >&2; fail "macOS tie-break install failed"; }
grep -Fq "Selected profile: $MAC_TIE_WORK" "$TMP/mac-tie.out" \
  || { cat "$TMP/mac-tie.out" >&2; fail "macOS tie-break chose the wrong profile"; }
if grep -Fq 'Choose the profile number' "$TMP/mac-tie.out" \
  || grep -Fq 'Multiple Firefox profiles found' "$TMP/mac-tie.out"; then
  cat "$TMP/mac-tie.out" >&2
  fail "macOS tie-break asked for a profile"
fi
[[ ! -e "$MAC_TIE_RELEASE/chrome" ]] || fail "macOS tie-break installed into the wrong profile"
pass "macOS tie-break is automatic and deterministic"

if command -v python3 >/dev/null 2>&1; then
  MAC_PY_ROOT="$TMP/macpython" PYTHONPATH="$ROOT" python3 -B - <<'PY' || fail "Python macOS profile detection failed"
import builtins
import os
from pathlib import Path
import install


def no_prompt(*args, **kwargs):
    raise AssertionError("installer asked for a profile choice")


builtins.input = no_prompt
root = Path(os.environ["MAC_PY_ROOT"])
root.mkdir(parents=True, exist_ok=True)
install.platform.system = lambda: "Darwin"

home = root / "detected"
home.mkdir(parents=True, exist_ok=True)
os.environ["HOME"] = str(home)
firefox = home / "Library" / "Application Support" / "Firefox"
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
    "[InstallABCDEF12]\nDefault=Profiles/abcd.default-release\nLocked=1\n",
    encoding="utf-8",
)
stale = firefox / "Profiles" / "profiles.ini"
stale.write_text(
    "[Install00000000]\nDefault=00000000.default-release\nLocked=1\n\n"
    "[Profile0]\nName=default-release\nIsRelative=1\n"
    "Path=00000000.default-release\nDefault=1\n",
    encoding="utf-8",
)
(profiles / "00000000.default-release").mkdir(exist_ok=True)
inis = install.candidate_ini_files()
assert firefox / "profiles.ini" in inis, inis
assert firefox / "installs.ini" in inis, inis
assert stale not in inis, inis
assert install.choose_profile(None).resolve() == default.resolve()

# Equal scores must be resolved automatically: prefer an initialized
# profile over an empty default-release one, without calling input().
tie_home = root / "tie"
tie_home.mkdir(parents=True, exist_ok=True)
os.environ["HOME"] = str(tie_home)
tie_firefox = tie_home / "Library" / "Application Support" / "Firefox"
tie_profiles = tie_firefox / "Profiles"
established = tie_profiles / "zzzz.work"
preferred = tie_profiles / "aaaa.default-release"
established.mkdir(parents=True, exist_ok=True)
preferred.mkdir(parents=True, exist_ok=True)
(established / "prefs.js").write_text("", encoding="utf-8")
(tie_firefox / "profiles.ini").write_text(
    "[General]\nVersion=2\n\n"
    "[Profile0]\nName=work\nIsRelative=1\nPath=Profiles/zzzz.work\n\n"
    "[Profile1]\nName=default-release\nIsRelative=1\nPath=Profiles/aaaa.default-release\n",
    encoding="utf-8",
)
assert install.choose_profile(None).resolve() == established.resolve()

# First run: create the profile where macOS Firefox actually looks.
first_home = root / "first"
first_home.mkdir(parents=True, exist_ok=True)
os.environ["HOME"] = str(first_home)
install.create_firefox_profile()
first_firefox = first_home / "Library" / "Application Support" / "Firefox"
first_profiles = first_firefox / "Profiles"
created = list(first_profiles.iterdir())
assert len(created) == 1 and created[0].is_dir(), created
name = created[0].name
profile_ini = (first_firefox / "profiles.ini").read_text(encoding="utf-8")
installs_ini = (first_firefox / "installs.ini").read_text(encoding="utf-8")
assert f"Path=Profiles/{name}" in profile_ini, profile_ini
assert f"Default=Profiles/{name}" in profile_ini, profile_ini
assert f"Default=Profiles/{name}" in installs_ini, installs_ini
assert install.choose_profile(None).resolve() == created[0].resolve()
PY
  pass "Python installer matches macOS layout and never prompts"
fi

# Linux: Firefox open, lock file present, --force closes it cleanly.
RUN_BIN="$TMP/runbin"
mkdir -p "$RUN_BIN"
cat > "$RUN_BIN/pgrep" <<'EOF'
#!/bin/sh
# Only report the fake Firefox PID supplied by the test.
if [ "$1" = "-x" ] && [ "$2" = "firefox" ] && [ -n "${FAKE_FIREFOX_PIDS:-}" ]; then
  printf '%s\n' "$FAKE_FIREFOX_PIDS"
  exit 0
fi
exit 1
EOF
cat > "$RUN_BIN/fake-firefox" <<'EOF'
#!/bin/sh
trap 'rm -f "$FAKE_LOCK"; exit 0' TERM
: > "$FAKE_LOCK"
while :; do sleep 0.2; done
EOF
chmod +x "$RUN_BIN/pgrep" "$RUN_BIN/fake-firefox"

RUN_HOME="$TMP/runhome"
RUN_PROFILE="$RUN_HOME/.config/mozilla/firefox/abcd1234.default-release"
mkdir -p "$RUN_PROFILE"
cat > "$RUN_HOME/.config/mozilla/firefox/profiles.ini" <<EOF
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=default-release
IsRelative=1
Path=abcd1234.default-release

[Install12345678]
Default=abcd1234.default-release
Locked=1
EOF

FAKE_LOCK="$RUN_PROFILE/parent.lock" "$RUN_BIN/fake-firefox" &
FAKE_PID=$!
for _ in $(seq 1 50); do
  [[ -f "$RUN_PROFILE/parent.lock" ]] && break
  sleep 0.1
done
[[ -f "$RUN_PROFILE/parent.lock" ]] || fail "fake Firefox did not create its lock file"

FAKE_FIREFOX_PIDS="$FAKE_PID" FAKE_LOCK="$RUN_PROFILE/parent.lock" \
  PATH="$RUN_BIN:$PATH" HOME="$RUN_HOME" FURR_FIREFOX_BIN="$BIN/fake-firefox" \
  "$ROOT/install.sh" --force </dev/null > "$TMP/run-install.out" 2>&1 \
  || { cat "$TMP/run-install.out" >&2; fail "installer failed with Firefox running"; }

grep -Fq 'Closing Firefox cleanly (SIGTERM)' "$TMP/run-install.out" \
  || { cat "$TMP/run-install.out" >&2; fail "installer did not close Firefox cleanly"; }
grep -Fq 'profile locks released' "$TMP/run-install.out" \
  || { cat "$TMP/run-install.out" >&2; fail "installer did not wait for profile locks"; }
for _ in $(seq 1 50); do
  kill -0 "$FAKE_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$FAKE_PID" 2>/dev/null; then
  fail "Firefox process survived the installer"
fi
wait "$FAKE_PID" 2>/dev/null || true
[[ ! -e "$RUN_PROFILE/parent.lock" ]] || fail "stale lock file was left behind"
for file in userChrome.css userContent.css; do
  cmp -s "$ROOT/$file" "$RUN_PROFILE/chrome/$file" || fail "$file missing with Firefox running"
done
pass "Linux installer closes Firefox cleanly and waits for lock release"

# First run with an existing [Install] section: append, never rewrite;
# repeated runs must not create a second profile or lose custom settings.
IDEM_HOME="$TMP/idemhome"
IDEM_BASE="$IDEM_HOME/.config/mozilla/firefox"
mkdir -p "$IDEM_BASE"
cat > "$IDEM_BASE/profiles.ini" <<'EOF'
[General]
StartWithLastProfile=1
Version=2
CustomKey=keep-me

[Install12345678]
Default=missing.default-release
Locked=1
EOF

PATH="$BIN:$PATH" HOME="$IDEM_HOME" FURR_FIREFOX_BIN="$BIN/fake-firefox" \
  "$ROOT/install.sh" </dev/null > "$TMP/idem-first.out" 2>&1 \
  || { cat "$TMP/idem-first.out" >&2; fail "first idempotency run failed"; }
grep -Fq 'Created Firefox profile' "$TMP/idem-first.out" \
  || { cat "$TMP/idem-first.out" >&2; fail "no profile was created on first run"; }
grep -Fq 'CustomKey=keep-me' "$IDEM_BASE/profiles.ini" \
  || fail "existing ini settings were overwritten"
grep -Fq '[Install12345678]' "$IDEM_BASE/profiles.ini" \
  || fail "existing [Install] section was overwritten"
IDEM_PROFILE=""
for item in "$IDEM_BASE"/*.default-release; do
  [[ -d "$item" ]] && IDEM_PROFILE="$item"
done
[[ -n "$IDEM_PROFILE" ]] || fail "managed profile was not created"
[[ -f "$IDEM_PROFILE/.furros-profile" ]] || fail "managed profile has no marker"
PROFILES_BEFORE="$(grep -c '^\[Profile' "$IDEM_BASE/profiles.ini")"
INSTALLS_BEFORE="$(grep -c '^\[Install' "$IDEM_BASE/profiles.ini")"

COLLISION="$(date +%Y%m%d-%H%M%S)"
printf 'sentinel' > "$IDEM_PROFILE/user.js.bak-$COLLISION"
PATH="$BIN:$PATH" HOME="$IDEM_HOME" FURR_FIREFOX_BIN="$BIN/fake-firefox" \
  "$ROOT/install.sh" </dev/null > "$TMP/idem-second.out" 2>&1 \
  || { cat "$TMP/idem-second.out" >&2; fail "second idempotency run failed"; }
grep -Fq 'Reusing FurrOS-managed profile' "$TMP/idem-second.out" \
  || { cat "$TMP/idem-second.out" >&2; fail "second run did not reuse the managed profile"; }
if grep -Fq 'Created Firefox profile' "$TMP/idem-second.out"; then
  fail "second run created a duplicate profile"
fi
[[ "$(grep -c '^\[Profile' "$IDEM_BASE/profiles.ini")" == "$PROFILES_BEFORE" ]] \
  || fail "second run duplicated a [Profile] section"
[[ "$(grep -c '^\[Install' "$IDEM_BASE/profiles.ini")" == "$INSTALLS_BEFORE" ]] \
  || fail "second run duplicated an [Install] section"
[[ "$(cat "$IDEM_PROFILE/user.js.bak-$COLLISION")" == "sentinel" ]] \
  || fail "second run overwrote an existing backup"
[[ "$(find "$IDEM_PROFILE" -maxdepth 1 -name 'user.js.bak-*' | wc -l | tr -d '[:space:]')" -ge 2 ]] \
  || fail "second run did not create a new unique backup"
pass "profile creation is idempotent and backups never collide"

if command -v python3 >/dev/null 2>&1; then
  PYTHONPATH="$ROOT" python3 -B - <<'PY' || fail "Python shutdown logic failed"
import signal
import install

state = {"alive": True, "kills": []}
fake_pid = 424242

install.is_wsl = lambda: False
install.firefox_pids = lambda: [fake_pid] if state["alive"] else []
install.process_alive = lambda pid: state["alive"]
install.wait_for_all_profile_locks = lambda: None
install.FIREFOX_CLOSE_TIMEOUT = 0
install.FIREFOX_KILL_TIMEOUT = 0

# Clean shutdown: SIGTERM is enough.
def clean(pids, sig):
    state["kills"].append(sig)
    if sig == signal.SIGTERM:
        state["alive"] = False

install.terminate_processes = clean
install.handle_running_firefox(True)
assert state["kills"] == [signal.SIGTERM], state["kills"]

# Stuck process: SIGKILL is only a fallback after the timeout.
state.update(alive=True, kills=[])
def stuck(pids, sig):
    state["kills"].append(sig)
    if sig == signal.SIGKILL:
        state["alive"] = False

install.terminate_processes = stuck
install.handle_running_firefox(True)
assert state["kills"] == [signal.SIGTERM, signal.SIGKILL], state["kills"]
PY
  pass "Python installer escalates to SIGKILL only after a timeout"
fi

grep -Fq 'parent.lock' "$ROOT/install.sh" || fail "shell installer ignores profile locks"
grep -Fq 'parent.lock' "$ROOT/install.py" || fail "Python installer ignores profile locks"
grep -Fq 'SIGTERM' "$ROOT/install.sh" || fail "shell installer has no clean shutdown"
grep -Fq 'SIGKILL' "$ROOT/install.py" || fail "Python installer has no forced shutdown fallback"
grep -Fq -- '--firefox-bin' "$ROOT/install.sh" || fail "shell installer has no binary override"
grep -Fq -- '--firefox-bin' "$ROOT/install.py" || fail "Python installer has no binary override"
if grep -Eq '^[[:space:]]*kill -9([[:space:]]|$)' "$ROOT/install.sh"; then
  fail "shell installer uses kill -9 as a first resort"
fi
pass "both installers implement safe shutdown, locks and a binary override"

echo
echo "All tests passed."
