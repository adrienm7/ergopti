// tools/test/test-metrics-freshness-banner.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Freshness Banner Guard
 * DESCRIPTION:
 * Executes the real _shared/ui/metrics_freshness.js and asserts how the typing
 * dashboard labels data that is not current.
 *
 * ROOT CAUSE ENCODED:
 * The macOS typing dashboard took about ten seconds to show anything because
 * it projected all of history before painting. It now paints the last saved
 * snapshot at once; that snapshot can be hours or days old, so it must say
 * when it was computed and that an update is running, a first open must say
 * that data is loading, and a failed update must keep the snapshot's date
 * visible instead of leaving a permanent "updating" notice. A delayed older
 * state must never cover a newer one.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const p = require('path');

const ROOT = p.resolve(__dirname, '..', '..');
const UI = p.join(ROOT, 'static/ergopti_plus/_shared/ui');
const REL = 'static/ergopti_plus/_shared/ui/metrics_freshness.js';
const LOCALES = p.join(ROOT, 'static/ergopti_plus/_shared/data/locales');

const errors = [];

function check(condition, message) {
	if (!condition) errors.push(message);
}

function load_api() {
	const src = fs.readFileSync(p.join(ROOT, REL), 'utf8');
	const window = {};
	new Function('window', src)(window);
	return window.metrics_freshness;
}

const api = load_api();
check(
	api && typeof api.describe_freshness === 'function',
	`${REL}: must expose describe_freshness`
);

const en = JSON.parse(fs.readFileSync(p.join(LOCALES, 'en.json'), 'utf8'));
const fr = JSON.parse(fs.readFileSync(p.join(LOCALES, 'fr.json'), 'utf8'));
// 2026-09-29 14:05 local time
const AT = new Date(2026, 8, 29, 14, 5).getTime();

if (api) {
	// ── 1. A cached snapshot names when it was computed ─────────────────────
	const stale = api.describe_freshness({ state: 'stale', generated_at: AT }, fr, 'fr');
	check(stale.visible && !stale.failed, `${REL}: a stale snapshot must be labelled`);
	check(
		/^Données du 29 septembre 2026/.test(stale.text) && stale.text.includes('mise à jour en cours'),
		`${REL}: the French label must read « Données du <date> — mise à jour en cours… », got "${stale.text}"`
	);
	check(stale.text.includes('14:05'), `${REL}: the label must carry the time, got "${stale.text}"`);
	check(!stale.text.includes('{date}'), `${REL}: the placeholder must be filled`);

	// ── 2. First open and failures ──────────────────────────────────────────
	const loading = api.describe_freshness({ state: 'loading' }, en, 'en');
	check(
		loading.visible && loading.text === en['ui_metrics_freshness.loading'],
		`${REL}: a first open without a snapshot must show the loading notice`
	);
	const failed = api.describe_freshness({ state: 'failed', generated_at: AT }, en, 'en');
	check(
		failed.visible && failed.failed && failed.text.includes('September 29, 2026'),
		`${REL}: a failed update must keep the snapshot's date visible, got "${failed.text}"`
	);
	const failed_empty = api.describe_freshness({ state: 'failed' }, en, 'en');
	check(
		failed_empty.failed && failed_empty.text === en['ui_metrics_freshness.failed_empty'],
		`${REL}: a failed first load must say so`
	);
	check(
		!api.describe_freshness({ state: 'fresh' }, en, 'en').visible,
		`${REL}: fresh data hides the banner`
	);
	check(
		!api.describe_freshness({ state: 'stale' }, en, 'en').visible,
		`${REL}: a stale state without a date is not shown as dated data`
	);
}

// ── 3. The typing dashboard routes every host state through the banner ─────
const html = fs.readFileSync(p.join(UI, 'metrics_typing', 'index.html'), 'utf8');
check(
	html.indexOf('<script src="../metrics_freshness.js"></script>') > 0 &&
		html.indexOf('<script src="../metrics_freshness.js"></script>') <
			html.indexOf('<script src="data.js"></script>'),
	'metrics_typing/index.html: must load the freshness banner before data.js'
);
const data = fs.readFileSync(p.join(UI, 'metrics_typing', 'data.js'), 'utf8');
check(
	/window\.metrics_freshness\.show\(metadata\.freshness, metadata\.manifest_revision\)/.test(data),
	'metrics_typing/data.js: publications must apply their freshness with their revision'
);
check(
	/window\.setTypingMetricsFreshness = function \(freshness, revision\)/.test(data),
	'metrics_typing/data.js: the host needs a data-less freshness entry point'
);

// ── 4. Every locale carries the strings and their placeholders ─────────────
for (const file of fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'))) {
	const strings = JSON.parse(fs.readFileSync(p.join(LOCALES, file), 'utf8'));
	const placeholders = {
		'ui_metrics_freshness.stale': ['{date}'],
		'ui_metrics_freshness.loading': [],
		'ui_metrics_freshness.failed': ['{date}'],
		'ui_metrics_freshness.failed_empty': []
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
	console.error(`metrics freshness banner: ${errors.length} failure(s).`);
	process.exit(1);
}
console.log('metrics freshness banner: OK');
