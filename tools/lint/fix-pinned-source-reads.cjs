// tools/lint/fix-pinned-source-reads.cjs

/**
 * ==============================================================================
 * MODULE: Pinned Source-Read Auto-Fixer (macOS / Lua tests)
 * DESCRIPTION:
 * Converts location-pinned source reads in macOS tests — any io.open of a path
 * naming a driver source file — into the move-resilient
 * `helpers.read_driver_source(symbol)` scan, so renaming or splitting a driver
 * module cannot turn a useful invariant into a path error.
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
 * 3. Candidate selectors go beyond declarations. Five menu/UI modules declare
 *    only the non-unique `function M.build` / `function M.new`, and refusing them
 *    was recorded as "needs a human" — but each carries a unique constant or
 *    i18n key. "Needs a human" meant "needs a selector the fixer cannot
 *    generate", which is a gap in the generator, not a property of the test.
 * 4. It shares its notion of a pinned path with the ratchet
 *    (tools/lint/pinned-source-read.cjs). While each carried its own regex they
 *    disagreed by a factor of five, so the fixer reported "0 convertible" against
 *    a population it could not see.
 * 5. Default scope is staged files, so the pre-commit hook can block a NEW pinned
 *    read without churning the tolerated legacy ones.
 *
 * USAGE:
 *   node tools/lint/fix-pinned-source-reads.cjs            # staged files, report
 *   node tools/lint/fix-pinned-source-reads.cjs --fix      # staged files, rewrite
 *   node tools/lint/fix-pinned-source-reads.cjs --all      # whole test tree, report
 *   node tools/lint/fix-pinned-source-reads.cjs --all --fix
 * ==============================================================================
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { SOURCE_PATH_LITERAL, collectLuaTests } = require('./pinned-source-read.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const TESTS_DIR = path.join(MACOS, 'tests');

// The quoted path, as a capturing group. SOURCE_PATH_LITERAL includes its own
// quotes, so the capture keeps them and the caller trims.
const QUOTED_PATH = `(${SOURCE_PATH_LITERAL})`;
// `helpers.driver_root()`, `driver_root()`, or a bare local holding either.
const ROOT_EXPR = '(?:[\\w.]*driver_root\\(\\)|\\b[A-Za-z_]\\w*\\b)';

// Everything between obtaining the handle and holding the source text. The
// optional lines are all shapes present in the tree: a bare io.open, an
// assert(io.open(...)), a bare assert(fh, …) on its own line, and an io.open
// followed by an explicit guard. None is any more ambiguous than the others.
const READ_TAIL =
	'(?:[ \\t]*(?:helpers\\.assert_[a-z_]+|assert)\\([^\\n]*\\r?\\n)?' +
	'(?:[ \\t]*if not \\w+ then return[^\\n]*end[ \\t]*\\r?\\n|[ \\t]*if not \\w+ then error\\([^\\n]*\\)[ \\t]*end[ \\t]*\\r?\\n)?' +
	'[ \\t]*local\\s+(\\w+)\\s*=\\s*\\w+:read\\("\\*a"\\)[ \\t]*(?:;[ \\t]*\\w+:close\\(\\))?[ \\t]*\\r?\\n' +
	'(?:[ \\t]*\\w+:close\\(\\)[ \\t]*\\r?\\n)?';

// The handle line, with an optional assert wrapper and optional message argument.
const OPEN_CALL = (pathExpr) =>
	`[ \\t]*local\\s+(\\w+)\\s*=\\s*(?:assert\\(\\s*)?io\\.open\\(\\s*${pathExpr}\\s*,\\s*"r"\\s*\\)(?:\\s*,[^\\n]*)?\\s*\\)?[ \\t]*\\r?\\n`;

// Shape A — the path is bound to a local, then opened on the next line.
const SHAPE_A = new RegExp(
	`([ \\t]*)local\\s+(\\w+)\\s*=\\s*${ROOT_EXPR}\\s*\\.\\.\\s*${QUOTED_PATH}[ \\t]*\\r?\\n` +
		OPEN_CALL('\\2') +
		READ_TAIL
);
// Shape B — the concatenation is written inline inside io.open.
const SHAPE_B = new RegExp(
	`([ \\t]*)local\\s+(\\w+)\\s*=\\s*(?:assert\\(\\s*)?io\\.open\\(\\s*${ROOT_EXPR}\\s*\\.\\.\\s*${QUOTED_PATH}\\s*,\\s*"r"\\s*\\)(?:\\s*,[^\\n]*)?\\s*\\)?[ \\t]*\\r?\\n` +
		READ_TAIL
);

// Group indices differ between the two shapes; name them once.
const SHAPES = [
	{ name: 'var-then-open', re: SHAPE_A, indent: 1, quoted: 3, srcVar: 5 },
	{ name: 'inline-open', re: SHAPE_B, indent: 1, quoted: 3, srcVar: 4 },
];

/** Production sources, cached — every selector is checked against this set. */
let productionCache = null;
function productionSources() {
	if (!productionCache) {
		const acc = [];
		(function walk(dir) {
			if (!fs.existsSync(dir)) return;
			for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
				const full = path.join(dir, e.name);
				if (e.isDirectory()) {
					if (e.name === 'tests') continue;
					walk(full);
				} else if (e.name.endsWith('.lua')) acc.push(full);
			}
		})(MACOS);
		productionCache = acc.map((f) => ({ file: f, body: fs.readFileSync(f, 'utf8') }));
	}
	return productionCache;
}

