// tools/codegen/codegen-expander-hs.cjs
// Generates static/ergopti_plus/macos/_generated/expander.lua from
// static/ergopti_plus/shared/domain/Expander.spec.js.

'use strict';

const fs = require('fs');
const path = require('path');

const OUT_DIR = path.resolve(__dirname, '../../static/ergopti_plus/macos/_generated');
const OUT_FILE = path.join(OUT_DIR, 'expander.lua');

// ================================
// ================================
// ======= 1/ Banner Helpers =======
// ================================
// ================================

/**
 * Builds a perfectly-aligned section banner (7= style, 4-line frame).
 * @param {string} title  - The title text, e.g. "1/ State".
 * @param {string} prefix - Comment prefix, e.g. "---".
 * @returns {string} The four banner lines joined by newlines.
 */
function section(title, prefix) {
	const body = `${prefix} ======= ${title} =======`;
	const bar = prefix + ' ' + '='.repeat(body.length - prefix.length - 1);
	return [bar, bar, body, bar, bar].join('\n');
}

/**
 * Builds a perfectly-aligned subsection banner (5= style, 2-line frame).
 * @param {string} title  - The title text, e.g. "1.1) Constants".
 * @param {string} prefix - Comment prefix, e.g. "---".
 * @returns {string} The three banner lines joined by newlines.
 */
function subsection(title, prefix) {
	const body = `${prefix} ===== ${title} =====`;
	const bar = prefix + ' ' + '='.repeat(body.length - prefix.length - 1);
	return [bar, body, bar].join('\n');
}

// ================================
// ================================
// ======= 2/ Code Generation =====
// ================================
// ================================

/**
 * Produces the full content of expander.lua.
 * @returns {string}
 */
