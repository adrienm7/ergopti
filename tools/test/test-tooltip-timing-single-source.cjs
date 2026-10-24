// tools/test/test-tooltip-timing-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Tooltip Timing Single Source
 * DESCRIPTION:
 * The tooltip duration decrement and floor are declared once, in
 * _shared/modules/tooltip/constants.toml [timing], and reach every engine from
 * there.
 *
 * ROOT CAUSE ENCODED:
 * The values had four homes. dequeue.js kept 0.2 and 0.05 as defaults,
 * dequeue.lua kept 0 and 0 as defaults, and timings/constants.toml repeated
 * the decrement and the floor (and the two display durations, the LLM one
 * already 12 s against 20 s) under a comment calling them a mirror, with no
 * reader. Changing the TOML would have left the JS reference, and with it the
 * shared corpus both drivers replay, on the old value, and a caller that
 * forgot the options would have computed a duration from a copy nobody owns.
 *
 * WHAT IS CHECKED:
 *   1. tooltip/constants.toml declares both values; no other shared TOML does,
 *      and the retired timings/constants.toml copies stay gone.
 *   2. Neither dequeue engine declares a default, and both refuse a call that
 *      omits the values (the JS one is executed here, the Lua one in
 *      macos/tests/unit/ui/tooltip/test_tooltip_dequeue_contract.lua).
 *   3. The cross-driver vectors, replayed through dequeue.js with the TOML
 *      values, produce the expiries they promise, so the corpus is tied to the
 *      declaration rather than to a number typed beside it.
 *   4. Windows and macOS read both keys from the TOML, the Windows globals
 *      start at the 0 sentinel, macOS hands the loaded values to its dequeue
 *      engine, and the Windows contract test's mirror of the formula uses the
 *      declared numbers.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { parse } = require('smol-toml');
const { loadCjsModule } = require('../lib/load-cjs-module.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const read = (relative) => fs.readFileSync(path.join(SP, relative), 'utf8');

const KEYS = ['timeout_decrement_sec', 'timeout_floor_sec'];
const RETIRED_TIMINGS_COPIES = [
	'ttl_decrement_ms',
	'min_visible_ms',
	'display_ttl_ms',
	'llm_display_ttl_ms'
];

// 1. One declaration.
const timing = parse(read('_shared/modules/tooltip/constants.toml')).timing;
for (const key of KEYS) {
	assert.equal(typeof timing?.[key], 'number', `tooltip/constants.toml [timing] declares ${key}`);
	assert.ok(timing[key] > 0, `[timing] ${key} is positive`);
}
const DEC = timing.timeout_decrement_sec;
const FLOOR = timing.timeout_floor_sec;

/**
 * Lists the TOML files under a directory.
 * @param {string} directory Absolute directory.
 * @param {string[]} out Accumulator.
 * @returns {string[]} Absolute paths.
 */
function tomlFiles(directory, out = []) {
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const full = path.join(directory, entry.name);
		if (entry.isDirectory()) tomlFiles(full, out);
		else if (entry.name.endsWith('.toml')) out.push(full);
	}
	return out;
}
for (const file of tomlFiles(path.join(SP, '_shared', 'modules'))) {
	const relative = path.relative(SP, file).replaceAll('\\', '/');
	if (relative === '_shared/modules/tooltip/constants.toml') continue;
	const source = fs.readFileSync(file, 'utf8');
	for (const key of [...KEYS, ...RETIRED_TIMINGS_COPIES]) {
		assert.ok(
			!new RegExp(`^\\s*${key}\\s*=`, 'm').test(source),
			`${relative} declares ${key}; tooltip/constants.toml [timing] is its only home`
		);
	}
}

