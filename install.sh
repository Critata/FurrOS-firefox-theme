#!/usr/bin/env bash
# POSIX-style installer for Linux and macOS.
# Installs Firefox automatically if it is missing.
# No Python required: Firefox profiles are detected directly from profiles.ini.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd -P)"
PROFILE=""
FORCE=0
UNINSTALL=0
SKIP_FIREFOX_INSTALL=0
REPORT="$HOME/FurrOS-install-report.txt"
REQUIRED_PREF='user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --profile PATH          Use this Firefox profile instead of detecting it
  --force                 Install even if Firefox is running (not recommended)
  --uninstall             Remove the theme files (backups are kept)
  --skip-firefox-install  Do not install Firefox automatically if missing
  -h, --help              Show this message

Firefox is installed automatically when missing. Close Firefox completely
before installing the theme: the theme files are read only at startup.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { echo "Error: --profile requires a path." >&2; exit 1; }
      PROFILE="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    --skip-firefox-install)
      SKIP_FIREFOX_INSTALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

echo "FurrOS Firefox theme installer — starting..."

trap 'code=$?; if [[ $code -ne 0 ]]; then echo; echo "INSTALL FAILED (exit $code)."; echo "Report: $REPORT"; [[ -t 0 ]] && read -rp "Press Enter to close..." || true; fi' EXIT

firefox_running() {
  command -v pgrep >/dev/null 2>&1 || return 1
  for name in firefox firefox-bin org.mozilla.firefox; do
    if pgrep -x "$name" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

firefox_ready() {
  if command -v firefox >/dev/null 2>&1 && firefox --version >/dev/null 2>&1; then
    return 0
  fi
  if command -v firefox-esr >/dev/null 2>&1 && firefox-esr --version >/dev/null 2>&1; then
    return 0
  fi

  for candidate in \
    /usr/bin/firefox \
    /usr/local/bin/firefox \
    /usr/lib/firefox/firefox \
    /opt/firefox/firefox \
    /snap/bin/firefox \
    "$HOME/.local/bin/firefox"; do
    if [[ -x "$candidate" ]] && "$candidate" --version >/dev/null 2>&1; then
      return 0
    fi
  done

  if [[ "$(uname -s)" == "Darwin" \
    && -x "/Applications/Firefox.app/Contents/MacOS/firefox" ]]; then
    if /Applications/Firefox.app/Contents/MacOS/firefox --version >/dev/null 2>&1; then
      return 0
    fi
  fi

  if command -v flatpak >/dev/null 2>&1 \
    && [[ "$(flatpak list --app 2>/dev/null)" == *org.mozilla.firefox* ]] \
    && flatpak run org.mozilla.firefox --version >/dev/null 2>&1; then
    return 0
  fi

  if command -v snap >/dev/null 2>&1 \
    && snap list firefox >/dev/null 2>&1 \
    && snap run firefox --version >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

firefox_installed() {
  if [[ -n "${FURR_FIREFOX_BIN:-}" ]]; then
    [[ -x "$FURR_FIREFOX_BIN" ]] && return 0
    return 1
  fi
  firefox_ready
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_firefox_linux() {
  # Prefer a real browser package over transitional wrappers. Ubuntu/Zorin
  # ship an apt "firefox" package that only points to Snap.
  if command -v snap >/dev/null 2>&1; then
    run_as_root snap install firefox || true
    firefox_ready && return 0
  fi
  if command -v flatpak >/dev/null 2>&1; then
    flatpak install -y flathub org.mozilla.firefox || true
    firefox_ready && return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update || true
    run_as_root apt-get install -y firefox || true
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y firefox || true
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y firefox || true
  elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive install firefox || true
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -S --noconfirm firefox || true
  elif command -v apk >/dev/null 2>&1; then
    run_as_root apk add firefox || true
  elif command -v xbps-install >/dev/null 2>&1; then
    run_as_root xbps-install -Sy firefox || true
  fi

  if firefox_ready; then
    return 0
  fi

  # The apt package may have installed a small transitional package. Install
  # the real browser from Snap/Flatpak as a fallback.
  echo "Firefox package installed, but the browser is not usable yet. Trying Snap/Flatpak..."
  if ! command -v snap >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get install -y snapd || true
  fi
  if command -v snap >/dev/null 2>&1; then
    run_as_root snap install firefox || true
    firefox_ready && return 0
  fi
  if command -v flatpak >/dev/null 2>&1; then
    flatpak install -y flathub org.mozilla.firefox || true
    firefox_ready && return 0
  fi

  return 1
}

install_firefox_macos() {
  command -v curl >/dev/null 2>&1 || return 1
  command -v hdiutil >/dev/null 2>&1 || return 1

  local tmp mount
  tmp="$(mktemp -d)"
  mount="$tmp/mount"
  mkdir -p "$mount"

  echo "Downloading Firefox for macOS..."
  curl -fL --retry 3 \
    -o "$tmp/firefox.dmg" \
    'https://download.mozilla.org/?product=firefox-latest-ssl&os=osx&lang=en-US'

  hdiutil attach "$tmp/firefox.dmg" -mountpoint "$mount" -nobrowse -quiet
  if [[ -w /Applications ]]; then
    rm -rf /Applications/Firefox.app
    cp -R "$mount/Firefox.app" /Applications/Firefox.app
  else
    sudo rm -rf /Applications/Firefox.app
    sudo cp -R "$mount/Firefox.app" /Applications/Firefox.app
  fi
  hdiutil detach "$mount" -quiet
  rm -rf "$tmp"
}

ensure_firefox() {
  if firefox_installed; then
    return 0
  fi

  if [[ "$SKIP_FIREFOX_INSTALL" -eq 1 ]]; then
    echo "Error: Firefox is not installed." >&2
    echo "Install it manually, or run the installer without --skip-firefox-install." >&2
    exit 1
  fi

  echo "Firefox not found. Installing it automatically..."
  case "$(uname -s)" in
    Linux)
      install_firefox_linux || {
        echo "Error: could not install Firefox automatically." >&2
        echo "Install Firefox manually, then run this installer again." >&2
        exit 1
      }
      ;;
    Darwin)
      install_firefox_macos || {
        echo "Error: could not install Firefox automatically." >&2
        echo "Install Firefox manually, then run this installer again." >&2
        exit 1
      }
      ;;
    *)
      echo "Error: automatic Firefox installation is not supported on this system." >&2
      exit 1
      ;;
  esac

  # The override is only for detecting a missing browser before installation.
  unset FURR_FIREFOX_BIN
  if ! firefox_installed; then
    echo "Error: Firefox was installed but could not be detected." >&2
    echo "Start Firefox once, then run this installer again." >&2
    exit 1
  fi
  echo "Firefox installed successfully."
}

