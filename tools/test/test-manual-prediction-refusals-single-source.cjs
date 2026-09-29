// tools/test/test-manual-prediction-refusals-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Manual Prediction Refusals Single-Source Gate
 * DESCRIPTION:
 * The llm_generate_prediction action is refused for the same four reasons on
 * every driver (paused, AI off, backend not ready, nothing typed), and each
 * reason shows the same localized notice. Each driver declares that table in
 * its own language because its decision reads driver state; this gate pins the
 * three copies together and to the locale keys they name.
 *
 * WHY:
 * The feedback exists because a manual request used to fail silently. A reason
 * added to one driver only, or a key renamed in one table, would bring the
 * silence back on the other two with every suite green.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCES = {
	windows: path.join(SP, 'windows', 'ui', 'menu', 'menu_llm', 'menu_settings.ahk'),
	macos: path.join(SP, 'macos', 'modules', 'llm', 'prediction_engine.lua'),
	linux: path.join(SP, 'linux', 'modules', 'llm', 'prediction_engine.lua')
};
const EN = path.join(SP, '_shared', 'data', 'locales', 'en.json');
const EXPECTED_REASONS = ['paused', 'disabled', 'backend_not_ready', 'empty_context'];

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const read = (file) => fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');

/**
 * Extracts the reason -> locale key pairs, in declaration order.
 * @param {string} block The source of the table.
 * @param {RegExp} pair A global pattern capturing (reason, key).
 * @returns {Array<[string, string]>}
 */
const pairsOf = (block, pair) => [...block.matchAll(pair)].map((m) => [m[1], m[2]]);

const tables = {};
const windows = read(SOURCES.windows);
const winBlock = (windows.match(/global LLM_MANUAL_PREDICTION_REFUSALS := Map\(([\s\S]*?)\n\)/) ||
	[])[1];
check(
	typeof winBlock === 'string',
	'windows: LLM_MANUAL_PREDICTION_REFUSALS not found in menu_settings.ahk'
);
tables.windows = pairsOf(winBlock || '', /"(\w+)",\s*"([\w.]+)"/g);

for (const driver of ['macos', 'linux']) {
	const source = read(SOURCES[driver]);
	const block = (source.match(/local MANUAL_REFUSAL_KEYS = \{([\s\S]*?)\n\}/) || [])[1];
	check(
		typeof block === 'string',
		`${driver}: MANUAL_REFUSAL_KEYS not found in modules/llm/prediction_engine.lua`
	);
	tables[driver] = pairsOf(block || '', /(\w+)\s*=\s*"([\w.]+)"/g);
}

const en = JSON.parse(read(EN));
for (const [driver, pairs] of Object.entries(tables)) {
	check(
		JSON.stringify(pairs.map(([reason]) => reason)) === JSON.stringify(EXPECTED_REASONS),
		`${driver}: refusal reasons ${JSON.stringify(pairs.map(([r]) => r))} must be ${JSON.stringify(EXPECTED_REASONS)} in that order`
	);
	for (const [reason, key] of pairs) {
		check(
			key === `llm.manual_prediction.${reason}`,
			`${driver}: '${reason}' must show llm.manual_prediction.${reason}, not ${key}`
		);
		check(typeof en[key] === 'string' && en[key] !== '', `${driver}: en.json lacks ${key}`);
	}
}

// Each decision function must return the reasons its table declares, so a
// renamed reason cannot survive in the table and vanish from the decision.
const decisions = {
	windows:
		(windows.match(/LLM_Menu_ManualPredictionRefusal\([^)]*\) \{([\s\S]*?)\n\}/) || [])[1] || '',
	macos:
		(read(SOURCES.macos).match(/local function manual_refusal\(\)([\s\S]*?)\nend/) || [])[1] || '',
	linux:
		(read(SOURCES.linux).match(/local function manual_refusal\(\)([\s\S]*?)\nend/) || [])[1] || ''
};
for (const [driver, body] of Object.entries(decisions)) {
	check(body !== '', `${driver}: the refusal decision function was not found`);
	for (const reason of EXPECTED_REASONS) {
		check(body.includes(`"${reason}"`), `${driver}: the decision never returns '${reason}'`);
	}
}

check(checks >= 40, `only ${checks} check(s) ran — the extraction collapsed`);

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] manual prediction refusals single source: ${checks} check(s) passed.\x1b[0m`
);
