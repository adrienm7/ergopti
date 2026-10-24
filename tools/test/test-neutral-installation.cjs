// tools/test/test-neutral-installation.cjs

/**
 * ==============================================================================
 * MODULE: Neutral Installation Guard
 * DESCRIPTION:
 * A fresh installation must not change how the keyboard types. The shipped
 * defaults enable no layout emulation, no system layout change and no number-row
 * inversion on any of the three drivers: the user opts in from the menu, the
 * wizard or the configuration file.
 *
 * WHAT THIS PINS, per driver:
 *   1. The manifest default of every layout switch the driver supports is its
 *      neutral value (false, "none", "" or the native number row). The list is
 *      explicit, so a switch added or renamed without a decision fails here
 *      instead of being skipped.
 *   2. The first-run state the driver actually boots from, its generated
 *      config_template.toml, carries exactly those values, and its
 *      [category_enabled] layout master (Windows) is off.
 *   3. Every input-altering entry of the layout section, whatever its name, is
 *      neutral in both places, so a new emulation switch cannot ship on.
 *   4. The Windows configuration example writes only those neutral [layout]
 *      values, so documentation cannot show an activated emulation.
 *   5. The row switches that narrow an emulation (emulate_*) stay parameters:
 *      on their own they alter no input, which is why they may default on.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const paths = require('../lib/paths.cjs');

/** Layout switches each platform supports, with the value a fresh install keeps. */
const NEUTRAL_LAYOUT = {
	ahk: {
		driver: 'windows',
		values: {
			ergopti_base: false,
			direct_access_digits: 'native',
			number_row_reorder_edges: false,
			ergopti_alt_gr: false,
			ergopti_variant: 'none',
			ctrl_magic_save: false,
			emulated_layout: ''
		}
	},
	hs: {
		driver: 'macos',
		values: {
			direct_access_digits: 'native',
			number_row_reorder_edges: false,
			pause_switch_enabled: false,
			// Layout ids; "" is « no change ».
			on_pause: '',
			on_resume: ''
		}
	},
	linux: {
		driver: 'linux',
		values: {
			direct_access_digits: 'native',
			number_row_reorder_edges: false,
			pause_switch_enabled: false,
			on_pause: '',
			on_resume: ''
		}
	}
};

/** Values that leave the typed output to the operating system. */
const NEUTRAL_VALUES = [false, 'none', '', 'native'];

/** Row switches that only narrow an emulation (see the manifest comment above them). */
const EMULATION_ROW_PARAMETERS = [
	'emulate_number_row',
	'emulate_top_row',
	'emulate_home_row',
	'emulate_bottom_row'
];

/**
 * Parses TOML with the repository's own-data wrapper.
 * @param {string} source TOML text.
 * @returns {Promise<object>} Parsed document.
 */
async function parseToml(source) {
	const { parse } = await import('smol-toml');
	return require('./fixtures/toml-own-data.cjs')(parse(source));
}

/**
 * Reads the feature manifest with one entry per declared feature.
 * @returns {Promise<object>} The parsed manifest.
 */
async function loadManifest() {
	const source = fs.readFileSync(paths.shared('modules/features/manifest.toml'), 'utf8');
	return parseToml(
		source.replace(
			/^\[\[features\.([^\]]+)\]\]$/gm,
			(_match, section) => `[[entries]]\nsection = "${section}"`
		)
	);
}

/**
 * Lists the manifest entries of one section that a platform supports.
 * @param {object} manifest Parsed manifest.
 * @param {string} section Section name.
 * @param {string} platform Platform id (ahk, hs, linux).
 * @returns {object[]} Matching entries.
 */
function entriesFor(manifest, section, platform) {
	return manifest.entries.filter(
		(entry) => entry.section === section && (!entry.platforms || entry.platforms.includes(platform))
	);
}

/**
 * Resolves the default one platform gets for an entry.
 * @param {object} entry Manifest entry.
 * @param {string} platform Platform id.
 * @returns {*} The default value.
 */
function defaultFor(entry, platform) {
	return entry.default_per_platform?.[platform] ?? entry.default;
}

