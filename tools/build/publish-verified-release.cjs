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
const { createHash } = require('node:crypto');

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
		const hash = createHash('sha256');
		const descriptor = fs.openSync(
			file,
			fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0)
		);
		try {
			const before = fs.fstatSync(descriptor);
			if (
				!before.isFile() ||
				before.dev !== stat.dev ||
				before.ino !== stat.ino ||
				before.size !== stat.size ||
				before.mtimeMs !== stat.mtimeMs ||
				before.ctimeMs !== stat.ctimeMs
			)
				throw new Error(`Release artifact changed before hashing: ${file}.`);
			const buffer = Buffer.allocUnsafe(1024 * 1024);
			let count;
			while ((count = fs.readSync(descriptor, buffer, 0, buffer.length, null)) > 0)
				hash.update(buffer.subarray(0, count));
			const after = fs.fstatSync(descriptor);
			if (
				after.size !== before.size ||
				after.mtimeMs !== before.mtimeMs ||
				after.ctimeMs !== before.ctimeMs
			)
				throw new Error(`Release artifact changed while hashing: ${file}.`);
		} finally {
			fs.closeSync(descriptor);
		}
		expected.set(name, { file, size: stat.size, digest: `sha256:${hash.digest('hex')}` });
	}
	return expected;
}

/** Validates the actual inventory and returns only artifacts without matching receipts. */
function missingAssets(release, assets, expected, draft) {
	if (!release || release.draft !== draft || !Array.isArray(assets)) {
		throw new Error(
			`GitHub did not acknowledge the expected ${draft ? 'draft' : 'published'} release state.`
		);
	}
	const found = new Map();
	for (const asset of assets) {
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
		return (
			!asset ||
			asset.state !== 'uploaded' ||
			asset.size !== local.size ||
			asset.digest !== local.digest
		);
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
	if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository))
		throw new Error('Invalid GitHub repository.');
	// The release list, not releases/tags/<tag>: GitHub serves a release by its
	// tag only once it is published, even when the tag exists, so the draft
	// this gate reads answered 404 (v0.0.0-dev.167's complete draft).
	const findRelease = () => {
		const matches = [];
		for (let page = 1; page <= 1000; page++) {
			const rows = JSON.parse(
				run(['api', `repos/${repository}/releases?per_page=100&page=${page}`])
			);
			if (!Array.isArray(rows) || rows.length > 100)
				throw new Error('GitHub returned an invalid paginated release list.');
			matches.push(...rows.filter((row) => row && row.tag_name === tag));
			if (rows.length < 100) break;
			if (page === 1000) throw new Error('GitHub release list exceeds the pagination bound.');
		}
		if (matches.length !== 1)
			throw new Error(
				`GitHub lists ${matches.length} releases named ${tag}, expected exactly one.`
			);
		return matches[0];
	};
	const inventory = (draft) => {
		const release = findRelease();
		if (!release || !Number.isSafeInteger(release.id) || release.id < 1 || release.tag_name !== tag)
			throw new Error('GitHub did not acknowledge the expected release identity.');
		const assets = [];
		for (let page = 1; page <= 1000; page++) {
			const rows = JSON.parse(
				run(['api', `repos/${repository}/releases/${release.id}/assets?per_page=100&page=${page}`])
			);
			if (!Array.isArray(rows) || rows.length > 100)
				throw new Error('GitHub returned an invalid paginated asset inventory.');
			assets.push(...rows);
			if (rows.length < 100) return missingAssets(release, assets, expected, draft);
		}
		throw new Error('GitHub asset inventory exceeds the pagination bound.');
	};
	let missing;
	for (let attempt = 0; attempt < 3; attempt++) {
		missing = inventory(true);
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
	missing = inventory(false);
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
