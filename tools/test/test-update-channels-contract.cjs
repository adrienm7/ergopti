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
 *    channel, and that channel's github_prerelease flag is the one CI sets. The
 *    workflow stamps the channel the registry gives the tag
 *    (tools/build/release-channel.cjs), never one derived from that flag, and
 *    each channel's appcast carries the name the workflow publishes.
 * 6. Ratchet: the sources that decide or display channels never quote a
 *    channel id or alias in code; they read the registry.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { spawnSync } = require('child_process');
const { pathToFileURL } = require('url');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const REGISTRY_PATH = path.join(SHARED, 'modules', 'updater', 'channels.json');
const VECTORS_PATH = path.join(SHARED, 'modules', 'updater', 'channel_vectors.json');
const MATCHER_PATH = path.join(SHARED, 'ui', 'update_channels.js');
const LOCALES_DIR = path.join(SHARED, 'data', 'locales');
const WORKFLOW_PATH = path.join(ROOT, '.github', 'workflows', 'ci.yml');
const RELEASE_CHANNEL_TOOL = path.join(ROOT, 'tools', 'build', 'release-channel.cjs');
// The one expression every release step reads the published channel from.
const pipeline = require('./ci-pipeline.cjs');
const RELEASE_CHANNEL_OUTPUT = '${{ needs.validate.outputs.channel }}';
const GENERATOR_PATH = path.join(ROOT, 'tools', 'codegen', 'codegen-update-channels.cjs');
const VERSION_PATH = path.join(SHARED, 'modules', 'updater', 'version.js');
const PAGE_DATA_PATH = path.join(SHARED, 'ui', '_generated', 'update_channel_registry.js');
const SWIFT_FEEDS_PATH = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'launcher',
	'Sources',
	'ErgoptiPlus',
	'UpdateChannels.generated.swift'
);
const LOCALE_COUNT = 21;
const MIN_VECTORS = { tag: 20, resolve: 5, visible: 5, offer: 8, pick: 5, newer_elsewhere: 10 };

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
		expect(
			got === none(v.channel),
			`tag ${v.id}: channelForTag(${JSON.stringify(v.tag)}) = ${JSON.stringify(got)}, expected ${JSON.stringify(v.channel)}`
		);
		for (const id of channels.ids) {
			expect(
				channels.matches(id, v.tag) === (id === none(v.channel)),
				`tag ${v.id}: matches(${id}) disagrees with the channel the tag belongs to`
			);
		}
	}
	for (const v of vectors.resolve || []) {
		const got = channels.resolve(v.value);
		expect(
			got === none(v.expect),
			`resolve ${v.id}: resolve(${JSON.stringify(v.value)}) = ${JSON.stringify(got)}, expected ${JSON.stringify(v.expect)}`
		);
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
		expect(
			got === none(v.expect),
			`pick ${v.id}: pickLatest = ${JSON.stringify(got)}, expected ${JSON.stringify(v.expect)}`
		);
	}
	for (const v of vectors.newer_elsewhere || []) {
		const got = JSON.stringify(
			channels.newerElsewhere(v.releases, v.selected, v.installed, compareVersions)
		);
		expect(
			got === JSON.stringify(v.expect),
			`newer_elsewhere ${v.id}: newerElsewhere = ${got}, expected ${JSON.stringify(v.expect)}`
		);
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
		[
			'no channels',
			(r) => {
				r.channels = [];
			}
		],
		[
			'a duplicate id',
			(r) => {
				r.channels[1].id = r.channels[0].id;
			}
		],
		[
			'an alias equal to an id',
			(r) => {
				r.channels[1].aliases = [r.channels[0].id];
			}
		],
		[
			'an alias used twice',
			(r) => {
				r.channels[1].aliases = r.channels[0].aliases.slice();
			}
		],
		[
			'an unknown tag core',
			(r) => {
				r.channels[0].tag.core = '1.x';
			}
		],
		[
			'a core with a leading zero',
			(r) => {
				r.channels[1].tag.core = '0.00.0';
			}
		],
		[
			'a prerelease without a label',
			(r) => {
				r.channels[1].tag.prerelease = { counter: true };
			}
		],
		[
			'an unreleased channel that does not exist',
			(r) => {
				r.unreleased_build_channel = 'beta';
			}
		],
		[
			'a missing label key',
			(r) => {
				delete r.channels[0].label_key;
			}
		],
		[
			'a feed outside the appcast naming',
			(r) => {
				r.channels[0].sparkle_feed = '../appcast.xml';
			}
		],
		[
			'an unsupported schema version',
			(r) => {
				r.schema_version = 2;
			}
		],
		[
			'two channels owning the same tags',
			(r) => {
				r.channels[1].tag = JSON.parse(JSON.stringify(r.channels[0].tag));
			}
		]
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
	expect(
		files.length === LOCALE_COUNT,
		`expected ${LOCALE_COUNT} locale files, found ${files.length}`
	);
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
	expect(
		typeof generator.renderOutputs === 'function',
		'the generator must export renderOutputs(registry)'
	);
	if (typeof generator.renderOutputs !== 'function') return;
	const outputs = generator.renderOutputs(registry);
	expect(
		outputs.length >= 3,
		'the generator must render the page data, the AHK data and the Swift feeds'
	);
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
	const stable = /tag="v\$\{maj\}\.\$\{min\}\.\$\{pat\}"\s*\n\s*prerelease="(true|false)"/.exec(
		text
	);
	const dev = /tag="v0\.0\.0-dev\.\$\{next_n\}"\s*\n\s*prerelease="(true|false)"/.exec(text);
	const families = [];
	if (stable)
		families.push({
			name: 'main branch',
			samples: ['v1.4.2', 'v0.0.1', 'v12.0.0'],
			prerelease: stable[1] === 'true'
		});
	if (dev)
		families.push({
			name: 'dev branch',
			samples: ['v0.0.0-dev.1', 'v0.0.0-dev.134'],
			prerelease: dev[1] === 'true'
		});
	return families;
}

