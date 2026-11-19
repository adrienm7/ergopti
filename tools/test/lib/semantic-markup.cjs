// tools/test/lib/semantic-markup.cjs

/**
 * ==============================================================================
 * MODULE: Semantic Markup Judgement
 * DESCRIPTION:
 * The shared div and span gate of the project's markup (maintainer request of
 * 2026-11-19: « no non-semantic tag, no span or div if possible », and
 * blocking tests). A div or a span is allowed only where no element has the
 * meaning, and each one is justified in a reviewed list per scope (the site,
 * the app windows, the Studio pages), with its exact count, a kind from a
 * closed list and a reason. None may be interactive.
 *
 * Reader-agnostic: a scope's reader (tools/test/lib/svelte-markup.cjs for the
 * site's Svelte files, an HTML reader for the static pages) turns each
 * element into a descriptor, and this module judges the descriptors and the
 * list. tools/test/test-site-semantic-html.cjs is the site scope.
 * ==============================================================================
 */

'use strict';

const GENERIC = Object.freeze(['div', 'span']);
// Why a generic element may stay: no HTML element means any of these.
const KINDS = Object.freeze({
	layout: 'a flex, grid or positioning box with no meaning of its own',
	'styling-hook': 'styles a part of a run of text that no phrasing element means',
	'icon-layer': 'a layer of an icon-font glyph',
	decorative: 'an aria-hidden or empty decoration',
	mount: 'an empty element that a script or a library fills',
	'aria-widget': 'carries an ARIA role that no HTML element has (tablist, tabpanel, tooltip)',
	'dl-group': 'groups a dt and its dd inside a dl, the one wrapper HTML allows there',
	language: 'marks a passage in another language (lang) with no other meaning'
});
// Roles a user operates: the native element must carry them, never a div or span.
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
const MIN_REASON_LENGTH = 20;
// Events a container may listen to for the controls inside it: a key that
// bubbles from them (Escape closing a popup), a focus moving between them,
// a scroll, a finished transition. None makes the container itself something
// a user operates; any other handler (click, pointer, hover) does.
const CONTAINER_EVENTS = Object.freeze([
	'keydown',
	'keyup',
	'focusin',
	'focusout',
	'scroll',
	'transitionend',
	'animationend'
]);

/**
 * One element as a scope's reader describes it.
 * @typedef {object} Descriptor
 * @property {string} tag - Lower-case tag name.
 * @property {string[]} classes - Its static class tokens.
 * @property {string|null} id - Its static id.
 * @property {string|null|undefined} role - Its static role, null when absent, undefined when computed.
 * @property {string|null|undefined} tabindex - Its static tabindex, null when absent, undefined when computed.
 * @property {string[]} handlers - The events it listens to in the markup (click, keydown…).
 * @property {number} line - Its line in the file.
 */

/** The list key of one element: tag plus its first static class, its id, or (none). */
function elementKey(descriptor) {
	if (descriptor.classes.length) return descriptor.tag + '.' + descriptor.classes[0];
	if (descriptor.id) return descriptor.tag + '#' + descriptor.id;
	return descriptor.tag + ' (none)';
}

/**
 * The generic elements of one file: counts per key and the interactive ones.
 * @param {Descriptor[]} descriptors
 * @param {string} file
 * @returns {{counts: Map<string, number>, interactive: string[]}}
 */
function inventoryOf(descriptors, file) {
	const counts = new Map();
	const interactive = [];
	for (const element of descriptors) {
		if (!GENERIC.includes(element.tag)) continue;
		const key = elementKey(element);
		counts.set(key, (counts.get(key) || 0) + 1);
		const where = `${file}:${element.line} <${key}>`;
		const operated = element.handlers.filter((event) => !CONTAINER_EVENTS.includes(event));
		if (operated.length)
			interactive.push(`${where} has a ${operated.join(', ')} handler: use a button or a link`);
		if (element.role === undefined)
			interactive.push(`${where} has a computed role: write it statically`);
		else if (
			element.role !== null &&
			element.role.split(/\s+/).some((token) => INTERACTIVE_ROLES.includes(token))
		)
			interactive.push(`${where} has role="${element.role}": use the native element`);
		if (element.tabindex !== null && element.tabindex !== '-1')
			interactive.push(
				`${where} is focusable (tabindex=${element.tabindex ?? '{…}'}): use a native control`
			);
	}
	return { counts, interactive };
}

