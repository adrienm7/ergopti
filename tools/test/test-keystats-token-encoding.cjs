// tools/test/test-keystats-token-encoding.cjs

/**
 * ==============================================================================
 * MODULE: Keystats Token Encoding Gate
 * DESCRIPTION:
 * Replays token_encoding_vectors.json on the dashboard reader and pins the
 * single marker source: the generated tables are current and every marker a
 * driver emits belongs to the shared list, so [PGUP] against [PAGEUP] cannot
 * come back. The Lua and AHK suites replay the same vectors.
 * ==============================================================================
 */
'use strict';

const assert = require('assert');
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..', '..');
const STATIC = path.join(ROOT, 'static/ergopti_plus');
const read = (relative) => fs.readFileSync(path.join(STATIC, relative), 'utf8');

const shared = JSON.parse(read('_shared/metrics/data/keystats_tokens.json'));
const vectors = JSON.parse(read('_shared/tests/corpus/keystats/token_encoding_vectors.json'));
const known = new Set(shared.markers);

assert.strictEqual(vectors.version, shared.version, 'the corpus follows the shared version');

const codegen = spawnSync(
	process.execPath,
	[path.join(ROOT, 'tools/codegen/codegen-keystats-tokens.cjs'), '--check'],
	{ encoding: 'utf8' }
);
assert.strictEqual(codegen.status, 0, `generated tables are stale: ${codegen.stderr}`);

const context = {};
vm.createContext(context);
vm.runInContext(read('_shared/ui/metrics_typing/_generated/keystats_tokens.js'), context);
vm.runInContext(read('_shared/ui/metrics_typing/key_tokens.js'), context);

for (const { key, tokens } of vectors.keys) {
	assert.deepStrictEqual(Array.from(context.key_tokens(key)), tokens, `reads ${key}`);
	assert.deepStrictEqual(
		Array.from(context.key_tokens(key.toLowerCase())).map((token) =>
			context.is_key_marker(token) ? token.toUpperCase() : token
		),
		tokens.map((token) => (token.length > 1 ? token : token.toLowerCase())),
		`reads the dashboard's lowercased ${key}`
	);
}

const hook = read('windows/modules/keystats/keystats_hook.ahk');
const hookStart = hook.indexOf('global KLHOOK_SPECIAL');
const hookTable = hook.slice(hookStart, hook.indexOf('\n)', hookStart));
const hookMarkers = [...hookTable.matchAll(/"(\[[A-Z0-9]+\])"/g)].map((match) => match[1]);
assert.ok(hookMarkers.length >= 12, 'the Windows hook table is found');
for (const marker of hookMarkers) assert.ok(known.has(marker), `Windows emits ${marker}`);

const macos = read('macos/modules/keystats/init.lua');
const macosStart = macos.indexOf('local F_KEY_CODES');
const macosTables = macos.slice(macosStart, macos.indexOf('Default State', macosStart));
const macosNames = [...macosTables.matchAll(/\]\s*= "([A-Z0-9]+)"/g)].map(
	(match) => `[${match[1]}]`
);
const macosLiterals = [...macos.matchAll(/ev_entry = \{ "(\[[A-Z0-9]+\])"/g)].map(
	(match) => match[1]
);
assert.ok(macosNames.length >= 20 && macosLiterals.length >= 4, 'the macOS markers are found');
for (const marker of [...macosNames, ...macosLiterals])
	assert.ok(known.has(marker), `macOS emits ${marker}`);

console.log('ok - keystats token encoding: the dashboard reader and every marker source agree');
