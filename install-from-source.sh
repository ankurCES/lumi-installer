#!/usr/bin/env bash
#
# Lumi — build-from-source installer (macOS + Linux)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ankurCES/OpenLaude/main/install-from-source.sh | bash
#
# Or, to preview before running:
#   curl -fsSL https://raw.githubusercontent.com/ankurCES/OpenLaude/main/install-from-source.sh -o install.sh
#   less install.sh && bash install.sh
#
# What it does:
#   1. Detects your platform (macOS / Linux; arm64 / x64).
#   2. Installs missing build deps (git, bun, pnpm, node).
#   3. Authenticates to GitHub for the private repo (gh CLI → PAT
#      fallback → SSH).
#   4. Clones ankurCES/OpenLaude to a temp directory (shallow).
#   5. Installs dependencies (bun + pnpm).
#   6. Builds the Lumi engine, then the desktop app (`dist:mac` /
#      `dist:linux`).
#   7. Installs the resulting app into `/Applications` (macOS) or
#      `~/.local/share/Lumi` (Linux).
#   8. Deletes the temp clone on success or failure.
#
# Environment overrides:
#   REPO           GitHub owner/repo (default: ankurCES/OpenLaude)
#   BRANCH         git branch to clone (default: main)
#   WORK_DIR       build scratch directory (default: $TMPDIR/lumi-build-<pid>)
#   GITHUB_TOKEN   pre-supplied PAT (skips interactive prompt)
#   SKIP_CLEANUP=1 keep $WORK_DIR around after install (for debugging)
#   KEEP_SOURCE=<path> copy the clone to <path> before cleanup (lets
#                 you keep a working tree while still wiping the temp)

set -u

