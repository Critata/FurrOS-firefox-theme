#!/usr/bin/env bash
# Bash installer for Linux, macOS and WSL.
# Installs Firefox automatically if it is missing.
# No Python required: Firefox profiles are detected directly from profiles.ini.

set -euo pipefail

# Resolve symlinks so a launcher placed elsewhere still finds the theme files.
SELF="$0"
while [[ -L "$SELF" ]]; do
  LINK="$(readlink "$SELF")"
  if [[ "$LINK" == /* ]]; then
    SELF="$LINK"
  else
    SELF="$(dirname "$SELF")/$LINK"
  fi
done
SRC="$(cd "$(dirname "$SELF")" && pwd -P)"
PROFILE=""
MANUAL_PROFILE=0
FORCE=0
UNINSTALL=0
SKIP_FIREFOX_INSTALL=0
ALL_PROFILES=0
SINGLE_PROFILE=0
REPORT="$HOME/FurrOS-install-report.txt"
REQUIRED_PREF='user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'
MANAGED_MARKER='.furros-profile'
FIREFOX_CLOSE_TIMEOUT=15
FIREFOX_KILL_TIMEOUT=5
LOCK_TIMEOUT=15

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Firefox installation hashes are 16 uppercase hexadecimal digits:
# profiles.ini writes them as [Install<hash>], installs.ini as [<hash>].
# Older FurrOS installers wrote [Install<profile-id>] with a lowercase
# 8-character id. Firefox copied those into installs.ini as bare sections,
# but they are not real installation defaults and must be ignored.
is_install_hash() {
  [[ "$1" =~ ^[0-9A-F]{16}$ ]]
}

# WSL reports a Linux kernel, but Windows Firefox keeps its profile under
# %APPDATA%. Interop is enabled by default, so cmd.exe and wslpath are
# normally available; if they are not, the installer simply ignores Windows
# profiles and documents how to run install.ps1 instead.
WSL=0
if [[ "$(uname -s)" == "Linux" && "$(uname -r)" == *[Mm]icrosoft* ]]; then
  WSL=1
fi

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --profile PATH          Use this Firefox profile instead of detecting it
  --all-profiles          Apply the theme to every detected Firefox profile
  --single-profile        Apply the theme only to the selected profile (macOS)
  --firefox-bin PATH      Use this Firefox binary (Snap/custom; Flatpak is auto-detected)
  --force                 Close a running Firefox automatically, without asking
  --uninstall             Remove the theme files (backups are kept)
  --skip-firefox-install  Do not install Firefox automatically if missing
  -h, --help              Show this message

Firefox is installed automatically when missing. If Firefox is running, the
installer asks for confirmation in an interactive terminal and closes it with
SIGTERM, then SIGKILL only after a timeout. In a non-interactive shell, pass
--force to allow the automatic shutdown. The theme files are read only at
startup.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { echo "Error: --profile requires a path." >&2; exit 1; }
      PROFILE="$2"
      MANUAL_PROFILE=1
      shift 2
      ;;
    --firefox-bin)
      [[ $# -ge 2 ]] || { echo "Error: --firefox-bin requires a path." >&2; exit 1; }
      [[ -x "$2" ]] || { echo "Error: Firefox binary is not executable: $2" >&2; exit 1; }
      export FURR_FIREFOX_BIN="$2"
      shift 2
      ;;
    --all-profiles)
      ALL_PROFILES=1
      shift
      ;;
    --single-profile)
      SINGLE_PROFILE=1
      ALL_PROFILES=0
      shift
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

# On macOS a single wrong profile means the browser shows no change at all.
# Theme every local Firefox profile by default so whichever one Firefox opens
# is covered. An explicit --profile or --single-profile keeps the old behavior.
if [[ "$(uname -s)" == "Darwin" && "$MANUAL_PROFILE" -eq 0 \
  && "$ALL_PROFILES" -eq 0 && "$SINGLE_PROFILE" -eq 0 ]]; then
  ALL_PROFILES=1
fi

echo "FurrOS Firefox theme installer — starting..."

# sudo changes HOME on Linux/macOS; without this warning the installer would
# happily write into root's Firefox profile instead of the user's.
if [[ "$(id -u)" -eq 0 && ( "$HOME" == "/root" || "$HOME" == "/var/root" ) ]]; then
  echo "Warning: running as root targets $HOME. Run as the desktop user instead" >&2
  echo "unless you intentionally want to change root's Firefox profile." >&2
fi

trap 'code=$?; if [[ $code -ne 0 ]]; then echo; echo "INSTALL FAILED (exit $code)."; echo "Report: $REPORT"; if [[ -t 0 && -z "${FURR_NO_PAUSE:-}" ]]; then read -rp "Press Enter to close..." || true; fi; fi' EXIT

windows_firefox_dir() {
  # Print the Unix path of %APPDATA%\Mozilla\Firefox when running under WSL.
  [[ "$WSL" -eq 1 ]] || return 1
  command -v cmd.exe >/dev/null 2>&1 || return 1
  command -v wslpath >/dev/null 2>&1 || return 1
  local raw dir
  raw="$(cmd.exe /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r\n')" || return 1
  [[ -n "$raw" ]] || return 1
  dir="$(wslpath -u "$raw" 2>/dev/null)/Mozilla/Firefox" || return 1
  [[ -d "$dir" ]] || return 1
  printf '%s\n' "$dir"
  return 0
}

windows_ini_candidates() {
  local dir
  dir="$(windows_firefox_dir)" || return 0
  printf '%s\n' "$dir/profiles.ini" "$dir/installs.ini"
}

# Match exact process names and the full command line. The second part is
# what catches Flatpak, Snap and custom binaries. The pattern deliberately
# requires a path/word boundary so this installer's own path (which contains
# "firefox-theme") is not mistaken for a browser process.
FIREFOX_CMD_PATTERN='(^|/)(firefox|firefox-bin|firefox-esr|org\.mozilla\.firefox)([[:space:]]|$)|/Mozilla/Firefox/|/snap/firefox/|/org\.mozilla\.firefox/'

firefox_pids() {
  local pid seen=() out=() cmd state
  local -a found=()

  if command -v pgrep >/dev/null 2>&1; then
    for name in firefox firefox-bin firefox-esr org.mozilla.firefox; do
      while IFS= read -r pid; do
        [[ -n "$pid" ]] && found+=("$pid")
      done < <(pgrep -x "$name" 2>/dev/null || true)
    done
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && found+=("$pid")
    done < <(pgrep -f "$FIREFOX_CMD_PATTERN" 2>/dev/null || true)
  elif [[ -d /proc ]]; then
    # Minimal environments without procps: read /proc directly.
    for cmd in /proc/[0-9]*/cmdline; do
      [[ -r "$cmd" ]] || continue
      pid="${cmd#/proc/}"
      pid="${pid%/cmdline}"
      cmd="$(tr '\0' ' ' < "$cmd" 2>/dev/null)" || continue
      if [[ "$cmd" =~ $FIREFOX_CMD_PATTERN ]]; then
        found+=("$pid")
      fi
    done
  elif command -v ps >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && found+=("$pid")
    done < <(ps -eo pid=,args= 2>/dev/null | grep -E "$FIREFOX_CMD_PATTERN" | awk '{print $1}' || true)
  fi

  # pgrep -f and ps also see this installer and its ancestors when a path or
  # argument contains "firefox". Never signal our own process tree.
  # Bash 3.2 (macOS /bin/bash) treats an empty array expansion as an unbound
  # variable under `set -u`; the ${arr[@]+...} form expands to nothing.
  for pid in ${found[@]+"${found[@]}"}; do
    is_own_process_tree "$pid" && continue
    if [[ -d "/proc/$pid" ]]; then
      if [[ -r "/proc/$pid/stat" ]]; then
        state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" || continue
        [[ "$state" == "Z" ]] && continue
      fi
    else
      # pgrep may report a PID that exited a moment ago.
      kill -0 "$pid" 2>/dev/null || continue
    fi
    if [[ " ${seen[*]-} " != *" $pid "* ]]; then
      seen+=("$pid")
      out+=("$pid")
    fi
  done
  printf '%s\n' "${out[*]-}"
}

is_own_process_tree() {
  local pid="$1" current="$$" parent guard=0 stat_line
  [[ "$pid" == "$current" ]] && return 0
  while [[ -n "$current" && "$current" != "0" && $guard -lt 32 ]]; do
    [[ "$pid" == "$current" ]] && return 0
    if [[ -r "/proc/$current/stat" ]]; then
      # Field 4 is the parent PID. comm may contain spaces or parentheses,
      # so strip everything up to the last closing parenthesis first.
      stat_line="$(sed 's/^.*) //' "/proc/$current/stat" 2>/dev/null)" || break
      parent="$(printf '%s' "$stat_line" | awk '{print $2}')"
    else
      parent="$(ps -o ppid= -p "$current" 2>/dev/null | tr -d ' ')" || break
    fi
    [[ -n "$parent" && "$parent" =~ ^[0-9]+$ ]] || break
    current="$parent"
    guard=$((guard + 1))
  done
  return 1
}

firefox_running() {
  [[ -n "$(firefox_pids)" ]]
}

process_alive() {
  local pid="$1" state
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -r "/proc/$pid/stat" ]]; then
    state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" || return 0
    [[ "$state" != "Z" ]] || return 1
  fi
  return 0
}

