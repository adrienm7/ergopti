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
const os = require('os');

const {
	REGISTRY_DIR,
	INDEX_PATH,
	buildIndex,
	validateMeta,
	validateRegistry,
	validateKeylayout,
	validateExtensionManifest
} = require('../build/build-layouts-index.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BUNDLES_DIR = path.join(ROOT, 'static', 'ergopti', 'macos', 'bundles');
const LAYOUT_DEFAULTS = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'layouts', 'defaults.json'),
		'utf8'
	)
);

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
		family: 'sample',
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
		assert.strictEqual(
			entry.file,
			`${entry.id}/${entry.id}.keylayout`,
			`${entry.id}: unexpected file path`
		);
		const bytes = fs.readFileSync(file);
		assert.strictEqual(sha256(bytes), entry.sha256, `${entry.id}: sha256 mismatch`);
		assert.strictEqual(bytes.length, entry.size, `${entry.id}: size mismatch`);
		assert.ok(
			!bytes.includes(0x0d),
			`${entry.id}: a CR byte would make the served file differ from the checkout`
		);
		assert.ok(!(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf), `${entry.id}: BOM`);
	}
});

check('each registry folder holds exactly one .keylayout named after its id', () => {
	const folders = fs
		.readdirSync(REGISTRY_DIR, { withFileTypes: true })
		.filter((d) => d.isDirectory());
	assert.strictEqual(
		folders.length,
		entries.length,
		'a folder is missing from the index or vice versa'
	);
	for (const folder of folders) {
		const layouts = fs
			.readdirSync(path.join(REGISTRY_DIR, folder.name))
			.filter((f) => f.endsWith('.keylayout'));
		assert.deepStrictEqual(
			layouts,
			[`${folder.name}.keylayout`],
			`${folder.name}: one layout = one .keylayout`
		);
	}
});

// The drivers switch the Ergopti-only features off while another layout is
// active, so which layouts are Ergopti must be data every driver can read.
check('every layout names its family and the Ergopti layouts are the Ergopti family', () => {
	const ergoptiFamily = LAYOUT_DEFAULTS.registry.ergopti_family;
	assert.match(
		String(ergoptiFamily),
		/^[a-z][a-z0-9_]*$/,
		'defaults.json declares no ergopti_family'
	);
	const byId = new Map(entries.map((e) => [e.id, e]));
	for (const entry of entries) {
		assert.match(String(entry.family), /^[a-z][a-z0-9_]*$/, `${entry.id} declares no family`);
		for (const variant of entry.variants) {
			assert.strictEqual(
				byId.get(variant).family,
				entry.family,
				`${entry.id} and its variant ${variant} disagree about their family`
			);
		}
	}
	const ergopti = entries
		.filter((e) => e.family === ergoptiFamily)
		.map((e) => e.id)
		.sort();
	assert.deepStrictEqual(ergopti, ['ergopti', 'ergopti_ansi', 'ergopti_plus', 'ergopti_plus_ansi']);
	assert.notStrictEqual(byId.get('ergol').family, ergoptiFamily, 'Ergo-L is not an Ergopti layout');
});

// macOS lists, selects and removes an installed .keylayout under the name its
// <keyboard> element declares, so the index publishes it as the file says.
check('every entry publishes the keyboard name its .keylayout declares', () => {
	for (const entry of entries) {
		const text = fs.readFileSync(path.join(REGISTRY_DIR, ...entry.file.split('/')), 'utf8');
		const declared = /<keyboard\b[^>]*\sname="([^"]+)"/.exec(text);
		assert.ok(declared, `${entry.id}: the .keylayout declares no keyboard name`);
		assert.strictEqual(
			entry.keyboard_name,
			declared[1],
			`${entry.id}: keyboard_name differs from the file`
		);
	}
	const unnamed = Buffer.from(
		'<keyboard group="0" id="1"><layouts><modifierMap><keyMapSet><keyMap index="0">'
	);
	assert.ok(
		validateKeylayout('unnamed', unnamed).some((e) => e.includes('declares no name')),
		'a nameless layout was accepted'
	);
	const names = entries.map((e) => e.keyboard_name);
	assert.strictEqual(
		new Set(names).size,
		names.length,
		'two layouts would install under one input-source name'
	);
});

