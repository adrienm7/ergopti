// scripts/test-manifest-equivalence.cjs

/**
 * ==============================================================================
 * MODULE: Manifest Reader Equivalence Test — Item 5.1.4
 * DESCRIPTION:
 * Verifies that the AHK and Hammerspoon drivers produce an identical Features
 * Map — same keys, same enabled/disabled states — when fed the same TOML
 * config fixture.
 *
 * FEATURES & RATIONALE:
 * 1. End-to-end config resolution: parses the fixture TOML, looks up each
 *    cross-platform feature path in the parsed tree, and checks both drivers
 *    would see the same resolved value.
 * 2. Default value parity: for any feature path absent from the fixture TOML,
 *    both manifests must declare the same default — catching build-script drift
 *    that would cause one driver to silently differ at runtime.
 * 3. Manifest metadata consistency: the manifest default emitted for each
 *    cross-platform feature must be identical in both generated files, even
 *    when the user overrides it in their config.
 * 4. No interpreter dependency: all checks are done in JavaScript by parsing
 *    the generated manifest files with the same regex strategy used by
 *    test-manifest-parity.cjs — no AHK or Lua runtime is required in CI.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared } = require('../lib/paths.cjs');

const REPO_ROOT = path.resolve(__dirname, '..', '..');

const AHK_MANIFEST = path.join(
	REPO_ROOT,
	'static/ergopti_plus/windows/_generated/features_manifest.ahk'
);
const HS_MANIFEST = path.join(
	REPO_ROOT,
	'static/ergopti_plus/macos/_generated/features_manifest.lua'
);
// Read only for the divergence check below. This gate compared two drivers
// because for most of its life there were two generated manifests; a third
// arrived and the comparison did not widen, so a default that differs ONLY on
// Linux read as a stale per-platform entry.
const LINUX_MANIFEST = path.join(
	REPO_ROOT,
	'static/ergopti_plus/linux/_generated/features_manifest.lua'
);
const FIXTURE_CONFIG = shared('tests/fixtures/test_config.toml');

// =====================================================================
// =====================================================================
// ======= 1/ TAP-compatible test runner ================================
// =====================================================================
// =====================================================================

let _pass = 0;
let _fail = 0;
const _results = [];

/**
 * Records a test result.
 * @param {string} name
 * @param {boolean} ok
 * @param {string} [detail]
 */
function test(name, ok, detail) {
	_pass += ok ? 1 : 0;
	_fail += ok ? 0 : 1;
	_results.push({ name, ok, detail });
}

/**
 * Prints the TAP report and exits with the appropriate exit code.
 */
function report() {
	const total = _pass + _fail;
	console.log('TAP version 14');
	console.log(`1..${total}`);
	let i = 1;
	for (const r of _results) {
		const prefix = r.ok ? 'ok' : 'not ok';
		console.log(`${prefix} ${i++} - ${r.name}`);
		if (!r.ok && r.detail) {
			console.log(`  # ${r.detail}`);
		}
	}
	console.log(`# passed: ${_pass}/${total}`);
	if (_fail > 0) {
		console.log(`# FAILED: ${_fail} test(s)`);
		process.exit(1);
	}
}

// =====================================================================
// =====================================================================
// ======= 2/ Manifest parsers (regex, codegen-format) =================
// =====================================================================
// =====================================================================

/**
 * Parses cross-platform feature entries from features_manifest.ahk.
 * Returns Map<path, { id, section, type, defaultVal, platforms }>.
 * @param {string} src - Raw file content.
 * @returns {Map<string, object>}
 */
