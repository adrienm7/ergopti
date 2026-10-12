// tools/ci/windows-stable-signing.cjs

/**
 * ==============================================================================
 * MODULE: Stable Windows Signature Disclosure
 * DESCRIPTION:
 * Admits human-authorized unsigned stable artifacts until signing is
 * implemented. This is signature metadata, not a test deferral or execution
 * authority. Every test remains full.
 * ==============================================================================
 */

'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { parseClosedJson, environmentContext } = require('./dev-release-qualification.cjs');
const ROOT = path.resolve(__dirname, '../..');
const POLICY = parseClosedJson(
	fs.readFileSync(path.join(ROOT, '.github/ci/stable_windows_signing_exception.json'), 'utf8')
);
const RECEIPT = 'windows-signing-qualification.json';
const QUOTE =
	"le exe non signé est autorisé tant qu'on n’a pas implémenté la signature, qui est un élément de la todo";
function refuse() {
	throw new Error('Unsigned stable Windows signature exception is not admitted.');
}
function keys(value, expected) {
	if (
		!value ||
		typeof value !== 'object' ||
		Array.isArray(value) ||
		Object.keys(value).sort().join('|') !== [...expected].sort().join('|')
	)
		refuse();
}
function validatePolicy(value) {
	keys(value, [
		'schema',
		'id',
		'authorized',
		'authorization_date',
		'authorization_quote',
		'repository',
		'event_name',
		'ref',
		'release',
		'prerelease',
		'channel',
		'purpose',
		'qualified',
		'until'
	]);
	if (
		value.schema !== 2 ||
		value.id !== 'stable-windows-unsigned-until-signing' ||
		typeof value.authorized !== 'boolean' ||
		value.authorization_date !== '2026-10-11' ||
		value.authorization_quote !== QUOTE ||
		value.until !== 'windows-signing-implemented' ||
		value.repository !== 'adrienm7/ergopti' ||
		value.event_name !== 'push' ||
		value.ref !== 'refs/heads/main' ||
		value.release !== true ||
		value.prerelease !== 'false' ||
		value.channel !== 'main' ||
		value.purpose !== 'windows-authenticode-only' ||
		value.qualified !== false
	)
		refuse();
	return value;
}
validatePolicy(POLICY);
function admit(context, source, checkout, now = new Date(), policy = POLICY) {
	validatePolicy(policy);
	keys(context, [
		'github_actions',
		'repository',
		'event_name',
		'ref',
		'release',
		'prerelease',
		'channel',
		'tag',
		'version'
	]);
	if (
		!policy.authorized ||
		context.github_actions !== 'true' ||
		!['repository', 'event_name', 'ref', 'release', 'prerelease', 'channel'].every(
			(key) => context[key] === policy[key]
		) ||
		typeof context.version !== 'string' ||
		!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(context.version) ||
		context.tag !== 'v' + context.version ||
		!/^[0-9a-f]{40}$/.test(source) ||
		checkout !== source ||
		!(now instanceof Date) ||
		!Number.isFinite(now.getTime()) ||
		now.getTime() < Date.parse(policy.authorization_date + 'T00:00:00Z')
	)
		refuse();
}
function receipt(context, source, checkout, sha256, now = new Date(), policy = POLICY) {
	admit(context, source, checkout, now, policy);
	if (!/^[0-9a-f]{64}$/.test(sha256)) refuse();
	return {
		schema: 1,
		scope: policy.id,
		source_sha: source,
		tag: context.tag,
		version: context.version,
		artifact: 'ErgoptiPlus.exe',
		sha256,
		signature: 'NotSigned',
		qualified: false,
		tests: 'mandatory'
	};
}
function validateReceipt(
	value,
	context,
	source,
	checkout,
	observedHash,
	now = new Date(),
	policy = POLICY
) {
	keys(value, [
		'schema',
		'scope',
		'source_sha',
		'tag',
		'version',
		'artifact',
		'sha256',
		'signature',
		'qualified',
		'tests'
	]);
	const expected = receipt(context, source, checkout, observedHash, now, policy);
	for (const key of Object.keys(expected)) if (value[key] !== expected[key]) refuse();
}
function notice(source, tag) {
	if (
		!/^[0-9a-f]{40}$/.test(source) ||
		typeof tag !== 'string' ||
		!/^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(tag)
	)
		refuse();
	return (
		'WINDOWS AUTHENTICODE UNSIGNED / qualified:false (source ' +
		source +
		'): ErgoptiPlus.exe has no Windows code-signing certificate for this ' +
		tag +
		' release. ' +
		'All tests, build, package, source and asset integrity, and installation checks remain mandatory. ' +
		'Windows may show an unknown-publisher warning. [Signature evidence](https://github.com/adrienm7/ergopti/releases/download/' +
		tag +
		'/windows-signing-qualification.json). ' +
		'Future signing requires SignPath Foundation enrollment and qualified GitHub integration.'
	);
}
function requireFreshUnsigned(createRelease) {
	if (createRelease !== 'true') refuse();
}
function main(args, env = process.env) {
	const context = environmentContext(env);
	const source = env.GITHUB_SHA || '';
	const checkout = execFileSync('git', ['rev-parse', 'HEAD'], {
		cwd: ROOT,
		encoding: 'utf8'
	}).trim();
	if (args.length === 1 && args[0] === '--receipt') {
		if (env.ERGOPTI_WINDOWS_AUTHENTICODE_STATUS !== 'NotSigned') refuse();
		console.log(
			JSON.stringify(receipt(context, source, checkout, env.ERGOPTI_UNSIGNED_ARTIFACT_SHA256 || ''))
		);
		return;
	}
	if (args.length === 1 && args[0] === '--publication-admit') {
		const directory = path.join(ROOT, 'release-assets');
		const filename = path.join(directory, RECEIPT);
		if (context.channel !== POLICY.channel) {
			if (fs.existsSync(filename)) refuse();
			console.log('ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE=');
			return;
		}
		if (!fs.existsSync(filename)) {
			if (env.ERGOPTI_WINDOWS_SIGNING_CONFIGURED !== 'true') refuse();
			console.log('ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE=');
			return;
		}
		if (env.ERGOPTI_WINDOWS_SIGNING_CONFIGURED === 'true') refuse();
		requireFreshUnsigned(env.ERGOPTI_WINDOWS_CREATE_RELEASE);
		const value = parseClosedJson(fs.readFileSync(filename, 'utf8'));
		const image = fs.readFileSync(path.join(directory, 'ErgoptiPlus.exe'));
		validateReceipt(
			value,
			context,
			source,
			checkout,
			crypto.createHash('sha256').update(image).digest('hex')
		);
		console.log('ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE=' + notice(source, context.tag));
		return;
	}
	refuse();
}
module.exports = {
	validatePolicy,
	admit,
	receipt,
	validateReceipt,
	notice,
	requireFreshUnsigned,
	POLICY
};
if (require.main === module) {
	try {
		main(process.argv.slice(2));
	} catch (error) {
		console.error(error.message);
		process.exitCode = 1;
	}
}
