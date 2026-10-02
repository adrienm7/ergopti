// tools/lint/audit-gui-titles.cjs

/**
 * Audits native titles and the brandless inputs to shared title composers.
 * This is a bounded source check, not interprocedural data-flow analysis: it
 * resolves direct literals, translations, simple preceding assignments (within eight lines and the same block) and
 * inline show_webview title options. Dynamic inputs remain counted explicitly.
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const ROOT = path.resolve(__dirname, '../..');
const BRAND = /^\s*Ergopti(?:Plus)?\b/;

/** Tokenize strings and delimiters without treating quoted comment markers as comments. */
function tokens(source, lua) {
	const out = [];
	let i = 0,
		line = 1;
	const consume = (end) => {
		line += (source.slice(i, end).match(/\n/g) || []).length;
		i = end;
	};
	while (i < source.length) {
		const start = i,
			at = line,
			c = source[i];
		if (/\s/.test(c)) {
			consume(i + 1);
			continue;
		}
		const long = lua && source.slice(i).match(/^(?:--)?\[(=*)\[/);
		if (long) {
			const close = ']' + long[1] + ']';
			const end = source.indexOf(close, i + long[0].length);
			const stop = end < 0 ? source.length : end + close.length;
			if (!long[0].startsWith('--'))
				out.push({
					value: source.slice(i + long[0].length, end < 0 ? source.length : end),
					string: true,
					line: at
				});
			consume(stop);
			continue;
		}
		if ((!lua && c === ';') || (lua && source.startsWith('--', i))) {
			const end = source.indexOf('\n', i);
			consume(end < 0 ? source.length : end);
			continue;
		}
		if (!lua && source.startsWith('/*', i)) {
			const end = source.indexOf('*/', i + 2);
			consume(end < 0 ? source.length : end + 2);
			continue;
		}
		if (c === '"' || c === "'") {
			let value = '';
			i++;
			while (i < source.length && source[i] !== c) {
				if (source[i] === (lua ? '\\' : '`') && i + 1 < source.length) {
					value += source[i + 1];
					i += 2;
				} else value += source[i++];
			}
			i = Math.min(i + 1, source.length);
			line += (source.slice(start, i).match(/\n/g) || []).length;
			out.push({ value, string: true, line: at });
			continue;
		}
		const word = source.slice(i).match(/^[A-Za-z_][A-Za-z_0-9]*/);
		const value = word
			? word[0]
			: source.startsWith(':=', i)
				? ':='
				: source.startsWith('..', i)
					? '..'
					: c;
		out.push({ value, line: at });
		i += value.length;
	}
	return out;
}

/** Return balanced call arguments, keeping nested expressions intact. */
function argumentsAt(ts, open) {
	const args = [];
	let current = [],
		depth = 0;
	for (let i = open + 1; i < ts.length; i++) {
		const t = ts[i],
			v = t.value;
		if (!t.string && v === ')' && depth === 0) {
			args.push(current);
			return { args, end: i };
		}
		if (!t.string && v === ',' && depth === 0) {
			args.push(current);
			current = [];
			continue;
		}
		if (!t.string && ['(', '[', '{'].includes(v)) depth++;
		if (!t.string && [')', ']', '}'].includes(v)) depth--;
		current.push(t);
	}
	return null;
}

function inlineTitle(ts) {
	let depth = 0;
	for (let i = 0; i < ts.length; i++) {
		const t = ts[i];
		if (t.string) continue;
		if (['{', '(', '['].includes(t.value)) depth++;
		if (['}', ')', ']'].includes(t.value)) depth--;
		if (depth === 1 && t.value === 'title' && ts[i + 1]?.value === '=') {
			const out = [];
			let nested = 0;
			for (let j = i + 2; j < ts.length; j++) {
				const n = ts[j];
				if (!n.string && nested === 0 && [',', '}'].includes(n.value)) return out;
				if (!n.string && ['{', '(', '['].includes(n.value)) nested++;
				if (!n.string && ['}', ')', ']'].includes(n.value)) nested--;
				out.push(n);
			}
		}
	}
	return null;
}

function walk(dir, extension, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (['tests', 'vendor', '_generated', 'node_modules', '.git'].includes(entry.name)) continue;
		const file = path.join(dir, entry.name);
		if (entry.isDirectory()) walk(file, extension, out);
		else if (entry.name.endsWith(extension)) out.push(file);
	}
	return out;
}

/** Identify native function ownership independently of dialog call arguments. */
function functionRanges(ts) {
	const ranges = [];
	for (let i = 0; i < ts.length - 1; i++) {
		if (ts[i].string || !/^[A-Za-z_]\w*$/.test(ts[i].value) || ts[i + 1].value !== '(') continue;
		if (['if', 'while', 'for', 'switch', 'catch'].includes(ts[i].value.toLowerCase())) continue;
		const previous = ts[i - 1];
		if (
			previous &&
			(['if', 'while', 'return', 'try', '.', ':', '=', '!', '?'].includes(
				previous.value.toLowerCase()
			) ||
				(previous.line === ts[i].line && !['{', '}'].includes(previous.value)))
		)
			continue;
		const call = argumentsAt(ts, i + 1);
		if (!call || ts[call.end + 1]?.value !== '{') continue;
		let depth = 1;
		for (let end = call.end + 2; end < ts.length; end++) {
			if (!ts[end].string && ts[end].value === '{') depth++;
			if (!ts[end].string && ts[end].value === '}') depth--;
			if (depth === 0) {
				ranges.push({ name: ts[i].value, start: call.end + 1, end });
				break;
			}
		}
	}
	return ranges;
}

// These seven last-resort startup modals precede the runtime dialog owner.
// Both function ownership and exact counts are bounded until their own migration.
const EARLY_DIALOGS = {
	'windows/infra/bundle.ahk': { owner: 'Bundle_Init', count: 6 },
	'windows/infra/error_net.ahk': { owner: 'ErgoptiGlobalErrorHandler', count: 1 }
};

function auditSource(source, lua, locales, relative = '') {
	const ts = tokens(source, lua),
		findings = [],
		debt = [],
		stats = { checked: 0, dynamic: 0 };
	const scopes = lua ? [] : functionRanges(ts);
	const early = EARLY_DIALOGS[relative];
	let earlyCalls = 0;
	// Only simple same-line assignments are followed. Parameters, table paths,
	// callback results and cross-function argument flow are deliberately unresolved.
	function alias(name, before, seen) {
		if (seen.has(name)) return [];
		for (let i = before - 2; i >= 0; i--) {
			if (
				ts[before].line - ts[i].line > 8 ||
				(!ts[i].string && ['function', '{', '}'].includes(ts[i].value))
			)
				break;
			if (ts[i].value !== name || !['=', ':='].includes(ts[i + 1]?.value)) continue;
			if (['.', ':', '['].includes(ts[i - 1]?.value)) continue;
			const line = ts[i].line,
				expr = [];
			for (let j = i + 2; j < before && ts[j].line === line; j++) expr.push(ts[j]);
			return values(expr, i, new Set([...seen, name]));
		}
		return [];
	}
	function values(expr, before, seen = new Set()) {
		if (!expr?.length) return [];
		if (expr.length === 1 && !expr[0].string) return alias(expr[0].value, before, seen);
		const found = [];
		for (let i = 0; i < expr.length; i++) {
			const t = expr[i];
			if (t.string) {
				if (expr[i - 1]?.value !== '[') found.push({ value: t.value });
				continue;
			}
			if (
				/^[A-Za-z_][A-Za-z_0-9]*$/.test(t.value) &&
				!['.', ':'].includes(expr[i - 1]?.value) &&
				expr[i + 1]?.value !== '(' &&
				!['[', '.'].includes(expr[i + 1]?.value)
			)
				found.push(...alias(t.value, before, seen));
			if (['window_title', 'WindowTitle'].includes(t.value) && expr[i + 1]?.value === '(')
				found.push({ value: 'ErgoptiPlus', composed: true });
			if (['t', 'get'].includes(t.value) && expr[i + 1]?.value === '(') {
				const call = argumentsAt(expr, i + 1);
				if (!call) continue;
				const keys = values(call.args[0], before, seen);
				for (const key of keys)
					for (const [locale, data] of Object.entries(locales)) {
						if (typeof data[key.value] === 'string')
							found.push({ value: data[key.value], key: key.value, locale });
					}
				i = call.end;
			}
		}
		return found;
	}
	for (let i = 0; i < ts.length - 1; i++) {
		const t = ts[i],
			name = t.value;
		if (t.string || ts[i + 1].value !== '(') continue;
		if (ts[i - 1]?.value === 'function' || ts[i - 3]?.value === 'function') continue;
		const wrapper = [
			'Gui_Create',
			'Ui_MsgBox',
			'Ui_InputBox',
			'WindowTitle',
			'window_title',
			'set_window_title',
			'set_title',
			'show_webview'
		].includes(name);
		const nativeDialog = !lua && ['MsgBox', 'InputBox'].includes(name);
		const raw = ['Gui', 'windowTitle'].includes(name) || nativeDialog;
		if (!wrapper && !raw) continue;
		const call = argumentsAt(ts, i + 1);
		if (!call) continue;
		const dialogWrapper = ['Ui_MsgBox', 'Ui_InputBox'].includes(name);
		const definition = scopes.some((s) => s.start === call.end + 1 && s.name === name);
		if (
			(nativeDialog || dialogWrapper ? definition : ts[call.end + 1]?.value === '{') ||
			(!nativeDialog &&
				!['Ui_MsgBox', 'Ui_InputBox'].includes(name) &&
				call.args.some((a) => a.some((n) => n.value === ':=')))
		)
			continue;
		if (nativeDialog) {
			const scope = scopes
				.filter((s) => s.start < i && i < s.end)
				.sort((a, b) => a.end - a.start - (b.end - b.start))[0];
			if (early && name === 'MsgBox' && scope?.name === early.owner) {
				earlyCalls++;
				debt.push({
					line: t.line,
					reason: 'pre-bootstrap native caption migration remains pending'
				});
				continue;
			}
			const caption = call.args[1];
			const composed =
				caption?.length === 4 &&
				caption[0].value === 'WindowTitle' &&
				caption[1].value === '(' &&
				caption[2].value === 'Title' &&
				caption[3].value === ')';
			if (
				relative !== 'windows/infra/native_dialogs.ahk' ||
				scope?.name !== 'Ui_' + name ||
				!composed
			) {
				findings.push({
					line: t.line,
					call: name,
					reason: 'native dialog bypasses its shared-caption owner',
					values: []
				});
			}
			stats.checked++;
			continue;
		}
		if (name === 'Gui') {
			const captionless = call.args[0]?.some(
				(n) => n.string && /(?:^|\s)-Caption(?:\s|$)/i.test(n.value)
			);
			const composed = call.args[1]?.some(
				(n, at, expr) => n.value === 'WindowTitle' && expr[at + 1]?.value === '('
			);
			if (captionless) continue;
			if (!composed) {
				findings.push({
					line: t.line,
					call: name,
					reason: 'captioned Gui bypasses the shared title factory',
					values: []
				});
				stats.checked++;
				continue;
			}
		}
		let expr,
			brandedInput = wrapper;
		if (name === 'show_webview') expr = inlineTitle(call.args[0]);
		else if (name === 'set_title' && call.args.length === 1) {
			expr = call.args[0];
			brandedInput = false;
		} else
			expr =
				call.args[
					[
						'Gui_Create',
						'Gui',
						'Ui_MsgBox',
						'Ui_InputBox',
						'set_window_title',
						'set_title'
					].includes(name)
						? 1
						: 0
				];
		if (!expr) continue;
		const resolved = values(expr, i);
		stats.checked++;
		if (resolved.length === 0) {
			stats.dynamic++;
			continue;
		}
		const bad = brandedInput
			? resolved.filter((v) => BRAND.test(v.value))
			: resolved.filter((v) => !BRAND.test(v.value));
		// Raw expressions composed by the title helper already have their prefix.
		if (!brandedInput && resolved.some((v) => v.composed || BRAND.test(v.value))) continue;

		if (bad.length)
			findings.push({
				line: t.line,
				call: name,
				reason: brandedInput
					? 'branded input to a prefix-adding wrapper'
					: 'raw native title lacks a product prefix',
				values: bad
			});
	}
	if (early && earlyCalls !== early.count)
		findings.push({
			line: 1,
			call: 'MsgBox',
			reason: `bounded pre-bootstrap dialog count changed: expected ${early.count}, found ${earlyCalls}`,
			values: []
		});
	return { findings, debt, ...stats };
}

function main(root = ROOT) {
	const localeDir = path.join(root, 'static/ergopti_plus/_shared/data/locales');
	const locales = Object.fromEntries(
		fs
			.readdirSync(localeDir)
			.filter((n) => n.endsWith('.json'))
			.map((n) => [n.slice(0, -5), JSON.parse(fs.readFileSync(path.join(localeDir, n), 'utf8'))])
	);
	let violations = 0,
		checked = 0,
		dynamic = 0,
		rawDebt = 0;
	for (const [platform, extension] of [
		['windows', '.ahk'],
		['macos', '.lua'],
		['linux', '.lua']
	]) {
		const files = walk(path.join(root, 'static/ergopti_plus', platform), extension);
		for (const file of files) {
			const relative = path
				.relative(path.join(root, 'static/ergopti_plus'), file)
				.replaceAll('\\', '/');
			const result = auditSource(
				fs.readFileSync(file, 'utf8'),
				extension === '.lua',
				locales,
				relative
			);
			checked += result.checked;
			dynamic += result.dynamic;
			for (const item of result.debt) {
				rawDebt++;
				console.log(
					`[DEBT] ${path.relative(root, file).replaceAll('\\', '/')}:${item.line}: ${item.reason || 'possible unbranded raw title; manual review required'}.`
				);
			}
			for (const finding of result.findings) {
				violations++;
				const details = [
					...new Set(
						finding.values.map((v) => (v.key ? `${v.locale}:${v.key}` : JSON.stringify(v.value)))
					)
				].join(', ');
				console.error(
					`${path.relative(root, file).replaceAll('\\', '/')}:${finding.line}: ${finding.call}: ${finding.reason} (${details}).`
				);
			}
		}
	}
	console.log(
		`GUI title audit: ${checked} call sites across Windows/macOS/Linux; ${dynamic} dynamic inputs unresolved; ${Object.keys(locales).length} locales; ${violations} violations; ${rawDebt} non-blocking raw-title review items.`
	);
	return violations ? 1 : 0;
}
module.exports = { auditSource, main };
if (require.main === module) process.exitCode = main(process.argv[2] || ROOT);
