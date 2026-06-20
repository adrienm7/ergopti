// tools/codegen/codegen-expander-ahk.cjs

/**
 * ==============================================================================
 * MODULE: Expander AHK Codegen
 * DESCRIPTION:
 * Generates `static/ergopti_plus/windows/_generated/expander.ahk` from the
 * Expander domain contract defined in
 * `static/ergopti_plus/shared/domain/Expander.spec.js`.
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: the generated file derives its class contract
 *    directly from the spec so structural drift between the spec and the AHK
 *    adapter is impossible.
 * 2. AHK v2 idioms: uses Map for result objects, proper class syntax, and
 *    SubStr-based suffix matching compatible with AHK's UTF-16 string model.
 * 3. Encoding safety: output is written as UTF-8 BOM + CRLF, which is required
 *    by the AHK v2 parser (silent abort risk on mismatch).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { sharedRel } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '../..');
const OUT_PATH = path.resolve(ROOT, 'static/ergopti_plus/windows/_generated/expander.ahk');
const SPEC_REL = sharedRel('domain/Expander.spec.js');

// ==================================================
// ==================================================
// ======= 1/ AHK Source Builder =======
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

/**
 * Builds a perfectly aligned minor-subsection banner comment block.
 * @param {string} title
 * @returns {string}
 */
function subsectionBanner(title) {
	const inner = `===== ${title} =====`;
	const width = inner.length;
	const rule = '='.repeat(width);
	return [`; ${rule}`, `; ${inner}`, `; ${rule}`].join('\n');
}

/**
 * Indents every line of a multi-line string by one tab.
 * @param {string} text
 * @returns {string}
 */
function indent(text) {
	return text.replace(/^/gm, '\t');
}

/**
 * Builds the full AHK source for the Expander class.
 * @returns {string} AHK v2 source text with bare LF newlines (normalised later).
 */
