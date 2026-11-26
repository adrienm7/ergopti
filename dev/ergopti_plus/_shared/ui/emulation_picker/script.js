// _shared/ui/emulation_picker/script.js

/**
 * MODULE: Emulation Picker Page
 * DESCRIPTION:
 * « Layout to emulate › Others… »: every layout the emulation can type, with a
 * search field, chosen with the keyboard or the mouse (maintainer decision of
 * 2026-11-25). The host owns the catalogue and the write: the page sends the
 * id chosen and its session token, and the host applies it as the menu does,
 * then closes the window.
 *
 * FEATURES & RATIONALE:
 * 1. A combobox: the focus stays in the search field while the arrows move the
 *    active choice (aria-activedescendant), so typing and choosing never fight
 *    over the focus. The list takes the focus too (Tab), with the same keys.
 * 2. The search ignores case and accents and reads the name and the id, so
 *    « bepo » finds « BÉPO ».
 * 3. The choice in force starts active and says so in its row.
 */
(function () {
	'use strict';
	var post = makeHostBridge('emulation_picker_bridge');
	var state = null;
	var busy = false;
	var query = '';
	var active = 0;
	var el = function (id) {
		return document.getElementById(id);
	};

	/** The active locale's text of a key, the key itself until the strings land. */
	function t(key) {
		var value = (window._i18n_strings || {})[key];
		return typeof value === 'string' ? value : key;
	}

	/** Folds case and accents, so a search matches what it reads like. */
	function fold(text) {
		return String(text).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
	}

	/** The choices the search keeps, in the host's order. */
	function visible() {
		if (!state) return [];
		var needle = fold(query.trim());
		return state.choices.filter(function (choice) {
			return (
				needle === '' || fold(choice.label).includes(needle) || fold(choice.id).includes(needle)
			);
		});
	}

	/** Draws the list, the active choice and the status, without parsing names as HTML. */
	function render() {
		var shown = visible();
		if (active >= shown.length) active = shown.length - 1;
		if (active < 0) active = 0;
		var list = el('choices');
		list.textContent = '';
		shown.forEach(function (choice, index) {
			var row = document.createElement('li');
			row.id = 'choice-' + index;
			row.setAttribute('role', 'option');
			row.setAttribute('aria-selected', index === active ? 'true' : 'false');
			row.className = index === active ? 'active' : '';
			row.dataset.id = choice.id;
			var name = document.createElement('span');
			name.className = 'name';
			name.dir = 'auto';
			name.textContent = choice.label;
			row.appendChild(name);
			if (choice.current) {
				var mark = document.createElement('span');
				mark.className = 'current';
				mark.textContent = t('emulation_picker.current');
				row.appendChild(mark);
			}
			list.appendChild(row);
		});
		// The field and the list both name the active choice: each can hold the focus.
		[el('search'), list].forEach(function (owner) {
			if (shown.length) owner.setAttribute('aria-activedescendant', 'choice-' + active);
			else owner.removeAttribute('aria-activedescendant');
		});
		el('btn-choose').disabled = busy || !shown.length;
		var status = '';
		if (state && !shown.length) status = t('emulation_picker.no_match');
		if (state && state.refused) status = t('menu.layout.emulation_not_saved');
		el('status').textContent = status;
		var row = el('choice-' + active);
		if (row && typeof row.scrollIntoView === 'function') row.scrollIntoView({ block: 'nearest' });
	}

	/** Sends the active choice; the host applies it and closes the window. */
	function choose() {
		var shown = visible();
		if (busy || !state || !shown.length) return;
		busy = true;
		render();
		post({ action: 'choose', session: state.session, id: shown[active].id });
	}

	/** Closes without changing the emulated layout. */
	function cancel() {
		post({ action: 'cancel', session: state ? state.session : '' });
	}

	/**
	 * Accepts the host's catalogue, or its refusal of a choice, for this page's session.
	 * @param {object} message - { session, choices: [{ id, label, current }], refused? }
	 */
	window.receiveEmulationPicker = function (message) {
		if (!message || typeof message.session !== 'string' || !Array.isArray(message.choices)) return;
		if (state && message.session !== state.session) return;
		var first = state === null;
		state = message;
		busy = false;
		if (first) {
			var current = state.choices.findIndex(function (choice) {
				return choice.current === true;
			});
			active = current < 0 ? 0 : current;
		}
		render();
		el('search').focus();
	};
	window.__hostBridgeResponse = function (bridge, base64, payload) {
		if (bridge === 'emulation_picker_bridge')
			window.receiveEmulationPicker(decodeHostBridgeResponse(base64, payload));
	};

	el('search').addEventListener('input', function () {
		query = el('search').value;
		active = 0;
		render();
	});
	/**
	 * Moves the active choice with the arrows and chooses it with Enter, from the
	 * search field and from the list alike.
	 * @param {KeyboardEvent} event
	 */
	function navigate(event) {
		if (event.isComposing || event.keyCode === 229) return;
		var count = visible().length;
		if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
			event.preventDefault();
			if (!count) return;
			active = (active + (event.key === 'ArrowDown' ? 1 : count - 1)) % count;
			render();
		} else if (
			event.key === 'PageDown' ||
			event.key === 'PageUp' ||
			event.key === 'Home' ||
			event.key === 'End'
		) {
			// Home and End stay the caret's in the search field.
			if (event.currentTarget === el('search') && (event.key === 'Home' || event.key === 'End'))
				return;
			event.preventDefault();
			active = event.key === 'PageDown' || event.key === 'End' ? count - 1 : 0;
			render();
		} else if (
			event.key === 'Enter' ||
			(event.key === ' ' && event.currentTarget === el('choices'))
		) {
			event.preventDefault();
			choose();
		}
	}
	el('search').addEventListener('keydown', navigate);
	el('choices').addEventListener('keydown', navigate);
	// Escape first clears the search, then closes, as Cancel does: the page holds
	// the keyboard, so no host window sees the key. A composition keeps its own.
	document.addEventListener('keydown', function (event) {
		if (event.key !== 'Escape' || event.isComposing || event.keyCode === 229) return;
		event.preventDefault();
		if (query !== '') {
			query = '';
			el('search').value = '';
			active = 0;
			render();
			return;
		}
		cancel();
	});
	// One listener delegated from the list's region: a click chooses the row, as
	// Enter chooses the active one from the search field or the list.
	document.querySelector('main').addEventListener('click', function (event) {
		var row = event.target.closest('li[role="option"]');
		if (!row) return;
		active = Number(row.id.replace('choice-', ''));
		choose();
	});
	el('btn-choose').addEventListener('click', choose);
	el('btn-cancel').addEventListener('click', cancel);
	document.addEventListener('i18n:applied', render);
	render();
	post('ready');
})();
