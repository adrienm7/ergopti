// static/ergopti_plus/shared/domain/Registry.spec.js

/**
 * ==============================================================================
 * DOMAIN: Registry
 * DESCRIPTION:
 * Contract and data model for the hotstring/expansion registry. The registry
 * is the single authoritative store of all known trigger→replacement mappings.
 * It supports O(1) lookups by the last typed character (tail-char bucketing),
 * group lifecycle (enable/disable a set of mappings atomically), and
 * monotonic sequencing for stable tiebreaking when multiple triggers match.
 *
 * FEATURES & RATIONALE:
 * 1. Tail-char bucketing: mappings are indexed by their last UTF-8 character so
 *    the hot path only scans candidates that could possibly match. A buffer
 *    ending in "e" never triggers a lookup in the "a" bucket.
 * 2. Group lifecycle: all mappings belong to exactly one named group. Disabling
 *    a group removes its mappings from the live index without deleting them —
 *    re-enabling restores them atomically. This avoids the overhead of
 *    reloading files on every toggle.
 * 3. Longest-first ordering: when multiple triggers share the same tail char,
 *    they are sorted by trigger length descending so the first match is the
 *    longest possible match. Ties are broken by `group_order` then `seq`.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Mapping Data Model =======
// ==================================================
// ==================================================

/**
 * Shape of a Mapping object stored in the registry.
 * All fields are normative — adapters MUST populate them exactly.
 *
 * @typedef {object} Mapping
 * @property {string}   trigger          UTF-8 trigger string (e.g. "btw").
 * @property {string}   repl             Raw replacement with optional tokens
 *           (e.g. "by the way", or "{{first_name}} {{last_name}}").
 * @property {string}   plain_repl       Tokens resolved to literal values (precomputed).
 * @property {boolean}  is_word          True = trigger must be preceded by a word boundary.
 * @property {boolean}  auto             True = fires without a terminator keystroke.
 * @property {number}   seq              Monotonically increasing insertion counter.
 * @property {number}   tlen             UTF-8 codepoint length of `trigger`.
 * @property {number}   trigger_bytes    Byte length of `trigger` (for fast buffer slicing).
 * @property {string}   tail_char        Last UTF-8 codepoint of `trigger` (bucket key).
 * @property {boolean}  has_magic        True = trigger participates in the magic-key cycle.
 * @property {string}   star_base        Magic-key base trigger (trigger without trailing ★).
 * @property {number}   star_base_bytes  Byte length of `star_base`.
 * @property {string}   star_base_tail   Last codepoint of `star_base` (for star bucket).
 * @property {string}   group            Owning group name (e.g. "autocorrect", "personal").
 * @property {number}   group_order      Load-order rank of the owning group (lower = earlier).
 * @property {boolean}  final_result     True = skip further substitution passes after expansion.
 * @property {string|null} color         Hex accent color inherited from the group, or null.
 */




// ==================================================
// ==================================================
// ======= 2/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The Registry domain contract.
 * @type {object}
 */
