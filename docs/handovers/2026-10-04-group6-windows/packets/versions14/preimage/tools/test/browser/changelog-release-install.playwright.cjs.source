// tools/test/browser/changelog-release-install.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Versions Page One-Click Install (real Chromium render)
 * DESCRIPTION:
 * Loads the shared Versions page (_shared/ui/changelog/index.html) in headless
 * Chromium through Playwright, as a Linux-hosted window with a recording bridge,
 * lists a fixture release list and checks the install buttons and the message
 * a click posts. It complements tools/test/test-changelog-release-install.cjs,
 * which runs the same scripts against a recording DOM in the JS suite: this one
 * proves the real document, stylesheet and layout (a button that is present
 * but invisible, or a script the document does not load, fails here).
 *
 * FEATURES & RATIONALE:
 * 1. Network-independent: the bridge is a stub, the locale strings are seeded,
 *    and the fixture list is injected; the page never reaches GitHub.
 * 2. Not in the CI JS suite: the CI image installs no browser. Run it where
 *    Playwright and its Chromium are installed (npm run test:browser:changelog-install).
 *    A missing Playwright fails the run; it is never reported as a pass.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { pathToFileURL } = require('url');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const PAGE = path.join(SHARED, 'ui', 'changelog', 'index.html');
const EN = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));
const INSTALLED = '0.0.0-dev.140';
const RELEASES = ['v0.0.0-dev.142', 'v0.0.0-dev.141', 'v0.0.0-dev.140', 'v0.0.0-dev.139'].map(
	(tag, index) => ({
		tag_name: tag,
		published_at: `2026-09-${30 - index}T10:00:00Z`,
		prerelease: true,
		body: '## Changes\n\n- Fixture',
		html_url: `https://github.com/adrienm7/ergopti/releases/tag/${tag}`
	})
);

/**
 * Loads Playwright from the project or from the global npm root.
 * @returns {Object} The playwright module.
 */
function loadPlaywright() {
	try {
		return require('playwright');
	} catch (_localMissing) {
		const globalRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
		return require(path.join(globalRoot, 'playwright'));
	}
}

const failures = [];
let checks = 0;

function expect(condition, message) {
	checks += 1;
	if (!condition) failures.push(message);
}

(async () => {
	const { chromium } = loadPlaywright();
	const browser = await chromium.launch();
	try {
		const page = await browser.newPage({ viewport: { width: 860, height: 580 } });
		const pageErrors = [];
		page.on('pageerror', (error) => pageErrors.push(error.message));
		page.on('request', (request) => {
			if (!request.url().startsWith('file:')) pageErrors.push(`network request: ${request.url()}`);
		});
		await page.addInitScript(
			({ strings, installed }) => {
				window._i18n_strings = strings;
				window.__ergopti_host = 'linux';
				window.__installed_version = installed;
				window.__subscribed_channel = 'dev';
				window.__posted = [];
				window.webkit = {
					messageHandlers: {
						changelog_bridge: { postMessage: (payload) => window.__posted.push(payload) }
					}
				};
			},
			{ strings: EN, installed: INSTALLED }
		);
		await page.goto(pathToFileURL(PAGE).href);
		await page.evaluate((releases) => window.injectReleases(releases, 'dev'), RELEASES);

		for (let index = 0; index < RELEASES.length; index += 1) {
			await page.click(`.release-item[data-idx="${index}"]`);
			const tag = RELEASES[index].tag_name;
			const installed = tag === `v${INSTALLED}`;
			const button = page.locator('#btn-install');
			expect(
				(await button.isVisible()) === !installed,
				`${tag}: the install button must be ${installed ? 'hidden' : 'visible'}`
			);
			expect(
				await page.locator('#btn-github').isVisible(),
				`${tag}: « View on GitHub » stays visible`
			);
			if (installed) {
				expect(
					(await page.locator('.release-item.installed .badge-installed').count()) === 1,
					'exactly the installed row carries the installed badge'
				);
				continue;
			}
			const label = await button.textContent();
			const older = tag === 'v0.0.0-dev.139';
			expect(
				label ===
					EN[older ? 'changelog_window.rollback_release' : 'changelog_window.install_release'],
				`${tag}: label « ${label} »`
			);
		}

		await page.click('.release-item[data-idx="3"]');
		await page.click('#btn-install');
		const posted = await page.evaluate(() => window.__posted);
		const installs = posted.filter((payload) => payload && payload.action === 'install_release');
		expect(
			installs.length === 1 &&
				installs[0].tag === 'v0.0.0-dev.139' &&
				installs[0].channel === 'dev',
			`one click must post install_release for the selected tag (got ${JSON.stringify(installs)})`
		);
		expect(await page.locator('#install-panel').isVisible(), 'the progress panel appears at once');
		expect(await page.locator('#btn-install').isDisabled(), 'the button waits for the host');

		await page.evaluate(() =>
			window.setInstallProgress({
				tag: 'v0.0.0-dev.139',
				phase: 'failed',
				reason_key: 'changelog_window.install_error_verify',
				backup_path: '/tmp/backups/pre-install'
			})
		);
		expect(await page.locator('#btn-install-retry').isVisible(), 'a failure shows Retry');
		await page.click('#btn-install-retry');
		const retried = (await page.evaluate(() => window.__posted)).filter(
			(payload) => payload && payload.action === 'install_release'
		);
		expect(retried.length === 2, 'Retry posts the request again');
		expect(
			pageErrors.length === 0,
			`the page raised or reached the network: ${pageErrors.join('; ')}`
		);

		const shot = process.env.CHANGELOG_SCREENSHOT;
		if (shot) await page.screenshot({ path: shot });
	} finally {
		await browser.close();
	}

	if (failures.length > 0) {
		console.error(
			`[FAIL] Versions page install buttons in Chromium (${failures.length}/${checks}):`
		);
		for (const failure of failures) console.error('  - ' + failure);
		process.exit(1);
	}
	console.log(`[OK] Versions page install buttons render and post in Chromium (${checks} checks).`);
})().catch((error) => {
	console.error(`[FAIL] Versions page Chromium run: ${error.stack || error.message}`);
	process.exit(1);
});
