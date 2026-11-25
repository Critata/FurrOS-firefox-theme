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

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-FirefoxInstalled {
  foreach ($name in @('firefox', 'firefox.exe')) {
    if (Get-Command $name -ErrorAction SilentlyContinue) { return $true }
  }

  $paths = @(
    (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe'),
    (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe')
  )
  foreach ($path in $paths) {
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }
  }

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
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install --id Mozilla.Firefox -e --accept-source-agreements --accept-package-agreements --silent
    return
  }
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    choco install firefox -y
    return
  }
  if (Get-Command scoop -ErrorAction SilentlyContinue) {
    scoop install firefox
    return
  }

  $url = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US'
  $out = Join-Path $env:TEMP 'FirefoxSetup.exe'
  Write-Host 'Downloading Firefox for Windows...'
  Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
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

  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($machinePath -and $userPath) {
    $env:Path = "$machinePath;$userPath"
  } elseif ($machinePath) {
    $env:Path = $machinePath
  } elseif ($userPath) {
    $env:Path = $userPath
  }

  if (-not (Test-FirefoxInstalled)) {
    throw 'Error: Firefox was installed but could not be detected. Start Firefox once, then run this installer again.'
  }
  Write-Host 'Firefox installed successfully.'
}

function Initialize-FirefoxProfile {
  # Never create a second profile: Firefox may already use one in another
  # standard location.
  foreach ($ini in (Get-IniCandidates)) {
    if (Select-String -LiteralPath $ini -Pattern '^\[Profile' -Quiet) { return }
  }

  $appData = $env:APPDATA
  if (-not $appData) { $appData = Join-Path $env:USERPROFILE 'AppData\Roaming' }
  $firefoxDir = Join-Path $appData 'Mozilla\Firefox'
  $profilesDir = Join-Path $firefoxDir 'Profiles'
  $profilesIni = Join-Path $firefoxDir 'profiles.ini'
  $installsIni = Join-Path $firefoxDir 'installs.ini'

  New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null
  $id = -join (1..8 | ForEach-Object {
    $index = Get-Random -Minimum 0 -Maximum 36
    '0123456789abcdefghijklmnopqrstuvwxyz'[$index]
  })
  $dir = "$id.default-release"
  $relative = "Profiles/$dir"
  New-Item -ItemType Directory -Path (Join-Path $profilesDir $dir) -Force | Out-Null

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
  Set-Content -LiteralPath $profilesIni -Value $profileLines -Encoding ASCII

  $installLines = @(
    "[Install$id]",
    "Default=$relative",
    'Locked=1',
    ''
  )
  Set-Content -LiteralPath $installsIni -Value $installLines -Encoding ASCII
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
    $value = [Environment]::GetEnvironmentVariable($variable)
    if (-not $value) { continue }
    $firefoxDir = Join-Path $value 'Mozilla\Firefox'
    $raw += (Join-Path $firefoxDir 'profiles.ini')
    $raw += (Join-Path $firefoxDir 'installs.ini')
    $raw += (Join-Path $firefoxDir 'Profiles\profiles.ini')
  }

  # Microsoft Store / MSIX Firefox stores its profile under Packages.
  $local = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
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
          $storeDir = Join-Path $app.FullName $relative
          $raw += (Join-Path $storeDir 'profiles.ini')
          $raw += (Join-Path $storeDir 'installs.ini')
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
      if ($section.Name -notlike 'Install*') { continue }
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

  return [pscustomobject]@{ Name = $name; Path = $path; LegacyDefault = $legacyDefault }
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

  $all = $all | Sort-Object -Property @{ Expression = { $_.Score } } -Descending
  if ($all.Count -eq 1) { return $all[0].Path }

  $topScore = $all[0].Score
  $top = @()
  $rest = @()
  foreach ($item in $all) {
    if ($item.Score -eq $topScore) { $top += $item } else { $rest += $item }
  }
  if ($top.Count -eq 1) {
    Write-Host "Selected profile: $($top[0].Path)"
    return $top[0].Path
  }

  $choices = @($top) + @($rest)
  Write-Host ''
  Write-Host 'Multiple Firefox profiles found:'
  for ($i = 0; $i -lt $choices.Count; $i++) {
    $marker = ''
    switch ($choices[$i].Score) {
      3 { $marker = ' (default)' }
      2 { $marker = ' (legacy default)' }
    }
    Write-Host ('  {0}. {1}{2} - {3}' -f ($i + 1), $choices[$i].Name, $marker, $choices[$i].Path)
  }
  while ($true) {
    $answer = Read-Host 'Choose the profile number'
    $number = 0
    if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $choices.Count) {
      return $choices[$number - 1].Path
    }
    Write-Host 'Invalid choice.'
  }
}

function Write-InstallReport {
  param([string]$ProfilePath, [hashtable]$Targets, [bool]$Removed, [string]$BackupStamp)
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
    foreach ($target in $Targets.Values) {
      $lines += ('Removed:  {0}' -f $target)
    }
  } else {
    $lines += ('Backup:   .bak-{0}' -f $BackupStamp)
    $lines += 'Action:   Install'
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
  New-Item -ItemType Directory -Path $chrome -Force | Out-Null

  $targets = @{
    'userChrome.css'  = Join-Path $chrome 'userChrome.css'
    'userContent.css' = Join-Path $chrome 'userContent.css'
    'user.js'         = Join-Path $profilePath 'user.js'
  }

  if ($Uninstall) {
    foreach ($file in $themeFiles) {
      if (Test-Path -LiteralPath $targets[$file] -PathType Leaf) {
        Remove-Item -LiteralPath $targets[$file] -Force
      }
    }
    Write-InstallReport -ProfilePath $profilePath -Targets $targets -Removed $true -BackupStamp $stamp
    Write-Host ''
    Write-Host "FurrOS theme removed from: $profilePath"
    Write-Host "Report saved: $report"
    Write-Host 'Start Firefox again to apply the change.'
  } else {
    foreach ($file in $themeFiles) {
      $target = $targets[$file]
      if (Test-Path -LiteralPath $target -PathType Leaf) {
        Copy-Item -LiteralPath $target -Destination ($target + '.bak-' + $stamp) -Force
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

    Write-InstallReport -ProfilePath $profilePath -Targets $targets -Removed $false -BackupStamp $stamp
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
