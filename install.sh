#!/usr/bin/env bash
# POSIX-style installer for Linux and macOS.
# No Python required: Firefox profiles are detected directly from profiles.ini.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd -P)"
PROFILE=""
FORCE=0
UNINSTALL=0
REPORT="$HOME/FurrOS-install-report.txt"
REQUIRED_PREF='user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --profile PATH   Use this Firefox profile instead of detecting it
  --force          Install even if Firefox is running (not recommended)
  --uninstall      Remove the theme files (backups are kept)
  -h, --help       Show this message

Important: close Firefox completely before running this script.
The theme files are loaded only when Firefox starts.
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
