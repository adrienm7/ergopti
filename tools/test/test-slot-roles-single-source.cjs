// tools/test/test-slot-roles-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Slot Roles Single Source
 * DESCRIPTION:
 * The neutral keyboard-slot grammar (PAR-41 step 2) names modifiers by role.
 * This gate holds the role table to the data the drivers already share, so a
 * role cannot resolve to a key a driver does not have.
 *
 * FEATURES & RATIONALE:
 * 1. Every native modifier a role names exists in modifier_chords.json for that
 *    driver, and every modifier the drivers' slot prefix families use maps to a
 *    role (nothing a driver binds today is unnameable).
 * 2. The roles of one driver map injectively, so two roles never share a key.
 * 3. The corpus crosswalk equals the inventory re-derived through the table,
 *    and its pending keys are exactly the keys the key catalogue still lacks.
 * 4. Key ids contain no underscore and are not role names, so a slot id parses
 *    unambiguously.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const json = (...parts) => JSON.parse(fs.readFileSync(path.join(...parts), 'utf8'));

const roles = json(SHARED, 'modules', 'actions', 'slot_roles.json');
const chords = json(SHARED, 'modules', 'actions', 'modifier_chords.json');
const inventory = json(ROOT, 'docs', 'audits', '2026-10-27-shortcut-inventory.json');
const corpus = json(SHARED, 'tests', 'corpus', 'shortcuts', 'neutral_slots.json');
const DRIVERS = ['windows', 'macos', 'linux'];

const nativeToRole = {};
for (const driver of DRIVERS) {
	nativeToRole[driver] = {};
	const known = new Set(chords.platforms[driver].modifiers.map((m) => m.id));
	for (const role of roles.modifier_order) {
		const native = roles.roles[role][driver];
		if (native === null) {
			assert.strictEqual(
				typeof roles.roles[role].absent_reason,
				'string',
				`${role}: no reason for ${driver}`
			);
			continue;
		}
		assert(
			known.has(native),
			`${role} names "${native}", which modifier_chords.json lacks for ${driver}`
		);
		assert.strictEqual(
			nativeToRole[driver][native],
			undefined,
			`${driver}: two roles share ${native}`
		);
		nativeToRole[driver][native] = role;
	}
}

for (const family of inventory.slot_families) {
	for (const modifier of family.modifiers) {
		assert(
			nativeToRole[family.driver][modifier],
			`${family.driver} slot prefix "${family.prefix}" uses ${modifier}, which no role names`
		);
	}
}

for (const driver of DRIVERS) {
	for (const family of roles.families[driver]) {
		const ranks = family.map((r) => roles.modifier_order.indexOf(r));
		assert(
			ranks.every((r, i) => r >= 0 && (i === 0 || r > ranks[i - 1])),
			`${driver} family ${family} is not ordered`
		);
		for (const role of family)
			assert.notStrictEqual(roles.roles[role][driver], null, `${driver} family uses ${role}`);
	}
}
assert.deepStrictEqual(
	Object.entries(corpus.families).map(([d, prefixes]) => [d, prefixes]),
	DRIVERS.map((d) => [d, roles.families[d].map((f) => f.join('_') + '_')]),
	'corpus families differ from slot_roles.json'
);

const keyIds = chords.keys.map((k) => k.id);
for (const driver of DRIVERS) {
	for (const key of roles.extra_keys[driver]) {
		assert(!keyIds.includes(key.id), `extra key "${key.id}" is already in modifier_chords.json`);
		assert(
			/^[a-z0-9]+$/.test(key.id) && !roles.modifier_order.includes(key.id),
			`extra key "${key.id}" is unparseable`
		);
	}
}
for (const id of keyIds) {
	assert(!id.includes('_'), `key "${id}" contains an underscore`);
	assert(!roles.modifier_order.includes(id), `key "${id}" is a role name`);
}

/** The neutral slot of one native chord. */
function slotOf(driver, modifiers, key) {
	const ordered = modifiers
		.map((m) => nativeToRole[driver][m])
		.sort((a, b) => roles.modifier_order.indexOf(a) - roles.modifier_order.indexOf(b));
	return [...ordered, key].join('_');
}

const derived = [];
const seen = new Set();
for (const row of inventory.rows) {
	if (!row.chord || row.chord.modifiers.length === 0) continue;
	const id = `${row.driver} ${[...row.chord.modifiers].sort()} ${row.chord.key}`;
	if (seen.has(id)) continue;
	seen.add(id);
	derived.push({
		driver: row.driver,
		modifiers: row.chord.modifiers,
		key: row.chord.key,
		slot: slotOf(row.driver, row.chord.modifiers, row.chord.key)
	});
}
assert.deepStrictEqual(
	corpus.crosswalk,
	derived,
	'the corpus crosswalk differs from the inventory'
);
assert.deepStrictEqual(
	corpus.pending_keys,
	[
		...new Set(
			derived
				.filter(
					(c) => !keyIds.includes(c.key) && !roles.extra_keys[c.driver].some((k) => k.id === c.key)
				)
				.map((c) => c.key)
		)
	].sort(),
	'pending_keys differ from the keys no driver table carries'
);

console.log(
	`[OK] slot roles resolve on ${DRIVERS.length} drivers, ${derived.length} chords cross-walked, ` +
		`${corpus.pending_keys.length} key(s) still to add to the catalogue.`
);
