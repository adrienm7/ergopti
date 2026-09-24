// tools/test/test-update-channels-contract.cjs

/**
 * ==============================================================================
 * MODULE: Update Channel Registry Contract Test
 * DESCRIPTION:
 * The update channels (which tags a channel owns, how a persisted value maps to
 * a channel, which releases a channel's Versions view lists, which candidate an
 * update check offers) are declared once, in _shared/modules/updater/
 * channels.json, and interpreted by one port per runtime.
 *
 * ROOT CAUSE ENCODED:
 * Every driver used to spell the channels by hand: "main"/"dev" literals in the
 * AHK updater, the page's two hardcoded buttons, a prerelease-flag filter in the
 * page and the macOS host, a '-dev.' substring test on macOS and a second
 * vocabulary ('stable'/'dev') on Linux. Adding a channel meant finding all of
 * them, and the Linux spelling silently disagreed with the other two.
 *
 * FEATURES & RATIONALE:
 * 1. The canonical JavaScript matcher (_shared/ui/update_channels.js) replays
 *    _shared/modules/updater/channel_vectors.json; the Lua and AHK suites
 *    replay the same file through their ports.
 * 2. A malformed registry is refused at creation, never degraded to a default.
 * 3. Every channel names locale keys present and non-empty in all 21 locales.
 * 4. The generated artifacts (page data, AHK data, launcher feeds) equal a
 *    fresh render of the registry; the page data and the launcher feed table
 *    are also read back and compared with the registry itself (the AHK suite
 *    checks its data by replaying the vectors through it).
 * 5. The tag families the release workflow publishes each belong to exactly one
 *    channel, and that channel's github_prerelease flag is the one CI sets.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { pathToFileURL } = require('url');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const REGISTRY_PATH = path.join(SHARED, 'modules', 'updater', 'channels.json');
const VECTORS_PATH = path.join(SHARED, 'modules', 'updater', 'channel_vectors.json');
const MATCHER_PATH = path.join(SHARED, 'ui', 'update_channels.js');
const LOCALES_DIR = path.join(SHARED, 'data', 'locales');
const WORKFLOW_PATH = path.join(ROOT, '.github', 'workflows', 'ci.yml');
const GENERATOR_PATH = path.join(ROOT, 'tools', 'codegen', 'codegen-update-channels.cjs');
const VERSION_PATH = path.join(SHARED, 'modules', 'updater', 'version.js');
const PAGE_DATA_PATH = path.join(SHARED, 'ui', '_generated', 'update_channel_registry.js');
const SWIFT_FEEDS_PATH = path.join(
	ROOT, 'static', 'ergopti_plus', 'macos', 'launcher', 'Sources', 'ErgoptiPlus', 'UpdateChannels.generated.swift'
);
const LOCALE_COUNT = 21;
const MIN_VECTORS = { tag: 20, resolve: 5, visible: 5, offer: 8, pick: 5 };

const failures = [];
let checks = 0;

function expect(condition, message) {
	checks += 1;
	if (!condition) failures.push(message);
}

// ==========================================
// ==========================================
// ======= 1/ Loading ======================
// ==========================================
// ==========================================

/** Runs the canonical matcher exactly as a page loads it: a plain script. */
function loadMatcher() {
	const sandbox = { console };
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	vm.runInContext(fs.readFileSync(MATCHER_PATH, 'utf8'), sandbox, { filename: MATCHER_PATH });
	if (typeof sandbox.createUpdateChannels !== 'function') {
		throw new Error('update_channels.js must define window.createUpdateChannels');
	}
	return sandbox.createUpdateChannels;
}

function readJson(file) {
	return JSON.parse(fs.readFileSync(file, 'utf8'));
}

// ==========================================
// ==========================================
// ======= 2/ Vectors ======================
// ==========================================
// ==========================================

/** The vectors spell 'no channel' as an empty string (no JSON null, see the file). */
function none(value) {
	return value === '' ? null : value;
}

