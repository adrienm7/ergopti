// tools/test/test-menu-category-coverage.cjs

/**
 * ==============================================================================
 * MODULE: Every Declared Menu, Answered By Every Driver That Shows It
 * DESCRIPTION:
 * The per-category answer to "is the menu centralised": for each `*_menu` key in
 * the shared manifest, how many rows each platform projects, and whether the
 * driver names every id it is expected to dispatch.
 *
 * WHAT IT PROVES, category by category — shortcuts, hotstrings, tap-holds,
 * metrics, gestures, layout, IA, debug, updates, apps, Karabiner and the
 * tray root — is that the manifest describes the menu and each driver answers
 * only ids the manifest names. A row a driver draws from nothing would not be
 * declared; a row declared and unanswered renders one item short, permanently.
 *
 * ONE MECHANISM IS NOT A FAILURE, and it is why this file exists rather than a
 * simple "every id appears in every driver": `platforms` restricts a row to the
 * drivers that have the capability, which is what makes "one menu with
 * driver-specific items" expressible at all. A restricted row carries a
 * `reason_key`; test-menu-parity.cjs holds that.
 *
 * A `toggle` is NOT exempt. This gate used to treat it as opt-in per driver, on
 * the premise that an hs.menubar parent can be clicked and so carries the switch
 * itself. It cannot — AppKit never sends the action of an item that opens a
 * submenu — and that premise left Gestures, Shortcuts, Metrics and the Hotstrings
 * master impossible to switch on from the macOS menu bar. A switch shown on a
 * driver is answered like any other row; test-menu-toggle-registered.cjs checks
 * the registration itself.
 *
 * The table is printed on success too: "which categories does each driver draw,
 * and how many rows" is the question this was written to answer, and an
 * unreadable answer is one nobody checks.
 * ==============================================================================
 */

'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const {
	delegatedMenuSources,
	publishesMenuTemplate
} = require('../lib/menu-shared-delegation.cjs');

const { scriptTokens } = require('../lib/script-source.cjs');

const { validateChildTemplates } = require('../lib/menu-row-availability.cjs');

// Independent native count-format controls call the genuine exported compiler validator.
{
	const row = {
		type: 'group',
		id: 'native_count_parent',
		caption_source: 'native',
		caption_getter: 'native_name',
		caption_count_getter: 'native_count',
		caption_count_format: '%s (%s)',
		unavailable: 'hide'
	};
	const vectors = [
		['%s (%s)', true],
		['%s (%s) %%s', true],
		['%%%s (%s)', true],
		['%s %%s', false],
		['%%s', false],
		['%s', false],
		['%s %s %s', false],
		['%s (%q)', false],
		['%s (%s) %', false]
	];
	for (const [format, admitted] of vectors) {
		const validate = () =>
			validateChildTemplates({
				count_frame: [
					{
						...row,
						caption_count_format: format
					}
				]
			});
		if (admitted) assert.doesNotThrow(validate, format);
		else assert.throws(validate, /two ordered scalar slots/, format);
	}
	console.log('[OK] 9 independent native count-format validator controls.');
}

const { nativeTemplateBinding } = require('../lib/menu-template-binding.cjs');

const { nativeLayoutRowOwnership } = require('../lib/menu-native-layout-binding.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const manifest = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json'), 'utf8')
);

const EXT = { ahk: '.ahk', hs: '.lua', linux: '.lua' };
const DIR = { ahk: 'windows', hs: 'macos', linux: 'linux' };

function driverSource(driver) {
	const out = [],
		nativeSources = [];
	(function walk(d) {
		if (!fs.existsSync(d)) return;
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const p = path.join(d, e.name);
			if (e.isDirectory()) {
				if (!['tests', 'vendor', 'node_modules', '_generated'].includes(e.name)) walk(p);
			} else if (p.endsWith(EXT[driver])) {
				const src = fs.readFileSync(p, 'utf8');
				out.push(src);
				nativeSources.push({ rel: p, src });
			}
		}
	})(path.join(SP, DIR[driver]));
	return {
		nativeSources,
		text: out
			.concat(
				delegatedMenuSources(nativeSources, path.join(SP, '_shared', 'lua')).map(
					(source) => source.src
				)
			)
			.join('\n')
	};
}

const src = Object.fromEntries(['ahk', 'hs', 'linux'].map((d) => [d, driverSource(d)]));
const PLATFORMS = ['ahk', 'hs', 'linux'];
const visible = (row, p) => !Array.isArray(row.platforms) || row.platforms.includes(p);

/** Inert provider identities need a reached template, rather than a handler. */
function inertTemplateRow(row, captionFormat) {
	if (
		['label', 'section_header'].includes(row?.type) &&
		Object.hasOwn(row, 'caption_getter') &&
		typeof captionFormat === 'function'
	) {
		try {
			validateChildTemplates({ inert_caption: [row] }, captionFormat);
			return true;
		} catch {
			return false;
		}
	}
	return (
		['label', 'section_header'].includes(row.type) &&
		typeof row.id === 'string' &&
		row.id !== '' &&
		typeof row.i18n === 'string' &&
		row.i18n !== '' &&
		Object.keys(row).every((key) =>
			['type', 'id', 'i18n', 'platforms', 'unavailable'].includes(key)
		)
	);
}

