// tools/test/test-metrics-category-ids.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Category Identity Guard
 * DESCRIPTION:
 * The app-time dashboard colours each category from a fixed table. That table
 * used to be keyed by the FRENCH LABEL, which made the colour a property of the
 * translation rather than of the category.
 *
 * ROOT CAUSE ENCODED:
 * Two consequences, one already live before this guard existed. 'Graphics
 * design' displays as "Design graphique", but the colour table held "Design", so
 * that category silently lost its lavender and fell through to the hash palette
 * — a mismatch nobody can see, because both spellings look correct. And
 * translating the dashboard would have dropped EVERY fixed colour at once, since
 * not one key would match any more.
 *
 * The category is also PERSISTED: a user override is written to
 * app_categories.json, and the default written there is itself localised. So the
 * file on disk already depends on which language was active when it was written.
 * A user who switches language must not find their overrides orphaned and their
 * charts recoloured, which is what a bare rename would have caused.
 *
 * This asserts the identity model rather than the spelling: colours are keyed by
 * the stable English id, every French label and every historical spelling still
 * resolves to its id, and an unknown category passes through so a user-invented
 * one keeps working.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SCRIPT = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'ui',
	'metrics_apps',
	'script.js'
);

const src = fs.readFileSync(SCRIPT, 'utf8');

// Evaluate only the declarations this guard needs, up to the first line that
// touches the DOM or the host bridge.
const cut = src.indexOf('const postBridge');
if (cut < 0) throw new Error('script.js no longer defines postBridge — update the slice point');
const prelude = src.slice(0, cut);

// The prelude reads `window` for host-injected data. A minimal stand-in is
// enough — this guard is about the category tables, and giving it a real DOM
// would couple it to whatever the dashboard renders next.
const ALIASES_FILE = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'data',
	'metrics_general_category_aliases.json'
);
const CORPUS_FILE = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'tests',
	'corpus',
	'metrics',
	'app_categories_vectors.json'
);

const aliasDoc = JSON.parse(fs.readFileSync(ALIASES_FILE, 'utf8'));
const corpus = JSON.parse(fs.readFileSync(CORPUS_FILE, 'utf8'));

const sandbox = new Function(
	'window',
	'document',
	`${prelude}\nreturn { MAC_CATEGORIES_FR, FIXED_CAT_COLORS, LABEL_TO_CATEGORY_ID, categoryId, getCategoryColor, CHART_PALETTE };`
);
const { MAC_CATEGORIES_FR, FIXED_CAT_COLORS, categoryId, getCategoryColor } = sandbox(
	{ ManifestData: {}, GeneralCategoryAliases: aliasDoc.aliases, addEventListener() {} },
	{ addEventListener() {}, getElementById: () => null, querySelectorAll: () => [] }
);

const errors = [];

function check(cond, msg) {
	if (!cond) errors.push(msg);
}

// 1. The colour table is keyed by IDs, never by a translated label.
for (const key of Object.keys(FIXED_CAT_COLORS)) {
	check(
		Object.prototype.hasOwnProperty.call(MAC_CATEGORIES_FR, key),
		`FIXED_CAT_COLORS key "${key}" is not a category id — it must be one of the keys of ` +
			'MAC_CATEGORIES_FR, or the colour belongs to a spelling rather than to a category'
	);
}

// 2. Every id and every French label resolves to the id.
for (const [id, fr] of Object.entries(MAC_CATEGORIES_FR)) {
	check(categoryId(id) === id, `categoryId("${id}") must be the identity for an id`);
	check(
		categoryId(fr) === id,
		`categoryId("${fr}") must resolve to "${id}" — a stored French override must survive a ` +
			'language switch, and the file on disk is already localised'
	);
}

// 3. The historical spelling that caused the live bug still resolves.
check(
	categoryId('Design') === 'Graphics design',
	'"Design" was the old colour key for Graphics design and may be on disk — it must still resolve'
);