function checkVectors(channels, vectors, compareVersions) {
	for (const [group, minimum] of Object.entries(MIN_VECTORS)) {
		const list = vectors[group];
		expect(
			Array.isArray(list) && list.length >= minimum,
			`channel_vectors.json must hold at least ${minimum} "${group}" vectors`
		);
	}
	for (const v of vectors.tag || []) {
		const got = channels.channelForTag(v.tag);
		expect(got === none(v.channel), `tag ${v.id}: channelForTag(${JSON.stringify(v.tag)}) = ${JSON.stringify(got)}, expected ${JSON.stringify(v.channel)}`);
		for (const id of channels.ids) {
			expect(
				channels.matches(id, v.tag) === (id === none(v.channel)),
				`tag ${v.id}: matches(${id}) disagrees with the channel the tag belongs to`
			);
		}
	}
	for (const v of vectors.resolve || []) {
		const got = channels.resolve(v.value);
		expect(got === none(v.expect), `resolve ${v.id}: resolve(${JSON.stringify(v.value)}) = ${JSON.stringify(got)}, expected ${JSON.stringify(v.expect)}`);
	}
	for (const v of vectors.visible || []) {
		const got = channels.visibleIn(v.view, v.tag);
		expect(got === v.expect, `visible ${v.id}: visibleIn(${v.view}, ${v.tag}) = ${got}`);
	}
	for (const v of vectors.offer || []) {
		const got = channels.shouldOffer(v.latest, v.current, v.selected, v.installed, compareVersions);
		expect(got === v.expect, `offer ${v.id}: shouldOffer = ${got}, expected ${v.expect}`);
	}
	for (const v of vectors.pick || []) {
		const index = channels.pickLatest(v.tags, v.channel, compareVersions);
		const got = index === -1 ? null : v.tags[index];
		expect(got === none(v.expect), `pick ${v.id}: pickLatest = ${JSON.stringify(got)}, expected ${JSON.stringify(v.expect)}`);
	}
}

// ==========================================
// ==========================================
// ======= 3/ Registry Validation ==========
// ==========================================
// ==========================================

function checkMalformedRegistries(create, registry) {
	const clone = () => JSON.parse(JSON.stringify(registry));
	const cases = [
		['no channels', (r) => { r.channels = []; }],
		['a duplicate id', (r) => { r.channels[1].id = r.channels[0].id; }],
		['an alias equal to an id', (r) => { r.channels[1].aliases = [r.channels[0].id]; }],
		['an alias used twice', (r) => { r.channels[1].aliases = r.channels[0].aliases.slice(); }],
		['an unknown tag core', (r) => { r.channels[0].tag.core = '1.x'; }],
		['a core with a leading zero', (r) => { r.channels[1].tag.core = '0.00.0'; }],
		['a prerelease without a label', (r) => { r.channels[1].tag.prerelease = { counter: true }; }],
		['an unreleased channel that does not exist', (r) => { r.unreleased_build_channel = 'beta'; }],
		['a missing label key', (r) => { delete r.channels[0].label_key; }],
		['a feed outside the appcast naming', (r) => { r.channels[0].sparkle_feed = '../appcast.xml'; }],
		['an unsupported schema version', (r) => { r.schema_version = 2; }],
		['two channels owning the same tags', (r) => { r.channels[1].tag = JSON.parse(JSON.stringify(r.channels[0].tag)); }]
	];
	for (const [name, mutate] of cases) {
		const candidate = clone();
		mutate(candidate);
		let refused = false;
		try {
			create(candidate);
		} catch (error) {
			refused = true;
		}
		expect(refused, `a registry with ${name} must be refused at creation`);
	}
}

// ==========================================
// ==========================================
// ======= 4/ Locales ======================
// ==========================================
// ==========================================

function checkLocales(registry) {
	const files = fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json'));
	expect(files.length === LOCALE_COUNT, `expected ${LOCALE_COUNT} locale files, found ${files.length}`);
	const keys = [];
	for (const channel of registry.channels) keys.push(channel.label_key, channel.menu_label_key);
	for (const file of files) {
		const strings = readJson(path.join(LOCALES_DIR, file));
		for (const key of keys) {
			expect(
				typeof strings[key] === 'string' && strings[key].trim() !== '',
				`${file} must translate ${key}`
			);
		}
	}
}

// ==========================================
// ==========================================
// ======= 5/ Generated Artifacts ==========
// ==========================================
// ==========================================

/**
 * Evaluates the committed page data as the page does and compares it with the
 * registry itself, independently of the generator's emitter.
 */
function checkPageData(registry) {
	const sandbox = {};
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	vm.runInContext(fs.readFileSync(PAGE_DATA_PATH, 'utf8'), sandbox, { filename: PAGE_DATA_PATH });
	const expected = Object.assign({}, registry);
	delete expected._comment;
	expect(
		JSON.stringify(sandbox.UPDATE_CHANNEL_REGISTRY) === JSON.stringify(expected),
		'the page data must define UPDATE_CHANNEL_REGISTRY equal to channels.json (without its _comment)'
	);
}

/**
 * Reads the launcher's committed feed table back and compares it with the
 * registry: the launcher accepts a command only for these ids and serves the
 * named appcast, so a stale table would route a channel to another feed.
 */
