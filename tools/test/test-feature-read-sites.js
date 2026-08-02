// tools/test/test-feature-read-sites.js

/**
 * ==============================================================================
 * MODULE: Feature Read-Site Manifest Guard
 * DESCRIPTION:
 * Static check that every literal feature-flag read site in the AHK driver
 * resolves against the Features map that the driver builds at runtime from the
 * single source of truth (_shared/modules/features/manifest.toml). It exists to kill the
 * class of bug behind the layout.ahk UnsetItemError crash: a feature read at a
 * path the manifest does not back (e.g. a section-prefix mismatch, or a feature
 * removed from the manifest but still read), which AHK surfaces only at runtime
 * as a bare "Item has no value." with no actionable context.
 *
 * FEATURES & RATIONALE:
 * 1. Faithful map: rebuilds the exact shape of ManifestBuildFeaturesMap()
 *    (ahk. prefix stripped, table-shaped defaults stored nested, section_order
 *    meta key) so a read that works at runtime also passes here, and a read
 *    that would crash fails CI with file:line and the offending key.
 * 2. Literal-prefix only: a read with a dynamic key (variable / function call)
 *    is validated up to its last string-literal segment — the part we can prove.
 * 3. Conservative: only fails when a key is missing from an existing section
 *    object; never on table-vs-primitive ambiguity, so no false positives.
 * ==============================================================================
 */

import { parse as parseToml } from 'smol-toml';
import { readFileSync, readdirSync, statSync } from 'fs';
import { dirname, resolve, join, relative } from 'path';
import { fileURLToPath } from 'url';
import sharedPaths from '../lib/paths.cjs';

const { shared } = sharedPaths;
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..', '..');
const MANIFEST_PATH = shared('modules/features/manifest.toml');
const AHK_ROOT = resolve(REPO_ROOT, 'static/ergopti_plus/windows');

// Directories whose .ahk files are NOT hand-written driver code reading the
// live map: tests build their own fixtures, _generated is codegen output, and
// vendor is third-party.
const SKIP_DIRS = new Set(['tests', '_generated', 'vendor']);

// Top-level keys the runtime map carries that are NOT feature sections.
const META_KEYS = new Set(['section_order']);

// Must stay in step with build-features-manifest.js's KNOWN_PLATFORMS: a
// platform missing here is a driver whose feature reads go unchecked, which
// looks exactly like a driver with no unread features.
const PLATFORMS = ['ahk', 'hs', 'linux'];




// =================================================
// =================================================
// ======= 1/ Manifest loading (mirrors build-features-manifest.js) =======
// =================================================
// =================================================

function preprocessManifestSource(raw) {
	return raw.replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_m, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	);
}

function loadFeatures() {
	const raw = readFileSync(MANIFEST_PATH, 'utf8');
	const parsed = parseToml(preprocessManifestSource(raw));
	const sections = flattenSections(parsed.sections || {});
	const features = (parsed.entries || []).map((entry) => {
		const { path_prefix, ...rest } = entry;
		return { ...rest, section: path_prefix, path: `${path_prefix}.${entry.id}` };
	});
	resolvePlatforms(features, sections);
	return features;
}

function flattenSections(node, pathParts = []) {
	const result = [];
	if (!node || typeof node !== 'object') return result;
	const isMeta =
		Object.prototype.hasOwnProperty.call(node, 'description_key') ||
		Object.prototype.hasOwnProperty.call(node, 'platforms') ||
		Object.prototype.hasOwnProperty.call(node, 'subsections');
	if (isMeta && pathParts.length > 0) {
		result.push({ path: pathParts.join('.'), platforms: node.platforms || PLATFORMS });
	}
	for (const [key, val] of Object.entries(node)) {
		if (['order', 'description_key', 'platforms', 'subsections'].includes(key)) continue;
		result.push(...flattenSections(val, [...pathParts, key]));
	}
	return result;
}

function resolvePlatforms(features, sections) {
	const byPath = new Map(sections.map((s) => [s.path, s]));
	for (const f of features) {
		if (f.platforms && f.platforms.length > 0) continue;
		const parts = f.section.split('.');
		while (parts.length > 0) {
			const ancestor = byPath.get(parts.join('.'));
			if (ancestor && ancestor.platforms && ancestor.platforms.length > 0) {
				f.platforms = [...ancestor.platforms];
				break;
			}
			parts.pop();
		}
		if (!f.platforms || f.platforms.length === 0) f.platforms = [...PLATFORMS];
	}
}

function resolveDefault(feature, platform) {
	if (feature.default_per_platform && feature.default_per_platform[platform] !== undefined) {
		return feature.default_per_platform[platform];
	}
	return feature.default;
}

// Rebuild the runtime Features map shape for the AHK platform.
function buildAhkFeaturesMap(features) {
	const map = {};
	for (const k of META_KEYS) map[k] = {}; // presence-only marker
	for (const f of features) {
		if (!f.platforms.includes('ahk')) continue;
		let section = f.section;
		if (section.startsWith('ahk.')) section = section.slice(4);
		let cursor = map;
		for (const part of section.split('.').filter(Boolean)) {
			if (typeof cursor[part] !== 'object' || cursor[part] === null) cursor[part] = {};
			cursor = cursor[part];
		}
		cursor[f.id] = resolveDefault(f, 'ahk');
	}
	return map;
}




