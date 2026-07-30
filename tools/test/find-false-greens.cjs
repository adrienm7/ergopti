// tools/test/find-false-greens.cjs

/**
 * ==============================================================================
 * MODULE: False-Green Test Detector
 * DESCRIPTION:
 * Scans the three driver test trees for tests that CANNOT FAIL. A test that
 * cannot fail is worse than no test: it occupies the slot where a real guard
 * would live, it is counted in the "3380/3380 green" figure everyone trusts,
 * and it actively certifies the bug it was written to prevent.
 *
 * FEATURES & RATIONALE:
 * 1. Four mechanically detectable shapes (see SECTION 3). Two further shapes —
 *    a harness that stubs the very function under test, and a source-grep that
 *    pins the current SPELLING of the code rather than the invariant — need
 *    human judgement and are deliberately NOT reported here; the skill
 *    `false-green-tests` explains how to hunt those by hand.
 * 2. Ratchet, not gate. The trees already contain accepted occurrences (skip
 *    acknowledgements, deliberate smoke tests). A hard zero would be rejected
 *    on day one and the check would be disabled. Instead the tool fails only
 *    when a count rises ABOVE its recorded baseline, so the number can only go
 *    down over time — the same shape as the repo's other ratchets.
 * 3. Every finding prints file:line so it can be opened directly, because a
 *    bare count teaches nobody anything.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS_ROOT = path.join(REPO_ROOT, 'static', 'ergopti_plus');

// The three test trees. Windows is AHK, macOS and Linux are Lua.
const TREES = [
	{ name: 'windows', dir: path.join(DRIVERS_ROOT, 'windows', 'tests'), ext: '.ahk' },
	{ name: 'macos', dir: path.join(DRIVERS_ROOT, 'macos', 'tests'), ext: '.lua' },
	{ name: 'linux', dir: path.join(DRIVERS_ROOT, 'linux', 'tests'), ext: '.lua' },
];

// Baseline: the highest count each pattern is allowed to reach. Regenerate with
// --update-baseline ONLY after deliberately accepting the new occurrences.
const BASELINE_PATH = path.join(__dirname, 'false-greens-baseline.json');

// A test body may delegate its assertions to a helper defined in the same file.
// One level of indirection is resolved before calling a body assertion-free;
// deeper chains are rare here and would produce more noise than signal.
const DELEGATION_DEPTH = 1;

// AHK control statements are written `if (...) {` — lexically identical to a
// function definition. Without this list every `if` block is mistaken for a
// function, and a test registered inside a top-level `if` is reported as dead.
const AHK_CONTROL_KEYWORDS = new Set([
	'if', 'else', 'while', 'for', 'loop', 'try', 'catch', 'finally', 'switch', 'case', 'until', 'return',
]);

/** True when `name` opens a control block rather than a function definition. */
function isControlKeyword(name) {
	return AHK_CONTROL_KEYWORDS.has(name.toLowerCase());
}

// ==================================================
// ==================================================
// ======= 1/ Walking the test trees ================
// ==================================================
// ==================================================

/**
 * Collects every test source file under a tree.
 * @param {string} dir - Absolute directory to walk.
 * @param {string} ext - File extension to keep (".ahk" or ".lua").
 * @param {string[]} out - Accumulator.
 * @returns {string[]} Absolute file paths.
 */
function walk(dir, ext, out = []) {
	if (!fs.existsSync(dir)) return out;
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, entry.name);
		if (entry.isDirectory()) walk(p, ext, out);
		else if (entry.name.endsWith(ext)) out.push(p);
	}
	return out;
}

/** Repo-relative POSIX path, so findings are copy-pasteable into an editor. */
function rel(p) {
	return path.relative(REPO_ROOT, p).replace(/\\/g, '/');
}

/** Strips a whole-line comment so a commented-out example is never a finding. */
function isComment(line, ext) {
	return ext === '.ahk' ? /^\s*;/.test(line) : /^\s*--/.test(line);
}

