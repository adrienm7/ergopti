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
 * closed list and a reason. None may be interactive. A made-up element
 * (`bloc-main`, `keyboard`: a custom element name, or a name HTML does not
 * define) is as generic as a div for assistive technology, so the same
 * judgement holds it wherever the scope's reader sees it (the site's does).
 *
 * Reader-agnostic: a scope's reader (tools/test/lib/svelte-markup.cjs for the
 * site's Svelte files, an HTML reader for the static pages) turns each
 * element into a descriptor, and this module judges the descriptors and the
 * list. tools/test/test-site-semantic-html.cjs is the site scope;
 * tools/test/test-app-windows-semantic-markup.cjs is the app windows' scope,
 * read from their HTML and scripts by the source scanner below.
 * ==============================================================================
 */

'use strict';

const GENERIC = Object.freeze(['div', 'span']);
// Every element HTML, SVG and MathML define that a page here may write; any
// other plain name is unknown to the browser (HTMLUnknownElement) and, like a
// custom element, carries no meaning.
const KNOWN_ELEMENTS = new Set(
	(
		'a abbr address area article aside audio b base bdi bdo blockquote body br button canvas ' +
		'caption cite code col colgroup data datalist dd del details dfn dialog div dl dt em embed ' +
		'fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head header hgroup hr html i ' +
		'iframe img input ins kbd label legend li link main map mark menu meta meter nav noscript ' +
		'object ol optgroup option output p picture pre progress q rp rt ruby s samp script search ' +
		'section select slot small source span strong style sub summary sup table tbody td template ' +
		'textarea tfoot th thead time title tr track u ul var video wbr ' +
		'svg g path circle ellipse line polyline polygon rect text tspan defs use symbol desc ' +
		'lineargradient radialgradient stop clippath mask pattern image foreignobject ' +
		'math mi mn mo ms mtext mrow msup msub mfrac msqrt mroot'
	).split(' ')
);

/**
 * Whether a tag is generic: a div, a span, or a made-up element (a custom
 * element name with a hyphen, or a name HTML, SVG and MathML do not define).
 * A namespaced name (`enhanced:img`, `svelte:head`) is a build-time
 * directive, not an element of the page.
 * @param {string} tag - Lower-case tag name.
 * @returns {boolean}
 */
