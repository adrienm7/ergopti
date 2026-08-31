// scripts/test-manifest-parity.cjs

/**
 * ==============================================================================
 * MODULE: Manifest Parity Meta-Test
 * DESCRIPTION:
 * Cross-driver equivalence test that validates the Windows, macOS, and Linux
 * generated manifest files (all produced from the same TOML source)
 * expose identical structural data — version, section_order, section keys and their
 * description_key + platforms fields, and feature paths with their id and type.
 *
 * FEATURES & RATIONALE:
 * 1. Codegen drift detection: both generated files are git-tracked (NOT
 *    gitignored — CI always regenerates-then-tests, but a stale hand-edit is
 *    still invisible to a local build that never re-runs the generator); if
 *    the build script is updated to emit different data for one target, this
 *    test fails immediately, preventing silent per-driver divergence.
 * 2. Regex-based parsing: both files are tightly formatted machine-generated
 *    output, so lightweight regex extraction is reliable and avoids the need
 *    for a Lua or AHK interpreter in CI.
 * 3. Platform-aware comparison: AHK-only sections (platforms = ["ahk"]) and
 *    HS-only sections (platforms = ["hs"]) are expected to differ — only
 *    cross-platform entries (platforms includes both "ahk" and "hs") are
 *    validated for structural parity.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');

const AHK_MANIFEST = path.join(
	REPO_ROOT,
	'static/ergopti_plus/windows/_generated/features_manifest.ahk'
);
const HS_MANIFEST = path.join(
	REPO_ROOT,
	'static/ergopti_plus/macos/_generated/features_manifest.lua'
);
const LINUX_MANIFEST = path.join(
	REPO_ROOT,
	'static/ergopti_plus/linux/_generated/features_manifest.lua'
);

// ==============================================================
// ==============================================================
// ======= 1/ Manifest parsers (regex, codegen-format) ==========
// ==============================================================
// ==============================================================

/**
 * Extracts the version string from features_manifest.ahk.
 * @param {string} src - Raw file content.
 * @returns {string}
 */
function parseAhkVersion(src) {
	const m = src.match(/"version",\s*"([^"]+)"/);
	return m ? m[1] : '';
}

/**
 * Extracts the version string from features_manifest.lua.
 * @param {string} src - Raw file content.
 * @returns {string}
 */
function parseLuaVersion(src) {
	const m = src.match(/M\.version\s*=\s*"([^"]+)"/);
	return m ? m[1] : '';
}

/**
 * Extracts the section_order array from features_manifest.ahk.
 * @param {string} src - Raw file content.
 * @returns {string[]}
 */
function parseAhkSectionOrder(src) {
	const m = src.match(/"section_order",\s*\[([^\]]+)\]/);
	if (!m) return [];
	return m[1].match(/"([^"]+)"/g).map((s) => s.replace(/"/g, ''));
}

/**
 * Extracts the section_order array from features_manifest.lua.
 * @param {string} src - Raw file content.
 * @returns {string[]}
 */
function parseLuaSectionOrder(src) {
	const m = src.match(/M\.section_order\s*=\s*\{([^}]+)\}/);
	if (!m) return [];
	return m[1].match(/"([^"]+)"/g).map((s) => s.replace(/"/g, ''));
}

/**
 * Extracts all section entries from features_manifest.ahk.
 * Returns Map<sectionPath, { description_key, platforms, subsections }>.
 * @param {string} src - Raw file content.
 * @returns {Map<string, object>}
 */
function parseAhkSections(src) {
	const result = new Map();
	// Each section is: "key", Map("description_key", "...", "platforms", [...], "subsections", [...])
	const re =
		/"([\w.]+)",\s*Map\("description_key",\s*"([^"]+)",\s*"platforms",\s*\[([^\]]*)\],\s*"subsections",\s*\[([^\]]*)\]\)/g;
	let m;
	while ((m = re.exec(src)) !== null) {
		const key = m[1];
		const description_key = m[2];
		const platforms = m[3].match(/"([^"]+)"/g)
			? m[3].match(/"([^"]+)"/g).map((s) => s.replace(/"/g, ''))
			: [];
		const subsections = m[4].match(/"([^"]+)"/g)
			? m[4].match(/"([^"]+)"/g).map((s) => s.replace(/"/g, ''))
			: [];
		result.set(key, { description_key, platforms, subsections });
	}
	return result;
}

