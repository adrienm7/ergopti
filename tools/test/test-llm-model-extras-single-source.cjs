// tools/test/test-llm-model-extras-single-source.cjs

/**
 * ==============================================================================
 * MODULE: API Model-Extras Single-Source Guard
 * DESCRIPTION:
 * Per-model body fields (e.g. reasoning_effort:none for qwen-3.8-27b, which
 * otherwise reasons at xhigh effort by default and stalls tiny probes) live
 * in exactly ONE place — _shared/modules/llm/api_providers.json
 * (providers.<id>.model_extras). Both drivers merge them generically from
 * data; neither may restate a field name in shipped code, or a tuning fix on
 * one driver silently stops applying to the other.
 *
 * ROOT CAUSE ENCODED:
 * A provider quirk fixed with a literal in one payload builder (say AHK)
 * stays broken in the twin (Hammerspoon) with no failure anywhere — the
 * request still goes out, the model just never answers in time. This guard
 * fails if a model_extras field name appears in shipped driver sources, if
 * either payload builder stops consuming model_extras, or if the JSON
 * section itself is malformed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SSOT_FILE = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'llm',
	'api_providers.json'
);

// Shipped driver sources that must consume model_extras generically.
// Test files are excluded: asserting merged output legitimately names fields.
const SHIPPED = [
	'static/ergopti_plus/windows/modules/llm/api_remote.ahk',
	'static/ergopti_plus/macos/modules/llm/api_remote.lua'
];

let failed = false;
const fail = (msg) => {
	console.error(`\x1b[31m[ERROR] ${msg}\x1b[0m`);
	failed = true;
};

let root;
try {
	root = JSON.parse(fs.readFileSync(SSOT_FILE, 'utf8'));
} catch (err) {
	fail(`could not read api_providers.json: ${err.message}`);
}

const fieldNames = new Set();
if (root && typeof root === 'object') {
	const providers = root.providers;
	if (!providers || typeof providers !== 'object') {
		fail('api_providers.json has no providers object.');
	} else {
		for (const [pid, desc] of Object.entries(providers)) {
			if (!desc || typeof desc !== 'object') continue;
			const extras = desc.model_extras;
			if (extras === undefined) continue;
			if (!extras || typeof extras !== 'object' || Array.isArray(extras)) {
				fail(`providers.${pid}.model_extras must be an object.`);
				continue;
			}
			for (const [model, fields] of Object.entries(extras)) {
				if (model.startsWith('_')) continue;
				if (typeof model !== 'string' || model === '') {
					fail(`providers.${pid}.model_extras has an invalid model key.`);
					continue;
				}
				if (!fields || typeof fields !== 'object' || Array.isArray(fields)) {
					fail(`providers.${pid}.model_extras.${model} must be an object.`);
					continue;
				}
				for (const [field, value] of Object.entries(fields)) {
					if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(field)) {
						fail(`providers.${pid}.model_extras.${model} has an unshippable field name: ${field}.`);
						continue;
					}
					if (typeof value !== 'string' && typeof value !== 'number') {
						fail(`providers.${pid}.model_extras.${model}.${field} must be a string or number.`);
						continue;
					}
					fieldNames.add(field);
				}
			}
		}
	}
}

function stripLineComments(src, isAhk) {
	return src
		.split('\n')
		.map((line) => (isAhk ? line.replace(/(^|\s);.*$/, '$1') : line.split('--')[0]))
		.join('\n');
}

for (const rel of SHIPPED) {
	const abs = path.join(ROOT, rel);
	if (!fs.existsSync(abs)) {
		fail(`shipped file missing: ${rel}.`);
		continue;
	}
	const src = fs.readFileSync(abs, 'utf8');
	const code = stripLineComments(src, rel.endsWith('.ahk'));
	for (const field of fieldNames) {
		if (code.includes(field)) {
			fail(
				`${rel} restates the shared model_extras field '${field}' (keep it in api_providers.json only).`
			);
		}
	}
	if (!src.includes('model_extras')) {
		fail(`${rel} no longer consumes model_extras — generic merge deleted?`);
	}
}

if (failed) process.exit(1);
console.log(
	'\x1b[32m[OK] API model extras are single-sourced (api_providers.json model_extras).\x1b[0m'
);
