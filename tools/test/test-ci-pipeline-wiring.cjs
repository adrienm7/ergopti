// tools/test/test-ci-pipeline-wiring.cjs

/**
 * ==============================================================================
 * MODULE: CI Pipeline Wiring Guard
 * DESCRIPTION:
 * Pins how ci.yml wires its root, "Validate and plan", into the three OS lanes
 * and Release: the shape of the run graph, the plan's outputs, what each lane
 * caller passes and waits for, which secrets and permissions reach a job, how
 * the root runs its checks before it deepens the clone for the plan, and the
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
 *    ci.yml. No job of ci.yml sets continue-on-error, and only release sets a
 *    job-level if, exactly its own.
 * 2. Private secrets reach a lane only on a release run, through one exact
 *    expression; the public Sparkle key is the only allow-listed exception.
 *    Every pipeline file reads contents only; release alone may write.
 * 3. The root runs exactly its four checks on the default shallow checkout,
 *    each with its exact command, so one red check does not hide the others
 *    (N2) and none can be narrowed; no step before them fetches history; then
 *    it deepens the clone with one exact script, which retries a failed fetch
 *    and fails on a clone still shallow, then runs the two plan steps.
 * 4. One root, one lane per OS: ci.yml has exactly one job without needs, the
 *    root; each lane caller needs the root alone; release needs the root and
 *    the three lanes, nothing else; and each OS workflow has exactly one entry
 *    job (no needs) and one exit job (needed by no job of its file).
 * 5. Only the steps in STEP_CONDITIONS set an `if`, each exactly its own, and
 *    test-linux's harnesses run under !cancelled(). No script swallows a test
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
// Public by design: SUPublicEDKey ships inside every app, and a CI package
// without it cannot pass the launch gate.
const PUBLIC_SECRETS = new Set(['SPARKLE_PUBLIC_KEY']);
const PREFLIGHT = 'Refuse to publish an incomplete or already-taken release';
// A step that writes to GitHub: the tag, the release, its notes, or a push. A
// read such as `gh release view` is not one.
const SIDE_EFFECT = /\bgh api\b|\bgh release (?:create|edit|upload|delete)\b|\bgit\b[^\n]*\bpush\b/;

// Floors — today: 7 plan outputs, 3 callers, 4 release-only secrets.
const MIN_PLAN_OUTPUTS = 7;
const MIN_GATED_SECRETS = 4;

// The root's checks after its setup, in order, with the one command each runs.
const VALIDATE_SETUP = 'Install native validation tools';
const VALIDATE_CHECKS = [
	['Check hotstring TOML files are sorted and formatted', 'python tools/format_toml.py --hotstrings --all --check'],
	['Property-based tests (fast-check, 27 × 1000 runs)', 'npm run test:properties'],
	['Mutation tests — domain layer (Stryker, break=25)', 'npm run test:mutation'],
	['JS validation suite (umbrella — every run-js-suite check)', 'npm run test:js'],
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
	'fi',
];
// The deepening step exactly as ci.yml writes it, for the self-check fixtures.
const DEEPEN_TEXT = `      - name: ${DEEPEN_STEP}\n        shell: bash\n        run: |\n` +
	DEEPEN_SCRIPT.map((line) => `          ${line}\n`).join('');
// Any other way to deepen the clone: a step before the deepening one that runs
// it would hand the checks a clone deeper than the one they were written for.
const HISTORY_FETCH = /\bgit\b.*\b(?:fetch|pull|clone)\b|--(?:unshallow|deepen|depth|shallow-since|shallow-exclude)\b/;
const PLAN_STEPS = ['Load the Linux release artifact contract', 'Compute tag and version'];

// The only steps of the pipeline that may set an `if`, each with its only
// accepted value. Every other step runs whenever its job runs, so no edit can
// skip a gate while its job stays green.
const STEP_CONDITIONS = [
	[ENTRY, 'validate', 'Check hotstring TOML files are sorted and formatted', NOT_CANCELLED],
	[ENTRY, 'validate', 'Property-based tests (fast-check, 27 × 1000 runs)', NOT_CANCELLED],
	[ENTRY, 'validate', 'Mutation tests — domain layer (Stryker, break=25)',
		"${{ !cancelled() && github.ref == 'refs/heads/main' }}"],
	[ENTRY, 'validate', 'JS validation suite (umbrella — every run-js-suite check)', NOT_CANCELLED],
	[ENTRY, 'release', 'Create git tag', "steps.preflight.outputs.create_tag == 'true'"],
	[ENTRY, 'release', 'Create release and upload all assets atomically', "steps.preflight.outputs.create_release == 'true'"],
	[ENTRY, 'release', 'Publish channel feed for Sparkle', "steps.preflight.outputs.skip_feed != 'true'"],
	[MACOS_BOX, 'package-macos', 'Smoke test built ErgoptiPlus.app (crash-on-launch guard)', 'inputs.release'],
	[MACOS_BOX, 'package-macos', 'Retain packaged application startup evidence', 'always() && inputs.release'],
	[MACOS_BOX, 'package-macos', 'Install Sparkle signing tool', 'inputs.release'],
	[MACOS_BOX, 'package-macos', 'Sign zip with Sparkle EdDSA key', 'inputs.release'],
	[MACOS_BOX, 'package-macos', 'Generate Sparkle appcast', 'inputs.release'],
	[MACOS_BOX, 'package-macos', 'Package latest keylayout bundle', 'inputs.release'],
	[MACOS_BOX, 'launch', 'Retain launch evidence', 'always()'],
	[WINDOWS_BOX, 'test-ahk', 'Download AutoHotkey v2 runtime', "steps.cache-ahk.outputs.cache-hit != 'true'"],
	[WINDOWS_BOX, 'test-ahk', 'Annotate AHK results', 'always()'],
	[WINDOWS_BOX, 'test-ahk', 'Publish AHK execution manifest', 'always()'],
];
// test-linux runs each harness under !cancelled(), so a red one hides no other;
// tools/test/test-linux-ci-evidence.cjs pins which of its steps those are.
const HARNESS_JOB = 'test-linux';

// A command whose exit status is a gate: a test runner, a verdict script, a
// package build, an install or a launch. `|| true` after one turns its failure
// green; `|| {` with an explicit failing exit is still allowed.
const GATE_COMMAND = new RegExp([
	/\btests\/(?:run\.lua|e2e\/run_e2e\.lua|hardware\/|distro\/)/,
	/\brun_all\.ahk\b|\brun_e2e\.ahk\b|\brun_llm_[a-z_]+\.ahk\b/,
	/\bswift (?:test|build)\b|\bplutil -lint\b/,
	/_test\.py\b|\bmacos_launch_gate\.py\b|\bmacos-release-launch\.py\b/,
	/\blinux-ci-evidence\.cjs (?:verify|record)\b|\bvalidate-ahk-suite-manifest\.cjs\b/,
	/\btools\/test\/test-[\w-]+\.(?:py|cjs)\b/,
	/\bnpm run (?:test|build)\b/,
	/\bformat_toml\.py\b/,
	/\binstall\.sh\b|\binstalled_layout_check\.lua\b/,
	/\btools\/build\/build[\w-]*\.(?:sh|ps1)\b/,
	/\s--help\b/,
].map((pattern) => pattern.source).join('|'));
const SWALLOWED = /\|\|\s*(?:true\b|:(?=\s|$)|exit\s+0\b|echo\b)/;

// The release steps, in the only order that publishes a complete release: the
// tag before the release, the release before its feed, the changelog before
// the notes that embed it.
const RELEASE_ORDER = [
	'Download all build artifacts',
	PREFLIGHT,
	'Create git tag',
	'Create release and upload all assets atomically',
	'Publish channel feed for Sparkle',
	'Build changelog section',
	'Write release body with platform sections',
];

// Seven days on a release run, so a next-day "Re-run failed jobs" still finds
// the gated files; package-windows runs on release runs only.
const ASSET_RETENTION = new Map([
	['assets-macos', '${{ inputs.release && 7 || 1 }}'],
	['assets-windows', '7'],
	['assets-linux', '${{ inputs.release && 7 || 1 }}'],
]);

const errors = [];

/** Drops full-line comments, which may name a forbidden form to explain it. */
function codeOf(body) {
	return body.split('\n').filter((line) => !line.trimStart().startsWith('#')).join('\n');
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
			errors.push(`${where}: unreadable ${key} entry '${line.trim()}'; write one \`key: value\` per line`);
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
		errors.push(`self-check "${what}": expected one '${from.trim()}' in ${rel}, found ${count}; re-derive the fixture`);
		return;
	}
	const mutated = pipeline.files()
		.map((entry) => (entry.rel === rel ? { rel, text: text.replace(from, () => to) } : entry));
	let problems;
	try {
		problems = problemsOf(mutated);
	} catch (error) {
		problems = [error.message];
	}
	if (problems.length === 0) errors.push(`self-check "${what}" went unnoticed, so this rule cannot fail`);
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
	errors.push(`${ROOT} declares ${planOutputs.size} plan output(s) (floor ${MIN_PLAN_OUTPUTS}); the outputs block moved`);
}
for (const [key, value] of planOutputs) {
	const source = new RegExp(`^\\$\\{\\{ steps\\.([A-Za-z0-9_-]+)\\.outputs\\.${key} \\}\\}$`).exec(value);
	if (!source) {
		errors.push(`${ROOT} output ${key} must forward \${{ steps.<id>.outputs.${key} }}, got: ${value}`);
		continue;
	}
	const owner = planSteps.find((candidate) => pipeline.stepField(candidate.body, 'id') === source[1]);
	if (!owner) {
		errors.push(`${ROOT} output ${key} reads step '${source[1]}', which ${ROOT} does not have`);
	} else if (!new RegExp(`\\bemit ${key} |"${key}=`).test(codeOf(owner.body))) {
		errors.push(`${ROOT} output ${key} reads step '${source[1]}', which never writes ${key}`);
	}
}
for (const match of pipeline.text().matchAll(/needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)/g)) {
	// Only the root publishes a plan; a lane's own jobs read their scenarios
	// from package-macos, which test-macos-swift-launcher-ci.cjs pins.
	if (match[1] === 'package-macos') continue;
	if (match[1] !== ROOT) {
		errors.push(`needs.${match[1]}.outputs.${match[2]} is read, but the plan lives in ${ROOT} alone`);
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
	const root = pipeline.jobsOfText(files.find((entry) => entry.rel === ENTRY).text, ENTRY)
		.find((candidate) => candidate.id === ROOT);
	if (!root) return [`ci.yml has no ${ROOT} job`];
	const rootSteps = pipeline.steps(root.body);
	// The checks were written against a depth-1 clone without tags; a deeper
	// checkout changes what the test:js gates that shell out to git see.
	const checkouts = rootSteps.filter((candidate) =>
		/^actions\/checkout@/.test(pipeline.stepField(candidate.body, 'uses') ?? ''));
	if (checkouts.length !== 1 || pipeline.stepField(checkouts[0].body, 'with') !== null) {
		problems.push(`${ROOT} must check out once, with no with: block: its checks run on the default depth-1 clone`);
	}
	const deepenAt = rootSteps.findIndex((candidate) => candidate.name === DEEPEN_STEP);
	for (const earlier of deepenAt < 0 ? rootSteps : rootSteps.slice(0, deepenAt)) {
		const fetching = logicalLines(earlier.body).find((line) => HISTORY_FETCH.test(line));
		if (fetching !== undefined) {
			problems.push(`${ROOT} step "${earlier.name || earlier.body.trim().split('\n')[0]}" fetches history before ` +
				`"${DEEPEN_STEP}", so the checks would not run on the depth-1 clone: ${fetching}`);
		}
	}
	const setupAt = rootSteps.findIndex((candidate) => candidate.name === VALIDATE_SETUP);
	const after = setupAt < 0 ? [] : rootSteps.slice(setupAt + 1);
	const expected = [...VALIDATE_CHECKS.map(([name]) => name), DEEPEN_STEP, ...PLAN_STEPS];
	if (JSON.stringify(after.map((candidate) => candidate.name)) !== JSON.stringify(expected)) {
		problems.push(`${ROOT} must run exactly, after "${VALIDATE_SETUP}": ${expected.join(' | ')}; ` +
			`got: ${after.map((candidate) => candidate.name).join(' | ')}`);
		return problems;
	}
	for (const [index, [name, command]] of VALIDATE_CHECKS.entries()) {
		const run = pipeline.stepField(after[index].body, 'run');
		if (run !== command) problems.push(`${ROOT} step "${name}" must run exactly \`${command}\`, got: ${run}`);
	}
	const deepen = pipeline.runOf(after[VALIDATE_CHECKS.length].body) ?? [];
	if (JSON.stringify(deepen) !== JSON.stringify(DEEPEN_SCRIPT)) {
		const differs = deepen.findIndex((line, index) => line !== DEEPEN_SCRIPT[index]);
		problems.push(`${ROOT} step "${DEEPEN_STEP}" must run exactly its pinned script; first difference at line ` +
			`${(differs < 0 ? Math.min(deepen.length, DEEPEN_SCRIPT.length) : differs) + 1}: ` +
			`${deepen[differs] ?? '(missing)'}`);
	}
	return problems;
}

errors.push(...rootProblems(pipeline.files()));
for (const [what, from, to] of [
	['fetch-depth: 0 on the root checkout', '    steps:\n      # A depth-1 clone without tags, which the checks below expect.\n      - uses: actions/checkout@v4\n',
		'    steps:\n      # A depth-1 clone without tags, which the checks below expect.\n      - uses: actions/checkout@v4\n        with:\n          fetch-depth: 0\n'],
	['a history fetch between the checkout and the setup', '      - uses: actions/checkout@v4\n\n      - uses: actions/setup-python@v5\n',
		'      - uses: actions/checkout@v4\n\n      - name: Fetch all history\n        run: git fetch --depth=2147483647 --tags origin\n\n      - uses: actions/setup-python@v5\n'],
	['a history fetch inside the setup step', '          sudo apt-get install -y lua5.4 libxml2-utils\n',
		'          sudo apt-get install -y lua5.4 libxml2-utils\n          git pull --unshallow\n'],
	['the deepening fetch without --unshallow', '        unshallow=(--unshallow)\n', '        unshallow=()\n'],
	['the deepening fetch without --tags', ' --prune "${unshallow[@]}" --tags origin; then\n', ' --prune "${unshallow[@]}" origin; then\n'],
	['the deepening fetch tried once', '          for attempt in 1 2 3; do\n', '          for attempt in 1; do\n'],
	['a failed deepening fetch forgiven', '                  exit 1\n              fi\n              echo "::warning::',
		'                  exit 0\n              fi\n              echo "::warning::'],
	['the completeness check dropped', '          if [ "$(git rev-parse --is-shallow-repository)" != false ]; then\n',
		'          if false; then\n'],
	['the deepening step dropped', DEEPEN_TEXT, ''],
	['a narrowed test:js', '        run: npm run test:js\n', '        run: npm run test:js -- --only lint\n'],
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
		const files = pipeline.files().map((entry) => (entry.rel === ENTRY ? { rel: ENTRY, text: moved } : entry));
		if (rootProblems(files).length === 0) {
			errors.push('self-check "the deepening fetch before the checks" went unnoticed, so this rule cannot fail');
		}
	}
}

// The Linux lane names its tarball with this output and release writes it into
// the notes and a shell command, so an unsafe name must fail the plan.
const contract = attempt(() => pipeline.runOf(pipeline.step(plan, 'Load the Linux release artifact contract')));
if (contract !== null) {
	const at = (pattern) => contract.findIndex((line) => pattern.test(line.trim()));
	const checkAt = at(/^if \[\[ ! "\$asset_name" =~ \^\[A-Za-z0-9\._\+-\]\+\\\.tar\\\.gz\$ \]\]; then$/);
	const exitAt = at(/^exit 1$/);
	const emitAt = at(/^echo "linux_bundle=\$asset_name" >> "\$GITHUB_OUTPUT"$/);
	if (checkAt < 0 || !(checkAt < exitAt && exitAt < emitAt)) {
		errors.push('plan must refuse an unsafe Linux bundle name (exit 1) before it emits linux_bundle');
	}
}




// ======================================
// ======================================
// ======= 2/ The Lane Callers ==========
// ======================================
// ======================================

// What each caller needs is pinned with the graph shape in section 3.
const callers = pipeline.calls();
if (callers.length !== 3) errors.push(`ci.yml must call the three OS lanes, found ${callers.length} call(s)`);
let gatedSecrets = 0;
for (const call of callers) {
	const body = pipeline.job(call.id);
	// The release input is the only computed one: a false value on a release
	// run skips the lane's release build while the lane still succeeds.
	const inputs = mappingOf(body, 'with', call.id) ?? new Map();
	if (inputs.get('release') !== RELEASE_INPUT) {
		errors.push(`caller ${call.id} must pass release: ${RELEASE_INPUT}, got: ${inputs.get('release')}`);
	}
	for (const [key, value] of inputs) {
		if (key === 'release') continue;
		if (value !== `\${{ needs.${ROOT}.outputs.${key} }}`) {
			errors.push(`caller ${call.id} must pass ${key}: \${{ needs.${ROOT}.outputs.${key} }}, got: ${value}`);
		}
	}
	const inlineSecrets = /^ {4}secrets:[ \t]*([^\s#].*)$/m.exec(body);
	if (inlineSecrets) {
		errors.push(`caller ${call.id} must list each secret it passes, never secrets: ${inlineSecrets[1].trim()}`);
	}
	for (const [key, value] of mappingOf(body, 'secrets', call.id) ?? new Map()) {
		if (PUBLIC_SECRETS.has(key)) {
			if (value !== `\${{ secrets.${key} }}`) errors.push(`caller ${call.id} must pass ${key}: \${{ secrets.${key} }}`);
			continue;
		}
		gatedSecrets++;
		const gated = `\${{ needs.${ROOT}.outputs.release == 'true' && secrets.${key} || '' }}`;
		if (value !== gated) {
			errors.push(`caller ${call.id} passes the private ${key} outside a release run; it must be exactly ${gated}, got: ${value}`);
		}
	}
}
if (gatedSecrets < MIN_GATED_SECRETS) {
	errors.push(`found ${gatedSecrets} release-only secret(s) passed to the lanes (floor ${MIN_GATED_SECRETS}); the secrets parse drifted`);
}
if (/^\s*secrets:\s*inherit\b/m.test(pipeline.text())) {
	errors.push('no job may use secrets: inherit, which hands every secret, PAT_ERGOPTI included, to the called workflow');
}

// Release publishes only when every other job of ci.yml succeeded, reached
// directly or through a lane's needs.
const topJobs = pipeline.jobs(ENTRY);
const needsById = new Map(topJobs.map((candidate) => [candidate.id, pipeline.needsOf(candidate.body)]));
const awaited = new Set();
const pending = [...(needsById.get('release') ?? [])];
while (pending.length > 0) {
	const id = pending.pop();
	if (awaited.has(id)) continue;
	awaited.add(id);
	pending.push(...(needsById.get(id) ?? []));
}
for (const candidate of topJobs) {
	if (candidate.id !== 'release' && !awaited.has(candidate.id)) {
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
	const roots = topLevel.filter((candidate) => pipeline.needsOf(candidate.body).length === 0).map((candidate) => candidate.id);
	if (JSON.stringify(roots) !== JSON.stringify([ROOT])) {
		problems.push(`ci.yml must have exactly one root job, ${ROOT}, that needs nothing; got [${roots.join(', ')}]`);
	}
	const lanes = topLevel.filter((candidate) => pipeline.field(candidate.body, 'uses') !== null);
	for (const lane of lanes) {
		const needs = pipeline.needsOf(lane.body);
		if (JSON.stringify(needs) !== JSON.stringify([ROOT])) {
			problems.push(`caller ${lane.id} must need the root alone, [${ROOT}], so the root fans out to one job per lane; got [${needs.join(', ')}]`);
		}
	}
	const release = topLevel.find((candidate) => candidate.id === 'release');
	const releaseNeeds = release ? [...pipeline.needsOf(release.body)].sort() : [];
	const expectedRelease = [ROOT, ...lanes.map((lane) => lane.id)].sort();
	if (JSON.stringify(releaseNeeds) !== JSON.stringify(expectedRelease)) {
		problems.push(`release must need exactly the root and the three lanes, [${expectedRelease.join(', ')}]; got [${releaseNeeds.join(', ')}]`);
	}
	for (const rel of BOXES) {
		const entry = files.find((candidate) => candidate.rel === rel);
		if (!entry) {
			problems.push(`${rel} is not part of the pipeline`);
			continue;
		}
		const jobs = pipeline.jobsOfText(entry.text, rel);
		const needsOfJob = new Map(jobs.map((candidate) => [candidate.id, pipeline.needsOf(candidate.body)]));
		const entries = jobs.filter((candidate) => needsOfJob.get(candidate.id).length === 0).map((candidate) => candidate.id);
		const needed = new Set([...needsOfJob.values()].flat());
		const exits = jobs.filter((candidate) => !needed.has(candidate.id)).map((candidate) => candidate.id);
		if (entries.length !== 1) {
			problems.push(`${rel} must have exactly one entry job, which needs no job of its file; got [${entries.join(', ')}]`);
		}
		if (exits.length !== 1) {
			problems.push(`${rel} must have exactly one exit job, which no job of its file needs; got [${exits.join(', ')}]`);
		}
		for (const [id, needs] of needsOfJob) {
			for (const need of needs) {
				if (!needsOfJob.has(need)) problems.push(`${rel} job ${id} needs ${need}, which is not a job of its file`);
			}
		}
	}
	return problems;
}

errors.push(...graphProblems(pipeline.files()));
for (const [what, rel, from, to] of [
	['a second root in ci.yml', ENTRY, '\njobs:\n',
		'\njobs:\n  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo lint\n'],
	['a caller that no longer needs the root', ENTRY, "    name: 'Linux'\n    needs: [validate]\n", "    name: 'Linux'\n"],
	['a caller that also needs another lane', ENTRY, "    name: 'Windows'\n    needs: [validate]\n",
		"    name: 'Windows'\n    needs: [validate, macos]\n"],
	['release that no longer waits for a lane', ENTRY, '    needs: [validate, macos, windows, linux]\n',
		'    needs: [validate, macos, windows]\n'],
	['release that stops reading the plan from the root', ENTRY, '    needs: [validate, macos, windows, linux]\n',
		'    needs: [macos, windows, linux]\n'],
	['a second entry in the macOS lane', MACOS_BOX, '    needs: test-hs\n', ''],
	['a second entry in the Linux lane', LINUX_BOX,
		"    name: 'First install (${{ matrix.distro }})'\n    runs-on: ubuntu-latest\n    needs: [package-linux]\n",
		"    name: 'first install (${{ matrix.distro }})'\n    runs-on: ubuntu-latest\n"],
	['a second entry in the Windows lane', WINDOWS_BOX, '    needs: [test-ahk]\n', ''],
	['a second exit in the macOS lane', MACOS_BOX, '    needs: package-macos\n', '    needs: test-hs\n'],
	['a second exit in the Linux lane', LINUX_BOX, '      - smoke-appimage-run\n    if: always()\n', '    if: always()\n'],
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
		const expected = candidate.id === 'release' ? RELEASE_IF : null;
		const condition = pipeline.field(candidate.body, 'if');
		if (condition !== expected) {
			problems.push(expected === null
				? `ci.yml job ${candidate.id} must set no job-level if (got: ${condition}): a skipped lane reads as green`
				: `ci.yml job ${candidate.id} must keep exactly if: ${expected}, got: ${condition}`);
		}
		const forgiven = pipeline.field(candidate.body, 'continue-on-error');
		if (forgiven !== null) {
			problems.push(`ci.yml job ${candidate.id} sets continue-on-error: ${forgiven}; its failure must fail the run`);
		}
	}
	if (!jobs.some((candidate) => candidate.id === 'release')) problems.push('ci.yml has no release job');
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
			problems.push(`${entry.rel} must grant exactly permissions: contents: read, got: ${granted.join(', ') || 'none'}`);
		}
		for (const candidate of pipeline.jobsOfText(entry.text, entry.rel)) {
			const value = pipeline.field(candidate.body, 'permissions');
			const expected = entry.rel === ENTRY && candidate.id === 'release' ? 'contents: write' : null;
			if (value !== expected) {
				problems.push(`${entry.rel} job ${candidate.id} must ${expected ? `grant exactly ${expected}` : 'not widen the permissions'}, got: ${value}`);
			}
		}
	}
	return problems;
}

errors.push(...topJobProblems(pipeline.files()), ...permissionProblems(pipeline.files()));
for (const [what, from, to] of [
	['if: false on the Windows caller', '  windows:\n', '  windows:\n    if: false\n'],
	['a push-only condition on the Linux caller', '  linux:\n', "  linux:\n    if: github.event_name == 'push'\n"],
	['always() on the macOS caller', '  macos:\n', '  macos:\n    if: always()\n'],
	['if: false on validate', '  validate:\n', '  validate:\n    if: false\n'],
	['continue-on-error on validate', '  validate:\n', '  validate:\n    continue-on-error: true\n'],
	['continue-on-error on the Windows caller', '  windows:\n', '  windows:\n    continue-on-error: true\n'],
	['continue-on-error on release', '  release:\n', '  release:\n    continue-on-error: true\n'],
	['a status function in release.if', `    if: ${RELEASE_IF}\n`, `    if: \${{ always() && ${RELEASE_IF} }}\n`],
]) {
	mustCatch(what, ENTRY, from, to, topJobProblems);
}
for (const [what, rel, from, to] of [
	['write-all at the top of ci.yml', ENTRY, 'permissions:\n  contents: read\n', 'permissions: write-all\n'],
	['contents: write for a lane', LINUX_BOX, 'permissions:\n  contents: read\n', 'permissions:\n  contents: write\n'],
	['a write grant on a caller', ENTRY, "    name: 'macOS'\n", "    name: 'macOS'\n    permissions:\n      contents: write\n"],
]) {
	mustCatch(what, rel, from, to, permissionProblems);
}




// ============================================
// ============================================
// ======= 5/ The Windows Gating Suites =======
// ============================================
// ============================================

// Every gate of test-ahk, which runs on every run. package-windows runs on a
// release only, so a gate moved there stops running on pull requests and dev.
// Each must keep the failing exit of its failure branch.
const WINDOWS_GATES = [
	{ name: 'Install the shipped Kana layout for real probes', run: './tools/test/install-ci-kana-layout.ps1' },
	{ name: 'Build and test native navigation event owner', run: './tools/build/build_windows_nav_owner.ps1' },
	{ name: 'Manifest parity (AHK ↔ HS codegen equivalence)', run: 'npm run test:manifest-parity' },
	{ name: 'Verify AHK source encoding (UTF-8 BOM + LF)', exits: [['if ($failures.Count -gt 0) {', '1']] },
	{
		name: 'Run AHK test suite',
		uses: ['tests\\run_all.ahk', 'tools\\test\\validate-ahk-suite-manifest.cjs'],
		exits: [['if ($manifestExit -ne 0) {', '$manifestExit'], ['if ($exit -ne 0) {', '$exit']],
	},
	{
		name: 'Run isolated AHK LLM suites',
		uses: ['run_llm_model_browser.ahk', 'run_llm_model_menu_disabled.ahk'],
		exits: [['if ($failed -gt 0) {', '1']],
	},
	{
		name: 'Check for AHK compiler warnings',
		uses: ['tests\\run_all.ahk', '--dry-run'],
		exits: [['if ($errors) {', '1'], ['if ($warnings) {', '1']],
	},
	{
		name: 'Run E2E suite (Strategy A — pure engine injection)',
		uses: ['tests\\e2e\\run_e2e.ahk'],
		exits: [['if ($exit -ne 0) {', '$exit']],
	},
];

const testAhkAt = attempt(() => pipeline.locate('test-ahk'));
if (testAhkAt !== null && testAhkAt.file !== WINDOWS_BOX) {
	errors.push(`test-ahk must be a job of ${WINDOWS_BOX}, found in ${testAhkAt.file}`);
}
for (const gate of WINDOWS_GATES) {
	const found = testAhkAt && attempt(() => pipeline.step(testAhkAt.body, gate.name));
	if (!found) {
		errors.push(`"${gate.name}" must run in job test-ahk of ${WINDOWS_BOX}, which runs on every run`);
		continue;
	}
	for (const key of ['if', 'continue-on-error']) {
		if (pipeline.stepField(found, key) !== null) errors.push(`"${gate.name}" gates the Windows box and must not set ${key}`);
	}
	if (gate.run && pipeline.stepField(found, 'run') !== gate.run) {
		errors.push(`"${gate.name}" must run exactly \`${gate.run}\`, got: ${pipeline.stepField(found, 'run')}`);
	}
	const script = pipeline.runOf(found) ?? [];
	const code = script.filter((line) => !line.trimStart().startsWith('#')).join('\n');
	for (const token of gate.uses ?? []) {
		if (!code.includes(token)) errors.push(`"${gate.name}" no longer runs ${token}`);
	}
	for (const [opener, exit] of gate.exits ?? []) {
		const block = attempt(() => pipeline.scriptBlock(script, opener));
		if (block !== null && !pipeline.blockExits(block, exit)) {
			errors.push(`"${gate.name}": the branch \`${opener}\` must end with exit ${exit}, so the failure fails the step`);
		}
	}
}




// ==============================================
// ==============================================
// ======= 6/ No Step Can Switch A Gate Off =====
// ==============================================
// ==============================================

const conditionKey = (rel, job, name) => `${rel} job ${job} step "${name}"`;
const CONDITIONS = new Map(STEP_CONDITIONS.map(([rel, job, name, condition]) => [conditionKey(rel, job, name), condition]));
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
				const harness = entry.rel === LINUX_BOX && candidate.id === HARNESS_JOB && condition === NOT_CANCELLED;
				if (condition !== expected && !harness) {
					problems.push(expected === null
						? `${where} sets if: ${condition}; only the steps in STEP_CONDITIONS may be conditional`
						: `${where} must keep exactly if: ${expected}, got: ${condition}`);
				}
				for (const line of logicalLines(found.body)) {
					if (GATE_COMMAND.test(line) && SWALLOWED.test(line)) {
						problems.push(`${where} swallows the failure of a gate: ${line.slice(0, 160)}`);
					}
				}
				// GitHub runs a step with no shell: key as `bash -e`, without
				// pipefail, so `runner | tee log` reports tee's success.
				const code = (pipeline.runOf(found.body) ?? []).filter((line) => !line.trimStart().startsWith('#'));
				if (code.some((line) => /\|\s*tee\b/.test(line)) &&
					pipeline.stepField(found.body, 'shell') !== 'bash' &&
					!code.some((line) => /^\s*set -[a-z]*o pipefail\b/.test(line))) {
					problems.push(`${where} pipes into tee without pipefail (set -euo pipefail or shell: bash)`);
				}
			}
		}
	}
	for (const key of unseen) problems.push(`STEP_CONDITIONS lists ${key}, which the pipeline no longer has`);
	return problems;
}

