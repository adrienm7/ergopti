// tools/test/lib/keyboard-operability.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Operability Analysis
 * DESCRIPTION:
 * Everything a mouse can use, the keyboard can use too (WCAG 2.1.1, 2.1.2,
 * 4.1.2; maintainer request of 2026-11-19: « everything must be navigable by
 * keyboard, on the site and in the WebView UI »). This module holds the page
 * functions that record and describe a page's interactive elements and the
 * pure judgement of what they report, so tools/test/test-keyboard-operability.cjs
 * proves without a browser that each failure is caught, and the browser gates
 * (tools/test/browser/keyboard-operability.playwright.cjs for the site and
 * the Studio frames, app-windows-accessibility.playwright.cjs for the app's
 * WebView windows) feed it real pages.
 *
 * WHAT A PAGE REPORTS (collectOperability), for every shown element that has
 * a pointer handler (click, mousedown, pointerdown…: addEventListener, an
 * on… property or a Svelte delegated handler) or an interactive ARIA role:
 * whether it is a native control, reachable with Tab, handled by a key
 * listener on itself or an ancestor, a delegating container of focusable
 * controls, an item of a roving-tabindex widget, hidden from assistive
 * technology.
 *
 * A pointer shortcut whose action a control elsewhere offers (the keys of a
 * keyboard drawing switch its layer on a click, which its layer select does
 * too) is declared by data-keyboard-equivalent="selector" on the element or
 * an ancestor; it passes only while that control exists, is shown and takes
 * the focus (WCAG 2.1.1 asks for the function, not for every element).
 *
 * WHAT IS REFUSED (operabilityProblems): a custom element a mouse can use
 * that Tab cannot reach, that has no interactive role, or that no key
 * listener answers; a native control taken out of the Tab order while it is
 * still clickable; a control a screen reader cannot see but Tab reaches.
 * The widget checks (widgetProblems) refuse a disclosure that Enter does not
 * open, a popup that Escape does not close or that keeps the focus away from
 * its opener, and a tab list, menu, list box, grid, radio group or tree whose
 * arrow keys do not move the focus.
 * ==============================================================================
 */

'use strict';

const POINTER_EVENTS = Object.freeze([
	'click',
	'dblclick',
	'mousedown',
	'mouseup',
	'pointerdown',
	'pointerup',
	'touchstart',
	'touchend',
	'contextmenu',
	'auxclick'
]);
const KEY_EVENTS = Object.freeze(['keydown', 'keyup', 'keypress']);
const INTERACTIVE_ROLES = Object.freeze([
	'button',
	'link',
	'checkbox',
	'radio',
	'switch',
	'tab',
	'menuitem',
	'menuitemcheckbox',
	'menuitemradio',
	'option',
	'slider',
	'spinbutton',
	'textbox',
	'searchbox',
	'combobox',
	'treeitem',
	'gridcell',
	'scrollbar'
]);

/**
 * Init script: records which element got which pointer or key listener.
 * Runs before any page script, in every frame (addInitScript).
 * @param {{pointer: string[], keys: string[]}} events
 */
function instrumentListeners(events) {
	if (window.__ergoptiListeners) return;
	const watched = new Set([...events.pointer, ...events.keys]);
	const record = new WeakMap();
	const roots = new Set();
	window.__ergoptiListeners = { record, roots };
	const original = EventTarget.prototype.addEventListener;
	EventTarget.prototype.addEventListener = function (type, listener, options) {
		if (watched.has(type)) {
			if (typeof Element !== 'undefined' && this instanceof Element) {
				const types = record.get(this) || new Set();
				types.add(type);
				record.set(this, types);
			} else if (this === window || this === document) roots.add(type);
		}
		return original.call(this, type, listener, options);
	};
}

/**
 * Page function: describe every shown element a pointer or an ARIA role makes
 * interactive. Runs in the page (or a frame) after instrumentListeners.
 * @param {{pointer: string[], keys: string[], roles: string[]}} lists
 * @returns {Array<object>} One row per element (see operabilityProblems).
 */
