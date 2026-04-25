#!/usr/bin/env bash
#
# Lumi — build-from-source installer (macOS + Linux)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ankurCES/OpenLaude/main/install-from-source.sh | bash
#
# This script is a *bootstrap*. Its only job is to make the build-tool
# prerequisites available (Bun, Node ≥ 20, pnpm) and then hand off to
# `install-from-source.tsx` — an Ink-based TUI that owns the actual
# install flow (clean-vs-update menu, GitHub auth picker, clone, build,
# install, launch). Once the prereqs are met everything user-visible
# happens inside the Ink app: bordered progress region, animated moon
# runner, etc.
#
# Flags + env vars are passed through to the TSX:
#   --yes / -y          non-interactive mode (inherits LUMI_INSTALL_YES=1)
#   REPO                GitHub owner/repo (default: ankurCES/OpenLaude)
#   BRANCH              git branch (default: main)
#   GITHUB_TOKEN        pre-supplied PAT (skips interactive prompt)
#   NO_LAUNCH=1         skip the post-install app launch
#   SKIP_CLEANUP=1      keep the staging dir for debugging
#

set -euo pipefail

# REPO + BRANCH point at the SOURCE repo the Ink installer will git-
# clone (private, requires auth — handled inside the Ink app's auth
# flow). TSX_REPO + TSX_BRANCH point at the public mirror this script
# self-references to fetch the Ink TSX without auth (the source repo
# is private; raw.githubusercontent.com would 404 for unauthenticated
# users). Keeping them split means a user can override REPO=their-fork
# without breaking the public TSX fetch path.
REPO="${REPO:-ankurCES/OpenLaude}"
BRANCH="${BRANCH:-main}"
TSX_REPO="${TSX_REPO:-ankurCES/lumi-installer}"
TSX_BRANCH="${TSX_BRANCH:-main}"
TSX_URL="${TSX_URL:-https://raw.githubusercontent.com/${TSX_REPO}/${TSX_BRANCH}/install-from-source.tsx}"

# ─── ANSI styling ────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  CYAN=$'\033[0;36m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  RED=$'\033[0;31m'
  RESET=$'\033[0m'
else
  BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RED='' RESET=''
fi

step() { printf '%s● %s%s\n' "${CYAN}" "$*" "${RESET}"; }
ok()   { printf '%s✓ %s%s\n' "${GREEN}" "$*" "${RESET}"; }
info() { printf '%s  %s%s\n' "${DIM}" "$*" "${RESET}"; }
warn() { printf '%s! %s%s\n' "${YELLOW}" "$*" "${RESET}"; }
die()  { printf '%s✗ %s%s\n' "${RED}" "$*" "${RESET}" >&2; exit 1; }

printf '\n%s🌙 Lumi%s build-from-source bootstrap%s\n\n' "${BOLD}${CYAN}" "${BOLD}" "${RESET}"
info "repo: ${REPO}@${BRANCH}"

# ─── Platform detection ────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin) PLATFORM=mac ;;
  Linux)  PLATFORM=linux ;;
  *)      die "Unsupported OS: $(uname -s). Use install-from-source.ps1 on Windows." ;;
esac
ok "platform: ${PLATFORM}/$(uname -m)"

# ─── Prerequisites ────────────────────────────────────────────────────────
step "Checking build-tool prerequisites"

# Bun — required to run the TSX. Auto-install via the official one-liner
# when missing; bun installer drops into ~/.bun/bin.
if ! command -v bun >/dev/null 2>&1; then
  warn "bun not found — installing"
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || die "bun install failed; see https://bun.sh/"
  if [[ -d "$HOME/.bun/bin" ]]; then
    export PATH="$HOME/.bun/bin:$PATH"
  fi
  command -v bun >/dev/null 2>&1 || die "bun installed but not on PATH; restart your shell and rerun"
fi
ok "bun $(bun --version)"

