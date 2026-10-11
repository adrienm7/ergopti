// tools/lib/menu-hotstring-language-binding.cjs

/** Proves the declared Hotstrings language controls through their physical native owners. */
'use strict';

const { isDeepStrictEqual } = require('node:util');
const { scriptTokens } = require('./script-source.cjs');

// Independent presentation contract: the former native checkbox and language heads.
const declarations = {
	hotstring_scope_checkbox: [
		{
			type: 'check',
			id: 'hotstring_scope_all_sections',
			i18n: 'menu.hotstrings.enable_all_sections',
			checked_when: ['hotstring_scope_all_on']
		}
	],
	hotstring_language_frame: [
		{ type: 'list', id: 'hotstring_language_switch' },
		{ type: '---' },
		{ type: 'list', id: 'hotstring_language_categories' }
	],
	hotstring_language_parent_windows: [
		{
			type: 'group',
			id: 'hotstring_language_children',
			caption_source: 'native',
			caption_getter: 'hotstring_language_name',
			caption_count_getter: 'hotstring_language_count',
			caption_count_format: '%s (%s)',
			icon_getter: 'hotstring_language_icon',
			platforms: ['ahk'],
			unavailable: 'hide'
		}
	],
	hotstring_language_parent_lua: [
		{
			type: 'group',
			id: 'hotstring_language_children',
			caption_source: 'native',
			caption_getter: 'hotstring_language_name',
			caption_count_getter: 'hotstring_language_count',
			caption_count_format: '%s (%s)',
			platforms: ['hs', 'linux'],
			unavailable: 'hide'
		}
	]
};

const files = {
	ahk: [
		'windows/ui/menu/menu_submenus.ahk',
		'windows/ui/menu/menu_hotstring_switches.ahk',
		'windows/ui/menu/menu_init.ahk'
	],
	hs: [
		'macos/ui/menu/builder.lua',
		'macos/ui/menu/menu_hotstrings_custom.lua',
		'macos/ui/menu/menu_hotstrings.lua'
	],
	linux: ['linux/ui/menu/menu_builder.lua']
};

