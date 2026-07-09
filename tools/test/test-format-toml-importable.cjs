// tools/test/test-format-toml-importable.cjs

/**
 * ==============================================================================
 * MODULE: format_toml CLI — Behavioral / Importability Guard
 * DESCRIPTION:
 * tools/format_toml.py is a load-bearing dev tool: the pre-commit hook and the
 * "Validate · hotstrings" CI job shell out to it, and any silent breakage (an
 * import error from the tools.lib.paths SSOT, a mangled CLI contract) surfaces
 * only when a contributor tries to commit. Nothing in the JS validation layer
 * ever executed the script, so a regression could ship unnoticed.
 *
 * ROOT CAUSE ENCODED:
 * This guard invokes the real interpreter on the real script and asserts the two
 * halves of its documented contract that a breakage would violate:
 *   1. A bare invocation (no args) is a usage error — it must exit 1 and print
 *      the usage banner, never exit 0 (a script that imports cleanly but no
 *      longer reaches main() would regress this).
 *   2. `<file> --preview` formats deterministically — sections and keys are
 *      sorted alphabetically and styled headers are emitted — while leaving the
 *      input file byte-for-byte untouched (preview must never write to disk).
 *
 * FEATURES & RATIONALE:
 * 1. Interpreter-agnostic: probes `python3` then `python` and uses the first
 *    that answers `--version` with status 0, so it runs unchanged on the ubuntu
 *    CI runner (python3) and a Windows dev box (python; the Store `python3` shim
 *    exits non-zero and is skipped).
 * 2. Zero side effects: the fixture lives in an OS temp dir removed in `finally`,
 *    and --preview is asserted to leave it unmodified — the repo tree is never
 *    touched whether the test passes or fails.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SCRIPT = path.join(ROOT, 'tools', 'format_toml.py');

// python3 first (ubuntu CI), python second (Windows dev — its Store python3 shim
// exits non-zero on --version and is skipped by the status check below).
const PY_CANDIDATES = ['python3', 'python'];

// Unsorted, header-less input: sections and keys are both out of alphabetical
// order so a correct run must visibly reorder them.
const FIXTURE_CONTENT = '[banana]\nzebra = "1"\napple = "2"\n\n[apple]\nkey = "3"\n';

let _pass = 0;
let _fail = 0;
const _results = [];

/**
 * Records a single assertion outcome for the TAP report.
 * @param {string} name - Human-readable assertion label.
 * @param {boolean} ok - Whether the assertion held.
 * @param {string} [detail] - Diagnostic printed as a TAP comment on failure.
 */
function test(name, ok, detail) {
	_pass += ok ? 1 : 0;
	_fail += ok ? 0 : 1;
	_results.push({ name, ok, detail });
}

/**
 * Emits the TAP summary and exits non-zero if any assertion failed.
 */
function report() {
	const total = _pass + _fail;
	console.log('TAP version 14');
	console.log(`1..${total}`);
	let i = 1;
	for (const r of _results) {
		console.log(`${r.ok ? 'ok' : 'not ok'} ${i++} - ${r.name}`);
		if (!r.ok && r.detail) console.log(`  # ${r.detail}`);
	}
	console.log(`# passed: ${_pass}/${total}`);
	if (_fail > 0) {
		console.log(`# FAILED: ${_fail} test(s)`);
		process.exit(1);
	}
}

/**
 * Returns the first interpreter that answers `--version` with exit status 0.
 * @returns {string|null} The interpreter command, or null when none is usable.
 */
function resolvePython() {
	for (const cand of PY_CANDIDATES) {
		const probe = spawnSync(cand, ['--version'], { encoding: 'utf8' });
		if (!probe.error && probe.status === 0) return cand;
	}
	return null;
}

const PYTHON = resolvePython();
if (!PYTHON) {
	console.log('TAP version 14');
	console.log('1..0');
	console.log('# FAILED: no python interpreter found (tried: ' + PY_CANDIDATES.join(', ') + ')');
	process.exit(1);
}

const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-fmttoml-'));
const fixturePath = path.join(fixtureDir, 'fixture.toml');

try {
	// 1) Bare invocation is a usage error — exit 1 and print the usage banner.
	const bare = spawnSync(PYTHON, [SCRIPT], { cwd: ROOT, encoding: 'utf8' });
	test('bare invocation exits 1 (usage), not 0', bare.status === 1,
		`status=${bare.status}\n${bare.stdout}${bare.stderr}`);
	test('bare invocation prints the usage banner',
		/Usage:\s*format_toml\.py/.test(bare.stdout + bare.stderr),
		bare.stdout + bare.stderr);

	// 2) --preview on a real file: deterministic sort + styled headers, no write.
	fs.writeFileSync(fixturePath, FIXTURE_CONTENT, 'utf8');
	const prev = spawnSync(PYTHON, [SCRIPT, fixturePath, '--preview'],
		{ cwd: ROOT, encoding: 'utf8' });
	const out = prev.stdout || '';

	test('--preview exits 0 on a valid file', prev.status === 0,
		`status=${prev.status}\n${out}${prev.stderr}`);

	const idxApple = out.indexOf('[apple]');
	const idxBanana = out.indexOf('[banana]');
	test('sections sorted alphabetically ([apple] before [banana])',
		idxApple !== -1 && idxBanana !== -1 && idxApple < idxBanana,
		`idxApple=${idxApple} idxBanana=${idxBanana}\n${out}`);

	const bananaBody = idxBanana === -1 ? '' : out.slice(idxBanana);
	const idxKeyApple = bananaBody.indexOf('apple = "2"');
	const idxKeyZebra = bananaBody.indexOf('zebra = "1"');
	test('keys sorted within a section (apple before zebra under [banana])',
		idxKeyApple !== -1 && idxKeyZebra !== -1 && idxKeyApple < idxKeyZebra,
		`idxKeyApple=${idxKeyApple} idxKeyZebra=${idxKeyZebra}\n${bananaBody}`);

	test('styled section headers are emitted for both sections',
		out.includes('# ======= Apple =======') && out.includes('# ======= Banana ======='),
		out);

	test('--preview writes nothing to disk (file byte-identical)',
		fs.readFileSync(fixturePath, 'utf8') === FIXTURE_CONTENT,
		fs.readFileSync(fixturePath, 'utf8'));
} finally {
	fs.rmSync(fixtureDir, { recursive: true, force: true });
}

report();