// 4. Graphics design gets its fixed colour, under BOTH spellings. This is the
//    bug: the label and the colour key disagreed, so it never did.
const lavender = FIXED_CAT_COLORS['Graphics design'];
check(!!lavender, 'Graphics design must have a fixed colour');
for (const spelling of ['Graphics design', 'Design graphique', 'Design']) {
	check(
		getCategoryColor(spelling, 0) === lavender,
		`getCategoryColor("${spelling}") must be the fixed Graphics-design colour ${lavender}, ` +
			'not a hashed palette entry'
	);
}

// 5. A category keeps ONE colour across spellings — the whole point of the id.
for (const [id, fr] of Object.entries(MAC_CATEGORIES_FR)) {
	check(
		getCategoryColor(id, 0) === getCategoryColor(fr, 0),
		`"${id}" and "${fr}" are the same category and must render the same colour`
	);
}

// 6. An unknown category still works, and is stable across calls.
const invented = 'Ma catégorie perso';
check(categoryId(invented) === invented, 'an unknown category must pass through unchanged');
check(
	getCategoryColor(invented, 0) === getCategoryColor(invented, 0),
	'an unknown category must hash to a stable colour'
);

// 7. Scores still win over any colour lookup.
check(getCategoryColor('Productivity', 1) === '#30D158', 'a positive score must render green');
check(getCategoryColor('Productivity', -1) === '#FF453A', 'a negative score must render red');

// 8. The generated alias file must still match the locales. Regenerating is one
//    command; a stale list silently orphans the overrides of whichever language
//    was added or corrected since.
const { collect } = require('../build/gen-metrics-category-aliases.cjs');
const live = collect();
for (const [code, label] of Object.entries(live)) {
	check(
		aliasDoc.by_locale[code] === label,
		`metrics_general_category_aliases.json is stale for "${code}": file says ` +
			`${JSON.stringify(aliasDoc.by_locale[code])}, locale says ${JSON.stringify(label)}. ` +
			'Run `node tools/build/gen-metrics-category-aliases.cjs`.'
	);
}
check(
	Object.keys(aliasDoc.by_locale).length === Object.keys(live).length,
	`the alias file covers ${Object.keys(aliasDoc.by_locale).length} locale(s), the tree ships ` +
		`${Object.keys(live).length} — regenerate it`
);

// 9. The corpus: every stored spelling, in every shipped language, resolves to
//    the id its vector expects. This is the file a real user has on disk.
check(
	corpus.vectors.length >= 20,
	`the corpus holds only ${corpus.vectors.length} vector(s) — it must cover every locale`
);
for (const v of corpus.vectors) {
	for (const [app, storedEntry] of Object.entries(v.stored)) {
		const want = v.expected_ids[app];
		const got = categoryId(storedEntry.type);
		check(
			got === want,
			`corpus "${v.id}": ${app} is stored as ${JSON.stringify(storedEntry.type)} and must ` +
				`resolve to ${JSON.stringify(want)}, got ${JSON.stringify(got)} — a user who switched ` +
				'language would find this override orphaned'
		);
	}
}

// Every alias must land on the SAME id, so the picker shows one general category
// rather than one per language the user has ever used.
const generalIds = new Set(aliasDoc.aliases.map((a) => categoryId(a)));
check(
	generalIds.size === 1,
	`the ${aliasDoc.aliases.length} spellings of the default category resolve to ` +
		`${generalIds.size} different ids (${[...generalIds].join(', ')}) — they must collapse to one, ` +
		'or the picker grows a new "General" every time the user switches language'
);

// The legacy declarations above remain covered, but the actual HTML loads the
// split helpers/state/main scripts. Exercise their real category and projection
// owners without native transports, live timers or optional chart canvases.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { loadMetricsAppsPage } = require('./support/metrics-apps-page.cjs');
const loadedCases = [];
const customLabels = ['Mon équipe', 'Dév & outils <équipe>', 'Projet [équipe]'];

function loadedPage(host) {
	const page = loadMetricsAppsPage(host);
	assert.equal(page.scripts.filter((name) => name !== '#inline').length, 10);
	assert.equal(
		page.scripts.includes('script.js'),
		false,
		'the legacy script cannot supply this proof'
	);
	for (const file of ['helpers.js', 'state.js', 'main.js', 'charts.js'])
		assert.ok(page.scripts.includes(file), `${file} must execute from the actual HTML`);
	page.evaluate = (code) => vm.runInContext(code, page.context, { timeout: 1000 });
	return page;
}

