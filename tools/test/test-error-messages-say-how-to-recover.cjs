// tools/test/test-error-messages-say-how-to-recover.cjs

/**
 * ==============================================================================
 * MODULE: Error Messages Say How To Recover
 * DESCRIPTION:
 * WCAG 3.3.3 (error suggestion): these messages used to say what failed and
 * stop there. Each one now ends with the next step its caller allows. The
 * English text must end with that step; every other locale must carry its own
 * translation of the whole message (not the English one, not the old fact
 * alone), keep the placeholders, and quote a button or menu label in that
 * locale's own words, so a translation cannot fall back to the bare fact.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const LOCALES_DIR = path.join(
	__dirname,
	'..',
	'..',
	'static',
	'ergopti_plus',
	'_shared',
	'core',
	'i18n',
	'data',
	'locales'
);

// Key, the recovery step that ends its English text, and the label it quotes
// (the label's key, and the value its %s takes) when it names one.
const RECOVERY = [
	// First pass (ef7aa6be10).
	['changelog_window.error_parse', ' Close this window and open it again.'],
	['layout_editor.error.copy_failed', ' Another program may be holding the clipboard: try again.'],
	[
		'layout_editor.error.host_save_failed',
		' Check that the folder is writable and has free space, then try again.'
	],
	[
		'layout_editor.error.workspace_store_failed',
		' Leave the private window or allow site storage, then try again.'
	],
	[
		'layout_editor.error.studio_write_failed',
		' Check that the folder is writable and has free space, then try again.'
	],
	['dialog.fatal_error.toml_key_missing', ' Reinstall Ergopti+ to restore it.'],
	['dialog.fatal_error.toml_not_found', ' Reinstall Ergopti+ to restore it.'],
	[
		'dialog.unused_keys.reason.unreadable',
		' Close any program that has the file open, then try again.'
	],
	[
		'download_window.error_unknown',
		' Try again; if it keeps failing, the details are in today’s log.'
	],
	['editor.hotstrings.err_write', ' Close any program that has the file open, then try again.'],
	['healthcheck.problem.network', ' Check your internet connection, then try again.'],
	['llm.vision.capture_failed', ' Try again; if it keeps failing, the details are in today’s log.'],
	[
		'llm.translate.failed',
		' Check the AI model and its API key in the AI settings, then try again.'
	],
	['llm.agent.failed', ' Check the AI model and its API key in the AI settings, then try again.'],
	[
		'llm.agent.connector_failed',
		' Try again; if it keeps failing, the details are in today’s log.'
	],
	['proxy_override.not_saved', ' Close any program that has the file open, then try again.'],
	['menu.layout.emulation_not_saved', ' Close any program that has the file open, then try again.'],
	['notify.color_copy_failed', ' Another program may be holding the clipboard: try again.'],
	['notify.take_note_failed', ' Check that it still exists, then try again.'],
	[
		'onboarding.error.write_failed',
		' Check that the folder is writable and has free space, then try again.'
	],
	['ui_apps.render_error', ' Close this window and open it again.'],
	[
		'ui_typing.maintenance_export_failed',
		' Check that the folder is writable and has free space, then try again.'
	],
	[
		'update_check.error_unexpected',
		' Try again; if it keeps failing, the details are in today’s log.'
	],
	['updater.settings_save_failed', ' Close any program that has the file open, then try again.'],
	['updater.parse_failed', ' Try again; if it keeps failing, the details are in today’s log.'],
	['ui_metrics_freshness.failed_empty', ' Close this window and open it again.'],
	['user_actions.path_open_failed', ' Check that it still exists, then try again.'],
	['layout_analysis.status.corpus_failed', ' Reload the page, or reopen the window, to try again.'],
	['layout_analysis.status.store_failed', ' Reload the page, or reopen the window, to try again.'],
	[
		'layout_analysis.error.studio_handoff_failed',
		' Leave the private window or allow site storage, then try again.'
	],
	// Second pass: bundled apps, gestures, layout manager, model browser, editor codes.
	['apps.cloner.error_unknown', ' Open App Cloner again from the Ergopti menu, then try again.'],
	[
		'apps.cloner.err_path_missing',
		' Check its spelling, or leave the field empty to simply start the application.'
	],
	['apps.cloner.err_source_unreadable', ' Choose the program itself, or another shortcut to it.'],
	['apps.encryptor.err_decrypt_failed', ' Try again with the password used to encrypt it.'],
	[
		'apps.encryptor.err_encrypt_failed',
		' Check that the file’s folder is writable and has free space, then try again.'
	],
	['apps.encryptor.err_file_missing', ' It may have been moved or renamed: choose it again.'],
	['apps.encryptor.err_password_mismatch', ' Type the same password twice.'],
	['apps.encryptor.err_empty_password', ' Type a password, or cancel to stop.'],
	[
		'gestures.system.slot_unavailable',
		'; use “Auto-configure (registry)” in this menu',
		{ key: 'menu.gestures.auto_configure' }
	],
	['gestures.system.slot_unverified', '; open this menu again to read them again'],
	[
		'layout_manager.error_http',
		' Click “Refresh” in a few minutes.',
		{ key: 'layout_manager.btn_refresh' }
	],
	[
		'layout_manager.error_generic',
		' Click “Refresh” to download it again.',
		{ key: 'layout_manager.btn_refresh' }
	],
	[
		'layout_manager.error_record',
		' Close this window and open it again; if the message stays, the details are in today’s log.'
	],
	['layout_manager.failure_busy', ': wait for it to finish, then try again.'],
	['layout_manager.failure_foreign_file', ': move or rename it, then try again.'],
	['layout_manager.failure_download', ': check the connection, then try again.'],
	[
		'layout_manager.failure_other',
		': try again; if it keeps failing, the details are in today’s log.'
	],
	[
		'model_browser.reason_ollama_missing',
		': click “Install Ollama” to install it.',
		{ key: 'model_browser.install_runtime', arg: 'Ollama' }
	],
	[
		'model_browser.reason_mlx_missing',
		': click “Install MLX” to install it.',
		{ key: 'model_browser.install_runtime', arg: 'MLX' }
	],
	[
		'layout_editor.error.codepoint_invalid',
		' Type a hexadecimal value up to 10FFFF, such as U+00E9.'
	],
	['layout_editor.error.save_busy', ' Wait for it to finish, then try again.'],
	['layout_editor.error.toml_codec_missing', ' Reload the page.'],
	['layout_editor.error.backup_invalid', ' Choose a backup the editor exported (a .zip file).'],
	[
		'layout_editor.error.backup_deflate_unsupported',
		' Open the editor in an up-to-date Chrome, Edge, Firefox or Safari.'
	],
	['layout_editor.error.dead_key_in_use', ' Change or remove the use named in parentheses first.'],
	['layout_editor.error.layer_in_use', ' Change or remove the use named in parentheses first.'],
	['layout_editor.error.modifier_in_use', ' Change or remove the use named in parentheses first.'],
	['layout_editor.error.source_duplicate', ' Give one of them another identifier.'],
	[
		'layout_editor.error.emulate_failed',
		' Try again; if it keeps failing, the details are in today’s log.'
	],
	[
		'layout_editor.error.emulate_not_saved',
		' Try again; if it keeps failing, the details are in today’s log.'
	],
	[
		'layout_editor.error.install_failed',
		' Try again; if it keeps failing, the details are in today’s log.'
	],
	[
		'layout_editor.error.toml_syntax',
		' Fix the place named in parentheses, then import the file again.'
	],
	[
		'layout_editor.error.file_unreadable',
		' Check that it still exists and that no other program holds it, then try again.'
	]
];

const locales = new Map(
	fs
		.readdirSync(LOCALES_DIR)
		.filter((name) => name.endsWith('.json'))
		.map((name) => [
			name.slice(0, -'.json'.length),
			JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, name), 'utf8'))
		])
);
const english = locales.get('en');
assert.ok(english, 'the canonical English locale is present');
assert.ok(locales.size > 1, 'the translated locales are present');

const placeholders = (text) => (text.match(/\{\w+\}|%s/g) || []).sort();
// A menu label may open with an emoji and a space; the message quotes the words.
const labelWords = (text) => text.replace(/^[^\p{L}\p{N}%]+/u, '');

const keys = RECOVERY.map(([key]) => key);
assert.equal(new Set(keys).size, keys.length, 'each message is listed once');

const problems = [];
for (const [key, step, label] of RECOVERY) {
	const message = english[key];
	if (typeof message !== 'string') {
		problems.push(`en: ${key} is missing`);
		continue;
	}
	assert.ok(step.trim() !== '', `${key}: its recovery step is not empty`);
	if (!message.endsWith(step))
		problems.push(`en: ${key} does not end with its recovery step "${step.trim()}"`);
	const fact = message.slice(0, message.length - step.length);
	for (const [code, strings] of locales) {
		if (code === 'en') continue;
		const text = strings[key];
		if (typeof text !== 'string' || text.trim() === '') {
			problems.push(`${code}: ${key} is missing`);
			continue;
		}
		if (text === message) problems.push(`${code}: ${key} is the English text`);
		if (JSON.stringify(placeholders(text)) !== JSON.stringify(placeholders(message)))
			problems.push(`${code}: ${key} changes the placeholders of the English text`);
		if (label) {
			const quoted = labelWords(strings[label.key] || '').replace('%s', label.arg || '');
			if (quoted === '' || !text.includes(quoted))
				problems.push(`${code}: ${key} does not quote its own label "${quoted}"`);
		}
		// The bare English fact copied into a locale is the old message, untranslated.
		if (text.trim() === fact.trim()) problems.push(`${code}: ${key} keeps only the English fact`);
	}
}

assert.deepEqual(problems, [], problems.join('\n'));
console.log(
	`PASS test-error-messages-say-how-to-recover (${RECOVERY.length} messages, ${locales.size} locales)`
);