// ==================================================
// ==================================================
// ======= 2/ Parsing AHK function blocks ===========
// ==================================================
// ==================================================

/**
 * Splits an AHK source into its function definitions, tracking WHICH open brace
 * belongs to a function versus to a control block. Distinguishing the two is the
 * whole point: `Test(...)` inside a top-level `Loop Files { … }` is a normal
 * generated-test idiom, while `Test(...)` inside a function body never runs.
 * @param {string} src - Full file text.
 * @returns {{name: string, start: number, end: number, text: string}[]} Blocks.
 */
function ahkFunctionBlocks(src) {
	const lines = src.split(/\r?\n/);
	const blocks = [];
	let current = null;
	let depth = 0;

	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		if (isComment(line, '.ahk')) {
			if (current) current.body.push(line);
			continue;
		}
		// A definition is `Name(params) {` — a call site never carries a trailing brace.
		if (!current) {
			const m = line.match(/^([ \t]*)([A-Za-z_]\w*)\s*\([^()]*\)\s*\{/);
			if (m && !isControlKeyword(m[2])) {
				current = { name: m[2], start: i + 1, body: [] };
				depth = 0;
			}
		}
		if (!current) continue;

		current.body.push(line);
		// Ignore braces inside strings and trailing comments: a `"{"` literal would
		// otherwise unbalance the whole file and swallow every later function.
		const code = line.replace(/"(?:[^"`]|`.)*"/g, '""').replace(/'[^']*'/g, "''").replace(/;.*$/, '');
		for (const ch of code) {
			if (ch === '{') depth++;
			else if (ch === '}') depth--;
		}
		if (depth <= 0) {
			blocks.push({ name: current.name, start: current.start, end: i + 1, text: current.body.join('\n') });
			current = null;
		}
	}
	return blocks;
}

/**
 * Names, for every line, the innermost enclosing AHK FUNCTION (or null).
 * Registering tests from inside a helper that the file then CALLS at top level
 * is a legitimate idiom here — it is how the corpus files emit one test per
 * JSON vector. Only a registration inside a function nobody calls is dead, so
 * the enclosing name has to be carried, not just a boolean.
 * @param {string} src - Full file text.
 * @returns {(string|null)[]} Index i is the function enclosing line i+1.
 */
function ahkEnclosingFunction(src) {
	const lines = src.split(/\r?\n/);
	const owners = new Array(lines.length).fill(null);
	// Stack entries hold the function name a block belongs to, or null for a
	// control block (Loop/if/try), which must NOT mask an outer function.
	const stack = [];
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		if (isComment(line, '.ahk')) continue;
		for (let k = stack.length - 1; k >= 0; k--) {
			if (stack[k]) {
				owners[i] = stack[k];
				break;
			}
		}
		const raw = line.match(/^[ \t]*([A-Za-z_]\w*)\s*\([^()]*\)\s*\{/);
		const def = raw && !isControlKeyword(raw[1]) ? raw : null;
		const code = line.replace(/"(?:[^"`]|`.)*"/g, '""').replace(/'[^']*'/g, "''").replace(/;.*$/, '');
		let first = true;
		for (const ch of code) {
			if (ch === '{') {
				stack.push(def && first ? def[1] : null);
				first = false;
			} else if (ch === '}') {
				stack.pop();
			}
		}
	}
	return owners;
}

// ==================================================
// ==================================================
// ======= 3/ The four detectable patterns ==========
// ==================================================
// ==================================================

/**
 * PATTERN 1 — Tautology. `AssertTrue(true)` passes whatever the driver does.
 * These are usually placeholders written to fill a coverage checklist; the
 * message string describes a real invariant that nothing verifies, which makes
 * them read like genuine coverage in a diff review.
 */
