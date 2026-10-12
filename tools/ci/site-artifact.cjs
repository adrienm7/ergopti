// tools/ci/site-artifact.cjs

/** Seal and receive the exact static site files produced by one source-bound CI build. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { resolveSiteContext, resolveSiteTarget } = require('../dev/site-context.cjs');

function refuse(condition, message) {
	if (!condition) throw new Error('Site artifact refused: ' + message);
}

function keys(value, expected) {
	refuse(value && typeof value === 'object' && !Array.isArray(value), 'expected an object.');
	assert.deepEqual(Object.keys(value).sort(), expected.slice().sort(), 'closed site artifact keys');
}

// Capacity limits exceed the 7,365-file / 216 MiB tracked static census and its
// precompression copies; the first actual Svelte output still needs measurement.
const LIMITS = Object.freeze({
	receiptBytes: 16 * 1024 * 1024,
	members: 65536,
	fileBytes: 1024 * 1024 * 1024,
	totalBytes: 4 * 1024 * 1024 * 1024
});

const SITE_ROUTES = Object.freeze([
	'/',
	'/utilisation',
	'/informations',
	'/benchmarks',
	'/ergopti-plus',
	'/ergopti-plus-old'
]);
const SITE_BROWSERS = Object.freeze(['chromium', 'webkit']);

const CONTEXT_KEYS = ['source_sha', 'run_id', 'run_attempt', 'target', 'base_path', 'lock_sha256'];

function positive(value) {
	refuse(
		typeof value === 'string' && /^[1-9][0-9]*$/.test(value) && Number.isSafeInteger(Number(value)),
		'invalid CI number.'
	);
	return Number(value);
}

function context(value) {
	keys(value, CONTEXT_KEYS);
	refuse(
		typeof value.source_sha === 'string' && /^[a-f0-9]{40}$/.test(value.source_sha),
		'invalid source SHA.'
	);
	positive(value.run_id);
	positive(value.run_attempt);
	resolveSiteTarget(value.target, value.base_path);
	refuse(
		typeof value.lock_sha256 === 'string' && /^[a-f0-9]{64}$/.test(value.lock_sha256),
		'invalid lock hash.'
	);
}

function sameFile(left, right) {
	return ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'].every((key) => left[key] === right[key]);
}

/** Hash an opened regular file and refuse replacement, short read or growth during capture. */
function fileHash(file, { maximumBytes = LIMITS.fileBytes, capture = false } = {}) {
	const initial = fs.lstatSync(file, { bigint: true });
	refuse(
		initial.isFile() && !initial.isSymbolicLink(),
		'only ordinary files may enter the site artifact.'
	);
	refuse(initial.size <= BigInt(maximumBytes), 'file exceeds the capture limit.');
	const handle = fs.openSync(
		file,
		fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0)
	);
	try {
		const opened = fs.fstatSync(handle, { bigint: true });
		refuse(opened.isFile() && sameFile(initial, opened), 'file changed before capture.');
		const hash = crypto.createHash('sha256');
		const buffer = Buffer.allocUnsafe(65536);
		const chunks = capture ? [] : null;
		let total = 0;
		for (;;) {
			const read = fs.readSync(handle, buffer, 0, buffer.length, null);
			if (read === 0) break;
			total += read;
			refuse(total <= Number(initial.size), 'file grew during capture.');
			hash.update(buffer.subarray(0, read));
			if (chunks) chunks.push(Buffer.from(buffer.subarray(0, read)));
		}
		refuse(total === Number(initial.size), 'short file capture.');
		refuse(
			sameFile(opened, fs.fstatSync(handle, { bigint: true })) &&
				sameFile(opened, fs.lstatSync(file, { bigint: true })),
			'file changed during capture.'
		);
		return {
			bytes: total,
			sha256: hash.digest('hex'),
			...(chunks ? { content: Buffer.concat(chunks, total) } : {})
		};
	} finally {
		fs.closeSync(handle);
	}
}

