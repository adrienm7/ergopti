// tools/test/lib/studio-markup.cjs

/**
 * ==============================================================================
 * MODULE: Studio Markup Reader
 * DESCRIPTION:
 * Reads the elements the Ergopti Studio pages write, for the shared div and
 * span judgement (lib/semantic-markup.cjs): the start tags of their HTML and
 * of the template strings their scripts hold, and the DOM their scripts
 * build through a builder call whose first argument is a literal tag
 * (document.createElement('div'), el('span', 'class', text),
 * el('div', {class, id, role, onclick})). Each element becomes the shared
 * Descriptor: its tag, its static classes and id, its role and tabindex
 * (undefined when a script computes them), the events it listens to, its
 * line. test-studio-semantic-html.cjs is the Studio scope.
 *
 * FEATURES & RATIONALE:
 * 1. A built element is followed through the variable it is assigned to, for
 *    the rest of its building code (FOLLOW_LINES, or until the name is
 *    declared again): a later className, id, setAttribute('role'), tabIndex,
 *    addEventListener or on… property is its own.
 * 2. Comments are blanked first, so a tag quoted in one is not an element; a
 *    selector (querySelector('div'), closest('span')) names a tag, it does
 *    not build one.
 * 3. Scope: every .html and .js file under the Studio folders, generated
 *    data excepted (STUDIO_ROOTS, EXCLUDE).
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const UI = 'static/ergopti_plus/_shared/ui/';
// The Studio's pages: the Comparer and its shared panels, the editor and its
// app window, the Optimiser, the layout manager, the composer and the layer
// editor (their models build no DOM, and stay held so a first one is seen).
const STUDIO_ROOTS = Object.freeze(
	[
		'layout_analysis',
		'layout_editor',
		'layout_editor_window',
		'layout_optimizer',
		'layout_manager',
		'layout_composer',
		'layer_editor'
	].map((folder) => UI + folder)
);
// Generated tables (corpora, key data) are data, never markup.
const EXCLUDE = Object.freeze([/\/_generated\//]);
const FILE_TYPES = Object.freeze(['.html', '.js']);
// How far after a builder call its variable is followed: the rest of a DOM-building function.
const FOLLOW_LINES = 60;

const START_TAG = /<([a-z][a-z0-9-]*)(?=[\s/>])([^>]*)>/g;
const BUILDER_CALL =
	/([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\(\s*(['"`])(div|span)\2\s*(?:,\s*(['"`])([^'"`]*)\4)?/g;
const SELECTOR_CALLEE = /(?:^|\.)(?:querySelector(?:All)?|closest|matches|getElementsByTagName)$/;

/** Every Studio page file, repository-relative, forward slashes, sorted. */
function studioFiles(root = ROOT) {
	const files = [];
	const walk = (relative) => {
		for (const entry of fs.readdirSync(path.join(root, relative), { withFileTypes: true })) {
			const child = relative + '/' + entry.name;
			if (entry.isDirectory()) walk(child);
			else if (FILE_TYPES.includes(path.extname(entry.name))) files.push(child);
		}
	};
	for (const folder of STUDIO_ROOTS) walk(folder);
	return files.filter((file) => !EXCLUDE.some((pattern) => pattern.test(file))).sort();
}

/** The 1-based line of an offset. */
function lineAt(text, offset) {
	let line = 1;
	for (let i = 0; i < offset; i++) if (text.charCodeAt(i) === 10) line++;
	return line;
}

/**
 * Blanks comments, keeping offsets and line breaks: HTML comments everywhere,
 * JS block and line comments in scripts (a « // » after an odd number of
 * quotes on its line is inside a string and stays).
 */
