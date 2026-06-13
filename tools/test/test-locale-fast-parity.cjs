// tools/test/test-locale-fast-parity.cjs

/**
 * ==============================================================================
 * MODULE: Locale Fast-Parse Parity Test
 * DESCRIPTION:
 * Proves every generated ``<code>.tsv`` round-trips back to the EXACT key/value
 * map of its source ``<code>.json``. The Windows AHK driver loads the .tsv for
 * speed (~23x faster than JsonParse); this guard fails CI if a .tsv is missing,
 * stale (someone edited the .json without re-running codegen-locales-fast), or if
 * the escape/unescape contract drifts. Mirrors the AHK single-scan unescaper.
 *
 * Exit 0 = all locales in parity; exit 1 = drift (with a per-locale diff).
 * Regenerate with: node tools/codegen/codegen-locales-fast.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const LOCALES_DIR = path.join(ROOT, 'static/ergopti_plus/shared/locales');

function readJsonStripBom(file) {
	let raw = fs.readFileSync(file, 'utf8');
	if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);
	return JSON.parse(raw);
}

// Inverse of codegen-locales-fast's escapeValue, matching the AHK loader's
// single left-to-right scan (so \\ does not collide with \n / \r).
function unescapeValue(s) {
	if (s.indexOf('\\') < 0) return s;
	let out = '';
	for (let i = 0; i < s.length; i++) {
		const c = s[i];
		if (c === '\\' && i + 1 < s.length) {
			const n = s[i + 1];
			if (n === 'n') {
				out += '\n';
				i++;
				continue;
			}
			if (n === 'r') {
				out += '\r';
				i++;
				continue;
			}
			if (n === '\\') {
				out += '\\';
				i++;
				continue;
			}
		}
		out += c;
	}
	return out;
}

function parseTsv(content) {
	if (content.charCodeAt(0) === 0xfeff) content = content.slice(1);
	const m = {};
	for (const line of content.split('\n')) {
		if (line === '') continue;
		const tab = line.indexOf('\t');
		if (tab < 0) continue;
		m[line.slice(0, tab)] = unescapeValue(line.slice(tab + 1));
	}
	return m;
}

function main() {
	const codes = fs
		.readdirSync(LOCALES_DIR)
		.filter((f) => f.endsWith('.json'))
		.map((f) => f.slice(0, -5))
		.sort();

	let failures = 0;
	for (const code of codes) {
		const tsvPath = path.join(LOCALES_DIR, code + '.tsv');
		if (!fs.existsSync(tsvPath)) {
			console.error(`  FAIL ${code}: ${code}.tsv missing — run: node tools/codegen/codegen-locales-fast.cjs`);
			failures++;
			continue;
		}
		const json = readJsonStripBom(path.join(LOCALES_DIR, code + '.json'));
		const tsv = parseTsv(fs.readFileSync(tsvPath, 'utf8'));

		const jKeys = Object.keys(json);
		const diffs = [];
		if (jKeys.length !== Object.keys(tsv).length) {
			diffs.push(`key count ${jKeys.length} (json) vs ${Object.keys(tsv).length} (tsv)`);
		}
		for (const k of jKeys) {
			if (!(k in tsv)) {
				diffs.push(`missing key '${k}'`);
			} else if (tsv[k] !== json[k]) {
				diffs.push(`value drift '${k}': ${JSON.stringify(json[k])} != ${JSON.stringify(tsv[k])}`);
			}
			if (diffs.length > 5) break;
		}
		if (diffs.length) {
			console.error(`  FAIL ${code}: ${diffs.slice(0, 6).join('; ')}`);
			failures++;
		}
	}

	if (failures) {
		console.error(`\nlocale-fast-parity: ${failures} locale(s) out of parity — regenerate the .tsv files.`);
		process.exit(1);
	}
	console.log(`locale-fast-parity: OK — ${codes.length} locale(s) round-trip .json <-> .tsv exactly.`);
}

main();
