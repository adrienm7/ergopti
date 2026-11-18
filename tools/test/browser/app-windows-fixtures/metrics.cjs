// tools/test/browser/app-windows-fixtures/metrics.cjs

/**
 * ==============================================================================
 * MODULE: App Windows Fixtures, Metrics and Onboarding
 * DESCRIPTION:
 * Fake hosts of the large windows: the typing metrics, the per-app metrics,
 * the onboarding and the layout manager. See app-windows-fixtures.cjs.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');

/**
 * Presses one tab button and checks that it alone reads as pressed: the shown
 * tab was told by its colour only (WCAG 1.4.1, 4.1.2).
 * @param {string} group - Selector of every tab button of the row.
 * @param {string} which - Attribute selector of the button to press.
 */
async function showsPressed(page, group, which) {
	await page.click(group + which);
	const pressed = await page.$$eval(group, (buttons) =>
		buttons
			.filter((button) => button.getAttribute('aria-pressed') === 'true')
			.map((b) => b.outerHTML)
	);
	assert.equal(pressed.length, 1, 'one tab reads as pressed');
	assert.ok(
		await page
			.locator(group + which)
			.evaluate((button) => button.getAttribute('aria-pressed') === 'true'),
		'the pressed tab is the one shown'
	);
}

/**
 * Moves the onboarding forward from the language step, as a user presses
 * Next, and optionally answers « Yes » on the page reached.
 * @param {number} steps - Presses of Next.
 * @param {boolean} [answerYes]
 */
function onboardingStep(steps, answerYes) {
	return async (page) => {
		for (let i = 0; i < steps; i++) {
			await page.click('#btn-next');
			// The fake host answers the folder step's requests before the next press.
			await page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 50)));
		}
		if (answerYes) await page.check('#page-yes');
	};
}

/**
 * Fourteen recorded days of six applications, in the shape the keystats
 * stores write per day (app_time_ms, typing time, characters, hourly slots,
 * switches, sessions, the _system pseudo-app). Run in the page.
 * @returns {Object} The manifest, keyed by YYYY-MM-DD.
 */
function appsManifest() {
	const apps = [
		['Code', 'Travail', 3.1],
		['Firefox', 'Navigation', 2.2],
		['Slack', 'Communication', 1.4],
		['Word', 'Travail', 1.1],
		['Terminal', 'Travail', 0.8],
		['Spotify', 'Divertissement', 0.3]
	];
	const manifest = {};
	for (let day = 0; day < 14; day++) {
		const date = new Date(Date.UTC(2026, 10, 4 + day)).toISOString().slice(0, 10);
		const entry = {
			_system: {
				locked_ms: 3600000 + day * 60000,
				sleep_ms: 7200000,
				passive_count: 3,
				awake_ms: 600000,
				wifi_changes: day % 3,
				space_switches: 12 + day,
				audio_muted_ms: 900000,
				night_wake_count: day % 2,
				battery_sum: 1640,
				battery_count: 20,
				battery_min: 41,
				battery_max: 100
			}
		};
		apps.forEach(([name, category, hours], index) => {
			const scale = 1 + ((day * 7 + index * 3) % 5) / 10;
			const appMs = Math.round(hours * scale * 3600000);
			const chars = Math.round(appMs / 400);
			const hourly = {};
			for (let hour = 8 + index; hour < 18; hour += 2)
				hourly[String(hour).padStart(2, '0')] = {
					c: Math.round(chars / 5),
					time_ms: Math.round(appMs / 5)
				};
			const next = apps[(index + 1) % apps.length][0];
			entry[name] = {
				category,
				app_time_ms: appMs,
				time: Math.round(appMs * 0.45),
				think_time: Math.round(appMs * 0.15),
				chars,
				hs_chars: Math.round(chars / 12),
				llm_chars: Math.round(chars / 30),
				hs_triggers: Math.round(chars / 90),
				bs_total: Math.round(chars / 18),
				session_count_total: 4 + index,
				session_total_active_ms: Math.round(appMs * 0.6),
				session_longest_ms: Math.round(appMs / 3),
				session_longest_chars: Math.round(chars / 3),
				session_durations: [600000, 1500000, 2400000],
				burst_max_cpm: 380 + index * 25,
				focus_to_first_key_sum_ms: 9000 + index * 1000,
				focus_to_first_key_count: 6,
				recovery_time_sum_ms: 4200,
				recovery_time_count: 7,
				cascade_count_total: 2,
				auto_repeat_count: 5,
				same_finger_streak_max: 4,
				char_letter: Math.round(chars * 0.8),
				char_digit: Math.round(chars * 0.05),
				switches_to: { [next]: 6 + index },
				win_titles: { [name + ' — projet Ergopti']: { c: chars, ms: appMs } },
				hourly
			};
		});
		manifest[date] = entry;
	}
	return manifest;
}

