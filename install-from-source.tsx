#!/usr/bin/env bun
/// <reference types="node" />
/**
 * @license
 * Copyright 2025 OpenLaude contributors
 * SPDX-License-Identifier: MIT
 */

/**
 * Lumi build-from-source installer — Ink TUI rewrite.
 *
 * Replaces the legacy bash installer's hand-rolled ANSI TUI with a
 * proper React-via-Ink terminal UI. The bash + ps1 bootstraps
 * (`install-from-source.sh`, `install-from-source.ps1`) install Bun
 * if missing, fetch this file from the repo, and exec
 * `bun install-from-source.tsx`. Bun auto-resolves the npm deps
 * (`ink`, `react`, `ink-select-input`, `ink-text-input`, `ink-spinner`)
 * on first run.
 *
 * UI flow:
 *   1. Splash — moon-dino animation + LUMI banner.
 *   2. Install-type menu — clean vs update (NEW).
 *      Clean wipes ~/.lumi/, ~/.aionui-config/, and the platform's
 *      Lumi user-data dir before the rest of the install runs.
 *   3. Auth picker — env-token / gh-cli / PAT / SSH, with auto-detect
 *      defaulting and the option to override (port from bash step 3.5).
 *   4. Progress region — bordered box, scrolling tail of every step's
 *      child-process output. No more overlap with the animation.
 *   5. Done / Error screen — final banner with launch hints.
 *
 * Non-interactive mode: `--yes` / `-y` / `LUMI_INSTALL_YES=1` skip the
 * menu (defaults to update) and the auth picker (uses auto-detected
 * method). Same flag the bash version honored.
 */

import React, { useEffect, useMemo, useReducer, useState, useRef } from 'react';
import { render, Box, Text, useApp, useInput } from 'ink';
import SelectInput from 'ink-select-input';
import TextInput from 'ink-text-input';
import Spinner from 'ink-spinner';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, openSync, readdirSync, rmSync, statSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import * as path from 'node:path';
import * as tty from 'node:tty';

// ── Constants ──────────────────────────────────────────────────────────────

const REPO = process.env.REPO ?? 'ankurCES/OpenLaude';
const BRANCH = process.env.BRANCH ?? 'main';
const WORK_DIR = process.env.WORK_DIR ?? path.join(tmpdir(), `lumi-build-${process.pid}`);
const ENV_TOKEN = (process.env.GITHUB_TOKEN ?? '').trim();
/**
 * Resolve a stdin stream Ink can use for raw-mode keystroke capture.
 *
 * Why we don't just rely on `process.stdin`:
 *   - Bun's `process.stdin.isTTY` is `undefined` in some versions
 *     even when fd 0 is genuinely a TTY, which makes Ink's
 *     `isRawModeSupported()` return false and silently disable input
 *     (menu renders but arrow keys / Ctrl-C do nothing — exactly the
 *     symptom reported).
 *   - Under `curl … | bash`, fd 0 is the curl pipe, not a TTY at all.
 *
 * Strategy: open `/dev/tty` fresh as a `tty.ReadStream` and pass that
 * to `render(<App />, { stdin })`. /dev/tty resolves to the
 * controlling terminal regardless of how fd 0 is set, so Ink ends up
 * with a stream where `setRawMode` actually works. Falls through to
 * `process.stdin` only when /dev/tty can't be opened (true headless:
 * CI, daemon, no controlling terminal) — in which case we force
 * non-interactive mode and skip the keystroke-driven components.
 */
function resolveInkStdin(): { stream: NodeJS.ReadStream; isTTY: boolean } {
  // 1. Try to open /dev/tty — the most reliable path on macOS / Linux
  //    when there's a controlling terminal, regardless of pipes on fd 0.
  if (existsSync('/dev/tty')) {
    try {
      const fd = openSync('/dev/tty', 'r');
      const stream = new tty.ReadStream(fd) as unknown as NodeJS.ReadStream;
      // Some Bun builds return a stream where isTTY is undefined even
      // for /dev/tty — pin it to `true` so Ink's
      // isRawModeSupported() returns true and raw mode actually
      // engages.
      Object.defineProperty(stream, 'isTTY', { value: true, writable: false, configurable: true });
      return { stream, isTTY: true };
    } catch {
      // fall through to process.stdin
    }
  }
  // 2. Fall back to process.stdin and trust whatever isTTY says (true
  //    for the rare case the user invoked us in a pty without a
  //    controlling terminal but still has fd 0 as a TTY).
  const isTTY = Boolean(process.stdin && process.stdin.isTTY === true);
  return { stream: process.stdin, isTTY };
}

const { stream: INK_STDIN, isTTY: STDIN_IS_TTY } = resolveInkStdin();
const NON_INTERACTIVE = (() => {
  if (process.env.LUMI_INSTALL_YES === '1') return true;
  if (process.argv.slice(2).some((a) => a === '--yes' || a === '-y')) return true;
  if (!STDIN_IS_TTY) return true;
  return false;
})();

// ── Type definitions ───────────────────────────────────────────────────────

type Platform = 'mac' | 'linux' | 'windows';
type Arch = 'arm64' | 'x64';
type InstallType = 'clean' | 'update';
type AuthMethod = 'env' | 'gh' | 'pat' | 'ssh';

type Step =
  | 'splash'
  | 'menu'
  | 'auth-picker'
  | 'pat-input'
  | 'running'
  | 'done'
  | 'error';

interface LogEntry {
  ts: string;
  level: 'info' | 'ok' | 'warn' | 'error' | 'step' | 'cmd';
  message: string;
}

interface State {
  step: Step;
  installType: InstallType | null;
  detectedAuth: AuthMethod | null;
  authMethod: AuthMethod | null;
  pat: string;
  cloneUrl: string;
  hasGhCli: boolean;
  ghAuthOk: boolean;
  sshOk: boolean;
  platform: Platform;
  arch: Arch;
  logs: LogEntry[];
  error: string | null;
  installedTo: string | null;
}