/**
 * Builds the ordered selector candidates for one module.
 *
 * Declarations come first because they are stable and meaningful. The later
 * classes exist because five menu/UI modules declare only `function M.build` —
 * a name shared by a dozen files — while each carries a constant or an i18n key
 * that names it alone.
 * @param {string} body - The module's source text.
 * @returns {string[]} Candidate selector literals, best first.
 */
function selectorCandidates(body) {
	const classes = [
		[...body.matchAll(/^local function ([A-Za-z0-9_]{5,})/gm)].map((m) => m[0]),
		[...body.matchAll(/^function M\.([A-Za-z0-9_]{5,})/gm)].map((m) => m[0]),
		[...body.matchAll(/^function [A-Za-z_]\w*[.:]([A-Za-z0-9_]{5,})/gm)].map((m) => m[0]),
		// Trailing `= …` deliberately dropped: the alignment spaces around it are
		// reformatting fodder, and a selector that a formatter can break is a
		// path pin with extra steps.
		[...body.matchAll(/^local ([A-Z][A-Z0-9_]{4,})\s*=/gm)].map((m) => `local ${m[1]}`),
	];

	// Long string literals — i18n keys and log markers, for the five menu modules
	// whose only declarations are the non-unique `function M.build`.
	//
	// The content must look like a KEY. Matching any quote-delimited run picked up
	// the code BETWEEN two adjacent string literals — the first pass produced
	// `") .. string.upper(state.apps_time_shortcut.key or "` as a selector, which
	// is unique, passes, and pins the exact spelling of an expression. Excluded
	// too: anything naming a .lua file, which would swap one path pin for another.
	const strings = [...body.matchAll(/"([A-Za-z][A-Za-z0-9_.\- ]{13,})"/g)]
		.map((m) => m[0])
		.filter((s) => !s.includes('.lua'));

	const out = [];
	for (const cls of classes) {
		cls.sort((a, b) => b.length - a.length); // longer collides less often
		out.push(...cls);
	}
	strings.sort((a, b) => b.length - a.length);
	out.push(...strings);
	return out;
}

/**
 * Finds a selector that appears in NO other production file.
 *
 * Uniqueness is the whole safety argument: read_driver_source concatenates every
 * file containing the symbol, so a selector matching two files changes what the
 * calling test is actually asserting about.
 * @param {string} relTarget - Driver-relative path of the module, e.g. "infra/logger.lua".
 * @returns {string|null} A proven-unique selector, or null when none exists.
 */
function uniqueSelectorFor(relTarget) {
	const sources = productionSources();
	const abs = path.join(MACOS, relTarget.split('/').join(path.sep));
	const entry = sources.find((s) => s.file === abs);
	if (!entry) return null;

	for (const c of selectorCandidates(entry.body)) {
		if (sources.filter((s) => s.body.includes(c)).length === 1) return c;
	}
	return null;
}

/**
 * Converts the local `read_source(rel)` helpers that most of the tree uses.
 *
 * Two thirds of the remaining pins are not written at the read site at all: the
 * file declares one helper taking a driver-relative path and calls it a dozen
 * times. Converting the read site alone would have left them all, and the same
 * rewrite applies — the helper stops taking a PATH and starts taking a SELECTOR,
 * and each call site swaps its literal for the selector of the module it names.
 *
 * Refuses the whole helper unless EVERY call site passes a resolvable literal
 * with a proven-unique selector: a helper taking a selector at some call sites
 * and a path at others is worse than one that never changed.
 * @param {string} src - Test file contents.
 * @param {string[]} blocked - Accumulator for refusals.
 * @returns {{src: string, converted: number}} Rewritten source and pin count.
 */
