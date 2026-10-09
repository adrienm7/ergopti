// tools/test/test-healthcheck-model.cjs

/**
 * ==============================================================================
 * MODULE: Diagnostics Page Model
 * DESCRIPTION:
 * Runs the shared diagnostics page model (_shared/ui/healthcheck/model.js) the
 * way the page loads it, against the v2 schema
 * (_shared/modules/diagnostics/schema.json) and one snapshot per driver:
 * 1. the schema is well formed: unique ids, known types and platforms, every
 *    probe a field names is declared, and every label it implies exists in
 *    all 21 locales;
 * 2. the page renders one H2 section per schema section, in order, pending
 *    and failed probes say so, opt-in values stay hidden until details are
 *    included, and values are HTML-escaped;
 * 3. the summary lists missing permissions with their settings button, a
 *    failed network probe and the session's errors;
 * 4. the Markdown report carries the sections in order and ends with the
 *    snapshot as JSON that parses back, without opt-in values unless details
 *    are included;
 * 5. the issue summary and the file name replay the shared vectors the Lua
 *    and AHK ports used to replay.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const LOCALES_DIR = path.join(SHARED, 'data', 'locales');
const DRIVERS = ['windows', 'macos', 'linux'];
const FIELD_TYPES = [
	'text',
	'path',
	'count',
	'bytes',
	'seconds',
	'ms',
	'percent',
	'bool',
	'list',
	'log',
	'enum'
];

const failures = [];
const fail = (message) => failures.push(message);

// ==============================
// ==============================
// ======= 1/ The Sources =======
// ==============================
// ==============================

const schema = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'schema.json'), 'utf8')
);
const locales = new Map(
	fs
		.readdirSync(LOCALES_DIR)
		.filter((name) => name.endsWith('.json'))
		.map((name) => [
			name.slice(0, -5),
			JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, name), 'utf8'))
		])
);
const en = locales.get('en');

// The model is a page script: it runs in a sandbox beside dom_utils.js, which
// owns escapeHtml, exactly as the page loads them
const Model = (() => {
	const sandbox = { window: {} };
	for (const rel of ['ui/dom_utils.js', 'ui/healthcheck/model.js']) {
		const file = path.join(SHARED, rel);
		vm.runInNewContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	}
	if (!sandbox.window.ErgoptiDiagnostics)
		throw new Error('model.js did not define window.ErgoptiDiagnostics');
	return sandbox.window.ErgoptiDiagnostics;
})();

/**
 * The page's translator over en.json: "%s" placeholders take the arguments in
 * order, and an unknown key comes back as itself so a leak is visible.
 */
function t(key, ...args) {
	const value = en[key];
	if (typeof value !== 'string') return key;
	let index = 0;
	return value.replace(/%s/g, () => String(args[index++]));
}

// ===============================
// ===============================
// ======= 2/ Schema Shape =======
// ===============================
// ===============================

if (schema.schema_version !== 2) fail(`schema_version is ${schema.schema_version}, expected 2`);
if (!Array.isArray(schema.sections) || schema.sections.length < 10)
	fail('the schema declares fewer than 10 sections');
for (const key of ['phase_a_budget_ms', 'max_export_bytes']) {
	if (!Number.isInteger(schema[key]) || schema[key] < 1) fail(`${key} must be a positive integer`);
}
const report = schema.report || {};
for (const key of ['subdir', 'name_prefix', 'name_suffix']) {
	if (typeof report[key] !== 'string' || report[key] === '')
		fail(`report.${key} must be a non-empty string`);
}

