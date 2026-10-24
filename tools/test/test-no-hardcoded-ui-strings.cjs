// tools/test/test-no-hardcoded-ui-strings.cjs

/**
 * ==============================================================================
 * MODULE: Hard-Coded UI String Gate
 * DESCRIPTION:
 * Every sentence a user reads comes from the i18n catalogue. This gate finds
 * the literals that reach the screen without it, at the call sites that show
 * text on each surface:
 *
 *   Windows (AutoHotkey): TrayTip, MsgBox, Ui_MsgBox, InputBox, Ui_InputBox,
 *     ToolTip, NotifierSend, the Gui_Create and WindowTitle labels, and the
 *     text of Text, Button, Checkbox, Radio, GroupBox and Link controls.
 *   macOS and Linux (Lua): hs.alert, hs.dialog and its dialog_util wrappers
 *     (block_alert, text_prompt, alert, choose), the Linux dialogs port,
 *     hs.notify, notifications.notify, notifier.send (message and title), and
 *     the window_title, set_window_title and show_webview title labels, also
 *     when called through pcall.
 *   Web UIs (JavaScript): alert, confirm, prompt, assignments to textContent,
 *     innerText, placeholder and title, setAttribute of a visible attribute,
 *     and the title, placeholder, aria-label and alt attributes of HTML built in
 *     strings.
 *   Linux shell scripts the user runs (install.sh, uninstall.sh, the launcher
 *     and the install/ helpers): every echo and printf sentence.
 *
 * A literal counts when, once escapes, format placeholders and the product
 * name are removed, it still holds a run of two letters (two words for shell,
 * whose echo also returns values such as a package name). Strings inside a
 * nested call are not counted unless the call only formats its arguments
 * (Format, StrReplace, string.format): a translation call takes a key, and
 * other calls take paths, options or keys.
 *
 * BASELINE THAT ONLY SHRINKS:
 * The literals present when the gate was written are listed in
 * no-hardcoded-ui-strings-baseline.json with their count. A literal that is
 * not listed, or listed with a lower count, fails: route it through the
 * catalogue. A listed literal that is gone, or present fewer times, fails too,
 * so the entry is removed with the fix and cannot hide a later return.
 * `--prune-baseline` rewrites the file without the entries that went away; it
 * never adds one. A literal that must stay as written (a pre-boot dialog, a
 * command the user types) goes in ALLOWED below with its reason instead.
 *
 * WHY THESE SHAPES AND NOT A WORD FILTER:
 * test-visible-text-is-localized.cjs records that a scan for accented literals
 * hit 154 places in 37 files, nearly all of them data. A display call is where
 * a literal is a bug, so the gate looks there and nowhere else. The tokenizer
 * and argument splitter are the ones tools/lint/audit-gui-titles.cjs uses for
 * the window titles, so both audits read a call the same way.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { parse } = require('acorn');
const { argumentsAt, tokens } = require('../lint/audit-gui-titles.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');
const BASELINE_PATH = path.join(__dirname, 'no-hardcoded-ui-strings-baseline.json');
const SKIPPED_DIRECTORIES = new Set(['tests', 'vendor', '_generated', 'node_modules', '.git']);

// The product name and the names of the runtimes it drives read the same in
// every language.
const PROPER_NOUNS = /Ergopti(?:Plus|\+)?|\b(?:Ollama|MLX|HuggingFace|GitHub)\b/g;

// Literals that stay as written, each with its reason. An entry without `text`
// covers every literal of that sink in that file. An entry that no longer
// matches anything fails, so an exemption cannot outlive its reason.
const ALLOWED = [
	{
		file: 'windows/infra/bundle.ahk',
		sink: 'Ui_MsgBox',
		reason: 'bundle extraction runs before the locale catalogue is on disk (audit I10)'
	},
	{
		file: 'windows/infra/error_net.ahk',
		sink: 'Ui_MsgBox',
		reason: 'the fatal boot handler can fire before i18n is loaded (audit I10)'
	},
	{
		file: 'linux/install/desktop_entry.sh',
		sink: 'printf',
		reason: 'these lines are the Exec keys of the desktop entry and unit files it writes'
	},
	{
		file: 'linux/install.sh',
		sink: 'echo',
		text: '  systemctl --user status ergopti-hotstrings',
		reason: 'a command the user types'
	},
	{
		file: 'linux/install.sh',
		sink: 'echo',
		text: '  ergopti-hotstrings',
		reason: 'a command the user types'
	},
	{
		file: 'linux/install.sh',
		sink: 'echo',
		text: '    export PATH=\\"\\$HOME/.local/bin:\\$PATH\\"',
		reason: 'a line the user pastes into a shell profile'
	}
];

// Function name -> indexes of the arguments that are shown to the user.
const AHK_CALLS = new Map([
	['TrayTip', [0, 1]],
	['MsgBox', [0, 1]],
	['Ui_MsgBox', [0, 1]],
	['InputBox', [0, 1]],
	['Ui_InputBox', [0, 1]],
	['ToolTip', [0]],
	['NotifierSend', [0]],
	['Gui_Create', [1]],
	['WindowTitle', [0]]
]);
const AHK_CONTROL_METHODS = new Set([
	'AddText',
	'AddButton',
	'AddCheckbox',
	'AddRadio',
	'AddGroupBox',
	'AddLink'
]);
const AHK_CONTROL_TYPES = new Set(['Text', 'Button', 'Checkbox', 'Radio', 'GroupBox', 'Link']);
const AHK_FORMATTERS = new Set(['Format', 'StrReplace', 'StrUpper', 'StrLower', 'Trim', 'String']);

// Dotted call name (matched on its trailing segments) -> visible argument indexes.
const LUA_CALLS = new Map([
	['hs.alert.show', [0]],
	['hs.alert', [0]],
	['hs.dialog.blockAlert', [0, 1, 2, 3]],
	['hs.dialog.textPrompt', [0, 1, 3, 4]],
	['dialog.alert', [3, 4, 5, 6]],
	['Dialog.alert', [3, 4, 5, 6]],
	['dialog_util.alert', [3, 4, 5, 6]],
	['block_alert', [0, 1, 2, 3]],
	['text_prompt', [0, 1, 3, 4]],
	['dialog.choose', [0, 1, 2, 3, 4]],
	['Dialog.choose', [0, 1, 2, 3, 4]],
	['dialog_util.choose', [0, 1, 2, 3, 4]],
	['dialogs.prompt', [0, 1]],
	['dialogs.error', [0, 1]],
	['dialogs.info', [0, 1]],
	['dialogs.confirm', [0, 1]],
	['hs.notify.show', [0, 1, 2]],
	['notifications.notify', [0, 1]],
	['Notifications.notify', [0, 1]],
	['notifier.send', [0]],
	['window_title', [0]],
	['set_window_title', [1]]
]);
// `pcall(fn, ...)` calls fn with the arguments that follow it.
const LUA_FORWARDERS = new Set(['pcall', 'Logger.run_modal']);
// Dotted call name -> table fields of its arguments that are shown to the user.
const LUA_TABLE_FIELDS = new Map([
	['hs.notify.new', ['title', 'subTitle', 'informativeText']],
	['notifier.send', ['title']],
	['show_webview', ['title']]
]);
const LUA_FORMATTERS = new Set(['string.format', 'tostring']);

const JS_DIALOGS = new Set(['alert', 'confirm', 'prompt']);
const JS_TEXT_PROPERTIES = new Set(['textContent', 'innerText', 'placeholder', 'title']);
const JS_TEXT_ATTRIBUTES = new Set(['title', 'placeholder', 'aria-label', 'alt']);
const HTML_TEXT_ATTRIBUTE = /\b(title|placeholder|aria-label|alt)\s*=\s*"([^"]*)"/g;

const SHELL_SCRIPTS = ['linux/install.sh', 'linux/uninstall.sh', 'linux/bin/ergopti-hotstrings'];
const SHELL_SCRIPT_DIRECTORIES = ['linux/install'];

/**
 * Tells whether a literal still reads as words once its non-words are removed.
 * @param {string} text Literal with its escapes already replaced by spaces.
 * @param {number} minimumWords Letter runs the literal needs to count.
 * @returns {boolean} True when the literal is user-facing prose.
 */
