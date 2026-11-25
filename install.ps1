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

function Test-FirefoxRunning {
  $processes = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -like 'firefox*'
  }
  return [bool]$processes
}

function Get-IniCandidates {
  $raw = @()
  if ($env:APPDATA) {
    $raw += (Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles\profiles.ini')
  }
  if ($env:LOCALAPPDATA) {
    $raw += (Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles\profiles.ini')
  }
  if ($env:USERPROFILE) {
    $raw += (Join-Path $env:USERPROFILE 'Mozilla\Firefox\Profiles\profiles.ini')
    $raw += (Join-Path $env:USERPROFILE '.mozilla\firefox\profiles.ini')
    $raw += (Join-Path $env:USERPROFILE '.config\mozilla\firefox\profiles.ini')
  }

  $seen = @{}
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

  $isDefault = $false
  if ($Data.ContainsKey('Default') -and $Data['Default'] -eq '1') { $isDefault = $true }

  return [pscustomobject]@{ Name = $name; Path = $path; Default = $isDefault }
}

function Read-Profiles {
  param([string]$Ini)
  $base = Split-Path -Parent $Ini
  $profiles = @()
  $section = ''
  $data = @{}

  foreach ($line in (Get-Content -LiteralPath $Ini)) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^\[(.+)\]$') {
      if ($section -like 'Profile*') {
        $item = ConvertTo-ProfileObject -Base $base -Data $data
        if ($item) { $profiles += $item }
      }
      $section = $matches[1]
      $data = @{}
      continue
    }
    if ($section -like 'Profile*' -and $trimmed -match '^([^=]+)=(.*)$') {
      $data[$matches[1].Trim()] = $matches[2].Trim()
    }
  }
  if ($section -like 'Profile*') {
    $item = ConvertTo-ProfileObject -Base $base -Data $data
    if ($item) { $profiles += $item }
  }

  $profiles = $profiles | Sort-Object -Property @{ Expression = { -not $_.Default } }
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

  $all = @()
  foreach ($ini in (Get-IniCandidates)) {
    Write-Host "Found profile list: $ini"
    foreach ($item in (Read-Profiles -Ini $ini)) {
      $duplicate = $false
      foreach ($known in $all) {
        if ($known.Path -eq $item.Path) { $duplicate = $true; break }
      }
      if (-not $duplicate) { $all += $item }
    }
  }

  if ($all.Count -eq 0) {
    throw "Error: Firefox profile not found.`nSpecify it with: powershell -File install.ps1 -Profile 'C:\path\to\profile'"
  }
  if ($all.Count -eq 1) { return $all[0].Path }

  Write-Host ''
  Write-Host 'Multiple Firefox profiles found:'
  for ($i = 0; $i -lt $all.Count; $i++) {
    $marker = ''
    if ($all[$i].Default) { $marker = ' (default)' }
    Write-Host ('  {0}. {1}{2} - {3}' -f ($i + 1), $all[$i].Name, $marker, $all[$i].Path)
  }
  while ($true) {
    $answer = Read-Host 'Choose the profile number'
    $number = 0
    if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $all.Count) {
      return $all[$number - 1].Path
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
