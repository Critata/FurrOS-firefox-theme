#!/usr/bin/env python3
"""Cross-platform installer for the FurrOS Firefox theme.

Works on Linux, Windows and macOS. Firefox must be closed because
user.js and the chrome CSS files are read only at startup.
"""

from __future__ import annotations

import argparse
import configparser
import hashlib
import os
import platform
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
THEME_FILES = ("userChrome.css", "userContent.css", "user.js")
REQUIRED_PREF = 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_wsl() -> bool:
    """True when Python runs inside Windows Subsystem for Linux."""
    if platform.system() != "Linux":
        return False
    if "microsoft" in platform.release().lower() or "wsl" in platform.release().lower():
        return True
    try:
        return "microsoft" in Path("/proc/version").read_text(
            encoding="utf-8", errors="ignore"
        ).lower()
    except OSError:
        return False


def wsl_windows_firefox_dir() -> Path | None:
    """Return %APPDATA%\\Mozilla\\Firefox as a WSL path, when available."""
    if not is_wsl() or not shutil.which("cmd.exe") or not shutil.which("wslpath"):
        return None
    try:
        raw = subprocess.check_output(
            ["cmd.exe", "/c", "echo %APPDATA%"],
            text=True,
            errors="ignore",
            timeout=10,
        ).strip().strip("\r\n")
        if not raw:
            return None
        unix = subprocess.check_output(
            ["wslpath", "-u", raw], text=True, errors="ignore", timeout=10
        ).strip()
        if not unix:
            return None
        firefox_dir = Path(unix) / "Mozilla" / "Firefox"
        return firefox_dir if firefox_dir.is_dir() else None
    except Exception:
        return None


def windows_store_firefox_dir() -> Path | None:
    """Return the Firefox profile folder of a Microsoft Store / MSIX install."""
    if platform.system() != "Windows":
        return None
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        return None
    packages = Path(local) / "Packages"
    if not packages.is_dir():
        return None
    relatives = (
        "LocalCache/Roaming/Mozilla/Firefox",
        "LocalCache/Local/Mozilla/Firefox",
        "LocalState/Mozilla/Firefox",
    )
    for app in packages.glob("Mozilla.Firefox*"):
        for relative in relatives:
            firefox_dir = app / relative
            if (firefox_dir / "profiles.ini").is_file() or (
                firefox_dir / "installs.ini"
            ).is_file():
                return firefox_dir
    # A Store Firefox that has never started has no ini yet, but the
    # LocalCache\Roaming folder still exists and is where Firefox will look.
    for app in packages.glob("Mozilla.Firefox*"):
        candidate = app / "LocalCache" / "Roaming" / "Mozilla" / "Firefox"
        if candidate.parent.is_dir():
            return candidate
    return None


def firefox_running() -> bool:
    system = platform.system()
    if system == "Windows":
        try:
            output = subprocess.check_output(
                ["tasklist"], text=True, errors="ignore", timeout=10
            )
            if "firefox.exe" in output.lower():
                return True
        except Exception:
            pass
    elif is_wsl():
        try:
            output = subprocess.check_output(
                ["tasklist.exe"], text=True, errors="ignore", timeout=10
            )
            if "firefox.exe" in output.lower():
                return True
        except Exception:
            pass

    # Match process names only. Matching full command lines would also match
    # this installer when its path contains "firefox".
    for name in ("firefox", "firefox-bin", "firefox-esr", "org.mozilla.firefox"):
        try:
            output = subprocess.check_output(
                ["pgrep", "-x", name], text=True, errors="ignore", timeout=10
            )
        except Exception:
            continue
        if output.strip():
            return True
    return False


