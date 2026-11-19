// tools/test/lib/i18n-dynamic-keys/studio-editor.cjs

/**
 * ==============================================================================
 * MODULE: Studio Editor Key Families
 * DESCRIPTION:
 * The key families the Studio's « Edit » tab builds at run time
 * (layout_editor/editor_page.js through its `tl` accessor, which prepends
 * `layout_editor.`) and the key names the layer model reads
 * (layer_editor/layer_model.js), each enumerated from the tables, page
 * globals and call sites the page reads.
 *
 * FEATURES & RATIONALE:
 * 1. The key names (layer_editor.key.*) are the family the Windows Studio
 *    showed raw for Shift, Ctrl, Alt...: NAMED_KEYS is their one table.
 * 2. The refusal families (error.*, reason.*) fall back to the translated
 *    layout_editor.error.generic message, naming the code, when a code has no
 *    text of its own; they are enumerated from every throw site the page's
 *    scripts hold, and the gate lists the codes that use the fallback.
 * ==============================================================================
 */

'use strict';

const ctx = require('./context.cjs');

const UI = 'static/ergopti_plus/_shared/ui/';
const PAGE = UI + 'layout_editor/editor_page.js';
const LAYER_MODEL = UI + 'layer_editor/layer_model.js';
// The model scripts of the editor page, in its index.html order: they define
// their globals at load and touch no DOM.
const MODEL_SCRIPTS = [
	'layer_editor/_generated/layer_data.js',
	'layout_composer/_generated/composer_data.js',
	'layer_editor/layer_model.js',
	'layout_composer/composer_model.js',
	'layout_composer/reference_layouts.js',
	'layout_composer/source_model.js',
	'layout_composer/source_compiler.js',
	'layout_editor/_generated/key_tables.js',
	'layout_editor/source_io.js',
	'layout_editor/editor_model.js'
].map((rel) => UI + rel);
// The scripts whose refusals reach the editor's problemText.
const REFUSING_SCRIPTS = [
	'layout_editor/editor_page.js',
	'layout_editor/source_io.js',
	'layout_editor/editor_model.js',
	'layout_editor/workspace.js',
	'layout_editor/lua_runner.js',
	'layout_editor/standalone.js',
	'layout_editor/_generated/kbd_dll_writer.js',
	'layout_editor_window/script.js',
	'layout_composer/source_model.js',
	'layout_composer/source_compiler.js',
	'layout_composer/target_compiler.js',
	'layout_composer/target_export.js',
	'layout_composer/composer_model.js'
].map((rel) => UI + rel);

/** Reads a page global from the editor's model scripts. */
function model(expression) {
	return ctx.page(MODEL_SCRIPTS, expression);
}

/**
 * The quoted ids of a slice of a source file, between two markers.
 * @param {string} rel - Repository-relative path.
 * @param {string} from - Text the slice starts at.
 * @param {string} to - Text the slice ends before (searched after `from`).
 * @param {RegExp} pattern - Global pattern whose first capture is an id.
 * @returns {string[]}
 */
function idsBetween(rel, from, to, pattern) {
	const text = ctx.read(rel);
	const start = text.indexOf(from);
	const end = text.indexOf(to, start + from.length);
	if (start === -1 || end === -1) throw new Error(`${rel}: no slice from ${from} to ${to}`);
	const ids = Array.from(text.slice(start, end).matchAll(pattern), (m) => m[1]);
	if (ids.length === 0) throw new Error(`${rel}: ${pattern} matches nothing after ${from}`);
	return [...new Set(ids)];
}

