// tools/test/test-source-encoding.cjs

/**
 * ==============================================================================
 * MODULE: Source Encoding Guard (all drivers, all text assets)
 * DESCRIPTION:
 * Rejects the two encoding corruptions this repository's Windows tooling keeps
 * producing: UTF-8 that has been read as CP1252 and re-encoded, and a byte-order
 * mark prepended on top of an existing one.
 *
 * ROOT CAUSE ENCODED:
 * The only encoding gate that existed, test-ahk-encoding.cjs, is scoped to .ahk
 * files under windows/. Everything else was unguarded, and two separate asset
 * classes were silently corrupted:
 *
 *   - Three macOS Lua sources accumulated sixteen double-encoded em dashes,
 *     ellipses and arrows across three unrelated commits. One of them was not a
 *     comment: ui/menu/menu_paths.lua writes that line into the generated
 *     paths.toml, so every fresh install produced a config file whose header was
 *     mojibake - while the docstring above it promised the file stays "visually
 *     identical" to the AutoHotkey driver's.
 *   - Nineteen of the twenty-one shared locale files were given a SECOND BOM by
 *     e1d6c6f27 "standardize repository line endings to lf". A double BOM is not
 *     parseable JSON even after a consumer strips one, which is what every
 *     consumer does, so nineteen languages fell back to English.
 *
 * FEATURES & RATIONALE:
 * 1. Byte-level, not text-level: reading the file as a string would silently
 *    normalise exactly what this guard exists to catch.
 * 2. A single BOM stays legal, because AHK v2 requires one. Only a REPEATED BOM
 *    is rejected, which is the shape a re-run of a fixing tool produces.
 * 3. Covers every driver and every text asset type in one sweep, so the next
 *    asset class to be added is guarded without editing this file.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SCAN_DIRS = ['static/ergopti_plus', 'tools', 'src'];
const EXTENSIONS = ['.lua', '.ahk', '.js', '.cjs', '.mjs', '.json', '.toml', '.py', '.md'];
const SKIP_DIRS = new Set(['node_modules', '.venv', '.git', 'vendor', '.svelte-kit', 'build', '__pycache__', '.pytest_cache']);

// The CP1252 re-encoding of a UTF-8 lead byte. Any of these appearing in a UTF-8
// file means the file was decoded with the wrong codepage and written back.
//
// The signatures are declared as BYTE ARRAYS and the labels describe them in
// words. Spelling them as string literals would embed the corruption in this
// file, and the guard would flag itself — which it did, on the first run.
const MOJIBAKE_SIGNATURES = [
	{ bytes: Buffer.from([0xc3, 0xa2, 0xe2, 0x82, 0xac]), label: 'UTF-8 punctuation read as CP1252 (em dash, ellipsis, curly quote, arrow)' },
	{ bytes: Buffer.from([0xc3, 0x83, 0xc2, 0xa9]), label: 'e-acute double-encoded' },
	{ bytes: Buffer.from([0xc3, 0x83, 0xc2, 0xa8]), label: 'e-grave double-encoded' },
	{ bytes: Buffer.from([0xc3, 0x83, 0xc2, 0xa0]), label: 'a-grave double-encoded' },
	{ bytes: Buffer.from([0xc3, 0x82, 0xc2, 0xab]), label: 'left guillemet double-encoded' },
	{ bytes: Buffer.from([0xc3, 0x82, 0xc2, 0xbb]), label: 'right guillemet double-encoded' },
];

const BOM = Buffer.from([0xef, 0xbb, 0xbf]);

const problems = [];
let scanned = 0;

/**
 * Recursively collects every text asset under a directory.
 * @param {string} dir Absolute directory path.
 * @param {Array<string>} out Accumulator of absolute file paths.
 */
function collect(dir, out) {
	let entries;
	try {
		entries = fs.readdirSync(dir, { withFileTypes: true });
	} catch {
		return;
	}
	for (const entry of entries) {
		if (entry.isDirectory()) {
			if (SKIP_DIRS.has(entry.name)) continue;
			collect(path.join(dir, entry.name), out);
		} else if (EXTENSIONS.includes(path.extname(entry.name))) {
			out.push(path.join(dir, entry.name));
		}
	}
}

/**
 * Reports the 1-based line number of a byte offset, for a legible failure.
 * @param {Buffer} buf File contents.
 * @param {number} offset Byte offset.
 * @returns {number} Line number.
 */
function lineOf(buf, offset) {
	let line = 1;
	for (let i = 0; i < offset && i < buf.length; i += 1) {
		if (buf[i] === 0x0a) line += 1;
	}
	return line;
}

const files = [];
for (const dir of SCAN_DIRS) collect(path.join(ROOT, dir), files);

for (const file of files) {
	const rel = path.relative(ROOT, file).replace(/\\/g, '/');
	const buf = fs.readFileSync(file);
	scanned += 1;

	// A second BOM. One is legal (AHK requires it); two is a tool that ran twice.
	if (buf.length >= 6 && buf.subarray(0, 3).equals(BOM) && buf.subarray(3, 6).equals(BOM)) {
		problems.push(`${rel}:1 — repeated UTF-8 BOM (a strict parser rejects it even after stripping one)`);
	}

	for (const sig of MOJIBAKE_SIGNATURES) {
		const at = buf.indexOf(sig.bytes);
		if (at !== -1) {
			problems.push(`${rel}:${lineOf(buf, at)} — double-encoded UTF-8: ${sig.label}`);
			break;
		}
	}

	// Invalid UTF-8 anywhere. Node's decoder substitutes U+FFFD rather than
	// throwing, so round-tripping is the reliable check.
	const decoded = buf.toString('utf8');
	if (!Buffer.from(decoded, 'utf8').equals(buf)) {
		problems.push(`${rel} — not valid UTF-8`);
	}
}

if (problems.length > 0) {
	console.error('[FAIL] source encoding:');
	for (const p of problems) console.error(`  - ${p}`);
	console.error('');
	console.error('  These are produced by a tool reading UTF-8 with the wrong codepage and');
	console.error('  writing it back — on Windows, typically PowerShell redirection or');
	console.error('  Set-Content without -Encoding utf8. Repair the bytes, do not re-type the text.');
	process.exit(1);
}

console.log(`[OK] Source encoding clean (${scanned} text asset(s) scanned).`);
