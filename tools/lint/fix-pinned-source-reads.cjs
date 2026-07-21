// tools/lint/fix-pinned-source-reads.cjs

/**
 * ==============================================================================
 * MODULE: Pinned Source-Read Auto-Fixer (macOS / Lua tests)
 * DESCRIPTION:
 * Converts location-pinned source reads in macOS tests —
 * `helpers.driver_root() .. "modules/foo/bar.lua"` followed by io.open — into the
 * move-resilient `helpers.read_driver_source(symbol)` scan, so renaming or
 * splitting a driver module cannot turn a useful invariant into a path error.
 *
 * FEATURES & RATIONALE:
 * 1. Selector uniqueness is PROVEN, never guessed. read_driver_source returns
 *    every production file containing the symbol, concatenated. Several of these
 *    tests compare positions inside the returned source, so a selector matching a
 *    second file would silently corrupt that arithmetic rather than fail loudly.
 *    The fixer therefore verifies a candidate resolves to exactly ONE file before
 *    using it.
 * 2. It REFUSES rather than guesses. When no unique selector exists for a target
 *    (a real case: `_on_config_changed` is assigned in two production files), the
 *    file is reported for a human to restructure. Converting it blindly is how an
 *    assertion silently starts inspecting the wrong module.
 * 3. Default scope is staged files, so the pre-commit hook can block a NEW pinned
 *    read without churning the tolerated legacy ones.
 *
 * USAGE:
 *   node tools/lint/fix-pinned-source-reads.cjs            # staged files, report
 *   node tools/lint/fix-pinned-source-reads.cjs --fix      # staged files, rewrite
 *   node tools/lint/fix-pinned-source-reads.cjs --all      # whole test tree
 * ==============================================================================
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const TESTS_DIR = path.join(MACOS, 'tests');

// The pinned read: any local assigned from driver_root() concatenated with a
// quoted relative path into a driver source tree.
const PINNED_RE =
	/([ \t]*)local\s+(\w+)\s*=\s*helpers\.driver_root\(\)\s*\.\.\s*"((?:modules|lib|ui|adapters)\/[^"\n]*\.lua)"/;

/**
 * Collects every Lua file in a tree, skipping a named subdirectory.
 * @param {string} dir - Directory to walk.
 * @param {string|null} skipDir - Directory basename to skip, or null.
 * @param {string[]} acc - Accumulator.
 * @returns {string[]} Absolute paths of matched files.
 */
function walkLua(dir, skipDir, acc) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (skipDir && e.name === skipDir) continue;
			walkLua(full, skipDir, acc);
		} else if (e.name.endsWith('.lua')) {
			acc.push(full);
		}
	}
	return acc;
}

/** Production sources, cached — every selector is checked against this set. */
let productionCache = null;
function productionSources() {
	if (!productionCache) {
		productionCache = walkLua(MACOS, 'tests', []).map((f) => ({
			file: f,
			body: fs.readFileSync(f, 'utf8'),
		}));
	}
	return productionCache;
}

/**
 * Finds a declaration in `target` that appears in NO other production file.
 *
 * Uniqueness is the whole safety argument: read_driver_source concatenates every
 * file containing the symbol, so a selector matching two files changes what the
 * calling test is actually asserting about.
 * @param {string} relTarget - Driver-relative path of the module, e.g. "lib/logger.lua".
 * @returns {string|null} A proven-unique selector, or null when none exists.
 */
function uniqueSelectorFor(relTarget) {
	const sources = productionSources();
	const abs = path.join(MACOS, relTarget.split('/').join(path.sep));
	const entry = sources.find((s) => s.file === abs);
	if (!entry) return null;

	// Prefer declarations: they are stable, meaningful, and rarely duplicated.
	const candidates = [
		...entry.body.matchAll(/^(?:local function |function M\.)([A-Za-z0-9_]{5,})/gm),
	].map((m) => m[0]);
	// Longest first — a longer declaration is less likely to collide.
	candidates.sort((a, b) => b.length - a.length);

	for (const c of candidates) {
		const hits = sources.filter((s) => s.body.includes(c));
		if (hits.length === 1) return c;
	}
	return null;
}

/**
 * Rewrites every pinned read in one test file.
 * @param {string} file - Absolute path to the test file.
 * @param {boolean} apply - Whether to write the result back.
 * @returns {{converted: number, blocked: string[]}} Conversion outcome.
 */
