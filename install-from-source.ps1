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

# ─── TUI scaffolding ─────────────────────────────────────────────────────
#
# Moonlit dino-game animation + scrollable log region for long
# non-interactive phases (clone, dependency install, build). PowerShell
# parallel of the bash version in install-from-source.sh.
#
# Uses ANSI escape sequences directly — they're supported in modern
# Windows Terminal and Windows 10/11's enhanced conhost. When the
# terminal is too small, doesn't render escapes (legacy conhost),
# or the user opts out via $env:OPENLAUDE_NO_TUI=1, we fall back to
# the static banner with no animation.
#
# Background animation via Start-ThreadJob (lightweight runspace) so
# the parent script stays unblocked. The thread writes to the
# console with [System.Console]::Write — that bypasses Write-Host's
# runspace coupling and renders directly to the terminal regardless
# of which runspace the call originated in.

$ESC = [char]27
$script:USE_TUI = $false
$script:TermLines = 0
$script:TermCols = 0
$script:AnimJob = $null
$script:SkyTopRow = 0
$script:SkyHeight = 4
$script:GroundRow = 0
$script:LogTopRow = 0
$script:LogBottomRow = 0

function Test-TuiSupported {
  if ($env:OPENLAUDE_NO_TUI -eq '1') { return $false }
  try {
    $size = $Host.UI.RawUI.WindowSize
    if (-not $size) { return $false }
    $script:TermLines = $size.Height
    $script:TermCols = $size.Width
  } catch {
    return $false
  }
  # Need height for banner (12) + sky (4) + ground (1) + min log (8)
  if ($script:TermLines -lt 25) { return $false }
  if ($script:TermCols -lt 60) { return $false }
  return $true
}

function Tui-Init {
  if (-not (Test-TuiSupported)) { return }
  $script:SkyTopRow = 14
  $script:GroundRow = $script:SkyTopRow + $script:SkyHeight
  $script:LogTopRow = $script:GroundRow + 2
  $script:LogBottomRow = $script:TermLines - 1

  # Hide cursor + clear screen + draw banner inline so it sits
  # statically above the animation block.
  [System.Console]::Write("$ESC[?25l$ESC[2J$ESC[H")
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

  # Ground line, gold-tinted
  [System.Console]::Write("$ESC[$($script:GroundRow);1H$ESC[33m")
  $i = 1
  while ($i -le $script:TermCols) {
    [System.Console]::Write('─')
    $i++
  }
  [System.Console]::Write("$ESC[0m")

  # Lock the scroll region to the log block. `\n` from foreground
  # writes inside this range scrolls only the region — banner +
  # animation rows stay pinned.
  [System.Console]::Write("$ESC[$($script:LogTopRow);$($script:LogBottomRow)r")
  [System.Console]::Write("$ESC[$($script:LogBottomRow);1H")

  # Spawn the animation thread. Start-ThreadJob is lighter than
  # Start-Job (no separate process); falls back gracefully if
  # ThreadJob module isn't available.
  if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $script:AnimJob = Start-ThreadJob -ScriptBlock {
      param($skyTop, $skyHeight, $groundRow, $cols)
      $ESC = [char]27
      $moon_x = 8
      $base_y = $groundRow - 1
      $moon_y = $base_y
      $jump_phase = 0
      $obstacle_x = $cols - 4
      $frame = 0
      $sparkles = @()
      for ($i = 0; $i -lt 4; $i++) { $sparkles += ($cols - $i * 17 - 5) }
      $arc = @(0, 1, 2, 3, 4, 4, 4, 4, 3, 2, 1, 0, 0, 0)

      while ($true) {
        # Auto-jump physics — same arc as bash version.
        if ($jump_phase -eq 0 -and
            $obstacle_x -le ($moon_x + 6) -and
            $obstacle_x -gt $moon_x) {
          $jump_phase = 1
        }
        if ($jump_phase -gt 0) {
          $moon_y = $base_y - $arc[$jump_phase - 1]
          $jump_phase++
          if ($jump_phase -gt 14) {
            $jump_phase = 0
            $moon_y = $base_y
          }
        }

        # Scroll obstacle + sparkles
        $obstacle_x--
        if ($obstacle_x -lt 2) { $obstacle_x = $cols - 4 }
        if (($frame % 3) -eq 0) {
          for ($s = 0; $s -lt $sparkles.Count; $s++) {
            $sparkles[$s]--
            if ($sparkles[$s] -lt 2) { $sparkles[$s] = $cols - 4 }
          }
        }

        # Repaint sky region
        for ($r = $skyTop; $r -lt $groundRow; $r++) {
          $pad = ' ' * ($cols - 2)
          [System.Console]::Write("$ESC[$r;1H$pad")
        }
        # Sparkles at varying y for parallax depth
        for ($s = 0; $s -lt $sparkles.Count; $s++) {
          $sy = $skyTop + (($s * 7) % $skyHeight)
          if ($sy -ge $groundRow) { $sy = $groundRow - 1 }
          [System.Console]::Write("$ESC[$sy;$($sparkles[$s])H$ESC[2;36m·$ESC[0m")
        }
        # Asteroid
        [System.Console]::Write("$ESC[$base_y;$obstacle_x" + "H$ESC[33m✦$ESC[0m")
        # Moon — always 🌙 on Windows (modern terminals render emoji)
        [System.Console]::Write("$ESC[$moon_y;$moon_x" + "H🌙")
        [System.Console]::Out.Flush()

        $frame++
        Start-Sleep -Milliseconds 75
      }
    } -ArgumentList $script:SkyTopRow, $script:SkyHeight, $script:GroundRow, $script:TermCols
    $script:USE_TUI = $true
  }
}

