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
 * 4. Reset (with an « Undo » line, undo_offer.js), export and import as
 *    JSON, for the keyboard shown.
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
	const UNDO = window.LAYOUT_ANALYSIS_UNDO;
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
	// Told of every change the user made ({before, after} as stored), for the
	// Studio's undo history (edit_history.js); a load or a restore is not one.
	const editListeners = [];

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

	/** What is stored, as a copy the caller may keep (null: the defaults). */
	function snapshot() {
		const value = stored();
		return value ? JSON.parse(JSON.stringify(value)) : null;
	}

	/**
	 * Keeps the profiles, if asked, and tells everyone which keyboard changed;
	 * a kept change the user made (not quiet) is told to the edit listeners.
	 */
	function commit(next, persist, keyboardId, quiet) {
		const before = snapshot();
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
		if (persist && !quiet) {
			const after = snapshot();
			if (JSON.stringify(before) !== JSON.stringify(after))
				for (const listener of editListeners) listener({ before, after });
		}
	}

	/**
	 * Puts stored profiles back (an undo or a redo of the Studio's history),
	 * checked and kept, without telling it as a new edit.
	 * @param {object|null} saved - A snapshot() value.
	 */
	function restore(saved) {
		commit(checkedSet(saved), true, null, true);
	}

	/** Calls a listener with {before, after} after each change the user makes. */
	function onEdit(listener) {
		if (typeof listener !== 'function') throw new Error('layout_analysis: onEdit needs a function');
		editListeners.push(listener);
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
	 * The key an arrow, Home or End moves to from key k of a board: the
	 * nearest key of the same row to the left or right, the nearest by column
	 * in the row above or below, the row's first or last key; null for any
	 * other key, or at the board's edge.
	 * @param {{codes: string[], x: number[], y: number[]}} board - E.keyboard()'s answer.
	 * @param {number} k
	 * @param {string} name - A KeyboardEvent key.
	 * @returns {number|null}
	 */
	function neighbour(board, k, name) {
		const all = board.codes.map((_, j) => j);
		const sameRow = all.filter((j) => board.y[j] === board.y[k]);
		const nearest = (list) =>
			list.reduce((best, j) =>
				Math.abs(board.x[j] - board.x[k]) < Math.abs(board.x[best] - board.x[k]) ? j : best
			);
		if (name === 'Home' || name === 'End') {
			const row = sameRow.sort((a, b) => board.x[a] - board.x[b]);
			const end = row[name === 'Home' ? 0 : row.length - 1];
			return end === k ? null : end;
		}
		if (name === 'ArrowLeft' || name === 'ArrowRight') {
			const side = name === 'ArrowRight' ? 1 : -1;
			const ahead = sameRow.filter((j) => (board.x[j] - board.x[k]) * side > 0);
			return ahead.length === 0 ? null : nearest(ahead);
		}
		if (name === 'ArrowUp' || name === 'ArrowDown') {
			const rows = Array.from(new Set(board.y)).sort((a, b) => a - b);
			const row = rows[rows.indexOf(board.y[k]) + (name === 'ArrowDown' ? 1 : -1)];
			return row === undefined ? null : nearest(all.filter((j) => board.y[j] === row));
		}
		return null;
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
		// The one key of the map in the Tab order (a roving tabindex): the arrows
		// move it across the board, so the map is one Tab stop, not one per key.
		let roving = null;
		const head = el('header', 'la-heading');
		const title = el('h2');
		head.append(title, INFO.button('fingering'));
		const help = el('p', 'la-muted');
		const baseLabel = el('label', 'la-fingering-row');
		const baseText = document.createTextNode('');
		const baseSelect = el('select');
		baseLabel.append(baseText, baseSelect);
		// The keys as one toolbar named by the section's title: one Tab stop,
		// the arrows walk it.
		const map = el('div', 'la-heatmap la-fingering-map');
		title.id = 'la-fingering-title';
		map.setAttribute('role', 'toolbar');
		map.setAttribute('aria-labelledby', title.id);
		// The board keeps its key size and scrolls inside this focusable box, so
		// a narrow screen never scrolls the page sideways (WCAG 1.4.10).
		const mapBox = el('section', 'la-fingering-scroll');
		mapBox.tabIndex = 0;
		mapBox.append(map);
		const keyLine = el('p', 'la-fingering-row la-fingering-key-line');
		const keyName = el('strong');
		const fingerSelect = el('select');
		const homeButton = el('button');
		homeButton.type = 'button';
		keyLine.append(keyName, fingerSelect, homeButton);
		const actions = el('p', 'la-row la-fingering-actions');
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
		// The reset acts at once; its line offers the keyboard's profile back.
		const undo = UNDO.create(root);
		const status = el('p', 'la-muted');
		status.setAttribute('role', 'status');
		root.append(head, help, baseLabel, mapBox, keyLine, actions, undo.node, status);
		errorSinks.push((text) => {
			status.textContent = text;
			status.className = 'la-error';
		});
		const profile = () => profiles[keyboardId()] || null;

		/** The key button of a code on the map drawn. */
		function keyOf(code) {
			return Array.from(map.children).find((key) => key.dataset.code === code);
		}

		/** Gives the map's Tab stop to another key and focuses it. */
		function moveTo(code) {
			const from = keyOf(roving);
			if (from) from.tabIndex = -1;
			roving = code;
			const to = keyOf(code);
			to.tabIndex = 0;
			to.focus();
		}

		function draw() {
			title.textContent = t('layout_analysis.fingering.title');
			help.textContent = t('layout_analysis.fingering.help');
			baseText.data = t('layout_analysis.fingering.base');
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
			// Named even while the key line is hidden: a hidden control is still
			// in the accessibility tree of some readers, and nameless there.
			fingerSelect.setAttribute('aria-label', t('layout_analysis.fingering.finger'));
			homeButton.textContent = t('layout_analysis.fingering.set_home');
			mapBox.setAttribute('aria-label', t('layout_analysis.fingering.title'));
			const board = E.keyboard(keyboardId(), profile() || undefined);
			const rows = Array.from(new Set(board.y)).sort((a, b) => a - b);
			// A redraw replaces the keys: the focused one is focused again after it.
			const focused = map.contains(document.activeElement)
				? document.activeElement.dataset.code
				: null;
			if (!board.index.has(roving)) roving = board.index.has(selected) ? selected : board.codes[0];
			map.replaceChildren();
			let width = 0;
			let height = 0;
			board.codes.forEach((code, k) => {
				const key = el('button', 'la-key la-fingering-key');
				key.type = 'button';
				key.dataset.code = code;
				key.tabIndex = code === roving ? 0 : -1;
				const finger = DATA.model.fingers[board.finger[k]];
				key.dataset.finger = finger;
				key.textContent = finger;
				key.title = `${code} — ${t(`layout_analysis.finger.${finger}`)}`;
				// The visible finger code first (WCAG 2.5.3), then its finger in words and
				// where the key is, which the drawing shows by place.
				const row = board.y[k];
				const column =
					board.codes.filter((_, j) => board.y[j] === row && board.x[j] < board.x[k]).length + 1;
				key.setAttribute(
					'aria-label',
					`${finger} — ${t(`layout_analysis.finger.${finger}`)}, ${t('layout_analysis.heat.position', { row: rows.indexOf(row) + 1, column })}`
				);
				if (board.homeOf[board.finger[k]] === k) key.classList.add('la-fingering-home');
				if (code === selected) key.classList.add('la-selected');
				key.setAttribute('aria-pressed', String(code === selected));
				const left = (board.x[k] - 0.5) * KEY_UNIT_PX;
				const top = (board.y[k] - 1) * KEY_UNIT_PX;
				key.style.left = `${left}px`;
				key.style.top = `${top}px`;
				key.addEventListener('click', () => {
					selected = code;
					roving = code;
					draw();
				});
				key.addEventListener('keydown', (event) => {
					const next = neighbour(board, k, event.key);
					if (next === null) return;
					event.preventDefault();
					moveTo(board.codes[next]);
				});
				map.append(key);
				width = Math.max(width, left + KEY_UNIT_PX);
				height = Math.max(height, top + KEY_UNIT_PX);
			});
			map.style.width = `${width}px`;
			map.style.height = `${height}px`;
			if (focused) keyOf(board.index.has(focused) ? focused : roving).focus();
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
		reset.addEventListener('click', () => {
			const board = keyboardId();
			const before = profile();
			use(board, null, true);
			if (!before) {
				undo.clear();
				return;
			}
			undo.offer({
				name: t('layout_analysis.fingering.title'),
				focus: reset,
				undo: () => use(board, before, true)
			});
		});
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

	return { current, onChange, onEdit, snapshot, restore, mount };
})();
