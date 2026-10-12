// tools/test/fixtures/site-artifact-smoke-controls.cjs

/** Portable resolver and recorded browser controls; these do not qualify a real site or browser. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const smoke = require('../browser/site-artifact-smoke.playwright.cjs');

/** Run the actual pure helpers and assertion body with finite recording ports only. */
async function run() {
	let checks = 0;
	const check = async (name, body) => {
		await body();
		checks += 1;
		console.log('[OK] site-artifact-smoke portable: ' + name);
	};
	await check('root and dev have distinct mounted URLs', () => {
		assert.equal(smoke.requestPath('/', ''), '/');
		assert.equal(smoke.requestPath('/dev/', '/dev'), '/');
		assert.equal(smoke.requestPath('/dev/utilisation?x=1', '/dev'), '/utilisation');
		assert.throws(() => smoke.requestPath('/utilisation', '/dev'), /outside artifact mount/);
		assert.throws(() => smoke.requestPath('/developer/', '/dev'), /outside artifact mount/);
	});
	await check('raw traversal and encoded path ambiguity refuse', () => {
		for (const raw of [
			'/../index.html',
			'/a/./b',
			'/%2e%2e/index.html',
			'/%2Findex.html',
			'/a%5cb',
			'//host/path',
			'/a//b',
			'/a\\b',
			'/%00',
			'/bad%xx'
		])
			assert.throws(() => smoke.requestPath(raw, ''));
	});
	const root = path.resolve('owned-site-port');
	const files = (entries) => ({
		lstatSync(file) {
			const type = entries[path.relative(root, file).split(path.sep).join('/')];
			if (!type) throw Object.assign(new Error('missing recorded file'), { code: 'ENOENT' });
			return {
				isDirectory: () => type === 'directory',
				isFile: () => type === 'file',
				isSymbolicLink: () => type === 'link'
			};
		}
	});
	await check('real layout selects one HTML file and declared resource MIME', () => {
		const port = files({
			'': 'directory',
			'index.html': 'file',
			'utilisation.html': 'file',
			_app: 'directory',
			'_app/start.js': 'file'
		});
		assert.deepEqual(smoke.resolveRequest(root, '/dev', '/dev/', port), {
			file: path.join(root, 'index.html'),
			mime: 'text/html; charset=utf-8'
		});
		assert.equal(
			smoke.resolveRequest(root, '', '/utilisation', port).file,
			path.join(root, 'utilisation.html')
		);
		assert.equal(
			smoke.resolveRequest(root, '', '/_app/start.js', port).mime,
			'text/javascript; charset=utf-8'
		);
	});
	await check('missing hotstrings and ambiguous generated HTML refuse', () => {
		const port = files({
			'': 'directory',
			'index.html': 'file',
			'utilisation.html': 'file',
			utilisation: 'directory',
			'utilisation/index.html': 'file'
		});
		assert.throws(() => smoke.resolveRequest(root, '', '/utilisation', port), /ambiguous/);
		for (const name of ['magic', 'magickey'])
			assert.throws(
				() => smoke.resolveRequest(root, '', '/hotstrings/' + name + '.toml', port),
				/Missing/
			);
		assert.throws(
			() => smoke.resolveRequest(root, '/dev', '/hotstrings/magickey.toml', port),
			/outside/
		);
	});
	await check('symlink root/file/parent and unknown MIME refuse', () => {
		for (const [url, entries] of [
			['/', { '': 'link' }],
			['/', { '': 'directory', 'index.html': 'link' }],
			['/assets/start.js', { '': 'directory', assets: 'link' }],
			['/unknown.bin', { '': 'directory', 'unknown.bin': 'file' }]
		])
			assert.throws(() => smoke.resolveRequest(root, '', url, files(entries)));
	});
	await check('only the three declared inert GitHub API routes exist', () => {
		const repo = 'https://api.github.com/repos/adrienm7/ergopti';
		assert.equal(smoke.githubFixture(repo).stargazers_count, 123);
		assert.equal(smoke.githubFixture(repo + '/releases/latest').prerelease, false);
		assert.equal(smoke.githubFixture(repo + '/releases?per_page=100&page=1')[0].prerelease, true);
		for (const url of [
			repo + '/releases?per_page=100&page=2',
			'https://foreign.invalid/',
			'http://127.0.0.1/hotstrings/magickey.toml'
		])
			assert.equal(smoke.githubFixture(url), null);
	});
	function pagePort({
		unhydrated = false,
		http = false,
		invisible = false,
		foreignNavigation = false,
		reload = false,
		wrongDownload = false,
		missingDownload = false
	} = {}) {
		let visible = false,
			url,
			navigationWait,
			navigationTarget,
			navigated = false;
		const routes = [],
			clicks = [],
			heads = [];
		let disposed = 0;
		return {
			routes,
			clicks,
			heads,
			get disposed() {
				return disposed;
			},
			url: () => url,
			async evaluate() {
				return reload && navigated ? 18 : 17;
			},
			waitForURL(target) {
				navigationTarget = target;
				return new Promise((resolve) => {
					navigationWait = resolve;
				});
			},
			request: {
				async head(target) {
					heads.push(target);
					return {
						ok: () => !missingDownload,
						async dispose() {
							disposed += 1;
						}
					};
				}
			},
			async goto(target) {
				routes.push(target);
				url = target;
				visible = false;
				return { ok: () => !http };
			},
			locator(selector) {
				return {
					first() {
						return this;
					},
					async isVisible() {
						return visible;
					},
					async click() {
						clicks.push(selector);
						if (selector.startsWith('header')) {
							url = navigationTarget;
							navigated = true;
							navigationWait();
						} else if (!unhydrated) visible = !visible;
					},
					async getAttribute() {
						if (selector.startsWith('header'))
							return foreignNavigation ? '/foreign' : 'utilisation';
						return wrongDownload ? '#' : selector.match(/href="([^"]+)"/)[1];
					},
					async waitFor({ state }) {
						if (selector === '#clavier-ref') assert.equal(visible, state === 'visible');
						else assert.equal(invisible, false);
					}
				};
			}
		};
	}
	await check(
		'actual browser assertion body visits all authored routes and toggles twice',
		async () => {
			const page = pagePort();
			await smoke.exercisePage(page, 'http://127.0.0.1:12345', '/dev', { local: [], page: [] });
			assert.deepEqual(
				page.routes,
				smoke.SITE_ROUTES.map((route) => 'http://127.0.0.1:12345/dev' + route)
			);
			assert.equal(page.clicks.length, smoke.SITE_ROUTES.length * 2 + 1);
		}
	);
	await check('client navigation retains the target prefix and document identity', async () => {
		for (const base of ['', '/dev']) {
			const page = pagePort();
			await page.goto('http://127.0.0.1:1' + base + '/');
			await smoke.exerciseNavigation(page, 'http://127.0.0.1:1', base);
			assert.equal(page.url(), 'http://127.0.0.1:1' + base + '/utilisation');
		}
		for (const options of [{ foreignNavigation: true }, { reload: true }]) {
			const page = pagePort(options);
			await page.goto('http://127.0.0.1:1/dev/');
			await assert.rejects(() => smoke.exerciseNavigation(page, 'http://127.0.0.1:1', '/dev'));
		}
	});
	await check('rendered fixture downloads and local HEAD refusals remain distinct', async () => {
		for (const base of ['', '/dev']) {
			const page = pagePort();
			await page.goto('http://127.0.0.1:1' + base + '/utilisation');
			await smoke.exerciseDownloads(page, 'http://127.0.0.1:1', base, '/utilisation');
			assert.equal(page.heads.length, 2);
			assert.equal(page.disposed, 2);
			assert.ok(
				page.heads.every((url) => url.startsWith('http://127.0.0.1:1' + base + '/documents/'))
			);
			await smoke.exerciseDownloads(page, 'http://127.0.0.1:1', base, '/ergopti-plus');
			assert.equal(page.heads.length, 2, 'remote binaries are never fetched');
		}
		for (const options of [{ wrongDownload: true }, { missingDownload: true }]) {
			const page = pagePort(options);
			await page.goto('http://127.0.0.1:1/utilisation');
			await assert.rejects(() =>
				smoke.exerciseDownloads(page, 'http://127.0.0.1:1', '', '/utilisation')
			);
			assert.equal(page.disposed, options.missingDownload ? 1 : 0);
		}
	});
	await check('unhydrated/absent UI, HTTP, page and resource errors cannot qualify', async () => {
		for (const options of [{ unhydrated: true }, { http: true }, { invisible: true }])
			await assert.rejects(() =>
				smoke.exercisePage(pagePort(options), 'http://127.0.0.1:1', '', { local: [], page: [] })
			);
		await assert.rejects(
			() =>
				smoke.exercisePage(pagePort(), 'http://127.0.0.1:1', '', {
					local: ['missing magic.toml'],
					page: []
				}),
			/Local resource/
		);
		await assert.rejects(
			() =>
				smoke.exercisePage(pagePort(), 'http://127.0.0.1:1', '', {
					local: [],
					page: ['hydration error']
				}),
			/Browser failures/
		);
	});
	await check('owned browser retirement runs on success and assertion failure', async () => {
		for (const failure of [false, true]) {
			let closed = 0;
			const sentinel = new Error('controlled assertion failure');
			const engine = {
				async launch() {
					return {
						async close() {
							closed += 1;
						}
					};
				}
			};
			const invoke = () =>
				smoke.withBrowser(engine, async () => {
					if (failure) throw sentinel;
					return 7;
				});
			if (failure) await assert.rejects(invoke, (error) => error === sentinel);
			else assert.equal(await invoke(), 7);
			assert.equal(closed, 1);
		}
	});
	await check(
		'actual CLI orders both verifications and publishes exclusively after completion',
		async () => {
			const fs = require('node:fs');
			const acorn = require('acorn');
			const source = fs.readFileSync(
				path.join(__dirname, '../browser/site-artifact-smoke.playwright.cjs'),
				'utf8'
			);
			const ast = acorn.parse(source, { ecmaVersion: 'latest' });
			const functions = ast.body.filter(
				(node) => node.type === 'FunctionDeclaration' && node.id.name === 'main'
			);
			assert.equal(functions.length, 1, 'actual CLI entry must be unique');
			const body = source.slice(functions[0].start, functions[0].end);
			for (const fault of [null, 'verify-before', 'browser', 'verify-after', 'record', 'write']) {
				const events = [],
					writes = [];
				const sentinel = new Error('controlled CLI failure');
				const context = { base_path: '/dev' },
					build = {},
					browsers = [];
				let verifications = 0;
				const mark = (stage) => {
					events.push(stage);
					if (fault === stage) throw sentinel;
				};
				const filePort = {
					realpathSync: (value) => value,
					writeFileSync(file, text, options) {
						assert.deepEqual(options, { flag: 'wx' });
						mark('write');
						writes.push({ file, text });
					}
				};
				const artifactPort = {
					ciContext() {
						mark('context');
						return context;
					},
					readReceipt() {
						mark('build');
						return build;
					},
					fileHash() {
						mark('cname');
						return { content: Buffer.from('ergopti.fr\n') };
					},
					verify(site, received, receiving) {
						assert.equal(received, build);
						assert.equal(receiving, context);
						mark(++verifications === 1 ? 'verify-before' : 'verify-after');
					},
					recordTestbuild(received, receiving, observed) {
						assert.equal(received, build);
						assert.equal(receiving, context);
						assert.equal(observed, browsers);
						mark('record');
						return 'recorded proof';
					},
					canonical: (value) => value
				};
				const entry = new Function(
					'assert',
					'path',
					'fs',
					'artifact',
					'runBrowsers',
					'require',
					'console',
					'process',
					body + '\nreturn main;'
				)(
					assert,
					path,
					filePort,
					artifactPort,
					async () => {
						mark('browser');
						return browsers;
					},
					(name) => {
						assert.equal(name, 'playwright');
						return {};
					},
					{ log() {} },
					{ env: {}, cwd: () => path.resolve('owned-source') }
				);
				const args = ['owned/site', 'owned/build.json', 'owned/testbuild.json'];
				if (fault) {
					await assert.rejects(
						() => entry(args),
						(error) => error === sentinel
					);
					assert.equal(writes.length, 0, 'no proof after failed observation');
				} else {
					await entry(args);
					assert.deepEqual(events, [
						'context',
						'build',
						'cname',
						'verify-before',
						'browser',
						'verify-after',
						'record',
						'write'
					]);
					assert.deepEqual(writes, [{ file: path.resolve(args[2]), text: 'recorded proof' }]);
				}
			}
		}
	);
	await check('encoded filename spaces serve actual owned bytes in GET and HEAD', () => {
		const fs = require('node:fs'),
			os = require('node:os');
		const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-site-smoke-space-'));
		const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0xff]);
		try {
			fs.writeFileSync(path.join(root, 'image name.png'), bytes, { flag: 'wx' });
			for (const base of ['', '/dev']) {
				assert.equal(
					smoke.resolveRequest(root, base, base + '/image%20name.png').file,
					path.join(root, 'image name.png')
				);
				for (const method of ['GET', 'HEAD']) {
					const errors = [],
						responses = [];
					smoke.serveRequest(
						root,
						base,
						{ method, url: base + '/image%20name.png' },
						{
							writeHead(status, headers) {
								responses.push({ status, headers });
							},
							end(body) {
								responses.push(body);
							}
						},
						errors
					);
					assert.deepEqual(errors, []);
					assert.deepEqual(responses[0], {
						status: 200,
						headers: {
							'Content-Type': 'image/png',
							'Cache-Control': 'no-store'
						}
					});
					assert.deepEqual(responses[1], method === 'GET' ? bytes : undefined);
				}
			}
			for (const raw of [
				'/image name.png',
				'/%2e%2e/image%20name.png',
				'/image%00name.png',
				'/image%09name.png',
				'/image%1fname.png',
				'/image%7fname.png'
			])
				assert.throws(() => smoke.resolveRequest(root, '', raw));
		} finally {
			assert.equal(path.dirname(root), path.resolve(os.tmpdir()));
			assert.ok(path.basename(root).startsWith('ergopti-site-smoke-space-'));
			fs.rmSync(root, { recursive: true });
		}
	});
	await check('actual browser context admits the declared desktop Header navigation', async () => {
		const fs = require('node:fs'),
			acorn = require('acorn');
		const sourceFile = path.join(__dirname, '../browser/site-artifact-smoke.playwright.cjs');
		const source = fs.readFileSync(sourceFile, 'utf8');
		const ast = acorn.parse(source, { ecmaVersion: 'latest' });
		const owners = ast.body.filter(
			(node) => node.type === 'FunctionDeclaration' && node.id.name === 'runBrowsers'
		);
		assert.equal(owners.length, 1, 'one actual browser context owner');
		const calls = [];
		function visit(node) {
			if (!node || typeof node !== 'object') return;
			if (
				node.type === 'CallExpression' &&
				node.callee.type === 'MemberExpression' &&
				node.callee.object.name === 'browser' &&
				node.callee.property.name === 'newContext'
			)
				calls.push(node);
			for (const value of Object.values(node)) {
				if (Array.isArray(value)) value.forEach(visit);
				else if (value && typeof value === 'object') visit(value);
			}
		}
		visit(owners[0]);
		assert.equal(calls.length, 1, 'one executable newContext call');
		const execute = new Function('browser', 'return ' + source.slice(calls[0].start, calls[0].end));
		let closed = 0,
			options;
		await smoke.withBrowser(
			{
				async launch() {
					return {
						async newContext(value) {
							options = value;
							return {};
						},
						async close() {
							closed += 1;
						}
					};
				}
			},
			execute
		);
		assert.equal(closed, 1, 'actual withBrowser retires the recording context owner');
		assert.deepEqual(options, { serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
		const sourceRoot = path.resolve(path.dirname(sourceFile), '../../..');
		const header = fs.readFileSync(
			path.join(sourceRoot, 'src/lib/components/Header.svelte'),
			'utf8'
		);
		assert.match(header, /@media\s*\(max-width:\s*1280px\)/);
		assert.match(header, /header \.menu-btn:not\(:checked\) ~ #menu\s*\{\s*height: 0;/);
		assert.ok(
			options.viewport.width > 1280,
			'desktop navigation stays outside the closed mobile menu'
		);
	});
	return checks;
}

module.exports = { run };
if (require.main === module)
	run().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
