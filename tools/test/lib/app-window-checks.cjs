// tools/test/lib/keyboard-operability.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Operability and Text Alternatives
 * DESCRIPTION:
 * What a Tab walk cannot see (WCAG 2.1.1 keyboard, 1.4.13 content on hover or
 * focus, 1.1.1 non-text content): an element a mouse can use and the
 * keyboard cannot reach, a control with a role and no focus, a composite
 * widget (tabs, list box, menu, grid, tree, radio group) whose arrow keys do
 * nothing, an open modal dialog that Escape does not close, and an image,
 * drawing or chart canvas without a text alternative.
 *
 * recordListeners runs in the page before its scripts (addInitScript) and
 * notes the pointer and hover listeners each element gets; the other
 * functions run in the page (page.evaluate) or drive it, so they use nothing
 * from this module's scope. app-windows-accessibility.playwright.cjs counts
 * their findings in its ratchet and proves each one on a small page first.
 * ==============================================================================
 */

'use strict';

/**
 * Notes, per element, the pointer and hover listeners it gets (also through
 * the on... properties), in window.__pointerListeners (a WeakMap of sets).
 */
function recordListeners() {
	const WATCHED = [
		'click',
		'dblclick',
		'mousedown',
		'mouseup',
		'pointerdown',
		'pointerup',
		'contextmenu',
		'mouseenter',
		'mouseover',
		'mousemove',
		'focus',
		'focusin'
	];
	const listeners = new WeakMap();
	window.__pointerListeners = listeners;
	const note = (target, type) => {
		if (!(target instanceof Element) || !WATCHED.includes(type)) return;
		if (!listeners.has(target)) listeners.set(target, new Set());
		listeners.get(target).add(type);
	};
	const add = EventTarget.prototype.addEventListener;
	EventTarget.prototype.addEventListener = function (type, listener, options) {
		note(this, type);
		return add.call(this, type, listener, options);
	};
	for (const type of WATCHED) {
		const descriptor = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'on' + type);
		if (!descriptor || !descriptor.set) continue;
		Object.defineProperty(HTMLElement.prototype, 'on' + type, {
			...descriptor,
			set(value) {
				if (value) note(this, type);
				return descriptor.set.call(this, value);
			}
		});
	}
}

/**
 * The elements a mouse can use that the keyboard cannot, and controls with
 * a role but no focus. Runs in the page.
 * @returns {string[]}
 */
function operabilityProblems() {
	const listeners = window.__pointerListeners || new WeakMap();
	const exposed = (node) =>
		!node.closest('[hidden], [aria-hidden="true"], [inert]') &&
		node.checkVisibility({ visibilityProperty: true });
	const describe = (node) =>
		node.tagName.toLowerCase() +
		(node.id ? '#' + node.id : '') +
		(node.classList.length ? '.' + node.classList[0] : '') +
		' «' +
		(node.getAttribute('aria-label') || node.textContent || '')
			.replace(/\s+/g, ' ')
			.trim()
			.slice(0, 30) +
		'»';
	const NATIVE =
		'a[href], button, input, select, textarea, summary, label, option, [contenteditable="true"], [contenteditable=""]';
	const FOCUSABLE = NATIVE + ', [tabindex]:not([tabindex="-1"]), audio[controls], video[controls]';
	const focusable = (node) => node.matches(NATIVE) || node.tabIndex >= 0;
	const holdsFocusable = (node) =>
		Array.from(node.querySelectorAll(FOCUSABLE)).some((child) => !child.disabled && exposed(child));
	const CONTROL_ROLES = [
		'button',
		'checkbox',
		'combobox',
		'gridcell',
		'link',
		'menuitem',
		'menuitemcheckbox',
		'menuitemradio',
		'option',
		'radio',
		'searchbox',
		'slider',
		'spinbutton',
		'switch',
		'tab',
		'textbox',
		'treeitem'
	];
	const COMPOSITES =
		'[role="tablist"], [role="listbox"], [role="menu"], [role="menubar"], [role="radiogroup"], [role="grid"], [role="tree"], [role="toolbar"], [role="treegrid"]';
	const POINTER = [
		'click',
		'dblclick',
		'mousedown',
		'mouseup',
		'pointerdown',
		'pointerup',
		'contextmenu'
	];
	const HOVER = ['mouseenter', 'mouseover', 'mousemove'];
	const FOCUS = ['focus', 'focusin'];
	const problems = [];
	const modal = Array.from(document.querySelectorAll('dialog, [aria-modal="true"]')).find((node) =>
		node.matches('dialog') ? node.matches(':modal') : exposed(node)
	);
	const scope = modal || document.body;
	const named = (node) =>
		Boolean(
			(node.getAttribute('aria-label') || '').trim() ||
				(node.getAttribute('aria-labelledby') || '').trim()
		);
	for (const node of scope.querySelectorAll('*')) {
		if (!exposed(node)) continue;
		const types = listeners.get(node) || new Set();
		const pointer = POINTER.some((type) => types.has(type)) || node.hasAttribute('onclick');
		const hover = HOVER.some((type) => types.has(type));
		// A chart canvas reads its pointer itself: its text alternative is what
		// the keyboard and a reader get (the data shown beside it or its name).
		const chart = node.tagName === 'CANVAS' && node.getAttribute('role') === 'img' && named(node);
		if (pointer && !chart && !focusable(node) && !holdsFocusable(node) && node.tagName !== 'DIALOG')
			problems.push('mouse only (click): ' + describe(node));
		if (hover && !chart && !focusable(node) && !holdsFocusable(node)) {
			const followsFocus = (() => {
				for (let at = node; at && at !== document.body; at = at.parentElement) {
					const own = listeners.get(at);
					if (own && FOCUS.some((type) => own.has(type))) return true;
				}
				return false;
			})();
			if (!followsFocus) problems.push('mouse only (hover): ' + describe(node));
		}
		const role = (node.getAttribute('role') || '').trim().split(/\s+/)[0];
		if (
			CONTROL_ROLES.includes(role) &&
			!focusable(node) &&
			!node.matches(':disabled, [aria-disabled="true"]')
		) {
			const composite = node.closest(COMPOSITES);
			const roving =
				composite &&
				Array.from(composite.querySelectorAll('[role="' + role + '"]')).some(
					(item) => item.tabIndex >= 0 && exposed(item)
				);
			const owner =
				node.id &&
				document.querySelector('[aria-activedescendant]') &&
				Array.from(document.querySelectorAll('[aria-activedescendant]')).some(
					(each) =>
						focusable(each) &&
						(each.getAttribute('aria-controls') || each.id) &&
						(each.contains(node) ||
							(each.getAttribute('aria-controls') || '')
								.split(/\s+/)
								.some(
									(id) =>
										id && document.getElementById(id) && document.getElementById(id).contains(node)
								))
				);
			if (!roving && !owner) problems.push(`role ${role} without focus: ` + describe(node));
		}
	}
	return problems;
}

