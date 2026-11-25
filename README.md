# FurrOS Firefox Theme

A Firefox theme inspired by [FurrOS](https://furros.xyz/): dark chrome, chips with ink borders, sticker shadows, and a paw + FurrOS wordmark on the new tab page.

## Contents

- `userChrome.css` — Firefox UI: oval address bar, attached dropdown, menus and panels.
- `userContent.css` — internal pages: wordmark, embedded FurrOS wallpapers, AI chatbot styles.
- `user.js` — required preferences (`toolkit.legacyUserProfileCustomizations.stylesheets`, dark theme, wallpapers, disabled shortcuts/stories/widgets).
- `install.sh` — installer that backs up your existing files.

## Installation

```bash
git clone https://github.com/Critata/FurrOS-firefox-theme.git
cd FurrOS-firefox-theme
chmod +x install.sh
./install.sh
```

**Close Firefox completely before running the installer.** The theme files are read only when Firefox starts. If Firefox is still running, the script stops with an error.

If you have multiple profiles or want to choose one manually:

```bash
./install.sh --profile /home/username/.config/mozilla/firefox/xxxx.default-release
```

Use `--force` only if you know what you are doing and want to install while Firefox is running:

```bash
./install.sh --force
```

The installer:

1. detects the default Firefox profile (including Snap and Flatpak installs) or asks you to choose;
2. creates the `chrome` folder if needed;
3. backs up the existing `userChrome.css`, `userContent.css` and `user.js` with a `.bak-DATE-TIME` suffix;
4. copies the theme files and verifies them;
5. asks you to start Firefox again.

## Uninstall

```bash
./install.sh --uninstall
```

Close Firefox first. This removes the three theme files. Your backups are kept in the profile.

## Important notes

- `user.js` is read on every startup and **overwrites** the preferences it contains. If you change one of those preferences in `about:config`, Firefox will restore it on the next launch.
- The new tab page uses `#150B11` as its background. Wallpaper tiles from the customize pencil are translated into three embedded FurrOS images behind the wordmark.
- Uploading your own image does not apply a background: the wordmark stays without any extra background image.
- Tested on Firefox 161, Linux/Wayland. Other versions may need small adjustments.

## Release

Release `v1.0.0` contains the theme source, ready to download and install.
