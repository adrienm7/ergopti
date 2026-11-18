// tools/test/browser/app-windows-fixtures/dialogs.cjs

/**
 * ==============================================================================
 * MODULE: App Windows Fixtures, Dialogs
 * DESCRIPTION:
 * Fake hosts of the small windows: the error window, the diagnostics, the
 * download and update windows, the release notes, the changelog, the action
 * picker and the configuration clean-up. See app-windows-fixtures.cjs.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');

/** Waits until the page's locale strings have landed, as a host's late calls do. */
function stringsLoaded(page) {
	return page.waitForFunction(
		() => window._i18n_strings && Object.keys(window._i18n_strings).length > 100
	);
}

/** A model download half way through, as models_manager pushes it. */
async function downloading(page) {
	await stringsLoaded(page);
	await page.evaluate(() => {
		setKind('mlx_model', null, null, 7);
		setModel('mlx-community/Qwen2.5-7B-Instruct-4bit');
		update(47, '2,1 Go / 4,3 Go', '18,4 Mo/s', '2 min 05 s', '3/7');
		addLog('Fetching 7 files');
		addLog('model-00001-of-00002.safetensors: done');
	});
}

// A release body as CI writes it: title, changelog (lists, a link, code), downloads.
const RELEASE_BODY = [
	'## Ergopti+ v0.0.0-dev.150',
	'',
	'Version de développement.',
	'',
	'## Changelog',
	'',
	'### Nouveautés',
	'',
	'- Le **Comparateur** classe les dispositions par effort ([#812](https://github.com/Ergopti/ergopti/pull/812)).',
	'- La fenêtre des diagnostics copie le rapport en un clic.',
	'',
	'### Corrections',
	'',
	'- `Ctrl+Retour arrière` efface de nouveau un mot entier.',
	'- Les raccourcis à une touche ne se déclenchent plus dans les jeux.',
	'',
	'## Downloads',
	'',
	'| Système | Fichier |',
	'| --- | --- |',
	'| Windows | [ErgoptiPlus.exe](https://github.com/Ergopti/ergopti/releases/download/v0.0.0-dev.150/ErgoptiPlus.exe) |'
].join('\n');

/** The update check's answer, sent once the strings are loaded. */
function updateState(state) {
	return async (page) => {
		await stringsLoaded(page);
		await page.evaluate((message) => window.receiveUpdateCheck(message), {
			type: 'state',
			channel: 'dev',
			current: 'v0.0.0-dev.144',
			others: [{ channel: 'main', tag: 'v1.2.0' }],
			...state
		});
	};
}

/**
 * The action picker's catalogue as the Windows host pushes it
 * (action_picker_webview.ahk), with the vocabulary the page is served beside.
 */
async function pickerCatalogue(page) {
	await page.evaluate(async () => {
		const vocabulary = await (await fetch('../../shortcuts/data/actions/send_keys.json')).json();
		init({
			title: 'Action de la touche',
			label: 'Touche CapsLock, appui court',
			searchPlaceholder: 'Rechercher une action',
			cancelLabel: 'Annuler',
			noneLabel: 'Aucune action',
			allowNative: true,
			nativeLabel: 'Comportement natif de la touche',
			noResults: 'Aucune action ne correspond',
			current: 'send_text',
			editCurrentLabel: 'Modifier l’action actuelle',
			executableSyntax: 'windows',
			commandIsPrimary: false,
			sendVocabulary: vocabulary,
			promptChoices: [
				{ value: 'basic', label: 'Correction' },
				{ value: 'rewrite', label: 'Reformulation' }
			],
			defaultCount: 3,
			visionChoices: [{ value: 'local', label: 'Local', defaultModel: 'qwen2.5vl:3b' }],
			languageChoices: [
				{ value: 'ui', label: 'Menu (Français)' },
				{ value: 'en', label: 'English' }
			],
			parameterStrings: {
				save: 'Enregistrer',
				back: 'Retour',
				captureKey: 'Appuyez sur une touche',
				captureShortcut: 'Appuyez sur un raccourci',
				promptLabel: 'Prompt',
				countLabel: 'Nombre de propositions',
				countDefault: 'Menu ({1})',
				visionProviderLabel: 'Fournisseur',
				visionModelLabel: 'Modèle',
				visionModelDefault: 'Par défaut : {1}',
				visionModelRequired: 'Obligatoire',
				languageLabel: 'Traduire en',
				programExecutableLabel: 'Programme',
				programArgumentsLabel: 'Arguments',
				programAddLabel: 'Ajouter un argument',
				programRemoveLabel: 'Retirer l’argument',
				prompts: {
					text: 'Texte à taper :',
					key: 'Touche à envoyer :',
					shortcut: 'Raccourci à envoyer :'
				},
				errors: {
					text: 'Texte invalide',
					key: 'Touche inconnue',
					shortcut: 'Raccourci invalide',
					llm_prompt: 'Prompt invalide',
					llm_vision: 'Fournisseur invalide',
					llm_language: 'Langue invalide'
				}
			},
			items: [
				{ type: 'heading', level: 1, text: 'Saisie' },
				{
					type: 'action',
					id: 'send_text',
					label: 'Taper un texte',
					parameter: 'text',
					parameterValue: 'Bonjour'
				},
				{ type: 'action', id: 'send_key', label: 'Envoyer une touche', parameter: 'key' },
				{ type: 'action', id: 'enter', label: 'Entrée' },
				{ type: 'heading', level: 2, text: 'Édition' },
				{ type: 'action', id: 'select_word', label: 'Sélectionner le mot' },
				{
					type: 'action',
					id: 'ocr_region',
					label: 'Lire le texte d’une zone',
					disabled: true,
					hint: 'Tesseract n’est pas installé'
				},
				{ type: 'heading', level: 1, text: 'Intelligence artificielle' },
				{
					type: 'action',
					id: 'llm_prompt_prediction',
					label: 'Proposer une suite',
					parameter: 'llm_prompt',
					parameterValue: 'rewrite|2'
				}
			]
		});
	});
}