/**
 * The composite widgets of the page to try with the arrow keys: a selector
 * for the element to focus first, the key and the widget. Runs in the page;
 * it marks each widget and its start with data attributes.
 * @returns {{widget: string, start: string, key: string, role: string}[]}
 */
function compositeWidgets() {
	const exposed = (node) =>
		!node.closest('[hidden], [aria-hidden="true"], [inert]') &&
		node.checkVisibility({ visibilityProperty: true });
	const ITEMS = {
		tablist: 'tab',
		listbox: 'option',
		menu: 'menuitem, [role="menuitemcheckbox"], [role="menuitemradio"]',
		menubar: 'menuitem',
		radiogroup: 'radio',
		tree: 'treeitem',
		grid: 'gridcell',
		treegrid: 'gridcell'
	};
	const widgets = [];
	let index = 0;
	for (const widget of document.querySelectorAll(
		Object.keys(ITEMS)
			.map((role) => `[role="${role}"]`)
			.join(', ')
	)) {
		if (!exposed(widget)) continue;
		const role = widget.getAttribute('role');
		const selector = ITEMS[role]
			.split(', ')
			.map((part) => (part.startsWith('[') ? part : `[role="${part}"]`))
			.join(', ');
		const items = Array.from(widget.querySelectorAll(selector)).filter(exposed);
		if (items.length < 2) continue;
		// The start: the item the Tab key reaches, or the field that owns the
		// widget through aria-controls (a combobox and its list box).
		const owner = widget.id
			? Array.from(document.querySelectorAll('[aria-controls]')).find(
					(each) =>
						exposed(each) &&
						each.getAttribute('aria-controls').split(/\s+/).includes(widget.id) &&
						(each.matches('input, textarea, [role="combobox"]') ||
							each.hasAttribute('aria-activedescendant'))
				)
			: null;
		const start =
			owner ||
			(widget.hasAttribute('aria-activedescendant') && widget.tabIndex >= 0 ? widget : null) ||
			items.find((item) => item.tabIndex >= 0) ||
			items.find((item) => item.matches('button, a[href], input'));
		if (!start) continue;
		const mark = `op-${index++}`;
		widget.setAttribute('data-op-widget', mark);
		start.setAttribute('data-op-start', mark);
		const vertical =
			widget.getAttribute('aria-orientation') === 'vertical' ||
			(['listbox', 'menu', 'tree', 'radiogroup', 'grid', 'treegrid'].includes(role) &&
				widget.getAttribute('aria-orientation') !== 'horizontal');
		widgets.push({ widget: mark, key: vertical ? 'ArrowDown' : 'ArrowRight', role });
	}
	return widgets;
}

/**
 * Presses each widget's arrow key from its start and reports the widgets
 * where neither the focus nor the active descendant moved.
 * @param {import('playwright').Page} page
 * @returns {Promise<string[]>}
 */