function checkSwiftFeeds(registry) {
	const source = fs.readFileSync(SWIFT_FEEDS_PATH, 'utf8');
	const table = /let kUpdateChannelFeeds: \[String: String\] = \[([\s\S]*?)\n\]/.exec(source);
	expect(table !== null, 'UpdateChannels.generated.swift must declare kUpdateChannelFeeds');
	if (!table) return;
	const pairs = [...table[1].matchAll(/"([^"]+)": "([^"]+)",/g)].map((m) => [m[1], m[2]]);
	const expected = registry.channels.map((channel) => [channel.id, channel.sparkle_feed]);
	expect(
		JSON.stringify(pairs) === JSON.stringify(expected),
		`the launcher's feed table ${JSON.stringify(pairs)} must equal the registry ${JSON.stringify(expected)}`
	);
}

function checkGeneratedArtifacts(registry) {
	// eslint-disable-next-line global-require
	const generator = require(GENERATOR_PATH);
	expect(typeof generator.renderOutputs === 'function', 'the generator must export renderOutputs(registry)');
	if (typeof generator.renderOutputs !== 'function') return;
	const outputs = generator.renderOutputs(registry);
	expect(outputs.length >= 3, 'the generator must render the page data, the AHK data and the Swift feeds');
	for (const output of outputs) {
		const committed = fs.existsSync(output.path) ? fs.readFileSync(output.path, 'utf8') : null;
		expect(
			committed === output.content,
			`${path.relative(ROOT, output.path)} is stale; run npm run codegen:update-channels`
		);
	}
}

// ==========================================
// ==========================================
// ======= 6/ Release Workflow =============
// ==========================================
// ==========================================

/**
 * Reads the tag template and prerelease flag of each branch of the release
 * workflow's "Compute tag and version" step and instantiates one sample tag.
 */
function workflowTagFamilies() {
	const text = fs.readFileSync(WORKFLOW_PATH, 'utf8');
	const stable = /tag="v\$\{maj\}\.\$\{min\}\.\$\{pat\}"\s*\n\s*prerelease="(true|false)"/.exec(text);
	const dev = /tag="v0\.0\.0-dev\.\$\{next_n\}"\s*\n\s*prerelease="(true|false)"/.exec(text);
	const families = [];
	if (stable) families.push({ name: 'main branch', samples: ['v1.4.2', 'v0.0.1', 'v12.0.0'], prerelease: stable[1] === 'true' });
	if (dev) families.push({ name: 'dev branch', samples: ['v0.0.0-dev.1', 'v0.0.0-dev.134'], prerelease: dev[1] === 'true' });
	return families;
}

function checkWorkflowFamilies(channels) {
	const families = workflowTagFamilies();
	expect(families.length === 2, 'the release workflow must still publish one stable and one dev tag family');
	for (const family of families) {
		for (const tag of family.samples) {
			const owners = channels.ids.filter((id) => channels.matches(id, tag));
			expect(owners.length === 1, `${family.name} tag ${tag} must belong to exactly one channel, got [${owners}]`);
			if (owners.length === 1) {
				expect(
					channels.channel(owners[0]).githubPrerelease === family.prerelease,
					`${family.name}: channel ${owners[0]} declares github_prerelease=${!family.prerelease}, the workflow publishes ${family.prerelease}`
				);
			}
		}
	}
}

// ==========================================
// ==========================================
// ======= 7/ Main =========================
// ==========================================
// ==========================================

(async () => {
	try {
		const { compareVersions } = await import(pathToFileURL(VERSION_PATH).href);
		const create = loadMatcher();
		const registry = readJson(REGISTRY_PATH);
		const channels = create(registry);
		expect(
			JSON.stringify(Array.from(channels.ids)) === JSON.stringify(registry.channels.map((c) => c.id)),
			'the matcher must keep the registry order (the stability rank)'
		);
		checkVectors(channels, readJson(VECTORS_PATH), compareVersions);
		checkMalformedRegistries(create, registry);
		checkLocales(registry);
		checkGeneratedArtifacts(registry);
		checkPageData(registry);
		checkSwiftFeeds(registry);
		checkWorkflowFamilies(channels);
	} catch (error) {
		failures.push(`the contract could not run: ${error && error.stack ? error.stack : error}`);
	}
	if (failures.length > 0) {
		console.error(`\x1b[31m[ERROR] update channel contract: ${failures.length} failure(s) in ${checks} check(s):\x1b[0m`);
		for (const failure of failures) console.error('  - ' + failure);
		process.exit(1);
	}
	console.log(`\x1b[32m[OK] update channel registry, vectors, locales, generated artifacts and release tags agree (${checks} checks).\x1b[0m`);
})();
