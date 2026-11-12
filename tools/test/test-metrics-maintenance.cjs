// tools/test/test-metrics-maintenance.cjs

/**
 * ==============================================================================
 * MODULE: Dashboard Export and Purge Contract Test
 * DESCRIPTION:
 * Proves the shared half of the dashboard's Export and Purge (maintainer
 * decision 2026-11-06) against metrics_maintenance_vectors.json.
 *
 * FEATURES & RATIONALE:
 * 1. Replay in SQLite, in every order. The three devices' ledgers replay into
 *    a store built from schema.sql, media_schema.sql and purge_schema.sql in
 *    each of their six orders: whichever order a sync delivers them in, a
 *    purged row never comes back and a later row survives. The same replay
 *    without purge_schema.sql must keep the purged rows, so the assertion can
 *    fail.
 * 2. Every driver installs the triggers where it opens or replays a store,
 *    and Windows renders the vector's names and tombstone.
 * 3. The page sends a confirmed request once, applies only the answer of the
 *    request it owns, and redraws from the store after a committed Purge.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.resolve(__dirname, '..', '..');
const STATIC = path.join(ROOT, 'static', 'ergopti_plus');
const DB_DIR = path.join(STATIC, '_shared', 'data', 'db');
const VECTORS = JSON.parse(
	fs.readFileSync(
		path.join(STATIC, '_shared', 'tests', 'corpus', 'keystats', 'metrics_maintenance_vectors.json'),
		'utf8'
	)
);

// node:sqlite prints an experimental-feature warning on first use; it is not a
// test outcome, so the module is loaded with that one warning silenced.
const silenced = process.emitWarning;
process.emitWarning = (warning, ...rest) =>
	String(warning).includes('SQLite') ? undefined : silenced.call(process, warning, ...rest);
const { DatabaseSync } = require('node:sqlite');
process.emitWarning = silenced;

let failures = 0;
function check(name, body) {
	try {
		body();
		console.log('  ok   ' + name);
	} catch (error) {
		failures += 1;
		console.error('  FAIL ' + name + '\n       ' + (error && error.stack ? error.stack : error));
	}
}

// ===================================
// ===================================
// ======= 1/ Replay in SQLite =======
// ===================================
// ===================================

const read_sql = (name) => fs.readFileSync(path.join(DB_DIR, name), 'utf8');

function permutations(items) {
	if (items.length <= 1) return [items];
	return items.flatMap((item, index) =>
		permutations(items.filter((_, other) => other !== index)).map((rest) => [item, ...rest])
	);
}

/**
 * Replays the vector ledgers into a fresh store, in one device order.
 * @param {string[]} order - Device ids, in replay order.
 * @param {boolean} with_purge - Whether purge_schema.sql is installed.
 * @returns {{raw: string[], derived: string[]}} Surviving rows.
 */
function replay(order, with_purge) {
	const db = new DatabaseSync(':memory:');
	db.exec(read_sql('schema.sql'));
	db.exec(read_sql('media_schema.sql'));
	if (with_purge) db.exec(read_sql('purge_schema.sql'));
	const replay_vectors = VECTORS.replay;
	const device = db.prepare(
		"INSERT INTO devices (device_id, name, os, os_version, host_signature, created_at, updated_at) VALUES (?, ?, ?, '', '', '', '')"
	);
	for (const entry of replay_vectors.devices)
		device.run(entry.device_id, entry.device_id, entry.os);
	for (const row of replay_vectors.derived)
		db.prepare(`INSERT INTO ${row.table} (device_id, date) VALUES (?, ?)`).run(
			row.device_id,
			row.date
		);
	const system = db.prepare(
		'INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES (?, ?, ?, ?, ?, ?)'
	);
	for (const device_id of order)
		for (const row of replay_vectors.ledgers[device_id]) {
			assert.equal(row.table, 'events_system', 'the vectors replay system rows only');
			system.run(device_id, row.id, row.ts, row.date, row.action, row.metadata_json ?? null);
		}
	const raw = db
		.prepare('SELECT device_id, id, action FROM events_system ORDER BY device_id, id')
		.all()
		.map((row) => `${row.device_id}:${row.id}:${row.action}`);
	const derived = db
		.prepare('SELECT device_id, date FROM agg_system_day ORDER BY device_id, date')
		.all()
		.map((row) => `${row.device_id}:${row.date}`);
	db.close();
	return { raw, derived };
}

const ORDERS = permutations(Object.keys(VECTORS.replay.ledgers));

