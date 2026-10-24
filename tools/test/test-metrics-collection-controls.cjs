// tools/test/test-metrics-collection-controls.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Pause And Session Reset, One Surface On Three Drivers
 * DESCRIPTION:
 * The Metrics menu's pause and session-reset rows used to be Linux-only, and the
 * Linux pause shared the password-field flag, so moving focus out of a password
 * manager silently ended a pause the user had set. This gate pins the contract
 * (docs/design/metrics-suspend-and-reset-session.md):
 *   - both rows are declared for all three platforms with no reason (nothing
 *     restricts them any more);
 *   - each driver wires both rows and the tick state to its own keystats module;
 *   - the pause is a state of its own on every driver;
 *   - the shared operation sequences are replayed by every driver's suite;
 *   - the Windows capture paths ask one helper whether to stay silent, and the
 *     chokepoint consults the pause, so a new capture source cannot bypass it.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = 'static/ergopti_plus';
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), 'utf8');
const failures = [];

function check(label, body) {
	try {
		body();
	} catch (error) {
		failures.push(`${label}: ${error.message}`);
	}
}

// 1. The rows are unrestricted.
check('manifest rows', () => {
	const menu = JSON.parse(read(`${PLUS}/_shared/modules/menu/menu_manifest.json`));
	const rows = menu.metrics_menu;
	for (const id of ['metrics_suspend', 'metrics_reset_session']) {
		const row = rows.find((item) => item.id === id);
		assert(row, `${id} must be declared in the metrics menu`);
		assert(row.platforms === undefined, `${id} must not restrict its platforms`);
		assert(row.reason_key === undefined, `${id} must not carry a platform reason`);
	}
	const suspend = rows.find((item) => item.id === 'metrics_suspend');
	assert.deepStrictEqual(
		suspend.checked_when,
		['metrics_suspended'],
		'the tick reads the pause state'
	);
	assert.strictEqual(
		suspend.i18n,
		'menu.metrics.suspend_collection',
		'the label names the metrics pause'
	);
});

// 2. Each driver wires the rows to its own keystats.
const wiring = {
	windows: {
		menu: `${PLUS}/windows/ui/menu/menu_metrics.ahk`,
		patterns: [/"metrics_suspend"\s*,/, /"metrics_reset_session"\s*,/, /"metrics_suspended"\s*,/]
	},
	macos: {
		menu: `${PLUS}/macos/ui/menu/menu_metrics.lua`,
		patterns: [
			/\["metrics_suspend"\]\s*=/,
			/\["metrics_reset_session"\]\s*=/,
			/metrics_suspended\s*=/
		]
	},
	linux: {
		menu: `${PLUS}/linux/ui/menu/menu_builder.lua`,
		patterns: [
			/\["metrics_suspend"\]\s*=/,
			/\["metrics_reset_session"\]\s*=/,
			/metrics_suspended\s*=/
		]
	}
};
for (const [driver, spec] of Object.entries(wiring)) {
	check(`${driver} menu wiring`, () => {
		const source = read(spec.menu);
		for (const pattern of spec.patterns)
			assert(pattern.test(source), `${spec.menu} lacks ${pattern}`);
	});
}

// 3. The pause is its own state, never the password flag.
check('linux pause state', () => {
	const source = read(`${PLUS}/linux/modules/keystats/keystats.lua`);
	assert(/^local _suspended = false$/m.test(source), 'Linux keystats keeps a state of its own');
	assert(/function M\.suspend_collection\(\)/.test(source), 'Linux exposes suspend_collection');
	assert(/function M\.resume_collection\(\)/.test(source), 'Linux exposes resume_collection');
	const menu = read(`${PLUS}/linux/ui/menu/menu_builder.lua`);
	const row = menu.slice(
		menu.indexOf('["metrics_suspend"]'),
		menu.indexOf('["reset_wpm_position"]')
	);
	assert(
		!/\bsuppress\(|unsuppress\(|is_suppressed/.test(row),
		'the menu row must not drive the password flag'
	);
});
check('macos pause state', () => {
	const source = read(`${PLUS}/macos/modules/keystats/init.lua`);
	assert(/function M\.suspend_collection\(\)/.test(source), 'macOS exposes suspend_collection');
	assert(/function M\.reset_session\(\)/.test(source), 'macOS exposes reset_session');
	const privacy = read(`${PLUS}/macos/modules/keystats/privacy_context.lua`);
	assert(
		/state\.collection_suspended/.test(privacy),
		'the shared recording gate consults the pause'
	);
});
check('windows pause state', () => {
	const source = read(`${PLUS}/windows/modules/keystats/keystats_collection.ahk`);
	assert(/static suspended := false/.test(source), 'Windows keeps the pause in its own class');
	assert(/^KL_ResetSession\(/m.test(source), 'Windows exposes the session reset');
});

// 4. Every driver replays the shared sequences.
const CORPUS = 'tests/corpus/metrics/collection_session_vectors.json';
check('shared vectors exist', () => {
	const corpus = JSON.parse(read(`${PLUS}/_shared/${CORPUS}`));
	assert(corpus.vectors.length >= 8, 'the corpus must hold the sequences');
	const ids = new Set(corpus.vectors.map((vector) => vector.id));
	assert.strictEqual(ids.size, corpus.vectors.length, 'vector ids must be unique');
});
check('linux replays the vectors', () => {
	const source = read(`${PLUS}/linux/tests/meta/corpus/test_corpus_metrics_collection_session.lua`);
	assert(source.includes('corpus/metrics/collection_session_vectors.json'));
	assert(
		read(`${PLUS}/linux/tests/test_manifest.lua`).includes('test_corpus_metrics_collection_session')
	);
});
check('macos replays the vectors', () => {
	const source = read(
		`${PLUS}/macos/tests/unit/modules/keystats/lifecycle/test_keystats_privacy.lua`
	);
	assert(source.includes('corpus/metrics/collection_session_vectors.json'));
});
check('windows replays the vectors', () => {
	const source = read(`${PLUS}/windows/tests/unit/modules/keystats/test_keystats_collection.ahk`);
	assert(source.includes('collection_session_vectors.json'));
});

// 5. The Windows capture paths cannot bypass the pause.
check('windows capture sources', () => {
	const dir = `${PLUS}/windows/modules/keystats`;
	const mouse = read(`${dir}/keystats_mouse.ahk`);
	assert(
		!/\bA_IsSuspended\b/.test(mouse.replace(/^\s*;.*$/gm, '')),
		'mouse capture asks KL_CaptureHeld, not A_IsSuspended'
	);
	const hook = read(`${dir}/keystats_hook.ahk`);
	for (const name of [
		'KL_Hook_OnChar',
		'KL_Hook_OnKeyDown',
		'_KL_Hook_CaptureInput',
		'_KL_Hook_InputLifecycleCurrent'
	]) {
		const start = hook.search(new RegExp('^' + name + '\\(', 'm'));
		assert(start >= 0, `${name} must exist`);
		assert(
			/KL_CaptureHeld\(\)/.test(hook.slice(start, start + 600)),
			`${name} must ask KL_CaptureHeld`
		);
	}
	const keystats = read(`${dir}/keystats.ahk`);
	const appendStart = keystats.indexOf('KL_AppendLog(entry');
	const appendBody = keystats.slice(appendStart, appendStart + 9000);
	assert(
		(appendBody.match(/KLCollection\.suspended/g) || []).length >= 2,
		'KL_AppendLog checks the pause at both gates'
	);
});

if (failures.length > 0) {
	console.error(`test-metrics-collection-controls: ${failures.length} failure(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log('test-metrics-collection-controls: ok');
