// tools/test/test-timings-registry-liveness.cjs

/**
 * ==============================================================================
 * MODULE: Timing Registry Liveness Gate
 * DESCRIPTION:
 * Every key of the shared timing registry
 * (_shared/modules/timings/constants.toml) must have a reader, and every
 * literal reader call must name a key the registry has.
 *
 * ROOT CAUSE ENCODED:
 * The registry calls itself "the single authoritative way to tune timings",
 * yet 40 of its 146 keys were read by nothing: mirrors of constants that had
 * moved elsewhere (the tooltip durations, whose canon is
 * tooltip/constants.toml, and one of which had drifted from 20 s to 12 s), keys
 * whose consumer had been deleted (a text-sender settle, a Karabiner priming
 * poll) and keys documenting AHK constants nothing compared them with. Tuning
 * any of them changed nothing, and a maintainer had no way to tell.
 *
 * WHAT COUNTS AS A READER:
 * 1. Runtime: a production source line (tests, vendor and generated code
 *    excluded) naming the quoted section and then the quoted key, which is how
 *    every driver reads it — `Timings.sec("ui", "layout_poll_ms")` on macOS and
 *    Linux, `TimingsGet("ui", "layout_poll_ms")` on Windows.
 * 2. Pinned copy: an entry of the PINS table of
 *    test-keystats-timings-single-source.cjs, or a `registry.<section>.<key>`
 *    comparison in one of the PIN_GATES below. A pinned copy is a driver literal
 *    that cannot read the registry yet; the pin keeps the two equal.
 *
 * FEATURES & RATIONALE:
 * 1. A key with no reader fails with the three possible fixes: prune it, wire
 *    a runtime read, or pin the driver copy.
 * 2. A literal `Timings.ms|sec|count(...)` or `TimingsGet[Sec](...)` call naming
 *    a missing key fails here, before the fail-fast reader throws at boot on
 *    the one driver that executes that line.
 * 3. The walk is floored and the gate proves it can fail on synthetic inputs.
 * 4. [limits] holds the byte caps (a child process's output, a declaration file,
 *    a feed, an identifier). Each key ends in `_bytes` and holds a positive
 *    integer, and a Lua or JavaScript `*_BYTES` constant may not retype the
 *    number of one of them: it reads the key, or it is listed in
 *    limit-literal-baseline.json, which can only shrink
 *    (--update-limit-baseline rewrites it and refuses while anything has
 *    grown). A byte cap that differs from every [limits] value is outside the
 *    section and is not flagged.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');
const { PINS, SOURCE_PINS } = require('./test-keystats-timings-single-source.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const REGISTRY_REL = '_shared/modules/timings/constants.toml';

// Gates that compare a driver copy with `registry.<section>.<key>`.
const PIN_GATES = ['tools/test/test-logger-scalars-single-source.cjs'];

const SOURCE_EXTENSIONS = /\.(?:lua|ahk|js|cjs|mjs|swift|py|sh)$/;
const SKIPPED_DIRECTORIES = new Set([
	'node_modules',
	'.git',
	'.build',
	'tests',
	'Tests',
	'vendor',
	'_generated'
]);
const MIN_SOURCE_FILES = 1000;

const READER_CALL =
	/\b(?:Timings\.(?:ms|sec|count)|TimingsGet(?:Sec)?)\(\s*"([A-Za-z_]\w*)"\s*,\s*"([A-Za-z_]\w*)"\s*\)/g;

/**
 * Every production source file of the drivers, as repository-relative paths.
 * @returns {{rel: string, text: string}[]}
 */
function productionSources() {
	const out = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const abs = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (!SKIPPED_DIRECTORIES.has(entry.name)) walk(abs);
			} else if (SOURCE_EXTENSIONS.test(entry.name)) {
				out.push({
					rel: path.relative(SP, abs).split(path.sep).join('/'),
					text: fs.readFileSync(abs, 'utf8')
				});
			}
		}
	};
	walk(SP);
	return out;
}

