// _shared/ui/layout_analysis/score_settings.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Score Settings
 * DESCRIPTION:
 * The one reading of the score settings the Comparer's « Réglages du score »
 * edits: the weights of the global score, the ideal finger load, the shortcut
 * table (shortcut_left), the compact form factors' weights (compact_fit) and
 * the fingering profile of each keyboard. The Comparer, the editor's analysis
 * panel and the optimizer all score with what this module reads, so a weight
 * changed in the Comparer changes every other score and the optimizer's
 * objective too.
 *
 * FEATURES & RATIONALE:
 * 1. One source of truth: the Comparer keeps its settings in localStorage
 *    (LAYOUT_ANALYSIS_FILES.SETTINGS_KEY) and the fingering editor keeps the
 *    profiles; this module reads both, each value checked by the engine the
 *    way the Comparer checks it, and never writes them.
 * 2. Followed live: the Comparer calls notify() after it saves (the same
 *    page: the app's Studio window), and another frame of the site hears the
 *    'storage' event; a fingering change comes through the fingering editor.
 * 3. A stored value the engine refuses is named in the console and its
 *    default applies, as the Comparer does on load.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS_SCORE_SETTINGS = (function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const FILES = window.LAYOUT_ANALYSIS_FILES;
	// The same-page signal the Comparer sends after it saves its settings.
	const CHANGE_EVENT = 'ergopti-studio:score-settings';

	/** The fingering editor, which owns the profiles; loaded before any reading. */
	function fingering() {
		const module = window.LAYOUT_ANALYSIS_FINGERING;
		if (!module) throw new Error('layout_analysis: score_settings needs fingering_editor.js');
		return module;
	}

	/** The Comparer's saved object; an unavailable storage or a broken value gives none. */
	function stored() {
		try {
			const raw = window.localStorage.getItem(FILES.SETTINGS_KEY);
			const value = raw ? JSON.parse(raw) : {};
			return value && typeof value === 'object' ? value : {};
		} catch {
			// A private window or blocked storage: the defaults apply.
			return {};
		}
	}

	/** A table the engine accepts (check), else its default, the refusal named once. */
	function checkedOr(check, value, fallback, what) {
		if (value === undefined || value === null) return fallback();
		try {
			return check(value);
		} catch (error) {
			console.warn(
				`layout_analysis: the saved ${what} is refused (${error.code || error.message}); the default applies`
			);
			return fallback();
		}
	}

	/**
	 * The score settings of a saved Comparer object: each weight the engine
	 * still has and accepts over the defaults, and the ideal load, shortcut
	 * table and form factor weights when the engine accepts them whole.
	 * @param {object} saved - What the Comparer stored (any shape).
	 * @returns {{weights: object, idealLoad: object, shortcuts: object, formWeights: object}}
	 */
	function parse(saved) {
		const value = saved && typeof saved === 'object' ? saved : {};
		const weights = E.defaultWeights();
		for (const [id, weight] of Object.entries(value.weights || {}))
			if (id in weights && Number.isFinite(weight) && weight >= 0) weights[id] = weight;
		return {
			weights,
			idealLoad: checkedOr(
				(load) => Object.assign({}, E.idealLoad(load)),
				value.idealLoad,
				E.defaultIdealLoad,
				'ideal finger load'
			),
			shortcuts: checkedOr(E.shortcuts, value.shortcuts, E.defaultShortcuts, 'shortcut table'),
			formWeights: checkedOr(
				E.formFactorWeights,
				value.formWeights,
				E.defaultFormFactorWeights,
				'form factor weights'
			)
		};
	}

	/**
	 * The analyse() options of every Studio score on a keyboard: the saved
	 * settings and that keyboard's fingering profile (undefined: its defaults).
	 * @param {string} keyboard - A model keyboard id.
	 * @returns {{weights, idealLoad, shortcuts, formWeights, profile}}
	 */
	function analysisOptions(keyboard) {
		return Object.assign(parse(stored()), {
			profile: fingering().current(keyboard) || undefined
		});
	}

	/** Whether two plain values hold the same numbers. */
	function same(a, b) {
		const keys = Object.keys(a);
		return keys.length === Object.keys(b).length && keys.every((k) => a[k] === b[k]);
	}

	/**
	 * Which settings differ from the model's defaults on a keyboard, for a page
	 * that only shows them.
	 * @param {string} keyboard - A model keyboard id.
	 * @returns {{weights: number, idealLoad: boolean, shortcuts: boolean,
	 *   formWeights: boolean, fingering: boolean}} weights: how many differ.
	 */
	function customised(keyboard) {
		const now = analysisOptions(keyboard);
		const weights = E.defaultWeights();
		const shortcuts = E.defaultShortcuts();
		return {
			weights: Object.keys(weights).filter((id) => now.weights[id] !== weights[id]).length,
			idealLoad: !same(now.idealLoad, E.defaultIdealLoad()),
			shortcuts:
				!same(now.shortcuts.letters, shortcuts.letters) ||
				!same(now.shortcuts.ease, shortcuts.ease),
			formWeights: !same(now.formWeights, E.defaultFormFactorWeights()),
			fingering: now.profile !== undefined
		};
	}

	/** Tells this page's readers that the Comparer saved its settings. */
	function notify() {
		window.dispatchEvent(new CustomEvent(CHANGE_EVENT));
	}

	/**
	 * Calls a listener (no argument) after every change of the settings: the
	 * Comparer's save on this page or in another frame, or a fingering edit.
	 * @param {function(): void} listener
	 */
	function onChange(listener) {
		if (typeof listener !== 'function')
			throw new Error('layout_analysis: score_settings.onChange needs a function');
		window.addEventListener(CHANGE_EVENT, () => listener());
		window.addEventListener('storage', (event) => {
			if (event.key === FILES.SETTINGS_KEY) listener();
		});
		fingering().onChange(() => listener());
	}

	return { parse, analysisOptions, customised, notify, onChange, CHANGE_EVENT };
})();
