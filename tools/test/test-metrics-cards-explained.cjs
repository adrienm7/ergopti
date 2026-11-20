// tools/test/test-metrics-cards-explained.cjs

/**
 * ==============================================================================
 * MODULE: Typing Dashboard Cards Explained
 * DESCRIPTION:
 * Every figure card of the typing dashboard (_shared/ui/metrics_typing) says
 * what it counts behind its « i » button (TODO « Full accessibility »,
 * « Cognitive »: every metric has its help text, WCAG 3.3.5). A card is a
 * `section.stat-card` or `section.expanded-kpi-block` with an id. Its help is
 * either an « i » button in the page itself, filled by a script with a
 * `ui_typing.tooltip_*` string, or one a script writes into the card's
 * value. The AI and hotstring cards had none: their only words were `title`
 * attributes, which neither the keyboard nor a touch screen reaches.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const PAGE = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui', 'metrics_typing');
const EN = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'core',
	'i18n',
	'data',
	'locales',
	'en.json'
);
// How many lines after an element is fetched its help must be written.
const WINDOW_LINES = 12;

/**
 * The cards of a page and the ids of the elements inside each.
 * @param {string} html
 * @returns {{id: string, body: string, ids: string[]}[]}
 */
function cardsOf(html) {
	const starts = [
		...html.matchAll(/<section class="(?:stat-card|expanded-kpi-block)\b[^"]*" id="([a-z_]+)"/g)
	];
	return starts.map((match, index) => {
		const end = index + 1 < starts.length ? starts[index + 1].index : html.length;
		const body = html.slice(match.index, end);
		return { id: match[1], body, ids: [...body.matchAll(/\sid="([a-z_]+)"/g)].map((m) => m[1]) };
	});
}

/**
 * The `ui_typing.tooltip_*` keys a script writes into an element, in the few
 * lines after it fetches it by id (directly, or from a list of [id, key]);
 * an empty name for a help built from one of the page's constants.
 * @param {string} scripts - Every script of the page, joined.
 * @param {string} id
 * @returns {string[]}
 */
function helpWrittenInto(scripts, id) {
	const lines = scripts.split('\n');
	const keys = [];
	lines.forEach((line, index) => {
		const fetched =
			line.includes(`getElementById('${id}')`) || line.includes(`['${id}', 'ui_typing.tooltip_`);
		if (!fetched) return;
		const near = lines.slice(index, index + WINDOW_LINES).join('\n');
		if (!near.includes('tooltiptext')) return;
		const named = [...near.matchAll(/'(ui_typing\.tooltip_[a-z_]+)'/g)].map((m) => m[1]);
		// A help built from a constant of the page (the finger distance's).
		keys.push(...(named.length ? named : ['']));
	});
	return keys;
}

/**
 * The cards without help text.
 * @param {string} html
 * @param {string} scripts
 * @param {Set<string>} known - The keys of the English catalogue.
 * @returns {string[]}
 */
function unexplained(html, scripts, known) {
	const missing = [];
	for (const card of cardsOf(html)) {
		const keys = card.ids.flatMap((id) => helpWrittenInto(scripts, id));
		const button = /class="tooltip\b/.test(card.body);
		const statics = [...card.body.matchAll(/data-i18n="(ui_typing\.tooltip_[a-z_]+)"/g)].map(
			(m) => m[1]
		);
		const all = keys.concat(statics);
		if (!all.length) missing.push(card.id + ': no help text');
		else if (!button && !keys.length) missing.push(card.id + ': no « i » button');
		for (const key of all)
			if (key && !known.has(key)) missing.push(card.id + ': unknown key ' + key);
	}
	return missing;
}

const html = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
const scripts = fs
	.readdirSync(PAGE)
	.filter((name) => name.endsWith('.js'))
	.map((name) => fs.readFileSync(path.join(PAGE, name), 'utf8'))
	.join('\n');
const known = new Set(Object.keys(JSON.parse(fs.readFileSync(EN, 'utf8'))));

const cards = cardsOf(html);
assert.ok(cards.length >= 15, `the dashboard's cards are found (${cards.length})`);
assert.deepEqual(unexplained(html, scripts, known), [], 'Typing dashboard cards without help text');

// The check finds what it forbids: a card with no « i », one whose script
// writes no help, and a help key the catalogue lacks.
const bare = '<section class="stat-card" id="x_card"><h2 id="x_title"></h2></section>';
assert.deepEqual(unexplained(bare, '', known), ['x_card: no help text']);
const filled =
	'<section class="stat-card" id="y_card"><button class="tooltip" id="y_info"></button></section>';
const script =
	"const info = document.getElementById('y_info');\n" +
	'info.innerHTML = `<small class="tooltiptext">${_t(\'ui_typing.tooltip_y\')}</small>`;';
assert.deepEqual(unexplained(filled, script, known), ['y_card: unknown key ui_typing.tooltip_y']);
assert.deepEqual(unexplained(filled, script, new Set(['ui_typing.tooltip_y'])), []);

console.log(`PASS test-metrics-cards-explained (${cards.length} cards, each with its help text)`);