/** List the actual output tree; no source directory is consulted as a fallback. */
function members(directory) {
	const root = path.resolve(directory);
	const rows = [];
	let totalBytes = 0;
	function visit(current, prefix) {
		const before = fs.lstatSync(current, { bigint: true });
		refuse(before.isDirectory() && !before.isSymbolicLink(), 'linked or non-directory site tree.');
		for (const name of fs.readdirSync(current).sort()) {
			refuse(name !== '.' && name !== '..' && !/[\\\x00]/.test(name), 'unsafe site member name.');
			const target = path.join(current, name);
			const relative = prefix + name;
			const stat = fs.lstatSync(target);
			if (stat.isDirectory() && !stat.isSymbolicLink()) visit(target, relative + '/');
			else {
				refuse(rows.length < LIMITS.members, 'too many site members.');
				refuse(totalBytes + stat.size <= LIMITS.totalBytes, 'site exceeds total byte limit.');
				const captured = fileHash(target, {
					maximumBytes: Math.min(LIMITS.fileBytes, LIMITS.totalBytes - totalBytes)
				});
				totalBytes += captured.bytes;
				rows.push({ path: relative, ...captured });
			}
		}
		refuse(
			sameFile(before, fs.lstatSync(current, { bigint: true })),
			'directory changed during capture.'
		);
	}
	visit(root, '');
	refuse(rows.length > 0, 'empty site artifact.');
	return rows.sort((left, right) => (left.path < right.path ? -1 : left.path > right.path ? 1 : 0));
}

function canonical(value) {
	return JSON.stringify(value, null, 2) + '\n';
}

/** Read only a bounded ordinary canonical receipt; duplicate keys and partial JSON refuse. */
function readCanonical(file, maximumBytes = LIMITS.receiptBytes) {
	const captured = fileHash(file, { maximumBytes, capture: true });
	refuse(captured.bytes > 0, 'empty receipt file.');
	const text = captured.content.toString('utf8');
	const receipt = JSON.parse(text);
	refuse(
		captured.content.equals(Buffer.from(canonical(receipt), 'utf8')),
		'receipt must be canonical closed JSON.'
	);
	return receipt;
}

function readReceipt(file) {
	const receipt = readCanonical(file);
	validateReceipt(receipt);
	return receipt;
}

function validateReceipt(value) {
	keys(value, ['schema_version', ...CONTEXT_KEYS, 'members']);
	refuse(value.schema_version === 1, 'unknown receipt schema.');
	context(Object.fromEntries(CONTEXT_KEYS.map((key) => [key, value[key]])));
	refuse(Array.isArray(value.members) && value.members.length > 0, 'empty member list.');
	refuse(value.members.length <= LIMITS.members, 'too many site members.');
	let previous = '';
	let totalBytes = 0;
	for (const member of value.members) {
		keys(member, ['path', 'bytes', 'sha256']);
		refuse(
			typeof member.path === 'string' &&
				member.path !== '' &&
				!/[\\\x00:]/.test(member.path) &&
				member.path.split('/').every((part) => part !== '' && part !== '.' && part !== '..'),
			'unsafe member path.'
		);
		refuse(member.path > previous, 'duplicate or unordered site member.');
		previous = member.path;
		refuse(
			Number.isSafeInteger(member.bytes) && member.bytes >= 0 && member.bytes <= LIMITS.fileBytes,
			'invalid member size.'
		);
		totalBytes += member.bytes;
		refuse(totalBytes <= LIMITS.totalBytes, 'site exceeds total byte limit.');
		refuse(
			typeof member.sha256 === 'string' && /^[a-f0-9]{64}$/.test(member.sha256),
			'invalid member hash.'
		);
	}
}

