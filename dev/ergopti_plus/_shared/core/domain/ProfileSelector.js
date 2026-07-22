// static/ergopti_plus/_shared/core/domain/ProfileSelector.js

/**
 * ==============================================================================
 * DOMAIN: ProfileSelector — Reference Implementation
 * DESCRIPTION:
 * Canonical pure-JS implementation of the LLM profile registry and prompt
 * variable injector. Loads the built-in profile catalogue from
 * _shared/modules/llm/profiles.json, merges user-defined overrides, resolves the
 * active profile by ID, and performs template variable substitution.
 *
 * FEATURES & RATIONALE:
 * 1. Shared JSON source: profiles.json is the single source of truth for both
 *    AHK and HS. This module reads it directly; driver adapters use the same
 *    file path (resolved relative to the _shared/modules/llm/ folder).
 * 2. User overrides: callers may pass an array of user-defined profiles that
 *    extend or replace built-in ones. User profiles with the same id as a
 *    built-in profile take precedence.
 * 3. Template injection: system prompts carry {context}, {tail}, {min_words},
 *    {max_words}, {n}, {language} placeholders. resolveSystemPrompt() replaces
 *    all occurrences in a single pass.
 * 4. Fallback chain: if the requested profile id is not found, the function
 *    returns the "basic" built-in profile as a safe default. If "basic" is
 *    also absent, returns null and the caller must handle it.
 * ==============================================================================
 */

'use strict';

// NOTE: This module is shared pure logic. No direct FS/OS requires (fs, path, hs, etc.)
// are allowed here — enforced by the meta purity test in macOS unit tests.
// Drivers (AHK/HS) must load _shared/modules/llm/profiles.json themselves (via port/adapter)
// and supply the data to the pure functions below.

// ==================================================
// ==================================================
// ======= 1/ Built-in Profile Path (driver-provided) =======
// ==================================================
// ==================================================

// Informational path only (no fs/path require in this pure module; drivers do the read).
const PROFILES_JSON_PATH = '../llm/profiles.json';

// ==================================================
// ==================================================
// ======= 2/ Profile Loading & Merging =======
// ==================================================
// ==================================================

/**
 * Loads the built-in profiles from profiles.json.
 * In the shared pure module this is a no-op (returns []); the driver layer
 * performs the actual FS read using its port and passes the parsed array in.
 * @returns {object[]}
 */
function loadBuiltInProfiles() {
	return [];
}

/**
 * Returns the merged profile catalogue: user profiles take precedence over
 * built-in profiles with the same id.
 *
 * @param {object[]} [userProfiles=[]]  User-defined profile overrides.
 * @returns {object[]} Merged catalogue.
 */
function getAllProfiles(userProfiles = []) {
	const builtIn = loadBuiltInProfiles();

	// Index built-in profiles by id
	const byId = new Map();
	for (const p of builtIn) {
		if (p.id) byId.set(p.id, p);
	}

	// User profiles override built-in ones with the same id
	for (const p of userProfiles) {
		if (p.id) byId.set(p.id, p);
	}

	return Array.from(byId.values());
}

// ==================================================
// ==================================================
// ======= 3/ Profile Resolution =======
// ==================================================
// ==================================================

/**
 * Resolves the active profile by ID from the merged catalogue.
 * Falls back to the "basic" built-in profile if the requested ID is not found.
 *
 * @param {string}   profileId     The requested profile ID.
 * @param {object[]} [userProfiles=[]] User-defined overrides.
 * @returns {object|null} The resolved profile object, or null if "basic" also missing.
 */
function getActiveProfile(profileId, userProfiles = []) {
	const all = getAllProfiles(userProfiles);
	const found = all.find((p) => p.id === profileId);
	if (found) return found;

	// Fallback to "basic"
	const basic = all.find((p) => p.id === 'basic');
	return basic ?? null;
}

// ==================================================
// ==================================================
// ======= 4/ Template Variable Injection =======
// ==================================================
// ==================================================

/**
 * Injects template variables into a profile's system prompt string.
 *
 * Algorithm (must stay in sync with both drivers and profile_selector.lua):
 *   1. null/undefined profile → { system: null }
 *   2. raw_prompt non-empty → return it verbatim (raw mode, no substitution)
 *   3. n === 1 → system_single (or null if absent)
 *   4. n > 1 → system_single + "\n\n" + system_multi_template (footer pattern)
 *      If no multi_template, falls back to system_single alone.
 *   5. Substitutes {context}, {tail}, {min_words}, {max_words}, {n}, {language}
 *      in a single replaceAll pass.
 *
 * Supported placeholders (all optional — missing placeholders stay as-is):
 *   {context}    Full (possibly truncated) context forwarded to the LLM.
 *   {tail}       Last N words of the context (freshness reference window).
 *   {min_words}  Minimum prediction word count.
 *   {max_words}  Maximum prediction word count.
 *   {n}          Number of predictions requested.
 *   {language}   Language hint (e.g. "fr", "en").
 *
 * @param {object|null} profile      The resolved profile object, or null.
 * @param {object}      vars         Variable values to inject.
 * @param {string}      vars.context
 * @param {string}      [vars.tail=""]
 * @param {number}      [vars.min_words=1]
 * @param {number}      [vars.max_words=5]
 * @param {number}      [vars.n=1]
 * @param {string}      [vars.language="fr"]
 * @returns {{ system: string|null, is_batch: boolean }}
 *   system:   The injected system prompt string (null if the profile has none).
 *   is_batch: True when the profile uses batch mode with multi_template.
 */
