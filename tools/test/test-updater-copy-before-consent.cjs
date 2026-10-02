// tools/test/test-updater-copy-before-consent.cjs

/**
 * ==============================================================================
 * MODULE: Updater Copy Before Consent
 * DESCRIPTION:
 * No driver downloads an update before the user chose to install it: Windows
 * and Linux download from the install prompt or tray row, macOS's Sparkle
 * never downloads on its own (SUAllowsAutomaticUpdates false). The copy shown
 * while an update is only found must say so, in every locale.
 *
 * ROOT CAUSE ENCODED:
 * updater.tray_new_version_body, the Windows and Linux "new version" toast,
 * said "Version {1} is ready to install" in all 21 locales, which now reads
 * as a completed download, and sent users to an "Install update" tray entry
 * that neither tray shows (Windows names it "Update to {tag}", Linux
 * "Download and install {tag}"). Each locale's own word for "ready" is taken
 * from updater.ready_to_install_body, the copy shown once a consented download
 * is staged, and must not appear in any copy shown before consent. The toast
 * then named the tray menu as the place to install from, while clicking it on
 * Windows installs too: it now ends with the consent sentence of the prompt it
 * opens, updater.update_found_body.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..');
const localesDir = path.join(root, 'static', 'ergopti_plus', '_shared', 'data', 'locales');
const errors = [];

// Everything the drivers show between finding an update and the user's choice
// to install it: notifications, the offer prompt and its install button, and
// the tray rows that name the release.
const PRE_CONSENT_KEYS = [
	'updater.tray_new_version_title',
	'updater.tray_new_version_body',
	'updater.available_window_title',
	'updater.window_title',
	'updater.update_found_body',
	'updater.update_window_title',
	'updater.update_dialog_header',
	'updater.update_dialog_install',
	'menu.about.update_now'
];

// Copy shown only once a consented download is staged; it defines each
// locale's word for "ready".
const POST_DOWNLOAD_KEY = 'updater.ready_to_install_body';

// Notification copy is shared by drivers whose tray rows carry different
// labels, so it must not quote one.
const NOTIFICATION_KEYS = ['updater.tray_new_version_title', 'updater.tray_new_version_body'];

// The toast is one of several ways to one install choice: clicking it on
// Windows opens the prompt that says updater.update_found_body, and Linux
// installs from its tray row. So it states the consent in that prompt's own
// words, which name no single place to install from.
const TOAST_KEY = 'updater.tray_new_version_body';
const PROMPT_KEY = 'updater.update_found_body';
const FIRST_SENTENCE = /^.*?[.。।]\s*/su;

const WORD = (stem) => new RegExp(`(?<!\\p{L})${stem}(?!\\p{L})`, 'iu');
const READY_BY_LOCALE = {
	ar: /جاهز/u,
	cs: /připraven/iu,
	da: WORD('klar'),
	de: WORD('bereit'),
	en: WORD('ready'),
	es: WORD('list[ao]s?'),
	fr: /prêt/iu,
	he: /מוכ[נן]/u,
	hi: /तैयार/u,
	it: WORD('pront[oa]'),
	ja: /準備/u,
	ko: /준비/u,
	nl: WORD('klaar'),
	no: WORD('klar'),
	pl: /gotow/iu,
	pt: WORD('pront[oa]'),
	ru: /готов/iu,
	sv: WORD('(?:klar|redo)'),
	tr: /hazır/iu,
	uk: /готов/iu,
	zh: /就绪|准备好/u
};

// English also states the download itself; anything but "downloaded only"
// claims it already happened.
const EN_DOWNLOADED = /\b(?:has been|was|already|is) downloaded\b(?!\s+only)/i;
const QUOTES = /["«»„“”「」『』]/u;
const PLACEHOLDER = /\{[A-Za-z0-9_]+\}/g;

const locales = fs
	.readdirSync(localesDir)
	.filter((name) => name.endsWith('.json'))
	.map((name) => name.slice(0, -'.json'.length))
	.sort();
if (locales.length !== 21) errors.push(`expected 21 locale catalogues, found ${locales.length}`);
const missingPatterns = locales.filter((code) => !(code in READY_BY_LOCALE));
if (missingPatterns.length > 0)
	errors.push(`no "ready" pattern for locale(s) ${missingPatterns.join(', ')}`);

const catalogs = Object.fromEntries(
	locales.map((code) => [
		code,
		JSON.parse(fs.readFileSync(path.join(localesDir, `${code}.json`), 'utf8'))
	])
);
const placeholders = (text) => (text.match(PLACEHOLDER) ?? []).sort().join(' ');

// The list must track copy a driver really shows, or it guards nothing.
const driverSources = [];
function collectSources(dir) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (entry.isDirectory()) {
			if (!['tests', 'Tests', '.build', 'node_modules'].includes(entry.name)) {
				collectSources(path.join(dir, entry.name));
			}
		} else if (/\.(?:ahk|lua|swift)$/.test(entry.name)) {
			driverSources.push(fs.readFileSync(path.join(dir, entry.name), 'utf8'));
		}
	}
}
for (const driver of ['windows', 'macos', 'linux'])
	collectSources(path.join(root, 'static', 'ergopti_plus', driver));
const driverText = driverSources.join('\n');
for (const key of PRE_CONSENT_KEYS) {
	if (!driverText.includes(`"${key}"`))
		errors.push(`${key} is no longer shown by any driver: update PRE_CONSENT_KEYS`);
}

for (const code of locales) {
	const catalog = catalogs[code];
	const ready = READY_BY_LOCALE[code];
	if (!ready) continue;
	const staged = catalog[POST_DOWNLOAD_KEY];
	if (typeof staged !== 'string' || !ready.test(staged)) {
		errors.push(
			`${code}: the "ready" pattern ${ready} does not match ${POST_DOWNLOAD_KEY}, so it guards nothing`
		);
	}
	for (const key of PRE_CONSENT_KEYS) {
		const text = catalog[key];
		if (typeof text !== 'string' || text === '') {
			errors.push(`${code}: ${key} is missing`);
			continue;
		}
		if (ready.test(text)) {
			errors.push(
				`${code}: ${key} calls the update ready before the user chose to install it: ${text}`
			);
		}
		if (code === 'en' && EN_DOWNLOADED.test(text)) {
			errors.push(`en: ${key} claims a download before consent: ${text}`);
		}
		if (placeholders(text) !== placeholders(catalogs.en[key])) {
			errors.push(
				`${code}: ${key} must keep the placeholders of en (${placeholders(catalogs.en[key])}): ${text}`
			);
		}
		if (NOTIFICATION_KEYS.includes(key) && QUOTES.test(text)) {
			errors.push(
				`${code}: ${key} quotes a menu label, but each tray names its update row differently: ${text}`
			);
		}
	}
	const prompt = catalog[PROMPT_KEY];
	const toast = catalog[TOAST_KEY];
	if (typeof prompt !== 'string' || typeof toast !== 'string') continue;
	const consent = prompt.replace(FIRST_SENTENCE, '');
	if (consent === '' || consent === prompt) {
		errors.push(`${code}: ${PROMPT_KEY} has no consent sentence after its first one: ${prompt}`);
	} else if (toast.replace(FIRST_SENTENCE, '') !== consent) {
		errors.push(
			`${code}: ${TOAST_KEY} must follow its first sentence with the consent of ${PROMPT_KEY} ("${consent}"), ` +
				`not send the user to one place to install from: ${toast}`
		);
	}
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log(
	`[OK] ${PRE_CONSENT_KEYS.length} pre-consent updater strings claim no download in ${locales.length} locales.`
);
