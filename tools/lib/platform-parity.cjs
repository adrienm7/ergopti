// tools/lib/platform-parity.cjs

/**
 * ============================================================================
 * MODULE: Platform Parity Table
 * DESCRIPTION:
 * Projects every user-facing feature, bindable action, layer entry and
 * interactive menu row into one status per OS (supported, degraded or
 * unavailable), with the driver code that owns each available cell and, for
 * every other cell, its technical reason and the translated text the menu
 * shows. The rules that make the table trustworthy are checked here, so the
 * generator and the gate cannot disagree.
 *
 * FEATURES & RATIONALE:
 * 1. One source: statuses come from the shared catalogues (manifest.toml,
 *    actions.toml, layer_actions.toml, menu_manifest.json); nothing is restated.
 * 2. Owners are found, not declared: a cell's owner is the production file of
 *    that driver whose code (comments and module names left out) spells the
 *    entry's key the most often. platform_parity.toml names an owner only when
 *    no file spells it, and that declaration is itself checked.
 * 3. A reason is two texts: `technical` in platform_parity.toml is for the
 *    developer (the OS API, the session, the permission), and the locale key is
 *    what the menu shows, which must exist in all 21 locales.
 * 4. An owner found by its spelling is source evidence, not proof that the
 *    feature works on that OS; native receiving stays a separate question.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { codeLines } = require('./feature-platform-reads.cjs');
const { driverProductionFiles } = require('./driver-source-owner.cjs');
const { gitPaths } = require('./git-paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const OS = { windows: 'ahk', macos: 'hs', linux: 'linux' };
const STATUSES = ['supported', 'degraded', 'unavailable'];
const REASON_KINDS = {
	os_api: 'the OS, its session or its permission model offers no way to do it',
	os_concept: 'the concept exists only on the OS that has it',
	os_equivalent: 'the OS reaches the same result its own way (another action or mechanism)',
	driver_storage: 'the same capability, kept under another name or place on that driver',
	menu_layout: 'a menu-structure difference: the control exists under another row',
	not_yet: 'possible on that OS but not delivered yet: a real parity gap'
};
// The interactive row types of menu_manifest.json, as the feature inventory reads them.
const MENU_ROW_TYPES = new Set([
	'command',
	'action',
	'group',
	'list',
	'toggle',
	'check',
	'choice',
	'feature',
	'letter_picker'
]);
const SOURCE_EXTENSIONS = { windows: ['.ahk'], macos: ['.lua'], linux: ['.lua'] };
// Key registries and the generated feature manifest spell every key once without
// owning any behaviour.
const NOT_OWNERS = new Set([
	'static/ergopti_plus/_shared/settings/engine/keys.lua',
	'static/ergopti_plus/_shared/settings/engine/features/manifest_data.lua'
]);
const SHARED_ROOT = 'static/ergopti_plus/_shared/';

// ====================================
// ====================================
// ======= 1/ Source token index =======
// ====================================
// ====================================

/**
 * Counts the identifiers, dotted names and quoted strings of one source.
 * @param {string} text Code without comment lines.
 * @returns {Map<string, number>} Token counts; quoted strings keep their quotes off and a q: prefix.
 */