type Action =
  | { type: 'set-install-type'; value: InstallType }
  | { type: 'set-auth-method'; value: AuthMethod; cloneUrl: string }
  | { type: 'set-detection'; detected: AuthMethod | null; cloneUrl: string; hasGhCli: boolean; ghAuthOk: boolean; sshOk: boolean }
  | { type: 'set-pat'; value: string }
  | { type: 'set-step'; value: Step }
  | { type: 'append-log'; entry: LogEntry }
  | { type: 'fail'; error: string }
  | { type: 'finish'; installedTo: string };

const MAX_LOG_LINES = 14;

const initialState: State = {
  step: 'splash',
  installType: null,
  detectedAuth: null,
  authMethod: null,
  pat: '',
  cloneUrl: '',
  hasGhCli: false,
  ghAuthOk: false,
  sshOk: false,
  platform: detectPlatform(),
  arch: detectArch(),
  logs: [],
  error: null,
  installedTo: null,
};

function reducer(state: State, action: Action): State {
  switch (action.type) {
    case 'set-install-type':
      return { ...state, installType: action.value };
    case 'set-auth-method':
      return { ...state, authMethod: action.value, cloneUrl: action.cloneUrl };
    case 'set-detection':
      return {
        ...state,
        detectedAuth: action.detected,
        authMethod: action.detected,
        cloneUrl: action.cloneUrl,
        hasGhCli: action.hasGhCli,
        ghAuthOk: action.ghAuthOk,
        sshOk: action.sshOk,
      };
    case 'set-pat':
      return { ...state, pat: action.value };
    case 'set-step':
      return { ...state, step: action.value };
    case 'append-log':
      return {
        ...state,
        logs: [...state.logs, action.entry].slice(-MAX_LOG_LINES * 4), // soft cap
      };
    case 'fail':
      return { ...state, step: 'error', error: action.error };
    case 'finish':
      return { ...state, step: 'done', installedTo: action.installedTo };
    default:
      return state;
  }
}

// ── Platform detection ─────────────────────────────────────────────────────

function detectPlatform(): Platform {
  if (process.platform === 'darwin') return 'mac';
  if (process.platform === 'linux') return 'linux';
  if (process.platform === 'win32') return 'windows';
  throw new Error(`Unsupported platform: ${process.platform}. Windows users: run install-from-source.ps1.`);
}

function detectArch(): Arch {
  if (process.arch === 'arm64') return 'arm64';
  if (process.arch === 'x64') return 'x64';
  throw new Error(`Unsupported architecture: ${process.arch}`);
}

// ── Top-level App component ────────────────────────────────────────────────

const App: React.FC = () => {
  const [state, dispatch] = useReducer(reducer, initialState);
  const { exit } = useApp();
  const startedRef = useRef(false);

  // Auth auto-detect on mount — populates detectedAuth + the
  // hasGhCli/ghAuthOk/sshOk flags the picker uses to decide which
  // options to surface. Specifically: when gh CLI is signed in but
  // doesn't have access to the repo (`gh repo view` fails),
  // ghAuthOk stays false, the picker hides the gh option entirely,
  // and the user is steered to the PAT flow (the user's spec).
  //
  // Non-interactive path skips the menu + picker entirely: even
  // briefly mounting <SelectInput>/<TextInput> trips Ink's raw-mode
  // requirement (which needs a TTY). Defaults: installType=update,
  // authMethod=detected. If no auth was detected and we're non-
  // interactive, fail explicitly rather than hanging.
  useEffect(() => {
    void (async () => {
      const detection = await detectAuth();
      dispatch({
        type: 'set-detection',
        detected: detection.method,
        cloneUrl: detection.cloneUrl,
        hasGhCli: detection.hasGhCli,
        ghAuthOk: detection.ghAuthOk,
        sshOk: detection.sshOk,
      });

      if (NON_INTERACTIVE) {
        if (!detection.method) {
          dispatch({
            type: 'fail',
            error: STDIN_IS_TTY
              ? 'No GitHub auth detected and --yes / non-interactive mode does not allow PAT prompt. Set GITHUB_TOKEN, sign in to gh CLI, or omit --yes.'
              : 'stdin is not a TTY and no GitHub auth detected. Set GITHUB_TOKEN or sign in to gh CLI before piping this script through bash.',
          });
          return;
        }
        dispatch({ type: 'set-install-type', value: 'update' });
        dispatch({ type: 'set-step', value: 'running' });
      }
    })();
    if (NON_INTERACTIVE) return; // skip the splash → menu transition
    const t = setTimeout(() => {
      dispatch({ type: 'set-step', value: 'menu' });
    }, 1700);
    return () => clearTimeout(t);
  }, []);

  // After menu + auth are settled, kick off install once.
  useEffect(() => {
    if (state.step !== 'running') return;
    if (startedRef.current) return;
    startedRef.current = true;
    runInstall(state, dispatch)
      .then((installedTo) => {
        dispatch({ type: 'finish', installedTo });
        // Hold the success screen for a beat so curl-pipe users see it.
        setTimeout(() => exit(), 2200);
      })
      .catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err);
        dispatch({ type: 'fail', error: msg });
        // Hold the error screen long enough for the user to read the
        // failure context, then dump the same context to actual
        // stderr so it survives Ink unmounting the rendered tree on
        // exit. The error message itself already includes recent
        // stderr / stdout from the failed subprocess (embedded by
        // execStream's reject path), so a single write is enough.
        setTimeout(() => {
          process.stderr.write('\n──── Lumi installer failure ────\n');
          process.stderr.write(`${msg}\n`);
          process.stderr.write(`\nBuild dir kept at ${WORK_DIR} for debugging.\n\n`);
          exit(new Error(msg));
        }, 5000);
      });
  }, [state.step]);

  return (
    <Box flexDirection='column' paddingX={1}>
      <Header />
      {/* Moon-runner animation runs continuously through every step
          — the user asked for the same animated moon character the
          renderer's Moonrunner draws, scaled down to a multi-line
          ASCII sprite that hops across a baseline. */}
      <MoonRunner />
      {state.step === 'splash' && <SplashAnimation />}
      {state.step === 'menu' && (
        <InstallTypeMenu
          onSelect={(value) => {
            dispatch({ type: 'set-install-type', value });
            dispatch({ type: 'set-step', value: 'auth-picker' });
          }}
        />
      )}
      {state.step === 'auth-picker' && (
        <AuthPicker
          detected={state.authMethod}
          hasGhCli={state.hasGhCli}
          ghAuthOk={state.ghAuthOk}
          sshOk={state.sshOk}
          onConfirm={() => dispatch({ type: 'set-step', value: 'running' })}
          onPickPat={() => dispatch({ type: 'set-step', value: 'pat-input' })}
          onPickGh={() => {
            dispatch({ type: 'set-auth-method', value: 'gh', cloneUrl: '' });
            dispatch({ type: 'set-step', value: 'running' });
          }}
          onPickSsh={() => {
            dispatch({ type: 'set-auth-method', value: 'ssh', cloneUrl: `git@github.com:${REPO}.git` });
            dispatch({ type: 'set-step', value: 'running' });
          }}
        />
      )}
      {state.step === 'pat-input' && (
        <PATInput
          onSubmit={(pat) => {
            dispatch({
              type: 'set-auth-method',
              value: 'pat',
              cloneUrl: `https://${pat}@github.com/${REPO}.git`,
            });
            dispatch({ type: 'set-pat', value: pat });
            dispatch({ type: 'set-step', value: 'running' });
          }}
        />
      )}
      {(state.step === 'running' || state.step === 'done' || state.step === 'error') && (
        <ProgressView state={state} />
      )}
      {state.step === 'done' && <DoneScreen state={state} />}
      {state.step === 'error' && <ErrorScreen state={state} />}
    </Box>
  );
};

