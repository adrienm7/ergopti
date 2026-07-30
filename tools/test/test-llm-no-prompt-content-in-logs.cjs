// tools/test/test-llm-no-prompt-content-in-logs.cjs

/**
 * ==============================================================================
 * MODULE: LLM Log-Content Privacy Gate
 * DESCRIPTION:
 * The LLM path sees everything the user types. No driver may write that text to
 * a log: the size of the context is diagnostic, its content is a keystroke sink.
 *
 * ROOT CAUSE ENCODED:
 * windows/modules/llm/prediction_exec.ahk built `preview := SubStr(tail, -40)`
 * and logged it at INFO on EVERY prediction request, so the daily log
 * accumulated a rolling 40-character sample of everything typed while the LLM
 * was enabled. docs/security/keylogger_privacy.md governs today.log and
 * data.sql; it says nothing about this sink, so the trade-off was never
 * accepted. macOS logged only a character count for the same event.
 *
 * WHAT IS FORBIDDEN:
 * Taking a substring of the typing context purely to put it in a log line. That
 * is expressed concretely: no logger call inside the drivers' LLM modules may
 * carry a substring expression in its argument list. Lengths (StrLen, #s, string
 * lengths) are explicitly fine and are what the fixed call sites use.
 *
 * FEATURES & RATIONALE:
 * 1. Class, not site: scans every LLM module of all three drivers, so the next
 *    call site is covered without editing this gate.
 * 2. Code only: comments are stripped before matching, because the fixed sites
 *    explain the defect in prose and a ratchet that counts comments would flag
 *    the very explanation (a documented foot-gun in this repo).
 * 3. Fails loudly when it scans nothing, so a stale path cannot make it vacuous.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');

// LLM code per driver, plus the shared Lua the Lua drivers require.
const SCAN_DIRS = [
	path.join(DRIVERS, 'windows', 'modules', 'llm'),
	path.join(DRIVERS, 'windows', 'ui', 'menu', 'menu_llm'),
	path.join(DRIVERS, 'macos', 'modules', 'llm'),
	path.join(DRIVERS, 'macos', 'ui', 'menu', 'menu_llm'),
	path.join(DRIVERS, 'linux', 'modules', 'llm'),
	path.join(DRIVERS, '_shared', 'lua', 'llm')
];

const EXTS = new Set(['.ahk', '.lua']);
const COMMENT = { '.ahk': ';', '.lua': '--' };

// A logger call in any of the three dialects.
const LOGGER_CALL = /\b(?:Logger(?:Info|Debug|Warn|Error|Start|Success|Trace|Done)|Logger\.(?:info|debug|warn|error|start|success|trace|done))\s*\(/;

// Substring extraction — the shape that turns user text into a log argument.
const SUBSTRING_EXPR = /\b(?:SubStr|string\.sub)\s*\(/;

const errors = [];
let filesScanned = 0;
let loggerLinesSeen = 0;

/** Returns the code part of a line for the given extension. */
function codeOnly(line, ext) {
	const marker = COMMENT[ext];
	if (!marker) return line;
	const at = line.indexOf(marker);
	return at === -1 ? line : line.slice(0, at);
}

/** Collects source files under a directory, recursively. */
function collect(dir, out = []) {
	if (!fs.existsSync(dir)) return out;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name === 'vendor' || e.name === '_generated') continue;
			collect(full, out);
		} else if (EXTS.has(path.extname(e.name))) {
			out.push(full);
		}
	}
	return out;
}

for (const dir of SCAN_DIRS) {
	for (const full of collect(dir)) {
		filesScanned++;
		const ext = path.extname(full);
		const rel = path.relative(ROOT, full).replace(/\\/g, '/');
		const lines = fs.readFileSync(full, 'utf8').split('\n');

		for (let i = 0; i < lines.length; i++) {
			const code = codeOnly(lines[i], ext);
			if (!LOGGER_CALL.test(code)) continue;
			loggerLinesSeen++;
			if (SUBSTRING_EXPR.test(code)) {
				errors.push(
					`${rel}:${i + 1}: a logger call carries a substring expression. ` +
					'Log the length of the context, never a slice of it — the LLM path ' +
					'sees everything the user types.'
				);
			}
		}
	}
}

if (filesScanned === 0) {
	errors.push('scanned zero LLM files — SCAN_DIRS is stale, not the tree.');
}
if (loggerLinesSeen === 0) {
	errors.push('found no logger call in the LLM modules — the matcher is stale, not the tree.');
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] LLM logs may leak typed text:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No LLM logger call slices the typed context ` +
	`(${loggerLinesSeen} logger line(s) across ${filesScanned} file(s)).\x1b[0m`
);
