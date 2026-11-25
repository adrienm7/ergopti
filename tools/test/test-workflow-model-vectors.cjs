// tools/test/test-workflow-model-vectors.cjs

/**
 * ==============================================================================
 * MODULE: User Workflow Model Vectors Gate
 * DESCRIPTION:
 * Replays _shared/tests/corpus/workflows/validation_vectors.json through the
 * canonical JS check of the workflow editor
 * (_shared/ui/workflow_model.js), replays the send_shortcut
 * vectors through its key-combination parser, holds steps.json to the timing
 * registry it names, and checks that the macOS and Linux suites replay the
 * shared Lua contracts of the same corpus and that the Windows suite replays
 * both corpora through its AutoHotkey port.
 *
 * ROOT CAUSE ENCODED:
 * User workflows had no model: the editor, an imported file and the three
 * drivers had no common rule, so a file the editor saved could be refused at
 * run time, or the reverse, and a step could run without a deadline.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const TOML = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

const errors = [];
let checks = 0;

/**
 * Records one check.
 * @param {boolean} condition
 * @param {string} message
 */
function check(condition, message) {
	checks += 1;
	if (!condition) errors.push(message);
}

/**
 * @param {string} relative Path under _shared/.
 * @returns {*} The decoded JSON file.
 */
function readJson(relative) {
	return JSON.parse(fs.readFileSync(path.join(SHARED, relative), 'utf8'));
}

// ==========================================
// ==========================================
// ======= 1/ Load the model ================
// ==========================================
// ==========================================

const context = {};
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(SHARED, 'ui', 'workflow_model.js'), 'utf8'), context);
const Model = context.ErgoptiWorkflowModel;
const catalogue = readJson('shortcuts/data/workflows/steps.json');
const vocabulary = readJson('shortcuts/data/actions/send_keys.json');
const corpus = readJson('tests/corpus/workflows/validation_vectors.json');
const registry = TOML.parse(
	fs.readFileSync(path.join(SHARED, 'core', 'timing', 'data', 'constants.toml'), 'utf8')
);

// ==========================================
// ==========================================
// ======= 2/ Validation vectors ============
// ==========================================
// ==========================================

check(corpus.vectors.length >= 90, 'the validation corpus lost its vectors');
const ids = new Set();
for (const vector of corpus.vectors) {
	check(!ids.has(vector.id), `duplicate vector id ${vector.id}`);
	ids.add(vector.id);
	const local = JSON.parse(JSON.stringify(catalogue));
	if (vector.limits) Object.assign(local.limits, vector.limits);
	const result = Model.validateFile(vector.doc, local, { vocabulary, timings: corpus.timings });
	const expected = vector.expected;
	check(
		result.ok === expected.ok && result.reason === expected.reason && result.path === expected.path,
		`${vector.id}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(result)}`
	);
	if (!expected.ok)
		check(catalogue.reasons.indexOf(expected.reason) >= 0, `${vector.id}: undeclared reason`);
}
const refused = new Set(corpus.vectors.filter((v) => !v.expected.ok).map((v) => v.expected.reason));
for (const reason of catalogue.reasons)
	check(refused.has(reason), `no vector refuses with ${reason}`);

// ==========================================
// ==========================================
// ======= 3/ Shortcut grammar ==============
// ==========================================
// ==========================================

const sendInput = readJson('tests/corpus/action_parameters/send_input_vectors.json');
const shortcuts = sendInput.vectors.filter((v) => v.kind === 'shortcut');
check(shortcuts.length >= 10, 'the send_input corpus lost its shortcut vectors');
for (const vector of shortcuts) {
	const parsed = Model.parseShortcut(vector.value, vocabulary);
	const wanted = vector.canonical === undefined ? null : vector.canonical;
	check(parsed === wanted, `shortcut ${vector.id}: expected ${wanted}, got ${parsed}`);
}

// ==========================================
// ==========================================
// ======= 4/ Catalogue and registry ========
// ==========================================
// ==========================================

const section = registry.workflows || {};
for (const [kind, declared] of Object.entries(catalogue.kinds)) {
	if (declared.timeout === null) continue;
	check(
		Number.isInteger(section[declared.timeout]) && section[declared.timeout] > 0,
		`step ${kind} names the timeout ${declared.timeout}, absent from [workflows] of constants.toml`
	);
	for (const [field, spec] of Object.entries(declared.fields)) {
		if (spec.max_limit === undefined) continue;
		check(
			catalogue.limits[spec.max_limit] !== undefined || section[spec.max_limit] !== undefined,
			`${kind}.${field} names the bound ${spec.max_limit}, declared nowhere`
		);
	}
}
check(
	section.wait_max_ms === corpus.timings.wait_max_ms,
	'the corpus timings no longer equal [workflows] wait_max_ms'
);

// ==========================================
// ==========================================
// ======= 5/ Driver replays ================
// ==========================================
// ==========================================

for (const driver of ['linux', 'macos']) {
	const file = path.join(
		SP,
		driver,
		'tests',
		'unit',
		'modules',
		'shortcuts',
		'test_workflow_model.lua'
	);
	const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
	for (const contract of [
		'workflow_model_contract',
		'workflow_interpreter_contract',
		'workflow_runner_contract',
		'workflow_owner_contract',
		'workflow_editor_host_contract'
	]) {
		check(
			text.includes(`tests.lua.workflows.${contract}`),
			`${driver} does not replay ${contract}`
		);
	}
}
check(
	fs
		.readFileSync(path.join(SP, 'linux', 'tests', 'test_manifest.lua'), 'utf8')
		.includes('"tests.unit.modules.shortcuts.test_workflow_model"'),
	'the Linux manifest does not list the workflow model test'
);
// The AutoHotkey port cannot run the Lua contracts: its suite replays both
// corpora itself, and only a test run_all.ahk includes ever runs.
const ahkRunAll = fs.readFileSync(path.join(SP, 'windows', 'tests', 'run_all.ahk'), 'utf8');
for (const [corpusName, test] of [
	['validation_vectors.json', 'test_workflow_model.ahk'],
	['interpreter_vectors.json', 'test_workflow_interpreter.ahk']
]) {
	const relative = `unit/modules/shortcuts/workflows/${test}`;
	const file = path.join(SP, 'windows', 'tests', ...relative.split('/'));
	const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
	check(text.includes(corpusName), `the Windows suite does not replay ${corpusName}`);
	check(ahkRunAll.includes(`#Include ${relative}`), `run_all.ahk does not include ${relative}`);
}

if (errors.length > 0) {
	for (const message of errors) console.error(`FAIL ${message}`);
	console.error(`[FAIL] user workflow model (${errors.length} of ${checks} checks failed).`);
	process.exit(1);
}
console.log(`[OK] user workflow model (${checks} checks).`);
