// tools/codegen/codegen-feature-inventory.cjs

/**
 * ============================================================================
 * MODULE: Feature Inventory Projection
 * DESCRIPTION:
 * Projects the shared configuration, action and menu catalogues to the website and a review queue.
 * A missing manifest entry is not proof that the user-facing capability is absent.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const { execFileSync } = require('child_process');
const path = require('path');
const toml = require('smol-toml');
const { loadFeatureModel } = require('../build/build-features-manifest.js');
const { loadBehaviors } = require('../lib/behavior-capabilities.cjs');

const ROOT = path.resolve(__dirname, '../..');
const OUT_JSON = 'src/routes/ergopti-plus/feature-inventory.json';
const OUT_MD = 'docs/feature-inventory.md';
const OUT_ACTIONS = 'src/routes/ergopti-plus/action-inventory.json';
const OUT_MENU = 'src/routes/ergopti-plus/menu-gaps.json';
const OUT_INPUT = 'src/routes/ergopti-plus/input-inventory.json';
const OUT_BEHAVIORS = 'src/routes/ergopti-plus/behavior-inventory.json';
const OUT_BEHAVIOR_MD = 'docs/behavior-inventory.md';
const OS = { windows: 'ahk', macos: 'hs', linux: 'linux' };

const OUT_HIDDEN_REASONS = 'static/ergopti_plus/_shared/menu/data/hidden_row_reasons.json';

// The reason of every hidden restricted menu row, keyed by `section` or `section.row`.
function loadHiddenReasons() {
	return JSON.parse(fs.readFileSync(path.join(ROOT, OUT_HIDDEN_REASONS), 'utf8'));
}

// A section reason applies only when it describes precisely the same drivers.
function withSectionReasons(features, sections) {
	return features.map((feature) => {
		if (feature.reason_key) return feature;
		const parts = feature.section.split('.');
		while (parts.length) {
			let section = sections;
			for (const part of parts) section = section?.[part];
			if (section?.reason_key && Array.isArray(section.platforms)) {
				const same =
					section.platforms.length === feature.platforms.length &&
					section.platforms.every((platform) => feature.platforms.includes(platform));
				if (same) return { ...feature, reason_key: section.reason_key };
				return feature;
			}
			parts.pop();
		}
		return feature;
	});
}

function render(
	features,
	locales,
	actions,
	menu,
	layers = {},
	tapHolds = {},
	behaviors = loadBehaviors(ROOT, locales),
	hiddenReasons = loadHiddenReasons()
) {
	if (features.length < 300) throw new Error('Feature inventory unexpectedly small');
	const seen = new Set();
	const rows = features.map((feature) => {
		if (seen.has(feature.path)) throw new Error(`Duplicate path: ${feature.path}`);
		seen.add(feature.path);
		if (
			!feature.platforms.length ||
			feature.platforms.some((p) => !Object.values(OS).includes(p))
		) {
			throw new Error(`Invalid platforms: ${feature.path}`);
		}
		if (
			feature.platforms.length < Object.keys(OS).length &&
			(!feature.reason_key || !locales.en[feature.reason_key] || !locales.fr[feature.reason_key])
		) {
			throw new Error(`Missing translated platform reason: ${feature.path}`);
		}
		const labels = Object.fromEntries(
			['fr', 'en'].map((lang) => [lang, locales[lang][feature.description_key] || feature.path])
		);
		return {
			path: feature.path,
			family: feature.family,
			labels,
			platforms: Object.fromEntries(
				Object.entries(OS).map(([os, key]) => [os, feature.platforms.includes(key)])
			),
			reason_key: feature.reason_key || null,
			reason: feature.reason_key
				? Object.fromEntries(
						['fr', 'en'].map((lang) => [lang, locales[lang][feature.reason_key] || ''])
					)
				: null
		};
	});
	const actionRows = [];
	for (const family of ['sg_actions', 'ax_actions']) {
		for (const [id, action] of Object.entries(actions[family])) {
			const platforms = action.platform === 'all' ? Object.values(OS) : action.platform.split(',');
			if (!platforms.length || platforms.some((key) => !Object.values(OS).includes(key)))
				throw new Error(`Invalid action platforms: ${id}`);
			const reasons = {};
			for (const [os, key] of Object.entries(OS)) {
				if (!platforms.includes(key)) {
					const reason = action[`reason_${key}`];
					if (!reason || !locales.en[reason]) throw new Error(`Missing action reason: ${id} ${os}`);
					reasons[os] = {
						en: locales.en[reason],
						fr: locales.fr[reason] || locales.en[reason],
						equivalents: action[`equivalent_${key}`] || []
					};
				}
			}
			actionRows.push({
				path: `${family}.${id}`,
				labels: Object.fromEntries(
					['fr', 'en'].map((lang) => [lang, locales[lang][`${family}.${id}`] || id])
				),
				platforms: Object.fromEntries(
					Object.entries(OS).map(([os, key]) => [os, platforms.includes(key)])
				),
				reasons
			});
		}
	}
	for (const family of ['actions', 'modifiers', 'source_kinds', 'parameters']) {
		for (const [id, entry] of Object.entries(layers[family] || {})) {
			const available =
				entry.platforms ||
				Object.keys(OS).filter((os) => entry[os] !== undefined || entry.all !== undefined);
			if (!available.length || available.some((os) => !Object.hasOwn(OS, os)))
				throw new Error(`Invalid layer platforms: ${family}.${id}`);
			const reasons = {};
			for (const os of Object.keys(OS).filter((os) => !available.includes(os))) {
				if (!entry.reason_key || !locales.en[entry.reason_key])
					throw new Error(`Missing layer reason: ${family}.${id}`);
				reasons[os] = {
					en: locales.en[entry.reason_key],
					fr: locales.fr[entry.reason_key] || locales.en[entry.reason_key],
					equivalents: []
				};
			}
			actionRows.push({
				path: `layers.${family}.${id}`,
				labels: Object.fromEntries(
					['fr', 'en'].map((lang) => [lang, locales[lang][`sg_actions.${id}`] || id])
				),
				platforms: Object.fromEntries(Object.keys(OS).map((os) => [os, available.includes(os)])),
				reasons
			});
		}
	}
	if (actionRows.length < 200) throw new Error('Action inventory unexpectedly small');
	const menuRows = [];
	const usedHiddenReasons = new Set();
	for (const [section, entries] of Object.entries(menu)) {
		if (!Array.isArray(entries)) continue;
		for (const entry of entries) {
			if (!Array.isArray(entry.platforms) || entry.platforms.length === 3) continue;
			if (
				entry.unavailable !== 'grey' &&
				![
					'command',
					'action',
					'group',
					'list',
					'toggle',
					'check',
					'choice',
					'feature',
					'letter_picker'
				].includes(entry.type)
			)
				continue;
			if (entry.platforms.some((key) => !Object.values(OS).includes(key)))
				throw new Error(`Invalid menu platforms: ${section}`);
			// A hidden row carries no reason_key in the menu (its validator forbids one), so its
			// reason lives in the hidden-row registry, by row identity then by section.
			const reasonKey =
				entry.reason_key ||
				hiddenReasons[`${section}.${entry.id || entry.path}`] ||
				hiddenReasons[section];
			if (!reasonKey || !locales.en[reasonKey] || !locales.fr[reasonKey])
				throw new Error(
					`Restricted menu entry has no translated reason: ${section}.${entry.id || entry.path}`
				);
			if (!entry.reason_key)
				usedHiddenReasons.add(
					hiddenReasons[`${section}.${entry.id || entry.path}`]
						? `${section}.${entry.id || entry.path}`
						: section
				);
			const id = entry.id || entry.path;
			if (!id) throw new Error(`Unavailable menu entry has no identity: ${section}`);
			menuRows.push({
				path: `${section}.${id}`,
				visibility: entry.unavailable || 'hide',
				labels: Object.fromEntries(
					['fr', 'en'].map((lang) => [lang, locales[lang][entry.i18n] || id])
				),
				platforms: Object.fromEntries(
					Object.entries(OS).map(([os, key]) => [os, entry.platforms.includes(key)])
				),
				reasons: Object.fromEntries(
					Object.entries(OS)
						.filter(([, key]) => !entry.platforms.includes(key))
						.map(([os]) => [
							os,
							{
								en: locales.en[reasonKey],
								fr: locales.fr[reasonKey]
							}
						])
				)
			});
		}
	}
	if (!menuRows.length) throw new Error('Unavailable menu inventory unexpectedly empty');
	for (const key of Object.keys(hiddenReasons))
		if (!usedHiddenReasons.has(key)) throw new Error(`Stale hidden-row reason: ${key}`);
	const inputRows = (tapHolds.tap_hold?.catalog?.keys || []).map((entry) => ({
		path: `tap_hold.${entry.id}`,
		labels: Object.fromEntries(
			['fr', 'en'].map((lang) => [lang, locales[lang][`key_name.${entry.id}`] || entry.id])
		),
		platforms: Object.fromEntries(
			Object.entries(OS).map(([os, driver]) => [os, typeof entry[driver] === 'string'])
		),
		native_ids: Object.fromEntries(
			Object.entries(OS).map(([os, driver]) => [os, entry[driver] || null])
		),
		reasons: {}
	}));
	const json = `${JSON.stringify(rows, null, '\t')}\n`;
	const lines = [
		'<!-- Generated by tools/codegen/codegen-feature-inventory.cjs. Do not edit. -->',
		'',
		'# Configuration, action and unavailable menu inventory',
		'',
		'These are complete projections of the shared configuration and action catalogues and the platform-restricted interactive menu entries, not a complete inventory of all product capabilities. An absent path or action may have an equivalent on another OS, be intentional, or be a real gap. Inclusion is a declaration, not proof of runtime behavior. Review the source, tests, and platform reason before implementing anything.',
		'',
		'Each unchecked row is a triage item, not a confirmed missing feature. To update this queue and the website data, edit the manifest and run `node tools/codegen/codegen-feature-inventory.cjs`; the Linux parity gate checks for stale outputs.',
		''
	];
	for (const os of Object.keys(OS)) {
		const absent = rows.filter((row) => !row.platforms[os]);
		lines.push(`## ${os} — ${absent.length} paths not declared`, '');
		for (const row of absent) {
			const available = Object.keys(OS)
				.filter((name) => row.platforms[name])
				.join(', ');
			lines.push(
				`- [ ] \`${row.path}\` (${row.family}; declared: ${available}${row.reason_key ? `; reason: \`${row.reason_key}\`` : '; reason: review section/platform implementation'})`
			);
		}
		lines.push('');
	}
	for (const os of Object.keys(OS)) {
		const absent = actionRows.filter((row) => !row.platforms[os]);
		lines.push(`## ${os} — ${absent.length} actions not declared`, '');
		for (const row of absent) {
			const reason = row.reasons[os];
			lines.push(
				`- [ ] \`${row.path}\`: ${reason.en}${reason.equivalents.length ? ` Equivalent actions: ${reason.equivalents.map((id) => `\`${id}\``).join(', ')}.` : ''}`
			);
		}
		lines.push('');
	}
	for (const os of Object.keys(OS)) {
		lines.push(`## ${os} — restricted menu entries`, '');
		for (const row of menuRows.filter((entry) => !entry.platforms[os]))
			lines.push(`- [ ] \`${row.path}\` (${row.visibility}): ${row.reasons[os].en}`);
		lines.push('');
	}
	lines.push(
		'## Tap-hold physical key identities',
		'',
		'These are native key identities, not missing-capability claims: Command/Option and Win/AltGr differ between keyboards. Hold-action picker contents are reviewed separately in the platform parity audit.',
		'',
		'| Key | Windows | macOS | Linux |',
		'| --- | --- | --- | --- |'
	);
	for (const row of inputRows)
		lines.push(
			`| ${row.path} | ${row.native_ids.windows || '—'} | ${row.native_ids.macos || '—'} | ${row.native_ids.linux || '—'} |`
		);
	lines.push('');
	const markdown = formatOwnedOutput(`${lines.join('\n')}\n`, OUT_MD);
	const actionJson = formatOwnedOutput(JSON.stringify(actionRows), OUT_ACTIONS);
	const menuJson = formatOwnedOutput(JSON.stringify(menuRows), OUT_MENU);
	const inputJson = formatOwnedOutput(JSON.stringify(inputRows), OUT_INPUT);
	const behaviorLines = [
		'<!-- Generated by tools/codegen/codegen-feature-inventory.cjs. Do not edit. -->',
		'',
		'# Reviewed behavior declarations',
		'',
		'This supplementary catalogue covers explicitly reviewed behaviors that need no separate setting or action. It is not an exhaustive product inventory or a native application delivery certificate. A declared behavior may have a documented limitation. Application Undo and automatic Backspace restoration are distinct.',
		'',
		'Edit `_shared/settings/data/features/behaviors.json` after reviewing the named owners, then run `npm run codegen:feature-inventory`. Any changed owner file blocks generation until its source receipt is explicitly reviewed; generation never updates review hashes. These conservative whole-file hashes detect source drift, not semantic correctness or an unlisted capability.',
		'',
		'| Behavior | Windows | macOS | Linux |',
		'| --- | --- | --- | --- |'
	];
	for (const behavior of behaviors) {
		behaviorLines.push(
			`| ${behavior.labels.en} | ${Object.keys(OS)
				.map(
					(os) =>
						`${behavior.platforms[os] ? 'Declared' : 'Not declared'}: ${behavior.notes[os].en}`
				)
				.join(' | ')} |`
		);
	}
	for (const behavior of behaviors) {
		behaviorLines.push('', `## ${behavior.path}`, '');
		for (const os of Object.keys(OS)) {
			behaviorLines.push(
				`- ${os}: ${behavior.evidence[os].map((owner) => `[${owner.file}](../${owner.file}) — \`${owner.symbol}\`, SHA-256 \`${owner.sha256}\``).join('; ')}.`
			);
		}
	}
	return {
		[OUT_BEHAVIORS]: formatOwnedOutput(JSON.stringify(behaviors), OUT_BEHAVIORS),
		[OUT_BEHAVIOR_MD]: formatOwnedOutput(`${behaviorLines.join('\n')}\n`, OUT_BEHAVIOR_MD),
		[OUT_INPUT]: inputJson,
		[OUT_MENU]: menuJson,
		[OUT_JSON]: json,
		[OUT_ACTIONS]: actionJson,
		[OUT_MD]: markdown
	};
}

/** Format owned outputs without applying the manual formatter's ignore policy. */
function formatOwnedOutput(source, filepath) {
	return execFileSync(
		process.execPath,
		[
			'--input-type=module',
			'-e',
			`import * as prettier from 'prettier';
process.stdin.setEncoding('utf8');
let source = '';
for await (const chunk of process.stdin) source += chunk;
const filepath = process.argv[1];
const config = await prettier.resolveConfig(filepath);
process.stdout.write(await prettier.format(source, { ...config, filepath }));`,
			filepath
		],
		{ cwd: ROOT, input: source, encoding: 'utf8' }
	);
}

