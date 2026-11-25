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


def firefox_running() -> bool:
    system = platform.system()
    try:
        if system == "Windows":
            output = subprocess.check_output(
                ["tasklist"], text=True, errors="ignore", timeout=10
            )
            return "firefox.exe" in output.lower()

        # Match process names only. Matching full command lines would also
        # match this installer when its path contains "firefox".
        for name in ("firefox", "firefox-bin", "org.mozilla.firefox"):
            try:
                output = subprocess.check_output(
                    ["pgrep", "-x", name], text=True, errors="ignore", timeout=10
                )
            except subprocess.CalledProcessError:
                continue
            if output.strip():
                return True
        return False
    except Exception:
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
            os.environ.get("ProgramFiles", r"C:\Program Files"),
            os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
            os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local")),
        )
        for root in roots:
            binary = Path(root) / "Mozilla" / "Firefox" / "firefox.exe"
            if binary.is_file() and command_works([str(binary)]):
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
    # wrapper that only points to Snap.
    if shutil.which("snap") and attempt(["snap", "install", "firefox"], True):
        return
    if shutil.which("flatpak") and attempt(
        ["flatpak", "install", "-y", "flathub", "org.mozilla.firefox"]
    ):
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
    for name, commands in managers:
        if shutil.which(name):
            for command in commands:
                attempt(command, True)
            break

    if firefox_ready():
        return

    print("Firefox package installed, but the browser is not usable yet. Trying Snap/Flatpak...")
    if not shutil.which("snap") and shutil.which("apt-get"):
        attempt(["apt-get", "install", "-y", "snapd"], True)
    if shutil.which("snap") and attempt(["snap", "install", "firefox"], True):
        return
    if shutil.which("flatpak") and attempt(
        ["flatpak", "install", "-y", "flathub", "org.mozilla.firefox"]
    ):
        return

    raise RuntimeError("Firefox package did not provide a usable browser")


def install_firefox_macos() -> None:
    url = "https://download.mozilla.org/?product=firefox-latest-ssl&os=osx&lang=en-US"
    temp = Path(tempfile.mkdtemp(prefix="furros-firefox-"))
    dmg = temp / "firefox.dmg"
    mount = temp / "mount"
    mount.mkdir()
    print("Downloading Firefox for macOS...")

    urllib.request.urlretrieve(url, dmg)
    subprocess.run(
        ["hdiutil", "attach", str(dmg), "-mountpoint", str(mount), "-nobrowse", "-quiet"],
        check=True,
    )
    try:
        app = Path("/Applications/Firefox.app")
        if app.exists():
            shutil.rmtree(app)
        try:
            shutil.copytree(mount / "Firefox.app", app)
        except PermissionError:
            subprocess.run(
                ["sudo", "cp", "-R", str(mount / "Firefox.app"), "/Applications/"],
                check=True,
            )
    finally:
        subprocess.run(["hdiutil", "detach", str(mount), "-quiet"], check=False)
        shutil.rmtree(temp, ignore_errors=True)


def install_firefox_windows() -> None:
    if shutil.which("winget"):
        subprocess.run(
            [
                "winget",
                "install",
                "--id",
                "Mozilla.Firefox",
                "-e",
                "--accept-source-agreements",
                "--accept-package-agreements",
                "--silent",
            ],
            check=True,
        )
        return
    if shutil.which("choco"):
        subprocess.run(["choco", "install", "firefox", "-y"], check=True)
        return
    if shutil.which("scoop"):
        subprocess.run(["scoop", "install", "firefox"], check=True)
        return

    url = "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US"
    temp_dir = Path(os.environ.get("TEMP", str(Path.home() / "AppData" / "Local" / "Temp")))
    installer = temp_dir / "FirefoxSetup.exe"
    print("Downloading Firefox for Windows...")
    urllib.request.urlretrieve(url, installer)
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
        appdata = os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming"))
        firefox_dir = Path(appdata) / "Mozilla" / "Firefox"
        base = firefox_dir / "Profiles"
        ini = firefox_dir / "profiles.ini"
        installs_ini = firefox_dir / "installs.ini"
        relative = "Profiles/{profile_dir}"
    elif system == "Darwin":
        base = Path.home() / "Library" / "Application Support" / "Firefox" / "Profiles"
        ini = base / "profiles.ini"
        relative = "{profile_dir}"
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
            raw += [
                firefox_dir / "profiles.ini",
                firefox_dir / "installs.ini",
                firefox_dir / "Profiles" / "profiles.ini",
            ]

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
        raw.append(
            home / "Library" / "Application Support" / "Firefox" / "Profiles" / "profiles.ini"
        )
    else:
        config_home = os.environ.get("XDG_CONFIG_HOME") or str(home / ".config")
        raw += [
            home / ".mozilla" / "firefox" / "profiles.ini",
            Path(config_home) / "mozilla" / "firefox" / "profiles.ini",
            home / ".config" / "mozilla" / "firefox" / "profiles.ini",
            home / "snap" / "firefox" / "common" / ".mozilla" / "firefox" / "profiles.ini",
            home / ".var" / "app" / "org.mozilla.firefox" / ".mozilla" / "firefox" / "profiles.ini",
        ]

    # Unusual installs may still use the generic Linux/macOS locations.
    # Do not add these on Windows: they would mix Linux profiles into the
    # Windows profile list and could make the installer choose the wrong one.
    if platform.system() != "Windows":
        raw += [
            home / ".mozilla" / "firefox" / "profiles.ini",
            home / ".config" / "mozilla" / "firefox" / "profiles.ini",
        ]

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
    parser = configparser.ConfigParser(strict=False)
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
    parser = configparser.ConfigParser(strict=False)
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

    def score(item: dict[str, object]) -> int:
        if running_resolved is not None and Path(item["resolved"]) == running_resolved:
            return 4
        if item["install_default"]:
            return 3
        if item["legacy_default"]:
            return 2
        return 1

    ranked = sorted(profiles, key=score, reverse=True)

    if running_resolved is not None and all(
        Path(item["resolved"]) != running_resolved for item in ranked
    ):
        ranked.insert(
            0,
            {
                "name": running.name,
                "path": running,
                "resolved": running_resolved,
                "legacy_default": False,
                "install_default": False,
                "_score": 4,
            },
        )

    def rank(item: dict[str, object]) -> int:
        return int(item.get("_score", score(item)))

    ranked.sort(key=rank, reverse=True)
    top_score = rank(ranked[0])
    top = [item for item in ranked if rank(item) == top_score]
    rest = [item for item in ranked if rank(item) != top_score]

    if len(top) == 1:
        selected = Path(top[0]["path"])
        print(f"Selected profile: {selected}")
        return selected

    choices = top + rest
    print("\nMultiple Firefox profiles found:")
    for index, item in enumerate(choices, 1):
        value = rank(item)
        marker = {4: " (running)", 3: " (default)", 2: " (legacy default)"}.get(value, "")
        print(f"  {index}. {item['name']}{marker} — {item['path']}")

    while True:
        answer = input("Choose the profile number: ").strip()
        if answer.isdigit() and 1 <= int(answer) <= len(choices):
            return Path(choices[int(answer) - 1]["path"])
        print("Invalid choice.")


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
    try:
        main()
    except SystemExit as exc:
        if str(exc):
            print(str(exc), file=sys.stderr)
        raise