const sectionIds = new Set();
const fieldIds = new Set();
const labelKeys = new Set(['menu.debug.healthcheck']);
for (const section of schema.sections || []) {
	if (sectionIds.has(section.id)) fail(`section ${section.id} is declared twice`);
	sectionIds.add(section.id);
	labelKeys.add(`healthcheck.section.${section.id}`);
	for (const platform of section.platforms || []) {
		if (!DRIVERS.includes(platform))
			fail(`section ${section.id} names an unknown platform ${platform}`);
	}
	const kind = section.kind || 'fields';
	if (!['fields', 'items', 'summary'].includes(kind))
		fail(`section ${section.id} has an unknown kind ${kind}`);
	const sectionProbes =
		typeof section.probe === 'string' ? [section.probe] : Object.values(section.probe || {});
	for (const probe of sectionProbes) {
		if (kind !== 'items')
			fail(`section ${section.id}: only an items section is completed by a probe`);
		if (!schema.probes || !schema.probes[probe])
			fail(`section ${section.id} names an undeclared probe ${probe}`);
	}
	if (kind === 'items') {
		if (!Array.isArray(section.columns) || section.columns.length === 0)
			fail(`items section ${section.id} has no columns`);
		for (const column of section.columns || [])
			labelKeys.add(`healthcheck.column.${section.id}.${column}`);
		for (const column of section.opt_in_columns || []) {
			if (!section.columns.includes(column))
				fail(`${section.id}: opt-in column ${column} is not a column`);
		}
	}
	for (const field of section.fields || []) {
		if (fieldIds.has(field.id))
			fail(`field ${field.id} is declared twice (labels are keyed by field id)`);
		fieldIds.add(field.id);
		labelKeys.add(`healthcheck.field.${field.id}`);
		if (!FIELD_TYPES.includes(field.type))
			fail(`field ${field.id} has an unknown type ${field.type}`);
		for (const platform of field.platforms || []) {
			if (!DRIVERS.includes(platform))
				fail(`field ${field.id} names an unknown platform ${platform}`);
		}
		const probes =
			typeof field.probe === 'string' ? [field.probe] : Object.values(field.probe || {});
		for (const probe of probes) {
			if (!schema.probes || !schema.probes[probe])
				fail(`field ${field.id} names an undeclared probe ${probe}`);
		}
		if (field.type === 'enum') {
			if (!Array.isArray(field.values) || field.values.length === 0)
				fail(`enum field ${field.id} lists no values`);
			for (const value of field.values || []) labelKeys.add(field.enum_key + value);
		}
	}
}
for (const [id, probe] of Object.entries(schema.probes || {})) {
	if (!Number.isInteger(probe.timeout_ms) || probe.timeout_ms < 1)
		fail(`probe ${id} needs a positive timeout_ms`);
}
for (const [driver, permissions] of Object.entries(schema.permissions || {})) {
	if (!DRIVERS.includes(driver)) fail(`permissions name an unknown driver ${driver}`);
	for (const [id, entry] of Object.entries(permissions)) {
		labelKeys.add(`healthcheck.permission.${id}`);
		if (entry.fix) labelKeys.add(`healthcheck.permission_fix.${id}`);
		if (entry.settings !== undefined && !/^[a-z][a-z0-9+.-]*:/.test(entry.settings)) {
			fail(`permission ${driver}.${id} opens "${entry.settings}", which is not a URL`);
		}
	}
}
for (const key of Object.values(schema.feature_labels || {})) labelKeys.add(key);
for (const bus of schema.peripheral_buses || []) labelKeys.add(`healthcheck.bus.${bus}`);
for (const kind of schema.peripheral_kinds || []) labelKeys.add(`healthcheck.device.${kind}`);

// The keys the model itself names, beyond those the schema implies
for (const key of [
	'healthcheck.value.yes',
	'healthcheck.value.no',
	'healthcheck.value.on',
	'healthcheck.value.off',
	'healthcheck.value.unknown',
	'healthcheck.value.none',
	'healthcheck.state.granted',
	'healthcheck.state.missing',
	'healthcheck.state.unknown',
	'healthcheck.state.unavailable',
	'healthcheck.state.not_used',
	'healthcheck.probe.pending',
	'healthcheck.probe.timeout',
	'healthcheck.probe.error',
	'healthcheck.probe.disabled',
	'healthcheck.probe.unsupported',
	'healthcheck.problem.none',
	'healthcheck.summary.quick',
	'healthcheck.summary.incomplete',
	'healthcheck.summary.observed',
	'healthcheck.summary.scope',
	'healthcheck.problem.diagnostic_check',
	'healthcheck.problem.paused',
	'healthcheck.problem.permission',
	'healthcheck.problem.unavailable',
	'healthcheck.problem.network',
	'healthcheck.problem.ai',
	'healthcheck.problem.errors',
	'healthcheck.problem.modules',
	'healthcheck.problem.keymap',
	'healthcheck.action.open',
	'healthcheck.action.open_settings',
	'healthcheck.export.version',
	'healthcheck.export.commit',
	'healthcheck.export.system',
	'healthcheck.export.driver',
	'healthcheck.export.generated',
	'healthcheck.export.schema',
	'healthcheck.export.details',
	'healthcheck.export.json'
]) {
	labelKeys.add(key);
}