# ─── ANSI styling ────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
  CYAN=$'\033[0;36m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  RED=$'\033[0;31m'
  MAGENTA=$'\033[0;35m'
else
  BOLD='' DIM='' RESET='' CYAN='' GREEN='' YELLOW='' RED='' MAGENTA=''
fi

# ─── TUI scaffolding ─────────────────────────────────────────────────────
#
# Moonlit dino-game animation + scrollable log region for long
# non-interactive phases (clone, dependency install, builds). The
# tricky part vs. the simpler scripts/install.sh case is that this
# installer has interactive prompts (GitHub auth, install-target
# confirmations) that need stdin and a fixed cursor position. We
# deal with that via `tui_pause` / `tui_resume` wrapped around every
# `ask_*` helper: pausing kills the animation subshell, resets the
# scroll region, and shows the cursor so the prompt renders normally;
# resuming hides the cursor, re-installs the scroll region, and
# spawns a fresh animation. The frozen frame between pause/resume is
# fine — the moon picks up where it left off.

USE_TUI=0
TERM_LINES=0
TERM_COLS=0
ANIM_PID=""
SKY_TOP_ROW=0
SKY_HEIGHT=4
GROUND_ROW=0
LOG_TOP_ROW=0
LOG_BOTTOM_ROW=0
NO_TUI="${OPENLAUDE_NO_TUI:-${NO_TUI:-0}}"

detect_tui() {
  # Skip the TUI when stdout isn't a terminal (CI / file redirect),
  # when the user opted out, or when the terminal is too small to
  # fit the banner + animation + a useful log region.
  if [[ "$NO_TUI" == "1" ]]; then return 1; fi
  if [[ ! -t 1 ]]; then return 1; fi
  if ! command -v tput >/dev/null 2>&1; then return 1; fi
  TERM_LINES=$(tput lines 2>/dev/null || echo 0)
  TERM_COLS=$(tput cols 2>/dev/null || echo 0)
  # Need height for banner (12) + sky (4) + ground (1) + min log (8)
  if [[ "$TERM_LINES" -lt 25 || "$TERM_COLS" -lt 60 ]]; then return 1; fi
  return 0
}

# Background animation subshell. Uses absolute cursor positioning
# (`tput cup ROW COL` via `\033[%d;%dH`) so concurrent foreground log
# writes don't fight the cursor — each writer just declares where it
# wants to draw. Reads no input; the parent kills it on pause / exit.
animation_loop() {
  local moon_x=8
  local base_y="$((GROUND_ROW - 1))"
  local moon_y="$base_y"
  local jump_phase=0
  local obstacle_x=$((TERM_COLS - 4))
  local frame=0
  local sparkle_xs=()
  local i=0
  while [[ "$i" -lt 4 ]]; do
    sparkle_xs+=( $((TERM_COLS - i * 17 - 5)) )
    i=$((i + 1))
  done

  draw_at() {
    printf '\033[%d;%dH%s' "$1" "$2" "$3"
  }
  clear_at() {
    local pad
    pad=$(printf '%*s' "$3" '')
    printf '\033[%d;%dH%s' "$1" "$2" "$pad"
  }

  trap 'exit 0' TERM INT

  while :; do
    # ── Auto-jump physics ─────────────────────────────────────────
    if [[ "$jump_phase" -eq 0 \
          && "$obstacle_x" -le $((moon_x + 6)) \
          && "$obstacle_x" -gt "$moon_x" ]]; then
      jump_phase=1
    fi
    if [[ "$jump_phase" -gt 0 ]]; then
      local arc=(0 1 2 3 4 4 4 4 3 2 1 0 0 0)
      moon_y=$((base_y - arc[jump_phase - 1]))
      jump_phase=$((jump_phase + 1))
      if [[ "$jump_phase" -gt 14 ]]; then
        jump_phase=0
        moon_y="$base_y"
      fi
    fi

    # ── Scroll obstacle + sparkles ────────────────────────────────
    obstacle_x=$((obstacle_x - 1))
    if [[ "$obstacle_x" -lt 2 ]]; then
      obstacle_x=$((TERM_COLS - 4))
    fi
    if [[ $((frame % 3)) -eq 0 ]]; then
      local s=0
      while [[ "$s" -lt "${#sparkle_xs[@]}" ]]; do
        sparkle_xs[s]=$((sparkle_xs[s] - 1))
        if [[ "${sparkle_xs[s]}" -lt 2 ]]; then
          sparkle_xs[s]=$((TERM_COLS - 4))
        fi
        s=$((s + 1))
      done
    fi

    # ── Repaint sky each frame (cheap) ────────────────────────────
    local r="$SKY_TOP_ROW"
    while [[ "$r" -lt "$GROUND_ROW" ]]; do
      clear_at "$r" 1 "$((TERM_COLS - 2))"
      r=$((r + 1))
    done
    local s=0
    while [[ "$s" -lt "${#sparkle_xs[@]}" ]]; do
      local sy=$((SKY_TOP_ROW + (s * 7) % SKY_HEIGHT))
      [[ "$sy" -ge "$GROUND_ROW" ]] && sy=$((GROUND_ROW - 1))
      draw_at "$sy" "${sparkle_xs[s]}" $'\033[2;36m·\033[0m'
      s=$((s + 1))
    done
    draw_at "$base_y" "$obstacle_x" $'\033[33m✦\033[0m'
    # 🌙 emoji on UTF-8 locales, fall back to crescent glyph
    local moon_glyph='☾'
    case "${LC_ALL:-${LANG:-}}" in
      *UTF-8*|*utf8*) moon_glyph='🌙' ;;
    esac
    draw_at "$moon_y" "$moon_x" "$moon_glyph"

    frame=$((frame + 1))
    sleep 0.075
  done
}

# Position the cursor at the bottom of the log scroll region so the
# next `\n` pushes the region up by one line. No-op when the TUI
# isn't active.
log_position() {
  if [[ "$USE_TUI" == "1" ]]; then
    printf '\033[%d;1H' "$LOG_BOTTOM_ROW"
  fi
}