function buildAhkSource() {
	const lines = [];

	// File path header (first line, required by project convention)
	lines.push('; static/ergopti_plus/windows/_generated/expander.ahk');
	lines.push('');

	// Auto-generated warning banner
	lines.push('; ==========================================');
	lines.push('; AUTO-GENERATED — do not edit manually');
	lines.push(`; Source: ${SPEC_REL}`);
	lines.push('; Run: npm run codegen:expander:ahk');
	lines.push('; ==========================================');
	lines.push('');

	// Module-level docstring
	lines.push('; ==============================================================================');
	lines.push('; MODULE: Expander');
	lines.push('; DESCRIPTION:');
	lines.push('; AHK v2 implementation of the Expander domain contract. Given the current');
	lines.push('; typing buffer and a tail character, queries the Registry for candidate');
	lines.push('; mappings, selects the best match, and returns an ExpansionResult Map.');
	lines.push(';');
	lines.push('; FEATURES & RATIONALE:');
	lines.push('; 1. Stateless expansion decision: Decide() is a pure function over the');
	lines.push(';    Registry — it calls no OS API and owns no persistent buffer.');
	lines.push('; 2. Word-boundary enforcement: mappings with is_word=true only fire when');
	lines.push(';    the character immediately before the trigger is a non-word char or the');
	lines.push(';    buffer starts at that position.');
	lines.push('; 3. Magic-key cycling: CycleNext() selects the next mapping in the star');
	lines.push(';    bucket for the same trigger base; Reset() clears that state.');
	lines.push('; 4. Backspace count: trigger byte length (UTF-16 char count) plus 1 when');
	lines.push(';    the terminator was consumed by the expansion.');
	lines.push('; ==============================================================================');
	lines.push('');
	lines.push('#Requires AutoHotkey v2.0');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');

	// -------------------------------------------------------
	// Section 1 — Word-boundary helpers (module-level)
	// -------------------------------------------------------
	lines.push(sectionBanner('1/ Word-Boundary Helpers'));
	lines.push('');

	lines.push('; Returns true when ch is a word character (letter, digit, or underscore).');
	lines.push('; Used by Expander.Decide() to enforce the is_word boundary rule.');
	lines.push(';');
	lines.push('; Param ch - A single character string.');
	lines.push('; Returns boolean.');
	lines.push('_Expander_IsWordChar(ch) {');
	lines.push('\treturn RegExMatch(ch, "[\\w]") > 0');
	lines.push('}');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');

	// -------------------------------------------------------
	// Section 2 — Expander Class
	// -------------------------------------------------------
	lines.push(sectionBanner('2/ Expander Class'));
	lines.push('');

	lines.push('class Expander {');
	lines.push('');

	// 2.1) Instance State
	lines.push(indent(subsectionBanner('2.1) Instance State')));
	lines.push('');
	lines.push('\t; _registry : Registry');
	lines.push('\t; Injected Registry instance used for all MappingsForTail() queries.');
	lines.push('\t_registry := ""');
	lines.push('');
	lines.push('\t; _cycle_base : string');
	lines.push('\t; star_base of the last successfully expanded magic-key trigger.');
	lines.push('\t; Empty string when no cycle is in progress.');
	lines.push('\t_cycle_base := ""');
	lines.push('');
	lines.push('\t; _cycle_index : integer');
	lines.push('\t; Zero-based index into the current star-bucket for cycling.');
	lines.push('\t_cycle_index := 0');
	lines.push('');
	lines.push('\t; _cycle_bucket : Array');
	lines.push('\t; Snapshot of the star-bucket captured at the start of a cycle.');
	lines.push('\t_cycle_bucket := []');
	lines.push('');
	lines.push('');
	lines.push('');

	// 2.2) Constructor
	lines.push(indent(subsectionBanner('2.2) Constructor')));
	lines.push('');
	lines.push('\t; Initialises the Expander with a Registry instance.');
	lines.push('\t;');
	lines.push('\t; Param registry - A Registry object exposing MappingsForTail(tailChar).');
	lines.push('\t__New(registry) {');
	lines.push('\t\tthis._registry := registry');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// 2.3) Decide
	lines.push(indent(subsectionBanner('2.3) Decide')));
	lines.push('');
	lines.push('\t; Decides whether to expand based on buffer + tailChar.');
	lines.push('\t; Queries MappingsForTail(tailChar), iterates candidates longest-first,');
	lines.push('\t; checks suffix match and optional word-boundary, and returns the first hit.');
	lines.push('\t;');
	lines.push('\t; Param buffer   - Full typing buffer (everything since last reset).');
	lines.push('\t; Param tailChar - The character just typed (terminator or auto-trigger tail).');
	lines.push('\t; Param opts     - Map with optional key terminator_consumed (boolean).');
	lines.push('\t; Returns Map    - ExpansionResult fields, or empty Map() when no match.');
	lines.push('\tDecide(buffer, tailChar, opts) {');
	lines.push(
		'\t\tlocal termConsumed := (opts.Has("terminator_consumed") && opts["terminator_consumed"])'
	);
	lines.push('\t\tlocal candidates   := this._registry.MappingsForTail(tailChar)');
	lines.push('');
	lines.push('\t\tfor m in candidates {');
	lines.push('\t\t\tlocal trigger := m["trigger"]');
	lines.push('\t\t\tlocal tlen    := m["tlen"]');
	lines.push('');
	lines.push('\t\t\t; Buffer must be at least as long as the trigger');
	lines.push('\t\t\tif (StrLen(buffer) < tlen) {');
	lines.push('\t\t\t\tcontinue');
	lines.push('\t\t\t}');
	lines.push('');
	lines.push('\t\t\t; Check suffix match: last tlen chars of buffer must equal trigger');
	lines.push('\t\t\tlocal suffix := SubStr(buffer, -(tlen - 1))');
	lines.push('\t\t\tif (suffix != trigger) {');
	lines.push('\t\t\t\tcontinue');
	lines.push('\t\t\t}');
	lines.push('');
	lines.push('\t\t\t; Word-boundary check when is_word is set');
	lines.push('\t\t\tif (m["is_word"]) {');
	lines.push('\t\t\t\tlocal bufLen  := StrLen(buffer)');
	lines.push('\t\t\t\tlocal preLen  := bufLen - tlen');
	lines.push('\t\t\t\tif (preLen > 0) {');
	lines.push('\t\t\t\t\tlocal preCh := SubStr(buffer, preLen, 1)');
	lines.push('\t\t\t\t\tif (_Expander_IsWordChar(preCh)) {');
	lines.push('\t\t\t\t\t\tcontinue ; Trigger is mid-word — skip');
	lines.push('\t\t\t\t\t}');
	lines.push('\t\t\t\t}');
	lines.push('\t\t\t\t; preLen = 0 means buffer starts at trigger — boundary satisfied');
	lines.push('\t\t\t}');
	lines.push('');
	lines.push('\t\t\t; Match found — compute backspace count');
	lines.push('\t\t\t; Backspaces = trigger char count + 1 if terminator was consumed');
	lines.push('\t\t\tlocal bsCount := tlen + (termConsumed ? 1 : 0)');
	lines.push('');
	lines.push('\t\t\t; Capture cycling state for potential CycleNext() call');
	lines.push('\t\t\tif (m["has_magic"]) {');
	lines.push('\t\t\t\tthis._cycle_base   := m["star_base"]');
	lines.push('\t\t\t\tthis._cycle_index  := 1');
	lines.push('\t\t\t\tthis._cycle_bucket := this._BuildStarBucket(m["star_base"])');
	lines.push('\t\t\t} else {');
	lines.push('\t\t\t\tthis._cycle_base   := ""');
	lines.push('\t\t\t\tthis._cycle_index  := 0');
	lines.push('\t\t\t\tthis._cycle_bucket := []');
	lines.push('\t\t\t}');
	lines.push('');
	lines.push('\t\t\treturn Map(');
	lines.push('\t\t\t\t"replacement",       m["plain_repl"],');
	lines.push('\t\t\t\t"backspace_count",   bsCount,');
	lines.push('\t\t\t\t"consume_terminator", termConsumed,');
	lines.push('\t\t\t\t"is_final",          m["final_result"],');
	lines.push('\t\t\t\t"group",             m["group"],');
	lines.push('\t\t\t\t"trigger",           trigger,');
	lines.push('\t\t\t\t"color",             m["color"]');
	lines.push('\t\t\t)');
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\t; No candidate matched');
	lines.push('\t\treturn Map()');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// 2.4) CycleNext
	lines.push(indent(subsectionBanner('2.4) CycleNext')));
	lines.push('');
	lines.push('\t; Advances to the next mapping in the magic-key star bucket.');
	lines.push('\t; Called when the user presses the magic key after a successful expansion.');
	lines.push('\t; Wraps around to the first candidate when the end of the bucket is reached.');
	lines.push('\t;');
	lines.push('\t; Param buffer - Buffer state at cycle time (used to validate star_base).');
	lines.push('\t; Returns Map  - Next ExpansionResult, or false when no cycle is active.');
	lines.push('\tCycleNext(buffer) {');
	lines.push('\t\tif (this._cycle_base = "" || this._cycle_bucket.Length = 0) {');
	lines.push('\t\t\treturn false');
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\tlocal bucket := this._cycle_bucket');
	lines.push('\t\tlocal idx    := this._cycle_index');
	lines.push('');
	lines.push('\t\t; Wrap around if index exceeds bucket size');
	lines.push('\t\tif (idx > bucket.Length) {');
	lines.push('\t\t\tidx := 1');
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\tlocal m     := bucket[idx]');
	lines.push('\t\tlocal tlen  := m["tlen"]');
	lines.push('\t\t; Backspace count covers the previously inserted replacement + magic key');
	lines.push(
		'\t\t; The caller is responsible for the replacement length; here we supply trigger length'
	);
	lines.push('\t\tlocal bsCount := tlen + 1 ; +1 for the magic key itself');
	lines.push('');
	lines.push('\t\t; Advance index for the next call, wrapping at bucket end');
	lines.push('\t\tthis._cycle_index := (idx >= bucket.Length) ? 1 : idx + 1');
	lines.push('');
	lines.push('\t\treturn Map(');
	lines.push('\t\t\t"replacement",        m["plain_repl"],');
	lines.push('\t\t\t"backspace_count",    bsCount,');
	lines.push('\t\t\t"consume_terminator", true,');
	lines.push('\t\t\t"is_final",           m["final_result"],');
	lines.push('\t\t\t"group",              m["group"],');
	lines.push('\t\t\t"trigger",            m["trigger"],');
	lines.push('\t\t\t"color",              m["color"]');
	lines.push('\t\t)');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// 2.5) Reset
	lines.push(indent(subsectionBanner('2.5) Reset')));
	lines.push('');
	lines.push('\t; Clears all magic-key cycling state.');
	lines.push('\t; Call on Escape, window focus change, or buffer reset.');
	lines.push('\tReset() {');
	lines.push('\t\tthis._cycle_base   := ""');
	lines.push('\t\tthis._cycle_index  := 0');
	lines.push('\t\tthis._cycle_bucket := []');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// 2.6) Private helpers
	lines.push(indent(subsectionBanner('2.6) Private Helpers')));
	lines.push('');
	lines.push('\t; Collects all mappings sharing the given star_base from the registry.');
	lines.push('\t; The result is used as the cycling bucket for CycleNext().');
	lines.push('\t;');
	lines.push('\t; Param starBase - The trigger string without its trailing magic-key character.');
	lines.push('\t; Returns Array  - Sorted array of matching Mapping objects.');
	lines.push('\t_BuildStarBucket(starBase) {');
	lines.push('\t\tlocal starTailChar := (StrLen(starBase) > 0) ? SubStr(starBase, -1) : ""');
	lines.push('\t\tif (starTailChar = "") {');
	lines.push('\t\t\treturn []');
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\tlocal candidates := this._registry.MappingsForTail(starTailChar)');
	lines.push('\t\tlocal bucket     := []');
	lines.push('\t\tfor m in candidates {');
	lines.push('\t\t\tif (m["has_magic"] && m["star_base"] = starBase) {');
	lines.push('\t\t\t\tbucket.Push(m)');
	lines.push('\t\t\t}');
	lines.push('\t\t}');
	lines.push('\t\treturn bucket');
	lines.push('\t}');
	lines.push('');
	lines.push('}');

	return lines.join('\n');
}

// ==================================================
// ==================================================
// ======= 2/ File Writer =======
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
// ======= 3/ Main =======
// ==================================================
// ==================================================

/**
 * Entry point — builds the source, writes the file, and reports the result.
 */
function main() {
	console.log('codegen:expander:ahk — generating Expander AHK adapter…');

	const source = buildAhkSource();
	writeWithBomCrlf(OUT_PATH, source);

	const relOut = path.relative(ROOT, OUT_PATH);
	console.log(`  Written: ${relOut}`);
	console.log('codegen:expander:ahk — done.');
}

main();
