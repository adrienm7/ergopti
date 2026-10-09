// tools/test/test-site-github-release.cjs

/**
 * ==============================================================================
 * MODULE: Website Release Channel Queries
 * DESCRIPTION:
 * Executes the actual website resolver with declared branch and fetch ports.
 * Stable downloads cannot depend on the first page of prereleases; dev routing,
 * strict asset-name lookup, cache isolation and API refusal remain intact.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(ROOT, 'src/lib/js/getGitHubRelease.js'), 'utf8');
const importLine = "import { branchForInstall } from '$lib/js/isDev.js';";
assert.equal(source.split(importLine).length - 1, 1, 'the canonical branch port must be explicit');
assert.equal((source.match(/^import /gm) || []).length, 1, 'unknown dependencies must refuse');
assert.equal((source.match(/^export /gm) || []).length, 2, 'both actual resolver APIs must load');

/** Loads unchanged production bodies with inert external ports and a fresh cache. */
function load(fetch, branch = () => 'main') {
	const body = source.replace(importLine, '').replace(/^export /gm, '');
	return new Function('branchForInstall', 'fetch', body + '\nreturn { getRelease, getRawUrl };')(
		branch,
		fetch
	);
}

const API = 'https://api.github.com/repos/adrienm7/ergopti';
const assetNames = ['ErgoptiPlus.exe', 'Ergopti_macOS.zip', 'ergopti-plus-linux.tar.gz'];
const stable = {
	tag_name: 'v1.0.0',
	prerelease: false,
	assets: assetNames.map((name) => ({
		name,
		browser_download_url: `https://github.com/adrienm7/ergopti/releases/download/v1.0.0/${name}`
	}))
};
const newerDev = Array.from({ length: 10 }, (_, index) => ({
	...stable,
	tag_name: `v0.0.0-dev.${200 - index}`,
	prerelease: true
}));

async function main() {
	let checks = 0;
	async function check(name, body) {
		await body();
		checks += 1;
		console.log('[OK] ' + name);
	}
	await check('ten newer prereleases cannot bury the stable download assets', async () => {
		const calls = [];
		const client = load(async (url) => {
			calls.push(url);
			return { ok: true, json: async () => (url.endsWith('/latest') ? stable : newerDev) };
		});
		const release = await client.getRelease();
		assert.ok(release, 'the stable release exists beyond the first dev page');
		assert.equal(release.tag, stable.tag_name);
		assert.deepEqual(calls, [API + '/releases/latest']);
		for (const asset of stable.assets)
			assert.equal(release.url(asset.name), asset.browser_download_url);
		assert.equal(release.url('missing-installer.exe'), null);
	});
	await check(
		'dev selects the first prerelease without borrowing the stable endpoint',
		async () => {
			const calls = [];
			const client = load(
				async (url) => {
					calls.push(url);
					return { ok: true, json: async () => [stable, ...newerDev] };
				},
				() => 'dev'
			);
			assert.equal((await client.getRelease()).tag, newerDev[0].tag_name);
			assert.deepEqual(calls, [API + '/releases?per_page=10']);
		}
	);
	await check('successful requests cache independently for each actual branch', async () => {
		let branch = 'main';
		const calls = [];
		const client = load(
			async (url) => {
				calls.push(url);
				return { ok: true, json: async () => (url.endsWith('/latest') ? stable : newerDev) };
			},
			() => branch
		);
		assert.equal((await client.getRelease()).tag, stable.tag_name);
		assert.equal((await client.getRelease()).tag, stable.tag_name);
		branch = 'dev';
		assert.equal((await client.getRelease()).tag, newerDev[0].tag_name);
		assert.equal((await client.getRelease()).tag, newerDev[0].tag_name);
		branch = 'main';
		assert.equal((await client.getRelease()).tag, stable.tag_name);
		assert.deepEqual(calls, [API + '/releases/latest', API + '/releases?per_page=10']);
	});
	for (const branch of ['main', 'dev']) {
		await check(
			branch + ' API errors remain cached refusal without parsing a failed response',
			async () => {
				let calls = 0;
				const client = load(
					async () => {
						calls += 1;
						return {
							ok: false,
							json: async () => {
								throw new Error('failed response must not parse');
							}
						};
					},
					() => branch
				);
				assert.equal(await client.getRelease(), null);
				assert.equal(await client.getRelease(), null);
				assert.equal(calls, 1);
			}
		);
		await check(branch + ' network and JSON failures do not fabricate a release', async () => {
			for (const fetch of [
				async () => {
					throw new Error('controlled network refusal');
				},
				async () => ({
					ok: true,
					json: async () => {
						throw new Error('controlled JSON refusal');
					}
				})
			])
				assert.equal(await load(fetch, () => branch).getRelease(), null);
		});
	}
	await check('a dev channel without a prerelease stays unavailable', async () => {
		assert.equal(
			await load(
				async () => ({ ok: true, json: async () => [stable] }),
				() => 'dev'
			).getRelease(),
			null
		);
	});
	await check('the stable endpoint cannot publish a prerelease response', async () => {
		assert.equal(
			await load(async () => ({ ok: true, json: async () => newerDev[0] })).getRelease(),
			null
		);
	});
	await check('raw installation scripts preserve the same channel authority', async () => {
		for (const branch of ['main', 'dev']) {
			const client = load(
				async () => {
					throw new Error('raw URLs cannot fetch');
				},
				() => branch
			);
			assert.equal(
				client.getRawUrl('static/install.sh'),
				`https://raw.githubusercontent.com/adrienm7/ergopti/${branch}/static/install.sh`
			);
		}
	});
	assert.equal(checks, 10, 'every declared behavior control must complete');
	console.log('Website release resolver: 10 actual-source controls passed; no network used.');
}
main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
