param(
  [string]$Profile,
  [switch]$Force,
  [switch]$Uninstall,
  [switch]$SkipFirefoxInstall
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$themeFiles = @('userChrome.css', 'userContent.css', 'user.js')
$report = Join-Path $env:USERPROFILE 'FurrOS-install-report.txt'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$requiredPref = 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'

Write-Host 'FurrOS Firefox theme installer - starting...'

function Get-EnvVar {
  param([string]$Name)
  return [Environment]::GetEnvironmentVariable($Name)
}

function Write-Utf8NoBom {
  param([string]$Path, [string[]]$Lines)
  $text = ($Lines -join "`r`n") + "`r`n"
  [IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-StoreFirefoxDir {
  # Microsoft Store / MSIX Firefox uses a virtualised APPDATA under Packages.
  $local = Get-EnvVar 'LOCALAPPDATA'
  if (-not $local) { return $null }
  $packages = Join-Path $local 'Packages'
  if (-not (Test-Path -LiteralPath $packages -PathType Container)) { return $null }

  $relatives = @(
    'LocalCache\Roaming\Mozilla\Firefox',
    'LocalCache\Local\Mozilla\Firefox',
    'LocalState\Mozilla\Firefox'
  )
  $apps = @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'Mozilla.Firefox*' -ErrorAction SilentlyContinue)
  foreach ($app in $apps) {
    foreach ($relative in $relatives) {
      $dir = Join-Path $app.FullName $relative
      if ((Test-Path -LiteralPath (Join-Path $dir 'profiles.ini') -PathType Leaf) -or
          (Test-Path -LiteralPath (Join-Path $dir 'installs.ini') -PathType Leaf)) {
        return $dir
      }
    }
  }
  # A Store Firefox that has never started has no ini yet, but this folder
  # still exists and is where Firefox will look for its profile.
  foreach ($app in $apps) {
    $dir = Join-Path $app.FullName 'LocalCache\Roaming\Mozilla\Firefox'
    if (Test-Path -LiteralPath (Split-Path -Parent $dir) -PathType Container) { return $dir }
  }
  return $null
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-FirefoxInstalled {
  foreach ($name in @('firefox', 'firefox.exe')) {
    if (Get-Command $name -ErrorAction SilentlyContinue) { return $true }
  }

  $paths = @()
  foreach ($variable in @('ProgramW6432', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA')) {
    $root = Get-EnvVar $variable
    if ($root) { $paths += (Join-Path $root 'Mozilla Firefox\firefox.exe') }
  }
  foreach ($path in $paths) {
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }
  }
  if (Get-StoreFirefoxDir) { return $true }

  $roots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($root in $roots) {
    $entries = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue
    if ($entries | Where-Object { $_.DisplayName -like '*Firefox*' }) { return $true }
  }

  return $false
}

function Install-Firefox {
  # Try every available manager: a broken winget must not block Chocolatey
  # or the direct Mozilla download.
  $managers = @(
    [pscustomobject]@{
      Name = 'winget'
      Args = @('install', '--id', 'Mozilla.Firefox', '-e', '--accept-source-agreements', '--accept-package-agreements', '--silent')
    },
    [pscustomobject]@{ Name = 'choco'; Args = @('install', 'firefox', '-y') },
    [pscustomobject]@{ Name = 'scoop'; Args = @('install', 'firefox') }
  )
  foreach ($manager in $managers) {
    if (-not (Get-Command $manager.Name -ErrorAction SilentlyContinue)) { continue }
    try {
      $managerArgs = @($manager.Args)
      & $manager.Name @managerArgs
    } catch {
      continue
    }
    if (Test-FirefoxInstalled) { return }
  }

  # Mozilla serves os=win (32-bit) and os=win64 (64-bit, emulated on ARM64).
  # ARM64 does not have a separate stable URL, so win64 is intentional.
  $arch = Get-EnvVar 'PROCESSOR_ARCHITECTURE'
  if (-not $arch) { $arch = Get-EnvVar 'PROCESSOR_ARCHITEW6432' }
  $os = if ($arch -eq 'X86') { 'win' } else { 'win64' }
  $url = "https://download.mozilla.org/?product=firefox-latest-ssl&os=$os&lang=en-US"
  $out = Join-Path $env:TEMP 'FirefoxSetup.exe'
  Write-Host "Downloading Firefox for Windows ($os)..."
  Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 300
  Start-Process -FilePath $out -ArgumentList '/S' -Wait
}

function Ensure-Firefox {
  param([bool]$Skip)

  if (Test-FirefoxInstalled) { return }

  if ($Skip) {
    throw "Error: Firefox is not installed.`nInstall it manually, or run the installer without -SkipFirefoxInstall."
  }

  Write-Host 'Firefox not found. Installing it automatically...'
  try {
    Install-Firefox
  } catch {
    throw "Error: could not install Firefox automatically. $($_.Exception.Message)"
  }

  # Refresh PATH from the machine and user values, but keep the inherited
  # entries and the ones added by winget/choco/scoop in this session.
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = @($env:Path -split ';') + @(($userPath -split ';') + ($machinePath -split ';'))
  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $newPath = @()
  foreach ($entry in $entries) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    if ($seen.Add($entry)) { $newPath += $entry }
  }
  $env:Path = $newPath -join ';'

  if (-not (Test-FirefoxInstalled)) {
    throw 'Error: Firefox was installed but could not be detected. Start Firefox once, then run this installer again.'
  }
  Write-Host 'Firefox installed successfully.'
}

function Initialize-FirefoxProfile {
  # Never create a second profile: Firefox may already use one in another
  # standard location (including the Store/MSIX sandbox).
  foreach ($ini in (Get-IniCandidates)) {
    if (Select-String -LiteralPath $ini -Pattern '^\[Profile' -Quiet) { return }
  }

  $storeDir = Get-StoreFirefoxDir
  if ($storeDir) {
    $firefoxDir = $storeDir
  } else {
    $appData = Get-EnvVar 'APPDATA'
    if (-not $appData) { $appData = Join-Path $env:USERPROFILE 'AppData\Roaming' }
    $firefoxDir = Join-Path $appData 'Mozilla\Firefox'
  }
  $profilesDir = Join-Path $firefoxDir 'Profiles'
  $profilesIni = Join-Path $firefoxDir 'profiles.ini'

  [IO.Directory]::CreateDirectory($profilesDir) | Out-Null
  $id = -join (1..8 | ForEach-Object {
    $index = Get-Random -Minimum 0 -Maximum 36
    '0123456789abcdefghijklmnopqrstuvwxyz'[$index]
  })
  $dir = "$id.default-release"
  $relative = "Profiles/$dir"
  [IO.Directory]::CreateDirectory((Join-Path $profilesDir $dir)) | Out-Null

  # Do not invent an [Install<hash>] section here. Firefox derives the hash
  # from its own installation directory and creates installs.ini on first
  # start; a fake hash is ignored (or, worse, migrated by Firefox and later
  # mistaken for a real default). The legacy [Profile] Default=1 flag is
  # enough to make Firefox pick this profile on first start.
  $profileLines = @(
    '[General]',
    'StartWithLastProfile=1',
    'Version=2',
    '',
    '[Profile0]',
    'Name=default-release',
    'IsRelative=1',
    "Path=$relative",
    'Default=1',
    ''
  )
  Write-Utf8NoBom -Path $profilesIni -Lines $profileLines
  Write-Host "Created Firefox profile: $(Join-Path $profilesDir $dir)"
}

function Test-FirefoxRunning {
  $processes = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -like 'firefox*'
  }
  return [bool]$processes
}

function Get-IniCandidates {
  # Firefox keeps profiles.ini and installs.ini in %APPDATA%\Mozilla\Firefox,
  # one level above the Profiles folder. Both files are needed: installs.ini
  # is what Firefox 62+ uses to remember the default profile.
  $raw = @()
  foreach ($variable in @('APPDATA', 'LOCALAPPDATA')) {
    $value = Get-EnvVar $variable
    if (-not $value) { continue }
    $firefoxDir = Join-Path $value 'Mozilla\Firefox'
    $raw += (Join-Path $firefoxDir 'profiles.ini')
    $raw += (Join-Path $firefoxDir 'installs.ini')
  }

  # Firefox never reads a profiles.ini inside Profiles/. Older FurrOS
  # installers wrote one there; it must be ignored on every platform.
  $storeDir = Get-StoreFirefoxDir
  if ($storeDir) {
    $raw += (Join-Path $storeDir 'profiles.ini')
    $raw += (Join-Path $storeDir 'installs.ini')
  }
  $local = Get-EnvVar 'LOCALAPPDATA'
  if ($local) {
    $packages = Join-Path $local 'Packages'
    if (Test-Path -LiteralPath $packages -PathType Container) {
      $storeApps = Get-ChildItem -LiteralPath $packages -Directory -Filter 'Mozilla.Firefox*' -ErrorAction SilentlyContinue
      foreach ($app in $storeApps) {
        foreach ($relative in @(
          'LocalCache\Roaming\Mozilla\Firefox',
          'LocalCache\Local\Mozilla\Firefox',
          'LocalState\Mozilla\Firefox'
        )) {
          $dir = Join-Path $app.FullName $relative
          $raw += (Join-Path $dir 'profiles.ini')
          $raw += (Join-Path $dir 'installs.ini')
        }
      }
    }
  }

  if ($env:USERPROFILE) {
    $raw += (Join-Path $env:USERPROFILE 'Mozilla\Firefox\profiles.ini')
    $raw += (Join-Path $env:USERPROFILE 'Mozilla\Firefox\installs.ini')
  }

  $seen = [System.Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::OrdinalIgnoreCase)
  $result = @()
  foreach ($item in $raw) {
    if (-not $item) { continue }
    if (-not (Test-Path -LiteralPath $item -PathType Leaf)) { continue }
    $full = [IO.Path]::GetFullPath($item)
    if (-not $seen.ContainsKey($full)) {
      $seen[$full] = $true
      $result += $full
    }
  }
  return $result
}

function Read-IniSections {
  param([string]$Ini)

  $sections = @()
  $section = ''
  $data = @{}

  foreach ($line in (Get-Content -LiteralPath $Ini)) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^\[(.+)\]$') {
      if ($section) {
        $sections += [pscustomobject]@{ Name = $section; Data = $data }
      }
      $section = $matches[1]
      $data = @{}
      continue
    }
    if ($section -and $trimmed -match '^([^=]+)=(.*)$') {
      $data[$matches[1].Trim()] = $matches[2].Trim()
    }
  }
  if ($section) {
    $sections += [pscustomobject]@{ Name = $section; Data = $data }
  }
  return $sections
}

