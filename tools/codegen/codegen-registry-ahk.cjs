// tools/codegen/codegen-registry-ahk.cjs

/**
 * ==============================================================================
 * MODULE: Registry AHK Codegen
 * DESCRIPTION:
 * Generates `static/ergopti_plus/windows/_generated/registry.ahk` from the
 * Registry domain contract defined in
 * `static/ergopti_plus/shared/domain/Registry.spec.js`.
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: the generated file derives its class contract
 *    directly from the spec so structural drift between the spec and the AHK
 *    adapter is impossible.
 * 2. AHK v2 idioms: uses Map for associative data, proper class syntax,
 *    and SubStr-based tail extraction compatible with AHK's UTF-16 string model.
 * 3. Encoding safety: output is written as UTF-8 BOM + CRLF, which is required
 *    by the AHK v2 parser (silent abort risk on mismatch).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { sharedRel } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '../..');
const OUT_PATH = path.resolve(ROOT, 'static/ergopti_plus/windows/_generated/registry.ahk');
const SPEC_REL = sharedRel('domain/Registry.spec.js');

// ==================================================
// ==================================================
// ======= 1/ AHK Source Builder =======
// ==================================================
// ==================================================

/**
 * Builds the full AHK source for the Registry class.
 * @returns {string} AHK v2 source text, newlines are bare LF (normalised later).
 */