// ── Header banner ──────────────────────────────────────────────────────────

const LUMI_BANNER = [
  '██╗     ██╗   ██╗███╗   ███╗██╗',
  '██║     ██║   ██║████╗ ████║██║',
  '██║     ██║   ██║██╔████╔██║██║',
  '██║     ██║   ██║██║╚██╔╝██║██║',
  '███████╗╚██████╔╝██║ ╚═╝ ██║██║',
  '╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝',
];

const Header: React.FC = () => (
  <Box flexDirection='column' alignItems='center' marginBottom={1}>
    <Text color='magenta'>·  ✦  🌙  ✦  ·</Text>
    <Box flexDirection='column' marginTop={1}>
      {LUMI_BANNER.map((line) => (
        <Text key={line} bold color='cyan'>
          {line}
        </Text>
      ))}
    </Box>
    <Text dimColor>build-from-source installer</Text>
    <Text dimColor>Your AI coworker, built fresh from HEAD.</Text>
  </Box>
);

// ── MoonRunner — running moon character ────────────────────────────────────

/**
 * ASCII port of the renderer's Moonrunner moon character (see
 * apps/desktop/src/renderer/pages/guid/components/Moonrunner.tsx,
 * `drawMoon` at line 303). The DOM/canvas version draws a crescent
 * body via radial gradient + a sky-coloured "bite" overlay; in a
 * terminal we approximate that with a parenthesised face + a
 * single-eye dot, plus a 2-frame stick-limb run cycle.
 *
 * The moon drifts across the line continuously regardless of which
 * screen the rest of the app is showing — so the splash, menu,
 * auth picker, and bordered progress region all sit below the same
 * running animation, matching the user's spec ("animation on top
 * header while verbose shows below in a neat section").
 */
const MOON_TRACK_WIDTH = 60;
const MOON_TICK_MS = 110;

const MoonRunner: React.FC = () => {
  const [frame, setFrame] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setFrame((f) => (f + 1) % MOON_TRACK_WIDTH), MOON_TICK_MS);
    return () => clearInterval(id);
  }, []);

  const moonX = frame; // 0..MOON_TRACK_WIDTH-1
  const pad = ' '.repeat(moonX);

  // 2-frame run cycle. Frame 0: arms ╱│╲, legs ╱ ╲ (right leg forward).
  // Frame 1: arms ╲│╱, legs ╲ ╱ (left leg forward). Swapping every
  // tick gives the deliberate, slightly-mechanical Chrome-Dino
  // cadence the canvas version uses.
  const runFrame = Math.floor(frame / 2) % 2;
  const arms = runFrame === 0 ? '╱│╲' : '╲│╱';
  const legs = runFrame === 0 ? '╱ ╲' : '╲ ╱';

  return (
    <Box flexDirection='column' marginBottom={1}>
      {/* Sky line — sparse stars that twinkle on phase parity. */}
      <Text dimColor>
        {twinkleRow(frame, MOON_TRACK_WIDTH + 8)}
      </Text>
      <Box>
        <Text>{pad}</Text>
        <Text color='yellow' bold>
          {' ___ '}
        </Text>
      </Box>
      <Box>
        <Text>{pad}</Text>
        <Text color='yellow' bold>
          {'( ◔ )'}
        </Text>
      </Box>
      <Box>
        <Text>{pad}</Text>
        <Text color='yellowBright'>{` ${arms} `}</Text>
      </Box>
      <Box>
        <Text>{pad}</Text>
        <Text color='yellowBright'>{` ${legs} `}</Text>
      </Box>
      {/* Ground line beneath the runner — unicode box-drawing for a
          clean horizon, slightly wider than the track so the moon
          never visibly overshoots. */}
      <Text dimColor>{'─'.repeat(MOON_TRACK_WIDTH + 8)}</Text>
    </Box>
  );
};