/** Records native block depth while keeping strings and field names inert. */
function depths(tokens, extension) {
	let depth = 0,
		awaitingDo = 0;
	return tokens.map((token, index) => {
		const before = depth;
		if (extension === '.ahk') {
			if (token.kind === 'symbol' && token.value === '{') depth++;
			if (token.kind === 'symbol' && token.value === '}') depth--;
		} else if (
			token.kind === 'identifier' &&
			(!['.', ':'].includes(tokens[index - 1]?.value) ||
				(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
		) {
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
		}
		return before;
	});
}

/** Matches a physical statement at its required owner depth, never an alias or literal. */
function ranges(source, fragment, extension, requiredDepth = 0) {
	const tokens = scriptTokens(source, extension),
		wanted = scriptTokens(fragment, extension);
	const level = depths(tokens, extension),
		found = [];
	for (let i = 0; i < tokens.length; i++) {
		if (level[i] !== requiredDepth || ['.', ':'].includes(tokens[i - 1]?.value)) continue;
		if (
			!wanted.every((token, offset) => {
				const actual = tokens[i + offset];
				return (
					actual?.kind === token.kind &&
					actual.value === token.value &&
					(token.kind !== 'string' ||
						source.slice(actual.start, actual.end) === fragment.slice(token.start, token.end))
				);
			})
		)
			continue;
		found.push({ start: tokens[i].start, end: tokens[i + wanted.length - 1].end, index: i });
	}
	return found;
}

/** Extracts one complete physical function; dead branches and duplicate owners refuse. */
function owner(source, signature, extension) {
	if (typeof source !== 'string') throw new Error('Missing physical Hotstrings source');
	const matches = ranges(source, signature, extension).filter(
		(range) => !source.slice(source.lastIndexOf('\n', range.start - 1) + 1, range.start).trim()
	);
	if (matches.length !== 1) throw new Error('One physical Hotstrings owner required');
	const tokens = scriptTokens(source, extension),
		level = depths(tokens, extension);
	const at = tokens.findIndex((token) => token.end === matches[0].end);
	for (let i = at + 1; i < tokens.length; i++) {
		if (
			level[i] === 1 &&
			(extension === '.ahk'
				? tokens[i].value === '}'
				: tokens[i].kind === 'identifier' && tokens[i].value === 'end')
		)
			return source.slice(matches[0].end, tokens[i].start);
	}
	throw new Error('Incomplete physical Hotstrings owner');
}

/** Tracks the actual native block path; a bare do/repeat does not make a return conditional. */
function paths(source, extension) {
	const tokens = scriptTokens(source, extension),
		contexts = [],
		stack = [];
	let awaitingDo = 0;
	for (let i = 0; i < tokens.length; i++) {
		const token = tokens[i];
		contexts.push(stack.filter((frame) => !frame.unconditional).map((frame) => frame.id));
		if (extension === '.ahk') {
			if (token.kind === 'symbol' && token.value === '{')
				stack.push({
					id: i,
					unconditional: tokens[i - 2]?.value === 'if' && tokens[i - 1]?.value === 'true'
				});
			if (token.kind === 'symbol' && token.value === '}') stack.pop();
			continue;
		}
		if (
			token.kind !== 'identifier' ||
			(['.', ':'].includes(tokens[i - 1]?.value) &&
				!(tokens[i - 1]?.value === ':' && tokens[i - 2]?.value === ':'))
		)
			continue;
		if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
			stack.push({
				id: i,
				kind: token.value,
				unconditional:
					token.value === 'repeat' ||
					(token.value === 'if' &&
						tokens[i + 1]?.value === 'true' &&
						tokens[i + 2]?.value === 'then')
			});
			if (['for', 'while'].includes(token.value)) awaitingDo++;
		} else if (token.value === 'do') {
			if (awaitingDo) awaitingDo--;
			else stack.push({ id: i, kind: 'do', unconditional: true });
		} else if (['else', 'elseif'].includes(token.value)) {
			const frame = stack.findLast((entry) => entry.kind === 'if');
			if (frame) frame.id = i;
		} else if (['end', 'until'].includes(token.value)) stack.pop();
	}
	return { tokens, contexts };
}

/** Finds the end of the return value, so fields evaluated inside a returned Map still count. */
function returnEnd(source, tokens, index, extension) {
	let nesting = 0,
		functions = 0,
		last = tokens[index].end;
	for (let i = index + 1; i < tokens.length; i++) {
		const token = tokens[i],
			previous = tokens[i - 1];
		if (
			!nesting &&
			!functions &&
			((token.kind === 'identifier' && ['end', 'until', 'else', 'elseif'].includes(token.value)) ||
				token.value === ';')
		)
			break;
		if (
			!nesting &&
			!functions &&
			source.slice(previous.end, token.start).includes('\n') &&
			(i > index + 1 || extension === '.ahk')
		)
			break;
		if (token.kind === 'symbol' && ['(', '[', '{'].includes(token.value)) nesting++;
		if (token.kind === 'symbol' && [')', ']', '}'].includes(token.value)) {
			if (!nesting) break;
			nesting--;
		}
		if (extension === '.lua' && token.kind === 'identifier' && token.value === 'function')
			functions++;
		if (extension === '.lua' && token.kind === 'identifier' && token.value === 'end' && functions)
			functions--;
		last = token.end;
	}
	return last;
}

/** A preceding return on the same path terminates the owner before this required effect. */
function reachable(source, extension, effect, flow) {
	const actual = flow.contexts[effect.index];
	for (let i = 0; i < effect.index; i++) {
		const token = flow.tokens[i];
		if (token.kind !== 'identifier' || token.value !== 'return') continue;
		const before = flow.contexts[i];
		if (!before.every((frame, offset) => actual[offset] === frame)) continue;
		if (returnEnd(source, flow.tokens, i, extension) < effect.start) return false;
	}
	return true;
}

/** Requires ordered, unique and reachable native effects in the actual owner. */
function route(source, extension, statements, flow = paths(source, extension)) {
	let previous = -1;
	for (const [fragment, depth = 0] of statements) {
		const matches = ranges(source, fragment, extension, depth);
		if (
			matches.length !== 1 ||
			matches[0].start <= previous ||
			!reachable(source, extension, matches[0], flow)
		)
			return false;
		previous = matches[0].end;
	}
	return true;
}

/** Records real variable writes and local declarations, excluding fields, strings and comments. */
function bindings(source, extension, name) {
	const tokens = scriptTokens(source, extension),
		found = [];
	for (let i = 0; i < tokens.length; i++) {
		if (
			tokens[i].kind !== 'identifier' ||
			tokens[i].value !== name ||
			['.', ':', '['].includes(tokens[i - 1]?.value)
		)
			continue;
		if (tokens[i + 1]?.value === (extension === '.ahk' ? ':=' : '=')) found.push(i);
		else if (extension === '.lua' && ['local', ','].includes(tokens[i - 1]?.value)) {
			let start = i - 1;
			while (start > 0 && (tokens[start].value === ',' || tokens[start].kind === 'identifier')) {
				if (tokens[start].value === 'local') {
					found.push(i);
					break;
				}
				start--;
			}
		}
	}
	return found;
}

/** The completed frame must reach its real parent without rebinding or a new local shadow. */
function retainedChild(source, extension, name, definition, consumption, depth, useDepth = depth) {
	const captured = ranges(source, definition, extension, depth),
		used = ranges(source, consumption, extension, useDepth);
	if (captured.length !== 1 || used.length !== 1 || captured[0].end >= used[0].start) return false;
	const flow = paths(source, extension);
	return !bindings(source, extension, name).some((index) => {
		const token = flow.tokens[index];
		return token.start > captured[0].end && token.start < used[0].start;
	});
}

/** Parses the complete Lua grammar used by the physical owners; unknown syntax refuses. */
function luaTree(source) {
	const raw = scriptTokens(source, '.lua'),
		tokens = [];
	for (let i = 0; i < raw.length; i++) {
		const t = raw[i];
		let value = t.value,
			end = t.end,
			kind = t.kind;
		if (t.kind === 'symbol' && /[0-9]/.test(t.value)) {
			const number = source
				.slice(t.start)
				.match(
					/^(?:0[xX][0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?(?:[pP][+-]?\d+)?|\d+(?:\.(?!\.)\d*)?(?:[eE][+-]?\d+)?)/
				);
			if (!number) throw Error('Lua numeric grammar');
			value = number[0];
			end = t.start + value.length;
			kind = 'number';
			while (raw[i + 1]?.start < end) i++;
		} else if (t.kind === 'symbol') {
			for (const op of ['...', '==', '~=', '<=', '>=', '..', '//', '<<', '>>', '::'])
				if (source.startsWith(op, t.start)) {
					value = op;
					end = t.start + op.length;
					while (raw[i + 1]?.start < end) i++;
					break;
				}
		}
		tokens.push({ ...t, value, end, kind });
	}
	let at = 0;
	const peek = (v) =>
		v === undefined ? tokens[at] : tokens[at]?.kind !== 'string' && tokens[at]?.value === v;
	const take = (v) => {
		const t = tokens[at];
		if (!t || (v !== undefined && t.value !== v))
			throw Error('Lua expected ' + v + ' at ' + (t?.start ?? source.length));
		at++;
		return t;
	};
	const maybe = (v) => (peek(v) ? take(v) : null);
	const identifier = () => {
		const t = take();
		if (
			t.kind !== 'identifier' ||
			['end', 'then', 'else', 'elseif', 'do', 'until'].includes(t.value)
		)
			throw Error('Lua identifier');
		return { type: 'id', name: t.value, start: t.start, end: t.end };
	};
	const node = (type, start, data) => ({ type, start, end: tokens[at - 1]?.end ?? start, ...data });
	const precedence = {
		or: 1,
		and: 2,
		'<': 3,
		'>': 3,
		'<=': 3,
		'>=': 3,
		'~=': 3,
		'==': 3,
		'|': 4,
		'~': 5,
		'&': 6,
		'<<': 7,
		'>>': 7,
		'..': 8,
		'+': 9,
		'-': 9,
		'*': 10,
		'/': 10,
		'//': 10,
		'%': 10,
		'^': 12
	};
	function list() {
		const out = [expression()];
		while (maybe(',')) out.push(expression());
		return out;
	}
	function args() {
		if (maybe('(')) {
			const values = peek(')') ? [] : list();
			take(')');
			return values;
		}
		if (peek('{')) return [table()];
		if (peek()?.kind === 'string') return [primary()];
		throw Error('Lua call arguments');
	}
	function table() {
		const start = take('{').start,
			fields = [];
		while (!peek('}')) {
			let key = null,
				value;
			if (maybe('[')) {
				key = expression();
				take(']');
				take('=');
				value = expression();
			} else if (peek()?.kind === 'identifier' && tokens[at + 1]?.value === '=') {
				const id = identifier();
				key = { type: 'string', value: id.name, start: id.start, end: id.end };
				take('=');
				value = expression();
			} else value = expression();
			fields.push({ key, value });
			if (!maybe(',') && !maybe(';')) break;
		}
		take('}');
		return node('table', start, { fields });
	}
	function func(start) {
		take('(');
		const params = [];
		if (!peek(')')) {
			do {
				if (peek('...')) params.push(node('vararg', take('...').start, {}));
				else params.push(identifier());
			} while (maybe(','));
		}
		take(')');
		const body = block(['end']);
		take('end');
		return node('function', start, { params, body });
	}
	function primary() {
		const t = peek();
		if (!t) throw Error('Lua expression');
		if (t.kind === 'string') {
			take();
			return node('string', t.start, { value: t.value });
		}
		if (t.kind === 'number') {
			take();
			return node('number', t.start, { value: Number(t.value) });
		}
		if (['nil', 'true', 'false'].includes(t.value)) {
			take();
			return node('literal', t.start, { value: t.value === 'nil' ? null : t.value === 'true' });
		}
		if (maybe('function')) return func(t.start);
		if (peek('{')) return table();
		if (maybe('(')) {
			const e = expression();
			take(')');
			return e;
		}
		if (maybe('...')) return node('vararg', t.start, {});
		return identifier();
	}
	function expression(min = 0) {
		let left,
			start = peek()?.start;
		if (peek()?.kind !== 'string' && ['not', '#', '-', '~'].includes(peek()?.value)) {
			const op = take().value;
			left = node('unary', start, { op, value: expression(11) });
		} else left = primary();
		while (true) {
			if (maybe('.')) {
				left = node('field', left.start, { object: left, key: identifier().name });
				continue;
			}
			if (maybe('[')) {
				const key = expression();
				take(']');
				left = node('index', left.start, { object: left, key });
				continue;
			}
			if (maybe(':')) {
				const method = identifier().name;
				left = node('call', left.start, {
					callee: node('field', left.start, { object: left, key: method }),
					args: args(),
					method: true
				});
				continue;
			}
			if (peek('(') || peek('{') || peek()?.kind === 'string') {
				left = node('call', left.start, { callee: left, args: args() });
				continue;
			}
			const op = peek()?.kind === 'string' ? undefined : peek()?.value,
				p = precedence[op];
			if (p === undefined || p < min) break;
			take();
			left = node('binary', left.start, {
				op,
				left,
				right: expression(op === '^' || op === '..' ? p : p + 1)
			});
		}
		return left;
	}
	function statement() {
		const start = peek().start;
		if (maybe(';')) return node('empty', start, {});
		if (maybe('local')) {
			if (maybe('function')) {
				const name = identifier(),
					value = func(start);
				return node('local-function', start, { name, value });
			}
			const names = [identifier()];
			while (maybe(',')) names.push(identifier());
			const values = maybe('=') ? list() : [];
			return node('local', start, { names, values });
		}
		if (maybe('function')) {
			let target = identifier();
			while (maybe('.')) target = node('field', start, { object: target, key: identifier().name });
			if (maybe(':')) target = node('field', start, { object: target, key: identifier().name });
			return node('assign-function', start, { target, value: func(start) });
		}
		if (maybe('if')) {
			const branches = [];
			let test = expression();
			take('then');
			branches.push({ test, body: block(['elseif', 'else', 'end']) });
			while (maybe('elseif')) {
				test = expression();
				take('then');
				branches.push({ test, body: block(['elseif', 'else', 'end']) });
			}
			if (maybe('else')) branches.push({ test: null, body: block(['end']) });
			take('end');
			return node('if', start, { branches });
		}
		if (maybe('while')) {
			const test = expression();
			take('do');
			const body = block(['end']);
			take('end');
			return node('while', start, { test, body });
		}
		if (maybe('repeat')) {
			const body = block(['until']);
			take('until');
			return node('repeat', start, { body, test: expression() });
		}
		if (maybe('do')) {
			const body = block(['end']);
			take('end');
			return node('do', start, { body });
		}
		if (maybe('for')) {
			const names = [identifier()];
			let values,
				numeric = false;
			if (maybe('=')) {
				numeric = true;
				values = list();
			} else {
				while (maybe(',')) names.push(identifier());
				take('in');
				values = list();
			}
			take('do');
			const body = block(['end']);
			take('end');
			return node('for', start, { names, values, numeric, body });
		}
		if (maybe('return')) {
			const values =
				!peek() || ['end', 'else', 'elseif', 'until', ';'].includes(peek().value) ? [] : list();
			maybe(';');
			return node('return', start, { values });
		}
		if (maybe('break')) return node('break', start, {});
		if (maybe('goto')) return node('goto', start, { label: identifier() });
		if (maybe('::')) {
			const label = identifier();
			take('::');
			return node('label', start, { label });
		}
		const targets = [expression()];
		while (maybe(',')) targets.push(expression());
		if (maybe('=')) return node('assign', start, { targets, values: list() });
		if (targets.length !== 1 || targets[0].type !== 'call')
			throw Error('Lua statement at ' + start);
		return node('call-statement', start, { call: targets[0] });
	}
	function block(stops = []) {
		const out = [];
		while (peek() && !stops.includes(peek().value)) out.push(statement());
		return out;
	}
	const body = block();
	if (at !== tokens.length) throw Error('Lua unparsed owner');
	return { body, source };
}

/** Resolves lexical identities and records every write, control edge and physical publication. */
function luaGraph(source, globals = {}) {
	const tree = luaTree(source),
		records = [],
		nodes = [];
	const currentDepth = (env) => env.functionDepth ?? currentDepth(env.parent);
	const guards = (env) => env.guards ?? (env.parent ? guards(env.parent) : []);
	const global = new Map(
		Object.entries(globals).map(([name, kind]) => [name, { name, kind, writes: [], global: true }])
	);
	const lookup = (env, name) => {
		for (let e = env; e; e = e.parent) if (e.names.has(name)) return e.names.get(name);
		if (!global.has(name)) global.set(name, { name, global: true, writes: [] });
		return global.get(name);
	};
	function expression(e, env, live) {
		if (!e) return;
		e.live = live;
		nodes.push(e);
		if (e.type === 'id') e.binding = lookup(env, e.name);
		else if (e.type === 'function') {
			const scope = { names: new Map(), parent: env, functionDepth: currentDepth(env) + 1 };
			for (const p of e.params) if (p.type === 'id') declare(p, null, scope, 'parameter');
			bind(e.body, scope, true);
		} else if (e.type === 'table') {
			for (const f of e.fields) {
				expression(f.key, env, live);
				expression(f.value, env, live);
			}
		} else
			for (const key of ['object', 'key', 'callee', 'value', 'left', 'right'])
				if (e[key] && typeof e[key] === 'object') expression(e[key], env, live);
		if (e.type === 'call') for (const a of e.args) expression(a, env, live);
	}
	function declare(id, value, env, kind) {
		let scope = env;
		while (scope.functionDepth === undefined) scope = scope.parent;
		const record = {
			name: id.name,
			value,
			kind,
			writes: [],
			declaration: id,
			global: false,
			functionDepth: scope.functionDepth
		};
		env.names.set(id.name, record);
		id.binding = record;
		records.push(record);
		return record;
	}
	const constant = (e) => {
		const value = luaTruth(e, new Map());
		return value === undefined ? undefined : value !== false && value !== null;
	};
	const hasBreak = (body) =>
		body.some(
			(s) =>
				s.type === 'break' ||
				(['if', 'do'].includes(s.type) &&
					(s.type === 'if' ? s.branches.some((b) => hasBreak(b.body)) : hasBreak(s.body)))
		);
	function terminal(s) {
		if (['return', 'goto'].includes(s.type)) return true;
		if (s.type === 'do') return ends(s.body);
		if (s.type === 'if') {
			for (const b of s.branches) if (b.test && constant(b.test) === true) return ends(b.body);
			return s.branches.at(-1)?.test === null && s.branches.every((b) => ends(b.body));
		}
		if (s.type === 'while' && constant(s.test) === true) return !hasBreak(s.body);
		if (s.type === 'repeat')
			return ends(s.body) || (constant(s.test) === false && !hasBreak(s.body));
		return false;
	}
	const ends = (body) => body.some(terminal);
	function bind(body, env, live) {
		let running = live;
		for (const s of body) {
			s.live = running;
			s.guards = guards(env);
			nodes.push(s);
			if (s.type === 'local') {
				s.values.forEach((v) => expression(v, env, running));
				s.names.forEach((n, i) => {
					const record = declare(
						n,
						s.values[i] ?? (s.values.length === 1 ? s.values[0] : null),
						env,
						'local'
					);
					record.valueIndex = i;
					record.statement = s;
				});
			} else if (s.type === 'local-function') {
				const ref = declare(s.name, s.value, env, 'function');
				expression(s.value, env, running);
				ref.statement = s;
			} else if (s.type === 'assign-function') {
				expression(s.target, env, running);
				expression(s.value, env, running);
				if (s.target.type === 'id') s.target.binding.writes.push(s);
			} else if (s.type === 'assign') {
				s.values.forEach((v) => expression(v, env, running));
				for (const target of s.targets) {
					expression(target, env, running);
					if (target.type === 'id') target.binding.writes.push(s);
				}
			} else if (s.type === 'if') {
				let earlierAlways = false;
				for (const b of s.branches) {
					expression(b.test, env, running);
					const value = b.test ? constant(b.test) : true;
					bind(
						b.body,
						{ names: new Map(), parent: env, guards: [...guards(env), b.test] },
						running && !earlierAlways && value !== false
					);
					if (value === true) earlierAlways = true;
				}
			} else if (['do', 'while', 'repeat'].includes(s.type)) {
				expression(s.test, env, running);
				bind(
					s.body,
					{ names: new Map(), parent: env },
					running && (s.type !== 'while' || constant(s.test) !== false)
				);
			} else if (s.type === 'for') {
				s.values.forEach((v) => expression(v, env, running));
				const scope = { names: new Map(), parent: env };
				s.names.forEach((n) => declare(n, null, scope, 'iteration'));
				bind(s.body, scope, running);
			} else if (s.type === 'return') s.values.forEach((v) => expression(v, env, running));
			else if (s.type === 'call-statement') expression(s.call, env, running);
			if (terminal(s)) running = false;
		}
	}
	bind(tree.body, { names: new Map(), parent: null, functionDepth: 0 }, true);
	return { ...tree, records, nodes, globals: global };
}

function luaField(table, key) {
	return table?.type === 'table'
		? table.fields.filter((f) => f.key?.type === 'string' && f.key.value === key)
		: [];
}
function luaSame(e, record) {
	return e?.type === 'id' && e.binding === record && record.writes.length === 0;
}
function luaLocal(graph, name) {
	const found = graph.records.filter(
		(r) =>
			r.name === name &&
			r.functionDepth === (graph.ownerDepth ?? 0) &&
			r.declaration &&
			r.declaration.start >= 0
	);
	if (found.length !== 1) throw Error('One actual Lua binding ' + name);
	return found[0];
}
function luaCall(e, name, method) {
	return (
		e?.type === 'call' &&
		e.live !== false &&
		(method
			? e.callee.type === 'field' &&
				e.callee.key === method &&
				e.callee.object.type === 'id' &&
				e.callee.object.name === name
			: e.callee.type === 'id' && e.callee.name === name)
	);
}
function luaTruth(expression, assumptions) {
	if (!expression) return undefined;
	if (expression.type === 'id') return assumptions.get(expression.binding);
	if (['literal', 'string', 'number'].includes(expression.type)) return expression.value;
	if (expression.type === 'unary' && expression.op === 'not') {
		const value = luaTruth(expression.value, assumptions);
		return value === undefined ? undefined : !(value !== false && value !== null);
	}
	if (expression.type === 'call' && expression.callee.name === 'type') {
		const value = luaTruth(expression.args[0], assumptions);
		return value?.canonical ? 'table' : typeof value === 'boolean' ? 'boolean' : undefined;
	}
	if (expression.type === 'binary') {
		const left = luaTruth(expression.left, assumptions),
			right = luaTruth(expression.right, assumptions);
		if (expression.op === 'or') {
			if (left !== undefined && left !== false && left !== null) return left;
			return left !== undefined ? right : undefined;
		}
		if (expression.op === 'and') {
			if (left === false || left === null) return left;
			return left !== undefined ? right : undefined;
		}
		if (left === undefined || right === undefined) return undefined;
		if (expression.op === '==') return left === right;
		if (expression.op === '~=') return left !== right;
	}
	return undefined;
}
function luaCanonical(record) {
	const e = record.value;
	if (
		!(
			(luaCall(e, 'require') &&
				e.callee.binding.global &&
				e.callee.binding.writes.length === 0 &&
				e.args[0]?.type === 'string' &&
				e.args[0].value === 'infra.manifest_menu') ||
			(luaCall(e, 'pcall') &&
				e.callee.binding.global &&
				e.callee.binding.writes.length === 0 &&
				e.args[0]?.binding?.global &&
				e.args[0].binding.writes.length === 0 &&
				record.valueIndex === 1 &&
				e.args[0]?.name === 'require' &&
				e.args[1]?.type === 'string' &&
				e.args[1].value === 'infra.manifest_menu')
		)
	)
		return false;
	const assumptions = new Map([[record, { canonical: true }]]);
	for (const name of record.statement?.names ?? [])
		if (name.binding.valueIndex === 0 && luaCall(e, 'pcall')) assumptions.set(name.binding, true);
	return record.writes.every(
		(write) =>
			write.targets.every((target) => target.binding === record) &&
			write.values.length === 1 &&
			write.values[0].type === 'literal' &&
			write.values[0].value === null &&
			write.guards.some((test) => luaTruth(test, assumptions) === false)
	);
}
function luaPhysicalFunction(moduleGraph, name) {
	if (name.includes('.')) {
		const [object, key] = name.split('.');
		const statements = moduleGraph.body.filter(
			(n) =>
				n.type === 'assign-function' &&
				n.target.type === 'field' &&
				n.target.object.name === object &&
				n.target.key === key
		);
		if (statements.length !== 1 || !statements[0].live)
			throw Error('One actual published Lua method');
		const binding = statements[0].target.object.binding;
		const writes = moduleGraph.nodes
			.filter((n) => ['assign', 'assign-function'].includes(n.type))
			.flatMap((n) => (n.type === 'assign' ? n.targets : [n.target]))
			.filter(
				(t) =>
					t.type === 'field' &&
					t.key === key &&
					t.object.type === 'id' &&
					t.object.binding === binding
			);
		if (
			writes.length !== 1 ||
			!moduleGraph.body.some(
				(n) =>
					n.type === 'return' && n.live && n.values.length === 1 && luaSame(n.values[0], binding)
			)
		)
			throw Error('Actual published method retained through module export');
		return statements[0].value;
	}
	const record = luaLocal(moduleGraph, name);
	if (record.kind !== 'function' || record.writes.length || !record.statement.live)
		throw Error('Actual Lua producer binding required');
	return record.value;
}
function luaOwnerGraph(moduleGraph, value) {
	const start = value.body[0]?.start ?? value.end,
		end = value.end;
	const ownerDepth =
		value.params.find((p) => p.binding)?.binding.functionDepth ??
		Math.min(
			...moduleGraph.records
				.filter((r) => r.declaration.start >= start && r.declaration.start < end)
				.map((r) => r.functionDepth)
		);
	return {
		...moduleGraph,
		body: value.body,
		ownerDepth,
		records: moduleGraph.records.filter(
			(r) => r.declaration.start >= start && r.declaration.start < end
		),
		nodes: moduleGraph.nodes.filter((n) => n.start >= start && n.end < end)
	};
}
function luaRendererGraph(graph) {
	return graph.nodes
		.filter(
			(n) => n.type === 'field' && n.object?.type === 'id' && n.object.name === 'ManifestMenu'
		)
		.every((n) => luaCanonical(n.object.binding));
}
/** A tracked collection may only retain its identity and append native rows at its actual sink. */
function luaRetained(graph, record, append = false, dispatch = false) {
	if (record.writes.length) return false;
	const rooted = (e) =>
		e?.type === 'id'
			? e.binding === record
			: ['field', 'index'].includes(e?.type) && rooted(e.object);
	for (const n of graph.nodes) {
		if (n.type === 'assign')
			for (const t of n.targets)
				if (rooted(t)) {
					const key = t.key;
					if (
						!append ||
						t.type !== 'index' ||
						!luaSame(t.object, record) ||
						key?.type !== 'binary' ||
						key.op !== '+' ||
						key.left.type !== 'unary' ||
						key.left.op !== '#' ||
						!luaSame(key.left.value, record) ||
						key.right.type !== 'number' ||
						key.right.value !== 1
					)
						return false;
				}
		if (
			n.type === 'call' &&
			rooted(n.callee) &&
			!(dispatch && n.callee.type === 'index' && luaSame(n.callee.object, record))
		)
			return false;
	}
	return true;
}
function luaReturnBinding(graph, record, key) {
	return graph.nodes.some(
		(n) =>
			n.type === 'return' &&
			n.live &&
			n.values.some((e) =>
				key ? luaField(e, key).some((f) => luaSame(f.value, record)) : luaSame(e, record)
			)
	);
}
function luaFunctionBinding(graph, name) {
	const record = luaLocal(graph, name);
	return record.kind === 'function' && record.writes.length === 0 && record.statement.live
		? record
		: null;
}

/** Checks the actual complete Lua data/control graph through native parent and public registration. */
/** A retained genuine feature receiver carries the exact completed native child. */
function luaDeclaredHotstringsParent(native, source, child, platform) {
	const receive = luaLocal(native, 'receive');
	if (
		receive.writes.length ||
		bindings(source, '.lua', 'receive').length !== 1 ||
		(!luaCall(receive.value, 'ManifestMenu', 'group_receiver') &&
			!(
				platform === 'linux' &&
				receive.value?.type === 'binary' &&
				receive.value.op === 'and' &&
				luaCall(receive.value.right, 'ManifestMenu', 'group_receiver')
			))
	)
		return false;
	const captured = platform === 'linux' ? receive.value.right : receive.value;
	if (
		captured.args.length !== 2 ||
		captured.args[0]?.value !== 'top_level' ||
		captured.args[1]?.value !== 'hotstrings' ||
		!luaCanonical(captured.callee.object.binding)
	)
		return false;
	const shape = (text) => scriptTokens(text, '.lua').map((t) => [t.kind, t.value]);
	if (platform === 'hs') {
		const parent = luaLocal(native, 'parent');
		return (
			luaRetained(native, parent) &&
			luaCall(parent.value, 'receive') &&
			parent.value.callee.binding === receive &&
			luaSame(parent.value.args[0], child) &&
			route(source, '.lua', [
				['local receive = ManifestMenu.group_receiver("top_level", "hotstrings")'],
				['if not receive then return {} end'],
				['local hotstrings_menu = {}'],
				[
					'local parent = receive(hotstrings_menu, { hotstrings_enabled = function() return master_on or nil end, hotstrings_parent_total = function() return grand_total end, hotstrings_parent_count_present = function() return grand_has_count end })'
				],
				['return parent and { parent } or {}']
			]) &&
			isDeepStrictEqual(
				shape(source).slice(-shape('return parent and { parent } or {}').length),
				shape('return parent and { parent } or {}')
			)
		);
	}
	const terminal =
		'return receive(items, { hotstrings_enabled = function() return _hotstrings_on(ctx) end, hotstrings_parent_total = function() return grand_total end, hotstrings_parent_count_present = function() return true end })';
	return (
		route(source, '.lua', [
			['local receive = ManifestMenu and ManifestMenu.group_receiver("top_level", "hotstrings")'],
			['if not receive then return nil end'],
			['local items = _manifest_hotstring_rows(ctx, config)'],
			[terminal]
		]) && isDeepStrictEqual(shape(source).slice(-shape(terminal).length), shape(terminal))
	);
}

/** The actual Linux root keeps its imported raw facade and receiving cohort around all children. */
function luaDeclaredLinuxRoot(source, topGraph) {
	const expectedFacade = `return type(ManifestMenu) == "table" and getmetatable(ManifestMenu) == nil
		and rawget(package, "loaded") == separator_modules
		and rawget(separator_modules, "infra.manifest_menu") == ManifestMenu
		and type(separator_factory) == "function" and rawget(ManifestMenu, "top_level_separator_receiver") == separator_factory
		and type(separator_render) == "function" and rawget(ManifestMenu, "render_rows") == separator_render
		and type(separator_array) == "function" and rawget(ManifestMenu, "get_array") == separator_array
		and type(separator_root) == "function" and rawget(ManifestMenu, "get_root") == separator_root`;
	const shape = (text) => scriptTokens(text, '.lua').map((t) => [t.kind, t.value]);
	if (
		!isDeepStrictEqual(
			shape(owner(source, 'local function separator_facade_current()', '.lua')),
			shape(expectedFacade)
		) ||
		bindings(source, '.lua', 'separator_facade_current').length
	)
		return false;
	for (const [name, value] of [
		['separator_modules', 'package.loaded'],
		[
			'separator_factory',
			'type(ManifestMenu) == "table" and rawget(ManifestMenu, "top_level_separator_receiver")'
		],
		['separator_render', 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")'],
		['separator_array', 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_array")'],
		['separator_root', 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_root")']
	])
		if (
			ranges(source, 'local ' + name + ' = ' + value, '.lua').length !== 1 ||
			bindings(source, '.lua', name).length !== 1
		)
			return false;
	const top = owner(source, 'function M.build(ctx)', '.lua');
	const capture = `if not separator_facade_current() then return {} end
		local declared = ManifestMenu.get_array("top_level")
		if not separator_facade_current() then return {} end
		local receive_separator, source_rows = separator_factory()
		if not separator_facade_current() or type(receive_separator) ~= "function"
			or type(declared) ~= "table" or not rawequal(declared, source_rows) then
			Logger.error(LOG, "The canonical top-level boundary source is unavailable.")
			return {}
		end`;
	const finish = `if not separator_facade_current() or not receive_separator("current") then return {} end
		local rendered = separator_render(rows, "top_level")
		if not separator_facade_current() or not receive_separator("current") then return {} end
		return rendered`;
	const headerCapture = ranges(top, 'local header, header_current = _build_header(ctx)', '.lua');
	const withHeader =
		headerCapture.length === 1 &&
		require('./menu-native-llm-parent-binding.cjs').declaredLinuxTopLevelPublication(source);
	const terminal = withHeader
		? finish.replaceAll(
				'not receive_separator("current") then',
				'not receive_separator("current") or not header_current() then'
			)
		: finish;
	return (
		['declared', 'receive_separator', 'source_rows', 'rendered'].every(
			(name) => luaLocal(topGraph, name).writes.length === 0
		) &&
		route(top, '.lua', [
			[capture],
			['for _, row in ipairs(declared) do'],
			[
				'if not separator_facade_current() or not receive_separator("current") then return {} end if type(row) == "table" then',
				1
			],
			['local build = builders[id]', 3],
			['rows[#rows + 1] = build(ctx)', 4],
			[
				'if not separator_facade_current() or not receive_separator("current") then return {} end end if quit_row then',
				1
			],
			[terminal]
		]) &&
		isDeepStrictEqual(shape(top).slice(-shape(terminal).length), shape(terminal))
	);
}

/** The actual Linux enclosing build retains its result through its final refusal and return. */
function luaLinuxHotstringsResult(outer, built, source) {
	const rows = luaLocal(outer, 'rows');
	const terminal =
		'local rows = ManifestMenu.build("hotstrings_menu", "Hotstrings", nil, group_builders, hs_ctx, providers)\nif not personal_choices_admitted then return nil end\nreturn rows';
	const shape = (text) => scriptTokens(text, '.lua').map((token) => [token.kind, token.value]);
	return (
		rows.statement.live &&
		rows.value?.live &&
		rows.value === built &&
		luaRetained(outer, rows) &&
		luaReturnBinding(outer, rows) &&
		route(source, '.lua', [
			[
				'local rows = ManifestMenu.build("hotstrings_menu", "Hotstrings", nil, group_builders, hs_ctx, providers)'
			],
			['if not personal_choices_admitted then return nil end'],
			['return rows']
		]) &&
		isDeepStrictEqual(shape(source).slice(-shape(terminal).length), shape(terminal))
	);
}

function luaHotstringGraph(sources, platform) {
	const source = sources[files[platform][0]],
		moduleGraph = luaGraph(source);
	if (platform === 'linux') {
		const producer = luaLocal(moduleGraph, '_manifest_hotstring_rows'),
			outer = luaOwnerGraph(
				moduleGraph,
				luaPhysicalFunction(moduleGraph, '_manifest_hotstring_rows')
			);
		if (!luaRendererGraph(outer)) return false;
		const languageValue = luaPhysicalFunction(
			{ ...outer, ownerDepth: outer.ownerDepth },
			'language_rows'
		);
		const languageGraph = luaOwnerGraph(moduleGraph, languageValue);
		for (const name of ['rows', 'switch', 'categories', 'items', 'parents'])
			if (
				!luaRetained(
					languageGraph,
					luaLocal(languageGraph, name),
					['rows', 'categories'].includes(name)
				)
			)
				return false;
		const language = luaFunctionBinding(outer, 'language_rows');
		if (!language) return false;
		const providers = luaLocal(outer, 'providers');
		if (!luaRetained(outer, providers)) return false;
		const field = luaField(providers.value, 'hotstring_languages');
		if (field.length !== 1 || !luaSame(field[0].value, language)) return false;
		const built = outer.nodes.filter(
			(n) => luaCall(n, 'ManifestMenu', 'build') && n.args[0]?.value === 'hotstrings_menu'
		);
		if (
			built.length !== 1 ||
			!luaSame(built[0].args[5], providers) ||
			!luaLinuxHotstringsResult(
				outer,
				built[0],
				owner(source, 'local function _manifest_hotstring_rows(ctx, config)', '.lua')
			)
		)
			return false;
		const nativeProducer = luaLocal(moduleGraph, '_build_hotstrings'),
			native = luaOwnerGraph(moduleGraph, luaPhysicalFunction(moduleGraph, '_build_hotstrings'));
		const items = luaLocal(native, 'items');
		if (
			!luaRetained(native, items) ||
			!luaCall(items.value, '_manifest_hotstring_rows') ||
			items.value.callee.binding !== producer ||
			producer.writes.length ||
			!(
				luaReturnBinding(native, items, 'submenu') ||
				luaDeclaredHotstringsParent(
					native,
					owner(sources[files.linux[0]], 'local function _build_hotstrings(ctx)', '.lua'),
					items,
					'linux'
				)
			)
		)
			return false;
		const top = luaOwnerGraph(moduleGraph, luaPhysicalFunction(moduleGraph, 'M.build'));
		const builders = luaLocal(top, 'builders'),
			registered = luaField(builders.value, 'hotstrings');
		if (
			!luaRetained(top, builders, false, true) ||
			registered.length !== 1 ||
			registered[0].value.type !== 'id' ||
			registered[0].value.binding !== nativeProducer ||
			nativeProducer.writes.length
		)
			return false;
		const rows = luaLocal(top, 'rows'),
			dispatch = luaLocal(top, 'build');
		if (!luaRetained(top, rows, true)) return false;
		if (
			dispatch.writes.length ||
			dispatch.value?.type !== 'index' ||
			!luaSame(dispatch.value.object, builders)
		)
			return false;
		const rowWrites = top.nodes.filter(
			(n) =>
				n.type === 'assign' &&
				n.live &&
				n.targets.some((t) => t.type === 'index' && luaSame(t.object, rows)) &&
				n.values.some((v) => luaCall(v, 'build') && v.callee.binding === dispatch)
		);
		const rendered = top.nodes.filter(
			(n) =>
				luaCall(n, 'ManifestMenu', 'render_rows') &&
				luaSame(n.args[0], rows) &&
				n.args[1]?.value === 'top_level'
		);
		return (
			rowWrites.length === 1 &&
			((rendered.length === 1 &&
				top.nodes.some((n) => n.type === 'return' && n.live && n.values.includes(rendered[0]))) ||
				(luaDeclaredLinuxRoot(sources[files.linux[0]], top) &&
					top.nodes.some(
						(n) =>
							luaCall(n, 'separator_render') &&
							luaSame(n.args[0], rows) &&
							n.args[1]?.value === 'top_level'
					))) &&
			luaRendererGraph(native) &&
			luaRendererGraph(top)
		);
	}
	const customModule = luaGraph(sources[files.hs[2]]),
		scopeModule = luaGraph(sources[files.hs[1]]);
	const custom = luaLocal(customModule, 'Custom'),
		bulk = luaOwnerGraph(
			customModule,
			luaPhysicalFunction(customModule, 'M.build_language_bulk_actions')
		);
	if (
		custom.writes.length ||
		!luaCall(custom.value, 'require') ||
		!custom.value.callee.binding.global ||
		custom.value.args[0]?.value !== 'ui.menu.menu_hotstrings_custom'
	)
		return false;
	const call = bulk.nodes.filter((n) => luaCall(n, 'Custom', 'all_sections_row'));
	if (call.length !== 1 || call[0].callee.object.binding !== custom) return false;
	if (
		!luaRendererGraph(
			luaOwnerGraph(scopeModule, luaPhysicalFunction(scopeModule, 'M.all_sections_row'))
		)
	)
		return false;
	const nativeProducer = luaLocal(moduleGraph, 'build_hotstrings_rows'),
		native = luaOwnerGraph(moduleGraph, luaPhysicalFunction(moduleGraph, 'build_hotstrings_rows'));
	if (!luaRendererGraph(native)) return false;
	const languages = luaLocal(native, 'language_rows'),
		providers = luaLocal(native, 'providers');
	for (const record of native.records.filter(
		(r) =>
			r.functionDepth === native.ownerDepth &&
			['language_rows', 'bulk', 'categories', 'items', 'parents'].includes(r.name)
	))
		if (!luaRetained(native, record, record.name === 'language_rows')) return false;
	const field = luaField(providers.value, 'hotstring_languages');
	if (
		!luaRetained(native, languages, true) ||
		!luaRetained(native, providers) ||
		field.length !== 1 ||
		field[0].value.type !== 'function'
	)
		return false;
	const callback = field[0].value;
	if (
		callback.body.length !== 1 ||
		callback.body[0].type !== 'return' ||
		!luaSame(callback.body[0].values[0], languages)
	)
		return false;
	const rendered = luaLocal(native, 'rendered'),
		menu = luaLocal(native, 'hotstrings_menu');
	if (
		!luaCall(rendered.value, 'ManifestMenu', 'build') ||
		!luaSame(rendered.value.args[5], providers) ||
		rendered.writes.length ||
		menu.writes.length
	)
		return false;
	const append = native.nodes.filter(
		(n) => luaCall(n, 'table', 'insert') && luaSame(n.args[0], menu)
	);
	if (append.length !== 1) return false;
	const output = native.nodes.filter(
		(n) =>
			n.type === 'return' &&
			n.live &&
			n.values[0]?.type === 'table' &&
			n.values[0].fields.some((f) =>
				luaField(f.value, 'submenu').some((p) => luaSame(p.value, menu))
			)
	);
	if (
		output.length !== 1 &&
		!luaDeclaredHotstringsParent(
			native,
			owner(sources[files.hs[0]], 'local function build_hotstrings_rows(ctx, menu_mods)', '.lua'),
			menu,
			'hs'
		)
	)
		return false;
	const top = luaOwnerGraph(moduleGraph, luaPhysicalFunction(moduleGraph, 'M.generate'));
	const builders = luaLocal(top, 'builders'),
		registration = luaField(builders.value, 'hotstrings');
	if (
		!luaRetained(top, builders, false, true) ||
		registration.length !== 1 ||
		registration[0].value.type !== 'function'
	)
		return false;
	const publicBody = registration[0].value.body;
	if (
		publicBody.length !== 1 ||
		publicBody[0].type !== 'return' ||
		!luaCall(publicBody[0].values[0], 'build_hotstrings_rows') ||
		publicBody[0].values[0].callee.binding !== nativeProducer ||
		nativeProducer.writes.length
	)
		return false;
	const items = luaLocal(top, 'items'),
		root = luaLocal(top, 'rendered');
	if (
		!luaRetained(top, items, true) ||
		!luaRetained(top, root, true) ||
		!(
			luaCall(root.value, 'ManifestMenu', 'render_rows') ||
			(luaCall(root.value, 'separator_render') &&
				require('./menu-native-llm-parent-binding.cjs').declaredMacTopLevelPublication(
					sources[files.hs[0]]
				))
		) ||
		!luaSame(root.value.args[0], items) ||
		!luaReturnBinding(top, root)
	)
		return false;
	const appendRoot = top.nodes.filter(
		(n) =>
			luaCall(n, 'table', 'insert') &&
			luaSame(n.args[0], items) &&
			n.args[1]?.type === 'id' &&
			n.args[1].binding.kind === 'iteration'
	);
	return appendRoot.length === 1 && luaRendererGraph(top);
}

/** Keeps the one label, checkmark getter and original native scope callback causal. */
function hotstringScopePublication(source, platform, manifest) {
	try {
		if (
			!isDeepStrictEqual(manifest.hotstring_scope_checkbox, declarations.hotstring_scope_checkbox)
		)
			return false;
		if (platform === 'ahk')
			return route(owner(source, '_HS_AllSectionsRow(AllOn, Apply) {', '.ahk'), '.ahk', [
				[
					'return MenuRenderer_CheckRow("hotstring_scope_checkbox", "hotstring_scope_all_sections", Map("hotstring_scope_all_sections", (*) => Apply(!AllOn)), Map("hotstring_scope_all_on", (*) => AllOn ? true : false))'
				]
			]);
		if (
			platform === 'hs' &&
			ranges(source, 'local ManifestMenu = require("infra.manifest_menu")', '.lua').length !== 1
		)
			return false;
		if (platform === 'hs')
			return route(
				owner(source, 'function M.all_sections_row(ctx, group_names, set_fn)', '.lua'),
				'.lua',
				[
					['local all_on = M.all_sections_on(ctx, group_names)'],
					[
						'local row = ManifestMenu.check_row("hotstring_scope_checkbox", "hotstring_scope_all_sections", { hotstring_scope_all_sections = function() return false end }, { hotstring_scope_all_on = function() return all_on end })'
					],
					['if not row then return nil end'],
					['row.disabled = ctx.paused or nil'],
					['row.action = not ctx.paused and set_fn(not all_on) or nil'],
					['return row']
				]
			);
		if (
			platform !== 'linux' ||
			ranges(source, 'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")', '.lua')
				.length !== 1
		)
			return false;
		const outer = owner(source, 'local function _manifest_hotstring_rows(ctx, config)', '.lua');
		return route(owner(outer, 'local function all_sections_row(ids)', '.lua'), '.lua', [
			['local all_on = sections_all_on(ids)'],
			['local action = function()'],
			['called, committed = pcall(config.set_categories_sections, ids, not all_on)', 2],
			['if called and committed == true then return true end', 1],
			[
				'return ManifestMenu.check_row("hotstring_scope_checkbox", "hotstring_scope_all_sections", { hotstring_scope_all_sections = action }, { hotstring_scope_all_on = function() return all_on end })'
			]
		]);
	} catch {
		return false;
	}
}

/** Admits only an actual registered language producer and its completed canonical frame. */
/** Retains the completed native Hotstrings child through its declared parent receiver.
 * The finite publication helper checks the row's exact native child identity before
 * AddFeature, propagates the declared checked state and disposes a refused child.
 */
function ahkDeclaredHotstringsTransport(stage, consumer) {
	const capture = 'Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")';
	const publish =
		'_MI_StageDeclaredFeature(Receiver, HotstringsMenu, Map("hotstrings_enabled", () => HotstringsAllEnabled, "hotstrings_parent_total", () => HotstringsTotal, "hotstrings_parent_count_present", () => true), true)';
	const prefix = scriptTokens(
		capture +
			`
		if !Receiver
			throw Error("The declared hotstrings feature parent was refused before native construction.")`,
		'.ahk'
	);
	const initial = scriptTokens(stage, '.ahk').slice(0, prefix.length);
	if (
		!isDeepStrictEqual(
			initial.map((t) => [t.kind, t.value]),
			prefix.map((t) => [t.kind, t.value])
		)
	)
		return false;
	if (
		!route(stage, '.ahk', [
			[capture],
			['HotstringsMenu := MenuRenderer_Build("hotstrings_menu"'],
			[publish]
		]) ||
		!retainedChild(stage, '.ahk', 'Receiver', capture, publish, 0) ||
		!retainedChild(
			stage,
			'.ahk',
			'HotstringsMenu',
			'HotstringsMenu := MenuRenderer_Build("hotstrings_menu"',
			publish,
			0
		) ||
		!route(stage, '.ahk', [
			[
				`if !Receiver
			throw Error("The declared hotstrings feature parent was refused before native construction.")`
			]
		])
	)
		return false;
	const actual = owner(
		consumer,
		'_MI_StageDeclaredFeature(Receiver, Child, Getters, DisposeOnRefusal := false) {',
		'.ahk'
	);
	const expected = `
		Published := false
		try {
			Row := Receiver.Call(Child, Getters)
			if !(Row is Map) || Row.Get("submenu", false) != Child
				throw Error("The canonical feature parent changed during native construction.")
			TrayMenuStage_AddFeature(Row["label"], Child)
			Published := true
			if Row.Get("checked", false)
				TrayMenuStage_Check(Row["label"])
			return true
		} finally {
			if DisposeOnRefusal && !Published {
				try Child.Delete()
				finally MenuDispatcher_PruneMenu(Child)
			}
		}
	`;
	const shape = (text) => scriptTokens(text, '.ahk').map((token) => [token.kind, token.value]);
	return isDeepStrictEqual(shape(actual), shape(expected));
}

function hotstringLanguagePublication(sources, manifest, platform, target) {
	try {
		if (!files[platform] || !Object.hasOwn(declarations, target)) return false;
		if (target === 'hotstring_language_parent_windows' && platform !== 'ahk') return false;
		if (target === 'hotstring_language_parent_lua' && platform === 'ahk') return false;
		for (const key of [
			'hotstring_scope_checkbox',
			'hotstring_language_frame',
			platform === 'ahk' ? 'hotstring_language_parent_windows' : 'hotstring_language_parent_lua'
		])
			if (!isDeepStrictEqual(manifest[key], declarations[key])) return false;
		if (
			!Array.isArray(manifest.hotstrings_menu) ||
			manifest.hotstrings_menu.filter(
				(row) => row.type === 'list' && row.id === 'hotstring_languages'
			).length !== 1
		)
			return false;
		const [languageFile, scopeFile, consumerFile] = files[platform];
		const source = sources[languageFile],
			scope = sources[scopeFile || languageFile];
		if (!hotstringScopePublication(scope, platform, manifest)) return false;
		if (platform !== 'ahk' && !luaHotstringGraph(sources, platform)) return false;
		if (platform === 'ahk') {
			const language = owner(source, '_HS_LanguageRows() {', '.ahk');
			const stage = owner(sources[consumerFile], '_MI_StageHotstrings() {', '.ahk');
			const directTransport =
				retainedChild(
					stage,
					'.ahk',
					'HotstringsMenu',
					'HotstringsMenu := MenuRenderer_Build("hotstrings_menu"',
					'TrayMenuStage_AddFeature(HotstringsMenuTitle, HotstringsMenu)',
					0
				) &&
				route(stage, '.ahk', [['TrayMenuStage_AddFeature(HotstringsMenuTitle, HotstringsMenu)']]);
			if (!directTransport && !ahkDeclaredHotstringsTransport(stage, sources[consumerFile]))
				return false;
			// Bind the real assigned symbol, including the separately owned reserved-name repair.
			const tokens = scriptTokens(language, '.ahk'),
				level = depths(tokens, '.ahk');
			const assignments = tokens.flatMap((token, index) =>
				level[index] === 1 &&
				token.kind === 'identifier' &&
				tokens[index + 1]?.value === ':=' &&
				tokens[index + 2]?.value === '_HS_LanguageSwitchRow' &&
				tokens[index + 3]?.value === '(' &&
				tokens[index + 4]?.value === 'Pack' &&
				tokens[index + 5]?.value === ')'
					? [token.value]
					: []
			);
			if (assignments.length !== 1) return false;
			const bound = assignments[0];
			for (const [name, captured, consumed, depth, useDepth = depth] of [
				[
					bound,
					bound + ' := _HS_LanguageSwitchRow(Pack)',
					'Items := MenuRenderer_TemplateRows("hotstring_language_frame"',
					1
				],
				[
					'Categories',
					'Categories := []',
					'Items := MenuRenderer_TemplateRows("hotstring_language_frame"',
					1
				],
				[
					'Items',
					'Items := MenuRenderer_TemplateRows("hotstring_language_frame"',
					'Parents := MenuRenderer_TemplateRows("hotstring_language_parent_windows"',
					1
				],
				[
					'Parents',
					'Parents := MenuRenderer_TemplateRows("hotstring_language_parent_windows"',
					'Rows.Push(Parent)',
					1
				],
				['Rows', 'Rows := []', 'return Rows', 0]
			])
				if (!retainedChild(language, '.ahk', name, captured, consumed, depth, useDepth))
					return false;
			return (
				route(owner(sources[consumerFile], '_MI_TopLevelBuilders() {', '.ahk'), '.ahk', [
					['"hotstrings", _MI_StageHotstrings,']
				]) &&
				route(owner(scope, '_HS_LanguageSwitchRow(Pack) {', '.ahk'), '.ahk', [
					['Gates.Push(Cat["v1"])', 1],
					['Paths.Push(V2Path)', 1],
					[
						'return _HS_AllSectionsRow(_HS_ScopeAllOn(Gates, Paths), ((p) => (Bool) => ToggleLanguageAllSections(p, Bool))(Pack))'
					]
				]) &&
				route(language, '.ahk', [
					['for _, Pack in HotstringsLanguageCategories() {'],
					[bound + ' := _HS_LanguageSwitchRow(Pack)', 1],
					[
						'Categories.Push(Map("label", GetCategoryTitle(V1Cat) . " (" . FmtCount(Total) . ")", "checked", IsCategoryGated(V1Cat) ? true : false, "submenu", SubMenus[V1Cat]))',
						2
					],
					[
						'Items := MenuRenderer_TemplateRows("hotstring_language_frame", Map(), Map(), Map("hotstring_language_switch", (*) => ' +
							bound +
							' is Map ? [' +
							bound +
							'] : [], "hotstring_language_categories", (*) => Categories))',
						1
					],
					['if !(Items is Array) || !(' + bound + ' is Map)', 1],
					[
						'Parents := MenuRenderer_TemplateRows("hotstring_language_parent_windows", Map(), Map("hotstring_language_name", HotstringsLanguageName.Bind(Pack["locale"]), "hotstring_language_count", (*) => FmtCount(LanguageTotal), "hotstring_language_icon", I18nFlagIconPath.Bind(Pack["locale"])), Map("hotstring_language_children", Items))',
						1
					],
					['Rows.Push(Parent)', 1],
					['return Rows']
				]) &&
				route(owner(sources[consumerFile], '_MI_StageHotstrings() {', '.ahk'), '.ahk', [
					['"hotstring_languages", (*) => _HS_LanguageRows(),'],
					[
						'HotstringsMenu := MenuRenderer_Build("hotstrings_menu", "Hotstrings", _HotDynHandlers, _HotGroupBuilders, _HotListProviders, _HotCommands, _HotGetters)'
					]
				])
			);
		}
		if (platform === 'hs') {
			if (
				ranges(source, 'local ManifestMenu = require("infra.manifest_menu")', '.lua').length !==
					1 ||
				ranges(
					sources[consumerFile],
					'local Custom = require("ui.menu.menu_hotstrings_custom")',
					'.lua'
				).length !== 1
			)
				return false;
			const native = owner(source, 'local function build_hotstrings_rows(ctx, menu_mods)', '.lua');
			const bulkOwner = owner(
				sources[consumerFile],
				'function M.build_language_bulk_actions(ctx, group_names)',
				'.lua'
			);
			if (bindings(bulkOwner, '.lua', 'Custom').length !== 0) return false;
			for (const [name, captured, consumed, depth, useDepth = depth] of [
				[
					'bulk',
					'local bulk = type(menu_mods.hotstrings.build_language_bulk_actions)',
					'local items = ManifestMenu.template_rows("hotstring_language_frame"',
					1
				],
				[
					'categories',
					'local categories = collect_groups(only, counts)',
					'local items = ManifestMenu.template_rows("hotstring_language_frame"',
					1
				],
				[
					'items',
					'local items = ManifestMenu.template_rows("hotstring_language_frame"',
					'ManifestMenu.template_rows("hotstring_language_parent_lua"',
					1,
					2
				],
				[
					'parents',
					'local parents = ManifestMenu.template_rows("hotstring_language_parent_lua"',
					'for _, row in ipairs(parents or {}) do language_rows',
					2
				],
				[
					'language_rows',
					'local language_rows = {}',
					'["hotstring_languages"] = function() return language_rows end,',
					0
				]
			])
				if (!retainedChild(native, '.lua', name, captured, consumed, depth, useDepth)) return false;
			return (
				route(
					owner(
						sources[consumerFile],
						'function M.build_language_bulk_actions(ctx, group_names)',
						'.lua'
					),
					'.lua',
					[
						[
							'return { Custom.all_sections_row(ctx, group_names, function(enable) return setGroupListSectionsFn(ctx, group_names, enable) end), }'
						]
					]
				) &&
				route(native, '.lua', [
					['for _, pack in ipairs(LANGUAGE_PACKS) do'],
					[
						'local bulk = type(menu_mods.hotstrings.build_language_bulk_actions) == "function" and menu_mods.hotstrings.build_language_bulk_actions(ctx, names) or {}',
						1
					],
					['local categories = collect_groups(only, counts)', 1],
					[
						'local items = ManifestMenu.template_rows("hotstring_language_frame", {}, {}, { hotstring_language_switch = function() return bulk end, hotstring_language_categories = function() return categories end, })',
						1
					],
					[
						'if items then local parents = ManifestMenu.template_rows("hotstring_language_parent_lua", {}, { hotstring_language_name = function() return language_label(pack.locale) end, hotstring_language_count = function() return fmt_grand(total) end, }, { hotstring_language_children = items })',
						1
					],
					['for _, row in ipairs(parents or {}) do language_rows[#language_rows + 1] = row end', 2],
					['["hotstring_languages"] = function() return language_rows end,'],
					['local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")', 1],
					[
						'local rendered = ManifestMenu.build("hotstrings_menu", "Hotstrings", nil, group_builders, hs_ctx, providers)',
						2
					]
				]) &&
				route(owner(source, 'function M.generate(ctx, menu_mods, actions)', '.lua'), '.lua', [
					['["hotstrings"] = function() return build_hotstrings_rows(ctx, menu_mods) end,']
				])
			);
		}
		const outer = owner(source, 'local function _manifest_hotstring_rows(ctx, config)', '.lua');
		const language = owner(outer, 'local function language_rows()', '.lua');
		for (const [name, captured, consumed, depth, useDepth = depth] of [
			[
				'switch',
				'local switch, categories = all_sections_row(ids), {}',
				'local items = switch and ManifestMenu.template_rows("hotstring_language_frame"',
				1
			],
			[
				'categories',
				'local switch, categories = all_sections_row(ids), {}',
				'local items = switch and ManifestMenu.template_rows("hotstring_language_frame"',
				1
			],
			[
				'items',
				'local items = switch and ManifestMenu.template_rows("hotstring_language_frame"',
				'ManifestMenu.template_rows("hotstring_language_parent_lua"',
				1,
				2
			],
			[
				'parents',
				'local parents = ManifestMenu.template_rows("hotstring_language_parent_lua"',
				'for _, row in ipairs(parents or {}) do rows',
				2
			],
			['rows', 'local rows = {}', 'return rows', 0]
		])
			if (!retainedChild(language, '.lua', name, captured, consumed, depth, useDepth)) return false;
		return (
			route(owner(outer, 'local function language_rows()', '.lua'), '.lua', [
				['for _, pack in ipairs(language_packs) do'],
				['local switch, categories = all_sections_row(ids), {}', 1],
				['categories[#categories + 1] = group_row(id)', 3],
				[
					'local items = switch and ManifestMenu.template_rows("hotstring_language_frame", {}, {}, { hotstring_language_switch = function() return { switch } end, hotstring_language_categories = function() return categories end, })',
					1
				],
				['if items then', 1],
				[
					'local parents = ManifestMenu.template_rows("hotstring_language_parent_lua", {}, { hotstring_language_name = function() return language_label(pack.locale) end, hotstring_language_count = function() return string.format("%d", total) end, }, { hotstring_language_children = items })',
					2
				],
				['for _, row in ipairs(parents or {}) do rows[#rows + 1] = row end', 2],
				['return rows']
			]) &&
			route(outer, '.lua', [
				['["hotstring_languages"] = language_rows,'],
				[
					'local rows = ManifestMenu.build("hotstrings_menu", "Hotstrings", nil, group_builders, hs_ctx, providers)'
				],
				['if not personal_choices_admitted then return nil end'],
				['return rows']
			]) &&
			route(owner(source, 'local function _build_hotstrings(ctx)', '.lua'), '.lua', [
				['local items = _manifest_hotstring_rows(ctx, config)']
			])
		);
	} catch {
		return false;
	}
}

const PERSONAL_DEFAULT_CHOICES = {
	ahk: {
		signature: '_HS_PersonalRows(Options := unset) {',
		extension: '.ahk',
		row: 'DefaultChoice',
		collection: 'DefaultRows',
		depth: 3,
		frameDepth: 2,
		init: 'DefaultRows := []',
		append: 'DefaultRows.Push(DefaultChoice)',
		refusal: 'if !(DefaultChoice is Map)\n\t\t\t\treturn []',
		call: 'DefaultChoice := MenuRenderer_CheckRow("hotstring_personal_default_choice", "personal_default_section",\n\t\t\t\tMap("personal_default_section", _MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData, DefaultSectionMenu, DisambiguatedLabels)),\n\t\t\t\tMap("personal_default_section_label", ((Label) => (*) => Label)(SecLabel),\n\t\t\t\t\t"personal_default_section_selected", ((Selected) => (*) => Selected)(CurDefaultSec == SecName)))',
		frame:
			'DefaultCommands := Map("personal_default_none", (*) => _SetPersonalDefaultSection("", PersonalMenu, TomlData, DefaultSectionMenu, DisambiguatedLabels))\n\t\tDefaultGetters := Map("personal_default_unset", (*) => CurDefaultSec == "", "personal_default_boundary", (*) => true)\n\t\tDefaultProviders := Map("personal_default_choices", (*) => DefaultRows)\n\t\tDefaultFrame := MenuRenderer_TemplateRows("hotstring_personal_default_frame", DefaultCommands, DefaultGetters, DefaultProviders)',
		prefix:
			'DefaultRows := []\n\t\tfor _, SecName in TomlData["sections_order"] {\n\t\t\tif (SecName == "-")\n\t\t\t\tcontinue\n\t\t\tif !TomlData["sections"].Has(SecName)\n\t\t\t\tcontinue\n\t\t\tSecLabel := DisambiguatedLabels[SecName]',
		enclosure: 'if (PersonalTomlData != false) {',
		enclosureDepth: 1,
		sink: 'if MenuRenderer_AppendTemplate(DefaultSectionMenu, "hotstring_personal_default_frame", DefaultCommands, DefaultGetters, DefaultProviders, &WholeTreeAdmitted) != DefaultRows.Length + 1 || !WholeTreeAdmitted\n\t\t\treturn []'
	},
	hs: {
		signature: 'function M.build_custom(ctx, counts)',
		extension: '.lua',
		row: 'choice',
		collection: 'cat_choices',
		depth: 4,
		frameDepth: 0,
		init: 'local cat_choices = {}',
		append: 'table.insert(cat_choices, choice)',
		refusal: 'if type(choice) ~= "table" then return nil end',
		call: 'local choice = ManifestMenu.check_row("hotstring_personal_default_choice", "personal_default_section", {\n\t\t\t\t\t\t["personal_default_section"] = function()\n\t\t\t\t\t\t\tstate.custom_default_section = sname\n\t\t\t\t\t\t\tif ctx.hotstring_editor and type(ctx.hotstring_editor.set_default_section) == "function" then\n\t\t\t\t\t\t\t\tpcall(ctx.hotstring_editor.set_default_section, sname)\n\t\t\t\t\t\t\tend\n\t\t\t\t\t\t\tif ctx.save_prefs() ~= true then return false end\n\t\t\t\t\t\t\tctx.updateMenu()\n\t\t\t\t\t\tend,\n\t\t\t\t\t}, {\n\t\t\t\t\t\tpersonal_default_section_label = function() return lbl end,\n\t\t\t\t\t\tpersonal_default_section_selected = function() return selected end,\n\t\t\t\t\t})',
		frame:
			'local cat_menu = ManifestMenu.template_rows("hotstring_personal_default_frame", {\n\t\t["personal_default_none"] = none_action,\n\t}, {\n\t\t["personal_default_unset"] = function() return not state.custom_default_section end,\n\t\t["personal_default_boundary"] = function() return #cat_choices > 0 end,\n\t}, { ["personal_default_choices"] = function() return cat_choices end })',
		prefix:
			'local cat_choices = {}\n\tif type(personal_secs) == "table" then\n\t\tlocal has_real = false\n\t\tfor _, sec in ipairs(personal_secs) do\n\t\t\tif type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then\n\t\t\t\thas_real = true; break\n\t\t\tend\n\t\tend\n\t\tif has_real then\n\t\t\tfor _, sec in ipairs(personal_secs) do\n\t\t\t\tif type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then\n\t\t\t\t\tlocal lbl   = (type(sec.description) == "string" and sec.description ~= "")\n\t\t\t\t\t\tand sec.description or tostring(sec.name):gsub("_", " ")\n\t\t\t\t\tlbl = ctx.applyTriggerChar(lbl)\n\t\t\t\t\tlocal sname = sec.name\n\t\t\t\t\tlocal selected = (state.custom_default_section == sname) or nil',
		frameVariable: 'cat_menu'
	},
	linux: {
		signature: '["hotstring_personal"] = function()',
		extension: '.lua',
		row: 'choice',
		collection: 'choices',
		depth: 2,
		frameDepth: 1,
		init: 'local choices = {}',
		append: 'choices[#choices + 1] = choice',
		refusal:
			'if type(choice) ~= "table" then\n\t\t\t\t\t\tpersonal_choices_admitted = false\n\t\t\t\t\t\treturn {}\n\t\t\t\t\tend',
		call: 'local choice = ManifestMenu.check_row("hotstring_personal_default_choice", "personal_default_section", {\n\t\t\t\t\t\t["personal_default_section"] = function()\n\t\t\t\t\t\t\tEditor.set_pref("default_section", name)\n\t\t\t\t\t\t\tif type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end\n\t\t\t\t\t\tend,\n\t\t\t\t\t}, {\n\t\t\t\t\t\tpersonal_default_section_label = function() return name end,\n\t\t\t\t\t\tpersonal_default_section_selected = function() return selected end,\n\t\t\t\t\t})',
		frame:
			'local sub = ManifestMenu.template_rows("hotstring_personal_default_frame", {\n\t\t\t\t\t["personal_default_none"] = none_action,\n\t\t\t\t}, {\n\t\t\t\t\t["personal_default_unset"] = function() return current == nil or current == "" end,\n\t\t\t\t\t["personal_default_boundary"] = function() return false end,\n\t\t\t\t}, { ["personal_default_choices"] = function() return choices end })',
		prefix:
			'local choices = {}\n\n\t\t\t\tfor _, name in ipairs(personal and personal.sections_order or {}) do\n\t\t\t\t\tlocal selected = (current == name)',
		enclosure: 'if ok_editor and type(Editor.get_pref) == "function" then',
		enclosureDepth: 0,
		frameVariable: 'sub'
	}
};

/** The two actual unbraced refusal bodies are conditional children of their native guards. */
function personalDefaultChoiceFlow(body, proof) {
	const flow = paths(body, '.ahk');
	for (const [fragment, depth] of [
		[proof.refusal, proof.depth],
		['if !(DefaultFrame is Array)\n\t\t\treturn []', proof.frameDepth]
	]) {
		const found = ranges(body, fragment, '.ahk', depth);
		if (found.length !== 1) throw Error('One actual conditional default-choice refusal');
		const guard = found[0],
			returns = flow.tokens
				.map((token, index) => ({ token, index }))
				.filter(
					({ token }) =>
						token.value === 'return' && token.start > guard.start && token.end < guard.end
				);
		if (returns.length !== 1) throw Error('One actual guarded refusal body');
		const index = returns[0].index;
		flow.contexts[index] = [...flow.contexts[index], guard.index];
	}
	return flow;
}

/** Actual Linux check refusal invalidates this invocation's real enclosing build. */
function personalDefaultLinuxRefusal(moduleGraph, native, graph, proof, source) {
	const admitted = luaLocal(native, 'personal_choices_admitted'),
		rows = luaLocal(native, 'rows'),
		failure = ranges(
			owner(
				owner(source, 'local function _manifest_hotstring_rows(ctx, config)', '.lua'),
				proof.signature,
				'.lua'
			),
			proof.refusal,
			'.lua',
			proof.depth
		);
	if (
		failure.length !== 1 ||
		admitted.value?.type !== 'literal' ||
		admitted.value.value !== true ||
		!admitted.statement.live ||
		admitted.writes.length !== 1 ||
		!luaRetained(native, rows)
	)
		return false;
	const write = admitted.writes[0];
	if (
		!write.live ||
		write.type !== 'assign' ||
		write.targets.length !== 1 ||
		write.targets[0].binding !== admitted ||
		write.values.length !== 1 ||
		write.values[0].type !== 'literal' ||
		write.values[0].value !== false ||
		!graph.nodes.includes(write)
	)
		return false;
	const refusal = graph.nodes.filter(
		(node) =>
			node.type === 'if' && node.branches.length === 1 && node.branches[0].body.includes(write)
	);
	if (
		refusal.length !== 1 ||
		refusal[0].branches[0].body.length !== 2 ||
		refusal[0].branches[0].body[1].type !== 'return'
	)
		return false;
	const actual = owner(source, 'local function _manifest_hotstring_rows(ctx, config)', '.lua');
	if (
		!route(actual, '.lua', [
			['local personal_choices_admitted = true'],
			[
				'local rows = ManifestMenu.build("hotstrings_menu", "Hotstrings", nil, group_builders, hs_ctx, providers)'
			],
			['if not personal_choices_admitted then return nil end'],
			['return rows']
		])
	)
		return false;
	const terminal = native.nodes.filter(
		(node) =>
			node.type === 'if' &&
			node.branches.length === 1 &&
			node.branches[0].test?.type === 'unary' &&
			node.branches[0].test.op === 'not' &&
			node.branches[0].test.value.binding === admitted &&
			node.branches[0].body.length === 1 &&
			node.branches[0].body[0].type === 'return' &&
			node.branches[0].body[0].values.length === 1 &&
			node.branches[0].body[0].values[0].type === 'literal' &&
			node.branches[0].body[0].values[0].value === null
	);
	if (terminal.length !== 1 || !terminal[0].live || terminal[0].start <= rows.statement.end)
		return false;
	const parent = luaOwnerGraph(moduleGraph, luaPhysicalFunction(moduleGraph, '_build_hotstrings')),
		items = luaLocal(parent, 'items'),
		receive = luaLocal(parent, 'receive');
	return (
		luaCall(items.value, '_manifest_hotstring_rows') &&
		luaSame(items.value.callee, luaLocal(moduleGraph, '_manifest_hotstring_rows')) &&
		luaRendererGraph(native) &&
		luaRendererGraph(parent) &&
		luaRetained(parent, items) &&
		// Calling the retained native receiver is its real sink, not a data mutation.
		luaRetained(
			{
				...parent,
				nodes: parent.nodes.filter((node) => node.type !== 'call' || !luaSame(node.callee, receive))
			},
			receive
		) &&
		route(owner(source, 'local function _build_hotstrings(ctx)', '.lua'), '.lua', [
			['local receive = ManifestMenu and ManifestMenu.group_receiver("top_level", "hotstrings")'],
			['if not receive then return nil end'],
			['local items = _manifest_hotstring_rows(ctx, config)'],
			[
				'return receive(items, { hotstrings_enabled = function() return _hotstrings_on(ctx) end,\n\t\thotstrings_parent_total = function() return grand_total end, hotstrings_parent_count_present = function() return true end })'
			]
		])
	);
}

/** The actual default list consumes one typed shared checkbox per native section. */
function personalDefaultChoicePublication(source, platform, manifest) {
	try {
		if (!Object.hasOwn(PERSONAL_DEFAULT_CHOICES, platform)) return false;
		const expected = [['ahk', 'hs'], ['linux']].map((platforms) => ({
			type: 'check',
			id: 'personal_default_section',
			caption_source: 'native',
			caption_getter: 'personal_default_section_label',
			checked_when: ['personal_default_section_selected'],
			platforms,
			unavailable: 'hide'
		}));
		if (!isDeepStrictEqual(manifest?.hotstring_personal_default_choice, expected)) return false;
		const frame = manifest?.hotstring_personal_default_frame;
		if (
			!Array.isArray(frame) ||
			frame.filter((row) => row?.id === 'personal_default_choices').length !== 1 ||
			!isDeepStrictEqual(
				frame.find((row) => row?.id === 'personal_default_choices'),
				{ type: 'list', id: 'personal_default_choices' }
			)
		)
			return false;
		const proof = PERSONAL_DEFAULT_CHOICES[platform],
			extension = proof.extension;
		let body;
		if (platform === 'ahk') {
			body = owner(source, proof.signature, extension);
			if (
				bindings(body, extension, 'MenuRenderer_CheckRow').length ||
				bindings(body, extension, 'MenuRenderer_TemplateRows').length
			)
				return false;
		} else {
			const moduleGraph = luaGraph(source);
			const native = luaOwnerGraph(
				moduleGraph,
				luaPhysicalFunction(
					moduleGraph,
					platform === 'hs' ? 'M.build_custom' : '_manifest_hotstring_rows'
				)
			);
			let graph = native;
			if (platform === 'linux') {
				const providers = luaLocal(native, 'providers');
				const fields = luaField(providers.value, 'hotstring_personal');
				if (
					fields.length !== 1 ||
					fields[0].value.type !== 'function' ||
					!luaRetained(native, providers)
				)
					return false;
				graph = luaOwnerGraph(moduleGraph, fields[0].value);
			}
			const row = luaLocal(graph, proof.row),
				collection = luaLocal(graph, proof.collection),
				frame = luaLocal(graph, proof.frameVariable);
			if (
				!luaRendererGraph(graph) ||
				bindings(source, extension, '_ENV').length ||
				![row, collection, frame].every((record) => record.statement.live && record.value?.live) ||
				!luaRetained(graph, row) ||
				!luaRetained(graph, collection, true) ||
				!luaRetained(graph, frame)
			)
				return false;
			const facade = luaLocal(moduleGraph, 'ManifestMenu');
			const rootedFacade = (expression, seen = new Set()) => {
				if (expression?.type !== 'id') return false;
				if (expression.binding === facade) return true;
				const binding = expression.binding;
				if (!binding || seen.has(binding) || binding.writes.length) return false;
				seen.add(binding);
				return rootedFacade(binding.value, seen);
			};
			if (
				moduleGraph.nodes.some(
					(node) =>
						['assign', 'assign-function'].includes(node.type) &&
						(node.type === 'assign' ? node.targets : [node.target]).some(
							(target) => ['field', 'index'].includes(target.type) && rootedFacade(target.object)
						)
				)
			)
				return false;
			if (
				platform === 'linux' &&
				!personalDefaultLinuxRefusal(moduleGraph, native, graph, proof, source)
			)
				return false;
			body =
				platform === 'hs'
					? owner(source, proof.signature, extension)
					: owner(
							owner(source, 'local function _manifest_hotstring_rows(ctx, config)', extension),
							proof.signature,
							extension
						);
		}
		const statements = [
			...(proof.enclosure ? [[proof.enclosure, proof.enclosureDepth]] : []),
			[proof.prefix, proof.frameDepth],
			[proof.call, proof.depth],
			[proof.refusal, proof.depth],
			[proof.append, proof.depth],
			[proof.frame, proof.frameDepth],
			...(proof.sink ? [[proof.sink, proof.frameDepth]] : [])
		];
		if (
			!route(
				body,
				extension,
				statements,
				platform === 'ahk' ? personalDefaultChoiceFlow(body, proof) : paths(body, extension)
			)
		)
			return false;
		const sink = proof.sink ?? proof.frame;
		if (
			!retainedChild(body, extension, proof.row, proof.call, proof.append, proof.depth) ||
			!retainedChild(body, extension, proof.collection, proof.init, sink, proof.frameDepth)
		)
			return false;
		return (
			platform !== 'ahk' ||
			['DefaultCommands', 'DefaultGetters', 'DefaultProviders'].every((name) =>
				retainedChild(body, extension, name, proof.frame, proof.sink, proof.frameDepth)
			)
		);
	} catch {
		return false;
	}
}

module.exports = {
	hotstringScopePublication,
	hotstringLanguagePublication,
	personalDefaultChoicePublication,
	files
};

// This finite extension uses the already received Lua graph and physical-route machinery.
const PERSONAL_SECTION_FACTORY_BODY = `return function()
		if admission ~= nil then
			local ok, admitted = pcall(admission)
			if not ok or admitted ~= true then
				return KeymapLifecycle.commit_mutation(ctx, "admit personal file section", function() return false end)
			end
		end
		local will_enable = not (ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(group_name, sec_name) or false)
		if PersonalFiles.components(group_name) and require("infra.preferences").personal_choices_available({
			{ group = group_name, section = sec_name, enabled = will_enable },
		}) ~= true then
			return KeymapLifecycle.commit_mutation(ctx, "admit canonical personal section choice", function() return false end)
		end
		if will_enable and not KeymapLifecycle.ensure_started(ctx, "enable custom hotstring section") then return end
		local mutator
		if ctx.keymap then
			if will_enable then mutator = ctx.keymap.enable_section else mutator = ctx.keymap.disable_section end
		end
		KeymapLifecycle.commit_mutation(ctx, "toggle custom hotstring section", function()
			if type(mutator) ~= "function" then return false end
			return mutator(group_name, sec_name)
		end, function()
			if ctx.save_prefs() ~= true then return false end
			ctx.notify_feature(ctx.applyTriggerChar(sec_label or sec_name), will_enable)
			ctx.updateMenu()
		end)
	end`;

function personalSectionLocal(graph, name) {
	const found = graph.records.filter(
		(record) =>
			record.name === name &&
			record.kind === 'local' &&
			record.functionDepth === graph.ownerDepth &&
			record.statement.live &&
			record.value?.live
	);
	if (found.length !== 1) throw Error('One actual section local ' + name);
	return found[0];
}

function personalSectionParameters(value, names) {
	if (
		!isDeepStrictEqual(
			value.params.map((parameter) => parameter.name),
			names
		)
	)
		throw Error('Actual personal section parameters');
	if (value.params.some((parameter) => parameter.binding.writes.length))
		throw Error('Actual personal section parameter retained');
	return Object.fromEntries(value.params.map((parameter) => [parameter.name, parameter.binding]));
}

/** This family permits only its actual collection writes and authenticated handoffs.
 * New aliases, container captures and foreign argument escapes refuse conservatively.
 * No generic parser or renderer retention contract is changed.
 */
function personalSectionCustody(graph, records, writes = [], transfers = [], reads = []) {
	const roots = new Set(records),
		allowedWrites = new Set(writes),
		allowedTransfers = new Set(transfers),
		allowedReads = new Set(reads);
	const touches = (expression) =>
		expression &&
		graph.nodes.some(
			(node) =>
				node.type === 'id' &&
				roots.has(node.binding) &&
				node.start >= expression.start &&
				node.end <= expression.end
		);
	for (const record of graph.records) {
		if (record.value && touches(record.value) && !allowedTransfers.has(record.value)) return false;
	}
	for (const node of graph.nodes) {
		if (
			node.type === 'assign' &&
			!allowedWrites.has(node) &&
			[...node.targets, ...node.values].some(touches)
		)
			return false;
		if (node.type === 'assign-function' && [node.target, node.value].some(touches)) return false;
		if (node.type !== 'call' || ![node.callee, ...node.args].some(touches)) continue;
		if (allowedTransfers.has(node)) continue;
		const read =
			allowedReads.has(node) &&
			node.callee.type === 'id' &&
			['type', 'ipairs'].includes(node.callee.name) &&
			node.callee.binding.global &&
			!node.callee.binding.writes.length &&
			node.args.length === 1 &&
			node.args[0].type === 'id' &&
			roots.has(node.args[0].binding);
		if (!read) return false;
	}
	return true;
}

/** The genuine personal content list receives the shared Mac section check leaves. */
function personalSectionChoicePublication(source, platform, manifest) {
	try {
		if (
			platform !== 'hs' ||
			!isDeepStrictEqual(manifest?.hotstring_personal_section_choice, [
				{
					type: 'check',
					id: 'personal_section_toggle',
					caption_source: 'native',
					caption_getter: 'personal_section_label',
					checked_when: ['personal_section_selected'],
					disabled_when: ['personal_section_ready'],
					platforms: ['hs'],
					unavailable: 'hide'
				}
			])
		)
			return false;
		const rows = manifest?.hotstring_personal_content_frame;
		if (
			!Array.isArray(rows) ||
			rows.filter((row) => row?.id === 'personal_main_sections').length !== 1 ||
			!isDeepStrictEqual(
				rows.find((row) => row?.id === 'personal_main_sections'),
				{ type: 'list', id: 'personal_main_sections' }
			)
		)
			return false;
		const moduleGraph = luaGraph(source),
			nativeValue = luaPhysicalFunction(moduleGraph, 'M.build_custom'),
			native = luaOwnerGraph(moduleGraph, nativeValue),
			context = personalSectionParameters(nativeValue, ['ctx', 'counts']).ctx,
			facade = luaLocal(moduleGraph, 'ManifestMenu'),
			sectionOwner = luaFunctionBinding(native, 'append_section_rows'),
			factory = luaFunctionBinding(moduleGraph, 'toggleSectionFn'),
			scopeOwner = luaFunctionBinding(native, 'scope_menu');
		if (
			!sectionOwner ||
			!factory ||
			!scopeOwner ||
			!luaRendererGraph(native) ||
			bindings(source, '.lua', '_ENV').length
		)
			return false;
		const rooted = (expression, record, seen = new Set()) => {
			if (expression?.type !== 'id') return false;
			if (expression.binding === record) return true;
			const alias = expression.binding;
			if (!alias || alias.writes.length || seen.has(alias)) return false;
			seen.add(alias);
			return rooted(alias.value, record, seen);
		};
		const imports = {
			ManifestMenu: 'infra.manifest_menu',
			PersonalFileScope: 'infra.personal_file_scope',
			KeymapLifecycle: 'ui.menu.keymap_lifecycle',
			PersonalFiles: 'hotstrings.personal_files',
			Labels: 'menu.labels'
		};
		for (const [name, path] of Object.entries(imports)) {
			const record = luaLocal(moduleGraph, name);
			if (
				record.writes.length ||
				!record.statement.live ||
				!luaCall(record.value, 'require') ||
				!record.value.callee.binding.global ||
				record.value.callee.binding.writes.length ||
				record.value.args.length !== 1 ||
				record.value.args[0]?.value !== path
			)
				return false;
			if (
				moduleGraph.nodes.some(
					(node) =>
						['assign', 'assign-function'].includes(node.type) &&
						(node.type === 'assign' ? node.targets : [node.target]).some(
							(target) => ['field', 'index'].includes(target.type) && rooted(target.object, record)
						)
				)
			)
				return false;
			if (
				moduleGraph.nodes.some(
					(node) =>
						['field', 'index'].includes(node.type) &&
						node.object?.type === 'id' &&
						node.object.name === name &&
						node.object.binding !== record
				)
			)
				return false;
		}
		for (const name of ['require', 'pcall', 'type', 'ipairs', 'tostring']) {
			if (
				moduleGraph.globals.get(name)?.writes.length ||
				moduleGraph.records.some((record) => record.name === name)
			)
				return false;
		}
		const published = luaLocal(moduleGraph, 'M');
		if (
			moduleGraph.nodes.some(
				(node) =>
					['assign', 'assign-function'].includes(node.type) &&
					(node.type === 'assign' ? node.targets : [node.target]).some(
						(target) =>
							['field', 'index'].includes(target.type) &&
							rooted(target.object, published) &&
							(target.type === 'field'
								? target.key === 'build_custom'
								: target.key?.type !== 'string' || target.key.value === 'build_custom') &&
							node.value !== nativeValue
					)
			)
		)
			return false;
		const shape = (text) => scriptTokens(text, '.lua').map((token) => [token.kind, token.value]);
		const count = luaLocal(moduleGraph, 'fmt_count');
		if (
			count.writes.length ||
			count.value.type !== 'field' ||
			count.value.key !== 'fmt_count' ||
			!luaSame(count.value.object, luaLocal(moduleGraph, 'Labels'))
		)
			return false;
		if (
			!isDeepStrictEqual(
				shape(
					owner(
						source,
						'local function toggleSectionFn(ctx, group_name, sec_name, sec_label, admission)',
						'.lua'
					)
				),
				shape(PERSONAL_SECTION_FACTORY_BODY)
			)
		)
			return false;
		personalSectionParameters(factory.value, [
			'ctx',
			'group_name',
			'sec_name',
			'sec_label',
			'admission'
		]);
		const section = luaOwnerGraph(moduleGraph, sectionOwner.value),
			parameters = personalSectionParameters(sectionOwner.value, [
				'target',
				'group_name',
				'secs',
				'group_enabled',
				'admission'
			]),
			row = personalSectionLocal(section, 'row'),
			action = personalSectionLocal(section, 'action'),
			caption = personalSectionLocal(section, 'caption'),
			selected = personalSectionLocal(section, 'sec_on'),
			ready = personalSectionLocal(section, 'ready'),
			label = personalSectionLocal(section, 'lbl'),
			paused = personalSectionLocal(native, 'paused');
		const sectionLoops = section.nodes.filter(
			(node) =>
				node.type === 'for' &&
				node.start < row.statement.start &&
				node.end > row.statement.end &&
				node.values.length === 1 &&
				luaCall(node.values[0], 'ipairs') &&
				luaSame(node.values[0].args[0], parameters.secs)
		);
		if (
			sectionLoops.length !== 1 ||
			sectionLoops[0].names.length !== 2 ||
			sectionLoops[0].names[1].name !== 'sec' ||
			section.records.some((record) => record.name === 'sec' && record.kind !== 'iteration') ||
			section.nodes.some(
				(node) => node.type === 'id' && node.name === 'ctx' && node.binding !== context
			) ||
			label.writes.length !== 1
		)
			return false;
		const actualSection = sectionLoops[0].names[1].binding;
		if (
			!luaSame(paused.value.object, context) ||
			paused.value.key !== 'paused' ||
			![action, caption, selected, ready].every((record) => luaRetained(section, record)) ||
			!luaRetained(section, parameters.target, true) ||
			!luaCall(action.value, 'toggleSectionFn') ||
			action.value.callee.binding !== factory ||
			action.value.args.length !== 5 ||
			!luaSame(action.value.args[0], context) ||
			!luaSame(action.value.args[1], parameters.group_name) ||
			action.value.args[2]?.type !== 'field' ||
			action.value.args[2].key !== 'name' ||
			!luaSame(action.value.args[2].object, actualSection) ||
			action.value.args[3]?.binding !== label ||
			!luaSame(action.value.args[4], parameters.admission) ||
			ready.value.type !== 'binary' ||
			ready.value.op !== 'and' ||
			!luaSame(ready.value.left, parameters.group_enabled) ||
			ready.value.right.type !== 'unary' ||
			ready.value.right.op !== 'not' ||
			!luaSame(ready.value.right.value, paused) ||
			!luaCall(row.value, 'ManifestMenu', 'check_row') ||
			row.value.callee.object.binding !== facade
		)
			return false;
		const command = luaField(row.value.args[2], 'personal_section_toggle');
		if (
			row.value.args[2]?.fields.length !== 1 ||
			command.length !== 1 ||
			!luaSame(command[0].value, action)
		)
			return false;
		for (const [name, record] of [
			['personal_section_label', caption],
			['personal_section_selected', selected],
			['personal_section_ready', ready]
		]) {
			const field = luaField(row.value.args[3], name);
			if (
				field.length !== 1 ||
				field[0].value.type !== 'function' ||
				field[0].value.params.length ||
				field[0].value.body.length !== 1 ||
				field[0].value.body[0].type !== 'return' ||
				field[0].value.body[0].values.length !== 1 ||
				!luaSame(field[0].value.body[0].values[0], record)
			)
				return false;
		}
		if (row.value.args[3]?.fields.length !== 3) return false;
		const nilWrites = section.nodes.filter(
			(node) =>
				node.type === 'assign' &&
				node.targets.some(
					(target) => ['field', 'index'].includes(target.type) && rooted(target.object, row)
				)
		);
		if (
			nilWrites.length !== 2 ||
			!nilWrites.every(
				(node) =>
					node.live &&
					node.targets.length === 1 &&
					node.targets[0].type === 'field' &&
					luaSame(node.targets[0].object, row) &&
					['action', 'checked'].includes(node.targets[0].key) &&
					node.values.length === 1 &&
					node.values[0].type === 'literal' &&
					node.values[0].value === null
			) ||
			!luaRetained(
				{ ...section, nodes: section.nodes.filter((node) => !nilWrites.includes(node)) },
				row
			)
		)
			return false;
		const body = owner(
			owner(source, 'function M.build_custom(ctx, counts)', '.lua'),
			'local function append_section_rows(target, group_name, secs, group_enabled, admission)',
			'.lua'
		);
		if (
			!route(body, '.lua', [
				['if type(secs) ~= "table" then return true end'],
				['local has_real = false'],
				[
					'for _, sec in ipairs(secs) do if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then has_real = true; break end end'
				],
				['if not has_real then return true end'],
				[
					'for _, sec in ipairs(secs) do if type(sec) ~= "table" then goto continue_sec end if sec.name == "-" then',
					0
				],
				[
					'local boundary = ManifestMenu.template_rows("hotstrings_parameter_boundary", {}, {}, {})',
					2
				],
				['if type(boundary) ~= "table" then return false end', 2],
				['for _, row in ipairs(boundary) do target[#target + 1] = row end', 2],
				['elseif not sec.is_module_placeholder then', 2],
				[
					'local sec_on = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(group_name, sec.name) or false',
					2
				],
				[
					'local lbl = (type(sec.description) == "string" and sec.description ~= "") and sec.description or tostring(sec.name):gsub("_", " ") lbl = ctx.applyTriggerChar(lbl)',
					2
				],
				['local ready = group_enabled and not paused', 2],
				[
					'local caption = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl',
					2
				],
				['local action = toggleSectionFn(ctx, group_name, sec.name, lbl, admission)', 2],
				[
					'local row = ManifestMenu.check_row("hotstring_personal_section_choice", "personal_section_toggle", { personal_section_toggle = action, }, { personal_section_label = function() return caption end, personal_section_selected = function() return sec_on end, personal_section_ready = function() return ready end, })',
					2
				],
				['if type(row) ~= "table" then return false end', 2],
				['if not ready then row.action = nil end', 2],
				['if row.checked == false then row.checked = nil end', 2],
				['target[#target + 1] = row', 2],
				['return true']
			])
		)
			return false;
		const grow = personalSectionLocal(native, 'g_rows'),
			main = personalSectionLocal(native, 'main_sections'),
			items = personalSectionLocal(native, 'menu_items'),
			admission = personalSectionLocal(native, 'admission'),
			scopeNames = personalSectionLocal(native, 'scope_names'),
			groups = personalSectionLocal(native, 'personal_group_names'),
			sections = personalSectionLocal(native, 'g_secs'),
			enabled = personalSectionLocal(native, 'g_enabled'),
			inventory = personalSectionLocal(native, 'all_personal_secs_by_group');
		if (
			![grow, main, items, admission, paused].every((record) =>
				luaRetained(native, record, record === main)
			) ||
			!luaRetained(native, scopeNames, true) ||
			!luaCall(items.value, 'ManifestMenu', 'template_rows') ||
			items.value.callee.object.binding !== facade
		)
			return false;
		const checks = native.nodes.filter(
			(node) => luaCall(node, 'append_section_rows') && luaSame(node.args[0], grow)
		);
		if (
			checks.length !== 1 ||
			checks[0].callee.binding !== sectionOwner ||
			checks[0].args.length !== 5 ||
			!luaSame(checks[0].args[2], sections) ||
			!luaSame(checks[0].args[3], enabled) ||
			!luaSame(checks[0].args[4], admission)
		)
			return false;
		const callers = native.nodes.filter(
			(node) =>
				node.type === 'for' &&
				node.start < checks[0].start &&
				node.end > checks[0].end &&
				node.values.length === 1 &&
				luaCall(node.values[0], 'ipairs') &&
				luaSame(node.values[0].args[0], groups)
		);
		if (
			callers.length !== 1 ||
			callers[0].names.length !== 2 ||
			!luaSame(checks[0].args[1], callers[0].names[1].binding) ||
			sections.value.type !== 'index' ||
			!luaSame(sections.value.object, inventory) ||
			!luaSame(sections.value.key, callers[0].names[1].binding) ||
			!luaCall(enabled.value, 'groupEnabled') ||
			enabled.value.callee.binding !== luaFunctionBinding(moduleGraph, 'groupEnabled') ||
			!luaSame(enabled.value.args[0], context) ||
			!luaSame(enabled.value.args[1], callers[0].names[1].binding)
		)
			return false;
		const provider = luaField(items.value.args[3], 'personal_main_sections');
		if (
			provider.length !== 1 ||
			provider[0].value.type !== 'function' ||
			provider[0].value.body.length !== 1 ||
			provider[0].value.body[0].type !== 'return' ||
			!luaSame(provider[0].value.body[0].values[0], main)
		)
			return false;
		const scope = luaOwnerGraph(moduleGraph, scopeOwner.value),
			scopeParameters = personalSectionParameters(scopeOwner.value, [
				'names',
				'file_rows',
				'section_rows'
			]);
		if (!luaRendererGraph(scope) || !luaRetained(scope, scopeParameters.section_rows)) return false;
		const nativeBody = owner(source, 'function M.build_custom(ctx, counts)', '.lua');
		if (
			!route(nativeBody, '.lua', [
				['local paused = ctx.paused'],
				['local personal_group_names = {}'],
				[
					'for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do if ctx.get_group_name(f) == "personal" then has_personal = true; break end end'
				],
				['if has_personal then table.insert(personal_group_names, "personal") end'],
				[
					'for _, ext_name in ipairs(get_personal_ext_groups(ctx)) do table.insert(personal_group_names, ext_name) end'
				],
				['local all_personal_secs_by_group = {}'],
				[
					'for _, gname in ipairs(personal_group_names) do local secs = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections(gname) or nil all_personal_secs_by_group[gname] = secs end'
				],
				['local main_sections, unavailable_rows, tree_rows = {}, {}, {}'],
				['local used_sources = {}'],
				['for _, gname in ipairs(personal_group_names) do local record'],
				[
					'for index, source in ipairs(ctx.personal_files or {}) do if source.name == gname and not used_sources[index] then record, used_sources[index] = source, true break end end',
					1
				],
				[
					'local g_enabled = groupEnabled(ctx, gname) local g_secs = all_personal_secs_by_group[gname] local g_rows = {} local admission = gname ~= "personal" and PersonalFileScope.bind(ctx, record) or nil',
					1
				],
				[
					'if append_section_rows(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end',
					1
				],
				[
					'if #g_rows > 0 or PersonalFiles.components(gname) then if gname == "personal" then for _, row in ipairs(g_rows) do main_sections[#main_sections + 1] = row end',
					1
				],
				[
					'local menu_items = ManifestMenu.template_rows("hotstring_personal_content_frame", {}, { ["personal_main_boundary"] = function() return #main_sections > 0 end, ["personal_tree_boundary"] = function() return #tree_rows > 0 end, ["personal_custom_boundary"] = function() return #custom_rows > 0 end, ["personal_empty"] = function() return false end, }, { ["personal_controls"] = function() return controls end, ["personal_main_sections"] = function() return main_sections end, ["personal_unavailable_directories"] = function() return unavailable_rows end, ["personal_tree"] = function() return tree_rows end, ["personal_custom_sections"] = function() return custom_rows end, })'
				],
				['if type(menu_items) ~= "table" then return nil end'],
				[
					'local scope_names = {} for _, name in ipairs(personal_group_names) do scope_names[#scope_names + 1] = name end if type(custom_secs) == "table" then scope_names[#scope_names + 1] = "custom" end'
				],
				[
					'return { label = title_str, checked = both_enabled or nil, submenu = scope_menu(scope_names, {}, menu_items), }'
				]
			])
		)
			return false;
		if (
			!route(
				owner(nativeBody, 'local function scope_menu(names, file_rows, section_rows)', '.lua'),
				'.lua',
				[
					[
						'return ManifestMenu.build("hotstring_category_menu", "Hotstrings", nil, nil, { commands = { ["hotstring_category_enable_all"] = M.category_scope_fn(ctx, names, true), ["hotstring_category_disable_all"] = M.category_scope_fn(ctx, names, false), } }, { ["hotstring_category_file"] = function() return file_rows end, ["hotstring_category_sections"] = function() return section_rows end, })'
					]
				]
			)
		)
			return false;
		const terminal = native.body.at(-1);
		if (terminal.type !== 'return' || !terminal.live || terminal.values.length !== 1) return false;
		const handoff = luaField(terminal.values[0], 'submenu');
		if (
			handoff.length !== 1 ||
			!luaCall(handoff[0].value, 'scope_menu') ||
			handoff[0].value.callee.binding !== scopeOwner ||
			!luaSame(handoff[0].value.args[0], scopeNames) ||
			!luaSame(handoff[0].value.args[2], items)
		)
			return false;
		// The actual extension receiver is already a genuine receiving port for g_rows.
		// Its input must also stay closed; an arbitrary same-spelling callee gets no credit.
		const fileOwner = luaFunctionBinding(native, 'file_menu_for_group');
		if (!fileOwner) return false;
		const fileReceives = native.nodes.filter(
			(node) => luaCall(node, 'file_menu_for_group') && luaSame(node.args[1], grow)
		);
		if (fileReceives.length !== 1 || fileReceives[0].callee.binding !== fileOwner) return false;
		const fileGraph = luaOwnerGraph(moduleGraph, fileOwner.value),
			fileParameters = personalSectionParameters(fileOwner.value, [
				'gname',
				'rows',
				'check',
				'readonly'
			]),
			rendered = personalSectionLocal(fileGraph, 'rendered');
		if (
			!luaCall(rendered.value, 'ManifestMenu', 'build') ||
			rendered.value.callee.object.binding !== facade ||
			rendered.value.args[0]?.value !== 'hotstring_category_menu'
		)
			return false;
		const fileSections = luaField(rendered.value.args[5], 'hotstring_category_sections');
		if (
			fileSections.length !== 1 ||
			fileSections[0].value.type !== 'function' ||
			fileSections[0].value.params.length ||
			fileSections[0].value.body.length !== 1 ||
			fileSections[0].value.body[0].type !== 'return' ||
			fileSections[0].value.body[0].values.length !== 1 ||
			!luaSame(fileSections[0].value.body[0].values[0], fileParameters.rows)
		)
			return false;
		const boundary = personalSectionLocal(section, 'boundary'),
			targetWrites = section.nodes.filter(
				(node) =>
					node.type === 'assign' &&
					node.targets.some(
						(target) =>
							['field', 'index'].includes(target.type) && rooted(target.object, parameters.target)
					)
			),
			mainWrites = native.nodes.filter(
				(node) =>
					node.type === 'assign' &&
					node.targets.some(
						(target) => ['field', 'index'].includes(target.type) && rooted(target.object, main)
					)
			);
		// The preceding physical-route checks require both actual target sinks and the actual main sink.
		// Cardinality closes extra append-shaped writes that generic append retention permits.
		if (targetWrites.length !== 2 || mainWrites.length !== 1) return false;
		const scopeReturn = scope.body.at(-1);
		if (
			scopeReturn.type !== 'return' ||
			!scopeReturn.live ||
			scopeReturn.values.length !== 1 ||
			!luaCall(scopeReturn.values[0], 'ManifestMenu', 'build') ||
			scopeReturn.values[0].callee.object.binding !== facade
		)
			return false;
		const exactReads = (graph, roles) =>
			roles.map(([name, record]) => {
				const calls = graph.nodes.filter(
					(node) => luaCall(node, name) && node.args.length === 1 && luaSame(node.args[0], record)
				);
				if (calls.length !== 1) throw Error('One actual personal section read port ' + name);
				return calls[0];
			});
		return (
			personalSectionCustody(
				section,
				[parameters.target, row, boundary],
				[...targetWrites, ...nilWrites],
				[],
				exactReads(section, [
					['type', row],
					['type', boundary],
					['ipairs', boundary]
				])
			) &&
			personalSectionCustody(
				native,
				[grow, main, items],
				mainWrites,
				[checks[0], items.value, fileReceives[0], handoff[0].value],
				exactReads(native, [
					['type', items],
					['ipairs', grow]
				])
			) &&
			personalSectionCustody(scope, [scopeParameters.section_rows], [], [scopeReturn.values[0]]) &&
			personalSectionCustody(fileGraph, [fileParameters.rows], [], [rendered.value])
		);
	} catch {
		return false;
	}
}

module.exports.personalSectionChoicePublication = personalSectionChoicePublication;

/** Finite physical contract: frozen pre-change donor plus exactly two reviewed edits. */
function personalFileCaptionPublication(source) {
	try {
		const donor =
			'\n\tTFMenu := Menu(), HandedOff := false\n\tPrimaryFailure := 0\n\ttry {\n\tControlRows := [], SectionRows := []\n\tOwner := PersonalFileControls.ForPath(TF.path)\n\tif Owner is PersonalFileAdoptedOwner {\n\t\tfor Row in _HS_PersonalFileControlRows(Owner, "")\n\t\t\tControlRows.Push(Row)\n\t\tfor Section in Owner.sectionNames {\n\t\t\tSectionRows.Push(Map("label", Section . " (" . FmtCount(Owner.counts[Section]) . ")",\n\t\t\t\t"items", _HS_PersonalFileControlRows(Owner, Section), "checked", Owner.Selected(Section)))\n\t\t}\n\t} else {\n\t\tUnavailable := _HS_PersonalUnavailableRow("file")\n\t\tif Unavailable is Map\n\t\t\tControlRows.Push(Unavailable)\n\t\tfor _, ES in TF.sections\n\t\t\tSectionRows.Push(Map("label", ES["description"] . " (" . FmtCount(ES["count"]) . ")"))\n\t}\n\tCommands := Map("hotstring_file_open", _MakeOpenFileFn(TF.path))\n\tGetters := Map("hotstring_file_ready", (*) => true, "personal_file_open_present", (*) => true,\n\t\t"personal_file_boundary", (*) => Owner is PersonalFileAdoptedOwner)\n\tProviders := Map("personal_file_controls", (*) => ControlRows, "personal_file_sections", (*) => SectionRows)\n\tFileRows := MenuRenderer_TemplateRows("hotstring_personal_file_frame", Commands, Getters, Providers)\n\tif !(FileRows is Array)\n\t\treturn false\n\tif MenuRenderer_AppendTemplate(TFMenu, "hotstring_personal_file_frame", Commands, Getters, Providers, &WholeTreeAdmitted) != 1 + ControlRows.Length + SectionRows.Length || !WholeTreeAdmitted\n\t\treturn false\n\tResult := Map(\n\t\t"label", TF.stem . " (" . FmtCount(Owner is PersonalFileAdoptedOwner ? Owner.ActiveCount() : TF.count) . ")",\n\t\t"submenu", TFMenu)\n\tHandedOff := true\n\treturn Result\n\t} catch as ErrorInfo {\n\t\tPrimaryFailure := ErrorInfo\n\t\tthrow ErrorInfo\n\t} finally {\n\t\tif !HandedOff {\n\t\t\ttry _HS_PersonalReleaseMenus([TFMenu])\n\t\t\tcatch as CleanupFailure {\n\t\t\t\tif !PrimaryFailure\n\t\t\t\t\tthrow CleanupFailure\n\t\t\t\ttry LoggerError("Hotstrings", "Personal menu cleanup failed after construction refusal: {1}", CleanupFailure.Message)\n\t\t\t}\n\t\t}\n\t}\n';
		const edits = [
			[
				'\tControlRows := [], SectionRows := []',
				'\tCaptionPolicy := MenuRenderer_PersonalFileCaptionPolicy()\n\tif !(CaptionPolicy is Map)\n\t\treturn false\n\tControlRows := [], SectionRows := []'
			],
			[
				'\tResult := Map(\n\t\t"label", TF.stem . " (" . FmtCount(Owner is PersonalFileAdoptedOwner ? Owner.ActiveCount() : TF.count) . ")",\n\t\t"submenu", TFMenu)',
				'\t; Keep original late reads and native concatenation coercion before projection.\n\tResult := (FileStem := TF.stem . "",\n\t\tFileCount := FmtCount(Owner is PersonalFileAdoptedOwner ? Owner.ActiveCount() : TF.count) . "",\n\t\tCaptionOwner := CaptionPolicy["parent"],\n\t\tCaptionOwner != MenuRenderer_PersonalFileParentRow || Object.Prototype.HasOwnProp.Call(CaptionOwner, "Call")\n\t\t\t? false : CaptionOwner.Call(CaptionPolicy, FileStem, FileCount, TFMenu))\n\tif !(Result is Map)\n\t\treturn false'
			]
		];
		let expected = donor;
		for (const [before, after] of edits) {
			if (expected.split(before).length !== 2) return false;
			expected = expected.replace(before, after);
		}
		// Preserve statement boundaries as well as tokens: an unbraced preceding control
		// cannot skip the genuine native fill while lending its brace depth to the route.
		return owner(source, '_HS_TomlFileRow(TF) {', '.ahk') === expected;
	} catch {
		return false;
	}
}
module.exports.personalFileCaptionPublication = personalFileCaptionPublication;
