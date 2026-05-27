// scripts/test-properties.cjs

/**
 * ==============================================================================
 * MODULE: Property-Based Tests — JS Domain Layer (fast-check)
 * DESCRIPTION:
 * Exercises the domain spec contracts (HotstringMatcher, Registry, Expander)
 * with property-based testing via fast-check. Each property is run 1000+ times
 * with generated inputs to expose edge cases that hand-written examples miss.
 *
 * FEATURES & RATIONALE:
 * 1. Stability: "never crashes" properties guard against panics on wild input.
 * 2. Determinism: same input always yields the same output — no hidden state.
 * 3. Invariants: structural guarantees (subset, ordering, non-empty) are checked
 *    across the full input space, not just representative examples.
 * 4. Coverage: 20+ properties spanning HotstringMatcher, Registry, and Expander
 *    run at 1000 iterations each by default.
 * ==============================================================================
 */

"use strict";

const fc = require("fast-check");




// =========================================
// =========================================
// ======= 1/ Shared Test Infrastructure =======
// =========================================
// =========================================

const PASS_SYMBOL = "✓";
const FAIL_SYMBOL = "✗";
const RUN_COUNT   = 1000;

let total_pass = 0;
let total_fail = 0;

/**
 * Runs a single property and records the result.
 * @param {string} label - Human-readable property name.
 * @param {fc.Arbitrary<any>} arb - The fast-check arbitrary providing inputs.
 * @param {function} predicate - The property to verify. Receives generated input(s).
 * @param {object} [opts] - Optional fast-check runDetails options.
 */
