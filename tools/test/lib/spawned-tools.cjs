// tools/test/lib/spawned-tools.cjs

/**
 * ==============================================================================
 * MODULE: Spawned Tools
 * DESCRIPTION:
 * Derives, from the driver sources themselves, the external programs the macOS
 * and Linux drivers start: docs/design/owned-runtimes.md must list each one
 * with a proposal (own and pin it, or take the system copy with a version check
 * and a clear refusal), and a spawn added without a row fails the inventory
 * test instead of joining the product unnoticed.
 *
 * FEATURES & RATIONALE:
 * A program counts as started when a string literal outside comments:
 * 1. is an absolute path in a system program folder (`/usr/bin/awk`), or a
 *    `/bin/<name>` suffix joined to an owned prefix (`root .. "/bin/ollama"`);
 * 2. is a bare program name given to a PATH lookup (`has_command("zenity")`),
 *    kept in a program constant (`local PYTHON = "python3"`), handed to
 *    `luv.spawn` or followed by its argument vector (`"xdotool", { ... }`), or
 *    the program of a `command -v`;
 * 3. is shell text: the first literal argument of a call that only starts
 *    processes (exec, execute, popen, spawn, system, shell), of a generic one
 *    (run, start, query, launch, capture) when it holds a space, the value of
 *    a `tool`, `command` or `cmd` field, or any literal with shell syntax
 *    (`2>/dev/null`, `||`, `&&`, `$(`). Each command position of that text
 *    (its first word and the word after `|`, `||`, `&&`, `;`, `$(` and a
 *    backtick) names a program, unless the file's scripts define it as a
 *    shell function.
 * 4. Shell builtins and keywords are not programs; SQL and awk programs are
 *    not shell text. Swift sources are read for rule 1 only (`Process` takes an
 *    absolute URL); tests, vendored code and generated files are not read.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const DRIVERS = Object.freeze({
	linux: 'static/ergopti_plus/linux',
	macos: 'static/ergopti_plus/macos',
});
// Folders that hold tests, vendored libraries or generated data, not driver code.
const SKIPPED_FOLDERS = new Set(['tests', 'Tests', 'vendor', 'node_modules', '_generated', '.build', 'old']);

const SYSTEM_PROGRAM =
	/^\/(?:usr\/(?:local\/)?)?(?:s?bin|libexec)\/([A-Za-z0-9._+-]+)$|^\/opt\/homebrew\/bin\/([A-Za-z0-9._+-]+)$/;
const OWNED_SUFFIX = /^\/bin\/([A-Za-z0-9._+-]+)$/;
// Callees that only ever start a process take any literal; the generic verbs
// also name timers, phases and loggers, so their literal must be shell text.
const SPAWN_CALLEE = /(?:^|[.:])_?(?:exec|execute|popen|spawn|system|shell)(?:_[a-z_]+)?$/i;
const GENERIC_CALLEE = /(?:^|[.:])_?(?:run|start|query|launch|capture)(?:_(?:command|background|async|checked|line|process|program))?$/;
const LOGGER_CALLEE = /^(?:Logger|log)[.:]/;
const SQL_CALLEE = /sql|rows|(?:^|[.:])db[.:]/i;
const LOOKUP_CALLEE = /(?:^|[.:])_?(?:has_command|command_exists|find_executable|which|validate_spawn_args)$/;
const COMMAND_FIELD = /\b(?:tool|command|cmd)\s*=\s*$/;
const PROGRAM_CONSTANT = /\blocal\s+[A-Z_]*(?:BIN|TOOL|PROGRAM|EXECUTABLE|CLI|PYTHON|CMD|COMMAND)\s*=\s*$/;
const SHELL_SYNTAX = /2>\/dev\/null|>\s*\/dev\/null| \|\| | && |\$\(/;
// Programs for another interpreter (awk, SQL) are kept in named constants.
const FOREIGN_PROGRAM = /\b[A-Z_]*(?:AWK|SQL|JS)[A-Z_]*\s*=\s*$/;
const SQL_TEXT = /^\s*(?:BEGIN|SELECT|INSERT|CREATE|UPDATE|DELETE|ALTER|PRAGMA|WITH|DROP|REPLACE)\b/i;
const PROGRAM_WORD = /^[a-z][a-z0-9._+-]*[a-z0-9]$/;
// Words that precede the program of a command.
const PREFIX_WORDS = new Set(['if', 'then', 'else', 'elif', 'while', 'until', 'do', '!', '{', 'exec', 'command',
	'env', 'nohup', 'time']);
// Shell keywords and builtins: a command, never a program.
const SHELL_WORDS = new Set([
	'fi', 'case', 'esac', 'in', 'for', 'done', 'function', 'eval', 'set', 'unset', 'export', 'local', 'readonly',
	'shift', 'trap', 'exit', 'return', 'break', 'continue', 'read', 'cd', 'pwd', 'echo', 'printf', 'test', 'true',
	'false', 'kill', 'wait', 'umask', 'ulimit', 'type', 'hash', 'times', 'getopts', 'alias', 'source',
]);

/**
 * Lists the driver source files of one driver.
 * @param {string} driver Key of DRIVERS.
 * @returns {string[]} Repository-relative paths.
 */
