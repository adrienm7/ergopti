// tools/lib/menu-shared-delegation.cjs

/** Credits shared menu methods only through executable native require/call routes. */
'use strict';

const fs = require('fs');
const path = require('path');
const { scriptTokens, stripComments } = require('./script-source.cjs');

const MODULES = new Set([
	'menu.personal_files',
	'menu.programmable_hotstrings',
	'keymap.magic_key_source'
]);
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
			!['function', '.', ':'].includes(tokens[i - 1]?.value)
		)
			result.add(tokens[i + 2].value);
	}
	return result;
}

/** The physical-key family needs the actual native renderer as its explicit port. */
function magicRendererPort(source, owner) {
	const tokens = values(source);
	const direct = tokens.some(
		(token, i) =>
			token.kind === 'identifier' &&
			token.value === 'local' &&
			tokens[i + 1]?.kind === 'identifier' &&
			tokens[i + 1]?.value === 'ManifestMenu' &&
			tokens[i + 2]?.value === '=' &&
			tokens[i + 3]?.value === 'require' &&
			tokens[i + 4]?.value === '(' &&
			tokens[i + 5]?.kind === 'string' &&
			tokens[i + 5]?.value === 'infra.manifest_menu' &&
			tokens[i + 6]?.value === ')'
	);
	const protectedImport = tokens.some(
		(token, i) =>
			token.kind === 'identifier' &&
			token.value === 'local' &&
			tokens[i + 1]?.kind === 'identifier' &&
			tokens[i + 2]?.value === ',' &&
			tokens[i + 3]?.kind === 'identifier' &&
			tokens[i + 3]?.value === 'ManifestMenu' &&
			tokens[i + 4]?.value === '=' &&
			tokens[i + 5]?.value === 'pcall' &&
			tokens[i + 6]?.value === '(' &&
			tokens[i + 7]?.kind === 'identifier' &&
			tokens[i + 7]?.value === 'require' &&
			tokens[i + 8]?.value === ',' &&
			tokens[i + 9]?.kind === 'string' &&
			tokens[i + 9]?.value === 'infra.manifest_menu' &&
			tokens[i + 10]?.value === ')'
	);
	if (!direct && !protectedImport) return false;
	for (let i = 0; i < tokens.length; i += 1) {
		if (
			tokens[i]?.kind !== 'identifier' ||
			tokens[i].value !== owner ||
			['.', ':', 'function'].includes(tokens[i - 1]?.value) ||
			tokens[i + 1]?.value !== '.' ||
			tokens[i + 2]?.kind !== 'identifier' ||
			tokens[i + 2]?.value !== 'menu_rows' ||
			tokens[i + 3]?.value !== '('
		)
			continue;
		let depth = 0,
			cursor = i + 4;
		for (; cursor < tokens.length; cursor += 1) {
			const token = tokens[cursor];
			if (token.kind !== 'symbol') continue;
			if (token.value === '(' || token.value === '{' || token.value === '[') depth += 1;
			if (token.value === ')' || token.value === '}' || token.value === ']') {
				if (depth === 0) break;
				depth -= 1;
			}
			if (token.value === ',' && depth === 0) break;
		}
		if (tokens[cursor]?.value !== ',' || tokens[cursor + 1]?.value !== '{') continue;
		depth = 1;
		let manifests = 0,
			genuine = false;
		for (cursor += 2; cursor < tokens.length && depth > 0; cursor += 1) {
			const token = tokens[cursor];
			// Inspect the whole physical options literal: Lua's last duplicate field wins.
			if (depth === 1 && [',', ';', '{'].includes(tokens[cursor - 1]?.value)) {
				let key, valueAt;
				if (token.kind === 'identifier' && tokens[cursor + 1]?.value === '=') {
					key = token.value;
					valueAt = cursor + 2;
				} else if (token.kind === 'symbol' && token.value === '[') {
					// A computed key could alias manifest: only a literal key is provable here.
					if (
						tokens[cursor + 1]?.kind !== 'string' ||
						tokens[cursor + 2]?.value !== ']' ||
						tokens[cursor + 3]?.value !== '='
					)
						return false;
					const spelling = source.slice(tokens[cursor + 1].start, tokens[cursor + 1].end);
					// The shared lexer records spelling, not Lua escape/long-string decoding.
					// Only an ordinary unescaped quoted key can prove its actual identity.
					if (
						!['"', "'"].includes(spelling[0]) ||
						spelling.at(-1) !== spelling[0] ||
						spelling.includes('\\')
					)
						return false;
					key = tokens[cursor + 1].value;
					valueAt = cursor + 4;
				}
				if (key === 'manifest') {
					manifests += 1;
					genuine =
						tokens[valueAt]?.kind === 'identifier' &&
						tokens[valueAt].value === 'ManifestMenu' &&
						[',', ';', '}'].includes(tokens[valueAt + 1]?.value);
				}
			}
			if (token.kind === 'symbol' && ['{', '(', '['].includes(token.value)) depth += 1;
			if (token.kind === 'symbol' && ['}', ')', ']'].includes(token.value)) depth -= 1;
		}
		if (depth === 0 && manifests === 1 && genuine) return true;
	}
	return false;
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
	const templatePort = tokens.some(
		(token, i) =>
			token.kind === 'identifier' &&
			token.value === 'local' &&
			tokens[i + 1]?.kind === 'identifier' &&
			tokens[i + 1]?.value === 'manifest' &&
			tokens[i + 2]?.value === '=' &&
			tokens[i + 3]?.kind === 'identifier' &&
			tokens[i + 3]?.value === 'opts' &&
			tokens[i + 4]?.value === '.' &&
			tokens[i + 5]?.kind === 'identifier' &&
			tokens[i + 5]?.value === 'manifest'
	);
	return tokens.some(
		(token, i) =>
			token.kind === 'identifier' &&
			token.value === 'manifest' &&
			tokens[i + 1]?.value === '.' &&
			(tokens[i + 2]?.value === 'build' ||
				(tokens[i + 2]?.value === 'template_rows' &&
					templatePort &&
					!['.', ':', 'function'].includes(tokens[i - 1]?.value))) &&
			tokens[i + 2]?.kind === 'identifier' &&
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
			if (module === 'keymap.magic_key_source' && !magicRendererPort(native.src, tokens[i].value))
				continue;
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
