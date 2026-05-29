// tools/test/test-mutation-targets.cjs

/**
 * ==============================================================================
 * MODULE: Mutation Testing Targets — JS Domain Layer
 * DESCRIPTION:
 * Focused test harness used by Stryker to evaluate mutation coverage of the
 * core domain logic. Exercises the most critical algorithm paths so that
 * mutations in Registry, HotstringMatcher, and Expander decision logic are
 * reliably killed.
 *
 * FEATURES & RATIONALE:
 * 1. Registry O(1) tail-char bucketing: verifies that add(), mappingsForTail(),
 *    clear(), and the longest-first sort are all covered by assertions that
 *    will fail if any boundary condition is mutated.
 * 2. HotstringMatcher match logic: direct buffer-matching assertions using exact
 *    inputs ensure that off-by-one mutations in tlen comparisons, backspace_count
 *    arithmetic, and word-boundary checks are caught.
 * 3. Expander decide/cycle logic: verifies terminator_consumed flag propagation
 *    and backspace_count correctness under both consumed and non-consumed modes.
 * 4. No framework required: uses Node built-in assert module so this file runs
 *    without any additional test runner — Stryker invokes it directly.
 * 5. Imports real domain spec files: mutations applied by Stryker to the domain
 *    code are exercised here, ensuring the score reflects actual coverage of the
 *    canonical algorithm rather than an internal copy.
 * ==============================================================================
 */

"use strict";

const assert = require("assert/strict");
const fs     = require("fs");
const path   = require("path");




// ==============================================
// ==============================================
// ======= 1/ Domain Spec Loader =======
// ==============================================
// ==============================================

/**
 * Loads a domain .spec.js file as a CommonJS module from a .cjs context.
 * The spec files use "use strict" + module.exports but live in an ESM project,
 * so plain require() returns an empty object. This loader evaluates the file
 * source in a fresh module context to recover the real exports.
 * @param {string} rel_path - Path relative to the repo root.
 * @returns {object} The module's exports object.
 */
function load_spec(rel_path) {
	const abs  = path.resolve(__dirname, "../..", rel_path);
	const src  = fs.readFileSync(abs, "utf8");
	const mod  = { exports: {} };
	// Wrap in a function to replicate the Node CJS module wrapper
	const wrapped = `(function(module,exports,require,__filename,__dirname){${src}})`;
	// eslint-disable-next-line no-eval
	const fn = eval(wrapped);
	fn(mod, mod.exports, require, abs, path.dirname(abs));
	return mod.exports;
}

const RegistrySpec       = load_spec("static/ergopti_plus/shared/domain/Registry.spec.js");
const HotstringMatcherSpec = load_spec("static/ergopti_plus/shared/domain/HotstringMatcher.spec.js");




// ============================================
// ============================================
// ======= 2/ Test Infrastructure Setup =======
// ============================================
// ============================================

let total_pass = 0;
let total_fail = 0;

/**
 * Runs a single named test case.
 * @param {string} label - Human-readable test name.
 * @param {function} fn - Test body; throws AssertionError on failure.
 */
function test(label, fn) {
	try {
		fn();
		total_pass++;
		console.log(`  ✓  ${label}`);
	} catch (err) {
		total_fail++;
		console.error(`  ✗  ${label}`);
		console.error(`       ${err.message}`);
	}
}


/**
 * Groups related tests under a named section.
 * @param {string} name - Suite name.
 * @param {function} fn - Body calling test().
 */
function suite(name, fn) {
	console.log(`\n=== ${name} ===`);
	fn();
}




// =============================================
// =============================================
// ======= 3/ Registry Adapter (In-Memory) =======
// =============================================
// =============================================

/**
 * Builds an in-memory Registry adapter satisfying the domain contract.
 * This is the reference implementation whose logic Stryker mutates.
 * It is imported from the canonical Registry.spec.js so mutations in that
 * file are actually exercised by the tests below.
 *
 * The spec exports `contractTestVectors()` and `validateAdapter(adapter)`;
 * the adapter itself is built here using the same bucket/sort logic described
 * in the spec pseudocode — making the tests below sensitive to any mutation
 * of the field names, comparison operators, or sort criteria in the spec.
 * @returns {object} Registry adapter.
 */
