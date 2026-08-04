// tools/test/test-kanata-defalias-parity.cjs

/**
 * ==============================================================================
 * MODULE: Kanata Defalias Parity Gate (LNX-4 / DD-4)
 * DESCRIPTION:
 * Verifies that the kanata.kbd tap-hold-press/one-shot timeouts match the
 * shared defaults.toml, and that the golden corpus matches what the generator
 * produces. This prevents timeout drift between the hand-written kanata.kbd
 * and the single source of truth (_shared/tap_hold/defaults.toml +
 * _shared/modules/timings/constants.toml).
 *
 * Two checks:
 *   1. kanata.kbd defalias block: every tap-hold-press timeout ms ==
 *      round(defaults.toml time_activation_seconds * 1000), and the one-shot
 *      ms == timings constants.
 *   2. Golden corpus: _shared/tap_hold/golden_kanata_defalias.kbd matches
 *      the committed kanata.kbd (or the generator output, whichever is
 *      declared as the source of truth).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '../../static/ergopti_plus');

const PASS = '\u2713';
const FAIL = '\u2717';
let pass = 0;
let fail = 0;

// ─── Load defaults.toml key configs ─────────────────────────────────────

const TOML_PATH = path.join(ROOT, '_shared/tap_hold/defaults.toml');
const TIMINGS_PATH = path.join(ROOT, '_shared/modules/timings/constants.toml');
const KANATA_PATH = path.join(ROOT, 'linux/platform/remap/data/kanata.kbd');
const GOLDEN_PATH = path.join(ROOT, '_shared/tap_hold/golden_kanata_defalias.kbd');

// Minimal TOML section parser — extracts [tap_hold.keys.<name>] blocks
function parseTapHoldKeys(tomlSrc) {
	const keys = {};
	// Match [tap_hold.keys.<key_id>] followed by key=value lines
	const keyBlockRe = /^\[tap_hold\.keys\.([a-z_]+)\]\r?\n([^[]*)/gm;
	let m;
	while ((m = keyBlockRe.exec(tomlSrc)) !== null) {
		const keyId = m[1];
		const block = m[2];
		const key = {};
		const tapAction = block.match(/^tap_action\s*=\s*"([^"]+)"/m);
		const holdMod = block.match(/^hold_modifier\s*=\s*"([^"]+)"/m);
		const holdLayer = block.match(/^hold_layer\s*=\s*"([^"]+)"/m);
		const timeSecs = block.match(/^time_activation_seconds\s*=\s*([\d.]+)/m);
		if (tapAction) key.tap_action = tapAction[1];
		if (holdMod) key.hold_modifier = holdMod[1];
		if (holdLayer) key.hold_layer = holdLayer[1];
		if (timeSecs) key.time_activation_seconds = parseFloat(timeSecs[1]);
		keys[keyId] = key;
	}
	return keys;
}

// Extract one_shot_shift_timeout_ms from timings/constants.toml
function parseOneShotMs(timingsSrc) {
	const m = timingsSrc.match(/^one_shot_shift_timeout_ms\s*=\s*(\d+)/m);
	return m ? parseInt(m[1], 10) : null;
}

// Parse tap-hold-press and one-shot lines from kanata.kbd defalias block.
// NOTE: multiline entries (e.g. ralt) are partially parsed — only tap_ms/hold_ms
// are captured; the hold expression on the next line is lost. This is acceptable
// because the test only asserts timeout values, not expression fidelity.
// Expression parity is an OS-specific concern that the kanata_generator
// explicitly does not handle (per its ralt docstring).
function parseKanataDefalias(kbdSrc) {
	const result = {};
	// Match: <alias> (tap-hold-press <tap_ms> <hold_ms> <tap_expr> <hold_expr>)
	const thRe = /^\s*(\w+)\s+\(tap-hold-press\s+(\d+)\s+(\d+)\s+(.+)\)\s*$/gm;
	let m;
	while ((m = thRe.exec(kbdSrc)) !== null) {
		result[m[1]] = {
			type: 'tap-hold-press',
			tap_ms: parseInt(m[2], 10),
			hold_ms: parseInt(m[3], 10),
			tap_expr: m[4].trim(),
		};
	}
	// Match: <alias> (one-shot <ms> <modifier>)
	const osRe = /^\s*(\w+)\s+\(one-shot\s+(\d+)\s+(\w+)\)\s*$/gm;
	while ((m = osRe.exec(kbdSrc)) !== null) {
		result[m[1]] = {
			type: 'one-shot',
			ms: parseInt(m[2], 10),
			modifier: m[3],
		};
	}
	return result;
}

function round(n) {
	return Math.floor(n + 0.5);
}

// ─── Key alias mapping: defaults.toml key_id → kanata alias name ────────

const KEY_ALIAS = {
	caps_lock: 'cap',
	left_shift: 'lsft',
	left_ctrl: 'lctl',
	left_alt: 'lalt',
	alt_gr: 'ralt',
	tab: 'alttab',
	right_ctrl: 'ossft',
};

// ─── Load all inputs ──────────────────────────────────────────────────────

const defaultsTxt = fs.readFileSync(TOML_PATH, 'utf8');
const timingsTxt = fs.readFileSync(TIMINGS_PATH, 'utf8');
const kanataTxt = fs.readFileSync(KANATA_PATH, 'utf8');
const goldenTxt = fs.readFileSync(GOLDEN_PATH, 'utf8');

const keys = parseTapHoldKeys(defaultsTxt);
const oneShotMs = parseOneShotMs(timingsTxt);
const kanataDefalias = parseKanataDefalias(kanataTxt);

// ================================================
// ======= 1/ Timeout parity: kanata.kbd vs defaults.toml
// ================================================

console.log('\nKanata defalias parity (kanata.kbd <-> defaults.toml)');
console.log('='.repeat(60));

for (const [keyId, alias] of Object.entries(KEY_ALIAS)) {
	const kc = keys[keyId];
	if (!kc) continue;

	const entry = kanataDefalias[alias];
	if (!entry) {
		console.log(`  ${FAIL}  ${alias} (${keyId}): missing in kanata.kbd`);
		fail++;
		continue;
	}

	if (entry.type === 'one-shot') {
		// One-shot shift timeout
		const want = oneShotMs;
		const got = entry.ms;
		if (got === want) {
			console.log(`  ${PASS}  ${alias}: one-shot ${got}ms (defaults=${want}ms)`);
			pass++;
		} else {
			console.log(`  ${FAIL}  ${alias}: one-shot ${got}ms !== ${want}ms (timings/constants.toml)`);
			fail++;
		}
	} else {
		// tap-hold-press timeout
		const wantMs = round((kc.time_activation_seconds || 0.20) * 1000);
		const gotMs = entry.tap_ms;
		if (gotMs === wantMs && entry.hold_ms === wantMs) {
			console.log(`  ${PASS}  ${alias}: tap-hold-press ${gotMs}/${gotMs}ms (defaults=${wantMs}ms)`);
			pass++;
		} else {
			console.log(`  ${FAIL}  ${alias}: tap-hold-press ${gotMs}/${entry.hold_ms}ms !== ${wantMs}ms (defaults.toml)`);
			fail++;
		}
	}
}

// ================================================
// ======= 2/ Golden corpus parity
// ================================================

console.log('');
console.log('Golden corpus parity (golden_kanata_defalias.kbd <-> kanata.kbd defalias)');
console.log('='.repeat(60));

const goldenDefalias = parseKanataDefalias(goldenTxt);

for (const alias of Object.keys(kanataDefalias)) {
	const k = kanataDefalias[alias];
	const g = goldenDefalias[alias];

	if (!g) {
		console.log(`  ${FAIL}  ${alias}: in kanata.kbd but missing from golden corpus`);
		fail++;
	} else if (k.type === g.type && k.tap_ms === g.tap_ms && k.hold_ms === g.hold_ms) {
		console.log(`  ${PASS}  ${alias}: ${k.type} matches golden corpus`);
		pass++;
	} else {
		console.log(`  ${FAIL}  ${alias}: kanata=${JSON.stringify(k)} !== golden=${JSON.stringify(g)}`);
		fail++;
	}
}

// Check for extra entries in golden that aren't in kanata.kbd
for (const alias of Object.keys(goldenDefalias)) {
	if (!kanataDefalias[alias]) {
		console.log(`  ${FAIL}  ${alias}: in golden corpus but missing from kanata.kbd`);
		fail++;
	}
}

// ================================================
// ======= 3/ Alias resolution: nothing may dangle
// ================================================
//
// kanata resolves every @name at load time, so ONE dangling reference makes the
// WHOLE configuration unloadable — not just the key that references it. That is
// what shipped: the generator emits 7 aliases, the block it replaces defined 12,
// and the generated `lsft`/`lctl` directives themselves reference @copy/@paste
// while the layers reference @rollx/@deadtrema. Sections 1 and 2 above compared
// only timeout numbers, so none of them could see it.

/** Strips `;;` comments. A LONE `;` is a legitimate alias name in this layout. */
function stripKanataComments(src) {
	return src.replace(/;;[^\n]*/g, '');
}