# Bring the TUI up. Layout, computed from terminal height:
#   banner (rows 1-12, drawn directly here)
#   blank row
#   3 rows sky
#   1 row ground
#   1 blank row
#   log scroll region down to LINES-1
tui_init() {
  if ! detect_tui; then
    return
  fi
  USE_TUI=1
  SKY_TOP_ROW=14
  GROUND_ROW=$((SKY_TOP_ROW + SKY_HEIGHT))
  LOG_TOP_ROW=$((GROUND_ROW + 2))
  LOG_BOTTOM_ROW=$((TERM_LINES - 1))

  # Hide cursor + clear screen + draw the existing banner inline so
  # it sits above the animation without needing a second printf-block
  # later. We re-implement the banner here (rather than calling out
  # to a helper) so the layout numbers above stay self-contained.
  printf '\033[?25l\033[2J\033[H'
  printf '\n%s                ·  ✦  🌙  ✦  ·%s\n\n' "${MAGENTA}" "${RESET}"
  printf '%s    ██╗     ██╗   ██╗███╗   ███╗██╗%s\n'    "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ██║     ██║   ██║████╗ ████║██║%s\n'    "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ██║     ██║   ██║██╔████╔██║██║%s\n'    "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ██║     ██║   ██║██║╚██╔╝██║██║%s\n'    "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ███████╗╚██████╔╝██║ ╚═╝ ██║██║%s\n'    "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝%s\n\n'  "${BOLD}${CYAN}" "${RESET}"
  printf '%s           build-from-source installer%s\n' "${DIM}" "${RESET}"

  # Ground line, gold-tinted to match the brand
  printf '\033[%d;1H%s' "$GROUND_ROW" "$YELLOW"
  local i=1
  while [[ "$i" -le "$TERM_COLS" ]]; do
    printf '─'
    i=$((i + 1))
  done
  printf '%s' "$RESET"

  # Lock the scroll region to the log block. `\n` from foreground
  # writes inside this range scrolls only the region — banner +
  # animation rows stay pinned.
  printf '\033[%d;%dr' "$LOG_TOP_ROW" "$LOG_BOTTOM_ROW"
  printf '\033[%d;1H' "$LOG_BOTTOM_ROW"

  ( animation_loop ) &
  ANIM_PID=$!
}

# Stop the animation, reset the scroll region, show the cursor.
# Used by every `ask_*` helper so prompts render in normal full-
# screen mode and the user's typed input doesn't compete with the
# moon's row positioning.
tui_pause() {
  if [[ "$USE_TUI" != "1" ]]; then return; fi
  if [[ -n "$ANIM_PID" ]]; then
    kill "$ANIM_PID" 2>/dev/null || true
    wait "$ANIM_PID" 2>/dev/null || true
    ANIM_PID=""
  fi
  # Reset scroll region and show cursor
  printf '\033[r\033[?25h'
  # Park cursor below the log region (or wherever the next free row
  # is) so the prompt prints into a sane spot
  printf '\033[%d;1H\n' "$TERM_LINES"
}

# Re-arm the TUI after a prompt completes. The frozen frame from
# the killed subshell vanishes and a fresh animation_loop redraws
# from current state — operator sees the moon resume mid-jump if
# they were lucky with the timing.
tui_resume() {
  if [[ "$USE_TUI" != "1" ]]; then return; fi
  printf '\033[?25l'
  printf '\033[%d;%dr' "$LOG_TOP_ROW" "$LOG_BOTTOM_ROW"
  printf '\033[%d;1H' "$LOG_BOTTOM_ROW"
  ( animation_loop ) &
  ANIM_PID=$!
}

# Final cleanup — called from the main `cleanup` trap so it fires
# on success, error, INT, and TERM. Belt-and-suspenders kill of the
# animation subshell, reset of the scroll region, and cursor
# restoration so the user's terminal isn't left hijacked.
tui_teardown() {
  if [[ "$USE_TUI" != "1" ]]; then return; fi
  if [[ -n "$ANIM_PID" ]]; then
    kill "$ANIM_PID" 2>/dev/null || true
    wait "$ANIM_PID" 2>/dev/null || true
    ANIM_PID=""
  fi
  printf '\033[r\033[?25h'
  printf '\033[%d;1H\n' "$TERM_LINES"
  USE_TUI=0
}

