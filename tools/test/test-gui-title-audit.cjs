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
const titles = require('../codegen/codegen-window-titles.cjs');
const audit = path.resolve(__dirname, '../lint/audit-gui-titles.cjs');
const repository = path.resolve(__dirname, '../..');
const sharedManifest = JSON.parse(fs.readFileSync(path.join(repository, titles.SOURCE), 'utf8'));
const localeDirectory = path.join(repository, 'static/ergopti_plus/_shared/data/locales');
const localeNames = fs.readdirSync(localeDirectory).filter((name) => name.endsWith('.json'));
assert.equal(localeNames.length, 21, 'every shipped locale participates in the title policy');
for (const locale of localeNames) {
	const strings = JSON.parse(fs.readFileSync(path.join(localeDirectory, locale), 'utf8'));
	for (const [app, entry] of Object.entries(sharedManifest.apps)) {
		assert.equal(
			typeof strings[entry.title_key],
			'string',
			`${locale}: ${app} has its title translation`
		);
		assert.equal(
			/^\s*Ergopti(?:Plus)?\b/.test(strings[entry.title_key]),
			false,
			`${locale}: ${app} passes a bare title to the shared policy`
		);
	}
}
/** Verifies the real folder owner remains reachable without native calls in infra. */
function assertFolderAdapterOwnership(sources) {
	const code = (name) => sources[name].replace(/^\s*;.*$/gm, '');
	assert.match(
		code('adapter'),
		/class\s+_Ui_FolderNative\s*\{/,
		'the adapter owns the native ABI class'
	);
	assert.doesNotMatch(
		code('infra'),
		/class\s+_Ui_FolderNative\s*\{/,
		'infra cannot duplicate the native ABI class'
	);
	assert.doesNotMatch(
		code('infra'),
		/\b(?:DllCall|CallbackCreate|CallbackFree)\s*\(/,
		'native calls belong to the adapter rather than folder orchestration'
	);
	for (const method of [
		'SHBrowseForFolderW',
		'GetWindowThreadProcessId',
		'SetWindowTextW',
		'CoTaskMemFree'
	])
		assert.ok(
			code('adapter').includes(method),
			`the adapter retains the actual ${method} primitive`
		);
	assert.match(
		code('infra'),
		/Native\s*:=\s*_Ui_FolderNative\b/,
		'the actual folder owner uses the native adapter'
	);
	assert.match(
		code('infra'),
		/^#Include %A_LineFile%\\\.\.\\\.\.\\adapters\\native_folder_picker\.ahk$/m,
		'the folder owner includes its adapter for both production and private children'
	);
	assert.match(
		code('dialogs'),
		/^#Include %A_LineFile%\\\.\.\\native_folder_picker\.ahk$/m,
		'the caption delegate includes the actual folder orchestration'
	);
	assert.match(
		code('entry'),
		/^#Include infra\/native_dialogs\.ahk$/m,
		'the production entry reaches the same caption owner'
	);
	assert.match(
		code('runner'),
		/^#Include \.\.\/infra\/native_dialogs\.ahk$/m,
		'the headless runner reaches the same caption owner'
	);
}
const folderOwnerSources = Object.fromEntries(
	Object.entries({
		adapter: 'adapters/native_folder_picker.ahk',
		infra: 'infra/native_folder_picker.ahk',
		dialogs: 'infra/native_dialogs.ahk',
		entry: 'ErgoptiPlus.ahk',
		runner: 'tests/run_all.ahk'
	}).map(([name, relative]) => [
		name,
		fs
			.readFileSync(path.join(repository, 'static/ergopti_plus/windows', relative), 'utf8')
			.replace(/^\uFEFF/, '')
	])
);
assertFolderAdapterOwnership(folderOwnerSources);
const folderMutations = [
	{
		...folderOwnerSources,
		infra: folderOwnerSources.infra + '\nDllCall("Shell32\\SHBrowseForFolderW")\n'
	},
	{ ...folderOwnerSources, infra: folderOwnerSources.infra + '\nCallbackCreate(Callback)\n' },
	{ ...folderOwnerSources, infra: folderOwnerSources.infra + '\nclass _Ui_FolderNative {}\n' },
	{
		...folderOwnerSources,
		infra: folderOwnerSources.infra.replace(/^#Include.*native_folder_picker\.ahk$/m, '')
	},
	{
		...folderOwnerSources,
		entry: folderOwnerSources.entry.replace(/^#Include infra\/native_dialogs\.ahk$/m, '')
	},
	{
		...folderOwnerSources,
		runner: folderOwnerSources.runner.replace(/^#Include \.\.\/infra\/native_dialogs\.ahk$/m, '')
	}
];
for (const mutant of folderMutations)
	assert.throws(
		() => assertFolderAdapterOwnership(mutant),
		assert.AssertionError,
		'native ownership and both real include graphs must reject each independent bypass'
	);
console.log(
	`Native folder adapter provenance mutations: ${folderMutations.length}/${folderMutations.length} passed.`
);

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-title-audit-'));
const sourcePath = (platform) =>
	`static/ergopti_plus/${platform}/ui/error_dialog/init.${platform === 'windows' ? 'ahk' : 'lua'}`;
function put(relative, content) {
	const target = path.join(root, relative);
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.writeFileSync(target, content);
}
const cases = [
	[
		'windows',
		'FileSelect(33, Root, "Tools", "Owned files (*.txt)")',
		1,
		'raw native file picker cannot bypass policy'
	],
	[
		'windows',
		'FileSelect("M33", Root, "ErgoptiPlus — Tools")',
		1,
		'prebranded file picker still bypasses policy'
	],
	[
		'windows',
		'Ui_FileSelect(33, "ErgoptiPlus path", "Tools", "ErgoptiPlus files (*.txt)")',
		0,
		'only the third file picker argument is a caption'
	],
	[
		'windows',
		'Ui_FileSelect(33, Root, "ErgoptiPlus — Tools")',
		1,
		'file picker caption cannot be branded twice'
	],
	[
		'windows',
		'Ui_FileSelect(33, Root, t("editor.personal_info.window_title"))',
		1,
		'translated file picker caption cannot retain stale branding'
	],
	['windows', 'Ui_FileSelect(33, Root)', 0, 'omitted file picker caption belongs to shared policy'],
	[
		'windows',
		'Ui_FileSelect(Options := "", RootDir := "", Title := "", Filter := "") {\nreturn FileSelect(Options, RootDir, WindowTitle(Title), Filter)\n}',
		0,
		'actual file picker delegate owns the third argument',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_FileSelect(Options, RootDir, Title, Filter) {\nreturn FileSelect(Options, RootDir, Title, Filter)\n}',
		1,
		'file picker owner cannot drop policy',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_FileSelect(Options, RootDir, Title, Filter) {\nreturn FileSelect(Options, WindowTitle(Title), Title, Filter)\n}',
		1,
		'file picker policy on the root path does not own the caption',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Other(Options, RootDir, Title, Filter) {\nreturn FileSelect(Options, RootDir, WindowTitle(Title), Filter)\n}',
		1,
		'another file picker function cannot duplicate the native owner',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	['windows', 'MsgBox("Body", "Tools")', 1, 'raw message box has no caption owner'],
	[
		'windows',
		'MsgBox("Body", "ErgoptiPlus — Tools")',
		1,
		'prebranded message box still bypasses policy'
	],
	[
		'windows',
		'MsgBox("Body", DynamicTitle, "YesNo")',
		1,
		'dynamic message box cannot bypass policy'
	],
	[
		'windows',
		'MsgBox(Body := "Body", DynamicTitle, "YesNo")',
		1,
		'argument assignment cannot disguise a raw native call as a definition'
	],
	[
		'windows',
		'if MsgBox("Body", "Tools", "YesNo") {\nreturn\n}',
		1,
		'conditional raw call is not a function declaration'
	],
	[
		'windows',
		'InputBox("Body", "Tools", "Password", "Secret")',
		1,
		'raw native input bypass is blocking'
	],
	[
		'windows',
		'Ui_MsgBox("ErgoptiPlus appears in this body", "Tools", "Icon!")',
		0,
		'only caption arguments are branded'
	],
	[
		'windows',
		'Ui_MsgBox("Body", "ErgoptiPlus — Tools")',
		1,
		'message caption cannot be branded twice'
	],
	[
		'windows',
		'if Ui_MsgBox("Body", "ErgoptiPlus — Tools", "YesNo") {\nreturn\n}',
		1,
		'conditional wrapper caption is still checked'
	],
	[
		'windows',
		'Ui_InputBox("Body", t("editor.personal_info.window_title"))',
		1,
		'one translated prebranded input caption is blocking'
	],
	[
		'windows',
		'Title := "ErgoptiPlus — Tools"\nUi_InputBox("Body", Title)',
		1,
		'input caption aliases cannot bypass double-prefix guard'
	],
	[
		'windows',
		'Ui_MsgBox("Body")\nUi_InputBox("Body", "")',
		0,
		'empty captions belong to shared product policy'
	],
	[
		'windows',
		'Ui_MsgBox(Text := "", Title := "", Options := "") {\nreturn MsgBox(Text, WindowTitle(Title), Options)\n}',
		0,
		'actual native message delegate owns its caption',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_InputBox(Prompt := "", Title := "", Options := "", Default := "") {\nreturn InputBox(Prompt, WindowTitle(Title), Options, Default)\n}',
		0,
		'actual native input delegate owns its caption',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_MsgBox(Text, Title, Options) {\nreturn MsgBox(Text, Title, Options)\n}',
		1,
		'central delegate itself cannot drop policy',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Other(Text, Title, Options) {\nreturn MsgBox(Text, WindowTitle(Title), Options)\n}',
		1,
		'other function in owner file cannot bypass central delegate',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_MsgBox(Text, Title, Options) {\nreturn MsgBox(Text, WindowTitle(Title), Options)\n}',
		1,
		'copying a delegate to another file cannot create another caption owner'
	],
	[
		'windows',
		'Bundle_Init() {\n' + 'MsgBox("Fatal", "ErgoptiPlus")\n'.repeat(6) + '}',
		1,
		'all six former bootstrap exceptions now require shared policy',
		'static/ergopti_plus/windows/infra/bundle.ahk'
	],
	[
		'windows',
		'Bundle_Init() {\n' + 'MsgBox("Fatal", "ErgoptiPlus")\n'.repeat(7) + '}',
		1,
		'additional bootstrap native calls cannot bypass shared policy',
		'static/ergopti_plus/windows/infra/bundle.ahk'
	],
	[
		'windows',
		'ErgoptiGlobalErrorHandler(Exc, Mode) {\nMsgBox("Fatal", "ErgoptiPlus — erreur de démarrage")\n}',
		1,
		'the original startup error caption no longer bypasses policy',
		'static/ergopti_plus/windows/infra/error_net.ahk'
	],
	[
		'windows',
		'Bundle_Init() {\n' + 'Ui_MsgBox("Fatal", "")\n'.repeat(6) + '}',
		0,
		'all six bundle startup calls use the shared owner',
		'static/ergopti_plus/windows/infra/bundle.ahk'
	],
	[
		'windows',
		'ErgoptiGlobalErrorHandler(Exc, Mode) {\nUi_MsgBox("Fatal", "erreur de démarrage")\n}',
		0,
		'the startup error supplies a brandless caption',
		'static/ergopti_plus/windows/infra/error_net.ahk'
	],
	[
		'windows',
		'Other() {\nMsgBox("Fatal", "ErgoptiPlus")\n}',
		1,
		'bootstrap file cannot authorize another native owner',
		'static/ergopti_plus/windows/infra/error_net.ahk'
	],
	[
		'windows',
		'g := Gui("+Resize", t("common.error_title"))',
		1,
		'translated raw Gui bypass is blocking'
	],
	['windows', 'g := Gui("+Resize", DynamicTitle)', 1, 'dynamic raw Gui bypass is blocking'],
	[
		'windows',
		'g := Gui("+Resize", "ErgoptiPlus — Tools")',
		1,
		'branded raw Gui still bypasses shared policy'
	],
	[
		'windows',
		'g := Gui("-Caption +AlwaysOnTop", "Overlay")',
		0,
		'captionless overlays retain native options'
	],
	['windows', 'return Gui(Options, WindowTitle(Name))', 0, 'native factory composes its caption'],
	[
		'windows',
		'First() {\nTitle := "ErgoptiPlus — Tools"\n}\nSecond(Title) {\ng := Gui_Create("", Title)\n}',
		0,
		'do not borrow aliases across AHK functions'
	],
	[
		'macos',
		'local function first()\n local title = "ErgoptiPlus — Tools"\nend\nlocal function second(title)\n ui_builder.window_title(title)\nend',
		0,
		'do not borrow aliases across Lua functions'
	],
	[
		'windows',
		'return Gui_Create("+Resize +AlwaysOnTop +MinSize440x320", "ErgoptiPlus — " . t("common.error_title"))',
		1,
		'real error dialog double prefix'
	],
	[
		'windows',
		'return Gui_Create("+Resize +AlwaysOnTop +MinSize440x320", t("common.error_title"))',
		0,
		'removing the prefix repairs the same call'
	],
	['windows', 'g := Gui("+Resize", "Unbranded")', 1, 'raw Gui still needs a prefix'],
	[
		'windows',
		'; Gui_Create("", "ErgoptiPlus — comment")\ng := Gui_Create("", "Tools; utilities")',
		0,
		'comments and semicolons inside strings'
	],
	[
		'windows',
		'Title := "ErgoptiPlus — Tools"\ng := Gui_Create("", Title)',
		1,
		'local literal alias'
	],
	['macos', 'view:windowTitle("Unbranded")', 1, 'raw macOS window'],
	['macos', 'ui_builder.window_title("ErgoptiPlus — Tools")', 1, 'macOS composer'],
	['macos', 'ui_builder.set_window_title(view, "ErgoptiPlus — Tools")', 1, 'macOS retitle'],
	[
		'macos',
		'ui_builder.show_webview({ frame = frame(), title = i18n.get("editor.personal_info.window_title"), on_close = function() close() end })',
		1,
		'real translated personal-info window'
	],
	[
		'macos',
		'ui_builder.show_webview({title = i18n.get("common.error_title")})',
		0,
		'brandless translated options'
	],
	['macos', 'ui_builder.window_title(ui_builder.window_title("Tools"))', 1, 'nested composers'],
	['linux', 'manager.set_title(APP_NAME, "ErgoptiPlus — Tools")', 1, 'Linux retitle'],
	[
		'linux',
		'M.window_title(i18n.get("editor.personal_info.window_title"))',
		1,
		'Linux localized composer'
	],
	['linux', 'window:set_title("Ergopti — Tools")', 0, 'native Gtk title already branded'],
	['linux', 'window:set_title("Tools")', 1, 'native Gtk title missing brand'],
	[
		'linux',
		'--[[ manager.set_title(APP, "Ergopti — comment") ]]\nmanager.set_title(APP, i18n.get("common.error_title"))',
		0,
		'Lua long comments'
	],
	[
		'windows',
		'DirSelect("*initial", 3, "Select configuration folder")',
		1,
		'folder native body text cannot establish caption ownership'
	],
	[
		'windows',
		'DirSelect("*initial", 3, "ErgoptiPlus \u2014 Select configuration folder")',
		1,
		'branding the explanatory body cannot establish native chrome'
	],
	[
		'windows',
		'Ui_DirSelect("*initial", 3, "ErgoptiPlus \u2014 explanatory body", "Configuration folder", 0)',
		0,
		'folder body remains independent from the shared native caption'
	],
	[
		'windows',
		'Ui_DirSelect("*initial", 3, "Select folder", "ErgoptiPlus \u2014 Configuration folder", 0)',
		1,
		'folder caption must be brandless before composition'
	],
	[
		'windows',
		'Ui_DirSelect("*initial", 3, "Select folder", t("editor.personal_info.window_title"), 0)',
		1,
		'translated folder captions cannot carry a stale brand'
	],
	[
		'windows',
		'Ui_DirSelect(RootDir, Options, Prompt, Title, OwnerHwnd) {\nreturn _Ui_FolderSelect(RootDir, Options, Prompt, WindowTitle(Title), OwnerHwnd)\n}',
		0,
		'folder wrapper owns exactly the fourth caption argument',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_DirSelect(RootDir, Options, Prompt, Title, OwnerHwnd) {\nreturn _Ui_FolderSelect(RootDir, Options, WindowTitle(Prompt), Title, OwnerHwnd)\n}',
		1,
		'composing the folder body cannot substitute for caption policy',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_DirSelect(RootDir, Options, Prompt, Title, OwnerHwnd) {\nreturn DirSelect(RootDir, Options, WindowTitle(Title))\n}',
		1,
		'the builtin folder dialog does not expose a chrome caption argument',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Other(Title) {\nreturn _Ui_FolderSelect("", 3, "Select folder", WindowTitle(Title), 0)\n}',
		1,
		'a differently owned native folder call cannot bypass the caption wrapper',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_DirSelect("*initial", 3, "Select folder", WindowTitle("Configuration folder"), 0)',
		1,
		'folder captions compose only once'
	]
];
try {
	put('tools/lint/audit-gui-titles.cjs', fs.readFileSync(audit));
	for (const platform of ['windows', 'macos', 'linux']) put(sourcePath(platform), '');
	put(
		'static/ergopti_plus/_shared/data/locales/en.json',
		JSON.stringify({
			'common.error_title': 'Error',
			'editor.personal_info.window_title': 'Personal information'
		})
	);
	put(
		'static/ergopti_plus/_shared/data/locales/fr.json',
		JSON.stringify({
			'common.error_title': 'Erreur',
			'editor.personal_info.window_title': 'ErgoptiPlus — Informations personnelles'
		})
	);
	for (const [platform, source, expected, label, override] of cases) {
		for (const relative of ['infra/native_dialogs.ahk', 'infra/bundle.ahk', 'infra/error_net.ahk'])
			fs.rmSync(path.join(root, 'static/ergopti_plus/windows', relative), { force: true });
		for (const other of ['windows', 'macos', 'linux'])
			put(sourcePath(other), other === platform && !override ? source : '');
		if (override) put(override, source);
		const result = spawnSync(
			process.execPath,
			[path.join(root, 'tools/lint/audit-gui-titles.cjs')],
			{ encoding: 'utf8' }
		);
		assert.equal(result.error, undefined, label);
		assert.equal(result.status, expected, `${label}\n${result.stdout}\n${result.stderr}`);
		if (expected)
			assert.match(
				result.stderr,
				new RegExp(
					(override || sourcePath(platform)).replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ':\\d+'
				),
				'failure identifies the actual source site'
			);
	}
	// Generate isolated artifacts from policies that change or remove branding.
	// Never rewrite the committed generated files to test customization.
	for (const policy of [
		{ prefix: 'ErgoptiPlus', separator: ' — ' },
		{ prefix: '', separator: ' — ' },
		{ prefix: 'Other product', separator: ': ' },
		{ prefix: 'Quoted "product" `name`', separator: '' },
		{ prefix: 'Other ; product', separator: ' ; ' },
		{ prefix: 'Émoji 😀', separator: ' / ' },
		{ prefix: 'Literal \\(1 + 1)', separator: ' / ' }
	]) {
		put(titles.SOURCE, JSON.stringify({ window_title: policy, apps: {} }));
		titles.main(root);
		const lua = fs.readFileSync(path.join(root, titles.LUA_OUTPUT), 'utf8');
		const ahk = fs.readFileSync(path.join(root, titles.AHK_OUTPUT), 'utf8');
		const swift = fs.readFileSync(path.join(root, titles.SWIFT_OUTPUT), 'utf8');
		assert.ok(swift.includes('let prefix = ' + JSON.stringify(policy.prefix)));
		assert.ok(swift.includes('let separator = ' + JSON.stringify(policy.separator)));
		assert.match(swift, /guard !prefix.isEmpty else \{ return label \}/);
		assert.ok(lua.includes('local PREFIX = ' + JSON.stringify(policy.prefix)));
		assert.ok(ahk.startsWith('\uFEFF'), 'AHK generated titles retain their UTF-8 BOM');
		assert.equal(/[\r]/.test(lua + ahk + swift), false, 'all generated hosts retain LF');
		assert.match(
			lua,
			/if PREFIX == "" then return label end/,
			'an empty policy prefix leaves the translated label bare'
		);
		assert.match(
			ahk,
			/if Prefix == ""\n\t\treturn Label/,
			'Windows removes its separator when the prefix is empty'
		);
		assert.ok(
			ahk.includes(
				'Prefix := "' +
					policy.prefix.replaceAll('`', '``').replaceAll('"', '`"').replaceAll(';', '`;') +
					'"'
			)
		);
		assert.ok(
			ahk.includes(
				'Separator := "' +
					policy.separator.replaceAll('`', '``').replaceAll('"', '`"').replaceAll(';', '`;') +
					'"'
			)
		);
	}
	for (const policy of [
		undefined,
		{},
		{ prefix: 1, separator: '' },
		{ prefix: '', separator: '\n' },
		{ prefix: '\u0001', separator: '' },
		{ prefix: '', separator: '\t' },
		{ prefix: '\uD800', separator: '' },
		{ prefix: '', separator: '\uDC00' },
		{ prefix: '\u2028', separator: '' },
		{ prefix: '', separator: '\u2029' }
	])
		assert.throws(
			() => titles.render(policy),
			/window_title|one line/,
			'invalid shared policies refuse generation'
		);
	console.log(`GUI title audit mutations: ${cases.length}/${cases.length} passed.`);
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}