function collectOperability(lists) {
	const recorded = window.__ergoptiListeners || { record: new WeakMap(), roots: new Set() };
	const interactiveRoles = new Set(lists.roles);
	const rovingRoles = new Set([
		'tab',
		'option',
		'menuitem',
		'menuitemcheckbox',
		'menuitemradio',
		'gridcell',
		'treeitem',
		'radio'
	]);
	const NATIVE =
		'a[href], area[href], button, input:not([type="hidden"]), select, textarea, summary, label, option, dialog, iframe, video[controls], audio[controls], [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"]';
	const FOCUSABLE =
		'a[href], area[href], button:not([disabled]), input:not([type="hidden"]):not([disabled]), select:not([disabled]), textarea:not([disabled]), summary, iframe, [tabindex]:not([tabindex="-1"]), [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"]';
	const typesOf = (element) => {
		const types = new Set(recorded.record.get(element) || []);
		for (const type of [...lists.pointer, ...lists.keys]) {
			if (typeof element['on' + type] === 'function') types.add(type);
			// Svelte 5 delegates events to the root and keeps the handler on the element.
			if (element['__' + type] !== undefined) types.add(type);
		}
		return types;
	};
	const shown = (element) => {
		if (element.closest('[inert]')) return false;
		if (!element.getClientRects().length) return false;
		const style = getComputedStyle(element);
		return style.visibility !== 'hidden' && style.display !== 'none';
	};
	const describe = (element) => {
		const name = (
			element.getAttribute('aria-label') ||
			element.getAttribute('title') ||
			element.textContent ||
			''
		)
			.replace(/\s+/g, ' ')
			.trim()
			.slice(0, 40);
		const classes = [...element.classList]
			.slice(0, 2)
			.map((c) => '.' + c)
			.join('');
		return `${element.tagName.toLowerCase()}${element.id ? '#' + element.id : ''}${classes} «${name}»`;
	};
	const rows = [];
	for (const element of document.body ? document.body.querySelectorAll('*') : []) {
		const types = typesOf(element);
		const pointer = lists.pointer.some((type) => types.has(type));
		const role = (element.getAttribute('role') || '').trim().split(/\s+/)[0];
		const roleInteractive = interactiveRoles.has(role);
		if (!pointer && !roleInteractive) continue;
		if (!shown(element)) continue;
		const native = element.matches(NATIVE);
		const disabled =
			element.matches(':disabled') || element.getAttribute('aria-disabled') === 'true';
		const focusable = element.matches(FOCUSABLE) && element.tabIndex >= 0;
		let keyHandled = recorded.roots.size > 0 && lists.keys.some((type) => recorded.roots.has(type));
		for (let node = element; node && !keyHandled; node = node.parentElement) {
			const own = typesOf(node);
			if (lists.keys.some((type) => own.has(type))) keyHandled = true;
		}
		// A container whose click listener serves the controls inside it.
		const delegating = !native && Boolean(element.querySelector(FOCUSABLE));
		// An item of a widget that keeps one item in the Tab order and moves
		// the focus with the arrow keys, or a widget pointing at its active item.
		let roving = false;
		if (rovingRoles.has(role)) {
			const widget =
				element.parentElement &&
				element.parentElement.closest(
					'[role="tablist"], [role="listbox"], [role="menu"], [role="menubar"], [role="grid"], [role="treegrid"], [role="tree"], [role="radiogroup"], [role="toolbar"]'
				);
			if (widget)
				roving =
					(widget.hasAttribute('aria-activedescendant') && widget.tabIndex >= 0) ||
					[...widget.querySelectorAll('[role="' + role + '"]')].some(
						(item) => item.tabIndex >= 0 && shown(item)
					);
		}
		// A control elsewhere that offers the same action (see the header).
		const holder = element.closest('[data-keyboard-equivalent]');
		let equivalent = false;
		if (holder) {
			const control = document.querySelector(holder.getAttribute('data-keyboard-equivalent'));
			equivalent = Boolean(control && control.matches(FOCUSABLE) && shown(control));
		}
		// A label hands its activation to its control.
		const labelOf =
			element.tagName === 'LABEL' && element.control
				? element.control.matches(FOCUSABLE) || element.control.tabIndex >= 0
				: null;
		rows.push({
			id: describe(element),
			tag: element.tagName.toLowerCase(),
			role,
			pointer,
			native,
			disabled,
			focusable,
			roving,
			keyHandled,
			delegating,
			labelControlFocusable: labelOf,
			equivalent,
			hiddenFromAT: Boolean(element.closest('[aria-hidden="true"]'))
		});
	}
	return rows;
}

/**
 * The problems of the rows a page reported.
 * @param {Array<object>} rows - From collectOperability.
 * @returns {string[]} Empty when everything the mouse can use, the keyboard can use.
 */
