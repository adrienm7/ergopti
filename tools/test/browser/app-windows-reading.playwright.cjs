// tools/test/browser/app-windows-reading.playwright.cjs

/**
 * ==============================================================================
 * MODULE: App Windows Reading Preferences
 * DESCRIPTION:
 * Renders the app's own windows in headless Chromium with each reading font
 * and text spacing (`script.reading_font`, `script.reading_spacing`, set in
 * the Configuration menu and the setup wizard), the way each host delivers
 * them:
 *   linked — Windows: the seed window.__ergopti_reading before the page's
 *            scripts, a11y_prefs.js linking the font beside it;
 *   inline — macOS and Linux: the page inline with a11y_prefs.js inside it,
 *            the seed and the font's faces as data: URLs right after <head>
 *            (core/ui/engine/webview/reading_preferences.lua).
 * Each rendering must:
 * 1. draw every text in the chosen font, its faces loaded;
 * 2. keep the page's own spacing with « Par défaut », whatever the font: the
 *    OpenDyslexic faces are so wide that, set as is, a title read
 *    « M é t r i q u e s » and the metrics toolbar wrapped (field report,
 *    macOS, 2026-11-24), so a line of text stays within a ratio of the
 *    default font's width and the toolbar on one row at the window's size;
 * 3. add the WCAG 1.4.12 spacing with « Aéré »: letter spacing 0.12 em and
 *    word spacing 0.16 em more than « Par défaut », line height 1.5 and
 *    paragraph spacing 2 em;
 * 4. follow a choice pushed into the open window (receiveHost), the way the
 *    hosts apply a menu change at once, the inline font included;
 * 5. in the setup wizard, restyle the page as soon as the reader picks a font
 *    or a spacing beside the languages, and ask the host to save it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { serveStatic, installFakeHost } = require('../lib/app-window-host.cjs');
const { WINDOWS } = require('./app-windows-fixtures.cjs');

const STATIC_ROOT = path.resolve(__dirname, '..', '..', '..', 'static');
const SHARED_UI = path.join(STATIC_ROOT, 'ergopti_plus', '_shared', 'ui');
const UI = '/ergopti_plus/_shared/ui/';
const MANIFEST = JSON.parse(fs.readFileSync(path.join(SHARED_UI, 'apps.manifest.json'), 'utf8'));
// The wizard runs in French here; its labels are read from the catalogue so a
// reworded label does not break the check that the wizard's language is used.
const FRENCH = JSON.parse(
	fs.readFileSync(
		path.join(STATIC_ROOT, 'ergopti_plus', '_shared', 'core', 'i18n', 'data', 'locales', 'fr.json'),
		'utf8'
	)
);
const FONT_FOLDERS = { hyperlegible: 'atkinson-hyperlegible', dyslexic: 'opendyslexic' };
const FAMILIES = { default: null, hyperlegible: 'Atkinson Hyperlegible', dyslexic: 'OpenDyslexic' };
const DELIVERIES = Object.freeze(['linked', 'inline']);
// A line set in a reading font with the default spacing stays within this
// ratio of the default font's width: OpenDyslexic set as is measured 1.6.
const MAX_WIDTH_RATIO = 1.35;
// The text whose width is compared, set in the window's title style.
const PROBE_TEXT = 'Métriques de frappe — Purger les données';
let checks = 0;

/** Counts and runs one assertion. */
function check(condition, label) {
	checks++;
	assert.ok(condition, label);
}

/**
 * The chosen font's stylesheet with each face inlined, as font_style() in
 * reading_preferences.lua writes it for an inline page.
 */
function inlineFontCss(font) {
	if (font === 'default') return '';
	const folder = path.join(SHARED_UI, 'fonts', FONT_FOLDERS[font]);
	return fs
		.readFileSync(path.join(folder, 'font.css'), 'utf8')
		.replace(
			/url\('([^']+)'\)/g,
			(_, file) =>
				"url('data:font/woff2;base64," +
				fs.readFileSync(path.join(folder, file)).toString('base64') +
				"')"
		);
}

/** The seed a host writes: only the non-default choices. */
function seedOf(preferences) {
	const seed = {};
	for (const [name, value] of Object.entries(preferences))
		if (value !== 'default') seed[name] = value;
	return seed;
}

