// tools/test/support/ahk-local-shadow-output.cjs
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');

/** Partition exact stdout into reported LocalSameAsGlobal records and original TAP. */
function partitionLocalShadowOutput(stdout, tap, source) {
	const reason = 'snapshot16 complete stdout differs';
	assert.ok(Buffer.isBuffer(stdout) && Buffer.isBuffer(tap), reason + ': missing bytes');
	assert.ok(tap.subarray(0, 3).equals(Buffer.from([239, 187, 191])), reason + ': missing TAP BOM');
	const expected = tap.subarray(3);
	assert.ok(stdout.length >= expected.length, reason + ': truncated stdout');
	const size = stdout.length - expected.length;
	assert.ok(stdout.subarray(size).equals(expected), reason + ': original TAP suffix differs');
	const prefix = Buffer.from(stdout.subarray(0, size));
	const text = prefix.toString('utf8');
	assert.ok(Buffer.from(text, 'utf8').equals(prefix), reason + ': malformed diagnostic UTF-8');
	assert.doesNotMatch(text, /[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]/, reason + ': diagnostic controls');
	const records = [];
	if (prefix.length) {
		assert.ok(source && typeof source.source_root === 'string', reason + ': missing source root');
		assert.match(source.head, /^[a-f0-9]{40}$/, reason + ': missing source commit');
		assert.ok(path.win32.isAbsolute(source.source_root), reason + ': relative source root');
		assert.ok(Array.isArray(source.inputs), reason + ': missing source refs');
		const files = new Map();
		for (const input of source.inputs) {
			assert.ok(typeof input.path === 'string', reason + ': malformed source ref');
			assert.ok(
				!input.path.includes('\\') && !input.path.includes(':'),
				reason + ': source ref syntax'
			);
			assert.ok(
				input.path.split('/').every((part) => part && part !== '.' && part !== '..'),
				reason + ': source ref escapes'
			);
			assert.match(input.sha256, /^[a-f0-9]{64}$/, reason + ': unsealed source ref');
			const full = path.win32.resolve(source.source_root, input.path).toLowerCase();
			assert.ok(!files.has(full), reason + ': ambiguous source ref');
			files.set(full, input);
		}
		// These are reported locations and names, not independently proved source
		// byte offsets or runtime function ownership. Every raw record is retained.
		const grammar =
			/([^\r\n]+\.ahk) \(([1-9]\d*)\) : ==> Warning: This local variable has the same name as a global variable\.\r?\n {5}Specifically: ([\p{L}_][\p{L}\p{N}_]*) {2}\(in function ([^\r\n()]+)\)\r?\n/uy;
		let cursor = 0,
			byteCursor = 0;
		while (cursor < text.length) {
			grammar.lastIndex = cursor;
			const match = grammar.exec(text);
			assert.ok(match, reason + ': unknown or malformed advisory record');
			assert.ok(path.win32.isAbsolute(match[1]), reason + ': relative reported source');
			const reported = path.win32.normalize(match[1]).toLowerCase();
			assert.ok(files.has(reported), reason + ': unbound reported source');
			assert.ok(
				match[4].length > 0 && match[4].trim() === match[4],
				reason + ': malformed reported function'
			);
			const line = Number(match[2]);
			assert.ok(Number.isSafeInteger(line) && line > 0, reason + ': invalid reported line');
			const end = byteCursor + Buffer.byteLength(match[0], 'utf8');
			records.push({
				category: 'LocalSameAsGlobal',
				source_ref: files.get(reported).path,
				source_sha256: files.get(reported).sha256,
				reported_file: match[1],
				reported_line: line,
				reported_variable: match[3],
				reported_function: match[4],
				byte_start: byteCursor,
				byte_end: end
			});
			cursor = grammar.lastIndex;
			byteCursor = end;
		}
		assert.equal(byteCursor, prefix.length, reason + ': unassigned diagnostic bytes');
	}
	assert.ok(
		stdout.equals(Buffer.concat([prefix, expected])),
		reason + ': complete partition differs'
	);
	return {
		prefix,
		manifest: {
			schema: 1,
			source_head: source ? source.head : null,
			category: 'LocalSameAsGlobal',
			advisory_debt: records.length > 0,
			count: records.length,
			prefix_bytes: prefix.length,
			prefix_sha256: crypto.createHash('sha256').update(prefix).digest('hex'),
			complete_partition_observed: true,
			original_relation_observed: prefix.length === 0,
			full_suite_qualified: false,
			records
		}
	};
}

module.exports = { partitionLocalShadowOutput };