function outputs() {
	const locales = Object.fromEntries(
		['fr', 'en'].map((lang) => [
			lang,
			JSON.parse(
				fs.readFileSync(
					path.join(ROOT, `static/ergopti_plus/_shared/core/i18n/data/locales/${lang}.json`),
					'utf8'
				)
			)
		])
	);
	const actions = toml.parse(
		fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/shortcuts/data/actions/actions.toml'),
			'utf8'
		)
	);
	const menu = JSON.parse(
		fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/menu/data/menu_manifest.json'),
			'utf8'
		)
	);
	const layers = toml.parse(
		fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/layouts/data/layer_actions.toml'),
			'utf8'
		)
	);
	const tapHolds = toml.parse(
		fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/tap_hold/data/defaults.toml'),
			'utf8'
		)
	);
	const model = loadFeatureModel();
	return render(
		withSectionReasons(model.features, model.manifest.sections),
		locales,
		actions,
		menu,
		layers,
		tapHolds
	);
}

function check() {
	for (const [name, expected] of Object.entries(outputs())) {
		if (
			!fs.existsSync(path.join(ROOT, name)) ||
			fs.readFileSync(path.join(ROOT, name), 'utf8') !== expected
		) {
			throw new Error(`${name} is stale; run node tools/codegen/codegen-feature-inventory.cjs`);
		}
	}
}

if (require.main === module) {
	if (process.argv.includes('--check')) check();
	else
		for (const [name, content] of Object.entries(outputs()))
			fs.writeFileSync(path.join(ROOT, name), content);
}

module.exports = { render, check, withSectionReasons };