def command_works(command: list[str]) -> bool:
    try:
        result = subprocess.run(
            command + ["--version"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
        return result.returncode == 0
    except Exception:
        return False


def firefox_ready() -> bool:
    for name in ("firefox", "firefox-esr"):
        binary = shutil.which(name)
        if binary and command_works([binary]):
            return True

    system = platform.system()
    if system == "Darwin":
        binary = "/Applications/Firefox.app/Contents/MacOS/firefox"
        if Path(binary).is_file() and command_works([binary]):
            return True

    if system == "Windows":
        roots = (
            os.environ.get("ProgramW6432"),
            os.environ.get("ProgramFiles", r"C:\Program Files"),
            os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
            os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local")),
        )
        for root in roots:
            if not root:
                continue
            binary = Path(root) / "Mozilla" / "Firefox" / "firefox.exe"
            if binary.is_file() and command_works([str(binary)]):
                return True

        # Microsoft Store / MSIX Firefox keeps its profile under Packages.
        if windows_store_firefox_dir() is not None:
            return True
        return False

    for candidate in (
        "/usr/bin/firefox",
        "/usr/local/bin/firefox",
        "/usr/lib/firefox/firefox",
        "/opt/firefox/firefox",
        "/snap/bin/firefox",
        str(Path.home() / ".local" / "bin" / "firefox"),
    ):
        path = Path(candidate)
        if path.exists() and command_works([str(path)]):
            return True

    try:
        if shutil.which("flatpak") and command_works(
            ["flatpak", "run", "org.mozilla.firefox"]
        ):
            return True
        if shutil.which("snap") and command_works(["snap", "run", "firefox"]):
            return True
    except Exception:
        pass

    return False


def firefox_installed() -> bool:
    override = os.environ.get("FURR_FIREFOX_BIN")
    if override:
        return Path(override).is_file() and os.access(override, os.X_OK)

    # Under WSL an existing Windows Firefox profile means the browser is
    # already installed on the Windows side: no need for a Linux copy.
    windows_dir = wsl_windows_firefox_dir()
    if windows_dir is not None and (
        (windows_dir / "profiles.ini").is_file()
        or (windows_dir / "installs.ini").is_file()
    ):
        return True
    return firefox_ready()


def run_as_root(command: list[str]) -> None:
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        command = ["sudo"] + command
    subprocess.run(command, check=True)


def install_firefox_linux() -> None:
    def attempt(command: list[str], root: bool = False) -> bool:
        try:
            if root:
                run_as_root(command)
            else:
                subprocess.run(command, check=True)
        except Exception:
            pass
        return firefox_ready()

    # Prefer a real browser package over Ubuntu/Zorin's transitional apt
    # wrapper that only points to Snap. Snap needs systemd, absent in WSL.
    if not is_wsl() and shutil.which("snap") and attempt(
        ["snap", "install", "firefox"], True
    ):
        return
    if shutil.which("flatpak"):
        attempt(
            [
                "flatpak",
                "remote-add",
                "--if-not-exists",
                "flathub",
                "https://dl.flathub.org/repo/flathub.flatpakrepo",
            ]
        )
        if attempt(["flatpak", "install", "-y", "flathub", "org.mozilla.firefox"]):
            return

    managers = (
        ("apt-get", (["apt-get", "update"], ["apt-get", "install", "-y", "firefox"])),
        ("dnf", (["dnf", "install", "-y", "firefox"],)),
        ("yum", (["yum", "install", "-y", "firefox"],)),
        ("zypper", (["zypper", "--non-interactive", "install", "firefox"],)),
        ("pacman", (["pacman", "-S", "--noconfirm", "firefox"],)),
        ("apk", (["apk", "add", "firefox"],)),
        ("xbps-install", (["xbps-install", "-Sy", "firefox"],)),
    )
    # Try every available manager; a broken apt/dnf must not hide a working
    # alternative.
    for name, commands in managers:
        if not shutil.which(name):
            continue
        for command in commands:
            attempt(command, True)

    if firefox_ready():
        return

    print("Firefox package installed, but the browser is not usable yet. Trying Snap/Flatpak...")
    if not is_wsl():
        if not shutil.which("snap") and shutil.which("apt-get"):
            attempt(["apt-get", "install", "-y", "snapd"], True)
        if shutil.which("snap") and attempt(["snap", "install", "firefox"], True):
            return
    if shutil.which("flatpak"):
        attempt(
            [
                "flatpak",
                "remote-add",
                "--if-not-exists",
                "flathub",
                "https://dl.flathub.org/repo/flathub.flatpakrepo",
            ]
        )
        if attempt(["flatpak", "install", "-y", "flathub", "org.mozilla.firefox"]):
            return

    raise RuntimeError("Firefox package did not provide a usable browser")


def install_firefox_macos() -> None:
    # os=osx is Mozilla's universal DMG: valid on Intel and Apple Silicon.
    url = "https://download.mozilla.org/?product=firefox-latest-ssl&os=osx&lang=en-US"
    temp = Path(tempfile.mkdtemp(prefix="furros-firefox-"))
    dmg = temp / "firefox.dmg"
    mount = temp / "mount"
    mount.mkdir()
    app = Path("/Applications/Firefox.app")
    old_app = temp / "Firefox.app.old"
    attached = False
    print("Downloading Firefox for macOS...")

    def detach_and_clean() -> None:
        if attached:
            subprocess.run(
                ["hdiutil", "detach", str(mount), "-quiet"], check=False
            )
        shutil.rmtree(temp, ignore_errors=True)

    try:
        with urllib.request.urlopen(url, timeout=300) as response, dmg.open("wb") as out:
            shutil.copyfileobj(response, out)
        subprocess.run(
            ["hdiutil", "attach", str(dmg), "-mountpoint", str(mount), "-nobrowse", "-quiet"],
            check=True,
        )
        attached = True
        if not (mount / "Firefox.app").is_dir():
            raise RuntimeError("Firefox.app is missing from the downloaded DMG")

        # Move the old app aside instead of deleting it, so we can roll back
        # if the copy fails. It is discarded only after a successful install.
        if app.exists():
            if os.access("/Applications", os.W_OK):
                shutil.move(str(app), str(old_app))
            else:
                subprocess.run(["sudo", "mv", str(app), str(old_app)], check=True)

        try:
            if os.access("/Applications", os.W_OK):
                shutil.copytree(mount / "Firefox.app", app)
            else:
                raise PermissionError("/Applications is not writable")
        except PermissionError:
            subprocess.run(
                ["sudo", "cp", "-R", str(mount / "Firefox.app"), "/Applications/"],
                check=True,
            )

        if not (app / "Contents" / "MacOS" / "firefox").is_file():
            raise RuntimeError("Firefox was copied but the browser binary is missing")
    except Exception:
        if old_app.exists():
            try:
                if os.access("/Applications", os.W_OK):
                    if app.exists():
                        shutil.rmtree(app)
                    shutil.move(str(old_app), str(app))
                else:
                    subprocess.run(["sudo", "mv", str(old_app), str(app)], check=True)
            except Exception:
                pass
        detach_and_clean()
        raise
    detach_and_clean()


def firefox_windows_url() -> str:
    # PROCESSOR_ARCHITECTURE is X86 for 32-bit Windows, AMD64 or ARM64
    # otherwise. Mozilla provides os=win (32-bit) and os=win64 (64-bit,
    # emulated on ARM64); os=osx-arm64 does not exist.
    arch = os.environ.get("PROCESSOR_ARCHITECTURE", "").upper()
    os_name = "win" if arch == "X86" else "win64"
    return (
        "https://download.mozilla.org/?product=firefox-latest-ssl"
        f"&os={os_name}&lang=en-US"
    )


def install_firefox_windows() -> None:
    attempts: list[list[str]] = []
    if shutil.which("winget"):
        attempts.append(
            [
                "winget", "install", "--id", "Mozilla.Firefox", "-e",
                "--accept-source-agreements", "--accept-package-agreements", "--silent",
            ]
        )
    if shutil.which("choco"):
        attempts.append(["choco", "install", "firefox", "-y"])
    if shutil.which("scoop"):
        attempts.append(["scoop", "install", "firefox"])

    # Try every available manager: a broken winget must not block Chocolatey
    # or the direct download.
    for command in attempts:
        try:
            subprocess.run(command, check=True)
        except Exception:
            continue
        if firefox_installed():
            return

    temp_dir = Path(os.environ.get("TEMP", str(Path.home() / "AppData" / "Local" / "Temp")))
    installer = temp_dir / "FirefoxSetup.exe"
    print("Downloading Firefox for Windows...")
    with urllib.request.urlopen(firefox_windows_url(), timeout=300) as response, installer.open("wb") as out:
        shutil.copyfileobj(response, out)
    subprocess.run([str(installer), "/S"], check=True)


def ensure_firefox(skip: bool) -> None:
    if firefox_installed():
        return
    if skip:
        raise SystemExit(
            "Error: Firefox is not installed.\n"
            "Install it manually, or run the installer without --skip-firefox-install."
        )

    print("Firefox not found. Installing it automatically...")
    try:
        if platform.system() == "Windows":
            install_firefox_windows()
        elif platform.system() == "Darwin":
            install_firefox_macos()
        else:
            install_firefox_linux()
    except Exception as exc:
        raise SystemExit(
            f"Error: could not install Firefox automatically. {exc}\n"
            "Install Firefox manually, then run this installer again."
        )

    # The override is only for detecting a missing browser before installation.
    os.environ.pop("FURR_FIREFOX_BIN", None)

    if not firefox_installed():
        raise SystemExit(
            "Error: Firefox was installed but could not be detected.\n"
            "Start Firefox once, then run this installer again."
        )
    print("Firefox installed successfully.")


def create_firefox_profile() -> None:
    # Never create a second profile: Firefox may already use one in another
    # standard location (for example ~/.config/mozilla/firefox on Linux).
    for candidate in candidate_ini_files():
        try:
            if "[Profile" in candidate.read_text(encoding="utf-8", errors="ignore"):
                return
        except OSError:
            pass

    system = platform.system()
    installs_ini: Path | None = None
    if system == "Windows":
        # A Store/MSIX Firefox uses a virtualised APPDATA under Packages.
        store_dir = windows_store_firefox_dir()
        appdata = os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming"))
        firefox_dir = store_dir or (Path(appdata) / "Mozilla" / "Firefox")
        base = firefox_dir / "Profiles"
        ini = firefox_dir / "profiles.ini"
        installs_ini = firefox_dir / "installs.ini"
        relative = "Profiles/{profile_dir}"
    elif system == "Darwin":
        firefox_dir = Path.home() / "Library" / "Application Support" / "Firefox"
        base = firefox_dir / "Profiles"
        ini = firefox_dir / "profiles.ini"
        installs_ini = firefox_dir / "installs.ini"
        # Paths are relative to the folder containing profiles.ini.
        relative = "Profiles/{profile_dir}"
    elif shutil.which("flatpak") and command_works(
        ["flatpak", "run", "org.mozilla.firefox"]
    ):
        base = Path.home() / ".var" / "app" / "org.mozilla.firefox" / ".mozilla" / "firefox"
        ini = base / "profiles.ini"
        relative = "{profile_dir}"
    elif shutil.which("snap") and command_works(["snap", "run", "firefox"]):
        base = Path.home() / "snap" / "firefox" / "common" / ".mozilla" / "firefox"
        ini = base / "profiles.ini"
        relative = "{profile_dir}"
    else:
        config_home = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
        base = Path(config_home) / "mozilla" / "firefox"
        ini = base / "profiles.ini"
        relative = "{profile_dir}"

    base.mkdir(parents=True, exist_ok=True)
    profile_id = secrets.token_hex(4)
    profile_dir = f"{profile_id}.default-release"
    (base / profile_dir).mkdir(parents=True, exist_ok=True)
    default_path = relative.format(profile_dir=profile_dir)
    ini.write_text(
        "\n".join(
            (
                "[General]",
                "StartWithLastProfile=1",
                "Version=2",
                "",
                f"[Install{profile_id}]",
                f"Default={default_path}",
                "Locked=1",
                "",
                "[Profile0]",
                "Name=default-release",
                "IsRelative=1",
                f"Path={default_path}",
                "Default=1",
                "",
            )
        ),
        encoding="utf-8",
    )
    if installs_ini is not None:
        installs_ini.write_text(
            "\n".join(
                (
                    f"[Install{profile_id}]",
                    f"Default={default_path}",
                    "Locked=1",
                    "",
                )
            ),
            encoding="utf-8",
        )
    print(f"Created Firefox profile: {base / profile_dir}")


def candidate_ini_files() -> list[Path]:
    home = Path.home()
    raw: list[Path] = []

    if platform.system() == "Windows":
        # Firefox keeps profiles.ini and installs.ini in %APPDATA%\Mozilla\Firefox,
        # one level above the Profiles folder. installs.ini is what Firefox 62+
        # uses to remember the default profile.
        for variable in ("APPDATA", "LOCALAPPDATA"):
            value = os.environ.get(variable)
            if not value:
                continue
            firefox_dir = Path(value) / "Mozilla" / "Firefox"
            # Firefox never reads profiles.ini from inside Profiles/. Old
            # FurrOS installers wrote one there; it must be ignored.
            raw += [firefox_dir / "profiles.ini", firefox_dir / "installs.ini"]

        local = os.environ.get("LOCALAPPDATA")
        if local:
            packages = Path(local) / "Packages"
            if packages.is_dir():
                for app in packages.glob("Mozilla.Firefox*"):
                    for relative in (
                        "LocalCache/Roaming/Mozilla/Firefox",
                        "LocalCache/Local/Mozilla/Firefox",
                        "LocalState/Mozilla/Firefox",
                    ):
                        store_dir = app / relative
                        raw += [store_dir / "profiles.ini", store_dir / "installs.ini"]

        raw += [
            home / "Mozilla" / "Firefox" / "profiles.ini",
            home / "Mozilla" / "Firefox" / "installs.ini",
        ]
    elif platform.system() == "Darwin":
        # On macOS profiles.ini and installs.ini live one level above
        # the Profiles folder, exactly like %APPDATA%\Mozilla\Firefox
        # on Windows. Both are needed to find the real default profile.
        firefox_dir = home / "Library" / "Application Support" / "Firefox"
        raw += [firefox_dir / "profiles.ini", firefox_dir / "installs.ini"]
    else:
        config_home = os.environ.get("XDG_CONFIG_HOME") or str(home / ".config")
        for base in (
            home / ".mozilla" / "firefox",
            Path(config_home) / "mozilla" / "firefox",
            home / ".config" / "mozilla" / "firefox",
            home / "snap" / "firefox" / "common" / ".mozilla" / "firefox",
            home / ".var" / "app" / "org.mozilla.firefox" / ".mozilla" / "firefox",
        ):
            raw += [base / "profiles.ini", base / "installs.ini"]

    # Under WSL, Firefox may be the Windows one. Read its ini files through
    # Windows interop; Linux candidates are listed first and win ties.
    windows_dir = wsl_windows_firefox_dir()
    if windows_dir is not None:
        raw += [windows_dir / "profiles.ini", windows_dir / "installs.ini"]

    seen: set[Path] = set()
    result: list[Path] = []
    for candidate in raw:
        candidate = candidate.expanduser()
        if candidate.is_file() and candidate not in seen:
            seen.add(candidate)
            result.append(candidate)
    return result


def active_profile() -> Path | None:
    """Find the profile a running Firefox instance is using (Linux only)."""
    proc = Path("/proc")
    if not proc.exists():
        return None

    try:
        fds = list(proc.glob("[0-9]*/fd/*"))
    except OSError:
        return None

    for fd in fds:
        try:
            target = Path(os.readlink(fd))
        except OSError:
            continue
        text = str(target)
        for marker in ("/mozilla/firefox/", "/Mozilla/Firefox/Profiles/"):
            if marker not in text:
                continue
            prefix, _, rest = text.partition(marker)
            profile_name = rest.split("/", 1)[0]
            if not (profile_name.endswith(".default") or ".default-" in profile_name or profile_name.startswith("Profile")):
                continue
            candidate = Path(prefix) / marker.strip("/") / profile_name
            if "/.cache/" in str(candidate):
                continue
            if candidate.is_dir() and (candidate / "prefs.js").is_file():
                return candidate
    return None


def read_install_defaults(ini: Path) -> set[Path]:
    """Read [Install...] Default entries from profiles.ini or installs.ini."""
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.read(ini)
    base = ini.parent

    found: set[Path] = set()
    for section in parser.sections():
        if not section.lower().startswith("install"):
            continue
        raw = parser.get(section, "Default", fallback="").strip()
        if not raw:
            continue
        path = Path(os.path.expandvars(raw)).expanduser()
        if not path.is_absolute():
            path = base / path
        try:
            found.add(path.resolve())
        except OSError:
            found.add(path)
    return found


def read_profiles(ini: Path) -> list[dict[str, object]]:
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.read(ini)
    base = ini.parent

    found: list[dict[str, object]] = []
    for section in parser.sections():
        if not section.lower().startswith("profile"):
            continue
        raw = parser.get(section, "Path", fallback="").strip()
        if not raw:
            continue

        path = Path(os.path.expandvars(raw)).expanduser()
        if not path.is_absolute():
            path = base / path
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        name = parser.get(section, "Name", fallback=path.name)
        legacy_default = parser.get(section, "Default", fallback="0") == "1"
        if path.is_dir():
            found.append(
                {
                    "name": name,
                    "path": path,
                    "resolved": resolved,
                    "legacy_default": legacy_default,
                    "install_default": False,
                }
            )

    return found


def choose_profile(specified: str | None, running: Path | None = None) -> Path:
    if specified:
        path = Path(os.path.expandvars(specified)).expanduser()
        if not path.is_dir():
            raise SystemExit(f"Error: profile directory does not exist: {path}")
        return path

    inis = candidate_ini_files()
    for ini in inis:
        print(f"Found profile list: {ini}")

    install_defaults: set[Path] = set()
    for ini in inis:
        install_defaults |= read_install_defaults(ini)
    for default in install_defaults:
        print(f"Default profile: {default}")

    profiles: list[dict[str, object]] = []
    seen: set[Path] = set()
    for ini in inis:
        for item in read_profiles(ini):
            resolved = Path(item["resolved"])
            if resolved in seen:
                continue
            seen.add(resolved)
            item["install_default"] = resolved in install_defaults
            profiles.append(item)

    if not profiles:
        raise SystemExit(
            "Error: Firefox profile not found.\n"
            "Specify it with: python3 install.py --profile /full/path/to/profile"
        )

    running_resolved = None
    if running:
        try:
            running_resolved = running.resolve()
        except OSError:
            running_resolved = running
        if all(Path(item["resolved"]) != running_resolved for item in profiles):
            profiles.append(
                {
                    "name": running.name,
                    "path": running,
                    "resolved": running_resolved,
                    "legacy_default": False,
                    "install_default": False,
                }
            )

    def score(item: dict[str, object]) -> int:
        if running_resolved is not None and Path(item["resolved"]) == running_resolved:
            return 4
        if item["install_default"]:
            return 3
        if item["legacy_default"]:
            return 2
        return 1

    # Automatic selection only. Score first, then an initialized profile,
    # then default-release, then the lexicographically first path.
    # Never ask the user to choose a profile.
    def tie_key(item: dict[str, object]) -> tuple[int, int, int, str]:
        resolved = Path(item["resolved"])
        established = (resolved / "prefs.js").is_file() or (resolved / "user.js").is_file()
        preferred = resolved.name.endswith(".default-release")
        return (-score(item), -int(established), -int(preferred), str(resolved))

    selected = Path(sorted(profiles, key=tie_key)[0]["path"])
    print(f"Selected profile: {selected}")
    return selected


def destinations(profile: Path) -> dict[str, Path]:
    chrome = profile / "chrome"
    chrome.mkdir(parents=True, exist_ok=True)
    return {
        "userChrome.css": chrome / "userChrome.css",
        "userContent.css": chrome / "userContent.css",
        "user.js": profile / "user.js",
    }


def verify_required_pref(user_js: Path) -> None:
    with user_js.open("r", encoding="utf-8", errors="ignore") as handle:
        content = handle.read()
    if REQUIRED_PREF not in content:
        raise SystemExit(
            "Error: user.js is missing the required stylesheet preference."
        )


def get_firefox_version() -> str:
    commands = [
        ["firefox", "--version"],
        ["firefox.exe", "--version"],
    ]
    if platform.system() == "Windows":
        commands = [["firefox.exe", "--version"], ["firefox", "--version"]]
    elif platform.system() == "Darwin":
        commands.insert(
            0,
            [
                "/Applications/Firefox.app/Contents/MacOS/firefox",
                "--version",
            ],
        )

    for command in commands:
        try:
            output = subprocess.check_output(
                command, text=True, errors="ignore", timeout=10
            )
            return output.strip().splitlines()[0]
        except Exception:
            continue
    return "version unavailable"


def write_report(
    profile: Path, stamp: str | None, targets: dict[str, Path], removed: bool
) -> Path:
    report = Path.home() / "FurrOS-install-report.txt"
    lines = [
        "FurrOS Firefox theme installation report",
        f"Date:     {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"System:   {platform.system()} {platform.release()}",
        f"User:     {os.environ.get('USER') or os.environ.get('USERNAME', 'unknown')}",
        f"Home:     {Path.home()}",
        f"Source:   {SOURCE}",
        f"Profile:  {profile}",
        f"Firefox:  {get_firefox_version()}",
    ]

    if removed:
        lines.append("Action:   Uninstall")
        for target in targets.values():
            lines.append(f"Removed:  {target}")
    else:
        lines += [
            f"Backup:   .bak-{stamp}" if stamp else "Backup:   none (no previous files)",
            "Action:   Install",
        ]
        for name, target in targets.items():
            lines.append(f"Verified: {name} -> {target}")
        lines.append("Verified: stylesheet preference enabled")

    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Install the FurrOS Firefox theme on Linux, Windows or macOS."
    )
    parser.add_argument("--profile", help="Use this Firefox profile instead of detecting it")
    parser.add_argument(
        "--force", action="store_true", help="Install even if Firefox is running"
    )
    parser.add_argument("--uninstall", action="store_true", help="Remove the theme files")
    parser.add_argument(
        "--skip-firefox-install",
        action="store_true",
        help="Do not install Firefox automatically if missing",
    )
    args = parser.parse_args()

    print("FurrOS Firefox theme installer — starting...")

    # sudo/root changes HOME; without this warning the profile would be the
    # root user's, not the desktop user's.
    home = str(Path.home())
    if hasattr(os, "geteuid") and os.geteuid() == 0 and home in ("/root", "/var/root"):
        print(
            f"Warning: running as root targets {home}. Run as the desktop user instead\n"
            "unless you intentionally want to change root's Firefox profile.",
            file=sys.stderr,
        )

    if not args.uninstall:
        ensure_firefox(args.skip_firefox_install)
        create_firefox_profile()

    if not args.force and firefox_running():
        raise SystemExit(
            "Error: Firefox is still running.\n"
            "Close every Firefox window completely, then run the installer again.\n"
            "The theme files are loaded only at startup.\n"
            "Use --force only if you know what you are doing."
        )

    running = active_profile() if args.force else None
    profile = choose_profile(args.profile, running)
    targets = destinations(profile)
    stamp = time.strftime("%Y%m%d-%H%M%S")

    if args.uninstall:
        for target in targets.values():
            try:
                target.unlink()
            except FileNotFoundError:
                pass
        report = write_report(profile, None, targets, removed=True)
        print(f"\nFurrOS theme removed from: {profile}")
        print(f"Report saved: {report}")
        print("Start Firefox again to apply the change.")
        return

    for target in targets.values():
        if target.exists():
            shutil.copy2(target, target.with_name(f"{target.name}.bak-{stamp}"))

    for name in THEME_FILES:
        source = SOURCE / name
        if not source.is_file():
            raise SystemExit(f"Error: missing source file: {source}")
        target = targets[name]
        shutil.copy2(source, target)
        if sha256(source) != sha256(target):
            raise SystemExit(f"Error: verification failed for {name}")

    verify_required_pref(targets["user.js"])

    report = write_report(profile, stamp, targets, removed=False)
    print(f"\nFurrOS theme installed in: {profile}")
    print(f"Previous files backed up with suffix .bak-{stamp}")
    print("Verified: all three theme files match the repository.")
    print("Verified: stylesheet preference enabled.")
    print(f"Report saved: {report}")
    print("\nNow start Firefox. If it was open, close it completely first.")


if __name__ == "__main__":
    # SystemExit messages are printed once by the interpreter itself.
    main()