/** Necessary lexical getter-port evidence, not live publication authority. */
function nativeCaptionBinding(source, extension, root, getter) {
	const t = scriptTokens(source, extension),
		ahk = extension === '.ahk';
	const id = (i, value) =>
		t[i]?.kind === 'identifier' && (value === undefined || t[i].value === value);
	const sym = (i, value) => t[i]?.kind === 'symbol' && t[i].value === value;
	const bare = (i) => !['.', ':'].includes(t[i - 1]?.value);
	const plainKey = (i) => {
		if (t[i]?.kind !== 'string') return false;
		const spelling = source.slice(t[i].start, t[i].end);
		return (
			['"', "'"].includes(spelling[0]) &&
			spelling.at(-1) === spelling[0] &&
			!spelling.includes(ahk ? '`' : '\\')
		);
	};
	const seq = (at, wanted) =>
		wanted.every((v, n) => t[at + n]?.value === v && t[at + n]?.kind !== 'string');
	function close(at) {
		const pair = { '(': ')', '{': '}', '[': ']' },
			stack = [];
		if (!pair[t[at]?.value]) return -1;
		for (let i = at; i < t.length; i++) {
			if (t[i].kind !== 'symbol') continue;
			if (pair[t[i].value]) stack.push(pair[t[i].value]);
			else if ([')', ']', '}'].includes(t[i].value)) {
				if (stack.pop() !== t[i].value) return -1;
				if (!stack.length) return i;
			}
		}
		return -1;
	}
	function args(at, end) {
		const result = [];
		let start = at,
			lua = 0;
		for (let i = at; i < end; i++) {
			if (t[i].kind === 'symbol' && ['(', '{', '['].includes(t[i].value)) {
				i = close(i);
				if (i < 0 || i >= end) return [];
				continue;
			}
			if (!ahk && t[i].kind === 'identifier') {
				if (['function', 'do', 'then', 'repeat'].includes(t[i].value)) lua++;
				if (['end', 'until'].includes(t[i].value)) lua--;
			}
			if (sym(i, ',') && lua === 0) {
				result.push([start, i]);
				start = i + 1;
			}
		}
		if (lua !== 0) return [];
		if (start < end) result.push([start, end]);
		return result;
	}
	const functions = [];
	for (let i = 0; i < t.length; i++) {
		if (ahk) {
			if (
				!id(i) ||
				['if', 'while', 'for', 'switch', 'catch'].includes(t[i].value) ||
				!bare(i) ||
				!sym(i + 1, '(') ||
				source.slice(source.lastIndexOf('\n', t[i].start - 1) + 1, t[i].start).trim() !== ''
			)
				continue;
			const end = close(i + 1);
			if (end < 0 || !sym(end + 1, '{')) continue;
			const tail = close(end + 1);
			if (tail < 0) continue;
			functions.push({
				name: t[i].value,
				start: i,
				params: [i + 2, end],
				body: end + 2,
				end: tail
			});
		} else if (id(i, 'function')) {
			let p = i + 1;
			while (p < t.length && !sym(p, '(') && p < i + 6) p++;
			if (!sym(p, '(')) continue;
			const e = close(p);
			if (e < 0) continue;
			let depth = 1,
				tail = e + 1;
			for (; tail < t.length; tail++) {
				if (t[tail].kind !== 'identifier') continue;
				if (['function', 'do', 'then', 'repeat'].includes(t[tail].value)) depth++;
				if (['end', 'until', 'elseif'].includes(t[tail].value)) depth--;
				if (depth === 0) break;
			}
			if (depth === 0)
				functions.push({
					name: id(i + 1) && p === i + 2 ? t[i + 1].value : undefined,
					start: i,
					params: [p + 1, e],
					body: e + 1,
					end: tail
				});
		}
	}
	const containing = (at) =>
		functions.filter((f) => f.body <= at && at < f.end).sort((a, b) => b.body - a.body)[0];
	function factory(name) {
		const found = functions.filter((f) => f.name === name);
		if (found.length !== 1) return false;
		for (let j = 0; j < t.length; j++) {
			if (id(j, name) && bare(j) && sym(j + 1, ahk ? ':=' : '=')) return false;
			if (!ahk && id(j - 1, 'local') && id(j, name)) return false;
		}
		const f = found[0];
		if (f.params[1] !== f.params[0] + 1 || !id(f.params[0])) return false;
		const frame = t[f.params[0]].value,
			b = f.body;
		if (ahk) {
			if (
				!id(b) ||
				!seq(b + 1, [':=', 'Map', '(', ')', 'for']) ||
				!id(b + 6) ||
				!seq(b + 7, ['in', frame])
			)
				return false;
			const out = t[b].value,
				key = t[b + 6].value;
			if (
				!seq(b + 9, [out, '[', key, ']', ':=']) ||
				!id(b + 14) ||
				!seq(b + 15, ['.', 'Bind', '(', frame, ',', key, ')', 'return', out]) ||
				b + 24 !== f.end
			)
				return false;
			const lookup = functions.filter((g) => g.name === t[b + 14].value);
			if (lookup.length !== 1) return false;
			const g = lookup[0],
				pa = args(g.params[0], g.params[1]);
			return (
				pa.length === 2 &&
				pa.every(([a, z]) => z === a + 1 && id(a)) &&
				g.end === g.body + 5 &&
				seq(g.body, ['return', t[pa[0][0]].value, '[', t[pa[1][0]].value, ']'])
			);
		}
		if (
			!seq(b, ['local']) ||
			!id(b + 1) ||
			!seq(b + 2, ['=', '{', '}', 'for']) ||
			!id(b + 6) ||
			!sym(b + 7, ',') ||
			!id(b + 8) ||
			!seq(b + 9, ['in', 'pairs', '(', frame, ')', 'do', 'local']) ||
			!id(b + 16)
		)
			return false;
		const out = t[b + 1].value,
			key = t[b + 6].value,
			val = t[b + 8].value,
			captured = t[b + 16].value;
		return (
			seq(b + 17, [
				'=',
				val,
				out,
				'[',
				key,
				']',
				'=',
				'function',
				'(',
				')',
				'return',
				captured,
				'end',
				'end',
				'return',
				out
			]) && b + 33 === f.end
		);
	}
	// Inspect full literal fields; duplicates/computed aliases cannot establish a port.
	function fields(at, end) {
		const rows = [],
			keys = new Set();
		if (ahk) {
			if (!id(at, 'Map') || !sym(at + 1, '(') || close(at + 1) !== end - 1) return null;
			const parts = args(at + 2, end - 1);
			if (parts.length % 2) return null;
			for (let i = 0; i < parts.length; i += 2) {
				const [a, z] = parts[i];
				if (z !== a + 1 || !plainKey(a) || keys.has(t[a].value)) return null;
				keys.add(t[a].value);
				rows.push({ key: t[a].value, value: parts[i + 1] });
			}
		} else {
			if (!sym(at, '{') || close(at) !== end - 1) return null;
			let cursor = at + 1;
			while (cursor < end - 1) {
				let key;
				if (id(cursor) && sym(cursor + 1, '=')) {
					key = t[cursor].value;
					cursor += 2;
				} else if (
					sym(cursor, '[') &&
					plainKey(cursor + 1) &&
					sym(cursor + 2, ']') &&
					sym(cursor + 3, '=')
				) {
					key = t[cursor + 1].value;
					cursor += 4;
				} else return null;
				if (keys.has(key)) return null;
				keys.add(key);
				const start = cursor;
				let depth = 0;
				for (; cursor < end - 1; cursor++) {
					if (t[cursor].kind === 'symbol' && ['(', '{', '['].includes(t[cursor].value)) {
						cursor = close(cursor);
						if (cursor < 0) return null;
						continue;
					}
					if (t[cursor].kind === 'identifier') {
						if (['function', 'do', 'then', 'repeat'].includes(t[cursor].value)) depth++;
						if (['end', 'until'].includes(t[cursor].value)) depth--;
					}
					if (depth === 0 && (sym(cursor, ',') || sym(cursor, ';'))) break;
				}
				if (depth !== 0 || cursor === start) return null;
				rows.push({ key, value: [start, cursor] });
				cursor++;
			}
		}
		return rows;
	}
	function callable([a, z]) {
		if (ahk) {
			const end = close(a);
			return sym(a, '(') && end > a && seq(end + 1, ['=', '>']) && end + 3 < z;
		}
		return seq(a, ['function', '(', ')', 'return']) && t[z - 1]?.value === 'end' && z > a + 5;
	}
	function dictionary(at, end, key) {
		const f = fields(at, end);
		return !!f && f.some((row) => row.key === key && callable(row.value));
	}
	function variableLiteral(name, call, owner, key) {
		const found = [];
		for (let j = owner.body; j < call; j++) {
			if (!id(j, name) || !bare(j) || containing(j) !== owner || !sym(j + 1, ahk ? ':=' : '='))
				continue;
			const at = j + 2,
				last = ahk && id(at, 'Map') ? close(at + 1) : sym(at, '{') ? close(at) : -1;
			if (last < 0) return false;
			found.push({ at, end: last + 1 });
		}
		if (found.length !== 1) return false;
		for (let j = found[0].end; j < call; j++) {
			if (
				containing(j) === owner &&
				id(j, name) &&
				bare(j) &&
				['[', '.'].includes(t[j + 1]?.value)
			) {
				const e = sym(j + 1, '[') ? close(j + 1) : j + 2;
				if (e >= 0 && sym(e + 1, ahk ? ':=' : '=')) return false;
			}
			if (!ahk && id(j - 1, 'local') && id(j, name)) return false;
		}
		return dictionary(found[0].at, found[0].end, key);
	}
	function capturedField(name, call, owner, key) {
		let initial,
			bound = false;
		for (let j = owner.body; j < call; j++) {
			if (!id(j, name) || !bare(j) || containing(j) !== owner) continue;
			if (sym(j + 1, ahk ? ':=' : '=')) {
				if (
					!ahk &&
					!id(j - 1, 'local') &&
					(initial === undefined || ['{', ','].includes(t[j - 1]?.value))
				)
					continue;
				if (initial !== undefined) return false;
				const at = j + 2,
					end = ahk && id(at, 'Map') ? close(at + 1) : sym(at, '{') ? close(at) : -1;
				if (end < 0) return false;
				const f = fields(at, end + 1);
				if (!f) return false;
				initial = j;
				const row = f.find((row) => row.key === key);
				if (row) {
					if (['nil', 'false'].includes(t[row.value[0]]?.value)) return false;
					bound = true;
				}
			}
			if (sym(j + 1, '[')) {
				const e = close(j + 1);
				if (e > 0 && sym(e + 1, ahk ? ':=' : '=') && !(plainKey(j + 2) && e === j + 3))
					return false;
			}
			// Literal property assignment; Lua may assign several properties at once.
			const properties = [];
			let c = j;
			while (id(c, name) && bare(c)) {
				if (ahk && sym(c + 1, '[') && plainKey(c + 2) && sym(c + 3, ']')) {
					properties.push(t[c + 2].value);
					c += 4;
				} else if (!ahk && sym(c + 1, '.') && id(c + 2)) {
					properties.push(t[c + 2].value);
					c += 3;
				} else break;
				if (!sym(c, ',')) break;
				c++;
			}
			if (properties.length && sym(c, ahk ? ':=' : '=')) {
				if (initial === undefined) return false;
				if (properties.includes(key)) {
					let end = c + 1;
					const line = source.indexOf('\n', t[c].end);
					while (end < call && (line < 0 || t[end].start < line)) end++;
					const values = args(c + 1, end),
						value = values[properties.indexOf(key)];
					if (!value || ['nil', 'false'].includes(t[value[0]]?.value)) return false;
					bound = true;
				}
			}
			if (!ahk && id(j - 1, 'local') && initial !== undefined && j !== initial) return false;
		}
		return initial !== undefined && bound;
	}
	for (let i = 0; i < t.length; i++) {
		let at,
			rootArg = 0;
		if (!ahk && id(i, 'ManifestMenu') && bare(i) && seq(i + 1, ['.', 'template_rows', '(']))
			at = i + 3;
		if (
			ahk &&
			id(i) &&
			bare(i) &&
			['MenuRenderer_TemplateRows', 'MenuRenderer_AppendTemplate'].includes(t[i].value) &&
			sym(i + 1, '(')
		) {
			at = i + 1;
			if (t[i].value === 'MenuRenderer_AppendTemplate') rootArg = 1;
		}
		if (at === undefined) continue;
		const end = close(at);
		if (end < 0) continue;
		const a = args(at + 1, end);
		const r = a[rootArg];
		if (!r || r[1] !== r[0] + 1 || t[r[0]]?.kind !== 'string' || t[r[0]].value !== root) continue;
		const g = a[rootArg + 2];
		if (!g) continue;
		if (dictionary(g[0], g[1], getter)) return true;
		const owner = containing(i);
		if (!owner) continue;
		if (g[1] === g[0] + 1 && id(g[0]) && variableLiteral(t[g[0]].value, i, owner, getter))
			return true;
		if (
			g[1] === g[0] + 4 &&
			id(g[0]) &&
			bare(g[0]) &&
			sym(g[0] + 1, '(') &&
			id(g[0] + 2) &&
			sym(g[0] + 3, ')') &&
			factory(t[g[0]].value) &&
			capturedField(t[g[0] + 2].value, i, owner, getter)
		)
			return true;
	}
	return false;
}