// The keys the page itself names: its data-i18n attributes and every literal
// t('…') of its scripts, read from the sources so a new label cannot be
// forgotten here
{
	const page = path.join(SHARED, 'ui', 'healthcheck');
	const html = fs.readFileSync(path.join(page, 'index.html'), 'utf8');
	let found = 0;
	for (const match of html.matchAll(/data-i18n(?:-title|-placeholder)?="([^"]+)"/g)) {
		labelKeys.add(match[1]);
		found++;
	}
	for (const file of ['script.js', 'model.js']) {
		const source = fs.readFileSync(path.join(page, file), 'utf8');
		// A complete key only: t('healthcheck.column.' + id) builds one at run time
		for (const match of source.matchAll(/\bt\(\s*'([a-z_]+\.[a-z0-9_.]*[a-z0-9_])'\s*[,)]/g)) {
			labelKeys.add(match[1]);
			found++;
		}
	}
	if (found < 20)
		fail(`only ${found} literal page key(s) found in the page sources, expected at least 20`);
}

// Floor: the label scan must see the whole schema
if (labelKeys.size < 100)
	fail(`only ${labelKeys.size} label key(s) derived from the schema, expected at least 100`);
if (locales.size !== 21) fail(`found ${locales.size} locale catalogue(s), expected 21`);
for (const key of labelKeys) {
	for (const [code, strings] of locales) {
		if (typeof strings[key] !== 'string' || strings[key].trim() === '')
			fail(`${code}.json lacks "${key}"`);
	}
}

// The system section reports the load on every driver: the machine's free
// memory, free disk and processor load, and ErgoptiPlus's own processor share
// and memory, which a report of a slow or stuck driver is read for
for (const driver of DRIVERS) {
	const system = Model.sectionsFor(schema, driver).find((section) => section.id === 'system');
	const ids = system ? system.fields.map((field) => field.id) : [];
	for (const id of [
		'ram_free',
		'disk_free',
		'cpu_usage',
		'process_cpu',
		'process_memory',
		'uptime'
	]) {
		if (!ids.includes(id)) fail(`${driver}: the system section does not report ${id}`);
	}
}
for (const [value, expected] of [
	[12.34, '12.3%'],
	[0, '0%'],
	[100, '100%']
]) {
	const got = Model.formatValue({ type: 'percent' }, value, t);
	if (got !== expected) fail(`a percent of ${value} reads ${got}, expected ${expected}`);
}

// ================================
// ================================
// ======= 3/ Driver Fixtures =====
// ================================
// ================================

/** A complete snapshot for one driver, with every value the schema declares. */
function fixture(driver, overrides) {
	const sections = {};
	for (const section of Model.sectionsFor(schema, driver)) {
		if (section.kind === 'summary') continue;
		if (section.kind === 'items') {
			sections[section.id] = { items: [] };
			continue;
		}
		const data = {};
		for (const field of section.fields) {
			if (Model.probeFor(field, driver)) continue;
			data[field.id] = {
				text: `${field.id} value`,
				path: `/home/jdoe/${field.id}`,
				count: 3,
				bytes: 17179869184,
				seconds: 3725,
				ms: 3.4,
				percent: 12.5,
				bool: false,
				list: [`${field.id} one`, `${field.id} two`],
				log: [`2026-09-24 10:00:00:000 [ERROR] [Probe] ${field.id} <b>boom</b>`],
				enum: field.values && field.values[0]
			}[field.type];
		}
		sections[section.id] = data;
	}
	sections.features = {
		items: [
			{ id: 'hotstrings', enabled: true },
			{ id: 'gestures', enabled: 0 }
		]
	};
	sections.peripherals = {
		items: [
			{
				bus: 'usb',
				kind: 'keyboard',
				vendor_id: '046d',
				product_id: 'c52b',
				name: 'Secret Keyboard'
			}
		]
	};
	if (sections.unavailable) {
		sections.unavailable = {
			items: [
				{
					feature: 'script.alt_gr_is_kana_remap',
					platforms: 'Windows',
					reason: 'platform_reason.alt_gr_is_kana_remap'
				},
				{ feature: 'hotstrings.expansion_delay', platforms: 'macOS' }
			]
		};
	}
	const permissions = Object.keys((schema.permissions || {})[driver] || {});
	if (permissions.length > 0) {
		sections.permissions = {
			items: permissions.map((id, index) => ({ id, state: index === 0 ? 'missing' : 'granted' }))
		};
	}
	if (
		Model.sectionsFor(schema, driver).some((s) => s.fields.some((f) => f.id === 'running_apps'))
	) {
		sections.system.running_apps = ['Private Notes', 'Mail'];
	}
	const snapshot = {
		schema_version: 2,
		driver,
		generated_at: '2026-09-24T10:00:00Z',
		detailed: false,
		sections,
		probes: { github_api: { state: 'pending' }, ai_health: { state: 'timeout', ms: 4000 } }
	};
	return Object.assign(snapshot, overrides || {});
}

