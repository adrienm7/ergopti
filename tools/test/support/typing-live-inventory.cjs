// tools/test/support/typing-live-inventory.cjs
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { bootstrapFrontend } = require('./typing-reset-fixture.cjs');

const [root, mode] = process.argv.slice(2);
assert.ok(root && ['chars', 'deep'].includes(mode));
const read = (name) =>
	JSON.parse(fs.readFileSync(path.join(root, name), 'utf8').replace(/^\uFEFF/, ''));
const full = read('full.json'),
	live = read('live.json'),
	range = read('range.json');
const day = Object.keys(full.metrics_manifest)[0];
const table = path.resolve(
	__dirname,
	'../../../static/ergopti_plus/_shared/ui/metrics_typing/table.js'
);
const specs =
	mode === 'chars'
		? [['c', 'a']]
		: [
				['pg', 'abcde'],
				['hx', 'abcdef'],
				['hp', 'abcdefg']
			];
const issues = [];
for (const [kind, token] of specs) {
	const f = bootstrapFrontend('windows');
	f.context.get_local_date_string = () => day;
	f.elements.date_start.value = f.elements.date_end.value = day;
	f.context.document.querySelectorAll = () => [];
	f.context.document.querySelector = () => null;
	const frames = new Map();
	let serial = 0,
		answered = 0,
		updated = false;
	f.context.requestAnimationFrame = (fn) => {
		const id = ++serial;
		frames.set(id, fn);
		return id;
	};
	f.context.cancelAnimationFrame = (id) => frames.delete(id);
	// Keep genuine tab selection, data preparation and table rendering. Only DOM
	// surfaces and native delivery are controlled by this existing VM fixture.
	vm.runInContext(fs.readFileSync(table, 'utf8'), f.context, { filename: table });
	function pump() {
		for (let round = 0; round < 30; round++) {
			f.dispatch();
			for (const [id, fn] of [...frames]) {
				frames.delete(id);
				fn();
			}
			const pending = f.requests.filter((request) => request.action === 'range');
			while (answered < pending.length) {
				const request = pending[answered++];
				assert.equal(request.start_date, day);
				assert.equal(request.end_date, day);
				assert.ok(request.apps.includes('fixture.exe'));
				// This is the actual native producer's selected-range result; no
				// invented deep-token data is inserted into frontend state.
				assert.equal(
					f.context.receive_range_data(updated ? range : full._prefetch_data, request.request_id),
					true
				);
			}
			if (!frames.size && ![...f.timers.values()].some((timer) => timer.delay === 50)) break;
		}
	}
	const count = () => f.state.data[kind]?.[token]?.count || 0;
	f.push(full);
	pump();
	f.context.switch_tab(kind);
	pump();
	assert.equal(count(), 1, `actual initial full projection ${kind}`);
	updated = true;
	f.push(live);
	pump();
	console.log(`LIVE_INVENTORY kind=${kind} after_push=${count()} native_ranges=${answered}`);
	if (count() < 1) issues.push(`${kind}: live delivery erased the visible inventory`);
	if (mode === 'deep') {
		f.context.switch_tab('c');
		pump();
		f.context.switch_tab(kind);
		pump();
	}
	console.log(`LIVE_INVENTORY kind=${kind} selected_count=${count()} native_ranges=${answered}`);
	if (count() !== 2) issues.push(`${kind}: selected count ${count()} instead of 2`);
}
assert.deepEqual(
	issues,
	[],
	'the genuine frontend must retain and refresh visible typing inventory'
);
console.log(`PASS live-inventory-composed ${mode}`);