check('purge-replay: every ledger order keeps exactly the rows after the tombstone', () => {
	assert.equal(ORDERS.length, 6);
	for (const order of ORDERS) {
		const result = replay(order, true);
		assert.deepEqual(result.raw, VECTORS.replay.surviving, 'order ' + order.join(' > '));
		assert.deepEqual(
			result.derived,
			VECTORS.replay.surviving_derived,
			'order ' + order.join(' > ')
		);
	}
});

check('purge-replay-control: without the purge triggers the purged rows come back', () => {
	const result = replay(ORDERS[0], false);
	assert.ok(
		result.raw.length > VECTORS.replay.surviving.length,
		'the replay assertion could not fail'
	);
});

check('purge-schema-idempotent: installing the triggers twice changes nothing', () => {
	const db = new DatabaseSync(':memory:');
	db.exec(read_sql('schema.sql'));
	db.exec(read_sql('media_schema.sql'));
	db.exec(read_sql('purge_schema.sql'));
	db.exec(read_sql('purge_schema.sql'));
	const triggers = db
		.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type='trigger'")
		.get().n;
	const raw_tables = db
		.prepare(
			"SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name LIKE 'events\\_%' ESCAPE '\\'"
		)
		.get().n;
	assert.equal(triggers, raw_tables + 1, 'one apply trigger and one guard per raw table');
	db.close();
});

