# Lumi — build-from-source installer (Windows)
#
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/ankurCES/OpenLaude/main/install-from-source.ps1 | iex
#
# Or, to preview before running:
#   irm https://raw.githubusercontent.com/ankurCES/OpenLaude/main/install-from-source.ps1 -OutFile install.ps1
#   Get-Content install.ps1 | more
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# What it does:
#   1. Detects arch (x64 / arm64).
#   2. Installs missing build deps via winget or direct downloads
#      (git, bun, pnpm, node).
#   3. Authenticates to the private repo (gh CLI → PAT fallback).
#   4. Clones ankurCES/OpenLaude to a temp directory.
#   5. Runs `bun run dist:win` — produces an NSIS installer .exe.
#   6. Launches the installer in silent mode, installs Lumi.
#   7. Deletes the temp clone on success or failure.
#
# Environment overrides (set in PowerShell before running):
#   $env:REPO         = 'ankurCES/OpenLaude'
#   $env:BRANCH       = 'main'
#   $env:GITHUB_TOKEN = 'ghp_...'    # skip interactive prompt
#   $env:SKIP_CLEANUP = '1'          # keep temp clone for debugging
#   $env:KEEP_SOURCE  = 'C:\src\lumi'# move temp clone here before cleanup

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ─── Styling helpers ─────────────────────────────────────────────────────
function Write-Step  { param($msg) Write-Host "`n🌙 $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn2 { param($msg) Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Info  { param($msg) Write-Host "  · $msg" -ForegroundColor DarkGray }
function Die {
  param($msg)
  Write-Host "`n  ✗ $msg`n" -ForegroundColor Red
  exit 1
}

function Ask-Input {
  param([string]$prompt, [string]$default = '')
  $hint = if ($default) { " [$default]" } else { '' }
  $ans = Read-Host "? $prompt$hint"
  if ([string]::IsNullOrWhiteSpace($ans)) { return $default }
  return $ans
}

function Ask-Secret {
  param([string]$prompt)
  $secure = Read-Host "? $prompt" -AsSecureString
  $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Ask-YesNo {
  param([string]$prompt, [string]$default = 'y')
  $hint = if ($default -eq 'y') { '[Y/n]' } else { '[y/N]' }
  $ans = Read-Host "? $prompt $hint"
  if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $default }
  return ($ans -match '^[Yy]')
}

# ─── Banner ──────────────────────────────────────────────────────────────
# Matches the engine CLI banner (packages/lumi-engine/src/cli/banner.ts)
# so the installer feels like part of the same product — moon icon +
# LUMI block art rendered in two tones.
Write-Host ''
Write-Host '                ·  ✦  🌙  ✦  ·' -ForegroundColor Magenta
Write-Host ''
Write-Host '    ██╗     ██╗   ██╗███╗   ███╗██╗' -ForegroundColor Cyan
Write-Host '    ██║     ██║   ██║████╗ ████║██║' -ForegroundColor Cyan
Write-Host '    ██║     ██║   ██║██╔████╔██║██║' -ForegroundColor Cyan
Write-Host '    ██║     ██║   ██║██║╚██╔╝██║██║' -ForegroundColor Cyan
Write-Host '    ███████╗╚██████╔╝██║ ╚═╝ ██║██║' -ForegroundColor Cyan
Write-Host '    ╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝' -ForegroundColor Cyan
Write-Host ''
Write-Host '           build-from-source installer' -ForegroundColor DarkGray
Write-Host '    Your AI coworker, built fresh from HEAD.' -ForegroundColor DarkGray
Write-Host ''

$Repo       = if ($env:REPO)    { $env:REPO }    else { 'ankurCES/OpenLaude' }
$Branch     = if ($env:BRANCH)  { $env:BRANCH }  else { 'main' }
$WorkDir    = if ($env:WORK_DIR){ $env:WORK_DIR }else { Join-Path $env:TEMP ("lumi-build-$PID") }
$GhToken    = $env:GITHUB_TOKEN

Write-Info "Repo:     $Repo@$Branch"
Write-Info "Work dir: $WorkDir"

# ─── Platform detection ──────────────────────────────────────────────────
Write-Step "Platform detection"

if (-not $IsWindows -and $PSVersionTable.PSEdition -ne 'Desktop') {
  Die "Use install-from-source.sh on macOS / Linux."
}

$arch = if ([Environment]::Is64BitOperatingSystem) {
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or
      $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
} else {
  Die "Unsupported arch: $env:PROCESSOR_ARCHITECTURE (Lumi needs 64-bit Windows)"
}
Write-Ok "Detected: windows/$arch"

# ─── Cleanup registration ────────────────────────────────────────────────
function Invoke-Cleanup {
  if ($env:SKIP_CLEANUP -eq '1') {
    Write-Host ''
    Write-Host "Kept $WorkDir for debugging" -ForegroundColor DarkGray
    return
  }
  if ($env:KEEP_SOURCE -and (Test-Path $WorkDir)) {
    $dest = $env:KEEP_SOURCE
    if (Test-Path $dest) {
      Write-Warn2 "$dest already exists; leaving $WorkDir in place"
    } else {
      New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
      Move-Item $WorkDir $dest
      Write-Ok "Source tree moved to $dest"
    }
  } elseif (Test-Path $WorkDir) {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "✓ Temp source removed" -ForegroundColor DarkGray
  }
}

# Register cleanup for all exit paths
try {
  # ─── Dependency checks + auto-install ────────────────────────────────
  Write-Step "Checking build dependencies"

  function Test-Cmd { param($name) [bool](Get-Command $name -ErrorAction SilentlyContinue) }
  function Install-Winget {
    param([string[]]$Packages)
    if (-not (Test-Cmd 'winget')) {
      Die "winget not available. Install App Installer from the Microsoft Store, then re-run."
    }
    foreach ($pkg in $Packages) {
      winget install --id $pkg -e --silent --accept-package-agreements --accept-source-agreements
      if ($LASTEXITCODE -ne 0) { Die "winget install failed for $pkg" }
    }
  }

  # git
  if (Test-Cmd 'git') {
    $gitVer = (git --version) -replace '^git version ',''
    Write-Ok "git $gitVer"
  } else {
    Write-Warn2 "git not found — installing via winget"
    Install-Winget -Packages @('Git.Git')
    # Refresh PATH for this session
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
    if (-not (Test-Cmd 'git')) { Die "git install completed but not on PATH; restart shell and re-run" }
    Write-Ok "git installed"
  }

  # node (≥ 20)
  function Test-NodeVersion {
    if (-not (Test-Cmd 'node')) { return $false }
    $v = (node -v) -replace '^v',''
    $major = [int]($v -split '\.')[0]
    return $major -ge 20
  }
  if (Test-NodeVersion) {
    Write-Ok "node $(node --version)"
  } else {
    Write-Warn2 "node < 20 or missing — installing Node.js 22 LTS via winget"
    Install-Winget -Packages @('OpenJS.NodeJS.LTS')
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
    if (-not (Test-NodeVersion)) { Die "node install did not land on PATH; restart shell and re-run" }
    Write-Ok "node $(node --version) installed"
  }

  # bun (via official installer script)
  if (Test-Cmd 'bun') {
    Write-Ok "bun $(bun --version)"
  } else {
    Write-Warn2 "bun not found — installing"
    powershell -c "irm bun.sh/install.ps1 | iex"
    $bunBin = Join-Path $env:USERPROFILE '.bun\bin'
    if (Test-Path $bunBin) {
      $env:Path = "$bunBin;$env:Path"
    }
    if (-not (Test-Cmd 'bun')) { Die "bun install failed" }
    Write-Ok "bun $(bun --version) installed"
  }

  # pnpm
  if (Test-Cmd 'pnpm') {
    Write-Ok "pnpm $(pnpm --version)"
  } else {
    Write-Warn2 "pnpm not found — installing via corepack"
    corepack enable 2>$null | Out-Null
    corepack prepare pnpm@10.33.0 --activate 2>$null | Out-Null
    if (-not (Test-Cmd 'pnpm')) {
      Write-Warn2 "corepack route failed — trying npm -g"
      npm install -g pnpm@10.33.0
    }
    if (-not (Test-Cmd 'pnpm')) { Die "pnpm install failed" }
    Write-Ok "pnpm $(pnpm --version)"
  }

  # ─── GitHub authentication ─────────────────────────────────────────────
  Write-Step "GitHub authentication"

  $AuthMethod = ''
  $CloneUrl   = ''

  function Test-GitHubToken {
    param([string]$Token)
    try {
      Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$Repo" `
        -Headers @{ Authorization = "token $Token"; 'User-Agent' = 'lumi-build-installer' } `
        -Method Get -ErrorAction Stop | Out-Null
      return $true
    } catch { return $false }
  }

  # 1. $env:GITHUB_TOKEN
  if ($GhToken -and (Test-GitHubToken $GhToken)) {
    $AuthMethod = 'env'
    $CloneUrl   = "https://$GhToken@github.com/$Repo.git"
    Write-Ok "Using GITHUB_TOKEN from environment"
  }

  # 2. gh CLI
  if (-not $AuthMethod -and (Test-Cmd 'gh')) {
    $ghStatus = (gh auth status 2>&1)
    if ($LASTEXITCODE -eq 0) {
      $null = gh repo view $Repo 2>&1
      if ($LASTEXITCODE -eq 0) {
        $AuthMethod = 'gh'
        Write-Ok "Using GitHub CLI (gh) authentication"
      } else {
        Write-Warn2 "gh authenticated but lacks access to $Repo"
      }
    }
  }

  # 3. Interactive PAT prompt
  if (-not $AuthMethod) {
    Write-Warn2 "No GitHub authentication detected."
    Write-Info "Create a PAT at:"
    Write-Info "  https://github.com/settings/tokens/new?scopes=repo&description=lumi-installer"
    Write-Info "Scope needed: 'repo' (full control of private repositories)"
    Write-Host ''
    while ($true) {
      $GhToken = Ask-Secret "GitHub Personal Access Token"
      if ([string]::IsNullOrWhiteSpace($GhToken)) {
        Die "A GitHub PAT is required to clone the private repo."
      }
      if (Test-GitHubToken $GhToken) {
        $AuthMethod = 'pat'
        $CloneUrl   = "https://$GhToken@github.com/$Repo.git"
        Write-Ok "Token validated"
        break
      }
      Write-Warn2 "Token invalid or no access to $Repo. Try again."
    }
  }

  # ─── Clone ─────────────────────────────────────────────────────────────
  Write-Step "Cloning $Repo@$Branch"

  if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
  New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

  switch ($AuthMethod) {
    'gh' {
      & gh repo clone $Repo $WorkDir -- --depth 1 --branch $Branch
    }
    default {
      & git clone --depth 1 --branch $Branch --recurse-submodules $CloneUrl $WorkDir
    }
  }
  if ($LASTEXITCODE -ne 0) { Die "git clone failed" }
  Write-Ok "Cloned to $WorkDir"

  # ─── Build ─────────────────────────────────────────────────────────────
  Write-Step "Installing engine + desktop dependencies"

  Push-Location $WorkDir
  try {
    if (Test-Path 'packages\lumi-engine\package.json') {
      Write-Info "pnpm install for lumi-engine"
      Push-Location 'packages\lumi-engine'
      try {
        pnpm install --frozen-lockfile
        if ($LASTEXITCODE -ne 0) { Die "pnpm install failed" }
      } finally { Pop-Location }
      Write-Ok "lumi-engine deps installed"
    }

    Write-Info "bun install for desktop"
    Push-Location 'apps\desktop'
    try {
      bun install
      if ($LASTEXITCODE -ne 0) { Die "bun install failed" }
    } finally { Pop-Location }
    Write-Ok "Desktop deps installed"

    Write-Step "Building the Lumi engine"
    Push-Location 'packages\lumi-engine'
    try {
      pnpm run build
      if ($LASTEXITCODE -ne 0) { Die "Engine build failed" }
    } finally { Pop-Location }
    Write-Ok "Engine built"

    Write-Step "Building the desktop app (this takes 3–5 min)"
    Push-Location 'apps\desktop'
    try {
      bun run dist:win
      if ($LASTEXITCODE -ne 0) { Die "Desktop build failed" }
    } finally { Pop-Location }
    Write-Ok "Desktop app built"

    # ─── Install ────────────────────────────────────────────────────────
    Write-Step "Installing Lumi"

    $outDir  = Join-Path $WorkDir 'apps\desktop\out'
    $installer = Get-ChildItem -Path $outDir -Filter '*.exe' -File |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First 1
    if (-not $installer) {
      Die "No NSIS installer (.exe) found in $outDir"
    }
    Write-Info "Installer: $($installer.Name) ($([math]::Round($installer.Length / 1MB)) MB)"

    if (Ask-YesNo "Run the NSIS installer now?" 'y') {
      # /S triggers NSIS silent mode. User doesn't get the UX screens,
      # but the install happens in-place without needing extra clicks.
      Write-Info "Starting silent install…"
      Start-Process -FilePath $installer.FullName -ArgumentList '/S' -Wait
      Write-Ok "Lumi installed"
    } else {
      Write-Warn2 "Skipped. Run the installer manually:"
      Write-Info "  $($installer.FullName)"
      $env:SKIP_CLEANUP = '1'
    }
  } finally {
    Pop-Location
  }

  # ─── Final banner ──────────────────────────────────────────────────────
  Write-Host ''
  Write-Host '              🌙  Lumi is ready.' -ForegroundColor Green
  Write-Host ''
  Write-Host '  Launch:  Start Menu → Lumi'
  Write-Host "  Docs:    https://github.com/$Repo/blob/main/README.md"
  Write-Host ''
} finally {
  Invoke-Cleanup
}