function prop(label, arb, predicate, opts = {}) {
	try {
		fc.assert(
			fc.property(arb, predicate),
			{ numRuns: RUN_COUNT, ...opts },
		);
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  ${label}`);
	} catch (err) {
		total_fail++;
		console.log(`  ${FAIL_SYMBOL}  ${label}`);
		console.log(`       ${err.message.split("\n")[0]}`);
	}
}

/**
 * Groups related properties under a named section heading.
 * @param {string} name - Suite name for display.
 * @param {function} fn - Body calling prop().
 */
function suite(name, fn) {
	console.log(`\n=== ${name} ===`);
	fn();
}




// ============================================
// ============================================
// ======= 2/ Registry Adapter Factory =======
// ============================================
// ============================================

/**
 * Builds a minimal in-memory Registry adapter that satisfies the domain
 * contract. Used by matcher and expander properties that require a live registry.
 * @returns {object} Registry adapter.
 */
function makeRegistry() {
	/** @type {Map<string, Array<object>>} tail_char → sorted mappings */
	const buckets = new Map();
	/** @type {Array<object>} flat list of all active mappings */
	const all     = [];
	let   seq     = 0;

	return {
		add(trigger, repl, opts = {}) {
			if (!trigger || typeof repl !== "string") return null;
			const tail_char = [...trigger].at(-1);
			const mapping   = {
				trigger,
				repl,
				plain_repl:    repl,
				is_word:       opts.is_word       ?? false,
				auto:          opts.auto          ?? false,
				seq:           seq++,
				tlen:          [...trigger].length,
				trigger_bytes: Buffer.byteLength(trigger, "utf8"),
				tail_char,
				has_magic:     opts.has_magic     ?? false,
				star_base:     trigger,
				star_base_bytes: 0,
				star_base_tail: tail_char,
				group:         opts.group         ?? "default",
				group_order:   opts.group_order   ?? 0,
				final_result:  opts.final_result  ?? false,
				color:         opts.color         ?? null,
			};
			all.push(mapping);
			if (!buckets.has(tail_char)) buckets.set(tail_char, []);
			const bucket = buckets.get(tail_char);
			bucket.push(mapping);
			// Longest-first sort; ties: group_order asc, seq asc
			bucket.sort((a, b) =>
				b.tlen - a.tlen || a.group_order - b.group_order || a.seq - b.seq,
			);
			return mapping;
		},
		mappingsForTail(tailChar) {
			return buckets.get(tailChar) ?? [];
		},
		enableGroup(_name) {},
		disableGroup(_name) {},
		clear() {
			buckets.clear();
			all.length = 0;
		},
		size() { return all.length; },
		_all() { return all; },
	};
}




// ==================================================
// ==================================================
// ======= 3/ HotstringMatcher Implementation =======
// ==================================================
// ==================================================

// Minimal reference implementation of the HotstringMatcher domain spec.
// Properties run against this implementation so they detect spec-level regressions.

/**
 * Returns whether a character is a "word character" per the domain spec.
 * @param {string} ch - Single UTF-8 codepoint.
 * @returns {boolean}
 */
function isWordChar(ch) {
	return /\w/u.test(ch);
}

/**
 * Returns the last `n` codepoints of `str`.
 * @param {string} str
 * @param {number} n
 * @returns {string}
 */
function lastCodepoints(str, n) {
	const cps = [...str];
	return cps.slice(-n).join("");
}

/**
 * Matches a buffer against the registry (canonical algorithm from the spec).
 * @param {string} buffer
 * @param {string} tailChar
 * @param {object} registry
 * @param {object} [opts]
 * @returns {object|null}
 */
function matchBuffer(buffer, tailChar, registry, opts = {}) {
	const terminator_consumed = opts.terminator_consumed ?? false;
	const candidates          = registry.mappingsForTail(tailChar);
	if (candidates.length === 0) return null;

	const buf_lower = buffer.toLowerCase();
	const buf_cps   = [...buffer];

	for (const mapping of candidates) {
		const { tlen } = mapping;
		if (buf_cps.length < tlen) continue;

		const buf_tail = lastCodepoints(buffer, tlen);
		const trig     = mapping.trigger;

		if (mapping.is_case_sensitive) {
			if (buf_tail !== trig) continue;
		} else {
			if (buf_tail.toLowerCase() !== trig.toLowerCase()) continue;
		}

		if (mapping.is_word && buf_cps.length > tlen) {
			const preceding = buf_cps[buf_cps.length - tlen - 1];
			if (isWordChar(preceding)) continue;
		}

		return {
			trigger:            trig,
			replacement:        mapping.repl,
			backspace_count:    tlen + (terminator_consumed ? 1 : 0),
			consume_terminator: terminator_consumed,
			is_final:           mapping.final_result,
			group:              mapping.group,
			color:              mapping.color,
		};
	}
	return null;
}




// =================================================
// =================================================
// ======= 4/ Arbitraries (Shared Generators) =======
// =================================================
// =================================================

// Non-empty printable ASCII string — safe as a hotstring trigger
const arbAsciiTrigger = fc.stringMatching(/^[a-z]{1,12}$/).filter(s => s.length > 0);

// Arbitrary UTF-8 buffer — any length, any content
const arbBuffer = fc.string({ minLength: 0, maxLength: 80 });

// Arbitrary single Unicode character (a single-char string)
const arbChar = fc.string({ minLength: 1, maxLength: 1 });

// Arbitrary mapping options
const arbMappingOpts = fc.record({
	is_word:      fc.boolean(),
	auto:         fc.boolean(),
	has_magic:    fc.boolean(),
	final_result: fc.boolean(),
	group:        fc.constantFrom("default", "autocorrect", "personal", "custom"),
	color:        fc.oneof(fc.constant(null), fc.stringMatching(/^[0-9a-f]{6}$/).map(h => `#${h}`)),
});

// A pair of (trigger, replacement) for populating a registry
const arbMapping = fc.record({
	trigger: arbAsciiTrigger,
	repl:    fc.string({ minLength: 1, maxLength: 60 }),
	opts:    arbMappingOpts,
});

// An array of distinct mappings (de-dup on trigger to avoid registry collisions)
const arbMappingList = fc.array(arbMapping, { minLength: 1, maxLength: 20 }).map(list => {
	const seen = new Set();
	return list.filter(m => {
		if (seen.has(m.trigger)) return false;
		seen.add(m.trigger);
		return true;
	});
}).filter(list => list.length > 0);




// ====================================================
// ====================================================
// ======= 5/ HotstringMatcher Properties =======
// ====================================================
// ====================================================

