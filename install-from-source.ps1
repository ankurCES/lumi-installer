# Lumi — build-from-source installer (Windows)
#
# Usage:
#   irm https://raw.githubusercontent.com/ankurCES/OpenLaude/main/install-from-source.ps1 | iex
#
# Bootstrap layer: install Bun + Node + pnpm + gh CLI if missing,
# fetch the Ink TUI (install-from-source.tsx), and hand off to it.
# Once the prereqs are met, everything user-visible happens inside
# the Ink app — same bordered progress region + animated moonrunner
# the macOS / Linux bash bootstrap targets. The Ink app does its own
# gh auth detection / PAT fallback; this script only ensures gh CLI
# is *available* for that detection to work.

$ErrorActionPreference = 'Stop'

# Repo + Branch point at the SOURCE repo the Ink installer will git-
# clone (private, requires auth — handled inside the Ink app's auth
# flow). TsxRepo + TsxBranch point at the public mirror this script
# self-references to fetch the Ink TSX without auth.
$Repo      = if ($env:REPO) { $env:REPO } else { 'ankurCES/OpenLaude' }
$Branch    = if ($env:BRANCH) { $env:BRANCH } else { 'main' }
$TsxRepo   = if ($env:TSX_REPO) { $env:TSX_REPO } else { 'ankurCES/lumi-installer' }
$TsxBranch = if ($env:TSX_BRANCH) { $env:TSX_BRANCH } else { 'main' }
$TsxUrl    = if ($env:TSX_URL) { $env:TSX_URL } else {
  "https://raw.githubusercontent.com/$TsxRepo/$TsxBranch/install-from-source.tsx"
}

