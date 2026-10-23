// tools/test/test-audit-translations-scope.cjs

/**
 * ==============================================================================
 * MODULE: Translation Audit Scope Guard
 * DESCRIPTION:
 * Proves that `tools/lint/audit-translations.cjs` reads every driver and the
 * shared tree, recognises the accessors each of them uses, and keeps its
 * unused-key baseline honest.
 *
 * ROOT CAUSE ENCODED:
 * The audit scanned the Windows and macOS drivers only. A missing key in the
 * Linux driver or in a shared webview rendered as a raw key name in the field
 * and failed no gate, and nothing looked for keys that no source used any more.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const audit = require('../lint/audit-translations.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const drivers = path.join(ROOT, 'static', 'ergopti_plus');

// 1. Every driver and the shared tree are in the scan plan.
const plan = audit.scanPlan().map((entry) => path.relative(drivers, entry.file).split(path.sep)[0]);
for (const root of ['windows', 'macos', 'linux', '_shared']) {
	assert(plan.includes(root), `the audit must scan ${root}`);
}
const sharedExtensions = new Set(
	audit
		.scanPlan()
		.filter((entry) => path.relative(drivers, entry.file).startsWith('_shared'))
		.map((entry) => path.extname(entry.file))
);
for (const extension of ['.lua', '.js', '.html']) {
	assert(sharedExtensions.has(extension), `the shared scan must read ${extension} files`);
}

// 2. The Linux and shared accessors are recognised, a dynamic family is not a key.
const linux = audit.extractKeys(
	'local a = i18n_safe("menu.alpha")\nlocal b = tr("menu.beta", x)\n' +
		'local c = I18n.get("menu.gamma")\nlocal d = t("menu.prefix." .. name)\n-- tr("menu.commented")\n',
	'.lua',
	true
);
assert.deepEqual(linux, ['menu.alpha', 'menu.beta', 'menu.gamma']);
assert.deepEqual(
	audit.extractKeys('<p data-i18n="page.title" data-i18n-title="page.hint"></p>', '.html', true),
	['page.title', 'page.hint']
);
assert.deepEqual(audit.extractKeys('const label = _t("ui.label"); // _t("ui.old")', '.js', true), [
	'ui.label'
]);
// The Windows and macOS shapes are unchanged.
assert.deepEqual(audit.extractKeys('Label := t("menu.win")', '.ahk', false), ['menu.win']);

// 3. A key only a macOS helper application names is used, not unused.
const available = audit.loadAvailableKeys();
const unused = new Set(audit.findUnusedKeys(available));
assert(!unused.has('apps.cloner.btn_back'), 'AppleScript usage must keep a key alive');

// 4. The baseline is sorted, duplicate-free and names real keys.
const baseline = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'tools', 'lint', 'audit-translations-unused-baseline.json'),
		'utf8'
	)
);
assert.deepEqual(baseline, [...new Set(baseline)].sort(), 'the baseline stays sorted and unique');
for (const key of baseline) assert(available.has(key), `baseline key ${key} no longer exists`);

console.log('audit-translations scope: ok');
