// tools/test/test-ci-pipeline-wiring.cjs

/**
 * ==============================================================================
 * MODULE: CI Pipeline Wiring Guard
 * DESCRIPTION:
 * Pins how ci.yml wires its root, "Validate and plan", into the three OS lanes
 * and Release: the shape of the run graph, the plan's outputs, what each lane
 * caller passes and waits for, which secrets and permissions reach a job, how
 * the root validates inputs before it deepens the clone for the plan, and the
 * release preflight that runs before any side effect. It also proves that no
 * job of ci.yml and no step of the pipeline can be switched off, or have its
 * failure swallowed, while the run stays green.
 *
 * ROOT CAUSE ENCODED:
 * After the pipeline was split into one reusable workflow per OS, a review
 * found single-line edits that kept every contract test green and broke a
 * release: `release: false` on the Windows caller published without the exe,
 * plan's channel hard-wired to `dev` put a stable build on the dev feed,
 * `secrets: inherit` handed PAT_ERGOPTI to every box, a caller that stopped
 * needing validate let release publish over a red Validate, a deleted
 * Windows E2E step or preflight went unnoticed, and reverting plan's tag probe
 * to `git ls-remote ... | grep -q` read a network error as "tag free".
 * A second review found the next layer: `if: false` or an event condition on
 * a box caller skipped a whole OS (and release with it) on a green run;
 * `continue-on-error` on validate, plan or release forgave them; `if:
 * ${{ !cancelled() && false }}` or `npm run test:js || true` switched off
 * Validate; `if: false` on any gating step of a box (the Swift XCTest, the
 * Hammerspoon suite, the Windows LLM suites, a Linux smoke, the Linux evidence
 * gate itself), `|| true` after a test runner, or a `| tee` without pipefail
 * turned a failure green; and the Windows compiler-warning and LLM gates could
 * drop their failing exit or move into the release-only job.
 * The run graph then became hard to read: two roots each wired to every first
 * job, lanes that started with two or three jobs, and several leaf jobs per
 * lane wired to the release. GitHub flattens a called workflow into the run's
 * graph, so only its entry and exit jobs decide what the graph shows. The plan
 * job merged into validate, which deepens its clone for the plan only after
 * the checks, since several test:js gates shell out to git.
 *
 * FEATURES & RATIONALE:
 * 1. Derived, not listed: every plan output must come from a plan step that
 *    writes it, every caller input must be the plan output of the same name,
 *    and release must wait, directly or through a lane, on every other job of
 *    ci.yml except the dispatch-only verdict. No job forgives failure; OS callers
 *    consume exact selection outputs. Release and the manual verdict retain
 *    their separate event guards.
 * 2. Private secrets reach a lane only on a release run, through one exact
 *    expression; the public Sparkle key is the only allow-listed exception.
 *    Every pipeline file reads contents only; release alone may write.
 * 3. The root checks TOML, then deepens its checkout with one exact script,
 *    which retries a failed fetch and rejects a clone still shallow. The
 *    parallel core matrix has a separate shallow checkout for its JS gates,
 *    properties and main-only mutations, pinned by test-desktop-ci-evidence.
 * 4. One root, one lane per OS: ci.yml has exactly one job without needs, the
 *    root; each lane caller needs the root alone; release needs the root and
 *    core and the three lanes, nothing else. Each OS exposes the same five
 *    phases with exactly one entry and one final verdict. macOS also observes
 *    its native tooltip canvas independently after E2E and before the verdict.
 * 5. Only the steps in STEP_CONDITIONS set an `if`, each exactly its own, and
 *    e2e-linux's harnesses run under !cancelled(). No script swallows a test
 *    runner's failure with `|| true`, and every `| tee` runs under pipefail.
 * 6. The release preflight precedes the first step that writes to GitHub, the
 *    release steps keep their order, and both tag probes capture ls-remote
 *    before testing it (N5). Every assets-* upload fails on a missing file and
 *    outlives a next-day re-run, and release merges them into one folder. The
 *    asset list of the preflight is derived from the release notes by
 *    tools/test/test-release-notes-assets-are-uploaded.cjs.
 * 7. Each rule is also run on a mutated copy of the real workflow, for every
 *    form a review used, and must report it: a rule that cannot fail is
 *    reported as broken.
 * ==============================================================================
 */

'use strict';

const pipeline = require('./ci-pipeline.cjs');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const manual = require('../ci/manual-ci-lanes.cjs');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ENTRY = pipeline.ENTRY_REL;
const MACOS_BOX = '.github/workflows/ci-macos.yml';
const WINDOWS_BOX = '.github/workflows/ci-windows.yml';
const LINUX_BOX = '.github/workflows/ci-linux.yml';
const BOXES = [MACOS_BOX, WINDOWS_BOX, LINUX_BOX];
// The run graph's single root: the repository-wide checks, then the release
// plan every lane and release read.
const ROOT = 'validate';
const RELEASE_INPUT = `\${{ needs.${ROOT}.outputs.release == 'true' }}`;
const RELEASE_IF = `github.event_name == 'push' && needs.${ROOT}.outputs.release == 'true'`;
const NOT_CANCELLED = '${{ !cancelled() }}';
const MANUAL_RUNTIME_IF =
	"${{ github.event_name == 'workflow_dispatch' && !inputs.release && !cancelled() }}";
const MANUAL_RUNTIME_EVIDENCE_IF =
	"${{ github.event_name == 'workflow_dispatch' && !inputs.release && !cancelled() }}";
const MANUAL_VERDICT_IF = "always() && github.event_name == 'workflow_dispatch'";
const LANE_IF = (os) => `needs.${ROOT}.outputs.lane_${os} == 'true'`;
// Public by design: SUPublicEDKey ships inside every app, and a CI package
// without it cannot pass the launch gate.
const PUBLIC_SECRETS = new Set(['SPARKLE_PUBLIC_KEY']);
const PREFLIGHT = 'Refuse to publish an incomplete or already-taken release';
// A step that writes to GitHub: the tag, the release, its notes, or a push. A
// read such as `gh release view` is not one.
const SIDE_EFFECT = /\bgh api\b|\bgh release (?:create|edit|upload|delete)\b|\bgit\b[^\n]*\bpush\b/;

// Floors — today: 7 plan outputs, 3 callers, 6 release-only secrets (the
// Sparkle private key and the macOS code-signing .p12 and its password, then
// Windows' certificate, password and subject). Raised from 4 with the macOS
// certificate, so dropping either of its secrets from the caller fails here.
const MIN_PLAN_OUTPUTS = 7;
const MIN_GATED_SECRETS = 6;

// The root's checks after its setup, in order, with the one command each runs.
const VALIDATE_SETUP = 'Prepare plan validation';
const VALIDATE_CHECKS = [
	[
		'Check hotstring TOML files are sorted and formatted',
		'python tools/format_toml.py --hotstrings --all --check'
	]
];
// Then the plan: the clone is deepened only after every check, because
// several test:js gates shell out to git and were written against the default
// depth-1 clone. --unshallow gives the plan the full history of every shallow
// commit, HEAD included, and --tags every tag; the plan steps follow it. The
// fetch is tried three times, as actions/checkout tried the fetch-depth: 0
// fetch the plan used to get from it, since one network error here stops
// every lane; --unshallow is passed only while the clone is still shallow,
// because an attempt can fail after completing it and --unshallow refuses a
// complete clone. A third failure, or a clone still shallow, fails the step.
const DEEPEN_STEP = 'Deepen history for the release plan';
const DEEPEN_SCRIPT = [
	'set -euo pipefail',
	'for attempt in 1 2 3; do',
	'    unshallow=()',
	'    if [ "$(git rev-parse --is-shallow-repository)" = true ]; then',
	'        unshallow=(--unshallow)',
	'    fi',
	'    if git fetch --prune "${unshallow[@]}" --tags origin; then',
	'        break',
	'    fi',
	'    if [ "$attempt" = 3 ]; then',
	'        echo "::error::git fetch failed 3 times: the release plan needs the full history and every tag."',
	'        exit 1',
	'    fi',
	'    echo "::warning::git fetch failed (attempt $attempt of 3), retrying in 15 s."',
	'    sleep 15',
	'done',
	'if [ "$(git rev-parse --is-shallow-repository)" != false ]; then',
	'    echo "::error::the clone is still shallow after the fetch: the release plan would number a tag from a partial history."',
	'    exit 1',
	'fi'
];
// The deepening step exactly as ci.yml writes it, for the self-check fixtures.
const DEEPEN_TEXT =
	`      - name: ${DEEPEN_STEP}\n        shell: bash\n        run: |\n` +
	DEEPEN_SCRIPT.map((line) => `          ${line}\n`).join('');
// Any other way to deepen the clone: a step before the deepening one that runs
// it would hand the checks a clone deeper than the one they were written for.
const HISTORY_FETCH =
	/\bgit\b.*\b(?:fetch|pull|clone)\b|--(?:unshallow|deepen|depth|shallow-since|shallow-exclude)\b/;
const PLAN_STEPS = ['Load the Linux release artifact contract', 'Compute tag and version'];

