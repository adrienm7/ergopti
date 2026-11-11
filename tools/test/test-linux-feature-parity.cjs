// tools/test/test-linux-feature-parity.cjs

/**
 * ============================================================================
 * MODULE: Linux Feature Parity Evidence Tests
 * DESCRIPTION:
 * Ensures every canonical feature has an explicit Linux status, absence reason,
 * implementation state, owner, and proof tier without treating declaration as
 * runtime or hardware evidence.
 * ============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { luaManifestSource } = require('../lib/lua-manifest-view.cjs');
const { buildParityRows, summarize } = require('./linux-feature-parity.cjs');
const ROOT = path.resolve(__dirname, '..', '..');
// Import the actual dictionary: apparent mappings inside JSDoc are not exports.
const inventoryText = [
	'Options de menu propres à certains systèmes',
	'Option',
	'Touches tap-hold par système',
	'Inventaire des actions configurables',
	'Action',
	'Trois systèmes, un projet.',
	'Inventaire des réglages et fonctionnalités',
	'Fonctionnalité ou réglage',
	'✓ déclaré pour ce système',
	'— entrée non déclarée pour ce système'
];
const dictionaryUrl = pathToFileURL(path.join(ROOT, 'src/routes/ergopti-plus/locales/en.js')).href;
const dictionaryResult = spawnSync(
	process.execPath,
	[
		'--input-type=module',
		'-e',
		`import dictionary from ${JSON.stringify(dictionaryUrl)}; console.log(JSON.stringify(${JSON.stringify(inventoryText)}.map(key => [key, dictionary[key] ?? null])));`
	],
	{ cwd: ROOT, encoding: 'utf8', timeout: 60000 }
);
assert.ifError(dictionaryResult.error);
assert.strictEqual(dictionaryResult.status, 0, dictionaryResult.stderr);
const exportedInventoryText = Object.fromEntries(JSON.parse(dictionaryResult.stdout));
for (const key of inventoryText)
	assert.ok(
		typeof exportedInventoryText[key] === 'string' && exportedInventoryText[key].length > 0,
		`The actual English dictionary must export the inventory label: ${key}`
	);
assert.strictEqual(exportedInventoryText['Fonctionnalité ou réglage'], 'Feature or setting');
const inventory = require('../codegen/codegen-feature-inventory.cjs');
const { CATALOGUE, projectBehaviors } = require('../lib/behavior-capabilities.cjs');
inventory.check();
// Both projections must react to a change in a platform declaration.
const featureModel = require('../build/build-features-manifest.js').loadFeatureModel();
const inventoryModel = inventory.withSectionReasons(
	featureModel.features,
	featureModel.manifest.sections
);
assert.strictEqual(
	inventoryModel.find((row) => row.path === 'gestures.modes.swipe_2_left').reason_key,
	'platform_reason.gesture_modes_and_steps_need_finger_travel'
);
const inheritedFixture = inventory.withSectionReasons(
	[{ section: 'one', platforms: ['hs', 'linux'] }],
	{ one: { platforms: ['hs'], reason_key: 'wrong' } }
);
assert.strictEqual(
	inheritedFixture[0].reason_key,
	undefined,
	'section reasons must not cross platform sets'
);
const inventoryLocales = Object.fromEntries(
	['fr', 'en'].map((lang) => [
		lang,
		JSON.parse(
			fs.readFileSync(
				path.join(ROOT, `static/ergopti_plus/_shared/data/locales/${lang}.json`),
				'utf8'
			)
		)
	])
);
const inventoryActions = require('smol-toml').parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/modules/actions/actions.toml'),
		'utf8'
	)
);
const inventoryMenu = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/modules/menu/menu_manifest.json'),
		'utf8'
	)
);
const beforeInventory = inventory.render(
	inventoryModel,
	inventoryLocales,
	inventoryActions,
	inventoryMenu
);
// Hidden rows resolve their translation key through the registry, not reason_key.
const hiddenProfileRow = JSON.parse(beforeInventory['src/routes/ergopti-plus/menu-gaps.json']).find(
	(row) => row.path === 'llm_custom_profile_controls.llm_profile_shortcut'
);
assert.ok(hiddenProfileRow, 'the restricted profile shortcut row must be inventoried');
const hiddenProfileReasons = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/modules/menu/hidden_row_reasons.json'),
		'utf8'
	)
);
const hiddenProfileReason =
	hiddenProfileReasons[hiddenProfileRow.path] || hiddenProfileReasons.llm_custom_profile_controls;
assert.notStrictEqual(
	inventoryLocales.fr[hiddenProfileReason],
	inventoryLocales.en[hiddenProfileReason]
);
assert.strictEqual(
	hiddenProfileRow.reasons.linux.fr,
	inventoryLocales.fr[hiddenProfileReason],
	'the French inventory must use the translated hidden-row reason'
);
const unexplainedModel = structuredClone(inventoryModel);
const unexplained = unexplainedModel.find((row) => row.platforms.length < 3);
delete unexplained.reason_key;
assert.throws(
	() => inventory.render(unexplainedModel, inventoryLocales, inventoryActions, inventoryMenu),
	/Missing translated platform reason/
);
// A hidden restricted menu row must name its reason, and a registry entry that no row uses is stale.
const noBehaviors = [];
assert.throws(
	() =>
		inventory.render(
			inventoryModel,
			inventoryLocales,
			inventoryActions,
			inventoryMenu,
			{},
			{},
			noBehaviors,
			{}
		),
	/Restricted menu entry has no translated reason/
);
assert.throws(
	() =>
		inventory.render(
			inventoryModel,
			inventoryLocales,
			inventoryActions,
			inventoryMenu,
			{},
			{},
			noBehaviors,
			{
				...JSON.parse(
					fs.readFileSync(
						path.join(ROOT, 'static/ergopti_plus/_shared/modules/menu/hidden_row_reasons.json'),
						'utf8'
					)
				),
				retired_section: 'platform_reason.remap_engine_is_per_driver'
			}
		),
	/Stale hidden-row reason: retired_section/
);
const generators = require('../build/generators.cjs').GENERATORS;
const inventoryGenerator = generators.find(
	(entry) => entry.script === 'codegen/codegen-feature-inventory.cjs'
);
assert.ok(inventoryGenerator, 'normal regeneration must include the public inventory');
assert.deepStrictEqual(
	[...inventoryGenerator.outputs].sort(),
	Object.keys(beforeInventory).sort(),
	'normal drift guard must own every inventory output'
);
const prebuild = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).scripts
	.prebuild;
assert.ok(
	prebuild.includes('build-menu-manifest.js') &&
		prebuild.indexOf('build-menu-manifest.js') < prebuild.indexOf('codegen-feature-inventory.cjs'),
	'site build must refresh the menu source before projecting the inventory'
);
assert.ok(
	prebuild.includes('codegen-feature-inventory.cjs'),
	'site builds must regenerate the inventory'
);
const changedModel = structuredClone(inventoryModel);
changedModel[0].platforms = ['ahk'];
changedModel[0].reason_key = 'platform_reason.alt_gr_is_kana_remap';
const afterInventory = inventory.render(
	changedModel,
	inventoryLocales,
	inventoryActions,
	inventoryMenu
);
for (const file of Object.keys(beforeInventory).filter(
	(name) =>
		!name.endsWith('action-inventory.json') &&
		!name.endsWith('menu-gaps.json') &&
		!name.endsWith('input-inventory.json') &&
		!name.endsWith('behavior-inventory.json') &&
		!name.endsWith('behavior-inventory.md')
)) {
	assert.notStrictEqual(
		beforeInventory[file],
		afterInventory[file],
		`${file} must reflect platform changes`
	);
}

// Behavioral declarations are independent of configuration paths. Changes to
// either source must reach its own projections without silently changing the other.
const behaviorCatalogue = JSON.parse(fs.readFileSync(path.join(ROOT, CATALOGUE), 'utf8'));
const behaviorRows = projectBehaviors(behaviorCatalogue, ROOT, inventoryLocales);
const behaviorOutputs = [
	'src/routes/ergopti-plus/behavior-inventory.json',
	'docs/behavior-inventory.md'
];
for (const file of behaviorOutputs) assert.strictEqual(beforeInventory[file], afterInventory[file]);
assert.ok(behaviorRows.length >= 2);
assert.deepStrictEqual(
	behaviorRows.find((row) => row.path === 'hotstrings.backspace_restore').platforms,
	{
		windows: true,
		macos: true,
		linux: true
	}
);
for (const behavior of behaviorCatalogue.behaviors) {
	const projected = behaviorRows.find((row) => row.path === behavior.id);
	for (const os of ['windows', 'macos', 'linux']) {
		for (const lang of ['en', 'fr']) {
			const expected = inventoryLocales[lang][behavior.platforms[os].note_key];
			assert.strictEqual(projected.notes[os][lang], expected);
			assert.strictEqual(
				JSON.parse(beforeInventory[behaviorOutputs[0]]).find((row) => row.path === behavior.id)
					.notes[os][lang],
				expected
			);
			if (lang === 'en') assert.ok(beforeInventory[behaviorOutputs[1]].includes(expected));
		}
	}
}
const changedBehavior = structuredClone(behaviorCatalogue);
changedBehavior.behaviors[1].platforms.linux.declared = false;
const afterBehavior = inventory.render(
	inventoryModel,
	inventoryLocales,
	inventoryActions,
	inventoryMenu,
	{},
	{},
	projectBehaviors(changedBehavior, ROOT, inventoryLocales)
);
for (const file of behaviorOutputs)
	assert.notStrictEqual(beforeInventory[file], afterBehavior[file]);
assert.strictEqual(
	beforeInventory['src/routes/ergopti-plus/feature-inventory.json'],
	afterBehavior['src/routes/ergopti-plus/feature-inventory.json']
);
for (const [mutate, message] of [
	[
		(doc) => {
			doc.schema_version = 2;
		},
		/catalogue metadata/
	],
	[
		(doc) => {
			doc.extra = true;
		},
		/catalogue fields/
	],
	[
		(doc) => {
			doc.owners = [];
		},
		/catalogue metadata/
	],
	[
		(doc) => {
			doc.behaviors = [];
		},
		/catalogue metadata/
	],
	[
		(doc) => {
			doc.owners.push(doc.owners[0]);
		},
		/duplicate behavior owner/
	],
	[
		(doc) => {
			doc.owners[0].file = 'static/ergopti_plus/windows/../private.ahk';
		},
		/behavior owner/
	],
	[
		(doc) => {
			doc.owners[0].file = 'static/ergopti_plus/windows/missing-owner.ahk';
		},
		/Missing behavior owner/
	],
	[
		(doc) => {
			doc.owners[0].sha256 = '0'.repeat(64);
		},
		/needs source review/
	],
	[
		(doc) => {
			doc.owners[0].symbol = 'NonexistentBehaviorOwnerMustFail';
		},
		/needs source review/
	],
	[
		(doc) => {
			doc.behaviors.push(doc.behaviors[0]);
		},
		/duplicate behavior id/
	],
	[
		(doc) => {
			delete doc.behaviors[0].platforms.linux;
		},
		/platforms fields/
	],
	[
		(doc) => {
			doc.behaviors[0].platforms.android = doc.behaviors[0].platforms.linux;
		},
		/platforms fields/
	],
	[
		(doc) => {
			doc.behaviors[0].platforms.linux.declared = 'true';
		},
		/Invalid behavior state/
	],
	[
		(doc) => {
			doc.behaviors[0].platforms.linux.owners = [];
		},
		/Invalid behavior state/
	],
	[
		(doc) => {
			doc.behaviors[0].platforms.linux.owners = ['windows-repeat'];
		},
		/Unknown behavior owner/
	],
	[
		(doc) => {
			doc.behaviors[0].platforms.linux.note_key = 'inventory.behavior.missing';
		},
		/Missing behavior translation/
	],
	[
		(doc) => {
			doc.behaviors[0].label_key = 'inventory.behavior.missing';
		},
		/Missing behavior translation/
	],
	[
		(doc) => {
			doc.behaviors[0].platforms.windows.owners.push('windows-repeat');
		},
		/Invalid behavior state/
	]
]) {
	const candidate = structuredClone(behaviorCatalogue);
	mutate(candidate);
	assert.throws(() => projectBehaviors(candidate, ROOT, inventoryLocales), message);
}
const missingTranslation = structuredClone(inventoryLocales);
assert.throws(
	() => projectBehaviors(behaviorCatalogue, ROOT, {}),
	/Missing behavior translation locales/
);
delete missingTranslation.fr['inventory.behavior.backspace_restore'];
assert.throws(
	() => projectBehaviors(behaviorCatalogue, ROOT, missingTranslation),
	/Missing behavior translation/
);

const EVIDENCE_PATH = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'features',
	'linux_evidence.json'
);
const manifest = luaManifestSource('linux');
const evidenceConfig = JSON.parse(fs.readFileSync(EVIDENCE_PATH, 'utf8'));

function build(config = evidenceConfig) {
	return buildParityRows({ manifest, evidenceConfig: config, rootDirectory: ROOT });
}

const expandedActions = structuredClone(inventoryActions);
expandedActions.sg_actions.lookup = { platform: 'all' };
const expandedInventory = inventory.render(
	inventoryModel,
	inventoryLocales,
	expandedActions,
	inventoryMenu
);
for (const file of ['src/routes/ergopti-plus/action-inventory.json', 'docs/feature-inventory.md']) {
	assert.notStrictEqual(
		beforeInventory[file],
		expandedInventory[file],
		`${file} must reflect action changes`
	);
}
const changedActions = structuredClone(inventoryActions);
delete changedActions.sg_actions.lookup.reason_ahk;
assert.throws(
	() => inventory.render(inventoryModel, inventoryLocales, changedActions, inventoryMenu),
	/Missing action reason/
);

const changedMenu = structuredClone(inventoryMenu);
changedMenu.llm_display_menu
	.find((item) => item.id === 'llm_token_streaming')
	.platforms.push('ahk');
const expandedMenuInventory = inventory.render(
	inventoryModel,
	inventoryLocales,
	inventoryActions,
	changedMenu
);
for (const file of ['src/routes/ergopti-plus/menu-gaps.json', 'docs/feature-inventory.md']) {
	assert.notStrictEqual(
		beforeInventory[file],
		expandedMenuInventory[file],
		`${file} must reflect menu changes`
	);
}

// Hidden platform-specific commands must be inventoried as well as grey rows.
const hiddenMenu = structuredClone(inventoryMenu);
const editShortcuts = hiddenMenu.shortcuts_menu.find((item) => item.id === 'edit_shortcuts');
assert.ok(editShortcuts && !editShortcuts.platforms.includes('linux'));
editShortcuts.platforms.push('linux');
const hiddenMenuInventory = inventory.render(
	inventoryModel,
	inventoryLocales,
	inventoryActions,
	hiddenMenu
);
for (const file of ['src/routes/ergopti-plus/menu-gaps.json', 'docs/feature-inventory.md']) {
	assert.notStrictEqual(
		beforeInventory[file],
		hiddenMenuInventory[file],
		`${file} must reflect hidden menu changes`
	);
}

const layerVocabulary = require('smol-toml').parse(
	fs.readFileSync(path.join(ROOT, 'static/ergopti_plus/_shared/keymap/layer_actions.toml'), 'utf8')
);
const withLayers = inventory.render(
	inventoryModel,
	inventoryLocales,
	inventoryActions,
	inventoryMenu,
	layerVocabulary
);
const layerRows = JSON.parse(withLayers['src/routes/ergopti-plus/action-inventory.json']).filter(
	(row) => row.path.startsWith('layers.')
);
assert.ok(layerRows.length >= 40, 'layer vocabulary must be projected');
assert.ok(
	JSON.parse(
		fs.readFileSync(path.join(ROOT, 'src/routes/ergopti-plus/action-inventory.json'), 'utf8')
	).filter((row) => row.path.startsWith('layers.')).length >= 40,
	'published inventory must contain the layer vocabulary'
);
assert.strictEqual(
	layerRows.find((row) => row.path === 'layers.parameters.repeat_count').platforms.linux,
	true
);
const badLayerVocabulary = structuredClone(layerVocabulary);
delete badLayerVocabulary.modifiers.fn.reason_key;
assert.throws(
	() =>
		inventory.render(
			inventoryModel,
			inventoryLocales,
			inventoryActions,
			inventoryMenu,
			badLayerVocabulary
		),
	/Missing layer reason/
);

const inputInventory = JSON.parse(
	fs.readFileSync(path.join(ROOT, 'src/routes/ergopti-plus/input-inventory.json'), 'utf8')
);
const tapDefaults = require('smol-toml').parse(
	fs.readFileSync(path.join(ROOT, 'static/ergopti_plus/_shared/tap_hold/defaults.toml'), 'utf8')
);
assert.strictEqual(inputInventory.length, tapDefaults.tap_hold.catalog.keys.length);
assert.ok(inputInventory.length >= 19, 'input inventory must cover the native key catalogue');
assert.strictEqual(
	inputInventory.find((entry) => entry.path === 'tap_hold.fn').platforms.windows,
	false
);

const rows = build();
const summary = summarize(rows);
const canonical = fs.readFileSync(
	path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'features', 'manifest.toml'),
	'utf8'
);
const declaredCount = [...canonical.matchAll(/^\[\[features\.[^\]]+\]\]$/gm)].length;
assert.ok(declaredCount >= 326, 'canonical registry must retain its audited feature coverage');
assert.strictEqual(
	summary.total,
	declaredCount,
	'the Linux projection must classify every canonical feature'
);
assert.ok(
	summary.claimed_supported >= 126,
	'supported feature count may only increase from the audited 126'
);
const provenPaths = new Set([
	...Object.values(evidenceConfig.evidence_groups).flatMap((group) => group.members),
	...Object.keys(evidenceConfig.overrides)
]);
assert.ok(provenPaths.size >= 126, 'the audited supported paths must retain explicit evidence');
for (const featurePath of provenPaths) {
	assert.strictEqual(
		rows.find((row) => row.path === featurePath)?.status,
		'claimed_supported',
		`adding platform-specific defaults must not remove Linux support for ${featurePath}`
	);
}
// Only macOS draws a menubar icon whose variant the user picks.
const menubarIcon = rows.find((row) => row.path === 'ui.menubar_icon');
assert.ok(
	menubarIcon &&
		menubarIcon.status === 'unavailable' &&
		menubarIcon.reason.kind === 'macos_specific',
	'ui.menubar_icon must stay a macOS-specific setting, not a Linux gap'
);
// layout.emulated_layout is a Linux feature since the maintainer decision of
// 2026-11-06 (layout emulation on the three OS): the daemon types the chosen
// .keylayout over the session's XKB layout (modules/keymap/layout_emulation.lua).
const emulatedLayout = rows.find((row) => row.path === 'layout.emulated_layout');
assert.ok(
	emulatedLayout && emulatedLayout.status === 'claimed_supported',
	'layout.emulated_layout must be claimed on Linux, which emulates the layout like Windows'
);
assert.strictEqual(summary.claimed_supported + summary.unavailable, summary.total);
assert.strictEqual(
	rows.filter((row) => !row.reason?.kind).length,
	0,
	'every row needs a reason classification'
);
assert.strictEqual(rows.filter((row) => !row.owner).length, 0, 'every row needs an owner');
assert.strictEqual(
	rows.filter(
		(row) =>
			row.status === 'unavailable' &&
			row.intentional === false &&
			row.reason.kind !== 'linux_parity_gap'
	).length,
	0
);
assert.strictEqual(
	summary.unverified_supported,
	0,
	'every supported Linux feature needs software evidence instead of inheriting a declaration'
);
assert.strictEqual(
	summary.proven_above_declaration,
	summary.claimed_supported,
	'every supported Linux feature needs proof above the declaration tier'
);

const mutation = JSON.parse(JSON.stringify(evidenceConfig));
mutation.supported_defaults.proof_tier = 'unit';
assert.throws(() => build(mutation), /claims proof without a tracked evidence path/);

const missingField = JSON.parse(JSON.stringify(evidenceConfig));
delete missingField.supported_defaults.applied;
assert.throws(() => build(missingField), /missing evidence field applied/);

const unknown = JSON.parse(JSON.stringify(evidenceConfig));
unknown.overrides['does.not.exist'] = { registered: 'yes' };
assert.throws(() => build(unknown), /unknown path/);

const unknownGroupMember = JSON.parse(JSON.stringify(evidenceConfig));
unknownGroupMember.evidence_groups.unknown = {
	...unknownGroupMember.evidence_groups.gestures,
	members: ['does.not.exist']
};
assert.throws(() => build(unknownGroupMember), /names unknown path/);

const duplicateGroupMember = JSON.parse(JSON.stringify(evidenceConfig));
duplicateGroupMember.evidence_groups.duplicate = {
	...duplicateGroupMember.evidence_groups.gestures,
	members: [duplicateGroupMember.evidence_groups.gestures.members[0]]
};
assert.throws(() => build(duplicateGroupMember), /belongs to more than one evidence group/);

if (process.argv.includes('--report')) {
	process.stdout.write(`${JSON.stringify({ summary, features: rows }, null, 2)}\n`);
} else {
	process.stdout.write(
		`PASS: ${summary.total} Linux features classified; ` +
			`${summary.claimed_supported} claimed supported, ${summary.unavailable} unavailable, ` +
			`${summary.parity_gaps} parity gaps, ${summary.unverified_supported} software claims unverified, ` +
			`${summary.hardware_pending} supported claims awaiting hardware proof.\n`
	);
}