/**
 * The n-gram index of the selected range, as the hosts' range reply carries
 * it: per table, each key with its count, its errors and its hotstring share.
 * Run in the page.
 * @returns {{historical: Object, today: Object}}
 */
function typingRange() {
	const text =
		'les claviers ergonomiques rendent la frappe plus rapide et plus confortable chaque jour';
	const words = text.split(' ');
	const table = (keys) => {
		const out = {};
		keys.forEach((key, index) => {
			out[key] = { c: 40 + ((index * 37) % 400), e: index % 4, hs: index % 3 === 0 ? 5 : 0 };
		});
		return out;
	};
	const grams = (size) => {
		const keys = new Set();
		for (let i = 0; i + size <= text.length; i++) keys.add(text.slice(i, i + size));
		return [...keys];
	};
	const historical = {
		c: table(grams(1)),
		bg: table(grams(2)),
		tg: table(grams(3)),
		qg: table(grams(4)),
		pg: table(grams(5)),
		w: table(words),
		w_bg: table(words.slice(1).map((word, index) => words[index] + ' ' + word)),
		sc: table(['Ctrl+C', 'Ctrl+V', 'Ctrl+S', 'Alt+Tab', 'Ctrl+Z']),
		sc_bg: table(['Ctrl+C Ctrl+V', 'Ctrl+S Alt+Tab'])
	};
	return { historical, today: {} };
}

