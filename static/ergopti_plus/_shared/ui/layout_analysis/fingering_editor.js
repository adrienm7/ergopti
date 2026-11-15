// _shared/ui/layout_analysis/fingering_editor.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Fingering Editor
 * DESCRIPTION:
 * The user's own model of the hand for Ergopti Studio: which finger presses
 * each physical key, the home key of each finger (a column stagger, the angle
 * mod, an ergonomic board) and the base fingering. The Comparer shows the
 * editor; the Comparer, the editor's analysis panel and the other analysers'
 * scores all analyse a keyboard with that keyboard's profile.
 *
 * FEATURES & RATIONALE:
 * 1. One profile per keyboard model (ISO, ANSI, ortholinear, each split
 *    board), since each geometry has its own keys and home row (maintainer,
 *    2026-11-14 night): LAYOUT_ANALYSIS_FINGERING.current(keyboard) is what
 *    every analysis on that keyboard passes as `profile`; null means the
 *    defaults. Stored as {version: 2, profiles: {<keyboard>: profile}}; the
 *    single profile of version 1 is not carried over (decided by the agent,
 *    to review by the maintainer: it served every board at once).
 * 2. Kept by the host when it can (LAYOUT_ANALYSIS_HOST.store.loadProfile /
 *    saveProfile: the app's data folder, the site's IndexedDB), else in
 *    localStorage; another page of the same site follows through the
 *    'storage' event.
 * 3. Checked by the engine (fingeringProfile, keyboard) before it is kept: an
 *    invalid change is refused with its reason, never half applied.
 * 4. Reset, export and import as JSON, for the keyboard shown.
 * 5. Mounted where the user analyses: the Comparer and the editor's analysis
 *    panel (both in the app's Studio window); every mount shows the refusals.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS_FINGERING = (function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	const INFO = window.LAYOUT_ANALYSIS_INFO;
	const t = INFO.t;
	const STORAGE_KEY = 'ergopti.layout_analysis.profiles.v2';
	const STORED_VERSION = 2;
	const PROFILE_ID = 'custom';
	// Size of one key unit of the key map, in pixels.
	const KEY_UNIT_PX = 40;
	// The board the key map is drawn on when the page names none.
	const MAP_KEYBOARD = 'iso';
	const BASES = ['standard', 'angle'];

	// keyboard id → its checked profile; a keyboard absent here uses the defaults.
	let profiles = {};
	const listeners = [];

	function el(tag, className, text) {
		const node = document.createElement(tag);
		if (className) node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	}

	const host = () => (window.LAYOUT_ANALYSIS_HOST && window.LAYOUT_ANALYSIS_HOST.store) || null;

	/** A profile the engine accepts on its keyboard, or an error. */
	function checked(keyboardId, candidate) {
		if (!DATA.model.keyboards[keyboardId])
			throw new Error(`layout_analysis: unknown keyboard ${keyboardId}`);
		const clean = E.fingeringProfile(candidate);
		E.keyboard(keyboardId, clean);
		return clean;
	}

	/** Every keyboard's profile from what was stored, checked; null is none. */
	function checkedSet(stored) {
		if (stored === null || stored === undefined) return {};
		if (
			typeof stored !== 'object' ||
			stored.version !== STORED_VERSION ||
			!stored.profiles ||
			typeof stored.profiles !== 'object'
		)
			// The engine's own refusal of what is not a profile (fingering_not_object).
			E.fingeringProfile(null);
		const out = {};
		for (const [keyboardId, candidate] of Object.entries(stored.profiles))
			out[keyboardId] = checked(keyboardId, candidate);
		return out;
	}

	/** What is stored: every keyboard's profile, or null when all use the defaults. */
	function stored() {
		return Object.keys(profiles).length ? { version: STORED_VERSION, profiles } : null;
	}

	function readLocal() {
		try {
			const raw = window.localStorage.getItem(STORAGE_KEY);
			return raw ? JSON.parse(raw) : null;
		} catch {
			return null;
		}
	}

	function writeLocal(value) {
		try {
			if (value) window.localStorage.setItem(STORAGE_KEY, JSON.stringify(value));
			else window.localStorage.removeItem(STORAGE_KEY);
		} catch {
			// A private window or a full quota: the profile lasts this visit.
		}
	}

	/** Keeps the profiles, if asked, and tells everyone which keyboard changed. */
	function commit(next, persist, keyboardId) {
		profiles = next;
		if (persist) {
			const store = host();
			if (store && typeof store.saveProfile === 'function')
				store
					.saveProfile(stored())
					.catch(() => notifyError('layout_analysis.fingering.save_failed'));
			else writeLocal(stored());
		}
		for (const listener of listeners) listener(keyboardId);
	}

	/** Makes `next` (or the defaults, for null) the profile of one keyboard. */
	function use(keyboardId, next, persist) {
		const copy = Object.assign({}, profiles);
		if (next) copy[keyboardId] = checked(keyboardId, next);
		else delete copy[keyboardId];
		commit(copy, persist, keyboardId);
	}

	// Each mount's status line: a refusal is shown wherever the editor is.
	const errorSinks = [];
	function notifyError(key, values) {
		for (const sink of errorSinks) sink(t(key, values));
	}

	/**
	 * The profile of one keyboard, or null for its defaults.
	 * @param {string} keyboardId A model keyboard id.
	 */
	function current(keyboardId) {
		if (typeof keyboardId !== 'string' || !DATA.model.keyboards[keyboardId])
			throw new Error(`layout_analysis: current() needs a keyboard, got ${keyboardId}`);
		return profiles[keyboardId] || null;
	}

	/** Calls a listener with the keyboard whose profile changed (null: all of them). */
	function onChange(listener) {
		if (typeof listener !== 'function')
			throw new Error('layout_analysis: onChange needs a function');
		listeners.push(listener);
	}

	/**
	 * Applies an edit to a copy of the current profile; refused edits keep the
	 * current one and report why.
	 */
	function edit(keyboardId, change) {
		const next = JSON.parse(
			JSON.stringify(profiles[keyboardId] || { id: PROFILE_ID, name: '', fingers: {}, home: {} })
		);
		change(next);
		try {
			use(keyboardId, next, true);
			return true;
		} catch (error) {
			notifyError('layout_analysis.fingering.invalid', { reason: INFO.refusal(error) });
			return false;
		}
	}

	/**
	 * Draws the editor into a container: base fingering, key map, finger and
	 * home-key controls for the selected key, reset, export and import.
	 * @param {HTMLElement} root
	 * @param {{keyboard?: function(): string}} [options] - The keyboard the map
	 *   shows (the page's current choice).
	 * @returns {{draw: function(): void}} Redraws, e.g. after the keyboard changed.
	 */
	function mount(root, options) {
		const keyboardId = () => (options && options.keyboard ? options.keyboard() : MAP_KEYBOARD);
		let selected = null;
		const head = el('div', 'la-heading');
		const title = el('h2');
		head.append(title, INFO.button('fingering'));
		const help = el('p', 'la-muted');
		const baseLabel = el('label', 'la-fingering-row');
		const baseText = el('span');
		const baseSelect = el('select');
		baseLabel.append(baseText, baseSelect);
		const map = el('div', 'la-heatmap la-fingering-map');
		const keyLine = el('div', 'la-fingering-row');
		const keyName = el('strong');
		const fingerSelect = el('select');
		fingerSelect.setAttribute('aria-label', '');
		const homeButton = el('button');
		homeButton.type = 'button';
		keyLine.append(keyName, fingerSelect, homeButton);
		const actions = el('div', 'la-row');
		const reset = el('button');
		reset.type = 'button';
		const exportButton = el('button');
		exportButton.type = 'button';
		const importLabel = el('label', 'la-file');
		// The page's button: the native control's words stay hidden (style.css .la-file).
		const importText = el('span', 'la-file-button');
		const importInput = el('input');
		importInput.type = 'file';
		importInput.accept = '.json';
		importLabel.append(importText, importInput);
		actions.append(reset, exportButton, importLabel);
		const status = el('p', 'la-muted');
		status.setAttribute('role', 'status');
		root.append(head, help, baseLabel, map, keyLine, actions, status);
		errorSinks.push((text) => {
			status.textContent = text;
			status.className = 'la-error';
		});
		const profile = () => profiles[keyboardId()] || null;

		function draw() {
			title.textContent = t('layout_analysis.fingering.title');
			help.textContent = t('layout_analysis.fingering.help');
			baseText.textContent = t('layout_analysis.fingering.base');
			baseSelect.replaceChildren(
				...BASES.map((id) => {
					const option = el('option', '', t(`layout_analysis.fingering.base_${id}`));
					option.value = id;
					return option;
				})
			);
			baseSelect.value = (profile() && profile().base) || 'standard';
			// A split, ortholinear or column-staggered board has its own fingering.
			baseLabel.hidden = Boolean(DATA.model.keyboards[keyboardId()].board);
			reset.textContent = t('layout_analysis.fingering.reset');
			exportButton.textContent = t('layout_analysis.fingering.export');
			importText.textContent = t('layout_analysis.fingering.import');
			const board = E.keyboard(keyboardId(), profile() || undefined);
			map.replaceChildren();
			let width = 0;
			let height = 0;
			board.codes.forEach((code, k) => {
				const key = el('button', 'la-key la-fingering-key');
				key.type = 'button';
				const finger = DATA.model.fingers[board.finger[k]];
				key.dataset.finger = finger;
				key.textContent = finger;
				key.title = `${code} — ${t(`layout_analysis.finger.${finger}`)}`;
				if (board.homeOf[board.finger[k]] === k) key.classList.add('la-fingering-home');
				if (code === selected) key.classList.add('la-selected');
				const left = (board.x[k] - 0.5) * KEY_UNIT_PX;
				const top = (board.y[k] - 1) * KEY_UNIT_PX;
				key.style.left = `${left}px`;
				key.style.top = `${top}px`;
				key.addEventListener('click', () => {
					selected = code;
					draw();
				});
				map.append(key);
				width = Math.max(width, left + KEY_UNIT_PX);
				height = Math.max(height, top + KEY_UNIT_PX);
			});
			map.style.width = `${width}px`;
			map.style.height = `${height}px`;
			keyLine.hidden = !selected;
			if (selected) {
				const k = board.index.get(selected);
				keyName.textContent = selected;
				fingerSelect.replaceChildren(
					...DATA.model.fingers.map((id) => {
						const option = el('option', '', t(`layout_analysis.finger.${id}`));
						option.value = id;
						return option;
					})
				);
				fingerSelect.value = DATA.model.fingers[board.finger[k]];
				fingerSelect.setAttribute('aria-label', t('layout_analysis.fingering.finger'));
				homeButton.textContent = t('layout_analysis.fingering.set_home');
				homeButton.disabled = board.homeOf[board.finger[k]] === k;
			}
			if (status.className !== 'la-error')
				status.textContent = profile() ? t('layout_analysis.fingering.custom') : '';
		}

		baseSelect.addEventListener('change', () =>
			edit(keyboardId(), (next) => {
				next.base = baseSelect.value;
			})
		);
		fingerSelect.addEventListener('change', () =>
			edit(keyboardId(), (next) => {
				next.fingers[selected] = fingerSelect.value;
			})
		);
		homeButton.addEventListener('click', () =>
			edit(keyboardId(), (next) => {
				next.home[fingerSelect.value] = selected;
			})
		);
		reset.addEventListener('click', () => use(keyboardId(), null, true));
		exportButton.addEventListener('click', () => {
			const text = JSON.stringify(
				profile() || { id: PROFILE_ID, fingers: {}, home: {} },
				null,
				'\t'
			);
			const link = el('a');
			link.href = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
			link.download = `ergopti-fingering-${keyboardId()}.json`;
			document.body.append(link);
			link.click();
			link.remove();
		});
		importInput.addEventListener('change', async () => {
			const file = importInput.files && importInput.files[0];
			importInput.value = '';
			if (!file) return;
			try {
				use(keyboardId(), JSON.parse(await file.text()), true);
			} catch (error) {
				notifyError('layout_analysis.fingering.invalid', { reason: INFO.refusal(error) });
			}
		});
		onChange(() => {
			status.className = 'la-muted';
			draw();
		});
		document.addEventListener('i18n:applied', draw);
		draw();
		return { draw };
	}

	// The saved profile: the host's first, else this browser's.
	function start() {
		const store = host();
		if (store && typeof store.loadProfile === 'function') {
			store.loadProfile().then(
				(saved) => {
					try {
						commit(checkedSet(saved || null), false, null);
					} catch (error) {
						notifyError('layout_analysis.fingering.invalid', { reason: INFO.refusal(error) });
					}
				},
				() => notifyError('layout_analysis.fingering.load_failed')
			);
			return;
		}
		try {
			commit(checkedSet(readLocal()), false, null);
		} catch (error) {
			// A saved set the engine no longer accepts: said, and the defaults.
			notifyError('layout_analysis.fingering.invalid', { reason: INFO.refusal(error) });
		}
		window.addEventListener('storage', (event) => {
			if (event.key !== STORAGE_KEY) return;
			try {
				commit(checkedSet(readLocal()), false, null);
			} catch (error) {
				notifyError('layout_analysis.fingering.invalid', { reason: INFO.refusal(error) });
			}
		});
	}

	// After the page's own scripts, so a host defined late (the app's window) is seen.
	if (typeof document !== 'undefined') {
		if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
		else start();
	}

	return { current, onChange, mount };
})();