step()  { log_position; printf '\n%s🌙 %s%s\n' "${BOLD}${CYAN}" "$1" "${RESET}"; }
ok()    { log_position; printf '  %s✓%s %s\n' "${GREEN}" "${RESET}" "$1"; }
warn()  { log_position; printf '  %s⚠%s %s\n' "${YELLOW}" "${RESET}" "$1"; }
info()  { log_position; printf '  %s·%s %s\n' "${DIM}" "${RESET}" "$1"; }
die()   {
  log_position
  printf '\n  %s✗%s %s\n\n' "${RED}" "${RESET}" "$1"
  # Linger so the user can read the failure before the TUI tears down.
  if [[ "$USE_TUI" == "1" ]]; then sleep 1; fi
  exit 1
}

ask_input() {
  # ask_input <prompt> [default]
  tui_pause
  local prompt=$1
  local default=${2:-}
  local ans
  if [[ -n "$default" ]]; then
    printf '%s? %s%s [%s]: ' "${BOLD}" "$prompt" "${RESET}" "${default}"
  else
    printf '%s? %s%s: ' "${BOLD}" "$prompt" "${RESET}"
  fi
  IFS= read -r ans < /dev/tty
  printf '%s' "${ans:-$default}"
  tui_resume
}

ask_secret() {
  tui_pause
  local prompt=$1
  local ans
  printf '%s? %s%s: ' "${BOLD}" "$prompt" "${RESET}"
  IFS= read -rs ans < /dev/tty
  echo
  printf '%s' "$ans"
  tui_resume
}

ask_yes_no() {
  # ask_yes_no <prompt> [default_y_or_n]
  tui_pause
  local prompt=$1
  local default=${2:-y}
  local hint="[y/N]"
  [[ "$default" == y ]] && hint="[Y/n]"
  local ans
  printf '%s? %s%s %s: ' "${BOLD}" "$prompt" "${RESET}" "$hint"
  IFS= read -r ans < /dev/tty
  ans=${ans:-$default}
  local rc=0
  [[ "$ans" =~ ^[Yy] ]] || rc=1
  tui_resume
  return "$rc"
}

# ─── Banner / TUI init ──────────────────────────────────────────────────
# Try to bring the moonlit dino-game TUI up. When the terminal is too
# small, isn't a TTY, or the user passed --no-tui, we fall back to the
# original static banner — same identity, no animation. The TUI version
# embeds the same banner inline so the moon + LUMI block art always sits
# at the top regardless of mode.
tui_init
if [[ "$USE_TUI" != "1" ]]; then
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  fi
  printf '\n'
  printf '%s                ·  ✦  🌙  ✦  ·%s\n'                  "${MAGENTA}" "${RESET}"
  printf '\n'
  printf '%s    ██╗     ██╗   ██╗███╗   ███╗██╗%s\n'             "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ██║     ██║   ██║████╗ ████║██║%s\n'             "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ██║     ██║   ██║██╔████╔██║██║%s\n'             "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ██║     ██║   ██║██║╚██╔╝██║██║%s\n'             "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ███████╗╚██████╔╝██║ ╚═╝ ██║██║%s\n'             "${BOLD}${CYAN}" "${RESET}"
  printf '%s    ╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝%s\n'             "${BOLD}${CYAN}" "${RESET}"
  printf '\n'
  printf '%s           build-from-source installer%s\n'          "${DIM}" "${RESET}"
  printf '%s    Your AI coworker, built fresh from HEAD.%s\n'    "${DIM}" "${RESET}"
  printf '\n'
fi

REPO="${REPO:-ankurCES/OpenLaude}"
BRANCH="${BRANCH:-main}"
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/lumi-build-$$}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

info "Repo:    ${REPO}@${BRANCH}"
info "Work dir: ${WORK_DIR}"

# ─── Platform detection ──────────────────────────────────────────────────
step "Platform detection"

PLATFORM=""
case "$(uname -s)" in
  Darwin) PLATFORM=mac ;;
  Linux)  PLATFORM=linux ;;
  *)      die "Unsupported OS: $(uname -s). Use install-from-source.ps1 on Windows." ;;
esac

ARCH=""
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x64 ;;
  *)             die "Unsupported arch: $(uname -m)" ;;
esac

ok "Detected: ${PLATFORM}/${ARCH}"