function Get-InstallDefaults {
  param([string[]]$IniFiles = @())

  $defaults = @()
  foreach ($ini in $IniFiles) {
    $base = Split-Path -Parent $ini
    foreach ($section in @(Read-IniSections -Ini $ini)) {
      # Firefox writes the install hash as 16 uppercase hex digits:
      # profiles.ini uses [Install<hash>], installs.ini uses [<hash>].
      # Older FurrOS installers wrote [Install<profile-id>] with a
      # lowercase id; Firefox copied those into installs.ini as bare
      # sections, but they are not real installation defaults.
      if ($section.Name -cnotmatch '^(Install)?[0-9A-F]{16}$') { continue }
      if (-not $section.Data.ContainsKey('Default')) { continue }

      $value = [Environment]::ExpandEnvironmentVariables($section.Data['Default'])
      if ([IO.Path]::IsPathRooted($value)) {
        $path = [IO.Path]::GetFullPath($value)
      } else {
        $path = [IO.Path]::GetFullPath((Join-Path $base $value))
      }
      $path = $path.TrimEnd([char]'\')
      if ($defaults -notcontains $path) { $defaults += $path }
    }
  }
  return $defaults
}

function ConvertTo-ProfileObject {
  param([string]$Base, [hashtable]$Data)
  if (-not $Data.ContainsKey('Path')) { return $null }

  $expanded = [Environment]::ExpandEnvironmentVariables($Data['Path'])
  if ([IO.Path]::IsPathRooted($expanded)) {
    $path = $expanded
  } else {
    $path = Join-Path $Base $expanded
  }
  $path = [IO.Path]::GetFullPath($path)
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }

  $name = Split-Path -Leaf $path
  if ($Data.ContainsKey('Name') -and $Data['Name']) { $name = $Data['Name'] }

  $legacyDefault = $false
  if ($Data.ContainsKey('Default') -and $Data['Default'] -eq '1') { $legacyDefault = $true }
  $initialized = (Test-Path -LiteralPath (Join-Path $path 'prefs.js') -PathType Leaf) -or
    (Test-Path -LiteralPath (Join-Path $path 'user.js') -PathType Leaf)
  $preferred = $path -like '*.default-release*'

  return [pscustomobject]@{
    Name = $name
    Path = $path
    LegacyDefault = $legacyDefault
    Initialized = [bool]$initialized
    Preferred = [bool]$preferred
  }
}