/**
 * Extracts all section entries from features_manifest.lua.
 * Returns Map<sectionPath, { description_key, platforms, subsections }>.
 * @param {string} src - Raw file content.
 * @returns {Map<string, object>}
 */
function parseLuaSections(src) {
	const result = new Map();
	// Each section block: ["key"] = { description_key = "...", platforms = {...}, subsections = {...} }
	const re =
		/\["([\w.]+)"\]\s*=\s*\{[^}]*description_key\s*=\s*"([^"]+)",[^}]*platforms\s*=\s*\{([^}]*)\},[^}]*subsections\s*=\s*\{([^}]*)\}[^}]*\}/g;
	let m;
	while ((m = re.exec(src)) !== null) {
		const key = m[1];
		const description_key = m[2];
		const platforms = m[3].match(/"([^"]+)"/g)
			? m[3].match(/"([^"]+)"/g).map((s) => s.replace(/"/g, ''))
			: [];
		const subsections = m[4].match(/"([^"]+)"/g)
			? m[4].match(/"([^"]+)"/g).map((s) => s.replace(/"/g, ''))
			: [];
		result.set(key, { description_key, platforms, subsections });
	}
	return result;
}

/**
 * Extracts all feature paths from features_manifest.ahk.
 * Returns array of { path, id, type, section, platforms }.
 *
 * Strategy: each feature line has a fixed structure — extract the fields
 * we care about using targeted named captures, skipping the "default" value
 * which may be a nested Map() expression of variable depth.
 * @param {string} src - Raw file content.
 * @returns {Array<object>}
 */
function parseAhkFeatures(src) {
	const results = [];
	// Match the fixed prefix fields
	const rePath = /"path",\s*"([^"]+)"/g;
	const reId = /"id",\s*"([^"]+)"/;
	const reSection = /"section",\s*"([^"]+)"/;
	const reType = /"type",\s*"([^"]+)"/;
	const reDescKey = /"description_key",\s*"([^"]+)"/;
	const rePlat = /"platforms",\s*\[([^\]]*)\]/;

	// Split on feature boundaries — each Map( starts a new feature entry
	// Use the "path" field as the anchor to find each line
	const lines = src.split(/\r?\n/);
	for (const line of lines) {
		if (!line.includes('"path"')) continue;
		const mPath = line.match(/"path",\s*"([^"]+)"/);
		if (!mPath) continue;
		const mId = line.match(reId);
		const mSection = line.match(reSection);
		const mType = line.match(reType);
		const mDescKey = line.match(reDescKey);
		const mPlat = line.match(rePlat);
		if (!mId || !mSection || !mType || !mDescKey || !mPlat) continue;
		const platforms = mPlat[1].match(/"([^"]+)"/g)
			? mPlat[1].match(/"([^"]+)"/g).map((s) => s.replace(/"/g, ''))
			: [];
		results.push({
			path: mPath[1],
			id: mId[1],
			section: mSection[1],
			type: mType[1],
			desc_key: mDescKey[1],
			platforms
		});
	}
	return results;
}

/**
 * Extracts all feature paths from features_manifest.lua.
 * Returns array of { path, id, type, section, platforms }.
 *
 * Strategy: locate each feature block by finding lines containing
 * `path = "..."` inside the M.features array (after the `M.features = {` line).
 * For each such line, look ahead within the enclosing block to gather the other
 * fields — handles both single-line and multi-line block formats.
 * @param {string} src - Raw file content.
 * @returns {Array<object>}
 */