function buildAhkSource() {
	// Ruler width constants — section banners must be perfectly aligned
	const SECTION_INNER = '======= {title} =======';
	const SUBSECT_INNER = '===== {title} =====';

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

	const lines = [];

	// File path header (first line)
	lines.push('; static/ergopti_plus/windows/_generated/registry.ahk');
	lines.push('');

	// Auto-generated banner
	lines.push('; ==========================================');
	lines.push('; AUTO-GENERATED — do not edit manually');
	lines.push(`; Source: ${SPEC_REL}`);
	lines.push('; Run: npm run codegen:registry');
	lines.push('; ==========================================');
	lines.push('');

	// Module-level docstring
	lines.push('; ==============================================================================');
	lines.push('; MODULE: Registry');
	lines.push('; DESCRIPTION:');
	lines.push('; AHK v2 implementation of the Registry domain contract. Stores all known');
	lines.push('; trigger->replacement mappings, indexes them by tail character for O(1)');
	lines.push('; candidate lookup, and supports atomic group enable/disable toggling.');
	lines.push(';');
	lines.push('; FEATURES & RATIONALE:');
	lines.push('; 1. Tail-char bucketing: mappings indexed by last UTF-16 code unit so the');
	lines.push(';    hot path only scans candidates whose tail matches the last typed char.');
	lines.push('; 2. Group lifecycle: disabling a group removes entries from the live index');
	lines.push(';    without deleting them; re-enabling atomically restores them.');
	lines.push('; 3. Longest-first ordering: Sort() ensures the first hit is always the');
	lines.push(';    longest possible trigger. Ties broken by group_order then seq.');
	lines.push('; ==============================================================================');
	lines.push('');
	lines.push('#Requires AutoHotkey v2.0');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');
	lines.push('');

	// Section 1 — Constants
	lines.push(sectionBanner('1/ Constants'));
	lines.push('');

	// Sentinel used as default group name
	lines.push('; Default group name assigned when the caller omits opts.group.');
	lines.push('global REGISTRY_DEFAULT_GROUP := "default"');
	lines.push('');
	lines.push('; Initial capacity hint for per-tail-char bucket arrays (no hard limit).');
	lines.push('global REGISTRY_BUCKET_INIT_CAPACITY := 8');
	lines.push('');
	lines.push('');
	lines.push('');

	// Section 2 — Registry Class
	lines.push(sectionBanner('2/ Registry Class'));
	lines.push('');

	lines.push('class Registry {');
	lines.push('');

	// -------------------------------------------------------
	// 2.1) Instance state
	// -------------------------------------------------------
	lines.push('\t' + subsectionBanner('2.1) Instance State').replace(/\n/g, '\n\t'));
	lines.push('');
	lines.push('\t; _mappings_by_tail_char : Map<string, Array<Mapping>>');
	lines.push('\t; Live index — only contains mappings whose group is enabled.');
	lines.push('\t_mappings_by_tail_char := Map()');
	lines.push('');
	lines.push('\t; _all_mappings : Array<Mapping>');
	lines.push('\t; Master store — every mapping regardless of group state.');
	lines.push('\t_all_mappings := []');
	lines.push('');
	lines.push('\t; _disabled_groups : Map<string, true>');
	lines.push('\t; Names of currently disabled groups for O(1) membership test.');
	lines.push('\t_disabled_groups := Map()');
	lines.push('');
	lines.push('\t; _group_order_map : Map<string, number>');
	lines.push('\t; Tracks the load-order rank of each group (insertion order).');
	lines.push('\t_group_order_map := Map()');
	lines.push('');
	lines.push('\t; _seq : integer');
	lines.push('\t; Monotonically increasing insertion counter for stable tiebreaking.');
	lines.push('\t_seq := 0');
	lines.push('');
	lines.push('');
	lines.push('');

	// -------------------------------------------------------
	// 2.2) Add
	// -------------------------------------------------------
	lines.push('\t' + subsectionBanner('2.2) Add').replace(/\n/g, '\n\t'));
	lines.push('');
	lines.push('\t; Registers a trigger->replacement mapping.');
	lines.push('\t; Duplicate triggers within the same group are logged and skipped.');
	lines.push('\t;');
	lines.push('\t; Param trigger     - UTF-16 trigger string.');
	lines.push('\t; Param repl        - Raw replacement (may contain tokens).');
	lines.push('\t; Param opts        - Optional Map with keys: is_word, auto, has_magic,');
	lines.push('\t;                     final_result, group, color, group_order.');
	lines.push('\t; Returns Mapping   - The created Mapping object, or false on duplicate.');
	lines.push('\tAdd(trigger, repl, opts := Map()) {');
	lines.push('\t\t; Resolve options with safe defaults');
	lines.push(
		'\t\tlocal group       := opts.Has("group")        ? opts["group"]        : REGISTRY_DEFAULT_GROUP'
	);
	lines.push('\t\tlocal is_word     := opts.Has("is_word")      ? opts["is_word"]      : false');
	lines.push('\t\tlocal auto        := opts.Has("auto")         ? opts["auto"]         : false');
	lines.push('\t\tlocal has_magic   := opts.Has("has_magic")    ? opts["has_magic"]    : false');
	lines.push('\t\tlocal final_res   := opts.Has("final_result") ? opts["final_result"] : false');
	lines.push('\t\tlocal color       := opts.Has("color")        ? opts["color"]        : ""');
	lines.push('');
	lines.push('\t\t; Assign group_order — first time a group name is seen it gets the next rank');
	lines.push('\t\tif (!this._group_order_map.Has(group)) {');
	lines.push('\t\t\tthis._group_order_map[group] := this._group_order_map.Count');
	lines.push('\t\t}');
	lines.push('\t\tlocal group_order := this._group_order_map[group]');
	lines.push('');
	lines.push('\t\t; Guard: detect duplicate trigger within the same group');
	lines.push('\t\tfor existing in this._all_mappings {');
	lines.push('\t\t\tif (existing.trigger = trigger && existing.group = group) {');
	lines.push(
		'\t\t\t\tLoggerWarn("registry", "Add: duplicate trigger \'{1}\' in group \'{2}\' — skipped.", trigger, group)'
	);
	lines.push('\t\t\t\treturn false');
	lines.push('\t\t\t}');
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\t; Compute derived fields');
	lines.push('\t\tlocal tlen             := StrLen(trigger)');
	lines.push('\t\t; AHK strings are UTF-16; byte length = char count * 2');
	lines.push('\t\tlocal trigger_bytes    := tlen * 2');
	lines.push('\t\t; Tail char = last UTF-16 code unit (SubStr with negative offset)');
	lines.push('\t\tlocal tail_char        := SubStr(trigger, -1)');
	lines.push('\t\t; Magic-key fields — star_base is trigger without trailing magic char');
	lines.push('\t\tlocal star_base        := has_magic ? SubStr(trigger, 1, tlen - 1) : trigger');
	lines.push('\t\tlocal star_base_len    := StrLen(star_base)');
	lines.push('\t\tlocal star_base_bytes  := star_base_len * 2');
	lines.push('\t\tlocal star_base_tail   := star_base_len > 0 ? SubStr(star_base, -1) : ""');
	lines.push('\t\t; plain_repl = repl with tokens resolved to literal text (precomputed)');
	lines.push('\t\t; For now plain_repl mirrors repl; a token resolver can inject here later');
	lines.push('\t\tlocal plain_repl       := repl');
	lines.push('');
	lines.push('\t\tthis._seq += 1');
	lines.push('');
	lines.push('\t\tlocal mapping := Map(');
	lines.push('\t\t\t"trigger",         trigger,');
	lines.push('\t\t\t"repl",            repl,');
	lines.push('\t\t\t"plain_repl",      plain_repl,');
	lines.push('\t\t\t"is_word",         is_word,');
	lines.push('\t\t\t"auto",            auto,');
	lines.push('\t\t\t"seq",             this._seq,');
	lines.push('\t\t\t"tlen",            tlen,');
	lines.push('\t\t\t"trigger_bytes",   trigger_bytes,');
	lines.push('\t\t\t"tail_char",       tail_char,');
	lines.push('\t\t\t"has_magic",       has_magic,');
	lines.push('\t\t\t"star_base",       star_base,');
	lines.push('\t\t\t"star_base_bytes", star_base_bytes,');
	lines.push('\t\t\t"star_base_tail",  star_base_tail,');
	lines.push('\t\t\t"group",           group,');
	lines.push('\t\t\t"group_order",     group_order,');
	lines.push('\t\t\t"final_result",    final_res,');
	lines.push('\t\t\t"color",           color');
	lines.push('\t\t)');
	lines.push('');
	lines.push('\t\t; Persist in master store');
	lines.push('\t\tthis._all_mappings.Push(mapping)');
	lines.push('');
	lines.push('\t\t; Add to live index only when the group is active');
	lines.push('\t\tif (!this._disabled_groups.Has(group)) {');
	lines.push('\t\t\tthis._IndexMapping(mapping)');
	lines.push('\t\t}');
	lines.push('');
	lines.push('\t\treturn mapping');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// -------------------------------------------------------
	// 2.3) MappingsForTail
	// -------------------------------------------------------
	lines.push('\t' + subsectionBanner('2.3) MappingsForTail').replace(/\n/g, '\n\t'));
	lines.push('');
	lines.push('\t; Returns all active mappings whose tail char equals tailChar.');
	lines.push('\t; Result is sorted: longest trigger first, then group_order, then seq.');
	lines.push('\t;');
	lines.push('\t; Param tailChar - A single UTF-16 code unit (the last typed character).');
	lines.push('\t; Returns Array  - Sorted array of Mapping objects.');
	lines.push('\tMappingsForTail(tailChar) {');
	lines.push('\t\tif (!this._mappings_by_tail_char.Has(tailChar)) {');
	lines.push('\t\t\treturn []');
	lines.push('\t\t}');
	lines.push('\t\treturn this._mappings_by_tail_char[tailChar]');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// -------------------------------------------------------
	// 2.4) EnableGroup / DisableGroup
	// -------------------------------------------------------
	lines.push('\t' + subsectionBanner('2.4) EnableGroup / DisableGroup').replace(/\n/g, '\n\t'));
	lines.push('');
	lines.push('\t; Restores all mappings in `name` to the live index.');
	lines.push('\t; No-op when the group is already enabled.');
	lines.push('\t;');
	lines.push('\t; Param name - Group name string.');
	lines.push('\tEnableGroup(name) {');
	lines.push('\t\tif (!this._disabled_groups.Has(name)) {');
	lines.push('\t\t\treturn ; Already enabled');
	lines.push('\t\t}');
	lines.push('\t\tthis._disabled_groups.Delete(name)');
	lines.push('\t\t; Re-index every mapping that belongs to this group');
	lines.push('\t\tfor m in this._all_mappings {');
	lines.push('\t\t\tif (m["group"] = name) {');
	lines.push('\t\t\t\tthis._IndexMapping(m)');
	lines.push('\t\t\t}');
	lines.push('\t\t}');
	lines.push('\t}');
	lines.push('');
	lines.push('\t; Removes all mappings in `name` from the live index.');
	lines.push('\t; No-op when the group is already disabled.');
	lines.push('\t;');
	lines.push('\t; Param name - Group name string.');
	lines.push('\tDisableGroup(name) {');
	lines.push('\t\tif (this._disabled_groups.Has(name)) {');
	lines.push('\t\t\treturn ; Already disabled');
	lines.push('\t\t}');
	lines.push('\t\tthis._disabled_groups[name] := true');
	lines.push('\t\t; Rebuild all buckets that contain at least one mapping from this group');
	lines.push('\t\tthis._RebuildIndex()');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// -------------------------------------------------------
	// 2.5) Clear / Size
	// -------------------------------------------------------
	lines.push('\t' + subsectionBanner('2.5) Clear / Size').replace(/\n/g, '\n\t'));
	lines.push('');
	lines.push('\t; Removes all mappings and resets the registry to the empty state.');
	lines.push('\tClear() {');
	lines.push('\t\tthis._mappings_by_tail_char := Map()');
	lines.push('\t\tthis._all_mappings          := []');
	lines.push('\t\tthis._disabled_groups       := Map()');
	lines.push('\t\tthis._group_order_map       := Map()');
	lines.push('\t\tthis._seq                   := 0');
	lines.push('\t}');
	lines.push('');
	lines.push('\t; Returns the total number of active mappings across all enabled groups.');
	lines.push('\t; Returns integer.');
	lines.push('\tSize() {');
	lines.push('\t\tlocal total := 0');
	lines.push('\t\tfor _, bucket in this._mappings_by_tail_char {');
	lines.push('\t\t\ttotal += bucket.Length');
	lines.push('\t\t}');
	lines.push('\t\treturn total');
	lines.push('\t}');
	lines.push('');
	lines.push('');
	lines.push('');

	// -------------------------------------------------------
	// 2.6) Private helpers
	// -------------------------------------------------------
	lines.push('\t' + subsectionBanner('2.6) Private Helpers').replace(/\n/g, '\n\t'));
	lines.push('');
	lines.push('\t; Inserts a single mapping into the live tail-char index and re-sorts its bucket.');
	lines.push('\t;');
	lines.push('\t; Param mapping - A Mapping Map object.');
	lines.push('\t_IndexMapping(mapping) {');
	lines.push('\t\tlocal tc := mapping["tail_char"]');
	lines.push('\t\tif (!this._mappings_by_tail_char.Has(tc)) {');
	lines.push('\t\t\tthis._mappings_by_tail_char[tc] := []');
	lines.push('\t\t}');
	lines.push('\t\tthis._mappings_by_tail_char[tc].Push(mapping)');
	lines.push('\t\tthis._SortBucket(tc)');
	lines.push('\t}');
	lines.push('');
	lines.push('\t; Rebuilds the entire live index from _all_mappings, respecting disabled groups.');
	lines.push('\t; Called after DisableGroup to flush entries in O(n) rather than per-bucket.');
	lines.push('\t_RebuildIndex() {');
	lines.push('\t\tthis._mappings_by_tail_char := Map()');
	lines.push('\t\tfor m in this._all_mappings {');
	lines.push('\t\t\tif (!this._disabled_groups.Has(m["group"])) {');
	lines.push('\t\t\t\tthis._IndexMapping(m)');
	lines.push('\t\t\t}');
	lines.push('\t\t}');
	lines.push('\t}');
	lines.push('');
	lines.push(
		'\t; Sorts a single bucket in-place: longest trigger first, then group_order, then seq.'
	);
	lines.push('\t; Uses a simple insertion sort — buckets are small (< 20 entries typical).');
	lines.push('\t;');
	lines.push('\t; Param tc - Tail char key.');
	lines.push('\t_SortBucket(tc) {');
	lines.push('\t\tlocal arr := this._mappings_by_tail_char[tc]');
	lines.push('\t\tlocal n   := arr.Length');
	lines.push('\t\tif (n <= 1) {');
	lines.push('\t\t\treturn');
	lines.push('\t\t}');
	lines.push('\t\t; Insertion sort — stable and avoids closure overhead of array sort callbacks');
	lines.push('\t\tlocal i := 2');
	lines.push('\t\twhile (i <= n) {');
	lines.push('\t\t\tlocal key := arr[i]');
	lines.push('\t\t\tlocal j   := i - 1');
	lines.push('\t\t\twhile (j >= 1 && this._ComesBefore(key, arr[j])) {');
	lines.push('\t\t\t\tarr[j + 1] := arr[j]');
	lines.push('\t\t\t\tj -= 1');
	lines.push('\t\t\t}');
	lines.push('\t\t\tarr[j + 1] := key');
	lines.push('\t\t\ti += 1');
	lines.push('\t\t}');
	lines.push('\t}');
	lines.push('');
	lines.push('\t; Returns true if mapping `a` should sort before mapping `b`.');
	lines.push('\t; Order: longest tlen descending, group_order ascending, seq ascending.');
	lines.push('\t;');
	lines.push('\t; Param a - Mapping Map object.');
	lines.push('\t; Param b - Mapping Map object.');
	lines.push('\t; Returns boolean.');
	lines.push('\t_ComesBefore(a, b) {');
	lines.push('\t\tif (a["tlen"] != b["tlen"]) {');
	lines.push('\t\t\treturn a["tlen"] > b["tlen"] ; Longest first');
	lines.push('\t\t}');
	lines.push('\t\tif (a["group_order"] != b["group_order"]) {');
	lines.push('\t\t\treturn a["group_order"] < b["group_order"] ; Earlier group first');
	lines.push('\t\t}');
	lines.push('\t\treturn a["seq"] < b["seq"] ; Earlier insertion first');
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
 * @param {string} outPath    Absolute path to the output file.
 * @param {string} content    Source text with bare LF newlines.
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
	console.log('codegen:registry — generating Registry AHK adapter…');

	const source = buildAhkSource();
	writeWithBomCrlf(OUT_PATH, source);

	const relOut = path.relative(ROOT, OUT_PATH);
	console.log(`  Written: ${relOut}`);
	console.log('codegen:registry — done.');
}

main();
