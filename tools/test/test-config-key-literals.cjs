// tools/test/test-config-key-literals.cjs

/**
 * ==============================================================================
 * MODULE: Raw Config-Key and Command-Id Literal Ratchet
 * DESCRIPTION:
 * Counts, per driver or tool source file, the string literals that spell a
 * configuration key or a menu command id by hand instead of reading the
 * generated constant (`config_keys.lua`, `_generated/config_keys.js`,
 * `_generated/config_keys.ahk`). The committed baseline records today's
 * counts; a file may only go down.
 *
 * WHAT COUNTS AS A LITERAL:
 * A whole quoted string equal to a dotted KEY (`"metrics.private_filter_enabled"`),
 * a LEAF with an underscore (`"private_filter_enabled"`, `"time_activation_seconds"`)
 * or a COMMAND with an underscore (`"scope_restore"`). Single words such as
 * `"enabled"` or `"reload"` are everyday strings in unrelated code and are not
 * counted; the `_meta` leaves (`schema_version`) name every versioned format in
 * the tree, not this configuration. Comment lines are skipped: explaining a key
 * is not reading it. A `require` argument is a module path, not a key, even
 * when it is spelt like one.
 *
 * WHY A RATCHET AND NOT A BAN:
 * About 2300 literals predate the constants, in code other agents
 * edit concurrently. Rewriting them in one sweep would conflict with all of
 * that work; a ratchet stops new ones today and lets each area migrate in its
 * own commit. A lower count must be written back (`--shrink`) so the baseline
 * cannot keep headroom that a later edit would silently spend.
 *
 * USAGE:
 *   node tools/test/test-config-key-literals.cjs           check
 *   node tools/test/test-config-key-literals.cjs --shrink  lower the baseline to today's counts
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const Codegen = require('../codegen/codegen-config-keys.cjs');
const { allOutputs } = require('../build/generators.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BASELINE = 'tools/lint/config-key-literal-baseline.json';
const SCANNED_EXTENSIONS = /\.(lua|ahk|js|cjs|mjs)$/;
// The drivers and the Node tools: a tool that spells a key by hand drifts from the schema the same way.
const SCANNED_ROOTS = ['static/ergopti_plus', 'tools'];
// Tests spell keys on purpose (they assert the spelling); vendored code is not ours.
const EXCLUDED = /(^|\/)(tests|test|vendor|node_modules)\//;
const COMMENT_LINE = /^\s*(--|;|\/\/|\*|\/\*)/;
// A line (or the line below a whole-line marker comment) that spells a homonym of a key on
// purpose, such as a prompt template token, says so and is not counted.
const EXEMPT_MARKER = 'config-key-literal-ok';
const STRING_LITERAL = /"([^"\\\n]*)"|'([^'\\\n]*)'/g;
// A module path is not a config key even when it is spelt like one
// (`require("llm.app_profile_overrides")`).
// A string that names a log channel, a window or a stop label is a homonym of a key, found by
// the syntax around it: `LOG = "x"`, `get_app_geometry("x")`, `Logger.info("x", ...)`,
// `label = "x"`, `name = "x"`.
// A menu GROUP or MODULE id is spelt like a section or a command too: `group_receiver("top_level", "x")`,
// `module_rows("x")`, and the dispatch tables keyed by module name (`["x"] = _build_x`,
// `["x"] = function() return module_rows("x") end`). A list of METHOD or DEPENDENCY names a
// participant must provide (`for _, method in ipairs({ ... })`) is not a key list either.
const HOMONYM_BEFORE =
	/(?:\b(?:LOG|APP_NAME|MODULE_NAME|TAG)\s*=|\b(?:label|name)\s*=|\b(?:get_app_geometry|ControllerPool\.reserve|Logger\.\w+|module_rows)\s*\(|\bgroup_receiver\(\s*"[^"]*"\s*,|\b(?:method|dependency)\s+in\s+ipairs\(\{[^}]*)\s*$/;
const HOMONYM_AFTER = /^\]\s*=\s*(?:_build_\w+\s*,|function\(\)\s*return module_rows\()/;
const REQUIRE_BEFORE = /\brequire\s*(?:\(\s*|,\s*)?$/;

// ==========================================
// ==========================================
// ======= 1/ Vocabulary and counting =======
// ==========================================
// ==========================================

/**
 * The literal values the ratchet counts, from the generated tables.
 * @param {ReturnType<Codegen.collect>} tables
 * @returns {Set<string>}
 */