/**
 * The diagnostics window's first answer, as the hosts build it: the shared
 * schema and redaction rules the page is served beside, a detailed snapshot,
 * then the probes' answers.
 */
async function diagnostics(page) {
	await stringsLoaded(page);
	await page.evaluate(async () => {
		const read = async (file) => (await fetch(file)).json();
		const schema = await read('../../diagnostics/data/schema.json');
		schema.export_strings = window._i18n_strings;
		const redaction = await read('../../diagnostics/data/redaction.json');
		const home = 'C:\\Users\\camille';
		window.receiveDiagnostics({
			type: 'init',
			config: {
				schema,
				redaction,
				context: { home, user: 'camille', case_insensitive: true },
				capabilities: { diagnostic_collection: false }
			},
			snapshot: {
				schema_version: 2,
				export_revision: 1,
				driver: 'windows',
				generated_at: '2026-11-18T09:30:00Z',
				detailed: true,
				sections: {
					paths: {
						logs_dir: home + '\\AppData\\Roaming\\ErgoptiPlus\\logs',
						diagnostics_dir: home + '\\AppData\\Roaming\\ErgoptiPlus\\diagnostics'
					},
					versions: { ergopti_version: '2.2.0', commit: 'ff83b6f04 (git)' },
					system: { os: 'Windows 11 Famille 24H2', uptime: 86400, elevated: false },
					input: { paused: false },
					network: {},
					peripherals: {
						items: [
							{
								bus: 'usb',
								kind: 'keyboard',
								vendor_id: '046d',
								product_id: 'c52b',
								name: 'Logitech K120'
							}
						]
					},
					issues: { warn_count: 3, err_count: 1, last_error: 'keystats flush failed' },
					developer: { modules_failed: [] }
				},
				probes: {
					github_api: { state: 'pending' },
					ai_health: { state: 'pending' },
					system_details: { state: 'pending' }
				}
			}
		});
		window.receiveDiagnostics({
			type: 'probe',
			id: 'github_api',
			result: { state: 'ok', ms: 42 },
			sections: { network: { github_api: 'HTTP 200, 59/60' } }
		});
	});
}

/** The Versions window's release list, as the hosts fetch it from GitHub. */
async function releaseList(page) {
	await stringsLoaded(page);
	await page.evaluate((body) => {
		const release = (tag, day, prerelease) => ({
			tag_name: tag,
			published_at: '2026-11-' + day + 'T10:00:00Z',
			prerelease,
			body: body.replace(/v0\.0\.0-dev\.150/g, tag),
			html_url: 'https://github.com/Ergopti/ergopti/releases/tag/' + tag
		});
		injectReleases(
			[
				release('v0.0.0-dev.150', '17', true),
				release('v0.0.0-dev.149', '15', true),
				release('v0.0.0-dev.148', '12', true),
				release('v1.2.0', '10', false),
				release('v0.0.0-dev.147', '08', true),
				release('v1.1.0', '01', false)
			],
			'dev'
		);
	}, RELEASE_BODY);
}