/**
 * Opens one window with its fake host and the given choices delivered as one
 * host family delivers them, and fills it.
 */
async function openWindow(browser, origin, target, preferences, delivery) {
	const app = MANIFEST.apps[target.id];
	const context = await browser.newContext({
		viewport: { width: app.width, height: app.height },
		reducedMotion: 'reduce'
	});
	context.setDefaultTimeout(30000);
	await context.route(
		(url) => !url.href.startsWith(origin + '/'),
		(route) => route.abort()
	);
	if (delivery === 'inline') {
		// The page as the macOS and Linux builders hand it over: a11y_prefs.js
		// inline (so it has no address to link a font from), the seed and the
		// inlined faces right after <head>.
		await context.route(origin + UI + target.id + '/index.html', async (route) => {
			const response = await route.fetch();
			const prefs = fs.readFileSync(path.join(SHARED_UI, 'a11y_prefs.js'), 'utf8');
			const head =
				'<script>window.__ergopti_reading=' +
				JSON.stringify(seedOf(preferences)) +
				';</script>' +
				(preferences.font === 'default'
					? ''
					: '<style>' + inlineFontCss(preferences.font) + '</style>');
			const html = (await response.text())
				.replace('<script src="../a11y_prefs.js"></script>', () => '<script>' + prefs + '</script>')
				.replace(/(<head[^>]*>)/, (tag) => tag + head);
			await route.fulfill({ response, body: html });
		});
	}
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.addInitScript(installFakeHost, {
		bridge: target.bridge,
		family: delivery === 'linked' ? 'windows' : 'webkit',
		locale: 'fr',
		host: target.host ? target.host.toString() : null
	});
	if (delivery === 'linked')
		await page.addInitScript((seed) => {
			window.__ergopti_reading = seed;
		}, seedOf(preferences));
	if (target.seed) await page.addInitScript(target.seed.script, target.seed.arg);
	await page.goto(origin + UI + target.id + '/index.html');
	if (target.fill) await target.fill(page);
	await page.locator(target.ready).first().waitFor({ state: 'visible' });
	await page.evaluate(() => document.fonts.ready);
	return { context, page, errors };
}

/**
 * Reads the look of one element and of a probe line in its style: font
 * family, spacing, the probe's width and whether the font's faces loaded.
 */
