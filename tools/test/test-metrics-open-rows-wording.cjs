// tools/test/test-metrics-open-rows-wording.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Menu Dashboard Rows Wording Tests
 * DESCRIPTION:
 * The Metrics menu has two rows that each open a window: the typing metrics
 * and the time spent in applications. In the 21 locales both rows start with
 * the same noun, the dashboard, and only their end names which one (the
 * maintainer's rules of 2026-10-01, metrics-open-rows-wording).
 *
 * FEATURES & RATIONALE:
 * 1. The rows read « Afficher les métriques de frappe » and « Afficher le
 *    temps sur les applications »: two sentences with nothing in common, for
 *    two rows that do the same thing to two windows.
 * 2. They then read « Ouvrir le tableau de bord … »: a row of a menu is
 *    clicked to open what it names, so the verb said nothing. The rows name
 *    the dashboard, and the verb each locale used is refused here.
 * 3. The common beginning is measured, not eyeballed: the whole first word of
 *    both labels, and never the whole label, so the two rows stay distinct.
 * 4. A locale with no space between words, or whose natural phrase would put
 *    the window first, names the dashboard and then the window after a colon.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const locales = path.resolve(__dirname, '../../static/ergopti_plus/_shared/data/locales');
const KEYS = ['menu.metrics.show_typing', 'menu.metrics.show_apps'];

// How each locale said « open » while the rows carried the verb.
const RETIRED_VERBS = {
	ar: 'فتح',
	cs: 'Otevřít',
	da: 'Åbn',
	de: 'öffnen',
	en: 'Open',
	es: 'Abrir',
	fr: 'Ouvrir',
	he: 'פתח',
	hi: 'खोलें',
	it: 'Apri',
	ja: '開く',
	ko: '열기',
	nl: 'openen',
	no: 'Åpne',
	pl: 'Otwórz',
	pt: 'Abrir',
	ru: 'Открыть',
	sv: 'Öppna',
	tr: 'aç',
	uk: 'Відкрити',
	zh: '打开'
};

const files = fs.readdirSync(locales).filter((name) => name.endsWith('.json'));
assert.equal(files.length, 21, 'the 21 locales are checked');
assert.equal(Object.keys(RETIRED_VERBS).length, 21, 'every locale has its retired verb');

/** The label's first word: up to its first space or colon. */
function firstWord(label) {
	return [...label.split(/[\s:：]/)[0]];
}

for (const file of files) {
	const code = file.replace(/\.json$/, '');
	const strings = JSON.parse(fs.readFileSync(path.join(locales, file), 'utf8'));
	const [typing, apps] = KEYS.map((key) => strings[key]);
	assert.ok(typeof typing === 'string' && typeof apps === 'string', `${file}: both rows are named`);
	const first = [...typing];
	const second = [...apps];
	let common = 0;
	while (common < first.length && common < second.length && first[common] === second[common])
		common++;
	const word = firstWord(typing);
	assert.ok(word.length >= 2, `${file}: « ${typing} » starts with a word`);
	assert.ok(
		common >= word.length && firstWord(apps).join('') === word.join(''),
		`${file}: « ${typing} » and « ${apps} » do not start with the same word`
	);
	assert.ok(
		common < Math.min(first.length, second.length),
		`${file}: the two rows must still name different windows`
	);
	const verb = RETIRED_VERBS[code];
	assert.ok(verb, `${file}: no retired verb is declared for this locale`);
	for (const label of [typing, apps]) {
		const words = label.split(/[\s:：]+/);
		assert.ok(
			!words.includes(verb) && !label.startsWith(verb) && !label.includes(verb + ':'),
			`${file}: « ${label} » still says « ${verb} »: the row names the dashboard, not the action`
		);
	}
}

const french = JSON.parse(fs.readFileSync(path.join(locales, 'fr.json'), 'utf8'));
assert.equal(french[KEYS[0]], 'Tableau de bord des métriques de frappe');
assert.equal(french[KEYS[1]], 'Tableau de bord du temps sur les applications');

console.log(
	'[OK] metrics menu: the two dashboard rows start with the same word and carry no verb in the 21 locales.'
);

// A retired feature must not return through a generated default or a scope.
const TOML = require('smol-toml');
const shared = path.resolve(__dirname, '../../static/ergopti_plus/_shared');
const manifest = TOML.parse(
	fs.readFileSync(path.join(shared, 'modules/features/manifest.toml'), 'utf8')
);
const retiredMetrics = [
	'metrics_shortcut_typing',
	'metrics_shortcut_apps',
	'shortcut',
	'apps_shortcut'
];
assert.ok(manifest.features.metrics.length > 10, 'the actual Metrics catalogue stays populated');
for (const id of retiredMetrics) {
	assert.ok(
		!manifest.features.metrics.some((feature) => feature.id === id),
		`${id}: retired binding is unowned`
	);
}
const actions = TOML.parse(
	fs.readFileSync(path.join(shared, 'modules/actions/actions.toml'), 'utf8')
);
for (const id of ['open_metrics_typing', 'open_metrics_apps']) {
	assert.equal(
		actions.sg_actions[id].platform,
		'all',
		`${id}: the ordinary action remains on every driver`
	);
}
for (const file of files) {
	const strings = JSON.parse(fs.readFileSync(path.join(locales, file), 'utf8'));
	const key = 'platform_reason.metrics_extras_are_not_on_linux';
	assert.equal(typeof strings[key], 'string');
	assert.ok(strings[key].length > 10, `${file}: the exclusion-list refusal is explained`);
	assert.ok(
		!Object.keys(strings).some(
			(id) => id.startsWith('menu.metrics.shortcut_') || id.startsWith('metrics.shortcut_')
		),
		`${file}: the removed dedicated shortcut UI has no orphan labels`
	);
}

// Maintained target-schema examples must not recommend a retired binding owner.
// Parse each real table header: these drafts contain unrelated duplicate scalar
// examples, so this does not pretend to validate their whole-document grammar.
for (const file of ['ahk_config.example.toml', 'hs_config.example.toml']) {
	const source = fs.readFileSync(path.join(shared, 'core/config_schema/examples', file), 'utf8');
	const headers = source
		.split('\n')
		.filter((line) => /^\s*\[\[?[^\]]+\]\]?\s*(?:#.*)?$/.test(line));
	assert.ok(headers.length > 0, `${file}: actual draft sections must be present`);
	let metricsFound = false;
	for (const header of headers) {
		const declared = TOML.parse(header + '\n');
		if (Object.hasOwn(declared, 'metrics')) metricsFound = true;
		assert.ok(
			!Object.hasOwn(declared.metrics || {}, 'shortcuts'),
			`${file}: the draft must not revive dedicated Metrics-window shortcuts`
		);
	}
	assert.ok(metricsFound, `${file}: actual Metrics draft sections remain`);
}
