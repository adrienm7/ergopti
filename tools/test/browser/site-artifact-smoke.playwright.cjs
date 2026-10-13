// tools/test/browser/site-artifact-smoke.playwright.cjs

/** Exercise received Svelte output in real browsers without rebuilding or replacing local resources. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const artifact = require('../../ci/site-artifact.cjs');
const { SITE_ROUTES } = artifact;

const FIXTURE_TAG = 'v0.0.0-smoke-fixture';
const FIXTURE_ASSETS = Object.freeze([
	'Ergopti_windows.exe',
	'Ergopti_macOS.zip',
	'ErgoptiPlus.exe',
	'ErgoptiPlus.app.zip',
	'ErgoptiPlus-linux-x86_64.AppImage'
]);
function fixtureDownload(name) {
	assert.ok(FIXTURE_ASSETS.includes(name), 'Unknown fixture download');
	return 'https://github.com/adrienm7/ergopti/releases/download/' + FIXTURE_TAG + '/' + name;
}

const MIME = Object.freeze({
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.json': 'application/json; charset=utf-8',
	'.toml': 'text/plain; charset=utf-8',
	'.txt': 'text/plain; charset=utf-8',
	'.svg': 'image/svg+xml',
	'.png': 'image/png',
	'.jpg': 'image/jpeg',
	'.jpeg': 'image/jpeg',
	'.gif': 'image/gif',
	'.webp': 'image/webp',
	'.avif': 'image/avif',
	'.ico': 'image/x-icon',
	'.woff': 'font/woff',
	'.woff2': 'font/woff2',
	'.ttf': 'font/ttf',
	'.otf': 'font/otf',
	'.wasm': 'application/wasm',
	'.pdf': 'application/pdf',
	'.mp4': 'video/mp4'
});

/** Decode the raw request path before URL normalization can hide traversal. */
function requestPath(raw, basePath) {
	assert.ok(basePath === '' || basePath === '/dev', 'Unknown artifact mount');
	assert.equal(typeof raw, 'string');
	const encoded = raw.split('?')[0];
	assert.ok(encoded.startsWith('/') && !encoded.startsWith('//'), 'Invalid local request');
	assert.ok(!/[\\#\x00-\x20\x7f]/.test(encoded), 'Invalid request characters');
	assert.ok(!/%(?:2f|5c)/i.test(encoded), 'Encoded path separator refused');
	const decoded = decodeURIComponent(encoded);
	assert.ok(!/[\\\x00-\x1f\x7f]/.test(decoded), 'Invalid decoded path');
	assert.ok(!decoded.split('/').some((part) => part === '.' || part === '..'), 'Traversal refused');
	assert.ok(!decoded.includes('//'), 'Ambiguous path refused');
	assert.ok(
		basePath === '' || decoded === basePath || decoded.startsWith(basePath + '/'),
		'Request outside artifact mount'
	);
	return decoded.slice(basePath.length) || '/';
}

/** Select one real regular file; directory/file aliases and symlinks cannot supply a fallback. */
function resolveRequest(site, basePath, raw, files = fs) {
	const root = path.resolve(site);
	const rootStat = files.lstatSync(root);
	assert.ok(rootStat.isDirectory() && !rootStat.isSymbolicLink(), 'Artifact root must be ordinary');
	const relative = requestPath(raw, basePath).slice(1);
	const candidates =
		relative === ''
			? ['index.html']
			: relative.endsWith('/')
				? [relative + 'index.html']
				: path.posix.extname(relative)
					? [relative]
					: [relative + '.html', relative + '/index.html', relative];
	const found = [];
	for (const candidate of candidates) {
		let current = root;
		const segments = candidate.split('/');
		let stat;
		for (let index = 0; index < segments.length; index += 1) {
			current = path.join(current, segments[index]);
			try {
				stat = files.lstatSync(current);
			} catch (error) {
				if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
				stat = null;
				break;
			}
			assert.ok(!stat.isSymbolicLink(), 'Artifact symlink refused');
			if (index < segments.length - 1)
				assert.ok(stat.isDirectory(), 'Artifact path parent must be a directory');
		}
		if (stat?.isFile()) found.push(current);
	}
	assert.equal(found.length, 1, 'Missing or ambiguous artifact resource');
	const mime = MIME[path.extname(found[0]).toLowerCase()];
	assert.ok(mime, 'Undeclared static MIME type');
	return { file: found[0], mime };
}

/** These exact external API responses are inert smoke fixtures, never live release qualification. */
function githubFixture(url) {
	const repo = 'https://api.github.com/repos/adrienm7/ergopti';
	const release = {
		tag_name: FIXTURE_TAG,
		prerelease: true,
		draft: false,
		published_at: '2026-10-01T00:00:00Z',
		assets: FIXTURE_ASSETS.map((name) => ({ name, browser_download_url: fixtureDownload(name) }))
	};
	if (url === repo) return { stargazers_count: 123 };
	if (url === repo + '/releases/latest') return { ...release, prerelease: false };
	if (url === repo + '/releases?per_page=100&page=1') return [release];
	if (url === repo + '/releases?per_page=20')
		return [{ ...release, tag_name: 'v0.0.0-smoke-stable', prerelease: false }, release];
	return null;
}

/** Exact app.html resources are inert fixtures; fonts and analytics remain unqualified. */
function authoredExternalFixture(url) {
	if (
		url === 'https://fonts.googleapis.com/css2?family=Noto+Sans:wght@100..900&display=swap' ||
		url === 'https://fonts.googleapis.com/css2?family=Noto+Sans+Symbols:wght@100..900&display=swap'
	)
		return {
			contentType: 'text/css',
			body: '/* Inert smoke fixture; live fonts are unqualified. */'
		};
	if (url === 'https://www.googletagmanager.com/gtag/js?id=G-KG5MR2RZSH')
		return {
			contentType: 'text/javascript',
			body: '/* Inert smoke fixture; live analytics are unqualified. */'
		};
	return null;
}

/** Genuine client navigation must preserve the document and use this artifact's target prefix. */
async function exerciseNavigation(page, origin, basePath) {
	const target = origin + basePath + '/utilisation';
	const link = page.locator('header a[href="utilisation"]').first();
	await link.waitFor({ state: 'visible' });
	assert.equal(new URL(await link.getAttribute('href'), page.url()).href, target);
	const timeOrigin = await page.evaluate(() => performance.timeOrigin);
	await Promise.all([page.waitForURL(target), link.click()]);
	assert.equal(page.url(), target, 'Client navigation stays in its declared target');
	assert.equal(
		await page.evaluate(() => performance.timeOrigin),
		timeOrigin,
		'Navigation must retain the hydrated document'
	);
}

/** Inspect live rendered release URLs; only local authored downloads receive real HTTP HEAD. */
async function exerciseDownloads(page, origin, basePath, route) {
	const names =
		route === '/utilisation'
			? FIXTURE_ASSETS.slice(0, 2)
			: route === '/ergopti-plus'
				? FIXTURE_ASSETS.slice(2)
				: [];
	for (const name of names) {
		const expected = fixtureDownload(name);
		const link = page.locator('a[download][href="' + expected + '"]').first();
		await link.waitFor({ state: 'attached' });
		assert.equal(await link.getAttribute('href'), expected, 'Rendered fixture asset URL');
	}
	if (route === '/utilisation') {
		for (const name of ['printable_layout_v2.2.pdf', 'printable_layout_v2.2_full.pdf']) {
			const href = 'documents/' + name;
			const link = page.locator('a[download][href="' + href + '"]').first();
			await link.waitFor({ state: 'attached' });
			const url = new URL(await link.getAttribute('href'), page.url()).href;
			assert.equal(url, origin + basePath + '/documents/' + name, 'Local download target prefix');
			const response = await page.request.head(url);
			try {
				assert.ok(response.ok(), 'Authored local download is absent: ' + name);
			} finally {
				await response.dispose();
			}
		}
	}
}

/** Assert actual hydrated event handling through the shared layout on the declared smoke routes. */
async function exercisePage(page, origin, basePath, errors) {
	for (const route of SITE_ROUTES) {
		const response = await page.goto(origin + basePath + route, { waitUntil: 'networkidle' });
		assert.ok(response?.ok(), 'Authored artifact route refused: ' + route);
		await page.locator('main').first().waitFor({ state: 'visible' });
		const toggle = page.locator('#afficher-clavier-reference');
		const keyboard = page.locator('#clavier-ref');
		await toggle.waitFor({ state: 'visible' });
		assert.equal(await keyboard.isVisible(), false, 'Reference starts hidden');
		await toggle.click();
		await keyboard.waitFor({ state: 'visible' });
		await toggle.click();
		await keyboard.waitFor({ state: 'hidden' });
		await exerciseDownloads(page, origin, basePath, route);
		if (route === '/') await exerciseNavigation(page, origin, basePath);
		assert.equal(errors.local.length, 0, 'Local resource failures: ' + errors.local.join('; '));
		assert.equal(errors.page.length, 0, 'Browser failures: ' + errors.page.join('; '));
	}
}

/** Launch ownership is retired even when an assertion fails. */
async function withBrowser(engine, visit) {
	const browser = await engine.launch({ headless: true });
	try {
		return await visit(browser);
	} finally {
		await browser.close();
	}
}

/** Serve the selected artifact bytes; the portable owner records this exact HTTP handler. */
function serveRequest(site, basePath, request, response, errors) {
	try {
		assert.ok(request.method === 'GET' || request.method === 'HEAD', 'Unexpected method');
		const selected = resolveRequest(site, basePath, request.url);
		const bytes = artifact.fileHash(selected.file, { capture: true }).content;
		response.writeHead(200, { 'Content-Type': selected.mime, 'Cache-Control': 'no-store' });
		response.end(request.method === 'HEAD' ? undefined : bytes);
	} catch (error) {
		errors.push(error.message);
		response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
		response.end('Artifact resource refused');
	}
}

/**
 * Exercise existing static output with real caller-supplied Playwright engines.
 * This domain function returns observations only; main owns CI context, exact
 * artifact verification before/after and exclusive publication of the proof.
 * @param {string} site Received static output directory.
 * @param {''|'/dev'} basePath Declared target prefix.
 * @param {Object} engines Real Chromium and WebKit browser types.
 * @returns {Promise<Array<Object>>} Completed browser observations after retirement.
 */
async function runBrowsers(site, basePath, engines) {
	const serverErrors = [];
	const server = http.createServer((request, response) =>
		serveRequest(site, basePath, request, response, serverErrors)
	);
	const results = [];
	try {
		await new Promise((resolve, reject) => {
			server.once('error', reject);
			server.listen(0, '127.0.0.1', resolve);
		});
		const origin = 'http://127.0.0.1:' + server.address().port;
		for (const name of ['chromium', 'webkit']) {
			const errors = { local: [], page: [] };
			await withBrowser(engines[name], async (browser) => {
				const context = await browser.newContext({
					serviceWorkers: 'block',
					viewport: { width: 1440, height: 900 }
				});
				try {
					const page = await context.newPage();
					page.setDefaultTimeout(15000);
					page.on('pageerror', (error) => errors.page.push(error.message));
					page.on('console', (message) => {
						if (message.type() === 'error') errors.page.push(message.text());
					});
					page.on('response', (response) => {
						if (new URL(response.url()).origin === origin && response.status() >= 400)
							errors.local.push(response.url() + ' HTTP ' + response.status());
					});
					page.on('requestfailed', (request) => {
						if (new URL(request.url()).origin === origin)
							errors.local.push(
								request.url() + ' transport: ' + (request.failure()?.errorText || 'unknown failure')
							);
					});
					await page.route('**/*', async (route) => {
						const url = route.request().url();
						if (new URL(url).origin === origin) return route.continue();
						const fixture = githubFixture(url);
						if (fixture !== null)
							return route.fulfill({
								status: 200,
								contentType: 'application/json',
								headers: { 'Access-Control-Allow-Origin': '*' },
								body: JSON.stringify(fixture)
							});
						const external = authoredExternalFixture(url);
						if (external !== null) return route.fulfill({ status: 200, ...external });
						errors.page.push('Unexpected remote request: ' + url);
						return route.abort();
					});
					await exercisePage(page, origin, basePath, errors);
				} finally {
					await context.close();
				}
			});
			assert.equal(errors.local.length, 0, 'Local resource failures before browser retirement');
			assert.equal(errors.page.length, 0, 'Browser failures before retirement');
			assert.equal(serverErrors.length, 0, 'Static artifact server refused a resource');
			results.push({
				name,
				routes: SITE_ROUTES.slice(),
				local_http_errors: 0,
				page_errors: 0,
				hydration: true,
				interaction: true
			});
		}
	} finally {
		if (server.listening)
			await new Promise((resolve, reject) =>
				server.close((error) => (error ? reject(error) : resolve()))
			);
	}
	return results;
}

/** Receive one sealed build, test its exact files and publish exclusively after owned browsers close. */
async function main(args = process.argv.slice(2)) {
	assert.equal(args.length, 3, 'Expected site-directory build-receipt output-testbuild-receipt');
	const [site, buildFile, output] = args.map((value) => path.resolve(value));
	const relativeOutput = path.relative(site, output);
	assert.ok(
		relativeOutput === '..' ||
			relativeOutput.startsWith('..' + path.sep) ||
			path.isAbsolute(relativeOutput),
		'Receipt must be outside site'
	);
	const physicalOutput = path.join(fs.realpathSync(path.dirname(output)), path.basename(output));
	const physicalRelative = path.relative(fs.realpathSync(site), physicalOutput);
	assert.ok(
		physicalRelative.startsWith('..' + path.sep) || path.isAbsolute(physicalRelative),
		'Receipt parent resolves inside site'
	);
	const context = artifact.ciContext(process.env, process.cwd());
	const build = artifact.readReceipt(buildFile);
	const cname = artifact.fileHash(path.resolve('static/CNAME'), {
		maximumBytes: 4096,
		capture: true
	}).content;
	artifact.verify(site, build, context, cname);
	const browsers = await runBrowsers(site, context.base_path, require('playwright'));
	artifact.verify(site, build, context, cname);
	fs.writeFileSync(output, artifact.canonical(artifact.recordTestbuild(build, context, browsers)), {
		flag: 'wx'
	});
	console.log(
		'Received site artifact: Chromium and WebKit routes/hydration/interaction PASS; GitHub API, authored fonts and analytics use inert fixtures; live external services remain unqualified.'
	);
}

module.exports = {
	SITE_ROUTES,
	requestPath,
	resolveRequest,
	serveRequest,
	githubFixture,
	authoredExternalFixture,
	fixtureDownload,
	exerciseNavigation,
	exerciseDownloads,
	exercisePage,
	withBrowser,
	runBrowsers,
	main
};
if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