function parseAhkCrossFeatures(src) {
	const result = new Map();
	const lines = src.split(/\r?\n/);
	for (const line of lines) {
		if (!line.includes('"path"')) continue;
		const mPath = line.match(/"path",\s*"([^"]+)"/);
		const mId = line.match(/"id",\s*"([^"]+)"/);
		const mSect = line.match(/"section",\s*"([^"]+)"/);
		const mType = line.match(/"type",\s*"([^"]+)"/);
		const mPlat = line.match(/"platforms",\s*\[([^\]]*)\]/);
		if (!mPath || !mId || !mSect || !mType || !mPlat) continue;

		const platforms = (mPlat[1].match(/"([^"]+)"/g) || []).map((s) => s.replace(/"/g, ''));
		if (!platforms.includes('ahk') || !platforms.includes('hs')) continue;

		// Extract the default value raw string (everything between "default", and the next key).
		// The default may be: a quoted string, a boolean, a number, or a nested Map(...).
		const defaultRaw = extractAhkDefault(line);

		result.set(mPath[1], {
			id: mId[1],
			section: mSect[1],
			type: mType[1],
			defaultRaw,
			platforms
		});
	}
	return result;
}

/**
 * Parses cross-platform feature entries from features_manifest.lua.
 * Returns Map<path, { id, section, type, defaultVal, platforms }>.
 * @param {string} src - Raw file content.
 * @returns {Map<string, object>}
 */
function parseLuaCrossFeatures(src) {
	const result = new Map();
	const featStart = src.indexOf('M.features');
	if (featStart === -1) return result;
	const featSrc = src.slice(featStart);
	const lines = featSrc.split(/\r?\n/);

	let i = 0;
	while (i < lines.length) {
		if (!lines[i].includes('path = "')) {
			i++;
			continue;
		}

		// Collect the block until we close the feature entry brace.
		const blockLines = [lines[i]];
		let j = i + 1;
		let depth = 1;
		for (const ch of lines[i]) {
			if (ch === '{') depth++;
			else if (ch === '}') depth--;
		}
		while (j < lines.length && depth > 0) {
			for (const ch of lines[j]) {
				if (ch === '{') depth++;
				else if (ch === '}') depth--;
			}
			blockLines.push(lines[j]);
			j++;
		}
		i = j + 1;

		const block = blockLines.join('\n');
		const mPath = block.match(/path\s*=\s*"([^"]+)"/);
		const mId = block.match(/\bid\s*=\s*"([^"]+)"/);
		const mSect = block.match(/section\s*=\s*"([^"]+)"/);
		const mType = block.match(/type\s*=\s*"([^"]+)"/);
		const mPlat = block.match(/platforms\s*=\s*\{([^}]*)\}/);
		if (!mPath || !mId || !mSect || !mType || !mPlat) continue;

		const platforms = (mPlat[1].match(/"([^"]+)"/g) || []).map((s) => s.replace(/"/g, ''));
		if (!platforms.includes('ahk') || !platforms.includes('hs')) continue;

		const defaultRaw = extractLuaDefault(block);

		result.set(mPath[1], {
			id: mId[1],
			section: mSect[1],
			type: mType[1],
			defaultRaw,
			platforms
		});
	}
	return result;
}

/**
 * Extracts the raw default value string from an AHK feature Map line.
 * Supports primitives (bool, number, quoted string) and nested Map(...) objects.
 * @param {string} line - A single line from features_manifest.ahk containing a feature entry.
 * @returns {string}
 */
function extractAhkDefault(line) {
	// Find the position of `"default", ` and extract everything until the next `"type",`
	const startMarker = '"default", ';
	const endMarker = ', "type",';
	const start = line.indexOf(startMarker);
	if (start === -1) return '';
	const valueStart = start + startMarker.length;
	const end = line.indexOf(endMarker, valueStart);
	if (end === -1) return line.slice(valueStart).trim();
	return line.slice(valueStart, end).trim();
}

/**
 * Extracts the raw default value string from a Lua feature block.
 * Handles both single-line (e.g. `default = "fr"`) and multi-line
 * (e.g. `default = {\n  enabled = true,\n  ...\n}`) forms.
 * @param {string} block - Multi-line text of one feature entry.
 * @returns {string}
 */
function extractLuaDefault(block) {
	const startMarker = 'default =';
	const start = block.indexOf(startMarker);
	if (start === -1) return '';
	const valueStart = start + startMarker.length;
	let rest = block.slice(valueStart).trimStart();

	// If value starts with `{`, extract the whole balanced brace block.
	if (rest[0] === '{') {
		let depth = 0;
		let j = 0;
		while (j < rest.length) {
			if (rest[j] === '{') depth++;
			else if (rest[j] === '}') {
				depth--;
				if (depth === 0) {
					j++;
					break;
				}
			}
			j++;
		}
		return rest.slice(0, j).trim();
	}

	// Primitive: take until comma or newline.
	const end = rest.search(/[,\n]/);
	return end === -1 ? rest.trim() : rest.slice(0, end).trim();
}