function requireSiteMetadata(directory, expected, expectedCname) {
	refuse(
		Buffer.isBuffer(expectedCname) && expectedCname.length > 0,
		'canonical domain bytes are required.'
	);
	const version = path.join(directory, 'version.json');
	const text = fileHash(version, { maximumBytes: 4096, capture: true }).content.toString('utf8');
	refuse(
		text ===
			canonical({
				branch: expected.target,
				base_path: expected.base_path,
				source_sha: expected.source_sha
			}),
		'built version metadata differs from source and target.'
	);
	const cname = path.join(directory, 'CNAME');
	refuse(
		fileHash(cname, { maximumBytes: 4096, capture: true }).content.equals(expectedCname),
		'built CNAME differs from the owned domain.'
	);
	refuse(fileHash(path.join(directory, 'index.html')).bytes > 0, 'built homepage is empty.');
}

/** Capture the actual producer files after a successful build. */
function seal(directory, producer, expectedCname) {
	context(producer);
	requireSiteMetadata(directory, producer, expectedCname);
	const receipt = { schema_version: 1, ...producer, members: members(directory) };
	validateReceipt(receipt);
	refuse(
		Buffer.byteLength(canonical(receipt)) <= LIMITS.receiptBytes,
		'receipt exceeds capture limit.'
	);
	return receipt;
}

/** Require exact files and context, allowing an earlier successful producer in this run. */
function verify(directory, receipt, receiving, expectedCname) {
	context(receiving);
	validateReceipt(receipt);
	for (const key of CONTEXT_KEYS.filter((key) => key !== 'run_attempt'))
		refuse(receipt[key] === receiving[key], 'foreign ' + key + '.');
	refuse(
		positive(receipt.run_attempt) <= positive(receiving.run_attempt),
		'future producing attempt.'
	);
	assert.deepEqual(
		members(directory),
		receipt.members,
		'received site bytes differ from the produced artifact'
	);
	requireSiteMetadata(directory, receiving, expectedCname);
	return {
		files: receipt.members.length,
		producer_run_attempt: receipt.run_attempt,
		receiving_run_attempt: receiving.run_attempt
	};
}

/** Admit only the actual complete two-browser observations for the authored public routes. */
function validateTestbuild(receipt) {
	keys(receipt, [
		'schema_version',
		'scope',
		...CONTEXT_KEYS,
		'build_receipt_sha256',
		'build_run_attempt',
		'browsers'
	]);
	refuse(
		receipt.schema_version === 1 && receipt.scope === 'svelte-output',
		'foreign Testbuild scope.'
	);
	context(Object.fromEntries(CONTEXT_KEYS.map((key) => [key, receipt[key]])));
	refuse(
		typeof receipt.build_receipt_sha256 === 'string' &&
			/^[a-f0-9]{64}$/.test(receipt.build_receipt_sha256),
		'invalid Build receipt digest.'
	);
	refuse(
		positive(receipt.build_run_attempt) <= positive(receipt.run_attempt),
		'Testbuild predates Build.'
	);
	refuse(
		Array.isArray(receipt.browsers) && receipt.browsers.length === SITE_BROWSERS.length,
		'incomplete browser inventory.'
	);
	for (const [index, browser] of receipt.browsers.entries()) {
		keys(browser, [
			'name',
			'routes',
			'local_http_errors',
			'page_errors',
			'hydration',
			'interaction'
		]);
		refuse(browser.name === SITE_BROWSERS[index], 'foreign or repeated browser.');
		assert.deepEqual(browser.routes, SITE_ROUTES, 'complete ordered site routes');
		refuse(
			browser.local_http_errors === 0 &&
				browser.page_errors === 0 &&
				browser.hydration === true &&
				browser.interaction === true,
			'browser did not complete every real output check.'
		);
	}
}

function sameContext(producer, receiving) {
	context(receiving);
	for (const key of CONTEXT_KEYS.filter((key) => key !== 'run_attempt'))
		refuse(producer[key] === receiving[key], 'foreign ' + key + '.');
	refuse(
		positive(producer.run_attempt) <= positive(receiving.run_attempt),
		'future producing attempt.'
	);
}