const TAUTOLOGY = [
	/\bAssertTrue\s*\(\s*(?:true|1)\s*[,)]/,
	/\bAssert\s*\(\s*(?:true|1)\s*[,)]/,
	/\bassert_true\s*\(\s*true\s*[,)]/,
	/\bassert\s*\(\s*true\s*[,)]/,
];

function findTautologies(file, src, ext) {
	const out = [];
	src.split(/\r?\n/).forEach((line, i) => {
		if (isComment(line, ext)) return;
		if (TAUTOLOGY.some((re) => re.test(line))) out.push({ file: rel(file), line: i + 1, text: line.trim() });
	});
	return out;
}

/**
 * PATTERN 2 — Vacuous absence assertion (Windows only).
 * `_DriverFuncBody(Name)` returns "" when Name is not found
 * (tests/test_framework.ahk:254). `InStr("", "anything") == 0` is TRUE, so every
 * "the body must NOT contain X" assertion passes when the function was renamed,
 * moved out of the scanned tree, or simply mistyped. AHK v2 raises no load-time
 * error for an unknown name, so nothing anywhere reports the problem.
 *
 * A body is considered proven non-empty by either an explicit emptiness guard
 * (`Assert(Body != "", …)`) or by any PRESENCE assertion on the same variable
 * (`InStr(Body, "x") > 0`), which cannot pass on an empty string.
 */
