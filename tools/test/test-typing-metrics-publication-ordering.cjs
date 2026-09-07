/**
 * tools/test/test-typing-metrics-publication-ordering.cjs
 * ==============================================================================
 * MODULE: Typing Metrics Publication Ordering
 * DESCRIPTION:
 * Replays actual dashboard state updates and Lua publication scripts in FIFO order.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { actualLuaPublications, actualLuaFallback } = require('./support/typing-publication-fixture.cjs');
const root = path.resolve(__dirname, '../../static/ergopti_plus');
const source = fs.readFileSync(path.join(root, '_shared/ui/metrics_typing/data.js'), 'utf8');
let passed = 0;
let failed = 0;

function fixture() {
	const state = { did_apply_initial_reset: true, selected_apps: new Set(), app_selection_mode: 'all',
		available_apps: [], loading_data: true, range_request_sequence: 0 };
	const context = vm.createContext({ app_state: state,
		APP_SELECTION_MODE: { ALL: 'all', UNINITIALIZED: 'uninitialized', NONE: 'none' },
		document: { getElementById() { return { value: '2026-09-01' }; } } });
	context.window = context;
	vm.runInContext(source, context);
	vm.runInContext('compute_manifest_metrics=function(){};update_app_btn_text=function(){};ensure_live_refresh=function(){};render_current_tab=function(){};', context);
	return { context, state, publish: context.publishTypingMetricsData };
}

const manifest = (app) => ({ '2026-09-01': { [app]: { chars: 1 } } });
const snapshot = (app) => ({ manifest: manifest(app), initial_data: { marker: app },
	app_icons: { [app]: 'icon' }, kc_layout: { 0: app } });
const revisions = (manifestRevision, assetsRevision) => ({ manifest_revision: manifestRevision,
	...(assetsRevision === undefined ? {} : { assets_revision: assetsRevision }) });

function test(name, callback) {
	try { callback(); passed++; console.log(`ok ${name}`); }
	catch (error) { failed++; console.error(`FAIL ${name}: ${error.message}`); }
}

test('cache paints while fresh submission has not executed', () => {
	const f = fixture();
	const pendingFresh = () => f.publish(snapshot('Fresh'), revisions(1, 1));
	assert.equal(f.publish(snapshot('Cache'), revisions(0, 0)), true);
	assert.deepEqual(Array.from(f.state.available_apps), ['Cache']);
	assert.equal(pendingFresh(), true);
	assert.deepEqual(Array.from(f.state.available_apps), ['Fresh']);
});

test('late startup fills assets without rolling back live manifest or prefetch', () => {
	const f = fixture();
	assert.equal(f.publish({ manifest: manifest('Live') }, revisions(2)), true);
	assert.equal(f.context._prefetch_data, null);
	let queries = 0;
	let renders = 0;
	f.state.loading_data = false;
	f.state.active_range_request_id = 77;
	f.context.request_range_data = () => { queries++; };
	f.context.compute_manifest_metrics = () => { throw new Error('assets must not recompute manifest'); };
	f.context.render_current_tab = () => { renders++; };
	assert.equal(f.publish(snapshot('Startup'), revisions(1, 1)), true);
	assert.equal(queries, 0);
	assert.equal(renders, 1);
	assert.equal(f.state.active_range_request_id, 77);
	assert.deepEqual(Array.from(f.state.available_apps), ['Live']);
	assert.equal(f.context._prefetch_data, null);
	assert.deepEqual(f.context.app_icons, { Startup: 'icon' });
	assert.deepEqual(f.context.keycode_layout, { 0: 'Startup' });
	assert.equal(f.publish(snapshot('Cache'), revisions(0, 0)), false);
	assert.equal(queries, 0);
	assert.equal(renders, 1);
	assert.deepEqual(Array.from(f.state.available_apps), ['Live']);
});

test('duplicate publication cannot reset current range ownership or render again', () => {
	const f = fixture();
	f.publish(snapshot('Fresh'), revisions(1, 1));
	f.state.active_range_request_id = 77;
	f.context.compute_manifest_metrics = () => { throw new Error('stale render must not run'); };
	assert.equal(f.publish(snapshot('Duplicate'), revisions(1, 1)), false);
	assert.equal(f.state.active_range_request_id, 77);
});

test('each page begins with independent cache authority', () => {
	const first = fixture();
	first.publish(snapshot('New'), revisions(9, 9));
	const second = fixture();
	assert.equal(second.publish(snapshot('Cache'), revisions(0, 0)), true);
	assert.deepEqual(Array.from(first.state.available_apps), ['New']);
	assert.deepEqual(Array.from(second.state.available_apps), ['Cache']);
});

for (const value of [null, -1, 1.5, Infinity, Number.MAX_SAFE_INTEGER + 1, '1']) {
	test(`invalid manifest revision leaves state untouched: ${String(value)}`, () => {
		const f = fixture();
		assert.throws(() => f.publish(snapshot('Invalid'), revisions(value, 1)), /revision/i);
		assert.equal(f.context.metrics_manifest, undefined);
		assert.equal(f.publish(snapshot('Cache'), revisions(0, 0)), true);
	});
}

test('invalid asset revision cannot partially publish a valid manifest', () => {
	const f = fixture();
	assert.throws(() => f.publish(snapshot('Invalid'), revisions(9, -1)), /revision/i);
	assert.equal(f.context.metrics_manifest, undefined);
	assert.equal(f.publish(snapshot('Cache'), revisions(0, 0)), true);
});

test('missing revision metadata fails before changing visible data', () => {
	const f = fixture();
	assert.throws(() => f.publish(snapshot('Invalid')), /revision/i);
	assert.equal(f.context.metrics_manifest, undefined);
});

test('render failure retains already-applied watermarks', () => {
	const f = fixture();
	f.context.compute_manifest_metrics = () => { throw new Error('render refused'); };
	assert.throws(() => f.publish(snapshot('Newest'), revisions(3, 3)), /render refused/);
	assert.deepEqual(f.context.metrics_manifest, manifest('Newest'));
	f.context.compute_manifest_metrics = () => {};
	assert.equal(f.publish(snapshot('Old'), revisions(2, 2)), false);
	assert.deepEqual(f.context.metrics_manifest, manifest('Newest'));
});

test('render reentry cannot reclaim a revision already superseded inside the render', () => {
	const f = fixture();
	f.context.compute_manifest_metrics = () => {
		f.context.compute_manifest_metrics = () => {};
		f.publish({ manifest: manifest('Newest') }, revisions(3));
	};
	f.publish(snapshot('First'), revisions(1, 1));
	assert.equal(f.publish({ manifest: manifest('Older') }, revisions(2)), false);
	assert.deepEqual(Array.from(f.state.available_apps), ['Newest']);
});

test('legacy Windows and Linux process_manifest calls retain replacement semantics', () => {
	const f = fixture();
	f.context.metrics_manifest = manifest('Legacy1');
	f.context.process_manifest();
	assert.deepEqual(Array.from(f.state.available_apps), ['Legacy1']);
	f.context.metrics_manifest = manifest('Legacy2');
	f.context.process_manifest();
	assert.deepEqual(Array.from(f.state.available_apps), ['Legacy2']);
});


test('actual FIFO Lua startup retry cannot roll back an applied live snapshot', () => {
	const scripts = actualLuaPublications();
	const f = fixture();
	assert.equal(vm.runInContext(scripts[0], f.context), true);
	assert.deepEqual(Array.from(f.state.available_apps), ['Live']);
	assert.equal(vm.runInContext(scripts[1], f.context), true, 'older startup must still supply previously absent assets');
	assert.deepEqual(Array.from(f.state.available_apps), ['Live']);
	assert.equal(f.context._prefetch_data, null);
});

test('actual Lua cold-empty payload accepts native empty-map arrays', () => {
	const scripts = actualLuaPublications(true);
	assert.match(scripts[0], /"manifest":\[\]/);
	assert.match(scripts[1], /"app_icons":\[\]/);
	assert.match(scripts[1], /"kc_layout":\[\]/);
	const f = fixture();
	f.state.did_apply_initial_reset = false;
	f.state.loading_data = false;
	const elements = new Map();
	f.context.document.getElementById = (id) => {
		if (!elements.has(id)) elements.set(id, { value: '', innerHTML: '', classList: { add() {} } });
		return elements.get(id);
	};
	f.context.setTimeout = () => 1;
	f.context.clearTimeout = () => {};
	const stateSource = fs.readFileSync(path.join(root, '_shared/ui/metrics_typing/state.js'), 'utf8');
	const watchdog = stateSource.match(/const RANGE_REQUEST_WATCHDOG_MS = ([\d_]+);/);
	assert.ok(watchdog);
	f.context.RANGE_REQUEST_WATCHDOG_MS = Number(watchdog[1].replaceAll('_', ''));
	vm.runInContext(fs.readFileSync(path.join(root, '_shared/ui/metrics_typing/filters.js'), 'utf8'), f.context);
	f.context.apply_default_date_range = () => {};
	f.context.ensure_live_refresh = () => {};
	f.context.update_app_btn_text = () => {};
	assert.equal(vm.runInContext(scripts[0], f.context), true);
	assert.equal(f.state.did_apply_initial_reset, true, 'cold publication must complete the actual initial reset');
	assert.equal(vm.runInContext(scripts[1], f.context), true);
	assert.deepEqual(Array.from(f.state.available_apps), []);
	assert.equal(f.context.metrics_manifest.length, 0);
	assert.equal(f.context.app_icons.length, 0);
	assert.equal(f.context.keycode_layout.length, 0);
});

test('nonempty array maps cannot corrupt a valid publication', () => {
	const f = fixture();
	assert.throws(() => f.publish({ manifest: ['invalid'] }, revisions(1)), /maps/);
	assert.throws(() => f.publish({ ...snapshot('Invalid'), app_icons: ['invalid'] }, revisions(1, 1)), /maps/);
	assert.equal(f.context.metrics_manifest, undefined);
	assert.equal(f.publish(snapshot('Cache'), revisions(0, 0)), true);
});

test('actual Lua refused fresh admission leaves delayed cache eligible', () => {
	const publications = actualLuaFallback();
	const f = fixture();
	// The refused fresh script never executes in the page
	assert.equal(publications[0].admitted, false);
	assert.equal(vm.runInContext(publications[1].code, f.context), true);
	assert.deepEqual(Array.from(f.state.available_apps), ['Cache']);
});

console.log(`typing metrics publication ordering: ${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