function blankComments(text, extension) {
	const blank = (match) => match.replace(/[^\n]/g, ' ');
	const out = text.replace(/<!--[\s\S]*?-->/g, blank);
	if (extension === '.html') return out;
	return out
		.replace(/\/\*[\s\S]*?\*\//g, blank)
		.split('\n')
		.map((line) => {
			const index = line.search(/(^|[^:\\])\/\//);
			if (index === -1) return line;
			const cut = line[index] === '/' ? index : index + 1;
			const quotes = (line.slice(0, cut).match(/['"`]/g) || []).length;
			return quotes % 2 === 0 ? line.slice(0, cut) + ' '.repeat(line.length - cut) : line;
		})
		.join('\n');
}

/** The raw text of a start tag's attribute, interpolations kept, or null when absent. */
function rawAttribute(attributes, name) {
	const match = new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i').exec(
		attributes
	);
	return match ? (match[1] ?? match[2] ?? match[3]) : null;
}

/** A static attribute value of a start tag: its text, null when absent, undefined when interpolated. */
function attribute(attributes, name) {
	const value = rawAttribute(attributes, name);
	return value !== null && value.includes('${') ? undefined : value;
}

/** The static class tokens of a class text, an interpolated part left out. */
function classTokens(text) {
	return (text || '')
		.replace(/\$\{[^}]*\}/g, ' ')
		.split(/\s+/)
		.filter((token) => /^[\w-]+$/.test(token));
}

/** The attribute object a builder passes after its tag (el('div', {…})), or ''. */
function attributeObject(source, from) {
	const open = /^\s*,\s*\{/.exec(source.slice(from, from + 200));
	if (!open) return '';
	const start = from + open[0].length - 1;
	let depth = 0;
	for (let i = start; i < source.length; i++) {
		if (source[i] === '{') depth++;
		else if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
	}
	return source.slice(start);
}

/** The variable a builder call is assigned to, from the text before it on its line. */
function assignedVariable(before) {
	const match = /(?:^|[^\w$.])([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)?)\s*=\s*$/.exec(before);
	return match ? match[1] : null;
}

/** The lines a variable is followed through, up to FOLLOW_LINES or its next declaration. */
function followedText(lines, start, name) {
	const escaped = name.replace(/[.$]/g, '\\$&');
	const redeclared = new RegExp(`\\b(?:const|let|var)\\s+${escaped}\\b`);
	const taken = [lines[start]];
	for (let i = start + 1; i < Math.min(lines.length, start + FOLLOW_LINES); i++) {
		if (redeclared.test(lines[i])) break;
		taken.push(lines[i]);
	}
	return taken.join('\n');
}

/**
 * What a built element receives through its variable and its attribute object.
 * @returns {{classes: string[], id: string|null, role: string|null|undefined, tabindex: string|null|undefined, handlers: string[]}}
 */
function builtParts(className, object, followed, variable) {
	const v = variable ? variable.replace(/[.$]/g, '\\$&') : null;
	const pick = (regex, text) => (text ? regex.exec(text) : null);
	const classes = classTokens(className);
	const objectClass = pick(/\b(?:class|className)['"]?\s*:\s*(['"`])([^'"`]*)\1/, object);
	if (objectClass) classes.push(...classTokens(objectClass[2]));
	if (v) {
		const later = new RegExp(
			`\\b${v}\\.(?:className\\s*=\\s*|classList\\.add\\(\\s*)(['"\`])([^'"\`]*)\\1`,
			'g'
		);
		for (const match of followed.matchAll(later)) classes.push(...classTokens(match[2]));
	}
	const objectId = pick(/\bid['"]?\s*:\s*(['"`])([^'"`$]+)\1/, object);
	const laterId = v
		? pick(new RegExp(`\\b${v}\\.id\\s*=\\s*(['"\`])([^'"\`$]+)\\1`), followed)
		: null;
	const id = objectId ? objectId[2] : laterId ? laterId[2] : null;
	// A role or tabindex a script computes from a variable is undefined: the
	// judgement asks for it to be written statically.
	let role = null;
	const objectRole = pick(/\brole['"]?\s*:\s*([^,}\n]+)/, object);
	if (objectRole) role = /^\s*(['"`])([\w\s-]+)\1\s*$/.exec(objectRole[1])?.[2] ?? undefined;
	const laterRole = v
		? pick(
				new RegExp(
					`\\b${v}\\.(?:setAttribute\\(\\s*['"]role['"]\\s*,\\s*|role\\s*=\\s*)([^)\\n;]+)`
				),
				followed
			)
		: null;
	if (laterRole) role = /^\s*(['"`])([\w\s-]+)\1\s*$/.exec(laterRole[1])?.[2] ?? undefined;
	let tabindex = null;
	const objectTab = pick(/\btab[iI]ndex['"]?\s*:\s*([^,}\n]+)/, object);
	if (objectTab) tabindex = /^\s*['"`]?(-?\d+)['"`]?\s*$/.exec(objectTab[1])?.[1] ?? undefined;
	const laterTab = v
		? pick(
				new RegExp(
					`\\b${v}\\.(?:tabIndex\\s*=\\s*|setAttribute\\(\\s*['"]tabindex['"]\\s*,\\s*)([^)\\n;]+)`
				),
				followed
			)
		: null;
	if (laterTab) tabindex = /^\s*['"`]?(-?\d+)['"`]?\s*$/.exec(laterTab[1])?.[1] ?? undefined;
	const handlers = [];
	for (const match of (object || '').matchAll(/(?:^|[{,\s])['"]?on([a-z]+)['"]?\s*:/gi))
		handlers.push(match[1].toLowerCase());
	if (v) {
		for (const match of followed.matchAll(
			new RegExp(`\\b${v}\\.addEventListener\\(\\s*['"\`]([a-z]+)['"\`]`, 'g')
		))
			handlers.push(match[1]);
		for (const match of followed.matchAll(new RegExp(`\\b${v}\\.on([a-z]+)\\s*=(?!=)`, 'g')))
			handlers.push(match[1]);
	}
	return { classes, id, role, tabindex, handlers: [...new Set(handlers)] };
}

/**
 * The div and span elements of one Studio file, as shared descriptors.
 * @param {string} file - Repository-relative path.
 * @param {string} text - Its content.
 * @returns {import('./semantic-markup.cjs').Descriptor[]}
 */
function descriptorsOf(file, text) {
	const extension = path.extname(file);
	const source = blankComments(text, extension);
	const lines = source.split('\n');
	const found = [];
	for (const match of source.matchAll(START_TAG)) {
		const [, tag, attributes] = match;
		if (tag !== 'div' && tag !== 'span') continue;
		const handlers = [...attributes.matchAll(/\son([a-z]+)\s*=/gi)].map((m) => m[1].toLowerCase());
		const className = rawAttribute(attributes, 'class');
		found.push({
			tag,
			classes: classTokens(className),
			id: attribute(attributes, 'id') || null,
			role: attribute(attributes, 'role'),
			tabindex: attribute(attributes, 'tabindex'),
			handlers,
			line: lineAt(source, match.index)
		});
	}
	if (extension === '.html') return found;
	for (const match of source.matchAll(BUILDER_CALL)) {
		const [, callee, , tag, , className] = match;
		if (SELECTOR_CALLEE.test(callee)) continue;
		const line = lineAt(source, match.index);
		const lineStart = source.lastIndexOf('\n', match.index) + 1;
		const variable = assignedVariable(source.slice(lineStart, match.index));
		const followed = variable ? followedText(lines, line - 1, variable) : lines[line - 1];
		const object = attributeObject(source, match.index + match[0].length);
		found.push({ tag, line, ...builtParts(className, object, followed, variable) });
	}
	return found.sort((a, b) => a.line - b.line);
}

module.exports = { ROOT, STUDIO_ROOTS, studioFiles, descriptorsOf };
