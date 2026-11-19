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
	],
	// Third pass: the editor codes that were failures without a step.
	['layout_editor.error.compile_refused', ' Undo the last change, then try again.'],
	['layout_editor.error.elevation_refused', ' Install it again and accept the Windows prompt.'],
	[
		'layout_editor.error.registry_unavailable',
		' Reload the page, or reopen the window, to try again.'
	],
	[
		'layout_editor.error.studio_invalid_layout',
		' Reload the page, or reopen the window, to try again.'
	],
	[
		'layout_editor.error.nav_file_invalid',
		' Fix the place named in parentheses, then import the file again.'
	],
	['layout_editor.error.source_keylayout', ' Open it in Ukelele, save it again, then import it.'],
	['layout_editor.error.source_format', ' Choose a layout file the editor saved.'],
	['layout_editor.error.source_version', ' Update Ergopti+, then import the file again.']
];

// The editor codes that are not a failure to recover from, each with why.
// rule: a validation rule; the rule itself (and the field the editor appends in
//   parentheses) tells what to change, so a step would only repeat it.
// inline: the message already gives its next step, quoted in `step`.
// fragment: shown only inside `within`, which says what happens next.
// preserved: no step is safe to suggest; `reason` says why.
const PREFIX = 'layout_editor.error.';
const CLASSIFIED = {
	generic: {
		kind: 'label',
		reason: 'the fallback that names a code without a message of its own; no known failure uses it'
	},
	dead_key_unknown: {
		kind: 'rule',
		reason: 'a reference to a dead key the layout does not define; the field is in parentheses'
	},
	layer_unknown: {
		kind: 'rule',
		reason: 'a reference to a layer the layout does not define; the field is in parentheses'
	},
	layer_base_required: { kind: 'rule', reason: 'the base layer is the one layer a layout needs' },
	nav_action_unknown: {
		kind: 'rule',
		reason:
			'the layer file names an action the navigation layer lacks; the action is in parentheses'
	},
	nav_binding_invalid: {
		kind: 'rule',
		reason: 'the binding that does not read is quoted in parentheses'
	},
	nav_binding_sequence: {
		kind: 'rule',
		reason: 'states the limit: one shortcut per key, not a sequence'
	},
	nav_mapping_unsupported: { kind: 'rule', reason: 'states which kind of key the layer refuses' },
	nav_modifier_unsupported: { kind: 'rule', reason: 'states which modifier the layer refuses' },
	nav_section_unknown: {
		kind: 'rule',
		reason: 'the unknown section of the layer file is named in parentheses'
	},
	source_base_convention: { kind: 'rule', reason: 'states the keyboard a new layout is drawn on' },
	source_base_layer: { kind: 'rule', reason: 'states the layer a layout needs' },
	source_invalid: { kind: 'rule', reason: 'the missing or invalid field is named in parentheses' },
	source_modifier_overlap: {
		kind: 'rule',
		reason: 'states the rule: a modifier is required or optional, not both'
	},
	source_reference: {
		kind: 'rule',
		reason: 'the reference to nothing is named in parentheses'
	},
	source_unicode: {
		kind: 'rule',
		reason: 'the field with the invalid character is in parentheses'
	},
	source_unknown_field: { kind: 'rule', reason: 'the unknown field is named in parentheses' },
	source_xml_entity: { kind: 'rule', reason: 'states the rule: entities are refused' },
	source_shortcut_key_self: { kind: 'rule', reason: 'states the rule the shortcut breaks' },
	source_export_unavailable: {
		kind: 'rule',
		reason: 'the edits this export cannot hold are named in parentheses; the other exports remain'
	},
	target_export_refused: {
		kind: 'rule',
		reason: 'the converter’s reason is in parentheses; the other targets remain'
	},
	import_unsupported: { kind: 'rule', reason: 'lists the files the import takes' },
	kbd_installer_text: { kind: 'rule', reason: 'states the length and the characters allowed' },
	foreign_layout: { kind: 'inline', step: 'change it in the Windows options' },
	profile_not_added: { kind: 'inline', step: 'add it in Settings' },
	export_assets_unavailable: { kind: 'inline', step: 'check the connection and try again' },
	lua_vm_unavailable: { kind: 'inline', step: 'The editor on ergopti.fr builds these files.' },
	workspace_store_unavailable: { kind: 'inline', step: 'export a backup before leaving' },
	nav_hold_key_missing: { kind: 'inline', step: 'Choose the key held for the layer first.' },
	source_preserved: { kind: 'inline', step: 'Convert the imported layout before editing it.' },
	workspace_invalid: { kind: 'fragment', within: 'layout_editor.tabs.restore_failed' },
	studio_unreadable: {
		kind: 'preserved',
		reason:
			'the damaged file holds the user’s Studio data; every way out (moving it aside) loses it, ' +
			'so the message says the drivers leave it untouched'
	}
};
const KINDS = new Set(['label', 'rule', 'inline', 'fragment', 'preserved']);

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

// Every editor code either ends with its step or is classified with a reason, so
// a new code cannot ship as a bare failure.
const recovered = new Set(keys);
for (const key of Object.keys(english).filter((name) => name.startsWith(PREFIX))) {
	const entry = CLASSIFIED[key.slice(PREFIX.length)];
	if (recovered.has(key)) {
		if (entry) problems.push(`${key} both ends with a step and is classified`);
		continue;
	}
	if (!entry) {
		problems.push(`${key} neither ends with a recovery step nor is classified`);
		continue;
	}
	if (!KINDS.has(entry.kind)) problems.push(`${key}: unknown kind "${entry.kind}"`);
	if (entry.kind === 'inline') {
		if (!english[key].includes(entry.step))
			problems.push(`${key} does not give its step "${entry.step}"`);
	} else if (entry.kind === 'fragment') {
		if (!/\{reason\}/.test(english[entry.within] || ''))
			problems.push(`${key}: ${entry.within} does not hold it as its {reason}`);
	} else if (typeof entry.reason !== 'string' || entry.reason.trim() === '') {
		problems.push(`${key} is classified without a reason`);
	}
}
for (const code of Object.keys(CLASSIFIED))
	if (typeof english[PREFIX + code] !== 'string')
		problems.push(`${PREFIX + code} is classified but has no message`);

assert.deepEqual(problems, [], problems.join('\n'));
console.log(
	`PASS test-error-messages-say-how-to-recover (${RECOVERY.length} messages, ` +
		`${Object.keys(CLASSIFIED).length} classified editor codes, ${locales.size} locales)`
);