function Read-Profiles {
  param([string[]]$IniFiles = @(), [string[]]$InstallDefaults = @())

  $profiles = @()
  foreach ($ini in $IniFiles) {
    $base = Split-Path -Parent $ini
    foreach ($section in @(Read-IniSections -Ini $ini)) {
      if ($section.Name -notlike 'Profile*') { continue }

      $item = ConvertTo-ProfileObject -Base $base -Data $section.Data
      if (-not $item) { continue }

      # Firefox's real default comes from [Install...] in profiles.ini or
      # installs.ini, not from the legacy [Profile...] Default=1 flag.
      $score = 1
      if ($item.LegacyDefault) { $score = 2 }
      foreach ($defaultPath in $InstallDefaults) {
        if ([string]::Equals(
          $defaultPath.TrimEnd([char]'\'), $item.Path.TrimEnd([char]'\'),
          [StringComparison]::OrdinalIgnoreCase
        )) { $score = 3; break }
      }
      $item | Add-Member -NotePropertyName Score -NotePropertyValue $score -Force

      $duplicate = $false
      foreach ($known in $profiles) {
        if ([string]::Equals($known.Path, $item.Path, [StringComparison]::OrdinalIgnoreCase)) {
          $duplicate = $true
          break
        }
      }
      if (-not $duplicate) { $profiles += $item }
    }
  }
  return $profiles
}

function Choose-Profile {
  param([string]$Specified)

  if ($Specified) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Specified)
    $path = [IO.Path]::GetFullPath($expanded)
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
      throw "Error: profile directory does not exist: $path"
    }
    return $path
  }

  $iniFiles = @(Get-IniCandidates)
  foreach ($ini in $iniFiles) {
    Write-Host "Found profile list: $ini"
  }

  $installDefaults = @(Get-InstallDefaults -IniFiles $iniFiles)
  foreach ($defaultPath in $installDefaults) {
    Write-Host "Default profile: $defaultPath"
  }

  $all = @(Read-Profiles -IniFiles $iniFiles -InstallDefaults $installDefaults)

  if ($all.Count -eq 0) {
    throw "Error: Firefox profile not found.`nSpecify it with: powershell -File install.ps1 -Profile 'C:\path\to\profile'"
  }

  # Automatic, deterministic tie-break, identical to install.sh/install.py:
  # score, initialized profile, .default-release, then ordinal path. Never
  # prompt, even when several profiles share the same score.
  $best = $null
  foreach ($item in $all) {
    if (-not $best) { $best = $item; continue }
    if ($item.Score -gt $best.Score) { $best = $item; continue }
    if ($item.Score -lt $best.Score) { continue }
    if ($item.Initialized -and -not $best.Initialized) { $best = $item; continue }
    if (-not $item.Initialized -and $best.Initialized) { continue }
    if ($item.Preferred -and -not $best.Preferred) { $best = $item; continue }
    if (-not $item.Preferred -and $best.Preferred) { continue }
    if ([string]::CompareOrdinal($item.Path, $best.Path) -lt 0) { $best = $item }
  }
  Write-Host "Selected profile: $($best.Path)"
  return $best.Path
}