function checkWorkflowFamilies(channels) {
	const families = workflowTagFamilies();
	expect(
		families.length === 2,
		'the release workflow must still publish one stable and one dev tag family'
	);
	for (const family of families) {
		for (const tag of family.samples) {
			const owners = channels.ids.filter((id) => channels.matches(id, tag));
			expect(
				owners.length === 1,
				`${family.name} tag ${tag} must belong to exactly one channel, got [${owners}]`
			);
			if (owners.length === 1) {
				expect(
					channels.channel(owners[0]).githubPrerelease === family.prerelease,
					`${family.name}: channel ${owners[0]} declares github_prerelease=${!family.prerelease}, the workflow publishes ${family.prerelease}`
				);
			}
		}
	}
}

/**
 * The release workflow names the channel of the release it publishes through
 * the registry: validate asks tools/build/release-channel.cjs which
 * channel owns the new tag, and every stamp (the Windows bundle, the macOS
 * bundle, its appcast and the feed branch) reads that one output. The workflow
 * used to turn GitHub's prerelease flag into "dev" or "main" in five places, so
 * a second prerelease channel would have been stamped as dev.
 */
function checkWorkflowChannelSource() {
	const text = pipeline.text();
	const plan = pipeline.job('validate');
	const meta = pipeline.step(plan, 'Compute tag and version');
	expect(
		plan.includes('channel: ${{ steps.meta.outputs.channel }}'),
		'validate must publish its channel'
	);
	expect(
		meta.includes('channel="$(node tools/build/release-channel.cjs "$tag")"'),
		'validate must resolve the release tag through the registry'
	);
	expect(
		meta.includes('emit channel "$channel"'),
		'the release path must publish the resolved channel'
	);
	expect(
		/uses: actions\/setup-node@v4\s*\n\s*with:\s*\n\s*node-version-file: '\.node-version'/.test(
			plan
		),
		'validate must install the pinned Node before running the registry tool'
	);
	for (const caller of ['windows', 'macos']) {
		expect(
			pipeline.job(caller).includes('channel: ' + RELEASE_CHANNEL_OUTPUT),
			caller + ' must receive the resolved channel'
		);
	}
	const macos = pipeline.job('package-macos');
	const feed = pipeline.step(pipeline.job('release'), 'Publish channel feed for Sparkle');
	const stamps = [...macos.matchAll(/ERGOPTI_CHANNEL:\s*(.+)/g)].map((match) => match[1].trim());
	expect(
		stamps.length === 2 && stamps.every((value) => value === '${{ inputs.channel }}'),
		'the macOS bundle and appcast must stamp their input channel'
	);
	expect(
		feed.includes('ERGOPTI_CHANNEL: ' + RELEASE_CHANNEL_OUTPUT),
		'the published feed must use the resolved channel'
	);
	expect(
		macos.includes('OUTPUT_PATH: build/macos/appcast-${{ inputs.channel }}.xml'),
		'the appcast basename must use the lane input channel'
	);
	expect(
		pipeline.job('package-windows').includes('$channel = "${{ inputs.channel }}"'),
		'the Windows bundle must stamp the lane input channel'
	);
	expect(
		!/outputs\.prerelease\s*==\s*'true'\s*&&/.test(text) &&
			!/-eq\s+'true'\)\s*\{\s*'/.test(text) &&
			!/if \[ "\$prerelease" = "true" \]; then channel=/.test(text),
		'no pipeline step may turn the prerelease flag into a channel id'
	);
}