function isGeneric(tag) {
	if (GENERIC.includes(tag)) return true;
	if (tag.includes(':')) return false;
	return tag.includes('-') || !KNOWN_ELEMENTS.has(tag.toLowerCase());
}
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
		if (!isGeneric(element.tag)) continue;
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
		const tag = /^([a-z][\w-]*)(\.[\w-]+|#[\w-]+| \(none\))$/.exec(entry.element ?? '');
		if (!tag || !isGeneric(tag[1]))
			problems.push(
				`${label}: element must be a div, a span or a made-up element with .class, #id or (none)`
			);
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

// ==========================================
// ==========================================
// ======= Source scanner (app windows) =====
// ==========================================
// ==========================================

// The app windows' reader: their HTML and the scripts that build their DOM
// (tools/test/test-app-windows-semantic-markup.cjs). Occurrences come from
// the source text, so every branch of a script is read; each comes with its
// context (the opening tag, or the line of a createElement or el call), which
// a list entry names a part of.

// The pointer events that make an element a control.
const POINTER_EVENTS = Object.freeze([
	'click',
	'dblclick',
	'mousedown',
	'mouseup',
	'pointerdown',
	'pointerup',
	'contextmenu'
]);
// Words that alone do not say why no element carries the meaning.
const EMPTY_REASONS =
	/^(todo|tbd|fixme|legacy|layout|wrapper|container|styling|style|css|needed|required)\.?$/i;

/**
 * Blanks comments while keeping every offset and line break, so a tag named
 * in a comment is not an occurrence and line numbers stay right.
 * @param {string} source
 * @param {'html'|'js'} kind
 */
function blankComments(source, kind) {
	const blank = (text) => text.replace(/[^\n]/g, ' ');
	if (kind === 'html') return source.replace(/<!--[\s\S]*?-->/g, blank);
	// A small lexer: strings, templates and regular expressions keep their
	// text (a `//` inside a URL is no comment), comments are blanked.
	let out = '';
	let index = 0;
	while (index < source.length) {
		const char = source[index];
		const next = source[index + 1];
		if (char === '/' && next === '/') {
			const end = source.indexOf('\n', index);
			const stop = end === -1 ? source.length : end;
			out += blank(source.slice(index, stop));
			index = stop;
		} else if (char === '/' && next === '*') {
			const end = source.indexOf('*/', index + 2);
			const stop = end === -1 ? source.length : end + 2;
			out += blank(source.slice(index, stop));
			index = stop;
		} else if (char === '"' || char === "'" || char === '`') {
			let stop = index + 1;
			while (stop < source.length && source[stop] !== char) {
				if (source[stop] === '\\') stop++;
				else if (char !== '`' && source[stop] === '\n') break;
				stop++;
			}
			out += source.slice(index, stop + 1);
			index = stop + 1;
		} else {
			out += char;
			index++;
		}
	}
	return out;
}

/** The 1-based line of an offset. */
function lineOf(source, offset) {
	let line = 1;
	for (let index = 0; index < offset; index++) if (source[index] === '\n') line++;
	return line;
}

/** The whole line around an offset. */
function lineAround(source, offset) {
	const start = source.lastIndexOf('\n', offset - 1) + 1;
	const end = source.indexOf('\n', offset);
	return source.slice(start, end === -1 ? source.length : end);
}

/**
 * The opening tag from its `<`: up to the `>` that closes it outside quotes
 * and template substitutions, at most 2000 characters.
 */
function openingTag(source, offset) {
	let quote = null;
	let depth = 0;
	for (let index = offset + 1; index < source.length && index < offset + 2000; index++) {
		const char = source[index];
		if (source.startsWith('${', index)) {
			depth++;
			index++;
		} else if (depth > 0) {
			if (char === '}') depth--;
		} else if (quote) {
			if (char === quote) quote = null;
		} else if (char === '"' || char === "'") quote = char;
		else if (char === '>') return source.slice(offset, index + 1);
	}
	return source.slice(offset, offset + 200);
}

/**
 * Every generic element a file writes.
 * @param {string} source
 * @param {'html'|'js'} kind
 * @returns {{tag: string, line: number, context: string, via: string}[]}
 */
function genericOccurrences(source, kind) {
	const text = blankComments(source, kind);
	const found = [];
	for (const match of text.matchAll(/<(div|span)(?=[\s>/])/g))
		found.push({
			tag: match[1],
			line: lineOf(text, match.index),
			context: openingTag(text, match.index),
			via: 'markup'
		});
	if (kind === 'js')
		for (const match of text.matchAll(/\b(?:createElement|el)\(\s*(['"`])(div|span)\1/g))
			found.push({
				tag: match[2],
				line: lineOf(text, match.index),
				context: lineAround(text, match.index),
				via: 'call'
			});
	return found.sort((a, b) => a.line - b.line);
}

/** Whether an opening tag gives itself an interactive role or a pointer handler. */
function interactiveTag(context) {
	const role = /\brole\s*=\s*\\?["'`]?([a-z]+)/i.exec(context);
	// A rich text editor has no native element: a contenteditable box named
	// as a text box is the pattern (a textarea cannot style its text).
	const editable = /\bcontenteditable\b/i.test(context) && /^textbox$/i.test(role ? role[1] : '');
	if (role && !editable && INTERACTIVE_ROLES.includes(role[1].toLowerCase()))
		return 'role="' + role[1] + '"';
	const handler = new RegExp('\\bon(' + POINTER_EVENTS.join('|') + ')\\s*=', 'i').exec(context);
	return handler ? 'on' + handler[1] : null;
}

/**
 * The statements that use a variable from its declaration to its next
 * declaration under the same name (or the end of the file).
 */
function variableScope(text, name, from) {
	const redeclared = new RegExp('\\b(?:const|let|var)\\s+' + name + '\\b', 'g');
	redeclared.lastIndex = from + 1;
	const next = redeclared.exec(text);
	return text.slice(from, next ? next.index : text.length);
}

/**
 * The div or span elements a script makes interactive after creating them:
 * a pointer listener, an `onclick` property or an interactive role.
 * @returns {{line: number, problem: string}[]}
 */
function interactiveCalls(source) {
	const text = blankComments(source, 'js');
	const problems = [];
	const declared =
		/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:document\.)?(?:createElement|el)\(\s*(['"`])(div|span)\2/g;
	for (const match of text.matchAll(declared)) {
		const [, name, , tag] = match;
		const scope = variableScope(text, name.replace(/\$/g, '\\$'), match.index);
		const escaped = name.replace(/\$/g, '\\$');
		const listener = new RegExp(
			'\\b' + escaped + '\\.addEventListener\\(\\s*[\'"`](' + POINTER_EVENTS.join('|') + ')'
		).exec(scope);
		const property = new RegExp(
			'\\b' + escaped + '\\.on(' + POINTER_EVENTS.join('|') + ')\\s*='
		).exec(scope);
		const role = new RegExp(
			'\\b' +
				escaped +
				'\\.(?:setAttribute\\(\\s*[\'"]role[\'"]\\s*,\\s*|role\\s*=\\s*)[\'"](' +
				INTERACTIVE_ROLES.join('|') +
				')[\'"]'
		).exec(scope);
		const how = listener
			? 'a ' + listener[1] + ' listener'
			: property
				? 'on' + property[1]
				: role
					? 'role="' + role[1] + '"'
					: null;
		if (how)
			problems.push({
				line: lineOf(text, match.index),
				problem: `${tag} ${name} gets ${how}: use a button, a link or a form control`
			});
	}
	return problems;
}

/**
 * Images and drawings without a text alternative: an img without alt, an svg
 * neither hidden from assistive technology nor named as an image, and the
 * same made by createElement.
 * @param {string} source
 * @param {'html'|'js'} kind
 * @returns {{line: number, problem: string}[]}
 */
function imageProblems(source, kind) {
	const text = blankComments(source, kind);
	const problems = [];
	for (const match of text.matchAll(/<(img|svg)(?=[\s>/])/g)) {
		const context = openingTag(text, match.index);
		const line = lineOf(text, match.index);
		if (match[1] === 'img' && !/\balt\s*=/.test(context))
			problems.push({ line, problem: 'img without alt' });
		if (match[1] === 'svg' && !svgAlternative(context))
			problems.push({
				line,
				problem: 'svg neither aria-hidden="true" nor role="img" with a name'
			});
	}
	if (kind === 'js') {
		const made =
			/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*document\.createElement(NS)?\(\s*(?:[^,()]+,\s*)?(['"`])(img|svg)\3/g;
		for (const match of text.matchAll(made)) {
			const [, name, , , tag] = match;
			const escaped = name.replace(/\$/g, '\\$');
			const scope = variableScope(text, escaped, match.index);
			const named =
				tag === 'img'
					? new RegExp('\\b' + escaped + '\\.(?:alt\\s*=|setAttribute\\(\\s*[\'"]alt[\'"])').test(
							scope
						)
					: new RegExp(
							'\\b' + escaped + '\\.setAttribute\\(\\s*[\'"](?:aria-hidden|role|aria-label)[\'"]'
						).test(scope);
			if (!named)
				problems.push({
					line: lineOf(text, match.index),
					problem: `${tag} ${name} is created without ${tag === 'img' ? 'alt' : 'aria-hidden or a role'}`
				});
		}
	}
	return problems;
}

/** Whether an svg opening tag hides itself or names itself as an image. */
function svgAlternative(context) {
	if (/\baria-hidden\s*=\s*\\?["'`]?true/.test(context)) return true;
	const named = /\baria-(label|labelledby)\s*=/.test(context);
	if (/\brole\s*=\s*\\?["'`]?img/.test(context)) return named;
	// An interactive drawing (the typing heatmaps): a named group whose own
	// keydown handler moves the focus between its marks, each named in turn
	// (the app windows scan checks the marks in the page).
	return /\brole\s*=\s*\\?["'`]?group/.test(context) && named && /\bonkeydown\s*=/.test(context);
}

/**
 * Checks one allowlist entry's own shape.
 * @returns {string[]} The problems, empty when the entry is well formed.
 */
function entryProblems(entry, where) {
	const problems = [];
	if (!GENERIC.includes(entry.tag)) problems.push(where + ': tag must be div or span');
	if (!Number.isSafeInteger(entry.count) || entry.count < 1)
		problems.push(where + ': count must be a positive integer');
	if (typeof entry.where !== 'string' || entry.where.trim().length < 3)
		problems.push(where + ': where must name a part of the opening tag or call line');
	const reason = typeof entry.reason === 'string' ? entry.reason.trim() : '';
	if (reason.length < MIN_REASON_LENGTH || EMPTY_REASONS.test(reason))
		problems.push(
			`${where}: the reason must say why no element carries the meaning (at least ${MIN_REASON_LENGTH} characters)`
		);
	const extra = Object.keys(entry).filter(
		(key) => !['tag', 'where', 'count', 'reason'].includes(key)
	);
	if (extra.length) problems.push(where + ': unknown field ' + extra.join(', '));
	return problems;
}

/**
 * Matches a file's occurrences with its allowlist entries. Every occurrence
 * must be claimed by an entry of its tag whose `where` is part of its
 * context; every entry must claim exactly its count, so a removed div lowers
 * the count in the same change and a new one needs its own reason.
 * @param {{tag: string, line: number, context: string}[]} occurrences
 * @param {{tag: string, where: string, count: number, reason: string}[]} entries
 * @param {string} file - For the messages.
 * @returns {string[]} The problems, empty when the file is justified.
 */
function matchAllowlist(occurrences, allEntries, file) {
	const problems = [];
	// A pending entry ({tag, count, pending: true}) holds the occurrences of a
	// window whose semantic pass has not landed yet: a count that can only
	// fall, with no reason. The gate refuses it once the pass is done.
	const pending = allEntries.filter((entry) => entry.pending === true);
	const entries = allEntries.filter((entry) => entry.pending !== true);
	const claimed = entries.map(() => 0);
	const held = pending.map(() => 0);
	pending.forEach((entry, index) => {
		const extra = Object.keys(entry).filter((key) => !['tag', 'count', 'pending'].includes(key));
		if (
			!GENERIC.includes(entry.tag) ||
			!Number.isSafeInteger(entry.count) ||
			entry.count < 1 ||
			extra.length
		)
			problems.push(`${file} pending entry ${index + 1}: {tag, count, pending: true} only`);
	});
	entries.forEach((entry, index) =>
		problems.push(...entryProblems(entry, `${file} entry ${index + 1}`))
	);
	for (const occurrence of occurrences) {
		const index = entries.findIndex(
			(entry, at) =>
				entry.tag === occurrence.tag &&
				typeof entry.where === 'string' &&
				occurrence.context.includes(entry.where) &&
				claimed[at] < entry.count
		);
		const hold =
			index === -1
				? pending.findIndex((entry, at) => entry.tag === occurrence.tag && held[at] < entry.count)
				: -1;
		if (hold !== -1) held[hold]++;
		else if (index === -1)
			problems.push(
				`${file}:${occurrence.line}: unjustified <${occurrence.tag}> ${occurrence.context
					.replace(/\s+/g, ' ')
					.slice(0, 120)}`
			);
		else claimed[index]++;
	}
	entries.forEach((entry, index) => {
		if (Number.isSafeInteger(entry.count) && claimed[index] < entry.count)
			problems.push(
				`${file} entry ${index + 1} (${entry.tag} « ${entry.where} »): ${claimed[index]} found, ` +
					`${entry.count} listed; lower its count`
			);
	});
	pending.forEach((entry, index) => {
		if (held[index] < entry.count)
			problems.push(
				`${file} pending ${entry.tag}: ${held[index]} found, ${entry.count} listed; lower its count`
			);
	});
	return problems;
}

module.exports = {
	GENERIC,
	isGeneric,
	CONTAINER_EVENTS,
	KINDS,
	INTERACTIVE_ROLES,
	elementKey,
	inventoryOf,
	allowlistProblems,
	compareWithAllowlist,
	ignoreProblems,
	POINTER_EVENTS,
	MIN_REASON_LENGTH,
	blankComments,
	genericOccurrences,
	interactiveTag,
	interactiveCalls,
	imageProblems,
	matchAllowlist
};
