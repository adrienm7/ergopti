// tools/test/test-shared-sources-are-lf.cjs

/**
 * ==============================================================================
 * MODULE: LF Line-Ending Guard (Lua, TOML, JSON)
 * DESCRIPTION:
 * Every `.lua`, `.toml` and `.json` file under `static/ergopti_plus/` uses LF.
 * The AutoHotkey half is enforced separately by test-ahk-encoding.cjs, which also
 * checks the BOM that AHK v2 requires; nothing covered the other three.
 *
 * ROOT CAUSE ENCODED:
 * `tools/format_toml.py` wrote its output with Python's default newline
 * handling, which on Windows translates every line feed to CRLF. It went
 * unnoticed because the pre-commit hook that calls it had been naming a moved
 * path — so the formatter had not successfully run on this machine in a long
 * time. The moment the hook was repaired, its first run rewrote
 * `_shared/modules/hotstrings/_index.toml` entirely in CRLF, and git printed a
 * warning that is easy to read past.
 *
 * Two more files were already CRLF and had been for a while:
 * `_shared/modules/llm/models.json` (3 864 lines) and
 * `_shared/tests/corpus/llm/process_prediction_vectors.json`. Both parse fine —
 * which is exactly the problem. A mixed-ending repo produces diffs where every
 * line appears changed, and it hides the one edit that mattered inside them.
 *
 * WHY THESE THREE EXTENSIONS:
 * They are what the three drivers actually read at runtime: the shared Lua
 * modules, the TOML configuration and the JSON data and corpora. A CRLF here is
 * carried into whatever the driver does with the file.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

const EXTS = new Set(['.lua', '.toml', '.json']);
const SKIP_DIR = new Set(['vendor', 'node_modules', 'build']);

// Floor: over a thousand files match today, so a low count means the walk broke
// and this guard would then approve a tree it never opened.
const MIN_FILES = 800;

const offenders = [];
let checked = 0;

(function walk(dir) {
	if (!fs.existsSync(dir)) return;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (!SKIP_DIR.has(e.name)) walk(p);
			continue;
		}
		if (!EXTS.has(path.extname(e.name))) continue;
		checked++;
		const buf = fs.readFileSync(p);
		let crlf = 0;
		for (let i = 1; i < buf.length; i++) {
			if (buf[i] === 0x0a && buf[i - 1] === 0x0d) crlf++;
		}
		if (crlf > 0) {
			offenders.push({ rel: path.relative(ROOT, p).split(path.sep).join('/'), crlf });
		}
	}
})(SP);

const errors = [];

if (checked < MIN_FILES) {
	errors.push(
		`scanned only ${checked} file(s) (floor ${MIN_FILES}) — the walk is broken, and every file would ` +
			'then look clean'
	);
}

for (const o of offenders) {
	errors.push(
		`${o.rel}: ${o.crlf} CRLF line ending(s). Convert to LF. A mixed-ending file parses fine, which ` +
			'is why it survives — but it turns the next diff into one where every line changed, and hides ' +
			'the edit that mattered inside it.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] CRLF line endings in shared sources:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(`\x1b[32m[OK] all ${checked} .lua/.toml/.json file(s) under ergopti_plus use LF.\x1b[0m`);