async function arrowProblems(page) {
	const problems = [];
	const widgets = await page.evaluate(compositeWidgets);
	for (const { widget, key, role } of widgets) {
		const where = () =>
			page.evaluate((mark) => {
				const active = document.activeElement;
				const owner = document.querySelector(`[data-op-start="${mark}"]`);
				return [
					active ? active.outerHTML.slice(0, 120) : '',
					active ? active.getAttribute('aria-activedescendant') || '' : '',
					owner ? owner.getAttribute('aria-activedescendant') || '' : ''
				].join('|');
			}, widget);
		const started = await page.evaluate((mark) => {
			const start = document.querySelector(`[data-op-start="${mark}"]`);
			if (!start || !start.isConnected) return false;
			start.focus();
			return document.activeElement === start;
		}, widget);
		if (!started) continue;
		const before = await where();
		await page.keyboard.press(key);
		await page.evaluate(
			() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
		);
		const after = await where();
		if (before === after) problems.push(`${key} does not move inside the ${role} ${widget}`);
	}
	return problems;
}

/**
 * Presses Escape in an open modal dialog and reports it when the dialog is
 * still open afterwards.
 * @param {import('playwright').Page} page
 * @returns {Promise<string[]>}
 */
async function escapeProblems(page) {
	const openModal = () =>
		page.evaluate(() => {
			const exposed = (node) =>
				!node.closest('[hidden], [aria-hidden="true"], [inert]') &&
				node.checkVisibility({ visibilityProperty: true });
			const modal = Array.from(document.querySelectorAll('dialog, [aria-modal="true"]')).find(
				(node) => (node.matches('dialog') ? node.matches(':modal') : exposed(node))
			);
			return modal
				? modal.tagName.toLowerCase() +
						(modal.id ? '#' + modal.id : '') +
						(modal.className ? '.' + String(modal.className).split(' ')[0] : '')
				: null;
		});
	const before = await openModal();
	if (!before) return [];
	// The focus is inside the open dialog, as a user's is: the one shown, not
	// the first hidden dialog of the page (a window keeps all its dialogs in
	// its markup, and the walk before this leaves the focus on the body).
	await page.evaluate(() => {
		const exposed = (node) =>
			!node.closest('[hidden], [aria-hidden="true"], [inert]') &&
			node.checkVisibility({ visibilityProperty: true });
		const modal = Array.from(document.querySelectorAll('dialog, [aria-modal="true"]')).find(
			(node) => (node.matches('dialog') ? node.matches(':modal') : exposed(node))
		);
		if (modal && !modal.contains(document.activeElement)) {
			const first = modal.querySelector(
				'button, a[href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
			);
			(first || modal).focus();
		}
	});
	await page.keyboard.press('Escape');
	await page.evaluate(
		() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
	);
	const after = await openModal();
	return after === before ? [`Escape does not close the modal ${before}`] : [];
}

/**
 * Images, drawings and chart canvases without a text alternative. Runs in the page.
 * @returns {string[]}
 */
function imageProblems() {
	const exposed = (node) =>
		!node.closest('[hidden], [aria-hidden="true"], [inert]') &&
		node.checkVisibility({ visibilityProperty: true });
	const describe = (node) =>
		node.tagName.toLowerCase() +
		(node.id ? '#' + node.id : '') +
		(node.classList.length ? '.' + node.classList[0] : '');
	const named = (node) => {
		const ids = (node.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean);
		if (ids.some((id) => (document.getElementById(id) || {}).textContent)) return true;
		if ((node.getAttribute('aria-label') || '').trim()) return true;
		const title = node.querySelector(':scope > title');
		return Boolean(title && title.textContent.trim());
	};
	const problems = [];
	for (const node of document.querySelectorAll(
		'img, svg, canvas, input[type="image"], [role="img"]'
	)) {
		if (!exposed(node)) continue;
		// A drawing inside a named image is part of that image.
		if (node.parentElement && node.parentElement.closest('svg, [role="img"]')) continue;
		const tag = node.tagName.toLowerCase();
		if (tag === 'img' || tag === 'input') {
			if (!node.hasAttribute('alt')) problems.push(`${describe(node)} has no alt`);
			continue;
		}
		const role = node.getAttribute('role');
		if (role === 'presentation' || role === 'none') {
			problems.push(
				`${describe(node)}: role ${role} still reaches readers, use aria-hidden="true"`
			);
			continue;
		}
		if (!named(node)) problems.push(`${describe(node)} is neither aria-hidden nor a named image`);
		else if (tag !== 'canvas' && role !== 'img' && tag === 'svg')
			problems.push(`${describe(node)} is named but not role="img"`);
	}
	return problems;
}

module.exports = {
	recordListeners,
	operabilityProblems,
	compositeWidgets,
	arrowProblems,
	escapeProblems,
	imageProblems
};