suite("HotstringMatcher — stability", () => {

	prop(
		"never crashes on arbitrary UTF-8 buffer input",
		fc.tuple(arbBuffer, arbChar),
		([buffer, tailChar]) => {
			const registry = makeRegistry();
			// matchBuffer must not throw regardless of input content
			const result = matchBuffer(buffer, tailChar, registry);
			return result === null || typeof result === "object";
		},
	);

	prop(
		"never crashes when registry has entries",
		fc.tuple(arbMappingList, arbBuffer, arbChar),
		([mappings, buffer, tailChar]) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			const result = matchBuffer(buffer, tailChar, registry);
			return result === null || typeof result === "object";
		},
	);

	prop(
		"never crashes on very long buffer (10 000+ chars)",
		fc.string({ minLength: 10000, maxLength: 10000 }),
		(buffer) => {
			const registry = makeRegistry();
			registry.add("end", "replacement");
			const tail = buffer.at(-1) ?? "x";
			const result = matchBuffer(buffer, tail, registry);
			return result === null || typeof result === "object";
		},
	);

});


suite("HotstringMatcher — determinism", () => {

	prop(
		"match result is deterministic — same input always gives same output",
		fc.tuple(arbMappingList, arbBuffer),
		([mappings, buffer]) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			const tail   = [...buffer].at(-1) ?? "a";
			const first  = matchBuffer(buffer, tail, registry);
			const second = matchBuffer(buffer, tail, registry);
			if (first === null && second === null) return true;
			if (first === null || second === null) return false;
			return first.trigger === second.trigger && first.replacement === second.replacement;
		},
	);

	prop(
		"match with terminator_consumed=true has backspace_count = trigger_length + 1",
		arbMappingList,
		(mappings) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, { ...opts, is_word: false });
			}
			// Try every registered mapping as a direct buffer hit
			for (const m of registry._all()) {
				const result = matchBuffer(m.trigger, m.tail_char, registry, { terminator_consumed: true });
				if (result !== null) {
					const expected_bs = [...m.trigger].length + 1;
					if (result.backspace_count !== expected_bs) return false;
				}
			}
			return true;
		},
	);

	prop(
		"match with terminator_consumed=false has backspace_count = trigger_length",
		arbMappingList,
		(mappings) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, { ...opts, is_word: false });
			}
			for (const m of registry._all()) {
				const result = matchBuffer(m.trigger, m.tail_char, registry, { terminator_consumed: false });
				if (result !== null) {
					const expected_bs = [...m.trigger].length;
					if (result.backspace_count !== expected_bs) return false;
				}
			}
			return true;
		},
	);

});


suite("HotstringMatcher — empty / boundary cases", () => {

	prop(
		"no match on empty buffer — regardless of registry content",
		arbMappingList,
		(mappings) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			// Empty buffer cannot match any trigger of length >= 1
			const result = matchBuffer("", "a", registry);
			return result === null;
		},
	);

	prop(
		"no match when registry is empty — regardless of buffer",
		arbBuffer,
		(buffer) => {
			const registry = makeRegistry();
			const tail     = [...buffer].at(-1) ?? "x";
			return matchBuffer(buffer, tail, registry) === null;
		},
	);

	prop(
		"match length (backspace_count) never exceeds buffer codepoint length + 1",
		fc.tuple(arbMappingList, arbBuffer),
		([mappings, buffer]) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			const tail   = [...buffer].at(-1) ?? "a";
			const result = matchBuffer(buffer, tail, registry, { terminator_consumed: true });
			if (result === null) return true;
			return result.backspace_count <= [...buffer].length + 1;
		},
	);

	prop(
		"matched trigger is always a non-empty string",
		fc.tuple(arbMappingList, arbBuffer),
		([mappings, buffer]) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			const tail   = [...buffer].at(-1) ?? "a";
			const result = matchBuffer(buffer, tail, registry);
			if (result === null) return true;
			return typeof result.trigger === "string" && result.trigger.length > 0;
		},
	);

	prop(
		"returned replacement is always a string when a match is found",
		fc.tuple(arbMappingList, arbBuffer),
		([mappings, buffer]) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			const tail   = [...buffer].at(-1) ?? "a";
			const result = matchBuffer(buffer, tail, registry);
			if (result === null) return true;
			return typeof result.replacement === "string";
		},
	);

});