function isProse(text, minimumWords = 1) {
	const cleaned = text
		.replace(/%[-+ 0#]*\d*(?:\.\d+)?[a-zA-Z%]/g, ' ')
		.replace(/\{\d*\}/g, ' ')
		.replace(PROPER_NOUNS, ' ');
	return (cleaned.match(/\p{L}{2,}/gu) || []).length >= minimumWords;
}

/**
 * Tells whether a JavaScript literal is a style sheet fragment, which a page
 * writes into a <style> element's textContent.
 * @param {string} text Literal.
 * @returns {boolean} True for CSS.
 */
function isCss(text) {
	return /[{}]/.test(text) && /[a-z-]+\s*:\s*[^;{}]+[;}]/.test(text);
}

/**
 * Replaces the escape sequences of an AutoHotkey or Lua literal by a space.
 * @param {string} raw Literal as written between its quotes.
 * @param {boolean} lua Whether the literal is Lua.
 * @returns {string} The literal without escapes.
 */
function withoutEscapes(raw, lua) {
	return lua
		? raw.replace(/\\(?:\d{1,3}|x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)/g, ' ')
		: raw.replace(/`./g, ' ');
}

/**
 * Lists the files with one of the extensions below a directory, skipping test,
 * vendor and generated trees.
 * @param {string} directory Absolute directory.
 * @param {string[]} extensions File extensions to keep.
 * @param {string[]} out Accumulator.
 * @returns {string[]} Absolute paths, sorted.
 */
function walk(directory, extensions, out = []) {
	const entries = fs
		.readdirSync(directory, { withFileTypes: true })
		.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
	for (const entry of entries) {
		if (SKIPPED_DIRECTORIES.has(entry.name)) continue;
		const full = path.join(directory, entry.name);
		if (entry.isDirectory()) walk(full, extensions, out);
		else if (extensions.some((extension) => entry.name.endsWith(extension))) out.push(full);
	}
	return out;
}

/**
 * Builds the dotted name of the call whose last segment is at index `at`.
 * @param {object[]} ts Tokens.
 * @param {number} at Index of the last name segment.
 * @returns {string} Name such as `hs.alert.show`.
 */
function dottedName(ts, at) {
	let name = ts[at].value;
	let i = at;
	while (
		i >= 2 &&
		!ts[i - 1].string &&
		['.', ':'].includes(ts[i - 1].value) &&
		!ts[i - 2].string &&
		/^[A-Za-z_]\w*$/.test(ts[i - 2].value)
	) {
		name = `${ts[i - 2].value}.${name}`;
		i -= 2;
	}
	return name;
}

/**
 * Finds the sink registered for a dotted call name, matching trailing segments.
 * @param {Map<string, *>} table Sink table.
 * @param {string} name Dotted call name.
 * @returns {[string, *]|null} The matching sink name and value.
 */
function sinkFor(table, name) {
	for (const [sink, value] of table) {
		if (name === sink || name.endsWith(`.${sink}`)) return [sink, value];
	}
	return null;
}

/**
 * Returns the string tokens of an argument that reach the screen as written:
 * its direct operands and the operands of a formatter. Index keys and strings
 * passed to any other call are left out.
 * @param {object[]} expr Argument tokens.
 * @param {Set<string>} formatters Calls that only format their arguments.
 * @returns {object[]} String tokens.
 */
function visibleStrings(expr, formatters) {
	const out = [];
	for (let i = 0; i < expr.length; i++) {
		const t = expr[i];
		if (t.string) {
			if (expr[i - 1]?.value !== '[' || expr[i - 1]?.string) out.push(t);
			continue;
		}
		if (!/^[A-Za-z_]\w*$/.test(t.value) || expr[i + 1]?.value !== '(') continue;
		const call = argumentsAt(expr, i + 1);
		if (!call) continue;
		if (formatters.has(dottedName(expr, i)))
			for (const arg of call.args) out.push(...visibleStrings(arg, formatters));
		i = call.end;
	}
	return out;
}

/**
 * Returns the tokens assigned to `field = ...` at the top level of a Lua table
 * constructor inside an argument.
 * @param {object[]} expr Argument tokens.
 * @param {string} field Field name.
 * @returns {object[]|null} Value tokens, or null when the field is absent.
 */
function tableField(expr, field) {
	let depth = 0;
	for (let i = 0; i < expr.length; i++) {
		const t = expr[i];
		if (t.string) continue;
		if (['{', '(', '['].includes(t.value)) depth++;
		if (['}', ')', ']'].includes(t.value)) depth--;
		if (depth !== 1 || t.value !== field || expr[i + 1]?.value !== '=') continue;
		const value = [];
		let nested = 0;
		for (let j = i + 2; j < expr.length; j++) {
			const n = expr[j];
			if (!n.string && nested === 0 && [',', '}'].includes(n.value)) break;
			if (!n.string && ['{', '(', '['].includes(n.value)) nested++;
			if (!n.string && ['}', ')', ']'].includes(n.value)) nested--;
			value.push(n);
		}
		return value;
	}
	return null;
}

/**
 * Tells whether the token at `at` begins an AutoHotkey statement: the first on
 * its line, or after `try`, `else` or a brace.
 * @param {object[]} ts Tokens.
 * @param {number} at Token index.
 * @returns {boolean} True at a statement start.
 */
function startsStatement(ts, at) {
	const previous = ts[at - 1];
	if (!previous || previous.line !== ts[at].line) return true;
	return !previous.string && ['try', 'else', '{', '}'].includes(previous.value.toLowerCase());
}

/**
 * Splits the arguments of a parenthesis-free AutoHotkey call statement
 * (`TrayTip "text", "title"`), which end with the line.
 * @param {object[]} ts Tokens.
 * @param {number} first Index of the first argument token.
 * @returns {object[][]} Arguments.
 */
function statementArguments(ts, first) {
	const args = [[]];
	let depth = 0;
	for (let i = first; i < ts.length && ts[i].line === ts[first].line; i++) {
		const t = ts[i];
		if (!t.string && ['(', '[', '{'].includes(t.value)) depth++;
		if (!t.string && [')', ']', '}'].includes(t.value)) depth--;
		if (!t.string && t.value === ',' && depth === 0) args.push([]);
		else args[args.length - 1].push(t);
	}
	return args;
}

/**
 * Records the prose literals of one visible argument.
 * @param {object[]} findings Accumulator.
 * @param {string} sink Sink label.
 * @param {object[]|undefined} expr Argument tokens.
 * @param {boolean} lua Whether the source is Lua.
 */
function recordArgument(findings, sink, expr, lua) {
	if (!expr) return;
	for (const t of visibleStrings(expr, lua ? LUA_FORMATTERS : AHK_FORMATTERS)) {
		if (isProse(withoutEscapes(t.raw ?? t.value, lua))) {
			findings.push({ sink, text: t.value, line: t.line });
		}
	}
}

/**
 * Finds the hard-coded visible literals of one AutoHotkey source.
 * @param {string} source File contents.
 * @returns {{sink: string, text: string, line: number}[]} Findings.
 */
function scanAhk(source) {
	const ts = tokens(source, false);
	const findings = [];
	for (let i = 0; i < ts.length; i++) {
		const t = ts[i];
		if (t.string || !/^[A-Za-z_]\w*$/.test(t.value)) continue;
		const method = ts[i - 1]?.value === '.' && !ts[i - 1].string;
		const next = ts[i + 1];
		if (!next) continue;
		let args = null;
		if (!next.string && next.value === '(') {
			const call = argumentsAt(ts, i + 1);
			// A definition (`Name(Params) {`) declares defaults, not text.
			if (!call || ts[call.end + 1]?.value === '{') continue;
			args = call.args;
		} else if (
			!method &&
			AHK_CALLS.has(t.value) &&
			next.line === t.line &&
			(next.string || /^[A-Za-z_]\w*$/.test(next.value)) &&
			startsStatement(ts, i)
		) {
			args = statementArguments(ts, i + 1);
		}
		if (!args) continue;
		if (method && AHK_CONTROL_METHODS.has(t.value)) {
			recordArgument(findings, t.value, args[1], false);
		} else if (method && t.value === 'Add') {
			const type = args[0];
			if (type?.length === 1 && type[0].string && AHK_CONTROL_TYPES.has(type[0].value))
				recordArgument(findings, `Add${type[0].value}`, args[2], false);
		} else if (!method && AHK_CALLS.has(t.value)) {
			for (const index of AHK_CALLS.get(t.value))
				recordArgument(findings, t.value, args[index], false);
		}
	}
	return findings;
}

/**
 * Finds the hard-coded visible literals of one Lua source.
 * @param {string} source File contents.
 * @returns {{sink: string, text: string, line: number}[]} Findings.
 */
function scanLua(source) {
	const ts = tokens(source, true);
	const findings = [];
	for (let i = 0; i < ts.length - 1; i++) {
		const t = ts[i];
		if (t.string || !/^[A-Za-z_]\w*$/.test(t.value) || ts[i + 1].value !== '(') continue;
		if (ts[i - 1]?.value === 'function' || ts[i - 3]?.value === 'function') continue;
		const call = argumentsAt(ts, i + 1);
		if (!call) continue;
		let name = dottedName(ts, i);
		let args = call.args;
		const target = args[0];
		if (
			LUA_FORWARDERS.has(name) &&
			target?.length > 0 &&
			target.every((n, at) => !n.string && (at % 2 === 0 ? /^[A-Za-z_]\w*$/ : /^\.$/).test(n.value))
		) {
			name = target.map((n) => n.value).join('');
			args = args.slice(1);
		}
		const positional = sinkFor(LUA_CALLS, name);
		if (positional) {
			for (const index of positional[1]) recordArgument(findings, positional[0], args[index], true);
		}
		const fields = sinkFor(LUA_TABLE_FIELDS, name);
		if (fields) {
			for (const arg of args)
				for (const field of fields[1])
					recordArgument(
						findings,
						`${fields[0]}.${field}`,
						tableField(arg, field) ?? undefined,
						true
					);
		}
	}
	return findings;
}

/**
 * Returns the string parts of a JavaScript expression that reach the screen as
 * written: literals, template text, and both sides of `+`, `?:` and `||`.
 * @param {object} node Expression node.
 * @returns {{text: string, node: object}[]} Visible parts.
 */
function jsVisible(node) {
	if (!node) return [];
	switch (node.type) {
		case 'Literal':
			return typeof node.value === 'string' ? [{ text: node.value, node }] : [];
		case 'TemplateLiteral':
			return [
				...node.quasis.map((quasi) => ({ text: quasi.value.cooked ?? '', node: quasi })),
				...node.expressions.flatMap(jsVisible)
			];
		case 'BinaryExpression':
			return node.operator === '+' ? [...jsVisible(node.left), ...jsVisible(node.right)] : [];
		case 'ConditionalExpression':
			return [...jsVisible(node.consequent), ...jsVisible(node.alternate)];
		case 'LogicalExpression':
			return [...jsVisible(node.left), ...jsVisible(node.right)];
		default:
			return [];
	}
}

/**
 * Visits every node of an acorn tree.
 * @param {object} node Root node.
 * @param {function(object): void} visit Visitor.
 */
function walkJs(node, visit) {
	visit(node);
	for (const key of Object.keys(node)) {
		const value = node[key];
		if (Array.isArray(value)) {
			for (const child of value) if (child && typeof child.type === 'string') walkJs(child, visit);
		} else if (value && typeof value.type === 'string') walkJs(value, visit);
	}
}

/**
 * Names the property or callee a member expression ends with.
 * @param {object} node Expression node.
 * @returns {string|null} Name, or null when computed.
 */
function memberName(node) {
	if (node.type === 'Identifier') return node.name;
	if (node.type === 'MemberExpression' && !node.computed) return node.property.name;
	return null;
}

/**
 * Finds the hard-coded visible literals of one JavaScript source.
 * @param {string} source File contents.
 * @returns {{sink: string, text: string, line: number}[]} Findings.
 */
function scanJs(source) {
	let program;
	try {
		program = parse(source, { ecmaVersion: 'latest', sourceType: 'module', locations: true });
	} catch {
		program = parse(source, { ecmaVersion: 'latest', sourceType: 'script', locations: true });
	}
	const findings = [];
	const record = (sink, expr) => {
		for (const part of jsVisible(expr))
			if (isProse(part.text) && !isCss(part.text))
				findings.push({ sink, text: part.text, line: part.node.loc.start.line });
	};
	walkJs(program, (node) => {
		if (node.type === 'CallExpression') {
			const name = memberName(node.callee);
			if (
				JS_DIALOGS.has(name) &&
				(node.callee.type === 'Identifier' || memberName(node.callee.object) === 'window')
			)
				record(name, node.arguments[0]);
			if (
				name === 'setAttribute' &&
				node.arguments[0]?.type === 'Literal' &&
				JS_TEXT_ATTRIBUTES.has(node.arguments[0].value)
			)
				record(`setAttribute(${node.arguments[0].value})`, node.arguments[1]);
		}
		if (node.type === 'AssignmentExpression' && node.left.type === 'MemberExpression') {
			const name = memberName(node.left);
			if (JS_TEXT_PROPERTIES.has(name)) record(name, node.right);
		}
		const markup =
			node.type === 'Literal' && typeof node.value === 'string'
				? node.value
				: node.type === 'TemplateElement'
					? (node.value.cooked ?? '')
					: null;
		if (markup === null) return;
		for (const match of markup.matchAll(HTML_TEXT_ATTRIBUTE)) {
			if (isProse(match[2]))
				findings.push({ sink: `html ${match[1]}`, text: match[2], line: node.loc.start.line });
		}
	});
	return findings;
}

/**
 * Splits the words of one shell command from `at` up to its end: an unquoted
 * `;`, `&`, `|`, `)` or comment, or a redirection, which is reported apart.
 * @param {string} line Source line.
 * @param {number} at Index after the command name.
 * @returns {{quoted: string[], redirect: string|null, piped: boolean}} Parts.
 */
function shellCommand(line, at) {
	const quoted = [];
	for (let i = at; i < line.length; i++) {
		const c = line[i];
		if (c === '"' || c === "'") {
			let text = '';
			for (i++; i < line.length && line[i] !== c; i++) {
				if (c === '"' && line[i] === '\\' && i + 1 < line.length) text += line[i++];
				text += line[i];
			}
			quoted.push(text);
		} else if (c === '>') {
			return { quoted, redirect: line.slice(i).replace(/^>+\s*/, ''), piped: false };
		} else if (c === '|' && line[i + 1] !== '|') {
			return { quoted, redirect: null, piped: true };
		} else if (';&|)#'.includes(c)) {
			break;
		}
	}
	return { quoted, redirect: null, piped: false };
}

/**
 * Finds the echo and printf sentences of one shell script. Output that is a
 * value rather than a message is not counted: a case arm such as
 * `apt) echo "lua-luv" ;;`, a `$(...)` capture, a pipe, a redirection into a
 * file, and a one-word echo, so a sentence needs two words.
 * @param {string} source File contents.
 * @returns {{sink: string, text: string, line: number}[]} Findings.
 */
function scanShell(source) {
	const findings = [];
	// A trailing backslash continues the command, and its redirection, on the next line.
	const lines = source.split('\n');
	for (let index = lines.length - 2; index >= 0; index--) {
		if (!lines[index].endsWith('\\')) continue;
		lines[index] = `${lines[index].slice(0, -1)} ${lines[index + 1].trim()}`;
		lines[index + 1] = '';
	}
	lines.forEach((raw, index) => {
		const line = raw.trim();
		if (line.startsWith('#') || /^[^"'#]*\)\s*(?:echo|printf)\b.*;;\s*$/.test(line)) return;
		for (const command of line.matchAll(
			/(^|[;&|({]\s*|\bthen\s+|\belse\s+|\bdo\s+)(echo|printf)\b/g
		)) {
			if (/\$\(\s*$/.test(line.slice(0, command.index + command[1].length))) continue;
			const parts = shellCommand(line, command.index + command[0].length);
			if (parts.piped || (parts.redirect !== null && !/^&[12]\b/.test(parts.redirect))) continue;
			for (const text of parts.quoted) {
				const words = text.replace(/\\./g, ' ').replace(/\$\{[^}]*\}|\$\w+|\$\(.*?\)/g, ' ');
				if (isProse(words, 2)) findings.push({ sink: command[2], text, line: index + 1 });
			}
		}
	});
	return findings;
}

/**
 * Scans every surface of the repository.
 * @param {string} driversRoot Absolute path of static/ergopti_plus.
 * @returns {{file: string, sink: string, text: string, line: number}[]} Findings.
 */
function collectFindings(driversRoot = DRIVERS) {
	const out = [];
	const add = (file, findings) => {
		const relative = path.relative(driversRoot, file).replaceAll('\\', '/');
		for (const finding of findings) out.push({ file: relative, ...finding });
	};
	for (const file of walk(path.join(driversRoot, 'windows'), ['.ahk']))
		add(file, scanAhk(fs.readFileSync(file, 'utf8')));
	for (const platform of ['macos', 'linux'])
		for (const file of walk(path.join(driversRoot, platform), ['.lua']))
			add(file, scanLua(fs.readFileSync(file, 'utf8')));
	const scripts = [
		...walk(path.join(driversRoot, '_shared', 'ui'), ['.js']),
		...walk(path.join(driversRoot, 'macos', 'ui'), ['.js'])
	];
	for (const file of scripts) add(file, scanJs(fs.readFileSync(file, 'utf8')));
	const shell = [
		...SHELL_SCRIPTS.map((relative) => path.join(driversRoot, relative)),
		...SHELL_SCRIPT_DIRECTORIES.flatMap((relative) =>
			walk(path.join(driversRoot, relative), ['.sh'])
		)
	];
	for (const file of shell) add(file, scanShell(fs.readFileSync(file, 'utf8')));
	return out;
}

/**
 * Removes the allowlisted findings and names the allowances nothing matched.
 * @param {{file: string, sink: string, text: string}[]} findings Findings.
 * @returns {{reported: object[], unusedAllowances: object[]}} What is left.
 */
function applyAllowances(findings) {
	const used = new Set();
	const reported = findings.filter((finding) => {
		const index = ALLOWED.findIndex(
			(entry) =>
				entry.file === finding.file &&
				entry.sink === finding.sink &&
				(entry.text === undefined || entry.text === finding.text)
		);
		if (index < 0) return true;
		used.add(index);
		return false;
	});
	return { reported, unusedAllowances: ALLOWED.filter((_, index) => !used.has(index)) };
}

/**
 * Counts findings by file, sink and text, the identity the baseline keeps.
 * @param {{file: string, sink: string, text: string}[]} findings Findings.
 * @returns {Map<string, {file: string, sink: string, text: string, count: number}>} Counts.
 */
function countFindings(findings) {
	const counts = new Map();
	for (const { file, sink, text } of findings) {
		const key = JSON.stringify([file, sink, text]);
		const entry = counts.get(key) ?? { file, sink, text, count: 0 };
		entry.count++;
		counts.set(key, entry);
	}
	return counts;
}

/**
 * Sorts baseline entries by file, sink and text.
 * @param {object[]} entries Entries.
 * @returns {object[]} Sorted copy.
 */
function sortEntries(entries) {
	const key = (entry) => JSON.stringify([entry.file, entry.sink, entry.text]);
	return [...entries].sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
}

/** Proves on small sources that each surface reports a literal and spares a key. */
function selfTest() {
	const ahk = scanAhk(
		[
			'TrayTip("Saved to disk", "ErgoptiPlus", "Iconi Mute")',
			'TrayTip(t("notify.saved"), "ErgoptiPlus")',
			'Ui_MsgBox(Format(t("x"), "literal tail") . "`n`n", t("title"))',
			'g := Gui_Create("+Resize", "IA")',
			'g.AddText("w200", "Choose a file")',
			'g.Add("Button", "Default", t("common.ok"))',
			'MsgBox "Bare call text"',
			'Ui_MsgBox(Text := "", Title := "") {',
			'}'
		].join('\n')
	);
	assert.deepEqual(
		ahk.map((finding) => [finding.sink, finding.text]),
		[
			['TrayTip', 'Saved to disk'],
			['Ui_MsgBox', 'literal tail'],
			['Gui_Create', 'IA'],
			['AddText', 'Choose a file'],
			['MsgBox', 'Bare call text']
		],
		'the AutoHotkey scan reports literals and spares keys, options, escapes and definitions'
	);
	const lua = scanLua(
		[
			'hs.alert.show("Copied")',
			'hs.alert.show(i18n.get("copied"))',
			'notifications.notify(string.format("Saved %s", name), nil, "info")',
			'notifier.send(i18n.get("k"), { title = "Updater", level = "info" })',
			'hs.notify.new({ title = i18n.get("t"), informativeText = "Done" }):send()',
			'local x = "\\n\\n"'
		].join('\n')
	);
	assert.deepEqual(
		lua.map((finding) => [finding.sink, finding.text]),
		[
			['hs.alert.show', 'Copied'],
			['notifications.notify', 'Saved %s'],
			['notifier.send.title', 'Updater'],
			['hs.notify.new.informativeText', 'Done']
		],
		'the Lua scan reports literals in arguments and table fields and spares keys'
	);
	const js = scanJs(
		[
			"alert('Clic pour modifier');",
			"alert(_t('editor.saved'));",
			"el.textContent = count + ' mots';",
			"el.title = _t('x');",
			"html += '<span title=\"Clic ici\">' + v + '</span>';",
			'html += `<td title="${_t(\'k\')}">x</td>`;',
			"button.setAttribute('aria-label', 'Fermer');"
		].join('\n')
	);
	assert.deepEqual(
		js.map((finding) => [finding.sink, finding.text]),
		[
			['alert', 'Clic pour modifier'],
			['textContent', ' mots'],
			['html title', 'Clic ici'],
			['setAttribute(aria-label)', 'Fermer']
		],
		'the JavaScript scan reports dialogs, text properties and HTML attributes'
	);
	const shell = scanShell(
		[
			'echo "=== Installation terminée ==="',
			'\tapt) echo "glib-networking lua-luv" ;;',
			'\t\techo "apt"',
			'echo "  ✔  ${cmd} — déjà installé"',
			'printf \'%s\\n\' "$name"',
			'# echo "a comment line"',
			'[ -n "$x" ] || { echo "Missing value given" >&2; exit 1; }',
			'printf \'%s\\tlinux/bin/lib.so\\n\' "$digest" >> "$MANIFEST"',
			'echo "two words" | sha256sum',
			'printf \'%s two words\\n\' "$digest" \\',
			'\t\t>> "$MANIFEST"',
			'label=$(printf "%s and more" "$x")'
		].join('\n')
	);
	assert.deepEqual(
		shell.map((finding) => [finding.sink, finding.text]),
		[
			['echo', '=== Installation terminée ==='],
			['echo', '  ✔  ${cmd} — déjà installé'],
			['echo', 'Missing value given']
		],
		'the shell scan reports messages and spares values, captures, pipes, files and comments'
	);
}

/** Compares the tree against the baseline and fails on any difference. */
function main() {
	selfTest();
	const { reported, unusedAllowances } = applyAllowances(collectFindings());
	assert.deepEqual(
		unusedAllowances.map((entry) => `${entry.file}: ${entry.sink}: ${entry.text ?? '(any)'}`),
		[],
		'allowlist entries that match nothing any more: remove them'
	);
	const current = countFindings(reported);
	let baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
	assert.deepEqual(
		baseline,
		sortEntries(baseline),
		'the baseline stays sorted by file, sink and text'
	);
	assert.ok(
		baseline.every((entry) => Number.isSafeInteger(entry.count) && entry.count > 0),
		'every baseline entry counts at least one site'
	);
	assert.equal(
		countFindings(baseline).size,
		baseline.length,
		'the baseline lists each file, sink and text once'
	);

	if (process.argv.includes('--prune-baseline')) {
		const kept = baseline
			.map((entry) => {
				const now = current.get(JSON.stringify([entry.file, entry.sink, entry.text]));
				return now ? { ...entry, count: Math.min(entry.count, now.count) } : null;
			})
			.filter(Boolean);
		fs.writeFileSync(BASELINE_PATH, `${JSON.stringify(sortEntries(kept), null, '\t')}\n`);
		console.log(`baseline pruned: ${baseline.length - kept.length} entr(ies) removed`);
		baseline = kept;
	}

	const known = countFindings([]);
	for (const entry of baseline)
		known.set(JSON.stringify([entry.file, entry.sink, entry.text]), entry);

	const fresh = [];
	const stale = [];
	for (const [key, entry] of current) {
		const allowed = known.get(key)?.count ?? 0;
		if (entry.count > allowed) fresh.push({ ...entry, allowed });
	}
	for (const [key, entry] of known) {
		const present = current.get(key)?.count ?? 0;
		if (present < entry.count) stale.push({ ...entry, present });
	}
	const describe = (entry) => `${entry.file}: ${entry.sink}: ${JSON.stringify(entry.text)}`;
	assert.deepEqual(
		fresh.map((entry) => `${describe(entry)} (${entry.count} > ${entry.allowed})`),
		[],
		'hard-coded visible text: route these through the i18n catalogue'
	);
	assert.deepEqual(
		stale.map((entry) => `${describe(entry)} (${entry.present} < ${entry.count})`),
		[],
		'baseline entries that went away: remove them (node tools/test/test-no-hardcoded-ui-strings.cjs --prune-baseline)'
	);
	const total = baseline.reduce((sum, entry) => sum + entry.count, 0);
	console.log(
		`no hard-coded UI strings: ok (${baseline.length} baselined literal(s), ${total} site(s), none new)`
	);
}

module.exports = { applyAllowances, collectFindings, countFindings, sortEntries };
if (require.main === module) main();
