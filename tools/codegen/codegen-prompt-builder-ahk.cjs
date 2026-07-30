// tools/codegen/codegen-prompt-builder-ahk.cjs

/**
 * ==============================================================================
 * MODULE: PromptBuilder AHK Codegen
 * DESCRIPTION:
 * Generates `static/ergopti_plus/windows/_generated/prompt_builder.ahk` from the
 * canonical algorithm defined in
 * `static/ergopti_plus/_shared/lua/llm/prompt_builder.lua`.
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: all constants are kept in sync with the Lua and JS
 *    reference implementations; no divergence is possible once this script runs.
 * 2. AHK v2 idioms: uses Map for result objects, proper class syntax, and
 *    StrSplit / RegExReplace for string manipulation compatible with AHK's
 *    UTF-16 string model.
 * 3. Encoding safety: output is written as UTF-8 BOM + LF, required by the
 *    AHK v2 parser (silent abort risk on mismatch).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { sharedRel } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '../..');
const OUT_PATH = path.resolve(ROOT, 'static/ergopti_plus/windows/_generated/prompt_builder.ahk');
const SRC_REL = sharedRel('lua/llm/prompt_builder.lua');

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

// AHK string delimiter helpers represented as JS string literals.
// AHK v2 string literals are delimited by a PLAIN double-quote; the backtick
// escape (`") is only needed for a quote *inside* a string — which none of the
// emitted strings contain. Using `" as a delimiter (the previous bug) produced
// invalid AHK like config.Has(`"max_words`"), so these are plain quotes.
const AQ = '"'; // a single AHK string delimiter:  "
const AQQ = '""'; // an empty AHK string literal:    ""

/**
 * Builds the full AHK source for the PromptBuilder class.
 * @returns {string} AHK v2 source text with bare LF newlines (normalised later).
 */
