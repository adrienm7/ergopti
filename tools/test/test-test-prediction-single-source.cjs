// tools/test/test-test-prediction-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Test Prediction Single-Source Gate
 * DESCRIPTION:
 * The AI menu's « Test a prediction » is one behaviour on the three drivers, each
 * in its own language: Windows in menu_settings.ahk, macOS and Linux in the shared
 * llm/test_prediction.lua. This gate pins the two copies of the shown excerpt's
 * length, of the seconds threshold and of the blank answer's reason, keeps the row
 * on every platform, and keeps the test's high temperature in the shared defaults:
 * no driver sends it as a literal or falls back on the low generation setting.
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
const lua = fs.readFileSync(
	path.join(SP, '_shared', 'ai', 'engine', 'prediction', 'test_prediction.lua'),
	'utf8'
);
const manifest = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'menu', 'data', 'menu_manifest.json'), 'utf8')
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

const ahkSecond = /LLM_TEST_PREDICTION_MS_PER_SECOND := (\d+)/.exec(ahk);
const luaSecond = /M\.MS_PER_SECOND = (\d+)/.exec(lua);
if (!ahkSecond || !luaSecond) errors.push('a seconds threshold declaration is missing');
else if (ahkSecond[1] !== luaSecond[1])
	errors.push(`seconds threshold: Windows ${ahkSecond[1]}, Lua ${luaSecond[1]}`);

const defaults = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'ai', 'data', 'defaults.json'), 'utf8')
);
const hot = defaults.llm_test_prediction_temperature;
if (typeof hot !== 'number' || hot <= defaults.llm_temperature || hot > 1)
	errors.push(`llm_test_prediction_temperature must sit above llm_temperature, at most 1: ${hot}`);
const sendBody = ahk.slice(ahk.indexOf('_LLM_Menu_TestPredictionSend(Sample'));
if (!sendBody.includes('LLM_Defaults["llm_test_prediction_temperature"]'))
	errors.push('Windows must send the temperature of the shared defaults');
if (/Temperature := _LLM_Engine\["temperature"\]/.test(sendBody.slice(0, 900)))
	errors.push('Windows must not send the generation temperature');
const mac = fs.readFileSync(
	path.join(SP, 'macos', 'modules', 'llm', 'prediction_engine.lua'),
	'utf8'
);
if (!mac.includes('.test_prediction_temperature()'))
	errors.push('macOS must send the temperature of the shared defaults');
const linux = fs.readFileSync(
	path.join(SP, 'linux', 'modules', 'llm', 'prediction_engine.lua'),
	'utf8'
);
if (!linux.includes('request.temperature = HttpBridge.TEST_PREDICTION_TEMPERATURE'))
	errors.push('Linux must send the temperature of the shared defaults');

for (const entry of fs.readdirSync(path.join(SP, '_shared', 'core', 'i18n', 'data', 'locales'))) {
	if (!entry.endsWith('.json')) continue;
	const strings = JSON.parse(
		fs.readFileSync(path.join(SP, '_shared', 'core', 'i18n', 'data', 'locales', entry), 'utf8')
	);
	const placeholders = {
		'llm.test_prediction.result': ['{1}', '{2}'],
		'llm.test_prediction.duration_ms': ['{1}'],
		'llm.test_prediction.duration_s': ['{1}', '{2}']
	};
	for (const [key, wanted] of Object.entries(placeholders))
		for (const mark of wanted)
			if (!String(strings[key]).includes(mark)) errors.push(`${entry}: ${key} lacks ${mark}`);
}

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