// Caption context validates metadata; these controls independently demand a
// callable getter at the actual native port, not a string elsewhere in a file.
{
	const root = 'caption_fixture',
		key = 'actual_caption';
	const lua =
		'ManifestMenu.template_rows("caption_fixture", {}, { actual_caption = function() return native_value end }, {})';
	assert.equal(nativeCaptionBinding(lua, '.lua', root, key), true);
	for (const changed of [
		'-- ' + lua,
		JSON.stringify(lua),
		'Foreign.' + lua,
		lua.replace('actual_caption = function', 'other_caption = function'),
		lua.replace('function() return native_value end', '"not_callable"'),
		lua.replace('native_value end', 'native_value end, actual_caption = nil'),
		lua.replace('native_value end', 'native_value end, [chosen] = nil'),
		lua.replace('native_value end', String.raw`native_value end, ["actual_\099aption"] = nil`),
		lua.replace('actual_caption = function', '[ [=[actual_caption]=] ] = function')
	])
		assert.equal(nativeCaptionBinding(changed, '.lua', root, key), false);
	const ahk =
		'ActualOwner() {\n State := Map("actual_caption", (*) => native_value)\n MenuRenderer_TemplateRows("caption_fixture", Map(), State, Map())\n}';
	assert.equal(nativeCaptionBinding(ahk, '.ahk', root, key), true);
	for (const changed of [
		ahk.replace('"actual_caption",', '"other_caption",'),
		ahk.replace('(*) => native_value', '"not_callable"'),
		ahk.replace('native_value)', 'native_value, "actual_caption", false)'),
		ahk.replace(' MenuRenderer_', ' State["actual_caption"] := false\n MenuRenderer_'),
		ahk.replace(' State :=', ' Foreign.State :=')
	])
		assert.equal(nativeCaptionBinding(changed, '.ahk', root, key), false);
	const native = fs.readFileSync(path.join(SP, 'windows/ui/menu/menu_llm/menu_models.ahk'), 'utf8');
	assert.equal(
		nativeCaptionBinding(native, '.ahk', 'llm_model_identity_rows', 'model_backend_caption'),
		true
	);
	for (const changed of [
		native.replace(
			'Frame := Map("model_backend_caption",',
			'Frame := Map("withdrawn_model_backend_caption",'
		),
		native.replace(
			'Frame := Map("model_backend_caption",',
			'Foreign.Frame := Map("model_backend_caption",'
		),
		native.replace('_LLM_Menu_ModelFrameValue.Bind(Frame, Key)', '"not_callable"'),
		native.replace('return Frame[Key]', 'return false'),
		native.replace('return Getters', 'return Map()'),
		native.replace('IdentityRows :=', 'Frame["model_backend_caption"] := false\n IdentityRows :='),
		native.replace('IdentityRows :=', 'Frame[chosen] := false\n IdentityRows :=')
	])
		assert.equal(
			nativeCaptionBinding(changed, '.ahk', 'llm_model_identity_rows', 'model_backend_caption'),
			false
		);
	const mac = fs.readFileSync(path.join(SP, 'macos/ui/menu/menu_llm/models_selector.lua'), 'utf8');
	assert.equal(
		nativeCaptionBinding(mac, '.lua', 'llm_model_hardware_rows', 'model_hw_backend_caption'),
		true
	);
	for (const changed of [
		mac.replace('frame.model_hw_backend_caption =', 'other.model_hw_backend_caption ='),
		mac.replace('pairs(values)', 'pairs(other)'),
		mac.replace('getters[name] = function() return captured end', 'getters[name] = captured'),
		mac.replace('return getters', 'return {}'),
		mac.replace(
			'frame.model_hw_backend_caption = display_backend',
			'frame.model_hw_backend_caption = nil'
		)
	])
		assert.equal(
			nativeCaptionBinding(changed, '.lua', 'llm_model_hardware_rows', 'model_hw_backend_caption'),
			false
		);
}