profile_ini_candidates() {
  printf '%s\n' \
    "$HOME/.mozilla/firefox/profiles.ini" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox/profiles.ini" \
    "$HOME/.config/mozilla/firefox/profiles.ini" \
    "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini" \
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini" \
    "$HOME/Library/Application Support/Firefox/Profiles/profiles.ini"
}

create_firefox_profile() {
  local candidate base ini id dir found=0

  # Never create a second profile: Firefox may already use a profile in a
  # different standard location (for example ~/.config/mozilla/firefox).
  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] || continue
    if grep -q '^\[Profile' "$candidate"; then
      found=1
      break
    fi
  done < <(profile_ini_candidates)
  [[ "$found" -eq 1 ]] && return 0

  if [[ "$(uname -s)" == "Darwin" ]]; then
    base="$HOME/Library/Application Support/Firefox/Profiles"
  elif command -v flatpak >/dev/null 2>&1 \
    && flatpak run org.mozilla.firefox --version >/dev/null 2>&1; then
    base="$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
  elif command -v snap >/dev/null 2>&1 \
    && snap run firefox --version >/dev/null 2>&1; then
    base="$HOME/snap/firefox/common/.mozilla/firefox"
  else
    base="${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
  fi

  ini="$base/profiles.ini"
  id="$(openssl rand -hex 4 2>/dev/null || printf 'furros%s' "$$")"
  id="${id:0:8}"
  dir="${id}.default-release"
  mkdir -p "$base/$dir"
  cat > "$ini" <<EOF