function parseLuaFeatures(src) {
	const results = [];
	// Find the start of M.features
	const featStart = src.indexOf('M.features');
	if (featStart === -1) return results;
	const featSrc = src.slice(featStart);

	// Split into lines and walk through them
	const lines = featSrc.split(/\r?\n/);

	let i = 0;
	while (i < lines.length) {
		if (!lines[i].includes('path = "')) {
			i++;
			continue;
		}

		// Collect the lines of this block until we see a line with only `},` or `}`
		// that closes the feature block (depth 0)
		const blockLines = [];
		blockLines.push(lines[i]);
		let j = i + 1;
		// Track brace depth to find the closing `}` of the feature block
		// The opening `{` of the feature entry was on a previous line (or same line)
		let depth = 1;
		// Count open braces on the first line
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
		const mSection = block.match(/section\s*=\s*"([^"]+)"/);
		const mType = block.match(/type\s*=\s*"([^"]+)"/);
		const mDescKey = block.match(/description_key\s*=\s*"([^"]+)"/);
		const mPlat = block.match(/platforms\s*=\s*\{([^}]*)\}/);
		if (!mPath || !mId || !mSection || !mType || !mDescKey || !mPlat) continue;

		const platforms = mPlat[1].match(/"([^"]+)"/g)
			? mPlat[1].match(/"([^"]+)"/g).map((s) => s.replace(/"/g, ''))
			: [];
		results.push({
			path: mPath[1],
			id: mId[1],
			section: mSection[1],
			type: mType[1],
			desc_key: mDescKey[1],
			platforms
		});
	}
	return results;
}

// ============================================================
// ============================================================
// ======= 2/ Test runner (TAP-compatible output) =============
// ============================================================
// ============================================================

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
 * Prints the TAP report and exits with the appropriate code.
 */