function readLook({ selector, probeText }) {
	const element = document.querySelector(selector);
	const style = getComputedStyle(element);
	const probe = document.createElement('span');
	probe.textContent = probeText;
	probe.style.whiteSpace = 'nowrap';
	element.appendChild(probe);
	const width = probe.getBoundingClientRect().width;
	probe.remove();
	const paragraph = document.querySelector('p');
	const family = style.fontFamily.split(',')[0].trim().replace(/['"]/g, '');
	return {
		family,
		loaded: [...document.fonts].some(
			(face) => face.family.replace(/['"]/g, '') === family && face.status === 'loaded'
		),
		fontSize: parseFloat(style.fontSize),
		letterSpacing: style.letterSpacing === 'normal' ? 0 : parseFloat(style.letterSpacing),
		wordSpacing: parseFloat(style.wordSpacing) || 0,
		lineHeight: style.lineHeight,
		paragraphFontSize: paragraph ? parseFloat(getComputedStyle(paragraph).fontSize) : 0,
		paragraphMargin: paragraph ? parseFloat(getComputedStyle(paragraph).marginBottom) : 0,
		width
	};
}

/**
 * The rows of the metrics toolbar: its controls grouped by where their row
 * starts. The page lays it out on two rows; a wider font must not add one.
 */
function toolbarRows() {
	const controls = [...document.querySelectorAll('.filters-bar :is(button, select, input)')].filter(
		(control) => control.checkVisibility()
	);
	const tops = [];
	for (const control of controls) {
		const box = control.getBoundingClientRect();
		if (!tops.some((top) => Math.abs(top - box.top) < box.height / 2)) tops.push(box.top);
	}
	return tops.length;
}

/** Checks one window in every font and spacing, delivered both ways. */
async function checkWindow(browser, origin, target, selector) {
	for (const delivery of DELIVERIES) {
		const looks = {};
		for (const font of Object.keys(FAMILIES))
			for (const spacing of ['default', 'wide']) {
				const { context, page, errors } = await openWindow(
					browser,
					origin,
					target,
					{ font, spacing },
					delivery
				);
				try {
					const look = await page.evaluate(readLook, { selector, probeText: PROBE_TEXT });
					const where = `${target.id} (${delivery}, font ${font}, spacing ${spacing})`;
					looks[font + '/' + spacing] = look;
					if (FAMILIES[font]) {
						check(
							look.family === FAMILIES[font],
							`${where}: drawn in ${FAMILIES[font]}, not ${look.family}`
						);
						check(look.loaded, `${where}: the ${FAMILIES[font]} faces are loaded`);
					} else
						check(
							!Object.values(FAMILIES).includes(look.family),
							`${where}: drawn in the page's font`
						);
					if (target.id === 'metrics_typing' && spacing === 'default')
						look.rows = await page.evaluate(toolbarRows);
					if (spacing === 'wide') {
						check(
							Math.abs(parseFloat(look.lineHeight) - 1.5 * look.fontSize) < 0.5,
							`${where}: line height 1.5, not ${look.lineHeight}`
						);
						if (look.paragraphFontSize)
							check(
								Math.abs(look.paragraphMargin - 2 * look.paragraphFontSize) < 0.5,
								`${where}: paragraph spacing 2 em, not ${look.paragraphMargin}px`
							);
					}
					check(errors.length === 0, `${where}: no page error (${errors.join('; ')})`);
				} finally {
					await context.close();
				}
			}
		const base = looks['default/default'];
		for (const font of Object.keys(FAMILIES)) {
			const plain = looks[font + '/default'];
			const wide = looks[font + '/wide'];
			const where = `${target.id} (${delivery}, font ${font})`;
			if (base.rows !== undefined)
				check(
					plain.rows === base.rows,
					`${where}: the toolbar keeps its ${base.rows} rows, not ${plain.rows}`
				);
			check(
				plain.width / base.width <= MAX_WIDTH_RATIO,
				`${where}: « Par défaut » keeps the page's spacing (width ratio ${(plain.width / base.width).toFixed(2)})`
			);
			check(
				Math.abs(wide.letterSpacing - plain.letterSpacing - 0.12 * wide.fontSize) < 0.1,
				`${where}: « Aéré » adds 0.12 em of letter spacing (${plain.letterSpacing} → ${wide.letterSpacing})`
			);
			check(
				Math.abs(wide.wordSpacing - plain.wordSpacing - 0.16 * wide.fontSize) < 0.1,
				`${where}: « Aéré » adds 0.16 em of word spacing (${plain.wordSpacing} → ${wide.wordSpacing})`
			);
		}
		check(
			base.letterSpacing === 0,
			`${target.id} (${delivery}): the default look adds no letter spacing`
		);
	}
}

/** Resolves after two frames, once the transitions a change starts have ended. */
function settle() {
	return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
}

/** A choice pushed into an open window applies at once, the inline font included. */
async function checkLivePush(browser, origin, target, selector) {
	for (const delivery of DELIVERIES) {
		const { context, page, errors } = await openWindow(
			browser,
			origin,
			target,
			{ font: 'default', spacing: 'default' },
			delivery
		);
		try {
			const where = `${target.id} (${delivery}, pushed)`;
			await page.evaluate(
				([seed, css]) => window.ErgoptiA11yPrefs.receiveHost(seed, css),
				[
					{ font: 'dyslexic', spacing: 'wide' },
					delivery === 'inline' ? inlineFontCss('dyslexic') : null
				]
			);
			await page.evaluate(() => document.fonts.ready);
			await page.evaluate(settle);
			await page.waitForFunction(() =>
				[...document.fonts].some(
					(face) => face.family.replace(/['"]/g, '') === 'OpenDyslexic' && face.status === 'loaded'
				)
			);
			let look = await page.evaluate(readLook, { selector, probeText: PROBE_TEXT });
			check(
				look.family === 'OpenDyslexic' && look.loaded,
				`${where}: the open window takes OpenDyslexic`
			);
			check(look.letterSpacing > 0, `${where}: the open window takes the wide spacing`);
			await page.evaluate(() => window.ErgoptiA11yPrefs.receiveHost({}, ''));
			// theme.css still runs each transition for 0.01 ms under reduced
			// motion: a read in the same frame sees the start value.
			await page.evaluate(settle);
			look = await page.evaluate(readLook, { selector, probeText: PROBE_TEXT });
			check(
				look.family !== 'OpenDyslexic' && look.letterSpacing === 0,
				`${where}: back to the default look (${JSON.stringify(look)})`
			);
			check(errors.length === 0, `${where}: no page error (${errors.join('; ')})`);
		} finally {
			await context.close();
		}
	}
}

/**
 * The setup wizard offers the font and the spacing beside the languages: a
 * choice restyles the page at once and is posted to the host to be saved.
 */
async function checkWizard(browser, origin) {
	const wizard = WINDOWS.find((target) => target.id === 'onboarding');
	for (const delivery of DELIVERIES) {
		const { context, page, errors } = await openWindow(
			browser,
			origin,
			wizard,
			{ font: 'default', spacing: 'default' },
			delivery
		);
		try {
			const where = `onboarding (${delivery})`;
			const font = page.locator('#reading-font');
			check(
				(await page.locator('#reading-font option').count()) === 3,
				`${where}: the three fonts are offered`
			);
			check((await font.inputValue()) === 'default', `${where}: the current font is selected`);
			check(
				(await page.locator('#reading-font-label').textContent()) ===
					FRENCH['menu.configuration.reading_font'],
				`${where}: the font list is named in the wizard's language`
			);
			// Chosen with the keyboard, as a reader who cannot use a pointer does.
			await font.focus();
			await page.keyboard.press('End');
			await page.evaluate(settle);
			check(
				(await page.evaluate(() => document.documentElement.getAttribute('data-a11y-font'))) ===
					'dyslexic',
				`${where}: the page takes the dyslexia font at once`
			);
			const posted = await page.evaluate(() =>
				window.__hostMessages.filter((message) => message.action === 'setReadingPreference')
			);
			check(
				posted.length === 1 && posted[0].name === 'font' && posted[0].value === 'dyslexic',
				`${where}: the host is asked to save the font (${JSON.stringify(posted)})`
			);
			// The host's answer: the macOS and Linux hosts push the faces inline.
			if (delivery === 'inline')
				await page.evaluate(
					([seed, css]) => window.ErgoptiA11yPrefs.receiveHost(seed, css),
					[{ font: 'dyslexic' }, inlineFontCss('dyslexic')]
				);
			await page.waitForFunction(() =>
				[...document.fonts].some(
					(face) => face.family.replace(/['"]/g, '') === 'OpenDyslexic' && face.status === 'loaded'
				)
			);
			let look = await page.evaluate(readLook, { selector: 'h1', probeText: PROBE_TEXT });
			check(
				look.family === 'OpenDyslexic' && look.loaded,
				`${where}: the heading is drawn in OpenDyslexic`
			);
			await page.selectOption('#reading-spacing', 'wide');
			await page.evaluate(settle);
			look = await page.evaluate(readLook, { selector: 'h1', probeText: PROBE_TEXT });
			check(
				look.family === 'OpenDyslexic' && look.letterSpacing > 0,
				`${where}: the wide spacing adds to the chosen font`
			);
			check(
				(await page.evaluate(
					() =>
						window.__hostMessages.filter((message) => message.action === 'setReadingPreference')
							.length
				)) === 2,
				`${where}: the host is asked to save the spacing`
			);
			check(errors.length === 0, `${where}: no page error (${errors.join('; ')})`);
		} finally {
			await context.close();
		}
	}
}

(async () => {
	const server = await serveStatic(STATIC_ROOT, 0);
	const origin = `http://127.0.0.1:${server.address().port}`;
	const browser = await chromium.launch({
		...(process.env.CHROMIUM_EXECUTABLE ? { executablePath: process.env.CHROMIUM_EXECUTABLE } : {})
	});
	try {
		const metrics = WINDOWS.find((target) => target.id === 'metrics_typing');
		await checkWindow(browser, origin, metrics, 'h1');
		await checkLivePush(browser, origin, metrics, 'h1');
		await checkWizard(browser, origin);
	} finally {
		await browser.close();
		server.close();
	}
	console.log(`app-windows-reading: ${checks} checks passed.`);
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