// The only steps of the pipeline that may set an `if`, each with its only
// accepted value. Every other step runs whenever its job runs, so no edit can
// skip a gate while its job stays green.
const STEP_CONDITIONS = [
	[
		LINUX_BOX,
		'test-linux',
		'Emit Configuration assertion from failed unit log',
		"${{ failure() && !cancelled() && steps.linux_unit.outcome == 'failure' }}"
	],
	[
		LINUX_BOX,
		'test-linux',
		'Upload failed unit log',
		"${{ failure() && !cancelled() && steps.linux_unit.outcome == 'failure' }}"
	],
	[LINUX_BOX, 'e2e-linux', 'Qualify genuine Nix installed runtime', NOT_CANCELLED],
	[LINUX_BOX, 'test-linux', 'Run manual official runtime and model acceptance', MANUAL_RUNTIME_IF],
	[
		LINUX_BOX,
		'test-linux',
		'Upload manual runtime acceptance evidence',
		MANUAL_RUNTIME_EVIDENCE_IF
	],
	[LINUX_BOX, 'e2e-linux', 'Qualify native runtime prerequisites', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Qualify native retained FD SHA-256', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Prepare authenticated managed HTTP validation tools', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Qualify native managed HTTP public and retained output', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Qualify native updater archive pipeline', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Qualify archive crypto and bin parent source controls', NOT_CANCELLED],
	[ENTRY, 'core', 'Install shared UI browsers', "matrix.suite == 'js'"],
	[ENTRY, 'core', 'Test shared layer editor rendering', "matrix.suite == 'js'"],
	[ENTRY, 'core', 'Test shared physical shortcut rendering', "matrix.suite == 'js'"],
	[ENTRY, 'core', 'Test shared Versions installation rendering', "matrix.suite == 'js'"],
	[ENTRY, 'validate', 'Check hotstring TOML files are sorted and formatted', NOT_CANCELLED],
	[ENTRY, 'release', 'Create git tag', "steps.preflight.outputs.create_tag == 'true'"],
	[
		ENTRY,
		'release',
		'Create draft release, verify assets and publish',
		"steps.preflight.outputs.create_release == 'true'"
	],
	[
		ENTRY,
		'release',
		'Publish channel feed for Sparkle',
		"steps.preflight.outputs.skip_feed != 'true'"
	],
	[
		MACOS_BOX,
		'package-macos',
		'Smoke test built ErgoptiPlus.app (crash-on-launch guard)',
		'inputs.release'
	],
	[
		MACOS_BOX,
		'package-macos',
		'Retain packaged application startup evidence',
		'always() && inputs.release'
	],
	[
		MACOS_BOX,
		'package-macos',
		'Retain archive diagnostic session',
		"${{ always() && steps.swift-launcher-tests.outputs.archive_session_dir != '' }}"
	],
	[
		MACOS_BOX,
		'package-macos',
		'Retain closed TIS diagnostic session',
		"${{ always() && steps.swift-launcher-tests.outcome != 'skipped' && steps.swift-launcher-tests.outputs.tis_session_dir != '' }}"
	],
	[
		MACOS_BOX,
		'package-macos',
		'Upload Swift launcher failure transcript',
		"${{ failure() && steps.swift-launcher-tests.outcome == 'failure' }}"
	],
	[
		MACOS_BOX,
		'package-macos',
		'Run signed Hammerspoon program provider inventory',
		'${{ always() }}'
	],
	[MACOS_BOX, 'package-macos', 'Retain native Hammerspoon provider inventory', '${{ always() }}'],
	[MACOS_BOX, 'package-macos', 'Observe native notification constructors', '${{ always() }}'],
	[
		MACOS_BOX,
		'package-macos',
		'Retain native notification constructor observations',
		'${{ always() }}'
	],
	[MACOS_BOX, 'package-macos', 'Observe native Apple Shortcuts discovery', '${{ always() }}'],
	[MACOS_BOX, 'package-macos', 'Observe native global application switcher', '${{ always() }}'],
	[
		MACOS_BOX,
		'package-macos',
		'Retain native global application switcher observations',
		'${{ always() }}'
	],
	[MACOS_BOX, 'package-macos', 'Retain native Apple Shortcuts observation', '${{ always() }}'],
	[MACOS_BOX, 'package-macos', 'Sign declared archives with Sparkle EdDSA key', 'inputs.release'],
	[MACOS_BOX, 'package-macos', 'Generate Sparkle appcast', 'inputs.release'],
	[MACOS_BOX, 'package-macos', 'Package latest keylayout bundle', 'inputs.release'],
	[MACOS_BOX, 'launch', 'Retain launch evidence', 'always()'],
	[
		MACOS_BOX,
		'tooltip-canvas',
		'Retain native captures, source, provisioning and retirement receipts',
		'always()'
	],
	[
		WINDOWS_BOX,
		'test-ahk',
		'Download AutoHotkey v2 runtime',
		"steps.cache-ahk.outputs.cache-hit != 'true'"
	],
	[WINDOWS_BOX, 'e2e-ahk', 'Download E2E runtime', "steps.cache-ahk.outputs.cache-hit != 'true'"],
	[WINDOWS_BOX, 'package-windows', 'Sign and verify ErgoptiPlus.exe', 'inputs.release'],
	[WINDOWS_BOX, 'test-ahk', 'Annotate AHK results', 'always()'],
	[WINDOWS_BOX, 'test-ahk', 'Publish AHK execution manifest', 'always()'],
	[WINDOWS_BOX, 'test-ahk', 'Publish native desktop AHK evidence', 'always()'],
	[
		WINDOWS_BOX,
		'launch-windows',
		'Qualify programmable hotstrings in the actual compiled package',
		NOT_CANCELLED
	],
	[
		WINDOWS_BOX,
		'launch-windows',
		'Upload mandatory compiled programmable package evidence',
		'always()'
	],
	[WINDOWS_BOX, 'launch-windows', 'Upload mandatory launch evidence', 'always()'],
	// Failed upgrade setup/launch must retain its negative receipt before the verdict.
	[WINDOWS_BOX, 'launch-windows', 'Upload mandatory compiled upgrade failure evidence', 'always()'],
	[LINUX_BOX, 'install-linux', 'Prepare the container', "matrix.kind == 'install'"],
	[LINUX_BOX, 'install-linux', 'Create the installation user', "matrix.kind == 'install'"],
	[
		LINUX_BOX,
		'install-linux',
		'Install as an ordinary user without runtime dependencies',
		"matrix.kind == 'install'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'The installed tree is the one the daemon expects',
		"matrix.kind == 'install'"
	],
	[
		LINUX_BOX,
		'install-linux',
		"The unit suite on this distribution's LuaJIT",
		"matrix.kind == 'install'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Upload the native distro unit log',
		"${{ !cancelled() && matrix.kind == 'install' }}"
	],
	[LINUX_BOX, 'install-linux', 'Record mandatory distro evidence', "matrix.kind == 'install'"],
	[LINUX_BOX, 'install-linux', 'Upload mandatory distro evidence', "matrix.kind == 'install'"],
	[
		LINUX_BOX,
		'install-linux',
		'Install on ${{ matrix.image }} and verify the first run',
		"matrix.kind == 'first'"
	],
	[LINUX_BOX, 'install-linux', 'Record mandatory first-install evidence', "matrix.kind == 'first'"],
	[LINUX_BOX, 'install-linux', 'Upload mandatory first-install evidence', "matrix.kind == 'first'"],
	[LINUX_BOX, 'install-linux', 'Download the .deb built above (deb)', "matrix.kind == 'deb'"],
	[LINUX_BOX, 'install-linux', 'Install it the way a user would (deb)', "matrix.kind == 'deb'"],
	[
		LINUX_BOX,
		'install-linux',
		'The package installed the files the daemon reads (deb)',
		"matrix.kind == 'deb'"
	],
	[LINUX_BOX, 'install-linux', 'Launch the installed binary (deb)', "matrix.kind == 'deb'"],
	[
		LINUX_BOX,
		'install-linux',
		'The installed shared data tree resolves and opens (deb)',
		"matrix.kind == 'deb'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Record mandatory .deb smoke evidence (deb)',
		"matrix.kind == 'deb'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Upload mandatory .deb smoke evidence (deb)',
		"matrix.kind == 'deb'"
	],
	[LINUX_BOX, 'install-linux', 'Tools the job itself needs (rpm)', "matrix.kind == 'rpm'"],
	[LINUX_BOX, 'install-linux', 'Download the .rpm built above (rpm)', "matrix.kind == 'rpm'"],
	[LINUX_BOX, 'install-linux', 'Install it the way a user would (rpm)', "matrix.kind == 'rpm'"],
	[LINUX_BOX, 'install-linux', 'Launch the installed binary (rpm)', "matrix.kind == 'rpm'"],
	[
		LINUX_BOX,
		'install-linux',
		'The installed shared data tree resolves and opens (rpm)',
		"matrix.kind == 'rpm'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Record mandatory .rpm smoke evidence (rpm)',
		"matrix.kind == 'rpm'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Upload mandatory .rpm smoke evidence (rpm)',
		"matrix.kind == 'rpm'"
	],
	[LINUX_BOX, 'install-linux', 'Download the AppImage built above', "matrix.kind == 'appimage'"],
	[LINUX_BOX, 'install-linux', 'Unpack it (no FUSE on this runner)', "matrix.kind == 'appimage'"],
	[LINUX_BOX, 'install-linux', 'Launch it', "matrix.kind == 'appimage'"],
	[
		LINUX_BOX,
		'install-linux',
		'The bundled shared data tree resolves and opens',
		"matrix.kind == 'appimage'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Record mandatory AppImage smoke evidence',
		"matrix.kind == 'appimage'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Upload mandatory AppImage smoke evidence',
		"matrix.kind == 'appimage'"
	]
];
// test-linux runs each harness under !cancelled(), so a red one hides no other;
// tools/test/test-linux-ci-evidence.cjs pins which of its steps those are.
const HARNESS_JOB = 'e2e-linux';

// A command whose exit status is a gate: a test runner, a verdict script, a
// package build, an install or a launch. `|| true` after one turns its failure
// green; `|| {` with an explicit failing exit is still allowed.
const GATE_COMMAND = new RegExp(
	[
		/\btests\/(?:run\.lua|e2e\/run_e2e\.lua|hardware\/|distro\/)/,
		/\brun_all\.ahk\b|\brun_e2e\.ahk\b|\brun_llm_[a-z_]+\.ahk\b/,
		/\bswift (?:test|build)\b|\bplutil -lint\b/,
		/_test\.py\b|\bmacos_launch_gate\.py\b|\bmacos-release-launch\.py\b|\bmacos_tooltip_canvas\.py\b/,
		/\blinux-ci-evidence\.cjs (?:verify|record)\b|\bvalidate-ahk-suite-manifest\.cjs\b/,
		/\btools\/test\/test-[\w-]+\.(?:py|cjs)\b/,
		/\bprepare-linux-distro-unit\.sh\b/,
		/\bnpm run (?:test|build)\b/,
		/\bformat_toml\.py\b/,
		/\binstall\.sh\b|\binstalled_layout_check\.lua\b/,
		/\btools\/build\/build[\w-]*\.(?:sh|ps1)\b/,
		/\s--help\b/
	]
		.map((pattern) => pattern.source)
		.join('|')
);
const SWALLOWED = /\|\|\s*(?:true\b|:(?=\s|$)|exit\s+0\b|echo\b)/;

// The release steps, in the only order that publishes a complete release: the
// tag before the release, the release before its feed, the changelog before
// the notes that embed it.
const RELEASE_ORDER = [
	'Download all build artifacts',
	PREFLIGHT,
	'Create git tag',
	'Create draft release, verify assets and publish',
	'Publish channel feed for Sparkle',
	'Build changelog section',
	'Write release body with platform sections'
];

// Seven days on a release run, so a next-day "Re-run failed jobs" still finds
// the gated files; package-windows runs on release runs only.
const ASSET_RETENTION = new Map([
	['assets-macos', '${{ inputs.release && 7 || 1 }}'],
	['assets-windows', '7'],
	['assets-linux', '${{ inputs.release && 7 || 1 }}']
]);

const errors = [];

/** Drops full-line comments, which may name a forbidden form to explain it. */
function codeOf(body) {
	return body
		.split('\n')
		.filter((line) => !line.trimStart().startsWith('#'))
		.join('\n');
}

/**
 * Reads the one-line entries of a job-level block mapping such as `with:`,
 * `secrets:` or `outputs:`; null when the job has no such block.
 * @param {string} body Job body.
 * @param {string} key Job-level key.
 * @param {string} where Job id, for the messages.
 * @returns {Map<string, string>|null}
 */
function mappingOf(body, key, where) {
	const lines = body.split('\n');
	const at = lines.findIndex((line) => new RegExp(`^ {4}${key}:\\s*$`).test(line));
	if (at < 0) return null;
	const entries = new Map();
	for (let index = at + 1; index < lines.length; index++) {
		const line = lines[index];
		if (line.trim() === '' || line.trimStart().startsWith('#')) continue;
		if (line.length - line.trimStart().length <= 4) break;
		const entry = /^ {6}([A-Za-z0-9_-]+):\s*(\S.*?)\s*$/.exec(line);
		if (!entry) {
			errors.push(
				`${where}: unreadable ${key} entry '${line.trim()}'; write one \`key: value\` per line`
			);
			continue;
		}
		if (entries.has(entry[1])) errors.push(`${where}: ${key}.${entry[1]} is set twice`);
		entries.set(entry[1], entry[2]);
	}
	return entries;
}

/** Runs `read`, recording a loader error instead of stopping every other check. */
function attempt(read) {
	try {
		return read();
	} catch (error) {
		errors.push(error.message);
		return null;
	}
}

/**
 * Returns a step's script as logical lines: comments dropped, and a line ending
 * in a bash `\` or a PowerShell backtick joined with the next.
 * @param {string} body Step body.
 * @returns {string[]}
 */
function logicalLines(body) {
	const joined = [];
	let pending = '';
	for (const line of pipeline.runOf(body) ?? []) {
		const text = line.trim();
		if (text.startsWith('#')) continue;
		if (/(?:\\|`)$/.test(text)) {
			pending += `${text.slice(0, -1)} `;
			continue;
		}
		joined.push(pending + text);
		pending = '';
	}
	if (pending !== '') joined.push(pending.trim());
	return joined;
}

/**
 * Proves a rule can fail: once `from` is replaced by `to` in the pipeline file
 * `rel`, `problemsOf` must report something for the mutated pipeline.
 * @param {string} what The review form this reproduces.
 * @param {string} rel Pipeline file to mutate.
 * @param {string} from Exact text, present once in the file.
 * @param {string} to Replacement.
 * @param {(files: Array<{rel: string, text: string}>) => string[]} problemsOf The rule.
 */
function mustCatch(what, rel, from, to, problemsOf) {
	const text = pipeline.file(rel);
	const count = text.split(from).length - 1;
	if (count !== 1) {
		errors.push(
			`self-check "${what}": expected one '${from.trim()}' in ${rel}, found ${count}; re-derive the fixture`
		);
		return;
	}
	const mutated = pipeline
		.files()
		.map((entry) => (entry.rel === rel ? { rel, text: text.replace(from, () => to) } : entry));
	let problems;
	try {
		problems = problemsOf(mutated);
	} catch (error) {
		problems = [error.message];
	}
	if (problems.length === 0)
		errors.push(`self-check "${what}" went unnoticed, so this rule cannot fail`);
}

// ========================================
// ========================================
// ======= 1/ The Root And Its Plan =======
// ========================================
// ========================================

const plan = pipeline.job(ROOT);
const planSteps = pipeline.steps(plan);
const planOutputs = mappingOf(plan, 'outputs', ROOT) ?? new Map();
if (planOutputs.size < MIN_PLAN_OUTPUTS) {
	errors.push(
		`${ROOT} declares ${planOutputs.size} plan output(s) (floor ${MIN_PLAN_OUTPUTS}); the outputs block moved`
	);
}
for (const [key, value] of planOutputs) {
	const source = new RegExp(`^\\$\\{\\{ steps\\.([A-Za-z0-9_-]+)\\.outputs\\.${key} \\}\\}$`).exec(
		value
	);
	if (!source) {
		errors.push(
			`${ROOT} output ${key} must forward \${{ steps.<id>.outputs.${key} }}, got: ${value}`
		);
		continue;
	}
	const owner = planSteps.find(
		(candidate) => pipeline.stepField(candidate.body, 'id') === source[1]
	);
	if (!owner) {
		errors.push(`${ROOT} output ${key} reads step '${source[1]}', which ${ROOT} does not have`);
	} else if (
		!(source[1] === 'lanes' && ['lane_windows', 'lane_macos', 'lane_linux'].includes(key)) &&
		!new RegExp(`\\bemit ${key} |"${key}=`).test(codeOf(owner.body))
	) {
		errors.push(`${ROOT} output ${key} reads step '${source[1]}', which never writes ${key}`);
	}
}
for (const match of pipeline
	.text()
	.matchAll(/needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)/g)) {
	// Only the root publishes a plan; a lane's own jobs read their scenarios
	// from package-macos, which test-macos-swift-launcher-ci.cjs pins.
	if (match[1] === 'package-macos') continue;
	if (match[1] !== ROOT) {
		errors.push(
			`needs.${match[1]}.outputs.${match[2]} is read, but the plan lives in ${ROOT} alone`
		);
	} else if (!planOutputs.has(match[2])) {
		errors.push(`needs.${ROOT}.outputs.${match[2]} is read but ${ROOT} declares no such output`);
	}
}

/**
 * Lists how the root could stop running its checks as written, or plan from a
 * partial history: it checks out once, at the default depth, and no step
 * before the deepening one fetches history; after its setup it runs exactly
 * the four checks, each with its exact command, then the deepening step with
 * its exact script, then the two plan steps.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
function rootProblems(files) {
	const problems = [];
	const root = pipeline
		.jobsOfText(files.find((entry) => entry.rel === ENTRY).text, ENTRY)
		.find((candidate) => candidate.id === ROOT);
	if (!root) return [`ci.yml has no ${ROOT} job`];
	const rootSteps = pipeline.steps(root.body);
	// The checks were written against a depth-1 clone without tags; a deeper
	// checkout changes what the test:js gates that shell out to git see.
	const checkouts = rootSteps.filter((candidate) =>
		/^actions\/checkout@/.test(pipeline.stepField(candidate.body, 'uses') ?? '')
	);
	if (checkouts.length !== 1 || pipeline.stepField(checkouts[0].body, 'with') !== null) {
		problems.push(
			`${ROOT} must check out once, with no with: block: its checks run on the default depth-1 clone`
		);
	}
	const deepenAt = rootSteps.findIndex((candidate) => candidate.name === DEEPEN_STEP);
	for (const earlier of deepenAt < 0 ? rootSteps : rootSteps.slice(0, deepenAt)) {
		const fetching = logicalLines(earlier.body).find((line) => HISTORY_FETCH.test(line));
		if (fetching !== undefined) {
			problems.push(
				`${ROOT} step "${earlier.name || earlier.body.trim().split('\n')[0]}" fetches history before ` +
					`"${DEEPEN_STEP}", so the checks would not run on the depth-1 clone: ${fetching}`
			);
		}
	}
	const setupAt = rootSteps.findIndex((candidate) => candidate.name === VALIDATE_SETUP);
	const after =
		setupAt < 0
			? []
			: rootSteps.slice(setupAt + 1).filter((step) => step.name !== 'Select native OS lanes');
	const expected = [...VALIDATE_CHECKS.map(([name]) => name), DEEPEN_STEP, ...PLAN_STEPS];
	if (JSON.stringify(after.map((candidate) => candidate.name)) !== JSON.stringify(expected)) {
		problems.push(
			`${ROOT} must run exactly, after "${VALIDATE_SETUP}": ${expected.join(' | ')}; ` +
				`got: ${after.map((candidate) => candidate.name).join(' | ')}`
		);
		return problems;
	}
	for (const [index, [name, command]] of VALIDATE_CHECKS.entries()) {
		const run = pipeline.stepField(after[index].body, 'run');
		if (run !== command)
			problems.push(`${ROOT} step "${name}" must run exactly \`${command}\`, got: ${run}`);
	}
	const deepen = pipeline.runOf(after[VALIDATE_CHECKS.length].body) ?? [];
	if (JSON.stringify(deepen) !== JSON.stringify(DEEPEN_SCRIPT)) {
		const differs = deepen.findIndex((line, index) => line !== DEEPEN_SCRIPT[index]);
		problems.push(
			`${ROOT} step "${DEEPEN_STEP}" must run exactly its pinned script; first difference at line ` +
				`${(differs < 0 ? Math.min(deepen.length, DEEPEN_SCRIPT.length) : differs) + 1}: ` +
				`${deepen[differs] ?? '(missing)'}`
		);
	}
	return problems;
}

errors.push(...rootProblems(pipeline.files()));
for (const [what, from, to] of [
	[
		'fetch-depth: 0 on the root checkout',
		'    steps:\n      # A depth-1 clone without tags, which the checks below expect.\n      - uses: actions/checkout@v4\n',
		'    steps:\n      # A depth-1 clone without tags, which the checks below expect.\n      - uses: actions/checkout@v4\n        with:\n          fetch-depth: 0\n'
	],
	[
		'a history fetch between the checkout and the setup',
		'      - uses: actions/checkout@v4\n\n      - uses: actions/setup-python@v5\n',
		'      - uses: actions/checkout@v4\n\n      - name: Fetch all history\n        run: git fetch --depth=2147483647 --tags origin\n\n      - uses: actions/setup-python@v5\n'
	],
	[
		'a history fetch inside the setup step',
		'      - name: Prepare plan validation\n',
		'      - name: Fetch history\n        run: git pull --unshallow\n\n      - name: Prepare plan validation\n'
	],
	[
		'the deepening fetch without --unshallow',
		'        unshallow=(--unshallow)\n',
		'        unshallow=()\n'
	],
	[
		'the deepening fetch without --tags',
		' --prune "${unshallow[@]}" --tags origin; then\n',
		' --prune "${unshallow[@]}" origin; then\n'
	],
	[
		'the deepening fetch tried once',
		'          for attempt in 1 2 3; do\n',
		'          for attempt in 1; do\n'
	],
	[
		'a failed deepening fetch forgiven',
		'                  exit 1\n              fi\n              echo "::warning::',
		'                  exit 0\n              fi\n              echo "::warning::'
	],
	[
		'the completeness check dropped',
		'          if [ "$(git rev-parse --is-shallow-repository)" != false ]; then\n',
		'          if false; then\n'
	],
	['the deepening step dropped', DEEPEN_TEXT, '']
]) {
	mustCatch(what, ENTRY, from, to, rootProblems);
}
// Moving the fetch ahead of the checks is two edits, so it gets its own copy.
{
	const text = pipeline.file(ENTRY);
	const deepen = `${DEEPEN_TEXT}\n`;
	const setup = `      - name: ${VALIDATE_SETUP}\n`;
	if (text.split(deepen).length !== 2 || text.split(setup).length !== 2) {
		errors.push('self-check "the deepening fetch before the checks": re-derive the fixture');
	} else {
		const moved = text.replace(deepen, '').replace(setup, () => `${deepen}${setup}`);
		const files = pipeline
			.files()
			.map((entry) => (entry.rel === ENTRY ? { rel: ENTRY, text: moved } : entry));
		if (rootProblems(files).length === 0) {
			errors.push(
				'self-check "the deepening fetch before the checks" went unnoticed, so this rule cannot fail'
			);
		}
	}
}

// The Linux lane names its tarball with this output and release writes it into
// the notes and a shell command, so an unsafe name must fail the plan.
const contract = attempt(() =>
	pipeline.runOf(pipeline.step(plan, 'Load the Linux release artifact contract'))
);
if (contract !== null) {
	const at = (pattern) => contract.findIndex((line) => pattern.test(line.trim()));
	const checkAt = at(
		/^if \[\[ ! "\$asset_name" =~ \^\[A-Za-z0-9\._\+-\]\+\\\.tar\\\.gz\$ \]\]; then$/
	);
	const exitAt = at(/^exit 1$/);
	const emitAt = at(/^echo "linux_bundle=\$asset_name" >> "\$GITHUB_OUTPUT"$/);
	if (checkAt < 0 || !(checkAt < exitAt && exitAt < emitAt)) {
		errors.push(
			'plan must refuse an unsafe Linux bundle name (exit 1) before it emits linux_bundle'
		);
	}
}

// ======================================
// ======================================
// ======= 2/ The Lane Callers ==========
// ======================================
// ======================================

// What each caller needs is pinned with the graph shape in section 3.
const callers = pipeline.calls();
if (callers.length !== 3)
	errors.push(`ci.yml must call the three OS lanes, found ${callers.length} call(s)`);
let gatedSecrets = 0;
for (const call of callers) {
	const body = pipeline.job(call.id);
	// The release input is the only computed one: a false value on a release
	// run skips the lane's release build while the lane still succeeds.
	const inputs = mappingOf(body, 'with', call.id) ?? new Map();
	if (inputs.get('release') !== RELEASE_INPUT) {
		errors.push(
			`caller ${call.id} must pass release: ${RELEASE_INPUT}, got: ${inputs.get('release')}`
		);
	}
	for (const [key, value] of inputs) {
		if (key === 'release') continue;
		if (value !== `\${{ needs.${ROOT}.outputs.${key} }}`) {
			errors.push(
				`caller ${call.id} must pass ${key}: \${{ needs.${ROOT}.outputs.${key} }}, got: ${value}`
			);
		}
	}
	const inlineSecrets = /^ {4}secrets:[ \t]*([^\s#].*)$/m.exec(body);
	if (inlineSecrets) {
		errors.push(
			`caller ${call.id} must list each secret it passes, never secrets: ${inlineSecrets[1].trim()}`
		);
	}
	for (const [key, value] of mappingOf(body, 'secrets', call.id) ?? new Map()) {
		if (PUBLIC_SECRETS.has(key)) {
			if (value !== `\${{ secrets.${key} }}`)
				errors.push(`caller ${call.id} must pass ${key}: \${{ secrets.${key} }}`);
			continue;
		}
		gatedSecrets++;
		const gated = `\${{ needs.${ROOT}.outputs.release == 'true' && secrets.${key} || '' }}`;
		if (value !== gated) {
			errors.push(
				`caller ${call.id} passes the private ${key} outside a release run; it must be exactly ${gated}, got: ${value}`
			);
		}
	}
}
if (gatedSecrets < MIN_GATED_SECRETS) {
	errors.push(
		`found ${gatedSecrets} release-only secret(s) passed to the lanes (floor ${MIN_GATED_SECRETS}); the secrets parse drifted`
	);
}
if (/^\s*secrets:\s*inherit\b/m.test(pipeline.text())) {
	errors.push(
		'no job may use secrets: inherit, which hands every secret, PAT_ERGOPTI included, to the called workflow'
	);
}

// Release waits for every original job. The dispatch-only verdict cannot run
// on a release push and is checked independently below.
const topJobs = pipeline.jobs(ENTRY);
const needsById = new Map(
	topJobs.map((candidate) => [candidate.id, pipeline.needsOf(candidate.body)])
);
const awaited = new Set();
const pending = [...(needsById.get('release') ?? [])];
while (pending.length > 0) {
	const id = pending.pop();
	if (awaited.has(id)) continue;
	awaited.add(id);
	pending.push(...(needsById.get(id) ?? []));
}
for (const candidate of topJobs) {
	if (
		candidate.id !== 'release' &&
		candidate.id !== 'manual-verdict' &&
		!awaited.has(candidate.id)
	) {
		errors.push(`release can publish without waiting for ${candidate.id}`);
	}
}

// ============================================
// ============================================
// ======= 3/ One Root, One Lane Per OS =======
// ============================================
// ============================================

/**
 * Lists every way the run graph could stop reading as one root, one lane per
 * OS and one release. GitHub draws no box around a called workflow: it
 * flattens its jobs into the run's graph, so a second job without needs in a
 * lane is a second edge from the root, and a second job nothing needs is a
 * second edge into the release. Release still needs the root: it reads the
 * plan from it, and a plan handed through the lanes' outputs would depend on
 * those outputs surviving "Re-run failed jobs", where a lost value skips the
 * release instead of failing it.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
function graphProblems(files) {
	const problems = [];
	const topLevel = pipeline.jobsOfText(files.find((entry) => entry.rel === ENTRY).text, ENTRY);
	const roots = topLevel
		.filter((candidate) => pipeline.needsOf(candidate.body).length === 0)
		.map((candidate) => candidate.id);
	if (JSON.stringify(roots) !== JSON.stringify([ROOT])) {
		problems.push(
			`ci.yml must have exactly one root job, ${ROOT}, that needs nothing; got [${roots.join(', ')}]`
		);
	}
	const lanes = topLevel.filter((candidate) => pipeline.field(candidate.body, 'uses') !== null);
	for (const lane of lanes) {
		const needs = pipeline.needsOf(lane.body);
		if (JSON.stringify(needs) !== JSON.stringify([ROOT])) {
			problems.push(
				`caller ${lane.id} must need the root alone, [${ROOT}], so the root fans out to one job per lane; got [${needs.join(', ')}]`
			);
		}
	}
	const release = topLevel.find((candidate) => candidate.id === 'release');
	const releaseNeeds = release ? [...pipeline.needsOf(release.body)].sort() : [];
	const expectedRelease = [ROOT, 'core', ...lanes.map((lane) => lane.id)].sort();
	if (JSON.stringify(releaseNeeds) !== JSON.stringify(expectedRelease)) {
		problems.push(
			`release must need exactly the root and the three lanes, [${expectedRelease.join(', ')}]; got [${releaseNeeds.join(', ')}]`
		);
	}
	const verdict = topLevel.find((candidate) => candidate.id === 'manual-verdict');
	if (
		!verdict ||
		JSON.stringify(pipeline.needsOf(verdict.body)) !==
			JSON.stringify([ROOT, 'core', 'macos', 'windows', 'linux'])
	) {
		problems.push('the manual verdict must wait for the root, shared core and every OS result');
	}
	if (
		topLevel.length !== 7 ||
		topLevel.some(
			(job) =>
				!['validate', 'core', 'macos', 'windows', 'linux', 'manual-verdict', 'release'].includes(
					job.id
				)
		)
	) {
		problems.push('ci.yml must contain only the original jobs and the manual verdict');
	}
	for (const rel of BOXES) {
		const entry = files.find((candidate) => candidate.rel === rel);
		if (!entry) {
			problems.push(`${rel} is not part of the pipeline`);
			continue;
		}
		const jobs = pipeline.jobsOfText(entry.text, rel);
		const sequence = {
			[MACOS_BOX]: ['test-hs', 'e2e-hs', 'package-macos', 'launch', 'macos-ok'],
			[WINDOWS_BOX]: ['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows', 'windows-ok'],
			[LINUX_BOX]: ['test-linux', 'e2e-linux', 'package-linux', 'install-linux', 'linux-ok']
		}[rel];
		// Preserve the five original phases and add exactly one independent native observation.
		const exposed =
			rel === MACOS_BOX
				? [...sequence.slice(0, 2), 'tooltip-canvas', ...sequence.slice(2)]
				: sequence;
		if (JSON.stringify(jobs.map((job) => job.id)) !== JSON.stringify(exposed)) {
			problems.push(
				`${rel} must expose unit tests, E2E, package, installed launch and verdict in order`
			);
		}
		for (const [index, id] of sequence.entries()) {
			const job = jobs.find((candidate) => candidate.id === id);
			const expected =
				index === 0
					? []
					: index === 4
						? [...sequence.slice(0, 4), ...(rel === MACOS_BOX ? ['tooltip-canvas'] : [])]
						: [sequence[index - 1]];
			if (!job || JSON.stringify(pipeline.needsOf(job.body)) !== JSON.stringify(expected)) {
				problems.push(`${rel} ${id} must need exactly ${expected.join(', ')}`);
			}
			if (job && pipeline.field(job.body, 'if') !== (index === 4 ? 'always()' : null)) {
				problems.push(`${rel} ${id} must run on every profile; only the verdict uses always()`);
			}
		}
		if (rel === MACOS_BOX) {
			const canvas = jobs.find((candidate) => candidate.id === 'tooltip-canvas');
			if (!canvas || JSON.stringify(pipeline.needsOf(canvas.body)) !== JSON.stringify(['e2e-hs'])) {
				problems.push(`${rel} tooltip-canvas must need exactly e2e-hs`);
			}
			if (canvas && pipeline.field(canvas.body, 'if') !== null) {
				problems.push(`${rel} tooltip-canvas must run on every profile without a job condition`);
			}
		}
		const needsOfJob = new Map(
			jobs.map((candidate) => [candidate.id, pipeline.needsOf(candidate.body)])
		);
		const entries = jobs
			.filter((candidate) => needsOfJob.get(candidate.id).length === 0)
			.map((candidate) => candidate.id);
		const needed = new Set([...needsOfJob.values()].flat());
		const exits = jobs
			.filter((candidate) => !needed.has(candidate.id))
			.map((candidate) => candidate.id);
		if (entries.length !== 1) {
			problems.push(
				`${rel} must have exactly one entry job, which needs no job of its file; got [${entries.join(', ')}]`
			);
		}
		if (exits.length !== 1) {
			problems.push(
				`${rel} must have exactly one exit job, which no job of its file needs; got [${exits.join(', ')}]`
			);
		}
		for (const [id, needs] of needsOfJob) {
			for (const need of needs) {
				if (!needsOfJob.has(need))
					problems.push(`${rel} job ${id} needs ${need}, which is not a job of its file`);
			}
		}
	}
	return problems;
}

for (const [what, from, to] of [
	['missing mandatory canvas graph node', '  tooltip-canvas:\n', '  omitted-tooltip-canvas:\n'],
	[
		'canvas bypassed by the macOS verdict',
		'    needs: [test-hs, e2e-hs, package-macos, launch, tooltip-canvas]\n',
		'    needs: [test-hs, e2e-hs, package-macos, launch]\n'
	],
	[
		'canvas depends on packaging instead of native E2E',
		"  tooltip-canvas:\n    name: 'Native tooltip canvas · 12 captures'\n    needs: e2e-hs\n",
		"  tooltip-canvas:\n    name: 'Native tooltip canvas · 12 captures'\n    needs: package-macos\n"
	],
	['conditional native canvas job', '  tooltip-canvas:\n', '  tooltip-canvas:\n    if: false\n']
]) {
	mustCatch(what, MACOS_BOX, from, to, graphProblems);
}

errors.push(...graphProblems(pipeline.files()));
for (const [what, rel, from, to] of [
	[
		'a second root in ci.yml',
		ENTRY,
		'\njobs:\n',
		'\njobs:\n  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo lint\n'
	],
	[
		'a caller that no longer needs the root',
		ENTRY,
		"    name: 'Linux'\n    needs: [validate]\n",
		"    name: 'Linux'\n"
	],
	[
		'a caller that also needs another lane',
		ENTRY,
		"    name: 'Windows'\n    needs: [validate]\n",
		"    name: 'Windows'\n    needs: [validate, macos]\n"
	],
	[
		'release that no longer waits for a lane',
		ENTRY,
		'    needs: [validate, core, macos, windows, linux]\n',
		'    needs: [validate, macos, windows]\n'
	],
	[
		'release that stops reading the plan from the root',
		ENTRY,
		'    needs: [validate, core, macos, windows, linux]\n',
		'    needs: [macos, windows, linux]\n'
	],
	['a second entry in the macOS lane', MACOS_BOX, '    needs: test-hs\n', ''],
	[
		'a second entry in the Linux lane',
		LINUX_BOX,
		"    name: 'Install and launch · ${{ matrix.label }}'\n    runs-on: ubuntu-latest\n    needs: [package-linux]\n",
		"    name: 'Install and launch · ${{ matrix.label }}'\n    runs-on: ubuntu-latest\n"
	],
	['a second entry in the Windows lane', WINDOWS_BOX, '    needs: [test-ahk]\n', ''],
	[
		'a second exit in the macOS lane',
		MACOS_BOX,
		'    needs: package-macos\n',
		'    needs: test-hs\n'
	],
	[
		'a second exit in the Linux lane',
		LINUX_BOX,
		'      - install-linux\n    if: always()\n',
		'    if: always()\n'
	]
]) {
	mustCatch(what, rel, from, to, graphProblems);
}

// ==========================================
// ==========================================
// ======= 4/ Every Job Gates The Run =======
// ==========================================
// ==========================================

/**
 * Lists how a job of ci.yml could skip or forgive a lane. A skipped lane skips
 * release too, so a pull request shows green without that OS and a push to
 * dev or main silently publishes nothing; a forgiven job lets the run pass red.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
function topJobProblems(files) {
	const problems = [];
	const jobs = pipeline.jobsOfText(files.find((entry) => entry.rel === ENTRY).text, ENTRY);
	for (const candidate of jobs) {
		const expected =
			candidate.id === 'release'
				? RELEASE_IF
				: candidate.id === 'manual-verdict'
					? MANUAL_VERDICT_IF
					: ['windows', 'macos', 'linux'].includes(candidate.id)
						? LANE_IF(candidate.id)
						: null;
		const condition = pipeline.field(candidate.body, 'if');
		if (condition !== expected) {
			problems.push(
				expected === null
					? `ci.yml job ${candidate.id} must set no job-level if (got: ${condition}): a skipped lane reads as green`
					: `ci.yml job ${candidate.id} must keep exactly if: ${expected}, got: ${condition}`
			);
		}
		const forgiven = pipeline.field(candidate.body, 'continue-on-error');
		if (forgiven !== null) {
			problems.push(
				`ci.yml job ${candidate.id} sets continue-on-error: ${forgiven}; its failure must fail the run`
			);
		}
	}
	if (!jobs.some((candidate) => candidate.id === 'release'))
		problems.push('ci.yml has no release job');
	return problems;
}

/**
 * Lists every permission beyond `contents: read`: each pipeline file reads
 * contents only, and release alone may write, to create the tag, the release
 * and the feed.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
function permissionProblems(files) {
	const problems = [];
	for (const entry of files) {
		const lines = entry.text.split('\n');
		const at = lines.findIndex((line) => /^permissions:/.test(line));
		const granted = [];
		if (at >= 0) {
			const inline = lines[at].replace(/^permissions:/, '').trim();
			if (inline !== '') granted.push(inline);
			for (let index = at + 1; index < lines.length; index++) {
				if (lines[index].trim() === '' || lines[index].trimStart().startsWith('#')) continue;
				if (!/^\s/.test(lines[index])) break;
				granted.push(lines[index].trim());
			}
		}
		if (granted.join(', ') !== 'contents: read') {
			problems.push(
				`${entry.rel} must grant exactly permissions: contents: read, got: ${granted.join(', ') || 'none'}`
			);
		}
		for (const candidate of pipeline.jobsOfText(entry.text, entry.rel)) {
			const value = pipeline.field(candidate.body, 'permissions');
			const expected = entry.rel === ENTRY && candidate.id === 'release' ? 'contents: write' : null;
			if (value !== expected) {
				problems.push(
					`${entry.rel} job ${candidate.id} must ${expected ? `grant exactly ${expected}` : 'not widen the permissions'}, got: ${value}`
				);
			}
		}
	}
	return problems;
}

errors.push(...topJobProblems(pipeline.files()), ...permissionProblems(pipeline.files()));
for (const [what, from, to] of [
	['if: false on the Windows caller', '  windows:\n', '  windows:\n    if: false\n'],
	[
		'a push-only condition on the Linux caller',
		'  linux:\n',
		"  linux:\n    if: github.event_name == 'push'\n"
	],
	['always() on the macOS caller', '  macos:\n', '  macos:\n    if: always()\n'],
	['if: false on validate', '  validate:\n', '  validate:\n    if: false\n'],
	['continue-on-error on validate', '  validate:\n', '  validate:\n    continue-on-error: true\n'],
	[
		'continue-on-error on the Windows caller',
		'  windows:\n',
		'  windows:\n    continue-on-error: true\n'
	],
	['continue-on-error on release', '  release:\n', '  release:\n    continue-on-error: true\n'],
	[
		'a status function in release.if',
		`    if: ${RELEASE_IF}\n`,
		`    if: \${{ always() && ${RELEASE_IF} }}\n`
	]
]) {
	mustCatch(what, ENTRY, from, to, topJobProblems);
}
for (const [what, rel, from, to] of [
	[
		'write-all at the top of ci.yml',
		ENTRY,
		'permissions:\n  contents: read\n',
		'permissions: write-all\n'
	],
	[
		'contents: write for a lane',
		LINUX_BOX,
		'permissions:\n  contents: read\n',
		'permissions:\n  contents: write\n'
	],
	[
		'a write grant on a caller',
		ENTRY,
		"    name: 'macOS'\n",
		"    name: 'macOS'\n    permissions:\n      contents: write\n"
	]
]) {
	mustCatch(what, rel, from, to, permissionProblems);
}

// ============================================
// ============================================
// ======= 5/ The Windows Gating Suites =======
// ============================================
// ============================================

// Unit/native gates belong to test-ahk and the engine harness to e2e-ahk.
// Both run on every profile, before packaging in a fresh workspace. Each
// must keep the failing exit of its failure branch.
const WINDOWS_GATES = [
	{
		name: 'Install the shipped Kana layout for real probes',
		run: './tools/test/install-ci-kana-layout.ps1'
	},
	{
		name: 'Build and test native navigation event owner',
		run: './tools/build/build_windows_nav_owner.ps1'
	},
	{
		name: 'Manifest parity (AHK ↔ HS codegen equivalence)',
		run: 'npm run test:manifest-parity'
	},
	{
		name: 'Verify AHK source encoding (UTF-8 BOM + LF)',
		exits: [['if ($failures.Count -gt 0) {', '1']]
	},
	{
		name: 'Run AHK test suite',
		uses: [
			'tests\\run_all.ahk',
			'tools\\test\\validate-ahk-suite-manifest.cjs',
			'tools\\test\\test-ahk-suite-manifest.cjs" --ahk $ahk'
		],
		exits: [
			['if ($manifestExit -ne 0) {', '$manifestExit'],
			['if ($exit -ne 0) {', '$exit']
		]
	},
	{
		name: 'Run isolated AHK LLM suites',
		uses: ['run_llm_model_browser.ahk', 'run_llm_model_menu_disabled.ahk'],
		exits: [['if ($failed -gt 0) {', '1']]
	},
	{
		name: 'Check for AHK compiler warnings',
		uses: ['tests\\run_all.ahk', '--dry-run'],
		exits: [
			['if ($errors) {', '1'],
			['if ($warnings) {', '1']
		]
	},
	{
		name: 'Run E2E suite (Strategy A — pure engine injection)',
		job: 'e2e-ahk',
		uses: ['tests\\e2e\\run_e2e.ahk'],
		exits: [['if ($exit -ne 0) {', '$exit']]
	}
];

const testAhkAt = attempt(() => pipeline.locate('test-ahk'));
if (testAhkAt !== null && testAhkAt.file !== WINDOWS_BOX) {
	errors.push(`test-ahk must be a job of ${WINDOWS_BOX}, found in ${testAhkAt.file}`);
}
for (const gate of WINDOWS_GATES) {
	const found = attempt(() => pipeline.step(pipeline.job(gate.job ?? 'test-ahk'), gate.name));
	if (!found) {
		errors.push(
			`"${gate.name}" must run in job test-ahk of ${WINDOWS_BOX}, which runs on every run`
		);
		continue;
	}
	for (const key of ['if', 'continue-on-error']) {
		if (pipeline.stepField(found, key) !== null)
			errors.push(`"${gate.name}" gates the Windows box and must not set ${key}`);
	}
	if (gate.run && pipeline.stepField(found, 'run') !== gate.run) {
		errors.push(
			`"${gate.name}" must run exactly \`${gate.run}\`, got: ${pipeline.stepField(found, 'run')}`
		);
	}
	const script = pipeline.runOf(found) ?? [];
	const code = script.filter((line) => !line.trimStart().startsWith('#')).join('\n');
	for (const token of gate.uses ?? []) {
		if (!code.includes(token)) errors.push(`"${gate.name}" no longer runs ${token}`);
	}
	for (const [opener, exit] of gate.exits ?? []) {
		const block = attempt(() => pipeline.scriptBlock(script, opener));
		if (block !== null && !pipeline.blockExits(block, exit)) {
			errors.push(
				`"${gate.name}": the branch \`${opener}\` must end with exit ${exit}, so the failure fails the step`
			);
		}
	}
}

// ==============================================
// ==============================================
// ======= 6/ No Step Can Switch A Gate Off =====
// ==============================================
// ==============================================

const conditionKey = (rel, job, name) => `${rel} job ${job} step "${name}"`;
const CONDITIONS = new Map(
	STEP_CONDITIONS.map(([rel, job, name, condition]) => [conditionKey(rel, job, name), condition])
);
if (CONDITIONS.size !== STEP_CONDITIONS.length) errors.push('STEP_CONDITIONS names one step twice');

/**
 * Lists every step of the pipeline that could be skipped, or whose gate could
 * fail without failing the step.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
function stepProblems(files) {
	const problems = [];
	const unseen = new Set(CONDITIONS.keys());
	for (const entry of files) {
		for (const candidate of pipeline.jobsOfText(entry.text, entry.rel)) {
			for (const found of pipeline.steps(candidate.body)) {
				const where = conditionKey(entry.rel, candidate.id, found.name);
				unseen.delete(where);
				const condition = pipeline.stepField(found.body, 'if');
				const expected = CONDITIONS.get(where) ?? null;
				const harness =
					entry.rel === LINUX_BOX && candidate.id === HARNESS_JOB && condition === NOT_CANCELLED;
				if (condition !== expected && !harness) {
					problems.push(
						expected === null
							? `${where} sets if: ${condition}; only the steps in STEP_CONDITIONS may be conditional`
							: `${where} must keep exactly if: ${expected}, got: ${condition}`
					);
				}
				for (const line of logicalLines(found.body)) {
					if (GATE_COMMAND.test(line) && SWALLOWED.test(line)) {
						problems.push(`${where} swallows the failure of a gate: ${line.slice(0, 160)}`);
					}
				}
				// GitHub runs a step with no shell: key as `bash -e`, without
				// pipefail, so `runner | tee log` reports tee's success.
				const code = (pipeline.runOf(found.body) ?? []).filter(
					(line) => !line.trimStart().startsWith('#')
				);
				if (
					code.some((line) => /\|\s*tee\b/.test(line)) &&
					pipeline.stepField(found.body, 'shell') !== 'bash' &&
					!code.some((line) => /^\s*set -[a-z]*o pipefail\b/.test(line))
				) {
					problems.push(
						`${where} pipes into tee without pipefail (set -euo pipefail or shell: bash)`
					);
				}
			}
		}
	}
	for (const key of unseen)
		problems.push(`STEP_CONDITIONS lists ${key}, which the pipeline no longer has`);
	return problems;
}

// Raw failure logs are diagnostics, separate from success-only distro evidence.
for (const condition of [
	'',
	'false',
	'success()',
	"matrix.kind == 'install'",
	'always()',
	"always() && matrix.kind == 'install'"
]) {
	const head = '      - name: Upload the native distro unit log\n';
	mustCatch(
		'distro native unit raw log condition ' + condition,
		LINUX_BOX,
		head + "        if: ${{ !cancelled() && matrix.kind == 'install' }}\n",
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing native distro unit raw log upload',
	LINUX_BOX,
	'      - name: Upload the native distro unit log\n',
	'      - name: Omitted native distro unit raw log upload\n',
	stepProblems
);
// The assertion annotation belongs only to the original failed unit run.
// A skipped or renamed diagnostic must be observed by the normal wiring gate.
for (const condition of ['', 'success()', 'failure()', 'always()', 'false']) {
	const head = '      - name: Emit Configuration assertion from failed unit log\n';
	mustCatch(
		'Configuration assertion condition ' + condition,
		LINUX_BOX,
		head +
			"        if: ${{ failure() && !cancelled() && steps.linux_unit.outcome == 'failure' }}\n",
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing Configuration assertion diagnostic',
	LINUX_BOX,
	'      - name: Emit Configuration assertion from failed unit log\n',
	'      - name: Omitted Configuration assertion diagnostic\n',
	stepProblems
);
// Upload only closed receipts: the owned script corpus contains newline names,
// and recursively uploading its private fixture tree also exposes unnecessary data.
const NATIVE_INVENTORY_ARTIFACT = 'Retain native Hammerspoon provider inventory';
const NATIVE_INVENTORY_PATHS = [
	'${{ runner.temp }}/native-hs-program-providers/summary.json',
	'${{ runner.temp }}/native-hs-program-providers/*/receipt.json',
	'${{ runner.temp }}/native-hs-program-providers/*/physical-group.json',
	'${{ runner.temp }}/native-hs-program-providers/*/diagnostic-facts.json'
];

/** Rejects missing failure receipts and recursive private-fixture uploads. */
function nativeInventoryArtifactProblems(files) {
	const found = files
		.filter((entry) => entry.rel === MACOS_BOX)
		.flatMap((entry) => pipeline.jobsOfText(entry.text, entry.rel))
		.filter((job) => job.id === 'package-macos')
		.flatMap((job) => pipeline.steps(job.body))
		.filter((step) => step.name === NATIVE_INVENTORY_ARTIFACT);
	if (found.length !== 1) return ['native inventory artifact step must exist exactly once'];
	const body = found[0].body;
	const lines = body.split('\n');
	const pathAt = lines.indexOf('          path: |');
	const paths = [];
	if (pathAt >= 0) {
		for (const line of lines.slice(pathAt + 1)) {
			if (line.trim() === '') continue;
			if (!/^ {12}\S/.test(line)) break;
			paths.push(line.trim());
		}
	}
	const problems = [];
	if (JSON.stringify(paths) !== JSON.stringify(NATIVE_INVENTORY_PATHS))
		problems.push(
			'native inventory artifact must whitelist only summary and per-scenario closed receipts'
		);
	if (
		pipeline.stepField(body, 'if') !== '${{ always() }}' ||
		pipeline.stepField(body, 'uses') !== 'actions/upload-artifact@v4' ||
		!/^ {10}if-no-files-found: error$/m.test(body)
	)
		problems.push(
			'native inventory failure evidence must upload with always() and fail on missing files'
		);
	return problems;
}

errors.push(...nativeInventoryArtifactProblems(pipeline.files()));
const nativeInventoryPathBlock =
	'          path: |\n' + NATIVE_INVENTORY_PATHS.map((item) => `            ${item}\n`).join('');
for (const replacement of [
	'          path: ${{ runner.temp }}/native-hs-program-providers\n',
	'          path: ${{ runner.temp }}/native-hs-program-providers/**\n',
	nativeInventoryPathBlock +
		'            ${{ runner.temp }}/native-hs-program-providers/*/configuration/**\n',
	...NATIVE_INVENTORY_PATHS.map((item) =>
		nativeInventoryPathBlock.replace(`            ${item}\n`, '')
	)
]) {
	mustCatch(
		'native inventory closed evidence whitelist',
		MACOS_BOX,
		nativeInventoryPathBlock,
		replacement,
		nativeInventoryArtifactProblems
	);
}
for (const replacement of ['', '          if-no-files-found: warn\n']) {
	mustCatch(
		'native inventory missing-file refusal',
		MACOS_BOX,
		nativeInventoryPathBlock + '          if-no-files-found: error\n',
		nativeInventoryPathBlock + replacement,
		nativeInventoryArtifactProblems
	);
}

const NATIVE_ACTION_PROBES = [
	{
		run: 'Observe native notification constructors',
		retain: 'Retain native notification constructor observations',
		folder: 'native-notification-constructors',
		commands: [
			'python3 -m unittest discover -s tools/diagnostics/native_notification_constructors -p test_receipt.py -v',
			'python3 tools/diagnostics/native_notification_constructors/run_native.py',
			'--source-root "$GITHUB_WORKSPACE"',
			'--source-sha "$GITHUB_SHA"',
			'--output "$RUNNER_TEMP/native-notification-constructors"',
			'--download'
		],
		files: [
			'receipt.json',
			'physical-group.json',
			'summary.json',
			'failure.json',
			'pending-retirement.json'
		]
	},
	{
		run: 'Observe native global application switcher',
		retain: 'Retain native global application switcher observations',
		folder: 'native-global-switcher',
		commands: [
			"python3 -m unittest discover -s tools/diagnostics/native_global_switcher -p 'test_*.py' -v",
			'brew install lua@5.4',
			'test -x "$global_switcher_lua54"',
			'python3 tools/diagnostics/native_global_switcher/run_owner_controls.py --lua "$global_switcher_lua54"',
			'python3 tools/diagnostics/native_global_switcher/run_ci_probe.py',
			'--source-root "$GITHUB_WORKSPACE"',
			'--output "$RUNNER_TEMP/native-global-switcher"',
			'2>&1 | env -u ERGOPTI_NATIVE_HS_METADATA_TOKEN tee "$RUNNER_TEMP/native-global-switcher-ci.log"'
		],
		files: ['report.json', 'native-result.json'],
		extraPaths: ['${{ runner.temp }}/native-global-switcher-ci.log']
	}
];

/** Keeps native action probes mandatory and their artifacts limited to receipts. */
function nativeActionProbeProblems(files) {
	const steps = files
		.filter((entry) => entry.rel === MACOS_BOX)
		.flatMap((entry) => pipeline.jobsOfText(entry.text, entry.rel))
		.filter((job) => job.id === 'package-macos')
		.flatMap((job) => pipeline.steps(job.body));
	const problems = [];
	for (const spec of NATIVE_ACTION_PROBES) {
		const runs = steps.filter((step) => step.name === spec.run);
		const artifacts = steps.filter((step) => step.name === spec.retain);
		if (runs.length !== 1 || artifacts.length !== 1) {
			problems.push(`${spec.run} needs exactly one execution and evidence step`);
			continue;
		}
		const body = runs[0].body;
		if (
			pipeline.stepField(body, 'if') !== '${{ always() }}' ||
			pipeline.stepField(body, 'timeout-minutes') !== '5' ||
			!spec.commands.every((command) => (pipeline.runOf(body) ?? []).join('\n').includes(command))
		)
			problems.push(`${spec.run} must run its controls and exact native command independently`);
		const artifact = artifacts[0].body;
		const lines = artifact.split('\n');
		const at = lines.indexOf('          path: |');
		const paths = [];
		if (at >= 0) {
			for (const line of lines.slice(at + 1)) {
				if (!line.trim()) continue;
				if (!/^ {12}\S/.test(line)) break;
				paths.push(line.trim());
			}
		}
		const expected = spec.files.map((file) => '${{ runner.temp }}/' + spec.folder + '/' + file);
		expected.push(...(spec.extraPaths ?? []));
		if (
			JSON.stringify(paths) !== JSON.stringify(expected) ||
			pipeline.stepField(artifact, 'if') !== '${{ always() }}' ||
			pipeline.stepField(artifact, 'uses') !== 'actions/upload-artifact@v4' ||
			!/^ {10}if-no-files-found: error$/m.test(artifact)
		)
			problems.push(`${spec.retain} must retain only closed receipts and refuse absent evidence`);
	}
	return problems;
}

errors.push(...nativeActionProbeProblems(pipeline.files()));
for (const spec of NATIVE_ACTION_PROBES) {
	const steps = pipeline
		.jobsOfText(pipeline.file(MACOS_BOX), MACOS_BOX)
		.filter((job) => job.id === 'package-macos')
		.flatMap((job) => pipeline.steps(job.body));
	const run = steps.find((step) => step.name === spec.run);
	const artifact = steps.find((step) => step.name === spec.retain);
	if (!run || !artifact) continue;
	for (const command of spec.commands) {
		mustCatch(
			`omitted native action command ${command}`,
			MACOS_BOX,
			run.body,
			run.body.replace(command, '# omitted native command'),
			nativeActionProbeProblems
		);
	}
	for (const file of spec.files) {
		const path = '            ${{ runner.temp }}/' + spec.folder + '/' + file + '\n';
		mustCatch(
			`omitted native action receipt ${file}`,
			MACOS_BOX,
			artifact.body,
			artifact.body.replace(path, ''),
			nativeActionProbeProblems
		);
	}
	mustCatch(
		'recursive native action fixture upload',
		MACOS_BOX,
		artifact.body,
		artifact.body.replace(
			'          path: |\n',
			'          path: |\n            ${{ runner.temp }}/' + spec.folder + '/**\n'
		),
		nativeActionProbeProblems
	);
	mustCatch(
		'native action missing-file refusal',
		MACOS_BOX,
		artifact.body,
		artifact.body.replace('if-no-files-found: error', 'if-no-files-found: warn'),
		nativeActionProbeProblems
	);
}

mustCatch(
	'global switcher log receiver must exclude the metadata credential',
	MACOS_BOX,
	'2>&1 | env -u ERGOPTI_NATIVE_HS_METADATA_TOKEN tee "$RUNNER_TEMP/native-global-switcher-ci.log"',
	'2>&1 | tee "$RUNNER_TEMP/native-global-switcher-ci.log"',
	nativeActionProbeProblems
);

for (const condition of ['', 'false', 'success()']) {
	const head =
		'      - name: Retain native captures, source, provisioning and retirement receipts\n';
	mustCatch(
		'canvas retained evidence condition ' + condition,
		MACOS_BOX,
		head + '        if: always()\n',
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing mandatory native canvas evidence upload',
	MACOS_BOX,
	'      - name: Retain native captures, source, provisioning and retirement receipts\n',
	'      - name: Omitted native canvas evidence upload\n',
	stepProblems
);
mustCatch(
	'native canvas diagnostic failure swallowed after its continued command',
	MACOS_BOX,
	'          --output "$RUNNER_TEMP/tooltip-canvas-evidence"\n',
	'          --output "$RUNNER_TEMP/tooltip-canvas-evidence" || true\n',
	stepProblems
);

for (const [name, expected] of [
	['Run manual official runtime and model acceptance', MANUAL_RUNTIME_IF],
	['Upload manual runtime acceptance evidence', MANUAL_RUNTIME_EVIDENCE_IF]
]) {
	const head = `      - name: ${name}\n`;
	const from = head + `        if: ${expected}\n`;
	for (const changed of ['', 'false', NOT_CANCELLED, "${{ github.event_name == 'push' }}"]) {
		mustCatch(
			`manual runtime qualification condition changed: ${name}: ${changed || 'missing'}`,
			LINUX_BOX,
			from,
			head + (changed ? `        if: ${changed}\n` : ''),
			stepProblems
		);
	}
	mustCatch(
		`manual runtime qualification step omitted: ${name}`,
		LINUX_BOX,
		head,
		`      - name: Omitted ${name}\n`,
		stepProblems
	);
}
errors.push(...stepProblems(pipeline.files()));
for (const name of [
	'Run signed Hammerspoon program provider inventory',
	'Retain native Hammerspoon provider inventory',
	'Observe native notification constructors',
	'Retain native notification constructor observations',
	'Observe native global application switcher',
	'Retain native global application switcher observations',
	'Observe native Apple Shortcuts discovery',
	'Retain native Apple Shortcuts observation'
]) {
	const head = `      - name: ${name}\n`;
	for (const condition of ['', 'false', 'success()']) {
		mustCatch(
			`native provider ${name} condition ${condition}`,
			MACOS_BOX,
			head + '        if: ${{ always() }}\n',
			head + (condition ? `        if: ${condition}\n` : ''),
			stepProblems
		);
	}
	mustCatch(
		`missing mandatory ${name}`,
		MACOS_BOX,
		head,
		'      - name: Omitted native provider step\n',
		stepProblems
	);
}
for (const condition of ['', 'false', 'success()']) {
	const head = '      - name: Retain archive diagnostic session\n';
	const from =
		head +
		"        if: ${{ always() && steps.swift-launcher-tests.outputs.archive_session_dir != '' }}\n";
	mustCatch(
		'archive retained evidence condition ' + condition,
		MACOS_BOX,
		from,
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing mandatory archive evidence upload',
	MACOS_BOX,
	'      - name: Retain archive diagnostic session\n',
	'      - name: Omitted archive evidence upload\n',
	stepProblems
);

for (const condition of ['', 'false', 'success()']) {
	const head = '      - name: Retain closed TIS diagnostic session\n';
	const from =
		head +
		"        if: ${{ always() && steps.swift-launcher-tests.outcome != 'skipped' && steps.swift-launcher-tests.outputs.tis_session_dir != '' }}\n";
	mustCatch(
		'TIS retained evidence condition ' + condition,
		MACOS_BOX,
		from,
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing mandatory TIS evidence upload',
	MACOS_BOX,
	'      - name: Retain closed TIS diagnostic session\n',
	'      - name: Omitted TIS evidence upload\n',
	stepProblems
);
for (const condition of ['false', "matrix.kind == 'deb'"]) {
	mustCatch(
		`an AppImage launch routed through ${condition}`,
		LINUX_BOX,
		"      - name: Launch it\n        if: matrix.kind == 'appimage'\n",
		`      - name: Launch it\n        if: ${condition}\n`,
		stepProblems
	);
}
for (const [what, rel, from, to] of [
	[
		'if: false on the Swift XCTest step',
		MACOS_BOX,
		'      - name: Run Swift launcher tests\n',
		'      - name: Run Swift launcher tests\n        if: false\n'
	],
	[
		'a `- if: false` step head on the Hammerspoon suite',
		MACOS_BOX,
		'      - name: Run unit + meta tests\n',
		'      - if: false\n        name: Run unit + meta tests\n'
	],
	[
		'if: false on the Windows exe smoke',
		WINDOWS_BOX,
		'      - name: Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)\n',
		'      - name: Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)\n        if: false\n'
	],
	[
		'a harness condition outside test-linux',
		LINUX_BOX,
		'      - name: Launch the Flatpak\n',
		`      - name: Launch the Flatpak\n        if: ${NOT_CANCELLED}\n`
	],
	[
		'if: false on a test-linux harness',
		LINUX_BOX,
		`      - name: Round-trip real events through the kernel\n        if: ${NOT_CANCELLED}\n`,
		'      - name: Round-trip real events through the kernel\n        if: false\n'
	],
	[
		'if: false on the Linux evidence verdict',
		LINUX_BOX,
		'      - name: Assert all mandatory subjects ran and passed\n',
		'      - name: Assert all mandatory subjects ran and passed\n        if: false\n'
	],
	[
		'`|| true` after the Hammerspoon harness',
		MACOS_BOX,
		'run: lua5.4 tests/e2e/run_e2e.lua\n',
		'run: lua5.4 tests/e2e/run_e2e.lua || true\n'
	],
	[
		'`|| true` after the Linux unit suite',
		LINUX_BOX,
		'-- luajit tests/run.lua 2>&1 | tee',
		'-- luajit tests/run.lua || true 2>&1 | tee'
	],
	[
		'`|| true` after the continued evidence verdict',
		LINUX_BOX,
		'              --sha "$GITHUB_SHA"\n          echo "Linux driver:',
		'              --sha "$GITHUB_SHA" || true\n          echo "Linux driver:'
	],
	[
		'a `| tee` left without pipefail',
		LINUX_BOX,
		'          set -euo pipefail\n          luajit tests/e2e/run_e2e.lua | tee',
		'          luajit tests/e2e/run_e2e.lua | tee'
	]
]) {
	mustCatch(what, rel, from, to, stepProblems);
}

// =========================================
// =========================================
// ======= 7/ The Release Job ==============
// =========================================
// =========================================

const releaseSteps = pipeline.steps(pipeline.job('release'));
const indexOf = (name) => releaseSteps.findIndex((candidate) => candidate.name === name);
const releaseOrder = RELEASE_ORDER.map(indexOf);
if (releaseOrder.some((at, index) => at < 0 || (index > 0 && at <= releaseOrder[index - 1]))) {
	errors.push(
		`release must run ${RELEASE_ORDER.join(' < ')}; got: ${releaseSteps.map((candidate) => candidate.name).join(' | ')}`
	);
}
const preflightAt = indexOf(PREFLIGHT);
const firstEffectAt = releaseSteps.findIndex((candidate) =>
	SIDE_EFFECT.test(codeOf(candidate.body))
);
if (firstEffectAt < 0 || releaseSteps[firstEffectAt].name !== 'Create git tag') {
	errors.push(
		'the first release step that writes to GitHub must be "Create git tag"; re-derive the side-effect scan'
	);
} else if (!(preflightAt >= 0 && preflightAt < firstEffectAt)) {
	errors.push(
		`"${PREFLIGHT}" must run before "${releaseSteps[firstEffectAt].name}", the first side effect`
	);
}
if (preflightAt >= 0) {
	const preflight = releaseSteps[preflightAt].body;
	for (const key of ['if', 'continue-on-error']) {
		if (pipeline.stepField(preflight, key) !== null)
			errors.push(`"${PREFLIGHT}" must not set ${key}`);
	}
	for (const token of [
		'set -euo pipefail',
		'_ErgoptiPlus.app.zip.sig',
		'"appcast-${CHANNEL}.xml"',
		'taken=$(git ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}")',
		'if [ "$tagged" = "$GITHUB_SHA" ]; then'
	]) {
		if (!preflight.includes(token)) errors.push(`"${PREFLIGHT}" is missing ${token}`);
	}
	if (/ls-remote[^\n]*\|/.test(codeOf(preflight))) {
		errors.push(
			`"${PREFLIGHT}" must capture ls-remote before testing it: piped, a network error reads as "tag free"`
		);
	}
}

// N5: under pipefail, `git ls-remote ... | grep -q` read a failing ls-remote as
// "tag free" and planned a release; the listing is captured first.
const planMeta = attempt(() => pipeline.step(plan, 'Compute tag and version'));
if (planMeta !== null) {
	if (
		!planMeta.includes('taken=$(git ls-remote --tags origin "refs/tags/$tag")') ||
		!planMeta.includes('if [ -n "$taken" ]; then')
	) {
		errors.push(
			'plan must capture `git ls-remote --tags origin "refs/tags/$tag"` into taken and test it'
		);
	}
	if (/ls-remote[^\n]*\|/.test(codeOf(planMeta))) {
		errors.push('plan must not pipe ls-remote: under pipefail a network error reads as "tag free"');
	}
}

// Each assets-* upload fails when a file is missing, and keeps what release
// publishes long enough for a re-run.
const retained = new Map();
for (const entry of pipeline.files()) {
	for (const candidate of pipeline.jobs(entry.rel)) {
		for (const found of pipeline.steps(candidate.body)) {
			if (!/^actions\/upload-artifact@/.test(pipeline.stepField(found.body, 'uses') ?? ''))
				continue;
			const name = /^ {10}name: (assets-\S+)$/m.exec(found.body)?.[1];
			if (!name) continue;
			retained.set(name, /^ {10}retention-days: (.+)$/m.exec(found.body)?.[1] ?? null);
			if (!/^ {10}if-no-files-found: error$/m.test(found.body)) {
				errors.push(
					`the ${name} upload must set if-no-files-found: error, so a missing file fails its box`
				);
			}
		}
	}
}
for (const [name, days] of ASSET_RETENTION) {
	if (retained.get(name) !== days) {
		errors.push(`the ${name} upload must keep retention-days: ${days}, got: ${retained.get(name)}`);
	}
}
// release attaches every file under release-assets: all assets-* artifacts,
// merged into that one folder, where the preflight looks for each file.
const download = releaseSteps.find(
	(candidate) => candidate.name === 'Download all build artifacts'
);
for (const line of [
	'          pattern: assets-*',
	'          path: release-assets',
	'          merge-multiple: true'
]) {
	if (!download || !download.body.split('\n').includes(line)) {
		errors.push(`"Download all build artifacts" must set ${line.trim()}`);
	}
}

/** Checks the names GitHub renders after flattening each OS workflow. */
function namingProblems(files) {
	const problems = [];
	for (const entry of files) {
		for (const candidate of pipeline.jobsOfText(entry.text, entry.rel)) {
			const name = (pipeline.field(candidate.body, 'name') ?? '').replace(/^(['"])(.*)\1$/, '$2');
			const caller = pipeline.field(candidate.body, 'uses') !== null;
			const valid =
				entry.rel === ENTRY
					? caller
						? ['macOS', 'Windows', 'Linux'].includes(name)
						: name === 'Core / ${{ matrix.suite }}' ||
							/^(Validate|Release) \/ [A-Z][^/]+$/.test(name)
					: /^[A-Z]/.test(name) && !name.includes(' / ');
			if (!valid)
				problems.push(`${entry.rel} job ${candidate.id} has an invalid display name: ${name}`);
			for (const found of pipeline.steps(candidate.body)) {
				if (found.name && !/^[A-Z]/.test(found.name)) {
					problems.push(`${entry.rel} job ${candidate.id} has a lowercase step: ${found.name}`);
				}
				if (entry.rel !== ENTRY && /\b(?:macOS|Linux|Windows(?! Defender))\b/.test(found.name)) {
					problems.push(
						`${entry.rel} job ${candidate.id} repeats its zone in a step: ${found.name}`
					);
				}
			}
		}
	}
	return problems;
}

errors.push(...namingProblems(pipeline.files()));
for (const [what, rel, from, to] of [
	['an unqualified root name', ENTRY, "name: 'Validate / Checks and plan'", "name: 'Validate'"],
	['a lowercase lane job', WINDOWS_BOX, "name: 'Unit tests'", "name: 'unit tests'"],
	['a repeated lane prefix', MACOS_BOX, "name: 'Package'", "name: 'macOS / Package'"],
	['a lowercase step', WINDOWS_BOX, 'name: Run AHK test suite', 'name: run AHK test suite'],
	[
		'an extra root separator',
		ENTRY,
		"name: 'Validate / Checks and plan'",
		"name: 'Validate / Checks / Plan'"
	],
	[
		'a repeated step zone',
		LINUX_BOX,
		'name: Run the driver unit test suite',
		'name: Run Linux driver unit test suite'
	]
]) {
	mustCatch(what, rel, from, to, namingProblems);
}

/** Keeps the approved root group as the pipeline's only concurrency owner. */
function concurrencyProblems(files) {
	const problems = [];
	const expected =
		"group: ci-${{ github.ref }}-${{ github.event_name == 'workflow_dispatch' && github.run_id || 'automatic' }}\n" +
		'  cancel-in-progress: true';
	for (const entry of files) {
		const text = codeOf(entry.text);
		// Top-level keys and job fields have fixed columns. Text inside run: |
		// remains more deeply indented and must never acquire YAML ownership.
		const roots = [...text.matchAll(/^(?:concurrency|'concurrency'|"concurrency")[ \t]*:/gm)];
		if (entry.rel === ENTRY) {
			const header = text.split('\njobs:')[0];
			const blocks = [...header.matchAll(/^concurrency:\n((?: {2}[^\n]*\n|[ \t]*\n)*)/gm)];
			if (roots.length !== 1 || blocks.length !== 1 || blocks[0][1].trim() !== expected)
				problems.push(
					'manual CI must have one unique run group; automatic branch runs must still supersede each other'
				);
		} else if (roots.length !== 0) {
			problems.push(`${entry.rel}: a called workflow must not add its own concurrency group`);
		}
		for (const job of pipeline.jobsOfText(entry.text, entry.rel)) {
			if (/^ {4}(?:concurrency|'concurrency'|"concurrency")[ \t]*:/m.test(codeOf(job.body)))
				problems.push(
					`${entry.rel} job ${job.id}: a job must not add a concurrency group that cancels an independent manual run`
				);
		}
	}
	return problems;
}

// A caller or called lane can otherwise cancel one OS of an independent run.
for (const [what, rel, from, to] of [
	[
		'Windows caller concurrency collision',
		ENTRY,
		"  windows:\n    name: 'Windows'",
		"  windows:\n    concurrency:\n      group: ci-windows-${{ github.ref }}\n      cancel-in-progress: true\n    name: 'Windows'"
	],
	[
		'called macOS workflow concurrency collision',
		MACOS_BOX,
		'jobs:\n',
		'concurrency:\n  group: ci-macos-${{ github.ref }}\n  cancel-in-progress: true\n\njobs:\n'
	],
	[
		'called Linux job concurrency collision',
		LINUX_BOX,
		'  linux-ok:\n',
		'  linux-ok:\n    concurrency:\n      group: ci-linux-${{ github.ref }}\n      cancel-in-progress: true\n'
	],
	[
		'quoted caller concurrency collision',
		ENTRY,
		"  windows:\n    name: 'Windows'",
		"  windows:\n    'concurrency':\n      group: ci-windows-${{ github.ref }}\n      cancel-in-progress: true\n    name: 'Windows'"
	]
]) {
	mustCatch(what, rel, from, to, concurrencyProblems);
}

const rootConcurrencyBlock = pipeline
	.file(ENTRY)
	.match(/^concurrency:\n(?: {2}[^\n]*\n|[ \t]*\n)*/m)?.[0];
if (rootConcurrencyBlock === undefined) {
	errors.push(
		'the approved root concurrency block is missing; self-check fixtures have no source owner'
	);
} else {
	mustCatch('missing root concurrency', ENTRY, rootConcurrencyBlock, '', concurrencyProblems);
	mustCatch(
		'duplicate root concurrency',
		ENTRY,
		rootConcurrencyBlock,
		rootConcurrencyBlock + rootConcurrencyBlock,
		concurrencyProblems
	);
}

// A shell body may legitimately print or write this text. Scan YAML fields,
// rather than interpreting a script's embedded content as another group.
const concurrencyScriptAnchor = '      - name: Install Lua 5.4 + luarocks\n        run: |\n';
const concurrencyScriptSource = pipeline.file(MACOS_BOX);
if (concurrencyScriptSource.split(concurrencyScriptAnchor).length - 1 !== 1) {
	errors.push('the actual macOS run block must uniquely own the script-text concurrency fixture');
} else {
	const scriptFixture = pipeline.files().map((entry) =>
		entry.rel === MACOS_BOX
			? {
					rel: entry.rel,
					text: entry.text.replace(
						concurrencyScriptAnchor,
						concurrencyScriptAnchor +
							'          concurrency:\n            group: literal-script-content\n            cancel-in-progress: true\n'
					)
				}
			: entry
	);
	if (concurrencyProblems(scriptFixture).length !== 0)
		errors.push('a run block containing concurrency text must not be scanned as a YAML group');
}

errors.push(...concurrencyProblems(pipeline.files()));
for (const [what, from, to] of [
	[
		'manual branch collision',
		"-${{ github.event_name == 'workflow_dispatch' && github.run_id || 'automatic' }}",
		''
	],
	['manual duplicate-SHA collision', '&& github.run_id', '&& github.sha'],
	['automatic runs never supersede', "|| 'automatic'", '|| github.run_id'],
	['automatic cancellation disabled', 'cancel-in-progress: true', 'cancel-in-progress: false']
]) {
	mustCatch(what, ENTRY, from, to, concurrencyProblems);
}

/** Requires real reporter subprocess regressions on each native host before product units. */
function reporterLifecycleProblems(files) {
	const problems = [];
	for (const [rel, id, host, product, shell] of [
		[WINDOWS_BOX, 'test-ahk', 'windows-', 'Run AHK test suite', 'pwsh'],
		[MACOS_BOX, 'package-macos', 'macos-', 'Build release launcher', null]
	]) {
		const entry = files.find((candidate) => candidate.rel === rel);
		const job =
			entry && pipeline.jobsOfText(entry.text, rel).find((candidate) => candidate.id === id);
		if (!job || !(pipeline.field(job.body, 'runs-on') ?? '').startsWith(host)) {
			problems.push(`${rel} ${id} must qualify the reporter on its actual native host`);
			continue;
		}
		const steps = pipeline.steps(job.body);
		const matches = steps.filter((candidate) => candidate.name === REPORTER_STEP);
		const nodes = steps.filter(
			(candidate) => pipeline.stepField(candidate.body, 'uses') === 'actions/setup-node@v4'
		);
		const node = nodes[0];
		const unit = steps.findIndex((candidate) => candidate.name === product);
		const report = steps.findIndex((candidate) => candidate.name === REPORTER_STEP);
		if (
			matches.length !== 1 ||
			nodes.length !== 1 ||
			unit < 0 ||
			report <= steps.indexOf(node) ||
			report >= unit
		) {
			problems.push(
				`${rel} ${id} must run exactly one reporter self-test after Node and before product units`
			);
			continue;
		}
		if (
			!node.body.includes("          node-version-file: '.node-version'") ||
			pipeline.stepField(node.body, 'if') !== null ||
			pipeline.stepField(node.body, 'continue-on-error') !== null
		) {
			problems.push(`${rel} ${id} must unconditionally prepare the repository Node runtime`);
		}
		const test = matches[0];
		if (
			(pipeline.runOf(test.body) ?? []).join('\n').trim() !== REPORTER_COMMAND ||
			pipeline.stepField(test.body, 'if') !== null ||
			pipeline.stepField(test.body, 'continue-on-error') !== null ||
			pipeline.stepField(test.body, 'shell') !== shell ||
			pipeline.stepField(test.body, 'working-directory') !== null
		) {
			problems.push(
				`${rel} ${id} reporter self-tests must run the exact command and propagate failure on every profile`
			);
		}
	}
	return problems;
}

const REPORTER_STEP = 'Run reporter lifecycle self-tests';
const REPORTER_COMMAND = 'node tools/test/test-report.cjs';
errors.push(...reporterLifecycleProblems(pipeline.files()));
for (const [rel, shell] of [
	[WINDOWS_BOX, '        shell: pwsh\n'],
	[MACOS_BOX, '']
]) {
	const block = `      - name: ${REPORTER_STEP}\n${shell}        run: ${REPORTER_COMMAND}\n`;
	for (const [what, replacement] of [
		['missing native reporter self-test', ''],
		[
			'manual-only native reporter self-test',
			block.replace(
				`${shell}        run:`,
				`${shell}        if: github.event_name == 'workflow_dispatch'\n        run:`
			)
		],
		[
			'forgiven native reporter self-test',
			block.replace(`${shell}        run:`, `${shell}        continue-on-error: true\n        run:`)
		],
		[
			'swallowed native reporter exit',
			block.replace(REPORTER_COMMAND, REPORTER_COMMAND + ' || true')
		],
		['duplicate native reporter self-test', block + '\n' + block],
		[
			'renamed native reporter command',
			block.replace(REPORTER_COMMAND, 'node tools/test/report.cjs --help')
		]
	]) {
		mustCatch(what, rel, block, replacement, reporterLifecycleProblems);
	}
	const steps = pipeline.steps(
		pipeline
			.jobsOfText(pipeline.files().find((candidate) => candidate.rel === rel).text, rel)
			.find((candidate) => candidate.id === (rel === WINDOWS_BOX ? 'test-ahk' : 'package-macos'))
			.body
	);
	const node = steps.find(
		(candidate) => pipeline.stepField(candidate.body, 'uses') === 'actions/setup-node@v4'
	).body;
	mustCatch(
		'reporter before Node setup',
		rel,
		node + '\n\n' + block,
		block + '\n' + node + '\n',
		reporterLifecycleProblems
	);
}

/** Pins the real workflow ports of the callable manual selector. */
function manualLaneProblems(files) {
	const problems = [];
	const text = files.find((entry) => entry.rel === ENTRY).text;
	const jobs = pipeline.jobsOfText(text, ENTRY);
	const root = jobs.find((job) => job.id === ROOT);
	const verdict = jobs.find((job) => job.id === 'manual-verdict');
	const expectedInput = `  workflow_dispatch:
    inputs:
      os_lanes:
        description: Native OS lanes to validate (shared checks always run)
        type: choice
        required: true
        default: all
        options:
          - all
          - windows
          - macos
          - linux
          - windows+macos
          - windows+linux
          - macos+linux
`;
	if (text.split(expectedInput).length !== 2)
		problems.push('manual CI must expose exactly seven validated choices with default all');
	const selects = root
		? pipeline.steps(root.body).filter((step) => step.name === 'Select native OS lanes')
		: [];
	if (
		selects.length !== 1 ||
		pipeline.stepField(selects[0].body, 'id') !== 'lanes' ||
		pipeline.stepField(selects[0].body, 'run') !==
			'node tools/ci/manual-ci-lanes.cjs select >> "$GITHUB_OUTPUT"' ||
		pipeline.stepField(selects[0].body, 'env') !==
			'CI_EVENT: ${{ github.event_name }} CI_OS_SELECTION: ${{ inputs.os_lanes }}'
	) {
		problems.push('the plan must call the actual selector with event and manual choice');
	}
	const steps = root ? pipeline.steps(root.body) : [];
	const selectedAt = steps.findIndex((step) => step.name === 'Select native OS lanes');
	const preparedAt = steps.findIndex((step) => step.name === VALIDATE_SETUP);
	const checkedAt = steps.findIndex((step) => step.name === VALIDATE_CHECKS[0][0]);
	if (!(preparedAt >= 0 && selectedAt === preparedAt + 1 && checkedAt === selectedAt + 1)) {
		problems.push(
			'selection must run after the checked-out Node setup and before the existing checks'
		);
	}
	for (const os of ['windows', 'macos', 'linux']) {
		if (
			!root ||
			!root.body.includes('      lane_' + os + ': ${{ steps.lanes.outputs.lane_' + os + ' }}\n')
		) {
			problems.push(`the plan must forward the actual ${os} selection output`);
		}
		const lane = jobs.find((job) => job.id === os);
		if (!lane || pipeline.field(lane.body, 'if') !== LANE_IF(os))
			problems.push(`the ${os} caller must consume its exact selection`);
	}
	const check =
		verdict &&
		pipeline.steps(verdict.body).filter((step) => step.name === 'Assert selected lanes completed');
	if (
		!check ||
		check.length !== 1 ||
		pipeline.stepField(check[0].body, 'run') !== 'node tools/ci/manual-ci-lanes.cjs verdict' ||
		pipeline.stepField(check[0].body, 'env') !==
			'CI_EVENT: ${{ github.event_name }} CI_OS_SELECTION: ${{ inputs.os_lanes }} CI_JOB_RESULTS: ${{ toJSON(needs) }}'
	) {
		problems.push(
			'the manual verdict must pass the actual complete needs receipt to the same selector owner'
		);
	}
	if (!verdict || pipeline.field(verdict.body, 'if') !== MANUAL_VERDICT_IF)
		problems.push('manual verdict must run after failed or skipped dependencies only on dispatch');
	return problems;
}

errors.push(...manualLaneProblems(pipeline.files()));
for (const [from, to] of [
	['        default: all\n', '        default: linux\n'],
	['          - windows+linux\n', '          - windows+macos+linux\n'],
	['node tools/ci/manual-ci-lanes.cjs select', 'echo lane_windows=true'],
	['CI_EVENT: ${{ github.event_name }}', 'CI_EVENT: workflow_dispatch'],
	['CI_JOB_RESULTS: ${{ toJSON(needs) }}', 'CI_JOB_RESULTS: {}'],
	[`    if: ${MANUAL_VERDICT_IF}\n`, '    if: always()\n'],
	["    if: needs.validate.outputs.lane_windows == 'true'\n", ''],
	[
		"    if: needs.validate.outputs.lane_macos == 'true'\n",
		"    if: needs.validate.outputs.lane_linux == 'true'\n"
	]
]) {
	// The event binding belongs to two ports; mutate just the plan occurrence.
	const source = pipeline.file(ENTRY);
	const mutated = pipeline
		.files()
		.map((entry) =>
			entry.rel === ENTRY ? { ...entry, text: source.replace(from, () => to) } : entry
		);
	assert.ok(source.includes(from), 'the actual workflow owns each manual selection mutation');
	assert.ok(manualLaneProblems(mutated).length > 0, 'manual selection mutation must refuse');
}

// Expected masks are independently declared; no expected status is derived from the resolver.
const choices = [
	['all', [true, true, true]],
	['windows', [true, false, false]],
	['macos', [false, true, false]],
	['linux', [false, false, true]],
	['windows+macos', [true, true, false]],
	['windows+linux', [true, false, true]],
	['macos+linux', [false, true, true]]
];
const nativeKeys = ['windows', 'macos', 'linux'];
for (const [choice, mask] of choices) {
	assert.deepEqual(Object.values(manual.selectLanes('workflow_dispatch', choice)), mask);
	const jobs = {
		validate: { result: 'success', outputs: {} },
		core: { result: 'success' }
	};
	for (const [index, os] of nativeKeys.entries()) {
		jobs[os] = { result: mask[index] ? 'success' : 'skipped' };
		jobs.validate.outputs[`lane_${os}`] = String(mask[index]);
	}
	assert.equal(manual.verifyManualJobs('workflow_dispatch', choice, jobs), true);
	for (const job of ['validate', 'core', ...nativeKeys]) {
		for (const result of ['failure', 'cancelled', 'skipped', 'success', '', null, true, 0, {}]) {
			if (result === jobs[job].result) continue;
			const altered = structuredClone(jobs);
			altered[job].result = result;
			assert.throws(() => manual.verifyManualJobs('workflow_dispatch', choice, altered));
		}
		const missing = structuredClone(jobs);
		delete missing[job];
		assert.throws(() => manual.verifyManualJobs('workflow_dispatch', choice, missing));
	}
	for (const os of nativeKeys) {
		for (const value of [undefined, true, false, '', 'unknown', 'TRUE', 'false', 'true']) {
			if (value === jobs.validate.outputs[`lane_${os}`]) continue;
			const altered = structuredClone(jobs);
			altered.validate.outputs[`lane_${os}`] = value;
			assert.throws(() => manual.verifyManualJobs('workflow_dispatch', choice, altered));
		}
	}
	const extra = structuredClone(jobs);
	extra.validate.outputs.lane_other = 'false';
	assert.throws(() => manual.verifyManualJobs('workflow_dispatch', choice, extra));
	const env = {
		...process.env,
		CI_EVENT: 'workflow_dispatch',
		CI_OS_SELECTION: choice,
		CI_JOB_RESULTS: JSON.stringify(jobs)
	};
	const selected = spawnSync(
		process.execPath,
		[require.resolve('../ci/manual-ci-lanes.cjs'), 'select'],
		{ env, encoding: 'utf8', timeout: 5000 }
	);
	assert.equal(selected.error, undefined);
	assert.equal(selected.signal, null);
	assert.equal(selected.status, 0);
	assert.equal(selected.stderr, '');
	assert.equal(
		selected.stdout,
		nativeKeys.map((os, index) => `lane_${os}=${mask[index]}\n`).join('')
	);
	const verified = spawnSync(
		process.execPath,
		[require.resolve('../ci/manual-ci-lanes.cjs'), 'verdict'],
		{ env, encoding: 'utf8', timeout: 5000 }
	);
	assert.equal(verified.error, undefined);
	assert.equal(verified.signal, null);
	assert.equal(verified.status, 0);
	assert.equal(verified.stderr, '');
	assert.equal(verified.stdout, '[OK] Shared checks and selected native OS lanes passed.\n');
}
assert.deepEqual(manual.selectLanes('workflow_dispatch'), {
	windows: true,
	macos: true,
	linux: true
});
for (const invalid of [
	'',
	'ALL',
	'windows,linux',
	'macos+windows',
	'all+linux',
	' windows',
	'linux\n',
	null,
	false,
	[],
	{},
	'__proto__'
]) {
	assert.throws(() => manual.selectLanes('workflow_dispatch', invalid));
	for (const event of ['push', 'pull_request']) {
		assert.deepEqual(manual.selectLanes(event, invalid), {
			windows: true,
			macos: true,
			linux: true
		});
	}
}
for (const event of ['push', 'pull_request'])
	assert.throws(() => manual.verifyManualJobs(event, 'all', {}));
for (const input of ['{', 'null', '[]', '{}']) {
	const result = spawnSync(
		process.execPath,
		[require.resolve('../ci/manual-ci-lanes.cjs'), 'verdict'],
		{
			env: {
				...process.env,
				CI_EVENT: 'workflow_dispatch',
				CI_OS_SELECTION: 'windows',
				CI_JOB_RESULTS: input
			},
			encoding: 'utf8',
			timeout: 5000
		}
	);
	assert.equal(result.error, undefined);
	assert.equal(result.signal, null);
	assert.equal(result.status, 1);
	assert.equal(result.stdout, '');
}

/** Requires native signing tools before XCTest without release-key access. */
function sparkleToolProblems(files) {
	const problems = [];
	const mac = files.find((entry) => entry.rel === MACOS_BOX);
	const job =
		mac && pipeline.jobsOfText(mac.text, MACOS_BOX).find((entry) => entry.id === 'package-macos');
	const steps = job ? pipeline.steps(job.body) : [];
	const tools = steps.filter((step) => step.name === 'Install Sparkle signing tool');
	const toolAt = steps.findIndex((step) => step.name === 'Install Sparkle signing tool');
	const nativeAt = steps.findIndex((step) => step.name === 'Run Swift launcher tests');
	if (tools.length !== 1 || toolAt < 0 || nativeAt <= toolAt) {
		problems.push('the actual pinned Sparkle tool installer must precede native XCTest');
	} else if (
		pipeline.stepField(tools[0].body, 'if') !== null ||
		pipeline.stepField(tools[0].body, 'continue-on-error') !== null ||
		/\bsecrets\.|SPARKLE_ED_PRIVATE_KEY/.test(codeOf(tools[0].body))
	) {
		problems.push(
			'native fixture tool installation must be unconditional and cannot receive release secrets'
		);
	}
	return problems;
}
errors.push(...sparkleToolProblems(pipeline.files()));
const sparkleToolBody = pipeline.step(
	pipeline.job('package-macos'),
	'Install Sparkle signing tool'
);
const sparkleNativeBody = pipeline.step(pipeline.job('package-macos'), 'Run Swift launcher tests');
for (const [what, from, to] of [
	['missing native Sparkle tools', sparkleToolBody, ''],
	[
		'release-only native Sparkle tools',
		sparkleToolBody,
		sparkleToolBody.replace(
			'        shell: bash',
			'        if: inputs.release\n        shell: bash'
		)
	],
	[
		'forgiven native Sparkle tools',
		sparkleToolBody,
		sparkleToolBody.replace(
			'        shell: bash',
			'        continue-on-error: true\n        shell: bash'
		)
	],
	[
		'release secret handed to native Sparkle tools',
		sparkleToolBody,
		sparkleToolBody.replace(
			"          SPARKLE_VERSION: '2.9.2'",
			"          SPARKLE_VERSION: '2.9.2'\n          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}"
		)
	]
]) {
	mustCatch(what, MACOS_BOX, from, to, sparkleToolProblems);
}
const swappedSparkleSteps = pipeline.files().map((entry) =>
	entry.rel === MACOS_BOX
		? {
				...entry,
				text: entry.text
					.replace(sparkleToolBody, '__OWNED_SPARKLE_TOOL_STEP__')
					.replace(sparkleNativeBody, sparkleToolBody)
					.replace('__OWNED_SPARKLE_TOOL_STEP__', sparkleNativeBody)
			}
		: entry
);
assert.ok(
	sparkleToolProblems(swappedSparkleSteps).length > 0,
	'native XCTest before Sparkle tool installation must refuse'
);

// This qualifies the shared renderer and recorded bridge, not physical input.
const DISTRO_UNIT_COMMAND =
	'bash "$GITHUB_WORKSPACE/tools/test/prepare-linux-distro-unit.sh" "${{ matrix.distro }}"';
const DISTRO_UNIT_HELPER = fs.readFileSync(
	path.join(__dirname, 'prepare-linux-distro-unit.sh'),
	'utf8'
);
const DISTRO_UNIT_SUITE =
	'sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \\\n\tLUA_CPATH="$native_root/modules/?.so;;" TMPDIR="$unit_tmp" "$interpreter" tests/run.lua\n';

// The supervised form adds diagnostics around the same one actual helper call.
// Pin its shell ownership envelope separately from the existing direct form;
// a comment, unreachable call or extra helper cannot satisfy this contract.
const DISTRO_DIAGNOSTIC_COMMAND =
	'python3 - "$unit_log" "$unit_root/static/ergopti_plus/linux/tests/run.lua" \'${{ matrix.distro }}\' "$native_status" <<\'PYTHON\'';
const DISTRO_DIAGNOSTIC_SHA256 = '2788cc3783304c8424e34de365bff105acd60068ca892a802ae6a273251da9dc';
const DISTRO_LOGGED_ENVELOPE = [
	'set -euo pipefail',
	'case "${{ matrix.distro }}" in',
	'debian) apt-get install -y --no-install-recommends curl ;;',
	'fedora) dnf install -y curl ;;',
	'arch) pacman -Sy --noconfirm curl ;;',
	'alpine) apk add --no-cache curl ;;',
	'opensuse) zypper --non-interactive install curl ;;',
	'*) echo "::error::unknown archive unit distribution"; exit 1 ;;',
	'esac',
	'command -v curl',
	'test "$(id -u ergopti-ci)" -ge 1000',
	'unit_root="$(mktemp -d)"',
	'readonly unit_root',
	'trap \'rm -rf -- "$unit_root"\' EXIT',
	'cp -a "$GITHUB_WORKSPACE/." "$unit_root/"',
	'chown -R ergopti-ci:ergopti-ci "$unit_root"',
	'unit_log_dir="$RUNNER_TEMP/linux-distro-unit-logs"',
	'mkdir -p "$unit_log_dir"',
	'unit_log="$unit_log_dir/${{ matrix.distro }}.log"',
	'set +e',
	'(cd "$unit_root/static/ergopti_plus/linux" &&',
	'bash "$GITHUB_WORKSPACE/tools/test/prepare-linux-distro-unit.sh" "${{ matrix.distro }}") 2>&1 | tee "$unit_log"',
	'unit_pipeline_status=("${PIPESTATUS[@]}")',
	'set -e',
	'native_status="${unit_pipeline_status[0]}"',
	'set +e',
	'python3 - "$unit_log" "$unit_root/static/ergopti_plus/linux/tests/run.lua" \'${{ matrix.distro }}\' "$native_status" <<\'PYTHON\'',
	'PYTHON',
	'diagnostic_status=$?',
	'set -e',
	'if [[ "$native_status" -ne 0 ]]; then exit "$native_status"; fi',
	'if [[ "${unit_pipeline_status[1]}" -ne 0 ]]; then exit "${unit_pipeline_status[1]}"; fi',
	'exit "$diagnostic_status"'
];

/** Reads only the existing supervised diagnostic's single quoted heredoc. */
function distroUnitDiagnostic(body) {
	const script = pipeline.runOf(body) ?? [];
	const opening = script
		.map((line, index) =>
			line.trim() === "'${{ matrix.distro }}' \"$native_status\" <<'PYTHON'" ? index : -1
		)
		.filter((index) => index >= 0);
	const closing = script
		.map((line, index) => (line === 'PYTHON' ? index : -1))
		.filter((index) => index >= 0);
	if (opening.length !== 1 || closing.length !== 1 || closing[0] <= opening[0]) return null;
	return script.slice(opening[0] + 1, closing[0]).join('\n') + '\n';
}

/** Admits one exact direct command or the actual source-owned logged wrapper. */
function distroUnitInvocationFits(body) {
	const lines = logicalLines(body).filter((line) => line !== '');
	if (JSON.stringify(lines) === JSON.stringify([DISTRO_UNIT_COMMAND])) return true;
	const normalized = lines.map((line) => line.replace(/[ \t]+/g, ' ').trim());
	const at = normalized.indexOf(DISTRO_DIAGNOSTIC_COMMAND);
	const close = normalized.indexOf('PYTHON');
	if (at < 0 || close <= at) return false;
	const envelope = [...normalized.slice(0, at + 1), ...normalized.slice(close)];
	const diagnostic = distroUnitDiagnostic(body);
	return (
		JSON.stringify(envelope) === JSON.stringify(DISTRO_LOGGED_ENVELOPE) &&
		diagnostic !== null &&
		require('node:crypto').createHash('sha256').update(diagnostic).digest('hex') ===
			DISTRO_DIAGNOSTIC_SHA256
	);
}

/** Rejects native distro suites whose wrapper omits their real prerequisites. */
function distroUnitProblems(files, helper = DISTRO_UNIT_HELPER) {
	const linux = files.find((entry) => entry.rel === LINUX_BOX);
	const job =
		linux && pipeline.jobsOfText(linux.text, LINUX_BOX).find((row) => row.id === 'install-linux');
	const steps = job ? pipeline.steps(job.body) : [];
	const units = steps.filter(
		(step) => step.name === "The unit suite on this distribution's LuaJIT"
	);
	const problems = [];
	if (
		units.length !== 1 ||
		pipeline.stepField(units[0].body, 'shell') !== 'bash' ||
		!distroUnitInvocationFits(units[0].body)
	) {
		problems.push('the distro unit step must execute its fail-closed native prerequisite wrapper');
	}
	const code = helper
		.split('\n')
		.filter((line) => !/^\s*(?:#|--)/.test(line))
		.join('\n');
	if (
		(code.match(/^sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \\$/gm) || [])
			.length !== 4
	) {
		problems.push(
			'the two original native preflights, added write preflight and unchanged suite must use the ordinary installation user'
		);
	}
	if (!code.includes(DISTRO_UNIT_SUITE)) {
		problems.push('the unchanged distro suite must inherit the exact admitted native modules');
	}
	const lua = code.match(/"\$interpreter" -e '\n([\s\S]*?)\n'/)?.[1] || '';
	for (const statement of [
		'assert(ffi.C.getuid() ~= 0)',
		'assert(jit.os == "Linux" and _VERSION == "Lua 5.1")',
		'local uv, lfs = require("luv"), require("lfs")',
		'assert(debug.getinfo(uv.fs_stat, "S").what == "C")',
		'assert(debug.getinfo(lfs.attributes, "S").what == "C")'
	]) {
		if (!lua.split('\n').includes(statement))
			problems.push('native distro admission omits ' + statement);
	}
	if (!code.includes("/usr/bin/python3 -c 'import os; assert(os.geteuid() != 0)'")) {
		problems.push('the actual Python filesystem fixture requires an ordinary-user preflight');
	}
	for (const distro of ['debian', 'fedora', 'arch', 'alpine', 'opensuse']) {
		const packages = code.match(new RegExp('^\\t' + distro + '\\) ([^\\n]+)$', 'm'))?.[1] || '';
		if (!packages.split(/\s+/).includes('curl')) {
			problems.push(distro + ' must install the actual curl executable for native timer fixtures');
		}
		if (distro === 'debian' && !packages.split(/\s+/).includes('libc6-dev')) {
			problems.push(
				'Debian native builds require libc startup objects without recommended packages'
			);
		}
	}
	const ownership = 'chown ergopti-ci "$unit_driver" "$unit_driver/tests"';
	const chowns = code.match(/^chown .+$/gm) || [];
	if (
		!code.includes('unit_driver="$(pwd -P)"') ||
		!code.includes('test -f "$unit_driver/tests/run.lua"') ||
		JSON.stringify(chowns) !== JSON.stringify(['chown ergopti-ci "$unit_tmp"', ownership]) ||
		code.indexOf(ownership) >= code.indexOf('sudo -H -u ergopti-ci env')
	) {
		problems.push(
			'only the actual driver and tests directories must become writable before admission'
		);
	}
	const python =
		code.match(
			/^sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \\\n\t\/usr\/bin\/python3 -c '\n([\s\S]*?)\n'/m
		)?.[1] || '';
	const expectedPython = [
		'import os',
		'from pathlib import Path',
		'import tempfile',
		'assert(os.geteuid() != 0)',
		'working = Path.cwd()',
		'for directory in (working, working / "tests"):',
		'    assert(directory.stat().st_uid == os.geteuid())',
		'    with tempfile.TemporaryFile(dir=directory) as receipt:',
		'        assert(receipt.write(b"ordinary fixture write") == 22)',
		'        receipt.seek(0)',
		'        assert(receipt.read() == b"ordinary fixture write")',
		'assert(Path.cwd() == working)',
		'print("Native ordinary-user fixture writes: 2 directories admitted")'
	].join('\n');
	if (python !== expectedPython) {
		problems.push('the added native directory write preflight must execute its exact closed body');
	}
	const pythonLines = python.split('\n').map((line) => line.trim());
	for (const statement of [
		'assert(os.geteuid() != 0)',
		'working = Path.cwd()',
		'for directory in (working, working / "tests"):',
		'assert(directory.stat().st_uid == os.geteuid())',
		'with tempfile.TemporaryFile(dir=directory) as receipt:',
		'assert(receipt.write(b"ordinary fixture write") == 22)',
		'receipt.seek(0)',
		'assert(receipt.read() == b"ordinary fixture write")',
		'assert(Path.cwd() == working)'
	]) {
		if (!pythonLines.includes(statement))
			problems.push('native Python fixture admission omits ' + statement);
	}
	if (!/^set -euo pipefail$/m.test(code) || /^\s*set \+e\b/m.test(code) || SWALLOWED.test(code)) {
		problems.push('native distro preparation and suite failures may not be swallowed');
	}
	return problems;
}
errors.push(...distroUnitProblems(pipeline.files()));
const distroUnitBody = pipeline.step(
	pipeline.job('install-linux'),
	"The unit suite on this distribution's LuaJIT"
);
for (const [what, changed] of [
	['missing native distro wrapper', ''],
	[
		'interpreter-only native distro setup',
		distroUnitBody.replace(DISTRO_UNIT_COMMAND, 'luajit tests/run.lua')
	]
]) {
	mustCatch(what, LINUX_BOX, distroUnitBody, changed, distroUnitProblems);
}
mustCatch(
	'swallowed native distro wrapper',
	LINUX_BOX,
	distroUnitBody,
	distroUnitBody.replace(DISTRO_UNIT_COMMAND, DISTRO_UNIT_COMMAND + ' || true'),
	stepProblems
);
for (const [what, from, to] of [
	[
		'root suite execution',
		DISTRO_UNIT_SUITE,
		DISTRO_UNIT_SUITE.replace('sudo -H -u ergopti-ci ', '')
	],
	['root Lua admission', 'sudo -H -u ergopti-ci env', 'env'],
	['missing ordinary UID admission', 'assert(ffi.C.getuid() ~= 0)', ''],
	['missing Linux LuaJIT admission', 'assert(jit.os == "Linux" and _VERSION == "Lua 5.1")', ''],
	['missing native modules', 'local uv, lfs = require("luv"), require("lfs")', ''],
	['missing luv C entry point', 'assert(debug.getinfo(uv.fs_stat, "S").what == "C")', ''],
	['missing lfs C entry point', 'assert(debug.getinfo(lfs.attributes, "S").what == "C")', ''],
	['missing Python preflight', "/usr/bin/python3 -c 'import os; assert(os.geteuid() != 0)'", ''],
	[
		'swallowed unchanged unit suite',
		'"$interpreter" tests/run.lua',
		'"$interpreter" tests/run.lua || true'
	]
]) {
	const changed = DISTRO_UNIT_HELPER.replace(from, to);
	assert.notEqual(changed, DISTRO_UNIT_HELPER, what + ' must actually mutate the native wrapper');
	assert.ok(distroUnitProblems(pipeline.files(), changed).length > 0, what + ' must refuse');
}

for (const [what, from, to] of [
	[
		'missing added filesystem preflight',
		"/usr/bin/python3 -c '\n",
		"/usr/bin/python3 -c 'omitted\n"
	],
	['missing added ordinary UID acknowledgement', '\nassert(os.geteuid() != 0)\n', '\n'],
	['missing driver fixture admission', 'test -f "$unit_driver/tests/run.lua"', ''],
	['missing Debian C startup objects', 'gcc libc6-dev make', 'gcc make'],
	['missing actual driver path', 'unit_driver="$(pwd -P)"', 'unit_driver="/tmp"'],
	[
		'missing driver write ownership',
		'chown ergopti-ci "$unit_driver" "$unit_driver/tests"',
		'chown ergopti-ci "$unit_driver/tests"'
	],
	[
		'missing tests write ownership',
		'chown ergopti-ci "$unit_driver" "$unit_driver/tests"',
		'chown ergopti-ci "$unit_driver"'
	],
	[
		'recursive source ownership',
		'chown ergopti-ci "$unit_driver" "$unit_driver/tests"',
		'chown -R ergopti-ci "$unit_driver" "$unit_driver/tests"'
	],
	[
		'missing native ownership acknowledgement',
		'assert(directory.stat().st_uid == os.geteuid())',
		''
	],
	[
		'missing actual native directory writes',
		'assert(receipt.write(b"ordinary fixture write") == 22)',
		''
	],
	['missing actual native readback', 'assert(receipt.read() == b"ordinary fixture write")', ''],
	['missing unchanged CWD acknowledgement', 'assert(Path.cwd() == working)', '']
]) {
	const changed = DISTRO_UNIT_HELPER.replace(from, to);
	assert.notEqual(changed, DISTRO_UNIT_HELPER, what + ' must actually mutate the native wrapper');
	assert.ok(distroUnitProblems(pipeline.files(), changed).length > 0, what + ' must refuse');
}
for (const distro of ['debian', 'fedora', 'arch', 'alpine', 'opensuse']) {
	const changed = DISTRO_UNIT_HELPER.replace(
		new RegExp('^(\\t' + distro + '\\) [^\\n]*?) curl( ;;)$', 'm'),
		'$1$2'
	);
	assert.notEqual(changed, DISTRO_UNIT_HELPER, distro + ' must actually lose its curl executable');
	assert.ok(
		distroUnitProblems(pipeline.files(), changed).length > 0,
		distro + ' without curl must refuse'
	);
}

const activeWriteLoop =
	'for directory in (working, working / "tests"):\n    assert(directory.stat().st_uid == os.geteuid())\n    with tempfile.TemporaryFile(dir=directory) as receipt:\n        assert(receipt.write(b"ordinary fixture write") == 22)\n        receipt.seek(0)\n        assert(receipt.read() == b"ordinary fixture write")';
const skippedWriteLoop =
	'if False:\n' +
	activeWriteLoop
		.split('\n')
		.map((line) => '    ' + line)
		.join('\n');
const skippedWriteHelper = DISTRO_UNIT_HELPER.replace(activeWriteLoop, skippedWriteLoop);
assert.notEqual(
	skippedWriteHelper,
	DISTRO_UNIT_HELPER,
	'the skipped-write control must actually change the native wrapper'
);
assert.ok(
	distroUnitProblems(pipeline.files(), skippedWriteHelper).length > 0,
	'disabled native directory writes must refuse'
);

// Preserve the incoming direct-command contract as a separately valid form.
const directDistroUnitStep =
	"      - name: The unit suite on this distribution's LuaJIT\n" +
	"        if: matrix.kind == 'install'\n" +
	'        working-directory: static/ergopti_plus/linux\n' +
	'        shell: bash\n        run: |\n          ' +
	DISTRO_UNIT_COMMAND +
	'\n';
const directDistroFiles = pipeline
	.files()
	.map((entry) =>
		entry.rel === LINUX_BOX
			? { ...entry, text: entry.text.replace(distroUnitBody, directDistroUnitStep) }
			: entry
	);
assert.deepEqual(
	distroUnitProblems(directDistroFiles),
	[],
	'the original exact one-command form remains admitted'
);
assert.equal(
	distroUnitInvocationFits(distroUnitBody),
	true,
	'the actual supervised form remains admitted'
);
for (const [what, from, to] of [
	['comment-only helper', DISTRO_UNIT_COMMAND, '# ' + DISTRO_UNIT_COMMAND],
	['unreachable helper', DISTRO_UNIT_COMMAND, 'if false; then ' + DISTRO_UNIT_COMMAND + '; fi'],
	['duplicated helper', DISTRO_UNIT_COMMAND, DISTRO_UNIT_COMMAND + '; ' + DISTRO_UNIT_COMMAND],
	[
		'helper redirected to a copy',
		DISTRO_UNIT_COMMAND,
		DISTRO_UNIT_COMMAND.replace('$GITHUB_WORKSPACE', '$unit_root')
	],
	['missing supervised curl', '          command -v curl\n', ''],
	['root private-copy admission', '          test "$(id -u ergopti-ci)" -ge 1000\n', ''],
	['missing private source copy', '          cp -a "$GITHUB_WORKSPACE/." "$unit_root/"\n', ''],
	[
		'suite runs in shared checkout',
		'(cd "$unit_root/static/ergopti_plus/linux" &&',
		'(cd "$GITHUB_WORKSPACE/static/ergopti_plus/linux" &&'
	],
	['missing raw log capture', '2>&1 | tee "$unit_log"', '2>&1'],
	[
		'late pipeline status capture',
		'unit_pipeline_status=("${PIPESTATUS[@]}")',
		'echo ignored\n          unit_pipeline_status=("${PIPESTATUS[@]}")'
	],
	[
		'tee mistaken for native exit',
		'native_status="${unit_pipeline_status[0]}"',
		'native_status="${unit_pipeline_status[1]}"'
	],
	['native exit fabricated green', 'native_status="${unit_pipeline_status[0]}"', 'native_status=0'],
	['diagnostic exit fabricated green', 'diagnostic_status=$?', 'diagnostic_status=0'],
	[
		'native failure swallowed',
		'if [[ "$native_status" -ne 0 ]]; then exit "$native_status"; fi',
		'if [[ "$native_status" -ne 0 ]]; then exit 0; fi'
	],
	[
		'tee failure swallowed',
		'if [[ "${unit_pipeline_status[1]}" -ne 0 ]]; then exit "${unit_pipeline_status[1]}"; fi',
		'true'
	],
	['diagnostic failure swallowed', 'exit "$diagnostic_status"', 'exit 0'],
	['zero tests accepted', 'passed + failed <= 0', 'passed + failed < 0'],
	['duplicate summaries accepted', 'len(frames) != 1', 'len(frames) < 1'],
	['contradictory native summary accepted', '(native_status == "0" and failed != 0)', 'False']
]) {
	const changed = distroUnitBody.replace(from, to);
	assert.notEqual(changed, distroUnitBody, what + ' must actually mutate the supervised source');
	mustCatch(what, LINUX_BOX, distroUnitBody, changed, distroUnitProblems);
}

// Execute the actual diagnostic and Bash exit tail with handwritten status/log
// controls. These certify this transport, not a distro suite or native modules.
const distroControlBash = bashExecutable();
const distroControlPython = process.platform === 'win32' ? 'python' : 'python3';
const distroControlWorkspace = path.resolve(__dirname, '../..').replaceAll('\\', '/');
const distroControlRoot = fs.mkdtempSync(
	path.join(require('node:os').tmpdir(), 'ergopti-distro wrapper-')
);
try {
	const log = path.join(distroControlRoot, 'unit.log');
	const runner = path.resolve(__dirname, '../../static/ergopti_plus/linux/tests/run.lua');
	const diagnostic = distroUnitDiagnostic(distroUnitBody);
	assert.notEqual(diagnostic, null, 'the current supervised diagnostic must be present');
	const footer = (pipeline.runOf(distroUnitBody) ?? []).slice(-3).join('\n');
	assert.equal(
		footer,
		DISTRO_LOGGED_ENVELOPE.slice(-3).join('\n'),
		'execute the actual native/tee/diagnostic exit tail'
	);
	const frame = (modules, passed, failed) =>
		'='.repeat(40) +
		'\nOVERALL RESULTS:\n' +
		'Total modules: ' +
		modules +
		'\nPassed tests:  ' +
		passed +
		'\nFailed tests:  ' +
		failed +
		'\n' +
		'='.repeat(40) +
		'\n';
	for (const [what, text, native, expected] of [
		['complete successful native log', frame(1, 7, 0), '0', 0],
		['complete refused native log', frame(1, 6, 1), '17', 0],
		['missing native summary', 'no terminal frame\n', '0', 2],
		['duplicate native summaries', frame(1, 7, 0) + frame(1, 7, 0), '0', 2],
		['zero native modules', frame(0, 7, 0), '0', 2],
		['zero native cases', frame(1, 0, 0), '0', 2],
		['green native exit with failed cases', frame(1, 6, 1), '0', 2],
		['partial native frame', frame(1, 7, 0).slice(0, -42), '0', 2]
	]) {
		fs.writeFileSync(log, text);
		const result = spawnSync(distroControlPython, ['-', log, runner, 'debian', native], {
			input: diagnostic,
			encoding: 'utf8',
			timeout: 5000
		});
		assert.equal(result.error, undefined, what);
		assert.equal(result.signal, null, what);
		assert.equal(result.status, expected, what);
		assert.equal(result.stderr, '', what);
		const propagated = spawnSync(
			distroControlBash,
			[
				'-c',
				'set -euo pipefail\nnative_status="$1"\nunit_pipeline_status=("$1" 0)\ndiagnostic_status="$2"\n' +
					footer,
				'distro-diagnostic-transport',
				native,
				String(result.status)
			],
			{ encoding: 'utf8', timeout: 5000 }
		);
		assert.equal(propagated.error, undefined, what);
		assert.equal(propagated.signal, null, what);
		assert.equal(
			propagated.status,
			native === '0' ? expected : 17,
			what + ': the actual Python outcome propagates through the real Bash tail'
		);
	}
	for (const [native, tee, diagnosticStatus, expected] of [
		[0, 0, 0, 0],
		[17, 23, 31, 17],
		[0, 23, 31, 23],
		[0, 0, 31, 31],
		[0, 23, 0, 23]
	]) {
		const result = spawnSync(
			distroControlBash,
			[
				'-c',
				'set -euo pipefail\nnative_status="$1"\nunit_pipeline_status=("$1" "$2")\ndiagnostic_status="$3"\n' +
					footer,
				'distro-transport',
				String(native),
				String(tee),
				String(diagnosticStatus)
			],
			{ encoding: 'utf8', timeout: 5000 }
		);
		assert.equal(result.error, undefined);
		assert.equal(result.signal, null);
		assert.equal(
			result.status,
			expected,
			'actual Bash tail preserves native/tee/diagnostic failure precedence'
		);
	}
	// The genuine helper's unsupported-distro branch refuses before installs or
	// native module builds. Trace proves one real call through the actual pipe;
	// no fake helper or successful native-suite certificate is substituted.
	const lines = pipeline.runOf(distroUnitBody) ?? [];
	const start = lines.findIndex((line) => line === 'set +e');
	const end = lines.findIndex(
		(line, index) => index > start && line === 'native_status="${unit_pipeline_status[0]}"'
	);
	assert(start >= 0 && end > start, 'the actual supervised pipeline must be present');
	const pipe = lines
		.slice(start, end + 1)
		.join('\n')
		.replaceAll('${{ matrix.distro }}', '__guard_unsupported__');
	const quote = (value) => "'" + value.replaceAll("'", "'\"'\"'") + "'";
	const script =
		'set -euo pipefail\nunit_root=' +
		quote(distroControlWorkspace) +
		'\nunit_log=' +
		quote(log.replaceAll('\\', '/')) +
		'\n' +
		'unset BASH_XTRACEFD\nPS4="+ "\nset -x\n: "$GITHUB_WORKSPACE/tools/test/prepare-linux-distro-unit.sh"\n' +
		pipe +
		'\ndiagnostic_status=0\n' +
		footer;
	const result = spawnSync(distroControlBash, ['-c', script], {
		encoding: 'utf8',
		timeout: 5000,
		env: { ...process.env, GITHUB_WORKSPACE: distroControlWorkspace },
		stdio: ['pipe', 'pipe', 'pipe']
	});
	assert.equal(result.error, undefined, 'the genuine prerequisite helper refuses promptly');
	assert.equal(result.signal, null);
	assert.equal(
		result.status,
		1,
		'the real helper refusal propagates through tee and the actual native exit tail'
	);
	assert.match(fs.readFileSync(log, 'utf8'), /Unsupported mandatory unit distribution\./);
	// The real Bash renderer quotes this independently supplied exact path. Use
	// that primitive's spelling to handle spaces and apostrophes without admitting
	// a different helper, a guessed quote grammar, or an arbitrary helper suffix.
	// Bash 3.2 has no BASH_XTRACEFD. Ordinary stderr carries the outer trace;
	// the genuine pipeline's 2>&1 carries its helper trace into the raw log.
	// Do not also include stdout: tee copies the same raw log there.
	const traceLines = (result.stderr + fs.readFileSync(log, 'utf8')).split('\n');
	const helperPathRenderings = traceLines.filter((line) => line.startsWith('+ : '));
	assert.equal(helperPathRenderings.length, 1, 'the exact helper path has one Bash rendering');
	const helperPathRendering = helperPathRenderings[0].slice('+ : '.length);
	const calls = traceLines.filter(
		(line) => line.replace(/^\++ /, '') === 'bash ' + helperPathRendering + ' __guard_unsupported__'
	);
	assert.equal(calls.length, 1, 'the actual wrapped prerequisite helper executes exactly once');

	// Qualify a real tee write refusal independently of native-suite execution.
	// A controlled printf child supplies transport bytes; it is not a fake helper.
	const refusedLog = path.join(distroControlRoot, 'refused-log');
	fs.mkdirSync(refusedLog);
	const teePipe = pipe.replace(
		DISTRO_UNIT_COMMAND.replaceAll('${{ matrix.distro }}', '__guard_unsupported__'),
		'printf "%s\\n" "controlled transport"'
	);
	assert.notEqual(teePipe, pipe, 'the transport-only producer replacement must be exact');
	const teeScript =
		'set -euo pipefail\nunit_root=' +
		quote(distroControlWorkspace) +
		'\nunit_log=' +
		quote(refusedLog.replaceAll('\\', '/')) +
		'\n' +
		'unset BASH_XTRACEFD\nPS4="+ "\nset -x\n' +
		teePipe +
		'\ndiagnostic_status=0\n' +
		footer;
	const refusedTee = spawnSync(distroControlBash, ['-c', teeScript], {
		encoding: 'utf8',
		timeout: 5000,
		stdio: ['pipe', 'pipe', 'pipe']
	});
	assert.equal(refusedTee.error, undefined);
	assert.equal(refusedTee.signal, null);
	assert.equal(
		refusedTee.status,
		1,
		'a real tee filesystem refusal cannot turn a successful producer green'
	);
	assert.match(
		refusedTee.stderr,
		/^\+ native_status=0$/m,
		'the actual PIPESTATUS source is successful'
	);
	assert.match(
		refusedTee.stderr,
		/^\+ exit 1$/m,
		'the genuine tee refusal reaches the actual Bash exit tail'
	);
} finally {
	fs.rmSync(distroControlRoot, { recursive: true, force: true });
}

const PHYSICAL_BROWSER_STEP = 'Test shared physical shortcut rendering';
const PHYSICAL_BROWSER_ALIAS = 'test:browser:physical-shortcuts';
const PHYSICAL_BROWSER_COMMAND = 'node ./tools/test/browser/physical-shortcuts.playwright.cjs';
const PHYSICAL_BROWSER_SCRIPTS = require('../../package.json').scripts;

/** Requires the recorded-bridge browser gate immediately after layer rendering. */
function physicalBrowserProblems(files, scripts = PHYSICAL_BROWSER_SCRIPTS) {
	const problems = [];
	const entry = files.find((file) => file.rel === ENTRY);
	const core = entry && pipeline.jobsOfText(entry.text, ENTRY).find((job) => job.id === 'core');
	const steps = core ? pipeline.steps(core.body) : [];
	const physical = steps.filter((step) => step.name === PHYSICAL_BROWSER_STEP);
	const at = steps.findIndex((step) => step.name === PHYSICAL_BROWSER_STEP);
	const layerAt = steps.findIndex((step) => step.name === 'Test shared layer editor rendering');
	const installAt = steps.findIndex((step) => step.name === 'Install shared UI browsers');
	if (
		physical.length !== 1 ||
		at !== layerAt + 1 ||
		layerAt < 0 ||
		installAt < 0 ||
		installAt >= layerAt
	) {
		problems.push(
			'physical shortcut renderer needs one gate immediately after layer rendering and browser installation'
		);
	} else if (
		pipeline.stepField(physical[0].body, 'if') !== "matrix.suite == 'js'" ||
		pipeline.stepField(physical[0].body, 'run') !== `npm run ${PHYSICAL_BROWSER_ALIAS}`
	) {
		problems.push('physical shortcut renderer must run its exact command on the shared JS lane');
	}
	if (scripts[PHYSICAL_BROWSER_ALIAS] !== PHYSICAL_BROWSER_COMMAND) {
		problems.push(
			'physical shortcut browser alias must execute the existing recorded-bridge fixture'
		);
	}
	return problems;
}
errors.push(...physicalBrowserProblems(pipeline.files()));
const physicalBrowserBody = pipeline.step(pipeline.job('core'), PHYSICAL_BROWSER_STEP);
for (const [what, changed] of [
	['missing physical browser step', ''],
	[
		'missing physical browser condition',
		physicalBrowserBody.replace("        if: matrix.suite == 'js'\n", '')
	],
	[
		'disabled physical browser condition',
		physicalBrowserBody.replace("matrix.suite == 'js'", 'false')
	],
	[
		'wrong physical browser lane',
		physicalBrowserBody.replace("matrix.suite == 'js'", "matrix.suite == 'properties'")
	],
	[
		'wrong physical browser command',
		physicalBrowserBody.replace(
			`npm run ${PHYSICAL_BROWSER_ALIAS}`,
			'npm run test:browser:layer-editor'
		)
	]
]) {
	mustCatch(what, ENTRY, physicalBrowserBody, changed, physicalBrowserProblems);
}
const layerBrowserBody = pipeline.step(pipeline.job('core'), 'Test shared layer editor rendering');
const misplacedPhysicalBrowser = pipeline.files().map((entry) =>
	entry.rel === ENTRY
		? {
				...entry,
				text: entry.text
					.replace(physicalBrowserBody, '')
					.replace(layerBrowserBody, physicalBrowserBody + layerBrowserBody)
			}
		: entry
);
assert.ok(
	physicalBrowserProblems(misplacedPhysicalBrowser).length > 0,
	'physical renderer before layer renderer must refuse'
);
for (const changed of [undefined, 'node ./tools/test/browser/layer-editor.playwright.cjs']) {
	const scripts = { ...PHYSICAL_BROWSER_SCRIPTS, [PHYSICAL_BROWSER_ALIAS]: changed };
	assert.ok(
		physicalBrowserProblems(pipeline.files(), scripts).length > 0,
		'missing or redirected physical browser alias must refuse'
	);
}

// Package downloads have a separate clock from the unchanged native audio gate.
const LINUX_AUDIO_SETUP = 'Install native virtual audio locale prerequisites';
const LINUX_AUDIO_NATIVE = 'Parse native virtual audio state independently of user locale';
const LINUX_AUDIO_INSTALL =
	'sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends pulseaudio pulseaudio-utils locales language-pack-fr language-pack-de';
const LINUX_AUDIO_LOCALES = 'sudo locale-gen fr_FR.UTF-8 de_DE.UTF-8';
const LINUX_AUDIO_COMMANDS = [
	'python3 tests/hardware/run_system_audio_locale_receipts.py',
	'ERGOPTI_SYSTEM_TEST_LUA=lua5.4 python3 tests/hardware/run_system_audio_locale_receipts.py'
];

/** Keeps exact locale prerequisites outside the unchanged two-minute native budget. */
function linuxAudioPrerequisiteProblems(files) {
	const steps = files
		.filter((entry) => entry.rel === LINUX_BOX)
		.flatMap((entry) => pipeline.jobsOfText(entry.text, entry.rel))
		.filter((job) => job.id === 'e2e-linux')
		.flatMap((job) => pipeline.steps(job.body));
	const setup = steps.filter((step) => step.name === LINUX_AUDIO_SETUP);
	const native = steps.filter((step) => step.name === LINUX_AUDIO_NATIVE);
	const setupAt = steps.findIndex((step) => step.name === LINUX_AUDIO_SETUP);
	const nativeAt = steps.findIndex((step) => step.name === LINUX_AUDIO_NATIVE);
	if (setup.length !== 1 || native.length !== 1 || setupAt + 1 !== nativeAt) {
		return ['native audio needs one prerequisite step immediately before its native gate'];
	}
	const problems = [];
	for (const step of [setup[0], native[0]]) {
		if (
			pipeline.stepField(step.body, 'if') !== NOT_CANCELLED ||
			pipeline.stepField(step.body, 'working-directory') !== 'static/ergopti_plus/linux' ||
			pipeline.stepField(step.body, 'continue-on-error') !== null
		) {
			problems.push(`${step.name} must remain an unforgiven Linux harness under !cancelled()`);
		}
	}
	if (
		pipeline.stepField(setup[0].body, 'timeout-minutes') !== '10' ||
		JSON.stringify(logicalLines(setup[0].body)) !==
			JSON.stringify([LINUX_AUDIO_INSTALL, LINUX_AUDIO_LOCALES])
	) {
		problems.push(
			'native audio setup must install the exact packages/locales with its separate budget'
		);
	}
	if (
		pipeline.stepField(native[0].body, 'timeout-minutes') !== '2' ||
		JSON.stringify(logicalLines(native[0].body)) !== JSON.stringify(LINUX_AUDIO_COMMANDS)
	) {
		problems.push(
			'native audio must retain both exact interpreter invocations and its two-minute budget'
		);
	}
	return problems;
}

errors.push(...linuxAudioPrerequisiteProblems(pipeline.files()));
const linuxAudioSetupBody = pipeline.step(pipeline.job('e2e-linux'), LINUX_AUDIO_SETUP);
const linuxAudioNativeBody = pipeline.step(pipeline.job('e2e-linux'), LINUX_AUDIO_NATIVE);
for (const [what, from, to] of [
	['missing audio prerequisites', linuxAudioSetupBody, ''],
	...['pulseaudio', 'pulseaudio-utils', 'locales', 'language-pack-fr', 'language-pack-de'].map(
		(name) => [
			`missing native audio package ${name}`,
			LINUX_AUDIO_INSTALL,
			LINUX_AUDIO_INSTALL.split(' ')
				.filter((word) => word !== name)
				.join(' ')
		]
	),
	['missing native audio locale generation', LINUX_AUDIO_LOCALES, 'true'],
	...LINUX_AUDIO_COMMANDS.map((command) => [
		`missing native audio interpreter ${command}`,
		linuxAudioNativeBody,
		linuxAudioNativeBody.replace(`          ${command}\n`, '')
	]),
	[
		'changed native audio budget',
		linuxAudioNativeBody,
		linuxAudioNativeBody.replace('timeout-minutes: 2', 'timeout-minutes: 10')
	],
	[
		'shared audio setup/native clock',
		linuxAudioSetupBody,
		linuxAudioSetupBody.replace('timeout-minutes: 10', 'timeout-minutes: 2')
	],
	[
		'APT returned to native audio clock',
		linuxAudioNativeBody,
		linuxAudioNativeBody.replace(
			'        run: |\n',
			`        run: |\n          ${LINUX_AUDIO_INSTALL}\n`
		)
	],
	[
		'disabled audio setup',
		linuxAudioSetupBody,
		linuxAudioSetupBody.replace(NOT_CANCELLED, 'false')
	],
	[
		'forgiven audio setup',
		linuxAudioSetupBody,
		linuxAudioSetupBody + '\n        continue-on-error: true'
	],
	[
		'audio prerequisites after native execution',
		linuxAudioSetupBody + '\n\n' + linuxAudioNativeBody,
		linuxAudioNativeBody + '\n\n' + linuxAudioSetupBody
	]
]) {
	mustCatch(what, LINUX_BOX, from, to, linuxAudioPrerequisiteProblems);
}

if (errors.length > 0) {
	console.error(
		'[FAIL] the CI pipeline wiring can skip a gate, publish a wrong or partial release, or draw a tangled graph:'
	);
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`[OK] one root (${ROOT}) with ${planOutputs.size} plan outputs, ${callers.length} lane callers with one ` +
		`entry and one exit job each, and ${gatedSecrets} release-only secrets are wired as designed, ` +
		`${CONDITIONS.size} conditional steps are the only ones, and the release preflight runs before any side effect.`
);
