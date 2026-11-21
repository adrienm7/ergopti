// _shared/ui/layout_try/try_page.js

/**
 * ==============================================================================
 * MODULE: Layout Try Page
 * DESCRIPTION:
 * The « Essayer » tab of Ergopti Studio (maintainer, 2026-11-21): the visitor
 * picks a layout of the Studio's library (Ergopti, or the one a ?layout=
 * address names, as /studio/essayer?layout=ergopti) and types in a text area;
 * each key press types what that layout puts on the key (typing.js), dead
 * keys and AltGr levels included, whatever layout the visitor's OS has. It
 * replaces the site's former « Essayer » page (/ergopti/utilisation), whose
 * old anchors (#input-text, #keyboard_emulation) name the text area and the
 * keyboard here.
 *
 * FEATURES & RATIONALE:
 * 1. A native text area: the browser keeps the caret, the selection,
 *    Backspace, Delete, Enter, the arrows, copy and paste and its own Ctrl+Z;
 *    only the keys the layout holds are typed by the emulator. Tab and
 *    Shift+Tab leave the field (WCAG 2.1.2).
 * 2. Heard: a waiting dead key is said in a polite status line, and the
 *    level shown is named in the keyboard's heading; the drawn keyboard is
 *    decorative (aria-hidden), the text area holds the result.
 * 3. Every visible string is a locale key of layout_try.* (21 locales).
 * 4. Fail fast: a library without the default layout throws; a ?layout= the
 *    library lacks is refused in words, and the page types with Ergopti.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_TRY_PAGE = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const PREFIX = 'layout_try.';
	// The message that tells the Studio which layout is typed (src/routes/studio/essayer).
	const LAYOUT_MESSAGE = 'ergopti-studio:try-layout';
	// The layout typed when the address names none (maintainer, 2026-11-21).
	const DEFAULT_LAYOUT = 'ergopti';
	// The library's origins, in the order the list groups them.
	const ORIGINS = ['registry', 'reference', 'library'];
	// The rows of keys the keyboard draws (an ISO board's typing area).
	const BOARD_ROWS = [
		[
			'Backquote',
			'Digit1',
			'Digit2',
			'Digit3',
			'Digit4',
			'Digit5',
			'Digit6',
			'Digit7',
			'Digit8',
			'Digit9',
			'Digit0',
			'Minus',
			'Equal'
		],
		[
			'KeyQ',
			'KeyW',
			'KeyE',
			'KeyR',
			'KeyT',
			'KeyY',
			'KeyU',
			'KeyI',
			'KeyO',
			'KeyP',
			'BracketLeft',
			'BracketRight'
		],
		[
			'KeyA',
			'KeyS',
			'KeyD',
			'KeyF',
			'KeyG',
			'KeyH',
			'KeyJ',
			'KeyK',
			'KeyL',
			'Semicolon',
			'Quote',
			'Backslash'
		],
		[
			'IntlBackslash',
			'KeyZ',
			'KeyX',
			'KeyC',
			'KeyV',
			'KeyB',
			'KeyN',
			'KeyM',
			'Comma',
			'Period',
			'Slash'
		]
	];
	// The keys that only change the level shown.
	const MODIFIER_KEYS = new Set([
		'ShiftLeft',
		'ShiftRight',
		'ControlLeft',
		'ControlRight',
		'AltLeft',
		'AltRight',
		'MetaLeft',
		'MetaRight',
		'CapsLock'
	]);

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const params = new URLSearchParams(location.search);
	const lang = params.get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	const MARKUP = `<header class="lt-header">
	<h1 data-i18n="layout_try.title"></h1>
	<p class="lt-lead" data-i18n="layout_try.intro"></p>
</header>
<p class="lt-field">
	<label for="lt-layout" data-i18n="layout_try.layout_label"></label>
	<select id="lt-layout"></select>
</p>
<p id="lt-layout-error" class="lt-error" role="alert" hidden></p>
<p class="lt-field lt-typing">
	<label for="input-text" data-i18n="layout_try.text_label"></label>
	<textarea id="input-text" rows="6" spellcheck="false" autocomplete="off" autocapitalize="off" aria-describedby="lt-help lt-status" data-emulation-state="loading" aria-busy="true" disabled></textarea>
</p>
<p id="lt-help" class="lt-muted" data-i18n="layout_try.help"></p>
<p id="lt-status" class="lt-status" role="status"></p>
<p class="lt-actions"><button id="lt-clear" type="button" data-i18n="layout_try.clear"></button></p>
<section id="keyboard_emulation" class="lt-keyboard" aria-labelledby="lt-board-title">
	<h2 id="lt-board-title"></h2>
	<ol id="lt-board" class="lt-board" aria-hidden="true"></ol>
</section>`;

	// ============================
	// ======= 2/ Mount ===========
	// ============================

	/**
	 * Mounts the page.
	 * @param {HTMLElement} root - The element the page fills.
	 * @returns {{choose: function(string): void}}
	 */
	function mount(root) {
		if (!root || root.dataset.mounted) throw new Error('layout try: mount needs one fresh root');
		root.dataset.mounted = 'true';
		const t = (key, values) => window.LAYOUT_ANALYSIS_INFO.t(key, values);
		const $ = (id) => root.querySelector('#' + id);
		root.innerHTML = MARKUP;
		const layouts = window.LAYOUT_ANALYSIS_DATA.layouts;
		const byId = new Map(layouts.map((layout) => [layout.id, layout]));
		if (!byId.has(DEFAULT_LAYOUT))
			throw new Error(`layout try: the library has no ${DEFAULT_LAYOUT} layout`);
		const asked = params.get('layout');
		const state = {
			layout: asked && byId.has(asked) ? asked : DEFAULT_LAYOUT,
			refused: asked && !byId.has(asked) ? asked : null,
			typist: null,
			// Right Alt held: the AltGr level on an OS layout without AltGr.
			altRight: false,
			held: { shift: false, altgr: false, caps: false },
			pressed: null
		};
		const select = $('lt-layout');
		const area = $('input-text');

		function applyStrings() {
			for (const node of root.querySelectorAll('[data-i18n]'))
				node.textContent = t(node.dataset.i18n);
			fillLayouts();
			sayRefused();
			drawBoard();
			sayStatus();
		}

		/** The library, grouped by origin, each group by name. */
		function fillLayouts() {
			const groups = ORIGINS.map((origin) => {
				const group = document.createElement('optgroup');
				group.label =
					origin === 'library'
						? t(`${PREFIX}origin_library`)
						: t(`layout_analysis.filter.origin_${origin}`);
				const members = layouts
					.filter((layout) => layout.origin === origin)
					.sort((a, b) => a.name.localeCompare(b.name));
				for (const layout of members) {
					const option = document.createElement('option');
					option.value = layout.id;
					option.textContent = layout.name;
					group.append(option);
				}
				return group;
			});
			const unknown = layouts.find((layout) => !ORIGINS.includes(layout.origin));
			if (unknown)
				throw new Error(`layout try: ${unknown.id} has the unknown origin ${unknown.origin}`);
			select.replaceChildren(...groups.filter((group) => group.children.length));
			select.value = state.layout;
		}

		function sayRefused() {
			const node = $('lt-layout-error');
			node.hidden = !state.refused;
			node.textContent = state.refused
				? t(`${PREFIX}unknown_layout`, { id: state.refused, name: byId.get(DEFAULT_LAYOUT).name })
				: '';
		}

		/** The keyboard of the level held, the last key pressed marked. */
		function drawBoard() {
			const level = state.typist.level(state.held);
			$('lt-board-title').textContent = t(`${PREFIX}board_title`, {
				name: byId.get(state.layout).name,
				level: t(`${PREFIX}level.${level}`)
			});
			$('lt-board').replaceChildren(
				...BOARD_ROWS.map((codes) => {
					const row = document.createElement('li');
					const keys = document.createElement('ol');
					keys.className = 'lt-row';
					for (const code of codes) {
						const key = document.createElement('li');
						const cap = document.createElement('kbd');
						cap.textContent = state.typist.legend(code, level).replace(/\s/g, '␣');
						key.className = 'lt-key';
						key.dataset.code = code;
						if (code === state.pressed) key.classList.add('lt-pressed');
						if (!state.typist.owns(code)) key.classList.add('lt-absent');
						key.append(cap);
						keys.append(key);
					}
					row.append(keys);
					return row;
				})
			);
		}

		/** The waiting dead key, said politely; nothing while none waits. */
		function sayStatus() {
			const waiting = state.typist.pending();
			$('lt-status').textContent =
				waiting === null ? '' : t(`${PREFIX}status.dead`, { char: waiting || '◌' });
		}

		/** Types with another layout of the library. */
		function choose(id) {
			if (!byId.has(id)) throw new Error(`layout try: the library has no layout ${id}`);
			state.layout = id;
			state.typist = window.LAYOUT_TRY_TYPING.create(byId.get(id));
			state.pressed = null;
			select.value = id;
			drawBoard();
			sayStatus();
			// The Studio keeps the choice in its address, so it can be shared.
			if (window.parent !== window)
				window.parent.postMessage({ type: LAYOUT_MESSAGE, layout: id }, location.origin);
		}

		/** The modifiers a key event holds. */
		function heldOf(event) {
			return {
				shift: event.shiftKey,
				altgr: state.altRight || event.altKey || event.getModifierState('AltGraph'),
				caps: event.getModifierState('CapsLock')
			};
		}

		function showLevel(event) {
			const held = heldOf(event);
			if (JSON.stringify(held) === JSON.stringify(state.held)) return;
			state.held = held;
			drawBoard();
		}

		area.addEventListener('keydown', (event) => {
			if (event.isComposing) return;
			if (event.code === 'AltRight') state.altRight = true;
			if (MODIFIER_KEYS.has(event.code)) {
				// Right Alt opens no browser menu while it is AltGr here.
				if (event.code === 'AltRight' || event.code === 'AltLeft') event.preventDefault();
				showLevel(event);
				return;
			}
			// Tab moves on; Ctrl and Cmd chords stay the browser's (copy, paste, undo).
			if (event.code === 'Tab' && !event.ctrlKey && !event.altKey && !event.metaKey) return;
			if ((event.ctrlKey && !event.altKey) || event.metaKey) return;
			const result = state.typist.press(event.code, heldOf(event));
			if (!result.owned) {
				// Backspace forgets a waiting dead key before it erases anything.
				if (event.code === 'Backspace' && state.typist.pending() !== null) {
					event.preventDefault();
					state.typist.reset();
					sayStatus();
				}
				return;
			}
			event.preventDefault();
			if (result.text)
				area.setRangeText(result.text, area.selectionStart, area.selectionEnd, 'end');
			state.pressed = event.code;
			state.held = heldOf(event);
			drawBoard();
			sayStatus();
		});
		area.addEventListener('keyup', (event) => {
			if (event.code === 'AltRight') state.altRight = false;
			if (MODIFIER_KEYS.has(event.code)) showLevel(event);
		});
		area.addEventListener('blur', () => {
			state.altRight = false;
			state.held = { shift: false, altgr: false, caps: false };
			drawBoard();
		});
		select.addEventListener('change', () => {
			state.refused = null;
			sayRefused();
			choose(select.value);
		});
		$('lt-clear').addEventListener('click', () => {
			area.value = '';
			state.typist.reset();
			sayStatus();
			area.focus();
		});

		state.typist = window.LAYOUT_TRY_TYPING.create(byId.get(state.layout));
		applyStrings();
		document.addEventListener('i18n:applied', applyStrings);
		// Ready: the field takes keys once the typist is built (the site's smoke test waits for it).
		area.disabled = false;
		area.setAttribute('aria-busy', 'false');
		area.dataset.emulationState = 'ready';
		// An old anchor of the former page (#input-text) lands in the text area.
		if (location.hash === '#input-text') area.focus();
		return { choose };
	}

	if (document.readyState === 'loading')
		document.addEventListener('DOMContentLoaded', () =>
			mount(document.getElementById('layout-try'))
		);
	else mount(document.getElementById('layout-try'));

	return Object.freeze({ LAYOUT_MESSAGE, mount });
})();
