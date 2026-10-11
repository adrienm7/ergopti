// Independent actual physical native-caption binding withdrawal and exact repair controls.
'use strict';
const assert = require('node:assert/strict');
const {
	declaredLinuxTopLevelPublication,
	nativeLinuxAiParentPublication
} = require('../../lib/menu-native-llm-parent-binding.cjs');
module.exports = function (sources, manifest) {
	const file = 'linux/ui/menu/menu_builder.lua',
		source = sources[file];
	const ports = [
		['complete native root', (body) => declaredLinuxTopLevelPublication(body)],
		...['llm', 'agent'].map((kind) => [
			kind,
			(body) =>
				nativeLinuxAiParentPublication({ ...sources, [file]: body }, manifest, kind, 'linux')
		])
	];
	const imported = 'local NativePresentation = require("infra.native_presentation")';
	const captured =
		'local PrepareNativePresentation, NativePresentationTitle = NativePresentation.prepare, NativePresentation.title';
	const cases = [
		[
			'local function _build_layouts(ctx)',
			'local function _foreign_layouts(ctx)',
			'notification cannot borrow a foreign enclosing producer'
		],
		[imported, '', 'actual import withdrawal'],
		[
			imported,
			'local NativePresentation = require("foreign.native_presentation")',
			'foreign import owner'
		],
		[imported, imported + '\n' + imported, 'duplicate physical import'],
		[imported, 'do ' + imported + ' end', 'scoped import cannot supply root authority'],
		[captured, '', 'actual factory/title capture withdrawal'],
		[captured, captured + '\n' + captured, 'duplicate factory/title capture'],
		[
			captured,
			captured.replace('NativePresentation.prepare', 'Foreign.prepare'),
			'foreign factory capture'
		],
		[
			captured,
			captured.replace('NativePresentation.title', 'Foreign.title'),
			'foreign title capture'
		],
		[
			captured,
			captured.replace(
				'NativePresentation.prepare, NativePresentation.title',
				'NativePresentation.title, NativePresentation.prepare'
			),
			'swapped factory/title roles'
		],
		[captured, 'do ' + captured + ' end', 'scoped capture cannot own genuine provider'],
		[captured, captured + '\nObserve(NativePresentation)', 'extra module observer escape'],
		[
			captured,
			captured + '\nlocal leaked = { PrepareNativePresentation }',
			'extra captured factory container escape'
		],
		[
			'local function notify(key, level)',
			'local function notify(key, level) local NativePresentationTitle = Foreign.title',
			'native receiver local shadow'
		],
		[
			'local function notify(key, level)',
			'local function notify(key, level) PrepareNativePresentation = Foreign.prepare',
			'native factory reassignment'
		],
		[
			'PrepareNativePresentation("magic_key_source_notice", "notification")',
			'PrepareNativePresentation("foreign_notice", "notification")',
			'foreign declared identity'
		],
		[
			'PrepareNativePresentation("magic_key_source_notice", "notification")',
			'PrepareNativePresentation("magic_key_source_notice", "dialog")',
			'foreign declaration kind'
		],
		[
			'local title = receipt and NativePresentationTitle(receipt) or nil',
			'local title = "invented caption"',
			'withdrawn actual current receiver'
		],
		[
			'if title == nil then return false end',
			'if false then return false end',
			'withdrawn actual title refusal'
		],
		[
			'Notifier.send(body, { title = title, level = level })',
			'Notifier.send(body, { title = "invented caption", level = level })',
			'foreign native title delivery'
		]
	];
	// The actual removal caption captures remain owned by their current native receiver.
	const removalCaptureBlock =
		'local uninstall_caption_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_caption_receiver")\nlocal uninstall_caption_i18n = rawget(separator_modules, "infra.i18n")\nlocal uninstall_caption_get = type(uninstall_caption_i18n) == "table" and rawget(uninstall_caption_i18n, "get")';
	const removalCaptureLines = removalCaptureBlock.split('\n');
	cases.push([
		removalCaptureBlock,
		[removalCaptureLines[2], removalCaptureLines[1], removalCaptureLines[0]].join('\n'),
		'captured removal getters cannot borrow future lexical declarations'
	]);
	const removalCaptures = [
		[
			'uninstall_caption_factory',
			'type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_caption_receiver")',
			'type(Foreign) == "table" and rawget(Foreign, "command_caption_receiver")'
		],
		[
			'uninstall_caption_i18n',
			'rawget(separator_modules, "infra.i18n")',
			'rawget(Foreign, "infra.i18n")'
		],
		[
			'uninstall_caption_get',
			'type(uninstall_caption_i18n) == "table" and rawget(uninstall_caption_i18n, "get")',
			'type(Foreign) == "table" and rawget(Foreign, "get")'
		]
	];
	for (const [name, value, foreign] of removalCaptures) {
		const physical = 'local ' + name + ' = ' + value;
		cases.push(
			[physical, '', name + ': physical capture withdrawal'],
			[physical, 'local ' + name + ' = ' + foreign, name + ': foreign capture'],
			[physical, physical + '\n' + name + ' = Foreign', name + ': capture reassignment'],
			[
				'local function _uninstall_command(ctx)',
				'local function _uninstall_command(ctx) local ' + name + ' = Foreign',
				name + ': receiver shadow'
			],
			[physical, physical + '\n' + physical, name + ': duplicate capture'],
			[physical, physical + '\nObserve(' + name + ')', name + ': observer escape']
		);
	}
	cases.push(
		[
			'local function uninstall_caption_facade_current()',
			'local function foreign_caption_facade_current()',
			'removal facade owner withdrawal'
		],
		[
			'local function _build_about(ctx)',
			'local function _foreign_about(ctx)',
			'removal cannot borrow a foreign About producer'
		],
		[
			'["uninstall"] = _uninstall_command(ctx),',
			'["uninstall"] = foreign_uninstall(ctx),',
			'withdrawn actual About command receiver'
		],
		[
			'["uninstall"] = _uninstall_command(ctx),',
			'["uninstall"] = function() return _uninstall_command(ctx) end,',
			'different About callback owner'
		],
		[
			'uninstall_caption_factory("about_menu", "uninstall")',
			'uninstall_caption_factory("foreign_menu", "uninstall")',
			'foreign removal frame'
		],
		[
			'local title = receive()',
			'local title = "invented title"',
			'withdrawn current removal caption receiver'
		]
	);
	// Genuine About container, context and finished subtree must transport the command.
	cases.push(
		[
			'local function _build_about(ctx)\n\tlocal root, top, section, parent, fields = about_source(ManifestMenu, "linux")\n\tif root == nil then return nil end\n\tlocal render_ctx = {}\n\tfor key, value in pairs(ctx) do render_ctx[key] = value end\n\trender_ctx.commands = {',
			'local function _build_about(ctx)\n\tlocal root, top, section, parent, fields = about_source(ManifestMenu, "linux")\n\tif root == nil then return nil end\n\tlocal render_ctx = {}\n\tfor key, value in pairs(ctx) do render_ctx[key] = value end\n\tlocal unused = {',
			'withdrawn actual About command table'
		],
		[
			'ManifestMenu.build("about_menu", "About", nil, nil, render_ctx, {',
			'ManifestMenu.build("about_menu", "About", nil, nil, foreign_ctx, {',
			'foreign About render context'
		],
		[
			'return ManifestMenu.group_row("top_level", "about", rows, render_ctx.state_getters)',
			'return ManifestMenu.group_row("top_level", "about", foreign_rows, render_ctx.state_getters)',
			'withdrawn actual finished About children'
		]
	);
	// Actual imported facade and package table must exist before dependent raw captures.
	cases.push(
		[
			'local separator_modules = package.loaded\nlocal separator_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "top_level_separator_receiver")\nlocal separator_render = type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")\nlocal separator_array = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_array")\nlocal separator_root = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_root")\nlocal header_template = type(ManifestMenu) == "table" and rawget(ManifestMenu, "template_rows")\nlocal header_command = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_row")\nlocal uninstall_caption_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_caption_receiver")\nlocal uninstall_caption_i18n = rawget(separator_modules, "infra.i18n")\nlocal uninstall_caption_get = type(uninstall_caption_i18n) == "table" and rawget(uninstall_caption_i18n, "get")',
			'local separator_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "top_level_separator_receiver")\nlocal separator_render = type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")\nlocal separator_array = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_array")\nlocal separator_root = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_root")\nlocal header_template = type(ManifestMenu) == "table" and rawget(ManifestMenu, "template_rows")\nlocal header_command = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_row")\nlocal uninstall_caption_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_caption_receiver")\nlocal uninstall_caption_i18n = rawget(separator_modules, "infra.i18n")\nlocal uninstall_caption_get = type(uninstall_caption_i18n) == "table" and rawget(uninstall_caption_i18n, "get")\nlocal separator_modules = package.loaded',
			'removal capture cannot precede the genuine package-table local'
		],
		[
			'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")\nif not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end\n\n-- The imported facade and its actual functions own every later boundary read.\nlocal separator_modules = package.loaded\nlocal separator_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "top_level_separator_receiver")\nlocal separator_render = type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")\nlocal separator_array = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_array")\nlocal separator_root = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_root")\nlocal header_template = type(ManifestMenu) == "table" and rawget(ManifestMenu, "template_rows")\nlocal header_command = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_row")\nlocal uninstall_caption_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_caption_receiver")\nlocal uninstall_caption_i18n = rawget(separator_modules, "infra.i18n")\nlocal uninstall_caption_get = type(uninstall_caption_i18n) == "table" and rawget(uninstall_caption_i18n, "get")',
			'\n-- The imported facade and its actual functions own every later boundary read.\nlocal separator_modules = package.loaded\nlocal separator_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "top_level_separator_receiver")\nlocal separator_render = type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")\nlocal separator_array = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_array")\nlocal separator_root = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_root")\nlocal header_template = type(ManifestMenu) == "table" and rawget(ManifestMenu, "template_rows")\nlocal header_command = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_row")\nlocal uninstall_caption_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_caption_receiver")\nlocal uninstall_caption_i18n = rawget(separator_modules, "infra.i18n")\nlocal uninstall_caption_get = type(uninstall_caption_i18n) == "table" and rawget(uninstall_caption_i18n, "get")\nlocal ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")\nif not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end',
			'removal capture cannot precede the genuine facade import and boot guard'
		]
	);
	let controls = 0;
	for (const [name, credits] of ports) {
		assert.equal(
			credits(source),
			true,
			name + ': actual closed caption cohort composes original route'
		);
		for (const [before, after, cause] of cases) {
			assert.equal(source.split(before).length - 1, 1, cause + ': unique actual Source anchor');
			const at = source.indexOf(before);
			const changed = source.slice(0, at) + after + source.slice(at + before.length);
			assert.equal(credits(changed), false, name + ': ' + cause);
			assert.equal(changed.slice(at, at + after.length), after, 'exact changed physical interval');
			const repaired = changed.slice(0, at) + before + changed.slice(at + after.length);
			assert.equal(repaired, source, cause + ': position-preserving byte inverse');
			assert.equal(credits(repaired), true, name + ': exact Source repair');
			controls++;
		}
	}
	return controls;
};