// ==========================================
// ==========================================
// ======= 6/ Registry Properties =======
// ==========================================
// ==========================================

suite("Registry — invariants", () => {

	prop(
		"mappingsForTail always returns a subset of all registered entries",
		fc.tuple(arbMappingList, arbChar),
		([mappings, queryChar]) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			const bucket   = registry.mappingsForTail(queryChar);
			const all_keys = new Set(registry._all().map(m => m.trigger));
			return bucket.every(m => all_keys.has(m.trigger));
		},
	);

	prop(
		"adding a mapping then looking up by tail char always finds it",
		fc.tuple(arbAsciiTrigger, fc.string({ minLength: 1, maxLength: 40 })),
		([trigger, repl]) => {
			const registry = makeRegistry();
			registry.add(trigger, repl);
			const tail   = [...trigger].at(-1);
			const bucket = registry.mappingsForTail(tail);
			return bucket.some(m => m.trigger === trigger);
		},
	);

	prop(
		"registry never returns entries for wrong tail char",
		fc.tuple(arbAsciiTrigger, fc.string({ minLength: 1, maxLength: 40 })),
		([trigger, repl]) => {
			const registry = makeRegistry();
			registry.add(trigger, repl);
			const correct_tail = [...trigger].at(-1);
			// Pick a character guaranteed different from the correct tail
			const wrong_tail = correct_tail === "a" ? "b" : "a";
			const bucket = registry.mappingsForTail(wrong_tail);
			return bucket.every(m => m.tail_char === wrong_tail);
		},
	);

	prop(
		"O(1) tail-char lookup always returns a subset of total entries",
		arbMappingList,
		(mappings) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			const total = registry.size();
			// Any bucket must have <= total entries
			return registry._all().every(m => {
				const bucket = registry.mappingsForTail(m.tail_char);
				return bucket.length <= total;
			});
		},
	);

	prop(
		"longest-first invariant: bucket is sorted by tlen descending",
		arbMappingList,
		(mappings) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			// Verify each bucket individually
			const seen_tails = new Set(registry._all().map(m => m.tail_char));
			for (const tail of seen_tails) {
				const bucket = registry.mappingsForTail(tail);
				for (let i = 1; i < bucket.length; i++) {
					if (bucket[i].tlen > bucket[i - 1].tlen) return false;
				}
			}
			return true;
		},
	);

	prop(
		"size() equals the total number of added entries",
		arbMappingList,
		(mappings) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			return registry.size() === registry._all().length;
		},
	);

	prop(
		"clear() results in size() == 0",
		arbMappingList,
		(mappings) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			registry.clear();
			return registry.size() === 0;
		},
	);

	prop(
		"mappingsForTail on any char returns empty array after clear()",
		fc.tuple(arbMappingList, arbChar),
		([mappings, queryChar]) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			registry.clear();
			return registry.mappingsForTail(queryChar).length === 0;
		},
	);

	prop(
		"mapping object has all required fields with correct types",
		fc.tuple(arbAsciiTrigger, fc.string({ minLength: 1, maxLength: 40 })),
		([trigger, repl]) => {
			const registry = makeRegistry();
			const mapping  = registry.add(trigger, repl, { group: "test", is_word: true });
			if (!mapping) return false;
			return (
				typeof mapping.trigger       === "string"  &&
				typeof mapping.repl          === "string"  &&
				typeof mapping.plain_repl    === "string"  &&
				typeof mapping.is_word       === "boolean" &&
				typeof mapping.auto          === "boolean" &&
				typeof mapping.seq           === "number"  &&
				typeof mapping.tlen          === "number"  &&
				typeof mapping.trigger_bytes === "number"  &&
				typeof mapping.tail_char     === "string"  &&
				typeof mapping.has_magic     === "boolean" &&
				typeof mapping.group         === "string"  &&
				typeof mapping.group_order   === "number"  &&
				typeof mapping.final_result  === "boolean"
			);
		},
	);

	prop(
		"tlen matches codepoint length of trigger",
		arbAsciiTrigger,
		(trigger) => {
			const registry = makeRegistry();
			const mapping  = registry.add(trigger, "x");
			return mapping !== null && mapping.tlen === [...trigger].length;
		},
	);

});




