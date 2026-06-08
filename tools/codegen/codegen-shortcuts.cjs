// tools/codegen/codegen-shortcuts.cjs

/**
 * ==============================================================================
 * MODULE: Shortcuts Bindings Codegen
 * DESCRIPTION:
 * Reads `static/ergopti_plus/shared/features/shortcuts.toml` and generates:
 *   - `static/ergopti_plus/windows/_generated/shortcuts_bindings.ahk`
 *   - `static/ergopti_plus/macos/_generated/shortcuts_bindings.lua`
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: shortcut ids, i18n keys and default chords live in
 *    one TOML file; both driver outputs are derived from it at codegen time.
 * 2. Encoding safety: the AHK output is written as UTF-8 BOM + CRLF, which is
 *    required by the AHK v2 parser (silent abort risk on mismatch).
 * 3. Conventional banner format: section headers follow the project style guide
 *    (7 = on each side, perfectly aligned ruler lines).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const TOML_PATH = path.resolve(ROOT, 'static/ergopti_plus/shared/features/shortcuts.toml');
const OUT_AHK = path.resolve(ROOT, 'static/ergopti_plus/windows/_generated/shortcuts_bindings.ahk');
const OUT_LUA = path.resolve(ROOT, 'static/ergopti_plus/macos/_generated/shortcuts_bindings.lua');

// ====================================
// ====================================
// ======= 1/ TOML Mini-Parser =======
// ====================================
// ====================================

/**
 * Minimal TOML array-of-tables parser sufficient for the shortcuts manifest.
 * Handles [[shortcuts]] blocks with scalar and inline-array values only.
 * @param {string} src Raw TOML source.
 * @returns {Array<Object>} Parsed shortcut entries.
 */
function parseShortcuts(src) {
	const shortcuts = [];
	let current = null;

	for (const rawLine of src.split('\n')) {
		const line = rawLine.trim();

		// Skip comments and blank lines
		if (line.startsWith('#') || line === '') continue;

		if (line === '[[shortcuts]]') {
			if (current) shortcuts.push(current);
			current = {};
			continue;
		}

		if (!current) continue;

		// Match key = value pairs
		const eqIdx = line.indexOf('=');
		if (eqIdx < 0) continue;

		const key = line.slice(0, eqIdx).trim();
		const raw = line.slice(eqIdx + 1).trim();

		if (raw.startsWith('[')) {
			// Inline array — extract quoted strings
			current[key] = [...raw.matchAll(/"([^"]*)"/g)].map((m) => m[1]);
		} else if (raw.startsWith('"') && raw.endsWith('"')) {
			current[key] = raw.slice(1, -1);
		} else if (raw === 'true') {
			current[key] = true;
		} else if (raw === 'false') {
			current[key] = false;
		} else {
			current[key] = raw;
		}
	}

	if (current) shortcuts.push(current);
	return shortcuts;
}

// ======================================
// ======================================
// ======= 2/ Banner Build Helpers =======
// ======================================
// ======================================

/**
 * Builds a perfectly aligned major-section banner in AHK comment style.
 * @param {string} title
 * @returns {string}
 */
function ahkSectionBanner(title) {
	const inner = `======= ${title} =======`;
	const rule = '='.repeat(inner.length);
	return [`; ${rule}`, `; ${rule}`, `; ${inner}`, `; ${rule}`, `; ${rule}`].join('\r\n');
}

/**
 * Builds a perfectly aligned major-section banner in Lua comment style.
 * @param {string} title
 * @returns {string}
 */
function luaSectionBanner(title) {
	const inner = `======= ${title} =======`;
	const rule = '='.repeat(inner.length);
	return [`-- ${rule}`, `-- ${rule}`, `-- ${inner}`, `-- ${rule}`, `-- ${rule}`].join('\n');
}

// =============================================
// =============================================
// ======= 3/ AHK Output Builder =======
// =============================================
// =============================================

/**
 * Generates the full AHK source for the shortcuts_bindings.ahk file.
 * @param {Array<Object>} shortcuts All parsed shortcut entries.
 * @returns {string} AHK v2 source (bare LF; CRLF conversion applied on write).
 */
