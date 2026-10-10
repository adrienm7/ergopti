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
	if (extension === '.lua' && section === 'personal_info_editor_frame')
		return require('./menu-native-personal-info-binding.cjs').retainedPersonalInfoProjection(
			source
		);
	if (
		extension === '.lua' &&
		section === 'llm_download_shortcut_frame' &&
		require('./menu-native-download-binding.cjs').retainedNativeDownloadProjection(source)
	)
		return true;
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

/** Follows the real model receiver into its returned parent and native consumer. */
function retainedModelGroupPublication(source, section, definition, proof, executable) {
	const row = {
		type: 'group',
		id: 'llm_model',
		i18n: 'menu.llm.model_parent_with_health',
		caption_getters: ['llm_model_health_prefix', 'llm_model_current_caption'],
		disabled_when: ['llm_model_parent_ready'],
		platforms: ['ahk'],
		unavailable: 'hide'
	};
	if (
		section !== 'llm_model_parent_ahk' ||
		proof.transport !== 'retained_model_receiver' ||
		!require('node:util').isDeepStrictEqual(definition, [row])
	)
		return false;
	try {
		const tokens = executable(source);
		const sameToken = (actual, wanted) =>
			actual?.kind === wanted.kind && actual.value === wanted.value;
		const symbol = (token, value) => token?.kind === 'symbol' && token.value === value;
		const identifier = (token, value) =>
			token?.kind === 'identifier' &&
			(value === undefined || token.value.toLowerCase() === value.toLowerCase());
		const levels = [],
			stack = [];
		for (let i = 0; i < tokens.length; i++) {
			levels.push(stack.length);
			if (symbol(tokens[i], '{')) stack.push(i);
			if (symbol(tokens[i], '}')) {
				if (!stack.length) return false;
				stack.pop();
			}
		}
		if (stack.length) return false;
		const close = (at, open, end) => {
			let count = 0;
			for (let i = at; i < tokens.length; i++) {
				if (symbol(tokens[i], open)) count++;
				if (symbol(tokens[i], end) && !--count) return i;
			}
			throw Error('Incomplete physical model owner');
		};
		const owner = (name) => {
			const found = [];
			for (let i = 0; i < tokens.length; i++) {
				if (levels[i] !== 0 || !identifier(tokens[i], name) || !symbol(tokens[i + 1], '('))
					continue;
				const end = close(i + 1, '(', ')');
				if (!symbol(tokens[end + 1], '{')) continue;
				if (source.slice(source.lastIndexOf('\n', tokens[i].start - 1) + 1, tokens[i].start).trim())
					continue;
				const finish = close(end + 1, '{', '}');
				found.push({
					index: i,
					parameters: tokens.slice(i + 2, end),
					body: tokens.slice(end + 2, finish)
				});
			}
			if (found.length !== 1) throw Error('One physical model owner required');
			return found[0];
		};
		const emit = owner('_LLM_Menu_EmitRow'),
			helper = owner('_LLM_Menu_ModelParentRows');
		const callableNames = new Set([
			'menurenderer_groupreceiver',
			'menurenderer_appendrows',
			'_mr_declaredparentcallable',
			'_llm_menu_emitrow',
			'_llm_menu_modelparentrows',
			'menurenderer_grouprow',
			'llm_menu_buildmodelmenu',
			'_llm_menu_firehealthprobe',
			'_llm_menu_fireinstalledtagsprobe',
			'_llm_menu_modeldisplaytext',
			'map',
			'error'
		]);
		const arrayLiteralOpen = (at) =>
			symbol(tokens[at], '[') &&
			((identifier(tokens[at - 1], 'return') && !['.', ':', '['].includes(tokens[at - 2]?.value)) ||
				(tokens[at - 1]?.kind === 'symbol' &&
					[':=', '(', ',', '[', '?', ':'].includes(tokens[at - 1].value)));
		const brackets = [];
		// Canonical callables cannot become aliases, parameters, fields or assigned values.
		for (let i = 0; i < tokens.length; i++) {
			if (symbol(tokens[i], '[')) brackets.push(i);
			if (symbol(tokens[i], ']')) brackets.pop();
			if (!identifier(tokens[i]) || !callableNames.has(tokens[i].value.toLowerCase())) continue;
			if (
				i === helper.index ||
				i === emit.index ||
				(identifier(tokens[i], 'Map') && identifier(tokens[i - 1], 'is'))
			)
				continue;
			// The native fallback Array and ternary values construct Maps directly.
			const arrayValue = arrayLiteralOpen(i - 1);
			const ternaryValue =
				symbol(tokens[i - 1], ':') && identifier(tokens[i - 2]) && symbol(tokens[i - 3], '?');
			// Enclosing postfix lookup cannot acquire the direct-constructor exception.
			const directMapValue =
				identifier(tokens[i], 'Map') &&
				symbol(tokens[i + 1], '(') &&
				(arrayValue || ternaryValue) &&
				brackets.every(arrayLiteralOpen);
			if (
				!symbol(tokens[i + 1], '(') ||
				(['.', ':', '['].includes(tokens[i - 1]?.value) && !directMapValue)
			)
				return false;
			const end = close(i + 1, '(', ')');
			if (symbol(tokens[end + 1], '{')) return false;
		}
		const reader = (list) => {
			let at = 0;
			return {
				peek: () => list[at],
				done: () => at === list.length,
				take: (fragment) => {
					const wanted = scriptTokens(fragment, '.ahk');
					if (!wanted.every((t, i) => sameToken(list[at + i], t)))
						throw Error('Unsupported model authority grammar');
					at += wanted.length;
				},
				name: () => {
					if (!identifier(list[at])) throw Error('Model binding identifier required');
					return list[at++].value;
				},
				line: () => {
					const t = list[at];
					if (!t || source.slice(source.lastIndexOf('\n', t.start - 1) + 1, t.start).trim())
						throw Error('Physical model statement required');
				},
				error: () => {
					if (list[at]?.kind !== 'string' || !list[at].value)
						throw Error('Actual refusal required');
					at++;
				}
			};
		};
		const h = reader(helper.parameters),
			params = [];
		for (let i = 0; i < 5; i++) {
			params.push(h.name());
			if (i < 4) h.take(',');
		}
		if (!h.done() || new Set(params.map((n) => n.toLowerCase())).size !== 5) return false;
		const [receive, child, health, caption, disabled] = params;
		const reserved = new Set([
			...callableNames,
			'map',
			'error',
			'global',
			'local',
			'static',
			'return',
			'if',
			'true',
			'false',
			'_llm_menu',
			'_llm_menu_handle',
			'class',
			'try',
			'catch',
			'finally',
			'else',
			'switch',
			'case',
			'default',
			'loop',
			'for',
			'while',
			'until',
			'break',
			'continue',
			'throw',
			'this',
			'super',
			'unset',
			'is',
			'not',
			'and',
			'or',
			'extends'
		]);
		if (params.some((n) => reserved.has(n.toLowerCase()))) return false;
		const body = reader(helper.body);
		const refusal = (condition) => {
			body.line();
			body.take('if ' + condition);
			body.line();
			body.take('throw Error(');
			body.error();
			body.take(')');
		};
		refusal('!_MR_DeclaredParentCallable(' + receive + ')');
		body.line();
		const getters = body.name();
		if (
			reserved.has(getters.toLowerCase()) ||
			params.some((n) => n.toLowerCase() === getters.toLowerCase())
		)
			return false;
		body.take(':= Map(');
		const wantedGetters = new Map([
			['llm_model_health_prefix', health],
			['llm_model_current_caption', caption],
			['llm_model_parent_ready', '!' + disabled]
		]);
		for (let i = 0; i < 3; i++) {
			const key = body.peek();
			if (key?.kind !== 'string' || !wantedGetters.has(key.value)) return false;
			body.take(JSON.stringify(key.value) + ', (*) => ' + wantedGetters.get(key.value));
			wantedGetters.delete(key.value);
			if (i < 2) body.take(',');
		}
		body.take(')');
		body.line();
		const parent = body.name();
		if (
			reserved.has(parent.toLowerCase()) ||
			[getters, ...params].some((n) => n.toLowerCase() === parent.toLowerCase())
		)
			return false;
		body.take(':= ' + receive + '.Call(' + child + ', ' + getters + ')');
		refusal('!(' + parent + ' is Map) || ' + parent + '.Get("submenu", false) != ' + child);
		body.line();
		body.take('return [' + parent + ']');
		if (!body.done()) return false;
		const signature = scriptTokens(
			'id, disabled, llm_is_operational, has_health_dot := false, CapturedWarningRows := unset',
			'.ahk'
		);
		if (
			emit.parameters.length !== signature.length ||
			!signature.every((t, i) => sameToken(emit.parameters[i], t))
		)
			return false;
		const e = reader(emit.body);
		e.line();
		e.take('global _LLM_Menu, _LLM_Menu_Handle');
		e.line();
		e.take('switch id {');
		let depth = 0;
		const branches = [],
			claims = [];
		for (let i = 0; i < emit.body.length; i++) {
			const t = emit.body[i];
			if (symbol(t, '{')) depth++;
			if (symbol(t, '}')) depth--;
			if (depth !== 1 || !identifier(t) || !['case', 'default'].includes(t.value.toLowerCase()))
				continue;
			if (source.slice(source.lastIndexOf('\n', t.start - 1) + 1, t.start).trim()) return false;
			let end = i + 1;
			const selectors = [];
			if (identifier(t, 'case')) {
				// AHK switch matches strings without case sensitivity unless requested otherwise.
				// Unknown expressions could claim this id or mutate authority before its case.
				for (;;) {
					if (emit.body[end]?.kind !== 'string' || !emit.body[end].value) return false;
					selectors.push(emit.body[end++].value);
					if (!symbol(emit.body[end], ',')) break;
					end++;
				}
			}
			if (!symbol(emit.body[end], ':')) return false;
			const branch = { index: i, body: end + 1, selectors, default: identifier(t, 'default') };
			branches.push(branch);
			for (const selector of selectors)
				if (selector.toLowerCase() === 'llm_model') claims.push(branch);
		}
		if (
			branches.filter((b) => b.default).length !== 1 ||
			claims.length !== 1 ||
			claims[0].selectors.length !== 1 ||
			claims[0].selectors[0] !== 'llm_model'
		)
			return false;
		const selected = claims[0].body,
			end = branches[branches.indexOf(claims[0]) + 1]?.index;
		if (end === undefined) return false;
		// The case grammar is finite; unexpected statements cannot hide a binding write.
		const stage = reader(emit.body.slice(selected, end));
		const stageNames = [];
		const binding = () => {
			stage.line();
			const name = stage.name();
			if (
				reserved.has(name.toLowerCase()) ||
				stageNames.some((n) => n.toLowerCase() === name.toLowerCase()) ||
				['id', 'disabled', 'llm_is_operational', 'has_health_dot', 'capturedwarningrows'].includes(
					name.toLowerCase()
				)
			)
				throw Error('Fresh model stage binding required');
			stageNames.push(name);
			stage.take(':=');
			return name;
		};
		const capturedReceiver = binding();
		stage.take('MenuRenderer_GroupReceiver("llm_model_parent_ahk", "llm_model")');
		stage.line();
		stage.take('if !' + capturedReceiver);
		stage.line();
		stage.take('throw Error(');
		stage.error();
		stage.take(')');
		const completedChild = binding();
		stage.take('LLM_Menu_BuildModelMenu()');
		stage.line();
		stage.take('try {');
		stage.line();
		stage.take('_LLM_Menu_FireHealthProbe(true)');
		stage.line();
		stage.take('_LLM_Menu_FireInstalledTagsProbe()');
		const status = binding();
		stage.take('_LLM_Menu.Has("last_health_status") ? _LLM_Menu["last_health_status"] : ""');
		const prefix = binding();
		stage.take(
			'(has_health_dot && llm_is_operational) ? ((' +
				status +
				' == "ok") ? "🟢 " : (' +
				status +
				' == "ko") ? "🔴 " : "") : ""'
		);
		const shown = binding();
		stage.take('_LLM_Menu_ModelDisplayText()');
		const returnedRows = binding();
		stage.take(
			'_LLM_Menu_ModelParentRows(' +
				capturedReceiver +
				', ' +
				completedChild +
				', ' +
				prefix +
				', ' +
				shown +
				', disabled)'
		);
		stage.line();
		stage.take(
			'MenuRenderer_AppendRows(_LLM_Menu_Handle, "llm_menu", "llm_model_parent_ahk", ' +
				returnedRows +
				')'
		);
		stage.take('} catch as Err {');
		const localNames = new Set([getters, parent, ...stageNames].map((n) => n.toLowerCase()));
		for (let i = 0; i < tokens.length; i++) {
			if (levels[i] !== 0 || !identifier(tokens[i])) continue;
			if (localNames.has(tokens[i].value.toLowerCase()) && symbol(tokens[i + 1], ':='))
				return false;
			if (!identifier(tokens[i], 'global')) continue;
			for (let j = i + 1; j < tokens.length; j++) {
				if (
					j > i + 1 &&
					source.slice(tokens[j - 1].end, tokens[j].start).includes('\n') &&
					!symbol(tokens[j - 1], ',')
				)
					break;
				if (identifier(tokens[j]) && localNames.has(tokens[j].value.toLowerCase())) return false;
			}
		}
		return true;
	} catch {
		return false;
	}
}