// =============================
// =============================
// ======= 4/ The Page =========
// =============================
// =============================

for (const driver of DRIVERS) {
	const snapshot = fixture(driver);
	const sections = Model.sectionsFor(schema, driver);
	const html = Model.renderHtml(snapshot, schema, t);

	const h2 = (html.match(/<h2>/g) || []).length;
	if (h2 !== sections.length)
		fail(`${driver}: ${h2} H2 heading(s) for ${sections.length} section(s)`);
	let last = -1;
	for (const section of sections) {
		const at = html.indexOf(`id="section-${section.id}"`);
		if (at < 0) fail(`${driver}: section ${section.id} is not rendered`);
		else if (at < last) fail(`${driver}: section ${section.id} is out of schema order`);
		last = Math.max(last, at);
	}
	const leaked = html.match(/healthcheck\.[a-z_]+\.[a-z_.]+/g);
	if (leaked) fail(`${driver}: untranslated keys in the page: ${[...new Set(leaked)].join(', ')}`);
	if (html.includes('<b>boom</b>')) fail(`${driver}: a log value reached the page unescaped`);
	if (!html.includes(t('healthcheck.probe.pending')))
		fail(`${driver}: a pending probe does not say so`);
	if (!html.includes(t('healthcheck.probe.timeout', 4000)))
		fail(`${driver}: a timed-out probe does not say so`);
	if (html.includes('Private Notes')) fail(`${driver}: an opt-in value is shown without details`);
	if (html.includes('Secret Keyboard'))
		fail(`${driver}: an opt-in column is shown without details`);
	const detailed = Model.renderHtml(Object.assign(fixture(driver), { detailed: true }), schema, t);
	const hasApps = sections.some((s) => s.fields.some((f) => f.id === 'running_apps'));
	if ((hasApps && !detailed.includes('Private Notes')) || !detailed.includes('Secret Keyboard')) {
		fail(`${driver}: opt-in values are missing once details are included`);
	}
	const pathButtons = (html.match(/data-action="open_path"/g) || []).length;
	const pathFields = sections.reduce(
		(n, s) => n + s.fields.filter((f) => f.type === 'path').length,
		0
	);
	// Paths, plus the summary's "open today's errors file" when errors exist
	if (pathFields === 0 || pathButtons < pathFields)
		fail(`${driver}: ${pathButtons} Open button(s) for ${pathFields} path(s)`);
	// The collapsed developer section stays last and collapsed
	if (!/<details class="section" id="section-developer">/.test(html))
		fail(`${driver}: the developer section is not collapsed`);
}