/** Follows canonical includes only from executable native template roots.
 * Lists and groups supply native children, not implicit section-name edges.
 * Validate each reached declaration before it can excuse an inert identity.
 */
function reachedInertTemplateRows(nativeSources, extension, definitions, platform, captionFormat) {
	const reached = new Set();
	if (EXT[platform] !== extension) return reached;
	for (const [root, declaration] of Object.entries(definitions)) {
		if (
			!Array.isArray(declaration) ||
			!nativeSources.some(
				(native) => native.src.includes(root) && publishesMenuTemplate(native.src, extension, root)
			)
		)
			continue;
		const graph = Object.create(null);
		const collecting = new Set();
		function declarations(key) {
			if (collecting.has(key)) throw new Error('cyclic child-template include');
			if (Object.hasOwn(graph, key)) return;
			const rows = definitions[key];
			if (!Array.isArray(rows) || rows.length === 0) throw new Error('missing child template');
			collecting.add(key);
			graph[key] = rows;
			for (const row of rows) {
				if (!row || typeof row !== 'object' || Array.isArray(row)) throw new Error('invalid row');
				if (
					row.platforms !== undefined &&
					(!Array.isArray(row.platforms) ||
						row.platforms.length === 0 ||
						new Set(row.platforms).size !== row.platforms.length ||
						!row.platforms.every((value) => PLATFORMS.includes(value)))
				)
					throw new Error('invalid platform projection');
				if (row.type === 'include') declarations(row.section);
			}
			collecting.delete(key);
		}
		try {
			declarations(root);
			validateChildTemplates(graph, captionFormat);
		} catch {
			// A malformed reached route cannot supply publication evidence.
			continue;
		}
		function visit(key, rowId) {
			for (const row of graph[key]) {
				if ((rowId !== undefined && row.id !== rowId) || !visible(row, platform)) continue;
				if (row.type === 'include') visit(row.section, row.row_id);
				else if (
					inertTemplateRow(row, captionFormat) &&
					(!Object.hasOwn(row, 'caption_getter') ||
						nativeSources.some(
							(native) =>
								publishesMenuTemplate(native.src, extension, root) &&
								nativeCaptionBinding(native.src, extension, root, row.caption_getter)
						))
				)
					reached.add(row);
			}
		}
		visit(root);
	}
	return reached;
}

// Independently authored controls keep commands and behavior-bearing labels in
// the handler census, and refuse decorative source as evidence of publication.
{
	const row = { type: 'label', id: 'fixture_label', i18n: 'fixture.caption' };
	assert.equal(inertTemplateRow(row), true);
	assert.equal(inertTemplateRow({ ...row, type: 'section_header' }), true);
	for (const change of [
		{ type: 'command' },
		{ command: 'run' },
		{ callback: 'run' },
		{ caption_getter: 'caption' },
		{ id: '' },
		{ i18n: '' }
	]) {
		assert.equal(inertTemplateRow({ ...row, ...change }), false);
	}
	for (const [extension, call, prefix] of [
		['.lua', 'ManifestMenu.template_rows("fixture")', '-- '],
		['.ahk', 'MenuRenderer_TemplateRows("fixture")', '; ']
	]) {
		assert.equal(publishesMenuTemplate(call, extension, 'fixture'), true);
		for (const source of [
			prefix + call,
			JSON.stringify(call),
			'function ' + call,
			call.replace('fixture', 'other'),
			call.replace('("fixture")', '("fixture" .. "tail")'),
			'Foreign.' + call
		]) {
			assert.equal(publishesMenuTemplate(source, extension, 'fixture'), false);
		}
	}
}