function categoriesPage(host) {
	const page = loadedPage(host);
	for (const id of ['category-filter-buttons', 'weekday-filter-buttons'])
		page.elements.set(id, page.context.document.createElement('div'));
	const manifest = {
		'2026-10-20': {
			Alpha: { category: 'Productivity', app_time_ms: 1000, chars: 1 },
			Beta: { category: 'Productivity', app_time_ms: 2000, chars: 2 },
			Gamma: { category: 'Productivity', app_time_ms: 3000, chars: 3 },
			Delta: { category: 'Utilities', app_time_ms: 4000, chars: 4 }
		}
	};
	const categories = {
		Alpha: { type: customLabels[0], score: 0 },
		Beta: { type: customLabels[1], score: 0 },
		Gamma: { type: 'Productivity', score: 0 },
		Delta: { type: customLabels[2], score: 0 }
	};
	page.evaluate("currentPeriod = 'all';");
	page.context.bootstrapMetricsAppsData(manifest, categories, {});
	page.categories = categories;
	return page;
}

/** Records generated pill markup and dispatches only the listeners bound by the real page. */
function categoryPillPort() {
	let markup = '';
	const port = { buttons: [], writes: 0 };
	const decode = (value) =>
		value
			.replace(/&quot;/g, '"')
			.replace(/&#39;/g, "'")
			.replace(/&lt;/g, '<')
			.replace(/&gt;/g, '>')
			.replace(/&amp;/g, '&');
	Object.defineProperty(port, 'innerHTML', {
		get: () => markup,
		set(value) {
			markup = value;
			port.writes++;
			port.buttons = [...value.matchAll(/<button\b([^>]*)>([^<]*)<\/button>/g)].map((match) => {
				const category = /\bdata-cat="([^"]*)"/.exec(match[1]);
				assert.ok(category, 'the real renderer supplies the category attribute');
				const listeners = [];
				return {
					category: decode(category[1]),
					textContent: decode(match[2]),
					getAttribute(name) {
						assert.equal(name, 'data-cat');
						return this.category;
					},
					addEventListener(name, callback) {
						assert.equal(name, 'click');
						listeners.push(callback);
					},
					click() {
						for (const callback of listeners) callback();
					}
				};
			});
		}
	});
	port.querySelectorAll = (selector) => {
		assert.equal(selector, 'button[data-cat]');
		return port.buttons;
	};
	return port;
}

/** Delivers through the real host handlers; the only substitutes are native transport and DOM ports. */
function categoryPillsPage(host) {
	const page = loadedPage(host);
	const pills = categoryPillPort();
	page.elements.set('category-filter-buttons', pills);
	page.elements.set('weekday-filter-buttons', page.context.document.createElement('div'));
	const manifest = {
		'2026-10-20': {
			Editor: { category: 'Productivity', app_time_ms: 1000 },
			Browser: { category: 'Utilities', app_time_ms: 2000 }
		}
	};
	page.sendCategories = (label, revision, initial = false) => {
		const categories = { Editor: { type: label, score: 1 }, Browser: { type: 'Outils', score: 0 } };
		if (host === 'macos') {
			if (initial)
				return page.context.publishMetricsAppsData(
					manifest,
					categories,
					{},
					{
						manifest_revision: revision,
						categories_revision: revision
					}
				);
			return page.context.publishMetricsAppsCategories(categories, revision);
		}
		const blob = { metrics_manifest: manifest, user_categories: categories, app_icons: {} };
		if (host === 'linux')
			return page.context.__hostBridgeResponse(
				'metrics_apps_bridge',
				false,
				encodeURIComponent(JSON.stringify(blob))
			);
		const listener = page.messageListeners.find(({ name }) => name === 'message');
		assert.ok(listener, 'the real inline Windows handler must be installed');
		return listener.callback({ data: { type: 'prefetch', blob } });
	};
	page.pills = pills;
	page.clickCategory = (label) => {
		const button = pills.buttons.find((candidate) => candidate.category === label);
		assert.ok(button, `the current category must have a pill: ${label}`);
		assert.equal(button.textContent, label);
		button.click();
	};
	page.evaluate("currentPeriod = 'all'; currentWeekdayFilter = new Set([1]);");
	page.sendCategories(customLabels[0], 1, true);
	return page;
}

