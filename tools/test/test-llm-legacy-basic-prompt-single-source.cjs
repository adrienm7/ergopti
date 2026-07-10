// scripts/test-llm-legacy-basic-prompt-single-source.cjs

/**
 * ==============================================================================
 * MODULE: LLM legacy_ids + BASIC_PROMPT Single-Source Guard
 * DESCRIPTION:
 * The profile-id migration table and the "basic" profile's fallback prompt
 * used to be hand-copied literals in both windows/modules/llm/profiles.ahk and
 * macos/modules/llm/profiles.lua, with no mechanism catching drift between the
 * two copies (or against the shared JSON they were meant to mirror).
 *
 * This test pins the fix:
 *   1. The generated windows/_generated/llm_profiles_data.ahk carries the exact
 *      legacy_ids.json mapping and the exact "basic" profiles.json prompt.
 *   2. windows/modules/llm/profiles.ahk no longer re-declares either literal —
 *      it must delegate to the generated globals/functions.
 *   3. macos/modules/llm/profiles.lua no longer hardcodes the migration table —
 *      it must load it via profile_selector.load_legacy_ids().
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

const LEGACY_IDS_JSON = path.join(ROOT, 'static/ergopti_plus/_shared/modules/llm/legacy_ids.json');
const PROFILES_JSON = path.join(ROOT, 'static/ergopti_plus/_shared/modules/llm/profiles.json');
const GENERATED_AHK = path.join(ROOT, 'static/ergopti_plus/windows/_generated/llm_profiles_data.ahk');
const PROFILES_AHK = path.join(ROOT, 'static/ergopti_plus/windows/modules/llm/profiles.ahk');
const PROFILES_LUA = path.join(ROOT, 'static/ergopti_plus/macos/modules/llm/profiles.lua');

let _pass = 0;
let _fail = 0;
const _results = [];

/**
 * @param {string} name
 * @param {boolean} ok
 * @param {string} [detail]
 */
function test(name, ok, detail) {
	_pass += ok ? 1 : 0;
	_fail += ok ? 0 : 1;
	_results.push({ name, ok, detail });
}

function report() {
	const total = _pass + _fail;
	console.log('TAP version 14');
	console.log(`1..${total}`);
	let i = 1;
	for (const r of _results) {
		console.log(`${r.ok ? 'ok' : 'not ok'} ${i++} - ${r.name}`);
		if (!r.ok && r.detail) console.log(`  # ${r.detail}`);
	}
	console.log(`# passed: ${_pass}/${total}`);
	if (_fail > 0) {
		console.log(`# FAILED: ${_fail} test(s)`);
		process.exit(1);
	}
}

const legacyIds = JSON.parse(fs.readFileSync(LEGACY_IDS_JSON, 'utf8'));
const profiles = JSON.parse(fs.readFileSync(PROFILES_JSON, 'utf8'));
const basicProfile = profiles.find((p) => p && p.id === 'basic');
const generatedAhk = fs.readFileSync(GENERATED_AHK, 'utf8');
const profilesAhk = fs.readFileSync(PROFILES_AHK, 'utf8');
const profilesLua = fs.readFileSync(PROFILES_LUA, 'utf8');

test(
	'legacy_ids.json has the four canonical migrations',
	legacyIds.parallel === 'basic' &&
		legacyIds.batch === 'batch_advanced' &&
		legacyIds.parallel_advanced === 'advanced' &&
		legacyIds.base_completion === 'raw',
	`legacy_ids.json = ${JSON.stringify(legacyIds)}`
);

test('profiles.json has a "basic" profile with a non-empty system_single', !!(basicProfile && basicProfile.system_single));

// --- Generated AHK legacy map matches legacy_ids.json exactly ---
for (const [oldId, newId] of Object.entries(legacyIds)) {
	const needle = `"${oldId}", "${newId}"`;
	test(
		`llm_profiles_data.ahk LLM_LEGACY_IDS maps "${oldId}" -> "${newId}"`,
		generatedAhk.includes(needle),
		`expected to find ${JSON.stringify(needle)} in the generated Map(...)`
	);
}

// --- Generated AHK basic prompt matches profiles.json exactly (AHK-escaped) ---
{
	const ahkEscaped = basicProfile.system_single
		.replace(/`/g, '``')
		.replace(/"/g, '`"')
		.replace(/\n/g, '`n');
	test(
		'llm_profiles_data.ahk LLM_GetBasicPrompt() returns the exact profiles.json "basic" text',
		generatedAhk.includes(`return "${ahkEscaped}"`),
		'generated function body does not match the AHK-escaped profiles.json text'
	);
}

// --- Regression guards: the hand-copied literals must not reappear ---
test(
	'profiles.ahk no longer declares its own legacy id Map',
	!/static\s+legacy\s*:=\s*Map\(/.test(profilesAhk),
	'found a hand-written "static legacy := Map(" — legacy ids must come from LLM_LEGACY_IDS (generated)'
);
test(
	'profiles.ahk no longer defines its own LLM_GetBasicPrompt() body',
	!/LLM_GetBasicPrompt\(\)\s*\{\s*\n\s*return "You are an ultra-concise/.test(profilesAhk),
	'found a hand-written LLM_GetBasicPrompt() body — it must come from _generated/llm_profiles_data.ahk'
);
test(
	'profiles.ahk references the generated LLM_LEGACY_IDS global',
	/LLM_LEGACY_IDS/.test(profilesAhk)
);

test(
	'profiles.lua no longer hardcodes the LEGACY_IDS table literal',
	!/LEGACY_IDS\s*=\s*\{\s*\n\s*parallel\s*=/.test(profilesLua),
	'found a hand-written "LEGACY_IDS = { parallel = ... }" — legacy ids must come from Selector.load_legacy_ids()'
);
test(
	'profiles.lua delegates legacy id loading to profile_selector',
	/Selector\.load_legacy_ids\(\)/.test(profilesLua)
);

report();