// Transitive publication is declaration-specific and rooted in native code.
// A list/group identity does not mean that a similarly named section is reached.
{
	const label = { type: 'label', id: 'nested_heading', i18n: 'fixture.caption' };
	const paused = {
		type: 'label',
		id: 'paused_heading',
		i18n: 'fixture.paused',
		platforms: ['hs'],
		unavailable: 'hide'
	};
	const command = { type: 'command', id: 'clicked_control', i18n: 'fixture.run' };
	const definitions = {
		frame: [
			{ type: 'include', section: 'bridge' },
			{ type: 'list', id: 'native_list' },
			{ type: 'group', id: 'native_group', i18n: 'fixture.group' }
		],
		bridge: [{ type: 'include', section: 'leaf', present_when: 'heading_present' }],
		leaf: [label, paused, command],
		native_list: [{ ...label, id: 'unreached_list_heading' }],
		native_group: [{ ...label, id: 'unreached_group_heading' }],
		orphan: [{ ...label, id: 'orphan_heading' }]
	};
	for (const [extension, call, comment] of [
		['.lua', 'ManifestMenu.template_rows("frame", {}, {}, {})', '-- '],
		['.ahk', 'MenuRenderer_TemplateRows("frame", Map(), Map(), Map())', '; ']
	]) {
		const platform = extension === '.ahk' ? 'ahk' : 'hs';
		const nativeDefinitions = {
			...definitions,
			leaf: [label, { ...paused, platforms: [platform] }, command]
		};
		const nativePaused = nativeDefinitions.leaf[1];
		const natives = [{ rel: 'actual-native-owner' + extension, src: call }];
		const reached = reachedInertTemplateRows(natives, extension, nativeDefinitions, platform);
		assert.equal(reached.has(label), true);
		assert.equal(reached.has(nativePaused), true);
		assert.equal(reached.has(command), false);
		assert.equal(reached.size, 2);
		for (const other of PLATFORMS.filter((value) => value !== platform)) {
			assert.equal(
				reachedInertTemplateRows(natives, extension, nativeDefinitions, other).has(nativePaused),
				false
			);
		}
		assert.equal(
			reachedInertTemplateRows(natives, '.foreign', nativeDefinitions, platform).size,
			0
		);

		for (const source of [
			comment + call,
			JSON.stringify(call),
			'function ' + call,
			'Foreign.' + call,
			call.replace('frame', 'foreign'),
			call.replace('"frame"', '"frame" .. suffix')
		]) {
			assert.equal(
				reachedInertTemplateRows(
					[{ rel: 'native' + extension, src: source }],
					extension,
					nativeDefinitions,
					platform
				).size,
				0
			);
		}
		// Text outside the caller-owned native inventory is not a publication root.
		assert.equal(reachedInertTemplateRows([], extension, nativeDefinitions, platform).size, 0);
		for (const change of [
			{ leaf: undefined },
			{ leaf: [] },
			{ bridge: [{ type: 'include', section: 'frame' }] },
			{ bridge: [{ type: 'include', section: 'missing' }] },
			{ bridge: [{ type: 'include', section: 'leaf', command: 'run' }] },
			{ bridge: [{ type: 'include', section: 'leaf', present_when: true }] },
			{ bridge: [{ type: 'include', section: 'leaf', row_id: 'missing' }] },
			{ leaf: [{ ...label, command: 'run' }] },
			{ leaf: [{ ...label, callback: 'run' }] },
			{ leaf: [{ ...label, disabled: 'true' }] },
			{ leaf: [{ ...label, disabled: true }] },
			{ leaf: [{ ...label, platforms: ['foreign'] }] },
			{ leaf: [{ ...label, platforms: ['hs', 'hs'] }] }
		]) {
			assert.equal(
				reachedInertTemplateRows(natives, extension, { ...nativeDefinitions, ...change }, platform)
					.size,
				0
			);
		}
		// Exact selection never credits the unselected identity or a clicked row.
		const selected = {
			...nativeDefinitions,
			bridge: [{ type: 'include', section: 'leaf', row_id: label.id }]
		};
		const selectedRows = reachedInertTemplateRows(natives, extension, selected, platform);
		assert.equal(selectedRows.has(label), true);
		assert.equal(selectedRows.has(nativePaused), false);
		assert.equal(selectedRows.size, 1);
		assert.equal(
			reachedInertTemplateRows(
				natives,
				extension,
				{ ...selected, leaf: [label, { ...label }] },
				platform
			).size,
			0
		);
		assert.equal(
			reachedInertTemplateRows(
				natives,
				extension,
				{ ...selected, bridge: [{ type: 'include', section: 'leaf', row_id: command.id }] },
				platform
			).size,
			0
		);
		assert.equal(
			reachedInertTemplateRows(
				natives,
				extension,
				{
					...definitions,
					bridge: [{ type: 'include', section: 'leaf', on_refusal: 'omit_presentation' }]
				},
				platform
			).size,
			0
		);
	}
}

const english = JSON.parse(fs.readFileSync(path.join(SP, '_shared/data/locales/en.json'), 'utf8'));
const canonicalCaption = (key) => (Object.hasOwn(english, key) ? english[key] : undefined);
{
	const caption = {
		type: 'label',
		id: 'actual_readout',
		i18n: 'fixture.format',
		caption_getter: 'actual_value'
	};
	const get = (key) =>
		({
			'fixture.format': 'Value: %s',
			'fixture.static': 'Static',
			'fixture.escaped': 'Value: %%s'
		})[key];
	assert.equal(inertTemplateRow(caption), false);
	assert.equal(inertTemplateRow(caption, get), true);
	for (const change of [
		{ i18n: 'fixture.static' },
		{ i18n: 'fixture.escaped' },
		{ caption_getter: '' },
		{ command: 'click' },
		{ callback: 'click' }
	])
		assert.equal(inertTemplateRow({ ...caption, ...change }, get), false);
	const native = [
		{
			rel: 'actual-owner.lua',
			src: 'ManifestMenu.template_rows("frame", {}, { actual_value = function() return "real" end }, {})'
		}
	];
	const graph = { frame: [{ type: 'include', section: 'detail' }], detail: [caption] };
	assert.equal(reachedInertTemplateRows(native, '.lua', graph, 'hs', get).has(caption), true);
	for (const change of [
		{ detail: [{ ...caption, i18n: 'fixture.static' }] },
		{ detail: [{ ...caption, caption_getter: '' }] }
	])
		assert.equal(
			reachedInertTemplateRows(native, '.lua', { ...graph, ...change }, 'hs', get).size,
			0
		);
	assert.equal(
		reachedInertTemplateRows(
			[{ ...native[0], src: '-- ' + native[0].src }],
			'.lua',
			graph,
			'hs',
			get
		).size,
		0
	);
}