/** The problems of a justified list itself: shape, kinds, reasons, duplicates. */
function allowlistProblems(allowlist) {
	const problems = [];
	const seen = new Set();
	if (!Array.isArray(allowlist.elements)) return ['allowlist.elements must be an array'];
	if (!Array.isArray(allowlist.svelteIgnores)) return ['allowlist.svelteIgnores must be an array'];
	for (const entry of allowlist.elements) {
		const label = `${entry.file} <${entry.element}>`;
		const keys = Object.keys(entry).sort().join(',');
		if (keys !== 'count,element,file,kind,reason')
			problems.push(`${label}: expected exactly file, element, count, kind, reason`);
		if (!Number.isInteger(entry.count) || entry.count < 1)
			problems.push(`${label}: count must be a positive integer`);
		if (!Object.hasOwn(KINDS, entry.kind)) problems.push(`${label}: unknown kind ${entry.kind}`);
		if (typeof entry.reason !== 'string' || entry.reason.trim().length < MIN_REASON_LENGTH)
			problems.push(`${label}: the reason must say why no element fits`);
		if (!/^(div|span)(\.[\w-]+|#[\w-]+| \(none\))$/.test(entry.element ?? ''))
			problems.push(`${label}: element must be div or span with .class, #id or (none)`);
		const key = entry.file + '\0' + entry.element;
		if (seen.has(key)) problems.push(`${label}: listed twice`);
		seen.add(key);
	}
	for (const entry of allowlist.svelteIgnores) {
		if (typeof entry.reason !== 'string' || entry.reason.trim().length < MIN_REASON_LENGTH)
			problems.push(`${entry.file} svelte-ignore ${entry.codes}: the reason must say why`);
		if (!Array.isArray(entry.codes) || entry.codes.length === 0)
			problems.push(`${entry.file} svelte-ignore: codes must be listed`);
	}
	return problems;
}

/**
 * Compare the measured elements with the justified list.
 * @param {Map<string, Map<string, number>>} measured - Per file, the counts per element key.
 * @param {object} allowlist
 * @returns {string[]} Problems, empty when the markup matches the reviewed list exactly.
 */
function compareWithAllowlist(measured, allowlist) {
	const problems = [];
	const listed = new Map();
	for (const entry of allowlist.elements)
		listed.set(entry.file + '\0' + entry.element, entry.count);
	for (const [file, counts] of measured)
		for (const [key, count] of counts) {
			const allowed = listed.get(file + '\0' + key);
			if (allowed === undefined)
				problems.push(
					`${file} <${key}> ×${count} is not justified: use the element that has the meaning, or add a reviewed entry`
				);
			else if (count > allowed)
				problems.push(`${file} <${key}> ×${count}, more than the ${allowed} justified`);
			else if (count < allowed)
				problems.push(
					`${file} <${key}> ×${count}, fewer than the ${allowed} listed: lower the entry`
				);
		}
	for (const entry of allowlist.elements) {
		const counts = measured.get(entry.file);
		if (!counts || !counts.has(entry.element))
			problems.push(`${entry.file} <${entry.element}> is listed but gone: remove the entry`);
	}
	return problems;
}

/**
 * The accessibility svelte-ignore comments of a file that the list does not justify.
 * @param {string} file
 * @param {Array<{codes: string[], line: number}>} ignores
 * @param {object} allowlist
 */
function ignoreProblems(file, ignores, allowlist) {
	const listed = allowlist.svelteIgnores.filter((entry) => entry.file === file);
	const problems = [];
	for (const ignore of ignores) {
		const a11y = ignore.codes.filter((code) => code.startsWith('a11y'));
		if (!a11y.length) continue;
		const match = listed.find(
			(entry) =>
				entry.codes.length === a11y.length && a11y.every((code) => entry.codes.includes(code))
		);
		if (!match)
			problems.push(`${file}:${ignore.line} svelte-ignore ${a11y.join(', ')} is not justified`);
	}
	for (const entry of listed)
		if (!ignores.some((ignore) => entry.codes.every((code) => ignore.codes.includes(code))))
			problems.push(`${file} svelte-ignore ${entry.codes.join(', ')} is listed but gone`);
	return problems;
}

module.exports = {
	GENERIC,
	CONTAINER_EVENTS,
	KINDS,
	INTERACTIVE_ROLES,
	elementKey,
	inventoryOf,
	allowlistProblems,
	compareWithAllowlist,
	ignoreProblems
};
