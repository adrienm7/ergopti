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
assert.equal(
	(source.match(/^export /gm) || []).length,
	5,
	'the resolver APIs, the asset fallback and its two constants must load'
);

/** Loads unchanged production bodies with inert external ports and a fresh cache. */
function load(fetch, branch = () => 'main') {
	const body = source.replace(importLine, '').replace(/^export /gm, '');
	return new Function(
		'branchForInstall',
		'fetch',
		body +
			'\nreturn { getRelease, getRawUrl, assetUrlOrPage, LINUX_APPIMAGE_ASSET, RELEASES_PAGE };'
	)(branch, fetch);
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

/** Execute the unchanged prebuild module body with checked inert Git and owned file ports. */
function branchWrites(env, attached, commit, failAt) {
	const os = require('node:os');
	const acorn = require('acorn');
	const { resolveSiteContext } = require('../dev/site-context.cjs');
	const source = fs.readFileSync(path.join(ROOT, 'tools/dev/write-branch.js'), 'utf8');
	const ast = acorn.parse(source, { ecmaVersion: 'latest', sourceType: 'module' });
	const imports = ast.body.filter((node) => node.type === 'ImportDeclaration');
	assert.ok(imports.length >= 3 && imports.length <= 4);
	for (const node of imports)
		assert.ok(
			[
				'child_process',
				'fs',
				'path',
				'node:child_process',
				'node:fs',
				'node:path',
				'./site-context.cjs'
			].includes(node.source.value)
		);
	const body = ast.body
		.filter((node) => node.type !== 'ImportDeclaration')
		.map((node) => source.slice(node.start, node.end))
		.join('\n');
	const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-site-branch-test-'));
	const calls = [],
		writes = [];
	const answer = (value) => {
		if (value instanceof Error) throw value;
		return value + '\n';
	};
	const execFile = (command, args) => {
		assert.equal(command, 'git');
		calls.push(args);
		if (JSON.stringify(args) === JSON.stringify(['symbolic-ref', '--quiet', '--short', 'HEAD']))
			return answer(attached);
		assert.deepEqual(args, ['rev-parse', '--verify', 'HEAD^{commit}']);
		return answer(commit);
	};
	try {
		new Function(
			'execSync',
			'execFileSync',
			'writeFileSync',
			'mkdirSync',
			'resolve',
			'resolveSiteContext',
			'process',
			'console',
			body
		)(
			(command) => {
				assert.equal(command, 'git rev-parse --abbrev-ref HEAD');
				calls.push(command);
				return answer(attached);
			},
			execFile,
			(file, text, encoding) => {
				const stage = path.dirname(file) === path.join(owned, 'static') ? 'static' : 'root';
				assert.ok(
					file === path.join(owned, 'static', 'version.json') ||
						file === path.join(owned, 'version.json')
				);
				if (failAt === stage) throw new Error('controlled ' + stage + ' failure');
				fs.writeFileSync(file, text, encoding);
				writes.push(file);
			},
			(directory, options) => {
				assert.equal(directory, path.join(owned, 'static'));
				if (failAt === 'mkdir') throw new Error('controlled mkdir failure');
				fs.mkdirSync(directory, options);
			},
			path.resolve,
			resolveSiteContext,
			{ env, cwd: () => owned },
			{ log() {} }
		);
		assert.deepEqual(writes, [
			path.join(owned, 'static', 'version.json'),
			path.join(owned, 'version.json')
		]);
		return {
			documents: writes.map((file) => JSON.parse(fs.readFileSync(file, 'utf8'))),
			git_calls: calls
		};
	} catch (error) {
		if (!failAt) assert.equal(writes.length, 0, 'rejected identity cannot write metadata');
		throw error;
	} finally {
		assert.equal(path.resolve(path.dirname(owned)), path.resolve(os.tmpdir()));
		assert.ok(path.basename(owned).startsWith('ergopti-site-branch-test-'));
		fs.rmSync(owned, { recursive: true });
	}
}

function siteTarget(branch, base) {
	const source = 'a'.repeat(40);
	return {
		ERGOPTI_SITE_TARGET: branch,
		ERGOPTI_SITE_SOURCE_SHA: source,
		BASE_PATH: base,
		GITHUB_ACTIONS: 'true',
		GITHUB_SHA: source
	};
}

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
	await check('a release without the Linux AppImage links its page, never "#"', async () => {
		const client = load(async (url) => ({
			ok: true,
			json: async () => (url.endsWith('/latest') ? stable : newerDev)
		}));
		const release = await client.getRelease();
		const page = 'https://github.com/adrienm7/ergopti/releases';
		assert.equal(client.RELEASES_PAGE, page);
		assert.equal(client.LINUX_APPIMAGE_ASSET, 'ErgoptiPlus-x86_64.AppImage');
		assert.equal(client.assetUrlOrPage(release, client.LINUX_APPIMAGE_ASSET), page + '/tag/v1.0.0');
		assert.equal(
			client.assetUrlOrPage(release, 'ErgoptiPlus.exe'),
			stable.assets[0].browser_download_url
		);
		assert.equal(client.assetUrlOrPage(null, client.LINUX_APPIMAGE_ASSET), page);
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
	await check('site-branch-identity: failed Git refuses before either metadata write', async () => {
		assert.throws(
			() => branchWrites({}, new Error('controlled Git failure')),
			/controlled Git failure/
		);
	});
	await check('site-branch-identity: detached local HEAD refuses before writing', async () => {
		assert.throws(() => branchWrites({}, 'HEAD'), /attached branch/);
	});
	await check('site-branch-identity: legitimate attached feature branches stay exact', async () => {
		for (const branch of ['main', 'dev', 'codex/feature-site', 'feature/site-identity']) {
			const result = branchWrites({}, branch);
			assert.deepEqual(result.documents, [{ branch }, { branch }]);
			assert.deepEqual(result.git_calls, [['symbolic-ref', '--quiet', '--short', 'HEAD']]);
		}
	});
	await check('site-branch-identity: both explicit targets bind the same real commit', async () => {
		for (const [branch, base_path] of [
			['main', ''],
			['dev', '/dev']
		]) {
			const env = siteTarget(branch, base_path);
			const result = branchWrites(env, 'HEAD', env.ERGOPTI_SITE_SOURCE_SHA);
			const expected = { branch, base_path, source_sha: env.ERGOPTI_SITE_SOURCE_SHA };
			assert.deepEqual(result.documents, [expected, expected]);
			assert.deepEqual(result.git_calls, [['rev-parse', '--verify', 'HEAD^{commit}']]);
		}
	});
	await check('site-branch-identity: incomplete or foreign target context refuses', async () => {
		for (const edit of [
			(env) => {
				delete env.ERGOPTI_SITE_TARGET;
			},
			(env) => {
				delete env.ERGOPTI_SITE_SOURCE_SHA;
			},
			(env) => {
				delete env.BASE_PATH;
			},
			(env) => {
				env.ERGOPTI_SITE_TARGET = 'feature/site';
			},
			(env) => {
				env.ERGOPTI_SITE_TARGET = 'HEAD';
			},
			(env) => {
				env.BASE_PATH = '';
			},
			(env) => {
				env.BASE_PATH = '/development';
			},
			(env) => {
				env.ERGOPTI_SITE_SOURCE_SHA = 'invalid';
			},
			(env) => {
				env.GITHUB_SHA = 'b'.repeat(40);
			},
			(env) => {
				delete env.GITHUB_SHA;
			}
		]) {
			const env = siteTarget('dev', '/dev');
			edit(env);
			assert.throws(() => branchWrites(env, 'HEAD', 'a'.repeat(40)), /Site build context refused/);
		}
	});
	await check('site-branch-identity: wrong checkout and failed commit lookup refuse', async () => {
		assert.throws(
			() => branchWrites(siteTarget('dev', '/dev'), 'HEAD', 'b'.repeat(40)),
			/checked-out commit/
		);
		assert.throws(
			() => branchWrites(siteTarget('dev', '/dev'), 'HEAD', new Error('controlled commit failure')),
			/controlled commit failure/
		);
	});
	await check('site-branch-identity: GitHub cannot silently use local mode', async () => {
		assert.throws(() => branchWrites({ GITHUB_ACTIONS: 'true' }, 'dev'), /explicit site target/);
	});
	await check('site-branch-identity: ambiguous branch metadata refuses', async () => {
		for (const branch of ['', 'main\ndev', 'feature\u0000name', ' feature name '])
			assert.throws(() => branchWrites({}, branch), /attached branch/);
	});
	await check('site-branch-identity: directory and both write failures propagate', async () => {
		for (const stage of ['mkdir', 'static', 'root'])
			assert.throws(
				() => branchWrites({}, 'codex/site', undefined, stage),
				new RegExp('controlled ' + stage + ' failure')
			);
	});

	await check(
		'site-artifact-integrity: received files and producer context stay exact',
		async () => {
			const os = require('node:os');
			const artifact = require('../ci/site-artifact.cjs');
			const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-site-artifact-test-'));
			const cname = Buffer.from('fixture.example\n');
			let assertions = 0;
			const refuses = (body, message) => {
				assert.throws(body, message);
				assertions++;
			};
			try {
				for (const [target, base_path] of [
					['main', ''],
					['dev', '/dev']
				]) {
					const directory = path.join(owned, target);
					fs.mkdirSync(path.join(directory, '_app'), { recursive: true });
					const producer = {
						source_sha: 'a'.repeat(40),
						run_id: '123',
						run_attempt: '1',
						target,
						base_path,
						lock_sha256: 'b'.repeat(64)
					};
					fs.writeFileSync(
						path.join(directory, 'index.html'),
						'<!doctype html><title>Actual fixture output</title>'
					);
					fs.writeFileSync(
						path.join(directory, 'version.json'),
						artifact.canonical({ branch: target, base_path, source_sha: producer.source_sha })
					);
					fs.writeFileSync(path.join(directory, 'CNAME'), cname);
					const chunk = path.join(directory, '_app', 'chunk.js');
					const bytes = Buffer.from([0, 127, 255, 10]);
					fs.writeFileSync(chunk, bytes);
					const receipt = artifact.seal(directory, producer, cname);
					const receiptFile = path.join(owned, target + '.json');
					const text = artifact.canonical(receipt);
					fs.writeFileSync(receiptFile, text);
					assert.deepEqual(artifact.readReceipt(receiptFile), receipt);
					assertions++;
					for (const invalid of [
						text.trimEnd(),
						text.replace(
							'  "schema_version": 1,',
							'  "schema_version": 1,\n  "schema_version": 1,'
						),
						'{invalid',
						artifact.canonical({ ...receipt, extra: true })
					]) {
						fs.writeFileSync(receiptFile, invalid);
						refuses(() => artifact.readReceipt(receiptFile));
					}
					const damagedUtf8 = Buffer.from(
						text.replace('"path": "version.json"', '"path": "\uFFFD"')
					);
					const damagedAt = damagedUtf8.indexOf(Buffer.from('\uFFFD'));
					assert.ok(damagedAt > 0, 'the invalid-UTF8 vector must alter an actual member path');
					fs.writeFileSync(
						receiptFile,
						Buffer.concat([
							damagedUtf8.subarray(0, damagedAt),
							Buffer.from([255]),
							damagedUtf8.subarray(damagedAt + 3)
						])
					);
					refuses(() => artifact.readReceipt(receiptFile), /canonical closed JSON/);
					refuses(() => artifact.readReceipt(directory), /ordinary files/);
					fs.truncateSync(receiptFile, 16 * 1024 * 1024 + 1);
					refuses(() => artifact.readReceipt(receiptFile), /capture limit/);
					fs.writeFileSync(receiptFile, text);
					assert.equal(receipt.members.length, 4);
					assertions++;
					const current = { ...producer, run_attempt: '2' };
					assert.deepEqual(artifact.verify(directory, receipt, current, cname), {
						files: 4,
						producer_run_attempt: '1',
						receiving_run_attempt: '2'
					});
					assertions++;
					assert.equal(artifact.verify(directory, receipt, producer, cname).files, 4);
					assertions++;
					for (const [key, value] of [
						['source_sha', 'c'.repeat(40)],
						['run_id', '124'],
						['lock_sha256', 'd'.repeat(64)]
					])
						refuses(
							() => artifact.verify(directory, receipt, { ...current, [key]: value }, cname),
							/foreign/
						);
					refuses(
						() => artifact.verify(directory, { ...receipt, run_attempt: '3' }, current, cname),
						/future/
					);
					for (const run_attempt of ['0', '02', '9007199254740992', 1, null])
						refuses(
							() => artifact.verify(directory, receipt, { ...current, run_attempt }, cname),
							/invalid CI number/
						);
					refuses(
						() =>
							artifact.verify(
								directory,
								receipt,
								{ ...current, target: target === 'main' ? 'dev' : 'main' },
								cname
							),
						/BASE_PATH/
					);
					refuses(
						() => artifact.verify(directory, { ...receipt, extra: true }, current, cname),
						/closed site artifact keys/
					);
					for (const mutate of [
						(value) => {
							value.members.pop();
						},
						(value) => {
							value.members.push(value.members[0]);
						},
						(value) => {
							value.members.reverse();
						},
						(value) => {
							value.members[0].path = '../outside';
						},
						(value) => {
							value.members[0].path = 'C:/outside';
						},
						(value) => {
							value.members[0].bytes++;
						},
						(value) => {
							value.members[0].sha256 = 'e'.repeat(64);
						},
						(value) => {
							value.members[0].extra = 'forged';
						}
					]) {
						const changed = structuredClone(receipt);
						mutate(changed);
						refuses(() => artifact.verify(directory, changed, current, cname));
					}
					fs.writeFileSync(chunk, Buffer.from([1, 127, 255, 10]));
					refuses(() => artifact.verify(directory, receipt, current, cname), /received site bytes/);
					fs.writeFileSync(chunk, bytes);
					fs.renameSync(chunk, chunk + '.changed');
					refuses(() => artifact.verify(directory, receipt, current, cname), /received site bytes/);
					fs.renameSync(chunk + '.changed', chunk);
					const extra = path.join(directory, 'unrecorded.html');
					fs.writeFileSync(extra, 'foreign');
					refuses(() => artifact.verify(directory, receipt, current, cname), /received site bytes/);
					fs.unlinkSync(extra);
					const version = path.join(directory, 'version.json'),
						versionBytes = fs.readFileSync(version);
					fs.writeFileSync(version, artifact.canonical({ branch: 'HEAD' }));
					refuses(() => artifact.seal(directory, producer, cname), /version metadata/);
					fs.writeFileSync(version, versionBytes);
					const homepage = path.join(directory, 'index.html');
					const homepageBytes = fs.readFileSync(homepage);
					fs.writeFileSync(homepage, '');
					refuses(() => artifact.seal(directory, producer, cname), /homepage is empty/);
					fs.writeFileSync(homepage, homepageBytes);
					refuses(
						() => artifact.seal(directory, producer, Buffer.from('foreign.example\n')),
						/CNAME/
					);
					const linked = path.join(owned, target + '-link');
					fs.symlinkSync(directory, linked, process.platform === 'win32' ? 'junction' : 'dir');
					refuses(
						() => artifact.verify(linked, receipt, current, cname),
						/linked or non-directory/
					);
					fs.unlinkSync(linked);
					const memberLink = path.join(directory, 'linked');
					fs.symlinkSync(
						path.join(directory, '_app'),
						memberLink,
						process.platform === 'win32' ? 'junction' : 'dir'
					);
					refuses(() => artifact.seal(directory, producer, cname), /ordinary files/);
					fs.unlinkSync(memberLink);
					assert.equal(artifact.verify(directory, receipt, current, cname).files, 4);
					assertions++;
				}
				assert.equal(assertions, 78, 'every explicit artifact acceptance/refusal must execute');
			} finally {
				assert.equal(path.resolve(path.dirname(owned)), path.resolve(os.tmpdir()));
				assert.ok(path.basename(owned).startsWith('ergopti-site-artifact-test-'));
				fs.rmSync(owned, { recursive: true });
			}
		}
	);

	await check('site-artifact-limits: exact limits accept and successors refuse', async () => {
		const artifact = require('../ci/site-artifact.cjs');
		const os = require('node:os');
		const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-site-artifact-limits-'));
		const limits = artifact.LIMITS;
		const context = {
			schema_version: 1,
			source_sha: 'a'.repeat(40),
			run_id: '123',
			run_attempt: '1',
			target: 'main',
			base_path: '',
			lock_sha256: 'b'.repeat(64)
		};
		const row = (index, bytes = 0) => ({
			path: 'files/' + String(index).padStart(5, '0'),
			bytes,
			sha256: 'c'.repeat(64)
		});
		try {
			const exact = {
				...context,
				members: Array.from({ length: limits.members }, (_, i) => row(i))
			};
			assert.doesNotThrow(() => artifact.validateReceipt(exact));
			assert.throws(
				() =>
					artifact.validateReceipt({ ...exact, members: [...exact.members, row(limits.members)] }),
				/too many site members/
			);
			assert.doesNotThrow(() =>
				artifact.validateReceipt({ ...context, members: [row(0, limits.fileBytes)] })
			);
			assert.throws(
				() => artifact.validateReceipt({ ...context, members: [row(0, limits.fileBytes + 1)] }),
				/invalid member size/
			);
			const total = {
				...context,
				members: Array.from({ length: limits.totalBytes / limits.fileBytes }, (_, i) =>
					row(i, limits.fileBytes)
				)
			};
			assert.doesNotThrow(() => artifact.validateReceipt(total));
			assert.throws(
				() =>
					artifact.validateReceipt({
						...total,
						members: [...total.members, row(total.members.length, 1)]
					}),
				/total byte limit/
			);
			const padding = limits.receiptBytes - Buffer.byteLength(artifact.canonical(exact));
			assert.ok(padding >= 0);
			exact.members.forEach((member, i) => {
				member.path +=
					'/' +
					'x'.repeat(
						Math.floor(padding / limits.members) - 1 + (i < padding % limits.members ? 1 : 0)
					);
			});
			const receipt = path.join(owned, 'exact.json');
			const bytes = Buffer.from(artifact.canonical(exact));
			assert.equal(bytes.length, limits.receiptBytes);
			fs.writeFileSync(receipt, bytes);
			assert.equal(artifact.readReceipt(receipt).members.length, limits.members);
			exact.members[0].path += 'x';
			fs.writeFileSync(receipt, artifact.canonical(exact));
			assert.throws(() => artifact.readReceipt(receipt), /capture limit/);
			const large = path.join(owned, 'large');
			fs.writeFileSync(large, '');
			fs.truncateSync(large, limits.fileBytes + 1);
			assert.throws(() => artifact.fileHash(large), /capture limit/);
		} finally {
			assert.equal(path.resolve(path.dirname(owned)), path.resolve(os.tmpdir()));
			assert.ok(path.basename(owned).startsWith('ergopti-site-artifact-limits-'));
			fs.rmSync(owned, { recursive: true });
		}
	});

	await check(
		'site-artifact-growth: a fresh file snapshot cannot exceed remaining capture budget',
		async () => {
			const acorn = require('acorn');
			const os = require('node:os');
			const actual = fs.readFileSync(path.join(ROOT, 'tools/ci/site-artifact.cjs'), 'utf8');
			const parsed = acorn.parse(actual, { ecmaVersion: 'latest' });
			const declarations = parsed.body
				.flatMap((node) => (node.type === 'VariableDeclaration' ? node.declarations : []))
				.filter((node) => node.id.name === 'LIMITS');
			assert.equal(declarations.length, 1);
			const initializer = declarations[0].init;
			// Scale policy values only: both production capture functions remain byte-identical.
			const bounded =
				actual.slice(0, initializer.start) +
				'Object.freeze({receiptBytes:4096,members:16,fileBytes:4,totalBytes:4})' +
				actual.slice(initializer.end);
			const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-site-artifact-growth-'));
			const target = path.join(owned, 'b');
			let grew = false,
				opens = 0,
				reads = 0;
			const handles = new Set();
			try {
				fs.writeFileSync(path.join(owned, 'a'), 'abc');
				fs.writeFileSync(target, 'x');
				const files = {
					...fs,
					lstatSync(file, options) {
						const before = fs.lstatSync(file, options);
						if (path.resolve(file) === target && options === undefined && !grew) {
							fs.appendFileSync(target, 'y');
							grew = true;
						}
						return before;
					},
					openSync(file, ...args) {
						const fd = fs.openSync(file, ...args);
						if (path.resolve(file) === target) {
							opens++;
							handles.add(fd);
						}
						return fd;
					},
					readSync(fd, ...args) {
						if (handles.has(fd)) reads++;
						return fs.readSync(fd, ...args);
					}
				};
				const loaded = { exports: {} };
				const ports = (name) => {
					if (name === 'node:fs') return files;
					if (name === 'node:child_process')
						return {
							execFileSync() {
								throw new Error('unexpected Git actor');
							}
						};
					if (name === '../dev/site-context.cjs') return require('../dev/site-context.cjs');
					assert.ok(['node:path', 'node:crypto', 'node:assert/strict'].includes(name));
					return require(name);
				};
				new Function('require', 'module', 'process', bounded)(ports, loaded, {});
				assert.throws(() => loaded.exports.members(owned), /file exceeds the capture limit/);
				assert.equal(grew, true, 'the file grows at the actual preliminary/fresh snapshot seam');
				assert.equal(opens, 0, 'over-budget growth refuses before the file is opened');
				assert.equal(reads, 0, 'over-budget growth refuses before reading bytes');
			} finally {
				assert.equal(path.resolve(path.dirname(owned)), path.resolve(os.tmpdir()));
				assert.ok(path.basename(owned).startsWith('ergopti-site-artifact-growth-'));
				fs.rmSync(owned, { recursive: true });
			}
		}
	);

	await check(
		'site-testbuild: complete browser proof binds exact build context and bytes',
		async () => {
			const artifact = require('../ci/site-artifact.cjs');
			const os = require('node:os');
			const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-site-testbuild-'));
			const context = {
				source_sha: 'a'.repeat(40),
				run_id: '123',
				run_attempt: '1',
				target: 'main',
				base_path: '',
				lock_sha256: 'b'.repeat(64)
			};
			const build = {
				schema_version: 1,
				...context,
				members: [{ path: 'index.html', bytes: 3, sha256: 'c'.repeat(64) }]
			};
			const browsers = artifact.SITE_BROWSERS.map((name) => ({
				name,
				routes: [...artifact.SITE_ROUTES],
				local_http_errors: 0,
				page_errors: 0,
				hydration: true,
				interaction: true
			}));
			const worker = { ...context, run_attempt: '2' },
				receiving = { ...context, run_attempt: '3' };
			const proof = artifact.recordTestbuild(build, worker, browsers);
			try {
				assert.deepEqual(artifact.verifyTestbuild(build, proof, receiving), {
					build_run_attempt: '1',
					testbuild_run_attempt: '2',
					receiving_run_attempt: '3'
				});
				assert.doesNotThrow(() => artifact.verifyTestbuild(build, proof, worker));
				const sameAttempt = artifact.recordTestbuild(build, context, browsers);
				assert.doesNotThrow(() => artifact.verifyTestbuild(build, sameAttempt, context));
				const receipt = path.join(owned, 'testbuild.json');
				fs.writeFileSync(receipt, artifact.canonical(proof));
				assert.deepEqual(artifact.readTestbuild(receipt), proof);
				for (const [key, value] of [
					['source_sha', 'd'.repeat(40)],
					['run_id', '124'],
					['lock_sha256', 'e'.repeat(64)],
					['run_attempt', '1']
				])
					assert.throws(() =>
						artifact.verifyTestbuild(build, proof, { ...receiving, [key]: value })
					);
				for (const mutate of [
					(value) => {
						value.scope = 'source-browser';
					},
					(value) => {
						value.schema_version = 2;
					},
					(value) => {
						value.run_attempt = '4';
					},
					(value) => {
						value.run_attempt = '0';
					},
					(value) => {
						value.run_attempt = 2;
					},
					(value) => {
						value.source_sha = 'd'.repeat(40);
					},
					(value) => {
						value.run_id = '124';
					},
					(value) => {
						value.target = 'dev';
						value.base_path = '/dev';
					},
					(value) => {
						value.base_path = '/dev';
					},
					(value) => {
						value.lock_sha256 = 'e'.repeat(64);
					},
					(value) => {
						value.build_receipt_sha256 = 'f'.repeat(64);
					},
					(value) => {
						value.build_run_attempt = '2';
					},
					(value) => {
						value.build_run_attempt = '3';
					},
					(value) => {
						value.qualified = true;
					},
					(value) => {
						value.browsers.pop();
					},
					(value) => {
						value.browsers.push(value.browsers[0]);
					},
					(value) => {
						value.browsers.reverse();
					},
					(value) => {
						value.browsers[1].name = 'chromium';
					},
					(value) => {
						value.browsers[0].routes.pop();
					},
					(value) => {
						value.browsers[0].routes.push('/unknown');
					},
					(value) => {
						value.browsers[0].routes.reverse();
					},
					(value) => {
						value.browsers[0].local_http_errors = 1;
					},
					(value) => {
						value.browsers[0].page_errors = 1;
					},
					(value) => {
						value.browsers[0].hydration = false;
					},
					(value) => {
						value.browsers[0].interaction = false;
					},
					(value) => {
						value.browsers[0].optional = true;
					}
				]) {
					const changed = structuredClone(proof);
					mutate(changed);
					assert.throws(() => artifact.verifyTestbuild(build, changed, receiving));
				}
				const changedBuild = structuredClone(build);
				changedBuild.members[0].bytes++;
				assert.throws(
					() => artifact.verifyTestbuild(changedBuild, proof, receiving),
					/different Build bytes/
				);
				assert.throws(() =>
					artifact.recordTestbuild(build, { ...context, run_attempt: '0' }, browsers)
				);
				assert.throws(() => artifact.recordTestbuild(build, worker, []));
				fs.writeFileSync(receipt, artifact.canonical({ ...proof, extra: true }));
				assert.throws(() => artifact.readTestbuild(receipt));
				fs.writeFileSync(
					receipt,
					artifact
						.canonical(proof)
						.replace(
							'"scope": "svelte-output",',
							'"scope": "svelte-output",\n  "scope": "svelte-output",'
						)
				);
				assert.throws(() => artifact.readTestbuild(receipt), /canonical/);
				fs.truncateSync(receipt, 64 * 1024 + 1);
				assert.throws(() => artifact.readTestbuild(receipt), /capture limit/);
			} finally {
				assert.equal(path.resolve(path.dirname(owned)), path.resolve(os.tmpdir()));
				assert.ok(path.basename(owned).startsWith('ergopti-site-testbuild-'));
				fs.rmSync(owned, { recursive: true });
			}
		}
	);

	await check(
		'deployment receives the exact successful source/run artifact and browser proof',
		async () => {
			assert.equal(
				(await require('./fixtures/site-deploy-admission-controls.cjs').run()).controls,
				153
			);
		}
	);
	await check('production output browser assertions reject inert causal failures', async () => {
		assert.equal(await require('./fixtures/site-artifact-smoke-controls.cjs').run(), 16);
	});
	await check('final shared Verdict receives both exact Build and browser proofs', async () => {
		assert.equal((await require('./fixtures/site-verdict-controls.cjs').run()).controls, 49);
	});
	await check('human site lots retain the one target and base authority', () => {
		const owner = require('../dev/site-context.cjs');
		const metadata = owner.siteLots();
		assert.deepEqual(metadata, {
			'Stable site': { target: 'main', base_path: '' },
			'Development site': { target: 'dev', base_path: '/dev' }
		});
		for (const [lot, row] of Object.entries(metadata)) {
			assert.equal(owner.siteLot(row.target), lot);
			assert.deepEqual(owner.selectSiteLot(lot, JSON.stringify(metadata)), row);
			assert.deepEqual(owner.resolveSiteTarget(row.target, row.base_path), {
				branch: row.target,
				base_path: row.base_path
			});
		}
	});
	await check('both production build legs forward the same complete admitted map', () => {
		const { planSiteLots } = require('../ci/site-matrix.cjs');
		const expected = planSiteLots('plan', {});
		assert.deepEqual(expected.matrix, { lot: ['Stable site', 'Development site'] });
		for (const [lot, row] of Object.entries(expected.metadata))
			assert.deepEqual(
				planSiteLots('admit', {
					SITE_LOT: lot,
					SITE_METADATA: JSON.stringify(expected.metadata),
					ERGOPTI_SITE_TARGET: row.target,
					BASE_PATH: row.base_path
				}),
				expected
			);
	});
	await check('foreign, partial, duplicated and reassigned site lot transports refuse', () => {
		const { planSiteLots } = require('../ci/site-matrix.cjs');
		const expected = planSiteLots('plan', {});
		const env = {
			SITE_LOT: 'Stable site',
			SITE_METADATA: JSON.stringify(expected.metadata),
			ERGOPTI_SITE_TARGET: 'main',
			BASE_PATH: ''
		};
		for (const change of [
			{ SITE_LOT: '' },
			{ SITE_LOT: 'foreign' },
			{ SITE_LOT: undefined },
			{ SITE_METADATA: '' },
			{ SITE_METADATA: '{}' },
			{ SITE_METADATA: JSON.stringify({ 'Stable site': expected.metadata['Stable site'] }) },
			{ SITE_METADATA: env.SITE_METADATA.replace('"main"', '"dev"') },
			{ SITE_METADATA: env.SITE_METADATA.replace('"base_path":""', '"base_path":"/dev"') },
			{ SITE_METADATA: env.SITE_METADATA.replace('{', '{"Stable site":{},') },
			{
				SITE_METADATA: JSON.stringify({
					...expected.metadata,
					Foreign: expected.metadata['Stable site']
				})
			},
			{ ERGOPTI_SITE_TARGET: 'dev' },
			{ BASE_PATH: '/dev' }
		])
			assert.throws(() => planSiteLots('admit', { ...env, ...change }));
		assert.throws(() => planSiteLots('unknown', env));
	});
	assert.equal(checks, 35, 'every declared behavior control must complete');
	console.log(
		'Website release resolver and branch identity: 35 actual-source controls passed; no network used.'
	);
}
main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