/**
 * Runs the release tool over the tags the workflow publishes: each prints the
 * channel the registry gives it, and a tag no channel owns fails the release.
 */
function checkReleaseChannelTool(channels) {
	const run = (args) =>
		spawnSync(process.execPath, [RELEASE_CHANNEL_TOOL, ...args], { encoding: 'utf8' });
	expect(fs.existsSync(RELEASE_CHANNEL_TOOL), 'tools/build/release-channel.cjs must exist');
	if (!fs.existsSync(RELEASE_CHANNEL_TOOL)) return;
	const families = workflowTagFamilies();
	expect(families.length > 0, 'the release tool check needs the workflow tag families');
	for (const family of families) {
		for (const tag of family.samples) {
			const result = run([tag]);
			expect(
				result.status === 0 && result.stdout === `${channels.channelForTag(tag)}\n`,
				`release-channel.cjs ${tag} must print ${channels.channelForTag(tag)}, got status ` +
					`${result.status} and ${JSON.stringify(result.stdout)} ${result.stderr}`
			);
		}
	}
	for (const args of [['nightly'], ['v1.2.3-beta.1'], [], ['v1.2.3', 'v1.2.4']]) {
		const result = run(args);
		expect(
			result.status !== 0 && result.stdout === '',
			`release-channel.cjs ${JSON.stringify(args)} must fail without printing a channel`
		);
	}
}

/**
 * build_macos_app.sh (SUFeedURL) and the release workflow name a channel's
 * appcast appcast-<id>.xml, while the launcher serves the registry's
 * sparkle_feed: a different name would point Sparkle at a feed nobody writes.
 */
function checkSparkleFeedNames(registry) {
	for (const channel of registry.channels) {
		expect(
			channel.sparkle_feed === `appcast-${channel.id}.xml`,
			`channel ${channel.id}: sparkle_feed must be appcast-${channel.id}.xml, the name the release ` +
				'workflow and build_macos_app.sh publish'
		);
	}
}

// ==========================================
// ==========================================
// ======= 7/ Hardcoded Channel Ratchet ====
// ==========================================
// ==========================================

// Sources that decide or display update channels. Each reads the ids from the
// registry; a quoted channel id or alias in code means a site spelled the
// channel by hand again.
const CHANNEL_CONSUMERS = [
	'windows/infra/bundle.ahk',
	'windows/modules/updater.ahk',
	'windows/modules/updater/channels.ahk',
	'windows/modules/updater/core.ahk',
	'windows/modules/updater/changelog.ahk',
	'windows/modules/updater/self_update.ahk',
	'windows/ui/changelog/init.ahk',
	'windows/ui/menu/menu_init.ahk',
	'macos/modules/updater/init.lua',
	'macos/modules/updater/channel.lua',
	'macos/modules/updater/auto_check.lua',
	'macos/ui/menu/menu_about.lua',
	'macos/ui/changelog/init.lua',
	'macos/adapters/update_launcher.lua',
	'macos/launcher/Sources/ErgoptiPlus/UpdaterCommandRouter.swift',
	'macos/launcher/Sources/ErgoptiPlus/UpdateChannelFeed.swift',
	'linux/modules/updater/manager.lua',
	'linux/ui/changelog/bridge.lua',
	'linux/ui/menu/menu_builder.lua',
	'_shared/lua/updater/channels.lua',
	'_shared/lua/updater/release_parser.lua',
	'_shared/ui/update_channels.js',
	'_shared/ui/changelog/script.js',
	'_shared/ui/changelog/atom_feed.js',
	'_shared/modules/updater/version.js'
];

