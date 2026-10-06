// tools/test/linux-managed-http-evidence.cjs

/**
 * ==============================================================================
 * MODULE: Managed HTTP Native Evidence Admission
 * DESCRIPTION:
 * Reads only complete bounded native console receipts and private setup output.
 * Exported tool paths stay scoped to the native gate; raw loader facts stay private.
 * ==============================================================================
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
function refuse() {
	throw new Error('Managed HTTP evidence refused.');
}
const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const hex = (value) => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
function keys(value, expected) {
	return (
		value !== null &&
		typeof value === 'object' &&
		!Array.isArray(value) &&
		Object.keys(value).sort().join(',') === [...expected].sort().join(',')
	);
}
// Independent closed diagnostic protocol. No native success/closure credit.
const SETUP_STAGES = new Set([
	'arguments',
	'pins-owner-admission',
	'private-destination',
	'bootstrap-client',
	'modern-source-fetch',
	'modern-source-extract',
	'openssl-sdk',
	'modern-configure',
	'modern-build',
	'modern-install',
	'legacy-release-fetch',
	'legacy-signature',
	'legacy-release-policy',
	'legacy-index-fetch',
	'legacy-index-parse',
	'legacy-package-identity',
	'legacy-package-fetch',
	'legacy-package-extract',
	'legacy-library-admission',
	'modern-runtime-admission',
	'legacy-runtime-admission',
	'receipt-publication',
	'completion'
]);
const SETUP_ERROR_CLASSES = new Set([
	'RuntimeError',
	'FileNotFoundError',
	'PermissionError',
	'ValueError',
	'TypeError',
	'KeyError',
	'OSError',
	'JSONDecodeError',
	'LZMAError',
	'TarReadError',
	'SystemExit',
	'KeyboardInterrupt',
	'NativeRefused',
	'Other'
]);
function readSetupFailure(text) {
	if (typeof text !== 'string' || Buffer.byteLength(text) > 512) refuse();
	let value;
	try {
		value = JSON.parse(text);
	} catch {
		refuse();
	}
	if (
		!keys(value, ['schema_version', 'state', 'stage', 'error_class']) ||
		value.schema_version !== 1 ||
		value.state !== 'setup_failed' ||
		!SETUP_STAGES.has(value.stage) ||
		!SETUP_ERROR_CLASSES.has(value.error_class) ||
		JSON.stringify(value) + '\n' !== text
	)
		refuse();
	return (
		'::error::Authenticated managed HTTP validation setup failed: stage=' +
		value.stage +
		'; kind=' +
		value.error_class +
		'. Private diagnostics retained.\n'
	);
}
function readNativeCounts(text, expectedSha, expectedNativeDigest) {
	if (
		typeof text !== 'string' ||
		typeof expectedSha !== 'string' ||
		Buffer.byteLength(text) > 4096 ||
		!/^[0-9a-f]{40}$/.test(expectedSha || '') ||
		!hex(expectedNativeDigest)
	)
		refuse();
	const lines = text.split('\n');
	if (lines.length !== 4 || lines[3] !== '') refuse();
	const output =
		/^\[OK\] Linux managed HTTP retained output: ([0-9]+) actual native controls passed; 0 skipped\.$/.exec(
			lines[0]
		);
	const publicResult =
		/^\[OK\] Linux managed HTTP public transport: ([0-9]+) actual native controls passed; 0 skipped\.$/.exec(
			lines[1]
		);
	const source =
		/^Linux managed HTTP source: ([0-9a-f]{40}); inventory ([0-9a-f]{64}); native ([0-9a-f]{64})\.$/.exec(
			lines[2]
		);
	if (
		!output ||
		output[1] !== '18' ||
		!publicResult ||
		publicResult[1] !== '30' ||
		!source ||
		source[1] !== expectedSha ||
		source[3] !== expectedNativeDigest
	)
		refuse();
	return { output: Number(output[1]), public: Number(publicResult[1]) };
}
function readToolEnvironment(text, root, pinsDigest, legacySha) {
	if (
		typeof text !== 'string' ||
		Buffer.byteLength(text) > 131072 ||
		typeof root !== 'string' ||
		!path.posix.isAbsolute(root) ||
		/[\0\r\n:]/.test(root) ||
		!hex(pinsDigest) ||
		!hex(legacySha)
	)
		refuse();
	let value;
	try {
		value = JSON.parse(text);
	} catch {
		refuse();
	}
	if (
		!keys(value, [
			'schema_version',
			'state',
			'native_30_qualification',
			'pins_sha256',
			'openssl_sdk_prefix',
			'tools',
			'legacy_library_path',
			'inherited_library_suffix_preserved'
		]) ||
		value.schema_version !== 1 ||
		value.state !== 'tools_admitted' ||
		value.native_30_qualification !== 'UNEXECUTED' ||
		value.pins_sha256 !== pinsDigest ||
		value.openssl_sdk_prefix !== '/usr' ||
		value.inherited_library_suffix_preserved !== true ||
		!keys(value.tools, ['modern', 'legacy']) ||
		value.legacy_library_path !== path.posix.join(root, 'legacy-libraries')
	)
		refuse();
	const result = {};
	for (const [name, version, relative] of [
		['modern', '8.14.1', 'modern/bin/curl'],
		['legacy', '7.88.1', 'legacy-root/usr/bin/curl']
	]) {
		const tool = value.tools[name];
		if (
			!keys(tool, ['path', 'sha256', 'actual_version', 'actual_loader_closure']) ||
			tool.path !== path.posix.join(root, relative) ||
			!hex(tool.sha256) ||
			typeof tool.actual_version !== 'string' ||
			/[\0\r\n]/.test(tool.actual_version) ||
			!tool.actual_version.startsWith('curl ' + version + ' ') ||
			!tool.actual_version.split(/\s+/).includes('libcurl/' + version) ||
			!tool.actual_version.split(/\s+/).some((token) => /^OpenSSL\/[0-9]/.test(token)) ||
			typeof tool.actual_loader_closure !== 'string' ||
			tool.actual_loader_closure.length === 0 ||
			Buffer.byteLength(tool.actual_loader_closure) > 65536 ||
			tool.actual_loader_closure.includes('not found') ||
			(name === 'legacy' && tool.sha256 !== legacySha)
		)
			refuse();
		result['ERGOPTI_MANAGED_NATIVE_' + name.toUpperCase() + '_CURL'] = tool.path;
		result['ERGOPTI_MANAGED_NATIVE_' + name.toUpperCase() + '_SHA256'] = tool.sha256;
	}
	result.ERGOPTI_MANAGED_NATIVE_LEGACY_LIBRARY_PATH = value.legacy_library_path;
	return result;
}
function readRegular(filename, maximum, privateFile = false) {
	const before = fs.lstatSync(filename, { bigint: true });
	if (
		!before.isFile() ||
		before.isSymbolicLink() ||
		before.size > BigInt(maximum) ||
		(privateFile &&
			(before.uid !== BigInt(process.getuid()) ||
				(before.mode & 511n) !== 384n ||
				before.nlink !== 1n))
	)
		refuse();
	const bytes = fs.readFileSync(filename);
	const after = fs.lstatSync(filename, { bigint: true });
	if (
		!after.isFile() ||
		after.dev !== before.dev ||
		after.ino !== before.ino ||
		after.size !== before.size ||
		BigInt(bytes.length) !== before.size ||
		after.mode !== before.mode ||
		after.uid !== before.uid ||
		after.nlink !== before.nlink
	)
		refuse();
	return bytes;
}
function toolsForCI(receipt, root, pinsFile) {
	if (receipt !== path.join(root, 'TOOLS-ADMISSION.json')) refuse();
	const before = fs.lstatSync(root, { bigint: true });
	if (
		!before.isDirectory() ||
		before.isSymbolicLink() ||
		before.uid !== BigInt(process.getuid()) ||
		(before.mode & 511n) !== 448n ||
		fs.realpathSync(root) !== root
	)
		refuse();
	const pinsBytes = readRegular(pinsFile, 32768);
	const pins = JSON.parse(pinsBytes.toString('utf8'));
	const env = readToolEnvironment(
		readRegular(receipt, 131072, true).toString('utf8'),
		root,
		digest(pinsBytes),
		pins.legacy.curl_file_sha256
	);
	for (const name of ['MODERN', 'LEGACY']) {
		const bytes = readRegular(env['ERGOPTI_MANAGED_NATIVE_' + name + '_CURL'], 32 * 1024 * 1024);
		if (
			digest(bytes) !== env['ERGOPTI_MANAGED_NATIVE_' + name + '_SHA256'] ||
			!bytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))
		)
			refuse();
		fs.accessSync(env['ERGOPTI_MANAGED_NATIVE_' + name + '_CURL'], fs.constants.X_OK);
	}
	const libraries = fs.lstatSync(env.ERGOPTI_MANAGED_NATIVE_LEGACY_LIBRARY_PATH);
	if (!libraries.isDirectory() || libraries.isSymbolicLink()) refuse();
	for (const library of pins.legacy.libraries) {
		if (!hex(library.file_sha256) || path.basename(library.soname) !== library.soname) refuse();
		if (
			digest(readRegular(path.join(root, 'legacy-libraries', library.soname), 32 * 1024 * 1024)) !==
			library.file_sha256
		)
			refuse();
	}
	const after = fs.lstatSync(root, { bigint: true });
	if (
		!after.isDirectory() ||
		after.dev !== before.dev ||
		after.ino !== before.ino ||
		after.mode !== before.mode ||
		after.uid !== before.uid
	)
		refuse();
	return env;
}
if (require.main === module) {
	try {
		const [mode, ...args] = process.argv.slice(2);
		if (mode === '--count' && args.length === 3 && ['output', 'public'].includes(args[0])) {
			const native = path.resolve(
				__dirname,
				'../../static/ergopti_plus/linux/adapters/curl_http_client.lua'
			);
			const counts = readNativeCounts(
				readRegular(args[1], 4096).toString('utf8'),
				args[2],
				digest(readRegular(native, 8 * 1024 * 1024))
			);
			process.stdout.write(String(counts[args[0]]) + '\n');
		} else if (mode === '--setup-diagnostic' && args.length === 1) {
			process.stdout.write(readSetupFailure(readRegular(args[0], 512, true).toString('utf8')));
		} else if (mode === '--tools-env' && args.length === 3) {
			const env = toolsForCI(...args);
			process.stdout.write(
				Object.entries(env)
					.map(([key, value]) => key + '=' + value + '\n')
					.join('')
			);
		} else refuse();
	} catch {
		console.error('[FAIL] Managed HTTP evidence admission refused.');
		process.exitCode = 1;
	}
}
module.exports = { readNativeCounts, readToolEnvironment, toolsForCI, readSetupFailure };