/** Record only completed observations after the caller has verified the received tree again. */
function recordTestbuild(build, receiving, browsers) {
	validateReceipt(build);
	sameContext(build, receiving);
	const receipt = {
		schema_version: 1,
		scope: 'svelte-output',
		...receiving,
		build_receipt_sha256: crypto.createHash('sha256').update(canonical(build)).digest('hex'),
		build_run_attempt: build.run_attempt,
		browsers: structuredClone(browsers)
	};
	validateTestbuild(receipt);
	return receipt;
}

/** Read the small success proof separately from the possibly large output member manifest. */
function readTestbuild(file) {
	const receipt = readCanonical(file, 64 * 1024);
	validateTestbuild(receipt);
	return receipt;
}

/** Bind completed browser checks to the exact earlier Build receipt and actual receiving run. */
function verifyTestbuild(build, tested, receiving) {
	validateReceipt(build);
	validateTestbuild(tested);
	sameContext(tested, receiving);
	sameContext(build, Object.fromEntries(CONTEXT_KEYS.map((key) => [key, tested[key]])));
	refuse(tested.build_run_attempt === build.run_attempt, 'foreign Build producing attempt.');
	refuse(
		tested.build_receipt_sha256 ===
			crypto.createHash('sha256').update(canonical(build)).digest('hex'),
		'browser evidence belongs to different Build bytes.'
	);
	return {
		build_run_attempt: build.run_attempt,
		testbuild_run_attempt: tested.run_attempt,
		receiving_run_attempt: receiving.run_attempt
	};
}

/** Bind CLI identity to actual GitHub environment, checked-out Git and lockfile bytes. */
function ciContext(env, cwd) {
	refuse(env.GITHUB_ACTIONS === 'true', 'CLI requires actual GitHub context.');
	const identity = resolveSiteContext(env, (args) =>
		execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
	);
	const result = {
		source_sha: identity.source_sha,
		run_id: env.GITHUB_RUN_ID,
		run_attempt: env.GITHUB_RUN_ATTEMPT,
		target: identity.branch,
		base_path: identity.base_path,
		lock_sha256: fileHash(path.join(cwd, 'package-lock.json')).sha256
	};
	context(result);
	return result;
}

function main(argv = process.argv.slice(2), env = process.env, cwd = process.cwd()) {
	refuse(
		argv.length === 3 && ['seal', 'verify'].includes(argv[0]),
		'usage: site-artifact.cjs <seal|verify> <site-directory> <receipt-file>'
	);
	const [command, directory, file] = argv;
	const relative = path.relative(path.resolve(directory), path.resolve(file));
	refuse(
		relative.startsWith('..' + path.sep) || path.isAbsolute(relative),
		'receipt must be outside the site tree.'
	);
	const identity = ciContext(env, cwd);
	const sourceCname = path.join(cwd, 'static/CNAME');
	const expectedCname = fileHash(sourceCname, { maximumBytes: 4096, capture: true }).content;
	if (command === 'seal') {
		const receipt = seal(directory, identity, expectedCname);
		fs.writeFileSync(file, canonical(receipt), { encoding: 'utf8', flag: 'wx' });
		console.log('Site artifact sealed: ' + receipt.members.length + ' exact files.');
	} else {
		const receipt = readReceipt(file);
		const result = verify(directory, receipt, identity, expectedCname);
		console.log('Site artifact received: ' + result.files + ' exact files.');
	}
}

if (require.main === module) main();
module.exports = {
	seal,
	verify,
	canonical,
	readReceipt,
	fileHash,
	members,
	ciContext,
	main,
	validateReceipt,
	LIMITS,
	SITE_ROUTES,
	SITE_BROWSERS,
	recordTestbuild,
	readTestbuild,
	verifyTestbuild
};
