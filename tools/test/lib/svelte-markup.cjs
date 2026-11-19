// tools/test/lib/svelte-markup.cjs

/**
 * ==============================================================================
 * MODULE: Svelte Markup Reader
 * DESCRIPTION:
 * Reads the markup of the site's Svelte files through the Svelte compiler's
 * own parser, so the site's static accessibility gates see the elements the
 * compiler sees: attributes written as {expressions}, elements inside {#if}
 * and {#each} blocks, Svelte 5 event attributes (onclick) and legacy
 * directives (on:click). Shared by test-site-semantic-html.cjs and
 * test-site-image-alternatives.cjs.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const SRC = path.join(ROOT, 'src');

/** Every Svelte file under src/, as paths relative to the repository, sorted. */
function svelteFiles(root = ROOT) {
	const files = [];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (entry.name.endsWith('.svelte'))
				files.push(path.relative(root, full).split(path.sep).join('/'));
		}
	};
	walk(path.join(root, 'src'));
	return files.sort();
}

function compiler() {
	return require(require.resolve('svelte/compiler', { paths: [ROOT] }));
}

/**
 * The elements of one Svelte source, in document order, with their parent
 * chain. Only markup: the script and style blocks are not walked.
 * @param {string} source
 * @param {string} filename - For the parser's error messages.
 * @returns {Array<{name: string, attributes: object[], children: object[], ancestors: string[], line: number}>}
 */
function elementsOf(source, filename) {
	const ast = compiler().parse(source, { modern: true, filename });
	const lineOf = (offset) => source.slice(0, offset).split('\n').length;
	const found = [];
	const visit = (node, ancestors) => {
		if (node === null || typeof node !== 'object') return;
		if (Array.isArray(node)) {
			for (const child of node) visit(child, ancestors);
			return;
		}
		const isElement = node.type === 'RegularElement' || node.type === 'SvelteElement';
		if (isElement)
			found.push({
				name: node.name,
				attributes: node.attributes,
				children: node.fragment ? node.fragment.nodes : [],
				ancestors,
				line: lineOf(node.start)
			});
		const next = isElement ? [...ancestors, node.name] : ancestors;
		for (const [key, value] of Object.entries(node)) {
			// Expressions and attributes hold no markup the gates read.
			if (key === 'attributes' || key === 'expression' || key === 'metadata') continue;
			if (value && typeof value === 'object') visit(value, next);
		}
	};
	visit(ast.fragment, []);
	return found;
}

/** The static text of an attribute, '' for a bare attribute, null when absent or dynamic. */
function staticValue(element, name) {
	const attribute = element.attributes.find(
		(item) => item.type === 'Attribute' && item.name.toLowerCase() === name
	);
	if (!attribute) return null;
	if (attribute.value === true) return '';
	const parts = Array.isArray(attribute.value) ? attribute.value : [attribute.value];
	if (parts.some((part) => part.type !== 'Text')) return null;
	return parts.map((part) => part.data).join('');
}

/** Whether the element carries the attribute at all, static or dynamic. */
function hasAttribute(element, name) {
	return element.attributes.some(
		(item) => item.type === 'Attribute' && item.name.toLowerCase() === name
	);
}

/** The static class tokens of the class attribute (dynamic parts left out). */
function staticClasses(element) {
	const attribute = element.attributes.find(
		(item) => item.type === 'Attribute' && item.name === 'class'
	);
	if (!attribute || attribute.value === true) return [];
	const parts = Array.isArray(attribute.value) ? attribute.value : [attribute.value];
	return parts
		.filter((part) => part.type === 'Text')
		.flatMap((part) => part.data.split(/\s+/))
		.filter(Boolean);
}

/** The event handlers of an element: Svelte 5 attributes and legacy directives. */
function handlersOf(element) {
	return element.attributes
		.filter(
			(item) =>
				(item.type === 'Attribute' && /^on[a-z]+$/.test(item.name)) || item.type === 'OnDirective'
		)
		.map((item) => (item.type === 'OnDirective' ? item.name : item.name.slice(2)));
}

/**
 * The descriptors of a source's elements, as lib/semantic-markup.cjs judges them.
 * @returns {Array<object>} See the Descriptor typedef of semantic-markup.cjs.
 */
function descriptorsOf(source, filename) {
	const valueOrComputed = (element, name) => {
		const value = staticValue(element, name);
		if (value !== null) return value;
		return hasAttribute(element, name) ? undefined : null;
	};
	return elementsOf(source, filename).map((element) => ({
		tag: element.name,
		classes: staticClasses(element),
		id: staticValue(element, 'id') || null,
		role: valueOrComputed(element, 'role'),
		tabindex: valueOrComputed(element, 'tabindex'),
		handlers: handlersOf(element),
		line: element.line
	}));
}

/** The text of the svelte-ignore comments of a source, with their line. */
function svelteIgnores(source, filename) {
	const ast = compiler().parse(source, { modern: true, filename });
	const lineOf = (offset) => source.slice(0, offset).split('\n').length;
	const found = [];
	const visit = (node) => {
		if (node === null || typeof node !== 'object') return;
		if (Array.isArray(node)) return node.forEach(visit);
		if (node.type === 'Comment' && /^\s*svelte-ignore\b/.test(node.data))
			found.push({
				codes: node.data
					.replace(/^\s*svelte-ignore\s*/, '')
					.split(/[\s,]+/)
					.filter(Boolean),
				line: lineOf(node.start)
			});
		for (const [key, value] of Object.entries(node))
			if (key !== 'metadata' && value && typeof value === 'object') visit(value);
	};
	visit(ast.fragment);
	return found;
}

/** The accessibility warnings the Svelte compiler gives for a source. */
function a11yWarnings(source, filename) {
	const result = compiler().compile(source, { filename, generate: false });
	return result.warnings
		.filter((warning) => warning.code.startsWith('a11y'))
		.map((warning) => ({
			code: warning.code,
			line: warning.start ? warning.start.line : 0,
			message: warning.message
		}));
}

module.exports = {
	ROOT,
	SRC,
	svelteFiles,
	elementsOf,
	descriptorsOf,
	staticValue,
	hasAttribute,
	staticClasses,
	handlersOf,
	svelteIgnores,
	a11yWarnings
};