function tokenCounts(text) {
	const counts = new Map();
	const bump = (token) => counts.set(token, (counts.get(token) || 0) + 1);
	for (const match of text.matchAll(/"([^"\n]{1,120})"|'([^'\n]{1,120})'/g))
		bump(`q:${match[1] ?? match[2]}`);
	for (const match of text.matchAll(/[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*/g)) {
		bump(match[0]);
		if (match[0].includes('.')) for (const part of match[0].split('.')) bump(part);
	}
	return counts;
}

/**
 * Indexes the production sources each OS runs: its driver tree first, then the
 * shared Lua both Lua drivers load.
 * @returns {Record<string, {driver: Array, shared: Array}>} Indexed files per OS.
 */
function loadSourceIndex() {
	const read = (rel) => ({
		rel,
		tokens: tokenCounts(codeLines(fs.readFileSync(path.join(ROOT, rel), 'utf8')))
	});
	const sharedLua = gitPaths(ROOT, ['ls-files', '--cached', '-z', '--', SHARED_ROOT])
		.map((rel) => rel.split(path.sep).join('/'))
		.filter(
			(rel) =>
				rel.endsWith('.lua') &&
				!/\/(tests|_generated|vendor)\//.test(rel) &&
				!NOT_OWNERS.has(rel) &&
				fs.existsSync(path.join(ROOT, rel))
		)
		.map(read);
	const index = {};
	for (const os of Object.keys(OS)) {
		const isSource = (rel) =>
			SOURCE_EXTENSIONS[os].some((ext) => rel.endsWith(ext)) &&
			!rel.includes('/native/') &&
			fs.existsSync(path.join(ROOT, rel));
		index[os] = {
			driver: driverProductionFiles(os).filter(isSource).map(read),
			shared: os === 'windows' ? [] : sharedLua,
			// The driver's dispatch tables generated from the action catalogues. They
			// own a key-sending action or layer entry, never a feature: every
			// generated feature manifest spells every feature it carries.
			generated: gitPaths(ROOT, [
				'ls-files',
				'--cached',
				'-z',
				'--',
				`static/ergopti_plus/${os}/_generated/`
			])
				.map((rel) => rel.split(path.sep).join('/'))
				.filter((rel) => isSource(rel) && /(action|emit|layer)/.test(path.posix.basename(rel)))
				.map(read)
		};
	}
	return index;
}

/** @param {string} id snake_case id. @returns {string} CamelCase spelling. */
function camel(id) {
	return id
		.split('_')
		.map((word) => (word ? word[0].toUpperCase() + word.slice(1) : ''))
		.join('');
}

/**
 * The spellings by which a driver reads or handles one catalogue entry.
 * @param {{kind: string, path: string, id: string, section?: string}} entry Table entry.
 * @returns {string[]} Index tokens.
 */
function entryTokens(entry) {
	const tokens = new Set([`q:${entry.path}`]);
	const upper = entry.path.replace(/\./g, '_').toUpperCase();
	if (entry.kind === 'feature') {
		tokens.add(upper);
		const leaf = entry.id === 'enabled' ? entry.section.split('.').pop() : entry.id;
		if (entry.id !== 'enabled') {
			tokens.add(`q:${entry.id}`);
			// The leaf constant: ConfigLeaf.X on Windows, ConfigKeys.LEAF.X in Lua.
			if (entry.id.includes('_')) tokens.add(entry.id.toUpperCase());
			// The prefixed state name a driver keeps (llm_streaming_multi for llm.display.streaming_multi).
			const root = entry.section.split('.')[0];
			tokens.add(`${root}_${entry.id}`);
			tokens.add(`q:${root}_${entry.id}`);
		} else tokens.add(`q:${entry.section}`);
		if (leaf.length > 5 && leaf.includes('_')) {
			tokens.add(leaf);
			tokens.add(camel(leaf));
		}
	} else {
		for (const name of [entry.id, entry.command].filter(Boolean)) {
			tokens.add(`q:${name}`);
			if (name.includes('_')) {
				// A Lua handler table key, or a command constant (MenuCommand.X, keys.COMMAND.X).
				tokens.add(name);
				tokens.add(name.toUpperCase());
				tokens.add(camel(name));
			}
		}
		// A row bound to a setting is handled where that setting is read.
		if (entry.feature_path && entry.feature_path.includes('.')) {
			const parts = entry.feature_path.split('.');
			const id = parts.pop();
			for (const token of entryTokens({
				kind: 'feature',
				path: entry.feature_path,
				id,
				section: parts.join('.')
			}))
				tokens.add(token);
		}
	}
	return [...tokens];
}

/**
 * The production file of one OS that spells an entry the most often.
 * @param {object} files Indexed files of that OS.
 * @param {string[]} tokens Entry spellings.
 * @returns {{file: string, files: number}|null} Owner and the count of files that spell it.
 */
function findOwner(files, tokens, kind) {
	const pools = [files.driver, files.shared];
	if (kind === 'action' || kind === 'layer') pools.push(files.generated);
	for (const pool of pools) {
		const hits = [];
		for (const file of pool) {
			let score = 0;
			for (const token of tokens) score += file.tokens.get(token) || 0;
			if (score > 0) hits.push({ file: file.rel, score });
		}
		if (hits.length) {
			hits.sort((a, b) => b.score - a.score || a.file.length - b.file.length);
			return { file: hits[0].file, files: hits.length };
		}
	}
	return null;
}

// =================================
// =================================
// ======= 2/ Catalogue rows =======
// =================================
// =================================

/** @param {string[]} keys Platform keys of the catalogue. @returns {Record<string, boolean>} Per OS. */
function availability(keys) {
	return Object.fromEntries(Object.entries(OS).map(([os, key]) => [os, keys.includes(key)]));
}

/**
 * Reads every user-facing entry of the catalogues with its per-OS availability
 * and, for each OS it leaves out or degrades, the reason key that explains it.
 * @param {object} catalogues Parsed catalogues.
 * @returns {Array<object>} Entries without owners.
 */
function catalogueEntries({ features, actions, layers, menu, hiddenReasons }) {
	const entries = [];
	for (const feature of features) {
		const available = availability(feature.platforms);
		const reasons = {};
		for (const os of Object.keys(OS)) if (!available[os]) reasons[os] = feature.reason_key || null;
		const degraded = {};
		for (const [os, key] of Object.entries(feature.degraded || {})) degraded[os] = key;
		entries.push({
			kind: 'feature',
			path: feature.path,
			id: feature.id,
			section: feature.section,
			label_key: feature.description_key,
			available,
			reasons,
			degraded
		});
	}
	for (const family of ['sg_actions', 'ax_actions']) {
		for (const [id, action] of Object.entries(actions[family])) {
			// A leading underscore marks a catalogue placeholder, never a bindable action.
			if (id.startsWith('_')) continue;
			const keys = action.platform === 'all' ? Object.values(OS) : action.platform.split(',');
			const available = availability(keys);
			const reasons = {};
			for (const [os, key] of Object.entries(OS))
				if (!available[os]) reasons[os] = action[`reason_${key}`] || null;
			entries.push({
				kind: 'action',
				path: `${family}.${id}`,
				id,
				label_key: `${family}.${id}`,
				available,
				reasons,
				degraded: {}
			});
		}
	}
	for (const family of ['actions', 'modifiers', 'source_kinds', 'parameters']) {
		for (const [id, entry] of Object.entries(layers[family] || {})) {
			const platforms =
				entry.platforms ||
				Object.keys(OS).filter((os) => entry[os] !== undefined || entry.all !== undefined);
			const available = Object.fromEntries(
				Object.keys(OS).map((os) => [os, platforms.includes(os)])
			);
			const reasons = {};
			for (const os of Object.keys(OS)) if (!available[os]) reasons[os] = entry.reason_key || null;
			entries.push({
				kind: 'layer',
				path: `layers.${family}.${id}`,
				id,
				label_key: `sg_actions.${id}`,
				available,
				reasons,
				degraded: {}
			});
		}
	}
	const featureByPath = new Map(features.map((feature) => [feature.path, feature]));
	for (const [section, rows] of Object.entries(menu)) {
		if (!Array.isArray(rows)) continue;
		for (const row of rows) {
			if (!MENU_ROW_TYPES.has(row.type)) continue;
			const id = row.id || row.path;
			// A feature row is drawn from each driver's generated manifest, which
			// holds only that driver's features: it inherits the feature's platforms.
			const drawn = row.type === 'feature' && !row.platforms ? featureByPath.get(row.path) : null;
			const keys = Array.isArray(row.platforms)
				? row.platforms
				: drawn
					? drawn.platforms
					: Object.values(OS);
			const available = availability(keys);
			const reasonKey =
				row.reason_key ||
				hiddenReasons[`${section}.${id}`] ||
				hiddenReasons[section] ||
				drawn?.reason_key ||
				null;
			const reasons = {};
			for (const os of Object.keys(OS)) if (!available[os]) reasons[os] = reasonKey;
			entries.push({
				kind: 'menu',
				path: `${section}.${id}`,
				id,
				command: row.command || null,
				feature_path: row.path || null,
				visibility: row.unavailable || 'hide',
				label_key: row.i18n || null,
				available,
				reasons,
				degraded: {}
			});
		}
	}
	return entries;
}

// ==============================
// ==============================
// ======= 3/ Table build =======
// ==============================
// ==============================

/**
 * Builds the table: one row per entry, one cell per OS.
 * @param {object} input Catalogues, sources index, parity declarations and locales.
 * @returns {Array<object>} Table rows.
 */
function buildTable({ catalogues, sources, parity }) {
	return catalogueEntries(catalogues).map((entry) => {
		const tokens = entryTokens(entry);
		const cells = {};
		for (const os of Object.keys(OS)) {
			if (!entry.available[os]) {
				cells[os] = { status: 'unavailable', reason_key: entry.reasons[os] };
				continue;
			}
			const found = findOwner(sources[os], tokens, entry.kind);
			const declared = found ? null : declaredOwner(parity, os, entry);
			cells[os] = {
				status: entry.degraded[os] ? 'degraded' : 'supported',
				reason_key: entry.degraded[os] || null,
				owner: found ? found.file : declared ? declared.file : null,
				owner_files: found ? found.files : declared ? 1 : 0,
				owner_rule: found ? 'spelled' : declared ? declared.rule : null
			};
		}
		return { ...entry, cells };
	});
}

/**
 * The owner platform_parity.toml declares for an entry no file spells: its own
 * entry (a trailing * matches a prefix), the generic reader of its section, then
 * the generic reader of its whole catalogue kind.
 * @param {object} parity Parsed platform_parity.toml.
 * @param {string} os OS name.
 * @param {object} entry Catalogue entry.
 * @returns {{file: string, token: string, rule: string}|null} Declared owner.
 */
function declaredOwner(parity, os, entry) {
	// A recorded gap is not covered by its section's or its kind's generic reader.
	if (parity.unowned?.[os]?.[entry.path]) return null;
	for (const [pattern, owner] of Object.entries(parity.owners?.[os] || {})) {
		const matches = pattern.endsWith('*')
			? entry.path.startsWith(pattern.slice(0, -1))
			: entry.path === pattern;
		if (matches) return { ...owner, rule: `owners.${os}."${pattern}"` };
	}
	if (entry.kind === 'feature') {
		const owner = parity.section_owners?.[os]?.[entry.section];
		if (owner) return { ...owner, rule: `section_owners.${os}."${entry.section}"` };
	}
	const owner = parity.kind_owners?.[os]?.[entry.kind];
	if (owner) return { ...owner, rule: `kind_owners.${os}.${entry.kind}` };
	return null;
}

// ===========================
// ===========================
// ======= 4/ The gate =======
// ===========================
// ===========================

/**
 * Checks the parity rules over a built table.
 * @param {Array<object>} table Rows from buildTable.
 * @param {{parity: object, locales: Record<string, object>, readSource: function}} context
 *   Declarations, every locale and a reader for declared owner files.
 * @returns {string[]} One message per violation.
 */
function validateTable(table, { parity, locales, readSource }) {
	const errors = [];
	const reasons = parity.reasons || {};
	const usedReasons = new Set();
	const usedRules = new Set();
	const localeNames = Object.keys(locales);
	if (localeNames.length !== 21) errors.push(`expected 21 locales, found ${localeNames.length}`);
	for (const [key, entry] of Object.entries(reasons)) {
		if (!Object.hasOwn(REASON_KINDS, entry.kind))
			errors.push(`platform_parity.toml reason ${key} has unknown kind ${entry.kind}`);
		if (typeof entry.technical !== 'string' || entry.technical.trim().length < 20)
			errors.push(`platform_parity.toml reason ${key} needs a technical explanation`);
	}
	const featurePaths = new Map(
		table.filter((row) => row.kind === 'feature').map((row) => [row.path, row])
	);
	for (const row of table) {
		for (const [os, cell] of Object.entries(row.cells)) {
			if (!STATUSES.includes(cell.status)) errors.push(`${row.path} ${os}: bad status`);
			if (cell.status !== 'supported') {
				const key = cell.reason_key;
				if (!key) {
					errors.push(`${row.kind} ${row.path} is ${cell.status} on ${os} without a reason key`);
					continue;
				}
				usedReasons.add(key);
				if (!reasons[key])
					errors.push(
						`${row.kind} ${row.path} on ${os}: reason ${key} has no kind and technical text in platform_parity.toml`
					);
				const missing = localeNames.filter(
					(lang) => typeof locales[lang][key] !== 'string' || locales[lang][key].trim() === ''
				);
				if (missing.length)
					errors.push(
						`${row.kind} ${row.path} on ${os}: menu reason ${key} is missing in ${missing.join(', ')}`
					);
			}
			const ledger = parity.unowned?.[os]?.[row.path];
			if (cell.status !== 'unavailable' && !cell.owner && !ledger)
				errors.push(
					`${row.kind} ${row.path} is ${cell.status} on ${os} but no ${os} production file spells it; ` +
						`fix the declaration or name its owner in platform_parity.toml`
				);
			if (ledger && (cell.status === 'unavailable' || cell.owner))
				errors.push(
					`platform_parity.toml unowned ${os} ${row.path} is stale: ` +
						(cell.owner ? `${cell.owner} owns it now` : 'the cell is unavailable')
				);
			if (ledger && !/^PPT-\d{2}$/.test(ledger.finding || ''))
				errors.push(`platform_parity.toml unowned ${os} ${row.path} names no PPT-nn finding`);
			if (cell.owner_rule) usedRules.add(cell.owner_rule);
		}
		// A menu row bound to a feature shows on an OS only where the feature is, or greyed with its reason.
		if (row.kind === 'menu' && row.feature_path && featurePaths.has(row.feature_path)) {
			const feature = featurePaths.get(row.feature_path);
			for (const os of Object.keys(OS)) {
				if (row.cells[os].status === 'unavailable') continue;
				if (feature.cells[os].status === 'unavailable')
					errors.push(
						`menu row ${row.path} shows on ${os} where its feature ${row.feature_path} is unavailable`
					);
			}
		}
	}
	for (const key of Object.keys(reasons))
		if (!usedReasons.has(key)) errors.push(`platform_parity.toml reason ${key} explains no cell`);
	// A declared owner must serve a cell no file spells, exist, and hold its token in code.
	for (const table_name of ['owners', 'section_owners', 'kind_owners']) {
		for (const [os, owners] of Object.entries(parity[table_name] || {})) {
			if (!Object.hasOwn(OS, os)) {
				errors.push(`platform_parity.toml ${table_name} has unknown OS ${os}`);
				continue;
			}
			for (const [pattern, declared] of Object.entries(owners)) {
				const rule =
					table_name === 'kind_owners'
						? `${table_name}.${os}.${pattern}`
						: `${table_name}.${os}."${pattern}"`;
				if (!usedRules.has(rule))
					errors.push(`platform_parity.toml ${rule} is stale: no unspelled cell uses it`);
				const source = readSource(declared.file);
				if (source === null)
					errors.push(`platform_parity.toml ${rule}: ${declared.file} does not exist`);
				else if (!declared.token || !codeLines(source).includes(declared.token))
					errors.push(
						`platform_parity.toml ${rule}: ${declared.file} has no code line with ${declared.token}`
					);
			}
		}
	}
	return errors;
}

/**
 * Counts cells per OS and status.
 * @param {Array<object>} table Rows from buildTable.
 * @returns {Record<string, Record<string, number>>} Counts.
 */
function summarize(table) {
	const counts = {};
	for (const os of Object.keys(OS)) {
		counts[os] = Object.fromEntries(STATUSES.map((status) => [status, 0]));
		for (const row of table) counts[os][row.cells[os].status]++;
	}
	return counts;
}

module.exports = {
	OS,
	REASON_KINDS,
	STATUSES,
	buildTable,
	catalogueEntries,
	entryTokens,
	loadSourceIndex,
	summarize,
	tokenCounts,
	validateTable
};