function convertFile(file, apply) {
	let src = fs.readFileSync(file, 'utf8');
	const blocked = [];
	let converted = 0;

	for (;;) {
		const m = src.match(PINNED_RE);
		if (!m) break;

		const [, indent, varName, relTarget] = m;
		const selector = uniqueSelectorFor(relTarget);
		if (!selector) {
			blocked.push(relTarget);
			// Neutralise this occurrence for the scan so the loop terminates,
			// without touching the file we are refusing to convert.
			src = src.replace(PINNED_RE, `${indent}local ${varName} = "__PINNED_UNRESOLVED__"`);
			continue;
		}

		// Consume the whole read block, whatever optional lines it carries.
		const block = new RegExp(
			PINNED_RE.source +
				'\\r?\\n' +
				`[ \\t]*local\\s+\\w+\\s*=\\s*io\\.open\\(${varName}, "r"\\)\\r?\\n` +
				'(?:[ \\t]*helpers\\.assert_[a-z_]+\\([^\\n]*\\r?\\n)?' +
				'(?:[ \\t]*if not \\w+ then return end\\r?\\n)?' +
				'[ \\t]*local\\s+(\\w+)\\s*=\\s*\\w+:read\\("\\*a"\\)[ \\t]*(?:;\\s*\\w+:close\\(\\))?\\r?\\n' +
				'(?:[ \\t]*\\w+:close\\(\\)\\r?\\n)?'
		);
		const bm = src.match(block);
		if (!bm) {
			// The read exists but is not written in a shape this fixer can rewrite
			// safely. Reported separately from a uniqueness failure, because the
			// remedy is different: this one just needs converting by hand.
			blocked.push(`${relTarget} [unrecognised read shape — convert by hand]`);
			src = src.replace(PINNED_RE, `${indent}local ${varName} = "__PINNED_UNRESOLVED__"`);
			continue;
		}

		const srcVar = bm[4];
		const replacement =
			`${indent}-- Selected by a declaration unique to ${relTarget} rather than by\n` +
			`${indent}-- path, so moving or splitting the module cannot turn this invariant\n` +
			`${indent}-- into a path error.\n` +
			`${indent}local ${srcVar} = helpers.read_driver_source("${selector}")\n` +
			`${indent}helpers.assert_true(${srcVar} ~= nil, "${relTarget} source must be locatable")\n` +
			`${indent}if not ${srcVar} then return end\n`;
		src = src.replace(block, replacement);
		converted += 1;
	}

	if (apply && converted > 0) fs.writeFileSync(file, src, 'utf8');
	return { converted, blocked };
}

// ---------- entry point ----------

const argv = process.argv.slice(2);
const apply = argv.includes('--fix');
const all = argv.includes('--all');

let targets;
if (all) {
	targets = walkLua(TESTS_DIR, null, []).filter((f) => /test_.*\.lua$/.test(path.basename(f)));
} else {
	let staged = '';
	try {
		staged = execSync('git diff --cached --name-only --diff-filter=ACM', {
			cwd: ROOT,
			encoding: 'utf8',
		});
	} catch {
		staged = '';
	}
	targets = staged
		.split('\n')
		.map((l) => l.trim())
		.filter((l) => l.endsWith('.lua') && l.includes('macos/tests/'))
		.map((l) => path.join(ROOT, l.split('/').join(path.sep)))
		.filter((f) => fs.existsSync(f));
}

let totalConverted = 0;
const offenders = [];
for (const file of targets) {
	const rel = path.relative(ROOT, file).replace(/\\/g, '/');
	const body = fs.readFileSync(file, 'utf8');
	if (!PINNED_RE.test(body)) continue;

	const { converted, blocked } = convertFile(file, apply);
	if (converted > 0) {
		totalConverted += converted;
		console.log(`${apply ? 'fixed' : 'convertible'}: ${rel} (${converted} read(s))`);
	}
	for (const b of blocked) offenders.push(`${rel} -> ${b}`);
}

// --all is a survey of the tolerated legacy population, so it reports without
// failing. Staged mode is the gate: a NEW pinned read must not land.
if (all) {
	console.log(`\nsurvey: ${totalConverted} auto-convertible, ${offenders.length} need a human`);
	for (const o of offenders) console.log('  ' + o);
	process.exit(0);
}

if (offenders.length > 0) {
	console.error('\x1b[31m[BLOCKED] Staged test(s) read driver source by a pinned path:\x1b[0m');
	for (const o of offenders) console.error('  ' + o);
	console.error(
		'\n  These could not be converted automatically. Where the note says the module\n' +
			'  has no unique declaration, read_driver_source would return several files\n' +
			'  concatenated — and if the test compares positions inside the source, that\n' +
			'  silently changes what it asserts. Make the assertion order-independent\n' +
			'  first, then use helpers.read_driver_source(symbol).'
	);
	process.exit(1);
}

if (totalConverted === 0) {
	console.log('\x1b[32m[OK] No pinned source reads in staged tests.\x1b[0m');
} else if (!apply) {
	console.error(
		`\x1b[31m[ERROR] ${totalConverted} pinned source read(s) in staged tests.\x1b[0m`
	);
	console.error('  Run `npm run fix:pinned-reads` to convert them automatically.');
	process.exit(1);
}