function twinkleRow(frame: number, width: number): string {
  const positions = [3, 11, 19, 27, 35, 43, 51, 59, 67];
  const symbols = ['·', '✦', '✧', '·', '✦'];
  const out: string[] = new Array(width).fill(' ');
  for (let i = 0; i < positions.length; i++) {
    const pos = positions[i];
    if (pos >= width) break;
    const visible = (frame + i * 5) % 13 < 7;
    if (visible) out[pos] = symbols[i % symbols.length];
  }
  return out.join('');
}

/** Splash-only tagline shown alongside MoonRunner during the brief intro phase. */
const SplashAnimation: React.FC = () => (
  <Box flexDirection='column' alignItems='center' marginBottom={1}>
    <Text dimColor>Preparing the build environment…</Text>
  </Box>
);

// ── Install-type menu ──────────────────────────────────────────────────────

const InstallTypeMenu: React.FC<{ onSelect: (v: InstallType) => void }> = ({ onSelect }) => {
  const items = [
    {
      label: 'Update — keep my Lumi data, just rebuild + replace the app',
      value: 'update' as const,
    },
    {
      label: 'Clean install — wipe all Lumi data first, then fresh install',
      value: 'clean' as const,
    },
  ];
  return (
    <Box flexDirection='column' marginBottom={1}>
      <Text bold>How would you like to install?</Text>
      <Text dimColor>
        Clean install removes ~/.lumi, ~/.aionui-config, and your Lumi user-data dir before rebuilding.
      </Text>
      <Box marginTop={1}>
        <SelectInput items={items} onSelect={(item) => onSelect(item.value)} />
      </Box>
    </Box>
  );
};

// ── Auth picker ────────────────────────────────────────────────────────────

const AuthPicker: React.FC<{
  detected: AuthMethod | null;
  hasGhCli: boolean;
  ghAuthOk: boolean;
  sshOk: boolean;
  onConfirm: () => void;
  onPickPat: () => void;
  onPickGh: () => void;
  onPickSsh: () => void;
}> = ({ detected, hasGhCli, ghAuthOk, sshOk, onConfirm, onPickPat, onPickGh, onPickSsh }) => {
  const items: Array<{ label: string; value: 'detected' | 'gh' | 'pat' | 'ssh' }> = [];
  if (detected) {
    items.push({
      label: `Continue with detected method: ${describeAuth(detected)} (default)`,
      value: 'detected',
    });
  }
  // Only surface "gh CLI" when the signed-in account actually has
  // repo access. If gh is installed + signed-in but `gh repo view`
  // failed during detection, ghAuthOk is false and we hide gh
  // entirely — that's the user-allowed-access guard. PAT becomes
  // the obvious next pick.
  if (hasGhCli && ghAuthOk) {
    items.push({ label: 'gh CLI — already signed in', value: 'gh' });
  }
  items.push({ label: 'Paste a Personal Access Token (PAT)', value: 'pat' });
  if (sshOk) {
    items.push({ label: 'SSH (git@github.com)', value: 'ssh' });
  }
  const noAccessHint = hasGhCli && !ghAuthOk;
  return (
    <Box flexDirection='column' marginBottom={1}>
      <Text bold>GitHub authentication</Text>
      {noAccessHint && (
        <Text color='yellow'>
          gh CLI is signed in but the active account doesn't have access to {REPO}. Use a PAT instead.
        </Text>
      )}
      <Box marginTop={1}>
        <SelectInput
          items={items}
          onSelect={(item) => {
            if (item.value === 'detected') onConfirm();
            else if (item.value === 'gh') onPickGh();
            else if (item.value === 'pat') onPickPat();
            else if (item.value === 'ssh') onPickSsh();
          }}
        />
      </Box>
    </Box>
  );
};

function describeAuth(method: AuthMethod): string {
  switch (method) {
    case 'env':
      return 'GITHUB_TOKEN (env)';
    case 'gh':
      return 'gh CLI';
    case 'pat':
      return 'Personal Access Token';
    case 'ssh':
      return 'SSH';
  }
}

// ── PAT input ──────────────────────────────────────────────────────────────

const PATInput: React.FC<{ onSubmit: (pat: string) => void }> = ({ onSubmit }) => {
  const [value, setValue] = useState('');
  const [validating, setValidating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <Box flexDirection='column' marginBottom={1}>
      <Text bold>Paste your GitHub Personal Access Token</Text>
      <Text dimColor>Create one: https://github.com/settings/tokens/new?scopes=repo&description=lumi-installer</Text>
      <Text dimColor>Scope needed: 'repo' (full control of private repositories)</Text>
      {error && (
        <Text color='red'>{error}</Text>
      )}
      <Box marginTop={1}>
        <Text>{validating ? 'Validating… ' : 'PAT: '}</Text>
        {!validating && (
          <TextInput
            value={value}
            onChange={(v) => {
              setValue(v);
              setError(null);
            }}
            onSubmit={(submitted) => {
              const trimmed = submitted.trim();
              if (!trimmed) {
                setError('Empty token — try again.');
                return;
              }
              setValidating(true);
              void validateToken(trimmed).then((ok) => {
                if (ok) {
                  onSubmit(trimmed);
                } else {
                  setValidating(false);
                  setError('Token invalid or no access to this repo. Try another.');
                  setValue('');
                }
              });
            }}
            mask='*'
          />
        )}
      </Box>
    </Box>
  );
};

// ── Progress view — bordered log region ────────────────────────────────────

