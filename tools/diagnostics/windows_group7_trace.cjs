// tools/diagnostics/windows_group7_trace.cjs

/**
 * MODULE: Owned Windows Hook Trace Protocol Reader
 * DESCRIPTION: Validate bounded native and AHK observations without qualifying
 * physical capture, callback order or production handler admission.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const U64_MAX = (1n << 64n) - 1n;
const BACKENDS = ['SendEvent', 'SendInput'];
const CHANNELS = ['hotif', 'hotkey', 'down', 'char', 'up'];

/** @param {unknown} value Exact decimal ABI value. @returns {bigint} */
function u64(value) {
	assert.equal(typeof value, 'string', 'A UInt64 must retain its decimal string representation.');
	assert.match(value, /^(0|[1-9][0-9]*)$/, 'Malformed UInt64.');
	const result = BigInt(value);
	assert(result <= U64_MAX, 'UInt64 overflow.');
	return result;
}

/** @param {object} row Protocol row. @param {string[]} fields Exact keys. @returns {void} */
function keys(row, fields) {
	assert.deepEqual(
		Object.keys(row).sort(),
		[...fields].sort(),
		'Unexpected or missing trace fields.'
	);
}

/** @returns {string} Marker derived from the production native declaration. */
function expectedMarker() {
	const header = fs.readFileSync(
		path.resolve(
			__dirname,
			'../../static/ergopti_plus/windows/native/nav_event_owner/nav_event_owner.h'
		),
		'utf8'
	);
	const match = header.match(/^#define ERGOPTI_NAV_AHK_SEND_LEVEL_BASE (0x[0-9A-Fa-f]+)u$/m);
	assert(match, 'Missing canonical native AHK marker.');
	return '0x' + (BigInt(match[1]) - 31n).toString(16).toUpperCase().padStart(16, '0');
}

/**
 * Preserve native append/completion order separately from hook-entry QPC.
 * @param {string} stdout Exact JSONL from the owned native fixture.
 * @param {{samples:number, sequence:string}} expected Supervisor parameters.
 * @returns {object} Bounded synthetic callback evidence with qualification false.
 */
function readTrace(stdout, expected) {
	assert(Number.isInteger(expected.samples) && expected.samples >= 3 && expected.samples <= 20);
	assert(['ahk-before-native', 'native-before-ahk'].includes(expected.sequence));
	assert(Buffer.byteLength(stdout) <= 1024 * 1024, 'Trace protocol exceeds its bound.');
	const lines = stdout.replace(/\r\n/g, '\n').split('\n');
	assert.equal(lines.pop(), '', 'Trace protocol requires a final newline.');
	assert(lines.length >= 2, 'Missing trace protocol.');
	const rows = lines.map((line) => {
		const row = JSON.parse(line);
		assert(row && !Array.isArray(row) && typeof row === 'object');
		// All protocol rows are flat. Detect duplicate keys before JSON.parse can erase them.
		const names = [...line.matchAll(/"((?:\\.|[^"\\])*)"\s*:/g)].map((match) => match[1]);
		assert(
			names.every((name) => /^[a-z_]+$/.test(name)),
			'Noncanonical trace field spelling.'
		);
		assert.equal(names.length, Object.keys(row).length, 'Duplicate trace field.');
		assert.equal(new Set(names).size, names.length, 'Duplicate trace field.');
		return row;
	});
	const start = rows.shift();
	keys(start, [
		'type',
		'schema',
		'owner',
		'token',
		'generation',
		'qpc_frequency',
		'requested_install_sequence',
		'mode',
		'fixture_codepoint',
		'samples',
		'send_level',
		'send_marker'
	]);
	assert.equal(start.type, 'start');
	assert.equal(start.schema, 1);
	assert.equal(start.mode, 'synthetic');
	assert.equal(start.fixture_codepoint, 97);
	assert.equal(start.samples, expected.samples);
	assert.equal(start.requested_install_sequence, expected.sequence);
	assert.equal(start.send_level, 31);
	assert.equal(start.send_marker, expectedMarker());
	for (const field of ['owner', 'token', 'generation', 'qpc_frequency'])
		assert(u64(start[field]) > 0n);
	const complete = rows.pop();
	keys(complete, [
		'type',
		'native_stop',
		'inputhook_stop',
		'trace_stop',
		'hotkey_stop',
		'hotif_clear',
		'hook_order_qualified',
		'physical_qualified',
		'production_qualified'
	]);
	assert.equal(complete.type, 'complete', 'Missing natural cleanup acknowledgement.');
	for (const field of ['native_stop', 'inputhook_stop', 'trace_stop', 'hotkey_stop', 'hotif_clear'])
		assert.equal(complete[field], true, 'Diagnostic owner remains live.');
	for (const field of ['hook_order_qualified', 'physical_qualified', 'production_qualified'])
		assert.equal(
			complete[field],
			false,
			'The fixture cannot grant native production qualification.'
		);
	const cases = [];
	for (const backend of BACKENDS) {
		for (let sample = 1; sample <= expected.samples; sample++) {
			const caseId = `${backend}-${sample}`;
			const before = rows.shift(),
				after = rows.shift(),
				receiving = rows.shift();
			for (const [row, phase] of [
				[before, 'before'],
				[after, 'after']
			]) {
				keys(row, ['type', 'case_id', 'backend', 'phase', 'qpc']);
				assert.deepEqual(
					[row.type, row.case_id, row.backend, row.phase],
					['emission', caseId, backend, phase],
					'Emission identity/order differs.'
				);
			}
			keys(receiving, ['type', 'case_id', 'backend', 'value_codepoints', 'qpc', 'settled']);
			assert.deepEqual(
				[receiving.type, receiving.case_id, receiving.backend],
				['receiving', caseId, backend]
			);
			assert.deepEqual(
				receiving.value_codepoints,
				[97],
				'Owned receiver changed or duplicated input.'
			);
			assert.equal(receiving.settled, true);
			const first = u64(before.qpc),
				emitted = u64(after.qpc),
				last = u64(receiving.qpc);
			assert(first > 0n && first <= emitted && emitted < last, 'Invalid case QPC interval.');
			if (cases.length) assert(u64(cases.at(-1).last) < first, 'Case windows overlap.');
			cases.push({
				case_id: caseId,
				backend,
				first: before.qpc,
				last: receiving.qpc,
				ahk_channels: Object.fromEntries(CHANNELS.map((name) => [name, 0])),
				native_edges: []
			});
		}
	}
	const ahkRows = [];
	while (rows[0]?.type === 'ahk') {
		const row = rows.shift();
		keys(row, [
			'type',
			'sequence',
			'qpc',
			'channel',
			'case_id',
			...(['down', 'up'].includes(row.channel) ? ['vk', 'sc'] : []),
			...(['hotif', 'hotkey'].includes(row.channel) ? ['registered_fixture'] : []),
			...(row.channel === 'char' ? ['codepoint'] : []),
			...(row.channel === 'hotif' ? ['decision'] : [])
		]);
		assert.equal(
			u64(row.sequence),
			BigInt(ahkRows.length + 1),
			'AHK trace sequence is missing or duplicated.'
		);
		assert(CHANNELS.includes(row.channel), 'Unknown AHK callback.');
		if (['down', 'up'].includes(row.channel)) {
			assert.equal(row.vk, 65);
			assert.equal(row.sc, 30);
		}
		if (['hotif', 'hotkey'].includes(row.channel)) assert.equal(row.registered_fixture, 'a');
		if (row.channel === 'char') assert.equal(row.codepoint, 97);
		if (row.channel === 'hotif') assert.equal(row.decision, true);
		const group = cases.find((item) => item.case_id === row.case_id);
		assert(group, 'AHK callback belongs to an unknown case.');
		const tick = u64(row.qpc);
		assert(
			tick >= u64(group.first) && tick <= u64(group.last),
			'AHK callback lies outside its owned case.'
		);
		group.ahk_channels[row.channel]++;
		ahkRows.push(row);
		assert(ahkRows.length <= 256, 'AHK evidence overflow.');
	}
	const page = rows.shift();
	keys(page, [
		'type',
		'owner',
		'token',
		'generation',
		'attempted',
		'dropped',
		'first_sequence',
		'last_sequence',
		'capacity',
		'stored',
		'page_offset',
		'page_count',
		'enabled',
		'overflow'
	]);
	assert.equal(page.type, 'page');
	for (const field of ['owner', 'token', 'generation'])
		assert.equal(page[field], start[field], 'Stale page identity.');
	assert.equal(u64(page.dropped), 0n, 'Native observations were dropped.');
	assert.equal(page.overflow, 0, 'Native evidence is incomplete.');
	assert.equal(page.enabled, 0, 'Native session was not frozen.');
	assert.equal(page.capacity, 256);
	assert.equal(page.page_offset, 0);
	assert(Number.isInteger(page.stored) && page.stored > 0 && page.stored <= 256);
	assert.equal(page.page_count, page.stored);
	assert.equal(u64(page.attempted), BigInt(page.stored));
	assert.equal(rows.length, page.stored, 'Native page is missing or has extra entries.');
	const firstSequence = u64(page.first_sequence);
	assert(firstSequence > 0n);
	assert.equal(u64(page.last_sequence), firstSequence + BigInt(page.stored - 1));
	for (const [index, row] of rows.entries()) {
		keys(row, [
			'type',
			'sequence',
			'qpc',
			'extra_info',
			'capture_sequence',
			'vk',
			'sc',
			'flags',
			'time',
			'message',
			'decision',
			'reserved'
		]);
		assert.equal(row.type, 'native');
		assert.equal(
			u64(row.sequence),
			firstSequence + BigInt(index),
			'Native append sequence differs.'
		);
		const tick = u64(row.qpc);
		const group = cases.find((item) => tick >= u64(item.first) && tick <= u64(item.last));
		assert(group, 'Native entry lies outside an owned case.');
		assert.equal(row.vk, 65);
		assert.equal(row.sc, 30);
		for (const name of ['flags', 'time', 'message', 'decision', 'reserved'])
			assert(Number.isInteger(row[name]) && row[name] >= 0 && row[name] <= 0xffffffff);
		assert.equal(row.flags & 0x12, 0x10, 'Synthetic evidence lacks trusted injected flags.');
		assert.equal(row.decision, 4, 'Synthetic input must retain injected pass provenance.');
		assert.equal(row.extra_info, start.send_marker, 'Synthetic SendLevel marker differs.');
		assert.equal(
			u64(row.capture_sequence),
			0n,
			'Injected input cannot claim physical FIFO capture.'
		);
		assert.equal(row.reserved, 0);
		assert([0x100, 0x101].includes(row.message), 'Unexpected native key message.');
		assert.equal(Boolean(row.flags & 0x80), row.message === 0x101, 'Native up flag differs.');
		group.native_edges.push(row);
	}
	for (const group of cases) {
		for (const name of CHANNELS)
			assert(group.ahk_channels[name] > 0, `Missing actual ${name} callback: ${group.case_id}`);
		for (const name of ['down', 'char', 'up', 'hotkey'])
			assert.equal(group.ahk_channels[name], 1, `Duplicate ${name} callback.`);
		assert.equal(group.native_edges.length, 2, 'Missing or duplicate actual native edges.');
		assert.equal(group.native_edges.filter((row) => row.message === 0x100).length, 1);
		assert.equal(group.native_edges.filter((row) => row.message === 0x101).length, 1);
	}
	return {
		schema_version: 1,
		mode: 'synthetic',
		requested_install_sequence: expected.sequence,
		qualification: 'synthetic-owned-receiver-callback-observations-only',
		hook_order_qualified: false,
		physical_qualified: false,
		production_qualified: false,
		ahk_attribution_semantics: 'owned-case-and-qpc-window',
		native_sequence_semantics: 'append-completion-order',
		native_qpc_semantics: 'hook-entry-time',
		owner: start.owner,
		token: start.token,
		generation: start.generation,
		qpc_frequency: start.qpc_frequency,
		ahk_observations: ahkRows,
		native_observations: rows,
		cases
	};
}

if (require.main === module) {
	try {
		assert.equal(
			process.argv.length,
			6,
			'Use: node windows_group7_trace.cjs stdout samples sequence output'
		);
		const result = readTrace(fs.readFileSync(process.argv[2], 'utf8'), {
			samples: Number(process.argv[3]),
			sequence: process.argv[4]
		});
		fs.writeFileSync(process.argv[5], JSON.stringify(result, null, 2) + '\n', { flag: 'wx' });
		console.log(
			`Owned synthetic callback trace verified: ${result.cases.length} cases; qualification remains false.`
		);
	} catch (error) {
		console.error(`FAIL hook trace: ${error.message}`);
		process.exitCode = 1;
	}
}
module.exports = { readTrace };
