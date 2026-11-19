// tools/test/lib/i18n-dynamic-keys/pages.cjs

/**
 * ==============================================================================
 * MODULE: Page Key Families
 * DESCRIPTION:
 * The run-time key families of the shared pages: the diagnostics window
 * (model.js, checks.js, script.js and its native Windows fallback core.ahk),
 * the layout manager, and the metrics charts. The diagnostics families read
 * the diagnostics schema the page renders from; the others read the constant
 * tables and loops of the page script itself, since those are the only
 * source of the ids the page appends.
 * ==============================================================================
 */

'use strict';

const ctx = require('./context.cjs');

const ROOT = 'static/ergopti_plus/';
const SCHEMA = ROOT + '_shared/diagnostics/data/schema.json';
const MODEL = ROOT + '_shared/ui/healthcheck/model.js';
const CHECKS = ROOT + '_shared/ui/healthcheck/checks.js';
const PAGE_SCRIPT = ROOT + '_shared/ui/healthcheck/script.js';
const NATIVE = ROOT + 'windows/diagnostics/ui/healthcheck/core.ahk';
const LAYOUT_MANAGER = ROOT + '_shared/ui/layout_manager/script.js';
const APPS_HELPERS = ROOT + '_shared/ui/metrics_apps/helpers.js';
const APPS_CHARTS = ROOT + '_shared/ui/metrics_apps/charts.js';
const TYPING_CHARTS = ROOT + '_shared/ui/metrics_typing/charts.js';
const CATALOGUE_AHK = ROOT + 'windows/modules/keymap/keylayout/layout_catalogue.ahk';
const CATALOGUE_LUA = ROOT + '_shared/layouts/engine/composer/catalogue.lua';

// ==========================================
// ==========================================
// ======= 1/ Readers =======================
// ==========================================
// ==========================================

/**
 * The diagnostics schema the page and the native view both render from.
 * @returns {object}
 */
function schema() {
	return ctx.json(SCHEMA);
}

/**
 * The field rules the share policy enforces on one items section's rows: the
 * enums there are the values a driver may send for each column.
 * @param {string} section - Schema section id.
 * @returns {object}
 */
function itemFields(section) {
	const policy = schema().share_policy.projection.fields.sections.fields[section];
	return policy.fields.items.item.fields;
}

/**
 * Every match of a pattern's first group in a text, failing when none is
 * found so a renamed site cannot read as an empty family.
 * @param {string} text
 * @param {RegExp} pattern - Global pattern with one group.
 * @param {string} what - What the pattern reads, for the error.
 * @returns {string[]}
 */
function allOf(text, pattern, what) {
	const ids = [...text.matchAll(pattern)].map((m) => m[1]);
	if (ids.length === 0) throw new Error(`no ${what} found`);
	return ids;
}

/**
 * The text of a function's body in a page script.
 * @param {string} rel - Repository-relative path.
 * @param {string} name - Function name.
 * @returns {string}
 */
function functionBody(rel, name) {
	const text = ctx.read(rel);
	const start = text.indexOf(`function ${name}(`);
	if (start < 0) throw new Error(`${rel} defines no ${name}`);
	const end = text.indexOf('\n}', start);
	return text.slice(start, end < 0 ? undefined : end);
}

/**
 * The integers a `[0, 1, ...].map(...)` list holds in a page function.
 * @param {string} rel - Repository-relative path.
 * @param {string} name - Function name.
 * @returns {string[]}
 */
function mappedIndexes(rel, name) {
	const m = /\[([\d,\s]+)\]\.map/.exec(functionBody(rel, name));
	if (!m) throw new Error(`${name} maps no index list`);
	return m[1].split(',').map((n) => n.trim());
}

/**
 * The values of the contiguous constant block that follows a comment line:
 * the catalogue sources are declared together under one comment, apart from
 * the other sources (the composer) the page never shows.
 * @param {string} rel - Repository-relative path.
 * @param {string} comment - The comment text opening the block.
 * @param {RegExp} line - Pattern of one declaration, one group for its value.
 * @returns {string[]}
 */