function vocabulary(tables) {
	const words = new Set();
	const metaLeaves = new Set(
		tables.KEY.filter(([, key]) => key.startsWith('_meta.')).map(([, key]) => key.split('.').pop())
	);
	// A section's own name (`tap_keys`, `caps_word`) is also a module name: only a leaf that
	// some declared property carries counts.
	const sectionOnly = new Set(tables.SECTION.map((key) => key.split('.').pop()));
	const declaredLeaf = new Set(
		tables.KEY.map(([, key]) => key)
			.filter((key) => !tables.SECTION.includes(key))
			.map((key) => key.split('.').pop())
	);
	for (const leaf of declaredLeaf) sectionOnly.delete(leaf);
	for (const [, key] of tables.KEY) if (key.includes('.')) words.add(key);
	for (const [, leaf] of tables.LEAF)
		if (
			leaf.includes('_') &&
			!leaf.startsWith('_') &&
			!metaLeaves.has(leaf) &&
			!sectionOnly.has(leaf)
		)
			words.add(leaf);
	for (const [, id] of tables.COMMAND) if (id.includes('_')) words.add(id);
	return words;
}

/**
 * Counts the counted literals in one source text.
 * @param {string} text File contents.
 * @param {Set<string>} words The vocabulary.
 * @returns {number}
 */
function countLiterals(text, words) {
	let count = 0;
	let exemptNext = false;
	for (const line of text.split('\n')) {
		const exempt = exemptNext || line.includes(EXEMPT_MARKER);
		exemptNext = COMMENT_LINE.test(line) && line.includes(EXEMPT_MARKER);
		if (COMMENT_LINE.test(line) || exempt) continue;
		for (const m of line.matchAll(STRING_LITERAL)) {
			if (!words.has(m[1] ?? m[2])) continue;
			if (REQUIRE_BEFORE.test(line.slice(0, m.index))) continue;
			if (HOMONYM_BEFORE.test(line.slice(0, m.index))) continue;
			if (HOMONYM_AFTER.test(line.slice(m.index + m[0].length))) continue;
			count++;
		}
	}
	return count;
}

/**
 * Per-file counts over every tracked driver source file.
 * @param {Set<string>} words
 * @returns {Record<string, number>} Only files with a non-zero count, sorted.
 */
function scan(words) {
	const generated = new Set(allOutputs());
	const files = execFileSync('git', ['ls-files', '-z', ...SCANNED_ROOTS], { cwd: ROOT })
		.toString('utf8')
		.split('\0')
		.filter((f) => SCANNED_EXTENSIONS.test(f) && !EXCLUDED.test(f) && !generated.has(f))
		.sort();
	const counts = {};
	for (const file of files) {
		const abs = path.join(ROOT, file);
		if (!fs.existsSync(abs)) continue;
		const n = countLiterals(fs.readFileSync(abs, 'utf8'), words);
		if (n > 0) counts[file] = n;
	}
	return counts;
}

// ==========================================
// ==========================================
// ======= 2/ Ratchet =======================
// ==========================================
// ==========================================

/**
 * Compares today's counts with the baseline.
 * @param {Record<string, number>} current
 * @param {Record<string, number>} baseline
 * @returns {{grown: string[], stale: string[]}}
 */
function compare(current, baseline) {
	const grown = [];
	const stale = [];
	for (const [file, n] of Object.entries(current)) {
		const allowed = baseline[file] ?? 0;
		if (n > allowed) grown.push(`${file}: ${n} literal(s), baseline allows ${allowed}`);
	}
	for (const [file, allowed] of Object.entries(baseline)) {
		const n = current[file] ?? 0;
		if (n < allowed) stale.push(`${file}: ${n} literal(s), baseline still allows ${allowed}`);
	}
	return { grown, stale };
}

/** Lowers every baseline entry to today's count; never raises one. */
function shrunk(current, baseline) {
	const out = {};
	for (const file of Object.keys(baseline).sort()) {
		const n = Math.min(current[file] ?? 0, baseline[file]);
		if (n > 0) out[file] = n;
	}
	return out;
}

function readBaseline() {
	const parsed = JSON.parse(fs.readFileSync(path.join(ROOT, BASELINE), 'utf8'));
	if (!parsed || typeof parsed.files !== 'object')
		throw new Error(`${BASELINE}: expected a "files" object`);
	return parsed;
}