/**
 * Parses an AHK Map(...) literal into a plain JS object.
 * Handles flat Maps with string keys and primitive/nested-Map values.
 * @param {string} raw - e.g. `Map("enabled", true, "time_activation_seconds", 0.5)`
 * @returns {object|null}
 */
function parseAhkMapLiteral(raw) {
	const trimmed = raw.trim();
	if (!trimmed.startsWith('Map(')) return null;
	// Extract contents between outermost Map( ... )
	const inner = trimmed.slice(4, -1).trim();
	const result = {};
	// Walk the pairs: "key", value, "key", value, ...
	let i = 0;
	while (i < inner.length) {
		// Skip whitespace and commas
		while (i < inner.length && /[\s,]/.test(inner[i])) i++;
		if (i >= inner.length) break;
		// Read key (must be a quoted string)
		if (inner[i] !== '"') break;
		const keyEnd = inner.indexOf('"', i + 1);
		if (keyEnd === -1) break;
		const key = inner.slice(i + 1, keyEnd);
		i = keyEnd + 1;
		// Skip comma + whitespace
		while (i < inner.length && /[\s,]/.test(inner[i])) i++;
		// Read value
		const { value, nextIndex } = readAhkValue(inner, i);
		result[key] = value;
		i = nextIndex;
	}
	return result;
}

/**
 * Reads one AHK value token from src starting at pos.
 * Returns { value, nextIndex }.
 * @param {string} src
 * @param {number} pos
 * @returns {{ value: *, nextIndex: number }}
 */
function readAhkValue(src, pos) {
	// Quoted string
	if (src[pos] === '"') {
		const end = src.indexOf('"', pos + 1);
		return { value: src.slice(pos + 1, end), nextIndex: end + 1 };
	}
	// Nested Map(...)
	if (src.slice(pos, pos + 4) === 'Map(') {
		let depth = 0;
		let j = pos;
		while (j < src.length) {
			if (src[j] === '(') depth++;
			else if (src[j] === ')') {
				depth--;
				if (depth === 0) {
					j++;
					break;
				}
			}
			j++;
		}
		const raw = src.slice(pos, j);
		return { value: parseAhkMapLiteral(raw), nextIndex: j };
	}
	// Array [...]
	if (src[pos] === '[') {
		const end = src.indexOf(']', pos);
		const inner = src.slice(pos + 1, end).trim();
		const items = inner
			? inner.split(',').map((s) => {
					const t = s.trim();
					if (t === 'true') return true;
					if (t === 'false') return false;
					if (t.startsWith('"')) return t.slice(1, -1);
					const n = Number(t);
					return isNaN(n) ? t : n;
				})
			: [];
		return { value: items, nextIndex: end + 1 };
	}
	// Boolean / number — read until comma or end
	let j = pos;
	while (j < src.length && src[j] !== ',' && src[j] !== ')') j++;
	const token = src.slice(pos, j).trim();
	if (token === 'true') return { value: true, nextIndex: j };
	if (token === 'false') return { value: false, nextIndex: j };
	const n = Number(token);
	return { value: isNaN(n) ? token : n, nextIndex: j };
}

/**
 * Parses a Lua table/array literal into a plain JS object or array.
 * Handles flat key=value tables, indexed arrays like { "alt" }, and empty {}.
 * @param {string} raw - e.g. `{ enabled = true, time_activation_seconds = 0.5 }`
 * @returns {object|Array|null}
 */
