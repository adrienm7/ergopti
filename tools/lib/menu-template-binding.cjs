// tools/lib/menu-template-binding.cjs

'use strict';
const { scriptTokens } = require('./script-source.cjs');
const { publishesMenuTemplate } = require('./menu-shared-delegation.cjs');

/** Necessary typed command/list port evidence, never live publication authority. */
function nativeTemplateBinding(
	source,
	extension,
	section,
	key,
	port,
	nativeSources = [{ src: source }],
	menuManifest,
	platform,
	buildOwner
) {
	const ahk = extension === '.ahk',
		tokens = scriptTokens(source, extension);
	const retainedPersonalInfo =
		!ahk && section === 'personal_info_editor_frame'
			? require('./menu-native-personal-info-binding.cjs').retainedPersonalInfoTemplateCallOffset(
					source,
					platform
				)
			: -1;
	if (
		!ahk &&
		section === 'personal_info_editor_frame' &&
		(retainedPersonalInfo < 0 || key !== 'personal_info_editor_open' || port !== 1)
	)
		return false;
	const retainedDownload =
		!ahk && section === 'llm_download_shortcut_frame'
			? require('./menu-native-download-binding.cjs').retainedNativeDownloadTemplateCallOffset(
					source
				)
			: -1;
	const sameName = (a, b) => (ahk ? a.toLowerCase() === b.toLowerCase() : a === b);
	const id = (i, v) =>
		tokens[i]?.kind === 'identifier' && (v === undefined || sameName(tokens[i].value, v));
	const sym = (i, v) => tokens[i]?.kind === 'symbol' && tokens[i].value === v;
	const bare = (i) => !['.', ':'].includes(tokens[i - 1]?.value);
	const literal = (i) => {
		if (tokens[i]?.kind !== 'string') return false;
		const raw = source.slice(tokens[i].start, tokens[i].end);
		return ['"', "'"].includes(raw[0]) && raw.at(-1) === raw[0] && !raw.includes(ahk ? '`' : '\\');
	};
	function close(at) {
		const pair = { '(': ')', '[': ']', '{': '}' },
			stack = [];
		for (let i = at; i < tokens.length; i++) {
			if (tokens[i].kind !== 'symbol') continue;
			if (pair[tokens[i].value]) stack.push(pair[tokens[i].value]);
			else if ([')', ']', '}'].includes(tokens[i].value)) {
				if (stack.pop() !== tokens[i].value) return -1;
				if (!stack.length) return i;
			}
		}
		return -1;
	}
	const scopes = [],
		stack = [],
		functions = [];
	let serial = 0;
	if (!ahk)
		for (let i = 0; i < tokens.length; i++) {
			scopes[i] = stack.slice();
			if (tokens[i].kind !== 'identifier') continue;
			const word = tokens[i].value;
			if (word === 'else' || word === 'elseif') stack.pop();
			if (['function', 'do', 'then', 'repeat', 'else'].includes(word)) stack.push(++serial);
			if (word === 'end' || word === 'until') stack.pop();
		}
	for (let i = 0; i < tokens.length; i++) {
		if (ahk) {
			if (
				!id(i) ||
				['if', 'while', 'for', 'switch', 'catch'].includes(tokens[i].value) ||
				!bare(i) ||
				!sym(i + 1, '(') ||
				source.slice(source.lastIndexOf('\n', tokens[i].start - 1) + 1, tokens[i].start).trim() !==
					''
			)
				continue;
			const p = close(i + 1);
			if (p < 0 || !sym(p + 1, '{')) continue;
			const end = close(p + 1);
			if (end < 0) continue;
			functions.push({
				name: tokens[i].value,
				start: i,
				body: p + 2,
				end,
				params: [i + 2, p],
				scope: []
			});
		} else if (id(i, 'function')) {
			let p = i + 1;
			while (p < i + 6 && p < tokens.length && !sym(p, '(')) p++;
			if (!sym(p, '(')) continue;
			const last = close(p);
			if (last < 0) continue;
			let depth = 1,
				end = last + 1;
			for (; end < tokens.length; end++) {
				if (tokens[end].kind !== 'identifier') continue;
				if (['function', 'do', 'then', 'repeat'].includes(tokens[end].value)) depth++;
				if (['end', 'until', 'elseif'].includes(tokens[end].value)) depth--;
				if (!depth) break;
			}
			if (depth) continue;
			let name, declared;
			if (id(i - 1, 'local') && id(i + 1) && p === i + 2) {
				name = tokens[i + 1].value;
				declared = i - 1;
			}
			if (id(i - 3, 'local') && id(i - 2) && sym(i - 1, '=')) {
				name = tokens[i - 2].value;
				declared = i - 3;
			}
			functions.push({
				name,
				start: i,
				declared,
				body: last + 1,
				end,
				params: [p + 1, last],
				scope: scopes[declared]
			});
		}
	}
	const ancestor = (a, b) => a && b && a.length <= b.length && a.every((v, i) => v === b[i]);
	const functionAt = (at) => functions.find((f) => f.start === at);
	function parts(start, end) {
		const out = [];
		let first = start;
		for (let i = start; i < end; i++) {
			if (!ahk && id(i, 'function')) {
				const f = functionAt(i);
				if (!f || f.end >= end) return null;
				i = f.end;
				continue;
			}
			if (tokens[i].kind === 'symbol' && ['(', '[', '{'].includes(tokens[i].value)) {
				i = close(i);
				if (i < 0 || i >= end) return null;
				continue;
			}
			if (sym(i, ',') || (!ahk && sym(i, ';'))) {
				out.push([first, i]);
				first = i + 1;
			}
		}
		if (first < end) out.push([first, end]);
		return out;
	}
	function dictionary(start, end) {
		const fields = [],
			keys = new Set();
		let list;
		if (ahk) {
			if (!id(start, 'Map') || !sym(start + 1, '(') || close(start + 1) !== end - 1) return null;
			list = parts(start + 2, end - 1);
			if (!list || list.length % 2) return null;
			for (let i = 0; i < list.length; i += 2) {
				const [a, z] = list[i];
				if (z !== a + 1 || !literal(a) || keys.has(tokens[a].value.toLowerCase())) return null;
				keys.add(tokens[a].value.toLowerCase());
				fields.push({ key: tokens[a].value, value: list[i + 1] });
			}
		} else {
			if (!sym(start, '{') || close(start) !== end - 1) return null;
			list = parts(start + 1, end - 1);
			if (!list) return null;
			for (const [a, z] of list) {
				let key, value;
				if (id(a) && sym(a + 1, '=')) {
					key = tokens[a].value;
					value = a + 2;
				} else if (sym(a, '[') && literal(a + 1) && sym(a + 2, ']') && sym(a + 3, '=')) {
					key = tokens[a + 1].value;
					value = a + 4;
				} else return null;
				if (keys.has(key) || value >= z) return null;
				keys.add(key);
				fields.push({ key, value: [value, z] });
			}
		}
		return fields;
	}
	function withdrawn(fn, call) {
		const name = fn.name;
		for (let i = fn.body; i < call; i++) {
			if (!id(i)) continue;
			if (
				(!ahk && id(i, 'local')) ||
				(ahk && ['local', 'global'].includes(tokens[i].value.toLowerCase()))
			) {
				let c = i + 1;
				if (id(c, 'function')) c++;
				while (id(c)) {
					if (id(c, name)) return true;
					if (!sym(c + 1, ',')) break;
					c += 2;
				}
			}

			if (!id(i, name) || !bare(i)) continue;
			let c = i + 1;
			while (sym(c, ',') && id(c + 1)) c += 2;
			if (sym(c, ahk ? ':=' : '=')) return true;
		}
		for (const f of functions) {
			if (f.start <= fn.start || f.start >= call) continue;
			for (let i = f.params[0]; i < f.params[1]; i++) if (id(i, name)) return true;
		}
		return false;
	}
	function reference(name, call) {
		if (ahk) {
			const declarations = [];
			for (const native of nativeSources) {
				if (!native.src.toLowerCase().includes(name.toLowerCase())) continue;
				const t = scriptTokens(native.src, '.ahk');
				let braces = 0;
				for (let j = 0; j < t.length; j++) {
					if (t[j].kind === 'symbol' && t[j].value === '{') {
						braces++;
						continue;
					}
					if (t[j].kind === 'symbol' && t[j].value === '}') {
						braces--;
						continue;
					}
					if (
						t[j].kind === 'identifier' &&
						t[j].value.toLowerCase() === name.toLowerCase() &&
						!['.', ':'].includes(t[j - 1]?.value) &&
						t[j + 1]?.value === ':='
					)
						return false;
					if (braces !== 0) continue;
					if (
						t[j].kind !== 'identifier' ||
						t[j].value.toLowerCase() !== name.toLowerCase() ||
						t[j + 1]?.value !== '(' ||
						['.', ':'].includes(t[j - 1]?.value) ||
						native.src
							.slice(native.src.lastIndexOf('\n', t[j].start - 1) + 1, t[j].start)
							.trim() !== ''
					)
						continue;
					let c = j + 1,
						depth = 0;
					for (; c < t.length; c++) {
						if (t[c].kind === 'symbol' && t[c].value === '(') depth++;
						if (t[c].kind === 'symbol' && t[c].value === ')' && !--depth) break;
					}
					if (t[c + 1]?.value === '{' && t[c + 2]?.value !== '}') {
						let b = c + 1,
							depth = 0;
						for (; b < t.length; b++) {
							if (t[b].kind !== 'symbol') continue;
							if (t[b].value === '{') depth++;
							if (t[b].value === '}' && !--depth) break;
						}
						if (b < t.length) declarations.push(t[j]);
					}
				}
			}
			if (declarations.length !== 1) return false;
			const owner = functions
				.filter((f) => f.body <= call && call < f.end)
				.sort((a, b) => b.body - a.body)[0];
			if (owner)
				for (let i = owner.params[0]; i < owner.params[1]; i++) if (id(i, name)) return false;
			return !owner || !withdrawn({ ...owner, name }, call);
		}
		const candidates = functions.filter(
			(f) => f.name === name && f.end < call && ancestor(f.scope, scopes[call])
		);
		return (
			candidates.length === 1 &&
			candidates[0].body < candidates[0].end &&
			!withdrawn(candidates[0], call)
		);
	}
	function callable([a, z], call) {
		if (!ahk && id(a, 'function')) {
			const f = functionAt(a);
			return !!f && f.end === z - 1 && f.body < f.end;
		}
		if (ahk && sym(a, '(')) {
			const c = close(a);
			return c > a && sym(c + 1, '=') && sym(c + 2, '>') && c + 3 < z;
		}
		return z === a + 1 && id(a) && reference(tokens[a].value, call);
	}
	// Only a declared, platform-visible include graph can share the root's ports.
	// A cyclic or incomplete graph cannot be rendered and supplies no evidence.
	function includesSection(root) {
		if (menuManifest === undefined) return root === section;
		if (!['ahk', 'hs', 'linux'].includes(platform)) return false;
		const visiting = new Set(),
			seen = new Set();
		let valid = true;
		function visit(name) {
			if (visiting.has(name) || !Array.isArray(menuManifest?.[name])) {
				valid = false;
				return;
			}
			if (seen.has(name)) return;
			visiting.add(name);
			seen.add(name);
			for (const row of menuManifest[name]) {
				if (row?.type !== 'include') continue;
				if (Array.isArray(row.platforms) && !row.platforms.includes(platform)) continue;
				if (typeof row.section !== 'string' || row.section === '') {
					valid = false;
					continue;
				}
				visit(row.section);
			}
			visiting.delete(name);
		}
		visit(root);
		return valid && seen.has(section);
	}
	for (let i = 0; i < tokens.length; i++) {
		let open;
		if (
			!ahk &&
			section !== 'personal_info_editor_frame' &&
			id(i, 'ManifestMenu') &&
			bare(i) &&
			sym(i + 1, '.') &&
			id(i + 2, 'template_rows') &&
			sym(i + 3, '(')
		)
			open = i + 3;
		if (
			retainedPersonalInfo >= 0 &&
			tokens[i]?.start === retainedPersonalInfo &&
			id(i, 'template') &&
			bare(i) &&
			sym(i + 1, '(')
		)
			open = i + 1;
		if (
			retainedDownload >= 0 &&
			tokens[i]?.start === retainedDownload &&
			id(i, 'template_owner') &&
			bare(i) &&
			sym(i + 1, '(')
		)
			open = i + 1;
		if (!buildOwner && ahk && id(i, 'MenuRenderer_TemplateRows') && bare(i) && sym(i + 1, '('))
			open = i + 1;
		if (buildOwner && ahk && id(i, 'MenuRenderer_Build') && bare(i) && sym(i + 1, '('))
			open = i + 1;
		if (open === undefined || tokens[i - 1]?.value === 'function') continue;
		const end = close(open);
		if (end < 0) continue;
		const args = parts(open + 1, end);
		if (buildOwner) {
			if (!ahk || platform !== 'ahk' || ![1, 2].includes(port)) continue;
			const owners = functions.filter((fn) => sameName(fn.name, buildOwner));
			const owner = owners[0];
			if (
				owners.length !== 1 ||
				owner.params[0] !== owner.params[1] ||
				owner.body + 1 !== i ||
				!id(owner.body, 'return') ||
				end + 1 !== owner.end ||
				!reference('MenuRenderer_Build', i)
			)
				continue;
			let depth = 0;
			for (let at = 0; at < owner.start; at++) {
				if (sym(at, '{')) depth++;
				if (sym(at, '}')) depth--;
			}
			if (depth !== 0) continue;
			const rows = menuManifest?.[section];
			if (!Array.isArray(rows)) continue;
			const visible = rows.filter((row) => !row.platforms || row.platforms.includes('ahk'));
			const selected = visible.filter((row) =>
				port === 1 ? row.id === key : row.caption_getter === key
			);
			if (
				selected.length !== 1 ||
				selected[0].type !== 'command' ||
				visible.filter((row) => row.id === selected[0].id).length !== 1
			)
				continue;
		}
		if (
			!args ||
			args[0]?.[1] !== args[0]?.[0] + 1 ||
			!literal(args[0][0]) ||
			!includesSection(tokens[args[0][0]].value) ||
			(buildOwner
				? tokens[args[0][0]].value !== section
				: !publishesMenuTemplate(source, extension, tokens[args[0][0]].value))
		)
			continue;
		const arg = args[buildOwner ? port + 4 : port];
		if (!arg) continue;
		const fields = dictionary(...arg);
		if (fields?.some((f) => f.key === key && callable(f.value, i))) return true;
	}
	return false;
}

/** Necessary typed ports of an actual returned Windows Build, never native execution proof. */
function nativeBuildCommandBinding(source, owner, section, key, port, nativeSources, menuManifest) {
	if (typeof owner !== 'string' || owner === '') return false;
	return nativeTemplateBinding(
		source,
		'.ahk',
		section,
		key,
		port,
		nativeSources,
		menuManifest,
		'ahk',
		owner
	);
}

module.exports = { nativeTemplateBinding, nativeBuildCommandBinding };
