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

**Close Firefox completely before installing.** The theme files are read only at startup. The installer refuses to continue while Firefox is running unless you explicitly pass `--force` / `-Force`.

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
2. Creates an initial Firefox profile if Firefox has never been started. Windows Store/MSIX profiles are handled where Firefox actually looks.
3. Detects the real default profile from `[Install]` in `profiles.ini` / `installs.ini`, not only the legacy `Default=1` flag. Linux, macOS, Windows, WSL, Snap, Flatpak and Store layouts are supported; stale `Profiles/profiles.ini` files from older FurrOS runs are ignored. Ties are resolved automatically: initialized profile, then `.default-release`, then the first path. **No prompt is ever shown.**
4. Creates the `chrome` folder if needed.
5. Backs up existing `userChrome.css`, `userContent.css` and `user.js` with a `.bak-DATE-TIME` suffix.
6. Copies the three theme files and verifies them byte-for-byte.
7. Verifies that `user.js` enables custom stylesheets.
8. Writes `FurrOS-install-report.txt` in your home folder and asks you to start Firefox again.

Extra options:

```bash
./install.sh --profile /full/path/to/profile   # manual override only
./install.sh --force                           # install while Firefox is running
./install.sh --skip-firefox-install            # do not install a missing Firefox
./install.sh --uninstall                       # remove the theme files
```

PowerShell equivalents: `-Profile "C:\path"`, `-Force`, `-SkipFirefoxInstall`, `-Uninstall`.

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

Then start Firefox. The address bar, panels and new tab page should use the FurrOS styling. If Firefox was already open, close it completely and start it again.

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

First, confirm Firefox is really closed and re-run the installer; it is non-interactive and safe to run twice (the second run creates new `.bak-DATE-TIME` backups).

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

The suite runs locally without network access and does not touch a real profile. It uses `FURR_FIREFOX_BIN` as a stub so no package manager or browser is started. It covers Linux, simulated macOS and simulated Windows/WSL profile detection, first-run profile creation, deterministic tie-breaks, non-interactive launchers, Store/MSIX paths and byte-for-byte file copies. PowerShell and CMD scripts are checked statically here because PowerShell is not available in this Linux test environment; real end-to-end runs on Windows, macOS Intel and macOS Apple Silicon still require manual verification.

## Release

Release `v1.0.0` contains the theme source and installers as a downloadable archive. Use the tag matching this checkout when you want a reproducible copy.