function parseLuaTableLiteral(raw) {
	const trimmed = raw.trim();
	if (!trimmed.startsWith('{')) return null;
	const inner = trimmed.slice(1, trimmed.lastIndexOf('}')).trim();
	if (!inner) return {};

	// Detect whether this is a Lua array (all items are values, no `=` at top level)
	// vs a key=value table. Split on commas first.
	const items = splitLuaTopLevel(inner, ',');

	const isArray = items.every((item) => !item.includes('=') || item.trim().startsWith('"'));
	if (isArray) {
		return items.map((s) => {
			const t = s.trim();
			if (t === 'true') return true;
			if (t === 'false') return false;
			if (t.startsWith('"')) return t.slice(1, t.lastIndexOf('"'));
			const n = Number(t);
			return isNaN(n) ? t : n;
		});
	}

	const result = {};
	for (const pair of items) {
		const eq = pair.indexOf('=');
		if (eq === -1) continue;
		const key = pair.slice(0, eq).trim();
		const valRaw = pair.slice(eq + 1).trim();
		if (valRaw === 'true') result[key] = true;
		else if (valRaw === 'false') result[key] = false;
		else if (valRaw.startsWith('"')) result[key] = valRaw.slice(1, valRaw.lastIndexOf('"'));
		else {
			const n = Number(valRaw);
			result[key] = isNaN(n) ? valRaw : n;
		}
	}
	return result;
}

/**
 * Splits a string on a delimiter, respecting nested braces and quotes.
 * @param {string} src
 * @param {string} delim
 * @returns {string[]}
 */
function splitLuaTopLevel(src, delim) {
	const parts = [];
	let depth = 0;
	let inStr = false;
	let cur = '';
	for (let i = 0; i < src.length; i++) {
		const ch = src[i];
		if (ch === '"' && (i === 0 || src[i - 1] !== '\\')) inStr = !inStr;
		if (!inStr && (ch === '{' || ch === '(')) depth++;
		if (!inStr && (ch === '}' || ch === ')')) depth--;
		if (!inStr && depth === 0 && src.slice(i, i + delim.length) === delim) {
			parts.push(cur);
			cur = '';
			i += delim.length - 1;
		} else {
			cur += ch;
		}
	}
	if (cur.trim()) parts.push(cur);
	return parts;
}

/**
 * Parses a raw default value from either AHK or Lua syntax into a canonical JS value.
 * Primitives are returned directly; Map/table literals are returned as plain objects.
 * @param {string} raw - Raw extracted default string.
 * @param {"ahk"|"lua"} lang - Source language.
 * @returns {*}
 */
function parseDefaultValue(raw, lang) {
	if (!raw) return undefined;
	const t = raw.trim();
	// Primitives
	if (t === 'true') return true;
	if (t === 'false') return false;
	if (t.startsWith('"') && t.endsWith('"')) return t.slice(1, -1);
	const n = Number(t);
	if (!isNaN(n) && t !== '') return n;
	// Structured types
	if (lang === 'ahk' && t.startsWith('Map(')) return parseAhkMapLiteral(t);
	if (lang === 'ahk' && t.startsWith('[')) {
		// AHK array literal: ["a", "b"] or [true, false]
		const inner = t.slice(1, t.lastIndexOf(']')).trim();
		if (!inner) return [];
		return inner.split(',').map((s) => {
			const tok = s.trim();
			if (tok === 'true') return true;
			if (tok === 'false') return false;
			if (tok.startsWith('"')) return tok.slice(1, -1);
			const num = Number(tok);
			return isNaN(num) ? tok : num;
		});
	}
	if (lang === 'lua' && t.startsWith('{')) return parseLuaTableLiteral(t);
	return t;
}

/**
 * Serialises a parsed default value to a canonical stable string for comparison.
 * Objects are serialised with sorted keys so order differences are irrelevant.
 * @param {*} val
 * @returns {string}
 */
function serialiseDefault(val) {
	if (val === null || val === undefined) return String(val);
	if (typeof val === 'object' && !Array.isArray(val)) {
		const keys = Object.keys(val).sort();
		return '{' + keys.map((k) => `${k}:${serialiseDefault(val[k])}`).join(',') + '}';
	}
	if (Array.isArray(val)) return '[' + val.map(serialiseDefault).join(',') + ']';
	return String(val);
}

// =====================================================================
// =====================================================================
// ======= 3/ Minimal TOML parser for fixture config ===================
// =====================================================================
// =====================================================================

