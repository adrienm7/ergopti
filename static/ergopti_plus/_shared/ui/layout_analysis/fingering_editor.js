// _shared/ui/layout_analysis/fingering_editor.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Fingering Editor
 * DESCRIPTION:
 * The user's own model of the hand for Ergopti Studio: which finger presses
 * each physical key, the home key of each finger (a column stagger, the angle
 * mod, an ergonomic board) and the base fingering. The Comparer shows the
 * editor; the Comparer, the editor's analysis panel and the other analysers'
 * scores all analyse with the same profile.
 *
 * FEATURES & RATIONALE:
 * 1. One current profile per viewer: LAYOUT_ANALYSIS_FINGERING.current() is
 *    what every analysis passes as `profile`; null means the defaults.
 * 2. Kept by the host when it can (LAYOUT_ANALYSIS_HOST.store.loadProfile /
 *    saveProfile: the app's data folder, the site's IndexedDB), else in
 *    localStorage; another page of the same site follows through the
 *    'storage' event.
 * 3. Checked by the engine (fingeringProfile, keyboard) before it is kept: an
 *    invalid change is refused with its reason, never half applied.
 * 4. Reset, export and import as JSON.
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
	const STORAGE_KEY = 'ergopti.layout_analysis.profile.v1';
	const PROFILE_ID = 'custom';
	// Size of one key unit of the key map, in pixels.
	const KEY_UNIT_PX = 40;
	// The board the key map is drawn on when the page names none.
	const MAP_KEYBOARD = 'iso';
	const BASES = ['standard', 'angle'];

	let profile = null;
	const listeners = [];

	function el(tag, className, text) {
		const node = document.createElement(tag);
		if (className) node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	}

	const host = () => (window.LAYOUT_ANALYSIS_HOST && window.LAYOUT_ANALYSIS_HOST.store) || null;

	/** A profile the engine accepts on every board, or an error. */
	function checked(candidate) {
		const clean = E.fingeringProfile(candidate);
		for (const id of Object.keys(DATA.model.keyboards)) E.keyboard(id, clean);
		return clean;
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

	/** Makes `next` (or the defaults, for null) the current profile and tells everyone. */
	function use(next, persist) {
		profile = next ? checked(next) : null;
		if (persist) {
			const store = host();
			if (store && typeof store.saveProfile === 'function')
				store
					.saveProfile(profile)
					.catch(() => notifyError('layout_analysis.fingering.save_failed'));
			else writeLocal(profile);
		}
		for (const listener of listeners) listener(profile);
	}

	let errorSink = null;
	function notifyError(key, values) {
		if (errorSink) errorSink(t(key, values));
	}

	/** The current profile, or null for the defaults. */
	function current() {
		return profile;
	}

	/** Calls a listener with the new profile after every change. */
	function onChange(listener) {
		if (typeof listener !== 'function')
			throw new Error('layout_analysis: onChange needs a function');
		listeners.push(listener);
	}

	/**
	 * Applies an edit to a copy of the current profile; refused edits keep the
	 * current one and report why.
	 */
	function edit(change) {
		const next = JSON.parse(
			JSON.stringify(profile || { id: PROFILE_ID, name: '', fingers: {}, home: {} })
		);
		change(next);
		try {
			use(next, true);
			return true;
		} catch (error) {
			notifyError('layout_analysis.fingering.invalid', { reason: error.message });
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
		errorSink = (text) => {
			status.textContent = text;
			status.className = 'la-error';
		};

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
			baseSelect.value = (profile && profile.base) || 'standard';
			// A split, ortholinear or column-staggered board has its own fingering.
			baseLabel.hidden = Boolean(DATA.model.keyboards[keyboardId()].board);
			reset.textContent = t('layout_analysis.fingering.reset');
			exportButton.textContent = t('layout_analysis.fingering.export');
			importText.textContent = t('layout_analysis.fingering.import');
			const board = E.keyboard(keyboardId(), profile || undefined);
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
				status.textContent = profile ? t('layout_analysis.fingering.custom') : '';
		}

		baseSelect.addEventListener('change', () =>
			edit((next) => {
				next.base = baseSelect.value;
			})
		);
		fingerSelect.addEventListener('change', () =>
			edit((next) => {
				next.fingers[selected] = fingerSelect.value;
			})
		);
		homeButton.addEventListener('click', () =>
			edit((next) => {
				next.home[fingerSelect.value] = selected;
			})
		);
		reset.addEventListener('click', () => {
			const store = host();
			if (store && typeof store.saveProfile === 'function') use(null, true);
			else {
				writeLocal(null);
				use(null, false);
			}
		});
		exportButton.addEventListener('click', () => {
			const text = JSON.stringify(profile || { id: PROFILE_ID, fingers: {}, home: {} }, null, '\t');
			const link = el('a');
			link.href = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
			link.download = 'ergopti-fingering.json';
			document.body.append(link);
			link.click();
			link.remove();
		});
		importInput.addEventListener('change', async () => {
			const file = importInput.files && importInput.files[0];
			importInput.value = '';
			if (!file) return;
			try {
				use(JSON.parse(await file.text()), true);
			} catch (error) {
				notifyError('layout_analysis.fingering.invalid', { reason: error.message });
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
						use(saved || null, false);
					} catch (error) {
						notifyError('layout_analysis.fingering.invalid', { reason: error.message });
					}
				},
				() => notifyError('layout_analysis.fingering.load_failed')
			);
			return;
		}
		try {
			use(readLocal(), false);
		} catch {
			// A saved profile the engine no longer accepts: the defaults.
			writeLocal(null);
		}
		window.addEventListener('storage', (event) => {
			if (event.key !== STORAGE_KEY) return;
			try {
				use(readLocal(), false);
			} catch {
				use(null, false);
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
