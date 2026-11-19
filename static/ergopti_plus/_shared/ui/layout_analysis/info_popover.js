// _shared/ui/layout_analysis/info_popover.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Info Popovers
 * DESCRIPTION:
 * The « i » buttons of Ergopti Studio: next to a metric or a sourced value,
 * a button whose popover explains where the value comes from and links its
 * references (LAYOUT_ANALYSIS_DATA.sources, from sources.json). Shared by
 * the Comparer and the editor's analysis panel, on the site and in the app.
 *
 * FEATURES & RATIONALE:
 * 1. One delegated listener: any `.la-info` button with a `data-info` item,
 *    drawn now or later by any script of the page, opens its popover.
 * 2. The popover element is created here, so a page needs no markup for it.
 * 3. A host that opens links itself (the app's browser) defines
 *    LAYOUT_ANALYSIS_HOST.openLink(url); otherwise links open a new tab.
 * 4. Explanations are locale keys layout_analysis.info.<item> (21 locales);
 *    the values they quote come from the data, never from the text.
 * 5. format() writes every number of the Studio pages in the language of
 *    their strings (locale()), the same in the app and on the site: the
 *    group separator of that language (U+202F in French) and its decimal
 *    mark. t() writes a number placeholder through it too, so a sentence
 *    never shows a number another way than a table (maintainer, 2026-11-19).
 * 6. One « i » per value: an item whose explanation needs another one's
 *    (ALSO_EXPLAINS) shows both in its own popover, so a page never draws a
 *    second button with the same name beside the first.
 * 7. A metric's popover (and the score's, item weights) names it in full,
 *    then gives its definition (layout_analysis.info.<id>, the one source of
 *    the definitions) and its formula (layout_analysis.formula.<id>, or the
 *    formula of what it is a share of): a compact header (« SFB », a name on
 *    two lines) keeps its full meaning one key press away (maintainer,
 *    2026-11-19). metricShort() gives the usual acronym of a metric's name,
 *    metricSpoken() the name of a header showing it.
 * 8. Percentile chips (percentile): « P70 » beside a metric's value opens a
 *    popover of its own words, with no references; note() makes an « i »
 *    of the same kind for any explanation without references (the
 *    Optimiser's switches).
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS_INFO = (function () {
	'use strict';

	// The popover's widest size and its gap to the window's edges.
	const POPOVER_WIDTH_PX = 360;
	const POPOVER_GUTTER_PX = 12;
	const POPOVER_ID = 'la-popover';
	// Digits of the shares an explanation quotes, and of a key's width in a formula.
	const SHARE_DIGITS = 1;
	const KEY_MM_DIGITS = 2;
	// The explanations an item's popover adds after its own: the left-hand
	// shortcuts metric is computed from the letters' usefulness, which once had a
	// second « i » on the same row.
	const ALSO_EXPLAINS = Object.freeze({ shortcut_left: Object.freeze(['shortcut_letters']) });
	// The metrics with a formula of their own; the others take the formula of
	// what they are a share of (LAYOUT_ANALYSIS.METRICS[id].of).
	const OWN_FORMULAS = Object.freeze([
		'distance',
		'sfb_distance',
		'finger_imbalance',
		'hand_imbalance',
		'char_coverage',
		'coverage_bonus',
		'direct_digits',
		'shortcut_left',
		'simplicity',
		'compact_fit',
		'distinct_chars'
	]);
	const SHARE_FORMULAS = Object.freeze(['bigrams', 'trigrams', 'keystrokes', 'characters']);
	// The score's popover: its weights' explanation and the score's formula.
	const SCORE_ITEM = 'weights';
	const SCORE_FORMULA = 'score';
	// The usual acronym a metric's name ends with: « Same-finger bigrams (SFB) ».
	const ACRONYM = /[(（]([A-Z]{2,5})[)）]\s*$/;

	// The language of the numbers when the page declares no usable one: the
	// locale i18n.js loads when none is set (its load()), never the browser's.
	const FALLBACK_LOCALE = 'fr';
	// The no-break space that ties a number to a unit or a counted word.
	const NO_BREAK_SPACE = '\u00a0';
	const PERCENT = '%';

	let popover = null;
	let owner = null;
	let warnedLocale = false;

	/**
	 * Translates a locale key; an unknown key shows itself so the gap is
	 * visible. A whole number placeholder is written by format(); a fraction
	 * is written by its caller, who knows its decimals.
	 * @param {string} key
	 * @param {Object<string, string|number>} [values]
	 * @returns {string}
	 * @throws {TypeError} On a fractional or non-finite number placeholder.
	 */
	function t(key, values) {
		const strings = window._i18n_strings || {};
		let text = typeof strings[key] === 'string' ? strings[key] : key;
		for (const [name, value] of Object.entries(values || {}))
			text = text.split(`{${name}}`).join(placeholder(key, name, value));
		return text;
	}

	/** A placeholder's text: a number as format() writes it, anything else as itself. */
	function placeholder(key, name, value) {
		if (typeof value !== 'number') return String(value);
		if (!Number.isInteger(value))
			throw new TypeError(
				`layout_analysis: ${key} {${name}} is ${value}; write a fraction with format(value, digits)`
			);
		return format(value, 0);
	}

	// The refusal values that name a finger or a keyboard, shown by their label
	// when they name a known one (a refused unknown finger shows as typed).
	const NAMED_VALUES = { finger: 'finger', below: 'finger', keyboard: 'keyboard' };
	// Digits of a refused number (an edited load's sum).
	const REFUSAL_DIGITS = 2;

	/**
	 * The text of an engine refusal (analysis_engine.js AnalysisError) in the
	 * reader's language: layout_analysis.error.<code>, its fingers and keyboard
	 * by their labels. A file that is not JSON is said as such.
	 * @param {Error} error
	 * @returns {string}
	 * @throws {Error} The error itself when it is neither: a programming error
	 *   stays visible instead of reaching the reader as English text.
	 */
	function refusal(error) {
		if (error && error.name === 'SyntaxError') return t('layout_analysis.error.not_json');
		if (!error || error.name !== 'AnalysisError' || typeof error.code !== 'string') throw error;
		const strings = window._i18n_strings || {};
		const values = {};
		for (const [name, value] of Object.entries(error.values || {})) {
			const label = Object.hasOwn(NAMED_VALUES, name)
				? `layout_analysis.${NAMED_VALUES[name]}.${value}`
				: null;
			if (label !== null && typeof strings[label] === 'string') values[name] = strings[label];
			else if (typeof value === 'number')
				values[name] = format(value, Number.isInteger(value) ? 0 : REFUSAL_DIGITS);
			else values[name] = value;
		}
		return t(`layout_analysis.error.${error.code}`, values);
	}

	function el(tag, className, text) {
		const node = document.createElement(tag);
		if (className) node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	}

	/**
	 * The language of the page's strings: the locale of the strings shown (an
	 * app window seeds them without naming a locale), else the one asked for,
	 * else the page's declared language. Numbers follow it, never the
	 * browser's own language, so a French browser shows an English page's
	 * numbers in English. A missing, empty or malformed tag (a host page that
	 * declares no language) would make Intl throw a RangeError: such a page
	 * writes its numbers in FALLBACK_LOCALE, said once in the console.
	 * @returns {string} A BCP 47 language code.
	 */
	function locale() {
		const strings = window._i18n_strings || {};
		// Read in order: a context without a document (a script gate) names its strings' locale.
		const sources = [
			() => strings['_meta.locale'],
			() => window._i18n_locale,
			() => document.documentElement.lang
		];
		const tags = [];
		for (const source of sources) {
			const tag = source();
			tags.push(tag);
			if (typeof tag !== 'string' || tag === '') continue;
			try {
				Intl.getCanonicalLocales(tag);
				return tag;
			} catch (error) {
				if (!(error instanceof RangeError)) throw error;
			}
		}
		if (!warnedLocale) {
			warnedLocale = true;
			console.warn(
				`[layout_analysis] no usable page language (${JSON.stringify(tags)}): numbers use ${FALLBACK_LOCALE}`
			);
		}
		return FALLBACK_LOCALE;
	}

	// One formatter per language and decimals: toLocaleString with options
	// builds a new Intl.NumberFormat on every call, and a ranking of every
	// layout writes tens of thousands of numbers.
	const formatters = new Map();

	/** A number with exactly this many decimals, written the page's way. */
	function format(value, digits) {
		const lang = locale();
		const key = `${lang}|${digits}`;
		let formatter = formatters.get(key);
		if (formatter === undefined) {
			formatter = new Intl.NumberFormat(lang, {
				minimumFractionDigits: digits,
				maximumFractionDigits: digits
			});
			formatters.set(key, formatter);
		}
		return formatter.format(Number(value));
	}

	// Where each language writes the percent sign, its spaces made no-break.
	const percentPatterns = new Map();

	/**
	 * The text a language writes before and after a percentage's number
	 * (« 12,3 % » in French with a no-break space, « 12.3% » in English, « %12,3 » in
	 * Turkish), from its own Intl pattern.
	 * @param {string} lang
	 * @returns {{before: string, after: string}}
	 */
	function percentPattern(lang) {
		let pattern = percentPatterns.get(lang);
		if (pattern === undefined) {
			const parts = new Intl.NumberFormat(lang, { style: 'percent' }).formatToParts(0.5);
			const at = parts.findIndex((part) => part.type === 'integer');
			const text = (list) =>
				list
					.map((part) => part.value)
					.join('')
					.replace(/ /g, NO_BREAK_SPACE);
			pattern = { before: text(parts.slice(0, at)), after: text(parts.slice(at + 1)) };
			percentPatterns.set(lang, pattern);
		}
		return pattern;
	}

	/**
	 * A written number with its unit, tied by a no-break space so the unit
	 * never wraps away from it (maintainer, 2026-11-19): a percentage the
	 * language's way (percentPattern), any other unit after U+00A0.
	 * @param {string} text - The number as format() wrote it, a sign included.
	 * @param {string} unit - '%' or a unit's translated text (mm, points…).
	 * @returns {string}
	 */
	function withUnit(text, unit) {
		if (unit === PERCENT) {
			const { before, after } = percentPattern(locale());
			return `${before}${text}${after}`;
		}
		return `${text}${NO_BREAK_SPACE}${unit}`;
	}

	/** A number with this many decimals and its unit (withUnit), written the page's way. */
	function measure(value, digits, unit) {
		return withUnit(format(value, digits), unit);
	}

	/**
	 * A metric's unit as a table cell writes it beside its value.
	 * @param {string} id - A LAYOUT_ANALYSIS.METRICS id.
	 * @returns {string}
	 * @throws {Error} On an unknown metric or unit.
	 */
	function metricUnit(id) {
		const metric = window.LAYOUT_ANALYSIS.METRICS[id];
		if (!metric) throw new Error(`layout_analysis: no metric ${id}`);
		if (metric.unit === PERCENT) return PERCENT;
		if (metric.unit === 'mm') return t('layout_analysis.unit.mm');
		if (metric.unit === 'chars') return t('layout_analysis.unit.chars');
		throw new Error(`layout_analysis: metric ${id} has no unit text for ${metric.unit}`);
	}

	// The locale key of each unit the other analysers' scores are in (analyser_models.json).
	const ANALYSER_UNITS = Object.freeze({
		points: 'layout_analysis.unit.points',
		effort: 'layout_analysis.unit.effort',
		'penalty per character': 'layout_analysis.unit.penalty',
		cost: 'layout_analysis.unit.cost'
	});

	/**
	 * An analyser's score unit in the reader's language.
	 * @param {{id: string, unit: string}} analyser - LAYOUT_ANALYSER_SCORES.analysers() entry.
	 * @returns {string}
	 * @throws {Error} On a unit without its words (a new analyser's model).
	 */
	function analyserUnit(analyser) {
		if (analyser.unit === PERCENT) return PERCENT;
		if (!Object.hasOwn(ANALYSER_UNITS, analyser.unit))
			throw new Error(
				`layout_analysis: analyser ${analyser.id} has no words for unit ${analyser.unit}`
			);
		return t(ANALYSER_UNITS[analyser.unit]);
	}

	/** Gives a button its translated accessible name and state. */
	function label(button) {
		const text = t('layout_analysis.info.button');
		button.setAttribute('aria-label', text);
		button.title = text;
		button.setAttribute('aria-expanded', String(button === owner));
		button.setAttribute('aria-controls', POPOVER_ID);
	}

	/**
	 * An « i » button for one item of the sources.
	 * @param {string} item - A key of LAYOUT_ANALYSIS_DATA.sources.items.
	 * @returns {HTMLButtonElement} The button.
	 * @throws {Error} On an item without references.
	 */
	function button(item) {
		const items = window.LAYOUT_ANALYSIS_DATA.sources.items;
		for (const id of [item].concat(ALSO_EXPLAINS[item] || []))
			if (!items[id]) throw new Error(`layout_analysis: no sources for ${id}`);
		const node = el('button', 'la-info', 'i');
		node.type = 'button';
		node.dataset.info = item;
		label(node);
		return node;
	}

	/** Opens a link through the host when it has a browser of its own. */
	function routeLink(link) {
		link.target = '_blank';
		link.rel = 'noopener';
		const host = window.LAYOUT_ANALYSIS_HOST || {};
		if (typeof host.openLink !== 'function') return;
		link.onclick = (event) => {
			event.preventDefault();
			host.openLink(link.href);
		};
	}

	/** A reference's link: its own URL, or its document on the repository. */
	function referenceUrl(repository, ref) {
		if (ref.url) return ref.url;
		const { host, owner, repo, branch } = repository;
		return `https://${host}/${owner}/${repo}/blob/${branch}/${ref.path}${ref.anchor ? `#${ref.anchor}` : ''}`;
	}

	/** The default values an explanation quotes, from the data. */
	function values(item) {
		if (item !== 'ideal_finger_load') return {};
		const load = window.LAYOUT_ANALYSIS.defaultIdealLoad();
		return {
			pinky: format(load.lp, SHARE_DIGITS),
			ring: format(load.lr, SHARE_DIGITS),
			middle: format(load.lm, SHARE_DIGITS),
			index: format(load.li, SHARE_DIGITS)
		};
	}

	/**
	 * The formula an item's popover gives: the metric's own, the formula of
	 * what it is a share of, the score's for its weights, else none.
	 * @param {string} item - A key of LAYOUT_ANALYSIS_DATA.sources.items.
	 * @returns {string|null} A layout_analysis.formula.<id> suffix.
	 * @throws {Error} On a metric with neither.
	 */
	function formulaOf(item) {
		if (item === SCORE_ITEM) return SCORE_FORMULA;
		const metrics = window.LAYOUT_ANALYSIS && window.LAYOUT_ANALYSIS.METRICS;
		if (!metrics || !Object.hasOwn(metrics, item)) return null;
		if (OWN_FORMULAS.includes(item)) return item;
		if (SHARE_FORMULAS.includes(metrics[item].of)) return metrics[item].of;
		throw new Error(`layout_analysis: metric ${item} has no formula`);
	}

	/** The full name an item's popover starts with: a metric's, the score's, else none. */
	function nameOf(item) {
		if (item === SCORE_ITEM) return t('layout_analysis.table.score');
		const metrics = window.LAYOUT_ANALYSIS && window.LAYOUT_ANALYSIS.METRICS;
		return metrics && Object.hasOwn(metrics, item) ? t(`layout_analysis.metric.${item}`) : null;
	}

	/** The values a formula quotes, written the page's way, from the data. */
	function formulaValues() {
		const model = window.LAYOUT_ANALYSIS_DATA.model;
		return {
			cap: format(model.coverage_cap, 0),
			key: measure(model.key_unit_mm, KEY_MM_DIGITS, t('layout_analysis.unit.mm')),
			zero: measure(0, 0, PERCENT),
			full: measure(100, 0, PERCENT)
		};
	}

	/**
	 * The usual acronym of a metric, the end of its name in the reader's
	 * language (« SFB »), for a compact header; null when its name has none.
	 * @param {string} id - A LAYOUT_ANALYSIS.METRICS id.
	 * @returns {string|null}
	 */
	function metricShort(id) {
		const match = ACRONYM.exec(t(`layout_analysis.metric.${id}`));
		return match ? match[1] : null;
	}

	/**
	 * The accessible name of a header that shows a metric's acronym: the
	 * acronym first, as shown, then the words it stands for (« SFB, Same-finger
	 * bigrams »), so a voice command saying the visible text reaches it (WCAG
	 * 2.5.3); the full name when the metric has no acronym.
	 * @param {string} id - A LAYOUT_ANALYSIS.METRICS id.
	 * @returns {string}
	 */
	function metricSpoken(id) {
		const name = t(`layout_analysis.metric.${id}`);
		const match = ACRONYM.exec(name);
		return match ? `${match[1]}, ${name.slice(0, match.index).trim()}` : name;
	}

	function build() {
		popover = el('div', 'la-popover');
		popover.id = POPOVER_ID;
		popover.setAttribute('role', 'dialog');
		popover.hidden = true;
		const close = el('button', 'la-popover-close');
		close.type = 'button';
		close.addEventListener('click', hide);
		const name = el('p', 'la-popover-name');
		name.id = `${POPOVER_ID}-name`;
		popover.append(
			name,
			el('div', 'la-popover-texts'),
			el('p', 'la-popover-formula'),
			el('p', 'la-popover-title'),
			el('ul'),
			close
		);
		document.body.append(popover);
	}

	/**
	 * A percentile chip beside a metric's value, written « P70 » and
	 * coloured from red at the lowest percentile to green at the highest, with
	 * its number always written, named in full for assistive technology after
	 * the text it shows (WCAG 2.5.3: a voice command saying « P70 » reaches
	 * it); a click explains it in the popover.
	 * @param {string} metric - The metric's name, as the page shows it.
	 * @param {{percent: number, count: number}} standing - LAYOUT_ANALYSIS.percentiles' answer.
	 * @returns {HTMLButtonElement}
	 */
	function percentile(metric, standing) {
		const values = { metric, percent: standing.percent, count: standing.count };
		const chip = t('layout_analysis.percentile.chip', values);
		const node = el('button', 'la-note la-pct', chip);
		node.type = 'button';
		node.style.setProperty('--la-pct', String(standing.percent));
		node.dataset.note = t('layout_analysis.percentile.explain', values);
		node.setAttribute('aria-label', `${chip}, ${t('layout_analysis.percentile.label', values)}`);
		node.setAttribute('aria-controls', POPOVER_ID);
		node.setAttribute('aria-expanded', 'false');
		return node;
	}

	/**
	 * An « i » button whose popover says one text, with no references.
	 * @param {string} name - Its accessible name (what it explains).
	 * @param {string} text - The popover's text.
	 * @returns {HTMLButtonElement}
	 */
	function note(name, text) {
		const node = el('button', 'la-note la-note-info', 'i');
		node.type = 'button';
		node.dataset.note = text;
		node.title = name;
		node.setAttribute('aria-label', name);
		node.setAttribute('aria-controls', POPOVER_ID);
		node.setAttribute('aria-expanded', 'false');
		return node;
	}

	function show(trigger) {
		if (trigger.classList.contains('la-note')) {
			showNote(trigger);
			return;
		}
		const item = trigger.dataset.info;
		const data = window.LAYOUT_ANALYSIS_DATA.sources;
		if (!data.items[item]) throw new Error(`layout_analysis: no sources for ${item}`);
		const items = [item].concat(ALSO_EXPLAINS[item] || []);
		// The references of every explanation shown, each once.
		const refs = [...new Set(items.flatMap((id) => data.items[id]))];
		hide();
		popover.querySelector('.la-popover-title').hidden = false;
		popover.querySelector('ul').hidden = false;
		popover
			.querySelector('.la-popover-texts')
			.replaceChildren(
				...items.map((id) =>
					el('p', 'la-popover-text', t(`layout_analysis.info.${id}`, values(id)))
				)
			);
		// A metric's full name heads its popover and names the dialog.
		const name = nameOf(item);
		const heading = popover.querySelector('.la-popover-name');
		heading.textContent = name || '';
		heading.hidden = name === null;
		if (name === null) popover.removeAttribute('aria-labelledby');
		else popover.setAttribute('aria-labelledby', heading.id);
		const formula = formulaOf(item);
		const line = popover.querySelector('.la-popover-formula');
		line.hidden = formula === null;
		line.replaceChildren();
		if (formula !== null)
			line.append(
				el('strong', '', `${t('layout_analysis.formula.label')} `),
				el('span', 'la-formula', t(`layout_analysis.formula.${formula}`, formulaValues()))
			);
		popover.querySelector('.la-popover-title').textContent = t('layout_analysis.info.sources');
		popover.querySelector('.la-popover-close').textContent = t('layout_analysis.info.close');
		const list = popover.querySelector('ul');
		list.replaceChildren();
		for (const id of refs) {
			const ref = data.references[id];
			const li = el('li');
			const a = el('a', '', ref.title);
			a.href = referenceUrl(data.repository, ref);
			routeLink(a);
			li.append(a);
			if (!ref.checked) li.append(` (${t('layout_analysis.info.unchecked')})`);
			list.append(li);
		}
		open(trigger);
	}

	/** A note's popover (a percentile chip): its text alone, no references. */
	function showNote(trigger) {
		hide();
		popover
			.querySelector('.la-popover-texts')
			.replaceChildren(el('p', 'la-popover-text', trigger.dataset.note));
		popover.querySelector('.la-popover-title').hidden = true;
		popover.querySelector('ul').hidden = true;
		// A metric's name and formula, from a popover shown before, are not this note's.
		popover.querySelector('.la-popover-name').hidden = true;
		popover.querySelector('.la-popover-formula').hidden = true;
		popover.removeAttribute('aria-labelledby');
		popover.querySelector('.la-popover-close').textContent = t('layout_analysis.info.close');
		open(trigger);
	}

	/** Shows the filled popover under its trigger and moves the focus into it. */
	function open(trigger) {
		owner = trigger;
		trigger.setAttribute('aria-expanded', 'true');
		popover.hidden = false;
		const box = trigger.getBoundingClientRect();
		const page = document.documentElement.clientWidth;
		const width = Math.min(POPOVER_WIDTH_PX, page - 2 * POPOVER_GUTTER_PX);
		popover.style.width = `${width}px`;
		const left = Math.min(Math.max(POPOVER_GUTTER_PX, box.left), page - width - POPOVER_GUTTER_PX);
		popover.style.left = `${left + window.scrollX}px`;
		popover.style.top = `${box.bottom + window.scrollY + POPOVER_GUTTER_PX / 2}px`;
		popover.querySelector('.la-popover-close').focus();
	}

	function hide() {
		if (!popover || popover.hidden) return;
		popover.hidden = true;
		const previous = owner;
		owner = null;
		if (previous && previous.isConnected) {
			previous.setAttribute('aria-expanded', 'false');
			previous.focus();
		}
	}

	function start() {
		build();
		document.querySelectorAll('.la-info').forEach(label);
		document.addEventListener(
			'click',
			(event) => {
				const trigger = event.target.closest('.la-info, .la-note');
				if (trigger) {
					// Inside a sortable header or a label: open only.
					event.preventDefault();
					event.stopPropagation();
					if (trigger === owner) hide();
					else show(trigger);
					return;
				}
				if (!event.target.closest(`#${POPOVER_ID}`)) hide();
			},
			true
		);
		document.addEventListener('keydown', (event) => {
			if (event.key === 'Escape') hide();
		});
		document.addEventListener('i18n:applied', () =>
			document.querySelectorAll('.la-info').forEach(label)
		);
	}

	// A Node vm context (the editor's script gates) loads the page without a document.
	if (typeof document !== 'undefined') {
		if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
		else start();
	}

	return {
		t,
		refusal,
		button,
		percentile,
		note,
		routeLink,
		locale,
		format,
		withUnit,
		measure,
		metricUnit,
		metricShort,
		metricSpoken,
		formulaOf,
		analyserUnit,
		NO_BREAK_SPACE,
		ALSO_EXPLAINS
	};
})();