/** Skips whitespace from `i`, returning the next significant index. */
function skipSpace(src, i) {
	while (i < src.length && /\s/.test(src[i])) i++;
	return i;
}

/** Returns the index just past the parenthesised group starting at `i`. */
function skipGroup(src, i) {
	let depth = 0;
	for (; i < src.length; i++) {
		if (src[i] === '(') depth++;
		else if (src[i] === ')') {
			depth--;
			if (depth === 0) return i + 1;
		}
	}
	return src.length;
}

/** Reads one atom (a run of characters that is neither space nor parenthesis). */
function readAtom(src, i) {
	const start = i;
	while (i < src.length && !/[\s()]/.test(src[i])) i++;
	return [src.slice(start, i), i];
}

/**
 * Collects the alias names defined by every `(defalias …)` block, in file order.
 * Entries alternate NAME then VALUE, where a VALUE is either an atom or a
 * parenthesised group.
 */
function definedAliases(src) {
	const clean = stripKanataComments(src);
	const names = [];
	const blockRe = /\(defalias\b/g;
	let m;
	while ((m = blockRe.exec(clean)) !== null) {
		const blockEnd = skipGroup(clean, m.index);
		let i = m.index + '(defalias'.length;
		while (i < blockEnd - 1) {
			i = skipSpace(clean, i);
			if (i >= blockEnd - 1) break;
			// A name is always an atom; a stray '(' here means malformed input.
			if (clean[i] === '(') { i = skipGroup(clean, i); continue; }
			const [name, afterName] = readAtom(clean, i);
			i = skipSpace(clean, afterName);
			i = clean[i] === '(' ? skipGroup(clean, i) : readAtom(clean, i)[1];
			if (name) names.push(name);
		}
		blockRe.lastIndex = blockEnd;
	}
	return names;
}

/** Collects every `@name` reference in the source. */
function referencedAliases(src) {
	const clean = stripKanataComments(src);
	const refs = new Set();
	const re = /@([^\s()]+)/g;
	let m;
	while ((m = re.exec(clean)) !== null) refs.add(m[1]);
	return refs;
}

/** Reports every reference with no definition. */
function danglingAliases(src) {
	const defined = new Set(definedAliases(src));
	return [...referencedAliases(src)].filter((r) => !defined.has(r)).sort();
}

/**
 * Reproduces platform/remap/manager.lua's merge: the LAST `(defalias)` block of
 * the template is replaced wholesale by the generated one. The golden corpus is
 * pinned byte-for-byte to the generator's output by the Lua suite
 * (linux/tests/unit/meta/test_kanata_generator.lua), so substituting it here
 * exercises the artifact the daemon actually writes to disk.
 */
function mergedConfig(templateSrc, generatedBlock) {
	let lastStart = -1;
	const re = /\n\(defalias\b/g;
	let m;
	while ((m = re.exec(templateSrc)) !== null) lastStart = m.index + 1;
	if (lastStart === -1) return null;
	const end = skipGroup(templateSrc, lastStart);
	return templateSrc.slice(0, lastStart) + generatedBlock.trim() + templateSrc.slice(end);
}

console.log('');
console.log('Alias resolution (every @reference must be defined)');
console.log('='.repeat(60));

const committedDangling = danglingAliases(kanataTxt);
if (committedDangling.length === 0) {
	console.log(`  ${PASS}  kanata.kbd: every @alias resolves (${definedAliases(kanataTxt).length} defined)`);
	pass++;
} else {
	console.log(`  ${FAIL}  kanata.kbd: dangling @alias — ${committedDangling.map((a) => '@' + a).join(', ')}`);
	fail++;
}

const merged = mergedConfig(kanataTxt, goldenTxt);
if (merged === null) {
	console.log(`  ${FAIL}  kanata.kbd has no (defalias) block for the generator to replace`);
	fail++;
} else {
	const mergedDangling = danglingAliases(merged);
	if (mergedDangling.length === 0) {
		console.log(`  ${PASS}  generated config: every @alias resolves after the defalias block is replaced`);
		pass++;
	} else {
		console.log(
			`  ${FAIL}  generated config is UNLOADABLE — dangling @alias after replacement: ` +
				mergedDangling.map((a) => '@' + a).join(', ')
		);
		console.log(
			'        The generator replaces the LAST (defalias) block wholesale. Anything it ' +
				'does not emit must live in an EARLIER block, or it disappears from the config kanata loads.'
		);
		fail++;
	}
}

// The composites the generator cannot produce must survive the replacement.
// Naming them explicitly means moving one back into the generated block fails
// here with a message that says why, rather than as an opaque parse error.
const SURVIVES_REPLACEMENT = ['rollc', 'rollx', 'deadtrema', 'copy', 'paste'];
if (merged !== null) {
	const mergedDefined = new Set(definedAliases(merged));
	const lost = SURVIVES_REPLACEMENT.filter((a) => !mergedDefined.has(a));
	if (lost.length === 0) {
		console.log(`  ${PASS}  hand-maintained composites survive the replacement (${SURVIVES_REPLACEMENT.join(', ')})`);
		pass++;
	} else {
		console.log(`  ${FAIL}  composites lost to the replacement: ${lost.join(', ')} — move them to an earlier (defalias) block`);
		fail++;
	}
}

// ─── Device coordination (defcfg) ───────────────────────────────────────
//
// kanata grabs every keyboard-like device it can find, and two of the devices on
// a machine running this driver are software keyboards it must never grab: our
// own uinput device (kanata would re-map text we already mapped) and any
// third-party injector a user runs alongside. The exclusion is an EXACT name
// match on kanata's side, so a name that drifts by one character does not fail —
// it silently stops excluding, and the corruption only reproduces on hardware.
//
// That is why this is a gate and not a comment: the names live once, in
// linux/infra/device_names.lua, and the config below has to agree with them.

const DEVICE_NAMES_PATH = path.join(ROOT, 'linux/infra/device_names.lua');

/**
 * Reads a `M.NAME = "value"` string constant out of the device-names module.
 * @param {string} src - Module source.
 * @param {string} field - Constant name without the `M.` prefix.
 * @returns {string|null} The value, or null when the constant is absent.
 */
function luaStringConst(src, field) {
	const m = src.match(new RegExp(`^M\\.${field}\\s*=\\s*"([^"]*)"`, 'm'));
	return m ? m[1] : null;
}

/**
 * Reads the ordered `M.REMAP_EXCLUDE` list, resolving its `M.FOO` references.
 * @param {string} src - Module source.
 * @returns {string[]} The device names, in declaration order.
 */
function remapExcludeList(src) {
	const block = src.match(/^M\.REMAP_EXCLUDE\s*=\s*\{([\s\S]*?)\}/m);
	if (!block) return [];
	return [...block[1].matchAll(/M\.([A-Z_]+)/g)]
		.map((r) => luaStringConst(src, r[1]))
		.filter((v) => v !== null);
}

/**
 * Extracts the `(defcfg …)` block from a kanata config.
 * @param {string} src - Config source.
 * @returns {string|null} The block including its parentheses, or null.
 */
function defcfgBlock(src) {
	const clean = stripKanataComments(src);
	const start = clean.indexOf('(defcfg');
	if (start === -1) return null;
	return clean.slice(start, skipGroup(clean, start));
}

/**
 * Reads the quoted names of `linux-dev-names-exclude` from a defcfg block.
 * @param {string} block - The defcfg block.
 * @returns {string[]} Names in file order, empty when the key is absent.
 */
function excludedDeviceNames(block) {
	const at = block.indexOf('linux-dev-names-exclude');
	if (at === -1) return [];
	const open = block.indexOf('(', at);
	if (open === -1) return [];
	const list = block.slice(open, skipGroup(block, open));
	return [...list.matchAll(/"([^"]*)"/g)].map((m) => m[1]);
}

console.log('');
console.log('Device coordination (the two daemons must not grab each other)');
console.log('='.repeat(60));

const deviceNamesSrc = fs.readFileSync(DEVICE_NAMES_PATH, 'utf8');
const declaredExclusions = remapExcludeList(deviceNamesSrc);
const cfg = defcfgBlock(kanataTxt);

if (declaredExclusions.length < 2) {
	console.log(
		`  ${FAIL}  device_names.lua declares ${declaredExclusions.length} exclusion(s) — ` +
			'expected at least our own uinput device and the third-party injector'
	);
	fail++;
} else {
	console.log(`  ${PASS}  device_names.lua is the single source (${declaredExclusions.join(', ')})`);
	pass++;
}

// The uinput writer stamps this exact string into struct uinput_setup. If it
// carried its own copy, the exclusion could go stale without a single test
// noticing — which is the whole failure mode this pair of checks exists for.
const WRITER_PATH = path.join(ROOT, 'linux/adapters/uinput_writer.lua');
const writerSrc = fs.readFileSync(WRITER_PATH, 'utf8');
if (/DEVICE_NAME\s*=\s*require\(["']infra\.device_names["']\)\.VIRTUAL_KEYBOARD/.test(writerSrc)) {
	console.log(`  ${PASS}  uinput_writer reads the name rather than redeclaring it`);
	pass++;
} else {
	console.log(
		`  ${FAIL}  uinput_writer must take DEVICE_NAME from infra.device_names.VIRTUAL_KEYBOARD — ` +
			'a second literal is how the device we create and the device kanata excludes drift apart'
	);
	fail++;
}

if (cfg === null) {
	console.log(`  ${FAIL}  kanata.kbd has no (defcfg) block`);
	fail++;
} else {
	const excluded = excludedDeviceNames(cfg);
	const missing = declaredExclusions.filter((n) => !excluded.includes(n));
	const extra = excluded.filter((n) => !declaredExclusions.includes(n));

	if (missing.length === 0 && extra.length === 0 && excluded.length > 0) {
		console.log(`  ${PASS}  linux-dev-names-exclude matches device_names.lua exactly`);
		pass++;
	} else {
		console.log(
			`  ${FAIL}  linux-dev-names-exclude drifted — missing: [${missing.join(', ')}], ` +
				`unexpected: [${extra.join(', ')}]`
		);
		console.log('        kanata matches these names byte for byte; a near-miss excludes nothing.');
		fail++;
	}

	const REQUIRED_KEYS = [
		[
			/linux-device-detect-mode\s+keyboard-only/,
			'linux-device-detect-mode keyboard-only',
			'kanata has no reason to own pointer or tablet event streams',
		],
		[
			/linux-continue-if-no-devs-found\s+yes/,
			'linux-continue-if-no-devs-found yes',
			'under a user unit the keyboard is routinely enumerated after the daemon starts',
		],
	];
	for (const [re, label, why] of REQUIRED_KEYS) {
		if (re.test(cfg)) {
			console.log(`  ${PASS}  ${label}`);
			pass++;
		} else {
			console.log(`  ${FAIL}  defcfg is missing \`${label}\` — ${why}`);
			fail++;
		}
	}
}

// The generator replaces the LAST (defalias) block wholesale. defcfg lives in the
// preserved prefix, but "lives in the prefix" is a property of where the split
// falls, and the split has moved before. Assert it on the merged artifact, which
// is what the daemon actually writes to disk.
if (merged !== null) {
	const mergedCfg = defcfgBlock(merged);
	const survived = mergedCfg !== null && excludedDeviceNames(mergedCfg).length === declaredExclusions.length;
	if (survived) {
		console.log(`  ${PASS}  the exclusions survive the defalias replacement`);
		pass++;
	} else {
		console.log(
			`  ${FAIL}  the generated config loses its defcfg exclusions — the daemon would ship a ` +
				'config in which kanata grabs our own virtual keyboard'
		);
		fail++;
	}
}

console.log('');
console.log(`Total: ${pass + fail} check(s) - ${pass} passed, ${fail} failed`);
console.log('');

process.exit(fail > 0 ? 1 : 0);