for (const host of ['macos', 'linux', 'windows']) {
	loadedCases.push([
		`${host}/app-name-keys`,
		() => {
			const page = loadedPage(host);
			const names = ['Editor', 'constructor', 'toString', '__proto__'];
			const manifest = JSON.parse(
				'{"2026-10-20":{' +
					names
						.map(
							(name, index) =>
								JSON.stringify(name) +
								':' +
								JSON.stringify({
									category: 'Productivity',
									app_time_ms: (index + 1) * 1000,
									chars: index + 1,
									switches_to: JSON.parse('{"constructor":2,"toString":3,"__proto__":4}')
								})
						)
						.join(',') +
					'}}'
			);
			const original = JSON.stringify(manifest);
			const prototypes =
				'JSON.stringify([Object.getOwnPropertyNames(Object), Object.getOwnPropertyNames(Object.prototype), Object.getOwnPropertyNames(Object.prototype.toString)])';
			const before = page.evaluate(prototypes);
			for (const name of names) {
				assert.deepEqual(
					{ ...page.context.getAppCategory(name, 'Productivity') },
					{ type: 'Productivité', score: 0 }
				);
				assert.equal(typeof page.context.getAppColor(name, 0), 'string');
				assert.equal(page.context.getAppColor(name, 1), '#30D158');
			}
			page.context.bootstrapMetricsAppsData(manifest, {}, {});
			const aggregate = page.context.getAggregatedData();
			assert.deepEqual(Object.keys(aggregate.apps), names);
			for (const [index, name] of names.entries()) {
				assert.ok(Object.hasOwn(manifest['2026-10-20'], name));
				assert.ok(Object.hasOwn(aggregate.apps, name));
				assert.equal(aggregate.apps[name].time_ms, (index + 1) * 1000);
				assert.deepEqual(
					{ ...aggregate.apps[name].switches },
					JSON.parse('{"constructor":2,"toString":3,"__proto__":4}')
				);
			}
			assert.equal(page.elements.get('apps-tbody').children.length, names.length);
			assert.equal(JSON.stringify(manifest), original);
			assert.equal(
				page.evaluate(prototypes),
				before,
				'aggregation must not mutate inherited native objects'
			);
			const overrides = JSON.parse('{"__proto__":{"type":"Mon équipe","score":2}}');
			page.context.updateUserCategories(overrides);
			assert.deepEqual(
				{ ...page.context.getAppCategory('__proto__', 'Productivity') },
				{ type: 'Mon équipe', score: 2 }
			);
			const accepted = page.context.getAggregatedData();
			assert.throws(() => page.context.publishMetricsAppsCategories({}, -1), /revision/);
			assert.strictEqual(
				page.context.getAggregatedData(),
				accepted,
				'refused publication must preserve the accepted query'
			);
			assert.equal(page.context.getAppCategory('__proto__').type, 'Mon équipe');
			page.evaluate("currentCategoryFilter = new Set(['Mon équipe']);");
			assert.deepEqual(Object.keys(page.context.getAggregatedData().apps), ['__proto__']);
			page.evaluate('currentCategoryFilter = null;');
			const images = [];
			page.context.Image = class ImagePort {
				constructor() {
					images.push(this);
				}
				set src(value) {
					this.value = value;
				}
			};
			page.context.Chart = class ChartPort {
				destroy() {}
				draw() {}
			};
			const canvas = page.context.document.createElement('canvas');
			canvas.getContext = () => ({});
			page.elements.set('apps_bar_chart', canvas);
			page.context.renderDashboard();
			assert.equal(
				images.length,
				0,
				'absent own icons must not consume inherited functions as image URLs'
			);
			const create = page.context.document.createElement;
			page.context.document.createElement = (tag) => {
				const node = create(tag);
				if (tag === 'canvas')
					node.getContext = () => ({
						drawImage() {},
						getImageData: () => ({ data: [255, 0, 0, 255] })
					});
				return node;
			};
			const icons = JSON.parse(
				'{' +
					names.map((name) => JSON.stringify(name) + ':"data:image/png;base64,AA=="').join(',') +
					'}'
			);
			page.context.bootstrapMetricsAppsData(manifest, {}, icons);
			assert.equal(
				images.length,
				8,
				'four real chart consumers and four color samplers must admit own icons'
			);
			assert.ok(images.every((image) => image.value === 'data:image/png;base64,AA=='));
			images[4].onerror();
			for (const image of images.slice(5)) image.onload();
			assert.equal(
				page.context.getAppColor('Editor', 0),
				page.evaluate("CHART_PALETTE[paletteIndex('Editor')]")
			);
			page.context.precomputeIconColors();
			assert.equal(images.length, 9, 'only the failed color sample should retry');
			images[8].onload();
			for (const name of names) assert.equal(page.context.getAppColor(name, 0), '#ff0000');
			assert.equal(page.evaluate(prototypes), before);
			assert.equal(page.diagnostics.filter(({ level }) => level === 'error').length, 0);
		}
	]);
	loadedCases.push([
		`${host}/live-category-pills`,
		() => {
			const page = categoryPillsPage(host);
			assert.deepEqual(
				page.pills.buttons.map((button) => button.category),
				[customLabels[0], 'Outils']
			);
			page.sendCategories(customLabels[1], 2);
			assert.deepEqual(
				page.pills.buttons.map((button) => button.category),
				[customLabels[1], 'Outils']
			);
			assert.equal(page.evaluate('JSON.stringify([...currentWeekdayFilter])'), '[1]');
			if (host === 'macos') {
				const writes = page.pills.writes;
				assert.equal(page.sendCategories('Obsolete category', 1), false);
				assert.equal(page.sendCategories('Duplicate revision', 2), false);
				assert.equal(page.pills.writes, writes, 'refused revisions must not rebuild pills');
			}
			page.clickCategory('Outils');
			assert.deepEqual(Object.keys(page.context.getAggregatedData().apps), ['Editor']);
			page.context.updateUserCategories({ Editor: { type: 'Legacy update', score: 0 } });
			assert.deepEqual(
				page.pills.buttons.map((button) => button.category),
				['Legacy update', 'Utilitaires']
			);
			assert.equal(page.evaluate('JSON.stringify([...currentWeekdayFilter])'), '[1]');
		}
	]);
	loadedCases.push([
		`${host}/renamed-filter-selection`,
		() => {
			const page = categoryPillsPage(host);
			page.clickCategory('Outils');
			assert.deepEqual(Object.keys(page.context.getAggregatedData().apps), ['Editor']);
			page.sendCategories(customLabels[1], 2);
			assert.deepEqual(Object.keys(page.context.getAggregatedData().apps), []);
			page.clickCategory(customLabels[1]);
			assert.deepEqual(
				Object.keys(page.context.getAggregatedData().apps),
				['Editor'],
				'one vanished category key cannot reactivate the excluded Outils category'
			);
			page.clickCategory('Outils');
			assert.deepEqual(Object.keys(page.context.getAggregatedData().apps), ['Editor', 'Browser']);
			assert.equal(
				page.evaluate('currentCategoryFilter'),
				null,
				'every current category is selected'
			);
		}
	]);
	loadedCases.push([
		`${host}/dictionary-word-labels`,
		() => {
			const page = loadedPage(host);
			const charts = [];
			// The native canvas renderer is an explicit browser port; chart inputs
			// still come from the actual shared updateCharts/renderDashboard code.
			page.context.Chart = class ChartInputPort {
				constructor(context, config) {
					charts.push({ canvas: context.id, config });
				}
				destroy() {}
			};
			for (const id of ['category_pie_chart', 'timeline_stacked_chart', 'timeline_chart_title']) {
				const node = page.context.document.createElement('canvas');
				node.getContext = () => ({ id });
				page.elements.set(id, node);
			}
			const labels = ['constructor', 'toString'];
			page.evaluate("currentPeriod = 'all';");
			page.context.bootstrapMetricsAppsData(
				{
					'2026-10-20': {
						Editor: {
							category: 'Productivity',
							app_time_ms: 3600000,
							chars: 1,
							hourly: { 12: { time_ms: 3600000, c: 1 } }
						},
						Browser: {
							category: 'Utilities',
							app_time_ms: 7200000,
							chars: 2,
							hourly: { 13: { time_ms: 7200000, c: 2 } }
						}
					}
				},
				{ Editor: { type: labels[0], score: 0 }, Browser: { type: labels[1], score: 0 } },
				{}
			);
			const aggregate = page.context.getAggregatedData();
			for (const [index, label] of labels.entries()) {
				const ms = (index + 1) * 3600000;
				assert.equal(page.context.categoryToId(label), label);
				assert.equal(page.context.translateCategory(label), label);
				assert.equal(typeof page.context.getCategoryColor(label, 0), 'string');
				assert.equal(
					page.context.getCategoryColor(label, 0),
					page.evaluate(`CHART_PALETTE[paletteIndex(${JSON.stringify(label)})]`)
				);
				assert.ok(Object.hasOwn(aggregate.rich.by_category, label));
				assert.equal(aggregate.rich.by_category[label].time_ms, ms);
				assert.equal(aggregate.rich.by_date['2026-10-20'].by_category[label], ms);
				assert.equal(Object.values(aggregate.rich.weekday_category)[0][label], ms);
				assert.equal(aggregate.rich.ribbon['2026-10-20'][String(12 + index)][label], ms);
				assert.equal(Object.values(aggregate.timeline)[0][label], ms);
			}
			const pie = charts.find((chart) => chart.canvas === 'category_pie_chart').config;
			assert.deepEqual(Array.from(pie.data.labels), ['toString', 'constructor']);
			assert.deepEqual(Array.from(pie.data.datasets[0].data), [2, 1]);
			page.evaluate("currentPeriod = 'day'; currentSelectedDate = '2026-10-20';");
			page.context.renderDashboard();
			const day = page.context.getAggregatedData();
			assert.equal(day.timeline['12'].constructor, 3600000);
			assert.equal(day.timeline['13'].toString, 7200000);
			const timeline = charts
				.filter((chart) => chart.canvas === 'timeline_stacked_chart')
				.at(-1).config;
			assert.deepEqual(
				Array.from(timeline.data.datasets, (dataset) => dataset.label),
				labels
			);
			assert.deepEqual(Array.from(timeline.data.datasets[0].data), [1, 0]);
			assert.deepEqual(Array.from(timeline.data.datasets[1].data), [0, 2]);
			page.evaluate("currentCategoryFilter = new Set(['constructor']);");
			assert.deepEqual(Object.keys(page.context.getAggregatedData().apps), ['Editor']);
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		}
	]);

	loadedCases.push([
		`${host}/custom-labels`,
		() => {
			const page = categoriesPage(host);
			for (const [index, label] of customLabels.entries()) {
				const stored = JSON.stringify(label);
				assert.equal(page.evaluate(`categoryToId(${stored})`), label);
				assert.equal(page.evaluate(`translateCategory(${stored})`), label);
				assert.equal(page.context.getAppCategory(['Alpha', 'Beta', 'Delta'][index]).type, label);
			}
			assert.equal(page.context.getAppCategory('Gamma').type, 'Productivité');
			assert.equal(page.categories.Alpha.type, customLabels[0]);
			assert.equal(page.categories.Beta.type, customLabels[1]);
			const rows = page.elements.get('apps-tbody').children;
			assert.equal(rows.length, 4);
			const cells = rows.map((row) => row.children[1]);
			assert.ok(
				cells.every((cell) => cell.className === 'app-cat-cell'),
				'category text is not a DOM selector'
			);
			assert.ok(cells.some((cell) => cell.innerHTML.includes('Dév &amp; outils &lt;équipe&gt;')));
			assert.ok(cells.some((cell) => cell.innerHTML.includes('Projet [équipe]')));
			assert.ok(rows.every((row) => typeof row.title === 'string' && row.title.length > 0));
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		}
	]);
	loadedCases.push([
		`${host}/custom-aggregation-filters`,
		() => {
			const page = categoriesPage(host);
			const aggregate = page.context.getAggregatedData();
			assert.deepEqual(
				Object.keys(aggregate.rich.by_category).sort(),
				[...customLabels, 'Productivité'].sort()
			);
			assert.equal(aggregate.rich.by_category[customLabels[0]].time_ms, 1000);
			assert.equal(aggregate.rich.by_category[customLabels[1]].time_ms, 2000);
			assert.equal(aggregate.rich.by_category.Productivité.time_ms, 3000);
			assert.equal(aggregate.rich.by_category[customLabels[2]].time_ms, 4000);
			const filter = (label) => {
				page.evaluate(`currentCategoryFilter = new Set([${JSON.stringify(label)}]);`);
				return Object.keys(page.context.getAggregatedData().apps);
			};
			assert.deepEqual(filter(customLabels[0]), ['Alpha']);
			assert.deepEqual(filter(customLabels[1]), ['Beta']);
			assert.deepEqual(filter(customLabels[2]), ['Delta']);
			assert.deepEqual(filter('Productivité'), ['Gamma']);
			assert.deepEqual(filter('Utilitaires'), []);
			const pills = page.elements.get('category-filter-buttons').innerHTML;
			assert.ok(pills.includes('Dév &amp; outils &lt;équipe&gt;'));
			assert.ok(pills.indexOf('Dév &amp; outils &lt;équipe&gt;') < pills.indexOf('Mon équipe'));
			assert.ok(pills.indexOf('Mon équipe') < pills.indexOf('Productivité'));
			assert.ok(pills.indexOf('Productivité') < pills.indexOf('Projet [équipe]'));
		}
	]);
	loadedCases.push([
		`${host}/preset-defaults`,
		() => {
			const page = loadedPage(host);
			for (const spelling of ['Productivity', 'Productivité', 'productivity']) {
				assert.equal(page.context.categoryToId(spelling), 'productivity');
				assert.equal(page.context.translateCategory(spelling), 'Productivité');
				assert.equal(page.context.getCategoryColor(spelling, 0), '#0A84FF');
			}
			for (const value of ['', ' \t ', null, undefined, false, true, 42, {}, []]) {
				assert.equal(page.context.categoryToId(value), 'utility');
				assert.equal(page.context.translateCategory(value), 'Utilitaires');
				assert.equal(page.context.getCategoryColor(value, 0), '#64D2FF');
			}
			page.context.updateUserCategories({
				Empty: { type: '', score: 1 },
				Absent: { score: 0 },
				Invalid: { type: 42, score: -1 }
			});
			for (const name of ['Empty', 'Absent', 'Invalid'])
				assert.equal(page.context.getAppCategory(name).type, 'Utilitaires');
			assert.equal(page.context.getAppCategory('Empty').score, 1);
			assert.equal(page.context.getAppCategory('Invalid').score, -1);
			// Preserve the declared preset aliases and their existing color policy;
			// a preset without a fixed color retains the existing palette branch.
			page.evaluate(`
			for (const [english, id] of Object.entries(CATEGORY_ID_MAP)) {
				if (categoryToId(english) !== id) throw new Error('preset id: ' + english);
				if (translateCategory(english) !== _t('app_category.' + id)) throw new Error('preset label: ' + english);
				const color = FIXED_CAT_COLORS[id] || CHART_PALETTE[paletteIndex(english)];
				if (getCategoryColor(english, 0) !== color) throw new Error('preset color: ' + english);
			}
			for (const [label, id] of Object.entries(_FRENCH_LEGACY_LABELS)) {
				if (categoryToId(label) !== id) throw new Error('legacy id: ' + label);
				if (translateCategory(label) !== _t('app_category.' + id)) throw new Error('legacy label: ' + label);
			}
			for (const id of Object.keys(FIXED_CAT_COLORS)) {
				if (categoryToId(id) !== id) throw new Error('fixed preset id: ' + id);
				if (getCategoryColor(id, 0) !== FIXED_CAT_COLORS[id]) throw new Error('fixed preset color: ' + id);
			}
		`);
		}
	]);
	loadedCases.push([
		`${host}/custom-colors-scores`,
		() => {
			const page = loadedPage(host);
			for (const label of customLabels) {
				// This is the already-declared canonical palette, not a new color scheme.
				const color = page.evaluate(`CHART_PALETTE[paletteIndex(${JSON.stringify(label)})]`);
				assert.equal(page.context.getCategoryColor(label, 0), color);
				assert.equal(page.context.getCategoryColor(label, 0), color);
				assert.equal(page.context.getCategoryColor(label, 1), '#30D158');
				assert.equal(page.context.getCategoryColor(label, -1), '#FF453A');
			}
		}
	]);
	loadedCases.push([
		`${host}/live-category-update`,
		() => {
			const page = categoriesPage(host);
			const prior = page.context.getAggregatedData();
			page.evaluate(`currentCategoryFilter = new Set([${JSON.stringify(customLabels[0])}]);`);
			page.context.updateUserCategories({
				Alpha: { type: customLabels[1], score: 2 },
				Beta: { type: customLabels[1], score: 0 },
				Gamma: { type: 'Productivity', score: 0 }
			});
			assert.notStrictEqual(page.context.getAggregatedData(), prior);
			assert.equal(page.context.getAppCategory('Alpha').type, customLabels[1]);
			assert.equal(page.context.getAppCategory('Alpha').score, 2);
			assert.deepEqual(Object.keys(page.context.getAggregatedData().apps), []);
			assert.equal(
				page.evaluate('JSON.stringify([...currentCategoryFilter])'),
				JSON.stringify([customLabels[0]])
			);
			const rows = page.elements.get('apps-tbody').children;
			assert.equal(rows.length, 0, 'the preserved filter cannot render a different category');
		}
	]);
}