function escape(text) {
	return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * The analysis, over explicit inputs so the self-test can feed it synthetic ones.
 * @param {Object} registry Parsed registry ([section][key] = value).
 * @param {{rel: string, text: string}[]} sources Production sources.
 * @param {{section: string, key: string}[]} pins Pinned driver copies.
 * @param {string[]} pinGateTexts Sources of the gates comparing registry.<s>.<k>.
 * @returns {{errors: string[], runtime: number, pinned: number}}
 */
function analyse(registry, sources, pins, pinGateTexts) {
	const errors = [];
	let runtime = 0;
	let pinned = 0;
	for (const [section, keys] of Object.entries(registry)) {
		if (keys === null || typeof keys !== 'object') {
			errors.push(`${REGISTRY_REL}: top-level key "${section}" is not a [section]`);
			continue;
		}
		for (const key of Object.keys(keys)) {
			const quoted = new RegExp(`["']${escape(section)}["'][^\\n]*["']${escape(key)}["']`);
			const reader = sources.find((s) => quoted.test(s.text));
			if (reader) {
				runtime++;
				continue;
			}
			const chain = new RegExp(`\\bregistry\\.${escape(section)}\\.${escape(key)}\\b`);
			const isPinned =
				pins.some((p) => p.section === section && p.key === key) ||
				pinGateTexts.some((text) => chain.test(text));
			if (isPinned) {
				pinned++;
				continue;
			}
			errors.push(
				`[${section}].${key} has no reader. Nothing reads it at runtime and no gate pins a ` +
					'driver copy to it, so tuning it changes nothing. Fix: delete it if its consumer ' +
					`is gone; read it (Timings.ms("${section}", "${key}") / TimingsGet("${section}", ` +
					`"${key}")); or pin the driver literal in test-keystats-timings-single-source.cjs.`
			);
		}
	}
	for (const source of sources) {
		for (const m of source.text.matchAll(READER_CALL)) {
			const [, section, key] = m;
			if (registry[section] && Object.hasOwn(registry[section], key)) continue;
			const line = source.text.slice(0, m.index).split('\n').length;
			errors.push(
				`${source.rel}:${line}: reads [${section}].${key}, which ${REGISTRY_REL} does not ` +
					'have. The fail-fast reader throws on that line at runtime, on the one driver ' +
					'that executes it.'
			);
		}
	}
	return { errors, runtime, pinned };
}

const LIMIT_BASELINE = path.join(__dirname, 'limit-literal-baseline.json');
const LIMIT_BASELINE_COMMENT =
	'Lua and JavaScript *_BYTES constants that retype a [limits] value (tools/test/test-timings-registry-liveness.cjs). Shrink it with --update-limit-baseline; never add to it.';
const BYTES_LITERAL =
	/\b([A-Za-z_][A-Za-z0-9_]*(?:BYTES|bytes)[A-Za-z0-9_]*)\s*=\s*(\d+(?:\s*\*\s*\d+)*)(?![\w.*+\-/])/g;

/**
 * Evaluates a product of integer literals.
 * @param {string} text Such as "4 * 1024 * 1024".
 * @returns {number} The product.
 */
function product(text) {
	return text.split('*').reduce((a, b) => a * Number(b.trim()), 1);
}

/**
 * The [limits] section and the literal copies of its values.
 * @param {Object} registry Parsed registry.
 * @param {{rel: string, text: string}[]} sources Production sources.
 * @param {Set<string>} pinnedFiles Files that hold a pinned canon copy, exempt from the scan.
 * @returns {{errors: string[], copies: string[]}} Shape errors and "file:NAME" copies.
 */
function limitsAnalysis(registry, sources, pinnedFiles = new Set()) {
	const errors = [];
	const limits = registry.limits;
	if (limits === null || typeof limits !== 'object') {
		return { errors: [`${REGISTRY_REL} has no [limits] section`], copies: [] };
	}
	const values = new Set();
	for (const [key, value] of Object.entries(limits)) {
		if (!key.endsWith('_bytes') || !Number.isInteger(value) || value < 1)
			errors.push(`[limits].${key} must be a positive integer number of bytes named *_bytes`);
		else values.add(value);
	}
	const copies = new Set();
	for (const source of sources) {
		if (!/\.(?:lua|js)$/.test(source.rel) || pinnedFiles.has(source.rel)) continue;
		for (const raw of source.text.split('\n')) {
			const line = raw.trim();
			if (line.startsWith('--') || line.startsWith('//') || line.startsWith('*')) continue;
			for (const m of line.matchAll(BYTES_LITERAL))
				if (values.has(product(m[2]))) copies.add(`${source.rel}:${m[1]}`);
		}
	}
	return { errors, copies: [...copies].sort() };
}

/**
 * Compares the copies with the baseline.
 * @param {string[]} copies Current "file:NAME" copies.
 * @param {string[]} baseline Frozen copies.
 * @returns {{grown: string[], stale: string[]}} Copies not frozen, frozen ones gone.
 */
function limitBaselineVerdict(copies, baseline) {
	return {
		grown: copies.filter((c) => !baseline.includes(c)),
		stale: baseline.filter((c) => !copies.includes(c))
	};
}

/** Proves the analysis rejects what it exists to reject. */
function selfTest() {
	const failures = [];
	const registry = { ui: { live_ms: 1, pinned_ms: 2, ghost_ms: 3 } };
	const reader = { rel: 'macos/a.lua', text: 'local X = Timings.sec("ui", "live_ms")\n' };
	const pins = [{ section: 'ui', key: 'pinned_ms' }];
	const expectErrors = (name, result, count) => {
		if (result.errors.length !== count)
			failures.push(`${name}: expected ${count} error(s), got ${result.errors.length}`);
	};
	expectErrors('unread key', analyse(registry, [reader], pins, []), 1);
	expectErrors(
		'all keys read or pinned',
		analyse({ ui: { live_ms: 1, pinned_ms: 2 } }, [reader], pins, []),
		0
	);
	expectErrors(
		'a key read under another section is not read',
		analyse(
			{ ui: { live_ms: 1 } },
			[{ rel: 'x.lua', text: 'Timings.sec("llm", "live_ms")' }],
			[],
			[]
		),
		2
	);
	expectErrors(
		'a gate comparison pins a key',
		analyse({ logger: { cap_ms: 1 } }, [], [], ['assert(x === registry.logger.cap_ms)']),
		0
	);
	expectErrors(
		'a reader of a missing key',
		analyse(
			{ ui: { live_ms: 1 } },
			[reader, { rel: 'w.ahk', text: 'X := TimingsGet("ui", "typo_ms")' }],
			[],
			[]
		),
		1
	);
	const limitsRegistry = { limits: { cap_bytes: 65536 } };
	const retyped = { rel: 'linux/a.lua', text: 'local MAX_OUTPUT_BYTES = 65536\n' };
	const other = { rel: 'linux/b.lua', text: 'local MAX_OTHER_BYTES = 777\nlocal X = 65536 * 2\n' };
	const found = limitsAnalysis(limitsRegistry, [retyped, other]);
	if (found.copies.join() !== 'linux/a.lua:MAX_OUTPUT_BYTES')
		failures.push(`a retyped limit was not found exactly: ${found.copies.join()}`);
	if (limitsAnalysis({ limits: { cap: 1 } }, []).errors.length !== 1)
		failures.push('a [limits] key not named *_bytes was accepted');
	if (limitsAnalysis({}, []).errors.length !== 1) failures.push('a missing [limits] was accepted');
	if (limitBaselineVerdict(['a:X'], []).grown.length !== 1)
		failures.push('a new copy was not reported');
	if (limitBaselineVerdict([], ['a:X']).stale.length !== 1)
		failures.push('a vanished copy was not reported');
	return failures;
}

function main() {
	const registry = toml.parse(fs.readFileSync(path.join(SP, REGISTRY_REL), 'utf8'));
	const sources = productionSources();
	const errors = [];
	if (sources.length < MIN_SOURCE_FILES)
		errors.push(
			`walked only ${sources.length} production source file(s) under static/ergopti_plus — ` +
				'the walk is broken, and an empty reader set proves nothing'
		);
	const pinGateTexts = PIN_GATES.map((rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8'));
	const result = analyse(registry, sources, [...PINS, ...SOURCE_PINS], pinGateTexts);
	errors.push(...result.errors);
	errors.push(...selfTest().map((f) => `self-test: ${f}`));

	const limits = limitsAnalysis(registry, sources, new Set(SOURCE_PINS.map((p) => p.file)));
	errors.push(...limits.errors);
	if (process.argv.includes('--update-limit-baseline')) {
		const frozen = JSON.parse(fs.readFileSync(LIMIT_BASELINE, 'utf8')).copies;
		if (limitBaselineVerdict(limits.copies, frozen).grown.length > 0) {
			console.error('refusing to update: a byte cap retypes a [limits] value. Read the key.');
			process.exit(1);
		}
		fs.writeFileSync(
			LIMIT_BASELINE,
			JSON.stringify({ _comment: LIMIT_BASELINE_COMMENT, copies: limits.copies }, null, '\t') + '\n'
		);
		console.log('limit-literal baseline rewritten');
		process.exit(0);
	}
	const verdict = limitBaselineVerdict(
		limits.copies,
		JSON.parse(fs.readFileSync(LIMIT_BASELINE, 'utf8')).copies
	);
	for (const c of verdict.grown)
		errors.push(
			`${c} retypes the number of a [limits] key. Fix: read it (Timings.count("limits", "<key>")) ` +
				'or, for a process output cap, llm.process_limits.'
		);
	for (const c of verdict.stale)
		errors.push(
			`${c} is in limit-literal-baseline.json but no longer retypes a [limits] value. Run ` +
				'node tools/test/test-timings-registry-liveness.cjs --update-limit-baseline.'
		);

	if (errors.length > 0) {
		console.error('\x1b[31m[ERROR] The shared timing registry has dead or dangling keys:\x1b[0m');
		for (const e of errors) console.error('    ' + e);
		process.exit(1);
	}
	console.log(
		`\x1b[32m[OK] Timing registry liveness — ${result.runtime} key(s) read at runtime, ` +
			`${result.pinned} pinned to a driver copy, ${sources.length} source file(s) scanned.\x1b[0m`
	);
}

if (require.main === module) main();

module.exports = { analyse, productionSources, limitsAnalysis };
