# Lumi installer

Public mirror of the two build-from-source install scripts for Lumi.

**The Lumi source is private** — it lives at
[`ankurCES/OpenLaude`](https://github.com/ankurCES/OpenLaude) and
requires collaborator access. This repo exists only so the install
one-liner works without needing to authenticate to fetch the script
itself; the script still prompts for your GitHub auth to clone the
actual source.

## Install

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/ankurCES/lumi-installer/main/install-from-source.sh | bash
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/ankurCES/lumi-installer/main/install-from-source.ps1 | iex
```

## What the script does

1. Detects your platform (mac/linux/windows; arm64/x64).
2. Installs any missing build deps (git, bun, pnpm, node ≥ 20) via
   platform-appropriate means (winget, bun's installer, corepack).
3. Authenticates to `ankurCES/OpenLaude` via — in order — `$GITHUB_TOKEN`,
   `gh` CLI, SSH (mac/linux), or an interactive PAT prompt.
4. Shallow-clones `ankurCES/OpenLaude` to a temp directory.
5. Builds the Lumi engine (pnpm) + desktop app (bun + electron-builder).
6. Installs the resulting artifact — `.dmg` → `/Applications` on macOS,
   AppImage or `.deb` on Linux, NSIS silent install on Windows.
7. Deletes the temp clone on success or failure (unless you pass
   `SKIP_CLEANUP=1` or `KEEP_SOURCE=<path>`).

## Access to the source

If you need a `repo`-scope Personal Access Token for an account that
has access to `ankurCES/OpenLaude`, create one at
<https://github.com/settings/tokens/new?scopes=repo>.

## Sync mechanism

This repo is a read-only mirror. The scripts here are pushed
automatically from `ankurCES/OpenLaude/main` by a GitHub Action
(`.github/workflows/sync-installer.yml`) every time one of the install
scripts is modified. Do **not** edit files here by hand — any local
edits will be overwritten on the next sync.
