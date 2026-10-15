// tools/ci/site-verdict.cjs

/** Receive both source-bound site proof bundles without claiming another build or browser run. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { siteLots, resolveSiteContext } = require('../dev/site-context.cjs');
const { selectSiteJobs, readCurrentRun } = require('./site-deploy-admission.cjs');

function refuse(ok, detail) {
	if (!ok) throw new Error('Site Verdict refused: ' + detail);
}

function closed(value, names) {
	refuse(value && typeof value === 'object' && !Array.isArray(value), 'expected closed object.');
	assert.deepEqual(Object.keys(value).sort(), names.slice().sort(), 'closed site Verdict keys');
}

function directory(directoryPath, expected) {
	const stat = fs.lstatSync(directoryPath, { bigint: true });
	refuse(
		stat.isDirectory() && !stat.isSymbolicLink(),
		'proof bundle must be an ordinary directory.'
	);
	assert.deepEqual(
		fs.readdirSync(directoryPath).sort(),
		expected.slice().sort(),
		'exact site proof bundle members'
	);
	return stat;
}

function sameDirectory(before, after) {
	return ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'].every((key) => before[key] === after[key]);
}

function requireManifestMetadata(build, target, source, cname) {
	const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
	const expected = {
		CNAME: cname,
		'version.json': Buffer.from(
			JSON.stringify(
				{ branch: target.target, base_path: target.base_path, source_sha: source },
				null,
				2
			) + '\n'
		)
	};
	for (const [name, bytes] of Object.entries(expected)) {
		const member = build.members.find((row) => row.path === name);
		refuse(
			member && member.bytes === bytes.length && member.sha256 === digest(bytes),
			'Build manifest has foreign ' + name + '.'
		);
	}
	refuse(
		build.members.some((row) => row.path === 'index.html' && row.bytes > 0),
		'Build manifest has no nonempty homepage.'
	);
}

/** Bind actual copied manifests and browser proofs to both latest successful writer jobs. */
async function verifyBundles(files, env, ports = {}) {
	closed(files, ['bundleRoot', 'sourceRoot']);
	for (const value of Object.values(files))
		refuse(
			typeof value === 'string' && path.isAbsolute(value),
			'absolute source and proof paths are required.'
		);
	refuse(env.SITE_PREDECESSOR_RESULT === 'success', 'actual preceding site stage did not succeed.');
	const artifact = ports.artifact || require('./site-artifact.cjs');
	const git =
		ports.git ||
		((args) =>
			execFileSync('git', args, {
				cwd: files.sourceRoot,
				encoding: 'utf8',
				stdio: ['ignore', 'pipe', 'pipe']
			}));
	const readApi =
		ports.readApi ||
		((endpoint) =>
			JSON.parse(
				execFileSync('gh', ['api', endpoint], {
					encoding: 'utf8',
					maxBuffer: 4 * 1024 * 1024,
					stdio: ['ignore', 'pipe', 'pipe']
				})
			));
	const identity = await readCurrentRun(env, readApi);
	const selected = await selectSiteJobs(
		{ head_sha: identity.head_sha, run_id: identity.run_id, run_attempt: identity.run_attempt },
		readApi
	);
	const targets = Object.values(siteLots());
	const bundleNames = targets.map((row) => row.target);
	const rootBefore = directory(files.bundleRoot, bundleNames);
	const lockFile = path.join(files.sourceRoot, 'package-lock.json');
	const cnameFile = path.join(files.sourceRoot, 'static/CNAME');
	const lock = artifact.fileHash(lockFile).sha256;
	const sourceCname = artifact.fileHash(cnameFile, { maximumBytes: 4096, capture: true });
	refuse(sourceCname.content.length > 0, 'canonical CNAME bytes are required.');
	const received = {};
	const directoryFences = [];
	for (const target of targets) {
		const bundle = path.join(files.bundleRoot, target.target);
		const before = directory(bundle, ['build.json', 'site-testbuild.json']);
		directoryFences.push({ bundle, before });
		const source = resolveSiteContext(
			{
				...env,
				ERGOPTI_SITE_TARGET: target.target,
				BASE_PATH: target.base_path,
				ERGOPTI_SITE_SOURCE_SHA: env.GITHUB_SHA
			},
			git
		);
		const context = {
			source_sha: source.source_sha,
			run_id: identity.run_id,
			run_attempt: identity.run_attempt,
			target: source.branch,
			base_path: source.base_path,
			lock_sha256: lock
		};
		const build = artifact.readReceipt(path.join(bundle, 'build.json'));
		const tested = artifact.readTestbuild(path.join(bundle, 'site-testbuild.json'));
		artifact.verifyTestbuild(build, tested, context);
		refuse(
			build.run_attempt === selected[target.target].build.run_attempt,
			'Build receipt differs from selected writer attempt.'
		);
		refuse(
			tested.run_attempt === selected[target.target].testbuild.run_attempt,
			'browser proof differs from selected writer attempt.'
		);
		requireManifestMetadata(build, target, context.source_sha, sourceCname.content);
		received[target.target] = {
			build_run_attempt: build.run_attempt,
			testbuild_run_attempt: tested.run_attempt,
			manifest_files: build.members.length
		};
	}
	for (const { bundle, before } of directoryFences)
		refuse(
			sameDirectory(before, directory(bundle, ['build.json', 'site-testbuild.json'])),
			'proof bundle changed during receiving.'
		);
	refuse(
		sameDirectory(rootBefore, directory(files.bundleRoot, bundleNames)),
		'proof root changed during receiving.'
	);
	refuse(
		artifact.fileHash(lockFile).sha256 === lock &&
			artifact.fileHash(cnameFile, { maximumBytes: 4096 }).sha256 === sourceCname.sha256,
		'checked-out source metadata changed during receiving.'
	);
	refuse(
		git(['rev-parse', '--verify', 'HEAD^{commit}']).trim() === env.GITHUB_SHA,
		'checked-out source changed during receiving.'
	);
	assert.deepEqual(
		await readCurrentRun(env, readApi),
		identity,
		'actual run identity changed during receiving'
	);
	return {
		schema_version: 1,
		scope: 'bound-site-proof-bundles',
		source_sha: env.GITHUB_SHA,
		api_head_sha: identity.head_sha,
		run_id: identity.run_id,
		run_attempt: identity.run_attempt,
		targets: received
	};
}

async function main(
	argv = process.argv.slice(2),
	env = process.env,
	cwd = process.cwd(),
	ports = {}
) {
	refuse(argv.length === 2 && argv[0] === 'verify', 'usage: site-verdict.cjs verify <bundle-root>');
	const result = await verifyBundles(
		{ bundleRoot: path.resolve(cwd, argv[1]), sourceRoot: path.resolve(cwd) },
		env,
		ports
	);
	console.log(JSON.stringify(result));
	return result;
}

if (require.main === module)
	main().catch((error) => {
		console.error(error.message);
		process.exitCode = 1;
	});
module.exports = { verifyBundles, main };