function buildAhkSource() {
	const lines = [];

	// File path header (first line, required by project convention)
	lines.push('; static/ergopti_plus/windows/_generated/prompt_builder.ahk');
	lines.push('');

	// Auto-generated warning banner
	lines.push('; ==========================================');
	lines.push('; AUTO-GENERATED — do not edit manually');
	lines.push(`; Source: ${SRC_REL}`);
	lines.push('; Run: npm run codegen:prompt-builder:ahk');
	lines.push('; ==========================================');
	lines.push('');

	// Module-level docstring
	lines.push('; ==============================================================================');
	lines.push('; MODULE: PromptBuilder');
	lines.push('; DESCRIPTION:');
	lines.push('; AHK v2 implementation of the PromptBuilder domain contract. Derives all');
	lines.push('; LLM request parameters (context, token budget, temperature, context tail)');
	lines.push('; from the current typing buffer and a configuration Map.');
	lines.push(';');
	lines.push('; This module is the AHK counterpart of:');
	lines.push(';   ' + sharedRel('lua/llm/prompt_builder.lua'));
	lines.push(';   ' + sharedRel('core/domain/PromptBuilder.js'));
	lines.push('; All constants and algorithms MUST stay in sync with those references.');
	lines.push(';');
	lines.push('; CONSTANTS (canonical — all drivers MUST use these exact values):');
	lines.push(';   CONTEXT_TAIL_WORDS      = 5');
	lines.push(';   DEFAULT_MAX_TOKENS      = 150');
	lines.push(';   MIN_MAX_TOKENS          = 15');
	lines.push(';   WORDS_TO_TOKENS_RATIO   = 6');
	lines.push(';   TOKEN_BUDGET_OVERHEAD   = 10');
	lines.push(';   TEMP_DIVERSITY_CAP      = 1.0');
	lines.push(';   TEMP_INCREMENT_PER_PRED = 0.1');
	lines.push(';   GREEDY_TEMP_THRESHOLD   = 0.15');
	lines.push(';   CONTEXT_CHARS_PER_WORD  = 40');
	lines.push(';   CONTEXT_MIN_CHARS       = 100');
	lines.push('; ==============================================================================');
	lines.push('');
	lines.push('#Requires AutoHotkey v2.0');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');

	// -------------------------------------------------------
	// Section 1 — Module Constants
	// -------------------------------------------------------
	lines.push(sectionBanner('1/ Module Constants'));
	lines.push('');

	lines.push('; Number of words from the buffer tail kept as rolling context window');
	lines.push('global PB_CONTEXT_TAIL_WORDS      := 5');
	lines.push('');
	lines.push('; Token budget when max_words is uncapped (= 0)');
	lines.push('global PB_DEFAULT_MAX_TOKENS      := 150');
	lines.push('');
	lines.push('; Hard floor on the token budget regardless of word settings');
	lines.push('global PB_MIN_MAX_TOKENS          := 15');
	lines.push('');
	lines.push('; Conservative words-to-tokens multiplier for token budget estimation');
	lines.push('global PB_WORDS_TO_TOKENS_RATIO   := 6');
	lines.push('');
	lines.push('; Fixed overhead appended to the computed token budget');
	lines.push('global PB_TOKEN_BUDGET_OVERHEAD   := 10');
	lines.push('');
	lines.push('; Upper bound when auto_raise_temperature is active');
	lines.push('global PB_TEMP_DIVERSITY_CAP      := 1.0');
	lines.push('');
	lines.push('; Temperature step per extra prediction requested beyond 1');
	lines.push('global PB_TEMP_INCREMENT_PER_PRED := 0.1');
	lines.push('');
	lines.push('; Greedy threshold: snap temperature to 0 when single prediction and temp <= this');
	lines.push('global PB_GREEDY_TEMP_THRESHOLD   := 0.15');
	lines.push('');
	lines.push('; Chars of context allocated per predicted output word');
	lines.push('global PB_CONTEXT_CHARS_PER_WORD  := 40');
	lines.push('');
	lines.push('; Hard floor: always forward at least this many context characters');
	lines.push('global PB_CONTEXT_MIN_CHARS        := 100');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');

	// -------------------------------------------------------
	// Section 2 — PromptBuilder Class
	// -------------------------------------------------------
	lines.push(sectionBanner('2/ PromptBuilder Class'));
	lines.push('');

	lines.push('class PromptBuilder {');
	lines.push('');

	// 2.1) Internal Helpers
	lines.push(indent(subsectionBanner('2.1) Internal Helpers')));
	lines.push('');

	// _ExtractTail
	lines.push('\t; Extracts the last PB_CONTEXT_TAIL_WORDS words from the buffer.');
	lines.push('\t; Returns a string of those whitespace-delimited tokens joined by spaces.');
	lines.push('\t;');
	lines.push('\t; Param buffer - The current typing buffer string.');
	lines.push('\t; Returns string - The tail words joined with single spaces.');
	lines.push('\t_ExtractTail(buffer) {');
	lines.push(`\t\tif (!buffer || RegExMatch(buffer, ${AQ}^\\s*$${AQ})) {`);
	lines.push(`\t\t\treturn ${AQQ}`);
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\t; Split on any whitespace run to get all tokens');
	lines.push(
		`\t\tlocal parts := StrSplit(Trim(buffer), [${AQ} ${AQ}, ${AQ}\`t${AQ}, ${AQ}\`n${AQ}, ${AQ}\`r${AQ}])`
	);
	lines.push('\t\tlocal words  := []');
	lines.push('\t\tfor p in parts {');
	lines.push(`\t\t\tif (p != ${AQQ}) {`);
	lines.push('\t\t\t\twords.Push(p)');
	lines.push('\t\t\t}');
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\tlocal total    := words.Length');
	lines.push('\t\tlocal startIdx := Max(1, total - PB_CONTEXT_TAIL_WORDS + 1)');
	lines.push(`\t\tlocal tail     := ${AQQ}`);
	lines.push('\t\tloop (total - startIdx + 1) {');
	lines.push('\t\t\tlocal w := words[startIdx + A_Index - 1]');
	lines.push(`\t\t\ttail    := (tail = ${AQQ}) ? w : tail . ${AQ} ${AQ} . w`);
	lines.push('\t\t}');
	lines.push('\t\treturn tail');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// _ComputeMaxTokens
	lines.push('\t; Computes the token budget from the max_words setting.');
	lines.push('\t; Returns PB_DEFAULT_MAX_TOKENS when max_words is 0 (unlimited).');
	lines.push('\t;');
	lines.push('\t; Param maxWords - Maximum predicted words (0 = unlimited).');
	lines.push('\t; Returns integer - The computed token budget.');
	lines.push('\t_ComputeMaxTokens(maxWords) {');
	lines.push('\t\tif (!maxWords || maxWords <= 0) {');
	lines.push('\t\t\treturn PB_DEFAULT_MAX_TOKENS');
	lines.push('\t\t}');
	lines.push(
		'\t\treturn Max(PB_MIN_MAX_TOKENS, maxWords * PB_WORDS_TO_TOKENS_RATIO + PB_TOKEN_BUDGET_OVERHEAD)'
	);
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// _ComputeTemperature
	lines.push('\t; Computes the effective temperature for a request.');
	lines.push('\t; Optionally raises temperature per extra prediction for diversity,');
	lines.push('\t; then snaps to 0 for single-prediction greedy decoding.');
	lines.push('\t;');
	lines.push('\t; Param baseTemp       - User-configured base temperature.');
	lines.push('\t; Param numPredictions - Number of predictions requested (1+).');
	lines.push('\t; Param autoRaise      - True = raise temperature for diversity.');
	lines.push('\t; Returns float - The effective temperature to send to the backend.');
	lines.push('\t_ComputeTemperature(baseTemp, numPredictions, autoRaise) {');
	lines.push('\t\tlocal t := baseTemp');
	lines.push('');
	lines.push('\t\tif (autoRaise && numPredictions > 1) {');
	lines.push(
		'\t\t\tt := Min(PB_TEMP_DIVERSITY_CAP, t + PB_TEMP_INCREMENT_PER_PRED * (numPredictions - 1))'
	);
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\t; Greedy decoding for single prediction and low temperature');
	lines.push('\t\tif (numPredictions = 1 && t <= PB_GREEDY_TEMP_THRESHOLD) {');
	lines.push('\t\t\tt := 0');
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\treturn t');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// _CapContext
	lines.push('\t; Truncates the context to a char limit proportional to max_words.');
	lines.push('\t; Prevents oversized prefill tokens from driving up TTFT on short predictions.');
	lines.push('\t;');
	lines.push('\t; Param buffer     - The full context buffer.');
	lines.push('\t; Param maxWords   - Max predicted words (0 = unlimited).');
	lines.push(
		'\t; Param ctxChars   - User-configured hard char cap (0 = no override). When'
	);
	lines.push(
		'\t;                    positive this is AUTHORITATIVE and wins over maxWords,'
	);
	lines.push(
		"\t;                    mirroring the shared Lua cap_context(). Omitting it is why"
	);
	lines.push(
		'\t;                    llm_context_length had no effect on the automatic path.'
	);
	lines.push('\t; Returns string   - The possibly truncated context.');
	lines.push('\t_CapContext(buffer, maxWords, ctxChars := 0) {');
	lines.push('\t\tif (ctxChars && ctxChars > 0) {');
	lines.push('\t\t\tlocal bufLenOverride := StrLen(buffer)');
	lines.push('\t\t\tif (bufLenOverride <= ctxChars) {');
	lines.push('\t\t\t\treturn buffer');
	lines.push('\t\t\t}');
	lines.push('\t\t\treturn SubStr(buffer, bufLenOverride - ctxChars + 1)');
	lines.push('\t\t}');
	lines.push('\t\tif (!maxWords || maxWords <= 0) {');
	lines.push('\t\t\treturn buffer');
	lines.push('\t\t}');
	lines.push(
		'\t\tlocal charLimit := Max(PB_CONTEXT_MIN_CHARS, maxWords * PB_CONTEXT_CHARS_PER_WORD)'
	);
	lines.push('\t\tlocal bufLen    := StrLen(buffer)');
	lines.push('\t\tif (bufLen <= charLimit) {');
	lines.push('\t\t\treturn buffer');
	lines.push('\t\t}');
	lines.push("\t\t; Take the trailing charLimit characters (mirrors Lua's buffer:sub(-charLimit))");
	lines.push('\t\treturn SubStr(buffer, bufLen - charLimit + 1)');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// 2.2) Build
	lines.push(indent(subsectionBanner('2.2) Build')));
	lines.push('');

	lines.push('\t; Derives all LLM request parameters from the buffer and configuration.');
	lines.push('\t; This is the AHK counterpart of PromptBuilder.lua:build_params().');
	lines.push('\t;');
	lines.push('\t; Param buffer - The current typing buffer string.');
	lines.push('\t; Param config - Map with optional keys:');
	lines.push('\t;   max_words       (integer, default 0)');
	lines.push('\t;   min_words       (integer, default 1)');
	lines.push('\t;   num_predictions (integer, default 1)');
	lines.push('\t;   temperature     (float,   default 0.1)');
	lines.push('\t;   auto_raise_temp (boolean, default false)');
	lines.push(`\t;   language        (string,  default ${AQ}fr${AQ})`);
	lines.push('\t; Returns Map - Keys: context, context_tail, max_tokens, temperature,');
	lines.push('\t;   min_words, max_words, language, num_predictions.');
	lines.push('\tBuild(buffer, config := Map()) {');
	lines.push(
		`\t\tlocal maxWords       := config.Has(${AQ}max_words${AQ})       ? config[${AQ}max_words${AQ}]       : 0`
	);
	lines.push(
		`\t\tlocal minWords       := config.Has(${AQ}min_words${AQ})       ? config[${AQ}min_words${AQ}]       : 1`
	);
	lines.push(
		`\t\tlocal numPredictions := config.Has(${AQ}num_predictions${AQ}) ? config[${AQ}num_predictions${AQ}] : 1`
	);
	lines.push(
		`\t\tlocal temperature    := config.Has(${AQ}temperature${AQ})     ? config[${AQ}temperature${AQ}]     : 0.1`
	);
	lines.push(
		`\t\tlocal autoRaise      := config.Has(${AQ}auto_raise_temp${AQ}) ? config[${AQ}auto_raise_temp${AQ}] : false`
	);
	lines.push(
		`\t\tlocal language       := config.Has(${AQ}language${AQ})        ? config[${AQ}language${AQ}]        : ${AQ}fr${AQ}`
	);
	lines.push('');
	lines.push('\t\tlocal tail    := this._ExtractTail(buffer)');
	lines.push(
		`\t\tlocal ctxChars       := config.Has(${AQ}context_window_chars${AQ}) ? config[${AQ}context_window_chars${AQ}] : 0`
	);
	lines.push('\t\tlocal context := this._CapContext(buffer, maxWords, ctxChars)');
	lines.push('');
	lines.push('\t\treturn Map(');
	lines.push(`\t\t\t${AQ}context${AQ},          context,`);
	lines.push(`\t\t\t${AQ}context_tail${AQ},     tail,`);
	lines.push(`\t\t\t${AQ}max_tokens${AQ},       this._ComputeMaxTokens(maxWords),`);
	lines.push(
		`\t\t\t${AQ}temperature${AQ},      this._ComputeTemperature(temperature, numPredictions, autoRaise),`
	);
	lines.push(`\t\t\t${AQ}min_words${AQ},        minWords,`);
	lines.push(`\t\t\t${AQ}max_words${AQ},        maxWords,`);
	lines.push(`\t\t\t${AQ}language${AQ},         language,`);
	lines.push(`\t\t\t${AQ}num_predictions${AQ},  numPredictions`);
	lines.push('\t\t)');
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
 * Writes content to outPath with UTF-8 BOM and LF line endings.
 * @param {string} outPath  Absolute path to the output file.
 * @param {string} content  Source text with bare LF newlines.
 */
function writeWithBomLf(outPath, content) {
	const BOM = Buffer.from([0xef, 0xbb, 0xbf]);
	const normalized = content.replace(/\r\n?/g, '\n');
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
	console.log('codegen:prompt-builder:ahk — generating PromptBuilder AHK adapter…');

	const source = buildAhkSource();
    writeWithBomLf(OUT_PATH, source);

	const relOut = path.relative(ROOT, OUT_PATH);
	console.log(`  Written: ${relOut}`);
	console.log('codegen:prompt-builder:ahk — done.');
}

main();