// Feature collection order differs across hosts. Alphabetical presentation is
// defined by translated labels, with decorative prefixes ignored, in both views.
for (const driver of DRIVERS) {
	const snapshot = fixture(driver);
	snapshot.sections.features.items = [
		{ id: 'hotstrings', enabled: true },
		{ id: 'gestures', enabled: false },
		{ id: 'shortcuts', enabled: true },
		{ id: 'unknown_feature', enabled: false }
	];
	const labels = {
		[schema.feature_labels.hotstrings]: '🔠 Zèbre',
		[schema.feature_labels.gestures]: '🖱️ Éclair',
		[schema.feature_labels.shortcuts]: '⌨️ Alpha'
	};
	const translated = (key, ...args) => labels[key] || t(key, ...args);
	const expected = ['⌨️ Alpha', '🖱️ Éclair', 'unknown_feature', '🔠 Zèbre'];
	const original = JSON.stringify(snapshot);
	const html = Model.renderHtml(snapshot, schema, translated);
	const featureHtml = html.match(/id="section-features">([\s\S]*?)<\/section>/);
	const markdown = Model.formatMarkdown(snapshot, schema, translated);
	const featureMarkdown = markdown.split(`## ${translated('healthcheck.section.features')}\n`)[1];
	if (!featureHtml || !featureMarkdown) fail(`${driver}: the feature views disappeared`);
	else {
		let lastHtml = -1;
		let lastMarkdown = -1;
		for (const label of expected) {
			const htmlAt = featureHtml[1].indexOf(`<td>${label}</td>`);
			const markdownAt = featureMarkdown.indexOf(`| ${label} |`);
			if (htmlAt < 0 || htmlAt <= lastHtml)
				fail(`${driver}: ${label} is not in translated alphabetical page order`);
			if (markdownAt < 0 || markdownAt <= lastMarkdown)
				fail(`${driver}: ${label} is not in translated alphabetical report order`);
			lastHtml = htmlAt;
			lastMarkdown = markdownAt;
		}
	}
	if (JSON.stringify(snapshot) !== original)
		fail(`${driver}: ordering features mutated the host snapshot`);
}

// The features this platform lacks, collapsed, each with its translated reason
{
	const html = Model.renderHtml(fixture('macos'), schema, t);
	if (!/<details class="section" id="section-unavailable">/.test(html))
		fail('macOS: the unavailable features are not collapsed');
	if (!html.includes(t('platform_reason.alt_gr_is_kana_remap').slice(0, 40))) {
		fail('macOS: an unavailable feature does not show its translated reason');
	}
	if (!html.includes('hotstrings.expansion_delay'))
		fail('macOS: an unavailable feature without a reason is hidden');
}

// macOS lists USB devices at once and learns its Bluetooth ones from a probe
// (hs.usb sees no Bluetooth keyboard): until that probe answers, the section
// says the list is incomplete, on the page and in the report
{
	const peripherals = Model.sectionsFor(schema, 'macos').find(
		(section) => section.id === 'peripherals'
	);
	const probeId = peripherals && Model.probeFor(peripherals, 'macos');
	if (!probeId) fail('macOS: no probe completes the peripherals with the Bluetooth devices');
	else {
		const pending = fixture('macos');
		const pendingSection = (html) =>
			html.slice(html.indexOf('id="section-peripherals"'), html.indexOf('id="section-issues"'));
		if (
			!pendingSection(Model.renderHtml(pending, schema, t)).includes(t('healthcheck.probe.pending'))
		) {
			fail('macOS: the peripherals do not say their Bluetooth devices are still being read');
		}
		const markdown = Model.formatMarkdown(pending, schema, t);
		const reportSection = markdown.slice(
			markdown.indexOf(`## ${t('healthcheck.section.peripherals')}`),
			markdown.indexOf(`## ${t('healthcheck.section.issues')}`)
		);
		if (!reportSection.includes(t('healthcheck.probe.pending')))
			fail('macOS: the report hides an unread Bluetooth list');
		const done = fixture('macos');
		done.probes[probeId] = { state: 'ok', ms: 900 };
		if (
			pendingSection(Model.renderHtml(done, schema, t)).includes(t('healthcheck.probe.pending'))
		) {
			fail('macOS: the peripherals still say "checking" once the Bluetooth probe answered');
		}
		const empty = fixture('macos');
		empty.sections.peripherals = { items: [] };
		empty.probes[probeId] = { state: 'timeout', ms: 10000 };
		const emptyHtml = pendingSection(Model.renderHtml(empty, schema, t));
		if (!emptyHtml.includes(t('healthcheck.probe.timeout', 10000)))
			fail('macOS: a timed-out Bluetooth read is not said');
	}
	const windows = Model.sectionsFor(schema, 'windows').find(
		(section) => section.id === 'peripherals'
	);
	if (windows && Model.probeFor(windows, 'windows'))
		fail('Windows reads its Bluetooth devices at once and needs no probe');
}

// A value the model does not escape would run in the page
const hostile = fixture('linux');
hostile.sections.system.os = '<img src=x onerror=alert(1)>';
if (Model.renderHtml(hostile, schema, t).includes('<img src=x'))
	fail('an OS name reached the page as HTML');