function Tui-LogPosition {
  if ($script:USE_TUI) {
    [System.Console]::Write("$ESC[$($script:LogBottomRow);1H")
  }
}

# Stop the animation, reset the scroll region, show the cursor.
# Used around every Ask-* helper so prompts render normally and
# the user's typing doesn't fight the moon for the same row.
function Tui-Pause {
  if (-not $script:USE_TUI) { return }
  if ($script:AnimJob) {
    $script:AnimJob | Stop-Job -ErrorAction SilentlyContinue
    $script:AnimJob | Remove-Job -Force -ErrorAction SilentlyContinue
    $script:AnimJob = $null
  }
  [System.Console]::Write("$ESC[r$ESC[?25h")
  [System.Console]::Write("$ESC[$($script:TermLines);1H")
  Write-Host ''
}

# Re-arm the TUI after a prompt. The killed subshell's frozen frame
# vanishes and a fresh thread redraws — same UX as the bash version.
function Tui-Resume {
  if (-not $script:USE_TUI) { return }
  if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) { return }
  [System.Console]::Write("$ESC[?25l")
  [System.Console]::Write("$ESC[$($script:LogTopRow);$($script:LogBottomRow)r")
  [System.Console]::Write("$ESC[$($script:LogBottomRow);1H")
  $script:AnimJob = Start-ThreadJob -ScriptBlock {
    param($skyTop, $skyHeight, $groundRow, $cols)
    $ESC = [char]27
    $moon_x = 8
    $base_y = $groundRow - 1
    $moon_y = $base_y
    $jump_phase = 0
    $obstacle_x = $cols - 4
    $frame = 0
    $sparkles = @()
    for ($i = 0; $i -lt 4; $i++) { $sparkles += ($cols - $i * 17 - 5) }
    $arc = @(0, 1, 2, 3, 4, 4, 4, 4, 3, 2, 1, 0, 0, 0)
    while ($true) {
      if ($jump_phase -eq 0 -and $obstacle_x -le ($moon_x + 6) -and $obstacle_x -gt $moon_x) {
        $jump_phase = 1
      }
      if ($jump_phase -gt 0) {
        $moon_y = $base_y - $arc[$jump_phase - 1]
        $jump_phase++
        if ($jump_phase -gt 14) { $jump_phase = 0; $moon_y = $base_y }
      }
      $obstacle_x--
      if ($obstacle_x -lt 2) { $obstacle_x = $cols - 4 }
      if (($frame % 3) -eq 0) {
        for ($s = 0; $s -lt $sparkles.Count; $s++) {
          $sparkles[$s]--
          if ($sparkles[$s] -lt 2) { $sparkles[$s] = $cols - 4 }
        }
      }
      for ($r = $skyTop; $r -lt $groundRow; $r++) {
        $pad = ' ' * ($cols - 2)
        [System.Console]::Write("$ESC[$r;1H$pad")
      }
      for ($s = 0; $s -lt $sparkles.Count; $s++) {
        $sy = $skyTop + (($s * 7) % $skyHeight)
        if ($sy -ge $groundRow) { $sy = $groundRow - 1 }
        [System.Console]::Write("$ESC[$sy;$($sparkles[$s])H$ESC[2;36m·$ESC[0m")
      }
      [System.Console]::Write("$ESC[$base_y;$obstacle_x" + "H$ESC[33m✦$ESC[0m")
      [System.Console]::Write("$ESC[$moon_y;$moon_x" + "H🌙")
      [System.Console]::Out.Flush()
      $frame++
      Start-Sleep -Milliseconds 75
    }
  } -ArgumentList $script:SkyTopRow, $script:SkyHeight, $script:GroundRow, $script:TermCols
}

# Final cleanup — called from the main `Invoke-Cleanup` so it fires
# on success, error, and trap exits. Idempotent.
function Tui-Teardown {
  if (-not $script:USE_TUI) { return }
  if ($script:AnimJob) {
    $script:AnimJob | Stop-Job -ErrorAction SilentlyContinue
    $script:AnimJob | Remove-Job -Force -ErrorAction SilentlyContinue
    $script:AnimJob = $null
  }
  [System.Console]::Write("$ESC[r$ESC[?25h")
  [System.Console]::Write("$ESC[$($script:TermLines);1H")
  Write-Host ''
  $script:USE_TUI = $false
}