const ProgressView: React.FC<{ state: State }> = ({ state }) => {
  const tail = state.logs.slice(-MAX_LOG_LINES);
  const stepLabel = lastStepLabel(state.logs) ?? 'Preparing…';
  const inProgress = state.step === 'running';
  return (
    <Box flexDirection='column' borderStyle='round' borderColor='cyan' paddingX={1} marginBottom={1}>
      <Box>
        {inProgress ? (
          <Text color='cyan'>
            <Spinner type='dots' />{' '}
          </Text>
        ) : (
          <Text color={state.step === 'error' ? 'red' : 'green'}>{state.step === 'error' ? '✗ ' : '✓ '}</Text>
        )}
        <Text bold>{stepLabel}</Text>
      </Box>
      <Box flexDirection='column' marginTop={1}>
        {tail.length === 0 ? (
          <Text dimColor>(waiting for first output…)</Text>
        ) : (
          tail.map((entry, idx) => (
            <Text key={`${entry.ts}-${idx}`} color={colorForLevel(entry.level)} wrap='truncate'>
              {entry.message}
            </Text>
          ))
        )}
      </Box>
    </Box>
  );
};

function lastStepLabel(logs: LogEntry[]): string | null {
  for (let i = logs.length - 1; i >= 0; i--) {
    const entry = logs[i];
    if (entry.level === 'step') return entry.message;
  }
  return null;
}

function colorForLevel(level: LogEntry['level']): string | undefined {
  switch (level) {
    case 'ok':
      return 'green';
    case 'warn':
      return 'yellow';
    case 'error':
      return 'red';
    case 'step':
      return 'cyan';
    case 'cmd':
      return 'magenta';
    default:
      return undefined;
  }
}

// ── Done / Error screens ───────────────────────────────────────────────────

const DoneScreen: React.FC<{ state: State }> = ({ state }) => (
  <Box flexDirection='column' marginTop={1}>
    <Text color='green' bold>
      🌙 Lumi is ready.
    </Text>
    {state.installedTo && (
      <Text dimColor>
        Installed to: {state.installedTo}
      </Text>
    )}
    <Box marginTop={1} flexDirection='column'>
      <Text bold>Launch</Text>
      {state.platform === 'mac' && <Text>  open -a Lumi</Text>}
      {state.platform === 'linux' && <Text>  Lumi    (AppImage) / search "Lumi" in your app launcher</Text>}
      {state.platform === 'windows' && <Text>  Start menu → Lumi</Text>}
    </Box>
  </Box>
);

const ErrorScreen: React.FC<{ state: State }> = ({ state }) => {
  // Surface the last warn/error entries — that's the actual
  // subprocess stderr (pnpm install output, build errors, etc.).
  // The truncated log tail in ProgressView gets cleared the moment
  // the screen scrolls, so dropping them here at full width gives
  // the user something they can actually act on.
  const failureContext = state.logs
    .filter((e) => e.level === 'warn' || e.level === 'error' || e.level === 'cmd')
    .slice(-25);
  return (
    <Box flexDirection='column' marginTop={1}>
      <Text color='red' bold>
        Install failed.
      </Text>
      <Text color='red'>{state.error ?? 'Unknown error'}</Text>
      {failureContext.length > 0 && (
        <Box flexDirection='column' marginTop={1}>
          <Text dimColor>Last subprocess output (most recent):</Text>
          {failureContext.map((entry, idx) => (
            <Text
              key={`fail-${entry.ts}-${idx}`}
              color={entry.level === 'error' ? 'red' : entry.level === 'cmd' ? 'magenta' : 'yellow'}
            >
              {entry.message}
            </Text>
          ))}
        </Box>
      )}
      <Box marginTop={1} flexDirection='column'>
        <Text dimColor>
          The build dir was kept for debugging — see logs above. Re-run after fixing the underlying issue, or pass --yes
          to skip prompts.
        </Text>
      </Box>
    </Box>
  );
};

// ── Auth detection ─────────────────────────────────────────────────────────

interface AuthDetection {
  method: AuthMethod | null;
  cloneUrl: string;
  hasGhCli: boolean;
  ghAuthOk: boolean;
  sshOk: boolean;
}

async function detectAuth(): Promise<AuthDetection> {
  // 1. GITHUB_TOKEN env — validate against the API.
  if (ENV_TOKEN) {
    const ok = await validateToken(ENV_TOKEN);
    if (ok) {
      return {
        method: 'env',
        cloneUrl: `https://${ENV_TOKEN}@github.com/${REPO}.git`,
        hasGhCli: hasCommand('gh'),
        ghAuthOk: false,
        sshOk: false,
      };
    }
  }
  // 2. gh CLI
  const hasGhCli = hasCommand('gh');
  let ghAuthOk = false;
  if (hasGhCli) {
    const status = spawnSync('gh', ['auth', 'status'], { stdio: 'ignore' });
    if (status.status === 0) {
      const view = spawnSync('gh', ['repo', 'view', REPO], { stdio: 'ignore' });
      ghAuthOk = view.status === 0;
    }
  }
  if (ghAuthOk) {
    return { method: 'gh', cloneUrl: '', hasGhCli, ghAuthOk, sshOk: false };
  }
  // 3. SSH
  const sshOk = await checkSshAuth();
  if (sshOk) {
    return { method: 'ssh', cloneUrl: `git@github.com:${REPO}.git`, hasGhCli, ghAuthOk, sshOk };
  }
  return { method: null, cloneUrl: '', hasGhCli, ghAuthOk, sshOk };
}