// 2. No engine default.
const DEFAULT_ASSIGNMENT = /\b\w*TIMEOUT_(?:DECREMENT|FLOOR)_SEC\s*=\s*[\d.]+/;
for (const relative of ['_shared/modules/tooltip/dequeue.js', 'macos/ui/tooltip/dequeue.lua']) {
	const source = read(relative);
	const match = DEFAULT_ASSIGNMENT.exec(source);
	assert.equal(
		match,
		null,
		`${relative} declares a default (${match?.[0]}); it must take the TOML value`
	);
	assert.ok(!/\bor\s+DEFAULT_|\?\?\s*DEFAULT_/.test(source), `${relative} falls back to a default`);
}
const dequeue = loadCjsModule(path.join(SP, '_shared/modules/tooltip/dequeue.js'));
assert.deepEqual(
	Object.keys(dequeue).filter((name) => /TIMEOUT/.test(name)),
	[],
	'dequeue.js exports no timing default'
);
const OPTS = { timeoutDecrementSec: DEC, timeoutFloorSec: FLOOR };
for (const [label, opts] of [
	['no options', undefined],
	['no decrement', { timeoutFloorSec: FLOOR }],
	['no floor', { timeoutDecrementSec: DEC }]
]) {
	assert.throws(
		() => dequeue.effectiveDurationSec(1, opts),
		TypeError,
		`effectiveDurationSec refuses ${label}`
	);
	assert.throws(
		() => dequeue.stampExpiryTimes([{ id: 'a', durationSec: 1 }], 0, opts),
		TypeError,
		`stampExpiryTimes refuses ${label}`
	);
}
assert.equal(dequeue.effectiveDurationSec(1, OPTS), Math.max(FLOOR, 1 - DEC));
assert.equal(dequeue.effectiveDurationSec(FLOOR / 2, OPTS), FLOOR, 'the floor holds');

// 3. The vectors replayed with the declared values.
let replayed = 0;
for (const vector of dequeue.dequeueTestVectors()) {
	assert.equal(
		dequeue.shouldUseDequeuePath(vector.rows, OPTS),
		vector.expectDequeue,
		`${vector.id}: dequeue path`
	);
	let rows = null;
	for (const step of vector.steps ?? []) {
		if (step.action === 'stamp') {
			rows = dequeue.stampExpiryTimes(vector.rows, step.atMs, OPTS).rows;
			for (const [id, expireMs] of Object.entries(step.expectExpiries ?? {})) {
				assert.equal(
					rows.find((row) => row.id === id).expireMs,
					expireMs,
					`${vector.id}: ${id} expires at ${expireMs} ms with the [timing] values`
				);
			}
		} else {
			assert.equal(step.action, 'prune', `${vector.id}: known step`);
			rows = dequeue.pruneExpired(rows, step.atMs, OPTS);
			if (step.expectNextDelayMs !== undefined)
				assert.equal(
					dequeue.nextExpiryDelayMs(rows, step.atMs, OPTS),
					step.expectNextDelayMs,
					`${vector.id}: next delay at ${step.atMs} ms`
				);
		}
		assert.deepEqual(
			rows.map((row) => row.id),
			step.expectIds,
			`${vector.id}: rows after ${step.action} at ${step.atMs} ms`
		);
		replayed++;
	}
}
assert.ok(replayed > 0, 'at least one vector has steps to replay');

// 4. The drivers read the declaration.
const uiStyle = read('windows/infra/ui_style.ahk');
const tooltipConfig = read('macos/ui/tooltip/config.lua');
for (const key of KEYS) {
	assert.ok(
		uiStyle.includes(`_UiStyleRequire(c, "timing", "${key}")`),
		`Windows ui_style.ahk reads [timing] ${key}`
	);
	assert.ok(
		tooltipConfig.includes(`require_key("timing", "${key}")`),
		`macOS ui/tooltip/config.lua reads [timing] ${key}`
	);
	assert.match(
		read('macos/ui/tooltip/tooltip_hotstring.lua'),
		new RegExp(`\\b${key}\\s*=\\s*Config\\.timing\\.${key}\\b`),
		`macOS tooltip_hotstring.lua hands Config.timing.${key} to its dequeue engine`
	);
}
for (const relative of ['windows/infra/ui_style.ahk', 'windows/ui/tooltip/core.ahk']) {
	for (const match of read(relative).matchAll(
		/\b(?:UI|_TOOLTIP)_TIMEOUT_(?:DECREMENT|FLOOR)_SEC\s*:=\s*([\d.]+)/g
	)) {
		assert.equal(Number(match[1]), 0, `${relative}: ${match[0]} starts at the 0 sentinel`);
	}
}
const contract = read('windows/tests/unit/ui/tooltip/test_tooltip_dequeue_contract.ahk');
const mirror = /Max\(([\d.]+),\s*CallerDurationSec\s*-\s*([\d.]+)\)/.exec(contract);
assert.ok(mirror, 'the Windows dequeue contract test keeps its effective-duration mirror');
assert.deepEqual(
	[Number(mirror[1]), Number(mirror[2])],
	[FLOOR, DEC],
	'the Windows contract test mirrors the declared floor and decrement'
);

console.log(
	`tooltip timing single source: ok (decrement ${DEC} s, floor ${FLOOR} s, ${replayed} vector step(s) replayed)`
);