# ─── Styling helpers ─────────────────────────────────────────────────────
function Write-Step  { param($msg) Tui-LogPosition; Write-Host "`n🌙 $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Tui-LogPosition; Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn2 { param($msg) Tui-LogPosition; Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Info  { param($msg) Tui-LogPosition; Write-Host "  · $msg" -ForegroundColor DarkGray }
function Die {
  param($msg)
  Tui-LogPosition
  Write-Host "`n  ✗ $msg`n" -ForegroundColor Red
  if ($script:USE_TUI) { Start-Sleep -Seconds 1 }
  exit 1
}

function Ask-Input {
  param([string]$prompt, [string]$default = '')
  Tui-Pause
  try {
    $hint = if ($default) { " [$default]" } else { '' }
    $ans = Read-Host "? $prompt$hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $default }
    return $ans
  } finally {
    Tui-Resume
  }
}

function Ask-Secret {
  param([string]$prompt)
  Tui-Pause
  try {
    $secure = Read-Host "? $prompt" -AsSecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
  } finally {
    Tui-Resume
  }
}

function Ask-YesNo {
  param([string]$prompt, [string]$default = 'y')
  Tui-Pause
  try {
    $hint = if ($default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "? $prompt $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $default }
    return ($ans -match '^[Yy]')
  } finally {
    Tui-Resume
  }
}

# ─── Banner / TUI init ──────────────────────────────────────────────────
# Try to bring the moonlit dino-game TUI up (Windows Terminal +
# Windows 10/11 enhanced conhost render the ANSI escapes). When the
# terminal is too small, doesn't support escapes, or the user passed
# $env:OPENLAUDE_NO_TUI=1, we fall back to the plain banner — same
# identity, no animation. The TUI version draws the same banner inline
# so the moon + LUMI block art appears regardless of mode.
Tui-Init
if (-not $script:USE_TUI) {
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
}

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
  # Tear the TUI down FIRST so cleanup output isn't trapped inside
  # the now-stale scroll region or hidden behind the animation.
  # Idempotent — no-op when the TUI isn't active.
  Tui-Teardown
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
  Write-Step "Installing workspace dependencies"

  Push-Location $WorkDir
  try {
    # 1. Root pnpm workspace — installs + symlinks every `packages/*`
    #    EXCEPT `lumi-engine` (excluded via `pnpm-workspace.yaml`). This
    #    is what produces `node_modules\@lumi\{shared,config,
    #    engine-bridge,setup,…}` and the symlinks the desktop's
    #    relative imports rely on (e.g. gatewaySingleton.ts →
    #    packages\engine-bridge\dist\index.js).
    Write-Info "pnpm install (root workspace)"
    pnpm install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) { Die "Root pnpm install failed" }
    Write-Ok "Root workspace deps installed"

    # 2. Lumi engine — separate workspace (grafted upstream dep graph).
    if (Test-Path 'packages\lumi-engine\package.json') {
      Write-Info "pnpm install for lumi-engine"
      Push-Location 'packages\lumi-engine'
      try {
        pnpm install --frozen-lockfile
        if ($LASTEXITCODE -ne 0) { Die "Engine pnpm install failed" }
      } finally { Pop-Location }
      Write-Ok "lumi-engine deps installed"
    }

    # 3. Desktop app — separate bun lockfile.
    Write-Info "bun install for desktop"
    Push-Location 'apps\desktop'
    try {
      bun install
      if ($LASTEXITCODE -ne 0) { Die "Desktop bun install failed" }
    } finally { Pop-Location }
    Write-Ok "Desktop deps installed"

    Write-Step "Building workspace packages"
    # 4. Build every `@lumi/*` root workspace package (shared, config,
    #    engine-bridge, setup — all `tsc -b`). `pnpm -r build` walks the
    #    workspace dep graph in topological order.
    Write-Info "pnpm -r build (shared / config / engine-bridge / setup …)"
    pnpm -r build
    if ($LASTEXITCODE -ne 0) { Die "Workspace package builds failed" }
    Write-Ok "Workspace packages built"

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

  # ─── Auto-launch the freshly-installed app ────────────────────────────
  # Parity with the bash installer's `launch_lumi_app` step. The in-app
  # "Install Update" flow expects this script to bring Lumi back up
  # automatically — otherwise the user is left staring at a closed app
  # after the NSIS silent install finishes. Best-effort: looks in the
  # standard NSIS install destination (Local AppData) plus the system-
  # wide Program Files path and starts the first match. Silent no-op
  # when neither exists or when $env:NO_LAUNCH=1.
  if ($env:NO_LAUNCH -ne '1') {
    $candidates = @(
      (Join-Path $env:LOCALAPPDATA 'Programs\Lumi\Lumi.exe'),
      (Join-Path ${env:ProgramFiles} 'Lumi\Lumi.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Lumi\Lumi.exe')
    )
    foreach ($exe in $candidates) {
      if ($exe -and (Test-Path $exe)) {
        Write-Info "launching $exe..."
        Start-Process -FilePath $exe -ErrorAction SilentlyContinue
        break
      }
    }
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