function Write-Step($msg) { Write-Host "● $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "  $msg" -ForegroundColor DarkGray }
function Write-WarnLine($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Die($msg) {
  Write-Host "✗ $msg" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "🌙 Lumi build-from-source bootstrap" -ForegroundColor Cyan
Write-Host ""
Write-Info "repo: $Repo@$Branch"

# ─── Platform sanity check ────────────────────────────────────────────────
if (-not $IsWindows -and ([System.Environment]::OSVersion.Platform -ne 'Win32NT')) {
  Die "This script is for Windows. Use install-from-source.sh on macOS / Linux."
}
$archLabel = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
Write-Ok "platform: windows/$archLabel"

# ─── Prerequisites ────────────────────────────────────────────────────────
Write-Step "Checking build-tool prerequisites"

function Has-Command($name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# Bun — install via the official PowerShell one-liner. Drops into
# %USERPROFILE%\.bun\bin.
if (-not (Has-Command 'bun')) {
  Write-WarnLine "bun not found — installing"
  try {
    Invoke-RestMethod 'https://bun.sh/install.ps1' | Invoke-Expression
  } catch {
    # Surface the upstream exception detail — the previous catch
    # block swallowed it and emitted only "bun install failed", which
    # gave the user nothing useful to act on.
    Die "bun install failed: $($_.Exception.Message). See https://bun.sh/ for manual install."
  }
  $bunBin = Join-Path $env:USERPROFILE '.bun\bin'
  if (Test-Path $bunBin) {
    $env:PATH = "$bunBin;$env:PATH"
  }
  if (-not (Has-Command 'bun')) {
    Die "bun installed but not on PATH; restart PowerShell and rerun"
  }
}
Write-Ok "bun $(bun --version)"

# Node ≥ 20 — required by the lumi-engine pnpm workspace.
function Get-NodeMajor {
  try {
    $v = (node -v) -replace '^v', ''
    return [int]($v.Split('.')[0])
  } catch {
    return 0
  }
}

if (Has-Command 'node') {
  $nodeMajor = Get-NodeMajor
  if ($nodeMajor -lt 20) {
    Write-WarnLine "node $(node -v) is too old (need ≥ 20)"
    if (Has-Command 'winget') {
      winget install OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements `
        | Out-Null
    } elseif (Has-Command 'choco') {
      choco install nodejs-lts -y | Out-Null
    } else {
      Die "Node.js ≥ 20 required. Install from https://nodejs.org/ and rerun."
    }
  }
} else {
  Write-WarnLine "node not found — installing"
  if (Has-Command 'winget') {
    winget install OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements `
      | Out-Null
  } elseif (Has-Command 'choco') {
    choco install nodejs-lts -y | Out-Null
  } else {
    Die "Node.js ≥ 20 required. Install from https://nodejs.org/ and rerun."
  }
}
if (-not (Has-Command 'node') -or (Get-NodeMajor) -lt 20) {
  Die "Node.js ≥ 20 install did not land on PATH; restart PowerShell and rerun."
}
Write-Ok "node $(node --version)"

# pnpm — corepack ships with Node 20+.
if (-not (Has-Command 'pnpm')) {
  Write-WarnLine "pnpm not found — activating via corepack"
  try {
    corepack enable | Out-Null
    corepack prepare pnpm@10.33.0 --activate | Out-Null
  } catch {
    Die "corepack failed to activate pnpm; install pnpm manually (https://pnpm.io/installation)"
  }
}
Write-Ok "pnpm $(pnpm --version)"

# gh CLI — best-effort. The Ink app's auth picker uses `gh repo view`
# to test access. Installing gh here means a user who already signed in
# elsewhere gets the gh option in the Ink picker; if installation
# fails, no big deal — the Ink app still offers PAT and SSH paths.
if (-not (Has-Command 'gh')) {
  Write-WarnLine "gh CLI not found — attempting install (best-effort)"
  if (Has-Command 'winget') {
    winget install GitHub.cli --silent --accept-source-agreements --accept-package-agreements `
      | Out-Null 2>&1
  } elseif (Has-Command 'choco') {
    choco install gh -y | Out-Null 2>&1
  } else {
    Write-Info "neither winget nor choco available; the Ink installer will fall back to PAT auth"
  }
}
if (Has-Command 'gh') {
  Write-Ok "gh $(gh --version | Select-Object -First 1)"
} else {
  Write-Info "gh CLI not installed — Ink installer will use PAT or SSH auth"
}

# ─── Stage Ink installer ──────────────────────────────────────────────────
Write-Step "Staging Ink installer"

$Work = Join-Path $env:TEMP "lumi-installer-$PID"
New-Item -ItemType Directory -Force -Path $Work | Out-Null

$cleanupBlock = {
  if ($env:SKIP_CLEANUP -ne '1') {
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
  } else {
    Write-Host "  kept $Work (SKIP_CLEANUP=1)" -ForegroundColor DarkGray
  }
}
Register-EngineEvent PowerShell.Exiting -Action $cleanupBlock | Out-Null

try {
  Invoke-WebRequest -Uri $TsxUrl -OutFile (Join-Path $Work 'install-from-source.tsx') -UseBasicParsing
} catch {
  Die "Could not fetch installer from $TsxUrl"
}

$pkgJson = @'
{
  "name": "lumi-installer",
  "type": "module",
  "private": true,
  "dependencies": {
    "ink": "^5.1.0",
    "react": "^18.3.1",
    "ink-select-input": "^6.0.0",
    "ink-text-input": "^6.0.0",
    "ink-spinner": "^5.0.0"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "@types/react": "^18.3.12"
  }
}
'@
Set-Content -Path (Join-Path $Work 'package.json') -Value $pkgJson -Encoding UTF8

Push-Location $Work
try {
  # PowerShell's $ErrorActionPreference='Stop' treats ANY native stderr
  # write as a NativeCommandError and aborts — bun emits "Resolving
  # dependencies" to stderr as routine progress, which trips that.
  # Locally drop to 'Continue' for the duration of the install + use
  # $LASTEXITCODE for the actual success check. Reported by user on
  # Windows fresh install ("bun : Resolving dependencies … RemoteException").
  $prevPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & bun install --no-progress 2>&1 | Out-Null
  } finally {
    $ErrorActionPreference = $prevPref
  }
  if ($LASTEXITCODE -ne 0) { Die "Failed to install Ink deps in $Work (exit $LASTEXITCODE)" }
} finally {
  Pop-Location
}

Write-Ok "bootstrap ready"
Write-Host ""

# ─── Hand off to Ink installer ────────────────────────────────────────────
Set-Location $Work

# Clear the terminal so the bootstrap's prereq-check output doesn't sit
# above the Ink UI. `Clear-Host` is the PowerShell-canonical version of
# the bash printf '\033[2J\033[H' clear we use on macOS / Linux. Only
# clear when running interactively — CI / piped invocations get plain
# output without the ANSI control sequences.
if ($Host.UI.SupportsVirtualTerminal -or $Host.Name -eq 'ConsoleHost') {
  Clear-Host
}

& bun install-from-source.tsx @args
$bunExit = $LASTEXITCODE
& $cleanupBlock
exit $bunExit