# Node ≥ 20 — required by the lumi-engine pnpm workspace + several builds.
if command -v node >/dev/null 2>&1; then
  node_major=$(node -v | sed 's/^v\([0-9]*\).*/\1/')
  if (( node_major < 20 )); then
    warn "node $(node --version) is too old (need ≥ 20)"
    if [[ "$PLATFORM" == "mac" ]] && command -v brew >/dev/null 2>&1; then
      brew install node || die "brew install node failed; install Node 20+ manually"
    else
      die "Node.js ≥ 20 is required. Install from https://nodejs.org/ (or via fnm/nvm) and rerun."
    fi
  fi
elif [[ "$PLATFORM" == "mac" ]] && command -v brew >/dev/null 2>&1; then
  warn "node not found — installing via brew"
  brew install node || die "brew install node failed"
else
  die "Node.js ≥ 20 is required. Install from https://nodejs.org/ (or via fnm/nvm) and rerun."
fi
ok "node $(node --version)"

# pnpm — used for the workspace install + engine build. corepack ships
# with Node so this should never need to fall back to a manual install.
if ! command -v pnpm >/dev/null 2>&1; then
  warn "pnpm not found — activating via corepack"
  corepack enable >/dev/null 2>&1 || true
  corepack prepare pnpm@10.33.0 --activate >/dev/null 2>&1 \
    || die "corepack failed to activate pnpm; install pnpm manually (https://pnpm.io/installation)"
fi
ok "pnpm $(pnpm --version)"

# gh CLI — best-effort. The Ink installer's auth picker uses `gh repo
# view` to detect whether the signed-in account has access to the repo.
# Installing gh here means a user who's already authenticated elsewhere
# gets the gh option offered in the Ink picker. If install fails (no
# brew on Linux without it, or no apt repo), the Ink app still offers
# PAT and SSH auth paths — gh is a nice-to-have, not required.
if ! command -v gh >/dev/null 2>&1; then
  warn "gh CLI not found — attempting install (best-effort)"
  if [[ "$PLATFORM" == "mac" ]] && command -v brew >/dev/null 2>&1; then
    brew install gh >/dev/null 2>&1 || true
  elif [[ "$PLATFORM" == "linux" ]] && command -v apt-get >/dev/null 2>&1; then
    # https://github.com/cli/cli/blob/trunk/docs/install_linux.md
    if command -v sudo >/dev/null 2>&1; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null 2>&1 || true
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null 2>&1 || true
      sudo apt-get update -y >/dev/null 2>&1 || true
      sudo apt-get install -y gh >/dev/null 2>&1 || true
    fi
  fi
fi
if command -v gh >/dev/null 2>&1; then
  ok "gh $(gh --version | head -1)"
else
  info "gh CLI not installed — Ink installer will use PAT or SSH auth"
fi

# ─── Stage Ink installer ──────────────────────────────────────────────────
step "Staging Ink installer"

WORK="${TMPDIR:-/tmp}/lumi-installer-$$"
mkdir -p "$WORK"
cleanup() {
  if [[ "${SKIP_CLEANUP:-0}" != "1" ]]; then
    rm -rf "$WORK" 2>/dev/null || true
  else
    info "kept $WORK (SKIP_CLEANUP=1)"
  fi
}
trap cleanup EXIT INT TERM

curl -fsSL "$TSX_URL" -o "$WORK/install-from-source.tsx" \
  || die "Could not fetch installer from $TSX_URL"

# package.json drives `bun install` for the Ink deps. Pinned majors so
# the API surfaces this TSX uses don't drift under us.
cat > "$WORK/package.json" <<'EOF'
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
EOF

(cd "$WORK" && bun install --no-progress >/dev/null 2>&1) \
  || die "Failed to install Ink deps in $WORK"

ok "bootstrap ready"
echo

# ─── Hand off to Ink installer ────────────────────────────────────────────
# The TSX takes over from here. Args + env vars flow through unchanged.
cd "$WORK"
bun install-from-source.tsx "$@"
exit $?
