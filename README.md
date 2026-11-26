# FurrOS Firefox Theme

A Firefox theme inspired by [FurrOS](https://furros.xyz/): dark chrome, chips with ink borders, sticker shadows, and a paw + FurrOS wordmark on the new tab page.

![FurrOS Firefox theme](screenshot.png)

## Contents

- `userChrome.css` — Firefox UI: oval address bar, attached dropdown, menus and panels.
- `userContent.css` — internal pages: wordmark, embedded FurrOS wallpapers, AI chatbot styles.
- `user.js` — required preferences (`toolkit.legacyUserProfileCustomizations.stylesheets`, dark theme, wallpapers, disabled shortcuts/stories/widgets).
- `install.sh` — Bash installer for Linux, macOS and WSL. No Python required.
- `install.command` — macOS double-click launcher.
- `install.desktop` — Linux desktop launcher.
- `install.bat` + `install.ps1` — Windows launchers. PowerShell is built into Windows, so no Python required.
- `install.py` — optional cross-platform alternative, only if you already have Python 3.7 or newer.
- `diagnose.sh` — non-interactive diagnostic for Linux, macOS and WSL.
- `tests/run-tests.sh` — regression tests for profile detection and file installation.

## Requirements

| Platform | Required | Optional / notes |
| --- | --- | --- |
| Linux | Bash, standard shell tools | Administrator rights (`sudo`) only if Firefox must be installed. Snap and Flatpak are used when available; Snap is skipped under WSL. |
| macOS | Bash (included) | Intel and Apple Silicon are both supported: Mozilla's `os=osx` DMG is universal. If Firefox is missing, `curl` and `hdiutil` (both included with macOS) plus administrator rights are used. |
| Windows | Windows PowerShell 4.0 or newer (`Get-FileHash`) | `install.bat` works in CMD and Explorer. Winget, Chocolatey or Scoop are used when available; otherwise the official Mozilla installer is downloaded. |
| Windows Store / MSIX | Same as Windows | The profile under `%LOCALAPPDATA%\Packages\Mozilla.Firefox*\LocalCache\Roaming` is detected and used. |
| WSL | Linux requirements | Windows interop (`cmd.exe` and `wslpath`, enabled by default) lets `install.sh` find the Windows Firefox profile. |
| Python alternative | Python 3.7 or newer | Not needed by `install.sh`, `install.command`, `install.bat` or `install.ps1`. |

**On Linux/macOS, `install.sh` and `install.py` close Firefox before writing any profile file.** In an interactive terminal they ask for confirmation; in a non-interactive shell they stop with a clear error unless you pass `--force`. They send `SIGTERM` first and use `SIGKILL` only as a fallback after a timeout, then wait for `parent.lock`, `.parentlock` and `lock` to disappear. Theme files are read only at startup, so Firefox must be restarted afterwards. `install.ps1` still requires Firefox to be closed manually, or `-Force` to override the check.

## Installation

Extract the archive first. Do not run the installer from inside the downloaded `.tar.gz`.

### Linux

```bash
cd /path/to/FurrOS-firefox-theme
./install.sh
```

If the archive was extracted without the executable bit:

```bash
cd /path/to/FurrOS-firefox-theme
bash ./install.sh
```

You can also double-click `install.desktop`. If your desktop environment does not pass the launcher location (`%k`), set `FURR_INSTALL_DIR` in the environment before starting it:

```bash
export FURR_INSTALL_DIR=/path/to/FurrOS-firefox-theme
```

### macOS (Intel and Apple Silicon)

Double-click `install.command`, or run:

```bash
cd /path/to/FurrOS-firefox-theme
bash ./install.command
```

`bash ./install.command` also works when the executable bit was lost. If macOS blocks a double-click, right-click the file and choose **Open**.

### Windows (PowerShell, CMD or Explorer)

PowerShell, from the extracted folder:

```powershell
cd C:\path\to\FurrOS-firefox-theme
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

CMD, from the extracted folder:

```cmd
cd /d C:\path\to\FurrOS-firefox-theme
install.bat
```

Explorer: double-click `install.bat`. The CMD launcher pauses only when the install fails; a successful run exits immediately.

### WSL

From inside WSL, `install.sh` reads the Windows Firefox profile through `cmd.exe` and `wslpath`. When a Windows profile exists, no second Linux Firefox is installed:

```bash
cd /mnt/c/Users/Name/Downloads/FurrOS-firefox-theme
./install.sh
```

To use the native Windows installer explicitly instead:

```bash
cd /mnt/c/Users/Name/Downloads/FurrOS-firefox-theme
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

### Optional: Python alternative

```bash
python3 install.py          # Linux, macOS, WSL
```

```powershell
py -3 install.py            # Windows
```

## What the installer does

1. Installs Firefox if it is missing (may require an administrator password). Pass `--skip-firefox-install` / `-SkipFirefoxInstall` to disable this.
2. Records which profile the running Firefox actually has open (before closing it), including Flatpak, Snap and custom binaries. With confirmation (or `--force`) it closes Firefox with `SIGTERM`, waits, and uses `SIGKILL` only if it is still blocked.
3. Removes lock files left by a previous crash (`lock`, `parent.lock`, `.parentlock`) when no Firefox process is alive, then waits for any remaining locks to be released before touching profile data.
4. Creates an initial Firefox profile only if none exists. Existing `profiles.ini` / `installs.ini` content is preserved by appending new sections; a `.furros-profile` marker makes the profile reusable and prevents duplicates on re-runs. Windows Store/MSIX profiles are handled where Firefox actually looks.
5. Selects the profile automatically: the instance that was open when installation started wins, then `[Install]` in `profiles.ini` / `installs.ini`, then the legacy `Default=1` flag. This prevents a system Firefox install from stealing a Flatpak profile (or vice versa). Linux, macOS, Windows, WSL, Snap, Flatpak and Store layouts are supported; stale `Profiles/profiles.ini` files from older FurrOS runs are ignored. Remaining ties use the FurrOS-managed profile, then initialized, then `.default-release`, then the first path. **No profile-choice prompt is ever shown.**
6. Creates the `chrome` folder if needed.
7. Backs up existing `userChrome.css`, `userContent.css` and `user.js` with a unique `.bak-DATE-TIME` suffix; a collision with an existing backup is avoided.
8. Copies the three theme files and verifies them byte-for-byte.
9. Verifies that `user.js` enables custom stylesheets.
10. Writes `FurrOS-install-report.txt` in your home folder, including the selected profile, how it was chosen, the Firefox container (system/Flatpak/Snap/MSIX) and binary, then asks you to start Firefox again.

Extra options:

```bash
./install.sh --profile /full/path/to/profile     # manual override only
./install.sh --firefox-bin /path/to/firefox      # custom binary or Snap wrapper
./install.sh --force                             # close running Firefox without asking
./install.sh --skip-firefox-install              # do not install a missing Firefox
./install.sh --uninstall                         # remove the theme files
python3 install.py --firefox-bin /path/to/firefox
```

`./install.sh --help` and `python3 install.py --help` list all options. PowerShell equivalents: `-Profile "C:\path"`, `-Force`, `-SkipFirefoxInstall`, `-Uninstall`.

## Verify the installation

Read the selected profile from the report, then check the three files.

Linux, macOS and WSL:

```bash
grep '^Profile:' ~/FurrOS-install-report.txt
PROFILE="$(grep '^Profile:' ~/FurrOS-install-report.txt | cut -d' ' -f2-)"
ls -l "$PROFILE/chrome/userChrome.css" "$PROFILE/chrome/userContent.css" "$PROFILE/user.js"
grep -F 'toolkit.legacyUserProfileCustomizations.stylesheets' "$PROFILE/user.js"
```

Windows PowerShell:

```powershell
Select-String -Path "$env:USERPROFILE\FurrOS-install-report.txt" -Pattern '^Profile:'
$profile = (Select-String -Path "$env:USERPROFILE\FurrOS-install-report.txt" -Pattern '^Profile:').Line.Split(': ', 2)[1]
Get-Item "$profile\chrome\userChrome.css", "$profile\chrome\userContent.css", "$profile\user.js"
Select-String -Path "$profile\user.js" -Pattern 'toolkit.legacyUserProfileCustomizations.stylesheets'
```

Then start Firefox. The address bar, panels and new tab page should use the FurrOS styling. If Firefox was open, the installer closed it; simply start it again.

## Uninstall

```bash
cd /path/to/FurrOS-firefox-theme
./install.sh --uninstall
```

Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Close Firefox first. This removes the three theme files; backups are kept in the profile.

## Important notes

- `user.js` is read on every startup and **overwrites** the preferences it contains. If you change one of those preferences in `about:config`, Firefox will restore it on the next launch.
- The new tab page uses `#150B11` as its background. Wallpaper tiles from the customize pencil are translated into three embedded FurrOS images behind the wordmark.
- Uploading your own image does not apply a background: the wordmark stays without any extra background image.
- On Windows, Firefox keeps `profiles.ini` and `installs.ini` in `%APPDATA%\Mozilla\Firefox\`, one level above `Profiles`. Microsoft Store installs use the virtualized folder under `%LOCALAPPDATA%\Packages`.
- On macOS, Firefox keeps both ini files in `~/Library/Application Support/Firefox/`, one level above `Profiles`; no second run is needed on a fresh install.
- On Linux, both `~/.mozilla/firefox` and `${XDG_CONFIG_HOME:-~/.config}/mozilla/firefox` are searched, along with the Snap and Flatpak locations. No duplicate profile is created.
- Running the installer as `sudo` / root targets root's Firefox profile. Run it as the desktop user unless you intentionally want to change root's browser.
- Do not rename or move the profile directory by hand after installing; `user.js` and `chrome/` must stay inside the profile selected in the report.

## Troubleshooting

The installer now closes Firefox for you (with confirmation in a terminal, or with `--force` in a script). If it reports that a process or a lock file remains, close Firefox manually and re-run; it is safe to run twice and each run creates a new `.bak-DATE-TIME` backup.

If the report says the files were verified but the UI does not change, check `Profile:`, `Profile source:` and `Container:` in `~/FurrOS-install-report.txt`. A Flatpak browser cannot read a system Firefox profile: the container must match the Firefox you actually launch. With both a system and a Flatpak Firefox installed, re-run the installer **while the browser you use is open** so it records the correct profile; or pass `--profile` explicitly. The CSS has no external image or font dependencies: all backgrounds are embedded as `data:` URLs, so a missing asset in `chrome/` is never the cause.

Linux and macOS:

```bash
pgrep -a -x firefox || echo "no Firefox process"
cd /path/to/FurrOS-firefox-theme
./diagnose.sh
cat ~/FurrOS-install-report.txt
```

Windows PowerShell:

```powershell
Get-Process firefox -ErrorAction SilentlyContinue
Get-Content "$env:USERPROFILE\FurrOS-install-report.txt"
cd C:\path\to\FurrOS-firefox-theme
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Force
```

WSL:

```bash
pgrep -a -x firefox || echo "no Linux Firefox process"
tasklist.exe | grep -i firefox.exe || echo "no Windows Firefox process"
cd /mnt/c/Users/Name/Downloads/FurrOS-firefox-theme
./diagnose.sh
```

For an unusual profile layout, use the manual override:

```bash
./install.sh --profile /full/path/to/profile
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Profile "C:\path\to\profile"
```

If an automatic Firefox installation fails, install Firefox manually from <https://www.firefox.com/> and re-run the theme installer with `--skip-firefox-install` / `-SkipFirefoxInstall`.

## Tests and validation

```bash
cd /path/to/FurrOS-firefox-theme
./tests/run-tests.sh
```

The suite runs locally without network access and does not touch a real profile. It uses `FURR_FIREFOX_BIN` as a stub so no package manager or browser is started. It covers Linux, simulated macOS and simulated Windows/WSL profile detection, first-run profile creation, deterministic tie-breaks, non-interactive launchers, Store/MSIX paths and byte-for-byte file copies. It also simulates a running Linux Firefox with a lock file and verifies clean shutdown, lock release, ini preservation and idempotent re-runs. PowerShell and CMD scripts are checked statically here because PowerShell is not available in this Linux test environment; real end-to-end runs on Windows, macOS Intel and macOS Apple Silicon still require manual verification.

### Manual test on Linux

With Firefox closed:

```bash
cd /path/to/FurrOS-firefox-theme
./install.sh
grep '^Profile:' ~/FurrOS-install-report.txt
./install.sh        # no duplicate profile, only a new .bak-DATE-TIME backup
```

With Firefox open, in an interactive terminal:

```bash
cd /path/to/FurrOS-firefox-theme
./install.sh        # answer y when asked to close Firefox
```

From a script or another non-interactive context:

```bash
./install.sh --force
```

Expected output: `Firefox is running (PID: ...)`, `Closing Firefox cleanly (SIGTERM)...` and `Firefox closed; profile locks released.` The browser must exit without data loss, the lock files must disappear, the three theme files must be installed in the profile shown in the report, and a second run must not add another `[Profile]` or `[Install]` section to `profiles.ini`. To test a non-default installation, point the installer at it explicitly:

```bash
./install.sh --firefox-bin /snap/bin/firefox
python3 install.py --firefox-bin /path/to/custom/firefox
```

Flatpak and Snap are detected automatically; `--firefox-bin` is only needed for a custom location.

## Release

Release `v1.0.0` contains the theme source and installers as a downloadable archive. Use the tag matching this checkout when you want a reproducible copy.
