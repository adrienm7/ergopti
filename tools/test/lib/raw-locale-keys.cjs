// tools/test/lib/raw-locale-keys.cjs

/**
 * ==============================================================================
 * MODULE: Raw Locale Keys On Screen
 * DESCRIPTION:
 * Finds the unresolved locale keys a rendered page shows: every visible text
 * and every accessible name (aria-label, title, placeholder, alt, an option's
 * text, the document title) is searched for a token shaped like a catalogue
 * key (`layer_editor.key.shift`). The browser gates run it after drawing a
 * page, so a key the page's strings lack fails the run instead of reaching a
 * user as a dotted identifier.
 *
 * FEATURES & RATIONALE:
 * 1. The shape comes from the catalogue itself: a token is a raw key when
 *    en.json has it, or when its first segment is one of the catalogue's
 *    namespaces and it is not a file name or a host name (« layers.toml »,
 *    « ergopti.fr »). A key missing from every catalogue is found too.
 * 2. The walk reads the DOM, not one page's markup: any page, any host.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const { shared } = require('../../lib/paths.cjs');

// The last segments that make a dotted token a file or a host, not a key.
const NOT_KEY_ENDINGS = Object.freeze([
	'ahk',
	'com',
	'csv',
	'dll',
	'dof',
	'exe',
	'fr',
	'html',
	'ini',
	'js',
	'json',
	'keylayout',
	'kla',
	'klc',
	'lua',
	'md',
	'org',
	'pdf',
	'png',
	'svg',
	'toml',
	'tsv',
	'txt',
	'xml',
	'zip'
]);

/**
 * The catalogue's key shape, to pass to the page.
 * @returns {{keys: string[], namespaces: string[], endings: string[]}}
 */
function catalogueShape() {
	const keys = Object.keys(
		JSON.parse(fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8'))
	);
	return {
		keys,
		namespaces: [...new Set(keys.map((key) => key.split('.')[0]))],
		endings: [...NOT_KEY_ENDINGS]
	};
}

/**
 * Runs in the page: the raw keys it shows, each with where it is shown.
 * @param {{keys: string[], namespaces: string[], endings: string[]}} shape
 * @returns {string[]} « <where>: <text> » for each text holding a raw key.
 */
function pageRawKeys(shape) {
	const keys = new Set(shape.keys);
	const namespaces = new Set(shape.namespaces);
	const endings = new Set(shape.endings);
	// Dotted identifiers whose segments start lower case: a key segment may be
	// camelCase (option.moveDigits.label), a W3C key code (keys.KeyA,
	// remap.CapsLock, a source path the export report names) never is; a file
	// path's last part (…\config.toml.bak) is not one either.
	const token =
		/(?<![A-Za-z0-9_.\\/])[a-z][a-z0-9_]*(?:\.[a-z0-9_][A-Za-z0-9_]*)+(?![A-Za-z0-9_\\/])/g;
	const isRaw = (word) => {
		if (keys.has(word)) return true;
		const parts = word.split('.');
		return namespaces.has(parts[0]) && !endings.has(parts[parts.length - 1].toLowerCase());
	};
	const found = [];
	const look = (where, text) => {
		if (typeof text !== 'string' || text === '') return;
		const raw = (text.match(token) || []).filter(isRaw);
		if (raw.length) found.push(`${where}: ${raw.join(', ')} in « ${text.trim().slice(0, 120)} »`);
	};
	const shown = (element) =>
		element.getClientRects().length > 0 && getComputedStyle(element).visibility !== 'hidden';
	const name = (element) => element.tagName.toLowerCase() + (element.id ? '#' + element.id : '');
	look('title', document.title);
	const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
	for (let node = walker.nextNode(); node; node = walker.nextNode()) {
		const parent = node.parentElement;
		if (!parent || /^(SCRIPT|STYLE|TEMPLATE)$/.test(parent.tagName)) continue;
		// An option is announced while its closed select shows another one.
		if (parent.closest('option') || shown(parent)) look(name(parent), node.nodeValue);
	}
	for (const element of document.body.querySelectorAll('*'))
		for (const attribute of ['aria-label', 'aria-description', 'title', 'placeholder', 'alt'])
			look(`${name(element)}[${attribute}]`, element.getAttribute(attribute));
	return found;
}

module.exports = { catalogueShape, pageRawKeys };