async function validateToken(token: string): Promise<boolean> {
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}`, {
      headers: {
        Authorization: `token ${token}`,
        'User-Agent': 'lumi-build-installer',
      },
    });
    return res.status === 200;
  } catch {
    return false;
  }
}

async function checkSshAuth(): Promise<boolean> {
  return new Promise((resolve) => {
    const child = spawn(
      'ssh',
      ['-T', 'git@github.com', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no'],
      { stdio: ['ignore', 'pipe', 'pipe'] }
    );
    let output = '';
    child.stdout?.on('data', (d) => (output += d.toString()));
    child.stderr?.on('data', (d) => (output += d.toString()));
    child.on('exit', () => resolve(/successfully authenticated/i.test(output)));
    child.on('error', () => resolve(false));
    setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* noop */
      }
      resolve(false);
    }, 5000);
  });
}

function hasCommand(name: string): boolean {
  const which = process.platform === 'win32' ? 'where' : 'which';
  const result = spawnSync(which, [name], { stdio: 'ignore' });
  return result.status === 0;
}

// ── Install orchestration ──────────────────────────────────────────────────

/**
 * Run the install pipeline and resolve with the final install path.
 * Throws on any subprocess failure — the caller's `.catch` routes that
 * to the error screen. Build-tool prerequisites (Bun, Node, pnpm) are
 * not checked here; the bash/ps1 bootstrap is responsible for getting
 * those into PATH before this TSX is ever spawned.
 */
async function runInstall(state: State, dispatch: React.Dispatch<Action>): Promise<string> {
  const log = (level: LogEntry['level'], message: string) =>
    dispatch({
      type: 'append-log',
      entry: { ts: new Date().toISOString(), level, message },
    });

  try {
    log('info', `Repo:    ${REPO}@${BRANCH}`);
    log('info', `Workdir: ${WORK_DIR}`);
    log('info', `Mode:    ${state.installType === 'clean' ? 'CLEAN install' : 'update'}`);
    log('info', `Auth:    ${describeAuth(state.authMethod ?? 'pat')}`);

    if (state.installType === 'clean') {
      log('step', 'Wiping previous Lumi data');
      await wipeLumiData(state.platform, log);
    }

    log('step', `Cloning ${REPO}@${BRANCH}`);
    await cloneRepo(state, log);

    log('step', 'Installing workspace dependencies');
    await runWorkspaceDeps(log);

    log('step', 'Building workspace + engine + desktop');
    await runBuilds(state, log);

    log('step', 'Installing Lumi');
    const installedTo = await installApp(state, log);

    log('step', 'Launching Lumi');
    await launchApp(state, log);

    log('ok', '🌙 Done.');
    cleanupWorkdir(log);
    return installedTo;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    log('error', msg);
    // KEEP the workdir on failure — the user almost always needs to
    // poke around in there to figure out what broke (cd <workdir> &&
    // pnpm install --reporter=ndjson, etc.). Skip cleanupWorkdir
    // here; the bash bootstrap's SKIP_CLEANUP env var still applies
    // for the success path.
    log('info', `Build dir kept at ${WORK_DIR} for debugging`);
    throw new Error(msg);
  }
}

// ── Step: clean wipe ───────────────────────────────────────────────────────

async function wipeLumiData(platform: Platform, log: (lvl: LogEntry['level'], msg: string) => void) {
  const targets: string[] = [
    path.join(homedir(), '.lumi'),
    path.join(homedir(), '.aionui-config'),
    path.join(homedir(), '.aionui-dev'),
  ];
  if (platform === 'mac') {
    targets.push(
      path.join(homedir(), 'Library', 'Application Support', 'Lumi'),
      path.join(homedir(), 'Library', 'Application Support', 'Lumi-Dev'),
      path.join(homedir(), 'Library', 'Logs', 'Lumi'),
      path.join(homedir(), 'Library', 'Caches', 'com.aionui.lumi'),
    );
  } else if (platform === 'linux') {
    targets.push(
      path.join(homedir(), '.config', 'Lumi'),
      path.join(homedir(), '.config', 'Lumi-Dev'),
      path.join(homedir(), '.local', 'share', 'Lumi'),
    );
  } else if (platform === 'windows') {
    const appData = process.env.APPDATA;
    if (appData) {
      targets.push(path.join(appData, 'Lumi'), path.join(appData, 'Lumi-Dev'));
    }
  }
  for (const target of targets) {
    if (existsSync(target)) {
      try {
        rmSync(target, { recursive: true, force: true });
        log('ok', `Wiped ${target}`);
      } catch (err) {
        log('warn', `Could not wipe ${target}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
  }
}

// ── Step: clone ────────────────────────────────────────────────────────────

async function cloneRepo(state: State, log: (lvl: LogEntry['level'], msg: string) => void) {
  if (existsSync(WORK_DIR)) rmSync(WORK_DIR, { recursive: true, force: true });
  mkdirSync(path.dirname(WORK_DIR), { recursive: true });

  if (state.authMethod === 'gh') {
    await execStream('gh', ['repo', 'clone', REPO, WORK_DIR, '--', '--depth', '1', '--branch', BRANCH], log);
  } else {
    if (!state.cloneUrl) throw new Error('No clone URL available — auth probably failed.');
    await execStream(
      'git',
      ['clone', '--depth', '1', '--branch', BRANCH, '--recurse-submodules', state.cloneUrl, WORK_DIR],
      log,
    );
  }
  log('ok', `Cloned to ${WORK_DIR}`);
}

// ── Step: workspace dep install ────────────────────────────────────────────

async function runWorkspaceDeps(log: (lvl: LogEntry['level'], msg: string) => void) {
  log('info', 'pnpm install (root workspace)');
  await execStream('pnpm', ['install', '--frozen-lockfile'], log, { cwd: WORK_DIR });
  log('ok', 'Root workspace deps installed');

  const enginePkg = path.join(WORK_DIR, 'packages', 'lumi-engine', 'package.json');
  if (existsSync(enginePkg)) {
    log('info', 'pnpm install for lumi-engine');
    await execStream('pnpm', ['install', '--frozen-lockfile'], log, {
      cwd: path.join(WORK_DIR, 'packages', 'lumi-engine'),
    });
    log('ok', 'lumi-engine deps installed');
  }

  log('info', 'bun install for desktop');
  await execStream('bun', ['install'], log, { cwd: path.join(WORK_DIR, 'apps', 'desktop') });
  log('ok', 'Desktop deps installed');
}