/**
 * Parses the fixture TOML into a nested plain-object tree.
 * Handles standard section headers [a.b.c], key = value, and inline arrays.
 * This is intentionally minimal — only the subset of TOML used by config.toml.
 * @param {string} src - Raw TOML content.
 * @returns {object}
 */
function parseTomlFixture(src) {
	const root = {};
	let cursor = root;
	let currentPath = [];

	const lines = src.split(/\r?\n/);
	for (let raw of lines) {
		const line = raw.split('#')[0].trim();
		if (!line) continue;

		// Section header [a.b.c]
		if (line.startsWith('[') && line.endsWith(']')) {
			const sectionKey = line.slice(1, -1).trim();
			currentPath = sectionKey.split('.');
			cursor = root;
			for (const part of currentPath) {
				if (typeof cursor[part] !== 'object' || cursor[part] === null) {
					cursor[part] = {};
				}
				cursor = cursor[part];
			}
			continue;
		}

		// Key = value
		const eqIdx = line.indexOf('=');
		if (eqIdx === -1) continue;
		const key = line.slice(0, eqIdx).trim();
		const valRaw = line.slice(eqIdx + 1).trim();
		cursor[key] = coerceTomlValue(valRaw);
	}
	return root;
}

/**
 * Coerces a raw TOML value string to a JavaScript primitive.
 * @param {string} raw
 * @returns {boolean|number|string|Array}
 */
function coerceTomlValue(raw) {
	if (raw === 'true') return true;
	if (raw === 'false') return false;
	if (raw.startsWith('"') && raw.endsWith('"')) return raw.slice(1, -1);

	// Inline array ["a", "b"]
	if (raw.startsWith('[') && raw.endsWith(']')) {
		const inner = raw.slice(1, -1).trim();
		if (!inner) return [];
		return inner.split(',').map((s) => coerceTomlValue(s.trim()));
	}

	const num = Number(raw);
	if (!isNaN(num) && raw !== '') return num;
	return raw;
}

/**
 * Resolves a dotted feature path against the parsed TOML tree.
 * Returns the value at that path, or undefined when absent.
 * @param {object} toml - Parsed TOML tree.
 * @param {string} featurePath - Dotted path, e.g. "hotstrings.autocorrection.accents".
 * @returns {*}
 */
function tomlLookup(toml, featurePath) {
	const parts = featurePath.split('.');
	let node = toml;
	for (const part of parts) {
		if (node === null || typeof node !== 'object') return undefined;
		if (!(part in node)) return undefined;
		node = node[part];
	}
	return node;
}

/**
 * Serialises a value to a stable string for comparison.
 * Handles primitives, objects, and arrays recursively.
 * @param {*} val
 * @returns {string}
 */
function serialise(val) {
	if (val === undefined) return '__ABSENT__';
	if (typeof val === 'object' && val !== null) {
		const keys = Object.keys(val).sort();
		const pairs = keys.map((k) => `${k}:${serialise(val[k])}`);
		return `{${pairs.join(',')}}`;
	}
	return String(val);
}

// =====================================================================
// =====================================================================
// ======= 4/ File availability checks =================================
// =====================================================================
// =====================================================================

const ahkExists = fs.existsSync(AHK_MANIFEST);
const luaExists = fs.existsSync(HS_MANIFEST);
const fixtureExists = fs.existsSync(FIXTURE_CONFIG);

test(
	'AHK manifest file exists',
	ahkExists,
	`Expected ${AHK_MANIFEST} — run npm run build:manifest`
);
test('HS manifest file exists', luaExists, `Expected ${HS_MANIFEST} — run npm run build:manifest`);
test('Fixture config file exists', fixtureExists, `Expected ${FIXTURE_CONFIG}`);

if (!ahkExists || !luaExists || !fixtureExists) {
	report();
	process.exit(1);
}

const ahkSrc = fs.readFileSync(AHK_MANIFEST, 'utf8');
const luaSrc = fs.readFileSync(HS_MANIFEST, 'utf8');
const fixtureSrc = fs.readFileSync(FIXTURE_CONFIG, 'utf8');
const manifestSrc = fs.readFileSync(
	shared('modules/features/manifest.toml'),
	'utf8'
);

