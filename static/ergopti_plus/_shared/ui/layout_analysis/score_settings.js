// _shared/ui/layout_analysis/score_settings.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Score Settings
 * DESCRIPTION:
 * The one reading of the score settings the Comparer's « Réglages du score »
 * edits: the weights of the global score and the penalty floors, the ideal finger load, the shortcut
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
 * 4. Named presets: a few built-in ones (PRESETS), each a score settings
 *    file the Comparer applies as it imports one.
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
	// The built-in score presets (ux-study item 13), each the defaults with a
	// few weights and floors changed, in score_weights.json's units (points
	// per % or mm; a floor in the metric's unit). Each one's words are
	// layout_analysis.presets.<id>.name and .help in every locale.
	// - balanced: the Studio's defaults, as shipped.
	// - pinkies: the pinkies' load, the outer columns and pinky-ring pairs
	//   cost several times more (hands that tire at the edges).
	// - rolls: inward rolls weigh three times as much, redirects twice, and
	//   plain alternation less (the rolling style of Colemak-DH, Graphite).
	// - code: modifiers, AltGr, dead keys and missing characters cost more,
	//   and shortcuts on the left hand and direct digits count more.
	// - forgiving: Cyanophage's idea, the small same-finger and stretch
	//   shares good layouts all have cost nothing (floors), so rank is
	//   decided by what is clearly worse.
	const PRESETS = Object.freeze([
		Object.freeze({ id: 'balanced', weights: {}, floors: {} }),
		Object.freeze({
			id: 'pinkies',
			weights: { pinky_load: 1.2, outer_column: 3, pinky_ring: 2, finger_imbalance: 0.8 },
			floors: {}
		}),
		Object.freeze({
			id: 'rolls',
			weights: {
				roll_in: 3,
				roll_out: 1.5,
				roll3_in: 3,
				roll3_out: 1.5,
				redirect: 3,
				redirect_bad: 6,
				alternation: 0.1
			},
			floors: {}
		}),
		Object.freeze({
			id: 'code',
			weights: {
				modifier_usage: 1.5,
				altgr_usage: 4,
				dead_key_usage: 4,
				unsupported: 8,
				shortcut_left: 0.5,
				direct_digits: 0.3
			},
			floors: {}
		}),
		Object.freeze({
			id: 'forgiving',
			weights: {},
			floors: { sfb: 0.3, sfs: 1, lsb: 0.3, scissors: 0.1 }
		})
	]);

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
	 * @returns {{weights: object, floors: object, idealLoad: object, shortcuts: object,
	 *   formWeights: object}}
	 */
	function parse(saved) {
		const value = saved && typeof saved === 'object' ? saved : {};
		const weights = E.defaultWeights();
		for (const [id, weight] of Object.entries(value.weights || {}))
			if (id in weights && Number.isFinite(weight) && weight >= 0) weights[id] = weight;
		return {
			weights,
			floors: checkedOr(E.scoreFloors, value.floors, E.defaultFloors, 'penalty floors'),
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
	 * @returns {{weights, floors, idealLoad, shortcuts, formWeights, profile}}
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
		const floors = E.defaultFloors();
		return {
			weights:
				Object.keys(weights).filter((id) => now.weights[id] !== weights[id]).length +
				Object.keys(floors).filter((id) => now.floors[id] !== floors[id]).length,
			idealLoad: !same(now.idealLoad, E.defaultIdealLoad()),
			shortcuts:
				!same(now.shortcuts.letters, shortcuts.letters) ||
				!same(now.shortcuts.ease, shortcuts.ease),
			formWeights: !same(now.formWeights, E.defaultFormFactorWeights()),
			fingering: now.profile !== undefined
		};
	}

	/**
	 * A built-in preset as a score settings file (E.scoreConfig, the format of
	 * « Export »): the defaults, its weights and floors over them.
	 * @param {string} id - One of PRESETS.
	 * @returns {object} The file's JSON value.
	 * @throws {Error} On an unknown preset.
	 */
	function presetConfig(id) {
		const preset = PRESETS.find((entry) => entry.id === id);
		if (!preset) throw new Error(`layout_analysis: no score preset ${id}`);
		return E.scoreConfig({
			weights: Object.assign(E.defaultWeights(), preset.weights),
			floors: Object.assign(E.defaultFloors(), preset.floors),
			idealLoad: E.defaultIdealLoad(),
			shortcuts: E.defaultShortcuts(),
			formWeights: E.defaultFormFactorWeights()
		});
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

	return {
		parse,
		analysisOptions,
		customised,
		notify,
		onChange,
		presetConfig,
		PRESET_IDS: PRESETS.map((preset) => preset.id),
		CHANGE_EVENT
	};
})();