/** Checks one platform against the manifest and its first-run template. */
async function checkPlatform(manifest, platform, spec) {
	const { driver, values } = spec;
	const template = await parseToml(
		fs.readFileSync(paths.shared('..', driver, '_generated', 'config_template.toml'), 'utf8')
	);
	const layoutEntries = entriesFor(manifest, 'layout', platform);
	const declared = new Set(layoutEntries.map((entry) => entry.id));

	for (const [id, neutral] of Object.entries(values)) {
		assert(declared.has(id), `${driver}: layout.${id} is not declared for ${platform}`);
		const entry = layoutEntries.find((item) => item.id === id);
		assert.deepEqual(
			defaultFor(entry, platform),
			neutral,
			`${driver}: the manifest default of layout.${id} must be neutral`
		);
		assert.deepEqual(
			template.layout?.[id],
			neutral,
			`${driver}: the first-run template must start layout.${id} neutral`
		);
	}

	for (const entry of layoutEntries) {
		const name = `layout.${entry.id}`;
		if (entry.input_altering) {
			assert(
				Object.hasOwn(values, entry.id),
				`${driver}: ${name} alters input; list its neutral value in this test`
			);
			assert(
				NEUTRAL_VALUES.includes(defaultFor(entry, platform)),
				`${driver}: ${name} alters input and must default to a neutral value`
			);
			assert(
				NEUTRAL_VALUES.includes(template.layout?.[entry.id]),
				`${driver}: the first-run template enables ${name}`
			);
		} else if (EMULATION_ROW_PARAMETERS.includes(entry.id)) {
			assert.equal(entry.input_altering, false, `${driver}: ${name} must stay a parameter`);
		}
	}

	for (const key of Object.keys(template.layout || {})) {
		assert(declared.has(key), `${driver}: the template writes layout.${key}, which is undeclared`);
	}

	const masters = template.category_enabled;
	if (platform === 'ahk') {
		assert.equal(masters?.layout, false, `${driver}: the layout master must start off`);
	} else {
		assert.equal(masters?.layout ?? false, false, `${driver}: no layout master may start on`);
	}
}

/**
 * Reads the scalar values the Windows example writes under one table. The
 * example is a reviewable draft with deliberate duplicate scalars elsewhere, so
 * only the table lines are parsed, never the whole document.
 * @param {string} table Table name, for example "layout".
 * @returns {Promise<object>} Key to parsed value.
 */
async function exampleTable(table) {
	const source = fs.readFileSync(
		paths.shared('core/config_schema/examples/ahk_config.example.toml'),
		'utf8'
	);
	const values = {};
	let current = '';
	for (const line of source.split(/\r?\n/)) {
		const header = line.match(/^\s*\[\[?([^\]]+)\]\]?/);
		if (header) {
			current = header[1].trim();
			continue;
		}
		const pair = line.match(/^([A-Za-z0-9_]+)\s*=\s*(.+?)\s*(?:#.*)?$/);
		if (current === table && pair) values[pair[1]] = (await parseToml(`x = ${pair[2]}`)).x;
	}
	return values;
}

/** The example must show the shipped neutral layout state, never an activated one. */
async function checkExample() {
	const layout = await exampleTable('layout');
	assert(Object.keys(layout).length > 0, 'the example must carry a [layout] table');
	for (const [id, value] of Object.entries(layout)) {
		assert(
			Object.hasOwn(NEUTRAL_LAYOUT.ahk.values, id),
			`the example writes layout.${id}, which is not a declared Windows layout switch`
		);
		assert.deepEqual(
			value,
			NEUTRAL_LAYOUT.ahk.values[id],
			`the example's layout.${id} must equal the shipped neutral default`
		);
	}
	const masters = await exampleTable('category_enabled');
	assert.notEqual(masters.layout, true, 'the example must not switch the layout master on');
}

/** Entry point. */
async function main() {
	const manifest = await loadManifest();
	assert(manifest.entries.length > 200, 'the real feature registry must be loaded');

	const master = manifest.entries.find(
		(entry) => entry.section === 'category_enabled' && entry.id === 'layout'
	);
	assert.equal(master.default, false, 'the layout master must default off');
	assert.equal(master.input_altering, true, 'the layout master is an activation');

	for (const id of EMULATION_ROW_PARAMETERS) {
		const row = manifest.entries.find((entry) => entry.section === 'layout' && entry.id === id);
		assert(row, `layout.${id} must stay declared`);
		assert.equal(
			row.input_altering,
			false,
			`layout.${id} narrows an emulation, it never starts one`
		);
	}

	for (const [platform, spec] of Object.entries(NEUTRAL_LAYOUT)) {
		await checkPlatform(manifest, platform, spec);
	}
	await checkExample();
	console.log('test-neutral-installation: OK');
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