/** Every refusal code a throw site of the page's scripts writes literally. */
function refusalCodes() {
	const codes = new Set();
	const shapes = [
		/new\s+\w*Error\(\s*['"`]([a-z][a-z0-9_]*)['"`]/g,
		/\bfail\(\s*['"`]([a-z][a-z0-9_]*)['"`]/g,
		/\bcode:\s*['"`]([a-z][a-z0-9_]*)['"`]/g
	];
	for (const rel of REFUSING_SCRIPTS) {
		const text = ctx.read(rel);
		for (const shape of shapes) for (const m of text.matchAll(shape)) codes.add(m[1]);
	}
	// problemText's own default for an error without a code, and refusedRow's
	// for a compile refusal without one (a report row's reason).
	codes.add('unexpected');
	codes.add('compile_refused');
	return [...codes];
}

/** Every report reason a target row of LayoutSourceIO.capabilities can carry. */
function reportReasons() {
	const reasons = new Set();
	// The rows source_io.js sets over the format owner's (the drivers' rows).
	for (const m of ctx
		.read(UI + 'layout_editor/source_io.js')
		.matchAll(/\breason:\s*'([a-z][a-z0-9_]*)'/g))
		reasons.add(m[1]);
	// The format owner's row picks its reason in a ternary (source_model.js
	// capabilities); its reason codes are the snake_case ids between reason:
	// and blockers: (the bare 'keylayout' there is the artifact it tests).
	const owner = ctx.read(UI + 'layout_composer/source_model.js');
	const row = owner.slice(owner.indexOf('function capabilities(source)'));
	const reason = row.slice(row.indexOf('reason:'), row.indexOf('blockers:'));
	if (!reason) throw new Error('source_model.js capabilities writes no reason');
	for (const m of reason.matchAll(/'([a-z]+_[a-z_]+)'/g)) reasons.add(m[1]);
	for (const row of ctx.literal(UI + 'layout_composer/source_model.js', 'TARGETS'))
		reasons.add(row.unavailable || 'exporter_not_implemented');
	// A row refusedRow writes carries a refusal code, which reasonText words
	// through problemText: those codes are the error family's.
	return [...reasons];
}

const GENERIC = {
	key: 'layout_editor.error.generic',
	// problemText: a code without its own text reads as the generic refusal.
	guard: /message === PREFIX \+ `error\.\$\{code\}` \? tl\('error\.generic'/
};

module.exports = [
	{
		prefix: 'layer_editor.key.',
		files: [LAYER_MODEL],
		source: 'the values of NAMED_KEYS in layer_editor/layer_model.js',
		keys: () =>
			ctx.keysOf('layer_editor.key.', Object.values(ctx.literal(LAYER_MODEL, 'NAMED_KEYS')))
	},
	{
		prefix: 'layout_editor.btn.',
		files: [PAGE],
		source: 'the actions historyButton is called with in editor_page.js',
		keys: () => ctx.keysOf('layout_editor.btn.', ctx.callArguments(PAGE, 'historyButton'))
	},
	{
		prefix: 'layout_editor.caps.',
		files: [PAGE],
		source: 'LayoutEditorModel.CAPS_MODES',
		keys: () => ctx.keysOf('layout_editor.caps.', model('LayoutEditorModel.CAPS_MODES'))
	},
	{
		prefix: 'layout_editor.error.',
		files: [PAGE],
		source: 'every literal refusal code of the scripts whose errors problemText words',
		fallback: GENERIC,
		keys: () => ctx.keysOf('layout_editor.error.', refusalCodes())
	},
	{
		prefix: 'layout_editor.reason.',
		files: [PAGE],
		source:
			'the reasons of the capabilities rows: source_model.js TARGETS and every reason: literal',
		fallback: {
			key: 'layout_editor.error.generic',
			// reasonText: a reason without its own text is worded as a refusal.
			guard: /typeof strings\[`\$\{PREFIX\}reason\.\$\{code\}`\] === 'string'/
		},
		keys: () => ctx.keysOf('layout_editor.reason.', reportReasons())
	},
	{
		prefix: 'layout_editor.export.option.',
		files: [PAGE],
		source: 'the downloads offer() lists in editor_page.js, and MACOS_EXPORTS',
		keys: () => {
			// offer('toml', …), and the rows of the loops that offer(target, …).
			const from = 'const offer = (id, run)';
			const to = 'downloads.map((entry)';
			const named = idsBetween(PAGE, from, to, /offer\(\s*'([a-z_]+)'/g);
			const rows = idsBetween(PAGE, from, to, /^\s*\['([a-z_]+)',/gm);
			const macos = ctx.literal(PAGE, 'MACOS_EXPORTS').map((variant) => `macos_${variant}`);
			return ctx.keysOf('layout_editor.export.option.', [...named, ...rows, ...macos]);
		}
	},
	{
		prefix: 'layout_editor.fill.level.',
		files: [PAGE],
		source: 'FILL_LEVELS of editor_page.js and LayoutSourceIO.LEVEL_LAYERS',
		keys: () =>
			ctx.keysOf('layout_editor.fill.level.', [
				...ctx.literal(PAGE, 'FILL_LEVELS'),
				...model('LayoutSourceIO.LEVEL_LAYERS.map((level) => level.id)')
			])
	},
	{
		prefix: 'layout_editor.inspector.',
		files: [PAGE],
		source: 'the ids inspectorGroup and group are called with in editor_page.js',
		keys: () =>
			ctx.keysOf('layout_editor.inspector.', [
				...ctx.callArguments(PAGE, 'inspectorGroup'),
				...ctx.callArguments(PAGE, 'group')
			])
	},
	{
		prefix: 'layout_editor.kind.',
		files: [PAGE],
		source: 'MAPPING_CHOICES of editor_page.js',
		keys: () => ctx.keysOf('layout_editor.kind.', ctx.literal(PAGE, 'MAPPING_CHOICES'))
	},
	{
		prefix: 'layout_editor.lost.',
		files: [PAGE],
		source: 'the lost codes source_io.js returns from its imports and copies',
		keys: () => {
			const ids = new Set();
			for (const line of ctx.read(UI + 'layout_editor/source_io.js').split('\n'))
				if (/\blost\b/.test(line) && !/^\s*(\*|\/\/)/.test(line))
					// The codes are the array items and pushed values, not the
					// literals the line's conditions test (convention === 'ansi').
					for (const list of line.matchAll(/(?:\[([^\]]*)\]|push\(([^)]*)\))/g))
						for (const m of (list[1] || list[2] || '').matchAll(/'([a-z][a-z0-9_]*)'/g))
							ids.add(m[1]);
			return ctx.keysOf('layout_editor.lost.', ids);
		}
	},
	{
		prefix: 'layout_editor.meta.',
		files: [PAGE],
		source: 'the names the metadata panel calls field() with',
		keys: () => ctx.keysOf('layout_editor.meta.', ctx.callArguments(PAGE, 'field'))
	},
	{
		prefix: 'layout_editor.modifier.',
		files: [PAGE],
		source: 'the modifier modes source_model.js validates (entry.mode)',
		keys: () =>
			ctx.keysOf(
				'layout_editor.modifier.',
				ctx
					.matches(UI + 'layout_composer/source_model.js', /\[([^\]]*)\]\.includes\(entry\.mode\)/g)
					.flatMap((list) => Array.from(list.matchAll(/'([a-z_]+)'/g), (m) => m[1]))
			)
	},
	{
		prefix: 'layout_editor.palette.block.',
		files: [PAGE],
		source: 'PALETTE_BLOCKS of editor_page.js',
		keys: () =>
			ctx.keysOf(
				'layout_editor.palette.block.',
				ctx.literal(PAGE, 'PALETTE_BLOCKS').map((block) => block.id)
			)
	},
	{
		prefix: 'layout_editor.physical.',
		files: [PAGE],
		source: 'BOARD_FORMS of editor_page.js (iso, ansi and LayoutSource.KEYBOARDS)',
		keys: () => {
			if (
				!/const BOARD_FORMS = \['iso', 'ansi'\]\.concat\(LayoutSource\.KEYBOARDS\);/.test(
					ctx.read(PAGE)
				)
			)
				throw new Error('BOARD_FORMS is no longer iso, ansi and LayoutSource.KEYBOARDS');
			return ctx.keysOf('layout_editor.physical.', [
				'iso',
				'ansi',
				...model('LayoutSource.KEYBOARDS')
			]);
		}
	},
	{
		prefix: 'layout_editor.scope.',
		files: [PAGE],
		source: 'LayoutEditorModel.PLATFORMS',
		keys: () => ctx.keysOf('layout_editor.scope.', model('LayoutEditorModel.PLATFORMS'))
	},
	{
		prefix: 'layout_editor.status_kind.',
		files: [PAGE],
		source:
			'every status a capabilities row is written with (source_model, source_io, source_compiler, target_export)',
		keys: () => {
			const statuses = new Set();
			// A value, or a ternary's branch; not the literal a condition tests.
			for (const rel of [
				'layout_composer/source_model.js',
				'layout_composer/source_compiler.js',
				'layout_composer/target_export.js',
				'layout_editor/source_io.js'
			])
				for (const m of ctx.read(UI + rel).matchAll(/\bstatus:\s*([^,\n}]+)/g))
					for (const id of m[1].matchAll(/(?:^|\?|:)\s*'([a-z_]+)'/g)) statuses.add(id[1]);
			return ctx.keysOf('layout_editor.status_kind.', statuses);
		}
	},
	{
		prefix: 'layout_editor.target.',
		files: [PAGE],
		source: 'TARGETS of source_model.js (the capabilities rows)',
		keys: () =>
			ctx.keysOf(
				'layout_editor.target.',
				ctx.literal(UI + 'layout_composer/source_model.js', 'TARGETS').map((row) => row.target)
			)
	},
	{
		prefix: 'layout_editor.tools.',
		files: [PAGE],
		source: 'TOOLS of editor_page.js',
		keys: () => ctx.keysOf('layout_editor.tools.', ctx.literal(PAGE, 'TOOLS'))
	},
	{
		prefix: 'layout_editor.windows.',
		files: [PAGE],
		source: 'the .klc fields of the Windows panel (klcFields)',
		keys: () =>
			ctx.keysOf(
				'layout_editor.windows.',
				idsBetween(PAGE, 'const klcFields = [', '].map(', /\['([a-z_]+)',/g)
			)
	}
];
