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
  if command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root apt-get install -y firefox
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y firefox
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y firefox
  elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive install firefox
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -S --noconfirm firefox
  elif command -v apk >/dev/null 2>&1; then
    run_as_root apk add firefox
  elif command -v xbps-install >/dev/null 2>&1; then
    run_as_root xbps-install -Sy firefox
  elif command -v flatpak >/dev/null 2>&1; then
    flatpak install -y flathub org.mozilla.firefox
  elif command -v snap >/dev/null 2>&1; then
    run_as_root snap install firefox
  else
    return 1
  fi

  if firefox_ready; then
    return 0
  fi

  # Ubuntu/Zorin install a small transitional "firefox" package that points
  # to Snap. If that happened, install the real browser from Snap/Flatpak.
  echo "Firefox package installed, but the browser is not usable yet. Trying Snap/Flatpak..."
  if command -v flatpak >/dev/null 2>&1; then
    flatpak install -y flathub org.mozilla.firefox || true
    if firefox_ready; then
      return 0
    fi
  fi
  if ! command -v snap >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get install -y snapd || true
  fi
  if command -v snap >/dev/null 2>&1; then
    run_as_root snap install firefox || true
    if firefox_ready; then
      return 0
    fi
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

if [[ "$UNINSTALL" -ne 1 ]]; then
  ensure_firefox
fi

if [[ "$FORCE" -ne 1 ]] && firefox_running; then
  echo "Error: Firefox is still running." >&2
  echo "Close every Firefox window completely, then run the installer again." >&2
  echo "The theme files are loaded only at startup." >&2
  echo "If you really know what you are doing: ./install.sh --force" >&2
  exit 1
fi

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

PROFILES=()
INIS=()

add_ini() {
  if [[ -f "$1" ]]; then
    INIS+=("$1")
  fi
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
  local ini="$1" base line key value path name default in_section=0
  base="$(cd "$(dirname "$ini")" && pwd -P)"
  path=""
  name=""
  default=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    case "$line" in
      \[Profile*)
        if [[ "$in_section" -eq 1 && -n "$path" ]]; then
          emit_profile "$base" "$path" "$name" "$default"
        fi
        in_section=1
        path=""
        name=""
        default=0
        continue
        ;;
      \[*)
        if [[ "$in_section" -eq 1 && -n "$path" ]]; then
          emit_profile "$base" "$path" "$name" "$default"
        fi
        in_section=0
        continue
        ;;
    esac

    [[ "$in_section" -eq 1 ]] || continue
    [[ "$line" == *=* ]] || continue
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"

    case "$key" in
      Path) path="$value" ;;
      Name) name="$value" ;;
      Default) default="$value" ;;
    esac
  done < "$ini"

  if [[ "$in_section" -eq 1 && -n "$path" ]]; then
    emit_profile "$base" "$path" "$name" "$default"
  fi
}

if [[ -z "$PROFILE" ]]; then
  add_ini "$HOME/.mozilla/firefox/profiles.ini"
  add_ini "$HOME/.config/mozilla/firefox/profiles.ini"
  add_ini "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini"
  add_ini "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini"
  add_ini "$HOME/Library/Application Support/Firefox/Profiles/profiles.ini"

  for ini in "${INIS[@]}"; do
    echo "Found profile list: $ini"
    parse_ini "$ini"
  done

  if [[ ${#PROFILES[@]} -eq 0 ]]; then
    echo "Error: Firefox profile not found." >&2
    echo "Specify it with: ./install.sh --profile /full/path/to/profile" >&2
    exit 1
  fi

  DEFAULT=()
  OTHER=()
  for entry in "${PROFILES[@]}"; do
    if [[ "${entry%%$'\t'*}" == "1" ]]; then
      DEFAULT+=("$entry")
    else
      OTHER+=("$entry")
    fi
  done
  ORDERED=("${DEFAULT[@]}" "${OTHER[@]}")

  if [[ ${#ORDERED[@]} -eq 1 ]]; then
    PROFILE="${ORDERED[0]##*$'\t'}"
  else
    echo
    echo "Multiple Firefox profiles found:"
    LABELS=()
    for entry in "${ORDERED[@]}"; do
      flag="${entry%%$'\t'*}"
      rest="${entry#*$'\t'}"
      name="${rest%%$'\t'*}"
      path="${rest##*$'\t'}"
      marker=""
      [[ "$flag" == "1" ]] && marker=" (default)"
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
      PROFILE="${ORDERED[$((index - 1))]##*$'\t'}"
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