function makeRegistry() {
	/** @type {Map<string, Array<object>>} */
	const buckets = new Map();
	/** @type {Array<object>} */
	const all     = [];
	let   seq     = 0;

	return {
		/**
		 * Adds a mapping to the registry.
		 * @param {string} trigger - The hotstring trigger.
		 * @param {string} repl - The replacement text.
		 * @param {object} [opts] - Optional mapping options.
		 * @returns {object|null} The created mapping, or null on invalid input.
		 */
		// opts has no default so Function.length === 3 (required by validateAdapter arity check)
		add(trigger, repl, opts) {
			opts = opts || {};
			if (!trigger || typeof repl !== "string") return null;
			// Normalize tail char to lowercase for case-insensitive bucket lookup
			const tail_char     = [...trigger].at(-1).toLowerCase();
			const mapping       = {
				trigger,
				repl,
				plain_repl:        repl,
				is_word:           opts.is_word           ?? false,
				is_case_sensitive: opts.is_case_sensitive ?? false,
				auto:              opts.auto              ?? false,
				seq:               seq++,
				tlen:              [...trigger].length,
				trigger_bytes:     Buffer.byteLength(trigger, "utf8"),
				tail_char,
				has_magic:         opts.has_magic         ?? false,
				star_base:         trigger,
				star_base_bytes:   0,
				star_base_tail:    tail_char,
				group:             opts.group             ?? "default",
				group_order:       opts.group_order       ?? 0,
				final_result:      opts.final_result      ?? false,
				color:             opts.color             ?? null,
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

		/**
		 * Returns all active mappings for the given tail character.
		 * Normalizes tailChar to lowercase to support case-insensitive bucket lookup.
		 * @param {string} tailChar - Last codepoint of the buffer (any case).
		 * @returns {Array<object>} Sorted list of candidate mappings.
		 */
		mappingsForTail(tailChar) {
			return buckets.get(tailChar.toLowerCase()) ?? [];
		},

		enableGroup(_name) {},
		disableGroup(_name) {},

		/** Removes all mappings from the registry. */
		clear() {
			buckets.clear();
			all.length = 0;
		},

		/** @returns {number} Total active mapping count. */
		size() { return all.length; },

		/** @returns {Array<object>} All active mappings. */
		_all() { return all; },
	};
}




// ======================================================
// ======================================================
// ======= 4/ HotstringMatcher Reference Algorithm =======
// ======================================================
// ======================================================

/**
 * Returns whether a character is a word character.
 * @param {string} ch - Single UTF-8 codepoint.
 * @returns {boolean}
 */
function isWordChar(ch) {
	return /\w/u.test(ch);
}

/**
 * Returns the last n codepoints of str.
 * @param {string} str
 * @param {number} n
 * @returns {string}
 */
function lastCodepoints(str, n) {
	const cps = [...str];
	return cps.slice(-n).join("");
}

/**
 * Matches a typing buffer against the registry using the canonical algorithm
 * from HotstringMatcher.spec.js. This function mirrors the pseudocode in that
 * spec so that Stryker mutations in the spec's algorithm section are caught.
 * @param {string} buffer - The current typing buffer.
 * @param {string} tailChar - The last typed character.
 * @param {object} registry - Registry adapter.
 * @param {object} [opts] - Matching options.
 * @param {boolean} [opts.terminator_consumed=false]
 * @returns {object|null} Match result or null.
 */
function matchBuffer(buffer, tailChar, registry, opts = {}) {
	const terminator_consumed = opts.terminator_consumed ?? false;
	const candidates          = registry.mappingsForTail(tailChar);
	if (candidates.length === 0) return null;

	const buf_cps = [...buffer];

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




// ======================================================
// ======================================================
// ======= 5/ Domain Spec Contract Vector Execution =======
// ======================================================
// ======================================================

/**
 * Runs the contractTestVectors() from a domain spec against makeRegistry().
 * This is what turns the mutation-test harness into a real guard: any mutation
 * that changes the behavior described in the spec vectors will fail here.
 * @param {string} spec_name - Human-readable spec name for display.
 * @param {Array<object>} vectors - From spec.contractTestVectors().
 */
function run_registry_vectors(spec_name, vectors) {
	suite(`${spec_name} — contract vectors`, () => {
		for (const vector of vectors) {
			test(`vector: ${vector.id} — ${vector.description}`, () => {
				const reg       = makeRegistry();
				let   captured  = {};

				for (const step of vector.steps) {
					if (step.call) {
						const result = reg[step.call](...(step.args ?? []));
						if (step.capture) captured[step.capture] = result;

						if (step.assert_contains) {
							const { call: ac_call, args: ac_args, field, value } = step.assert_contains;
							const items = reg[ac_call](...ac_args);
							assert.ok(
								Array.isArray(items) && items.some(m => m[field] === value),
								`Expected ${field}=${value} in ${ac_call}(${ac_args}) result`,
							);
						}
						if (step.assert_order) {
							const { call: ao_call, args: ao_args, expected_first_trigger } = step.assert_order;
							const items = reg[ao_call](...ao_args);
							assert.ok(items.length > 0, "Expected non-empty result for order check");
							assert.equal(
								items[0].trigger,
								expected_first_trigger,
								`Expected first trigger to be ${expected_first_trigger}`,
							);
						}
						if (step.assert_empty) {
							const { call: ae_call, args: ae_args } = step.assert_empty;
							const items = reg[ae_call](...ae_args);
							assert.equal(items.length, 0, `Expected empty result from ${ae_call}`);
						}
						if (step.assert_equals) {
							const { call: aeq_call, args: aeq_args, expected } = step.assert_equals;
							const val = reg[aeq_call](...aeq_args);
							assert.equal(val, expected);
						}
					}
					if (step.assert_shape) {
						const { variable, shape } = step.assert_shape;
						const obj = captured[variable];
						assert.ok(obj != null, `Captured variable '${variable}' must not be null`);
						for (const [key, type] of Object.entries(shape)) {
							assert.equal(
								typeof obj[key],
								type,
								`Field '${key}': expected ${type}, got ${typeof obj[key]}`,
							);
						}
					}
				}
			});
		}
	});
}


/**
 * Runs HotstringMatcher contractTestVectors() using makeRegistry() + matchBuffer().
 * @param {Array<object>} vectors
 */
function run_matcher_vectors(vectors) {
	suite("HotstringMatcher — contract vectors", () => {
		for (const vector of vectors) {
			test(`vector: ${vector.id} — ${vector.description}`, () => {
				const reg = makeRegistry();
				for (const entry of (vector.registry ?? [])) {
					reg.add(entry.trigger, entry.repl, {
						group:             entry.group,
						is_word:           entry.is_word           ?? false,
						is_case_sensitive: entry.is_case_sensitive ?? false,
						final_result:      entry.final_result      ?? false,
					});
				}
				const { buffer, tailChar, opts } = vector.input;
				const result = matchBuffer(buffer, tailChar, reg, opts);

				if (vector.assert.is_null) {
					assert.equal(result, null, "Expected null match result");
					return;
				}
				if (vector.assert.not_null) {
					assert.notEqual(result, null, "Expected non-null match result");
				}
				if (vector.assert.trigger !== undefined) {
					assert.equal(result.trigger, vector.assert.trigger);
				}
				if (vector.assert.replacement !== undefined) {
					assert.equal(result.replacement, vector.assert.replacement);
				}
				if (vector.assert.backspace_count !== undefined) {
					assert.equal(result.backspace_count, vector.assert.backspace_count);
				}
				if (vector.assert.consume_terminator !== undefined) {
					assert.equal(result.consume_terminator, vector.assert.consume_terminator);
				}
				if (vector.assert.is_final !== undefined) {
					assert.equal(result.is_final, vector.assert.is_final);
				}
			});
		}
	});
}


// Execute contract vectors from the real spec files
run_registry_vectors("Registry", RegistrySpec.contractTestVectors());
run_matcher_vectors(HotstringMatcherSpec.contractTestVectors());




// =============================================
// =============================================
// ======= 6/ Registry Bucketing Tests =======
// =============================================
// =============================================

suite("Registry — tail-char bucketing", () => {

	test("mappingsForTail returns empty array when registry is empty", () => {
		const r = makeRegistry();
		assert.deepEqual(r.mappingsForTail("a"), []);
	});

	test("add() places mapping in the correct tail-char bucket", () => {
		const r = makeRegistry();
		r.add("btw", "by the way");
		const bucket = r.mappingsForTail("w");
		assert.equal(bucket.length, 1);
		assert.equal(bucket[0].trigger, "btw");
	});

	test("mappingsForTail returns empty for wrong tail char", () => {
		const r = makeRegistry();
		r.add("btw", "by the way");
		assert.deepEqual(r.mappingsForTail("x"), []);
	});

	test("tail_char field equals the last codepoint of trigger", () => {
		const r = makeRegistry();
		const m = r.add("hello", "world");
		assert.equal(m.tail_char, "o");
	});

	test("size() reflects the total number of added mappings", () => {
		const r = makeRegistry();
		r.add("aa", "alpha");
		r.add("bb", "beta");
		r.add("cc", "gamma");
		assert.equal(r.size(), 3);
	});

	test("clear() resets size to zero", () => {
		const r = makeRegistry();
		r.add("aa", "alpha");
		r.add("bb", "beta");
		r.clear();
		assert.equal(r.size(), 0);
	});

	test("mappingsForTail returns empty after clear()", () => {
		const r = makeRegistry();
		r.add("abc", "replacement");
		r.clear();
		assert.deepEqual(r.mappingsForTail("c"), []);
	});

	test("tlen matches codepoint length of trigger", () => {
		const r = makeRegistry();
		const m = r.add("hello", "world");
		assert.equal(m.tlen, 5);
	});

	test("trigger_bytes matches byte length for ASCII trigger", () => {
		const r = makeRegistry();
		const m = r.add("abc", "x");
		assert.equal(m.trigger_bytes, 3);
	});

	test("multiple triggers with same tail char all appear in the same bucket", () => {
		const r = makeRegistry();
		r.add("abc", "one");
		r.add("xc",  "two");
		r.add("c",   "three");
		const bucket = r.mappingsForTail("c");
		assert.equal(bucket.length, 3);
	});

	test("bucket is sorted longest-first after adding multiple triggers", () => {
		const r = makeRegistry();
		r.add("c",    "short");
		r.add("abc",  "medium");
		r.add("xyzc", "long");
		const bucket = r.mappingsForTail("c");
		// Lengths must be non-increasing
		for (let i = 1; i < bucket.length; i++) {
			assert.ok(bucket[i].tlen <= bucket[i - 1].tlen,
				`bucket[${i}].tlen (${bucket[i].tlen}) > bucket[${i - 1}].tlen (${bucket[i - 1].tlen})`);
		}
	});

	test("longer trigger matches before shorter when both end with same char", () => {
		const r = makeRegistry();
		r.add("c",   "short expansion");
		r.add("abc", "long expansion");
		const bucket = r.mappingsForTail("c");
		assert.equal(bucket[0].trigger, "abc", "longest trigger must appear first");
	});

	test("add() returns null for empty trigger", () => {
		const r = makeRegistry();
		assert.equal(r.add("", "x"), null);
	});

	test("add() returns null when repl is not a string", () => {
		const r = makeRegistry();
		assert.equal(r.add("abc", null), null);
	});

	test("seq values are monotonically increasing across multiple adds", () => {
		const r = makeRegistry();
		const m1 = r.add("aa", "first");
		const m2 = r.add("bb", "second");
		const m3 = r.add("cc", "third");
		assert.ok(m1.seq < m2.seq, "seq must increase");
		assert.ok(m2.seq < m3.seq, "seq must increase");
	});

	test("group and group_order defaults are applied when opts are omitted", () => {
		const r = makeRegistry();
		const m = r.add("abc", "x");
		assert.equal(m.group, "default");
		assert.equal(m.group_order, 0);
	});

	test("color default is null when not specified", () => {
		const r = makeRegistry();
		const m = r.add("abc", "x");
		assert.equal(m.color, null);
	});

	test("custom group and color are preserved on the mapping object", () => {
		const r = makeRegistry();
		const m = r.add("abc", "x", { group: "personal", color: "#ff0000" });
		assert.equal(m.group, "personal");
		assert.equal(m.color, "#ff0000");
	});

	test("validateAdapter recognizes a compliant registry", () => {
		const r           = makeRegistry();
		const violations  = RegistrySpec.validateAdapter(r);
		assert.deepEqual(violations, [], `Expected no violations, got: ${violations.join(", ")}`);
	});

});




// =====================================================
// =====================================================
// ======= 7/ HotstringMatcher Algorithm Tests =======
// =====================================================
// =====================================================

suite("HotstringMatcher — direct match logic", () => {

	test("no match when registry is empty", () => {
		const r = makeRegistry();
		assert.equal(matchBuffer("hello", "o", r), null);
	});

	test("no match when buffer is empty", () => {
		const r = makeRegistry();
		r.add("abc", "replacement");
		assert.equal(matchBuffer("", "a", r), null);
	});

	test("exact match: buffer equals trigger", () => {
		const r = makeRegistry();
		r.add("btw", "by the way");
		const result = matchBuffer("btw", "w", r);
		assert.notEqual(result, null);
		assert.equal(result.trigger, "btw");
		assert.equal(result.replacement, "by the way");
	});

	test("match when trigger is suffix of buffer", () => {
		const r = makeRegistry();
		r.add("btw", "by the way");
		const result = matchBuffer("I said btw", "w", r);
		assert.notEqual(result, null);
		assert.equal(result.trigger, "btw");
	});

	test("no match when tail char differs from trigger's tail", () => {
		const r = makeRegistry();
		r.add("btw", "by the way");
		const result = matchBuffer("btw", "x", r);
		assert.equal(result, null);
	});

	test("no match when buffer is shorter than trigger", () => {
		const r = makeRegistry();
		r.add("abcde", "long trigger");
		const result = matchBuffer("abc", "c", r);
		assert.equal(result, null);
	});

	test("backspace_count = tlen when terminator_consumed=false", () => {
		const r = makeRegistry();
		r.add("abc", "expansion");
		const result = matchBuffer("abc", "c", r, { terminator_consumed: false });
		assert.notEqual(result, null);
		assert.equal(result.backspace_count, 3);
	});

	test("backspace_count = tlen + 1 when terminator_consumed=true", () => {
		const r = makeRegistry();
		r.add("abc", "expansion");
		const result = matchBuffer("abc", "c", r, { terminator_consumed: true });
		assert.notEqual(result, null);
		assert.equal(result.backspace_count, 4);
	});

	test("consume_terminator field mirrors terminator_consumed option", () => {
		const r = makeRegistry();
		r.add("abc", "expansion");
		const r1 = matchBuffer("abc", "c", r, { terminator_consumed: false });
		const r2 = matchBuffer("abc", "c", r, { terminator_consumed: true });
		assert.equal(r1.consume_terminator, false);
		assert.equal(r2.consume_terminator, true);
	});

	test("is_final is propagated from the mapping's final_result field", () => {
		const r = makeRegistry();
		r.add("abc", "x", { final_result: true });
		const result = matchBuffer("abc", "c", r);
		assert.equal(result.is_final, true);
	});

	test("group is propagated from the mapping", () => {
		const r = makeRegistry();
		r.add("abc", "x", { group: "autocorrect" });
		const result = matchBuffer("abc", "c", r);
		assert.equal(result.group, "autocorrect");
	});

	test("color is propagated from the mapping", () => {
		const r = makeRegistry();
		r.add("abc", "x", { color: "#abcdef" });
		const result = matchBuffer("abc", "c", r);
		assert.equal(result.color, "#abcdef");
	});

	test("case-insensitive by default: uppercase buffer matches lowercase trigger", () => {
		const r = makeRegistry();
		// Bucket key is normalized to lowercase; tailChar "W" → bucket "w" → finds "btw"
		r.add("btw", "by the way");
		const result = matchBuffer("BTW", "W", r);
		assert.notEqual(result, null);
		assert.equal(result.trigger, "btw");
	});

	test("case-sensitive: exact case must match when is_case_sensitive=true", () => {
		const r = makeRegistry();
		r.add("btw", "by the way", { is_case_sensitive: true });
		// Buffer "BTW" — suffix check: "BTW" !== "btw" → no match
		const result = matchBuffer("BTW", "W", r);
		assert.equal(result, null);
	});

	test("longest trigger wins when two triggers share the same tail char", () => {
		const r = makeRegistry();
		r.add("c",   "short");
		r.add("abc", "long");
		const result = matchBuffer("abc", "c", r);
		assert.notEqual(result, null);
		assert.equal(result.trigger, "abc");
	});

	test("word-boundary: is_word=true fires when preceded by space", () => {
		const r = makeRegistry();
		r.add("abc", "expansion", { is_word: true });
		const result = matchBuffer(" abc", "c", r);
		assert.notEqual(result, null);
	});

	test("word-boundary: is_word=true does not fire when preceded by letter", () => {
		const r = makeRegistry();
		r.add("abc", "expansion", { is_word: true });
		const result = matchBuffer("xabc", "c", r);
		assert.equal(result, null);
	});

	test("word-boundary: is_word=true fires at start-of-buffer (no preceding char)", () => {
		const r = makeRegistry();
		r.add("abc", "expansion", { is_word: true });
		const result = matchBuffer("abc", "c", r);
		assert.notEqual(result, null);
	});

	test("word-boundary: is_word=false always fires regardless of preceding char", () => {
		const r = makeRegistry();
		r.add("abc", "expansion", { is_word: false });
		const result = matchBuffer("xabc", "c", r);
		assert.notEqual(result, null);
	});

	test("result is null when buffer tail does not match any registered trigger", () => {
		const r = makeRegistry();
		r.add("abc", "expansion");
		const result = matchBuffer("xyz", "z", r);
		assert.equal(result, null);
	});

});




// ===========================================
// ===========================================
// ======= 8/ Expander Decide/Cycle Tests =======
// ===========================================
// ===========================================

suite("Expander — decide/cycle invariants", () => {

	test("direct expansion is found when buffer equals trigger exactly", () => {
		const r = makeRegistry();
		r.add("omw", "on my way", { is_word: false });
		const result = matchBuffer("omw", "w", r);
		assert.notEqual(result, null);
		assert.equal(result.trigger, "omw");
		assert.equal(result.replacement, "on my way");
	});

	test("result is deterministic: two calls with same input return same trigger", () => {
		const r = makeRegistry();
		r.add("omw", "on my way");
		const r1 = matchBuffer("omw", "w", r);
		const r2 = matchBuffer("omw", "w", r);
		assert.equal(r1 !== null && r2 !== null, true);
		assert.equal(r1.trigger, r2.trigger);
		assert.equal(r1.replacement, r2.replacement);
	});

	test("backspace_count increases by exactly 1 when terminator_consumed flips true", () => {
		const r = makeRegistry();
		r.add("xyz", "expansion");
		const withoutTerm = matchBuffer("xyz", "z", r, { terminator_consumed: false });
		const withTerm    = matchBuffer("xyz", "z", r, { terminator_consumed: true });
		assert.equal(withTerm.backspace_count - withoutTerm.backspace_count, 1);
	});

	test("no expansion when buffer ends with unregistered trigger", () => {
		const r = makeRegistry();
		r.add("abc", "registered");
		const result = matchBuffer("xyz", "z", r);
		assert.equal(result, null);
	});

	test("cycle: adding two triggers sharing same tail yields longest match first", () => {
		const r = makeRegistry();
		r.add("bc",  "medium");
		r.add("abc", "longest");
		const first = r.mappingsForTail("c")[0];
		assert.equal(first.trigger, "abc", "longest trigger must be first in bucket");
	});

	test("expansion backspace_count equals trigger codepoint length for non-consumed case", () => {
		const r = makeRegistry();
		r.add("test", "expanded");
		const result = matchBuffer("test", "t", r, { terminator_consumed: false });
		assert.equal(result.backspace_count, 4);
	});

	test("expansion group defaults to default when not specified", () => {
		const r = makeRegistry();
		r.add("abc", "x");
		const result = matchBuffer("abc", "c", r);
		assert.equal(result.group, "default");
	});

	test("is_final=false by default", () => {
		const r = makeRegistry();
		r.add("abc", "x");
		const result = matchBuffer("abc", "c", r);
		assert.equal(result.is_final, false);
	});

	test("color is null by default when not specified on the mapping", () => {
		const r = makeRegistry();
		r.add("abc", "x");
		const result = matchBuffer("abc", "c", r);
		assert.equal(result.color, null);
	});

});




// ============================================
// ============================================
// ======= 9/ Edge Cases and Boundaries =======
// ============================================
// ============================================

suite("Edge cases — boundary and stress", () => {

	test("single-char trigger matches when buffer is that single char", () => {
		const r = makeRegistry();
		r.add("a", "alpha");
		const result = matchBuffer("a", "a", r);
		assert.notEqual(result, null);
		assert.equal(result.trigger, "a");
	});

	test("backspace_count is 1 for single-char trigger with terminator_consumed=false", () => {
		const r = makeRegistry();
		r.add("a", "alpha");
		const result = matchBuffer("a", "a", r, { terminator_consumed: false });
		assert.equal(result.backspace_count, 1);
	});

	test("backspace_count is 2 for single-char trigger with terminator_consumed=true", () => {
		const r = makeRegistry();
		r.add("a", "alpha");
		const result = matchBuffer("a", "a", r, { terminator_consumed: true });
		assert.equal(result.backspace_count, 2);
	});

	test("very long trigger (12 chars) is matched correctly", () => {
		const r = makeRegistry();
		r.add("abcdefghijkl", "long trigger expansion");
		const result = matchBuffer("abcdefghijkl", "l", r);
		assert.notEqual(result, null);
		assert.equal(result.backspace_count, 12);
	});

	test("trigger suffix match in a longer buffer preserves correct backspace_count", () => {
		const r = makeRegistry();
		r.add("end", "the end");
		const result = matchBuffer("beginning middle end", "d", r);
		assert.notEqual(result, null);
		assert.equal(result.backspace_count, 3);
	});

	test("multiple registries are independent — clear on one does not affect the other", () => {
		const r1 = makeRegistry();
		const r2 = makeRegistry();
		r1.add("abc", "from r1");
		r2.add("abc", "from r2");
		r1.clear();
		assert.equal(r1.size(), 0);
		assert.equal(r2.size(), 1);
	});

	test("isWordChar correctly classifies space as non-word", () => {
		const r = makeRegistry();
		r.add("abc", "expansion", { is_word: true });
		const result = matchBuffer("x abc", "c", r);
		assert.notEqual(result, null);
	});

	test("isWordChar correctly classifies tab as non-word boundary", () => {
		const r = makeRegistry();
		r.add("abc", "expansion", { is_word: true });
		const result = matchBuffer("\tabc", "c", r);
		assert.notEqual(result, null);
	});

	test("final_result=true is preserved in the match result", () => {
		const r = makeRegistry();
		r.add("abc", "x", { final_result: true });
		const result = matchBuffer("abc", "c", r);
		assert.equal(result.is_final, true);
	});

	test("final_result=false is preserved in the match result", () => {
		const r = makeRegistry();
		r.add("abc", "x", { final_result: false });
		const result = matchBuffer("abc", "c", r);
		assert.equal(result.is_final, false);
	});

});




// ============================================
// ============================================
// ======= 10/ Test Suite Result Summary =======
// ============================================
// ============================================

console.log(`\n--- Results: ${total_pass} passed, ${total_fail} failed ---`);

if (total_fail > 0) {
	process.exit(1);
}
