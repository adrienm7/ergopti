// tools/codegen/codegen-llm-profiles-data-ahk.cjs

/**
 * ==============================================================================
 * MODULE: LLM Profiles Data AHK Codegen
 * DESCRIPTION:
 * Generates `static/ergopti_plus/windows/_generated/llm_profiles_data.ahk` from
 * two shared JSON sources: `_shared/modules/llm/legacy_ids.json` (profile-ID
 * migration table, DL-2) and the "basic" profile's `system_single` prompt in
 * `_shared/modules/llm/profiles.json` (the ultimate fallback prompt, DL-3).
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: both facts were previously hand-copied literals in
 *    windows/modules/llm/profiles.ahk AND macos/modules/llm/profiles.lua, with
 *    no mechanism catching drift between the three copies (JSON + 2 literals).
 *    The macOS driver already reads its copy from the loaded JSON at runtime
 *    (Lua has no equivalent codegen step); AHK cannot do the same without a
 *    JSON parse on every profile lookup, so — per the plan — the AHK side gets
 *    build-time generation instead of runtime delegation.
 * 2. Encoding safety: output is written as UTF-8 BOM + CRLF, required by the
 *    AHK v2 parser (silent abort risk on mismatch).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared, sharedRel } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '../..');
const OUT_PATH = path.resolve(ROOT, 'static/ergopti_plus/windows/_generated/llm_profiles_data.ahk');
const LEGACY_IDS_PATH = shared('modules/llm/legacy_ids.json');
const PROFILES_PATH = shared('modules/llm/profiles.json');
const LEGACY_IDS_REL = sharedRel('modules/llm/legacy_ids.json');
const PROFILES_REL = sharedRel('modules/llm/profiles.json');

// ==================================================
// ==================================================
// ======= 1/ Source Data Loading =======
// ==================================================
// ==================================================

/**
 * Loads and parses the legacy_ids.json migration table.
 * @returns {Object<string,string>} Map of old profile id -> new profile id.
 */
function loadLegacyIds() {
	const raw = fs.readFileSync(LEGACY_IDS_PATH, 'utf8');
	const parsed = JSON.parse(raw);
	if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
		throw new Error(`${LEGACY_IDS_REL} must decode to a flat JSON object`);
	}
	return parsed;
}

/**
 * Loads profiles.json and returns the "basic" profile's system_single prompt.
 * @returns {string} The basic profile's system_single text.
 */
function loadBasicPrompt() {
	const raw = fs.readFileSync(PROFILES_PATH, 'utf8');
	const parsed = JSON.parse(raw);
	if (!Array.isArray(parsed)) {
		throw new Error(`${PROFILES_REL} must decode to a JSON array`);
	}
	const basic = parsed.find((p) => p && p.id === 'basic');
	if (!basic || typeof basic.system_single !== 'string' || basic.system_single === '') {
		throw new Error(`${PROFILES_REL} has no "basic" profile with a non-empty system_single`);
	}
	return basic.system_single;
}

// ==================================================
// ==================================================
// ======= 2/ AHK Source Builder =======
// ==================================================
// ==================================================

/**
 * Builds a perfectly aligned major-section banner comment block.
 * @param {string} title
 * @returns {string}
 */
function sectionBanner(title) {
	const inner = `======= ${title} =======`;
	const width = inner.length;
	const rule = '='.repeat(width);
	return [`; ${rule}`, `; ${rule}`, `; ${inner}`, `; ${rule}`, `; ${rule}`].join('\n');
}

// AHK v2 has no backslash-escape convention; a literal double quote inside a
// double-quoted string is written `" (backtick + quote), never \" or "".
const AQ = '"';

/**
 * Escapes a JS string for embedding as an AHK v2 double-quoted string literal.
 * @param {string} text
 * @returns {string} The escaped text (without surrounding quotes).
 */
