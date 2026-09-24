// tools/test/test-shared-ui-translators-defined.cjs

/**
 * ==============================================================================
 * MODULE: Shared Pages Only Call Translators That Exist
 * DESCRIPTION:
 * The numeric prompt translated its refusals through window.i18n_get, which no
 * script defines: behind a `window.i18n_get ? … : ''` guard every refusal became
 * an empty, hidden message, and the window seemed to ignore the click. The
 * guard turned a missing function into silence. This gate lists every
 * translation-looking window function a shared page reads and requires one of
 * the shared scripts to define it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const UI_ROOT = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');

/** Every .js and .html file under the shared UI tree. */
function sources(dir) {
	const out = [];
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name !== 'node_modules' && entry.name !== 'vendor') out.push(...sources(full));
		} else if (/\.(js|html)$/.test(entry.name)) {
			out.push(full);
		}
	}
	return out;
}

// Line and block comments removed: prose that names a function is not a call.
const files = sources(UI_ROOT).map((file) => ({
	file,
	text: fs.readFileSync(file, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, ''),
}));
const defined = new Set();
for (const { text } of files) {
	for (const match of text.matchAll(/window\.([A-Za-z_$][\w$]*)\s*=/g)) defined.add(match[1]);
	for (const match of text.matchAll(/window\[['"]([A-Za-z_$][\w$]*)['"]\]\s*=/g)) defined.add(match[1]);
}

const missing = [];
for (const { file, text } of files) {
	// Calls only: _i18n_locale and __i18n_base are values the host injects.
	for (const match of text.matchAll(/window\.([A-Za-z_$][\w$]*)\s*\(/g)) {
		const name = match[1];
		if (!/i18n|translat|^_t$/i.test(name)) continue;
		if (!defined.has(name)) missing.push(`${path.relative(UI_ROOT, file)}: window.${name}`);
	}
}

const unique = [...new Set(missing)];
if (unique.length) {
	console.error('\x1b[31m[ERROR] shared pages read translators that nothing defines:\x1b[0m');
	for (const line of unique) console.error(`  - ${line}`);
	process.exit(1);
}
console.log('\x1b[32m[OK] every translator a shared page reads is defined.\x1b[0m');
