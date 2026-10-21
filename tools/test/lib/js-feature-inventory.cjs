// tools/test/lib/js-feature-inventory.cjs

/** Load the literal, ordered JavaScript check inventory without executing checks. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');

function requireInventory(condition, message) {
	if (!condition) throw new Error(`Invalid JS feature inventory: ${message}`);
}

function closedKeys(value, required, optional = []) {
	requireInventory(
		value !== null && typeof value === 'object' && !Array.isArray(value),
		'object required'
	);
	const keys = Object.keys(value);
	requireInventory(
		required.every((key) => keys.includes(key)),
		'missing field'
	);
	requireInventory(
		keys.every((key) => [...required, ...optional].includes(key)),
		'unknown field'
	);
}

function text(value) {
	return typeof value === 'string' && value.length > 0 && !/[\r\n\0]/.test(value);
}

function canonical(value) {
	if (Array.isArray(value)) return value.map(canonical);
	if (value !== null && typeof value === 'object')
		return Object.fromEntries(
			Object.keys(value)
				.sort()
				.map((key) => [key, canonical(value[key])])
		);
	return value;
}

/** Return all platform-declared checks; command tokens remain literal until dispatch. */
function loadInventory(root) {
	const directory = path.join(root, 'tools', 'test', 'features');
	const entries = fs
		.readdirSync(directory, { withFileTypes: true })
		.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
	requireInventory(entries.length > 0, 'empty feature directory');
	const features = [];
	const manifests = [];
	const checks = [];
	const ids = new Set();
	const names = new Set();
	const ordinals = new Set();
	const commands = new Set();
	const foldedFeatures = new Set();
	for (const entry of entries) {
		requireInventory(
			entry.isDirectory() && !entry.isSymbolicLink(),
			'orphan file or linked feature'
		);
		requireInventory(
			/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(entry.name),
			'invalid feature identity'
		);
		requireInventory(!foldedFeatures.has(entry.name.toLowerCase()), 'duplicate feature identity');
		foldedFeatures.add(entry.name.toLowerCase());
		const children = fs.readdirSync(path.join(directory, entry.name), { withFileTypes: true });
		requireInventory(
			children.length === 1 &&
				children[0].name === 'suite.json' &&
				children[0].isFile() &&
				!children[0].isSymbolicLink(),
			'missing or orphan feature manifest'
		);
		const manifest = JSON.parse(
			fs.readFileSync(path.join(directory, entry.name, 'suite.json'), 'utf8')
		);
		closedKeys(manifest, ['schema_version', 'feature', 'checks']);
		requireInventory(
			manifest.schema_version === 1 && manifest.feature === entry.name,
			'wrong feature schema or identity'
		);
		requireInventory(
			Array.isArray(manifest.checks) && manifest.checks.length > 0,
			'empty feature checks'
		);
		let previousOrdinal = 0;
		for (const check of manifest.checks) {
			closedKeys(check, ['id', 'ordinal', 'name', 'cmd', 'args', 'repro'], ['platforms']);
			requireInventory(
				text(check.id) && /^[a-z][a-z0-9-]*$/.test(check.id) && !ids.has(check.id),
				'duplicate or invalid check identity'
			);
			requireInventory(
				Number.isSafeInteger(check.ordinal) &&
					check.ordinal > previousOrdinal &&
					!ordinals.has(check.ordinal),
				'duplicate or unordered global ordinal'
			);
			requireInventory(
				text(check.name) && !names.has(check.name),
				'duplicate or invalid check name'
			);
			// run-js-suite.cjs prints check names in every run; the uppercase
			// marker must stay unique to its summary of cases that did not run.
			requireInventory(
				!check.name.includes('NOT EXECUTED'),
				'a check name cannot carry the NOT EXECUTED summary marker'
			);
			requireInventory(
				['node', 'npm', '$NODE_EXECUTABLE'].includes(check.cmd),
				'unknown command owner'
			);
			requireInventory(
				Array.isArray(check.args) && check.args.length > 0 && check.args.every(text),
				'empty or invalid command arguments'
			);
			requireInventory(text(check.repro), 'empty reproduction command');
			const commandIdentity = JSON.stringify([
				check.cmd === '$NODE_EXECUTABLE' ? 'node' : check.cmd,
				check.args
			]);
			requireInventory(!commands.has(commandIdentity), 'duplicate command identity');
			commands.add(commandIdentity);
			if (Object.hasOwn(check, 'platforms'))
				requireInventory(
					Array.isArray(check.platforms) &&
						check.platforms.length > 0 &&
						new Set(check.platforms).size === check.platforms.length &&
						check.platforms.every((platform) => ['linux', 'win32', 'darwin'].includes(platform)),
					'invalid platform projection'
				);
			ids.add(check.id);
			names.add(check.name);
			ordinals.add(check.ordinal);
			previousOrdinal = check.ordinal;
			checks.push({
				...check,
				args: [...check.args],
				...(check.platforms ? { platforms: [...check.platforms] } : {}),
				feature: manifest.feature
			});
		}
		features.push(manifest.feature);
		manifests.push(manifest);
	}
	checks.sort((a, b) => a.ordinal - b.ordinal);
	requireInventory(
		checks.every((check, index) => check.ordinal === index + 1),
		'missing global ordinal'
	);
	const digest = createHash('sha256')
		.update(JSON.stringify(canonical(manifests)))
		.digest('hex');
	return { features, checks, digest };
}

/** Select fresh check records in original global order for one execution platform. */
function selectFeature(inventory, feature, platform = process.platform) {
	requireInventory(['linux', 'win32', 'darwin'].includes(platform), 'unknown execution platform');
	requireInventory(
		feature === null || (typeof feature === 'string' && inventory.features.includes(feature)),
		'unknown or empty feature selector'
	);
	const checks = inventory.checks.filter(
		(check) =>
			(feature === null || check.feature === feature) &&
			(!check.platforms || check.platforms.includes(platform))
	);
	requireInventory(checks.length > 0, 'empty selected feature');
	return checks.map((check) => ({
		...check,
		args: [...check.args],
		...(check.platforms ? { platforms: [...check.platforms] } : {})
	}));
}

module.exports = { loadInventory, selectFeature };