[Install$id]
Default=$dir
Locked=1

[Profile0]
Name=default-release
IsRelative=1
Path=$dir
Default=1
EOF
  echo "Created Firefox profile: $base/$dir"
}

if [[ "$UNINSTALL" -ne 1 ]]; then
  ensure_firefox
  create_firefox_profile
fi

if [[ "$FORCE" -ne 1 ]] && firefox_running; then
  echo "Error: Firefox is still running." >&2
  echo "Close every Firefox window completely, then run the installer again." >&2
  echo "The theme files are loaded only at startup." >&2
  echo "If you really know what you are doing: ./install.sh --force" >&2
  exit 1
fi

running_profile() {
  local link target rest profile prefix candidate

  [[ -d /proc ]] || return 1
  for link in /proc/[0-9]*/fd/*; do
    [[ -L "$link" ]] || continue
    target="$(readlink "$link" 2>/dev/null)" || continue

    case "$target" in
      */mozilla/firefox/*)
        rest="${target#*/mozilla/firefox/}"
        profile="${rest%%/*}"
        prefix="${target%%/mozilla/firefox/*}"
        candidate="$prefix/mozilla/firefox/$profile"
        ;;
      */Mozilla/Firefox/Profiles/*)
        rest="${target#*/Mozilla/Firefox/Profiles/}"
        profile="${rest%%/*}"
        prefix="${target%%/Mozilla/Firefox/Profiles/*}"
        candidate="$prefix/Mozilla/Firefox/Profiles/$profile"
        ;;
      *)
        continue
        ;;
    esac

    case "$profile" in
      *.default*|Profile*) ;;
      *) continue ;;
    esac
    [[ -d "$candidate" ]] || continue
    [[ "$candidate" != */.cache/* ]] || continue
    [[ -f "$candidate/prefs.js" || -f "$candidate/user.js" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

PROFILES=()
INIS=()
INSTALL_DEFAULTS=()

add_ini() {
  local existing
  [[ -f "$1" ]] || return 0
  for existing in "${INIS[@]}"; do
    [[ "$existing" == "$1" ]] && return 0
  done
  INIS+=("$1")
  return 0
}

add_profile() {
  local flag="$1" name="$2" path="$3" existing
  [[ -d "$path" ]] || return 0
  if [[ ${#PROFILES[@]} -gt 0 ]]; then
    for existing in "${PROFILES[@]}"; do
      if [[ "${existing##*$'\t'}" == "$path" ]]; then
        return 0
      fi
    done
  fi
  PROFILES+=("$flag"$'\t'"$name"$'\t'"$path")
  return 0
}

emit_profile() {
  local base="$1" raw="$2" name="$3" default="$4" path
  if [[ "$raw" == /* ]]; then
    path="$raw"
  else
    path="$base/$raw"
  fi
  [[ -d "$path" ]] || return 0
  path="$(cd "$(dirname "$path")" && printf '%s/%s' "$(pwd -P)" "$(basename "$path")")"
  [[ -n "$name" ]] || name="$(basename "$path")"
  add_profile "$default" "$name" "$path"
}

parse_ini() {
  local ini="$1" base line key value path name default section="" resolved

  base="$(cd "$(dirname "$ini")" && pwd -P)"
  path=""
  name=""
  default=0

  finish_profile() {
    if [[ "$section" == Profile* && -n "$path" ]]; then
      emit_profile "$base" "$path" "$name" "$default"
    fi
    path=""
    name=""
    default=0
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    case "$line" in
      \[Profile*\])
        finish_profile
        section="Profile"
        continue
        ;;
      \[Install*\])
        finish_profile
        section="Install"
        continue
        ;;
      \[*\])
        finish_profile
        section=""
        continue
        ;;
    esac

    [[ "$line" == *=* ]] || continue
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"

    # Firefox's real default is declared in [Install...], not in the legacy
    # [Profile...] Default=1 flag.
    if [[ "$section" == "Install" && "$key" == "Default" ]]; then
      if [[ "$value" == /* ]]; then
        resolved="$value"
      else
        resolved="$base/$value"
      fi
      if [[ -d "$resolved" ]]; then
        resolved="$(cd "$(dirname "$resolved")" && printf '%s/%s' "$(pwd -P)" "$(basename "$resolved")")"
      fi
      INSTALL_DEFAULTS+=("$resolved")
      continue
    fi

    [[ "$section" == "Profile" ]] || continue
    case "$key" in
      Path) path="$value" ;;
      Name) name="$value" ;;
      Default) default="$value" ;;
    esac
  done < "$ini"

  finish_profile
}

if [[ -z "$PROFILE" ]]; then
  while IFS= read -r candidate; do
    add_ini "$candidate"
  done < <(profile_ini_candidates)

  for ini in "${INIS[@]}"; do
    echo "Found profile list: $ini"
    parse_ini "$ini"
  done

  if [[ ${#PROFILES[@]} -eq 0 ]]; then
    echo "Error: Firefox profile not found." >&2
    echo "Specify it with: ./install.sh --profile /full/path/to/profile" >&2
    exit 1
  fi

  ACTIVE=""
  [[ "$FORCE" -eq 1 ]] && ACTIVE="$(running_profile || true)"

  # Score: 4 = currently running, 3 = Firefox [Install] default,
  # 2 = legacy [Profile] Default=1, 1 = other profile.
  SCORED=()
  for entry in "${PROFILES[@]}"; do
    flag="${entry%%$'\t'*}"
    rest="${entry#*$'\t'}"
    name="${rest%%$'\t'*}"
    path="${rest##*$'\t'}"

    score=1
    [[ "$flag" == "1" ]] && score=2
    for default_path in "${INSTALL_DEFAULTS[@]}"; do
      [[ "$default_path" == "$path" ]] && score=3
    done
    [[ -n "$ACTIVE" && "$ACTIVE" == "$path" ]] && score=4

    SCORED+=("$score"$'\t'"$name"$'\t'"$path")
  done

  if [[ -n "$ACTIVE" ]]; then
    known=0
    for entry in "${SCORED[@]}"; do
      [[ "${entry##*$'\t'}" == "$ACTIVE" ]] && known=1
    done
    if [[ "$known" -eq 0 ]]; then
      SCORED+=("4"$'\t'"$(basename "$ACTIVE")"$'\t'"$ACTIVE")
    fi
  fi

  ORDERED=()
  for score in 4 3 2 1; do
    for entry in "${SCORED[@]}"; do
      [[ "${entry%%$'\t'*}" == "$score" ]] && ORDERED+=("$entry")
    done
  done

  TOP=()
  REST=()
  top_score="${ORDERED[0]%%$'\t'*}"
  for entry in "${ORDERED[@]}"; do
    if [[ "${entry%%$'\t'*}" == "$top_score" ]]; then
      TOP+=("$entry")
    else
      REST+=("$entry")
    fi
  done

  if [[ ${#TOP[@]} -eq 1 ]]; then
    PROFILE="${TOP[0]##*$'\t'}"
    echo "Selected profile: $PROFILE"
  else
    CHOICES=("${TOP[@]}" "${REST[@]}")
    echo
    echo "Multiple Firefox profiles found:"
    LABELS=()
    for entry in "${CHOICES[@]}"; do
      score="${entry%%$'\t'*}"
      rest="${entry#*$'\t'}"
      name="${rest%%$'\t'*}"
      path="${rest##*$'\t'}"
      marker=""
      case "$score" in
        4) marker=" (running)" ;;
        3) marker=" (default)" ;;
        2) marker=" (legacy default)" ;;
      esac
      LABELS+=("$name$marker — $path")
    done

    PS3="Choose the profile number: "
    select label in "${LABELS[@]}"; do
      if [[ -z "$label" ]]; then
        echo "Invalid choice." >&2
        exit 1
      fi
      index=0
      for candidate in "${LABELS[@]}"; do
        index=$((index + 1))
        if [[ "$candidate" == "$label" ]]; then
          break
        fi
      done
      PROFILE="${CHOICES[$((index - 1))]##*$'\t'}"
      break
    done
  fi
fi

PROFILE="${PROFILE/#\~/$HOME}"
case "$PROFILE" in
  /*) ;;
  *) PROFILE="$(cd "$(dirname "$PROFILE")" && pwd -P)/$(basename "$PROFILE")" ;;
esac

if [[ ! -d "$PROFILE" ]]; then
  echo "Error: profile directory does not exist: $PROFILE" >&2
  exit 1
fi

CHROME="$PROFILE/chrome"
TS="$(date +%Y%m%d-%H%M%S)"

version() {
  firefox --version 2>/dev/null \
    || firefox-esr --version 2>/dev/null \
    || flatpak run org.mozilla.firefox --version 2>/dev/null \
    || snap run firefox --version 2>/dev/null \
    || /Applications/Firefox.app/Contents/MacOS/firefox --version 2>/dev/null \
    || echo "version unavailable"
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  rm -f "$CHROME/userChrome.css" "$CHROME/userContent.css" "$PROFILE/user.js"
  {
    echo "FurrOS Firefox theme installation report"
    echo "Date:     $(date)"
    echo "System:   $(uname -s) $(uname -r)"
    echo "User:     ${USER:-unknown}"
    echo "Home:     $HOME"
    echo "Source:   $SRC"
    echo "Profile:  $PROFILE"
    echo "Firefox:  $(version)"
    echo "Action:   Uninstall"
    echo "Removed:  $CHROME/userChrome.css"
    echo "Removed:  $CHROME/userContent.css"
    echo "Removed:  $PROFILE/user.js"
  } > "$REPORT"
  echo
  echo "FurrOS theme removed from: $PROFILE"
  echo "Report saved: $REPORT"
  echo "Start Firefox again to apply the change."
  exit 0
fi

mkdir -p "$CHROME"

for f in userChrome.css userContent.css; do
  if [[ -f "$CHROME/$f" ]]; then
    cp -p "$CHROME/$f" "$CHROME/$f.bak-$TS"
  fi
done
if [[ -f "$PROFILE/user.js" ]]; then
  cp -p "$PROFILE/user.js" "$PROFILE/user.js.bak-$TS"
fi

for f in userChrome.css userContent.css; do
  [[ -f "$SRC/$f" ]] || { echo "Error: missing source file: $SRC/$f" >&2; exit 1; }
  cp "$SRC/$f" "$CHROME/$f"
  cmp -s "$SRC/$f" "$CHROME/$f" || { echo "Error: copy failed for $f" >&2; exit 1; }
done

[[ -f "$SRC/user.js" ]] || { echo "Error: missing source file: $SRC/user.js" >&2; exit 1; }
cp "$SRC/user.js" "$PROFILE/user.js"
cmp -s "$SRC/user.js" "$PROFILE/user.js" || { echo "Error: copy failed for user.js" >&2; exit 1; }
grep -Fq "$REQUIRED_PREF" "$PROFILE/user.js" || {
  echo "Error: user.js is missing the required stylesheet preference." >&2
  exit 1
}

{
  echo "FurrOS Firefox theme installation report"
  echo "Date:     $(date)"
  echo "System:   $(uname -s) $(uname -r)"
  echo "User:     ${USER:-unknown}"
  echo "Home:     $HOME"
  echo "Source:   $SRC"
  echo "Profile:  $PROFILE"
  echo "Firefox:  $(version)"
  echo "Backup:   .bak-$TS"
  echo "Action:   Install"
  echo "Verified: $CHROME/userChrome.css"
  echo "Verified: $CHROME/userContent.css"
  echo "Verified: $PROFILE/user.js"
  echo "Verified: stylesheet preference enabled"
} > "$REPORT"

echo
echo "FurrOS theme installed in: $PROFILE"
echo "Previous files backed up with suffix .bak-$TS"
echo "Verified: all three theme files match the repository."
echo "Verified: stylesheet preference enabled."
echo "Report saved: $REPORT"
echo
echo "Now start Firefox. If it was open, close it completely first."