module.exports = [
	{
		id: 'metrics_typing',
		bridge: 'metrics_typing_bridge',
		// The macOS host's publication: the manifest, the range's n-grams as
		// the initial data, and the presentation assets.
		fill: (page) =>
			page.evaluate(
				([manifest, range]) =>
					window.publishTypingMetricsData(
						{
							manifest: (0, eval)('(' + manifest + ')')(),
							initial_data: (0, eval)('(' + range + ')')(),
							app_icons: {},
							kc_layout: {}
						},
						{ manifest_revision: 1, assets_revision: 1 }
					),
				[appsManifest.toString(), typingRange.toString()]
			),
		ready: '#metrics_table tbody tr',
		states: [
			...['kc', 'bg', 'w', 'sc'].map((tab) => ({
				name: 'tab-' + tab,
				enter: (page) => showsPressed(page, '.tabs .tab-btn', '[data-tab="' + tab + '"]')
			})),
			{
				// A rebuild in progress and a failed refresh, both banners shown.
				name: 'banners',
				enter: (page) =>
					page.evaluate(() => {
						window.metrics_rebuild.show_progress({ state: 'running', percent: 42, eta_s: 95 });
						window.setTypingMetricsFreshness({ state: 'failed', generated_at: 1794900000 }, 2);
					})
			},
			{
				// Opened from the keyboard: the focus goes into the dialog and the
				// page behind it is inert, Escape closes it and gives the focus back.
				name: 'app-filter',
				enter: async (page) => {
					const opener = page.locator('#app_filter_btn');
					await opener.focus();
					await page.keyboard.press('Enter');
					const inDialog = () =>
						page.evaluate(() => !!document.activeElement.closest('[role="dialog"][aria-modal]'));
					assert.ok(await inDialog(), 'the app filter takes the focus');
					await page.keyboard.press('Escape');
					assert.ok(
						await opener.evaluate((node) => node === document.activeElement),
						'Escape closes the app filter and the focus returns to its opener'
					);
					await opener.press('Enter');
					assert.ok(await inDialog(), 'the app filter opens again');
				}
			}
		]
	},
	{
		id: 'metrics_apps',
		bridge: 'metrics_apps_bridge',
		// The macOS host's path: it calls the bootstrap with the manifest, the
		// user's categories and the application icons.
		fill: (page) =>
			page.evaluate(
				(source) => window.bootstrapMetricsAppsData((0, eval)('(' + source + ')')(), {}, {}),
				appsManifest.toString()
			),
		ready: '#apps_bar_chart',
		// The overview tab is the filled state; each other tab is its own.
		states: [
			...['time', 'apps', 'typing', 'system'].map((tab) => ({
				name: 'tab-' + tab,
				enter: (page) => showsPressed(page, '.tab-btn', '[data-tab-target="' + tab + '"]')
			})),
			{
				// Opened from the keyboard: the focus goes into the dialog and the
				// page behind it is inert, Escape closes it and gives the focus back.
				name: 'drilldown',
				enter: async (page) => {
					await page.click('.tab-btn[data-tab-target="apps"]');
					const opener = page.locator('#apps-table .app-name-btn', { hasText: 'Code' });
					await opener.focus();
					await page.keyboard.press('Enter');
					const inDialog = () =>
						page.evaluate(() => !!document.activeElement.closest('[role="dialog"][aria-modal]'));
					assert.ok(await inDialog(), 'the drill-down takes the focus');
					await page.keyboard.press('Escape');
					assert.ok(
						await opener.evaluate((node) => node === document.activeElement),
						'Escape closes the drill-down and the focus returns to its opener'
					);
					await opener.press('Enter');
					assert.ok(await inDialog(), 'the drill-down opens again');
				}
			}
		]
	},
	{
		id: 'onboarding',
		bridge: 'hsOnboarding',
		host: async function (message) {
			if (!message || typeof message !== 'object') return;
			const root = 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\';
			if (message.action === 'ready') {
				const strings = await (await fetch('../../core/i18n/data/locales/fr.json')).json();
				window.initData({
					locale: 'fr',
					strings,
					default_config_dir: root,
					empty_config_dir: root,
					locales: [
						{ code: 'en', flag: '🇬🇧', name: 'English' },
						{ code: 'fr', flag: '🇫🇷', name: 'Français' },
						{ code: 'de', flag: '🇩🇪', name: 'Deutsch' }
					],
					config_dir: '',
					current: {},
					metrics_path: root + 'metrics',
					platform: 'windows',
					capabilities: { gesture_registration: true }
				});
			} else if (message.action === 'loadExistingConfig')
				window.applyCurrentValues({ request: message.request, values: {} });
			else if (message.action === 'resolveMetricsPath')
				window.setMetricsPath({ request: message.request, path: root + 'metrics' });
		},
		ready: '#lang-list .lang-item',
		// Language (filled), folder, then pages of the Windows catalogue:
		// tap_holds shortcuts gestures keyboard_layout hotstrings llm metrics.
		states: [
			{ name: 'folder', enter: onboardingStep(1) },
			{ name: 'shortcuts-yes', enter: onboardingStep(3, true) },
			{ name: 'gestures-yes', enter: onboardingStep(4, true) },
			{ name: 'keyboard-layout-yes', enter: onboardingStep(5, true) },
			{ name: 'hotstrings-yes', enter: onboardingStep(6, true) },
			{ name: 'metrics-yes', enter: onboardingStep(8, true) }
		]
	},
	{
		id: 'layout_manager',
		bridge: 'layout_manager_bridge',
		// The hosts send the strings with the first state; the fake host reads
		// the French catalogue the page is served beside.
		host: async function (message) {
			if (!message || message.action !== 'ready') return;
			const strings = await (await fetch('../../core/i18n/data/locales/fr.json')).json();
			const layout = (id, name, version, sha256, author) => ({
				id,
				name,
				family: id,
				version,
				sha256,
				author,
				licence: 'MIT',
				homepage: 'https://ergopti.fr',
				platforms: ['linux', 'macos', 'windows']
			});
			window.initData({
				strings,
				source_editor: true,
				state: {
					platform: 'windows',
					shortcut_menu_path: 'shortcuts/menu.ahk',
					index: {
						layouts: [
							layout('ergopti', 'Ergopti', '2.2.2', 'a', 'Ergopti authors'),
							layout('ergol', 'Ergo-L', '1.0.2', 'b', 'NuclearSquid'),
							layout('fresh', 'Fresh', '3.0.0', 'c', 'Someone')
						]
					},
					source: 'network',
					error: null,
					installed: {
						ergopti: layout('ergopti', 'Ergopti', '2.2.2', 'a', 'Ergopti authors'),
						ergol: layout('ergol', 'Ergo-L', '1.0.1', 'old', 'NuclearSquid')
					},
					active: 'ergopti',
					result: { id: 'ergol', action: 'install', ok: true }
				}
			});
		},
		ready: '#layout-list li'
	}
];