# Parse Path= entries from an ini file and print existing profile directories.
ini_profile_paths() {
  local ini="$1" base line key value path
  [[ -f "$ini" ]] || return 0
  base="$(cd "$(dirname "$ini")" && pwd -P)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ "$line" == *=* ]] || continue
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    [[ "$key" == "Path" ]] || continue
    if [[ "$value" == /* ]]; then
      path="$value"
    else
      path="$base/$value"
    fi
    [[ -d "$path" ]] && printf '%s\n' "$path"
  done < "$ini"
}

# Paths listed in [Install...] / bare installation sections. Unlike Path=
# entries these can be stale, so they are not normal profile candidates, but
# they are still real Firefox profile directories that may be opened by a
# launcher using an older installation hash. On macOS we theme them too.
ini_install_paths() {
  local ini="$1" base line key value path section=""
  [[ -f "$ini" ]] || return 0
  base="$(cd "$(dirname "$ini")" && pwd -P)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    if [[ "$line" =~ ^\[(Install)?[[:xdigit:]]+\]$ ]]; then
      section="$line"
      continue
    fi
    [[ "$line" == *=* ]] || continue
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    [[ -n "$section" && "$key" == "Default" ]] || continue
    if [[ "$value" == /* ]]; then
      path="$value"
    else
      path="$base/$value"
    fi
    [[ -d "$path" ]] && printf '%s\n' "$path"
  done < "$ini"
}

all_known_profile_paths() {
  local ini path
  while IFS= read -r ini; do
    while IFS= read -r path; do
      printf '%s\n' "$path"
    done < <(ini_profile_paths "$ini")
    while IFS= read -r path; do
      printf '%s\n' "$path"
    done < <(ini_install_paths "$ini")
  done < <(profile_ini_candidates)
}

managed_profiles_in_ini() {
  local path
  while IFS= read -r path; do
    [[ -f "$path/$MANAGED_MARKER" ]] && printf '%s\n' "$path"
  done < <(ini_profile_paths "$1")
}

# Which Firefox installation owns a profile path. Reported so a Flatpak or
# Snap install can never be mistaken for a system Firefox install (and vice
# versa): Flatpak is sandboxed and cannot read ~/.config/mozilla/firefox.
profile_container() {
  case "$1" in
    */.var/app/org.mozilla.firefox/*) printf 'Flatpak' ;;
    */snap/firefox/*) printf 'Snap' ;;
    */Library/Application\ Support/Firefox/*) printf 'macOS' ;;
    *Mozilla.Firefox*) printf 'Store/MSIX' ;;
    *) printf 'system' ;;
  esac
}

firefox_binary() {
  if [[ -n "${FURR_FIREFOX_BIN:-}" ]]; then
    printf '%s\n' "$FURR_FIREFOX_BIN"
    return
  fi
  case "$(profile_container "${PROFILE:-}")" in
    Flatpak) printf 'flatpak run org.mozilla.firefox\n' ;;
    Snap) printf 'snap run firefox\n' ;;
    *)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        local bin
        while IFS= read -r bin; do
          printf '%s\n' "$bin"
          return
        done < <(macos_firefox_binaries)
      fi
      command -v firefox || command -v firefox-esr || printf 'unknown\n'
      ;;
  esac
}

# Capture the profile held open by the Firefox instance that was running when
# the installer started. Must run BEFORE Firefox is closed. Only paths that
# are also registered in an ini file are used for scoring, so an unrelated
# lock from another user can never redirect the installation.
ACTIVE_PROFILES=()

is_active_profile() {
  local active
  for active in ${ACTIVE_PROFILES[@]+"${ACTIVE_PROFILES[@]}"}; do
    [[ "$active" == "$1" ]] && return 0
  done
  return 1
}

capture_active_profiles() {
  local pids pid link target rest name prefix candidate resolved active
  [[ -d /proc ]] || return 0
  pids="$(firefox_pids)" || return 0
  [[ -n "$pids" ]] || return 0
  read -ra pids <<< "$pids"
  for pid in ${pids[@]+"${pids[@]}"}; do
    for link in /proc/"$pid"/fd/*; do
      [[ -L "$link" ]] || continue
      target="$(readlink "$link" 2>/dev/null)" || continue
      case "$target" in
        */mozilla/firefox/*)
          rest="${target#*/mozilla/firefox/}"
          name="${rest%%/*}"
          prefix="${target%%/mozilla/firefox/*}"
          candidate="$prefix/mozilla/firefox/$name"
          ;;
        */Mozilla/Firefox/Profiles/*)
          rest="${target#*/Mozilla/Firefox/Profiles/}"
          name="${rest%%/*}"
          prefix="${target%%/Mozilla/Firefox/Profiles/*}"
          candidate="$prefix/Mozilla/Firefox/Profiles/$name"
          ;;
        *) continue ;;
      esac
      [[ -d "$candidate" ]] || continue
      [[ "$candidate" != */.cache/* ]] || continue
      is_active_profile "$candidate" && continue
      resolved="$(cd "$candidate" 2>/dev/null && pwd -P)" || continue
      is_active_profile "$resolved" && continue
      ACTIVE_PROFILES+=("$resolved")
    done
  done
  if [[ ${#ACTIVE_PROFILES[@]} -gt 0 ]]; then
    echo "Running Firefox profile: ${ACTIVE_PROFILES[0]} ($(profile_container "${ACTIVE_PROFILES[0]}"))"
  fi
}

# A SIGKILL or a crash can leave lock files behind. This function only runs
# when no Firefox process is visible, so every lock in a registered profile
# is stale. The PID recorded inside the lock may have been reused by an
# unrelated process; trusting it would leave Firefox unable to start and the
# installer waiting for a lock that will never disappear.
clear_stale_profile_locks() {
  [[ -z "$(firefox_pids)" ]] || return 0
  local ini path name file
  while IFS= read -r ini; do
    [[ -f "$ini" ]] || continue
    while IFS= read -r path; do
      # WSL cannot inspect Windows processes with pgrep; never touch locks
      # inside the Windows filesystem from the Linux side.
      [[ "$WSL" -eq 1 && "$path" == /mnt/* ]] && continue
      for name in lock parent.lock .parentlock; do
        file="$path/$name"
        [[ -e "$file" || -L "$file" ]] || continue
        # Firefox may have been started again while this loop was running.
        [[ -n "$(firefox_pids)" ]] && return 0
        echo "Removing stale profile lock: $file"
        rm -f "$file"
      done
    done < <(ini_profile_paths "$ini")
  done < <(profile_ini_candidates)
  return 0
}

wait_for_profile_locks() {
  local profile="$1" seconds="${2:-$LOCK_TIMEOUT}" i=0 locks="" found
  while :; do
    found=""
    for name in parent.lock .parentlock lock; do
      [[ -e "$profile/$name" || -L "$profile/$name" ]] && found+=" $name"
    done
    [[ -z "$found" ]] && return 0
    if (( i >= seconds * 5 )); then
      echo "Error: Firefox lock file still present in $profile after ${seconds}s:${found}" >&2
      echo "Running Firefox processes: $(firefox_pids)" >&2
      echo "Terminate Firefox completely, then run the installer again." >&2
      return 1
    fi
    sleep 0.2
    i=$((i + 1))
  done
}

wait_for_all_profile_locks() {
  local candidate path
  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] || continue
    while IFS= read -r path; do
      wait_for_profile_locks "$path" || return 1
    done < <(ini_profile_paths "$candidate")
  done < <(profile_ini_candidates)
  return 0
}

handle_running_firefox() {
  local pids answer i pid existing remaining="" newpids="" known
  local -a pid_array=() remaining_array=() new_array=()

  pids="$(firefox_pids)"
  [[ -n "$pids" ]] || return 0

  read -ra pid_array <<< "$pids"
  echo "Firefox is running (PID: ${pid_array[*]})."
  echo "Theme files are loaded only at startup, so Firefox must be closed first."

  if [[ "$FORCE" -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
      echo "Error: Firefox is running and this session is not interactive." >&2
      echo "Close Firefox and retry, or run with --force to close it automatically." >&2
      return 1
    fi
    read -rp "Close Firefox now? [y/N] " answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *)
        echo "Aborted: Firefox was left running." >&2
        return 1
        ;;
    esac
  fi

  echo "Closing Firefox cleanly (SIGTERM)..."
  kill -TERM ${pid_array[@]+"${pid_array[@]}"} 2>/dev/null || true
  for ((i = 0; i < FIREFOX_CLOSE_TIMEOUT * 5; i++)); do
    remaining=""
    for pid in ${pid_array[@]+"${pid_array[@]}"}; do
      process_alive "$pid" && remaining+=" $pid"
    done
    # Snap and Flatpak launchers can leave children behind: pick up any new
    # Firefox process and signal it too, instead of failing at the end.
    newpids="$(firefox_pids)"
    if [[ -n "$newpids" ]]; then
      read -ra new_array <<< "$newpids"
      for pid in ${new_array[@]+"${new_array[@]}"}; do
        known=0
        for existing in ${pid_array[@]+"${pid_array[@]}"}; do
          if [[ "$existing" == "$pid" ]]; then
            known=1
            break
          fi
        done
        if [[ "$known" -eq 0 ]]; then
          pid_array+=("$pid")
          kill -TERM "$pid" 2>/dev/null || true
        fi
      done
    fi
    [[ -z "$remaining" && -z "$newpids" ]] && break
    sleep 0.2
  done

  if [[ -n "$remaining" || -n "$newpids" ]]; then
    echo "Warning: Firefox did not exit within ${FIREFOX_CLOSE_TIMEOUT}s. Forcing termination (SIGKILL)." >&2
    read -ra remaining_array <<< "$remaining $newpids"
    kill -KILL ${remaining_array[@]+"${remaining_array[@]}"} 2>/dev/null || true
    for ((i = 0; i < FIREFOX_KILL_TIMEOUT * 5; i++)); do
      remaining=""
      for pid in ${remaining_array[@]+"${remaining_array[@]}"}; do
        process_alive "$pid" && remaining+=" $pid"
      done
      [[ -z "$remaining" ]] && break
      sleep 0.2
    done
  fi

  newpids="$(firefox_pids)"
  if [[ -n "$newpids" ]]; then
    echo "Error: Firefox could not be closed (PID: $newpids)." >&2
    echo "Close it manually and run the installer again." >&2
    return 1
  fi
  clear_stale_profile_locks || return 1
  wait_for_all_profile_locks || return 1
  echo "Firefox closed; profile locks released."
  return 0
}

# macOS installs Firefox.app in /Applications, but users can also install it
# in ~/Applications. Finder-based installs and some managed Macs use the
# per-user location, so both are checked before falling back to PATH.
macos_firefox_binaries() {
  local root roots old_ifs
  # Colon-separated application folders. The override keeps tests away from
  # a real /Applications/Firefox.app and supports managed Macs that install
  # Firefox somewhere else.
  roots="${FURR_MACOS_APPLICATIONS:-/Applications:$HOME/Applications}"
  old_ifs="$IFS"
  IFS=':'
  for root in $roots; do
    [[ -n "$root" ]] || continue
    if [[ -x "$root/Firefox.app/Contents/MacOS/firefox" ]]; then
      printf '%s\n' "$root/Firefox.app/Contents/MacOS/firefox"
    fi
  done
  IFS="$old_ifs"
  return 0
}

firefox_ready() {
  local candidate

  if [[ "$(uname -s)" == "Darwin" ]]; then
    while IFS= read -r candidate; do
      if "$candidate" --version >/dev/null 2>&1; then
        return 0
      fi
    done < <(macos_firefox_binaries)
  fi

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

  # Under WSL an existing Windows Firefox profile means the browser is
  # installed on the Windows side: do not install a second copy in Linux.
  local dir
  if dir="$(windows_firefox_dir)" \
    && { [[ -f "$dir/profiles.ini" || -f "$dir/installs.ini" ]]; }; then
    return 0
  fi
  firefox_ready
}

# Build the command used to start Firefox once for profile initialization.
# The result is stored in FIREFOX_LAUNCH so arguments with spaces (Flatpak,
# Snap, app bundles) survive without eval.
firefox_launch_command() {
  FIREFOX_LAUNCH=()

  if [[ -n "${FURR_FIREFOX_BIN:-}" ]]; then
    if [[ -x "$FURR_FIREFOX_BIN" ]]; then
      FIREFOX_LAUNCH=("$FURR_FIREFOX_BIN")
      return 0
    fi
    return 1
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    local bin
    while IFS= read -r bin; do
      FIREFOX_LAUNCH=("$bin")
      return 0
    done < <(macos_firefox_binaries)
    return 1
  fi

  local name
  for name in firefox firefox-esr; do
    if command -v "$name" >/dev/null 2>&1; then
      FIREFOX_LAUNCH=("$name")
      return 0
    fi
  done
  if command -v flatpak >/dev/null 2>&1 \
    && flatpak run org.mozilla.firefox --version >/dev/null 2>&1; then
    FIREFOX_LAUNCH=(flatpak run org.mozilla.firefox)
    return 0
  fi
  if command -v snap >/dev/null 2>&1 \
    && snap run firefox --version >/dev/null 2>&1; then
    FIREFOX_LAUNCH=(snap run firefox)
    return 0
  fi
  return 1
}

# Run a command with a timeout without depending on GNU timeout, which macOS
# does not ship. Returns the command's exit status, or 1 after killing it.
run_with_timeout() {
  local seconds="$1" pid i state
  shift
  "$@" >/dev/null 2>&1 &
  pid=$!
  for ((i = 0; i < seconds * 10; i++)); do
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    if [[ -z "$state" || "$state" == Z* ]]; then
      if wait "$pid" 2>/dev/null; then
        return 0
      fi
      return 1
    fi
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$state" && "$state" != Z* ]]; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  return 1
}

# The profile Firefox really opens is the only reliable answer on macOS:
# installs.ini can contain a hash from an older app location, and profiles.ini
# can still point at a profile that Firefox no longer uses. Starting Firefox
# once in headless mode with the very same binary exposes that profile through
# its lock file. The ini files alone are not enough.
BOOT_PROFILE=""
PROBE_DONE=0

all_registered_paths() {
  local ini path
  while IFS= read -r ini; do
    [[ -f "$ini" ]] || continue
    while IFS= read -r path; do
      printf '%s\n' "$path"
    done < <(ini_profile_paths "$ini")
  done < <(profile_ini_candidates)
}

initialize_firefox_profile() {
  local tmp pid state i path lock found="" before leftovers
  local -a leftover_pids=()
  PROBE_DONE=1
  firefox_launch_command || return 1
  before="$(all_registered_paths)"
  tmp="$(mktemp -d)"
  echo "Checking which Firefox profile is used..."
  ${FIREFOX_LAUNCH[@]+"${FIREFOX_LAUNCH[@]}"} --headless --new-instance \
    --screenshot "$tmp/shot.png" about:blank >/dev/null 2>&1 &
  pid=$!
  for ((i = 0; i < 1200; i++)); do
    # A lock file belongs to the profile this Firefox instance opened.
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      for lock in parent.lock .parentlock lock; do
        if [[ -e "$path/$lock" || -L "$path/$lock" ]]; then
          found="$path"
          break 2
        fi
      done
    done < <(all_registered_paths)
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || state=""
    if [[ -z "$state" || "$state" == Z* ]]; then
      break
    fi
    sleep 0.1
  done
  if ! wait "$pid" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  # The headless process can leave short-lived children behind. Firefox was
  # closed before the probe started, so anything still running belongs to the
  # probe and must be stopped before a lock can be treated as stale.
  leftovers="$(firefox_pids)"
  if [[ -n "$leftovers" ]]; then
    read -ra leftover_pids <<< "$leftovers"
    kill -TERM ${leftover_pids[@]+"${leftover_pids[@]}"} 2>/dev/null || true
    for ((i = 0; i < 50; i++)); do
      [[ -z "$(firefox_pids)" ]] && break
      sleep 0.1
    done
    leftovers="$(firefox_pids)"
    if [[ -n "$leftovers" ]]; then
      read -ra leftover_pids <<< "$leftovers"
      kill -KILL ${leftover_pids[@]+"${leftover_pids[@]}"} 2>/dev/null || true
      sleep 0.5
    fi
  fi
  # A headless run can leave lock files behind even after a clean exit. No
  # Firefox process is alive now, so those locks are stale.
  clear_stale_profile_locks || true
  wait_for_all_profile_locks || return 1
  if [[ -z "$found" ]]; then
    # A first run creates the real profile and registers it in the ini files.
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      if [[ $'\n'"$before"$'\n' != *$'\n'"$path"$'\n'* ]]; then
        found="$path"
        break
      fi
    done < <(all_registered_paths)
  fi
  if [[ -n "$found" ]]; then
    BOOT_PROFILE="$found"
    echo "Firefox opened profile: $BOOT_PROFILE"
  fi
  return 0
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: administrator privileges are required, but sudo is not available." >&2
    return 1
  fi
  sudo "$@"
}

install_firefox_linux() {
  # Prefer a real browser package over transitional wrappers. Ubuntu/Zorin
  # ship an apt "firefox" package that only points to Snap. Snap needs
  # systemd, which is not available in WSL, so skip it there.
  if [[ "$WSL" -ne 1 ]] && command -v snap >/dev/null 2>&1; then
    run_as_root snap install firefox || true
    firefox_ready && return 0
  fi
  if command -v flatpak >/dev/null 2>&1; then
    flatpak remote-add --if-not-exists flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo || true
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
  if [[ "$WSL" -ne 1 ]]; then
    if ! command -v snap >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
      run_as_root apt-get install -y snapd || true
    fi
    if command -v snap >/dev/null 2>&1; then
      run_as_root snap install firefox || true
      firefox_ready && return 0
    fi
  fi
  if command -v flatpak >/dev/null 2>&1; then
    flatpak remote-add --if-not-exists flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo || true
    flatpak install -y flathub org.mozilla.firefox || true
    firefox_ready && return 0
  fi

  return 1
}

install_firefox_macos() {
  command -v curl >/dev/null 2>&1 || return 1
  command -v hdiutil >/dev/null 2>&1 || return 1

  # os=osx is Mozilla's universal DMG: it works on Intel and Apple Silicon.
  local tmp mount app old_app="" attached=0 ok=0
  tmp="$(mktemp -d)"
  mount="$tmp/mount"
  app="/Applications/Firefox.app"
  mkdir -p "$mount"

  cleanup() {
    if [[ "$attached" -eq 1 ]]; then
      hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
  }

  echo "Downloading Firefox for macOS..."
  if ! curl -fL --retry 3 --max-time 300 \
    -o "$tmp/firefox.dmg" \
    'https://download.mozilla.org/?product=firefox-latest-ssl&os=osx&lang=en-US'; then
    cleanup
    return 1
  fi

  if ! hdiutil attach "$tmp/firefox.dmg" -mountpoint "$mount" -nobrowse -quiet; then
    cleanup
    return 1
  fi
  attached=1

  if [[ ! -d "$mount/Firefox.app" ]]; then
    cleanup
    return 1
  fi

  # Move the old app aside instead of deleting it, so a failed copy can be
  # rolled back. The temporary backup is discarded only after success.
  if [[ -e "$app" ]]; then
    old_app="$tmp/Firefox.app.old"
    if [[ -w /Applications ]]; then
      mv "$app" "$old_app" || { cleanup; return 1; }
    else
      sudo mv "$app" "$old_app" || { cleanup; return 1; }
    fi
  fi

  if [[ -w /Applications ]]; then
    cp -R "$mount/Firefox.app" "$app" >/dev/null 2>&1 || true
  else
    sudo cp -R "$mount/Firefox.app" /Applications/ >/dev/null 2>&1 || true
  fi

  if [[ -x "$app/Contents/MacOS/firefox" ]]; then
    ok=1
  fi

  if [[ "$ok" -eq 0 ]]; then
    if [[ -n "$old_app" && -e "$old_app" ]]; then
      if [[ -w /Applications ]]; then
        mv "$old_app" "$app" >/dev/null 2>&1 || true
      else
        sudo mv "$old_app" "$app" >/dev/null 2>&1 || true
      fi
    fi
    cleanup
    return 1
  fi

  cleanup
  return 0
}

ensure_firefox() {
  if firefox_installed; then
    return 0
  fi

  if [[ "$SKIP_FIREFOX_INSTALL" -eq 1 ]]; then
    echo "Error: Firefox was not found on this system." >&2
    echo "Install it with your package manager, or pass --firefox-bin /path/to/firefox." >&2
    echo "Examples: sudo apt install firefox | sudo dnf install firefox | flatpak install flathub org.mozilla.firefox" >&2
    echo "Remove --skip-firefox-install to let this installer try automatically." >&2
    exit 1
  fi

  echo "Firefox not found. Installing it automatically..."
  case "$(uname -s)" in
    Linux)
      install_firefox_linux || {
        echo "Error: could not install Firefox automatically on this Linux system." >&2
        echo "Install it manually (apt/dnf/yum/zypper/pacman/snap/flatpak) and retry," >&2
        echo "or pass --firefox-bin /path/to/firefox if your browser is in a custom location." >&2
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
  # Firefox reads both profiles.ini and installs.ini. A profiles.ini inside
  # Profiles/ is never used by Firefox: older FurrOS installers wrote one
  # there, so it is deliberately excluded on every platform.
  #
  # On macOS the native profile root is checked first. A stale Linux-style
  # ~/.mozilla or ~/.config profile must never win over the profile Firefox
  # actually uses.
  local mac=0
  if [[ "$(uname -s)" == "Darwin" ]]; then
    mac=1
  fi

  if [[ "$mac" -eq 1 ]]; then
    printf '%s\n' \
      "$HOME/Library/Application Support/Firefox/profiles.ini" \
      "$HOME/Library/Application Support/Firefox/installs.ini"
  fi

  printf '%s\n' \
    "$HOME/.mozilla/firefox/profiles.ini" \
    "$HOME/.mozilla/firefox/installs.ini" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox/profiles.ini" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox/installs.ini" \
    "$HOME/.config/mozilla/firefox/profiles.ini" \
    "$HOME/.config/mozilla/firefox/installs.ini" \
    "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini" \
    "$HOME/snap/firefox/common/.mozilla/firefox/installs.ini" \
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini" \
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/installs.ini"

  if [[ "$mac" -eq 0 ]]; then
    printf '%s\n' \
      "$HOME/Library/Application Support/Firefox/profiles.ini" \
      "$HOME/Library/Application Support/Firefox/installs.ini"
  fi

  windows_ini_candidates
}

append_ini_sections() {
  local file="$1" section="$2" body="$3" header
  header="[$section]"
  if [[ -f "$file" ]] && grep -Fqx "$header" "$file"; then
    return 0
  fi
  if [[ ! -s "$file" ]]; then
    printf '%s\n%s\n' "$header" "$body" > "$file"
  else
    printf '\n%s\n%s\n' "$header" "$body" >> "$file"
  fi
}

next_profile_index() {
  local file="$1" line n max=-1
  [[ -f "$file" ]] || { printf '0'; return; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    if [[ "$line" =~ ^\[Profile([0-9]+)\]$ ]]; then
      n="${BASH_REMATCH[1]}"
      (( n > max )) && max="$n"
    fi
  done < "$file"
  printf '%d' "$((max + 1))"
}

# True when at least one existing directory is registered as a Firefox
# profile in any standard profiles.ini or installs.ini.
has_registered_profile() {
  local candidate path
  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] || continue
    while IFS= read -r path; do
      [[ -d "$path" ]] && return 0
    done < <(ini_profile_paths "$candidate")
  done < <(profile_ini_candidates)
  return 1
}

create_firefox_profile() {
  local candidate base ini default_path id dir os managed index

  # Reuse a profile previously created by this project. It carries a marker
  # file, so re-runs never add a second FurrOS profile.
  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] || continue
    while IFS= read -r managed; do
      if [[ -d "$managed" ]]; then
        echo "Reusing FurrOS-managed profile: $managed"
        return 0
      fi
    done < <(managed_profiles_in_ini "$candidate")
  done < <(profile_ini_candidates)

  # Never create a second profile when Firefox already has a usable profile
  # in any standard location (including Flatpak and Snap). Reading Path=
  # directly also covers ini files that only contain [Install...] entries.
  # An existing directory registered in an ini is a Firefox profile, even
  # when Firefox has not written prefs.js yet.
  if has_registered_profile; then
    return 0
  fi

  # No profile exists yet and the headless probe did not run. Let Firefox
  # create its real default profile and installs.ini instead of writing a
  # Default=1 profile that Firefox 67+ ignores. If Firefox cannot be started
  # (for example under WSL when only the Windows browser exists), fall back
  # to the manual profile below.
  if [[ "$PROBE_DONE" -eq 0 ]]; then
    if initialize_firefox_profile && has_registered_profile; then
      return 0
    fi
  fi

  os="$(uname -s)"
  if [[ "$os" == "Darwin" ]]; then
    base="$HOME/Library/Application Support/Firefox/Profiles"
    ini="$HOME/Library/Application Support/Firefox/profiles.ini"
  elif command -v flatpak >/dev/null 2>&1 \
    && flatpak run org.mozilla.firefox --version >/dev/null 2>&1; then
    base="$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
    ini="$base/profiles.ini"
  elif command -v snap >/dev/null 2>&1 \
    && snap run firefox --version >/dev/null 2>&1; then
    base="$HOME/snap/firefox/common/.mozilla/firefox"
    ini="$base/profiles.ini"
  else
    base="${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
    ini="$base/profiles.ini"
  fi

  mkdir -p "$(dirname "$ini")" "$base"
  id="$(openssl rand -hex 4 2>/dev/null || printf 'furros%s' "$$")"
  id="${id:0:8}"
  dir="${id}.default-release"
  if [[ "$os" == "Darwin" ]]; then
    # Paths are relative to the folder containing profiles.ini.
    default_path="Profiles/$dir"
  else
    default_path="$dir"
  fi

  index="$(next_profile_index "$ini")"
  mkdir -p "$base/$dir"
  : > "$base/$dir/$MANAGED_MARKER"

  # Append instead of rewriting: existing [General]/[Install] sections and
  # unrelated user settings must survive a first FurrOS installation.
  if [[ ! -s "$ini" ]]; then
    printf '[General]\nStartWithLastProfile=1\nVersion=2\n' > "$ini"
  fi
  # Do not invent an [Install<hash>] section here. Firefox derives the hash
  # from its own installation directory and creates installs.ini on first
  # start; a fake hash is ignored (or, worse, migrated by Firefox and later
  # mistaken for a real default). The legacy [Profile] Default=1 flag is
  # enough to make Firefox pick this profile on first start.
  append_ini_sections "$ini" "Profile$index" "Name=default-release
IsRelative=1
Path=$default_path
Default=1"
  echo "Created Firefox profile: $base/$dir"
}

if [[ "$UNINSTALL" -ne 1 ]]; then
  ensure_firefox
fi

# Capture the active profile before shutdown, then close Firefox and clear
# locks left behind by an earlier crash before touching any profile data.
capture_active_profiles
handle_running_firefox || exit 1
clear_stale_profile_locks

# A manual --profile is used as-is: do not probe or create another profile
# behind the user's back. Otherwise ask Firefox itself which profile it opens
# before reading the ini files; on macOS the running instance cannot be
# inspected through /proc, and an outdated installs.ini can be misleading.
if [[ "$UNINSTALL" -ne 1 && -z "$PROFILE" ]]; then
  initialize_firefox_profile || true
  create_firefox_profile
fi

# Wait again after profile creation: a slow shutdown may leave a lock file
# behind even when the process is already gone.
wait_for_all_profile_locks || exit 1

PROFILES=()
INIS=()
INSTALL_DEFAULTS=()

add_ini() {
  local existing
  [[ -f "$1" ]] || return 0
  for existing in ${INIS[@]+"${INIS[@]}"}; do
    [[ "$existing" == "$1" ]] && return 0
  done
  INIS+=("$1")
  return 0
}

add_profile() {
  local flag="$1" name="$2" path="$3" existing
  [[ -d "$path" ]] || return 0
  if [[ ${#PROFILES[@]} -gt 0 ]]; then
    for existing in ${PROFILES[@]+"${PROFILES[@]}"}; do
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
  local ini="$1" base line key value path name default section="" resolved header hash

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
      \[*\])
        finish_profile
        section=""
        header="${line#\[}"
        header="${header%\]}"
        if [[ "$header" == Install* ]]; then
          hash="${header#Install}"
        else
          hash="$header"
        fi
        if is_install_hash "$hash"; then
          section="Install"
        fi
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

  for ini in ${INIS[@]+"${INIS[@]}"}; do
    echo "Found profile list: $ini"
    parse_ini "$ini"
  done

  if [[ ${#PROFILES[@]} -eq 0 ]]; then
    echo "Error: Firefox profile not found." >&2
    echo "Specify it with: ./install.sh --profile /full/path/to/profile" >&2
    exit 1
  fi

  # Score: 6 = profile Firefox opened during the headless probe, 5 = profile
  # that was open when installation started (this is what distinguishes
  # Flatpak from a system Firefox install), 3 = Firefox [Install] default,
  # 2 = legacy [Profile] Default=1, 1 = other profile.
  # The active profile was recorded before Firefox was closed and is only
  # considered when it is registered in an ini file. Ties are resolved
  # automatically: FurrOS-managed, initialized, default-release, then the
  # lexicographically first path. Never prompt.
  SCORED=()
  for entry in ${PROFILES[@]+"${PROFILES[@]}"}; do
    flag="${entry%%$'\t'*}"
    rest="${entry#*$'\t'}"
    path="${rest##*$'\t'}"

    score=1
    [[ "$flag" == "1" ]] && score=2
    for default_path in ${INSTALL_DEFAULTS[@]+"${INSTALL_DEFAULTS[@]}"}; do
      [[ "$default_path" == "$path" ]] && score=3
    done
    # The running profile wins even when another installation's [Install]
    # section sorts first (a common Flatpak + system Firefox setup).
    if is_active_profile "$path"; then
      score=5
    fi
    # The profile Firefox just opened with the binary we found is the ground
    # truth. On macOS there is no /proc, so nothing outranks it there; on
    # Linux a profile that was open when the installer started still wins.
    if [[ -n "$BOOT_PROFILE" && "$path" == "$BOOT_PROFILE" ]] \
      && ! is_active_profile "$path"; then
      if [[ ${#ACTIVE_PROFILES[@]} -eq 0 ]]; then
        score=6
      else
        score=4
      fi
    fi

    managed=0
    [[ -f "$path/$MANAGED_MARKER" ]] && managed=1
    established=0
    [[ -f "$path/prefs.js" || -f "$path/user.js" ]] && established=1
    preferred=0
    case "$path" in
      *.default-release*) preferred=1 ;;
    esac

    SCORED+=("$score"$'\t'"$managed"$'\t'"$established"$'\t'"$preferred"$'\t'"$path")
  done

  BEST="$(printf '%s\n' ${SCORED[@]+"${SCORED[@]}"} \
    | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4nr -k5,5 \
    | sed -n '1p')"
  PROFILE="${BEST##*$'\t'}"
  echo "Selected profile: $PROFILE"
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

# On macOS even a careful profile probe can be defeated by a launcher that
# opens a different profile. Theme every registered profile, plus any native
# profile folder Firefox created without a standard ini entry. The selected
# profile stays first so the report and messages remain useful.
TARGETS=("$PROFILE")
add_target() {
  local candidate="$1" existing resolved
  [[ -n "$candidate" && -d "$candidate" ]] || return 0
  # Resolve /var -> /private/var and similar symlinks so the same profile
  # cannot be added twice through two different path spellings.
  resolved="$(cd "$candidate" 2>/dev/null && pwd -P)" || return 0
  for existing in ${TARGETS[@]+"${TARGETS[@]}"}; do
    [[ "$existing" == "$resolved" ]] && return 0
  done
  TARGETS+=("$resolved")
}
if [[ "$ALL_PROFILES" -eq 1 ]]; then
  while IFS= read -r candidate; do
    add_target "$candidate"
  done < <(all_known_profile_paths)
  if [[ "$(uname -s)" == "Darwin" ]]; then
    for candidate in "$HOME/Library/Application Support/Firefox/Profiles"/* \
                     "$HOME/Library/Application Support/Firefox"/*; do
      [[ -d "$candidate" ]] || continue
      [[ "$(basename "$candidate")" == "Profiles" ]] && continue
      [[ -f "$candidate/prefs.js" || -f "$candidate/user.js" || -d "$candidate/chrome" ]] || continue
      add_target "$candidate"
    done
  fi
  echo "Applying the theme to ${#TARGETS[@]} Firefox profile(s)."
fi

if [[ "$MANUAL_PROFILE" -eq 1 ]]; then
  PROFILE_SOURCE="manual --profile"
elif is_active_profile "$PROFILE"; then
  PROFILE_SOURCE="running Firefox ($(profile_container "$PROFILE"))"
elif [[ -n "$BOOT_PROFILE" && "$PROFILE" == "$BOOT_PROFILE" ]]; then
  PROFILE_SOURCE="Firefox headless probe ($(profile_container "$PROFILE"))"
else
  PROFILE_SOURCE="Firefox profile lists"
fi

# Final guard immediately before any write: a profile can be locked by a
# Firefox instance that started while the installer was running.
for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
  wait_for_profile_locks "$target" || exit 1
done

# Avoid overwriting an existing backup when two runs happen in one second.
TS="$(date +%Y%m%d-%H%M%S)"
while :; do
  collision=0
  for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
    if [[ -e "$target/user.js.bak-$TS" \
      || -e "$target/chrome/userChrome.css.bak-$TS" \
      || -e "$target/chrome/userContent.css.bak-$TS" ]]; then
      collision=1
      break
    fi
  done
  [[ "$collision" -eq 0 ]] && break
  sleep 1
  TS="$(date +%Y%m%d-%H%M%S)"
done

version() {
  local bin
  if [[ -n "${FURR_FIREFOX_BIN:-}" && -x "$FURR_FIREFOX_BIN" ]]; then
    "$FURR_FIREFOX_BIN" --version 2>/dev/null && return 0
  fi
  firefox --version 2>/dev/null \
    || firefox-esr --version 2>/dev/null \
    || flatpak run org.mozilla.firefox --version 2>/dev/null \
    || snap run firefox --version 2>/dev/null \
    || {
      while IFS= read -r bin; do
        "$bin" --version 2>/dev/null && return 0
      done < <(macos_firefox_binaries)
      [[ "$WSL" -eq 1 ]] && echo "Firefox on Windows (WSL)"
    } \
    || echo "version unavailable"
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  REMOVED=()
  for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
    for f in userChrome.css userContent.css; do
      if [[ -f "$target/chrome/$f" ]]; then
        rm -f "$target/chrome/$f"
        REMOVED+=("$target/chrome/$f")
      fi
    done
    if [[ -f "$target/user.js" ]]; then
      rm -f "$target/user.js"
      REMOVED+=("$target/user.js")
    fi
  done
  {
    echo "FurrOS Firefox theme installation report"
    echo "Date:     $(date)"
    echo "System:   $(uname -s) $(uname -r)"
    echo "User:     ${USER:-unknown}"
    echo "Home:     $HOME"
    echo "Source:   $SRC"
    echo "Profile:  $PROFILE"
    for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
      echo "Profile:  $target"
    done
    echo "Profile source: ${PROFILE_SOURCE:-automatic}"
    echo "Container:     $(profile_container "$PROFILE")"
    echo "Firefox:  $(version)"
    echo "Firefox binary: $(firefox_binary)"
    echo "Action:   Uninstall"
    if [[ ${#REMOVED[@]} -eq 0 ]]; then
      echo "Removed:  nothing (no theme files were present)"
    else
      for f in ${REMOVED[@]+"${REMOVED[@]}"}; do
        echo "Removed:  $f"
      done
    fi
  } > "$REPORT"
  echo
  echo "FurrOS theme removed from: $PROFILE"
  echo "Report saved: $REPORT"
  echo "Start Firefox again to apply the change."
  exit 0
fi

for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
  target_chrome="$target/chrome"
  mkdir -p "$target_chrome"

  for f in userChrome.css userContent.css; do
    if [[ -f "$target_chrome/$f" ]]; then
      cp -p "$target_chrome/$f" "$target_chrome/$f.bak-$TS"
    fi
  done
  if [[ -f "$target/user.js" ]]; then
    cp -p "$target/user.js" "$target/user.js.bak-$TS"
  fi

  for f in userChrome.css userContent.css; do
    [[ -f "$SRC/$f" ]] || { echo "Error: missing source file: $SRC/$f" >&2; exit 1; }
    cp "$SRC/$f" "$target_chrome/$f"
    cmp -s "$SRC/$f" "$target_chrome/$f" || { echo "Error: copy failed for $f in $target" >&2; exit 1; }
  done

  [[ -f "$SRC/user.js" ]] || { echo "Error: missing source file: $SRC/user.js" >&2; exit 1; }
  cp "$SRC/user.js" "$target/user.js"
  cmp -s "$SRC/user.js" "$target/user.js" || { echo "Error: copy failed for user.js in $target" >&2; exit 1; }
  grep -Fq "$REQUIRED_PREF" "$target/user.js" || {
    echo "Error: user.js is missing the required stylesheet preference in $target." >&2
    exit 1
  }
done

{
  echo "FurrOS Firefox theme installation report"
  echo "Date:     $(date)"
  echo "System:   $(uname -s) $(uname -r)"
  echo "User:     ${USER:-unknown}"
  echo "Home:     $HOME"
  echo "Source:   $SRC"
  echo "Profile:  $PROFILE"
  for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
    echo "Profile:  $target"
  done
  echo "Profile source: ${PROFILE_SOURCE:-automatic}"
  echo "Container:     $(profile_container "$PROFILE")"
  echo "Firefox:  $(version)"
  echo "Firefox binary: $(firefox_binary)"
  echo "Backup:   .bak-$TS"
  echo "Action:   Install"
  for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
    echo "Verified: $target/chrome/userChrome.css"
    echo "Verified: $target/chrome/userContent.css"
    echo "Verified: $target/user.js"
  done
  echo "Verified: stylesheet preference enabled"
} > "$REPORT"

echo
echo "FurrOS theme installed in ${#TARGETS[@]} Firefox profile(s):"
for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
  echo "  $target"
done
echo "Previous files backed up with suffix .bak-$TS"
echo "Verified: all three theme files match the repository."
echo "Verified: stylesheet preference enabled."
echo "Report saved: $REPORT"
echo
echo "Now start Firefox. If it was open, close it completely first."