// Exact replay keeps every legacy assertion above active, even for one loaded case.
const caseName = process.env.ERGOPTI_METRICS_CATEGORY_CASE;
const cases = caseName ? loadedCases.filter(([name]) => name === caseName) : [...loadedCases];
assert.ok(cases.length > 0, `unknown loaded category case: ${caseName}`);
if (process.env.ERGOPTI_METRICS_CATEGORY_ORDER === 'reverse') cases.reverse();
// Node's first descriptor scan can materialize its own lazy built-in globals.
// Complete that observer initialization before measuring any browser fixture.
Object.getOwnPropertyDescriptors(globalThis);
for (const [name, callback] of cases) {
	const globals = Object.getOwnPropertyDescriptors(globalThis);
	const cache = { ...require.cache };
	let passedCase = false;
	try {
		callback();
		passedCase = true;
	} catch (error) {
		errors.push(`loaded categories ${name}: ${error.stack}`);
	} finally {
		const currentGlobals = Object.getOwnPropertyDescriptors(globalThis);
		assert.deepEqual(
			Reflect.ownKeys(currentGlobals),
			Reflect.ownKeys(globals),
			'global keys changed'
		);
		for (const key of Reflect.ownKeys(globals)) {
			for (const field of ['value', 'get', 'set', 'writable', 'enumerable', 'configurable'])
				assert.strictEqual(
					currentGlobals[key][field],
					globals[key][field],
					'global identity changed'
				);
		}
		assert.deepEqual(Object.keys(require.cache), Object.keys(cache), 'host module keys changed');
		for (const key of Object.keys(cache))
			assert.strictEqual(require.cache[key], cache[key], 'host module identity changed');
	}
	if (passedCase) console.log(`  ok loaded categories ${name}`);
}
console.log(`Loaded category cases: ${cases.length}`);

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Metrics category identity is broken:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${Object.keys(MAC_CATEGORIES_FR).length} categories are id-keyed; ` +
		`${Object.keys(FIXED_CAT_COLORS).length} fixed colours resolve under every stored spelling.\x1b[0m`
);