const portContract = {
	name: "Registry",
	version: "1.0.0",

	/**
	 * add(trigger, replacement, opts) — Register a mapping.
	 *   @param {string} trigger      The hotstring trigger.
	 *   @param {string} replacement  The raw replacement text (may contain tokens).
	 *   @param {object} [opts]
	 *   @param {boolean} [opts.is_word=false]    Word-boundary required.
	 *   @param {boolean} [opts.auto=false]        Auto-fire without terminator.
	 *   @param {boolean} [opts.has_magic=false]   Participates in magic-key cycle.
	 *   @param {boolean} [opts.final_result=false] Skip re-substitution.
	 *   @param {string}  [opts.group="default"]  Owning group name.
	 *   @param {string|null} [opts.color=null]   Hex accent color.
	 *   @returns {Mapping} The created mapping object.
	 *   @error_behavior "log_and_return" on duplicate trigger within the same group.
	 *
	 * mappingsForTail(tailChar) — Return all active mappings with this tail char.
	 *   Sorted: longest trigger first, then group_order ascending, then seq ascending.
	 *   @param {string} tailChar  A single UTF-8 codepoint.
	 *   @returns {Mapping[]}
	 *
	 * enableGroup(name) — Add all mappings in the group back to the live index.
	 *   @param {string} name
	 *   @returns {void}
	 *
	 * disableGroup(name) — Remove all mappings in the group from the live index.
	 *   @param {string} name
	 *   @returns {void}
	 *
	 * clear() — Remove all mappings and reset the registry to empty.
	 *   @returns {void}
	 *
	 * size() — Return total number of active mappings across all groups.
	 *   @returns {number}
	 */
	methods: {
		add:              { arity: 3, required: true },
		mappingsForTail:  { arity: 1, required: true },
		enableGroup:      { arity: 1, required: true },
		disableGroup:     { arity: 1, required: true },
		clear:            { arity: 0, required: true },
		size:             { arity: 0, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 3/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a Registry adapter.
 * @param {object} adapter
 * @returns {string[]} Violations. Empty = compliant.
 */
function validateAdapter(adapter) {
	const violations = [];
	if (!adapter || typeof adapter !== "object") {
		return ["adapter must be a non-null object"];
	}
	for (const [name, spec] of Object.entries(portContract.methods)) {
		if (!spec.required) continue;
		if (typeof adapter[name] !== "function") {
			violations.push(`missing method: ${name}`);
		} else if (adapter[name].length !== spec.arity) {
			violations.push(`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`);
		}
	}
	return violations;
}




// ==================================================
// ==================================================
// ======= 4/ Compliance Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns test vectors for Registry compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "add_and_lookup_by_tail",
			description: "add('btw', 'by the way') is found by mappingsForTail('w').",
			steps: [
				{ call: "add", args: ["btw", "by the way", {}] },
				{
					assert_contains: {
						call: "mappingsForTail", args: ["w"],
						field: "trigger", value: "btw",
					},
				},
			],
		},
		{
			id: "longest_match_first",
			description: "Longer trigger appears before shorter when tail chars match.",
			steps: [
				{ call: "add", args: ["btw",  "by the way", {}] },
				{ call: "add", args: ["btww", "by the way, wow", {}] },
				{
					assert_order: {
						call: "mappingsForTail", args: ["w"],
						expected_first_trigger: "btww",
					},
				},
			],
		},
		{
			id: "disable_group_removes_from_index",
			description: "disableGroup removes its mappings from mappingsForTail.",
			steps: [
				{ call: "add", args: ["btw", "by the way", { group: "test_group" }] },
				{ call: "disableGroup", args: ["test_group"] },
				{
					assert_empty: { call: "mappingsForTail", args: ["w"] },
				},
			],
		},
		{
			id: "enable_group_restores_index",
			description: "enableGroup after disableGroup restores the mappings.",
			steps: [
				{ call: "add", args: ["btw", "by the way", { group: "g" }] },
				{ call: "disableGroup", args: ["g"] },
				{ call: "enableGroup",  args: ["g"] },
				{
					assert_contains: {
						call: "mappingsForTail", args: ["w"],
						field: "trigger", value: "btw",
					},
				},
			],
		},
		{
			id: "clear_empties_registry",
			description: "clear() results in size() == 0.",
			steps: [
				{ call: "add", args: ["a", "alpha", {}] },
				{ call: "add", args: ["b", "beta",  {}] },
				{ call: "clear", args: [] },
				{ assert_equals: { call: "size", args: [], expected: 0 } },
			],
		},
		{
			id: "mapping_fields_populated",
			description: "Mapping object has all required fields with correct types.",
			steps: [
				{
					call:     "add",
					args:     ["hello", "world", { group: "g", is_word: true }],
					capture:  "mapping",
				},
				{
					assert_shape: {
						variable: "mapping",
						shape: {
							trigger:       "string",
							repl:          "string",
							plain_repl:    "string",
							is_word:       "boolean",
							auto:          "boolean",
							seq:           "number",
							tlen:          "number",
							trigger_bytes: "number",
							tail_char:     "string",
							has_magic:     "boolean",
							group:         "string",
							group_order:   "number",
							final_result:  "boolean",
						},
					},
				},
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