function buildAhk(shortcuts) {
	const ahk = shortcuts.filter((s) => (s.platforms || []).includes('ahk'));

	const lines = [];

	// File-path header
	lines.push('; autohotkey/_generated/shortcuts_bindings.ahk');
	lines.push(';');
	lines.push('; MODULE: Shortcuts Bindings (AHK generated)');
	lines.push('; DESCRIPTION:');
	lines.push('; Auto-generated from static/ergopti_plus/shared/features/shortcuts.toml.');
	lines.push('; DO NOT EDIT MANUALLY — run `npm run codegen:shortcuts` to regenerate.');
	lines.push(';');
	lines.push('; Exposes SHORTCUTS_BINDINGS, a Map keyed by shortcut id.');
	lines.push('; Each value is a Map with: label_key, description_key, default_key.');
	lines.push('');

	// 5 blank lines before the section
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push(ahkSectionBanner('1/ Shortcuts bindings table'));
	lines.push('');

	lines.push('global SHORTCUTS_BINDINGS := Map(');
	for (let i = 0; i < ahk.length; i++) {
		const s = ahk[i];
		const comma = i < ahk.length - 1 ? ',' : '';
		lines.push(`\t"${s.id}", Map(`);
		lines.push(`\t\t"label_key",       "${s.label_key || ''}",`);
		lines.push(`\t\t"description_key", "${s.description_key || ''}",`);
		lines.push(`\t\t"default_key",     "${s.default_key_ahk || ''}"`);
		lines.push(`\t)${comma}`);
	}
	lines.push(')');
	lines.push('');

	return lines.join('\n');
}

// ============================================
// ============================================
// ======= 4/ Lua Output Builder =======
// ============================================
// ============================================

/**
 * Generates the full Lua source for the shortcuts_bindings.lua file.
 * @param {Array<Object>} shortcuts All parsed shortcut entries.
 * @returns {string} Lua source.
 */
function buildLua(shortcuts) {
	const hs = shortcuts.filter((s) => (s.platforms || []).includes('hs'));

	const lines = [];

	// File-path header (three dashes, as required for .lua by the style guide)
	lines.push('--- hammerspoon/_generated/shortcuts_bindings.lua');
	lines.push('---');
	lines.push('--- ==============================================================================');
	lines.push('--- MODULE: Shortcuts Bindings (Lua generated)');
	lines.push('--- DESCRIPTION:');
	lines.push('--- Auto-generated from static/ergopti_plus/shared/features/shortcuts.toml.');
	lines.push('--- DO NOT EDIT MANUALLY — run `npm run codegen:shortcuts` to regenerate.');
	lines.push('---');
	lines.push('--- Returns a table keyed by shortcut id, each entry containing:');
	lines.push('---   label_key, description_key, default_key.');
	lines.push('--- ==============================================================================');
	lines.push('');
	lines.push('local M = {}');
	lines.push('');

	// 5 blank lines before the section
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push(luaSectionBanner('1/ Shortcuts bindings table'));
	lines.push('');

	lines.push('M.bindings = {');
	for (const s of hs) {
		lines.push(`\t["${s.id}"] = {`);
		lines.push(`\t\tlabel_key       = "${s.label_key || ''}",`);
		lines.push(`\t\tdescription_key = "${s.description_key || ''}",`);
		lines.push(`\t\tdefault_key     = "${s.default_key_hs || ''}",`);
		lines.push(`\t},`);
	}
	lines.push('}');
	lines.push('');
	lines.push('return M');
	lines.push('');

	return lines.join('\n');
}

// ==========================================
// ==========================================
// ======= 5/ Write Helpers =======
// ==========================================
// ==========================================

/**
 * Writes a text file with UTF-8 BOM and CRLF line endings (required for AHK v2).
 * @param {string} filePath Absolute destination path.
 * @param {string} content  Source text with bare LF endings.
 */
function writeAhk(filePath, content) {
	const crlf = content.replace(/\n/g, '\r\n');
	const bom = Buffer.from([0xef, 0xbb, 0xbf]);
	const body = Buffer.from(crlf, 'utf8');
	fs.writeFileSync(filePath, Buffer.concat([bom, body]));
}

/**
 * Writes a UTF-8 text file with LF line endings.
 * @param {string} filePath Absolute destination path.
 * @param {string} content  Source text.
 */
function writeLua(filePath, content) {
	fs.writeFileSync(filePath, content, 'utf8');
}

// ==========================================
// ==========================================
// ======= 6/ Main Entry Point =======
// ==========================================
// ==========================================

/**
 * Reads shortcuts.toml, generates both output files, and reports results.
 */
function main() {
	const src = fs.readFileSync(TOML_PATH, 'utf8');
	const shortcuts = parseShortcuts(src);

	const ahkSrc = buildAhk(shortcuts);
	const luaSrc = buildLua(shortcuts);

	fs.mkdirSync(path.dirname(OUT_AHK), { recursive: true });
	fs.mkdirSync(path.dirname(OUT_LUA), { recursive: true });

	writeAhk(OUT_AHK, ahkSrc);
	writeLua(OUT_LUA, luaSrc);

	const ahkCount = shortcuts.filter((s) => (s.platforms || []).includes('ahk')).length;
	const hsCount = shortcuts.filter((s) => (s.platforms || []).includes('hs')).length;

	console.log(`codegen:shortcuts — OK`);
	console.log(`  AHK: ${ahkCount} shortcut(s) → ${path.relative(ROOT, OUT_AHK)}`);
	console.log(`  Lua: ${hsCount} shortcut(s) → ${path.relative(ROOT, OUT_LUA)}`);
}

main();