function operabilityProblems(rows) {
	const problems = [];
	for (const row of rows) {
		if (row.disabled) continue;
		if (row.hiddenFromAT && row.focusable)
			problems.push(`${row.id} takes the focus inside aria-hidden: a screen reader cannot name it`);
		if (row.delegating) continue;
		// A table cell of a drawing keeps its role: only an interactive one asks for keys.
		if (row.equivalent && !row.focusable && !INTERACTIVE_ROLES.includes(row.role)) continue;
		const reachable = row.focusable || row.roving;
		if (row.native) {
			if (row.tag === 'label') {
				if (row.labelControlFocusable === false)
					problems.push(`${row.id} is a label whose control Tab cannot reach`);
				continue;
			}
			if (row.tag === 'option' || row.tag === 'dialog' || row.tag === 'iframe') continue;
			if (!reachable)
				problems.push(`${row.id} can be clicked but Tab cannot reach it (tabindex="-1")`);
			continue;
		}
		if (!reachable) problems.push(`${row.id} answers the mouse only: Tab cannot reach it`);
		if (!INTERACTIVE_ROLES.includes(row.role))
			problems.push(`${row.id} has no interactive role: use a button or a link`);
		else if (!row.keyHandled)
			problems.push(
				`${row.id} (role="${row.role}") has no key listener: Enter and Space do nothing`
			);
	}
	return problems;
}

/**
 * Page function: the widgets whose keyboard behaviour widgetProblems judges,
 * each with a selector the driver can find it again by.
 * @returns {{disclosures: object[], composites: object[]}}
 */
function collectWidgets() {
	const shown = (element) =>
		element.getClientRects().length > 0 &&
		getComputedStyle(element).visibility !== 'hidden' &&
		!element.closest('[inert]') &&
		element.tabIndex >= 0 &&
		!element.matches(':disabled');
	const mark = (element, kind, index) => {
		element.setAttribute('data-operability-probe', kind + index);
		return '[data-operability-probe="' + kind + index + '"]';
	};
	const disclosures = [];
	const triggers = document.querySelectorAll(
		'[aria-expanded][aria-controls], [aria-haspopup]:not([aria-haspopup="false"])'
	);
	[...triggers].filter(shown).forEach((element, index) =>
		disclosures.push({
			selector: mark(element, 'd', index),
			popup: element.hasAttribute('aria-haspopup'),
			checkbox: element.matches('input[type="checkbox"]')
		})
	);
	const composites = [];
	const ITEM = {
		tablist: 'tab',
		menu: 'menuitem',
		menubar: 'menuitem',
		listbox: 'option',
		radiogroup: 'radio',
		tree: 'treeitem',
		grid: 'gridcell'
	};
	for (const widget of document.querySelectorAll(
		Object.keys(ITEM)
			.map((r) => `[role="${r}"]`)
			.join(', ')
	)) {
		const role = widget.getAttribute('role');
		const items = [...widget.querySelectorAll(`[role="${ITEM[role]}"]`)].filter(
			(item) => item.getClientRects().length > 0 && !item.matches(':disabled')
		);
		if (items.length < 2) continue;
		const start = items.find((item) => item.tabIndex >= 0) || null;
		const active = widget.getAttribute('aria-activedescendant');
		if (!start && !(active && widget.tabIndex >= 0)) continue;
		composites.push({
			role,
			selector: mark(widget, 'c', composites.length),
			start: start ? mark(start, 's', composites.length) : null,
			vertical:
				['menu', 'listbox', 'tree', 'radiogroup'].includes(role) ||
				widget.getAttribute('aria-orientation') === 'vertical'
		});
	}
	return { disclosures, composites };
}

/**
 * The problems of the widget walk the driver recorded.
 * @param {Array<{id: string, kind: string, opened?: boolean, closed?: boolean, focusBack?: boolean, moved?: boolean}>} results
 * @returns {string[]}
 */
function widgetProblems(results) {
	const problems = [];
	for (const result of results) {
		if (result.kind === 'disclosure') {
			if (!result.opened) problems.push(`${result.id}: Enter does not open what it controls`);
			else if (result.popup && !result.closed)
				problems.push(`${result.id}: Escape does not close its popup`);
			else if (result.popup && !result.focusBack)
				problems.push(`${result.id}: Escape leaves the focus away from the opener`);
			else if (!result.popup && !result.closed)
				problems.push(`${result.id}: Enter a second time does not close it`);
		} else if (result.kind === 'composite' && !result.moved)
			problems.push(`${result.id}: the arrow keys do not move the focus between its items`);
	}
	return problems;
}

module.exports = {
	POINTER_EVENTS,
	KEY_EVENTS,
	INTERACTIVE_ROLES,
	instrumentListeners,
	collectOperability,
	operabilityProblems,
	collectWidgets,
	widgetProblems
};