// Independently authored binding controls preserve necessary static evidence.
{
	const assigned =
		'local callback = function() return real_owner() end\nManifestMenu.template_rows("actual_frame", { actual_command = callback }, {}, {})';
	assert.equal(nativeTemplateBinding(assigned, '.lua', 'actual_frame', 'actual_command', 1), true);
	for (const changed of [
		assigned.replace('actual_command = callback', 'other_command = callback'),
		assigned.replace('actual_command = callback', 'actual_command = "callback"'),
		assigned.replace('actual_command = callback', 'actual_command = Foreign.callback'),
		assigned.replace('return real_owner()', ''),
		assigned.replace('ManifestMenu.template_rows', '-- ManifestMenu.template_rows'),
		assigned.replace('ManifestMenu.template_rows', 'Foreign.ManifestMenu.template_rows'),
		assigned.replace('ManifestMenu.template_rows', 'local callback; ManifestMenu.template_rows'),
		assigned.replace(
			'ManifestMenu.template_rows',
			'local other, callback; ManifestMenu.template_rows'
		),
		assigned.replace('ManifestMenu.template_rows', 'callback = nil; ManifestMenu.template_rows'),
		assigned.replace(
			'actual_command = callback',
			'actual_command = callback, actual_command = nil'
		),
		assigned.replace(
			'actual_command = callback',
			String.raw`actual_command = callback, ["actual_\099ommand"] = nil`
		),
		assigned.replace('actual_command = callback', 'actual_command = callback, [chosen] = nil'),
		assigned.replace('actual_command = callback', '[ [=[actual_command]=] ] = callback'),
		assigned.replace(
			'local callback = function() return real_owner() end',
			'do local callback = function() return real_owner() end end'
		)
	])
		assert.equal(
			nativeTemplateBinding(changed, '.lua', 'actual_frame', 'actual_command', 1),
			false
		);
	const child =
		'ManifestMenu.template_rows("actual_frame", {}, {}, { actual_children = function() return real_children end })';
	assert.equal(nativeTemplateBinding(child, '.lua', 'actual_frame', 'actual_children', 3), true);
	for (const changed of [
		child.replace('actual_children = function', 'withdrawn = function'),
		child.replace('return real_children', ''),
		child.replace('function() return real_children end', '"not_callable"')
	])
		assert.equal(
			nativeTemplateBinding(changed, '.lua', 'actual_frame', 'actual_children', 3),
			false
		);
	const callback = 'ActualCallback(*) {\n NativeAction()\n}\n',
		ahk =
			callback +
			'Owner() {\n MenuRenderer_TemplateRows("actual_frame", Map("actual_command", ActualCallback), Map(), Map())\n}';
	assert.equal(nativeTemplateBinding(ahk, '.ahk', 'actual_frame', 'actual_command', 1), true);
	for (const changed of [
		ahk.replace('"actual_command",', '"withdrawn",'),
		ahk.replace('Map("actual_command", ActualCallback)', 'Map("actual_command", "ActualCallback")'),
		ahk.replace(
			'Map("actual_command", ActualCallback)',
			'Map("actual_command", Foreign.ActualCallback)'
		),
		ahk.replace(
			'Map("actual_command", ActualCallback)',
			'Map("actual_command", ActualCallback, "actual_command", false)'
		),
		ahk.replace(' NativeAction()', ''),
		ahk.replace(' MenuRenderer_', ' local ActualCallback\n MenuRenderer_'),
		ahk.replace(' MenuRenderer_', ' local other, ActualCallback\n MenuRenderer_'),
		ahk.replace('Owner()', 'Owner(ActualCallback)'),
		ahk.replace('Owner()', 'Owner(actualcallback)'),
		ahk.replace(' MenuRenderer_', ' LOCAL other, actualcallback\n MenuRenderer_'),
		ahk.replace(
			'Map("actual_command", ActualCallback)',
			'Map("actual_command", ActualCallback, "ACTUAL_COMMAND", false)'
		),
		ahk.replace(callback, 'Outer() {\n' + callback + '}\n'),
		ahk.replace(' MenuRenderer_', ' ActualCallback := false\n MenuRenderer_')
	])
		assert.equal(
			nativeTemplateBinding(changed, '.ahk', 'actual_frame', 'actual_command', 1),
			false
		);
	const mac = fs.readFileSync(
		path.join(SP, 'macos/ui/menu/menu_hotstrings_management.lua'),
		'utf8'
	);
	assert.equal(
		nativeTemplateBinding(mac, '.lua', 'hotstrings_magic_trigger_frame', 'magic_key_change', 1),
		true
	);
	assert.equal(
		nativeTemplateBinding(
			mac.replace('magic_key_change = magic_key_action', 'withdrawn = magic_key_action'),
			'.lua',
			'hotstrings_magic_trigger_frame',
			'magic_key_change',
			1
		),
		false
	);
	const linux = fs.readFileSync(path.join(SP, 'linux/ui/menu/menu_builder.lua'), 'utf8');
	assert.equal(
		nativeTemplateBinding(linux, '.lua', 'hotstrings_magic_trigger_frame', 'magic_key_change', 1),
		true
	);
	assert.equal(
		nativeTemplateBinding(
			linux,
			'.lua',
			'hotstrings_magic_trigger_frame',
			'magic_key_reset_if_custom',
			3
		),
		true
	);
	assert.equal(
		nativeTemplateBinding(linux, '.lua', 'hotstrings_magic_trigger_reset', 'magic_key_reset', 1),
		true
	);
	for (const [section, key, port, from, to] of [
		[
			'hotstrings_magic_trigger_frame',
			'magic_key_change',
			1,
			'magic_key_change = change',
			'withdrawn = change'
		],
		[
			'hotstrings_magic_trigger_frame',
			'magic_key_change',
			1,
			'local change = function()',
			'local change = false; local withdrawn = function()'
		],
		[
			'hotstrings_magic_trigger_reset',
			'magic_key_reset',
			1,
			'{ magic_key_reset = reset }',
			'{ magic_key_reset = "reset" }'
		],
		[
			'hotstrings_magic_trigger_frame',
			'magic_key_reset_if_custom',
			3,
			'magic_key_reset_if_custom = function()',
			'withdrawn_children = function()'
		]
	])
		assert.equal(nativeTemplateBinding(linux.replace(from, to), '.lua', section, key, port), false);
	const win = fs.readFileSync(path.join(SP, 'windows/ui/menu/menu_hotstrings.ahk'), 'utf8'),
		editor = fs.readFileSync(path.join(SP, 'windows/ui/editors.ahk'), 'utf8');
	assert.equal(
		nativeTemplateBinding(win, '.ahk', 'hotstrings_magic_trigger_frame', 'magic_key_change', 1, [
			{ src: win },
			{ src: editor }
		]),
		true
	);
	assert.equal(
		nativeTemplateBinding(
			win.replace('Map("magic_key_change", MagicKeyEditor)', 'Map("withdrawn", MagicKeyEditor)'),
			'.ahk',
			'hotstrings_magic_trigger_frame',
			'magic_key_change',
			1,
			[{ src: win }, { src: editor }]
		),
		false
	);
	assert.equal(
		nativeTemplateBinding(win, '.ahk', 'hotstrings_magic_trigger_frame', 'magic_key_change', 1, [
			{ src: win }
		]),
		false
	);
}

