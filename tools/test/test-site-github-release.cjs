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
	published_at: '2026-10-01T00:00:00Z',
	assets: assetNames.map((name) => ({
		name,
		browser_download_url: `https://github.com/adrienm7/ergopti/releases/download/v1.0.0/${name}`
	}))
};
const newerDev = Array.from({ length: 10 }, (_, index) => ({
	...stable,
	tag_name: `v0.0.0-dev.${200 - index}`,
	prerelease: true,
	published_at: new Date(Date.UTC(2026, 9, 9, 0, 0, 0) - index * 1000).toISOString()
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
		'dev selects the newest published prerelease without borrowing the stable endpoint',
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
			assert.deepEqual(calls, [API + '/releases?per_page=100&page=1']);
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
		assert.deepEqual(calls, [API + '/releases/latest', API + '/releases?per_page=100&page=1']);
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
	await check('a prerelease beyond a complete stable page remains available', async () => {
		const calls = [];
		const first = Array.from({ length: 100 }, (_, index) => ({
			...stable,
			tag_name: `v9.0.${index}`
		}));
		const client = load(
			async (url) => {
				calls.push(url);
				return { ok: true, json: async () => (url.endsWith('page=1') ? first : [newerDev[0]]) };
			},
			() => 'dev'
		);
		assert.equal((await client.getRelease()).tag, newerDev[0].tag_name);
		assert.deepEqual(calls, [
			API + '/releases?per_page=100&page=1',
			API + '/releases?per_page=100&page=2'
		]);
	});
	await check(
		'publication time selects the latest prerelease despite creation-list order',
		async () => {
			const client = load(
				async () => ({
					ok: true,
					json: async () => [newerDev[3], stable, newerDev[0], newerDev[2]]
				}),
				() => 'dev'
			);
			assert.equal((await client.getRelease()).tag, newerDev[0].tag_name);
		}
	);
	await check('drafts never become real prerelease downloads', async () => {
		const client = load(
			async () => ({
				ok: true,
				json: async () => [
					{ ...newerDev[0], draft: true, published_at: '2030-01-01T00:00:00Z' },
					newerDev[1]
				]
			}),
			() => 'dev'
		);
		assert.equal((await client.getRelease()).tag, newerDev[1].tag_name);
	});
	await check('a failed later page cannot publish an incomplete older result', async () => {
		let requests = 0;
		const first = Array.from({ length: 100 }, (_, index) => ({
			...newerDev[0],
			tag_name: `v0.0.0-dev.${index}`
		}));
		const client = load(
			async () => {
				requests++;
				return { ok: requests === 1, json: async () => first };
			},
			() => 'dev'
		);
		assert.equal(await client.getRelease(), null);
		assert.equal(await client.getRelease(), null);
		assert.equal(requests, 2);
	});
	await check(
		'repeated pages and invalid publication dates refuse a complete dev lookup',
		async () => {
			const page = Array.from({ length: 100 }, (_, index) => ({
				...newerDev[0],
				tag_name: `v0.0.0-dev.${index}`
			}));
			assert.equal(
				await load(
					async () => ({ ok: true, json: async () => page }),
					() => 'dev'
				).getRelease(),
				null
			);
			assert.equal(
				await load(
					async () => ({
						ok: true,
						json: async () => [{ ...newerDev[0], published_at: 'invalid' }]
					}),
					() => 'dev'
				).getRelease(),
				null
			);
		}
	);
	await check('only the exact public dev path selects prereleases', async () => {
		const branchSource = fs.readFileSync(path.join(ROOT, 'src/lib/js/isDev.js'), 'utf8');
		const body = branchSource.replace(/^export default .*;$/gm, '').replace(/^export /gm, '');
		for (const [pathname, expected] of [
			['/', 'main'],
			['/dev', 'dev'],
			['/dev/', 'dev'],
			['/dev/install', 'dev'],
			['/device', 'main'],
			['/development/', 'main']
		]) {
			const branch = new Function(
				'window',
				'XMLHttpRequest',
				body + '\nreturn {branchForInstall,detectDev};'
			)({ location: { pathname, hostname: 'ergopti.fr' } }, () => {
				throw new Error('production paths cannot read local metadata');
			});
			assert.equal(branch.branchForInstall(), expected);
			assert.equal(branch.detectDev(), expected === 'dev');
		}
	});
	assert.equal(checks, 16, 'every declared behavior control must complete');
	console.log('Website release resolver: 16 actual-source controls passed; no network used.');
}
main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