// =============================
// =============================
// ======= 5/ The Summary ======
// =============================
// =============================

{
	const snapshot = fixture('macos');
	snapshot.sections.issues.err_count = 2;
	snapshot.sections.input.paused = true;
	snapshot.probes.github_api = { state: 'error', ms: 12, detail: 'HTTP 503' };
	const list = Model.problems(snapshot, schema);
	const keys = list.map((problem) => problem.key);
	for (const key of [
		'healthcheck.problem.paused',
		'healthcheck.problem.permission',
		'healthcheck.problem.network',
		'healthcheck.problem.errors'
	]) {
		if (!keys.includes(key)) fail(`macOS summary misses ${key}`);
	}
	const permission = list.find((problem) => problem.key === 'healthcheck.problem.permission');
	if (!permission || !permission.action || permission.action.name !== 'open_settings') {
		fail('a missing macOS permission offers no settings button');
	}
	const errors = list.find((problem) => problem.key === 'healthcheck.problem.errors');
	if (!errors || errors.action.id !== 'errors_today')
		fail("the errors problem does not open today's errors file");
	const html = Model.renderHtml(snapshot, schema, t);
	if (!html.includes('data-action="open_settings"'))
		fail('the page renders no settings button for a missing permission');
	// The remap guardian: unavailable leaves every remap inert and needs Login
	// Items; « not used » is the Karabiner switch turned off, not a problem.
	const guardianState = (state) => {
		const shot = fixture('macos');
		for (const item of shot.sections.permissions.items) {
			item.state = item.id === 'login_items' ? state : 'granted';
		}
		return shot;
	};
	const loginItemsButton = 'data-action="open_settings" data-id="login_items"';
	const unavailable = guardianState('unavailable');
	const unavailableProblem = Model.problems(unavailable, schema).find(
		(problem) => problem.key === 'healthcheck.problem.unavailable'
	);
	if (
		!unavailableProblem ||
		!unavailableProblem.action ||
		unavailableProblem.action.id !== 'login_items'
	) {
		fail('an unavailable remap guardian is not a problem that opens Login Items');
	}
	if (!Model.renderHtml(unavailable, schema, t).includes(loginItemsButton))
		fail('an unavailable remap guardian row offers no Login Items button');
	const notUsed = guardianState('not_used');
	if (Model.problems(notUsed, schema).some((problem) => /permission|unavailable/.test(problem.key)))
		fail('a Karabiner switch turned off is reported as a problem');
	if (Model.renderHtml(notUsed, schema, t).includes(loginItemsButton))
		fail('an unused remap guardian row still offers the Login Items button');
	const healthy = fixture('windows');
	healthy.probes.github_api = { state: 'ok', ms: 80 };
	healthy.probes.ai_health = { state: 'disabled' };
	healthy.sections.issues.err_count = 0;
	healthy.sections.developer.modules_failed = [];
	if (Model.problems(healthy, schema).length !== 0)
		fail('a healthy Windows snapshot lists problems');
	if (!Model.renderHtml(healthy, schema, t).includes(t('healthcheck.summary.quick'))) {
		fail(
			'a healthy quick snapshot must state its limited scope without claiming in-depth acceptance'
		);
	}
	const linux = fixture('linux');
	linux.sections.input.keymap_resolved = false;
	if (
		!Model.problems(linux, schema).some((problem) => problem.key === 'healthcheck.problem.keymap')
	) {
		fail('an unresolved Linux keymap is not a problem');
	}
}

// ==============================
// ==============================
// ======= 6/ The Report ========
// ==============================
// ==============================

