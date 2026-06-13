// tools/codegen/codegen-locales-fast.cjs

/**
 * ==============================================================================
 * MODULE: Locale Fast-Parse Codegen
 * DESCRIPTION:
 * Generates a flat, fast-to-parse ``<code>.tsv`` next to every shared locale
 * ``<code>.json`` in static/ergopti_plus/shared/locales/. The Windows AHK driver
 * reads the .tsv for the ACTIVE locale at boot: a tight StrSplit loop parses it in
 * ~8 ms versus ~190 ms for the pure-AHK recursive-descent JsonParse of the same
 * 2196-key JSON (a measured ~23x speedup, ~184 ms off the boot critical path).
 *
 * FEATURES & RATIONALE:
 * 1. JSON stays the single source of truth: the .tsv is a derived build artifact.
 *    The macOS/Hammerspoon driver keeps reading the .json; the .tsv is Windows-only
 *    and the AHK loader falls back to the .json if a .tsv is missing.
 * 2. Lossless round-trip: a flat object {string: string} maps 1:1 to
 *    ``key<TAB>value`` lines. Values are escaped (backslash, CR, LF) so the format
 *    stays one-record-per-line; tools/test/test-locale-fast-parity.cjs proves the
 *    .tsv round-trips back to the exact .json key/value map (catches staleness).
 * 3. Flat-only contract: locale JSONs are flat string maps. A non-string value
 *    aborts generation loudly rather than silently emitting a broken record.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const LOCALES_DIR = path.join(ROOT, 'static/ergopti_plus/shared/locales');

// Escape a value so it occupies exactly one TSV record. Backslash MUST be escaped
// first so the CR/LF escapes it introduces are not themselves re-escaped, and so
// the AHK single-scan unescaper can invert it unambiguously.
function escapeValue(v) {
	return v.split('\\').join('\\\\').split('\r').join('\\r').split('\n').join('\\n');
}

function readJsonStripBom(file) {
	let raw = fs.readFileSync(file, 'utf8');
	if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);
	return JSON.parse(raw);
}

function generateOne(code) {
	const jsonPath = path.join(LOCALES_DIR, code + '.json');
	const tsvPath = path.join(LOCALES_DIR, code + '.tsv');
	const data = readJsonStripBom(jsonPath);

	const lines = [];
	for (const key of Object.keys(data)) {
		const val = data[key];
		if (typeof val !== 'string') {
			throw new Error(
				`Locale '${code}' key '${key}' has a non-string value (${typeof val}); ` +
					`the fast-parse format only supports flat {string: string} locales.`
			);
		}
		if (key.includes('\t') || key.includes('\n') || key.includes('\r')) {
			throw new Error(`Locale '${code}' key '${key}' contains a tab/newline; not representable as TSV.`);
		}
		lines.push(key + '\t' + escapeValue(val));
	}
	// LF line endings, UTF-8 without BOM: AHK FileRead(path, "UTF-8") handles both,
	// and the parser splits on "`n" trimming "`r", so either ending works.
	fs.writeFileSync(tsvPath, lines.join('\n') + '\n', 'utf8');
	return lines.length;
}

function main() {
	const codes = fs
		.readdirSync(LOCALES_DIR)
		.filter((f) => f.endsWith('.json'))
		.map((f) => f.slice(0, -5))
		.sort();

	let total = 0;
	for (const code of codes) {
		const n = generateOne(code);
		total += n;
		console.log(`  ${code}.tsv  (${n} keys)`);
	}
	console.log(`codegen-locales-fast: generated ${codes.length} .tsv file(s), ${total} record(s) total.`);
}

main();
