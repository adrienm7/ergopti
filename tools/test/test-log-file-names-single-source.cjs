// tools/test/test-log-file-names-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Log File Names Single-Source Guard
 * DESCRIPTION:
 * Fails when driver code spells a log file-name prefix itself instead of
 * reading it from the generated application-folders data
 * (_shared/modules/paths/app_dirs.toml, emitted by codegen-app-dirs.cjs).
 *
 * ROOT CAUSE ENCODED:
 * The dated names were rebuilt from literals in about twenty files across the
 * three drivers and the native launcher, and so was the folder they live in.
 * The copies agreed until one moved: the macOS menu, gesture actions and
 * health check kept the path the logger chose at boot while the native worker
 * rolled its files at midnight, so every "open today's log" after midnight
 * opened yesterday's file. A resolver owns the name now; this gate keeps a
 * second spelling from reappearing next to it.
 *
 * WHAT COUNTS AS A SPELLING:
 * A string literal in executable code (comments are stripped) that contains
 * the errors prefix, or the unified prefix followed by nothing, by a pattern
 * or interpolation marker, or by a ".log" name. Other names that merely begin
 * with the same word (an ".exe" or an ".ini") are not log names. Tests are not
 * scanned: their expected paths must stay independent of the code under test.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

const registry = toml.parse(
	fs.readFileSync(path.join(SP, '_shared/modules/paths/app_dirs.toml'), 'utf8')
);
const FILES = registry.logs.files;
const UNIFIED = FILES.unified_prefix;
const ERRORS = FILES.errors_prefix;

// The generated owners, which are the only files allowed to spell the names.
const GENERATED_OWNERS = [
	'_shared/lua/app_dirs.lua',
	'windows/_generated/app_dirs.ahk',
	'macos/launcher/Sources/ErgoptiPlus/AppDirs.generated.swift'
];

// Generated from those owners by another generator, outside a _generated/
// folder because SwiftPM compiles only its Sources tree.
const GENERATED_DERIVED = ['macos/launcher/Sources/ErgoptiPlus/LoggerTopics.generated.swift'];

const SCANNED_ROOTS = [
	{ dir: path.join(SP, 'macos'), rel: 'static/ergopti_plus/macos' },
	{ dir: path.join(SP, 'windows'), rel: 'static/ergopti_plus/windows' },
	{ dir: path.join(SP, 'linux'), rel: 'static/ergopti_plus/linux' },
	{ dir: path.join(SP, '_shared'), rel: 'static/ergopti_plus/_shared' },
	{ dir: path.join(ROOT, 'tools', 'codegen'), rel: 'tools/codegen' }
];

const EXTENSIONS = new Set(['.lua', '.ahk', '.swift', '.js', '.cjs', '.mjs']);
const SKIPPED_DIRS = new Set([
	'tests',
	'Tests',
	'vendor',
	'node_modules',
	'_generated',
	'.build',
	'corpus'
]);

/** Lists every scanned source file below `dir`. */
function walk(dir, out) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (entry.isDirectory()) {
			if (!SKIPPED_DIRS.has(entry.name)) walk(path.join(dir, entry.name), out);
		} else if (EXTENSIONS.has(path.extname(entry.name))) {
			out.push(path.join(dir, entry.name));
		}
	}
	return out;
}

/**
 * Returns the string literals of executable code, with their line numbers.
 * One scanner for the four syntaxes: it tracks quotes so a comment marker
 * inside a string is data, and drops line and block comments.
 * @param {string} src File content.
 * @param {string} ext File extension.
 * @returns {{line: number, text: string}[]}
 */
function literals(src, ext) {
	const isLua = ext === '.lua';
	const isAhk = ext === '.ahk';
	const escape = isAhk ? '`' : '\\';
	const quotes = isAhk
		? ['"', "'"]
		: ext === '.swift'
			? ['"']
			: isLua
				? ['"', "'"]
				: ['"', "'", '`'];
	const found = [];
	let line = 1;
	let i = 0;
	while (i < src.length) {
		const c = src[i];
		if (c === '\n') {
			line++;
			i++;
			continue;
		}
		// Block comments.
		const blockOpen = isLua ? src.startsWith('--[[', i) : !isLua && src.startsWith('/*', i);
		if (blockOpen) {
			const close = src.indexOf(isLua ? ']]' : '*/', i + 2);
			const end = close < 0 ? src.length : close + 2;
			line += (src.slice(i, end).match(/\n/g) || []).length;
			i = end;
			continue;
		}
		// Line comments.
		const lineComment = isLua
			? src.startsWith('--', i)
			: isAhk
				? c === ';' && (i === 0 || /\s/.test(src[i - 1]))
				: src.startsWith('//', i);
		if (lineComment) {
			const end = src.indexOf('\n', i);
			i = end < 0 ? src.length : end;
			continue;
		}
		if (quotes.includes(c)) {
			let j = i + 1;
			let text = '';
			while (j < src.length && src[j] !== c && !(src[j] === '\n' && c !== '`')) {
				if (src[j] === escape && j + 1 < src.length) {
					text += src[j] + src[j + 1];
					j += 2;
					continue;
				}
				text += src[j];
				j++;
			}
			found.push({ line, text });
			line += (text.match(/\n/g) || []).length;
			i = j + 1;
			continue;
		}
		i++;
	}
	return found;
}

