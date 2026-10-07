// tools/test/test-layout-supersession-declared.cjs

/**
 * ==============================================================================
 * MODULE: Layout Features An Emulated Layout Supersedes
 * DESCRIPTION:
 * The Windows driver can emulate a registry layout instead of Ergopti
 * ([layout] emulated_layout). The Ergopti emulation's own features, with the
 * overlays they carry (typography, selection wrapping, the Ergopti+ changes),
 * stop applying then; the independent digit-row policy stays available. The manifest declares each of
 * them with `superseded_reason_key`, the reason the menu shows next to the
 * greyed row.
 *
 * WHY:
 * A declaration that no driver reads, a reason that does not translate, or a
 * reason key the generator drops on the way to the driver all look fine in
 * manifest.toml and show the user nothing (or a dotted key). So:
 *   1. at least the three Ergopti emulation features are declared: two Windows
 *      booleans and the exact closed internal helper-backed variant;
 *   2. every reason resolves in all 21 locales;
 *   3. the generated Windows manifest ships every declaration;
 *   4. the master gate and the menu read the declaration outside comments;
 *   5. the manifest schema declares every field a feature uses: its
 *      feature_entry refuses undeclared fields, so a field the schema lacks
 *      makes the manifest invalid against its own contract.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared', 'modules', 'features', 'manifest.toml');
const SCHEMA = path.join(SP, '_shared', 'modules', 'features', 'manifest.schema.json');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');
const GENERATED_AHK = path.join(SP, 'windows', '_generated', 'features_manifest.ahk');
const CONSUMERS = [
	{ file: path.join(SP, 'windows', 'infra', 'master_gates.ahk'), token: 'superseded_reason_key' },
	{
		file: path.join(SP, 'windows', 'ui', 'menu', 'menu_engine.ahk'),
		token: 'LayoutSupersededReason('
	}
];
const EXPECTED = ['ergopti_base', 'ergopti_alt_gr', 'ergopti_variant'];

let failures = 0;

function check(name, fn) {
	try {
		fn();
		console.log(`  ok   ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${err.message}`);
	}
}

/** Each [[features.*]] block of manifest.toml as { section, fields }. */
function featureBlocks(source) {
	const blocks = [];
	let current = null;
	for (const line of source.split('\n')) {
		const header = /^\[\[features\.([a-z0-9_.]+)\]\]\s*$/.exec(line);
		if (header) {
			current = { section: header[1], fields: {} };
			blocks.push(current);
			continue;
		}
		if (/^\[/.test(line)) {
			current = null;
			continue;
		}
		const field = /^([a-z_]+)\s*=\s*(.+?)\s*$/.exec(line);
		if (current && field) current.fields[field[1]] = field[2];
	}
	return blocks;
}

const blocks = featureBlocks(fs.readFileSync(SOURCE, 'utf8'));
const declared = blocks
	.filter((b) => b.fields.superseded_reason_key)
	.map((b) => ({
		id: JSON.parse(b.fields.id),
		section: b.section,
		reason: JSON.parse(b.fields.superseded_reason_key),
		platforms: b.fields.platforms,
		type: b.fields.type
	}));

console.log('Layout features an emulated layout supersedes');
check('number-row modes are independently source-scoped rather than boolean supersession', () => {
	const row = blocks.find(
		(b) => b.section === 'layout' && JSON.parse(b.fields.id) === 'direct_access_digits'
	);
	assert.ok(row, 'the genuine number-row feature must exist');
	assert.strictEqual(row.fields.type, '"enum"');
	assert.deepStrictEqual(JSON.parse(row.fields.enum_values), ['native', 'digits', 'symbols']);
	assert.deepStrictEqual(JSON.parse(row.fields.platforms), ['ahk', 'hs', 'linux']);
	assert.strictEqual(row.fields.default, '"native"');
	assert.strictEqual(
		row.fields.superseded_reason_key,
		undefined,
		'a source-scoped enum cannot be switched off as a boolean'
	);
	assert.ok(!declared.some((d) => d.section === 'layout' && d.id === 'direct_access_digits'));
});

check('the Ergopti emulation declares two Windows booleans and one closed internal variant', () => {
	assert.ok(declared.length >= EXPECTED.length, `only ${declared.length} declaration(s) found`);
	for (const id of EXPECTED) {
		assert.ok(
			declared.some((d) => d.section === 'layout' && d.id === id),
			`layout.${id} is not declared`
		);
	}
	for (const d of declared) {
		assert.strictEqual(
			d.platforms,
			'["ahk"]',
			`${d.section}.${d.id}: only the Windows driver emulates layouts`
		);
		if (d.section === 'layout' && d.id === 'ergopti_variant') {
			const row = blocks.find((b) => b.section === 'layout' && JSON.parse(b.fields.id) === d.id);
			assert.strictEqual(d.type, '"enum"');
			assert.deepStrictEqual(JSON.parse(row.fields.enum_values), [
				'none',
				'ergopti',
				'ergopti_plus'
			]);
			assert.strictEqual(row.fields.default, '"none"');
			assert.strictEqual(row.fields.recommended, '"ergopti_plus"');
			assert.strictEqual(
				row.fields.choice,
				undefined,
				'internal source intent cannot add a public chooser'
			);
		} else {
			assert.strictEqual(
				d.type,
				'"boolean"',
				`${d.section}.${d.id}: the gate can only turn a boolean off`
			);
		}
	}
});

check('every reason resolves in all 21 locales', () => {
	const files = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
	assert.strictEqual(files.length, 21, `found ${files.length} locale catalogue(s)`);
	for (const file of files) {
		const catalogue = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
		for (const d of declared) {
			const value = catalogue[d.reason];
			assert.ok(
				typeof value === 'string' && value.trim() !== '',
				`${file}: ${d.reason} is missing`
			);
		}
	}
});

check('the generated Windows manifest ships every declaration', () => {
	const generated = fs.readFileSync(GENERATED_AHK, 'utf8');
	for (const d of declared) {
		const entry = new RegExp(
			`Map\\("path", "${d.section}\\.${d.id}",[^\\n]*"superseded_reason_key", "${d.reason.replace(/\./g, '\\.')}"`
		);
		assert.ok(
			entry.test(generated),
			`${d.section}.${d.id} reaches features_manifest.ahk without its reason`
		);
	}
});

check('the master gate and the menu read the declaration', () => {
	for (const c of CONSUMERS) {
		const code = fs
			.readFileSync(c.file, 'utf8')
			.split('\n')
			.filter((l) => !/^\s*;/.test(l))
			.join('\n');
		assert.ok(
			code.includes(c.token),
			`${path.relative(ROOT, c.file)} does not use ${c.token} outside comments`
		);
	}
});

check('the manifest schema declares every field a feature uses', () => {
	const entry = JSON.parse(fs.readFileSync(SCHEMA, 'utf8')).$defs.feature_entry;
	assert.strictEqual(
		entry.additionalProperties,
		false,
		'feature_entry no longer refuses undeclared fields'
	);
	const used = new Set(blocks.flatMap((b) => Object.keys(b.fields)));
	assert.ok(
		used.size >= 5 && used.has('superseded_reason_key'),
		`only ${used.size} feature field(s) found`
	);
	for (const field of used) {
		assert.ok(
			Object.hasOwn(entry.properties, field),
			`manifest.schema.json does not declare the feature field ${field}`
		);
	}
});

if (failures > 0) process.exit(1);
console.log('All layout supersession checks passed.');
