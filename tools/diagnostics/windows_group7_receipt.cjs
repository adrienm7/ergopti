// tools/diagnostics/windows_group7_receipt.cjs

/** Strict receiving protocol reader; native qualification remains case-scoped. */
'use strict';

const fs = require('node:fs');
const assert = require('node:assert/strict');

const HEADER = 'backend,case,sample,send_ms,receive_ms,queued,replayed,mode,install_sequence';
const COMPLETE =
	'COMPLETE exact native Edit receiving; production and physical hook order remain unqualified.';
const BACKENDS = ['SendEvent', 'SendInput'];
const CASES = ['long-text', 'unicode-text', 'clipboard-paste'];

/**
 * Validates complete ordered native observations and summarizes finite samples.
 * @param {string} stdout Exact native stdout.
 * @param {{samples: number, mode: string, sequence: string}} expected Supervisor parameters.
 * @returns {object} Explicitly bounded receiving evidence, never a policy choice.
 */
function readReceipt(stdout, expected) {
	assert(Number.isInteger(expected.samples) && expected.samples >= 3 && expected.samples <= 100);
	assert(['idle', 'physical'].includes(expected.mode));
	assert(['ahk-before-native', 'native-before-ahk'].includes(expected.sequence));
	const lines = stdout.replace(/\r\n/g, '\n').split('\n');
	if (lines.at(-1) === '') lines.pop();
	assert.equal(lines.shift(), HEADER, 'Missing exact CSV protocol header');
	assert.equal(lines.pop(), COMPLETE, 'Missing native retirement/completion acknowledgement');
	assert.equal(
		lines.length,
		expected.samples * BACKENDS.length * CASES.length,
		'Missing or extra observations'
	);
	const groups = [];
	let offset = 0;
	for (const backend of BACKENDS) {
		for (const kind of CASES) {
			const rows = [];
			for (let sample = 1; sample <= expected.samples; sample++) {
				const fields = lines[offset++].split(',');
				assert.equal(fields.length, 9, 'Malformed receiving row');
				assert.deepEqual(
					[fields[0], fields[1], fields[2], fields[7], fields[8]],
					[backend, kind, String(sample), expected.mode, expected.sequence],
					'Observation identity/order changed'
				);
				assert(
					fields.slice(3, 5).every((value) => /^\d+\.\d{4}$/.test(value)),
					'Invalid elapsed measurement'
				);
				assert(
					fields.slice(5, 7).every((value) => /^(0|[1-9]\d*)$/.test(value)),
					'Invalid capture count'
				);
				const [send, receive, queued, replayed] = fields.slice(3, 7).map(Number);
				assert(
					[send, receive].every(Number.isFinite) && receive >= send,
					'Elapsed measurements are not coherent'
				);
				assert([queued, replayed].every(Number.isSafeInteger), 'Capture count overflow');
				assert.equal(queued, replayed, 'Unacknowledged capture debt');
				if (expected.mode === 'idle') assert.equal(queued, 0, 'Idle mode claims physical input');
				else assert(queued >= 6 && queued <= 8192, 'Missing bounded physical capture edges');
				rows.push({ sample, send_ms: send, receive_ms: receive, captured: queued, replayed });
			}
			const sorted = rows.map((row) => row.receive_ms).sort((a, b) => a - b);
			groups.push({
				backend,
				case: kind,
				samples: rows,
				receive_median_ms: sorted[Math.floor(sorted.length / 2)],
				receive_max_ms: sorted.at(-1)
			});
		}
	}
	return {
		schema_version: 1,
		mode: expected.mode,
		requested_install_sequence: expected.sequence,
		qualification: 'native-owned-edit-primitives-only',
		production_qualified: false,
		physical_hook_order_qualified: false,
		simultaneous_physical_typing_qualified: false,
		production_backend_policy_changed: false,
		groups
	};
}

if (require.main === module) {
	try {
		assert.equal(
			process.argv.length,
			7,
			'Use: node windows_group7_receipt.cjs stdout samples mode sequence output'
		);
		const result = readReceipt(fs.readFileSync(process.argv[2], 'utf8'), {
			samples: Number(process.argv[3]),
			mode: process.argv[4],
			sequence: process.argv[5]
		});
		fs.writeFileSync(process.argv[6], JSON.stringify(result, null, 2) + '\n');
	} catch (error) {
		console.error(error.message);
		process.exitCode = 1;
	}
}

module.exports = { readReceipt, HEADER, COMPLETE };