check('vendored layouts are byte-identical to their upstream release asset', () => {
	const vendored = entries.filter((e) => e.source_sha256);
	assert.ok(vendored.length >= 1, 'no vendored layout declares source_sha256');
	for (const entry of vendored) {
		assert.strictEqual(
			entry.sha256,
			entry.source_sha256,
			`${entry.id} was modified after vendoring`
		);
	}
});

check('third-party licences ship next to their layout', () => {
	const foreign = entries.filter((e) => e.licence !== 'MIT');
	assert.ok(foreign.length >= 1, 'expected at least one non-MIT layout (Ergo-L)');
	for (const entry of foreign) {
		assert.ok(entry.licence_file, `${entry.id} (${entry.licence}) names no licence_file`);
		const licence = path.join(REGISTRY_DIR, entry.id, entry.licence_file);
		assert.ok(fs.existsSync(licence), `${entry.id}: ${entry.licence_file} is missing`);
		assert.ok(
			fs.readFileSync(licence, 'utf8').trim().length > 0,
			`${entry.id}: empty licence file`
		);
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
	const suffixes = {
		ergopti: '',
		ergopti_ansi: '_ansi',
		ergopti_plus: '_plus',
		ergopti_plus_ansi: '_plus_ansi'
	};
	for (const [id, suffix] of Object.entries(suffixes)) {
		const entry = entries.find((e) => e.id === id);
		assert.ok(entry, `${id} is not registered`);
		assert.strictEqual(entry.version, version, `${id} is not at the latest bundle version`);
		const bundleFile = path.join(
			BUNDLES_DIR,
			latest[0],
			'Contents',
			'Resources',
			`${stem}${suffix}.keylayout`
		);
		const registryFile = path.join(REGISTRY_DIR, id, `${id}.keylayout`);
		assert.ok(
			fs.readFileSync(bundleFile).equals(fs.readFileSync(registryFile)),
			`${id}.keylayout differs from ${path.basename(bundleFile)}`
		);
	}
});

check('a .keylayout-only change selects the registry and XKB conversion gates', () => {
	const { selectGates, GATE_COMMANDS } = require('./verify-change.cjs');
	assert.ok(GATE_COMMANDS['xkb-python'], 'the XKB Python gate has no command');
	for (const entry of entries) {
		const gates = selectGates([`static/layouts/registry/${entry.file}`]);
		assert.ok(gates.has('js'), `editing ${entry.file} would not run the registry checksum gate`);
		assert.ok(gates.has('xkb-python'), `editing ${entry.file} would not re-run its XKB conversion`);
	}
	for (const file of [
		'static/ergopti/linux/xkb_generation/keylayout_to_xkb.py',
		'static/ergopti_plus/_shared/modules/layouts/mac_keycodes.json'
	]) {
		assert.ok(selectGates([file]).has('xkb-python'), `${file} does not select the XKB Python gate`);
	}
});

check('the meta.toml validator accepts a complete record', () => {
	assert.deepStrictEqual(
		validateMeta('sample', validMeta(), () => true),
		[]
	);
});

check('the meta.toml validator rejects every malformed shape', () => {
	const cases = [
		['missing name', (m) => delete m.name],
		['missing family', (m) => delete m.family],
		['family that is not an id', (m) => (m.family = 'Ergo L')],
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
		['variant that is not an id', (m) => (m.variants = ['Not An Id'])],
		['unknown xkb key', (m) => (m.xkb = { colour: 'blue' })],
		['xkb override that is not a pair', (m) => (m.xkb = { keysym_overrides: [['a']] })],
		[
			'xkb override to a malformed keysym',
			(m) => (m.xkb = { keysym_overrides: [['a', 'not a keysym']] })
		],
		[
			'xkb override mapping one text twice',
			(m) =>
				(m.xkb = {
					keysym_overrides: [
						['a', 'b'],
						['a', 'c']
					]
				})
		],
		['empty base_level_only', (m) => (m.xkb = { base_level_only: [] })]
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
	assert.ok(
		validateRegistry(
			new Map([
				['a', a],
				['b', b]
			])
		).length > 0,
		'asymmetric variants accepted'
	);
	const c = { ...validMeta(), variants: ['ghost'] };
	assert.ok(validateRegistry(new Map([['c', c]])).length > 0, 'dangling variant accepted');
	const d = { ...validMeta(), variants: ['d'] };
	assert.ok(validateRegistry(new Map([['d', d]])).length > 0, 'self variant accepted');
	const e = { ...validMeta(), variants: ['f'] };
	const f = { ...validMeta(), family: 'other', variants: ['e'] };
	assert.ok(
		validateRegistry(
			new Map([
				['e', e],
				['f', f]
			])
		).length > 0,
		'variants of two families accepted'
	);
	assert.deepStrictEqual(
		validateRegistry(
			new Map([
				['e', e],
				['f', { ...f, family: 'sample' }]
			])
		),
		[]
	);
});

check('layout extensions inventory existing-format files and reject incomplete packages', () => {
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-layout-extension-'));
	try {
		fs.cpSync(REGISTRY_DIR, fixture, { recursive: true });
		const folder = path.join(fixture, 'ergopti');
		const hotstrings = path.join(folder, 'hotstrings');
		fs.mkdirSync(hotstrings, { recursive: true });
		const content = '[[sample]]\n"test★" = "example"\n';
		fs.writeFileSync(path.join(hotstrings, 'sample.toml'), content);
		const result = buildIndex(fixture).index.layouts.find((entry) => entry.id === 'ergopti');
		assert.ok(result.extension, 'every layout is an existing-format extension');
		const file = result.extension.files.find((item) => item.path === 'hotstrings/sample.toml');
		assert.deepStrictEqual(file, {
			path: 'hotstrings/sample.toml',
			file: 'ergopti/hotstrings/sample.toml',
			size: Buffer.byteLength(content),
			sha256: sha256(content)
		});
		assert.ok(result.extension.files.some((item) => item.path === 'manifest.toml'));
		assert.ok(result.extension.files.some((item) => item.path === 'ergopti.keylayout'));
		const generation = result.extension.sha256;
		fs.writeFileSync(path.join(hotstrings, 'sample.toml'), content + '# changed\n');
		assert.notStrictEqual(
			buildIndex(fixture).index.layouts.find((entry) => entry.id === 'ergopti').extension.sha256,
			generation
		);
		fs.mkdirSync(path.join(hotstrings, 'nested'));
		assert.throws(() => buildIndex(fixture), /unsupported extension file/);
		fs.rmdirSync(path.join(hotstrings, 'nested'));
		const manifestPath = path.join(folder, 'manifest.toml');
		const manifest = fs.readFileSync(manifestPath, 'utf8');
		fs.writeFileSync(manifestPath, manifest.replace('id = "ergopti"', 'id = "../outside"'));
		assert.throws(() => buildIndex(fixture), /extension id/);
		fs.writeFileSync(manifestPath, manifest);
		fs.rmSync(path.join(folder, 'manifest.toml'));
		assert.throws(() => buildIndex(fixture), /manifest\.toml/);
	} finally {
		assert.ok(
			path
				.resolve(fixture)
				.startsWith(path.resolve(os.tmpdir()) + path.sep + 'ergopti-layout-extension-')
		);
		fs.rmSync(fixture, { recursive: true, force: true });
	}
});

check('the builder refuses the manifests the extension scanners refuse (shared vectors)', () => {
	const { parse: parseToml } = require('smol-toml');
	const corpus = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'tests', 'corpus', 'layouts');
	const read = (name) => JSON.parse(fs.readFileSync(path.join(corpus, name), 'utf8'));
	const bindings = read('extension_binding_vectors.json').cases;
	assert.ok(bindings.length >= 8, 'the binding vectors lost their coverage');
	for (const scenario of bindings) {
		const refused = scenario.packs.some(
			(pack) =>
				validateExtensionManifest(parseToml(pack.manifest).extension || {}, pack.files).length > 0
		);
		assert.strictEqual(refused, !scenario.valid, scenario.name);
	}
	const magicKeys = read('extension_magic_key_vectors.json').cases;
	assert.ok(magicKeys.length >= 8, 'the magic-key vectors lost their coverage');
	for (const scenario of magicKeys) {
		const errors = validateExtensionManifest(parseToml(scenario.manifest).extension || {}, []);
		assert.strictEqual(errors.length === 0, scenario.valid && scenario.published, scenario.name);
	}
});

check(
	'every published manifest passes the scanner rules and Ergopti declares its magic key',
	() => {
		const index = JSON.parse(fs.readFileSync(INDEX_PATH, 'utf8'));
		const { parse: parseToml } = require('smol-toml');
		const ergopti = parseToml(
			fs.readFileSync(path.join(REGISTRY_DIR, 'ergopti', 'manifest.toml'), 'utf8')
		).extension;
		assert.strictEqual(
			ergopti.id,
			'ergopti',
			'the display name must not rename saved extension ids'
		);
		assert.strictEqual(
			ergopti.name,
			'Ergopti+',
			'the bundled hotstrings extension includes the plus'
		);
		assert.deepStrictEqual(
			ergopti.magic_key,
			{ key: 'KeyC' },
			'Ergopti declares the key its layout places the magic key on'
		);
		for (const entry of index.layouts) {
			const manifest = parseToml(
				fs.readFileSync(path.join(REGISTRY_DIR, entry.extension.id, 'manifest.toml'), 'utf8')
			).extension;
			// A binding must name a file the published inventory carries.
			const stems = entry.extension.files
				.map((file) => /^hotstrings\/([a-z][a-z0-9_-]*)\.toml$/.exec(file.path))
				.filter(Boolean)
				.map((match) => match[1]);
			assert.deepStrictEqual(validateExtensionManifest(manifest, stems), [], entry.id);
		}
	}
);

check(
	'distance reduction belongs only to Ergopti with its historical rules, metadata and preference ids',
	() => {
		const { parse } = require('smol-toml');
		const shared = path.join(ROOT, 'static/ergopti_plus/_shared');
		const reference = JSON.parse(
			fs.readFileSync(
				path.join(shared, 'tests/corpus/hotstrings/distance_reduction_entries.json'),
				'utf8'
			)
		);
		const extension = parse(
			fs.readFileSync(path.join(REGISTRY_DIR, 'ergopti/manifest.toml'), 'utf8')
		).extension;
		assert.deepStrictEqual(extension.hotstring_bindings.distancesreduction, {
			category: reference.category,
			feature_section: reference.feature_section,
			source: reference.source
		});
		assert.strictEqual(reference.entries.length, 101);
		const document = parse(
			fs.readFileSync(path.join(REGISTRY_DIR, 'ergopti/hotstrings/distancesreduction.toml'), 'utf8')
		);
		assert.deepStrictEqual(document._meta, reference.meta);
		const entries = Object.entries(document)
			.filter(([section]) => section !== '_meta')
			.flatMap(([section, blocks]) =>
				blocks.flatMap((block) =>
					Object.entries(block).map(([trigger, fields]) => ({ section, trigger, ...fields }))
				)
			);
		assert.deepStrictEqual(entries, reference.entries, 'relocation must not change a rule or flag');
		assert.strictEqual(
			fs.existsSync(path.join(shared, 'modules/hotstrings/distancesreduction.toml')),
			false
		);
		const manifest = parse(
			fs.readFileSync(path.join(shared, 'modules/features/manifest.toml'), 'utf8')
		);
		assert.ok(!manifest.menu.hotstring_groups.standard.includes('distances_reduction'));
		assert.ok(manifest.menu.hotstring_groups.ergopti.includes('distances_reduction'));
		const index = parse(
			fs.readFileSync(path.join(shared, 'modules/hotstrings/_index.toml'), 'utf8')
		);
		assert.ok(!index.menu.categories_order.includes(reference.category));
		assert.ok(!index.languages.french.categories_order.includes(reference.category));
		assert.strictEqual(
			fs.existsSync(path.join(shared, 'modules/hotstrings/french/distancesreduction.toml')),
			false,
			'Ergopti suffixes have one extension source'
		);
		const distanceFeatures = manifest.features.hotstrings.flatMap(
			(entry) => entry.distances_reduction || []
		);
		assert.strictEqual(
			distanceFeatures.length,
			6,
			'all historical distance switches must remain declared'
		);
		for (const feature of distanceFeatures) {
			assert.strictEqual(feature.default.enabled, false, `${feature.id} must stay opt-in`);
			assert.strictEqual(
				feature.recommended.enabled,
				false,
				`${feature.id} must not be newly recommended`
			);
		}
	}
);

check('Ergopti owns suffixes and magic-key replacement with exact historical data', () => {
	const { parse } = require('smol-toml');
	const shared = path.join(ROOT, 'static/ergopti_plus/_shared');
	const extension = parse(
		fs.readFileSync(path.join(REGISTRY_DIR, 'ergopti/manifest.toml'), 'utf8')
	).extension;
	assert.deepStrictEqual(extension.hotstring_bindings.suffixes_a, {
		category: 'french_distancesreduction',
		feature_section: 'hotstrings.french_distancesreduction',
		source: 'common'
	});
	assert.deepStrictEqual(extension.hotstring_bindings.magickeyreplace, {
		category: 'magickey',
		feature_section: 'hotstrings.magic_key',
		sections: ['replace'],
		source: 'common'
	});
	// Captured from the original source before relocation; never generated from the moved file.
	const suffixSource = fs.readFileSync(
		path.join(REGISTRY_DIR, 'ergopti/hotstrings/suffixes_a.toml'),
		'utf8'
	);
	assert.strictEqual(
		crypto
			.createHash('sha256')
			.update(suffixSource.slice(suffixSource.indexOf('\n') + 1))
			.digest('hex'),
		'779cdcac3eb9446f998a915c22398aa6cb8b08e19b18d696249ddad7801e7ff2',
		'all 24 historical rules, flags, order and 21-language metadata remain byte-exact'
	);
	const suffixes = parse(suffixSource);
	assert.deepStrictEqual(suffixes._meta.sections_order, ['suffixes_a']);
	assert.strictEqual(Object.keys(suffixes.suffixes_a[0]).length, 24);
	const replacementSource = fs.readFileSync(
		path.join(REGISTRY_DIR, 'ergopti/hotstrings/magickeyreplace.toml'),
		'utf8'
	);
	const replacementDescription = replacementSource
		.split('\n')
		.find((line) => line.startsWith('replace = '));
	assert.strictEqual(
		crypto.createHash('sha256').update(replacementDescription).digest('hex'),
		'445d95e02245d1d65425357db4374315c95e75206038e8b00e22963fa4547861',
		'the complete independent 21-language replacement description is preserved'
	);
	const replacement = parse(replacementSource);
	assert.deepStrictEqual(replacement._meta.sections_order, ['replace']);
	assert.strictEqual(Object.keys(replacement._meta.sections.replace).length, 21);
	assert.strictEqual(
		replacement.replace,
		undefined,
		'replacement remains a native feature, with no fabricated hotstring'
	);
	const common = parse(
		fs.readFileSync(path.join(shared, 'modules/hotstrings/magickey.toml'), 'utf8')
	);
	assert.strictEqual(
		common._meta.sections.replace,
		undefined,
		'the common source no longer owns replacement'
	);
	assert.deepStrictEqual(
		common._meta.sections_order,
		[
			'replace',
			'repeat_corrections',
			'-',
			'text_expansion_symbols',
			'text_expansion_symbols_typst'
		],
		'the category retains the canonical relative-order anchors for its bound sections'
	);
});

console.log(`\n${passes} passed, ${failures} failed`);
if (failures > 0) process.exit(1);