function generate() {
	const lines = [];
	const L = (s = '') => lines.push(s);

	// -- File path header + auto-generated notice
	L('--- drivers/hammerspoon/_generated/expander.lua');
	L('--- AUTO-GENERATED — do not edit manually.');
	L('--- Source: static/ergopti_plus/shared/domain/Expander.spec.js');
	L('--- Run: npm run codegen:expander:hs');
	L();
	L('--- ==============================================================================');
	L('--- MODULE: Expander (Generated — Hammerspoon driver)');
	L('--- DESCRIPTION:');
	L('--- Cross-driver, pure Lua 5.3+ implementation of the Expander domain contract.');
	L('--- Receives the current typing buffer and a tail character, queries the');
	L('--- Registry for candidate mappings, selects the best match, and returns an');
	L('--- ExpansionResult descriptor. No OS-specific APIs are used.');
	L('---');
	L('--- FEATURES & RATIONALE:');
	L('--- 1. Stateless expansion decision: decide() is a pure function of');
	L('---    (buffer, tail_char, opts) — no hidden global state beyond cycle tracking.');
	L('--- 2. Word-boundary enforcement: mappings with is_word=true only fire when');
	L('---    the character immediately before the trigger is a non-word character');
	L('---    (space, punctuation) or the trigger starts at the buffer boundary.');
	L('--- 3. Magic-key cycling: cycle_next() advances through the star bucket for');
	L('---    the same trigger base; cycling state is owned exclusively by this module.');
	L('--- 4. Backspace count: trigger_bytes + 1 when the terminator was consumed.');
	L('--- ==============================================================================');
	L();
	L('local M = {}');
	L();
	L();
	L();

	// -- Section 1: Constants
	L(section('1/ Constants', '---'));
	L();
	L('--- UTF-8 byte sequence for the U+2605 BLACK STAR magic key character.');
	L('local STAR_CHAR = string.char(0xE2, 0x98, 0x85)');
	L();
	L('--- Pattern that matches a single non-word boundary character.');
	L('--- A word char is any ASCII letter, digit, or underscore.');
	L('local WORD_CHAR_PATTERN = "[%w_]"');
	L();
	L();
	L();

	// -- Section 2: Private State
	L(section('2/ Private State', '---'));
	L();
	L('--- Registry instance injected via M.init().');
	L('local _registry = nil');
	L();
	L('--- Cycling state: base trigger string of the last expansion, or nil.');
	L('local _cycle_base = nil');
	L();
	L('--- Cycling state: index into the star bucket that was last returned.');
	L('local _cycle_index = nil');
	L();
	L('--- Cycling state: the candidate list frozen at the time of the first expansion.');
	L('local _cycle_candidates = nil');
	L();
	L();
	L();

	// -- Section 3: Module Initialisation
	L(section('3/ Module Initialisation', '---'));
	L();
	L('--- Guard: verifies that M.init() was called before any public function.');
	L('--- Logs an error via print and returns false on failure.');
	L('--- @param func_name string Name of the calling function.');
	L('--- @return boolean True when all dependencies are ready.');
	L('local function require_state(func_name)');
	L('\tif not _registry then');
	L(
		'\t\tprint(string.format("[expander] ERROR \'%s\' called before M.init() — registry not initialized.", func_name))'
	);
	L('\t\treturn false');
	L('\tend');
	L('\treturn true');
	L('end');
	L();
	L('--- Initialises the Expander with a Registry instance.');
	L('--- Must be called exactly once before any other public function.');
	L('--- @param registry table A Registry implementing mappings_for_tail().');
	L('function M.init(registry)');
	L('\tif type(registry) ~= "table" or type(registry.mappings_for_tail) ~= "function" then');
	L(
		'\t\tprint("[expander] ERROR M.init(): registry must expose mappings_for_tail — module non-functional.")'
	);
	L('\t\treturn');
	L('\tend');
	L('\tif _registry then');
	L('\t\tprint("[expander] WARN M.init() called more than once — ignoring duplicate call.")');
	L('\t\treturn');
	L('\tend');
	L('\t_registry = registry');
	L('end');
	L();
	L();
	L();

	// -- Section 4: Internal Helpers
	L(section('4/ Internal Helpers', '---'));
	L();

	// -- Subsection 4.1: UTF-8 tail char
	L(subsection('4.1) UTF-8 helpers', '---'));
	L();
	L('--- Returns the last UTF-8 codepoint of string s as a byte string.');
	L('--- Falls back to the raw last byte on malformed input.');
	L('--- @param s string');
	L('--- @return string');
	L('local function _tail_cp(s)');
	L('\tif type(s) ~= "string" or s == "" then return "" end');
	L('\tlocal ok, offset = pcall(utf8.offset, s, -1)');
	L('\tif ok and offset then return s:sub(offset) end');
	L('\treturn s:sub(-1)');
	L('end');
	L();
	L('--- Returns the number of UTF-8 codepoints in s (falls back to byte length).');
	L('--- @param s string');
	L('--- @return number');
	L('local function _utf8_len(s)');
	L('\treturn utf8.len(s) or #s');
	L('end');
	L();
	L();

	// -- Subsection 4.2: Word boundary check
	L(subsection('4.2) Word boundary check', '---'));
	L();
	L('--- Returns true when the character immediately before the trigger position in');
	L('--- buffer is a non-word character, or when the trigger starts at the buffer');
	L('--- boundary (no preceding character). Used to enforce is_word=true semantics.');
	L('--- @param buffer string  The full typing buffer.');
	L('--- @param trigger_bytes number  Byte length of the matched trigger.');
	L('--- @return boolean');
	L('local function _word_boundary_ok(buffer, trigger_bytes)');
	L('\tlocal pre_end = #buffer - trigger_bytes');
	L('\tif pre_end <= 0 then');
	L('\t\t-- Trigger spans the entire buffer — start-of-buffer counts as a boundary');
	L('\t\treturn true');
	L('\tend');
	L('\t-- Find the last codepoint before the trigger start');
	L('\tlocal pre_str = buffer:sub(1, pre_end)');
	L('\tlocal last_cp = _tail_cp(pre_str)');
	L('\t-- A non-word character satisfies the boundary requirement');
	L('\treturn last_cp:match(WORD_CHAR_PATTERN) == nil');
	L('end');
	L();
	L();

	// -- Subsection 4.3: Build ExpansionResult
	L(subsection('4.3) Build ExpansionResult', '---'));
	L();
	L('--- Constructs an ExpansionResult table from a candidate mapping and call context.');
	L('--- @param mapping table  The matched Mapping object from the Registry.');
	L('--- @param terminator_consumed boolean  True when the terminator is part of the trigger.');
	L('--- @return table  An ExpansionResult.');
	L('local function _build_result(mapping, terminator_consumed)');
	L('\tlocal bs_count = mapping.trigger_bytes + (terminator_consumed and 1 or 0)');
	L('\treturn {');
	L('\t\treplacement        = mapping.plain_repl or mapping.repl,');
	L('\t\tbackspace_count    = bs_count,');
	L('\t\tconsume_terminator = terminator_consumed,');
	L('\t\tis_final           = mapping.final_result or false,');
	L('\t\tgroup              = mapping.group,');
	L('\t\ttrigger            = mapping.trigger,');
	L('\t\tcolor              = mapping.color or nil,');
	L('\t}');
	L('end');
	L();
	L();
	L();

	// -- Section 5: Port Contract
	L(section('5/ Port Contract', '---'));
	L();

	// -- Subsection 5.1: decide
	L(subsection('5.1) M.decide', '---'));
	L();
	L('--- Decides whether to expand the current buffer.');
	L('--- Queries the Registry for candidates whose tail matches tail_char, then');
	L('--- iterates in longest-first order (Registry guarantees this), checks that');
	L('--- the buffer ends with the trigger, enforces word-boundary rules, and');
	L('--- returns the first match.');
	L('---');
	L('--- @param buffer    string  The full typing buffer.');
	L('--- @param tail_char string  The character just typed.');
	L('--- @param opts      table|nil  { terminator_consumed: boolean }');
	L('--- @return table|nil  An ExpansionResult, or nil when no mapping matches.');
	L('function M.decide(buffer, tail_char, opts)');
	L('\tif not require_state("decide") then return nil end');
	L('\tif type(buffer) ~= "string" or type(tail_char) ~= "string" then return nil end');
	L('\topts = opts or {}');
	L('\tlocal terminator_consumed = opts.terminator_consumed == true');
	L();
	L('\tlocal candidates = _registry.mappings_for_tail(tail_char)');
	L('\tfor _, mapping in ipairs(candidates) do');
	L('\t\t-- Check whether the buffer ends with this trigger');
	L('\t\tlocal tlen = mapping.trigger_bytes');
	L('\t\tif #buffer >= tlen then');
	L('\t\t\tlocal suffix = buffer:sub(-tlen)');
	L('\t\t\tif suffix == mapping.trigger then');
	L('\t\t\t\t-- Enforce word-boundary rule for is_word mappings');
	L('\t\t\t\tlocal boundary_ok = (not mapping.is_word) or _word_boundary_ok(buffer, tlen)');
	L('\t\t\t\tif boundary_ok then');
	L('\t\t\t\t\t-- Arm cycling state so cycle_next() can pick up from here');
	L('\t\t\t\t\t_cycle_base       = mapping.star_base');
	L('\t\t\t\t\t_cycle_candidates = candidates');
	L('\t\t\t\t\t_cycle_index      = nil');
	L('\t\t\t\t\tfor i, c in ipairs(candidates) do');
	L('\t\t\t\t\t\tif c == mapping then _cycle_index = i; break end');
	L('\t\t\t\t\tend');
	L('\t\t\t\t\treturn _build_result(mapping, terminator_consumed)');
	L('\t\t\t\tend');
	L('\t\t\tend');
	L('\t\tend');
	L('\tend');
	L('\treturn nil');
	L('end');
	L();
	L();

	// -- Subsection 5.2: cycle_next
	L(subsection('5.2) M.cycle_next', '---'));
	L();
	L('--- Advances to the next magic-key mapping for the same star_base as the last');
	L('--- expansion. Returns nil when no further candidates exist in the bucket.');
	L('---');
	L('--- @param buffer string  Buffer state at cycle time (used for backspace count).');
	L('--- @return table|nil  The next ExpansionResult, or nil.');
	L('function M.cycle_next(buffer)');
	L('\tif not require_state("cycle_next") then return nil end');
	L('\tif not _cycle_base or not _cycle_candidates or not _cycle_index then');
	L('\t\treturn nil');
	L('\tend');
	L();
	L('\t-- Collect all candidates that share the same star_base');
	L('\tlocal star_bucket = {}');
	L('\tfor _, c in ipairs(_cycle_candidates) do');
	L('\t\tif c.star_base == _cycle_base then');
	L('\t\t\ttable.insert(star_bucket, c)');
	L('\t\tend');
	L('\tend');
	L();
	L('\tif #star_bucket < 2 then return nil end');
	L();
	L('\t-- Find the position of the current mapping inside the star bucket');
	L('\tlocal current = _cycle_candidates[_cycle_index]');
	L('\tlocal pos_in_bucket = nil');
	L('\tfor i, c in ipairs(star_bucket) do');
	L('\t\tif c == current then pos_in_bucket = i; break end');
	L('\tend');
	L();
	L('\tif not pos_in_bucket then return nil end');
	L();
	L('\t-- Advance cyclically');
	L('\tlocal next_pos = (pos_in_bucket % #star_bucket) + 1');
	L('\tlocal next_mapping = star_bucket[next_pos]');
	L();
	L('\t-- Update cycle index to point at the new mapping in the full candidate list');
	L('\tfor i, c in ipairs(_cycle_candidates) do');
	L('\t\tif c == next_mapping then _cycle_index = i; break end');
	L('\tend');
	L();
	L("\t-- Backspace count covers the previous expansion's replacement plus the trigger");
	L('\tlocal prev_repl_len = #(current.plain_repl or current.repl)');
	L('\tlocal result = _build_result(next_mapping, false)');
	L('\tresult.backspace_count = prev_repl_len');
	L('\treturn result');
	L('end');
	L();
	L();

	// -- Subsection 5.3: reset
	L(subsection('5.3) M.reset', '---'));
	L();
	L('--- Clears all cycling state. Must be called on Escape, focus change, or');
	L('--- when the buffer is externally cleared.');
	L('--- @return nil');
	L('function M.reset()');
	L('\t_cycle_base       = nil');
	L('\t_cycle_index      = nil');
	L('\t_cycle_candidates = nil');
	L('end');
	L();
	L();
	L('return M');
	L();

	return lines.join('\n');
}

// ================================
// ================================
// ======= 3/ Entry Point =========
// ================================
// ================================

(function main() {
	if (!fs.existsSync(OUT_DIR)) {
		fs.mkdirSync(OUT_DIR, { recursive: true });
	}

	const content = generate();
	fs.writeFileSync(OUT_FILE, content, 'utf8');

	const rel = path.relative(process.cwd(), OUT_FILE).replace(/\\/g, '/');
	console.log(`[codegen:expander:hs] Written → ${rel}`);
})();
