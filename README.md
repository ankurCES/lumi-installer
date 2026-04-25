<p align="center">
  <img src="docs/lumi.png" alt="Lumi" width="160" />
</p>

<h1 align="center">Lumi</h1>

<p align="center">
  She reads code. She writes it too. She remembers. She learns.
</p>

<p align="center">
  <img src="docs/moonrunner.gif" alt="Moonrunner — Lumi's animated banner" width="720" />
</p>

---

## About

**Lumi** is a desktop AI workspace — your AI coworker for code, documents, and image / video generation, with team mode for long-running multi-step work.

- **Optimised for Claude.** Bring your Claude Code CLI as the runtime; Lumi auto-provisions a sandboxed overlay (skills, MCP servers, persona) that never touches your global `~/.claude/` config.
- **Built-in Lumi Engine** runtime. Works with Anthropic, OpenAI, Google Gemini, and locally-hosted models via Ollama, LM Studio, and similar providers. Each agent picks its own model.
- **ComfyUI bundled in.** Image and video generation pipelines are auto-provisioned on first launch — no separate install.
- **Team mode** for long-running tasks. Spawn a lead agent + a configurable team of specialists; the lead delegates, tracks progress, and reports back.

---

## Install

The installer handles everything: build-tool prerequisites (Bun, Node, pnpm, gh CLI), source clone, dependency install, app build, and first launch. Expect 3–5 minutes end-to-end.

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/ankurCES/lumi-installer/main/install-from-source.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/ankurCES/lumi-installer/main/install-from-source.ps1 | iex
```

You'll be asked whether to perform a clean install or an update, and prompted for GitHub authentication (gh CLI, PAT, or SSH — auto-detected). The Ink-based TUI guides you through the rest.

---

> **Note — alpha release.** Lumi is currently in private alpha. The install will ask for a GitHub access token (or `gh` CLI auth) because the source repo is not public yet. If you'd like access, reach out and a time-limited PAT will be shared with you. The token, the build pipeline, and the installed app all run locally on your machine — nothing is sent to a remote service.