/** Credits only one independently pinned selected group in its real native owner. */
function publishesSelectedMenuGroup(source, extension, section, definition, proof) {
	if (
		extension !== '.ahk' ||
		!proof ||
		!Array.isArray(definition) ||
		definition.length !== 1 ||
		!require('node:util').isDeepStrictEqual(definition, [proof.row]) ||
		proof.row?.type !== 'group' ||
		typeof proof.row.id !== 'string' ||
		proof.row.id === ''
	)
		return false;
	const loopSource = fs.readFileSync(
		path.join(__dirname, '../test/test-ahk-loop-capture.cjs'),
		'utf8'
	);
	const start = loopSource.indexOf('function codeLines(src) {'),
		end = loopSource.indexOf('/**', start);
	if (start < 0 || end <= start) return false;
	const codeLines = require('node:vm').runInNewContext(
		loopSource.slice(start, end) + '\ncodeLines'
	);
	const executable = (text) => {
		const lines = codeLines(text);
		return scriptTokens(text, '.ahk').filter((token) => {
			if (token.kind === 'string')
				return text.slice(token.start, token.end) === JSON.stringify(token.value);
			const line = text.slice(0, token.start).split('\n').length - 1;
			const column = token.start - text.lastIndexOf('\n', token.start - 1) - 1;
			return lines[line]?.slice(column, column + token.value.length) === token.value;
		});
	};
	if (proof.transport !== undefined)
		return retainedModelGroupPublication(source, section, definition, proof, executable);
	const matches = (tokens, at, wanted) =>
		wanted.every(
			(token, offset) =>
				tokens[at + offset]?.kind === token.kind && tokens[at + offset]?.value === token.value
		);
	const tokens = executable(source),
		signature = scriptTokens(proof.owner_signature, '.ahk'),
		bodies = [];
	for (let at = 0; at < tokens.length; at++) {
		if (
			!matches(tokens, at, signature) ||
			source.slice(source.lastIndexOf('\n', tokens[at].start - 1) + 1, tokens[at].start).trim() !==
				''
		)
			continue;
		let depth = 1;
		for (let index = at + signature.length; index < tokens.length; index++) {
			if (tokens[index].kind !== 'symbol') continue;
			if (tokens[index].value === '{') depth++;
			if (tokens[index].value === '}') depth--;
			if (!depth) {
				bodies.push(source.slice(tokens[at + signature.length - 1].end, tokens[index].start));
				break;
			}
		}
	}
	if (bodies.length !== 1 || !bodies[0].trim()) return false;
	const body = executable(bodies[0]);
	const call = scriptTokens(proof.call, '.ahk');
	// The authored source proof must actually name this selected physical row.
	const method = call.findIndex(
		(token) => token.kind === 'identifier' && token.value === 'MenuRenderer_GroupRow'
	);
	if (
		method < 0 ||
		call[method + 1]?.value !== '(' ||
		call[method + 2]?.kind !== 'string' ||
		call[method + 2].value !== section ||
		call[method + 3]?.value !== ',' ||
		call[method + 4]?.kind !== 'string' ||
		call[method + 4].value !== proof.row.id
	)
		return false;
	let previous = -1;
	for (const statement of [proof.call, proof.handoff, proof.consumer]) {
		const wanted = scriptTokens(statement, '.ahk'),
			positions = [];
		for (let index = 0; index < body.length; index++) {
			if (matches(body, index, wanted) && !['.', ':'].includes(body[index - 1]?.value))
				positions.push(index);
		}
		if (positions.length !== 1 || positions[0] <= previous) return false;
		previous = positions[0];
	}
	return true;
}

module.exports = {
	delegatedMenuSources,
	combineMenuVisibility,
	publishesMenuTemplate,
	publishesSelectedMenuGroup
};
