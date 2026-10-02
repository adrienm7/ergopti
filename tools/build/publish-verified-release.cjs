// tools/build/publish-verified-release.cjs

/**
 * ==============================================================================
 * MODULE: Verified Draft Release Publication
 * DESCRIPTION:
 * Reads GitHub's actual draft asset inventory, repairs refused or missing uploads,
 * and publishes only after every local artifact has a matching uploaded receipt.
 * A successful create/upload command is not proof that GitHub retained the file.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

/** Executes one GitHub operation and rejects every unacknowledged native result. */
function github(args) {
	const result = spawnSync('gh', args, {
		encoding: 'utf8',
		timeout: 120000,
		maxBuffer: 16 * 1024 * 1024
	});
	if (result.error) throw result.error;
	if (result.status !== 0) {
		throw new Error(`GitHub release operation failed (${result.status}): ${result.stderr.trim()}`);
	}
	return result.stdout;
}

/** Resolves each unique nonempty regular artifact before any publication. */
function expectedAssets(files) {
	if (!Array.isArray(files) || files.length === 0)
		throw new Error('No release artifacts supplied.');
	const expected = new Map();
	for (const file of files) {
		if (typeof file !== 'string' || file === '') throw new Error('Invalid release artifact path.');
		const name = path.basename(file);
		if (expected.has(name)) throw new Error(`Duplicate release artifact name: ${name}.`);
		const stat = fs.lstatSync(file);
		if (!stat.isFile() || stat.size <= 0)
			throw new Error(`Release artifact is not a nonempty regular file: ${file}.`);
		expected.set(name, { file, size: stat.size });
	}
	return expected;
}

/** Validates the actual inventory and returns only artifacts without matching receipts. */
function missingAssets(raw, expected, draft) {
	const release = JSON.parse(raw);
	if (!release || release.isDraft !== draft || !Array.isArray(release.assets)) {
		throw new Error(
			`GitHub did not acknowledge the expected ${draft ? 'draft' : 'published'} release state.`
		);
	}
	const found = new Map();
	for (const asset of release.assets) {
		if (
			!asset ||
			typeof asset.name !== 'string' ||
			asset.name === '' ||
			!Number.isSafeInteger(asset.size) ||
			asset.size < 0 ||
			typeof asset.state !== 'string' ||
			found.has(asset.name)
		) {
			throw new Error('GitHub returned an invalid or duplicate release asset receipt.');
		}
		found.set(asset.name, asset);
	}
	return [...expected.entries()].filter(([name, local]) => {
		const asset = found.get(name);
		return !asset || asset.state !== 'uploaded' || asset.size !== local.size;
	});
}

/**
 * Repairs at most twice, publishes once, and verifies the final asset inventory.
 * @param {string} tag Release tag already admitted by the workflow preflight.
 * @param {string} repository GitHub owner/repository receiving the release.
 * @param {string[]} files Every local artifact attached to the draft.
 * @param {function(string[]): string} run Exact GitHub command boundary.
 * @returns {number} Verified artifact count.
 */
function publishVerifiedRelease(tag, repository, files, run = github) {
	if (
		typeof tag !== 'string' ||
		tag === '' ||
		typeof repository !== 'string' ||
		repository === ''
	) {
		throw new Error('A release tag and repository are required.');
	}
	const expected = expectedAssets(files);
	const view = ['release', 'view', tag, '--repo', repository, '--json', 'isDraft,assets'];
	let missing;
	for (let attempt = 0; attempt < 3; attempt++) {
		missing = missingAssets(run(view), expected, true);
		if (missing.length === 0) break;
		if (attempt === 2) {
			throw new Error(
				`Release remains a draft: missing or incomplete assets: ${missing.map(([name]) => name).join(', ')}.`
			);
		}
		run([
			'release',
			'upload',
			tag,
			...missing.map(([, local]) => local.file),
			'--repo',
			repository,
			'--clobber'
		]);
	}
	// Publication can make assets immutable. The last draft readback is the gate.
	run(['release', 'edit', tag, '--repo', repository, '--draft=false']);
	missing = missingAssets(run(view), expected, false);
	if (missing.length !== 0) {
		throw new Error(
			`Published release lost verified assets: ${missing.map(([name]) => name).join(', ')}.`
		);
	}
	return expected.size;
}

module.exports = { publishVerifiedRelease };

if (require.main === module) {
	try {
		const [tag, repository, ...files] = process.argv.slice(2);
		const count = publishVerifiedRelease(tag, repository, files);
		console.log(`Published ${tag} after verifying ${count} uploaded release assets.`);
	} catch (error) {
		console.error(`::error::${error.message}`);
		process.exitCode = 1;
	}
}
