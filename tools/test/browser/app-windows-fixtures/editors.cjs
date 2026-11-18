// tools/test/browser/app-windows-fixtures/editors.cjs

/**
 * ==============================================================================
 * MODULE: App Windows Fixtures, Editors
 * DESCRIPTION:
 * Fake hosts of the editing windows: hotstrings, hotstring settings, paths,
 * personal information, prompts, numeric and token prompts, the model
 * browser and the physical shortcuts. See app-windows-fixtures.cjs.
 * ==============================================================================
 */

'use strict';

/** Waits until the page's locale strings have landed, as a host's late calls do. */
function stringsLoaded(page) {
	return page.waitForFunction(
		() => window._i18n_strings && Object.keys(window._i18n_strings).length > 100
	);
}

module.exports = [
	{
		id: 'numeric_prompt',
		bridge: 'numeric_prompt_bridge',
		host: function (message) {
			if (message !== 'ready') return;
			window.receive_prompt({
				title: 'Température',
				hint: 'Plus la valeur est haute, plus les suggestions sont variées.',
				value: 0.7,
				min: 0,
				max: 2,
				request_epoch: 3
			});
		},
		ready: '#range-hint:not(:empty)',
		states: [
			{
				name: 'refused',
				enter: async (page) => {
					await stringsLoaded(page);
					await page.fill('#value-input', '5');
					await page.click('#save-button');
					await page.locator('#error:not([hidden])').waitFor();
				}
			}
		]
	},
	{
		id: 'token_prompt',
		bridge: 'token_bridge',
		fill: stringsLoaded,
		ready: '#btn-validate:not(:empty)'
	},
	{
		id: 'prompt_editor',
		bridge: 'prompt_bridge',
		host: function (message) {
			if (!message || message.action !== 'ready') return;
			window.init({
				edit_id: 'summary',
				epoch: 4,
				title: 'Modifier le prompt',
				name: 'Résumé court',
				mode: 'parallel',
				prompt: 'Résume {context} en {n} phrases de {min_words} à {max_words} mots, en {language}.'
			});
		},
		fill: stringsLoaded,
		ready: '#e-out .chip, #e-out span'
	},
	{
		id: 'paths_editor',
		bridge: 'hsPaths',
		// The hosts send the strings with the data; the fake host reads the
		// French catalogue the page is served beside.
		host: async function (message) {
			if (!message || message.action !== 'ready') return;
			const strings = await (await fetch('../../core/i18n/data/locales/fr.json')).json();
			window.initData({
				configDir: 'D:\\Ergopti\\config\\',
				defaultConfigDir: 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\',
				logsDir: 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\logs\\',
				defaultLogsDir: 'C:\\Users\\me\\AppData\\Roaming\\ErgoptiPlus\\logs\\',
				strings
			});
		},
		ready: '#default-config-dir:not(:empty)'
	},
	{
		id: 'personal_info_editor',
		bridge: 'hsPersonalInfo',
		host: async function (message) {
			if (!message || message.action !== 'ready') return;
			const strings = await (await fetch('../../core/i18n/data/locales/fr.json')).json();
			window.initData({
				strings,
				fields: [
					{ key: 'first_name', label: 'Prénom', value: 'Camille' },
					{ key: 'last_name', label: 'Nom', value: 'Martin' },
					{ key: 'email', label: 'Adresse e-mail', value: 'camille.martin@example.org' },
					{ key: 'phone', label: 'Téléphone', value: '06 12 34 56 78', hint: '(@@tel)' },
					{
						key: 'street_address',
						label: 'Adresse',
						value: '12 rue des Lilas\nBâtiment B'
					},
					{ key: 'city', label: 'Ville', value: 'Lyon' }
				]
			});
		},
		ready: '#rows textarea'
	},
	{
		id: 'hotstring_editor',
		bridge: 'hsEditor',
		// The section lists render their labels through the page's translator:
		// the data comes once the strings have landed, as the hosts send it on
		// their navigation-complete callback.
		fill: async (page) => {
			await stringsLoaded(page);
			await page.evaluate(() => {
				const entry = (trigger, output, flags) => ({
					trigger,
					output,
					is_word: false,
					auto_expand: false,
					is_case_sensitive: false,
					final_result: false,
					...flags
				});
				window.initData({
					trigger_char: '★',
					star: '★',
					compact_view: false,
					auto_close: false,
					default_priority: 50,
					open_mode: 'menu',
					sections: [
						{
							name: 'signatures',
							description: 'Signatures',
							entries: [
								entry('sig★', 'Cordialement,\nCamille Martin', { is_word: true }),
								entry('adr★', '12 rue des Lilas, 69003 Lyon', { auto_expand: true })
							]
						},
						{
							name: 'code',
							description: 'Code',
							entries: [
								entry('cl★', 'console.log({context});', { is_case_sensitive: true }),
								entry('fn★', 'function () {}', { final_result: true, priority: 80 })
							]
						}
					]
				});
			});
		},
		ready: '.entry-row',
		states: [
			{
				name: 'entry form',
				enter: async (page) => {
					await page.click('.btn-add');
					await page.locator('#entry-modal.on').waitFor();
				}
			},
			{
				name: 'section form',
				enter: async (page) => {
					await page.click('#hdr .btn-p');
					await page.locator('#sec-modal.on').waitFor();
				}
			},
			{
				name: 'search',
				enter: async (page) => {
					await page.fill('#search-input', 'sig');
					await page.locator('#search-clear').waitFor();
				}
			},
			{
				name: 'selection',
				enter: async (page) => {
					await page.check('.entry-cb >> nth=0');
					await page.locator('#bulk-bar').waitFor();
				}
			},
			{
				// Deleting the selection asks first; the dialog takes the focus.
				name: 'confirmation',
				enter: async (page) => {
					await page.check('.entry-cb >> nth=0');
					await page.click('.btn-bulk-del');
					await page.locator('#confirm-modal.on').waitFor();
					await page.waitForFunction(() =>
						document.getElementById('confirm-modal').contains(document.activeElement)
					);
				}
			},
			{
				// The keyboard alone opens an entry: Enter on its trigger (WCAG 2.1.1).
				name: 'keyboard edit',
				enter: async (page) => {
					await page.focus('.trig-lbl');
					await page.keyboard.press('Enter');
					await page.locator('#entry-modal.on').waitFor();
				}
			}
		]
	},
	{
		id: 'hotstrings_config_window',
		bridge: 'hotstrings_config_bridge',
		host: function (message) {
			if (message !== 'ready') return;
			const section = (name, title, overrides) => ({
				name,
				title,
				delay_ms: 750,
				delay_default_ms: 750,
				color: '#4a9eff',
				priority: 50,
				priority_default: 50,
				show_tooltip: true,
				...overrides
			});
			window.setData({
				global_default_delay_ms: 750,
				presets: [
					{ label: 'Bleu', hex: '#4a9eff' },
					{ label: 'Vert', hex: '#32d74b' },
					{ label: 'Gris', hex: '#888888' }
				],
				groups: [
					{ key: 'ergopti', label: 'Ergopti+' },
					{ key: 'personal', label: 'Personnels' }
				],
				categories: [
					{
						...section('magic', 'Touche magique'),
						group: 'ergopti',
						sections: [
							section('suffixes', 'Suffixes', { delay_ms: 400, delay_overridden: true }),
							section('words', 'Mots courants', { color: '#32d74b', color_overridden: true })
						]
					},
					{
						...section('repeat', 'Répétitions', { show_tooltip: false }),
						group: 'ergopti',
						sections: [section('letters', 'Lettres doublées', { priority: 70 })]
					},
					{
						...section('mine', 'Mes hotstrings'),
						group: 'personal',
						personal_path: 'hotstrings/personal.toml',
						sections: [section('signatures', 'Signatures')]
					}
				]
			});
		},
		ready: '.cat .sec'
	},
	{
		id: 'model_browser',
		bridge: 'model_browser_bridge',
		fill: async (page) => {
			await stringsLoaded(page);
			await page.evaluate(() =>
				window.injectModels({
					session: 1,
					backend: 'ollama',
					active: 'qwen3:4b',
					backends: [
						{
							id: 'ollama',
							kind: 'local',
							brand: 'Ollama',
							emoji: '🦙',
							available: true,
							add_model: true
						},
						{
							id: 'mlx',
							kind: 'local',
							brand: 'MLX',
							emoji: '🍎',
							available: false,
							reason_key: 'model_browser.reason_mlx_intel',
							add_model: true
						},
						{
							id: 'openai',
							kind: 'remote',
							brand: 'OpenAI',
							emoji: '☁️',
							available: true,
							providers: [
								{ id: 'openai', label: 'OpenAI' },
								{ id: 'mistral', label: 'Mistral' }
							]
						}
					],
					models: [
						{
							name: 'qwen3:4b',
							backend: 'ollama',
							family: 'Qwen 3',
							installed: true,
							disk_gb: 2.6,
							ram_gb: 4,
							params_b: 4,
							is_default: true
						},
						{
							name: 'llama3.2:3b',
							backend: 'ollama',
							family: 'Llama 3.2',
							installed: true,
							disk_gb: 2,
							ram_gb: 3.5,
							params_b: 3
						},
						{
							name: 'mistral:7b',
							backend: 'ollama',
							family: 'Mistral',
							installed: false,
							disk_gb: 4.1,
							ram_gb: 8,
							params_b: 7
						},
						{
							name: 'hf.co/me/custom:Q4_K_M',
							backend: 'ollama',
							installed: true,
							custom: true,
							disk_gb: 3,
							ram_gb: 5,
							params_b: 4
						},
						{
							name: 'mlx-community/Qwen3-4B-4bit',
							backend: 'mlx',
							installed: false,
							disk_gb: 2.3,
							ram_gb: 4,
							params_b: 4
						},
						{ name: 'gpt-4o-mini', backend: 'openai', provider: 'OpenAI' }
					]
				})
			);
		},
		ready: '#models tbody tr',
		states: [
			{
				// Every backend's group unfolded, one model chosen: the rows and their actions.
				name: 'unfolded',
				enter: async (page) => {
					for (const toggle of await page.locator('.group-toggle').all()) await toggle.click();
					await page.click('tr[data-key*="llama3.2"] td >> nth=1');
					await page.locator('tr[aria-selected="true"]').waitFor();
				}
			}
		]
	},
	{
		id: 'physical_shortcuts',
		bridge: 'physical_shortcuts_bridge',
		// The hosts send the strings with the data; the fake host reads them from
		// the French catalogue where it has them.
		host: async function (message) {
			if (!message || message.action !== 'ready') return;
			const fr = await (await fetch('../../core/i18n/data/locales/fr.json')).json();
			const strings = {
				title: fr['physical_shortcuts.window_title'],
				'manual-hint': fr['physical_shortcuts.manual_hint'],
				capture: fr['physical_shortcuts.capture'],
				'capture-reason': fr['physical_shortcuts.capture_unavailable'],
				empty: fr['physical_shortcuts.empty'],
				add: 'Ajouter un raccourci',
				'position-label': fr['physical_shortcuts.position'],
				'modifier-label': 'Modificateurs',
				choose: 'Choisir l’action',
				save: fr['common.save'],
				cancel: fr['common.cancel'],
				close: fr['common.close'],
				edit: fr['physical_shortcuts.edit'],
				remove: fr['common.delete'],
				source_changed: fr['physical_shortcuts.source_changed'],
				save_failed: fr['physical_shortcuts.save_failed'],
				saved_reopen: fr['physical_shortcuts.saved_reopen'],
				saved: fr['common.saved'],
				unavailable: fr['physical_shortcuts.position_unavailable']
			};
			const mods = (on) => ({ ctrl: false, alt: false, shift: false, super: false, ...on });
			window.init({
				strings,
				names: {
					modifiers: { ctrl: 'Ctrl', alt: 'Alt', shift: 'Maj', super: 'Win' },
					positions: { Backquote: '²', KeyJ: 'J', KeyK: 'K', KeyL: 'L' }
				},
				entries: [
					{
						slot: 1,
						code: 'KeyJ',
						mods: mods({ ctrl: true, alt: true }),
						label: 'Ouvrir le terminal'
					},
					{ slot: 2, code: 'KeyK', mods: mods({ super: true }), label: 'Prendre une note' }
				],
				positions: [
					{ code: 'Backquote', available: false, reason: strings.unavailable },
					{ code: 'KeyJ', available: true },
					{ code: 'KeyK', available: true },
					{ code: 'KeyL', available: true }
				],
				capture: false
			});
		},
		ready: '#entries .entry',
		states: [
			{
				name: 'editor',
				enter: async (page) => {
					await page.click('#add');
					await page.locator('#editor:not([hidden])').waitFor();
				}
			}
		]
	}
];