/** True when a literal spells a log file name. */
function spellsLogName(text) {
	if (text.includes(ERRORS)) return true;
	const at = text.indexOf(UNIFIED);
	if (at < 0) return false;
	const rest = text.slice(at + UNIFIED.length);
	if (rest === '') return true;
	if (/^[$*%{(\\[]/.test(rest)) return true;
	return rest.includes(FILES.extension);
}

const violations = [];
let scannedFiles = 0;
let scannedLiterals = 0;

for (const root of SCANNED_ROOTS) {
	for (const abs of walk(root.dir, [])) {
		const rel = path.relative(SP, abs).split(path.sep).join('/');
		if (GENERATED_OWNERS.includes(rel) || GENERATED_DERIVED.includes(rel)) continue;
		scannedFiles++;
		const src = fs.readFileSync(abs, 'utf8');
		for (const literal of literals(src, path.extname(abs))) {
			scannedLiterals++;
			if (spellsLogName(literal.text)) {
				const shown = path.relative(ROOT, abs).split(path.sep).join('/');
				violations.push(`${shown}:${literal.line}: "${literal.text}"`);
			}
		}
	}
}

// A scan that finds nothing to scan is a false green.
const floors = [];
if (scannedFiles < 500) floors.push(`only ${scannedFiles} source files were scanned`);
if (scannedLiterals < 20000) floors.push(`only ${scannedLiterals} string literals were scanned`);
for (const owner of GENERATED_OWNERS) {
	const content = fs.readFileSync(path.join(SP, owner), 'utf8');
	if (!content.includes(ERRORS) || !content.includes(UNIFIED)) {
		floors.push(`${owner} no longer carries the log prefixes it owns`);
	}
}
// The detector itself must recognise the spellings it exists to forbid.
for (const sample of [
	ERRORS,
	UNIFIED,
	`${UNIFIED}\\(date)`,
	`^${UNIFIED}(%d)`,
	`${UNIFIED}*${FILES.extension}`,
	`${UNIFIED}boot${FILES.extension}`
]) {
	if (!spellsLogName(sample)) floors.push(`the detector misses ${JSON.stringify(sample)}`);
}
for (const sample of [`${UNIFIED}new.exe`, `${UNIFIED}Configuration.ini`]) {
	if (spellsLogName(sample))
		floors.push(`the detector flags the non-log name ${JSON.stringify(sample)}`);
}

if (floors.length || violations.length) {
	for (const f of floors) console.error(`\x1b[31m[ERROR] ${f}\x1b[0m`);
	if (violations.length) {
		console.error(
			`\x1b[31m[ERROR] ${violations.length} literal(s) spell a log file name outside ` +
				'the generated application-folders data:\x1b[0m'
		);
		for (const v of violations) console.error(`  ${v}`);
		console.error('Read the name from the driver resolver (app_dirs data) instead.');
	}
	process.exit(1);
}

console.log(
	`[OK] log file names are spelled only by the generated app_dirs data ` +
		`(${scannedFiles} files, ${scannedLiterals} literals scanned).`
);

/** Exercises the actual generator with a closed in-memory output owner. */
function assertManagedWindowsRuntimeContract() {
	const assert = require('node:assert/strict');
	const vm = require('node:vm');
	const source = fs.readFileSync(path.join(SP, '_shared/modules/paths/app_dirs.toml'), 'utf8');
	const generator = fs.readFileSync(path.join(ROOT, 'tools/codegen/codegen-app-dirs.cjs'), 'utf8');
	const declared = toml.parse(source);
	const nativeFunction = 'AppDirsWindowsManagedOllamaFolderName';
	const targets = GENERATED_OWNERS.map((p) => path.join(SP, p));
	function generate(input) {
		const writes = new Map();
		const messages = [];
		let refusal = false;
		const sourcePath = path.join(SP, '_shared/modules/paths/app_dirs.toml');
		const filesystem = {
			readFileSync(filename, encoding) {
				assert.equal(filename, sourcePath);
				assert.equal(encoding, 'utf8');
				return input;
			},
			mkdirSync(filename) {
				assert(targets.some((target) => path.dirname(target) === filename));
			},
			writeFileSync(filename, content, encoding) {
				assert(targets.includes(filename), 'Unknown generated output is not owned.');
				assert.equal(encoding, 'utf8');
				assert(!writes.has(filename), 'Each generated output is written once.');
				writes.set(filename, content);
			}
		};
		const exit = {};
		try {
			vm.runInNewContext(
				generator,
				{
					__dirname: path.join(ROOT, 'tools/codegen'),
					require(name) {
						if (name === 'fs') return filesystem;
						if (name === 'path') return path;
						if (name === 'smol-toml') return toml;
						throw new Error(`Unowned generator dependency ${name}.`);
					},
					console: {
						log() {},
						error(message) {
							messages.push(message);
						}
					},
					process: {
						exit(code) {
							assert.equal(code, 1);
							throw exit;
						}
					}
				},
				{ timeout: 2000, filename: 'actual-app-dirs-generator.cjs' }
			);
		} catch (error) {
			if (error !== exit) throw error;
			refusal = true;
		}
		return { writes, messages, refusal };
	}
	const healthy = generate(source);
	assert(!healthy.refusal);
	assert.equal(healthy.writes.size, 3);
	const ahk = healthy.writes.get(path.join(SP, 'windows/_generated/app_dirs.ahk'));
	assert(ahk.startsWith('\uFEFF'));
	assert(!ahk.includes('\r'));
	assert(
		ahk.includes(`${nativeFunction}() {\n\treturn "ergopti_plus_ollama"\n}`),
		'The actual generator must emit AppDirsWindowsManagedOllamaFolderName from the shared declaration.'
	);
	assert.equal(declared.runtime.windows.managed_ollama_folder_name, 'ergopti_plus_ollama');
	assert.equal(ahk, fs.readFileSync(path.join(SP, 'windows/_generated/app_dirs.ahk'), 'utf8'));
	for (const file of GENERATED_OWNERS.filter((p) => !p.endsWith('.ahk'))) {
		assert.equal(
			healthy.writes.get(path.join(SP, file)),
			fs.readFileSync(path.join(SP, file), 'utf8'),
			'Existing macOS/Linux paths remain unchanged.'
		);
	}
	const invalid = [
		undefined,
		null,
		false,
		7,
		[],
		'',
		'.',
		'..',
		'a/b',
		'a\\b',
		'a:b',
		'a<b',
		'a>b',
		'a"b',
		'a|b',
		'a?b',
		'a*b',
		'a\0b',
		'a\nb',
		'a\u0085b',
		'tail.',
		'tail ',
		'CON',
		'con.txt',
		'PrN.any',
		'AUX',
		'nul',
		'COM1',
		'com9.ext',
		'LPT1',
		'lpt9.ext',
		'COM¹',
		'LPT².txt',
		'CONIN$',
		'conout$.txt',
		declared.app.folder_name,
		declared.app.folder_name.toUpperCase()
	];
	for (const value of invalid) {
		const candidate = toml.parse(source);
		if (value === undefined) delete candidate.runtime.windows.managed_ollama_folder_name;
		else if (value === null) delete candidate.runtime.windows;
		else candidate.runtime.windows.managed_ollama_folder_name = value;
		const result = generate(toml.stringify(candidate));
		assert(result.refusal, `Invalid managed root was accepted: ${JSON.stringify(value)}.`);
		assert.equal(result.writes.size, 0, 'Refusal precedes every generated output.');
		assert(
			result.messages.some((message) =>
				message.includes('runtime.windows.managed_ollama_folder_name')
			)
		);
	}
	for (const value of ['runtime-safe', 'résident_ollama', 'CONSOLE', 'com10', 'LPT10.data']) {
		const candidate = toml.parse(source);
		candidate.runtime.windows.managed_ollama_folder_name = value;
		const result = generate(toml.stringify(candidate));
		assert(!result.refusal, `Valid managed root was refused: ${value}.`);
		assert(
			result.writes
				.get(path.join(SP, 'windows/_generated/app_dirs.ahk'))
				.includes(`return "${value}"`)
		);
	}
	console.log(
		`[OK] managed Windows runtime root: exact generated owner, ${invalid.length} refusals and five valid controls.`
	);
}

assertManagedWindowsRuntimeContract();
