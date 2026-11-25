#!/usr/bin/env python3
"""Cross-platform installer for the FurrOS Firefox theme.

Works on Linux, Windows and macOS. Firefox must be closed because
user.js and the chrome CSS files are read only at startup.
"""

import argparse
import configparser
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
THEME_FILES = ("userChrome.css", "userContent.css", "user.js")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def firefox_running() -> bool:
    system = platform.system()
    try:
        if system == "Windows":
            out = subprocess.check_output(
                ["tasklist"], text=True, errors="ignore", timeout=10
            )
            return "firefox.exe" in out.lower()
        out = subprocess.check_output(
            ["pgrep", "-af", "firefox"], text=True, errors="ignore", timeout=10
        )
        for line in out.splitlines():
            low = line.lower()
            if "install.py" in low or "pgrep" in low:
                continue
            if "firefox" in low:
                return True
        return False
    except Exception:
        return False


def candidate_ini_files() -> list[Path]:
    home = Path.home()
    candidates: list[Path] = []

    if platform.system() == "Windows":
        appdata = os.environ.get("APPDATA")
        if appdata:
            candidates.append(Path(appdata) / "Mozilla" / "Firefox" / "Profiles" / "profiles.ini")
    elif platform.system() == "Darwin":
        candidates.append(home / "Library" / "Application Support" / "Firefox" / "Profiles" / "profiles.ini")
    else:
        candidates += [
            home / ".mozilla" / "firefox" / "profiles.ini",
            home / ".config" / "mozilla" / "firefox" / "profiles.ini",
            home / "snap" / "firefox" / "common" / ".mozilla" / "firefox" / "profiles.ini",
            home / ".var" / "app" / "org.mozilla.firefox" / ".mozilla" / "firefox" / "profiles.ini",
        ]

    # Also try these everywhere, in case of unusual installs.
    candidates += [
        home / ".mozilla" / "firefox" / "profiles.ini",
        home / ".config" / "mozilla" / "firefox" / "profiles.ini",
    ]

    seen: set[Path] = set()
    result: list[Path] = []
    for p in candidates:
        p = p.expanduser()
        if p.is_file() and p not in seen:
            seen.add(p)
            result.append(p)
    return result


def read_profiles(ini: Path) -> list[tuple[str, Path, bool]]:
    parser = configparser.ConfigParser()
    parser.read(ini)
    base = ini.parent
    found: list[tuple[str, Path, bool]] = []
    for section in parser.sections():
        if not section.lower().startswith("profile"):
            continue
        raw = parser.get(section, "Path", fallback="").strip()
        if not raw:
            continue
        path = Path(os.path.expandvars(raw)).expanduser()
        if not path.is_absolute():
            path = base / path
        name = parser.get(section, "Name", fallback=path.name)
        default = parser.get(section, "Default", fallback="0") == "1"
        if path.is_dir():
            found.append((name, path, default))
    found.sort(key=lambda item: not item[2])
    return found


def choose_profile(specified: str | None) -> Path:
    if specified:
        p = Path(os.path.expandvars(specified)).expanduser()
        if not p.is_dir():
            raise SystemExit(f"Error: profile directory does not exist: {p}")
        return p

    profiles: list[tuple[str, Path, bool]] = []
    seen: set[Path] = set()
    for ini in candidate_ini_files():
        print(f"Found profile list: {ini}")
        for name, path, default in read_profiles(ini):
            if path in seen:
                continue
            seen.add(path)
            profiles.append((name, path, default))

    if not profiles:
        raise SystemExit(
            "Error: Firefox profile not found.\n"
            "Specify it with: python3 install.py --profile /full/path/to/profile"
        )

    if len(profiles) == 1:
        return profiles[0][1]

    print("\nMultiple Firefox profiles found:")
    for index, (name, path, default) in enumerate(profiles, 1):
        marker = " (default)" if default else ""
        print(f"  {index}. {name}{marker} — {path}")
    while True:
        answer = input("Choose the profile number: ").strip()
        if answer.isdigit() and 1 <= int(answer) <= len(profiles):
            return profiles[int(answer) - 1][1]
        print("Invalid choice.")


def destinations(profile: Path) -> dict[str, Path]:
    chrome = profile / "chrome"
    chrome.mkdir(parents=True, exist_ok=True)
    return {
        "userChrome.css": chrome / "userChrome.css",
        "userContent.css": chrome / "userContent.css",
        "user.js": profile / "user.js",
    }


def write_report(profile: Path, stamp: str | None, targets: dict[str, Path], removed: bool) -> Path:
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
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report


def get_firefox_version() -> str:
    commands = [
        ["firefox", "--version"],
        ["firefox.exe", "--version"],
    ]
    if platform.system() == "Windows":
        commands = [["firefox.exe", "--version"], ["firefox", "--version"]]
    for cmd in commands:
        try:
            return subprocess.check_output(
                cmd, text=True, errors="ignore", timeout=10
            ).strip().splitlines()[0]
        except Exception:
            continue
    return "version unavailable"


def main() -> None:
    parser = argparse.ArgumentParser(description="Install the FurrOS Firefox theme on Linux, Windows or macOS.")
    parser.add_argument("--profile", help="Use this Firefox profile instead of detecting it")
    parser.add_argument("--force", action="store_true", help="Install even if Firefox is running")
    parser.add_argument("--uninstall", action="store_true", help="Remove the theme files")
    args = parser.parse_args()

    print("FurrOS Firefox theme installer — starting...")

    if not args.force and firefox_running():
        raise SystemExit(
            "Error: Firefox is still running.\n"
            "Close every Firefox window completely, then run the installer again.\n"
            "The theme files are loaded only at startup.\n"
            "Use --force only if you know what you are doing."
        )

    profile = choose_profile(args.profile)
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

    for name, target in targets.items():
        if target.exists():
            shutil.copy2(target, target.with_name(f"{target.name}.bak-{stamp}"))

    for name, target in targets.items():
        source = SOURCE / name
        if not source.is_file():
            raise SystemExit(f"Error: missing source file: {source}")
        shutil.copy2(source, target)
        if sha256(source) != sha256(target):
            raise SystemExit(f"Error: verification failed for {name}")

    report = write_report(profile, stamp, targets, removed=False)
    print(f"\nFurrOS theme installed in: {profile}")
    print(f"Previous files backed up with suffix .bak-{stamp}")
    print("Verified: all three theme files match the repository.")
    print(f"Report saved: {report}")
    print("\nNow start Firefox. If it was open, close it completely first.")


if __name__ == "__main__":
    try:
        main()
    except SystemExit as exc:
        if str(exc):
            print(str(exc), file=sys.stderr)
        raise