function sourceFiles(driver) {
	const found = [];
	const walk = (relative) => {
		for (const entry of fs.readdirSync(path.join(ROOT, relative), { withFileTypes: true })) {
			const child = `${relative}/${entry.name}`;
			if (entry.isDirectory()) {
				if (!SKIPPED_FOLDERS.has(entry.name)) walk(child);
			} else if (/\.(lua|swift)$/.test(entry.name)) {
				found.push(child);
			}
		}
	};
	walk(DRIVERS[driver]);
	return found.sort();
}

/**
 * Splits Lua source into its string literals, each with the code before and
 * after it, comments removed and other literals blanked.
 * @param {string} text Lua source.
 * @returns {{ value: string, before: string, after: string }[]}
 */
function luaLiterals(text) {
	const literals = [];
	let code = '';
	let index = 0;
	const longBracket = (at) => {
		const match = /^\[(=*)\[/.exec(text.slice(at, at + 64));
		return match ? match[1].length : -1;
	};
	const keep = (value) => {
		literals.push({ value, before: code, at: code.length });
		code += ' "" ';
	};
	while (index < text.length) {
		const char = text[index];
		if (char === '-' && text[index + 1] === '-') {
			const level = longBracket(index + 2);
			const close = level >= 0 ? text.indexOf(`]${'='.repeat(level)}]`, index) : text.indexOf('\n', index);
			index = close < 0 ? text.length : close + (level >= 0 ? level + 2 : 0);
			continue;
		}
		if (char === '"' || char === "'") {
			let value = '';
			let at = index + 1;
			while (at < text.length && text[at] !== char && text[at] !== '\n') {
				if (text[at] === '\\') {
					const escaped = text[at + 1];
					value += escaped === 'n' ? '\n' : escaped === 't' ? '\t' : escaped;
					at += 2;
				} else {
					value += text[at];
					at += 1;
				}
			}
			keep(value);
			index = at + 1;
			continue;
		}
		const level = char === '[' ? longBracket(index) : -1;
		if (level >= 0) {
			const open = index + level + 2;
			const close = text.indexOf(`]${'='.repeat(level)}]`, open);
			const end = close < 0 ? text.length : close;
			keep(text.slice(open, end).replace(/^\n/, ''));
			index = end + level + 2;
			continue;
		}
		code += char;
		index += 1;
	}
	return literals.map((literal) => ({
		value: literal.value,
		before: literal.before,
		after: code.slice(literal.at + 4, literal.at + 64),
	}));
}

/**
 * Names the programs at the command positions of a shell text.
 * @param {string} shell Shell command text.
 * @param {boolean} [continued] The text is joined after other text.
 * @param {Set<string>} [functions] Shell functions the file's scripts define.
 * @returns {string[]}
 */
function shellPrograms(shell, continued = false, functions = new Set()) {
	const programs = [];
	const segments = shell.split(/\|\||&&|[|;`\n]|\$\(/);
	for (const [index, segment] of segments.entries()) {
		// A fragment joined after other text continues a command already named.
		if (index === 0 && continued) continue;
		if (/^\s*\(/.test(segment)) continue;
		const words = segment.trim().split(/\s+/).filter(Boolean);
		while (words.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0]) || PREFIX_WORDS.has(words[0])
			|| /^[0-9]*[<>]/.test(words[0]))) {
			// A bare redirection operator takes the next word as its target.
			if (/^[0-9]*[<>]+&?$/.test(words.shift())) words.shift();
		}
		const word = (words[0] || '').replace(/^['"]+|['"]+$/g, '');
		const name = word.includes('/') ? word.slice(word.lastIndexOf('/') + 1) : word;
		if (PROGRAM_WORD.test(name) && !SHELL_WORDS.has(name) && !functions.has(name)) programs.push(name);
	}
	return programs;
}

/**
 * Derives the programs one Lua literal starts.
 * @param {{ value: string, before: string, after: string }} literal
 * @param {Set<string>} [functions] Shell functions the file's scripts define.
 * @returns {string[]}
 */
function literalPrograms({ value, before, after }, functions = new Set()) {
	const programs = [];
	const system = SYSTEM_PROGRAM.exec(value);
	if (system) programs.push(system[1] || system[2]);
	const owned = OWNED_SUFFIX.exec(value);
	if (owned && /\.\.\s*$/.test(before)) programs.push(owned[1]);
	for (const match of value.matchAll(/\bcommand -v ([a-z][a-z0-9._+-]*)/g)) programs.push(match[1]);
	const call = /([A-Za-z_][\w.:]*)\s*\(\s*$/.exec(before);
	const callee = call ? call[1] : '';
	const argv = /^\s*,\s*\{/.test(after);
	if (PROGRAM_WORD.test(value)) {
		const named = LOOKUP_CALLEE.test(callee) || PROGRAM_CONSTANT.test(before) || /\bspawn\s*,\s*$/.test(before)
			|| (argv && (SPAWN_CALLEE.test(callee) || GENERIC_CALLEE.test(callee)))
			|| (/^\s*,\s*\{\s*""/.test(after) && /\breturn\s*$/.test(before));
		if (named) programs.push(value);
	}
	if (SQL_CALLEE.test(callee) || SQL_TEXT.test(value) || FOREIGN_PROGRAM.test(before)) return programs;
	if (LOGGER_CALLEE.test(callee)) return programs;
	const shellText = /\s/.test(value.trim());
	if (SPAWN_CALLEE.test(callee) || (GENERIC_CALLEE.test(callee) && shellText) || COMMAND_FIELD.test(before)
		|| SHELL_SYNTAX.test(value)) {
		programs.push(...shellPrograms(value, /\.\.\s*$/.test(before), functions));
	}
	return programs;
}

/**
 * Derives the programs one source file starts.
 * @param {string} relative Repository-relative path.
 * @returns {Set<string>}
 */
function programsOf(relative) {
	const text = fs.readFileSync(path.join(ROOT, relative), 'utf8');
	const programs = new Set();
	if (relative.endsWith('.swift')) {
		for (const match of text.matchAll(/"([^"\n]+)"/g)) {
			const system = SYSTEM_PROGRAM.exec(match[1]);
			if (system) programs.add(system[1] || system[2]);
		}
		return programs;
	}
	const literals = luaLiterals(text);
	const functions = new Set();
	for (const { value } of literals) {
		for (const match of value.matchAll(/(?:^|[\s;{])([a-z_][a-z0-9_]*)\s*\(\)/g)) functions.add(match[1]);
	}
	for (const literal of literals) {
		for (const name of literalPrograms(literal, functions)) programs.add(name);
	}
	return programs;
}

/**
 * Derives every program a driver starts, with the files that start it.
 * @param {string} driver Key of DRIVERS.
 * @returns {Map<string, string[]>} Program name to repository-relative files.
 */
function spawnedTools(driver) {
	const tools = new Map();
	for (const file of sourceFiles(driver)) {
		for (const name of programsOf(file)) {
			if (!tools.has(name)) tools.set(name, []);
			tools.get(name).push(file);
		}
	}
	return tools;
}

module.exports = { DRIVERS, luaLiterals, shellPrograms, literalPrograms, spawnedTools };