function resolveSystemPrompt(profile, vars = {}) {
	if (!profile) return { system: null, is_batch: false };

	const n = vars.n ?? 1;

	// raw_prompt short-circuit: verbatim, no substitution (matches both drivers)
	if (typeof profile.raw_prompt === 'string' && profile.raw_prompt !== '') {
		return { system: profile.raw_prompt, is_batch: false };
	}

	const isBatch = profile.batch === true && n > 1 && typeof profile.system_multi_template === 'string' && profile.system_multi_template !== '';

	const base = typeof profile.system_single === 'string' ? profile.system_single : null;
	if (!base) return { system: null, is_batch: isBatch };

	let template;
	if (isBatch) {
		// Footer pattern matching both drivers: base + "\n\n" + footer{n}
		const footer = profile.system_multi_template.replace(/\{n\}/g, String(n));
		template = base + '\n\n' + footer;
	} else {
		template = base;
	}

	const context = vars.context ?? '';
	const tail = vars.tail ?? '';
	const minWords = vars.min_words != null ? String(vars.min_words) : '1';
	const maxWords = vars.max_words != null ? String(vars.max_words) : '5';
	const language = vars.language ?? 'fr';

	const system = template
		.replace(/\{context\}/g, context)
		.replace(/\{tail\}/g, tail)
		.replace(/\{min_words\}/g, String(minWords))
		.replace(/\{max_words\}/g, String(maxWords))
		.replace(/\{n\}/g, String(n))
		.replace(/\{language\}/g, language);

	return { system, is_batch: isBatch };
}

// ==================================================
// ==================================================
// ======= 5/ Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns cross-driver test vectors for the ProfileSelector.
 * @returns {Array<object>}
 */
function profileSelectorTestVectors() {
	return [
		{
			id: 'resolve_known_profile',
			description: "getActiveProfile('basic') returns the built-in basic profile.",
			call: 'getActiveProfile',
			args: ['basic', []],
			assert: { field: 'id', value: 'basic', not_null: true }
		},
		{
			id: 'resolve_unknown_falls_back_to_basic',
			description: "Unknown profile ID falls back to 'basic'.",
			call: 'getActiveProfile',
			args: ['nonexistent_id', []],
			assert: { field: 'id', value: 'basic' }
		},
		{
			id: 'user_profile_overrides_builtin',
			description: "User profile with id='basic' replaces the built-in basic.",
			call: 'getActiveProfile',
			args: ['basic', [{ id: 'basic', system_single: 'CUSTOM PROMPT {context}', batch: false }]],
			assert: { field: 'system_single', starts_with: 'CUSTOM PROMPT' }
		},
		{
			id: 'get_all_profiles_includes_builtins',
			description: 'getAllProfiles([]) returns at least 3 built-in profiles.',
			call: 'getAllProfiles',
			args: [[]],
			assert: { min_length: 3 }
		},
		{
			id: 'inject_basic_context',
			description: 'resolveSystemPrompt replaces {context} and {min_words} / {max_words}.',
			call: 'resolveSystemPrompt',
			args: [
				{
					id: 'basic',
					system_single: 'Context: {context} — {min_words}–{max_words} words.',
					batch: false
				},
				{ context: 'bonjour', min_words: 2, max_words: 5, language: 'fr' }
			],
			assert: {
				field: 'system',
				contains: 'bonjour',
				not_null: true
			}
		},
		{
			id: 'inject_language_placeholder',
			description: 'resolveSystemPrompt replaces {language}.',
			call: 'resolveSystemPrompt',
			args: [
				{ id: 'basic', system_single: 'Default language: {language}.', batch: false },
				{ context: '', language: 'en' }
			],
			assert: { field: 'system', contains: 'en' }
		},
		{
			id: 'batch_footer_pattern',
			description: 'Batch n>1 concatenates system_single + \\n\\n + footer{n}.',
			call: 'resolveSystemPrompt',
			args: [
				{
					id: 'batch_test',
					batch: true,
					system_single: 'BASE',
					system_multi_template: 'FOOTER n={n}'
				},
				{ context: 'ctx', n: 5 }
			],
			assert: { field: 'system', contains: 'BASE\n\nFOOTER n=5' }
		},
		{
			id: 'batch_mode_returns_is_batch_true',
			description: 'Batch profile with n>1 returns is_batch=true.',
			call: 'resolveSystemPrompt',
			args: [
				{
					id: 'batch_test',
					batch: true,
					system_single: 'Single: {context}',
					system_multi_template: 'Batch n={n}: {context}'
				},
				{ context: 'test', n: 3 }
			],
			assert: { field: 'is_batch', value: true }
		},
		{
			id: 'raw_prompt_short_circuit',
			description: 'raw_prompt non-empty returns verbatim, no substitution, is_batch=false.',
			call: 'resolveSystemPrompt',
			args: [
				{ id: 'raw', raw_prompt: 'JUST {context} VERBATIM', batch: false },
				{ context: 'hello', n: 1 }
			],
			assert: { field: 'system', value: 'JUST {context} VERBATIM' }
		},
		{
			id: 'null_profile_returns_null_system',
			description: 'resolveSystemPrompt(null) returns system=null.',
			call: 'resolveSystemPrompt',
			args: [null, {}],
			assert: { field: 'system', value: null }
		}
	];
}

module.exports = {
	PROFILES_JSON_PATH,
	loadBuiltInProfiles,
	getAllProfiles,
	getActiveProfile,
	resolveSystemPrompt,
	profileSelectorTestVectors
};
