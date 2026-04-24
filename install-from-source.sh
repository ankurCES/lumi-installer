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

step()  { printf '\n%s🌙 %s%s\n' "${BOLD}${CYAN}" "$1" "${RESET}"; }
ok()    { printf '  %s✓%s %s\n' "${GREEN}" "${RESET}" "$1"; }
warn()  { printf '  %s⚠%s %s\n' "${YELLOW}" "${RESET}" "$1"; }
info()  { printf '  %s·%s %s\n' "${DIM}" "${RESET}" "$1"; }
die()   { printf '\n  %s✗%s %s\n\n' "${RED}" "${RESET}" "$1"; exit 1; }

ask_input() {
  # ask_input <prompt> [default]
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
}

ask_secret() {
  local prompt=$1
  local ans
  printf '%s? %s%s: ' "${BOLD}" "$prompt" "${RESET}"
  IFS= read -rs ans < /dev/tty
  echo
  printf '%s' "$ans"
}

ask_yes_no() {
  # ask_yes_no <prompt> [default_y_or_n]
  local prompt=$1
  local default=${2:-y}
  local hint="[y/N]"
  [[ "$default" == y ]] && hint="[Y/n]"
  local ans
  printf '%s? %s%s %s: ' "${BOLD}" "$prompt" "${RESET}" "$hint"
  IFS= read -r ans < /dev/tty
  ans=${ans:-$default}
  [[ "$ans" =~ ^[Yy] ]]
}

# ─── Banner ──────────────────────────────────────────────────────────────
# Two-tone moon + LUMI block art, matching the engine CLI banner
# (`packages/lumi-engine/src/cli/banner.ts`) so the installer looks like
# it belongs to the same product and doesn't feel tacked on.
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

# ─── Final banner ────────────────────────────────────────────────────────
printf '\n%s              🌙  Lumi is ready.%s\n\n' "${BOLD}${GREEN}" "${RESET}"
printf '  %sLaunch%s\n' "${BOLD}" "${RESET}"
printf '    %smacOS:%s   open -a Lumi\n' "${BOLD}" "${RESET}"
printf '    %sLinux:%s   Lumi  (AppImage) / or search in your app launcher\n' "${BOLD}" "${RESET}"
printf '\n  %sDocs%s     https://github.com/%s/blob/main/README.md\n\n' "${BOLD}" "${RESET}" "${REPO}"
