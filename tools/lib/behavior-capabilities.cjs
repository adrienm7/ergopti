// tools/lib/behavior-capabilities.cjs

/**
 * ============================================================================
 * MODULE: Reviewed Behavior Capabilities
 * DESCRIPTION:
 * Validates explicit behavior declarations and their conservative source-review
 * receipts. A receipt proves reviewed bytes, never native application behavior.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const SYSTEMS = ['windows', 'macos', 'linux'];
const CATALOGUE = 'static/ergopti_plus/_shared/settings/data/features/behaviors.json';

/** Reject unrecognized fields instead of silently dropping declaration mistakes. */
function keys(value, expected, label) {
	if (!value || typeof value !== 'object' || Array.isArray(value))
		throw new Error(`Invalid behavior ${label}`);
	if (
		Object.keys(value).length !== expected.length ||
		Object.keys(value).some((key) => !expected.includes(key))
	)
		throw new Error(`Invalid behavior ${label} fields`);
}

/** Validate reviewed owners and project only supported display fields. */
function projectBehaviors(catalogue, root, locales) {
	if (!locales || !locales.en || !locales.fr)
		throw new Error('Missing behavior translation locales');
	keys(
		catalogue,
		['schema_version', 'audited_sha', 'reviewed_at', 'owners', 'behaviors'],
		'catalogue'
	);
	if (
		catalogue.schema_version !== 1 ||
		!/^[a-f0-9]{40}$/.test(catalogue.audited_sha) ||
		!/^\d{4}-\d{2}-\d{2}$/.test(catalogue.reviewed_at) ||
		!Array.isArray(catalogue.owners) ||
		!catalogue.owners.length ||
		!Array.isArray(catalogue.behaviors) ||
		!catalogue.behaviors.length
	)
		throw new Error('Invalid behavior catalogue metadata');
	const owners = new Map();
	for (const owner of catalogue.owners) {
		keys(owner, ['id', 'platform', 'file', 'symbol', 'sha256'], 'owner');
		if (
			typeof owner.id !== 'string' ||
			!owner.id ||
			owners.has(owner.id) ||
			!SYSTEMS.includes(owner.platform) ||
			typeof owner.file !== 'string' ||
			owner.file.includes('\\') ||
			owner.file.split('/').some((part) => part === '..' || part === '.') ||
			!owner.file.startsWith(`static/ergopti_plus/${owner.platform}/`) ||
			typeof owner.symbol !== 'string' ||
			!owner.symbol ||
			!/^[a-f0-9]{64}$/.test(owner.sha256)
		)
			throw new Error('Invalid or duplicate behavior owner');
		const file = path.join(root, owner.file);
		if (!fs.existsSync(file) || !fs.lstatSync(file).isFile())
			throw new Error(`Missing behavior owner: ${owner.file}`);
		const source = fs.readFileSync(file);
		if (
			!source.toString('utf8').includes(owner.symbol) ||
			crypto.createHash('sha256').update(source).digest('hex') !== owner.sha256
		)
			throw new Error(`Behavior owner needs source review: ${owner.file}`);
		owners.set(owner.id, owner);
	}
	const seen = new Set();
	const used = new Set();
	function translated(key) {
		if (
			typeof key !== 'string' ||
			!key ||
			Object.values(locales).some(
				(locale) => !locale || typeof locale[key] !== 'string' || !locale[key].trim()
			)
		)
			throw new Error(`Missing behavior translation: ${key}`);
		return Object.fromEntries(Object.entries(locales).map(([lang, locale]) => [lang, locale[key]]));
	}
	const rows = catalogue.behaviors.map((behavior) => {
		keys(behavior, ['id', 'label_key', 'platforms'], 'entry');
		if (
			typeof behavior.id !== 'string' ||
			!/^[a-z][a-z0-9_.]+$/.test(behavior.id) ||
			seen.has(behavior.id)
		)
			throw new Error('Invalid or duplicate behavior id');
		seen.add(behavior.id);
		keys(behavior.platforms, SYSTEMS, 'platforms');
		const platforms = {};
		const notes = {};
		const evidence = {};
		for (const os of SYSTEMS) {
			const state = behavior.platforms[os];
			keys(state, ['declared', 'note_key', 'owners'], 'platform state');
			if (
				typeof state.declared !== 'boolean' ||
				!Array.isArray(state.owners) ||
				!state.owners.length ||
				new Set(state.owners).size !== state.owners.length
			)
				throw new Error(`Invalid behavior state: ${behavior.id} ${os}`);
			platforms[os] = state.declared;
			notes[os] = translated(state.note_key);
			evidence[os] = state.owners.map((id) => {
				const owner = owners.get(id);
				if (!owner || owner.platform !== os) throw new Error(`Unknown behavior owner: ${id}`);
				used.add(id);
				return { file: owner.file, symbol: owner.symbol, sha256: owner.sha256 };
			});
		}
		return {
			path: behavior.id,
			labels: translated(behavior.label_key),
			platforms,
			notes,
			evidence
		};
	});
	if (used.size !== owners.size) throw new Error('Unused behavior owner');
	return rows;
}

/** Read the one authored catalogue without creating or updating source receipts. */
function loadBehaviors(root, locales) {
	return projectBehaviors(
		JSON.parse(fs.readFileSync(path.join(root, CATALOGUE), 'utf8')),
		root,
		locales
	);
}

module.exports = { CATALOGUE, projectBehaviors, loadBehaviors };
