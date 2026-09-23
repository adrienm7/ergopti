// tools/test/test-layouts-defaults-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Layout Registry Location Single Source
 * DESCRIPTION:
 * Pins where every driver downloads keyboard layouts from to one file,
 * _shared/modules/layouts/defaults.json, and that file to the real repository
 * folder the index is committed in.
 *
 * WHY:
 * The registry URL is built from four facts (owner, repo, branch, folder). A
 * driver that retypes any of them keeps working until the folder moves or the
 * repository is renamed, then downloads a 404 on one OS only. So:
 *   1. the declared folder must exist and hold the declared index file;
 *   2. the URL template must take owner/repo from the updater defaults (the
 *      repository's one owner/repo source) instead of repeating them;
 *   3. no driver source outside tests may spell the raw-content host or the
 *      folder path, and each registry client must read defaults.json.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DEFAULTS_PATH = path.join(SP, '_shared', 'modules', 'layouts', 'defaults.json');
const UPDATER_DEFAULTS_PATH = path.join(SP, '_shared', 'modules', 'updater', 'defaults.json');

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

/** Lists driver sources, skipping tests, vendored code and generated output. */
function driverSources(dir, extensions, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (['tests', 'vendor', 'node_modules', '_generated'].includes(entry.name)) continue;
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) driverSources(full, extensions, out);
		else if (extensions.includes(path.extname(entry.name))) out.push(full);
	}
	return out;
}

/** Drops comments so an explanatory note cannot hide or fake a literal. */
function stripComments(source, extension) {
	if (extension === '.ahk') {
		return source
			.replace(/\/\*[\s\S]*?\*\//g, '')
			.split('\n')
			.map((line) => line.replace(/(^|\s);.*$/, '$1'))
			.join('\n');
	}
	return source.replace(/--\[\[[\s\S]*?\]\]/g, '').replace(/--.*$/gm, '');
}

const defaults = JSON.parse(fs.readFileSync(DEFAULTS_PATH, 'utf8'));
const registry = defaults.registry;
const updater = JSON.parse(fs.readFileSync(UPDATER_DEFAULTS_PATH, 'utf8'));

console.log('Layout registry location single source');

check('the declared folder exists and holds the declared index', () => {
	const folder = path.join(ROOT, ...registry.folder.split('/'));
	assert.ok(fs.statSync(folder).isDirectory(), `${registry.folder} is not a folder`);
	assert.ok(fs.existsSync(path.join(folder, registry.index_file)), `${registry.index_file} is missing`);
});

check('the URL template takes every part from a placeholder', () => {
	for (const part of ['{owner}', '{repo}', '{branch}', '{folder}', '{path}']) {
		assert.ok(registry.raw_url_template.includes(part), `raw_url_template lacks ${part}`);
	}
	assert.ok(registry.raw_url_template.startsWith('https://'), 'the registry must be fetched over HTTPS');
	const text = fs.readFileSync(DEFAULTS_PATH, 'utf8');
	assert.ok(!text.includes(`"${updater.github.owner}"`), 'owner is repeated instead of read from the updater defaults');
	assert.ok(!text.includes(`"${updater.github.repo}"`), 'repo is repeated instead of read from the updater defaults');
});

check('the scalars are positive and the branch is a plain name', () => {
	assert.ok(Number.isInteger(registry.download_timeout_sec) && registry.download_timeout_sec > 0);
	assert.ok(Number.isInteger(registry.max_file_bytes) && registry.max_file_bytes > 0);
	assert.match(registry.branch, /^[A-Za-z0-9._-]+$/);
	// A folder name inside the configuration folder, never a path out of it.
	assert.match(registry.local_folder, /^[A-Za-z0-9_-]+$/);
});

check('no driver source spells the registry host or folder', () => {
	const files = [
		...driverSources(path.join(SP, 'windows'), ['.ahk']),
		...driverSources(path.join(SP, 'macos'), ['.lua']),
		...driverSources(path.join(SP, 'linux'), ['.lua']),
		...driverSources(path.join(SP, '_shared', 'lua'), ['.lua'])
	];
	assert.ok(files.length > 300, `scanned only ${files.length} driver files`);
	const offenders = [];
	for (const file of files) {
		const code = stripComments(fs.readFileSync(file, 'utf8'), path.extname(file));
		if (code.includes('raw.githubusercontent.com') || code.includes(registry.folder)) {
			offenders.push(path.relative(ROOT, file));
		}
	}
	assert.deepStrictEqual(offenders, [], 'these files retype the registry location');
});

check('every registry client reads the URL template and owner/repo from the shared defaults', () => {
	const files = [
		...driverSources(path.join(SP, 'windows'), ['.ahk']),
		...driverSources(path.join(SP, 'macos'), ['.lua']),
		...driverSources(path.join(SP, 'linux'), ['.lua']),
		...driverSources(path.join(SP, '_shared', 'lua'), ['.lua'])
	];
	const clients = files.filter((file) =>
		stripComments(fs.readFileSync(file, 'utf8'), path.extname(file)).includes('raw_url_template')
	);
	assert.ok(clients.length >= 1, 'no driver builds a registry URL');
	for (const file of clients) {
		const code = stripComments(fs.readFileSync(file, 'utf8'), path.extname(file)).replace(/\\\\?/g, '/');
		const rel = path.relative(ROOT, file);
		assert.ok(code.includes('modules/layouts/defaults.json'), `${rel} does not read the layouts defaults`);
		assert.ok(code.includes('modules/updater/defaults.json'), `${rel} does not read owner/repo from the updater defaults`);
	}
});

if (failures > 0) process.exit(1);
console.log('All layout registry location checks passed.');