function Write-InstallReport {
  param(
    [string]$ProfilePath,
    [hashtable]$Targets,
    [bool]$Removed,
    [string[]]$Paths = @()
  )
  $lines = @(
    'FurrOS Firefox theme installation report',
    ('Date:     {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('System:   Windows {0}' -f [Environment]::OSVersion.Version),
    ('User:     {0}' -f $env:USERNAME),
    ('Home:     {0}' -f $env:USERPROFILE),
    ('Source:   {0}' -f $source),
    ('Profile:  {0}' -f $ProfilePath)
  )
  if ($Removed) {
    $lines += 'Action:   Uninstall'
    if ($Paths.Count -eq 0) {
      $lines += 'Removed:  nothing (no theme files were present)'
    } else {
      foreach ($path in $Paths) {
        $lines += ('Removed:  {0}' -f $path)
      }
    }
  } else {
    $lines += 'Action:   Install'
    if ($Paths.Count -eq 0) {
      $lines += 'Backup:   none (no previous files)'
    } else {
      foreach ($path in $Paths) {
        $lines += ('Backup:   {0}' -f $path)
      }
    }
    foreach ($key in $themeFiles) {
      $lines += ('Verified: {0} -> {1}' -f $key, $Targets[$key])
    }
    $lines += 'Verified: stylesheet preference enabled'
  }
  Set-Content -LiteralPath $report -Value $lines -Encoding UTF8
}

try {
  foreach ($file in $themeFiles) {
    $sourceFile = Join-Path $source $file
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
      throw "Error: missing source file: $sourceFile"
    }
  }

  if (-not $Uninstall) {
    Ensure-Firefox -Skip $SkipFirefoxInstall
    Initialize-FirefoxProfile
  }

  if (-not $Force -and (Test-FirefoxRunning)) {
    throw "Error: Firefox is still running.`nClose every Firefox window completely, then run the installer again.`nThe theme files are loaded only at startup.`nUse -Force only if you know what you are doing."
  }

  $profilePath = Choose-Profile -Specified $Profile
  $chrome = Join-Path $profilePath 'chrome'
  # IO.Directory handles paths containing [ ] literally, unlike New-Item -Path.
  [IO.Directory]::CreateDirectory($chrome) | Out-Null

  $targets = @{
    'userChrome.css'  = Join-Path $chrome 'userChrome.css'
    'userContent.css' = Join-Path $chrome 'userContent.css'
    'user.js'         = Join-Path $profilePath 'user.js'
  }

  if ($Uninstall) {
    $removedPaths = @()
    foreach ($file in $themeFiles) {
      if (Test-Path -LiteralPath $targets[$file] -PathType Leaf) {
        Remove-Item -LiteralPath $targets[$file] -Force
        $removedPaths += $targets[$file]
      }
    }
    Write-InstallReport -ProfilePath $profilePath -Targets $targets -Removed $true -Paths $removedPaths
    Write-Host ''
    Write-Host "FurrOS theme removed from: $profilePath"
    Write-Host "Report saved: $report"
    Write-Host 'Start Firefox again to apply the change.'
  } else {
    $backupPaths = @()
    foreach ($file in $themeFiles) {
      $target = $targets[$file]
      if (Test-Path -LiteralPath $target -PathType Leaf) {
        $backup = $target + '.bak-' + $stamp
        Copy-Item -LiteralPath $target -Destination $backup -Force
        $backupPaths += $backup
      }
    }

    foreach ($file in $themeFiles) {
      $sourceFile = Join-Path $source $file
      Copy-Item -LiteralPath $sourceFile -Destination $targets[$file] -Force
      if ((Get-Sha256 -Path $sourceFile) -ne (Get-Sha256 -Path $targets[$file])) {
        throw "Error: verification failed for $file"
      }
    }

    $userJs = Get-Content -LiteralPath $targets['user.js'] -Raw
    if ($userJs -notlike "*$requiredPref*") {
      throw 'Error: user.js is missing the required stylesheet preference.'
    }

    Write-InstallReport -ProfilePath $profilePath -Targets $targets -Removed $false -Paths $backupPaths
    Write-Host ''
    Write-Host "FurrOS theme installed in: $profilePath"
    Write-Host "Previous files backed up with suffix .bak-$stamp"
    Write-Host 'Verified: all three theme files match the repository.'
    Write-Host 'Verified: stylesheet preference enabled.'
    Write-Host "Report saved: $report"
    Write-Host ''
    Write-Host 'Now start Firefox. If it was open, close it completely first.'
  }
} catch {
  Write-Host ''
  Write-Host "INSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Report: $report"
  exit 1
}