# ─── Cleanup trap ────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  # Tear the TUI down FIRST so the rest of cleanup's printf output isn't
  # confined to the now-stale scroll region (or hidden behind the
  # animation). Idempotent — no-op when the TUI isn't active.
  tui_teardown
  if [[ "${SKIP_CLEANUP:-0}" == "1" ]]; then
    printf '\n%sKept %s for debugging%s\n' "${DIM}" "$WORK_DIR" "${RESET}"
    exit $exit_code
  fi
  if [[ -n "${KEEP_SOURCE:-}" && -d "$WORK_DIR" ]]; then
    mkdir -p "$(dirname "$KEEP_SOURCE")"
    if [[ -d "$KEEP_SOURCE" ]]; then
      warn "$KEEP_SOURCE already exists; leaving $WORK_DIR in place"
    else
      mv "$WORK_DIR" "$KEEP_SOURCE"
      ok "Source tree moved to $KEEP_SOURCE"
    fi
  elif [[ -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
    printf '%s✓ Temp source removed%s\n' "${DIM}" "${RESET}"
  fi
  exit $exit_code
}
trap cleanup EXIT INT TERM

# ─── Dependency checks + auto-install ────────────────────────────────────
step "Checking build dependencies"

ensure_bun() {
  if command -v bun >/dev/null 2>&1; then
    ok "bun $(bun --version)"
    return
  fi
  warn "bun not found — installing"
  curl -fsSL https://bun.sh/install | bash > /dev/null
  # bun installer drops into ~/.bun/bin by default
  if [[ -d "$HOME/.bun/bin" ]]; then
    export PATH="$HOME/.bun/bin:$PATH"
  fi
  command -v bun >/dev/null 2>&1 || die "bun install failed; see https://bun.sh/"
  ok "bun $(bun --version) installed"
}

ensure_node() {
  if command -v node >/dev/null 2>&1; then
    local major
    major=$(node -v | sed 's/^v\([0-9]*\).*/\1/')
    if (( major >= 20 )); then
      ok "node $(node --version)"
      return
    fi
    warn "node $(node --version) is too old (need ≥ 20)"
  fi
  warn "node not found or too old — install Node.js 20+ via nvm, asdf, or your package manager"
  warn "macOS: brew install node@22  |  Linux: https://nodejs.org/en/download/"
  die "node ≥ 20 required"
}

ensure_pnpm() {
  if command -v pnpm >/dev/null 2>&1; then
    ok "pnpm $(pnpm --version)"
    return
  fi
  # Enable corepack-managed pnpm (bundled with node ≥ 16.9)
  if command -v corepack >/dev/null 2>&1; then
    warn "pnpm not found — enabling via corepack"
    corepack enable >/dev/null 2>&1 || true
    corepack prepare pnpm@10.33.0 --activate >/dev/null 2>&1 || true
  fi
  if ! command -v pnpm >/dev/null 2>&1; then
    warn "pnpm still missing — installing via npm"
    npm install -g pnpm@10.33.0 >/dev/null 2>&1 || die "pnpm install failed"
  fi
  ok "pnpm $(pnpm --version)"
}

command -v git >/dev/null 2>&1 || die "git is required (macOS: xcode-select --install)"
ok "git $(git --version | awk '{print $3}')"

command -v curl >/dev/null 2>&1 || die "curl is required"
ok "curl $(curl --version | head -1 | awk '{print $2}')"

ensure_node
ensure_bun
ensure_pnpm

# ─── GitHub authentication ───────────────────────────────────────────────
step "GitHub authentication"

AUTH_METHOD=""
CLONE_URL=""

validate_token() {
  local token=$1
  curl -fs -o /dev/null -w '%{http_code}' \
    -H "Authorization: token $token" \
    -H "User-Agent: lumi-build-installer" \
    "https://api.github.com/repos/${REPO}" \
    | grep -q '^200$'
}

# Try 1: existing GITHUB_TOKEN env
if [[ -n "$GITHUB_TOKEN" ]]; then
  if validate_token "$GITHUB_TOKEN"; then
    AUTH_METHOD=env
    CLONE_URL="https://${GITHUB_TOKEN}@github.com/${REPO}.git"
    ok "Using GITHUB_TOKEN from environment"
  else
    warn "GITHUB_TOKEN set but invalid or no access to ${REPO}; trying other methods"
    GITHUB_TOKEN=""
  fi
fi

# Try 2: gh CLI
if [[ -z "$AUTH_METHOD" ]] && command -v gh >/dev/null 2>&1 \
    && gh auth status >/dev/null 2>&1; then
  # Verify gh can actually see this repo
  if gh repo view "$REPO" >/dev/null 2>&1; then
    AUTH_METHOD=gh
    ok "Using GitHub CLI (gh) authentication"
  else
    warn "gh is authenticated but lacks access to ${REPO}"
  fi
fi

# Try 3: SSH (check if user has working SSH auth for GitHub)
if [[ -z "$AUTH_METHOD" ]]; then
  if ssh -T git@github.com -o BatchMode=yes -o StrictHostKeyChecking=no 2>&1 \
       | grep -qi "successfully authenticated"; then
    AUTH_METHOD=ssh
    CLONE_URL="git@github.com:${REPO}.git"
    ok "Using SSH authentication"
  fi
fi

# Try 4: interactive PAT prompt
if [[ -z "$AUTH_METHOD" ]]; then
  warn "No GitHub authentication detected."
  info "Create a PAT at:"
  info "  https://github.com/settings/tokens/new?scopes=repo&description=lumi-installer"
  info "Scope needed: 'repo' (full control of private repositories)"
  echo
  while true; do
    GITHUB_TOKEN=$(ask_secret "GitHub Personal Access Token (ghp_... or github_pat_...)")
    if [[ -z "$GITHUB_TOKEN" ]]; then
      die "A GitHub PAT is required to clone the private repo."
    fi
    if validate_token "$GITHUB_TOKEN"; then
      AUTH_METHOD=pat
      CLONE_URL="https://${GITHUB_TOKEN}@github.com/${REPO}.git"
      ok "Token validated"
      break
    else
      warn "Token invalid or no access to ${REPO}. Try again."
    fi
  done
fi

# ─── Clone ───────────────────────────────────────────────────────────────
step "Cloning ${REPO}@${BRANCH}"

mkdir -p "$(dirname "$WORK_DIR")"
if [[ -d "$WORK_DIR" ]]; then
  rm -rf "$WORK_DIR"
fi

# NOTE: --depth=1 keeps the clone lean; --recurse-submodules covers the
# grafted lumi-engine submodule when it's registered as such.
case "$AUTH_METHOD" in
  gh)
    gh repo clone "$REPO" "$WORK_DIR" -- --depth 1 --branch "$BRANCH" \
      || die "git clone failed"
    ;;
  env|pat|ssh)
    git clone --depth 1 --branch "$BRANCH" --recurse-submodules "$CLONE_URL" "$WORK_DIR" \
      || die "git clone failed"
    ;;