// Build the set of feature paths that use default_per_platform — their defaults
// are intentionally different between drivers and must not be compared.
const PER_PLATFORM_PATHS = buildPerPlatformPaths(manifestSrc);

/**
 * Scans the shared manifest TOML source for entries that use
 * default_per_platform and returns their full dotted paths.
 * This avoids a runtime dependency on smol-toml in a .cjs script.
 * @param {string} src - Raw manifest.toml content.
 * @returns {Set<string>}
 */
function buildPerPlatformPaths(src) {
	const found = new Set();
	const lines = src.split(/\r?\n/);
	// Walk through [[features.<path>]] blocks and collect ids that follow
	// a default_per_platform key.
	let currentSection = null;
	let currentId = null;
	let hasPerPlatform = false;
	for (const raw of lines) {
		const line = raw.trim();
		// [[features.<path>]] header resets the current entry
		const headerMatch = line.match(/^\[\[features\.([\w.]+)\]\]/);
		if (headerMatch) {
			if (hasPerPlatform && currentSection && currentId) {
				found.add(`${currentSection}.${currentId}`);
			}
			currentSection = headerMatch[1];
			currentId = null;
			hasPerPlatform = false;
			continue;
		}
		if (line.startsWith('id =')) {
			const m = line.match(/id\s*=\s*"([^"]+)"/);
			if (m) currentId = m[1];
		}
		if (line.startsWith('default_per_platform')) {
			hasPerPlatform = true;
		}
	}
	// Flush last entry
	if (hasPerPlatform && currentSection && currentId) {
		found.add(`${currentSection}.${currentId}`);
	}
	return found;
}

// =====================================================================
// =====================================================================
// ======= 5/ Parse manifests and fixture ==============================
// =====================================================================
// =====================================================================

const ahkFeatures = parseAhkCrossFeatures(ahkSrc);
const luaFeatures = parseLuaCrossFeatures(luaSrc);
// Absent on a checkout that has not generated the Linux manifest; the
// divergence check then behaves exactly as it did before this file knew about
// a third driver, rather than failing for a missing file it does not otherwise
// need.
const linuxFeatures = fs.existsSync(LINUX_MANIFEST)
	? parseLuaCrossFeatures(fs.readFileSync(LINUX_MANIFEST, 'utf8'))
	: new Map();
const fixtureToml = parseTomlFixture(fixtureSrc);

test(
	'AHK manifest cross-platform features parseable',
	ahkFeatures.size > 0,
	`Extracted 0 cross-platform features from AHK manifest`
);

test(
	'HS manifest cross-platform features parseable',
	luaFeatures.size > 0,
	`Extracted 0 cross-platform features from HS manifest`
);

test(
	'Fixture config parseable',
	Object.keys(fixtureToml).length > 0,
	`Failed to parse ${FIXTURE_CONFIG}`
);

// =====================================================================
// =====================================================================
// ======= 6/ Cross-platform feature set equivalence ===================
// =====================================================================
// =====================================================================

// Every cross-platform path present in AHK must also be present in HS.
for (const [featurePath] of ahkFeatures) {
	test(
		`Cross-platform feature "${featurePath}" declared in both manifests`,
		luaFeatures.has(featurePath),
		`Path "${featurePath}" is cross-platform in AHK manifest but missing in HS manifest`
	);
}

// Every cross-platform path in HS must also be in AHK.
for (const [featurePath] of luaFeatures) {
	test(
		`Cross-platform feature "${featurePath}" declared in both manifests (HS→AHK)`,
		ahkFeatures.has(featurePath),
		`Path "${featurePath}" is cross-platform in HS manifest but missing in AHK manifest`
	);
}

// =====================================================================
// =====================================================================
// ======= 7/ Default value parity =====================================
// =====================================================================
// =====================================================================

