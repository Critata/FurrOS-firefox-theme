# FurrOS Firefox Theme

A Firefox theme inspired by [FurrOS](https://furros.xyz/): dark chrome, chips with ink borders, sticker shadows, and a paw + FurrOS wordmark on the new tab page.

![FurrOS Firefox theme](screenshot.png)

## Contents

- `userChrome.css` — Firefox UI: oval address bar, attached dropdown, menus and panels.
- `userContent.css` — internal pages: wordmark, embedded FurrOS wallpapers, AI chatbot styles.
- `user.js` — required preferences (`toolkit.legacyUserProfileCustomizations.stylesheets`, dark theme, wallpapers, disabled shortcuts/stories/widgets).
- `install.sh` — Linux/macOS installer. No Python required.
- `install.command` — macOS double-click launcher.
- `install.desktop` — Linux desktop launcher.
- `install.bat` + `install.ps1` — Windows launchers. PowerShell is built into Windows, so no Python required.
- `install.py` — optional cross-platform alternative, only if you already have Python 3.
- `diagnose.sh` — prints system/profile information if the install fails.
- `tests/run-tests.sh` — regression tests for profile detection and file installation.

## Installation

Extract the archive first, then use the launcher for your system:

| System | What to do |
| --- | --- |
| **Linux** | Open a terminal in the extracted folder and run `./install.sh`. You can also double-click `install.desktop`. |
| **macOS** | Double-click `install.command` (or run `./install.command` in a terminal). If macOS blocks it, right-click it and choose **Open**, or run `chmod +x install.command` first. |
| **Windows** | Double-click `install.bat`. It uses the built-in PowerShell. |

Optional alternative, if Python 3 is available:

```bash
python3 install.py
```

**If Firefox is not installed, the installer installs it automatically.** On Linux it prefers Snap or Flatpak when available, then falls back to APT, DNF, Pacman, Zypper, APK or XBPS; on macOS it downloads the official Firefox DMG; on Windows it uses Winget, Chocolatey, Scoop or the official Mozilla installer. On Ubuntu/Zorin, where the APT package can be a small transitional package that only points to Snap, the installer detects that Firefox is not usable and installs the real browser from Snap/Flatpak automatically. This may ask for your administrator password. To disable this behaviour, pass `--skip-firefox-install` (or `-SkipFirefoxInstall` in PowerShell).

**Close Firefox completely before running the installer.** The theme files are read only when Firefox starts. If Firefox is still running, the installer stops with an error. It writes a detailed report to `FurrOS-install-report.txt` in your home folder.

Profile selection is automatic: the installer uses the profile Firefox actually starts with and never asks you to choose. Use `--profile` only as a manual override for an unusual layout:

```bash
./install.sh --profile /full/path/to/profile
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Profile "C:\Users\Name\AppData\Roaming\Mozilla\Firefox\Profiles\xxxx.default-release"
```

Use `--force` (or `-Force` in PowerShell) only if you know what you are doing and want to install while Firefox is running.

The installer:

1. installs Firefox if it is missing;
2. creates an initial Firefox profile if Firefox has never been started;
3. detects the real default profile from the `[Install]` section of `profiles.ini`/`installs.ini` (not only the legacy `Default=1` flag), including Linux, macOS, Windows, Snap and Flatpak, and never creates a duplicate profile; ties are resolved automatically without any prompt;
4. creates the `chrome` folder if needed;
5. backs up the existing `userChrome.css`, `userContent.css` and `user.js` with a `.bak-DATE-TIME` suffix;
6. copies the theme files and verifies them byte-for-byte;
7. verifies that `user.js` enables custom stylesheets;
8. asks you to start Firefox again.

## Uninstall

```bash
./install.sh --uninstall
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

Close Firefox first. This removes the three theme files. Your backups are kept in the profile.

## Important notes

- `user.js` is read on every startup and **overwrites** the preferences it contains. If you change one of those preferences in `about:config`, Firefox will restore it on the next launch.
- The new tab page uses `#150B11` as its background. Wallpaper tiles from the customize pencil are translated into three embedded FurrOS images behind the wordmark.
- Uploading your own image does not apply a background: the wordmark stays without any extra background image.
- On Windows, Firefox keeps `profiles.ini` and `installs.ini` in `%APPDATA%\Mozilla\Firefox\`, one level above the `Profiles` folder. The installer reads both files (also for Microsoft Store installs) so the theme goes into the profile Firefox actually uses.
- On macOS, Firefox keeps `profiles.ini` and `installs.ini` in `~/Library/Application Support/Firefox/`, one level above the `Profiles` folder. The installer reads both files, so the first run writes into the same profile Firefox uses and no second run is needed.
- Tested on Firefox 161, Linux/Wayland. Other versions may need small adjustments.

## Troubleshooting

If nothing changes after the install:

1. Confirm Firefox was fully closed before running the installer.
2. Run `./diagnose.sh` and check the profile list and the profile used by a running Firefox.
3. Open `FurrOS-install-report.txt` in your home folder: it shows the exact profile and files installed.
4. Start Firefox again; the theme is applied only at startup.
5. If the profile is unusual, run: `./install.sh --profile /full/path/to/profile`.

## Tests

Run `./tests/run-tests.sh` from a checkout. It verifies that the installer selects the real `[Install]` default profile on Linux, Windows and macOS (including first-run profile creation), leaves the legacy `Default=1` profile untouched, never prompts for a profile, creates no duplicate profile and copies all three theme files byte-for-byte.

## Release

Release `v1.0.0` contains the theme source, ready to download and install.
