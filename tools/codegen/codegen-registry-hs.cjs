// tools/codegen/codegen-registry-hs.cjs
// Generates static/ergopti_plus/macos/_generated/registry.lua from
// static/ergopti_plus/shared/domain/Registry.spec.js.

'use strict';

const fs = require('fs');
const path = require('path');

const OUT_DIR = path.resolve(__dirname, '../../static/ergopti_plus/macos/_generated');
const OUT_FILE = path.join(OUT_DIR, 'registry.lua');

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
 * Produces the full content of registry.lua.
 * @returns {string}
 */
function generate() {
	const lines = [];
	const L = (s = '') => lines.push(s);

	// -- File path header + auto-generated notice
	L('--- drivers/hammerspoon/_generated/registry.lua');
	L('--- AUTO-GENERATED — do not edit manually.');
	L('--- Source: static/ergopti_plus/shared/domain/Registry.spec.js');
	L('--- Run: npm run codegen:registry:hs');
	L();
	L('--- ==============================================================================');
	L('--- MODULE: Registry (Generated — Hammerspoon driver)');
	L('--- DESCRIPTION:');
	L('--- Cross-driver, pure Lua 5.3+ implementation of the Registry domain contract.');
	L('--- Maintains a tail-char-bucketed index of all known trigger→replacement');
	L('--- mappings. Supports group lifecycle (enable/disable) and O(1) tail-char');
	L('--- lookups for the per-keystroke hot path.');
	L('---');
	L('--- FEATURES & RATIONALE:');
	L('--- 1. Tail-char bucketing: each mapping is indexed by its last UTF-8');
	L('---    codepoint so the hot path only visits candidates that can match.');
	L('--- 2. Group lifecycle: disabling a group removes its entries from the live');
	L('---    index without destroying them; re-enabling restores them atomically.');
	L('--- 3. Longest-first ordering: within each bucket, mappings are sorted by');
	L('---    trigger length descending, then group_order, then seq, so the first');
	L('---    candidate tested is always the longest possible match.');
	L('--- ==============================================================================');
	L();
	L('local M = {}');
	L();
	L();
	L();

	// -- Section 1: Constants
	L(section('1/ Constants', '---'));
	L();
	L('--- Default group name assigned when opts.group is not provided.');
	L('local DEFAULT_GROUP       = "default"');
	L();
	L('--- Default group_order used when the group has no explicit order assigned.');
	L('--- A high sentinel keeps anonymous groups after explicitly ordered ones.');
	L('local DEFAULT_GROUP_ORDER = 9999');
	L();
	L();
	L();

	// -- Section 2: Private State
	L(section('2/ Private State', '---'));
	L();
	L('--- Live bucket index: maps tail_char → sorted array of active Mapping objects.');
	L('local _mappings_by_tail_char = {}');
	L();
	L('--- Full store (active + disabled) keyed by group → array of Mapping objects.');
	L('local _store_by_group = {}');
	L();
	L('--- Set of currently disabled group names (group_name → true).');
	L('local _disabled_groups = {}');
	L();
	L('--- Monotonically increasing insertion counter, used as tiebreaker.');
	L('local _seq = 0');
	L();
	L('--- Per-group insertion order counter, incremented the first time a group is seen.');
	L('local _group_order_counter = 0');
	L();
	L('--- Map from group name → group_order value, populated lazily on first add().');
	L('local _group_order_map = {}');
	L();
	L();
	L();

	// -- Section 3: Internal Helpers
	L(section('3/ Internal Helpers', '---'));
	L();

	// -- Subsection 3.1: UTF-8 tail codepoint
	L(subsection('3.1) UTF-8 tail codepoint', '---'));
	L();
	L('--- Returns the last UTF-8 codepoint of string s.');
	L('--- Falls back to the raw last byte when utf8.offset fails (malformed input).');
	L('--- @param s string');
	L('--- @return string');
	L('local function _tail_codepoint(s)');
	L('\tif type(s) ~= "string" or s == "" then return "" end');
	L('\tlocal ok, offset = pcall(utf8.offset, s, -1)');
	L('\tif ok and offset then return s:sub(offset) end');
	L('\t-- Malformed UTF-8: fall back to single byte at the end');
	L('\treturn s:sub(-1)');
	L('end');
	L();
	L();

	// -- Subsection 3.2: Mapping construction
	L(subsection('3.2) Mapping construction', '---'));
	L();
	L('--- Builds a Mapping object from the supplied arguments.');
	L('--- @param trigger string');
	L('--- @param repl    string');
	L('--- @param opts    table');
	L('--- @param seq     number');
	L('--- @param group_order number');
	L('--- @return table');
	L('local function _build_mapping(trigger, repl, opts, seq, group_order)');
	L('\tlocal tail = _tail_codepoint(trigger)');
	// U+2605 STAR = UTF-8 bytes E2 98 85 — expressed as literal codepoint escape
	// so this .cjs file stays clean of octal sequences in strict mode.
	const STAR_UTF8 = '★';
	L(
		`\tlocal star_base       = trigger:match("^(.-)" .. string.char(0xE2, 0x98, 0x85) .. "?$") or trigger`
	);
	L('\t-- Determine byte length of star_base safely');
	L('\tlocal star_base_bytes = #star_base');
	L('\tlocal star_base_tail  = _tail_codepoint(star_base)');
	L('\treturn {');
	L('\t\ttrigger         = trigger,');
	L('\t\trepl            = repl,');
	L('\t\tplain_repl      = repl,   -- Caller may override with pre-resolved value');
	L('\t\tis_word         = opts.is_word      or false,');
	L('\t\tauto            = opts.auto         or false,');
	L('\t\tseq             = seq,');
	L('\t\ttlen            = utf8.len(trigger) or #trigger,');
	L('\t\ttrigger_bytes   = #trigger,');
	L('\t\ttail_char       = tail,');
	L('\t\thas_magic       = opts.has_magic    or false,');
	L('\t\tstar_base       = star_base,');
	L('\t\tstar_base_bytes = star_base_bytes,');
	L('\t\tstar_base_tail  = star_base_tail,');
	L('\t\tgroup           = opts.group        or DEFAULT_GROUP,');
	L('\t\tgroup_order     = group_order,');
	L('\t\tfinal_result    = opts.final_result or false,');
	L('\t\tcolor           = opts.color        or nil,');
	L('\t}');
	L('end');
	L();
	L();

	// -- Subsection 3.3: Sort comparator
	L(subsection('3.3) Sort comparator', '---'));
	L();
	L('--- Comparison function for the per-bucket sort.');
	L('--- Order: longest tlen first, then lowest group_order, then lowest seq.');
	L('--- @param a table');
	L('--- @param b table');
	L('--- @return boolean');
	L('local function _mapping_cmp(a, b)');
	L('\tif a.tlen ~= b.tlen then return a.tlen > b.tlen end');
	L('\tif a.group_order ~= b.group_order then return a.group_order < b.group_order end');
	L('\treturn a.seq < b.seq');
	L('end');
	L();
	L();

	// -- Subsection 3.4: Bucket insertion
	L(subsection('3.4) Bucket insertion', '---'));
	L();
	L('--- Inserts a mapping into the live tail-char bucket and re-sorts it.');
	L('--- @param mapping table');
	L('local function _bucket_insert(mapping)');
	L('\tlocal tc = mapping.tail_char');
	L('\tif not _mappings_by_tail_char[tc] then');
	L('\t\t_mappings_by_tail_char[tc] = {}');
	L('\tend');
	L('\ttable.insert(_mappings_by_tail_char[tc], mapping)');
	L('\ttable.sort(_mappings_by_tail_char[tc], _mapping_cmp)');
	L('end');
	L();
	L('--- Removes a mapping from the live tail-char bucket.');
	L('--- @param mapping table');
	L('local function _bucket_remove(mapping)');
	L('\tlocal bucket = _mappings_by_tail_char[mapping.tail_char]');
	L('\tif not bucket then return end');
	L('\tfor i = #bucket, 1, -1 do');
	L('\t\tif bucket[i] == mapping then');
	L('\t\t\ttable.remove(bucket, i)');
	L('\t\t\treturn');
	L('\t\tend');
	L('\tend');
	L('end');
	L();
	L();
	L();

	// -- Section 4: Port Contract
	L(section('4/ Port Contract', '---'));
	L();

	// -- Subsection 4.1: add
	L(subsection('4.1) M.add', '---'));
	L();
	L('--- Registers a new mapping in the registry.');
	L('--- Duplicate triggers within the same group are logged and skipped.');
	L('--- @param trigger string  The hotstring trigger text.');
	L('--- @param repl    string  The raw replacement text.');
	L('--- @param opts    table   Optional fields: is_word, auto, has_magic,');
	L('---                        final_result, group, color, plain_repl, group_order.');
	L('--- @return table|nil The created Mapping object, or nil on duplicate.');
	L('function M.add(trigger, repl, opts)');
	L('\topts = opts or {}');
	L('\tlocal group = opts.group or DEFAULT_GROUP');
	L();
	L('\t-- Assign a stable group_order the first time a group is seen');
	L('\tif not _group_order_map[group] then');
	L('\t\t-- Caller may supply an explicit rank (e.g. from a config load-order)');
	L('\t\t_group_order_map[group] = opts.group_order');
	L('\t\t\tor (function()');
	L('\t\t\t\t_group_order_counter = _group_order_counter + 1');
	L('\t\t\t\treturn _group_order_counter');
	L('\t\t\tend)()');
	L('\tend');
	L('\tlocal group_order = _group_order_map[group]');
	L();
	L('\t-- Duplicate check inside the group');
	L('\tlocal existing = _store_by_group[group]');
	L('\tif existing then');
	L('\t\tfor _, m in ipairs(existing) do');
	L('\t\t\tif m.trigger == trigger then');
	L("\t\t\t\tprint(string.format(\"[registry] Duplicate trigger '%s' in group '%s' — skipping.\",");
	L('\t\t\t\t\ttrigger, group))');
	L('\t\t\t\treturn nil');
	L('\t\t\tend');
	L('\t\tend');
	L('\tend');
	L();
	L('\t_seq = _seq + 1');
	L();
	L('\t-- Allow caller to override plain_repl with a pre-resolved value');
	L('\tlocal mapping = _build_mapping(trigger, repl, opts, _seq, group_order)');
	L('\tif opts.plain_repl then mapping.plain_repl = opts.plain_repl end');
	L();
	L('\t-- Persist into the full store');
	L('\tif not _store_by_group[group] then _store_by_group[group] = {} end');
	L('\ttable.insert(_store_by_group[group], mapping)');
	L();
	L('\t-- Insert into live index only when the group is not disabled');
	L('\tif not _disabled_groups[group] then');
	L('\t\t_bucket_insert(mapping)');
	L('\tend');
	L();
	L('\treturn mapping');
	L('end');
	L();
	L();

	// -- Subsection 4.2: mappings_for_tail
	L(subsection('4.2) M.mappings_for_tail', '---'));
	L();
	L('--- Returns all active mappings whose trigger ends with tail_char.');
	L('--- The returned array is sorted: longest trigger first, then group_order,');
	L('--- then seq. Callers MUST NOT mutate the returned table.');
	L('--- @param tail_char string  A single UTF-8 codepoint.');
	L('--- @return table');
	L('function M.mappings_for_tail(tail_char)');
	L('\treturn _mappings_by_tail_char[tail_char] or {}');
	L('end');
	L();
	L();

	// -- Subsection 4.3: enable_group
	L(subsection('4.3) M.enable_group', '---'));
	L();
	L('--- Adds all mappings in the named group back to the live index.');
	L('--- No-op when the group is already enabled or does not exist.');
	L('--- @param name string');
	L('function M.enable_group(name)');
	L('\tif not _disabled_groups[name] then return end');
	L('\t_disabled_groups[name] = nil');
	L('\tlocal group_mappings = _store_by_group[name]');
	L('\tif not group_mappings then return end');
	L('\tfor _, mapping in ipairs(group_mappings) do');
	L('\t\t_bucket_insert(mapping)');
	L('\tend');
	L('end');
	L();
	L();

	// -- Subsection 4.4: disable_group
	L(subsection('4.4) M.disable_group', '---'));
	L();
	L('--- Removes all mappings in the named group from the live index.');
	L('--- The mappings remain in the full store so enable_group() can restore them.');
	L('--- No-op when the group is already disabled or does not exist.');
	L('--- @param name string');
	L('function M.disable_group(name)');
	L('\tif _disabled_groups[name] then return end');
	L('\t_disabled_groups[name] = true');
	L('\tlocal group_mappings = _store_by_group[name]');
	L('\tif not group_mappings then return end');
	L('\tfor _, mapping in ipairs(group_mappings) do');
	L('\t\t_bucket_remove(mapping)');
	L('\tend');
	L('end');
	L();
	L();

	// -- Subsection 4.5: clear
	L(subsection('4.5) M.clear', '---'));
	L();
	L('--- Removes all mappings and resets the registry to its initial empty state.');
	L('function M.clear()');
	L('\t_mappings_by_tail_char = {}');
	L('\t_store_by_group        = {}');
	L('\t_disabled_groups       = {}');
	L('\t_group_order_map       = {}');
	L('\t_group_order_counter   = 0');
	L('\t_seq                   = 0');
	L('end');
	L();
	L();

	// -- Subsection 4.6: size
	L(subsection('4.6) M.size', '---'));
	L();
	L('--- Returns the total number of active (non-disabled) mappings.');
	L('--- @return number');
	L('function M.size()');
	L('\tlocal n = 0');
	L('\tfor _, bucket in pairs(_mappings_by_tail_char) do');
	L('\t\tn = n + #bucket');
	L('\tend');
	L('\treturn n');
	L('end');
	L();
	L();
	L();

	// -- Section 5: Introspection (bonus, useful for tests)
	L(section('5/ Introspection', '---'));
	L();
	L('--- Returns the raw full store (group → mappings array). Read-only.');
	L('--- Intended for testing and diagnostics — do not mutate.');
	L('--- @return table');
	L('function M.store()');
	L('\treturn _store_by_group');
	L('end');
	L();
	L('--- Returns true when the named group is currently disabled.');
	L('--- @param name string');
	L('--- @return boolean');
	L('function M.is_group_disabled(name)');
	L('\treturn _disabled_groups[name] == true');
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
	console.log(`[codegen:registry:hs] Written → ${rel}`);
})();
