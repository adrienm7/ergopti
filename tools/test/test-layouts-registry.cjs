// tools/test/test-layouts-registry.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard-Layout Registry Gate
 * DESCRIPTION:
 * Guards the layout registry folder (static/layouts/registry): one
 * <id>/<id>.keylayout per layout, its meta.toml, and the committed index.json
 * that the drivers download to discover layouts and verify what they fetch.
 *
 * WHY:
 * The index is the only thing a driver trusts before installing or emulating a
 * layout: a stale checksum makes every download fail its verification, and a
 * stale entry advertises a layout whose file is not there. So this gate:
 *   1. regenerates the index in memory and requires the committed file to be
 *      byte-identical (drift), and requires two builds to agree (determinism);
 *   2. recomputes every checksum and size from the files themselves, without
 *      going through the builder, so a builder bug cannot bless itself;
 *   3. proves the meta.toml validator rejects each malformed shape it claims
 *      to reject, so a green schema check is not a validator that accepts all;
 *   4. pins vendored third-party files to the digest their upstream release
 *      publishes, and the Ergopti copies to the macOS bundle they come from.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const {
	REGISTRY_DIR,
	INDEX_PATH,
	buildIndex,
	validateMeta,
	validateRegistry
} = require('../build/build-layouts-index.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BUNDLES_DIR = path.join(ROOT, 'static', 'ergopti', 'macos', 'bundles');

let failures = 0;
let passes = 0;

function check(name, fn) {
	try {
		fn();
		passes += 1;
		console.log(`  ok   ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${err.message.split('\n').join('\n       ')}`);
	}
}

function sha256(buffer) {
	return crypto.createHash('sha256').update(buffer).digest('hex');
}

/** A meta record every rule accepts, cloned so each negative case mutates its own copy. */
function validMeta() {
	return {
		name: 'Sample',
		version: '1.2.3',
		author: 'Someone',
		licence: 'MIT',
		homepage: 'https://example.org',
		languages: ['fr', 'en'],
		variants: [],
		source_url: 'https://example.org/sample.keylayout',
		platforms: ['linux', 'macos', 'windows'],
		keycode_convention: 'iso'
	};
}

const committed = JSON.parse(fs.readFileSync(INDEX_PATH, 'utf8'));
const entries = committed.layouts;

console.log('Layout registry');

check('the registry holds Ergopti and Ergo-L (subject floor)', () => {
	assert.ok(Array.isArray(entries), 'index.json has no layouts array');
	assert.ok(entries.length >= 5, `expected at least 5 layouts, found ${entries.length}`);
	const ids = entries.map((e) => e.id);
	for (const id of ['ergopti', 'ergopti_plus', 'ergol']) {
		assert.ok(ids.includes(id), `${id} is missing from index.json`);
	}
});

check('index.json is in sync with the meta.toml files (run npm run build:layouts-index)', () => {
	const expected = buildIndex(REGISTRY_DIR).text;
	const actual = fs.readFileSync(INDEX_PATH, 'utf8');
	assert.strictEqual(actual, expected, 'index.json drifted from the registry folder');
});

check('the index build is deterministic and sorted by id', () => {
	const first = buildIndex(REGISTRY_DIR).text;
	const second = buildIndex(REGISTRY_DIR).text;
	assert.strictEqual(first, second, 'two builds of the same folder differ');
	const ids = entries.map((e) => e.id);
	assert.deepStrictEqual(ids, [...ids].sort(), 'entries are not sorted by id');
});

check('every checksum and size matches the committed .keylayout bytes', () => {
	for (const entry of entries) {
		const file = path.join(REGISTRY_DIR, ...entry.file.split('/'));
		assert.strictEqual(entry.file, `${entry.id}/${entry.id}.keylayout`, `${entry.id}: unexpected file path`);
		const bytes = fs.readFileSync(file);
		assert.strictEqual(sha256(bytes), entry.sha256, `${entry.id}: sha256 mismatch`);
		assert.strictEqual(bytes.length, entry.size, `${entry.id}: size mismatch`);
		assert.ok(!bytes.includes(0x0d), `${entry.id}: a CR byte would make the served file differ from the checkout`);
		assert.ok(!(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf), `${entry.id}: BOM`);
	}
});

check('each registry folder holds exactly one .keylayout named after its id', () => {
	const folders = fs.readdirSync(REGISTRY_DIR, { withFileTypes: true }).filter((d) => d.isDirectory());
	assert.strictEqual(folders.length, entries.length, 'a folder is missing from the index or vice versa');
	for (const folder of folders) {
		const layouts = fs.readdirSync(path.join(REGISTRY_DIR, folder.name)).filter((f) => f.endsWith('.keylayout'));
		assert.deepStrictEqual(layouts, [`${folder.name}.keylayout`], `${folder.name}: one layout = one .keylayout`);
	}
});

check('vendored layouts are byte-identical to their upstream release asset', () => {
	const vendored = entries.filter((e) => e.source_sha256);
	assert.ok(vendored.length >= 1, 'no vendored layout declares source_sha256');
	for (const entry of vendored) {
		assert.strictEqual(entry.sha256, entry.source_sha256, `${entry.id} was modified after vendoring`);
	}
});

check('third-party licences ship next to their layout', () => {
	const foreign = entries.filter((e) => e.licence !== 'MIT');
	assert.ok(foreign.length >= 1, 'expected at least one non-MIT layout (Ergo-L)');
	for (const entry of foreign) {
		assert.ok(entry.licence_file, `${entry.id} (${entry.licence}) names no licence_file`);
		const licence = path.join(REGISTRY_DIR, entry.id, entry.licence_file);
		assert.ok(fs.existsSync(licence), `${entry.id}: ${entry.licence_file} is missing`);
		assert.ok(fs.readFileSync(licence, 'utf8').trim().length > 0, `${entry.id}: empty licence file`);
	}
});

check('the Ergopti entries are the latest macOS bundle layouts', () => {
	const bundles = fs
		.readdirSync(BUNDLES_DIR)
		.map((name) => /^Ergopti_v(\d+)\.(\d+)\.(\d+)\.bundle$/.exec(name))
		.filter(Boolean)
		.sort((a, b) => a[1] - b[1] || a[2] - b[2] || a[3] - b[3]);
	const latest = bundles[bundles.length - 1];
	assert.ok(latest, 'no Ergopti bundle found');
	const version = `${latest[1]}.${latest[2]}.${latest[3]}`;
	const stem = `Ergopti_v${latest[1]}_${latest[2]}_${latest[3]}`;
	const suffixes = { ergopti: '', ergopti_ansi: '_ansi', ergopti_plus: '_plus', ergopti_plus_ansi: '_plus_ansi' };
	for (const [id, suffix] of Object.entries(suffixes)) {
		const entry = entries.find((e) => e.id === id);
		assert.ok(entry, `${id} is not registered`);
		assert.strictEqual(entry.version, version, `${id} is not at the latest bundle version`);
		const bundleFile = path.join(BUNDLES_DIR, latest[0], 'Contents', 'Resources', `${stem}${suffix}.keylayout`);
		const registryFile = path.join(REGISTRY_DIR, id, `${id}.keylayout`);
		assert.ok(
			fs.readFileSync(bundleFile).equals(fs.readFileSync(registryFile)),
			`${id}.keylayout differs from ${path.basename(bundleFile)}`
		);
	}
});

check('a .keylayout-only change selects the gate that runs this file', () => {
	const { selectGates } = require('./verify-change.cjs');
	for (const entry of entries) {
		const gates = selectGates([`static/layouts/registry/${entry.file}`]);
		assert.ok(gates.has('js'), `editing ${entry.file} would not run the registry checksum gate`);
	}
});

check('the meta.toml validator accepts a complete record', () => {
	assert.deepStrictEqual(validateMeta('sample', validMeta(), () => true), []);
});

check('the meta.toml validator rejects every malformed shape', () => {
	const cases = [
		['missing name', (m) => delete m.name],
		['unknown key', (m) => (m.colour = 'blue')],
		['non-semver version', (m) => (m.version = 'latest')],
		['plain-http homepage', (m) => (m.homepage = 'http://example.org')],
		['empty languages', (m) => (m.languages = [])],
		['malformed language', (m) => (m.languages = ['French'])],
		['unknown platform', (m) => (m.platforms = ['android'])],
		['duplicate platform', (m) => (m.platforms = ['linux', 'linux'])],
		['unknown keycode convention', (m) => (m.keycode_convention = 'jis')],
		['malformed source digest', (m) => (m.source_sha256 = 'abc')],
		['non-MIT licence without its file', (m) => (m.licence = 'WTFPL')],
		['licence file that does not exist', (m) => (m.licence_file = 'MISSING')],
		['variant that is not an id', (m) => (m.variants = ['Not An Id'])]
	];
	for (const [label, mutate] of cases) {
		const meta = validMeta();
		mutate(meta);
		const errors = validateMeta('sample', meta, (name) => name !== 'MISSING');
		assert.ok(errors.length > 0, `the validator accepted a record with ${label}`);
	}
});

check('the registry validator rejects asymmetric and dangling variants', () => {
	const a = { ...validMeta(), variants: ['b'] };
	const b = { ...validMeta(), variants: [] };
	assert.ok(validateRegistry(new Map([['a', a], ['b', b]])).length > 0, 'asymmetric variants accepted');
	const c = { ...validMeta(), variants: ['ghost'] };
	assert.ok(validateRegistry(new Map([['c', c]])).length > 0, 'dangling variant accepted');
	const d = { ...validMeta(), variants: ['d'] };
	assert.ok(validateRegistry(new Map([['d', d]])).length > 0, 'self variant accepted');
});

console.log(`\n${passes} passed, ${failures} failed`);
if (failures > 0) process.exit(1);
