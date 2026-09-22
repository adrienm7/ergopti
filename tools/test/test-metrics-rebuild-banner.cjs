// tools/test/test-metrics-rebuild-banner.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Rebuild Banner Guard
 * DESCRIPTION:
 * Executes the real _shared/ui/metrics_rebuild_banner.js and asserts how the
 * metrics dashboards describe a statistics rebuild that is still running.
 *
 * ROOT CAUSE ENCODED:
 * A cold rebuild of a large metrics store showed nothing at all for tens of
 * minutes, with no sign that anything was happening or that the worker had
 * died. The progress bar must show the host's real percentage and measured
 * remaining time, and turn into an error when the worker fails.
 *
 * The worker also publishes snapshots covering the newest days first;
 * a page that rendered them without saying so would present a week of data as
 * the whole history. Every snapshot marked `_partial` must therefore be named
 * as partial, with the oldest rebuilt day, and a complete snapshot must clear
 * that notice. Both dashboards must route every snapshot through the banner.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const p = require('path');

const ROOT = p.resolve(__dirname, '..', '..');
const UI = p.join(ROOT, 'static/ergopti_plus/_shared/ui');
const REL = 'static/ergopti_plus/_shared/ui/metrics_rebuild_banner.js';
const LOCALES = p.join(ROOT, 'static/ergopti_plus/_shared/data/locales');

const errors = [];

function check(condition, message) {
	if (!condition) errors.push(message);
}

function load_api() {
	const src = fs.readFileSync(p.join(ROOT, REL), 'utf8');
	const window = {};
	new Function('window', src)(window);
	return window.metrics_rebuild;
}

const api = load_api();
check(api && typeof api.describe_partial === 'function', `${REL}: must expose describe_partial`);

const en = JSON.parse(fs.readFileSync(p.join(LOCALES, 'en.json'), 'utf8'));
const fr = JSON.parse(fs.readFileSync(p.join(LOCALES, 'fr.json'), 'utf8'));

if (api) {
	// ── 1. A partial snapshot is named, with how far back it reaches ────────
	const text = api.describe_partial({ oldest: '2026-08-01', newest: '2026-09-22' }, en, 'en');
	check(
		text.includes('August 1, 2026'),
		`${REL}: the notice must name the oldest rebuilt day, got "${text}"`
	);
	check(!text.includes('{date}'), `${REL}: the notice must fill its placeholder, got "${text}"`);
	check(text !== 'ui_metrics_rebuild.partial', `${REL}: the English notice must be translated`);
	const french = api.describe_partial({ oldest: '2026-08-01' }, fr, 'fr');
	check(
		/1(er)? août 2026/.test(french),
		`${REL}: the French notice must use a French date, got "${french}"`
	);

	// ── 2. A complete snapshot clears the notice ────────────────────────────
	check(
		api.describe_partial(undefined, en, 'en') === '',
		`${REL}: a complete snapshot must clear the notice`
	);
	check(
		api.describe_partial({}, en, 'en') === '',
		`${REL}: a snapshot without an oldest day is not partial`
	);

	// ── 2b. Progress shows the host's percentage and remaining time ─────────
	const running = api.describe_progress({ state: 'running', percent: 37.9, eta_s: 3725 }, en);
	check(
		running.visible && !running.failed,
		`${REL}: a running rebuild must be visible and not failed`
	);
	check(
		running.percent === 37,
		`${REL}: the bar must show the floored host percentage, got ${running.percent}`
	);
	check(
		running.text.includes('37%') && running.text.includes('1:02:05'),
		`${REL}: the text must carry the percentage and h:mm:ss remaining time, got "${running.text}"`
	);
	const unknown = api.describe_progress({ state: 'running', percent: 2, eta_s: -1 }, en);
	check(
		unknown.text.includes(en['ui_metrics_rebuild.eta_unknown']),
		`${REL}: an unknown ETA must say so`
	);
	const failed = api.describe_progress({ state: 'failed' }, en);
	check(
		failed.visible && failed.failed && failed.text === en['ui_metrics_rebuild.failed'],
		`${REL}: a dead worker must show the error state`
	);
	check(
		api.describe_progress({ state: 'finalizing' }, en).percent === 100,
		`${REL}: finalizing is a full bar`
	);
	check(
		!api.describe_progress({ state: 'done' }, en).visible,
		`${REL}: a finished rebuild hides the bar`
	);
	check(
		api.format_eta(59) === '0:59' && api.format_eta(600) === '10:00',
		`${REL}: format_eta must be m:ss`
	);
}

// ── 3. Every dashboard routes every snapshot through the banner ─────────────
for (const page of ['metrics_typing', 'metrics_apps']) {
	const html = fs.readFileSync(p.join(UI, page, 'index.html'), 'utf8');
	check(
		html.includes('<script src="../metrics_rebuild_banner.js"></script>'),
		`${page}/index.html: must load the rebuild banner`
	);
	const apply = html.indexOf('function apply_prefetch(blob)');
	const mark = html.indexOf('window.metrics_rebuild.mark_snapshot(blob)', apply);
	const next = html.indexOf('function ', apply + 10);
	check(
		apply > 0 && mark > apply && (next < 0 || mark < next),
		`${page}/index.html: apply_prefetch must mark every snapshot as partial or complete`
	);
	check(
		/type === 'rebuild_progress'\) \{\s*if \(window\.metrics_rebuild\) window\.metrics_rebuild\.show_progress\(payload\.progress\);/.test(
			html
		),
		`${page}/index.html: the WebView listener must route rebuild progress to the banner`
	);
}

// ── 4. The notice exists in every locale ────────────────────────────────────
for (const file of fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'))) {
	const strings = JSON.parse(fs.readFileSync(p.join(LOCALES, file), 'utf8'));
	const value = strings['ui_metrics_rebuild.partial'];
	check(
		typeof value === 'string' && value.includes('{date}'),
		`${file}: ui_metrics_rebuild.partial needs {date}`
	);
	const placeholders = {
		'ui_metrics_rebuild.progress': ['{percent}', '{remaining}'],
		'ui_metrics_rebuild.eta': ['{eta}'],
		'ui_metrics_rebuild.eta_unknown': [],
		'ui_metrics_rebuild.finalizing': [],
		'ui_metrics_rebuild.failed': []
	};
	for (const [key, needed] of Object.entries(placeholders)) {
		const text = strings[key];
		check(
			typeof text === 'string' && text !== '' && needed.every((n) => text.includes(n)),
			`${file}: ${key} must exist with ${needed.join(' ') || 'text'}`
		);
	}
}

if (errors.length) {
	for (const e of errors) console.error('  ✗ ' + e);
	console.error(`metrics rebuild banner: ${errors.length} failure(s).`);
	process.exit(1);
}
console.log('metrics rebuild banner: OK');
