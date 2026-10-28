// tools/codegen/codegen-linux-shell-messages.cjs

/**
 * ==============================================================================
 * MODULE: Linux Shell Message Catalogues Codegen
 * DESCRIPTION:
 * Emits one key=value catalogue per locale for the sentences the Linux shell
 * scripts print (install.sh, uninstall.sh, the launcher and the install/
 * helpers), read by linux/install/messages.sh.
 *
 * WHY A GENERATED CATALOGUE:
 * The scripts run before LuaJIT, jq or Python can be assumed (install.sh is
 * what installs them), so they cannot read the JSON catalogues. The sentences
 * still live in _shared/data/locales/*.json under `linux_shell.`, translated in
 * all 21 locales like every other string, and this generator projects them to a
 * format a bash `read` loop parses.
 *
 * FORMAT:
 * `#` comment lines, then one `name=value` line per message, sorted, with the
 * `linux_shell.` prefix removed. Placeholders are {1}..{9}, filled by
 * ergopti_msg in argument order.
 *
 * FAIL FAST:
 * A value with a newline cannot be one catalogue line, and a translation whose
 * placeholders differ from English would drop or invent an argument: both stop
 * the generator before anything is written.
 *
 * USAGE:  node tools/codegen/codegen-linux-shell-messages.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const LOCALES_DIR = path.join(SP, '_shared', 'data', 'locales');
const OUTPUT_DIR = path.join(SP, 'linux', '_generated', 'shell_messages');
const PREFIX = 'linux_shell.';
const SOURCE_LOCALE = 'en';
const PLACEHOLDER = /\{([1-9])\}/g;

const order = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'data', 'locale_order.json'), 'utf8')
).order;

/**
 * The sorted placeholder numbers of a message.
 * @param {string} text Message value.
 * @returns {string} Such as "1,2".
 */
function placeholders(text) {
	return [...new Set([...text.matchAll(PLACEHOLDER)].map((m) => m[1]))].sort().join(',');
}

/**
 * The shell messages of one locale, validated against the source locale.
 * @param {string} code Locale code.
 * @param {Object<string,string>|null} source The source locale's messages, null for the source itself.
 * @returns {Object<string,string>} name -> value.
 */
function messagesOf(code, source) {
	const catalogue = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, `${code}.json`), 'utf8'));
	const out = {};
	for (const [key, value] of Object.entries(catalogue)) {
		if (!key.startsWith(PREFIX)) continue;
		const name = key.slice(PREFIX.length);
		if (typeof value !== 'string' || value === '' || /[\r\n]/.test(value))
			throw new Error(`${code}.json ${key}: a shell message is one non-empty line`);
		if (source && placeholders(value) !== placeholders(source[name]))
			throw new Error(`${code}.json ${key}: placeholders differ from ${SOURCE_LOCALE}.json`);
		out[name] = value;
	}
	if (source) {
		const missing = Object.keys(source).filter((name) => !(name in out));
		if (missing.length > 0)
			throw new Error(`${code}.json lacks ${missing.map((n) => PREFIX + n).join(', ')}`);
	}
	return out;
}

const source = messagesOf(SOURCE_LOCALE, null);
if (Object.keys(source).length === 0)
	throw new Error(`${SOURCE_LOCALE}.json has no ${PREFIX} message`);
const catalogues = order.map((code) => [
	code,
	messagesOf(code, code === SOURCE_LOCALE ? null : source)
]);

fs.mkdirSync(OUTPUT_DIR, { recursive: true });
for (const [code, messages] of catalogues) {
	const lines = [
		`# linux/_generated/shell_messages/${code}.msg`,
		`# AUTO-GENERATED from _shared/data/locales/${code}.json (${PREFIX}* keys).`,
		'# DO NOT EDIT BY HAND: run `npm run codegen:linux-shell-messages` to refresh.',
		...Object.keys(messages)
			.sort()
			.map((name) => `${name}=${messages[name]}`)
	];
	fs.writeFileSync(path.join(OUTPUT_DIR, `${code}.msg`), lines.join('\n') + '\n');
}
console.log(`[OK] ${catalogues.length} Linux shell message catalogue(s) written.`);