function convertHelpers(src, blocked) {
	let converted = 0;
	// Helpers converted so far in this file. A second-level wrapper —
	// assert_gc_pinned(rel) forwarding to read_source(rel) — reads no file itself,
	// so it only becomes convertible once its callee has been. Ten of the pins in
	// test_gc_retention.lua are behind exactly that one indirection.
	const convertedNames = new Set();
	// Seed with helpers a previous run already converted, or a wrapper around one
	// of them stays invisible for ever: its callee no longer looks like a read.
	//
	// The marker is the parameter NAME. The fixer always emits `(selector, …)`, so
	// that spelling is a reliable "already done" flag — and it has to be checked,
	// not merely used for seeding: a converted wrapper still forwards its
	// parameter to a converted callee, so it matches the detector on every later
	// run, and its arguments are now selectors that no resolvability check can
	// accept. The pre-commit hook blocked on exactly that.
	for (const m of src.matchAll(/local function (\w+)\(selector\b/g)) convertedNames.add(m[1]);
	for (const m of src.matchAll(
		/local function (\w+)\((\w+)[^)]*\)\r?\n(?:[^\n]*\r?\n){0,6}?[^\n]*helpers\.read_driver_source\(\s*\2\s*\)/g
	)) {
		convertedNames.add(m[1]);
	}
	for (let pass = 0; pass < 4; pass++) {
		const before = converted;
		converted += convertHelperPass(
			() => src,
			(s) => {
				src = s;
			},
			convertedNames,
			blocked
		);
		if (converted === before) break;
	}
	return { src, converted };
}

/**
 * One fixpoint pass of the helper conversion.
 * @param {() => string} get - Reads the current source.
 * @param {(s: string) => void} set - Writes the rewritten source.
 * @param {Set<string>} convertedNames - Helpers already taking a selector.
 * @param {string[]} blocked - Accumulator for refusals.
 * @returns {number} Pins converted in this pass.
 */
function convertHelperPass(get, set, convertedNames, blocked) {
	let src = get();
	let converted = 0;
	// The path is always the FIRST parameter; later ones (a marker to look for, a
	// baseline) ride along untouched. Restricting this to single-parameter
	// helpers left assert_gc_pinned and check_file behind for no reason.
	const defRe = /^([ \t]*)local function (\w+)\((\w+)((?:\s*,\s*\w+)*)\)[ \t]*\r?\n([\s\S]*?)\r?\n\1end[ \t]*$/gm;

	for (const def of [...src.matchAll(defRe)]) {
		const [whole, indent, name, param, moreParams, body] = def;
		const P = param.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

		// Does the body read the file its own parameter names?
		const inline = new RegExp(
			`([ \\t]*)local\\s+(\\w+)\\s*=\\s*(?:assert\\(\\s*)?io\\.open\\(\\s*${ROOT_EXPR}\\s*\\.\\.\\s*${P}\\s*,\\s*"r"\\s*\\)(?:\\s*,[^\\n]*)?\\s*\\)?[ \\t]*\\r?\\n` +
				READ_TAIL
		);
		const varThen = new RegExp(
			`([ \\t]*)local\\s+(\\w+)\\s*=\\s*${ROOT_EXPR}\\s*\\.\\.\\s*${P}[ \\t]*\\r?\\n` +
				OPEN_CALL('\\2') +
				READ_TAIL
		);
		if (convertedNames.has(name)) continue;
		// … or does it hand its parameter to a helper already converted?
		const forwards = [...convertedNames].some((c) =>
			new RegExp(`(?<![:.\\w])${c}\\(\\s*${P}\\s*[,)]`).test(body)
		);
		const hit = body.match(inline) || body.match(varThen);
		if (!hit && !forwards) continue;
		const srcVar = hit ? hit[hit.length - 1] : null;
		const blockIndent = hit ? hit[1] : null;

		// Every call site must name a module with a unique selector, or the helper
		// is left alone: half-converted, it would take two different kinds of
		// argument and the next reader could not tell which.
		// The lookbehind excludes a method call: a helper named `read` otherwise
		// matched `fh:read("*a")`, and the fixer refused the whole file because
		// "*a" is not a driver source path.
		const callRe = new RegExp(`(?<![:.\\w])${name}\\(\\s*("[^"\\n]*")\\s*([,)])`, 'g');
		const calls = [...src.matchAll(callRe)];
		if (calls.length === 0) continue;
		const selectors = new Map();
		let refused = null;
		for (const c of calls) {
			const literal = c[1];
			if (selectors.has(literal)) continue;
			const rel = literal.slice(1, -1).replace(/^[.\\/]+/, '');
			if (!fs.existsSync(path.join(MACOS, rel.split('/').join(path.sep)))) {
				refused = `${name}(${literal}) [not a driver source file]`;
				break;
			}
			const selector = uniqueSelectorFor(rel);
			if (!selector) {
				refused = `${rel} [no declaration or constant unique to it]`;
				break;
			}
			selectors.set(literal, selector);
		}
		if (refused) {
			blocked.push(refused);
			continue;
		}

		// The parameter is renamed because it no longer holds what its name says,
		// and a message built from it ("cannot open " .. rel) would otherwise print
		// a selector while calling it a path.
		let newBody = hit
			? body.replace(hit[0], `${blockIndent}local ${srcVar} = helpers.read_driver_source(selector)\n`)
			: body;
		newBody = newBody.replace(new RegExp(`\\b${P}\\b`, 'g'), 'selector');
		const newDef =
			`${indent}-- Takes a selector unique to one production file rather than that file's\n` +
			`${indent}-- path, so moving or splitting a module cannot turn these invariants into\n` +
			`${indent}-- path errors.\n` +
			`${indent}local function ${name}(selector${moreParams})\n${newBody}\n${indent}end`;
		src = src.replace(whole, newDef);

		// The call site used to name the module it read. A selector does not, and
		// losing that costs more legibility than the move-resilience is worth, so
		// the path is kept as a trailing comment — a comment cannot break a test
		// when the file moves, it can only go stale.
		//
		// Only when the call ENDS the line: several sites read two modules and
		// concatenate them across a line continuation, where a trailing comment
		// would swallow the `..` and everything after it.
		src = src.replace(callRe, (m, literal, closer, offset, whole_) => {
			const rest = whole_.slice(offset + m.length, whole_.indexOf('\n', offset));
			const call = `${name}(${JSON.stringify(selectors.get(literal))}${closer}`;
			const endsLine = closer === ')' && /^\s*$/.test(rest);
			return endsLine ? `${call} -- ${literal.slice(1, -1)}` : call;
		});
		convertedNames.add(name);
		converted += calls.length;
	}
	set(src);
	return converted;
}