function findVacuousAbsence(file, src) {
	const out = [];
	for (const block of ahkFunctionBlocks(src)) {
		const vars = new Set();
		for (const m of block.text.matchAll(/(\w+)\s*:=\s*_DriverFuncBody\s*\(/g)) vars.add(m[1]);
		if (vars.size === 0) continue;

		const proven = new Set();
		for (const v of vars) {
			const explicit = new RegExp(`Assert\\w*\\(\\s*(?:!\\s*)?(?:${v}\\s*!==?\\s*""|StrLen\\(\\s*${v}\\s*\\)\\s*>|${v}\\s*==?\\s*"")`);
			const presence = new RegExp(`InStr\\(\\s*${v}\\b[^\\r\\n]*?\\)\\s*(?:>\\s*0|>=\\s*1)`);
			if (explicit.test(block.text) || presence.test(block.text)) proven.add(v);
		}

		block.text.split('\n').forEach((line, idx) => {
			if (isComment(line, '.ahk') || !/Assert/.test(line)) return;
			for (const v of vars) {
				if (proven.has(v)) continue;
				const absence = new RegExp(`(?:InStr\\(\\s*${v}\\b[^\\r\\n]*?\\)\\s*(?:==?|<)\\s*(?:0|1)\\b|!\\s*InStr\\(\\s*${v}\\b)`);
				if (absence.test(line)) {
					out.push({ file: rel(file), line: block.start + idx, text: line.trim(), detail: `"${v}" is never proven non-empty` });
					break;
				}
			}
		});
	}
	return out;
}

/**
 * PATTERN 3 — A registered test that asserts nothing, or a test that is never
 * registered at all.
 *
 * 3a (AHK): `Test("…", Fn)` where Fn's body contains no assertion, no `throw`
 *     and does not delegate to a same-file helper that asserts.
 * 3b (AHK): a `Test(…)` call sitting inside a FUNCTION body. The runner
 *     collects registrations made during the auto-execute pass, so a
 *     registration nested in a function that nobody calls never happens — the
 *     file contributes zero tests and the suite total silently shrinks.
 * 3c (Lua): an `it("…", function() end)` with an empty body.
 */
function findDeadTests(file, src, ext) {
	const out = [];

	if (ext === '.lua') {
		src.split(/\r?\n/).forEach((line, i) => {
			if (isComment(line, ext)) return;
			if (/\bit\s*\(\s*(?:"[^"]*"|'[^']*')\s*,\s*function\s*\(\s*\)\s*end\s*\)/.test(line)) {
				out.push({ file: rel(file), line: i + 1, text: line.trim(), detail: 'empty test body' });
			}
		});
		return out;
	}

	const blocks = ahkFunctionBlocks(src);
	const byName = new Map(blocks.map((b) => [b.name, b]));

	/** True when the body asserts, throws, or reaches something that does. */
	const proves = (block, depth, seen) => {
		if (!block || seen.has(block.name)) return false;
		seen.add(block.name);
		if (/\bAssert\w*\s*\(|\bthrow\b/.test(block.text)) return true;
		if (depth <= 0) return false;
		// Match bare identifiers, not just call syntax: the common idiom here passes
		// the asserting body to a fixture helper BY REFERENCE
		// (`_FIL_WithFeatures(Map(…), _FIL_SomethingBody)`), and a `Name(`-only
		// regex reads that as a test asserting nothing.
		for (const m of block.text.matchAll(/\b([A-Za-z_]\w*)\b/g)) {
			if (m[1] === block.name) continue;
			if (byName.has(m[1]) && proves(byName.get(m[1]), depth - 1, seen)) return true;
		}
		return false;
	};

	for (const m of src.matchAll(/^[ \t]*Test\s*\(\s*(?:"[^"]*"|'[^']*')\s*,\s*([A-Za-z_]\w*)\s*\)/gm)) {
		const block = byName.get(m[1]);
		if (!block) continue;
		if (!proves(block, DELEGATION_DEPTH, new Set())) {
			out.push({ file: rel(file), line: block.start, text: `${m[1]}()`, detail: 'registered test body asserts nothing' });
		}
	}

	const owners = ahkEnclosingFunction(src);
	const lines = src.split(/\r?\n/);
	// A function is "reached" when the file calls it from outside any function.
	const reached = new Set();
	lines.forEach((line, i) => {
		if (isComment(line, '.ahk') || owners[i]) return;
		const m = line.match(/^[ \t]*([A-Za-z_]\w*)\s*\(\s*\)\s*$/);
		if (m) reached.add(m[1]);
	});
	lines.forEach((line, i) => {
		if (isComment(line, '.ahk') || !owners[i]) return;
		if (!/^\s*Test\s*\(\s*["']/.test(line)) return;
		// Walk outward: a chain of helpers is fine as long as the outermost one runs.
		if (reached.has(owners[i])) return;
		out.push({
			file: rel(file),
			line: i + 1,
			text: line.trim(),
			detail: `Test() sits in ${owners[i]}(), which the file never calls at top level`,
		});
	});
	return out;
}

/**
 * PATTERN 5 — "It did not crash" masquerading as a behavioural assertion.
 * `assert_true(ok)` where `ok` came from `pcall` proves only that the call
 * returned. Every wrong-but-non-throwing result — a nil prediction, an empty
 * expansion, a guard that silently no-ops — passes. This is the shape that let
 * the macOS `on_done` bug ship: the callback aborted on its first line, the
 * surrounding pcall swallowed it, and the test stayed green
 * (PROJECT_MEMORY, project-lua-closure-before-local-nil-global).
 */
function findPcallOnly(file, src) {
	const out = [];
	const lines = src.split(/\r?\n/);

	lines.forEach((line, i) => {
		if (isComment(line, '.lua')) return;
		if (/assert\w*\s*\(\s*pcall\s*\(/.test(line)) {
			out.push({ file: rel(file), line: i + 1, text: line.trim(), detail: 'asserts only that the call returned' });
		}
	});

	for (let i = 0; i < lines.length; i++) {
		if (isComment(lines[i], '.lua')) continue;
		const m = lines[i].match(/local\s+(\w+)\s*(?:,\s*([\w, ]+?))?\s*=\s*pcall\s*\(/);
		if (!m) continue;
		const statusVar = m[1];
		// A test that ALSO asserts on the pcall's returned value is doing real
		// work — the status check is just a precondition. Only flag the case
		// where the status is the sole thing ever asserted.
		const resultVars = (m[2] || '').split(',').map((s) => s.trim()).filter(Boolean);
		const window = lines.slice(i + 1, Math.min(i + 12, lines.length)).filter((l) => !isComment(l, '.lua')).join('\n');
		if (resultVars.some((v) => new RegExp(`assert\\w*\\s*\\([^)\\n]*\\b${v}\\b`).test(window))) continue;

		for (let j = i + 1; j < Math.min(i + 8, lines.length); j++) {
			if (isComment(lines[j], '.lua')) continue;
			if (new RegExp(`assert\\w*\\s*\\(\\s*${statusVar}\\s*[,)]`).test(lines[j])) {
				out.push({ file: rel(file), line: j + 1, text: lines[j].trim(), detail: `"${statusVar}" is a pcall status, not a result` });
				break;
			}
		}
	}
	return out;
}

/**
 * PATTERN 6 — A corpus consumer that SKIPS when its corpus cannot be loaded.
 * `Corpus := _CorpusHS_Parse()` followed by `if Corpus = "" { return }` turns a
 * missing or malformed corpus into a PASS. The shared corpora are cross-driver
 * contracts, so the one event that must fail loudest — the contract went
 * missing — was the one event that produced green.
 *
 * Measured before the guard existed: moving `_shared/tests/corpus/` produced
 * one red (the single readability test) and sixteen silent greens across
 * test_corpus_hotstrings.ahk and test_corpus_tap_hold.ahk. The fix is for the
 * LOADER to throw; a consumer never needs this branch.
 */
function findCorpusSkips(file, src, ext) {
	const out = [];
	const lines = src.split(/\r?\n/);
	const isAhk = ext === '.ahk';
	// Only a value that came from a corpus/fixture/vector loader — a plain "" guard
	// on a parsed field is ordinary defensive code, not a skipped contract.
	const assign = isAhk
		? /^\s*(\w+)\s*:=\s*[\w.]*(?:corpus|fixture|vectors)\w*\s*\(/i
		: /^\s*local\s+(\w+)\s*=\s*[\w.]*(?:corpus|fixture|vectors)\w*\s*\(/i;

	for (let i = 0; i < lines.length; i++) {
		if (isComment(lines[i], ext)) continue;
		const m = lines[i].match(assign);
		if (!m) continue;
		const v = m[1];
		const guard = isAhk
			? new RegExp(`^\\s*if\\s*\\(?\\s*!?\\s*${v}\\s*(?:==?=?\\s*""|\\)?\\s*(?:\\{|$))`)
			: new RegExp(`^\\s*if\\s+(?:not\\s+${v}\\b|${v}\\s*==\\s*nil)`);
		for (let j = i + 1; j < Math.min(i + 5, lines.length); j++) {
			if (isComment(lines[j], ext)) continue;
			if (!guard.test(lines[j])) continue;
			// The guard is only a false green when its body gives up silently.
			const body = lines.slice(j, Math.min(j + 4, lines.length)).join('\n');
			if (/\bAssert\w*\s*\(|\bassert\w*\s*\(|\bthrow\b|\berror\s*\(|\bTest\s*\(/.test(body)) break;
			if (/^\s*return\b|\breturn\s+end\b/m.test(body)) {
				out.push({
					file: rel(file),
					line: j + 1,
					text: lines[j].trim(),
					detail: `"${v}" came from a corpus loader — skipping makes a missing contract pass`,
				});
			}
			break;
		}
	}
	return out;
}

// ==================================================
// ==================================================
// ======= 4/ Scanning and reporting ================
// ==================================================
// ==================================================

const PATTERNS = {
	tautology: 'Assertion that cannot fail (Assert(true) / assert_true(true))',
	'vacuous-absence': 'Absence assertion on a _DriverFuncBody() that may be empty',
	'dead-test': 'Test body that asserts nothing, or a Test() never registered',
	'pcall-only': 'Assertion on a pcall status — proves "did not crash", nothing else',
	'corpus-skip': 'Early return when a corpus could not be loaded — a missing contract passes',
};

function scan() {
	const findings = { tautology: [], 'vacuous-absence': [], 'dead-test': [], 'pcall-only': [], 'corpus-skip': [] };
	for (const tree of TREES) {
		for (const file of walk(tree.dir, tree.ext)) {
			const src = fs.readFileSync(file, 'utf8');
			findings.tautology.push(...findTautologies(file, src, tree.ext));
			findings['dead-test'].push(...findDeadTests(file, src, tree.ext));
			findings['corpus-skip'].push(...findCorpusSkips(file, src, tree.ext));
			if (tree.ext === '.ahk') findings['vacuous-absence'].push(...findVacuousAbsence(file, src));
			else findings['pcall-only'].push(...findPcallOnly(file, src));
		}
	}
	return findings;
}

function readBaseline() {
	if (!fs.existsSync(BASELINE_PATH)) return null;
	try {
		return JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
	} catch (e) {
		console.error(`find-false-greens: baseline is unreadable (${e.message}) — treating as absent.`);
		return null;
	}
}

function main() {
	const args = process.argv.slice(2);
	const verbose = args.includes('--list');
	const update = args.includes('--update-baseline');
	const only = (args.find((a) => a.startsWith('--pattern=')) || '').replace('--pattern=', '');

	const findings = scan();
	const counts = Object.fromEntries(Object.entries(findings).map(([k, v]) => [k, v.length]));

	if (update) {
		fs.writeFileSync(BASELINE_PATH, JSON.stringify(counts, null, '\t') + '\n', 'utf8');
		console.log(`find-false-greens: baseline written to ${rel(BASELINE_PATH)}`);
		console.log(JSON.stringify(counts, null, '\t'));
		return 0;
	}

	console.log('find-false-greens: tests that cannot fail\n');
	const baseline = readBaseline();
	let regressions = 0;

	for (const [key, label] of Object.entries(PATTERNS)) {
		if (only && only !== key) continue;
		const list = findings[key];
		const max = baseline ? baseline[key] : null;
		const over = max !== null && max !== undefined && list.length > max;
		if (over) regressions += list.length - max;

		const budget = max === null || max === undefined ? '(no baseline)' : `baseline ${max}`;
		console.log(`  ${over ? 'OVER  ' : 'ok    '} ${String(list.length).padStart(4)}  ${key.padEnd(16)} ${budget}`);
		console.log(`         ${label}`);

		if (verbose || over) {
			// When over budget, print everything: the tool cannot know WHICH
			// occurrence is new, and pointing at the wrong line wastes more time
			// than printing the full list.
			for (const f of list) {
				console.log(`           ${f.file}:${f.line}${f.detail ? `  — ${f.detail}` : ''}`);
				if (verbose) console.log(`               ${f.text.slice(0, 120)}`);
			}
		}
		console.log('');
	}

	console.log('  Not detectable here — hunt these by hand (see the false-green-tests skill):');
	console.log('   - a harness that stubs the very function the test claims to verify');
	console.log('   - a source-grep pinning the current SPELLING of the code, not the invariant\n');

	if (!baseline) {
		console.log('No baseline recorded. Run with --update-baseline to freeze these counts as the ceiling.');
		return 0;
	}
	if (regressions > 0) {
		console.error(`find-false-greens: ${regressions} new occurrence(s) above baseline — the ratchet only turns down.`);
		console.error('If an occurrence is genuinely justified, say why in the test and re-run with --update-baseline.');
		return 1;
	}
	const total = Object.values(counts).reduce((a, b) => a + b, 0);
	const baseTotal = Object.values(baseline).reduce((a, b) => a + b, 0);
	console.log(`find-false-greens: within baseline (${total} vs ${baseTotal}).`);
	if (total < baseTotal) console.log('Some patterns dropped — re-run with --update-baseline to lock the improvement in.');
	return 0;
}

process.exit(main());
