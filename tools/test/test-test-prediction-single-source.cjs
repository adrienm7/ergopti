// tools/test/test-test-prediction-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Test Prediction Single-Source Gate
 * DESCRIPTION:
 * The AI menu's « Test a prediction » is one behaviour on the three drivers, each
 * in its own language: Windows in menu_settings.ahk, macOS and Linux in the shared
 * llm/test_prediction.lua. This gate pins the two copies of the shown excerpt's
 * length and of the blank answer's reason, and the row stays on every platform.
 *
 * WHY:
 * A length or a wording changed on one side would drift with every suite green,
 * since each suite only checks its own copy.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const SP = path.resolve(__dirname, '..', '..', 'static', 'ergopti_plus');
const ahk = fs.readFileSync(
	path.join(SP, 'windows', 'ui', 'menu', 'menu_llm', 'menu_settings.ahk'),
	'utf8'
);
const lua = fs.readFileSync(path.join(SP, '_shared', 'lua', 'llm', 'test_prediction.lua'), 'utf8');
const manifest = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json'), 'utf8')
);

const errors = [];
const ahkChars = /LLM_TEST_PREDICTION_EXCERPT_CHARS := (\d+)/.exec(ahk);
const luaChars = /M\.EXCERPT_CHARS = (\d+)/.exec(lua);
if (!ahkChars || !luaChars) errors.push('an excerpt length declaration is missing');
else if (ahkChars[1] !== luaChars[1])
	errors.push(`excerpt length: Windows ${ahkChars[1]}, Lua ${luaChars[1]}`);

const luaEmpty = /M\.EMPTY_ANSWER_REASON = "([^"]+)"/.exec(lua);
if (!luaEmpty) errors.push('the Lua blank-answer reason is missing');
else if (!ahk.includes(`"${luaEmpty[1]}"`))
	errors.push(`Windows does not name the blank-answer reason "${luaEmpty[1]}"`);

let row = null;
const walk = (node) => {
	if (Array.isArray(node)) node.forEach(walk);
	else if (node && typeof node === 'object') {
		if (node.id === 'llm_test_prediction') row = node;
		Object.values(node).forEach(walk);
	}
};
walk(manifest);
if (!row) errors.push('the manifest declares no llm_test_prediction row');
else if (row.platforms !== undefined)
	errors.push(`the row is limited to ${JSON.stringify(row.platforms)}`);

if (errors.length) {
	console.error(`test-prediction single-source: FAILED\n  ${errors.join('\n  ')}`);
	process.exit(1);
}
console.log('test-prediction single-source: OK');