errors.push(...stepProblems(pipeline.files()));
for (const [what, rel, from, to] of [
	['if: false on the Swift XCTest step', MACOS_BOX,
		'      - name: Run Swift launcher tests\n', '      - name: Run Swift launcher tests\n        if: false\n'],
	['a `- if: false` step head on the Hammerspoon suite', MACOS_BOX,
		'      - name: Run unit + meta tests\n', '      - if: false\n        name: Run unit + meta tests\n'],
	['if: false on the Windows exe smoke', WINDOWS_BOX,
		'      - name: Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)\n',
		'      - name: Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)\n        if: false\n'],
	['a harness condition outside test-linux', LINUX_BOX,
		'      - name: Launch the Flatpak\n', `      - name: Launch the Flatpak\n        if: ${NOT_CANCELLED}\n`],
	['if: false on a test-linux harness', LINUX_BOX,
		`      - name: Round-trip real events through the kernel\n        if: ${NOT_CANCELLED}\n`,
		'      - name: Round-trip real events through the kernel\n        if: false\n'],
	['if: false on the Linux evidence verdict', LINUX_BOX,
		'      - name: Assert all mandatory subjects ran and passed\n',
		'      - name: Assert all mandatory subjects ran and passed\n        if: false\n'],
	['a Stryker ref that never matches', ENTRY,
		"github.ref == 'refs/heads/main' }}\n", "github.ref == 'refs/heads/never' }}\n"],
	['`|| true` after the Hammerspoon harness', MACOS_BOX,
		'run: lua5.4 tests/e2e/run_e2e.lua\n', 'run: lua5.4 tests/e2e/run_e2e.lua || true\n'],
	['`|| true` after the Linux unit suite', LINUX_BOX,
		'-- luajit tests/run.lua\n', '-- luajit tests/run.lua || true\n'],
	['`|| true` after the continued evidence verdict', LINUX_BOX,
		'              --sha "$GITHUB_SHA"\n          echo "Linux driver:',
		'              --sha "$GITHUB_SHA" || true\n          echo "Linux driver:'],
	['a `| tee` left without pipefail', LINUX_BOX,
		'          set -euo pipefail\n          luajit tests/e2e/run_e2e.lua | tee',
		'          luajit tests/e2e/run_e2e.lua | tee'],
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
	errors.push(`release must run ${RELEASE_ORDER.join(' < ')}; got: ${releaseSteps.map((candidate) => candidate.name).join(' | ')}`);
}
const preflightAt = indexOf(PREFLIGHT);
const firstEffectAt = releaseSteps.findIndex((candidate) => SIDE_EFFECT.test(codeOf(candidate.body)));
if (firstEffectAt < 0 || releaseSteps[firstEffectAt].name !== 'Create git tag') {
	errors.push('the first release step that writes to GitHub must be "Create git tag"; re-derive the side-effect scan');
} else if (!(preflightAt >= 0 && preflightAt < firstEffectAt)) {
	errors.push(`"${PREFLIGHT}" must run before "${releaseSteps[firstEffectAt].name}", the first side effect`);
}
if (preflightAt >= 0) {
	const preflight = releaseSteps[preflightAt].body;
	for (const key of ['if', 'continue-on-error']) {
		if (pipeline.stepField(preflight, key) !== null) errors.push(`"${PREFLIGHT}" must not set ${key}`);
	}
	for (const token of [
		'set -euo pipefail',
		'_ErgoptiPlus.app.zip.sig',
		'"appcast-${CHANNEL}.xml"',
		'taken=$(git ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}")',
		'if [ "$tagged" = "$GITHUB_SHA" ]; then',
	]) {
		if (!preflight.includes(token)) errors.push(`"${PREFLIGHT}" is missing ${token}`);
	}
	if (/ls-remote[^\n]*\|/.test(codeOf(preflight))) {
		errors.push(`"${PREFLIGHT}" must capture ls-remote before testing it: piped, a network error reads as "tag free"`);
	}
}

// N5: under pipefail, `git ls-remote ... | grep -q` read a failing ls-remote as
// "tag free" and planned a release; the listing is captured first.
const planMeta = attempt(() => pipeline.step(plan, 'Compute tag and version'));
if (planMeta !== null) {
	if (!planMeta.includes('taken=$(git ls-remote --tags origin "refs/tags/$tag")') ||
		!planMeta.includes('if [ -n "$taken" ]; then')) {
		errors.push('plan must capture `git ls-remote --tags origin "refs/tags/$tag"` into taken and test it');
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
			if (!/^actions\/upload-artifact@/.test(pipeline.stepField(found.body, 'uses') ?? '')) continue;
			const name = /^ {10}name: (assets-\S+)$/m.exec(found.body)?.[1];
			if (!name) continue;
			retained.set(name, /^ {10}retention-days: (.+)$/m.exec(found.body)?.[1] ?? null);
			if (!/^ {10}if-no-files-found: error$/m.test(found.body)) {
				errors.push(`the ${name} upload must set if-no-files-found: error, so a missing file fails its box`);
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
const download = releaseSteps.find((candidate) => candidate.name === 'Download all build artifacts');
for (const line of ['          pattern: assets-*', '          path: release-assets', '          merge-multiple: true']) {
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
			const valid = entry.rel === ENTRY
				? (caller ? ['macOS', 'Windows', 'Linux'].includes(name) : /^(Validate|Release) \/ [A-Z][^/]+$/.test(name))
				: /^[A-Z]/.test(name) && !name.includes(' / ');
			if (!valid) problems.push(`${entry.rel} job ${candidate.id} has an invalid display name: ${name}`);
			for (const found of pipeline.steps(candidate.body)) {
				if (found.name && !/^[A-Z]/.test(found.name)) {
					problems.push(`${entry.rel} job ${candidate.id} has a lowercase step: ${found.name}`);
				}
				if (entry.rel !== ENTRY && /\b(?:macOS|Linux|Windows(?! Defender))\b/.test(found.name)) {
					problems.push(`${entry.rel} job ${candidate.id} repeats its zone in a step: ${found.name}`);
				}
			}
		}
	}
	return problems;
}

errors.push(...namingProblems(pipeline.files()));
for (const [what, rel, from, to] of [
	['an unqualified root name', ENTRY, "name: 'Validate / Checks and plan'", "name: 'Validate'"],
	['a lowercase lane job', WINDOWS_BOX, "name: 'Tests'", "name: 'tests'"],
	['a repeated lane prefix', MACOS_BOX, "name: 'Package'", "name: 'macOS / Package'"],
	['a lowercase step', WINDOWS_BOX, 'name: Run AHK test suite', 'name: run AHK test suite'],
	['an extra root separator', ENTRY, "name: 'Validate / Checks and plan'", "name: 'Validate / Checks / Plan'"],
	['a repeated step zone', LINUX_BOX, 'name: Run the driver unit test suite', 'name: Run Linux driver unit test suite'],
]) {
	mustCatch(what, rel, from, to, namingProblems);
}

if (errors.length > 0) {
	console.error('[FAIL] the CI pipeline wiring can skip a gate, publish a wrong or partial release, or draw a tangled graph:');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(`[OK] one root (${ROOT}) with ${planOutputs.size} plan outputs, ${callers.length} lane callers with one ` +
	`entry and one exit job each, and ${gatedSecrets} release-only secrets are wired as designed, ` +
	`${CONDITIONS.size} conditional steps are the only ones, and the release preflight runs before any side effect.`);
