// tools/diagnostics/tis_evidence_transport.cjs
// Lossless test diagnostics are independent of the strict raw XCTest reporter.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const PREFIX = Buffer.from('TIS_TEST_EVIDENCE ');
const sha = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const refuse = () => {
	throw new Error('TIS diagnostic transport refused');
};
const integer = (value, min, max) => Number.isSafeInteger(value) && value >= min && value <= max;
const hash = (value) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
function keys(value, required) {
	if (
		!value ||
		typeof value !== 'object' ||
		Array.isArray(value) ||
		Object.keys(value).sort().join(',') !== [...required].sort().join(',')
	)
		refuse();
}
function json(data) {
	const text = data.toString('utf8');
	if (!Buffer.from(text, 'utf8').equals(data)) refuse();
	let value;
	try {
		value = JSON.parse(text);
	} catch {
		refuse();
	}
	// JSON.parse accepts repeated keys; the transport does not. Token strings
	// remain escaped until decoded, so braces/colons inside data are harmless.
	const tokens =
		text.match(/"(?:[^"\\]|\\.)*"|[{}\[\]:,]|true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g) ||
		[];
	const stack = [];
	for (let index = 0; index < tokens.length; index++) {
		const token = tokens[index];
		if (token === '{') stack.push(new Set());
		else if (token === '[') stack.push(null);
		else if (token === '}' || token === ']') stack.pop();
		else if (token.startsWith('"') && tokens[index + 1] === ':') {
			const object = stack.at(-1),
				key = JSON.parse(token);
			if (!object || object.has(key)) refuse();
			object.add(key);
		}
	}
	return value;
}
function boundedIdentity(value) {
	if (
		!value ||
		typeof value !== 'object' ||
		Array.isArray(value) ||
		typeof value.state !== 'string' ||
		!['present', 'missing', 'oversize', 'invalidType', 'sourceUnavailable'].includes(value.state)
	)
		refuse();
	if (value.state === 'present') {
		if (typeof value.value !== 'string' || Buffer.byteLength(value.value, 'utf8') > 1024) refuse();
	} else if (value.value !== undefined && value.value !== null) refuse();
}
function record(data, pid) {
	if (
		data.length < PREFIX.length + 3 ||
		data.length > 2097152 ||
		!data.subarray(0, PREFIX.length).equals(PREFIX) ||
		data.at(-1) !== 10 ||
		data.subarray(0, -1).includes(10)
	)
		refuse();
	const text = data.subarray(PREFIX.length, -1).toString('utf8');
	if (!Buffer.from(text, 'utf8').equals(data.subarray(PREFIX.length, -1))) refuse();
	const receipt = json(data.subarray(PREFIX.length, -1));
	keys(receipt, ['version', 'test', 'pid', 'events', 'omittedEvents']);
	if (
		receipt.version !== 1 ||
		receipt.pid !== pid ||
		!Array.isArray(receipt.events) ||
		!integer(receipt.events.length, 0, 64) ||
		!integer(receipt.omittedEvents, 0, Number.MAX_SAFE_INTEGER)
	)
		refuse();
	boundedIdentity(receipt.test);
	for (const event of receipt.events) {
		if (
			!event ||
			typeof event !== 'object' ||
			typeof event.phase !== 'string' ||
			!Number.isFinite(event.uptime) ||
			event.uptime < 0
		)
			refuse();
		if (event.status !== undefined && !integer(event.status, -2147483648, 2147483647)) refuse();
		if (event.snapshotID !== undefined) boundedIdentity(event.snapshotID);
		for (const source of ['original', 'target', 'current']) {
			if (event[source] === undefined) continue;
			boundedIdentity(event[source].id);
			for (const property of ['enabled', 'selected', 'selectCapable']) {
				const value = event[source][property];
				if (
					!value ||
					!['present', 'missing', 'invalidType', 'sourceUnavailable'].includes(value.state) ||
					(value.state === 'present'
						? typeof value.value !== 'boolean'
						: value.value !== undefined && value.value !== null)
				)
					refuse();
			}
		}
		if (event.keyboardType !== undefined && !integer(event.keyboardType, 0, 4294967295)) refuse();
		if (
			event.unicodeDataBytes !== undefined &&
			!integer(event.unicodeDataBytes, 0, Number.MAX_SAFE_INTEGER)
		)
			refuse();
	}
	return receipt;
}
function validate(root, session) {
	if (!path.isAbsolute(root) || !hash(session)) refuse();
	const directory = fs.lstatSync(root);
	if (!directory.isDirectory() || directory.isSymbolicLink()) refuse();
	if (process.getuid && directory.uid !== process.getuid()) refuse();
	function read(name, maximum) {
		const source = path.join(root, name);
		const status = fs.lstatSync(source);
		if (
			!status.isFile() ||
			status.isSymbolicLink() ||
			status.nlink !== 1 ||
			status.size > maximum ||
			status.size === 0
		)
			refuse();
		if (process.getuid && status.uid !== process.getuid()) refuse();
		const descriptor = fs.openSync(source, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
		try {
			const retained = fs.fstatSync(descriptor);
			if (
				retained.dev !== status.dev ||
				retained.ino !== status.ino ||
				retained.size !== status.size
			)
				refuse();
			const data = fs.readFileSync(descriptor);
			const after = fs.fstatSync(descriptor);
			if (
				data.length !== status.size ||
				after.size !== retained.size ||
				after.mtimeMs !== retained.mtimeMs ||
				after.ctimeMs !== retained.ctimeMs
			)
				refuse();
			return data;
		} finally {
			fs.closeSync(descriptor);
		}
	}
	const startData = read('start.json', 4096);
	const terminalData = read('manifest.json', 32768);
	const start = json(startData),
		terminal = json(terminalData);
	keys(start, ['version', 'session', 'producerPID', 'bundleSHA256']);
	keys(terminal, [
		'version',
		'session',
		'producerPID',
		'bundleSHA256',
		'startSHA256',
		'phase',
		'enrolledCount',
		'records'
	]);
	if (
		start.version !== 1 ||
		start.session !== session ||
		!integer(start.producerPID, 1, 2147483647) ||
		!hash(start.bundleSHA256) ||
		terminal.version !== 1 ||
		terminal.session !== session ||
		terminal.producerPID !== start.producerPID ||
		terminal.bundleSHA256 !== start.bundleSHA256 ||
		terminal.startSHA256 !== sha(startData) ||
		terminal.phase !== 'closed' ||
		!integer(terminal.enrolledCount, 1, 64) ||
		!Array.isArray(terminal.records) ||
		terminal.records.length !== terminal.enrolledCount
	)
		refuse();
	const expected = ['start.json', 'manifest.json'];
	const receipts = [];
	for (const [offset, entry] of terminal.records.entries()) {
		keys(entry, ['index', 'bytes', 'sha256', 'closed']);
		if (
			entry.index !== offset + 1 ||
			!integer(entry.bytes, 1, 2097152) ||
			!hash(entry.sha256) ||
			entry.closed !== true
		)
			refuse();
		const name = 'record-' + String(entry.index).padStart(6, '0') + '.dat';
		expected.push(name);
		const data = read(name, 2097152);
		if (data.length !== entry.bytes || sha(data) !== entry.sha256) refuse();
		receipts.push(record(data, start.producerPID));
	}
	if (fs.readdirSync(root).sort().join(',') !== expected.sort().join(',')) refuse();
	// Reread terminal/source and the exact census to refuse concurrent replacement.
	if (
		!read('start.json', 4096).equals(startData) ||
		!read('manifest.json', 32768).equals(terminalData) ||
		fs.readdirSync(root).sort().join(',') !== expected.sort().join(',')
	)
		refuse();
	const afterDirectory = fs.lstatSync(root);
	if (
		!afterDirectory.isDirectory() ||
		afterDirectory.isSymbolicLink() ||
		afterDirectory.dev !== directory.dev ||
		afterDirectory.ino !== directory.ino
	)
		refuse();
	return { complete: true, record_count: receipts.length, receipts };
}
module.exports = { validate, record };
if (require.main === module) {
	try {
		if (process.argv.length !== 4) refuse();
		const result = validate(process.argv[2], process.argv[3]);
		console.log('[OK] Closed TIS diagnostic session: ' + result.record_count + ' records.');
	} catch {
		console.error('::error::TIS diagnostic session is incomplete or refused');
		process.exitCode = 1;
	}
}