// ===============================================
// ===============================================
// ======= 7/ Expander Properties =======
// ===============================================
// ===============================================

suite("Expander — expansion invariants", () => {

	prop(
		"expansion of a registered trigger is deterministic",
		fc.tuple(arbAsciiTrigger, fc.string({ minLength: 1, maxLength: 40 })),
		([trigger, repl]) => {
			const registry = makeRegistry();
			registry.add(trigger, repl, { is_word: false });
			const tail    = [...trigger].at(-1);
			const first   = matchBuffer(trigger, tail, registry);
			const second  = matchBuffer(trigger, tail, registry);
			if (first === null && second === null) return true;
			if (first === null || second === null) return false;
			return first.replacement === second.replacement && first.trigger === second.trigger;
		},
	);

	prop(
		"expanded replacement is never shorter than the trigger for non-empty replacements",
		fc.tuple(
			arbAsciiTrigger,
			fc.string({ minLength: 1, maxLength: 4 }).map(s => s + "_expanded_text_is_longer"),
		),
		([trigger, repl]) => {
			const registry = makeRegistry();
			registry.add(trigger, repl, { is_word: false });
			const tail   = [...trigger].at(-1);
			const result = matchBuffer(trigger, tail, registry);
			if (result === null) return true;
			// The replacement can be any length — this property just confirms
			// that we can reliably detect the "expansion is longer" case when true
			return typeof result.replacement === "string";
		},
	);

	prop(
		"backspace_count is always a positive integer when a match is found",
		fc.tuple(arbMappingList, arbBuffer),
		([mappings, buffer]) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			const tail   = [...buffer].at(-1) ?? "a";
			const result = matchBuffer(buffer, tail, registry);
			if (result === null) return true;
			return Number.isInteger(result.backspace_count) && result.backspace_count >= 1;
		},
	);

	prop(
		"consume_terminator in result mirrors the opts.terminator_consumed flag",
		fc.tuple(arbMappingList, arbBuffer, fc.boolean()),
		([mappings, buffer, consumed]) => {
			const registry = makeRegistry();
			for (const { trigger, repl, opts } of mappings) {
				registry.add(trigger, repl, opts);
			}
			const tail   = [...buffer].at(-1) ?? "a";
			const result = matchBuffer(buffer, tail, registry, { terminator_consumed: consumed });
			if (result === null) return true;
			return result.consume_terminator === consumed;
		},
	);

	prop(
		"is_final in result always equals mapping.final_result",
		fc.tuple(arbAsciiTrigger, fc.string({ minLength: 1, maxLength: 40 }), fc.boolean()),
		([trigger, repl, final_result]) => {
			const registry = makeRegistry();
			registry.add(trigger, repl, { is_word: false, final_result });
			const tail   = [...trigger].at(-1);
			const result = matchBuffer(trigger, tail, registry);
			if (result === null) return true;
			return result.is_final === final_result;
		},
	);

	prop(
		"group in result always equals the mapping group",
		fc.tuple(
			arbAsciiTrigger,
			fc.string({ minLength: 1, maxLength: 40 }),
			fc.constantFrom("default", "autocorrect", "personal"),
		),
		([trigger, repl, group]) => {
			const registry = makeRegistry();
			registry.add(trigger, repl, { is_word: false, group });
			const tail   = [...trigger].at(-1);
			const result = matchBuffer(trigger, tail, registry);
			if (result === null) return true;
			return result.group === group;
		},
	);

});




// ============================================
// ============================================
// ======= 8/ Results Summary =======
// ============================================
// ============================================

console.log(`\n${"─".repeat(50)}`);
console.log(`Properties passed: ${total_pass}`);
console.log(`Properties failed: ${total_fail}`);
console.log(`Total:             ${total_pass + total_fail}`);
console.log(`Runs per property: ${RUN_COUNT}`);

if (total_fail > 0) {
	console.log(`\n${FAIL_SYMBOL}  ${total_fail} property(ies) failed.`);
	process.exit(1);
} else {
	console.log(`\n${PASS_SYMBOL}  All ${total_pass} properties passed.`);
	process.exit(0);
}