esac

ok "Cloned to $WORK_DIR"

# ─── Build ───────────────────────────────────────────────────────────────
step "Installing workspace dependencies"

cd "$WORK_DIR" || die "chdir failed"

# 1. Root pnpm workspace — installs + symlinks every `packages/*`
#    EXCEPT `lumi-engine` (excluded via `pnpm-workspace.yaml`). This is
#    what produces `node_modules/@lumi/{shared,config,engine-bridge,
#    setup,…}` and the symlinks `apps/desktop`'s relative imports rely on
#    (e.g. `gatewaySingleton.ts` → `packages/engine-bridge/dist/index.js`).
info "pnpm install (root workspace)"
(pnpm install --frozen-lockfile 2>&1 | tail -5) \
  || die "Root pnpm install failed"
ok "Root workspace deps installed"

# 2. Lumi engine — its own isolated workspace because of the grafted
#    upstream dep graph.
if [[ -f packages/lumi-engine/package.json ]]; then
  info "pnpm install for lumi-engine"
  (cd packages/lumi-engine && pnpm install --frozen-lockfile 2>&1 | tail -5) \
    || die "Engine pnpm install failed"
  ok "lumi-engine deps installed"
fi

# 3. Desktop app — separate bun lockfile. Not part of the pnpm workspace
#    (Electron native modules + a very different dep graph).
info "bun install for desktop"
(cd apps/desktop && bun install 2>&1 | tail -5) \
  || die "Desktop bun install failed"
