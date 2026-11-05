'use strict';
const fs = require('node:fs'),
	path = require('node:path'),
	crypto = require('node:crypto'),
	assert = require('node:assert/strict');
const root = path.resolve(process.argv[2] || process.env.SOURCE_ROOT || '.');
const base = 'static/ergopti_plus/';
const owners = [
	'windows/infra/webview_script.ahk',
	'windows/infra/webview_utils.ahk',
	'windows/infra/webview_browser_warmup.ahk',
	'windows/adapters/webview_profiles.ahk',
	'windows/ui/personal_toml_editor_webview.ahk',
	'windows/ui/hotstrings_config_window/webview.ahk',
	'windows/ui/hotstrings_config_window/hcw_mutations.ahk',
	'windows/ui/action_picker_webview.ahk',
	'windows/ui/action_picker/init.ahk',
	'windows/infra/hotstrings/personal_toml_io.ahk'
];
const pages = ['hotstring_editor', 'hotstrings_config_window', 'action_picker'];
const inventory = owners.map((p) => {
	const bytes = fs.readFileSync(path.join(root, base, p));
	assert(bytes.length > 0);
	return { path: base + p, sha256: crypto.createHash('sha256').update(bytes).digest('hex') };
});
const actions = pages.map((page) => {
	const src = fs.readFileSync(path.join(root, base, '_shared/ui', page, 'script.js'), 'utf8');
	return {
		page,
		actions: [
			...new Set([...src.matchAll(/(?:toLua\(\s*|action:\s*)['"]([a-z_]+)['"]/g)].map((m) => m[1]))
		].sort()
	};
});
assert(actions.every((x) => x.actions.length >= 3));
console.log(
	JSON.stringify(
		{
			sourceRoot: root,
			inventory,
			actions,
			note: 'source inventory, not execution of Windows owners'
		},
		null,
		2
	)
);
