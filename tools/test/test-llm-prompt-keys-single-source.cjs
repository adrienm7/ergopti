// tools/test/test-llm-prompt-keys-single-source.cjs

/**
 * ==============================================================================
 * MODULE: One Key Set For The Duplicated LLM Prompt Strings
 * DESCRIPTION:
 * The numeric-prompt texts of the AI menu existed twice: macOS read
 * menu.settings.{max_words,temperature}_prompt while Windows read
 * menu.llm.{max_words,temperature}_prompt, and the two local-server port dialogs
 * had one title and one prompt per provider (ollama_port_*, mlx_port_*). Two
 * wordings for one question is how the drivers end up asking it differently in
 * twenty-one languages. This gate pins the single keys:
 *   - the menu.llm prompts are the only max-words and temperature prompts;
 *   - the port dialogs read menu.llm.server_port_title and
 *     menu.llm.server_port_prompt, each taking the provider name, and the
 *     per-provider dialog keys are gone;
 *   - the drivers read those keys, and no source reads a retired one.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = 'static/ergopti_plus';
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), 'utf8');
const LOCALES = 'ar cs da de en es fr he hi it ja ko nl no pl pt ru sv tr uk zh'.split(' ');
const failures = [];
const check = (label, body) => {
	try {
		body();
	} catch (error) {
		failures.push(`${label}: ${error.message}`);
	}
};

const RETIRED = [
	'menu.settings.max_words_prompt',
	'menu.settings.temperature_prompt',
	'menu.llm.ollama_port_title',
	'menu.llm.ollama_port_prompt',
	'menu.llm.mlx_port_title',
	'menu.llm.mlx_port_prompt',
	'menu.llm.mlx_port_label'
];
const SHARED = [
	'menu.llm.max_words_prompt',
	'menu.llm.temperature_prompt',
	'menu.llm.server_port_title',
	'menu.llm.server_port_prompt'
];

// The port row caption names the provider, then the port: one key, two getters.
const PORT_LABEL = 'menu.llm.server_port_label';
// Windows still reads its own caption until the PC switches to the shared label.
const WINDOWS_PORT_LABEL = 'menu.llm.ollama_port_label';
// The two idle-delay prompts accept different input on purpose: macOS takes a blank
// (reset) or "Never"/-1 on top of milliseconds, Windows a plain integer of milliseconds.
const DELAY_PROMPTS = ['menu.settings.delay_prompt', 'menu.llm.debounce_prompt'];

check('catalogues', () => {
	for (const locale of LOCALES) {
		const catalogue = JSON.parse(read(`${PLUS}/_shared/data/locales/${locale}.json`));
		for (const key of RETIRED) assert(!(key in catalogue), `${locale} still carries ${key}`);
		for (const key of SHARED) assert(typeof catalogue[key] === 'string', `${locale} lacks ${key}`);
		assert.strictEqual(
			(catalogue['menu.llm.server_port_title'].match(/%s/g) || []).length,
			1,
			`${locale}: the port title takes the provider name once`
		);
		assert.strictEqual(
			(catalogue['menu.llm.server_port_prompt'].match(/%s/g) || []).length,
			2,
			`${locale}: the port prompt takes the provider name and the default port`
		);
	}
});

check('the shared port row label', () => {
	for (const locale of LOCALES) {
		const catalogue = JSON.parse(read(`${PLUS}/_shared/data/locales/${locale}.json`));
		assert.strictEqual(
			(catalogue[PORT_LABEL].match(/%s/g) || []).length,
			2,
			`${locale}: the port label takes the provider name, then the port`
		);
		for (const key of [WINDOWS_PORT_LABEL, ...DELAY_PROMPTS])
			assert(
				typeof catalogue[key] === 'string',
				`${locale} lost ${key}, which a driver still reads`
			);
	}
	const manifest = read(`${PLUS}/_shared/modules/features/manifest.toml`);
	assert(
		manifest.includes(`i18n = "${PORT_LABEL}"`),
		'the macOS MLX port row reads the shared label'
	);
	assert(
		manifest.includes(`i18n = "${WINDOWS_PORT_LABEL}"`),
		'the Windows Ollama port row keeps its label'
	);
	assert(
		read(`${PLUS}/windows/ui/menu/menu_llm/menu_settings.ahk`).includes(
			'"menu.llm.debounce_prompt"'
		)
	);
	assert(
		read(`${PLUS}/macos/ui/menu/menu_llm/settings_manager.lua`).includes(
			'"menu.settings.delay_prompt"'
		)
	);
});

check('no source reads a retired key', () => {
	const roots = [`${PLUS}/windows`, `${PLUS}/macos`, `${PLUS}/linux`, `${PLUS}/_shared`];
	const hits = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
			const relative = `${dir}/${entry.name}`;
			if (entry.isDirectory()) {
				if (!['node_modules', 'locales', '.git'].includes(entry.name)) walk(relative);
			} else if (
				/\.(lua|ahk|js|json|toml)$/.test(entry.name) &&
				!/run_all_.*tmp/.test(entry.name)
			) {
				const text = read(relative);
				for (const key of RETIRED) if (text.includes(key)) hits.push(`${relative} reads ${key}`);
			}
		}
	};
	roots.forEach(walk);
	assert.deepStrictEqual(hits, [], hits.join('; '));
});

check('macOS dialogs', () => {
	const source = read(`${PLUS}/macos/ui/menu/menu_llm/settings_manager.lua`);
	for (const key of SHARED)
		assert(source.includes(`"${key}"`), `macOS settings manager must read ${key}`);
});
check('Windows dialogs', () => {
	const source = read(`${PLUS}/windows/ui/menu/menu_llm/menu_settings.ahk`);
	for (const key of SHARED)
		assert(source.includes(`"${key}"`), `Windows settings must read ${key}`);
});

if (failures.length > 0) {
	console.error(`test-llm-prompt-keys-single-source: ${failures.length} failure(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log('test-llm-prompt-keys-single-source: ok');