module.exports = [
	{
		id: 'error_dialog',
		bridge: 'error_dialog',
		host: function (message) {
			if (message !== 'ready') return;
			window.receiveErrorDialog({
				type: 'init',
				kind: 'error',
				module: 'keystats',
				message: 'Flush failed: disk full\nstack traceback:\n\tkeystats.lua:12',
				log_path: 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\logs\\errors.log',
				text: '# ErgoptiPlus diagnostics\n\n```text\nerror:\n  module: keystats\n```\n',
				more: 2
			});
		},
		ready: '#btn-copy:not([disabled])',
		states: [{ name: 'details', enter: (page) => page.click('#details > summary') }]
	},
	{
		id: 'config_cleanup',
		bridge: 'config_cleanup_bridge',
		host: function (message) {
			if (message !== 'ready') return;
			window.receiveConfigCleanup({
				session: 'c0ffee',
				status: 'ready',
				path: 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\config.ini',
				keys: [
					{ section: 'Hotstrings', key: 'old_autocorrect', value: 'true' },
					{ section: 'Shortcuts', key: 'legacy_capslock_mode', value: 'toggle' },
					{ section: 'Metrics', key: 'flush_seconds_v1', value: '30' },
					{ section: '', key: 'theme_v0', value: 'dark' }
				]
			});
		},
		ready: '#btn-clean:not([disabled])',
		states: [
			{
				name: 'removed',
				enter: (page) =>
					page.evaluate(() =>
						window.receiveConfigCleanup({
							session: 'c0ffee',
							status: 'removed',
							path: 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\config.ini',
							removed: 4,
							backup: 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\config.ini.bak',
							keys: []
						})
					)
			}
		]
	},
	{
		id: 'download_window',
		bridge: 'dl_bridge',
		fill: downloading,
		ready: '#file-count',
		states: [
			{
				name: 'network-failure',
				enter: (page) =>
					page.evaluate(() => {
						showLog();
						done(false, null, null);
						window.showNetworkFailure(
							{
								message_key: 'network.failure.unknown',
								actions: [
									{ id: 'retry', label_key: 'network.action.retry' },
									{ id: 'diagnostics', label_key: 'error_dialog.open_log' }
								]
							},
							7,
							1
						);
					})
			},
			{
				name: 'done',
				enter: (page) => page.evaluate(() => done(true, null, null))
			}
		]
	},
	{
		id: 'update_check',
		bridge: 'update_check_bridge',
		fill: updateState({
			state: 'available',
			latest: 'v0.0.0-dev.150',
			notes: { body: RELEASE_BODY, owner: 'Ergopti', repo: 'ergopti' }
		}),
		ready: '#btn-update:not([hidden])',
		states: [
			{ name: 'up-to-date', enter: updateState({ state: 'up_to_date' }) },
			{
				name: 'error',
				enter: updateState({
					state: 'error',
					reason_key: 'updater.no_connection',
					log_path: 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\logs\\updater.log'
				})
			}
		]
	},
	{
		// The pane inside the Windows update prompt; it has no manifest window of
		// its own (release_notes_prompt.ahk sizes the prompt), so it gives a size.
		id: 'release_notes',
		bridge: 'release_notes_bridge',
		size: { width: 560, height: 420 },
		// The seed the Windows host prepends to the page (changelog.ahk,
		// _Updater_ReleaseNotesSeed), run before the page's own scripts.
		seed: {
			script: (body) => {
				window.__release_notes = { body, owner: 'Ergopti', repo: 'ergopti', session: 'a1b2c3' };
			},
			arg: RELEASE_BODY
		},
		ready: '#release-notes a'
	},
	{
		id: 'changelog',
		bridge: 'changelog_bridge',
		// The seed the hosts prepend: the running build, its channel, the
		// backup the last install left.
		seed: {
			script: () => {
				window.__installed_version = '0.0.0-dev.148';
				window.__subscribed_channel = 'dev';
				window.__changelog_gh_owner = 'Ergopti';
				window.__changelog_gh_repo = 'ergopti';
				window.__restorable_backup = {
					id: 'pre-install-20261112',
					created_at: '2026-11-12T09:00:00Z',
					tag: 'v0.0.0-dev.147'
				};
			},
			arg: null
		},
		fill: releaseList,
		ready: '#btn-install:visible',
		states: [
			{
				name: 'downloads',
				enter: (page) =>
					page.evaluate(() =>
						document.querySelectorAll('#release-body details').forEach((node) => {
							node.open = true;
						})
					)
			},
			{
				name: 'install-failed',
				enter: async (page) => {
					await page.click('#btn-install');
					await page.evaluate(() =>
						window.setInstallProgress({
							tag: 'v0.0.0-dev.150',
							phase: 'failed',
							reason_key: 'changelog_window.install_error_verify',
							backup_path: 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\backups\\pre-install'
						})
					);
				}
			},
			{
				name: 'other-channel',
				enter: async (page) => {
					await page.click('#channel-toggle .channel-btn:not(.active)');
					await page.click('#btn-subscribe');
				}
			},
			{
				// A release row is a keyboard stop that Enter picks: the scan alone
				// cannot tell a row the keyboard never reaches.
				name: 'keyboard-pick',
				enter: async (page) => {
					await page.focus('.release-item[data-idx="1"]');
					await page.keyboard.press('Enter');
					assert.equal(
						await page.getAttribute('.release-item[data-idx="1"]', 'aria-current'),
						'true',
						'Enter on a focused release row selects it'
					);
					assert.equal(await page.textContent('#release-tag'), 'v0.0.0-dev.149');
				}
			},
			{
				name: 'error',
				enter: (page) =>
					page.evaluate(() => injectError('Impossible de joindre GitHub (délai dépassé).'))
			}
		]
	},
	{
		id: 'healthcheck',
		bridge: 'healthcheck',
		fill: diagnostics,
		ready: '#btn-copy:not([disabled])',
		states: [
			{ name: 'preview', enter: (page) => page.click('#preview > summary') },
			{
				name: 'day-log',
				enter: async (page) => {
					await page.check('#chk-day-log');
					await page.evaluate(() => {
						const line = (n) =>
							'2026-11-18 09:' + String(n).padStart(2, '0') + ' INFO keystats flush';
						window.receiveDiagnostics({
							type: 'action',
							action: 'day_log',
							ok: true,
							state: 'ready',
							bytes: 48213,
							lines: 612,
							cap_bytes: 4194304,
							first_time: '2026-11-18 00:00:01',
							last_time: '2026-11-18 09:29:58',
							head: Array.from({ length: 20 }, (_, n) => line(n)),
							tail: Array.from({ length: 20 }, (_, n) => line(n + 30))
						});
					});
					await page.click('#day-log-preview > summary');
				}
			},
			{
				name: 'saved',
				enter: (page) =>
					page.evaluate(() =>
						window.receiveDiagnostics({
							type: 'action',
							action: 'save',
							ok: 1,
							path: 'C:\\Users\\camille\\Desktop\\ergopti-diagnostics.md'
						})
					)
			}
		]
	},
	{
		id: 'action_picker',
		bridge: 'action_picker_bridge',
		fill: pickerCatalogue,
		ready: '#list .row',
		states: [
			{ name: 'contents', enter: (page) => page.click('#toc-btn') },
			{
				// Folding and the contents work from the keyboard alone, and the
				// focus stays where the user is: the scan cannot see either.
				name: 'keyboard-fold',
				enter: async (page) => {
					const focused = () =>
						page.evaluate(() => [
							document.activeElement.className,
							document.activeElement.getAttribute('aria-expanded')
						]);
					await page.focus('#list .heading');
					await page.keyboard.press('Enter');
					assert.deepEqual(await focused(), ['heading lvl1 collapsed', 'false'], 'Enter folds');
					assert.equal(await page.locator('#list .row[data-id="send_text"]').count(), 0);
					await page.keyboard.press('Space');
					assert.deepEqual(await focused(), ['heading lvl1', 'true'], 'Space unfolds');
					await page.focus('#toc-btn');
					await page.keyboard.press('Enter');
					assert.equal(await page.getAttribute('#toc-btn', 'aria-expanded'), 'true');
					assert.deepEqual(await focused(), ['toc-item lvl1', null], 'The contents take the focus');
					await page.keyboard.press('Escape');
					assert.equal(await page.evaluate(() => document.activeElement.id), 'toc-btn');
				}
			},
			{ name: 'text-editor', enter: (page) => page.click('#btn-edit-current') },
			{
				name: 'prompt-editor',
				enter: (page) => page.click('#list .row[data-id="llm_prompt_prediction"]')
			}
		]
	}
];