/** Whether a source line is a comment in any of the consumers' languages. */
function isCommentLine(line) {
	return /^\s*(;|--|\/\/|\/\*|\*)/.test(line);
}

/**
 * Lists the code lines of a source that quote a channel id or alias.
 * @param {string} text - Source text.
 * @param {Set<string>} names - Channel ids and aliases.
 * @returns {Array<{line: number, name: string}>}
 */
function hardcodedChannelsIn(text, names) {
	const hits = [];
	text.split('\n').forEach((line, index) => {
		if (isCommentLine(line)) return;
		for (const name of names) {
			if (line.includes(`"${name}"`) || line.includes(`'${name}'`))
				hits.push({ line: index + 1, name });
		}
	});
	return hits;
}

function checkNoHardcodedChannels(registry) {
	const names = new Set();
	for (const channel of registry.channels) {
		names.add(channel.id);
		for (const alias of channel.aliases) names.add(alias);
	}
	expect(
		names.size > registry.channels.length,
		'the ratchet must look for every channel id and alias'
	);
	// The scan must be able to fail: a quoted id in code is found, a comment is not.
	const probe = `x = 1\nif (channel === '${registry.channels[0].id}') {}\n// "${registry.channels[0].id}" in prose\n`;
	const probeHits = hardcodedChannelsIn(probe, names);
	expect(
		probeHits.length === 1 && probeHits[0].line === 2,
		`the ratchet must flag a quoted channel in code and skip comments (got ${JSON.stringify(probeHits)})`
	);
	const plus = path.join(ROOT, 'static', 'ergopti_plus');
	for (const relative of CHANNEL_CONSUMERS) {
		const file = path.join(plus, relative);
		expect(
			fs.existsSync(file),
			`channel consumer ${relative} is missing; update CHANNEL_CONSUMERS`
		);
		if (!fs.existsSync(file)) continue;
		for (const hit of hardcodedChannelsIn(fs.readFileSync(file, 'utf8'), names)) {
			expect(
				false,
				`${relative}:${hit.line} spells the channel "${hit.name}" by hand; read it from the registry`
			);
		}
	}
}

// ==========================================
// ==========================================
// ======= 8/ Main =========================
// ==========================================
// ==========================================

(async () => {
	try {
		const { compareVersions } = await import(pathToFileURL(VERSION_PATH).href);
		const create = loadMatcher();
		const registry = readJson(REGISTRY_PATH);
		const channels = create(registry);
		expect(
			JSON.stringify(Array.from(channels.ids)) ===
				JSON.stringify(registry.channels.map((c) => c.id)),
			'the matcher must keep the registry order (the stability rank)'
		);
		checkVectors(channels, readJson(VECTORS_PATH), compareVersions);
		checkMalformedRegistries(create, registry);
		checkLocales(registry);
		checkGeneratedArtifacts(registry);
		checkPageData(registry);
		checkSwiftFeeds(registry);
		checkWorkflowFamilies(channels);
		checkWorkflowChannelSource();
		checkReleaseChannelTool(channels);
		checkSparkleFeedNames(registry);
		checkNoHardcodedChannels(registry);
	} catch (error) {
		failures.push(`the contract could not run: ${error && error.stack ? error.stack : error}`);
	}
	if (failures.length > 0) {
		console.error(
			`\x1b[31m[ERROR] update channel contract: ${failures.length} failure(s) in ${checks} check(s):\x1b[0m`
		);
		for (const failure of failures) console.error('  - ' + failure);
		process.exit(1);
	}
	console.log(
		`\x1b[32m[OK] update channel registry, vectors, locales, generated artifacts and release tags agree (${checks} checks).\x1b[0m`
	);
})();