// ── Step: builds ───────────────────────────────────────────────────────────

async function runBuilds(state: State, log: (lvl: LogEntry['level'], msg: string) => void) {
  log('info', 'pnpm -r build (workspace packages)');
  await execStream('pnpm', ['-r', 'build'], log, { cwd: WORK_DIR });
  log('ok', 'Workspace packages built');

  log('info', 'Building Lumi engine');
  await execStream('pnpm', ['run', 'build'], log, {
    cwd: path.join(WORK_DIR, 'packages', 'lumi-engine'),
  });
  log('ok', 'Engine built');

  log('info', `Building desktop app (this takes 3–5 min)`);
  if (state.platform === 'mac') {
    await execStream('bun', ['run', 'dist:mac'], log, { cwd: path.join(WORK_DIR, 'apps', 'desktop') });
  } else if (state.platform === 'linux') {
    await execStream('bun', ['run', 'build'], log, { cwd: path.join(WORK_DIR, 'apps', 'desktop') });
  } else if (state.platform === 'windows') {
    await execStream('bun', ['run', 'dist:win'], log, { cwd: path.join(WORK_DIR, 'apps', 'desktop') });
  }
  log('ok', 'Desktop app built');
}

// ── Step: install ──────────────────────────────────────────────────────────

async function installApp(state: State, log: (lvl: LogEntry['level'], msg: string) => void): Promise<string> {
  if (state.platform === 'mac') return installMac(log);
  if (state.platform === 'linux') return installLinux(log);
  if (state.platform === 'windows') return installWindows(log);
  throw new Error(`Unsupported platform: ${state.platform}`);
}

async function installMac(log: (lvl: LogEntry['level'], msg: string) => void): Promise<string> {
  const outDir = path.join(WORK_DIR, 'apps', 'desktop', 'out');
  const dmg = pickNewest(outDir, '.dmg');
  if (!dmg) throw new Error(`No .dmg in ${outDir}`);
  log('info', `DMG: ${path.basename(dmg)}`);

  const attachOut = await captureCommand('hdiutil', ['attach', dmg, '-nobrowse', '-noverify']);
  const mountMatch = attachOut.match(/(\/Volumes\/[^\t\n]+)/);
  let mountPoint = mountMatch ? mountMatch[1].trim() : '';
  if (!mountPoint || !existsSync(mountPoint)) {
    const candidates = readdirSync('/Volumes')
      .filter((n) => n.startsWith('Lumi'))
      .map((n) => path.join('/Volumes', n));
    mountPoint = candidates[0] ?? '';
  }
  if (!mountPoint || !existsSync(mountPoint)) throw new Error('Could not resolve DMG mount point');
  log('info', `Mounted at: ${mountPoint}`);

  const apps = readdirSync(mountPoint).filter((n) => n.endsWith('.app'));
  const appName = apps[0];
  if (!appName) {
    spawnSync('hdiutil', ['detach', mountPoint, '-quiet']);
    throw new Error('No .app bundle inside DMG');
  }
  const appSrc = path.join(mountPoint, appName);

  let targetDir = '/Applications';
  let writable = (() => {
    try {
      const probe = path.join(targetDir, `.lumi-write-test-${process.pid}`);
      mkdirSync(probe);
      rmSync(probe, { recursive: true, force: true });
      return true;
    } catch {
      return false;
    }
  })();
  if (!writable) {
    log('warn', '/Applications not writable — falling back to ~/Applications');
    targetDir = path.join(homedir(), 'Applications');
    mkdirSync(targetDir, { recursive: true });
  }
  const target = path.join(targetDir, appName);
  if (existsSync(target)) {
    rmSync(target, { recursive: true, force: true });
  }
  await execStream('cp', ['-R', appSrc, `${targetDir}/`], log);
  spawnSync('xattr', ['-d', 'com.apple.quarantine', target]);
  spawnSync('hdiutil', ['detach', mountPoint, '-quiet']);
  log('ok', `Installed to ${target}`);
  return target;
}

async function installLinux(log: (lvl: LogEntry['level'], msg: string) => void): Promise<string> {
  const outDir = path.join(WORK_DIR, 'apps', 'desktop', 'out');
  const appImage = pickNewest(outDir, '.AppImage');
  const debFile = pickNewest(outDir, '.deb');
  if (appImage) {
    const target = path.join(homedir(), '.local', 'bin', 'Lumi');
    mkdirSync(path.dirname(target), { recursive: true });
    await execStream('cp', [appImage, target], log);
    await execStream('chmod', ['+x', target], log);
    log('ok', `AppImage installed to ${target}`);
    return target;
  }
  if (debFile) {
    await execStream('sudo', ['dpkg', '-i', debFile], log);
    log('ok', 'Package installed (dpkg)');
    return debFile;
  }
  throw new Error(`No installable artifact in ${outDir}`);
}

async function installWindows(log: (lvl: LogEntry['level'], msg: string) => void): Promise<string> {
  const outDir = path.join(WORK_DIR, 'apps', 'desktop', 'out');
  const exeFile = pickNewest(outDir, '.exe');
  if (!exeFile) throw new Error(`No .exe installer in ${outDir}`);
  log('info', `Running ${path.basename(exeFile)} (silent install)`);
  await execStream(exeFile, ['/S'], log);
  log('ok', 'Windows installer completed');
  return exeFile;
}

