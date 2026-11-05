// tools/test/test-typing-metrics-partial-live.cjs
// Exercise real partial-today delivery across replacement, calendar and app-key boundaries.
'use strict';
const assert = require('node:assert/strict');
const { frontend, bootstrapFrontend } = require('./support/typing-reset-fixture.cjs');
const deep = { pg: { abcde: { c: 1 } }, hx: { abcdef: { c: 1 } }, hp: { abcdefg: { c: 1 } } };
function receive(f, today, day = '2026-09-07', partial = []) {
	return f.context.receive_range_data({
		historical: {},
		today,
		today_date: day,
		today_partial_types: partial
	});
}
const f = frontend('windows');
assert.equal(receive(f, { Editor: { ...deep, c: { a: { c: 1 } } } }), true);
assert.equal(receive(f, { Editor: { c: { b: { c: 2 } } } }, undefined, ['pg', 'hx', 'hp']), true);
assert.equal(f.state.today_live_data.Editor.pg.abcde.c, 1);
assert.equal(f.state.today_live_data.Editor.c.a, undefined);
assert.equal(f.state.today_live_data.Editor.c.b.c, 2);
assert.equal(receive(f, {}, '2026-09-08', ['pg', 'hx', 'hp']), true);
assert.equal(
	Object.keys(f.state.today_live_data).length,
	0,
	'new day cannot inherit old deep rows'
);
receive(f, { Editor: deep }, '2026-09-08');
receive(f, {}, '2026-09-08');
assert.equal(
	Object.keys(f.state.today_live_data).length,
	0,
	'complete empty replaces retained rows'
);
const dangerous = JSON.parse(
	'{"__proto__":{"pg":{"old":{"c":1}}},"constructor":{"hx":{"sixsix":{"c":1}}}}'
);
receive(f, dangerous);
receive(f, JSON.parse('{"__proto__":{"c":{"new":{"c":2}}}}'), undefined, ['pg', 'hx', 'hp']);
assert.equal(Object.getPrototypeOf(f.state.today_live_data), null);
assert.equal(f.state.today_live_data.__proto__.pg.old.c, 1);
assert.equal(f.state.today_live_data.__proto__.c.new.c, 2);
assert.equal(f.state.today_live_data.constructor.hx.sixsix.c, 1);
const before = f.state.today_live_data;
assert.throws(
	() => f.context.receive_range_data({ today: {}, today_partial_types: ['pg'] }),
	/date/
);
assert.equal(
	f.state.today_live_data,
	before,
	'malformed metadata does not mutate current projection'
);
f.state.current_tab = 'pg';
f.state.today_partial_types = ['pg'];
f.elements.date_start.value = f.elements.date_end.value = '2026-09-01';
assert.equal(
	f.context.request_partial_today_refresh(),
	false,
	'past-only selection does not fetch omitted today'
);
f.state.current_tab = 'c';
f.elements.date_end.value = '2026-09-07';
assert.equal(
	f.context.request_partial_today_refresh(),
	false,
	'ordinary live tab does not fetch deep tables'
);
console.log(
	'PASS partial-contracts same-day, new-day, complete-empty, prototype-app, malformed, scopes'
);

{
	const f = bootstrapFrontend('windows'),
		m = { c: 1, t: 0, e: 0, hs: 0, llm: 0, o: 0 };
	const manifest = {
		'2026-09-06': { Editor: { chars: 2 } },
		'2026-09-07': { Editor: { chars: 1 } }
	};
	f.push({
		metrics_manifest: manifest,
		_prefetch_data: {
			historical: { c: { all_time: { ...m, c: 9 } } },
			today: {},
			today_date: '2026-09-07'
		}
	});
	f.select('2026-09-06');
	f.dispatch();
	const request = f.requests.filter((x) => x.action === 'range').at(-1);
	assert.ok(request);
	assert.equal(
		f.context.receive_range_data(
			{ historical: { c: { selected: m } }, today: {}, today_date: '2026-09-07', incomplete: true },
			request.request_id
		),
		true
	);
	const selected = f.state.historical_cache;
	f.push({
		metrics_manifest: manifest,
		_prefetch_data: {
			today: { Editor: { c: { new: m } } },
			today_date: '2026-09-07',
			today_partial_types: ['pg', 'hx', 'hp']
		}
	});
	assert.equal(f.state.historical_cache, selected);
	assert.equal(f.state.historical_cache_incomplete, true);
	console.log(
		'PASS explicit partial delivery preserves selected history identity and incomplete provenance'
	);
}
