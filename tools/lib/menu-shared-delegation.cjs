// tools/lib/menu-shared-delegation.cjs

/** Credits shared menu methods only through executable native require/call routes. */
'use strict';

const fs = require('fs');
const path = require('path');
const { scriptTokens, stripComments } = require('./script-source.cjs');

const MODULES = new Set(['menu.personal_files', 'menu.programmable_hotstrings']);
const values = (source) => scriptTokens(source, '.lua');
const same = (tokens, index, expected) =>
	expected.every(
		(value, offset) =>
			tokens[index + offset]?.value === value &&
			(tokens[index + offset]?.kind !== 'string' || offset === expected.length - 2)
	);

/** Finds real member calls; a comment, string or method declaration is not a call. */
function calls(source, owner) {
	const tokens = values(source),
		result = new Set();
	for (let i = 0; i + 3 < tokens.length; i += 1) {
		if (
			tokens[i].kind === 'identifier' &&
			tokens[i].value === owner &&
			tokens[i + 1].value === '.' &&
			tokens[i + 2].kind === 'identifier' &&
			tokens[i + 3].value === '(' &&
			tokens[i - 1]?.value !== 'function'
		)
			result.add(tokens[i + 2].value);
	}
	return result;
}

/** Splits the module's public methods, without crediting its unused neighbors. */
function methods(source) {
	const tokens = values(source),
		starts = [];
	for (let i = 0; i + 5 < tokens.length; i += 1) {
		if (
			same(tokens, i, ['function', 'M', '.', tokens[i + 3]?.value, '(']) &&
			tokens[i + 3].kind === 'identifier'
		)
			starts.push({ name: tokens[i + 3].value, at: tokens[i].start });
	}
	return new Map(
		starts.map((entry, index) => [
			entry.name,
			source.slice(entry.at, starts[index + 1]?.at ?? source.length)
		])
	);
}

/** A reached method must actually render, or delegate to a reached renderer. */
function renders(source) {
	const tokens = values(source);
	return tokens.some(
		(token, i) =>
			token.kind === 'identifier' &&
			token.value === 'manifest' &&
			tokens[i + 1]?.value === '.' &&
			tokens[i + 2]?.value === 'build' &&
			tokens[i + 3]?.value === '(' &&
			tokens[i + 4]?.kind === 'string'
	);
}

/** Returns callable table keys, rather than adding decorative identifiers to source. */
function handlerKeys(source) {
	const tokens = values(source),
		keys = new Set();
	for (let i = 0; i + 2 < tokens.length; i += 1) {
		if (
			tokens[i].kind === 'identifier' &&
			tokens[i + 1].value === '=' &&
			['command', 'mutation', 'function'].includes(tokens[i + 2].value)
		)
			keys.add(tokens[i].value);
		if (
			tokens[i].value === '[' &&
			tokens[i + 1].kind === 'string' &&
			tokens[i + 2].value === ']' &&
			tokens[i + 3]?.value === '=' &&
			['command', 'mutation', 'function'].includes(tokens[i + 4]?.value)
		)
			keys.add(tokens[i + 1].value);
	}
	return keys;
}

/**
 * Resolves exact shared menu methods from production native sources.
 * @param {Array<{rel: string, src: string}>} sources Native production files.
 * @param {string} sharedRoot Shared Lua root.
 * @param {Function} readFile Optional independent fixture reader.
 * @returns {Array<{rel: string, src: string, handlers: Set<string>}>} Reached methods.
 */
function delegatedMenuSources(
	sources,
	sharedRoot,
	readFile = (file) => fs.readFileSync(file, 'utf8')
) {
	const result = [],
		seen = new Set();
	for (const native of sources) {
		if (!native.rel.endsWith('.lua')) continue;
		const tokens = values(native.src);
		for (let i = 0; i + 6 < tokens.length; i += 1) {
			if (
				tokens[i].kind !== 'identifier' ||
				tokens[i + 1]?.value !== '=' ||
				tokens[i + 2]?.value !== 'require' ||
				tokens[i + 3]?.value !== '(' ||
				tokens[i + 4]?.kind !== 'string' ||
				tokens[i + 5]?.value !== ')'
			)
				continue;
			const module = tokens[i + 4].value;
			if (!MODULES.has(module)) continue;
			const shared = readFile(path.join(sharedRoot, module.replaceAll('.', '/') + '.lua'));
			const bodies = methods(shared),
				reached = new Set();
			const visit = (name, visiting = new Set()) => {
				if (visiting.has(name) || !bodies.has(name)) return false;
				const body = bodies.get(name),
					children = [...calls(body, 'M')];
				const next = new Set(visiting).add(name);
				const childrenRender = children.map((child) => visit(child, next)).some(Boolean);
				if (!renders(body) && !childrenRender) return false;
				reached.add(name);
				return true;
			};
			for (const name of calls(native.src, tokens[i].value)) visit(name);
			for (const name of reached) {
				const rel = `${module}.${name}`;
				if (seen.has(rel)) continue;
				seen.add(rel);
				const src = stripComments(bodies.get(name), '.lua');
				result.push({ rel, src, handlers: handlerKeys(src) });
			}
		}
	}
	return result;
}

/** Unions independent incoming routes without extending an edge's visibility. */
function combineMenuVisibility(platforms, previous, incoming) {
	return platforms.filter(
		(platform) => (previous || []).includes(platform) || incoming.includes(platform)
	);
}

/** Credits executable native template calls, never comments, strings or declarations. */
function publishesMenuTemplate(source, extension, section) {
	const tokens = scriptTokens(source, extension);
	return tokens.some((token, i) => {
		if (token.kind !== 'identifier' || tokens[i - 1]?.value === 'function') return false;
		const lua =
			extension === '.lua' &&
			token.value === 'template_rows' &&
			tokens[i - 1]?.value === '.' &&
			tokens[i - 2]?.value === 'ManifestMenu' &&
			!['function', '.', ':'].includes(tokens[i - 3]?.value);
		const ahk =
			extension === '.ahk' &&
			token.value === 'MenuRenderer_TemplateRows' &&
			!['.', ':'].includes(tokens[i - 1]?.value);
		return (
			(lua || ahk) &&
			tokens[i + 1]?.value === '(' &&
			tokens[i + 2]?.kind === 'string' &&
			tokens[i + 2]?.value === section &&
			[',', ')'].includes(tokens[i + 3]?.value)
		);
	});
}

module.exports = { delegatedMenuSources, combineMenuVisibility, publishesMenuTemplate };
