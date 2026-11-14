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
	// Digits of the shares an explanation quotes.
	const SHARE_DIGITS = 1;

	let popover = null;
	let owner = null;

	/** Translates a locale key; an unknown key shows itself so the gap is visible. */
	function t(key, values) {
		const strings = window._i18n_strings || {};
		let text = typeof strings[key] === 'string' ? strings[key] : key;
		for (const [name, value] of Object.entries(values || {}))
			text = text.split(`{${name}}`).join(String(value));
		return text;
	}

	function el(tag, className, text) {
		const node = document.createElement(tag);
		if (className) node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	}

	const format = (value, digits) =>
		Number(value).toLocaleString(window._i18n_locale || undefined, {
			minimumFractionDigits: digits,
			maximumFractionDigits: digits
		});

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
		if (!window.LAYOUT_ANALYSIS_DATA.sources.items[item])
			throw new Error(`layout_analysis: no sources for ${item}`);
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

	function build() {
		popover = el('div', 'la-popover');
		popover.id = POPOVER_ID;
		popover.setAttribute('role', 'dialog');
		popover.hidden = true;
		const close = el('button', 'la-popover-close');
		close.type = 'button';
		close.addEventListener('click', hide);
		popover.append(el('p', 'la-popover-text'), el('p', 'la-popover-title'), el('ul'), close);
		document.body.append(popover);
	}

	function show(trigger) {
		const item = trigger.dataset.info;
		const data = window.LAYOUT_ANALYSIS_DATA.sources;
		const refs = data.items[item];
		if (!refs) throw new Error(`layout_analysis: no sources for ${item}`);
		hide();
		popover.querySelector('.la-popover-text').textContent = t(
			`layout_analysis.info.${item}`,
			values(item)
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
				const trigger = event.target.closest('.la-info');
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

	return { t, button, routeLink };
})();