// Genuine current native Layout row owners, with independent non-vacuity controls.
{
	const { nativeLayoutRowOwnership } = require('../lib/menu-native-layout-binding.cjs');
	const source = fs.readFileSync(path.join(SP, 'macos/ui/menu/menu_keyboard_layout.lua'), 'utf8');
	const english = JSON.parse(
		fs.readFileSync(path.join(SP, '_shared/data/locales/en.json'), 'utf8')
	);
	const caption = (key) => (Object.hasOwn(english, key) ? english[key] : undefined);
	const behavior = [
		['layout_native_record_choice', 'layout_native_select'],
		['layout_bundle_update', 'layout_install'],
		['layout_bundle_install', 'layout_install'],
		['layout_bundle_upgrade', 'layout_upgrade_list'],
		['layout_bundle_upgrade_to', 'layout_upgrade_list'],
		['layout_bundle_variant_add', 'layout_enable_variant']
	];
	const inert = [
		['layout_bundle_in_list', 'layout_in_list_caption'],
		['layout_bundle_install_first', 'layout_install_first_caption'],
		['layout_bundle_installed', 'layout_installed_caption'],
		['layout_bundle_update_install_first', 'layout_update_install_first_caption'],
		['layout_bundle_variant_added', 'layout_added_variant_caption']
	];
	let admittedBehavior = 0,
		admittedInert = 0;
	for (const [ownership, subjects] of [
		['behavior', behavior],
		['inert', inert]
	]) {
		for (const [section, id] of subjects) {
			const definition = manifest[section];
			assert.equal(
				definition.length,
				1,
				'actual canonical singleton, never an invented fixture declaration'
			);
			const row = definition[0];
			assert.equal(row.id, id, 'independently named actual callback/caption owner');
			const owns = (
				native,
				rows = definition,
				platform = 'hs',
				extension = '.lua',
				kind = ownership
			) =>
				nativeLayoutRowOwnership(
					native,
					extension,
					platform,
					section,
					rows?.[0],
					rows,
					caption,
					kind
				);
			assert.equal(
				owns(source),
				true,
				section + ': actual native callback/getter and final publication'
			);
			if (ownership === 'behavior') admittedBehavior++;
			else admittedInert++;
			assert.equal(
				owns(source, definition, 'hs', '.lua', ownership === 'behavior' ? 'inert' : 'behavior'),
				false
			);
			assert.equal(owns(source, definition, 'hs', '.lua', 'foreign'), false);
			assert.equal(owns(source, definition, 'linux'), false);
			assert.equal(owns(source, definition, 'ahk', '.ahk'), false);
			assert.equal(owns(source, definition, 'hs', '.foreign'), false);
			assert.equal(owns(source, []), false);
			assert.equal(
				owns(source, [row, { ...row }]),
				false,
				'ambiguous canonical row never acquires borrowed ownership'
			);
			assert.equal(
				nativeLayoutRowOwnership(
					source,
					'.lua',
					'hs',
					section,
					{ ...row },
					definition,
					caption,
					ownership
				),
				false,
				'an unrelated object cannot borrow the canonical row identity'
			);
			for (const change of [
				{ id: 'foreign_owner' },
				{ type: 'group' },
				{ platforms: ['linux'] },
				{ platforms: ['hs', 'hs'] },
				{ command: id },
				{ action: id },
				{ callback: id },
				{ provider: id },
				{ handler: id },
				{ unavailable: 'grey' },
				{ disabled: true },
				{ checked_when: ['foreign'] },
				{ disabled_when: ['foreign'] },
				{ caption_getter: 'foreign' },
				{ caption_getters: ['foreign'] },
				{ foreign_field: id }
			])
				assert.equal(
					owns(source, [{ ...row, ...change }]),
					false,
					'canonical shape/kind/identity refuses foreign policy'
				);
			for (const [name, native] of [
				['quoted source', JSON.stringify(source)],
				['commented source', '--[=[\n' + source + '\n]=]'],
				[
					'foreign singleton receiver',
					source.replace('renderer.template_rows(section,', 'Foreign.template_rows(section,')
				],
				[
					'withdrawn finished menu',
					source.replace('"layout_parent_content", submenu, {}', '"layout_parent_content", {}, {}')
				],
				['discarded custom result', source.replace('return custom_rows end', 'return {} end')],
				['discarded active result', source.replace('return active_rows end', 'return {} end')],
				[
					'discarded bundle result',
					source.replace('return declared_bundle_rows end', 'return {} end')
				],
				[
					'discarded switching result',
					source.replace('return switching_rows end', 'return {} end')
				],
				[
					'discarded bundle status provider',
					source.replace('return {bundle_rows[#bundle_rows]} end', 'return {} end')
				],
				[
					'shadowed actual frame producer',
					source.replace(
						'local declared_bundle_rows = bundle_frame_rows()',
						'local bundle_frame_rows; local declared_bundle_rows = bundle_frame_rows()'
					)
				]
			]) {
				assert.notEqual(native, source, name + ' changes the actual owner');
				assert.equal(owns(native), false, name + ' cannot supply dynamic ownership');
			}
			assert.equal(
				nativeLayoutRowOwnership(
					source,
					'.lua',
					'hs',
					'unowned_layout_probe',
					row,
					definition,
					caption,
					ownership
				),
				false
			);
			assert.equal(owns(source), true, 'exact canonical/native restoration recovers ownership');
		}
	}
	assert.equal(admittedBehavior, 6);
	assert.equal(admittedInert, 5);
	for (const [section, from, to] of [
		[
			'layout_native_record_choice',
			'layout_native_select = callback',
			'layout_native_select = "callback"'
		],
		['layout_native_record_choice', 'LayoutRegistry.select(id,', 'Foreign.select(id,'],
		[
			'layout_native_record_choice',
			'set_input_source_async(target_localised, target_kl_name,',
			'Foreign.set_input_source_async(target_localised, target_kl_name,'
		],
		['layout_native_record_choice', 'return on_pick(id)', 'return false'],
		['layout_native_record_choice', 'state.layout_on_pause = id', 'state.layout_on_pause = false'],
		['layout_bundle_update', 'layout_install = do_install', 'layout_install = "do_install"'],
		['layout_bundle_install', 'return install_system(bundles_dir, latest)', 'return true'],
		['layout_bundle_install', 'return install_user(bundles_dir, latest)', 'return true'],
		['layout_bundle_install', 'ok = install_fn()', 'ok = true'],
		[
			'layout_bundle_variant_add',
			'local function variant_provider() return add_sub end',
			'local function variant_provider() return {} end'
		],
		[
			'layout_bundle_upgrade',
			'upgrade_active_list_async(legacy_active, function(ok)',
			'Foreign.upgrade_active_list_async(legacy_active, function(ok)'
		],
		[
			'layout_bundle_upgrade_to',
			'local upgrade_active_list_async     = input_sources.upgrade_active_list_async',
			'local upgrade_active_list_async = false'
		],
		[
			'layout_bundle_variant_add',
			'enable_keylayout_source_async(var.keylayout, label,',
			'Foreign.enable_keylayout_source_async(var.keylayout, label,'
		],
		[
			'layout_bundle_variant_add',
			'local enable_keylayout_source_async = input_sources.enable_keylayout_source_async',
			'local enable_keylayout_source_async = false'
		]
	]) {
		const native = source.replace(from, to),
			definition = manifest[section];
		assert.notEqual(native, source, 'withdraw a genuine measured callable/effect owner');
		assert.equal(
			nativeLayoutRowOwnership(
				native,
				'.lua',
				'hs',
				section,
				definition[0],
				definition,
				caption,
				'behavior'
			),
			false,
			'a named but noncallable/no-op/foreign callback cannot answer a declared behavior'
		);
	}
	for (const [section, from, to] of [
		[
			'layout_bundle_installed',
			'layout_install_scope = function() return scope_label end',
			'layout_install_scope = function() return false end'
		],
		[
			'layout_bundle_in_list',
			'layout_bundle_version = function() return version_str(installed_ver) end',
			'layout_bundle_version = function() return false end'
		],
		[
			'layout_bundle_update_install_first',
			'layout_bundle_version = function() return latest_str end',
			'layout_bundle_version = "latest_str"'
		],
		[
			'layout_bundle_variant_added',
			'layout_variant_label = function() return label end',
			'layout_variant_label = "label"'
		],
		[
			'layout_bundle_variant_added',
			'local function variant_provider() return add_sub end',
			'local function variant_provider() return {} end'
		],
		[
			'layout_bundle_installed',
			'bundle_rows[#bundle_rows + 1] = build_install_item(',
			'discarded_install_row = build_install_item('
		],
		[
			'layout_bundle_install_first',
			'layout_declared_row("layout_bundle_install_first", {}, {})',
			'layout_declared_row("layout_bundle_install_first", { foreign = function() return true end }, {})'
		]
	]) {
		const native = source.replace(from, to),
			definition = manifest[section];
		assert.notEqual(native, source, 'withdraw the actual inert/data owner');
		assert.equal(
			nativeLayoutRowOwnership(
				native,
				'.lua',
				'hs',
				section,
				definition[0],
				definition,
				caption,
				'inert'
			),
			false,
			'foreign inert/getter/behavior data cannot excuse a declared identity'
		);
	}
}