function writeBaseline(previous, files) {
	const out = { ...previous, files };
	fs.writeFileSync(path.join(ROOT, BASELINE), JSON.stringify(out, null, '\t') + '\n', 'utf8');
}

function total(counts) {
	return Object.values(counts).reduce((a, b) => a + b, 0);
}

/**
 * Proves the counter and the comparison can fail before trusting a green
 * result: a scan that matched nothing would pass every baseline.
 * @param {Set<string>} words
 */
function selfTest(words) {
	const probe = [
		'local v = prefs["metrics.private_filter_enabled"]',
		"store_bool('private_filter_enabled', on)",
		'Menu.on("scope_restore", restore)',
		'-- "metrics.private_filter_enabled" is only explained here',
		'local s = "enabled" .. "schema_version"',
		'local m = "metrics.private_filter_enabled is the key"',
		'local Overrides = require("llm.app_profile_overrides")',
		'local ok, mod = pcall(require, "llm.app_profile_overrides")',
		'local LOG = "shortcuts.tap_keys"',
		'local geo = ui_builder.get_app_geometry("layout_manager")',
		'Logger.info("scope_restore", "x")',
		'{ name = "tap_holds", stop = f }',
		'x = "min_words" -- config-key-literal-ok: a prompt token',
		'-- config-key-literal-ok: the next line is a homonym',
		'local tokens = { "max_words" }',
		'local again = "max_words"',
		'local receive = Menu.group_receiver("top_level", "tap_holds")',
		'return module_rows("tap_holds")',
		'["tap_holds"]       = _build_tap_holds,',
		'["tap_holds"]       = function() return module_rows("tap_holds") end,',
		'for _, method in ipairs({ "scope_acquire", "scope_restore" }) do',
		'for _, field in ipairs({ "private_filter_enabled" }) do'
	].join('\n');
	const n = countLiterals(probe, words);
	if (n !== 5) throw new Error(`self-test: expected 5 counted literals in the probe, got ${n}`);
	if (
		!SCANNED_ROOTS.includes('tools') ||
		!['tools/x.cjs', 'tools/x.mjs'].every((f) => SCANNED_EXTENSIONS.test(f))
	)
		throw new Error('self-test: the Node tools must stay under the ratchet');
	const { grown, stale } = compare({ 'a.lua': 2, 'b.lua': 1 }, { 'a.lua': 1, 'c.lua': 4 });
	if (grown.length !== 2 || stale.length !== 1)
		throw new Error('self-test: compare() no longer reports a rise, a new file and headroom');
	const lowered = shrunk({ 'a.lua': 5, 'c.lua': 0 }, { 'a.lua': 3, 'c.lua': 4 });
	if (JSON.stringify(lowered) !== JSON.stringify({ 'a.lua': 3 }))
		throw new Error('self-test: --shrink must lower or drop entries and never raise one');
}

function main() {
	const words = vocabulary(Codegen.collect());
	selfTest(words);
	const current = scan(words);
	const baseline = readBaseline();

	if (process.argv.includes('--shrink')) {
		const files = shrunk(current, baseline.files);
		writeBaseline(baseline, files);
		console.log(
			`[OK] ${BASELINE} lowered from ${total(baseline.files)} to ${total(files)} literal(s).`
		);
	}

	const { grown, stale } = compare(current, readBaseline().files);
	if (grown.length > 0 || stale.length > 0) {
		if (grown.length > 0) {
			console.error(
				'\x1b[31m[ERROR] new hand-typed config keys or command ids — read the generated ' +
					'constant instead (ConfigKeys.KEY/LEAF/COMMAND, ConfigKey/ConfigLeaf/MenuCommand):\x1b[0m'
			);
			for (const g of grown) console.error('    - ' + g);
		}
		if (stale.length > 0) {
			console.error(
				'\x1b[31m[ERROR] the baseline allows more literals than remain; lower it with ' +
					'`node tools/test/test-config-key-literals.cjs --shrink`:\x1b[0m'
			);
			for (const s of stale) console.error('    - ' + s);
		}
		process.exit(1);
	}
	console.log(
		`[OK] ${total(current)} raw config-key/command-id literal(s) in ${Object.keys(current).length} ` +
			'file(s), none above the baseline.'
	);
}

if (require.main === module) main();

module.exports = { BASELINE, vocabulary, countLiterals, scan, compare, shrunk };