check('purge-schema-coverage: every raw and derived table of the shared schema is purged', () => {
	const schema = read_sql('schema.sql') + read_sql('media_schema.sql');
	const purge = read_sql('purge_schema.sql');
	const tables = [...schema.matchAll(/CREATE TABLE IF NOT EXISTS (\w+) \(/g)].map(
		(match) => match[1]
	);
	for (const table of tables.filter((name) => /^(events|agg|ngram)_/.test(name)))
		assert.ok(purge.includes(`DELETE FROM ${table} WHERE`), `${table} is not purged`);
	for (const table of tables.filter((name) => name.startsWith('events_')))
		assert.ok(purge.includes(`BEFORE INSERT ON ${table}\n`), `${table} has no guard`);
});

// ======================================
// ======================================
// ======= 2/ Driver Installation =======
// ======================================
// ======================================

const read = (relative) => fs.readFileSync(path.join(STATIC, relative), 'utf8');

check(
	'purge-schema-installed: every driver installs the triggers where it opens or replays a store',
	() => {
		for (const relative of [
			'linux/modules/keystats/sqlite_writer.lua',
			'macos/modules/keystats/sqlite_writer.lua',
			'windows/modules/keystats/keystats_reader_db.ahk'
		])
			assert.match(read(relative), /data[\\/]+db[\\/]+purge_schema\.sql/, relative);
		assert.match(
			read('windows/modules/keystats/keystats_reader_db.ahk'),
			/KLR_ApplyIncremental\(db, tails, logPath\) \{[\s\S]{0,400}KLR_LoadPurgeSchema\(db\)/,
			'a restored Windows image installs the triggers before applying a tail'
		);
	}
);

check('windows-vectors: the Windows module renders the shared names and tombstone', () => {
	const source = read('windows/modules/keystats/keystats_maintenance.ahk');
	assert.ok(source.includes(`TOMBSTONE_ACTION := "${VECTORS.tombstone.action}"`));
	assert.ok(source.includes(`EXPORT_PREFIX := "${VECTORS.export.prefix}"`));
	assert.ok(source.includes(`EXPORT_EXTENSION := "${VECTORS.export.extension}"`));
	assert.ok(source.includes('"yyyy-MM-dd_HH-mm-ss"'), 'the export name format');
	// KMD-1: the tombstone's utc is the very ts its events_system row stores,
	// milliseconds kept, so both must come from the one local-to-UTC converter.
	assert.match(
		source,
		/KL_MetricsTombstone\(LocalTs\) \{[\s\S]{0,300}"utc", KL_TimestampFromLocal\(LocalTs\)\["ts"\]\)/,
		'the tombstone carries the UTC instant of its journal stamp'
	);
	assert.match(
		read('windows/modules/keystats/keystats_sql.ahk'),
		/KL_EventTime\(e\) \{[\s\S]{0,200}Instant := KL_TimestampFromLocal\(LocalTs\)[\s\S]{0,100}"ts", Instant\["ts"\]/,
		'the events_system row stores the same UTC instant'
	);
	assert.ok(source.includes(`KeystatsQuery("${VECTORS.export.query}"`));
	assert.ok(read('windows/_generated/keystats_queries.ahk').includes(`"${VECTORS.export.query}"`));
});

// ============================
// ============================
// ======= 3/ Page Flow =======
// ============================
// ============================

function page() {
	const elements = new Map();
	const element = (id) => {
		if (!elements.has(id)) elements.set(id, { id, hidden: true, disabled: false, textContent: '' });
		return elements.get(id);
	};
	const posted = [];
	const timers = [];
	const context = {
		document: { getElementById: element },
		window: { chrome: { webview: { postMessage: (message) => posted.push(JSON.parse(message)) } } },
		_t: (key) => (key === 'ui_typing.maintenance_export_done' ? 'exported {path}' : key),
		hostHasCapability: () => false,
		setTimeout: (fn) => timers.push(fn),
		clearTimeout: () => {},
		resets: 0
	};
	context.request_cache_reset = () => {
		context.resets += 1;
	};
	vm.createContext(context);
	vm.runInContext(read('_shared/ui/metrics_typing/maintenance.js'), context);
	return { context, element, posted, timers };
}

check('page-confirmation: nothing is sent before Confirm, and Cancel sends nothing', () => {
	const { context, posted } = page();
	assert.equal(vm.runInContext("ask_metrics_maintenance('purge')", context), true);
	assert.equal(posted.length, 0);
	vm.runInContext('cancel_metrics_maintenance()', context);
	assert.equal(vm.runInContext('confirm_metrics_maintenance()', context), 0);
	assert.equal(posted.length, 0);
	assert.equal(vm.runInContext("ask_metrics_maintenance('drop')", context), false);
});

check(
	'page-ownership: only the active request completes, and a Purge redraws from the store',
	() => {
		const { context, element, posted } = page();
		vm.runInContext("ask_metrics_maintenance('purge')", context);
		const id = vm.runInContext('confirm_metrics_maintenance()', context);
		assert.deepEqual(posted, [{ action: 'metrics_purge', maintenance_id: id }]);
		assert.equal(element('btn_metrics_purge').disabled, true);
		assert.equal(
			vm.runInContext("ask_metrics_maintenance('export')", context),
			false,
			'one request at a time'
		);
		assert.equal(
			vm.runInContext(`complete_metrics_maintenance(${id + 1}, true, null)`, context),
			false
		);
		assert.equal(
			vm.runInContext(`complete_metrics_maintenance(${id}, 1, null)`, context),
			false,
			'ok is a boolean'
		);
		assert.equal(vm.runInContext(`complete_metrics_maintenance(${id}, true, null)`, context), true);
		assert.equal(context.resets, 1);
		assert.equal(
			element('metrics_maintenance_text').textContent,
			'ui_typing.maintenance_purge_done'
		);
		assert.equal(
			vm.runInContext(`complete_metrics_maintenance(${id}, true, null)`, context),
			false,
			'answered once'
		);
	}
);

check(
	'page-export: the outcome names the copy, a failure does not redraw, the watchdog releases',
	() => {
		const { context, element, timers } = page();
		vm.runInContext("ask_metrics_maintenance('export')", context);
		let id = vm.runInContext('confirm_metrics_maintenance()', context);
		vm.runInContext(
			`complete_metrics_maintenance(${id}, true, '/tmp/Downloads/x.sqlite')`,
			context
		);
		assert.equal(
			element('metrics_maintenance_text').textContent,
			'exported /tmp/Downloads/x.sqlite'
		);
		vm.runInContext("ask_metrics_maintenance('purge')", context);
		id = vm.runInContext('confirm_metrics_maintenance()', context);
		vm.runInContext(`complete_metrics_maintenance(${id}, false, null)`, context);
		assert.equal(context.resets, 0);
		assert.equal(
			element('metrics_maintenance_text').textContent,
			'ui_typing.maintenance_purge_failed'
		);
		vm.runInContext("ask_metrics_maintenance('export')", context);
		id = vm.runInContext('confirm_metrics_maintenance()', context);
		timers[timers.length - 1]();
		assert.equal(element('metrics_maintenance_text').textContent, 'ui_typing.maintenance_timeout');
		assert.equal(
			vm.runInContext(`complete_metrics_maintenance(${id}, true, null)`, context),
			false,
			'late answer ignored'
		);
		assert.equal(element('btn_metrics_export').disabled, false);
	}
);

if (failures > 0) {
	console.error(`test-metrics-maintenance: ${failures} failure(s).`);
	process.exit(1);
}
console.log('test-metrics-maintenance: all checks passed.');