const reachedInert = Object.fromEntries(
	PLATFORMS.map((platform) => [
		platform,
		reachedInertTemplateRows(
			src[platform].nativeSources,
			EXT[platform],
			manifest,
			platform,
			canonicalCaption
		)
	])
);

const rows = [];
for (const [key, list] of Object.entries(manifest)) {
	if (!Array.isArray(list)) continue;
	const cell = {};
	for (const p of PLATFORMS) {
		const shown = list.filter((r) => visible(r, p));
		// Rows that need the driver to name something: an id it dispatches on.
		const needing = shown.filter((r) => typeof r.id === 'string' && r.id !== '---');
		const missing = needing.filter(
			(r) =>
				!src[p].text.includes(r.id) &&
				!reachedInert[p].has(r) &&
				!src[p].nativeSources.some((native) =>
					nativeLayoutRowOwnership(
						native.src,
						EXT[p],
						p,
						key,
						r,
						manifest[key],
						canonicalCaption,
						'inert'
					)
				) &&
				!(
					['command', 'list'].includes(r.type) &&
					src[p].nativeSources.some(
						(native) =>
							(native.src.includes('template_rows') ||
								native.src.includes('MenuRenderer_TemplateRows')) &&
							nativeTemplateBinding(
								native.src,
								EXT[p],
								key,
								r.command || r.id,
								r.type === 'list' ? 3 : 1,
								src[p].nativeSources,
								manifest,
								p
							)
					)
				)
		);
		cell[p] = { shown: shown.length, missing: missing.map((r) => r.id) };
	}
	rows.push({ key, cell });
}

const pad = (s, n) => String(s).padEnd(n);
console.log(pad('menu', 30) + pad('windows', 12) + pad('macos', 12) + 'linux');
console.log('-'.repeat(66));
let unanswered = 0;
for (const { key, cell } of rows.sort((a, b) => a.key.localeCompare(b.key))) {
	const fmt = (c) =>
		c.shown === 0 ? '—' : c.missing.length ? `${c.shown} (${c.missing.length}!)` : `${c.shown}`;
	console.log(pad(key, 30) + pad(fmt(cell.ahk), 12) + pad(fmt(cell.hs), 12) + fmt(cell.linux));
	for (const p of PLATFORMS) unanswered += cell[p].missing.length;
}
console.log('-'.repeat(66));
console.log(
	`${rows.length} menus declared; ${unanswered} declared id(s) not named by the driver that shows them`
);
if (unanswered > 0) {
	console.error('[31m[FAIL] a declared menu row is not answered by a driver that shows it:[0m');
	for (const { key, cell } of rows) {
		for (const p of PLATFORMS) {
			if (cell[p].missing.length) {
				console.error(
					`    - ${p} ${key}: ${cell[p].missing.join(', ')} — declared for this platform and named ` +
						'nowhere in its source. The renderer logs one warning and skips the row, so the menu is ' +
						'one item short, permanently.'
				);
			}
		}
	}
	process.exit(1);
}
console.log(
	`[32m[OK] ${rows.length} menus declared in _shared; every id shown on a driver is answered by it.[0m`
);