for (const driver of DRIVERS) {
	const snapshot = fixture(driver);
	snapshot.sections.issues.last_error = 'a ```` fenced ``` value';
	const markdown = Model.formatMarkdown(snapshot, schema, t);
	let last = -1;
	for (const section of Model.sectionsFor(schema, driver)) {
		const title = t(`healthcheck.section.${section.id}`);
		const at = markdown.indexOf(
			section.collapsed ? `<summary>${title}</summary>` : `## ${title}\n`
		);
		if (at < 0) fail(`${driver}: the report has no ${section.id} section`);
		else if (at < last) fail(`${driver}: the report's ${section.id} section is out of order`);
		last = Math.max(last, at);
	}
	if (markdown.includes('Private Notes') || markdown.includes('Secret Keyboard')) {
		fail(`${driver}: the report carries opt-in values without details`);
	}
	if (!markdown.includes('`````text'))
		fail(`${driver}: a fence does not outgrow the backticks of its content`);
	// The snapshot carries the backticks of last_error, so its fence is longer too
	const json = markdown.match(/(`{3,})json\n([\s\S]*?)\n\1\n/);
	if (!json) fail(`${driver}: the report has no JSON block`);
	else {
		if (json[1].length <= 4)
			fail(`${driver}: the JSON fence does not outgrow the backticks it holds`);
		const parsed = JSON.parse(json[2]);
		if (parsed.driver !== driver || parsed.schema_version !== 2)
			fail(`${driver}: the JSON block is not the snapshot`);
		if (parsed.sections.system.running_apps !== undefined)
			fail(`${driver}: the JSON block carries opt-in values`);
	}
	const detailed = Model.formatMarkdown(
		Object.assign(fixture(driver), { detailed: true }),
		schema,
		t
	);
	if (!detailed.includes('Secret Keyboard'))
		fail(`${driver}: the detailed report drops the opt-in values`);
	if (!markdown.startsWith(`# ErgoptiPlus — ${t('menu.debug.healthcheck')}\n`))
		fail(`${driver}: the report has no title`);
}

// =====================================
// =====================================
// ======= 7/ Issue Fields And Name =====
// =====================================
// =====================================

// The page formats every duration; the corpus once pinned the Lua and AHK
// formatters it replaces
{
	const corpus = JSON.parse(
		fs.readFileSync(
			path.join(SHARED, 'tests', 'corpus', 'healthcheck', 'snapshot_vectors.json'),
			'utf8'
		)
	);
	const uptime = corpus.vectors.filter((vector) => vector.category === 'format_uptime');
	if (uptime.length < 4) fail('fewer than 4 format_uptime vectors');
	for (const vector of uptime) {
		const got = Model.formatValue({ type: 'seconds' }, vector.input.sec, t);
		if (got !== vector.expected)
			fail(`format_uptime ${vector.id}: got ${got}, expected ${vector.expected}`);
	}
}

const vectors = JSON.parse(
	fs.readFileSync(
		path.join(SHARED, 'tests', 'corpus', 'diagnostics', 'issue_report_vectors.json'),
		'utf8'
	)
);
if (!Array.isArray(vectors.file_name_vectors) || vectors.file_name_vectors.length < 2)
	fail('fewer than 2 file name vectors');
for (const vector of vectors.file_name_vectors || []) {
	const got = Model.fileName(vector.info);
	if (got !== vector.expected) fail(`file name ${vector.id}: got ${got}`);
}
{
	const info = Model.reportInfo(fixture('windows'));
	if (info.file_stamp !== '20260924T100000Z')
		fail(`the file stamp of 2026-09-24T10:00:00Z is ${info.file_stamp}`);
	const fields = Model.issueFields(info);
	for (const id of ['version', 'os', 'driver']) {
		if (typeof fields[id] !== 'string' || fields[id] === '') fail(`the issue field ${id} is empty`);
	}
	// The host fills the report field with the whole report: a summary sent
	// by the page would be refused by its validator
	const templates = JSON.parse(
		fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'issue_templates.json'), 'utf8')
	);
	if (Object.prototype.hasOwnProperty.call(fields, templates.templates.bug.report_field)) {
		fail(`the page must not fill the report field ${templates.templates.bug.report_field}`);
	}
	if ('issueSummary' in Model) fail('the model still exports a short issue summary');
}

// =========================
// =========================
// ======= 8/ Verdict ======
// =========================
// =========================

require('./fixtures/healthcheck-sharing-controls.cjs').run(ROOT);
require('./fixtures/diagnostic-checks-controls.cjs').run(ROOT);
require('./fixtures/diagnostic-summary-controls.cjs').run(ROOT);

if (failures.length > 0) {
	console.error(`[FAIL] diagnostics page model: ${failures.length} failure(s)`);
	for (const failure of failures.slice(0, 60)) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	`[OK] diagnostics page model: ${sectionIds.size} section(s), ${fieldIds.size} field(s) and ${labelKeys.size} ` +
		'label(s) in 21 locales; page, summary, report and issue text agree with the schema on the three drivers.'
);
