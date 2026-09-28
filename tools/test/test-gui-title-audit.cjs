// tools/test/test-gui-title-audit.cjs

/**
 * Exercises the title guard through its real CLI in private fixture repositories.
 * The mutations cover raw windows, branded wrapper inputs and translated titles.
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const audit = path.resolve(__dirname, '../lint/audit-gui-titles.cjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-title-audit-'));
const sourcePath = (platform) => `static/ergopti_plus/${platform}/ui/error_dialog/init.${platform === 'windows' ? 'ahk' : 'lua'}`;
function put(relative, content) {
	const target = path.join(root, relative);
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.writeFileSync(target, content);
}
const cases = [
	['windows', 'First() {\nTitle := "ErgoptiPlus — Tools"\n}\nSecond(Title) {\ng := Gui_Create("", Title)\n}', 0, 'do not borrow aliases across AHK functions'],
	['macos', 'local function first()\n local title = "ErgoptiPlus — Tools"\nend\nlocal function second(title)\n ui_builder.window_title(title)\nend', 0, 'do not borrow aliases across Lua functions'],
	['windows', 'return Gui_Create("+Resize +AlwaysOnTop +MinSize440x320", "ErgoptiPlus — " . t("common.error_title"))', 1, 'real error dialog double prefix'],
	['windows', 'return Gui_Create("+Resize +AlwaysOnTop +MinSize440x320", t("common.error_title"))', 0, 'removing the prefix repairs the same call'],
	['windows', 'g := Gui("+Resize", "Unbranded")', 1, 'raw Gui still needs a prefix'],
	['windows', '; Gui_Create("", "ErgoptiPlus — comment")\ng := Gui_Create("", "Tools; utilities")', 0, 'comments and semicolons inside strings'],
	['windows', 'Title := "ErgoptiPlus — Tools"\ng := Gui_Create("", Title)', 1, 'local literal alias'],
	['macos', 'view:windowTitle("Unbranded")', 1, 'raw macOS window'],
	['macos', 'ui_builder.window_title("ErgoptiPlus — Tools")', 1, 'macOS composer'],
	['macos', 'ui_builder.set_window_title(view, "ErgoptiPlus — Tools")', 1, 'macOS retitle'],
	['macos', 'ui_builder.show_webview({ frame = frame(), title = i18n.get("editor.personal_info.window_title"), on_close = function() close() end })', 1, 'real translated personal-info window'],
	['macos', 'ui_builder.show_webview({title = i18n.get("common.error_title")})', 0, 'brandless translated options'],
	['macos', 'ui_builder.window_title(ui_builder.window_title("Tools"))', 1, 'nested composers'],
	['linux', 'manager.set_title(APP_NAME, "ErgoptiPlus — Tools")', 1, 'Linux retitle'],
	['linux', 'M.window_title(i18n.get("editor.personal_info.window_title"))', 1, 'Linux localized composer'],
	['linux', 'window:set_title("Ergopti — Tools")', 0, 'native Gtk title already branded'],
	['linux', 'window:set_title("Tools")', 0, 'native Gtk title missing brand'],
	['linux', '--[[ manager.set_title(APP, "Ergopti — comment") ]]\nmanager.set_title(APP, i18n.get("common.error_title"))', 0, 'Lua long comments'],
];
try {
	put('tools/lint/audit-gui-titles.cjs', fs.readFileSync(audit));
	for (const platform of ['windows', 'macos', 'linux']) put(sourcePath(platform), '');
	put('static/ergopti_plus/_shared/data/locales/en.json', JSON.stringify({ 'common.error_title': 'Error', 'editor.personal_info.window_title': 'Personal information' }));
	put('static/ergopti_plus/_shared/data/locales/fr.json', JSON.stringify({ 'common.error_title': 'Erreur', 'editor.personal_info.window_title': 'ErgoptiPlus — Informations personnelles' }));
	for (const [platform, source, expected, label] of cases) {
		for (const other of ['windows', 'macos', 'linux']) put(sourcePath(other), other === platform ? source : '');
		const result = spawnSync(process.execPath, [path.join(root, 'tools/lint/audit-gui-titles.cjs')], { encoding: 'utf8' });
		assert.equal(result.error, undefined, label);
		assert.equal(result.status, expected, `${label}\n${result.stdout}\n${result.stderr}`);
		if (expected) assert.match(result.stderr, /error_dialog\/init\.(ahk|lua):\d+/, 'failure identifies the actual source site');
	}
	console.log(`GUI title audit mutations: ${cases.length}/${cases.length} passed.`);
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}