// =================================================
// =================================================
// ======= 2/ AHK source scanning =======
// =================================================
// =================================================

function listAhkFiles(dir) {
	const out = [];
	for (const name of readdirSync(dir)) {
		const full = join(dir, name);
		const st = statSync(full);
		if (st.isDirectory()) {
			if (SKIP_DIRS.has(name)) continue;
			out.push(...listAhkFiles(full));
		} else if (name.endsWith('.ahk')) {
			out.push(full);
		}
	}
	return out;
}

// Matches a run of one or more ["literal"] index segments right after Features.
const CHAIN_RE = /\bFeatures((?:\[\s*"[^"]+"\s*\])+)/g;
const KEY_RE = /\[\s*"([^"]+)"\s*\]/g;

// Strip the trailing line comment from one AHK source line, string-aware. An
// AHK ";" starts a comment only at line start or when preceded by whitespace,
// and not inside a double-quoted string ("`"" is an escaped quote).
function stripLineComment(line) {
	let inString = false;
	for (let i = 0; i < line.length; i++) {
		const ch = line[i];
		if (ch === '"') {
			// Backtick is the AHK escape char; `" is a literal quote, not a delimiter.
			if (line[i - 1] !== '`') inString = !inString;
			continue;
		}
		if (!inString && ch === ';' && (i === 0 || /\s/.test(line[i - 1]))) {
			return line.slice(0, i);
		}
	}
	return line;
}

function extractReads(text) {
	const reads = [];
	const lines = text.split(/\r?\n/);
	let inBlockComment = false;
	lines.forEach((raw, idx) => {
		let line = raw;
		// AHK block comments: a line whose first non-space char is /* opens it,
		// */ closes it. Handled line-granular (AHK requires them at line start).
		const trimmed = line.trimStart();
		if (inBlockComment) {
			if (trimmed.includes('*/')) inBlockComment = false;
			return;
		}
		if (trimmed.startsWith('/*')) {
			if (!trimmed.includes('*/')) inBlockComment = true;
			return;
		}
		line = stripLineComment(line);
		let m;
		CHAIN_RE.lastIndex = 0;
		while ((m = CHAIN_RE.exec(line)) !== null) {
			const keys = [];
			let k;
			KEY_RE.lastIndex = 0;
			while ((k = KEY_RE.exec(m[1])) !== null) keys.push(k[1]);
			reads.push({ line: idx + 1, keys });
		}
	});
	return reads;
}

// Walk the literal prefix against the map. Returns null if OK, or the offending
// key when an existing section object lacks it.
function validate(keys, map) {
	let cursor = map;
	for (const key of keys) {
		if (typeof cursor !== 'object' || cursor === null) return null; // can't go deeper — conservative pass
		if (!Object.prototype.hasOwnProperty.call(cursor, key)) {
			return key;
		}
		cursor = cursor[key];
	}
	return null;
}




// =================================================
// =================================================
// ======= 3/ Runner =======
// =================================================
// =================================================

const features = loadFeatures();
const map = buildAhkFeaturesMap(features);

// Always-on regression for the layout.ahk ctrl_magic_save UnsetItemError class:
// the buggy section-prefixed form must be rejected and the correct stripped form
// accepted. Encodes the exact crash so it can never silently return.
const SELF_TESTS = [
	{ keys: ['ahk.layout', 'ctrl_magic_save'], expectMissing: true, why: 'section-prefixed crash form' },
	{ keys: ['layout', 'ctrl_magic_save'], expectMissing: false, why: 'correct stripped form' },
	{ keys: ['layout', '__definitely_not_a_feature__'], expectMissing: true, why: 'unknown key' }
];
for (const t of SELF_TESTS) {
	const missing = validate(t.keys, map) !== null;
	if (missing !== t.expectMissing) {
		console.error(
			`Feature read-site guard SELF-TEST FAILED (${t.why}): ` +
				`validate(${JSON.stringify(t.keys)}) expected missing=${t.expectMissing}, got ${missing}.`
		);
		process.exit(2);
	}
}

const files = listAhkFiles(AHK_ROOT);
let checked = 0;
const failures = [];

for (const file of files) {
	const text = readFileSync(file, 'utf8');
	for (const read of extractReads(text)) {
		checked++;
		const missing = validate(read.keys, map);
		if (missing) {
			failures.push({
				file: relative(REPO_ROOT, file).replace(/\\/g, '/'),
				line: read.line,
				path: read.keys.join('.'),
				missing
			});
		}
	}
}

console.log('\nFeature read-site manifest guard');
console.log('='.repeat(50));
console.log(`Scanned ${files.length} AHK file(s), ${checked} literal Features[...] read site(s).`);

if (failures.length === 0) {
	console.log(`\n  ✓  All read sites resolve against the manifest-built Features map.`);
	console.log('');
	process.exit(0);
}

console.log(`\n  ✗  ${failures.length} read site(s) with no backing manifest entry:\n`);
for (const f of failures) {
	console.log(`     ${f.file}:${f.line}`);
	console.log(`        Features["${f.path.split('.').join('"]["')}"]  — key "${f.missing}" not in manifest`);
}
console.log(`\n  Fix: add the feature to _shared/modules/features/manifest.toml and run "npm run codegen",`);
console.log(`       or correct the read path. (This is the layout.ahk ctrl_magic_save crash class.)`);
console.log('');
process.exit(1);