function constantBlock(rel, comment, line) {
	const lines = ctx.read(rel).split('\n');
	let at = lines.findIndex((l) => l.includes(comment));
	if (at < 0) throw new Error(`${rel} has no "${comment}" block`);
	const ids = [];
	for (at++; at < lines.length; at++) {
		const m = line.exec(lines[at]);
		if (!m) break;
		ids.push(m[1]);
	}
	if (ids.length === 0) throw new Error(`${rel}: the "${comment}" block is empty`);
	return ids;
}

// ==========================================
// ==========================================
// ======= 2/ Families ======================
// ==========================================
// ==========================================

module.exports = [
	{
		prefix: 'app_category.',
		files: [APPS_HELPERS],
		source: 'the preset ids of CATEGORY_ID_MAP in metrics_apps/helpers.js (CATEGORY_IDS)',
		keys: () =>
			ctx.keysOf('app_category.', Object.values(ctx.literal(APPS_HELPERS, 'CATEGORY_ID_MAP')))
	},
	{
		prefix: 'healthcheck.bus.',
		files: [MODEL],
		source: 'the peripheral_buses of the diagnostics schema',
		keys: () => ctx.keysOf('healthcheck.bus.', schema().peripheral_buses)
	},
	{
		prefix: 'healthcheck.column.',
		files: [MODEL],
		source: 'the columns of every items section of the diagnostics schema',
		keys: () =>
			schema()
				.sections.filter((section) => section.kind === 'items')
				.flatMap((section) =>
					section.columns.map((column) => `healthcheck.column.${section.id}.${column}`)
				)
	},
	{
		prefix: 'healthcheck.config_file.',
		files: [MODEL],
		source:
			"every driver's configuration.files of the diagnostics schema and the share policy's id enum",
		keys: () =>
			ctx.keysOf('healthcheck.config_file.', [
				...Object.values(schema().configuration.files).flat(),
				...itemFields('configuration_files').id.values
			])
	},
	{
		prefix: 'healthcheck.config_state.',
		files: [MODEL],
		source: "configuration.states of the diagnostics schema and the share policy's state enum",
		keys: () =>
			ctx.keysOf('healthcheck.config_state.', [
				...schema().configuration.states,
				...itemFields('configuration_files').state.values
			])
	},
	{
		prefix: 'healthcheck.day_log.',
		files: [PAGE_SCRIPT],
		source:
			'the day-log phases whose case labels fall through to the phase-named key in healthcheck/script.js',
		keys: () => {
			const m =
				/((?:case\s+'\w+':\s*)+)status\.textContent = t\('healthcheck\.day_log\.' \+ dayLog\.phase\)/.exec(
					ctx.read(PAGE_SCRIPT)
				);
			if (!m) throw new Error('the phase-named day-log key moved');
			return ctx.keysOf('healthcheck.day_log.', allOf(m[1], /case\s+'(\w+)'/g, 'phase'));
		}
	},
	{
		prefix: 'healthcheck.deep_tests.reason.',
		files: [CHECKS, MODEL],
		source:
			"the reasons of the schema's diagnostic_checks items, plus the not-run reasons checks.js writes (`reason: '...'`) and model.js defaults to",
		keys: () =>
			// Only a not_run result is labelled. checks.js assigns its other reason
			// (`result.reason = '...'`) to a failed check, which shows FAIL instead.
			ctx.keysOf('healthcheck.deep_tests.reason.', [
				...schema()
					.diagnostic_checks.items.filter((item) => item.reason)
					.map((item) => item.reason),
				...allOf(ctx.read(CHECKS), /reason:[^\n]*?'(\w+)'/g, 'not-run reason'),
				...allOf(ctx.read(MODEL), /result\.reason \|\| '(\w+)'/g, 'default reason')
			])
	},
	{
		prefix: 'healthcheck.device.',
		files: [MODEL],
		source: 'the peripheral_kinds of the diagnostics schema',
		keys: () => ctx.keysOf('healthcheck.device.', schema().peripheral_kinds)
	},
	{
		prefix: 'healthcheck.field.',
		files: [MODEL, NATIVE],
		source:
			'the field ids of every section of the diagnostics schema (the page and the native view)',
		keys: () =>
			ctx.keysOf(
				'healthcheck.field.',
				schema().sections.flatMap((section) => (section.fields || []).map((field) => field.id))
			)
	},
	{
		prefix: 'healthcheck.permission.',
		files: [MODEL],
		source:
			"the permission ids of the diagnostics schema's permissions and of the share policy's id enum",
		keys: () =>
			ctx.keysOf('healthcheck.permission.', [
				...Object.values(schema().permissions).flatMap(Object.keys),
				...itemFields('permissions').id.values
			])
	},
	{
		prefix: 'healthcheck.permission_fix.',
		files: [MODEL],
		source: 'the permissions the diagnostics schema marks with a fix, on any driver',
		keys: () =>
			ctx.keysOf(
				'healthcheck.permission_fix.',
				Object.values(schema().permissions).flatMap((byId) =>
					Object.keys(byId).filter((id) => byId[id].fix)
				)
			)
	},
	{
		prefix: 'healthcheck.section.',
		files: [MODEL, NATIVE],
		source: 'the section ids of the diagnostics schema (the page and the native view)',
		keys: () =>
			ctx.keysOf(
				'healthcheck.section.',
				schema().sections.map((section) => section.id)
			)
	},
	{
		prefix: 'healthcheck.setting_type.',
		files: [MODEL],
		source: 'configuration.types of the diagnostics schema',
		keys: () => ctx.keysOf('healthcheck.setting_type.', schema().configuration.types)
	},
	{
		prefix: 'healthcheck.state.',
		files: [MODEL],
		source: "the share policy's permission state enum in the diagnostics schema",
		keys: () => ctx.keysOf('healthcheck.state.', itemFields('permissions').state.values)
	},
	{
		prefix: 'layout_manager.source_',
		files: [LAYOUT_MANAGER],
		source:
			'the catalogue index sources of layout_catalogue.ahk (Windows) and composer/catalogue.lua (macOS, Linux), plus the page default none',
		keys: () =>
			ctx.keysOf('layout_manager.source_', [
				...constantBlock(
					CATALOGUE_AHK,
					'Where the index the catalogue shows comes from.',
					/^global LAYOUT_CATALOGUE_SOURCE_\w+ := "(\w+)"/
				),
				...constantBlock(
					CATALOGUE_LUA,
					'Where the index shown by the catalogue comes from.',
					/^M\.SOURCE_\w+ = "(\w+)"/
				),
				// The page's own fallback when a host sends no source.
				...allOf(
					functionBody(LAYOUT_MANAGER, 'catalogueStatus'),
					/typeof state\.source === 'string' \? state\.source : '(\w+)'/g,
					'default source'
				)
			])
	},
	{
		prefix: 'layout_manager.status_',
		files: [LAYOUT_MANAGER],
		source: 'the statuses makeRow assigns in layout_manager/script.js',
		keys: () =>
			ctx.keysOf(
				'layout_manager.status_',
				allOf(functionBody(LAYOUT_MANAGER, 'makeRow'), /status = '(\w+)'/g, 'row status')
			)
	},
	{
		prefix: 'ui_typing.calendar_month_',
		files: [APPS_CHARTS],
		source: 'getUTCMonth(), whose 0..11 range the calendar fixes',
		keys: () =>
			ctx.keysOf(
				'ui_typing.calendar_month_',
				Array.from({ length: 12 }, (_, month) => String(month))
			)
	},
	{
		prefix: 'ui_typing.day_',
		files: [TYPING_CHARTS],
		source: 'the weekday indexes days_fr maps in metrics_typing/charts.js',
		keys: () => ctx.keysOf('ui_typing.day_', mappedIndexes(TYPING_CHARTS, 'days_fr'))
	},
	{
		prefix: 'ui_typing.heatmap_day_',
		files: [APPS_HELPERS],
		source: 'the weekday ids metricWeekdayLabels maps in metrics_apps/helpers.js',
		keys: () => {
			const m = /\[([^\]]+)\]\.map/.exec(functionBody(APPS_HELPERS, 'metricWeekdayLabels'));
			if (!m) throw new Error('metricWeekdayLabels maps no weekday list');
			return ctx.keysOf('ui_typing.heatmap_day_', allOf(m[1], /'(\w+)'/g, 'weekday'));
		}
	},
	{
		prefix: 'ui_typing.month_',
		files: [TYPING_CHARTS],
		source: 'the month indexes months_fr maps in metrics_typing/charts.js',
		keys: () => ctx.keysOf('ui_typing.month_', mappedIndexes(TYPING_CHARTS, 'months_fr'))
	}
];