/**
 * Rewrites every convertible pinned read in one test file.
 * @param {string} file - Absolute path to the test file.
 * @param {boolean} apply - Whether to write the result back.
 * @returns {{converted: number, blocked: string[]}} Conversion outcome.
 */
function convertFile(file, apply) {
	let src = fs.readFileSync(file, 'utf8');
	const blocked = [];
	let converted = 0;

	for (const shape of SHAPES) {
		// The loop advances by neutralising each occurrence it refuses, which must
		// happen on a SCRATCH copy only. Doing it on `src` wrote the sentinel to
		// disk for any file holding both a convertible and a refused read.
		let scan = src;
		for (;;) {
			const m = scan.match(shape.re);
			if (!m) break;

			const indent = m[shape.indent];
			const relTarget = m[shape.quoted].slice(1, -1).replace(/^[.\\/]+/, '');
			const srcVar = m[shape.srcVar];
			const skip = `${indent}local __PINNED_UNRESOLVED__ = true\n`;

			const selector = uniqueSelectorFor(relTarget);
			if (!selector) {
				blocked.push(`${relTarget} [no declaration or constant unique to it]`);
				scan = scan.replace(shape.re, skip);
				continue;
			}

			// No `if not src then return end` tail: assert_true raises, so the guard
			// could never run — and at file scope a bare `return` would end the chunk
			// and silently drop every test declared below it.
			const replacement =
				`${indent}-- Selected by a declaration unique to ${relTarget} rather than by\n` +
				`${indent}-- path, so moving or splitting the module cannot turn this invariant\n` +
				`${indent}-- into a path error.\n` +
				`${indent}local ${srcVar} = helpers.read_driver_source(${JSON.stringify(selector)})\n` +
				`${indent}helpers.assert_true(${srcVar} ~= nil, "${relTarget} source must be locatable")\n`;
			src = src.replace(shape.re, replacement);
			scan = scan.replace(shape.re, skip);
			converted += 1;
		}
	}

	const viaHelper = convertHelpers(src, blocked);
	src = viaHelper.src;
	converted += viaHelper.converted;

	if (apply && converted > 0) fs.writeFileSync(file, src, 'utf8');
	return { converted, blocked };
}

// ---------- entry point ----------

const argv = process.argv.slice(2);
const apply = argv.includes('--fix');
const all = argv.includes('--all');

let targets;
if (all) {
	targets = collectLuaTests(TESTS_DIR, []);
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
	console.log(`\nsurvey: ${totalConverted} ${apply ? 'converted' : 'auto-convertible'}, ${offenders.length} need a human`);
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
	console.error(`\x1b[31m[ERROR] ${totalConverted} pinned source read(s) in staged tests.\x1b[0m`);
	console.error('  Run `npm run fix:pinned-reads` to convert them automatically.');
	process.exit(1);
}