function pickNewest(dir: string, ext: string): string | null {
  if (!existsSync(dir)) return null;
  const matches = readdirSync(dir)
    .filter((n) => n.toLowerCase().endsWith(ext.toLowerCase()))
    .map((n) => path.join(dir, n));
  if (matches.length === 0) return null;
  matches.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  return matches[0];
}

// ── Step: launch ───────────────────────────────────────────────────────────

async function launchApp(state: State, log: (lvl: LogEntry['level'], msg: string) => void) {
  if (process.env.NO_LAUNCH === '1') return;
  if (state.platform === 'mac') {
    const candidates = ['/Applications/Lumi.app', path.join(homedir(), 'Applications', 'Lumi.app')];
    for (const c of candidates) {
      if (existsSync(c)) {
        spawnSync('open', ['-n', '-a', c], { stdio: 'ignore' });
        log('info', `Launched ${c}`);
        return;
      }
    }
  } else if (state.platform === 'linux') {
    for (const bin of ['Lumi', 'lumi']) {
      if (hasCommand(bin)) {
        spawn(bin, [], { detached: true, stdio: 'ignore' }).unref();
        log('info', `Launched ${bin}`);
        return;
      }
    }
  } else if (state.platform === 'windows') {
    const startMenu = path.join(process.env.APPDATA ?? '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Lumi.lnk');
    if (existsSync(startMenu)) {
      spawnSync('cmd', ['/c', 'start', '', startMenu], { stdio: 'ignore' });
      log('info', `Launched via ${startMenu}`);
    }
  }
}

// ── Cleanup ────────────────────────────────────────────────────────────────

function cleanupWorkdir(log: (lvl: LogEntry['level'], msg: string) => void) {
  if (process.env.SKIP_CLEANUP === '1') {
    log('info', `Kept ${WORK_DIR} (SKIP_CLEANUP=1)`);
    return;
  }
  if (existsSync(WORK_DIR)) {
    try {
      rmSync(WORK_DIR, { recursive: true, force: true });
      log('info', 'Temp source removed');
    } catch {
      /* noop */
    }
  }
}

// ── Subprocess helpers ─────────────────────────────────────────────────────

async function captureCommand(cmd: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    let out = '';
    const child = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout?.on('data', (d) => (out += d.toString()));
    child.stderr?.on('data', (d) => (out += d.toString()));
    child.on('exit', (code) => (code === 0 ? resolve(out) : reject(new Error(`${cmd} exited ${code}`))));
    child.on('error', reject);
  });
}

interface ExecOptions {
  cwd?: string;
}

/**
 * Spawn `cmd args` with stdout+stderr streamed line-by-line into the
 * Ink log buffer. Resolves on exit code 0; rejects otherwise. The
 * "rich terminal UI" the user asked for boils down to: subprocess
 * output is captured here (never written to the live tty) and surfaces
 * inside the bordered ProgressView.
 */
async function execStream(
  cmd: string,
  args: string[],
  log: (lvl: LogEntry['level'], msg: string) => void,
  opts: ExecOptions = {},
): Promise<void> {
  log('cmd', `$ ${cmd} ${args.join(' ')}${opts.cwd ? ` (in ${opts.cwd})` : ''}`);
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      cwd: opts.cwd,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: process.env,
    });
    // Don't truncate stderr — the actual error message (pnpm install
    // failed because of … / npm registry 502 / etc.) is the whole
    // point of streaming it. Truncate stdout aggressively since it's
    // the noisy progress bars we don't need persisted.
    //
    // Buffer the most recent stderr lines so we can embed them in
    // the rejected Error. The previous version surfaced just the
    // exit code ("pnpm exited with code 1") with no context — the
    // user reported being unable to debug an actual install failure.
    const recentStderr: string[] = [];
    const recentStdoutTail: string[] = [];
    streamLines(child.stdout, (line) => {
      log('info', truncate(line, 110));
      recentStdoutTail.push(line);
      if (recentStdoutTail.length > 8) recentStdoutTail.shift();
    });
    streamLines(child.stderr, (line) => {
      log('warn', truncate(line, 240));
      recentStderr.push(line);
      if (recentStderr.length > 40) recentStderr.shift();
    });
    child.on('exit', (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      const lines: string[] = [];
      lines.push(`${cmd} exited with code ${code}`);
      if (recentStderr.length > 0) {
        lines.push('--- recent stderr ---');
        lines.push(...recentStderr);
      } else if (recentStdoutTail.length > 0) {
        // Some tools (looking at you, pnpm) emit failure detail to
        // stdout instead of stderr. Fall back to the stdout tail
        // when stderr was empty.
        lines.push('--- recent stdout ---');
        lines.push(...recentStdoutTail);
      }
      reject(new Error(lines.join('\n')));
    });
    child.on('error', reject);
  });
}

function streamLines(stream: NodeJS.ReadableStream | null, onLine: (line: string) => void): void {
  if (!stream) return;
  let buffer = '';
  stream.on('data', (chunk: Buffer | string) => {
    buffer += chunk.toString();
    const lines = buffer.split(/\r?\n/);
    buffer = lines.pop() ?? '';
    for (const line of lines) {
      if (line.trim()) onLine(line);
    }
  });
  stream.on('end', () => {
    if (buffer.trim()) onLine(buffer);
  });
}

function truncate(line: string, max = 110): string {
  return line.length <= max ? line : `${line.slice(0, max - 1)}…`;
}

// ── Entry point ────────────────────────────────────────────────────────────

// Pass the resolved TTY stream explicitly so Ink's raw-mode
// keystroke capture works under `curl | bash` and on Bun builds
// where process.stdin.isTTY is undefined.
const { waitUntilExit } = render(<App />, {
  stdin: INK_STDIN,
  exitOnCtrlC: true,
});
await waitUntilExit();