function report() {
	const total = _pass + _fail;
	console.log(`TAP version 14`);
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

// ==================================================
// ==================================================
// ======= 3/ Manifest file availability ============
// ==================================================
// ==================================================

const ahkExists = fs.existsSync(AHK_MANIFEST);
const luaExists = fs.existsSync(HS_MANIFEST);
const linuxExists = fs.existsSync(LINUX_MANIFEST);

test(
	'AHK manifest file exists',
	ahkExists,
	`Expected ${AHK_MANIFEST} — run npm run build:manifest`
);
test('HS manifest file exists', luaExists, `Expected ${HS_MANIFEST} — run npm run build:manifest`);
test('Linux manifest file exists', linuxExists, `Expected ${LINUX_MANIFEST} — run npm run build:manifest`);

if (!ahkExists || !luaExists || !linuxExists) {
	// Cannot proceed without all three files.
	report();
	process.exit(1);
}

const ahkSrc = fs.readFileSync(AHK_MANIFEST, 'utf8');
const luaSrc = fs.readFileSync(HS_MANIFEST, 'utf8');
const linuxSrc = fs.readFileSync(LINUX_MANIFEST, 'utf8');

// =====================================================
// =====================================================
// ======= 4/ Version parity ===========================
// =====================================================
// =====================================================

const ahkVersion = parseAhkVersion(ahkSrc);
const luaVersion = parseLuaVersion(luaSrc);
const linuxVersion = parseLuaVersion(linuxSrc);

test(
	'AHK manifest version is parseable',
	ahkVersion !== '',
	`Could not extract version from ${AHK_MANIFEST}`
);
test(
	'HS manifest version is parseable',
	luaVersion !== '',
	`Could not extract version from ${HS_MANIFEST}`
);
test(
	`Version matches: "${ahkVersion}" (AHK) == "${luaVersion}" (HS)`,
	ahkVersion === luaVersion && ahkVersion !== '',
	`AHK="${ahkVersion}" HS="${luaVersion}"`
);
test('Linux manifest version is parseable', linuxVersion !== '', `Could not extract version from ${LINUX_MANIFEST}`);
test(
	`Version matches Linux: "${ahkVersion}" (AHK) == "${linuxVersion}" (Linux)`,
	ahkVersion === linuxVersion && ahkVersion !== '',
	`AHK="${ahkVersion}" Linux="${linuxVersion}"`
);

// =====================================================
// =====================================================
// ======= 5/ section_order parity =====================
// =====================================================
// =====================================================

const ahkOrder = parseAhkSectionOrder(ahkSrc);
const luaOrder = parseLuaSectionOrder(luaSrc);
const linuxOrder = parseLuaSectionOrder(linuxSrc);

test(
	'AHK section_order is parseable',
	ahkOrder.length > 0,
	`Extracted 0 items from AHK section_order`
);
test(
	'HS section_order is parseable',
	luaOrder.length > 0,
	`Extracted 0 items from HS section_order`
);
test(
	`section_order length matches: ${ahkOrder.length} (AHK) == ${luaOrder.length} (HS)`,
	ahkOrder.length === luaOrder.length,
	`AHK=[${ahkOrder}] HS=[${luaOrder}]`
);
test('Linux section_order is parseable', linuxOrder.length > 0, 'Extracted 0 items from Linux section_order');
test(
	`section_order length matches Linux: ${ahkOrder.length} (AHK) == ${linuxOrder.length} (Linux)`,
	ahkOrder.length === linuxOrder.length,
	`AHK=[${ahkOrder}] Linux=[${linuxOrder}]`
);

for (let i = 0; i < Math.max(ahkOrder.length, luaOrder.length); i++) {
	const a = ahkOrder[i] || '(missing)';
	const l = luaOrder[i] || '(missing)';
	test(`section_order[${i}] matches: "${a}"`, a === l, `AHK="${a}" HS="${l}"`);
	const linux = linuxOrder[i] || '(missing)';
	test(`section_order[${i}] matches Linux: "${a}"`, a === linux, `AHK="${a}" Linux="${linux}"`);
}

// ====================================================
// ====================================================
// ======= 6/ Sections parity ==========================
// ====================================================
// ====================================================

const ahkSections = parseAhkSections(ahkSrc);
const luaSections = parseLuaSections(luaSrc);
const linuxSections = parseLuaSections(linuxSrc);

test('AHK sections parseable', ahkSections.size > 0, `Extracted 0 sections from AHK manifest`);
test('HS sections parseable', luaSections.size > 0, `Extracted 0 sections from HS manifest`);
test('Linux sections parseable', linuxSections.size > 0, 'Extracted 0 sections from Linux manifest');

// Collect cross-platform sections (present in both drivers)
const crossPlatformSections = new Set();
for (const [key, info] of ahkSections) {
	if (info.platforms.includes('ahk') && info.platforms.includes('hs')) {
		crossPlatformSections.add(key);
	}
}

test(
	`Cross-platform sections found: ${crossPlatformSections.size}`,
	crossPlatformSections.size > 0,
	`No cross-platform sections detected in AHK manifest`
);

for (const sectionKey of crossPlatformSections) {
	const luaInfo = luaSections.get(sectionKey);
	test(
		`Cross-platform section "${sectionKey}" exists in HS manifest`,
		luaInfo !== undefined,
		`Section "${sectionKey}" is cross-platform in AHK but missing in HS manifest`
	);
	if (!luaInfo) continue;

	const ahkInfo = ahkSections.get(sectionKey);
	test(
		`Section "${sectionKey}" description_key matches`,
		ahkInfo.description_key === luaInfo.description_key,
		`AHK="${ahkInfo.description_key}" HS="${luaInfo.description_key}"`
	);

	// Sort both subsection arrays for stable comparison
	const ahkSubs = [...ahkInfo.subsections].sort().join(',');
	const luaSubs = [...luaInfo.subsections].sort().join(',');
	test(
		`Section "${sectionKey}" subsections match`,
		ahkSubs === luaSubs,
		`AHK=[${ahkSubs}] HS=[${luaSubs}]`
	);
}

for (const [sectionKey, ahkInfo] of ahkSections) {
	if (!ahkInfo.platforms.includes('linux')) continue;
	const linuxInfo = linuxSections.get(sectionKey);
	test(`Linux section "${sectionKey}" exists`, linuxInfo !== undefined, `Missing from Linux manifest`);
	if (!linuxInfo) continue;
	test(
		`Linux section "${sectionKey}" metadata matches`,
		ahkInfo.description_key === linuxInfo.description_key &&
			[...ahkInfo.subsections].sort().join(',') === [...linuxInfo.subsections].sort().join(','),
		`AHK=${JSON.stringify(ahkInfo)} Linux=${JSON.stringify(linuxInfo)}`
	);
}

// ====================================================
// ====================================================
// ======= 7/ Feature paths parity =====================
// ====================================================
// ====================================================

const ahkFeatures = parseAhkFeatures(ahkSrc);
const luaFeatures = parseLuaFeatures(luaSrc);
const linuxFeatures = parseLuaFeatures(linuxSrc);

test('AHK features parseable', ahkFeatures.length > 0, `Extracted 0 features from AHK manifest`);
test('HS features parseable', luaFeatures.length > 0, `Extracted 0 features from HS manifest`);
test('Linux features parseable', linuxFeatures.length > 0, 'Extracted 0 features from Linux manifest');

// Cross-platform features: present in both ahk and hs
const ahkCrossFeatures = ahkFeatures.filter(
	(f) => f.platforms.includes('ahk') && f.platforms.includes('hs')
);
const luaCrossFeatures = luaFeatures.filter(
	(f) => f.platforms.includes('ahk') && f.platforms.includes('hs')
);

test(
	`Cross-platform feature count matches: ${ahkCrossFeatures.length} (AHK) == ${luaCrossFeatures.length} (HS)`,
	ahkCrossFeatures.length === luaCrossFeatures.length,
	`AHK has ${ahkCrossFeatures.length}, HS has ${luaCrossFeatures.length} cross-platform features`
);

// Build path-indexed map for HS features
const luaFeatMap = new Map(luaCrossFeatures.map((f) => [f.path, f]));

for (const feat of ahkCrossFeatures) {
	const luaFeat = luaFeatMap.get(feat.path);
	test(
		`Cross-platform feature "${feat.path}" exists in HS manifest`,
		luaFeat !== undefined,
		`Feature "${feat.path}" is cross-platform in AHK but missing in HS manifest`
	);
	if (!luaFeat) continue;

	test(
		`Feature "${feat.path}" id matches`,
		feat.id === luaFeat.id,
		`AHK="${feat.id}" HS="${luaFeat.id}"`
	);
	test(
		`Feature "${feat.path}" type matches`,
		feat.type === luaFeat.type,
		`AHK="${feat.type}" HS="${luaFeat.type}"`
	);
	test(
		`Feature "${feat.path}" description_key matches`,
		feat.desc_key === luaFeat.desc_key,
		`AHK="${feat.desc_key}" HS="${luaFeat.desc_key}"`
	);
}

const ahkLinuxFeatures = ahkFeatures.filter((feature) => feature.platforms.includes('linux'));
const linuxFeatureMap = new Map(linuxFeatures.map((feature) => [feature.path, feature]));
const linuxAhkFeatures = linuxFeatures.filter((feature) => feature.platforms.includes('ahk'));
test(
	`AHK/Linux feature count matches: ${ahkLinuxFeatures.length} (AHK) == ${linuxAhkFeatures.length} (Linux)`,
	ahkLinuxFeatures.length === linuxAhkFeatures.length,
	`AHK has ${ahkLinuxFeatures.length}, Linux has ${linuxAhkFeatures.length}`
);
for (const feature of ahkLinuxFeatures) {
	const linuxFeature = linuxFeatureMap.get(feature.path);
	test(`Linux feature "${feature.path}" exists`, linuxFeature !== undefined, 'Missing from Linux manifest');
	if (!linuxFeature) continue;
	test(
		`Linux feature "${feature.path}" metadata matches`,
		feature.id === linuxFeature.id && feature.type === linuxFeature.type &&
			feature.desc_key === linuxFeature.desc_key,
		`AHK=${JSON.stringify(feature)} Linux=${JSON.stringify(linuxFeature)}`
	);
}

const hsLinuxFeatures = luaFeatures.filter((feature) => feature.platforms.includes('linux'));
const linuxHsFeatures = linuxFeatures.filter((feature) => feature.platforms.includes('hs'));
const hsFeatureMap = new Map(hsLinuxFeatures.map((feature) => [feature.path, feature]));
test(
	`HS/Linux feature count matches: ${hsLinuxFeatures.length} (HS) == ${linuxHsFeatures.length} (Linux)`,
	hsLinuxFeatures.length === linuxHsFeatures.length,
	`HS has ${hsLinuxFeatures.length}, Linux has ${linuxHsFeatures.length}`
);
for (const feature of linuxHsFeatures) {
	const hsFeature = hsFeatureMap.get(feature.path);
	test(`Linux feature "${feature.path}" exists in HS`, hsFeature !== undefined, 'Missing from HS manifest');
	if (!hsFeature) continue;
	test(
		`Linux/HS feature "${feature.path}" metadata matches`,
		feature.id === hsFeature.id && feature.type === hsFeature.type &&
			feature.desc_key === hsFeature.desc_key,
		`HS=${JSON.stringify(hsFeature)} Linux=${JSON.stringify(feature)}`
	);
}

report();