// For each cross-platform feature, the manifest default must be identical
// in both generated files — divergence here means build-script drift.
// Both raw strings are parsed into canonical JS values before comparison so
// that syntax differences (Map(...) vs { ... }) do not cause false failures.
// Features with default_per_platform are intentionally different between
// drivers — they are documented as expected divergences rather than failures.
for (const [featurePath, ahkInfo] of ahkFeatures) {
	const luaInfo = luaFeatures.get(featurePath);
	if (!luaInfo) continue; // Already reported above.

	if (PER_PLATFORM_PATHS.has(featurePath)) {
		// Intentional per-platform divergence — verify it is actually different
		// so stale entries in PER_PLATFORM_PATHS are caught too.
		//
		// Across all THREE drivers, not two. The rule being enforced is "a
		// per-platform default must actually differ somewhere", and a feature
		// whose only exception is Linux satisfies it while looking identical from
		// Windows and macOS. Comparing two of three read that as stale and failed
		// a correct declaration.
		const ahkDefault = serialiseDefault(parseDefaultValue(ahkInfo.defaultRaw, 'ahk'));
		const luaDefault = serialiseDefault(parseDefaultValue(luaInfo.defaultRaw, 'lua'));
		const linuxInfo = linuxFeatures.get(featurePath);
		const linuxDefault = linuxInfo
			? serialiseDefault(parseDefaultValue(linuxInfo.defaultRaw, 'lua'))
			: null;
		const differs =
			ahkDefault !== luaDefault ||
			(linuxDefault !== null && (linuxDefault !== ahkDefault || linuxDefault !== luaDefault));
		test(
			`Default for "${featurePath}" correctly diverges per platform (default_per_platform)`,
			differs,
			`Expected at least two drivers to differ for a default_per_platform feature — ` +
				`AHK "${ahkDefault}", HS "${luaDefault}", Linux "${linuxDefault ?? '(not declared)'}"`
		);
		continue;
	}

	const ahkDefault = serialiseDefault(parseDefaultValue(ahkInfo.defaultRaw, 'ahk'));
	const luaDefault = serialiseDefault(parseDefaultValue(luaInfo.defaultRaw, 'lua'));

	test(
		`Default for "${featurePath}" matches between AHK and HS manifests`,
		ahkDefault === luaDefault,
		`AHK default="${ahkDefault}" | HS default="${luaDefault}"`
	);
}

// =====================================================================
// =====================================================================
// ======= 8/ TOML config resolution equivalence =======================
// =====================================================================
// =====================================================================

// For each cross-platform feature path, verify that looking it up in the
// fixture TOML produces the same value from both drivers' perspectives.
//
// Both drivers read cross-platform features from the same dotted TOML path
// (no prefix is applied for cross-platform features). The value found in the
// TOML tree — or the manifest default when the path is absent — must be
// identical for both drivers.
//
// Resolution rule (mirrors both drivers' boot logic):
//   resolved = toml[path] ?? manifestDefault
//
// A default_per_platform feature is exempt ONLY on the fallback branch. Once
// the user's config supplies a value, that value is what both drivers resolve
// to and they must still agree — the per-platform declaration governs the
// default, not the lookup. Until the driver silos were dissolved this loop
// never saw a gesture at all: "ahk.gestures.tap_4" and "hs.gestures.tap_4"
// were different paths, so the lua lookup missed and every gesture skipped the
// check. The paths agreeing is what made the divergence visible.

for (const [featurePath, ahkInfo] of ahkFeatures) {
	const luaInfo = luaFeatures.get(featurePath);
	if (!luaInfo) continue;

	const tomlValue = tomlLookup(fixtureToml, featurePath);
	if (tomlValue === undefined && PER_PLATFORM_PATHS.has(featurePath)) continue;

	const ahkResolved =
		tomlValue !== undefined ? tomlValue : parseDefaultValue(ahkInfo.defaultRaw, 'ahk');
	const luaResolved =
		tomlValue !== undefined ? tomlValue : parseDefaultValue(luaInfo.defaultRaw, 'lua');

	const ahkStr = serialise(ahkResolved);
	const luaStr = serialise(luaResolved);

	test(
		`Resolved value for "${featurePath}" is identical across drivers`,
		ahkStr === luaStr,
		`AHK="${ahkStr}" | HS="${luaStr}"`
	);
}

report();
