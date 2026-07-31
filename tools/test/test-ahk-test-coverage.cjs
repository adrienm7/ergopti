// tools/test/test-ahk-test-coverage.cjs

/**
 * ==============================================================================
 * MODULE: AHK Test Coverage Drift Gate
 * DESCRIPTION:
 * Fails if any test_*.ahk on disk under windows/tests/ (top-level or meta/) is
 * NOT reachable through the #Include closure rooted at run_all.ahk. AHK resolves
 * #Include at compile time, so a test file that nobody includes is silently
 * skipped — it never registers its Test() cases and never runs in CI.
 *
 * ROOT CAUSE ENCODED:
 * 16 test_*.ahk files were found on disk but never wired into run_all.ahk (nor
 * any other runner) — they had provided ZERO coverage, some for many refactors.
 * This guard makes that failure mode impossible: add a test file, and if it is
 * not pulled into the run_all closure the suite fails here, naming the orphan and
 * the exact #Include line to add. It is the cross-language twin of the macOS
 * auto-discovered runner (lua run.lua walks the tree) — AHK cannot walk at
 * runtime, so we enforce the manifest instead of generating it.
 *
 * SCOPE: windows/tests/{,meta/}test_*.ahk. e2e/ has its own runner (run_e2e.ahk)
 * and is intentionally excluded.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const TESTS_DIR = path.join(ROOT, 'static', 'ergopti_plus', 'windows', 'tests');
const RUN_ALL = path.join(TESTS_DIR, 'run_all.ahk');

/**
 * Extracts the resolvable #Include targets from a source blob, skipping the
 * optional-include (*i) and library-search (<...>) forms.
 * @param {string} src Source text.
 * @returns {string[]} Raw include target strings.
 */
function includeTargets(src) {
	const out = [];
	for (const line of src.split(/\r?\n/)) {
		const t = line.trim();
		if (!t.startsWith('#Include')) continue;
		const rest = t.slice('#Include'.length).trim();
		if (!rest || rest.startsWith('*i') || rest.startsWith('<')) continue;
		out.push(rest);
	}
	return out;
}

/**
 * Resolves an #Include target to an absolute path. Handles plain relative paths
 * (relative to the including file's directory) and the %A_LineFile% form (which
 * AHK expands to the including file's own path).
 * @param {string} target Raw include target.
 * @param {string} fromFile Absolute path of the file containing the directive.
 * @returns {string} Absolute, normalised path (forward slashes).
 */
function resolveInclude(target, fromFile) {
	let t = target.replace(/`/g, '').trim();
	if (/%A_LineFile%/i.test(t)) {
		t = t.replace(/%A_LineFile%/gi, fromFile);
		return path.normalize(t).replace(/\\/g, '/');
	}
	return path.resolve(path.dirname(fromFile), t).replace(/\\/g, '/');
}

/**
 * Builds the transitive set of .ahk files reachable from a root via #Include.
 * @param {string} rootFile Absolute path of the entry file.
 * @returns {Set<string>} Absolute paths (forward slashes) in the closure.
 */
function includeClosure(rootFile) {
	const seen = new Set();
	const stack = [path.normalize(rootFile).replace(/\\/g, '/')];
	while (stack.length) {
		const file = stack.pop();
		if (seen.has(file)) continue;
		seen.add(file);
		let src;
		try {
			src = fs.readFileSync(file, 'utf8');
		} catch {
			continue; // unresolved (variable path / missing) — skip, do not crash
		}
		for (const target of includeTargets(src)) {
			const abs = resolveInclude(target, file);
			if (abs.toLowerCase().endsWith('.ahk') && !seen.has(abs)) stack.push(abs);
		}
	}
	return seen;
}

// e2e/ has its own runner (run_e2e.ahk) and is deliberately outside this
// closure; fixtures/ and stubs/ hold no tests.
const NOT_RUN_ALL = new Set(['e2e', 'fixtures', 'stubs', 'scratch_test_dir']);

/**
 * Every test_*.ahk anywhere under tests/, at any depth.
 *
 * This used to list three directories and read each one flat. A test file in a
 * nested folder — tests/unit/modules/foo/ — was therefore invisible to the
 * orphan check, which is precisely the population most likely to be forgotten
 * when wiring run_all.ahk: the ones someone filed away neatly.
 * @returns {string[]} Absolute POSIX-style paths.
 */
function discoverTestFiles() {
	const files = [];
	const walk = (dir) => {
		let entries = [];
		try {
			entries = fs.readdirSync(dir, { withFileTypes: true });
		} catch {
			return;
		}
		for (const e of entries) {
			if (e.isDirectory()) {
				if (!NOT_RUN_ALL.has(e.name)) walk(path.join(dir, e.name));
			} else if (/^test_.+\.ahk$/i.test(e.name)) {
				files.push(path.join(dir, e.name).replace(/\\/g, '/'));
			}
		}
	};
	walk(TESTS_DIR);
	return files;
}

const closure = includeClosure(RUN_ALL);
// Compare case-insensitively (Windows paths) to avoid false orphans on drive-letter casing.
const closureLower = new Set([...closure].map((p) => p.toLowerCase()));
const testFiles = discoverTestFiles();

const orphans = testFiles.filter((f) => !closureLower.has(f.toLowerCase()));

if (orphans.length > 0) {
	console.error(
		`\x1b[31m[ERROR] ${orphans.length} test_*.ahk file(s) are not reachable from run_all.ahk's #Include closure — they never run.\x1b[0m`
	);
	for (const o of orphans) {
		const rel = path.relative(TESTS_DIR, o).replace(/\\/g, '/');
		console.error(`    ${rel}   — add:  #Include ${rel}`);
	}
	console.error('  Wire each into static/ergopti_plus/windows/tests/run_all.ahk (or delete it if obsolete).');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] All ${testFiles.length} windows test_*.ahk file(s) are reachable from run_all.ahk — no silently-skipped tests.\x1b[0m`
);