function escapeAhkString(text) {
	return text
		.replace(/`/g, '``')
		.replace(/"/g, '`"')
		.replace(/\n/g, '`n')
		.replace(/\r/g, '');
}

/**
 * Builds the full AHK source for the generated LLM profiles data file.
 * @param {Object<string,string>} legacyIds
 * @param {string} basicPrompt
 * @returns {string} AHK v2 source text with bare LF newlines (normalised later).
 */
function buildAhkSource(legacyIds, basicPrompt) {
	const lines = [];

	lines.push('; static/ergopti_plus/windows/_generated/llm_profiles_data.ahk');
	lines.push('');

	lines.push('; ==========================================');
	lines.push('; AUTO-GENERATED — do not edit manually');
	lines.push(`; Sources: ${LEGACY_IDS_REL}, ${PROFILES_REL}`);
	lines.push('; Run: npm run codegen:llm-profiles-data:ahk');
	lines.push('; ==========================================');
	lines.push('');

	lines.push('; ==============================================================================');
	lines.push('; MODULE: LLM Profiles Data (generated)');
	lines.push('; DESCRIPTION:');
	lines.push('; Two small domain facts extracted from the shared LLM profile registry so the');
	lines.push('; AHK driver never hand-maintains a copy that can drift from the JSON source:');
	lines.push(';   LLM_LEGACY_IDS   — profile-ID migration table (DL-2).');
	lines.push(';   LLM_GetBasicPrompt() — the "basic" profile system prompt, used as the');
	lines.push(';     resolver fallback when no profile-specific prompt is available (DL-3).');
	lines.push('; ==============================================================================');
	lines.push('');
	lines.push('#Requires AutoHotkey v2.0');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');

	lines.push(sectionBanner('1/ Legacy Profile ID Migration (DL-2)'));
	lines.push('');
	lines.push('; Renamed profile ids from earlier releases -> their current id.');
	lines.push('global LLM_LEGACY_IDS := Map(');
	const legacyEntries = Object.entries(legacyIds);
	legacyEntries.forEach(([oldId, newId], i) => {
		const comma = i < legacyEntries.length - 1 ? ',' : '';
		lines.push(`\t${AQ}${escapeAhkString(oldId)}${AQ}, ${AQ}${escapeAhkString(newId)}${AQ}${comma}`);
	});
	lines.push(')');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');

	lines.push(sectionBanner('2/ Basic Prompt Fallback (DL-3)'));
	lines.push('');
	lines.push('; Returns the "basic" profile system prompt — the resolver fallback when a');
	lines.push('; profile is missing or malformed. Sourced from profiles.json so it can never');
	lines.push('; drift from the profile the user actually sees when nothing else applies.');
	lines.push('LLM_GetBasicPrompt() {');
	lines.push(`\treturn ${AQ}${escapeAhkString(basicPrompt)}${AQ}`);
	lines.push('}');

	return lines.join('\n');
}

// ==================================================
// ==================================================
// ======= 3/ File Writer =======
// ==================================================
// ==================================================

/**
 * Writes content to outPath with UTF-8 BOM and CRLF line endings.
 * @param {string} outPath  Absolute path to the output file.
 * @param {string} content  Source text with bare LF newlines.
 */
function writeWithBomCrlf(outPath, content) {
	const BOM = Buffer.from([0xef, 0xbb, 0xbf]);
	const normalized = content.replace(/\r?\n/g, '\r\n');
	const body = Buffer.from(normalized, 'utf8');
	const out = Buffer.concat([BOM, body]);
	fs.mkdirSync(path.dirname(outPath), { recursive: true });
	fs.writeFileSync(outPath, out);
}

// ==================================================
// ==================================================
// ======= 4/ Main =======
// ==================================================
// ==================================================

/**
 * Entry point — loads sources, builds the AHK source, writes the file.
 */
function main() {
	console.log('codegen:llm-profiles-data:ahk — generating LLM profiles data AHK adapter…');

	const legacyIds = loadLegacyIds();
	const basicPrompt = loadBasicPrompt();
	const source = buildAhkSource(legacyIds, basicPrompt);
	writeWithBomCrlf(OUT_PATH, source);

	const relOut = path.relative(ROOT, OUT_PATH);
	console.log(`  Written: ${relOut}`);
	console.log('codegen:llm-profiles-data:ahk — done.');
}

main();