ok "Desktop deps installed"

step "Building workspace packages"
# 4. Build every `@lumi/*` package the desktop imports from (shared,
#    config, engine-bridge, setup — all `tsc -b`). Recursive `-r` walks
#    the workspace dep graph in topological order.
info "pnpm -r build (shared / config / engine-bridge / setup …)"
(pnpm -r build 2>&1 | tail -10) \
  || die "Workspace package builds failed"
ok "Workspace packages built"

step "Building the Lumi engine"
(cd packages/lumi-engine && pnpm run build 2>&1 | tail -5) \
  || die "Engine build failed"
ok "Engine built"

step "Building the desktop app (this takes 3–5 min)"
case "$PLATFORM" in
  mac)
    (cd apps/desktop && bun run dist:mac) \
      || die "Desktop build failed"
    ;;
  linux)
    (cd apps/desktop && bun run build 2>&1 | tail -20) \
      || die "Desktop build failed"
    ;;
esac
ok "Desktop app built"

# ─── Install ─────────────────────────────────────────────────────────────
step "Installing Lumi"

install_mac() {
  local dmg
  dmg=$(ls -t "$WORK_DIR/apps/desktop/out/"*.dmg 2>/dev/null | head -1)
  if [[ -z "$dmg" || ! -f "$dmg" ]]; then
    die "No DMG produced in $WORK_DIR/apps/desktop/out/"
  fi
  info "DMG: $(basename "$dmg") ($(du -h "$dmg" | awk '{print $1}'))"

  # Parse hdiutil output via the tab-delimited final column so volume
  # names with spaces (e.g. `/Volumes/Lumi 0.3.0-arm64`) survive
  # intact. The previous regex `/Volumes/[^ ]+` truncated at the first
  # space and pointed `cp` at a non-existent path.
  local hdiutil_out
  if ! hdiutil_out=$(hdiutil attach "$dmg" -nobrowse -noverify 2>&1); then
    die "hdiutil attach failed: $hdiutil_out"
  fi
  local mount_point
  mount_point=$(printf '%s\n' "$hdiutil_out" \
    | awk -F'\t' '/\/Volumes\// { n = NF; while (n > 1 && $n == "") n--; if ($n ~ /^\/Volumes\//) { print $n; exit } }' \
    | sed -e 's/[[:space:]]*$//')
  # Fallback — enumerate /Volumes/ and pick the newest Lumi* mount in
  # case the awk parse misses (older hdiutil variants, stdout buffering).
  if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
    mount_point=$(ls -dt /Volumes/Lumi* 2>/dev/null | head -1)
  fi
  if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
    die "Could not resolve mounted volume from hdiutil output: $hdiutil_out"
  fi
  info "Mounted at: $mount_point"

  # Pick the .app inside the mount (usually Lumi.app, but stay resilient
  # if electron-builder ever renames it).
  local app_src
  app_src=$(ls -d "${mount_point}"/*.app 2>/dev/null | head -1)
  if [[ -z "$app_src" || ! -d "$app_src" ]]; then
    hdiutil detach "$mount_point" -quiet 2>/dev/null || true
    die "No .app bundle inside the mounted DMG"
  fi

  # Pick install target. /Applications needs admin-group write perms
  # (default on most macOS installs, locked down on some corporate ones).
  local target_dir=/Applications
  if [[ ! -w "$target_dir" ]]; then
    warn "/Applications is not writable by this user"
    if ask_yes_no "Install to ~/Applications instead?" y; then
      target_dir="$HOME/Applications"
      mkdir -p "$target_dir"
    else
      warn "Try rerunning with sudo to install to /Applications"
      hdiutil detach "$mount_point" -quiet 2>/dev/null || true
      die "Install aborted"
    fi
  fi

  local app_name
  app_name=$(basename "$app_src")
  local target="${target_dir}/${app_name}"
  if [[ -d "$target" ]]; then
    if ask_yes_no "Existing ${target} found. Replace?" y; then
      rm -rf "$target" 2>/dev/null || sudo rm -rf "$target" \
        || { hdiutil detach "$mount_point" -quiet 2>/dev/null || true; die "Could not remove existing app"; }
    else
      hdiutil detach "$mount_point" -quiet 2>/dev/null || true
      die "Install aborted"
    fi
  fi

  if ! cp -R "$app_src" "$target_dir/" 2>/dev/null; then
    warn "Plain cp failed — retrying with sudo"
    sudo cp -R "$app_src" "$target_dir/" \
      || { hdiutil detach "$mount_point" -quiet 2>/dev/null || true; die "Copy to $target_dir failed"; }
  fi
  xattr -d com.apple.quarantine "$target" 2>/dev/null || true
  hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  ok "Installed to $target"
}

install_linux() {
  # Desktop build output on Linux lands as AppImage / deb in out/
  local artifact
  artifact=$(ls -t "$WORK_DIR/apps/desktop/out/"*.{AppImage,deb} 2>/dev/null | head -1)
  if [[ -z "$artifact" ]]; then
    warn "No installable artifact (.AppImage or .deb) found in apps/desktop/out/"
    info "Contents:"
    ls "$WORK_DIR/apps/desktop/out/" | sed 's/^/    /'
    die "Nothing to install"
  fi

  case "$artifact" in
    *.AppImage)
      local target="$HOME/.local/bin/Lumi"
      mkdir -p "$HOME/.local/bin"
      cp "$artifact" "$target"
      chmod +x "$target"
      ok "AppImage installed to $target"
      info "Run with: Lumi"
      ;;
    *.deb)
      if ! command -v dpkg >/dev/null 2>&1; then
        die "dpkg not available — install $(basename "$artifact") manually"
      fi
      info "Running: sudo dpkg -i $(basename "$artifact")"
      sudo dpkg -i "$artifact" || sudo apt-get install -fy || die "Install failed"
      ok "Package installed"
      ;;
  esac
}

case "$PLATFORM" in
  mac)   install_mac ;;
  linux) install_linux ;;
esac

# ─── Auto-launch the freshly-installed app ──────────────────────────────
# The in-app "Install Update" flow quits Lumi before invoking this
# script and expects it to bring the new version up automatically —
# otherwise the user is left staring at a closed app wondering whether
# the update worked. For curl-pipe-bash users on a desktop session this
# is just a friendly UX touch; on headless installs (no display server,
# CI runs) the launch silently fails and the script still exits clean.
#
# Set NO_LAUNCH=1 (or pass --no-launch) to opt out — useful when
# scripting installs that shouldn't trigger a GUI window.
launch_lumi_app() {
  if [[ "${NO_LAUNCH:-0}" == "1" ]]; then
    return 0
  fi

  case "$PLATFORM" in
    mac)
      # `open -n -a` boots a fresh instance even when one is already
      # running. We try the install destination first (which depends on
      # whether /Applications was writable above) so we always relaunch
      # the version we just installed, not a stale older copy that
      # might still be sitting in the other location.
      local candidate
      for candidate in "/Applications/Lumi.app" "$HOME/Applications/Lumi.app"; do
        if [[ -d "$candidate" ]]; then
          info "launching $candidate..."
          open -n -a "$candidate" 2>/dev/null && return 0
        fi
      done
      ;;
    linux)
      local lumi_bin
      for lumi_bin in lumi Lumi; do
        if command -v "$lumi_bin" >/dev/null 2>&1; then
          info "launching $lumi_bin..."
          nohup "$lumi_bin" >/dev/null 2>&1 &
          disown
          return 0
        fi
      done
      ;;
  esac
}

launch_lumi_app

# ─── Final banner ────────────────────────────────────────────────────────
printf '\n%s              🌙  Lumi is ready.%s\n\n' "${BOLD}${GREEN}" "${RESET}"
printf '  %sLaunch%s\n' "${BOLD}" "${RESET}"
printf '    %smacOS:%s   open -a Lumi\n' "${BOLD}" "${RESET}"
printf '    %sLinux:%s   Lumi  (AppImage) / or search in your app launcher\n' "${BOLD}" "${RESET}"
printf '\n  %sDocs%s     https://github.com/%s/blob/main/README.md\n\n' "${BOLD}" "${RESET}" "${REPO}"
